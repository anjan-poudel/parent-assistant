import XCTest
@testable import ElderlyAssistant

/// The on-device stack's OPT-IN cloud escalation decision
/// (cloud-fallback task, 2026-09-07): pure logic — the flag the
/// household sets in Settings AND the provider interpreter's live
/// availability (the same gate `IntentRouter` applies at route time).
/// Kept free of any `AppCoordinator` instance so the matrix is
/// unit-testable (same seam as
/// `AppCoordinator.shouldAutoDownloadAssistantBrain`).
final class CloudFallbackTests: XCTestCase {

    func testFallbackNeverEngagesWhileOptInIsOff() {
        // OFF is the default and the strictly-on-device contract: a
        // configured Gemini key must NOT enter the chain without the
        // explicit opt-in.
        XCTAssertFalse(CloudProvider.cloudFallbackEngages(enabled: false, geminiAvailable: false))
        XCTAssertFalse(CloudProvider.cloudFallbackEngages(enabled: false, geminiAvailable: true))
    }

    func testFallbackEngagesOnlyWhenOptInAndGeminiAreBothLive() {
        // ON + key actually usable → abstentions may escalate.
        XCTAssertTrue(CloudProvider.cloudFallbackEngages(enabled: true, geminiAvailable: true))
        // ON but no usable key → escalation must stay off (the Settings
        // "requires a Gemini API key" caption tells this truth).
        XCTAssertFalse(CloudProvider.cloudFallbackEngages(enabled: true, geminiAvailable: false))
    }

    func testCloudProviderRawValueRoundTrip() {
        // The persisted raw-value round-trip the UserDefaults restore
        // relies on ("cloudProvider" key, default .gemini).
        XCTAssertEqual(CloudProvider.gemini.rawValue, "gemini")
        XCTAssertEqual(CloudProvider(rawValue: "gemini"), .gemini)
        // An unknown stored value (a future provider id written by a
        // newer build, or a corrupt default) restores as nil — the
        // coordinator's init falls back to .gemini rather than wedging.
        XCTAssertNil(CloudProvider(rawValue: "anthropic"))
        XCTAssertNil(CloudProvider(rawValue: ""))
    }
}
