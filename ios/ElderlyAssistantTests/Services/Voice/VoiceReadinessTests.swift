import XCTest
@testable import ElderlyAssistant

/// Unit tests for the voice-readiness machine ([STARTUP-R2], 2026-09-10):
/// the pure fold, the observable tracker's progressive enablement, the
/// Talk-hero gating mapping, and the catalog binding of the honest
/// preparing label (same pattern as StartupBootTests' stage labels).
final class VoiceReadinessTests: XCTestCase {

    // MARK: - Fold

    func testEmptySourcesArePreparing() {
        XCTAssertEqual(VoiceReadinessFold.status(for: []), .preparing)
    }

    func testAllReadyFoldsToReady() {
        XCTAssertEqual(VoiceReadinessFold.status(for: [.ready, .ready]),
                       .ready)
    }

    func testSingleReadySourceIsReady() {
        XCTAssertEqual(VoiceReadinessFold.status(for: [.ready]), .ready)
    }

    func testAnyPreparingKeepsPreparing() {
        XCTAssertEqual(VoiceReadinessFold.status(for: [.ready, .preparing]),
                       .preparing)
    }

    func testAnyFailureDegradesWithReason() {
        XCTAssertEqual(
            VoiceReadinessFold.status(for: [.ready, .failed(reason: "audio_denied")]),
            .degraded(reason: "audio_denied"))
        // A failure wins even when another source is still preparing —
        // the honest reason must surface, never hide behind preparing.
        XCTAssertEqual(
            VoiceReadinessFold.status(for: [.preparing, .failed(reason: "mic_missing")]),
            .degraded(reason: "mic_missing"))
    }

    // MARK: - Tracker

    func testTrackerStartsPreparing() {
        let tracker = VoiceReadiness()
        XCTAssertEqual(tracker.status, .preparing)
    }

    func testTrackerRefoldsOnEverySignal() {
        let tracker = VoiceReadiness()
        tracker.setSignal(id: "pipeline", .preparing)
        XCTAssertEqual(tracker.status, .preparing)

        tracker.setSignal(id: "pipeline", .ready)
        XCTAssertEqual(tracker.status, .ready)

        // A later subsystem attaching while not ready pulls the fold
        // back to preparing — progressive enablement is per-source.
        tracker.setSignal(id: "wakeWord", .preparing)
        XCTAssertEqual(tracker.status, .preparing)

        tracker.setSignal(id: "wakeWord", .ready)
        XCTAssertEqual(tracker.status, .ready)
    }

    func testTrackerFailureDegradesAndLaterReadyRecovers() {
        let tracker = VoiceReadiness()
        tracker.setSignal(id: "pipeline", .failed(reason: "audio_session"))
        XCTAssertEqual(tracker.status, .degraded(reason: "audio_session"))

        // A retry success upgrades degraded → ready (the boot failure
        // path is the Talk hero's tap-to-retry).
        tracker.setSignal(id: "pipeline", .ready)
        XCTAssertEqual(tracker.status, .ready)
    }

    func testTrackerKeepsPerSourceSignalForDiagnostics() {
        let tracker = VoiceReadiness()
        XCTAssertNil(tracker.signal(for: "pipeline"))
        tracker.setSignal(id: "pipeline", .ready)
        XCTAssertEqual(tracker.signal(for: "pipeline"), .ready)
    }

    // MARK: - Talk hero gating (pure mapping)

    func testHeroDisabledWhilePreparing() {
        let gating = TalkHeroGating(readiness: .preparing,
                                    sessionState: .stopped)
        XCTAssertTrue(gating.isDisabled)
        XCTAssertTrue(gating.showsPreparingStatus)
    }

    func testHeroEnabledWhenReady() {
        for state: VoiceSessionState in [.idle, .listening, .transcribing,
                                         .understanding, .speaking,
                                         .error, .stopped] {
            let gating = TalkHeroGating(readiness: .ready, sessionState: state)
            XCTAssertFalse(gating.isDisabled, "state \(state) must stay enabled once ready")
            XCTAssertFalse(gating.showsPreparingStatus)
        }
    }

    func testHeroStaysTappableWhenDegraded() {
        // A failed boot-time pipeline start keeps the hero tappable:
        // its tap IS the retry (recoverVoiceCycle).
        for state: VoiceSessionState in [.error, .stopped] {
            let gating = TalkHeroGating(readiness: .degraded(reason: "mic_denied"),
                                        sessionState: state)
            XCTAssertFalse(gating.isDisabled, "state \(state) must keep the retry escape hatch")
            XCTAssertFalse(gating.showsPreparingStatus)
        }
    }

    func testAwaitingConfirmationStillDisabledWhenReady() {
        let gating = TalkHeroGating(readiness: .ready,
                                    sessionState: .awaitingConfirmation)
        XCTAssertTrue(gating.isDisabled,
                      "the confirmation chips own the UI regardless of readiness")
        XCTAssertFalse(gating.showsPreparingStatus,
                       "the chips branch has no preparing label")
    }

    // MARK: - Catalog binding (honest label in both shipped languages)

    func testPreparingLabelResolvesInBothLanguages() {
        let ne = Locale(identifier: "ne-NP")
        let en = Locale(identifier: "en-US")
        XCTAssertEqual(L10n.str("startup.preparingVoice", locale: ne),
                       "आवाज तयार हुँदैछ…")
        XCTAssertEqual(L10n.str("startup.preparingVoice", locale: en),
                       "Preparing voice…")
    }
}
