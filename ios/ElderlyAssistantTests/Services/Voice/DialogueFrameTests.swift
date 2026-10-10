import XCTest
@testable import ElderlyAssistant

/// [MULTI-TURN] (2026-10-10, design-l2 §8/§18, C-MTC-01) — the focused
/// `DialogueFrameTests` suite: frame lifecycle (arm stamps the deadline
/// from the injected window, expiry-aware reads, window-busy and
/// no-resolution refusals, re-probe restamping, idempotent resolution)
/// and the template-only probe composer with the label caps.
///
/// Every test uses the manager's injected fake clock — no wall-clock
/// waits, no session machine, no router, no catalog resource load
/// (catalogs are inline JSON Data literals, the §18 pattern).
final class DialogueFrameTests: XCTestCase {

    // MARK: - Fixtures

    /// A mutable fake clock; the manager reads it through its injected
    /// `now` closure.
    private final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ interval: TimeInterval) { now += interval }
    }

    /// The fixed arm-time reading and the injected answer window — a
    /// small value; the manager never owns a literal (design-l2 §27).
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let window: TimeInterval = 30

    private let ne = Locale(identifier: "ne")

    private func makeManager(clock: TestClock) -> DialogueManager {
        DialogueManager(answerWindowSeconds: window, now: { clock.now })
    }

    private func musicCommand(message: String? = "भजन") -> InterpretedCommand {
        InterpretedCommand(action: .music, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: message, callType: nil,
                           requestedApp: nil, confidence: 0.9, reply: "")
    }

    private func musicCandidate(query: String? = "दुर्गा भजन",
                                matchKeys: [String] = ["दुर्गा"]) -> DialogueCandidate {
        DialogueCandidate(id: UUID().uuidString, labelKey: "dialogue.candidate.music",
                          domain: .music, query: query, appID: nil, matchKeys: matchKeys)
    }

    private func slotFillDraft(candidates: [DialogueCandidate]? = nil,
                               defaultQuery: String? = "भजन",
                               activeCommand: InterpretedCommand? = nil) -> DialogueFrame {
        DialogueFrame.slotFill(candidates: candidates ?? [musicCandidate()],
                               defaultQuery: defaultQuery,
                               domain: .music,
                               activeCommand: activeCommand,
                               sourceTranscript: "भजन बजाऊ")
    }

    /// The test catalog: the bhajan group with FIVE options — one more
    /// than `DialogueConfig.maxSlotOptions` — so the cap is observable.
    /// The extra option reuses a real label key so its resolved text is
    /// distinctively assertable.
    private static let fiveOptionCatalogJSON = """
    {
      "version": 1,
      "groups": [
        {
          "id": "bhajan.deity",
          "questionKey": "dialogue.probe.bhajanKind",
          "matchKeys": ["भजन", "bhajan"],
          "options": [
            { "id": "shiva",  "labelKey": "dialogue.option.bhajan.shiva",
              "query": "shiva bhajan",  "aliases": ["शिव", "shiva"] },
            { "id": "durga",  "labelKey": "dialogue.option.bhajan.durga",
              "query": "durga bhajan",  "aliases": ["दुर्गा", "durga"] },
            { "id": "bishnu", "labelKey": "dialogue.option.bhajan.bishnu",
              "query": "bishnu bhajan", "aliases": ["विष्णु", "bishnu"] },
            { "id": "devi",   "labelKey": "dialogue.option.bhajan.devi",
              "query": "devi bhajan",   "aliases": ["देवी", "devi"] },
            { "id": "extra",  "labelKey": "dialogue.candidate.news",
              "query": "gita bhajan",   "aliases": ["गीता"] }
          ]
        }
      ]
    }
    """

    private func fiveOptionCatalog() throws -> DialogueOptionCatalog {
        try DialogueOptionCatalog(data: Data(Self.fiveOptionCatalogJSON.utf8))
    }

    // MARK: - FR-MTC-001 lifecycle

    /// Gherkin 1: arming stamps the deadline from the injected window
    /// and stores one frame; the frame records probe kind, slot and
    /// attempt 1.
    func testArmStampsDeadlineFromTheInjectedWindow() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)
        let command = musicCommand(message: "भजन")
        let draft = slotFillDraft(activeCommand: command)

        try manager.arm(draft)

        let held = try XCTUnwrap(manager.frame, "arming stores exactly one frame")
        XCTAssertEqual(manager.liveFrame?.id, held.id, "the same one frame is live")
        XCTAssertEqual(held.deadline, t0.addingTimeInterval(window),
                       "the deadline is the injected window from the arm-time reading")
        XCTAssertEqual(held.probeKind, .slotFill)
        XCTAssertEqual(held.slot, .musicQuery, "the frame records the missing slot")
        XCTAssertEqual(held.attempts, 1, "arm sets attempt 1")
        XCTAssertEqual(held.activeCommand, command, "the pending command is captured verbatim")
    }

    /// Gherkin 2: an expired frame resolves to no frame on read; the
    /// next utterance is a fresh command — a fresh trigger arms
    /// immediately (the stale frame never blocks).
    func testLiveFrameDropsExpiredOnRead() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)
        try manager.arm(slotFillDraft())
        clock.advance(window + 1)

        XCTAssertNil(manager.liveFrame, "an expired frame resolves to no frame on read")
        XCTAssertNil(manager.frame, "the expired frame is dropped, not retained")

        let fresh = slotFillDraft(defaultQuery: "गीत")
        try manager.arm(fresh)
        XCTAssertEqual(manager.liveFrame?.id, fresh.id,
                       "a fresh trigger arms immediately after expiry")
    }

    /// FR-MTC-013 boundary: the window is half-open — live strictly
    /// before the deadline, expired at exactly the deadline.
    func testDeadlineBoundaryIsHalfOpen() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)
        try manager.arm(slotFillDraft())

        clock.advance(window - 1)
        XCTAssertNotNil(manager.liveFrame, "live strictly before the deadline")

        clock.advance(1) // exactly at the deadline
        XCTAssertNil(manager.liveFrame, "expired at exactly the deadline (now >= deadline)")
    }

    /// Gherkin 3: arming is refused while a window is live; the live
    /// frame and its deadline are untouched.
    func testArmThrowsWindowBusy() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)
        let first = slotFillDraft()
        try manager.arm(first)
        let deadlineBefore = manager.frame?.deadline

        XCTAssertThrowsError(try manager.arm(slotFillDraft(defaultQuery: "गीत"))) { error in
            XCTAssertEqual(error as? DialogueError, .windowBusy,
                           "the arm throws the closed window-busy error")
        }
        XCTAssertEqual(manager.frame?.id, first.id, "the live frame is untouched")
        XCTAssertEqual(manager.frame?.deadline, deadlineBefore, "its deadline is untouched")
    }

    /// Gherkin 4: a draft with neither candidates nor a default is not
    /// armable; no frame is stored.
    func testArmThrowsNoResolution() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)

        let noResolution = DialogueFrame.slotFill(candidates: [],
                                                  defaultQuery: nil,
                                                  domain: .music,
                                                  activeCommand: nil,
                                                  sourceTranscript: "भजन बजाऊ")
        XCTAssertThrowsError(try manager.arm(noResolution)) { error in
            XCTAssertEqual(error as? DialogueError, .noResolution,
                           "the arm throws the closed no-resolution error")
        }
        XCTAssertNil(manager.frame, "no frame is stored")
        XCTAssertNil(manager.liveFrame)

        XCTAssertThrowsError(try manager.arm(
            DialogueFrame.candidateChoice(candidates: [], sourceTranscript: "केही"))) { error in
            XCTAssertEqual(error as? DialogueError, .noResolution)
        }
        XCTAssertNil(manager.liveFrame)
    }

    /// Gherkin 5: a re-probe restamps the deadline from the later clock
    /// reading without changing the captured data (L2-D6).
    func testNoteAttemptRestampsTheDeadline() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)
        try manager.arm(slotFillDraft(activeCommand: musicCommand(message: "भजन")))
        let before = try XCTUnwrap(manager.frame)

        clock.advance(7)
        let attempts = manager.noteAttempt()

        XCTAssertEqual(attempts, 2, "the attempt count increments")
        let after = try XCTUnwrap(manager.frame)
        XCTAssertEqual(after.id, before.id, "one frame identity through a re-probe")
        XCTAssertEqual(after.deadline, clock.now.addingTimeInterval(window),
                       "the deadline restamps from the later reading")
        XCTAssertNotEqual(after.deadline, before.deadline)
        XCTAssertEqual(after.attempts, 2)
        XCTAssertEqual(after.probeKind, before.probeKind)
        XCTAssertEqual(after.slot, before.slot)
        XCTAssertEqual(after.domain, before.domain)
        XCTAssertEqual(after.activeCommand, before.activeCommand)
        XCTAssertEqual(after.candidates, before.candidates, "the captured candidates are unchanged")
        XCTAssertEqual(after.defaultQuery, before.defaultQuery, "the captured query is unchanged")
        XCTAssertEqual(after.sourceTranscript, before.sourceTranscript)
    }

    /// Design-l2 §8: `noteAttempt` on an absent (or expired) frame is a
    /// no-op returning 0.
    func testNoteAttemptWithoutALiveFrameIsANoOpReturningZero() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)
        XCTAssertEqual(manager.noteAttempt(), 0)
        XCTAssertNil(manager.frame)

        try manager.arm(slotFillDraft())
        clock.advance(window) // expired
        XCTAssertEqual(manager.noteAttempt(), 0, "an expired frame is absent")
        XCTAssertNil(manager.frame)
    }

    /// Gherkin 6: resolution clears the held frame for EVERY outcome in
    /// the closed set.
    func testResolveClearsAllFields() throws {
        let outcomes: [DialogueFrameResolution] = [
            .answered(DialogueMerge(value: "durga bhajan", capture: .optionName, source: .catalog)),
            .defaultExecuted,
            .candidateSelected(index: 1),
            .exhausted,
            .cancelled,
            .escaped,
            .bargedIn,
            .timedOut,
            .superseded,
            .emergency
        ]
        for outcome in outcomes {
            let clock = TestClock(t0)
            let manager = makeManager(clock: clock)
            try manager.arm(slotFillDraft())
            let armedID = try XCTUnwrap(manager.frame?.id)

            let resolved = manager.resolve(outcome)

            XCTAssertEqual(resolved?.id, armedID, "the funnel returns the cleared frame: \(outcome)")
            XCTAssertNil(manager.frame, "every outcome clears the held frame: \(outcome)")
            XCTAssertNil(manager.liveFrame)
        }
    }

    /// Gherkin 6, second half: a second resolution of the same frame is
    /// a no-op.
    func testResolveIsIdempotent() throws {
        let clock = TestClock(t0)
        let manager = makeManager(clock: clock)
        try manager.arm(slotFillDraft())

        XCTAssertNotNil(manager.resolve(.cancelled))
        XCTAssertNil(manager.resolve(.cancelled), "a second resolution is a no-op on a cleared frame")
        XCTAssertNil(manager.frame)
    }

    /// The candidate-choice factory records its kind and keeps the
    /// no-execution shape (no domain, no pending command).
    func testCandidateChoiceFactoryRecordsTheFrameShape() {
        let frame = DialogueFrame.candidateChoice(candidates: [musicCandidate()],
                                                  sourceTranscript: "केही बुझिएन")
        XCTAssertEqual(frame.probeKind, .candidateChoice)
        XCTAssertEqual(frame.slot, .musicQuery)
        XCTAssertNil(frame.domain, "a pure candidateChoice frame has no frame domain (B6/B7)")
        XCTAssertNil(frame.activeCommand, "nothing executes unasked (R3)")
        XCTAssertNil(frame.defaultQuery)
    }

    // MARK: - Config knobs (design-l2 §27)

    /// The knobs are constructor values with the design defaults, never
    /// call-site literals.
    func testConfigKnobsPinTheDesignDefaults() {
        XCTAssertEqual(DialogueConfig.maxProbes, 2)
        XCTAssertEqual(DialogueConfig.maxCandidates, 3)
        XCTAssertEqual(DialogueConfig.maxSlotOptions, 4)
    }

    // MARK: - Probe composition (FR-MTC-003 / FR-MTC-016)

    /// Gherkin 7: the question is the group's localized template with
    /// at most the capped labels plus the any-option label — the §8
    /// anchor pinned by string equality.
    func testProbeTextSlotFillUsesGroupTemplateAndCapsOptions() throws {
        let catalog = try fiveOptionCatalog()
        let frame = slotFillDraft(defaultQuery: "भजन")

        let probe = DialogueProbeComposer.probeText(for: frame, catalog: catalog,
                                                    retry: false, locale: ne)

        XCTAssertEqual(probe,
                       "कस्तो भजन? शिव, दुर्गा, विष्णु, देवी, जे पनि बजाऊ … वा आफैँ भन्नुहोस्",
                       "the group's localized template with the capped labels + anyPlay")
        // The fifth option is over `maxSlotOptions` — never spoken.
        XCTAssertFalse(probe.contains("समाचार सुनाउने हो?"),
                       "labels beyond the cap must not reach the probe")
        // The fill is exactly the capped labels + the any-option label,
        // joined ", " (design-l2 §8 join rule).
        let template = L10n.str("dialogue.probe.bhajanKind", locale: ne)
        let fill = ["शिव", "दुर्गा", "विष्णु", "देवी", "जे पनि बजाऊ"].joined(separator: ", ")
        XCTAssertEqual(probe, String(format: template, fill))
    }

    /// Gherkin 7, second half: the retry variant prefixes the localized
    /// retry prefix exactly once, with exactly one space.
    func testProbeTextRetryPrefixesTheRetryKeyExactlyOnce() throws {
        let catalog = try fiveOptionCatalog()
        let frame = slotFillDraft(defaultQuery: "भजन")

        let first = DialogueProbeComposer.probeText(for: frame, catalog: catalog,
                                                    retry: false, locale: ne)
        let retry = DialogueProbeComposer.probeText(for: frame, catalog: catalog,
                                                    retry: true, locale: ne)

        let prefix = L10n.str("dialogue.retry", locale: ne)
        XCTAssertTrue(retry.hasPrefix(prefix + " "),
                      "exactly one space after the retry prefix")
        XCTAssertEqual(retry, prefix + " " + first)
        XCTAssertEqual(retry.components(separatedBy: prefix).count - 1, 1,
                       "the retry prefix appears exactly once")
    }

    /// L2-D12: with no group claiming the pending query — or with no
    /// catalog at all — the probe is the free-text-only musicAny line
    /// and no option labels are named.
    func testProbeTextWithoutAGroupUsesTheMusicAnyLine() throws {
        let catalog = try fiveOptionCatalog()
        let frame = slotFillDraft(defaultQuery: "गीत")

        let noGroup = DialogueProbeComposer.probeText(for: frame, catalog: catalog,
                                                      retry: false, locale: ne)
        XCTAssertEqual(noGroup, "कस्तो संगीत चाहियो? नाम भन्नुहोस्।")

        let noCatalog = DialogueProbeComposer.probeText(for: frame, catalog: nil,
                                                        retry: false, locale: ne)
        XCTAssertEqual(noCatalog, L10n.str("dialogue.probe.musicAny", locale: ne))
        XCTAssertFalse(noCatalog.contains("शिव"), "no option labels in the degraded probe")
        XCTAssertFalse(noCatalog.contains("जे पनि बजाऊ"))
    }

    /// candidateChoice: the honest line plus the did-you-mean probe with
    /// at most `maxCandidates` candidate labels; a candidate label's %@
    /// fills from its own query.
    func testProbeTextCandidateChoiceJoinsTheHonestLineAndCappedCandidates() {
        let music = musicCandidate(query: "दुर्गा भजन", matchKeys: ["दुर्गा"])
        let youtube = DialogueCandidate(id: "y", labelKey: "dialogue.candidate.youtube",
                                        domain: .youtube, query: "bhajan", appID: nil,
                                        matchKeys: ["युट्युब"])
        let news = DialogueCandidate(id: "n", labelKey: "dialogue.candidate.news",
                                     domain: .news, query: nil, appID: nil,
                                     matchKeys: ["समाचार"])
        let app = DialogueCandidate(id: "a", labelKey: "dialogue.candidate.appLaunch",
                                    domain: .appLaunch, query: nil, appID: "camera",
                                    matchKeys: ["क्यामेरा"])
        let frame = DialogueFrame.candidateChoice(candidates: [music, youtube, news, app],
                                                  sourceTranscript: "केही बुझिएन")

        let probe = DialogueProbeComposer.probeText(for: frame, catalog: nil,
                                                    retry: false, locale: ne)

        XCTAssertEqual(probe,
                       "मैले बुझिन। के तपाईंको मतलब दुर्गा भजन बजाउने हो?, युट्युबमा bhajan हेर्ने हो?, समाचार सुनाउने हो? हो?")
        // The fourth candidate is over `maxCandidates` — never spoken.
        XCTAssertFalse(probe.contains("क्यामेरा"))
    }

    /// Design-l2 §8: a candidate label without a query renders its
    /// primary match key — the user's own word, never generated text.
    func testProbeTextCandidateLabelFallsBackToThePrimaryMatchKey() {
        let youtube = DialogueCandidate(id: "y", labelKey: "dialogue.candidate.youtube",
                                        domain: .youtube, query: nil, appID: nil,
                                        matchKeys: ["युट्युब", "भिडियो"])
        let frame = DialogueFrame.candidateChoice(candidates: [youtube],
                                                  sourceTranscript: "केही बुझिएन")

        let probe = DialogueProbeComposer.probeText(for: frame, catalog: nil,
                                                    retry: false, locale: ne)

        XCTAssertTrue(probe.contains("युट्युबमा युट्युब हेर्ने हो?"),
                      "without a query the primary match key renders")
        XCTAssertFalse(probe.contains("भिडियो"), "only the primary match key renders")
    }

    /// NFR-MTC-006: the English locale composes entirely from the
    /// English keys (the expectation is derived through the same L10n
    /// resolution the composer uses, so it pins structure in any host).
    func testProbeTextEnglishSlotFillUsesTheEnglishTemplates() throws {
        let catalog = try fiveOptionCatalog()
        let frame = slotFillDraft(defaultQuery: "bhajan")
        let en = Locale(identifier: "en")

        let probe = DialogueProbeComposer.probeText(for: frame, catalog: catalog,
                                                    retry: false, locale: en)

        let template = L10n.str("dialogue.probe.bhajanKind", locale: en)
        let fill = ["shiva", "durga", "bishnu", "devi",
                    L10n.str("dialogue.option.anyPlay", locale: en)].joined(separator: ", ")
        XCTAssertEqual(probe, String(format: template, fill))
        XCTAssertFalse(probe.contains("शिव"), "no Nepali label leaks into the English probe")
    }
}
