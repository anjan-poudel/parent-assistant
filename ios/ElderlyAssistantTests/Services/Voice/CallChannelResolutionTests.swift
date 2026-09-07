import XCTest
@testable import ElderlyAssistant

/// The channel-resolution matrix behind an ADDRESS-BOOK row's call
/// button (Phone-tab redesign, 2026-09-07): the row's explicit pick
/// beats the global default, and a `.messenger` result that has no
/// on-file handle drops to `.phone` — a row must never resolve to a
/// channel it cannot open. Pure static seam on AppCoordinator, so the
/// whole matrix is covered without instantiating the coordinator.
final class CallChannelResolutionTests: XCTestCase {

    func testExplicitPickBeatsDefault() {
        assertResolved(explicit: .whatsApp, defaultApp: .phone, handleAvailable: true, expected: .whatsApp)
        assertResolved(explicit: .faceTime, defaultApp: .phone, handleAvailable: true, expected: .faceTime)
        assertResolved(explicit: .messenger, defaultApp: .whatsApp, handleAvailable: true, expected: .messenger)
        assertResolved(explicit: .phone, defaultApp: .messenger, handleAvailable: true, expected: .phone)
    }

    func testMissingExplicitFallsBackToDefault() {
        assertResolved(explicit: nil, defaultApp: .whatsApp, handleAvailable: true, expected: .whatsApp)
        assertResolved(explicit: nil, defaultApp: .faceTime, handleAvailable: true, expected: .faceTime)
        assertResolved(explicit: nil, defaultApp: .phone, handleAvailable: false, expected: .phone)
    }

    func testDefaultMessengerWithoutHandleDropsToPhone() {
        assertResolved(explicit: nil, defaultApp: .messenger, handleAvailable: false, expected: .phone)
    }

    func testDefaultMessengerWithHandleStaysMessenger() {
        assertResolved(explicit: nil, defaultApp: .messenger, handleAvailable: true, expected: .messenger)
    }

    func testExplicitMessengerWithoutHandleDropsToPhone() {
        // A row with no handle cannot open a Messenger thread even when
        // the user explicitly pinned Messenger — .phone is the honest
        // openable channel (contract: never resolve to a channel the
        // row cannot open).
        assertResolved(explicit: .messenger, defaultApp: .phone, handleAvailable: false, expected: .phone)
        assertResolved(explicit: .messenger, defaultApp: .messenger, handleAvailable: false, expected: .phone)
    }

    func testExplicitMessengerWithHandleStaysMessenger() {
        assertResolved(explicit: .messenger, defaultApp: .phone, handleAvailable: true, expected: .messenger)
    }

    func testWhatsAppFaceTimeAndPhonePassThroughWithoutHandle() {
        // The handle gate applies to Messenger only — every other
        // channel opens by phone number and is unaffected.
        assertResolved(explicit: .whatsApp, defaultApp: .phone, handleAvailable: false, expected: .whatsApp)
        assertResolved(explicit: .faceTime, defaultApp: .phone, handleAvailable: false, expected: .faceTime)
        assertResolved(explicit: .phone, defaultApp: .messenger, handleAvailable: false, expected: .phone)
        assertResolved(explicit: nil, defaultApp: .whatsApp, handleAvailable: false, expected: .whatsApp)
        assertResolved(explicit: nil, defaultApp: .faceTime, handleAvailable: false, expected: .faceTime)
        assertResolved(explicit: nil, defaultApp: .phone, handleAvailable: false, expected: .phone)
    }

    private func assertResolved(explicit: CallApp?, defaultApp: CallApp,
                                handleAvailable: Bool, expected: CallApp,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            AppCoordinator.resolvedCallChannel(explicit: explicit,
                                               defaultApp: defaultApp,
                                               messengerHandleAvailable: handleAvailable),
            expected,
            "explicit: \(String(describing: explicit)), default: \(defaultApp), handle: \(handleAvailable)",
            file: file, line: line
        )
    }
}
