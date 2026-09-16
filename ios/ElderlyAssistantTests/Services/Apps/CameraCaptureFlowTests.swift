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

        init(availability: CameraAvailability = .available,
             outcome: CameraCaptureOutcome = .cancelled) {
            self.availability = availability
            self.outcome = outcome
        }

        func presentCamera(completion: @escaping (CameraCaptureOutcome) -> Void) {
            presentCount += 1
            completion(outcome)
        }
    }

    /// Scripted photo library: whatever `saved` is, the flow must speak
    /// accordingly — a false here is never swallowed.
    private final class FakeSaver: PhotoSaving {
        var saved: Bool
        private(set) var savedImages: [UIImage] = []

        init(saved: Bool = true) { self.saved = saved }

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

    /// Every line this flow can speak resolves in both locales — a
    /// missing translation would surface to the elder as a raw key.
    func testEveryCameraLineResolvesInBothLocales() {
        let keys = ["apps.camera.photoSaved", "apps.camera.saveFailed",
                    "apps.camera.cancelled", "apps.camera.unavailable",
                    "apps.camera.permissionDenied", "apps.camera.cannotPresent"]
        for key in keys {
            for locale in [en, ne] {
                let value = L10n.str(key, locale: locale)
                XCTAssertNotEqual(value, key, "\(key) must resolve in \(locale)")
                XCTAssertFalse(value.isEmpty)
            }
        }
    }
}
