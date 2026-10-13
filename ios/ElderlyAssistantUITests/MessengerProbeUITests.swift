import XCTest

/// Device evidence for the Messenger deep-link forms (2026-10-13).
///
/// The m.me regression was found on-device and the fix must be proven
/// on-device: `devicectl` on this toolchain has no screenshot command,
/// and the phone is network-attached (libimobiledevice's
/// `idevicescreenshot` sees no USB device), so the honest capture path
/// is a UI test. It launches the app with the DEBUG probe argument
/// (`MessengerProbe`), waits for the probe to fire, and grabs
/// FULL-SCREEN screenshots — `XCUIScreen` captures whatever app is on
/// screen, ours or not, which is exactly the question ("did Messenger,
/// Safari, or the App Store land in front?").
///
/// The handle rides in the `PROBE_HANDLE` environment variable supplied
/// to the runner (`TEST_RUNNER_PROBE_HANDLE=<handle>` on the xcodebuild
/// command line — xcodebuild strips the prefix for the runner process;
/// both spellings are read defensively). A synthetic default keeps the
/// test runnable on its own.
final class MessengerProbeUITests: XCTestCase {

    func testProbeMessengerHandleFrontmostScreenshot() throws {
        let environment = ProcessInfo.processInfo.environment
        let handle = environment["PROBE_HANDLE"]
            ?? environment["TEST_RUNNER_PROBE_HANDLE"]
            ?? "probe.synthetic.handle"

        let app = XCUIApplication()
        app.launchArguments = ["-probeMessengerHandle", handle,
                               "-probeDelay", "3",
                               "-probeMode", "open"]
        app.launch()

        // The probe fires 3 s after the first frame; give the external
        // surface time to animate and settle before the captures.
        sleep(10)
        attach(XCUIScreen.main.screenshot(), name: "frontmost-after-probe-\(handle)")
        sleep(5)
        attach(XCUIScreen.main.screenshot(), name: "frontmost-after-probe-later-\(handle)")
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
