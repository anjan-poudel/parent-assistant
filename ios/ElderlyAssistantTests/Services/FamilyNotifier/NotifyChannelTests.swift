import XCTest
@testable import ElderlyAssistant

/// Channel-derivation rules for caregiver event alerts (caregiver
/// event-notifications task, 2026-09-13). Pure mapping, no fixtures —
/// the whole point of `NotifyChannel` is that the delivery surface is
/// decided by a rule a test can state in one line.
final class NotifyChannelTests: XCTestCase {

    // MARK: - app → channel

    /// Every `CallApp` has an answer. `CallApp` has no `allCases`, so the
    /// list is written out on purpose: a new case must break THIS test
    /// (and force a deliberate channel decision) rather than silently
    /// inherit whatever the switch happens to do.
    func testMappingIsTotalForEveryCallApp() {
        let expected: [(CallApp, NotifyChannel)] = [
            (.faceTime, .sms),
            (.phone, .sms),
            (.messenger, .messenger),
            (.whatsApp, .whatsApp)
        ]
        for (app, channel) in expected {
            XCTAssertEqual(NotifyChannel.resolve(from: app), channel,
                           "\(app) must map to \(channel)")
        }
    }

    /// FaceTime is video-only in the app's call vocabulary
    /// (`CallApp.supportsVideo`/`supportsAudio`), so it has no text
    /// surface of its own and takes the universal fallback.
    func testFaceTimeFallsBackToSMSRatherThanInventingAVideoTextSurface() {
        XCTAssertEqual(NotifyChannel.resolve(from: .faceTime), .sms)
        XCTAssertFalse(CallApp.faceTime.supportsAudio,
                       "the premise of the SMS fallback: FaceTime carries no audio/text on its own")
    }

    /// Messenger addresses people by username, not phone number — a
    /// handle-less contact dead-ends exactly the way the Messenger call
    /// button does, so the alert drops to SMS instead of vanishing.
    func testMessengerKeepsMessengerOnlyWhenAHandleIsOnFile() {
        XCTAssertEqual(NotifyChannel.resolve(from: .messenger, messengerHandleAvailable: true),
                       .messenger)
        XCTAssertEqual(NotifyChannel.resolve(from: .messenger, messengerHandleAvailable: false),
                       .sms)
    }

    /// The bare app→channel form defaults the handle question to TRUE:
    /// it is called without a contact in hand (the `resolve(from:)`
    /// shape), and a Messenger pick is a deliberate one.
    func testHandleAvailabilityDefaultsToTrue() {
        XCTAssertEqual(NotifyChannel.resolve(from: .messenger), .messenger)
    }

    // MARK: - preferred / default resolution

    /// `.phone` IS the unconfigured default of
    /// `FamilyContact.preferredCallApp`, so it must fall through to the
    /// global default app instead of pinning every contact to SMS.
    func testUnconfiguredPerContactPreferenceFallsThroughToTheGlobalDefault() {
        XCTAssertEqual(NotifyChannel.resolve(preferred: .phone, defaultApp: .whatsApp,
                                             messengerHandleAvailable: true),
                       .whatsApp,
                       "a .phone pick is 'not configured', not 'I want SMS'")
        XCTAssertEqual(NotifyChannel.resolve(preferred: .phone, defaultApp: .messenger,
                                             messengerHandleAvailable: true),
                       .messenger)
    }

    /// A deliberate per-contact pick wins over the global default — the
    /// same precedence `AppCoordinator.resolvedCallChannel` uses.
    func testExplicitPerContactPickBeatsTheGlobalDefault() {
        XCTAssertEqual(NotifyChannel.resolve(preferred: .whatsApp, defaultApp: .phone,
                                             messengerHandleAvailable: true),
                       .whatsApp)
        XCTAssertEqual(NotifyChannel.resolve(preferred: .messenger, defaultApp: .whatsApp,
                                             messengerHandleAvailable: true),
                       .messenger)
    }

    /// The handle rule survives the two-level resolution: a Messenger
    /// pick (explicit OR global) with no handle still lands on SMS.
    func testHandleRuleAppliesAfterPrecedenceIsResolved() {
        XCTAssertEqual(NotifyChannel.resolve(preferred: .messenger, defaultApp: .phone,
                                             messengerHandleAvailable: false),
                       .sms)
        XCTAssertEqual(NotifyChannel.resolve(preferred: .phone, defaultApp: .messenger,
                                             messengerHandleAvailable: false),
                       .sms)
    }

    // MARK: - wire format

    /// The raw values are the payload spelling the future relay carries —
    /// the same spelling `CallApp` uses, so a channel and an app never
    /// disagree about what "whatsApp" is called.
    func testRawValuesAreTheWireSpelling() {
        XCTAssertEqual(NotifyChannel.sms.rawValue, "sms")
        XCTAssertEqual(NotifyChannel.whatsApp.rawValue, "whatsApp")
        XCTAssertEqual(NotifyChannel.messenger.rawValue, "messenger")
        XCTAssertEqual(NotifyChannel.whatsApp.rawValue, CallApp.whatsApp.rawValue)
        XCTAssertEqual(NotifyChannel.messenger.rawValue, CallApp.messenger.rawValue)
    }
}
