import Foundation

// [MULTI-TURN] (2026-10-10, design-l2 §8, C-MTC-01) — the dialogue-frame
// core: the one-deep frame, its manager, the template-only probe
// composer, the config knobs and the closed error vocabulary.
//
// Responsibility fence: this file never speaks, never executes, never
// loads the catalog, never touches the session state machine and never
// logs. It holds the single live frame; the coordinator owns the
// manager and wires the speech/execution lanes (T-136).
//
// Concurrency (design-l2 §4/§8): main-queue-confined by contract — reads
// travel the router's turn and the coordinator's hooks, writes travel
// the coordinator only. No locks, no actors, no atomics: the pipeline
// serialises one utterance turn at a time, so the frame is never raced.
//
// Log safety (constitution "Privacy & log-safety stance unchanged"): no
// console output and no observability metadata are produced here — the
// coordinator's funnel emits the closed-vocabulary events instead. This
// file is one of the four new files the release log gate covers (T-138).
//
// C-1 (review-l2 F-1). The answer-window default arrives as an injected
// value at construction; this file never addresses
// `VoiceSessionStateMachine.Config.confirmationTimeoutSeconds` at the
// type level (it is an instance `var` at
// `App/VoiceSessionStateMachine.swift:95`). No window literal exists
// here: the 45 s value stays single-source at the machine's instance
// config and the coordinator passes it in (T-136).

/// The two probe kinds (constitution "Probe Kinds & Answer-Capture
/// Contract"; design-l2 §8). `.slotFill` asks for a slot the pending
/// command still needs; `.candidateChoice` offers narrowing
/// interpretations when the utterance was not understood at all.
enum ProbeKind: String, Equatable {
    case slotFill
    case candidateChoice
}

/// The missing-slot vocabulary. Phase 1 has exactly one slot — the
/// music query the pending command needs; Phase 3 adds
/// `.reminderTime`, `.calendarTitle`, `.calendarTime` (design-l2 §8).
enum DialogueSlot: Equatable {
    case musicQuery
}

/// One candidate interpretation offered inside a frame (design-l2 §8,
/// L2-D10/D11).
struct DialogueCandidate: Equatable {
    /// Stable within one frame; index words map to list position. Never
    /// logged with content.
    let id: String
    /// xcstrings key for the spoken label template.
    let labelKey: String
    /// The safe fast-path domain the candidate executes through.
    let domain: KeywordIntentRule.Domain
    /// The user's own extracted words; nil when the domain needs none.
    let query: String?
    /// `.appLaunch` only (L2-D11); mirrors `KeywordIntentRule.Match.appID`.
    let appID: String?
    /// Pick-by-name vocabulary (L2-D10) — the user's own partial words,
    /// fixed rule vocabulary, never spoken.
    let matchKeys: [String]
}

/// The one live dialogue frame (design-l2 §8; FR-MTC-001). Structured,
/// in-memory, one-deep: a new probe cannot start while a frame is
/// active, and every terminal outcome clears it.
struct DialogueFrame {
    /// Process-local identity; telemetry/debugging only.
    let id: UUID
    let probeKind: ProbeKind
    /// The slot the probe asked for (FR-MTC-003 "the frame records the
    /// missing slot").
    let slot: DialogueSlot
    /// The frame's own domain — the barge-in exclusion (B6/B7).
    let domain: KeywordIntentRule.Domain?
    /// Non-nil only when action == .music (L2-D13); the pending command
    /// the answer merges into.
    let activeCommand: InterpretedCommand?
    /// <= `DialogueConfig.maxCandidates`.
    let candidates: [DialogueCandidate]
    /// slotFill: the pending degenerate query the default pick resolves.
    let defaultQuery: String?
    /// The utterance that opened the frame (near-match context).
    let sourceTranscript: String
    /// Probes spoken so far; `DialogueManager.arm` sets 1.
    var attempts: Int
    /// Probe-spoken + the injected answer window. `arm` is the only
    /// writer of the live value (L2-D7).
    var deadline: Date

    /// Half-open window: exactly at the deadline the frame is expired
    /// (design-l2 §8; L1 §14).
    func isExpired(at now: Date) -> Bool { now >= deadline }

    /// The slot-fill factory (design-l2 §8): a resolved music command
    /// whose query was degenerate, awaiting the missing slot. The
    /// deadline placeholder is never live — `DialogueManager.arm`
    /// stamps the real deadline (L2-D7) and forces `attempts` to 1.
    static func slotFill(candidates: [DialogueCandidate],
                         defaultQuery: String?,
                         domain: KeywordIntentRule.Domain,
                         activeCommand: InterpretedCommand?,
                         sourceTranscript: String) -> DialogueFrame {
        DialogueFrame(id: UUID(),
                      probeKind: .slotFill,
                      slot: .musicQuery,
                      domain: domain,
                      activeCommand: activeCommand,
                      candidates: candidates,
                      defaultQuery: defaultQuery,
                      sourceTranscript: sourceTranscript,
                      attempts: 1,
                      deadline: .distantPast)
    }

    /// The did-you-mean factory (design-l2 §8): the utterance was not
    /// understood; the candidates are the narrowing interpretations.
    /// No domain and no pending command — nothing executes unasked
    /// (FR-MTC-004/FR-MTC-010; R3).
    static func candidateChoice(candidates: [DialogueCandidate],
                                sourceTranscript: String) -> DialogueFrame {
        DialogueFrame(id: UUID(),
                      probeKind: .candidateChoice,
                      slot: .musicQuery,
                      domain: nil,
                      activeCommand: nil,
                      candidates: candidates,
                      defaultQuery: nil,
                      sourceTranscript: sourceTranscript,
                      attempts: 1,
                      deadline: .distantPast)
    }
}

// MARK: - Wave-order home: C-MTC-02's merge vocabulary (design-l2 §9)

// [MULTI-TURN] (2026-10-10, T-125 session) — WAVE-ORDER DEVIATION, by
// construction reported. These three types are C-MTC-02's per design-l2
// §7/§9 (their planned home file is `DialogueAnswerPath.swift`), but the
// app module cannot typecheck without them in wave 1:
// `DialogueFrameResolution.answered(DialogueMerge)` is design-pinned
// (§8) and every wave-1 focused suite needs the module to compile
// (verified: the only two build errors on this tree were "Cannot find
// type 'DialogueMerge' in scope" and its Equatable cascade in this
// file). They are declared here verbatim from design-l2 §9 so the plan
// can proceed:
//   - T-131 is a pure CONSUMER: `DialogueAnswerPath.swift` must NOT
//     re-declare these (a redeclaration is a compile error).
//   - The orchestrator may move this block into
//     `DialogueAnswerPath.swift` unchanged if the plan is amended; no
//     other file needs to change.
// Keeping the block in this file (rather than a fifth source file)
// preserves T-138's four-entry FEATURE_ROOTS log-gate wiring, which
// covers `DialogueManager.swift` exactly.
// No case or field here is used by T-125's behaviour beyond the
// resolution payload's shape; nothing is spoken, logged or executed.

/// How the answer was captured (design-l2 §9, C-MTC-02).
enum CaptureForm: String, Equatable {
    /// A spoken position word ("पहिलो") — 1-based position in the probe.
    case indexWord
    /// The option's own name, matched against the group aliases.
    case optionName
    /// A repetition of the pending command ("भजन बजाऊ").
    case repetition
    /// Free text the extractors claimed (music query).
    case freeText
}

/// Where the merged value came from (design-l2 §9, C-MTC-02).
enum MergeSource: String, Equatable {
    case catalog
    case freeText
    case candidate
    case defaultQuery
}

/// The merged slot value an answered frame carries (design-l2 §9,
/// C-MTC-02): the execution payload plus its capture form and source.
struct DialogueMerge: Equatable {
    /// The merged slot value / execution payload.
    let value: String
    let capture: CaptureForm
    let source: MergeSource
}

/// The closed resolution vocabulary — the single funnel every terminal
/// outcome travels (design-l2 §8; the ten-case set of §26/L2-D16). The
/// outcome is the caller's (the coordinator emits it); the manager only
/// clears the frame.
enum DialogueFrameResolution: Equatable {
    case answered(DialogueMerge)
    case defaultExecuted
    case candidateSelected(index: Int)
    case exhausted
    case cancelled
    case escaped
    case bargedIn
    case timedOut
    case superseded
    /// L2-D16 — the emergency side-effect clear, distinct from a
    /// barge-in and from a supersession in telemetry.
    case emergency
}

/// Owns the single live frame: stamps its deadline, counts attempts,
/// clears it through one idempotent funnel (design-l2 §8, FR-MTC-001).
/// Main-queue-confined; the coordinator owns the instance (T-136).
final class DialogueManager {
    /// The one-deep frame state. Readable for the router's turn reads;
    /// writes are the manager's own (and the coordinator's hooks that
    /// call them).
    private(set) var frame: DialogueFrame?

    /// The injected answer window — sourced from the session machine's
    /// instance config by the coordinator. Never a literal, never a
    /// type-level access (C-1; L1 §20).
    private let answerWindowSeconds: TimeInterval

    /// The injected clock; tests pass a fake to exercise the deadline
    /// boundaries without wall-clock waits (L1 §20 invariant).
    private let now: () -> Date

    init(answerWindowSeconds: TimeInterval,
         now: @escaping () -> Date = { Date() }) {
        self.answerWindowSeconds = answerWindowSeconds
        self.now = now
    }

    /// nil when absent OR expired; an expired frame is dropped on read
    /// (the half-open-window guarantee, L1 §14). The same turn then
    /// continues as a fresh command.
    var liveFrame: DialogueFrame? {
        guard let frame else { return nil }
        guard !frame.isExpired(at: now()) else {
            self.frame = nil
            return nil
        }
        return frame
    }

    /// Validates, stamps `deadline = now() + answerWindowSeconds`,
    /// stores, and never speaks (design-l2 §8).
    ///
    /// Throws the closed window-busy error while a live window exists
    /// (expiry-aware, so a stale frame never blocks), and the closed
    /// no-resolution error when the draft has neither candidates nor a
    /// default to resolve. On either throw nothing is stored and a live
    /// frame is untouched.
    func arm(_ draft: DialogueFrame) throws {
        // The state-conflict guard runs first: a live window is never
        // disturbed by draft inspection, and the expiry-aware read
        // drops stale state before the check (design-l2 §8).
        guard liveFrame == nil else { throw DialogueError.windowBusy }
        guard !draft.candidates.isEmpty || draft.defaultQuery != nil else {
            throw DialogueError.noResolution
        }
        var armed = draft
        armed.attempts = 1
        armed.deadline = now().addingTimeInterval(answerWindowSeconds)
        frame = armed
    }

    /// A re-probe: attempts += 1 on the same frame identity and the
    /// deadline restamps from the later clock reading (L2-D6) — every
    /// probe speech gets one full window. The captured data (command,
    /// candidates, query, transcript) is never touched. On an absent or
    /// expired frame this is a no-op returning 0 (design-l2 §8).
    @discardableResult
    func noteAttempt() -> Int {
        guard var live = liveFrame else { return 0 }
        live.attempts += 1
        live.deadline = now().addingTimeInterval(answerWindowSeconds)
        frame = live
        return live.attempts
    }

    /// The single resolution funnel: clears the held frame and returns
    /// it for the caller's telemetry; every outcome in the closed set
    /// travels here. Idempotent — a second resolution of an already
    /// cleared frame is a no-op returning nil, so no state survives a
    /// resolution.
    @discardableResult
    func resolve(_ resolution: DialogueFrameResolution) -> DialogueFrame? {
        guard let resolved = frame else { return nil }
        frame = nil
        return resolved
    }
}

/// Composes probe text from `dialogue.*` xcstrings keys only (design-l2
/// §8, FR-MTC-016, NFR-MTC-009): fixed localizable templates plus
/// catalog labels and the user's own words — the model is never
/// consulted and no string here is model-generated. Testable by string
/// equality; the join rules are exactly one space after the
/// `dialogue.retry` prefix and `", "` between labels.
enum DialogueProbeComposer {
    private enum Key {
        static let retry = "dialogue.retry"
        static let musicAny = "dialogue.probe.musicAny"
        static let anyPlay = "dialogue.option.anyPlay"
        static let understoodNo = "dialogue.understood.no"
        static let didYouMean = "dialogue.didYouMean"
    }

    /// slotFill: the group's question key with `%@` = the capped option
    /// labels plus the any-option label joined `", "`, or
    /// `dialogue.probe.musicAny` when no group claims the pending query
    /// (design-l2 §8; L2-D12 — a free-text-only probe). candidateChoice:
    /// the honest `dialogue.understood.no` line plus `dialogue.didYouMean`
    /// with `%@` = the capped candidate labels joined `", "`. A retry
    /// prefixes `dialogue.retry` and exactly one space.
    static func probeText(for frame: DialogueFrame,
                          catalog: DialogueOptionCatalog?,
                          retry: Bool,
                          locale: Locale) -> String {
        let body: String
        switch frame.probeKind {
        case .slotFill:
            body = slotFillProbe(for: frame, catalog: catalog, locale: locale)
        case .candidateChoice:
            body = candidateChoiceProbe(for: frame, locale: locale)
        }
        guard retry else { return body }
        return L10n.str(Key.retry, locale: locale) + " " + body
    }

    // MARK: - Kind composers

    private static func slotFillProbe(for frame: DialogueFrame,
                                      catalog: DialogueOptionCatalog?,
                                      locale: Locale) -> String {
        guard let query = frame.defaultQuery,
              let group = catalog?.groupForMusicQuery(query) else {
            // No group claims the pending query (or no catalog): the
            // free-text-only probe; the default stays answerable via
            // the anyPlay aliases (L2-D12, §22 S5).
            return L10n.str(Key.musicAny, locale: locale)
        }
        let optionLabels = group.options
            .prefix(DialogueConfig.maxSlotOptions)
            .map { L10n.str($0.labelKey, locale: locale) }
        let labels = (optionLabels + [L10n.str(Key.anyPlay, locale: locale)])
            .joined(separator: ", ")
        return String(format: L10n.str(group.questionKey, locale: locale), labels)
    }

    private static func candidateChoiceProbe(for frame: DialogueFrame,
                                             locale: Locale) -> String {
        let labels = frame.candidates
            .prefix(DialogueConfig.maxCandidates)
            .map { candidateLabel(for: $0, locale: locale) }
            .joined(separator: ", ")
        return L10n.str(Key.understoodNo, locale: locale) + " " +
            String(format: L10n.str(Key.didYouMean, locale: locale), labels)
    }

    /// A candidate's spoken label: its template key resolved in the
    /// locale, with a `%@` filled from the candidate's own query — or,
    /// without one, the primary match key (the user's own partial
    /// words; design-l2 §8 — never generated text).
    private static func candidateLabel(for candidate: DialogueCandidate,
                                       locale: Locale) -> String {
        let template = L10n.str(candidate.labelKey, locale: locale)
        guard template.contains("%@") else { return template }
        let value = candidate.query ?? candidate.matchKeys.first ?? ""
        return String(format: template, value)
    }
}

/// The dialogue config knobs (design-l2 §27): constructor values with
/// the design defaults, never call-site literals.
enum DialogueConfig {
    /// OD-M1 default; counts probes spoken (FR-MTC-007).
    static let maxProbes = 2
    /// FR-MTC-004 — <= 2-3 candidates per probe.
    static let maxCandidates = 3
    /// FR-MTC-003 — <= 3-4 named options per probe.
    static let maxSlotOptions = 4
}

/// The complete error vocabulary of the new dialogue types (design-l2
/// §4/§8). Closed and `Equatable` so tests compare cases directly; no
/// untyped error crosses a component boundary.
enum DialogueError: Error, Equatable {
    /// arm while a window is live (defensive).
    case windowBusy
    /// arm with neither candidates nor a default to resolve.
    case noResolution
    /// catalog resource missing or malformed (thrown by the loader).
    case catalogUnavailable
    /// a merge produced no value (callers treat as invalid).
    case emptyMerge
}
