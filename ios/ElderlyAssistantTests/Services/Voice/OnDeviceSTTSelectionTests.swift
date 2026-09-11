import XCTest
@testable import ElderlyAssistant

/// Unit tests for the on-device STT engine preference table
/// ([STARTUP-R2], 2026-09-10) — devices favor ANE WhisperKit, the
/// simulator forces the cheaper whisper.cpp path when its bundled model
/// is available (reason "simulator", mirroring the warm plan's skip).
final class OnDeviceSTTSelectionTests: XCTestCase {

    // MARK: - Devices (non-simulator)

    func testDevicePrefersWhisperKitWhenAvailable() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: true,
                                        isSimulator: false),
            .whisperKit)
        // whisper.cpp availability is irrelevant on a device with the
        // ANE artifact installed.
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: false,
                                        isSimulator: false),
            .whisperKit)
    }

    func testDeviceFallsToWhisperCppWhenWhisperKitMissing() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: false,
                                        whisperCppAvailable: true,
                                        isSimulator: false),
            .whisperCpp(reason: "whisperkit_unavailable"))
    }

    func testDeviceFallsBackWhenNoWhisperModel() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: false,
                                        whisperCppAvailable: false,
                                        isSimulator: false),
            .fallback(reason: "no_whisper_model"))
    }

    // MARK: - Simulator

    func testSimulatorForcesWhisperCppWhenBothAvailable() {
        // The CPU-only WhisperKit prepare is a minutes-scale load that
        // outlives the boot watchdog without ever helping a sim
        // conversation — the bundled whisper.cpp model wins with the
        // honest "simulator" reason.
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: true,
                                        isSimulator: true),
            .whisperCpp(reason: "simulator"))
    }

    func testSimulatorFallsToWhisperCppWhenWhisperKitMissing() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: false,
                                        whisperCppAvailable: true,
                                        isSimulator: true),
            .whisperCpp(reason: "whisperkit_unavailable"))
    }

    func testSimulatorKeepsWhisperKitWhenItIsTheOnlyOption() {
        // A sim with ONLY the WhisperKit artifact still gets it (better
        // than nothing) — the caller skips prepare() there so the
        // selection adds no startup load either way.
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: false,
                                        isSimulator: true),
            .whisperKit)
    }

    // MARK: - Prepare policy

    func testPrepareOnlyOnDevice() {
        XCTAssertTrue(OnDeviceSTTSelection.shouldPrepareWhisperKit(isSimulator: false))
        XCTAssertFalse(OnDeviceSTTSelection.shouldPrepareWhisperKit(isSimulator: true))
    }

    // MARK: - Coordinator seam

    func testCoordinatorChoiceDelegatesToTable() {
        XCTAssertEqual(
            AppCoordinator.onDeviceSTTChoice(whisperKitAvailable: true,
                                             whisperCppAvailable: true,
                                             isSimulator: true),
            .whisperCpp(reason: "simulator"))
        XCTAssertEqual(
            AppCoordinator.onDeviceSTTChoice(whisperKitAvailable: true,
                                             whisperCppAvailable: false,
                                             isSimulator: false),
            .whisperKit)
    }
}
