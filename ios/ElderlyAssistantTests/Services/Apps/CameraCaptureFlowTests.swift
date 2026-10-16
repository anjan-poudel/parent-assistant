import XCTest
import UIKit
@testable import ElderlyAssistant

/// [APP-LAUNCHER] (2026-09-16) The camera special path's decision layer:
/// probe → present → save → say what actually happened.
///
/// Every path out of the camera is covered with doubles — no device, no
/// permission prompt, no photo library — because these tests exist to pin
/// the SPOKEN outcome: "photo saved" only when the asset was really
/// created, an honest failure when it was not, and guidance (never a
/// crash, never a silent nothing) when the camera cannot be presented at
/// all.
final class CameraCaptureFlowTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")
    private let en = Locale(identifier: "en-US")

    // MARK: - Doubles

    /// Scripted presenter: reports any availability and hands back any
    /// outcome, recording whether the system UI was asked for at all.
    private final class FakePresenter: CameraCapturePresenting {
        var availability: CameraAvailability
        var outcome: CameraCaptureOutcome
        private(set) var presentCount = 0

        /// [F5] When true the session is HELD open (the camera is still on
        /// screen) instead of finishing inline — the in-flight state the
        /// one-session-at-a-time tests need.
        var holdsSession = false
        private var pending: ((CameraCaptureOutcome) -> Void)?

        init(availability: CameraAvailability = .available,
             outcome: CameraCaptureOutcome = .cancelled,
             holdsSession: Bool = false) {
            self.availability = availability
            self.outcome = outcome
            self.holdsSession = holdsSession
        }

        func presentCamera(completion: @escaping (CameraCaptureOutcome) -> Void) {
            presentCount += 1
            guard holdsSession else { return completion(outcome) }
            pending = completion
        }

        /// Ends the held session with the scripted outcome.
        func finishHeldSession() {
            let completion = pending
            pending = nil
            completion?(outcome)
        }
    }

    /// Scripted photo library: whatever `saved` is, the flow must speak
    /// accordingly — a false here is never swallowed.
    private final class FakeSaver: PhotoSaving {
        var saved: Bool
        /// [F7] What the pre-flight resolves to — the answer to "may a
        /// photo be stored at all".
        var prepareGranted: Bool
        private(set) var prepareCount = 0
        private(set) var savedImages: [UIImage] = []

        init(saved: Bool = true, prepareGranted: Bool = true) {
            self.saved = saved
            self.prepareGranted = prepareGranted
        }

        func prepareToSave(completion: @escaping (Bool) -> Void) {
            prepareCount += 1
            completion(prepareGranted)
        }

        func savePhoto(_ image: UIImage, completion: @escaping (Bool) -> Void) {
            savedImages.append(image)
            completion(saved)
        }
    }

    private final class Recorder {
        var spoken: [String] = []
        var announced: [(icon: String, text: String)] = []
        var emitted: [(type: String, outcome: String)] = []
    }

    private func makeFlow(presenter: FakePresenter, saver: FakeSaver,
                          locale: Locale? = nil, recorder: Recorder)
        -> CameraCaptureFlow {
        CameraCaptureFlow(
            presenter: presenter,
            saver: saver,
            locale: { locale ?? self.ne },
            channels: .init(speak: { recorder.spoken.append($0) },
                            announce: { recorder.announced.append(($0, $1)) },
                            emit: { recorder.emitted.append(($0, $1)) }),
            // The system callbacks land on arbitrary queues in production;
            // here they run inline so a test asserts the whole turn.
            deliver: { $0() })
    }

    private var testImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    // MARK: - Captured + saved

    func testCapturedAndSavedPhotoIsConfirmedOutLoud() {
        let presenter = FakePresenter(outcome: .captured(testImage))
        let saver = FakeSaver(saved: true)
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: saver, recorder: recorder).start()

        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(saver.savedImages.count, 1, "the shot must be handed to the library")
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.photoSaved", locale: ne)])
        XCTAssertEqual(recorder.announced.map(\.icon), ["checkmark.circle.fill"])
        XCTAssertEqual(recorder.emitted.map(\.type), ["camera_capture_finished"])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["photoSaved"])
    }

    func testTheSavedLineIsSpokenInTheActiveLocale() {
        let recorder = Recorder()
        makeFlow(presenter: FakePresenter(outcome: .captured(testImage)),
                 saver: FakeSaver(saved: true),
                 locale: en, recorder: recorder).start()

        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.photoSaved", locale: en)])
        XCTAssertEqual(recorder.spoken.first, "Photo saved.")
    }

    /// A shutter press whose write FAILED must be said out loud: the
    /// elder believes a photo exists and would otherwise never learn
    /// otherwise (constitution: no silent stubs).
    func testSaveFailureIsSpokenHonestly() {
        let recorder = Recorder()
        makeFlow(presenter: FakePresenter(outcome: .captured(testImage)),
                 saver: FakeSaver(saved: false), recorder: recorder).start()

        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.saveFailed", locale: ne)])
        XCTAssertEqual(recorder.announced.map(\.icon), ["exclamationmark.triangle.fill"])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["saveFailed"])
        XCTAssertNotEqual(recorder.spoken, [L10n.str("apps.camera.photoSaved", locale: ne)],
                          "a failed write must never be reported as saved")
    }

    // MARK: - Cancelled

    func testCancellingTheCameraSavesNothingAndSaysSoGently() {
        let presenter = FakePresenter(outcome: .cancelled)
        let saver = FakeSaver()
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: saver, recorder: recorder).start()

        XCTAssertTrue(saver.savedImages.isEmpty, "a cancelled session must write nothing")
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.cancelled", locale: ne)])
        XCTAssertEqual(recorder.emitted.map(\.type), ["camera_capture_cancelled"])
        XCTAssertTrue(recorder.announced.isEmpty,
                      "a cancel is not an outcome card — the elder just closed the camera")
    }

    // MARK: - Unavailable (simulator / camera-less / permission denied)

    func testNoCameraIsAnsweredWithoutPresentingAnything() {
        let presenter = FakePresenter(availability: .noCamera)
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: FakeSaver(), recorder: recorder).start()

        XCTAssertEqual(presenter.presentCount, 0,
                       "never present a sheet that cannot appear on this device")
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.unavailable", locale: ne)])
        XCTAssertEqual(recorder.announced.map(\.icon), ["exclamationmark.triangle.fill"])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["noCamera"])
    }

    /// The simulator path — the one every `xcodebuild test` run takes —
    /// is the `noCamera` case above; this pins that a presenter whose
    /// availability flips to unavailable BETWEEN the probe and the
    /// completion still lands on the same honest line rather than an
    /// "Opening Camera" over nothing.
    func testAnUnavailableOutcomeFromThePresenterIsSpokenHonestly() {
        let presenter = FakePresenter(availability: .available,
                                     outcome: .unavailable(.noCamera))
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: FakeSaver(), recorder: recorder).start()

        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.unavailable", locale: ne)])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["noCamera"])
    }

    func testPermissionDeniedGetsItsOwnGuidanceLine() {
        let presenter = FakePresenter(availability: .permissionDenied)
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: FakeSaver(), recorder: recorder).start()

        XCTAssertEqual(presenter.presentCount, 0)
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.permissionDenied", locale: ne)])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["permissionDenied"])
    }

    /// The denied CAMERA and the missing camera are different problems
    /// with different fixes — the line must not collapse them.
    func testDeniedAndMissingCameraSpeakDifferentLines() {
        XCTAssertNotEqual(L10n.str("apps.camera.permissionDenied", locale: ne),
                          L10n.str("apps.camera.unavailable", locale: ne))
        XCTAssertNotEqual(L10n.str("apps.camera.permissionDenied", locale: en),
                          L10n.str("apps.camera.unavailable", locale: en))
    }

    /// A camera that exists and is permitted but has no window to be
    /// presented from is a THIRD problem: the elder should try again, and
    /// neither "no camera on this phone" nor "go to Settings" is true.
    func testACameraWithNothingToPresentFromGetsItsOwnLine() {
        let presenter = FakePresenter(availability: .cannotPresent)
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: FakeSaver(), recorder: recorder).start()

        XCTAssertEqual(presenter.presentCount, 0)
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.cannotPresent", locale: ne)])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["cannotPresent"])
        XCTAssertNotEqual(L10n.str("apps.camera.cannotPresent", locale: ne),
                          L10n.str("apps.camera.unavailable", locale: ne))
        XCTAssertNotEqual(L10n.str("apps.camera.cannotPresent", locale: ne),
                          L10n.str("apps.camera.permissionDenied", locale: ne))
    }

    // MARK: - One session at a time (F5)

    /// [F5] The flow is built once and lives for the app's lifetime, so a
    /// second "क्यामेरा खोल" while the camera is still up must not stack a
    /// second picker — and must not touch the session that is running.
    ///
    /// The damage of the old behaviour was worse than a double sheet: the
    /// presenter's single completion slot was overwritten, so the first
    /// session's shot reported into a nil slot and the photo was lost
    /// without a word.
    func testASecondStartWhileTheCameraIsUpDoesNotStackAPickerOrLoseTheFirstSession() {
        let presenter = FakePresenter(outcome: .cancelled, holdsSession: true)
        let saver = FakeSaver()
        let recorder = Recorder()
        let flow = makeFlow(presenter: presenter, saver: saver, recorder: recorder)

        flow.start()
        XCTAssertEqual(presenter.presentCount, 1)

        flow.start()

        XCTAssertEqual(presenter.presentCount, 1, "no second picker is stacked")
        XCTAssertEqual(saver.savedImages.count, 0)
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.cannotPresent", locale: ne)],
                       "the second request is answered honestly, never silently dropped")
        XCTAssertEqual(recorder.emitted.map(\.type), ["camera_capture_unavailable"])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["cannotPresent"])

        // …and the FIRST session is untouched: it still reports its own
        // outcome when the elder closes the camera.
        presenter.finishHeldSession()

        XCTAssertEqual(recorder.spoken,
                       [L10n.str("apps.camera.cannotPresent", locale: ne),
                        L10n.str("apps.camera.cancelled", locale: ne)])
        XCTAssertEqual(recorder.emitted.map(\.type),
                       ["camera_capture_unavailable", "camera_capture_cancelled"])
    }

    /// A session that has ENDED frees the flow for the next launch: the
    /// busy answer above is about concurrency, not about a one-shot flow.
    func testANewSessionStartsOnceThePreviousOneHasEnded() {
        let presenter = FakePresenter(outcome: .cancelled)
        let recorder = Recorder()
        let flow = makeFlow(presenter: presenter, saver: FakeSaver(), recorder: recorder)

        flow.start()
        flow.start()

        XCTAssertEqual(presenter.presentCount, 2, "the next launch gets its own session")
        XCTAssertEqual(recorder.emitted.map(\.type),
                       ["camera_capture_cancelled", "camera_capture_cancelled"])
    }

    // MARK: - Photo-library permission before the camera (F7)

    /// [F7] A refused photo-library permission stops the flow BEFORE the
    /// picker: an elder who cannot store a photo must not be walked through
    /// taking one and then have it thrown away.
    func testARefusedPhotoPermissionStopsBeforeTheCameraAndSaysWhatToDo() {
        let presenter = FakePresenter(outcome: .captured(testImage))
        let saver = FakeSaver(saved: true, prepareGranted: false)
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: saver, recorder: recorder).start()

        XCTAssertEqual(saver.prepareCount, 1, "the permission is resolved up front")
        XCTAssertEqual(presenter.presentCount, 0,
                       "no camera is presented when the photo could not be saved")
        XCTAssertTrue(saver.savedImages.isEmpty,
                      "and nothing is ever discarded after a shutter")
        XCTAssertEqual(recorder.spoken,
                       [L10n.str("apps.camera.savePermissionDenied", locale: ne)])
        XCTAssertEqual(recorder.announced.map(\.icon), ["exclamationmark.triangle.fill"])
        XCTAssertEqual(recorder.emitted.map(\.type), ["camera_capture_unavailable"])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["savePermissionDenied"])
        XCTAssertNotEqual(L10n.str("apps.camera.savePermissionDenied", locale: ne),
                          L10n.str("apps.camera.permissionDenied", locale: ne),
                          "a refused PHOTO permission is not a refused CAMERA permission — different fix")
    }

    /// The granted half: the permission is resolved once, before the
    /// picker, and the session then runs exactly as before.
    func testThePhotoPermissionIsResolvedBeforeThePickerIsPresented() {
        let presenter = FakePresenter(outcome: .captured(testImage))
        let saver = FakeSaver(saved: true, prepareGranted: true)
        let recorder = Recorder()

        makeFlow(presenter: presenter, saver: saver, recorder: recorder).start()

        XCTAssertEqual(saver.prepareCount, 1)
        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(saver.savedImages.count, 1)
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.photoSaved", locale: ne)])
    }

    /// [F15] Every channel goes through the injected main-queue hop — the
    /// `.unavailable` probe included. Speech, the outcome card and the bus
    /// are main-confined elsewhere in the app; this branch used to call
    /// them synchronously on whatever queue `start()` arrived on, so a
    /// caller off main spoke off main.
    func testAnUnavailableProbeDeliversEveryChannelThroughTheQueueHop() {
        let presenter = FakePresenter(availability: .noCamera)
        let recorder = Recorder()
        let delivered = expectation(description: "channels delivered")
        let flow = CameraCaptureFlow(
            presenter: presenter,
            saver: FakeSaver(),
            locale: { self.ne },
            channels: .init(
                speak: { text in
                    XCTAssertTrue(Thread.isMainThread, "speech must be main-confined")
                    recorder.spoken.append(text)
                },
                announce: { icon, text in
                    XCTAssertTrue(Thread.isMainThread, "the outcome card must be main-confined")
                    recorder.announced.append((icon, text))
                },
                emit: { type, outcome in
                    XCTAssertTrue(Thread.isMainThread, "the bus must be main-confined")
                    recorder.emitted.append((type, outcome))
                    delivered.fulfill()
                }),
            deliver: { DispatchQueue.main.async(execute: $0) })

        DispatchQueue.global().async { flow.start() }

        wait(for: [delivered], timeout: 2.0)
        XCTAssertEqual(recorder.spoken, [L10n.str("apps.camera.unavailable", locale: ne)])
        XCTAssertEqual(recorder.emitted.map(\.outcome), ["noCamera"])
    }

    /// Every line this flow can speak resolves in both locales — a
    /// missing translation would surface to the elder as a raw key.
    func testEveryCameraLineResolvesInBothLocales() {
        let keys = ["apps.camera.photoSaved", "apps.camera.saveFailed",
                    "apps.camera.cancelled", "apps.camera.unavailable",
                    "apps.camera.permissionDenied", "apps.camera.cannotPresent",
                    "apps.camera.savePermissionDenied"]
        for key in keys {
            for locale in [en, ne] {
                let value = L10n.str(key, locale: locale)
                XCTAssertNotEqual(value, key, "\(key) must resolve in \(locale)")
                XCTAssertFalse(value.isEmpty)
            }
        }
    }
}
