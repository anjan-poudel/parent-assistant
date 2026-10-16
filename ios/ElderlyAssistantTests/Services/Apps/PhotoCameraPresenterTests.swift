import AVFoundation
import XCTest
@testable import ElderlyAssistant

/// [APP-LAUNCHER] (2026-09-16) T4's production presenter: the system
/// camera UI (`UIImagePickerController`, `sourceType = .camera`).
///
/// These tests pin the parts that decide what the elder experiences —
/// which availability is reported, whether a picker is presented at all,
/// what the picker is configured to do, and how a delegate callback maps
/// to an outcome. Every device-, permission- and window-shaped input is
/// injected, so the whole matrix runs on a simulator with no camera and
/// no permission prompts.
final class PhotoCameraPresenterTests: XCTestCase {

    // MARK: - Doubles

    /// A picker that records the configuration instead of applying it.
    /// `sourceType` is deliberately NOT passed to UIKit: this machine has
    /// no camera, and the presenter's job is to ask for the camera source,
    /// not to make one exist.
    private final class RecordingPicker: UIImagePickerController {
        private(set) var recordedSourceType: UIImagePickerController.SourceType?
        override var sourceType: UIImagePickerController.SourceType {
            get { recordedSourceType ?? super.sourceType }
            set { recordedSourceType = newValue }
        }

        private(set) var recordedCaptureMode: UIImagePickerController.CameraCaptureMode?
        override var cameraCaptureMode: UIImagePickerController.CameraCaptureMode {
            get { recordedCaptureMode ?? super.cameraCaptureMode }
            set { recordedCaptureMode = newValue }
        }

        /// [F4] How many times the presenter asked for the sheet to come
        /// down. `super` is deliberately NOT called: there is no
        /// presentation to tear down on a camera-less simulator, and the
        /// property under test is that the presenter ASKS at all.
        private(set) var dismissCount = 0
        override func dismiss(animated flag: Bool, completion: (() -> Void)?) {
            dismissCount += 1
        }
    }

    /// Every system the presenter touches, scripted.
    ///
    /// The closures hold the harness WEAKLY and answer with safe defaults
    /// once it is gone: a presenter can legitimately outlive the test that
    /// built it (it retains its completion, and UIKit holds it as a
    /// delegate), and reading a destroyed double must never turn a test
    /// result into a crash.
    private final class Harness {
        var cameraAvailable = true
        var authorization: AVAuthorizationStatus = .authorized
        var host: UIViewController? = UIViewController()
        var accessRequested = 0
        var grantsAccess = true
        private(set) var presented: [(host: UIViewController, picker: UIViewController)] = []
        private(set) var presentedOnMain: [Bool] = []
        let picker = RecordingPicker()
        private(set) var outcomes: [CameraCaptureOutcome] = []
        /// Fired by the injected `present`, so a test can wait for the
        /// presentation instead of sleeping.
        var onPresent: (() -> Void)?

        func makePresenter() -> PhotoCameraPresenter {
            PhotoCameraPresenter(
                host: { [weak self] in self?.host },
                cameraIsAvailable: { [weak self] in self?.cameraAvailable ?? false },
                cameraAuthorization: { [weak self] in self?.authorization ?? .denied },
                requestCameraAccess: { [weak self] completion in
                    self?.accessRequested += 1
                    // The production request hops back to main itself; the
                    // double answers inline so the turn is synchronous.
                    completion(self?.grantsAccess ?? false)
                },
                present: { [weak self] host, picker in
                    self?.presented.append((host, picker))
                    self?.presentedOnMain.append(Thread.isMainThread)
                    self?.onPresent?()
                },
                makePicker: { [weak self] in self?.picker ?? UIImagePickerController() })
        }

        func start(_ presenter: PhotoCameraPresenter) {
            presenter.presentCamera { [weak self] in self?.outcomes.append($0) }
        }
    }

    private var testImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    // MARK: - Availability matrix

    func testNoCaptureDeviceIsNoCameraEvenWhenPermissionIsRefused() {
        let harness = Harness()
        harness.cameraAvailable = false
        harness.authorization = .denied
        harness.host = nil

        XCTAssertEqual(harness.makePresenter().availability, .noCamera,
                       "a device with no camera must never be sent to Settings")
    }

    /// There IS a camera and the permission is fine — but no view
    /// controller to present from. Collapsing this into `noCamera` would
    /// tell the elder their phone has no camera, and into `permissionDenied`
    /// would send them to Settings; both are false.
    func testNoHostIsCannotPresentNotNoCamera() {
        let harness = Harness()
        harness.host = nil

        XCTAssertEqual(harness.makePresenter().availability, .cannotPresent)
    }

    func testAuthorizedCameraWithAHostIsAvailable() {
        let harness = Harness()

        XCTAssertEqual(harness.makePresenter().availability, .available)
    }

    /// The permission prompt is asked at the moment the elder asked for
    /// the camera, never at launch: `.notDetermined` is therefore an
    /// available state, not a refusal.
    func testNotDeterminedIsAvailableUntilTheElderIsAsked() {
        let harness = Harness()
        harness.authorization = .notDetermined

        XCTAssertEqual(harness.makePresenter().availability, .available)
    }

    func testRefusedAndRestrictedAreBothPermissionDenied() {
        for status: AVAuthorizationStatus in [.denied, .restricted] {
            let harness = Harness()
            harness.authorization = status
            XCTAssertEqual(harness.makePresenter().availability, .permissionDenied,
                           "\(status) must be reported as a refusal")
        }
    }

    // MARK: - Presenting

    func testAvailableCameraPresentsTheConfiguredPicker() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        let host = harness.host

        harness.start(presenter)

        XCTAssertEqual(harness.presented.count, 1)
        XCTAssertTrue(harness.presented.first?.host === host)
        XCTAssertTrue(harness.presented.first?.picker === harness.picker)
        XCTAssertEqual(harness.picker.recordedSourceType, .camera)
        XCTAssertEqual(harness.picker.recordedCaptureMode, .photo)
        XCTAssertTrue(harness.picker.delegate === presenter,
                      "the presenter is the picker's delegate — it owns the outcome")
        XCTAssertEqual(harness.picker.modalPresentationStyle, .fullScreen,
                       "the elder asked for the camera, not a card they can lose")
        XCTAssertEqual(harness.outcomes.count, 0,
                       "no outcome yet: the session is running")
    }

    func testAnUnavailableCameraNeverBuildsOrPresentsAPicker() {
        let harness = Harness()
        harness.cameraAvailable = false

        harness.start(harness.makePresenter())

        XCTAssertTrue(harness.presented.isEmpty,
                      "never present a sheet that cannot appear")
        XCTAssertEqual(harness.outcomes, [.unavailable(.noCamera)])
    }

    func testARefusedPermissionNeverPresentsAndReportsTheRefusal() {
        let harness = Harness()
        harness.authorization = .denied

        harness.start(harness.makePresenter())

        XCTAssertTrue(harness.presented.isEmpty)
        XCTAssertEqual(harness.outcomes, [.unavailable(.permissionDenied)])
    }

    func testNoHostNeverPresentsAndReportsCannotPresent() {
        let harness = Harness()
        harness.host = nil

        harness.start(harness.makePresenter())

        XCTAssertTrue(harness.presented.isEmpty)
        XCTAssertEqual(harness.outcomes, [.unavailable(.cannotPresent)])
    }

    // MARK: - Permission asked at point of use

    func testAnUndeterminedPermissionIsAskedAtPointOfUseAndPresentsWhenGranted() {
        let harness = Harness()
        harness.authorization = .notDetermined
        harness.grantsAccess = true

        harness.start(harness.makePresenter())

        XCTAssertEqual(harness.accessRequested, 1)
        XCTAssertEqual(harness.presented.count, 1)
        XCTAssertEqual(harness.picker.recordedSourceType, .camera)
    }

    func testAnUndeterminedPermissionRefusedAtThePromptIsReportedAsRefused() {
        let harness = Harness()
        harness.authorization = .notDetermined
        harness.grantsAccess = false

        harness.start(harness.makePresenter())

        XCTAssertEqual(harness.accessRequested, 1)
        XCTAssertTrue(harness.presented.isEmpty, "a refused prompt gets no picker")
        XCTAssertEqual(harness.outcomes, [.unavailable(.permissionDenied)])
    }

    /// The request is only made when the status is still undetermined —
    /// asking an already-authorized elder again would be a second prompt
    /// for something they already granted.
    func testAnAuthorizedElderIsNeverAskedAgain() {
        let harness = Harness()

        harness.start(harness.makePresenter())

        XCTAssertEqual(harness.accessRequested, 0)
        XCTAssertEqual(harness.presented.count, 1)
    }

    // MARK: - Delegate mapping

    func testPickingAPhotoHandsTheOriginalImageBack() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)
        let image = testImage

        presenter.imagePickerController(harness.picker,
                                        didFinishPickingMediaWithInfo: [.originalImage: image])

        XCTAssertEqual(harness.outcomes.count, 1)
        guard case .captured(let returned) = harness.outcomes.first else {
            return XCTFail("expected a captured outcome, got \(harness.outcomes)")
        }
        XCTAssertEqual(returned.size, image.size)
    }

    func testCancellingThePickerReportsACancel() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)

        presenter.imagePickerControllerDidCancel(harness.picker)

        XCTAssertEqual(harness.outcomes, [.cancelled])
    }

    /// [F4] Cancelling dismisses the picker — the same thing the capture
    /// path does, and the thing this callback used to assume UIKit would do
    /// for it.
    ///
    /// It does not: `dismiss(animated:)` is the presenter's job in this
    /// flow, so the sheet stayed on screen over the app while the flow had
    /// already reported the cancel and gone back to idle — an elder left
    /// staring at a dead camera.
    func testCancellingThePickerDismissesTheSheet() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)

        presenter.imagePickerControllerDidCancel(harness.picker)

        XCTAssertEqual(harness.picker.dismissCount, 1,
                       "a cancel must take the camera down with it")
        XCTAssertEqual(harness.outcomes, [.cancelled])
    }

    /// The capture half of the same contract, pinned alongside it so the
    /// two callbacks can never drift apart again.
    func testPickingAPhotoDismissesTheSheet() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)

        presenter.imagePickerController(harness.picker,
                                        didFinishPickingMediaWithInfo: [.originalImage: testImage])

        XCTAssertEqual(harness.picker.dismissCount, 1)
    }

    /// [F5] A second session request while one is live is answered
    /// immediately and honestly, instead of overwriting the running
    /// session's completion.
    ///
    /// Overwriting it is exactly how a photo goes missing: the first
    /// session's completion is dropped, and when its picker's delegate
    /// callback arrives it finds a nil slot and reports nothing — the elder
    /// pressed the shutter and heard silence.
    func testASecondRequestWhileOneSessionIsLiveIsRefusedAndLeavesTheFirstIntact() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)
        XCTAssertEqual(harness.presented.count, 1)

        var second: CameraCaptureOutcome?
        presenter.presentCamera { second = $0 }

        XCTAssertEqual(second, .unavailable(.cannotPresent),
                       "the second request is told it cannot be served right now")
        XCTAssertEqual(harness.presented.count, 1, "no second picker is stacked")

        presenter.imagePickerController(harness.picker,
                                        didFinishPickingMediaWithInfo: [.originalImage: testImage])

        XCTAssertEqual(harness.outcomes.count, 1,
                       "the first session still owns the completion")
        guard case .captured = harness.outcomes.first else {
            return XCTFail("expected the first session's capture, got \(harness.outcomes)")
        }
    }

    /// …and a fresh session is accepted the moment the previous one ends:
    /// the refusal above is about concurrency, not about a one-shot
    /// presenter.
    func testASessionCanStartAgainOnceThePreviousOneEnded() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)
        presenter.imagePickerController(harness.picker,
                                        didFinishPickingMediaWithInfo: [.originalImage: testImage])

        harness.start(presenter)

        XCTAssertEqual(harness.presented.count, 2, "the next launch gets its own session")
        XCTAssertEqual(harness.outcomes.count, 1, "and the finished one reports nothing more")
    }

    /// A media dictionary with no image (a media type a `.photo` capture
    /// should never produce) is a cancel, never a claim that something was
    /// captured.
    func testACompletionWithNoImageIsACancelNotACapture() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)

        presenter.imagePickerController(harness.picker, didFinishPickingMediaWithInfo: [:])

        XCTAssertEqual(harness.outcomes, [.cancelled])
    }

    /// One session, one outcome: a late callback after the session ended is
    /// dropped rather than spoken as a second result.
    func testASecondCallbackAfterTheSessionEndedIsIgnored() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.start(presenter)

        presenter.imagePickerController(harness.picker,
                                        didFinishPickingMediaWithInfo: [.originalImage: testImage])
        presenter.imagePickerControllerDidCancel(harness.picker)

        XCTAssertEqual(harness.outcomes.count, 1, "the session is over after the first callback")
    }

    /// The unavailable paths end the session immediately (there is nothing
    /// to present, so nothing can call back). A stray callback must still
    /// not produce a second, contradictory outcome.
    func testACallbackAfterAnUnavailableSessionDeliversNothing() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        harness.cameraAvailable = false
        harness.start(presenter)

        presenter.imagePickerControllerDidCancel(harness.picker)

        XCTAssertEqual(harness.outcomes, [.unavailable(.noCamera)])
    }

    // MARK: - Threading

    /// `CameraCaptureFlow` may hand the launch over from wherever it is;
    /// UIKit and AVFoundation are main-thread-only, so the presenter hops
    /// rather than trapping.
    func testPresentingFromABackgroundThreadHopsToMain() {
        let harness = Harness()
        let presenter = harness.makePresenter()
        let presented = expectation(description: "picker presented")
        harness.onPresent = { presented.fulfill() }

        DispatchQueue.global().async {
            presenter.presentCamera { _ in }
        }

        wait(for: [presented], timeout: 2)
        XCTAssertEqual(harness.presentedOnMain, [true],
                       "the picker must be configured and presented on main")
    }

    /// The host lookup is a smoke test only: in the test host it may or may
    /// not find a key window, but it must never trap.
    func testTopmostLookupNeverTraps() {
        _ = PhotoCameraPresenter.keyWindowTopmost()
    }
}
