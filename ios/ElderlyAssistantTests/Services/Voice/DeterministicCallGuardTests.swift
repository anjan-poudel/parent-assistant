import XCTest
@testable import ElderlyAssistant

/// [DETERMINISTIC-CALL] (2026-10-11) Regression guards for the call
/// fallback fix — the checks that must fail if the old behavior ever
/// comes back:
///
///  (1) RUNTIME, corpus-driven: every call-shaped golden-corpus entry,
///      routed through a BRAINLESS router (no interpreter available —
///      the exact device condition that used to trigger the refusal),
///      must never produce the old `router.sensitiveBlocked` line or
///      its `command_sensitive_blocked_auth_unavailable` event — the
///      "secure authentication" refusal named an auth gate that has
///      never existed — and must never dead-end silently: every entry
///      ends in a visible card or a spoken honest re-prompt.
///  (2) STATIC: `CommandRouter.swift` must contain no call site of
///      `router.sensitiveBlocked` at all (comment-stripped whole-file
///      scan — the same `FeatureSourceScan` mechanism as the T-140 E6
///      source audit). The catalog key survives for the future auth
///      seam, but nothing in the router may speak it.
///
/// Corpus-driven means the guard grows when the golden corpus grows:
/// a new call phrasing added to `GoldenCorpus.call` is automatically
/// covered here, so the fix can never silently regress while the
/// corpus is the shared vocabulary both the interpreter and the
/// fallback are judged against.
final class DeterministicCallGuardTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    /// Extra fixtures beyond the corpus: the topic-word + call-word
    /// combo the router's own docs name as the shadowing hazard, and a
    /// phone-word utterance that is NOT a call request (must not be
    /// refused as one either).
    private static let extraFixtures = [
        "मौसम बताउनेलाई फोन गर",
        "मेरो फोन कहाँ छ"
    ]

    func testNoCallUtteranceEverSpeaksTheAuthRefusal() async {
        let authLineNe = L10n.str("router.sensitiveBlocked", locale: ne)
        let authLineEn = L10n.str("router.sensitiveBlocked", locale: Locale(identifier: "en-US"))

        var utterances = GoldenCorpus.call.map(\.utterance)
        utterances.append(contentsOf: Self.extraFixtures)

        for utterance in utterances {
            let coordinator = StubCoordinator()
            let bus = MockObservabilityBus()
            let router = CommandRouter(coordinator: coordinator,
                                       observabilityBus: bus,
                                       speaker: RecordingSpeakerGuard(),
                                       interpreter: StubCommandInterpreter(available: false, result: nil))

            _ = router.route(transcript: utterance)

            // The auth-block event was synchronous (the old block was) —
            // assert before any drain so a reintroduced refusal cannot
            // hide behind a queue hop.
            XCTAssertFalse(
                bus.emittedEvents.contains { $0.eventType == "command_sensitive_blocked_auth_unavailable" },
                "\(utterance) must never emit the auth-block event"
            )
            // Drain the main queue: speech may commit on deferred hops —
            // the did-you-mean arm/probe defers by one tick (W4 review
            // F-1 pattern), and the web-search hook's fallback reply
            // lands after its own hop. Poll briefly rather than fixing a
            // yield count.
            for _ in 0..<40 {
                if coordinator.genericReplies.count + coordinator.assistantSpokeTexts.count >= 1 { break }
                await Task.yield()
            }
            for reply in coordinator.genericReplies {
                XCTAssertNotEqual(reply, authLineNe,
                                  "\(utterance) must never card the auth refusal (ne)")
                XCTAssertNotEqual(reply, authLineEn,
                                  "\(utterance) must never card the auth refusal (en)")
            }
            if utterance != "मेरो फोन कहाँ छ" {
                // The no-dead-end invariant applies to every CALL-shaped
                // entry — a call request must always end in a visible
                // card or a spoken honest line. The non-call fixture is
                // exempt: its unrecognised-branch behaviour is the
                // correction-reroute machinery's contract (PRs #162–164),
                // whose harness state this guard does not reproduce; the
                // auth-invariants above still apply to it.
                XCTAssertGreaterThanOrEqual(
                    coordinator.genericReplies.count + coordinator.assistantSpokeTexts.count, 1,
                    "\(utterance) must never dead-end silently — a card or an honest spoken line"
                )
            }
        }
    }

    /// The static half: no code in the router may speak the unwired
    /// auth-gate line. Comments are stripped by `codeText` (the T-140
    /// audit mechanism), so a documentation example cannot false-
    /// positive and a real call site cannot hide.
    func testRouterSourceHasNoSensitiveBlockedCallSite() throws {
        let root = FeatureSourceScan.iosDirectory(file: #filePath)
        let url = root.appendingPathComponent("ElderlyAssistant/Services/Voice/CommandRouter.swift")
        let text = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(text.isEmpty, "could not read CommandRouter.swift")
        XCTAssertFalse(text.contains("router.sensitiveBlocked"),
                       "CommandRouter must contain no call site of router.sensitiveBlocked")
    }
}

/// Minimal speaker for the guard — the router's speak() path needs a
/// `Speaker`; only the coordinator's synchronous `noteAssistantSpoke`
/// recorder is asserted on, so nothing is recorded here.
private final class RecordingSpeakerGuard: Speaker {
    func speak(_ text: String, locale: Locale) async {}
    func cancel() {}
}
