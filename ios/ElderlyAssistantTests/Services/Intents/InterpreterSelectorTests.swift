import XCTest
@testable import ElderlyAssistant

/// [LAT-M3] (2026-09-11) The pure selection rule behind cloud-first
/// interpretation (latency plan M3): open-domain utterances interpret
/// through the CLOUD interpreter exactly when a provider + key are
/// configured AND the day's cost budget allows; every other combination
/// is local (llama), with the honest reason attached.
final class InterpreterSelectorTests: XCTestCase {

    func testKeyAndBudgetSelectCloud() {
        XCTAssertEqual(
            InterpreterSelector.select(keyConfigured: true, costAllows: true),
            .cloud
        )
    }

    func testNoKeySelectsLocal() {
        XCTAssertEqual(
            InterpreterSelector.select(keyConfigured: false, costAllows: true),
            .local(reason: .noKey)
        )
    }

    func testBudgetBlockedSelectsLocal() {
        XCTAssertEqual(
            InterpreterSelector.select(keyConfigured: true, costAllows: false),
            .local(reason: .costBlocked)
        )
    }

    func testNoKeyTakesPrecedenceOverBlockedBudget() {
        // The key check runs FIRST: a missing key is reported as
        // `no_key` even on a budget-blocked day (the primary reason,
        // not a side effect).
        XCTAssertEqual(
            InterpreterSelector.select(keyConfigured: false, costAllows: false),
            .local(reason: .noKey)
        )
    }

    func testCloudSelectionReasonAndInterpreterName() {
        let selection = InterpreterSelector.select(keyConfigured: true, costAllows: true)
        XCTAssertEqual(selection.reason, .cloudConfigured)
        XCTAssertEqual(selection.reason.rawValue, "cloud_configured")
        XCTAssertEqual(selection.interpreterName, "gemini")
    }

    func testLocalSelectionReasonAndInterpreterName() {
        let selection = InterpreterSelector.select(keyConfigured: true, costAllows: false)
        XCTAssertEqual(selection.reason, .costBlocked)
        XCTAssertEqual(selection.interpreterName, "llama")
    }

    /// The wire strings logged in the `interpreter_selected` event's
    /// `reason` metadata — pinned so a rename can never silently break
    /// what dashboards filter on.
    func testReasonRawValuesPinned() {
        XCTAssertEqual(InterpreterSelectionReason.cloudConfigured.rawValue, "cloud_configured")
        XCTAssertEqual(InterpreterSelectionReason.costBlocked.rawValue, "cost_blocked")
        XCTAssertEqual(InterpreterSelectionReason.noKey.rawValue, "no_key")
        XCTAssertEqual(InterpreterSelectionReason.cloudFailedFallback.rawValue, "cloud_failed_fallback")
    }
}
