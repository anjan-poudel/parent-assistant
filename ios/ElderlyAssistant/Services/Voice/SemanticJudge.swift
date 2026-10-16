// [SEMANTIC-JUDGE] correction-revive (2026-10-11) — the Phase 2 contextual
// selection rung (addendum §6.7): a pluggable semantic judge that re-ranks
// the corrector's near-miss candidates by MEANING, not surface form.
//
// WHY A PROTOCOL. The constitution requires engine stacks to stay pluggable
// and selectable — no layer may hard-couple to one brain. The judge runs the
// same discipline as the brain slot: one protocol, implementations behind it,
// each with its own readiness gate and its own activation record. The first
// implementation judges on the resident 4B brain (LlamaSemanticJudge); a
// BERT-class embedder judge is a designed future seam (deferred: the encoder
// publishes no embeddings today and is publication-withheld).
//
// WHAT THE JUDGE SEES. ONLY candidate surfaces and their token positions,
// never anything it could leak: the corrector's own surfaces stay on-device
// (constitution: inference on-device, no cloud), and every egress path is
// count-only. The judge's verdicts re-enter the corrector through the pure
// `STTCorrector.reRank` — vetoes run LAST there, so no judge output can
// bypass the frozen-set refusal.
//
// WHERE IT RUNS. Never on a successful turn. The judge is consulted only on
// the unrecognised path, once per turn, for the token(s) the banded gate
// marked `.judgeEligible` — an owner-pinned rule (clarify only when about to
// fail). It must never load a second model: `isReady` means the judging
// brain is ALREADY resident.

import Foundation

/// One token the banded gate marked judge-eligible: its scalar range in the
/// sanitised transcript and its top candidate readings (2-3 surfaces).
struct JudgeItem: Equatable, Sendable {
    /// Unicode-scalar range, base 0, end-exclusive — the corrector's own
    /// offset unit (`STTCorrectionApplication.originalRange`).
    let tokenRange: Range<Int>
    /// The heard surface (punctuation retained, as `TokenDecision.surface`).
    let surface: String
    /// The candidate readings, best first. Never empty by construction.
    let top: [String]

    init(tokenRange: Range<Int>, surface: String, top: [String]) {
        precondition(!top.isEmpty, "a judge item without readings is not askable")
        self.tokenRange = tokenRange
        self.surface = surface
        self.top = top
    }
}

/// One judged outcome: which reading (if any) the judge picked.
struct JudgeVerdict: Equatable, Sendable {
    let tokenRange: Range<Int>
    /// Index into the item's `top`, or nil when the judge abstains (no
    /// reading fits — the caller falls through to clarification or pass).
    let pick: Int?
    /// 0.0-1.0, the judge's own confidence. On-device only; egress carries
    /// a BUCKET, never the raw value.
    let confidence: Double
}

/// A batch of items one judge call answers — one per turn at most.
struct JudgeBatch: Equatable, Sendable {
    /// The utterance the items were drawn from, sanitised. On-device only;
    /// never logged, never persisted, never placed in an event.
    let source: String
    let items: [JudgeItem]

    init(source: String, items: [JudgeItem]) {
        precondition(!items.isEmpty, "an empty batch is not a judge call")
        self.source = source
        self.items = items
    }
}

/// The contextual-selection rung. Implementations judge against their OWN
/// resident model; a nil pick is an abstention, and an unavailable judge is
/// reported by `isReady == false` — the caller then falls through to the
/// spoken clarification, never to a silent guess.
///
/// Not `Sendable` deliberately: the primary implementation wraps the
/// interpreter class, which is the app's established non-Sendable shape —
/// and the protocol exists to keep engines pluggable, not to promise
/// cross-actor safety the interpreters do not have.
protocol SemanticJudge {
    /// True when the judging model is ALREADY resident and usable. The
    /// contract forbids `judge` from loading a model: readiness is a
    /// statement about the current residency, not a promise to acquire one.
    var isReady: Bool { get }

    /// Judges one batch and reports one verdict per item, in order. The
    /// completion is always called — with `.pick = nil` verdicts when the
    /// model abstains or the call times out (the caller's fallback is the
    /// same either way: clarification or pass).
    func judge(_ batch: JudgeBatch,
               completion: @escaping ([JudgeVerdict]) -> Void)
}

/// The brain capability the judge wraps: a batched candidate call on the
/// interpreter's OWN resident handle. An implementation must NEVER load a
/// model to judge — `isReady`-false paths abstain.
protocol JudgingCommandInterpreter {
    var isAvailable: Bool { get }
    func judgeCandidates(_ batch: JudgeBatch,
                         completion: @escaping ([JudgeVerdict]) -> Void)
}

/// The 4B-rung judge: readiness = the brain is AVAILABLE and the `.brain`
/// slot is CURRENTLY resident in the lifecycle ledger. Both are reads —
/// `judge` never acquires residency, so the [VOICE-OOM] per-turn
/// load/evict pattern is structurally excluded.
struct LlamaSemanticJudge: SemanticJudge {
    private let brain: JudgingCommandInterpreter
    private let lifecycle: ModelLifecycleManager

    init(brain: JudgingCommandInterpreter,
         lifecycle: ModelLifecycleManager = .shared) {
        self.brain = brain
        self.lifecycle = lifecycle
    }

    var isReady: Bool {
        brain.isAvailable && lifecycle.isResident(.brain)
    }

    func judge(_ batch: JudgeBatch,
               completion: @escaping ([JudgeVerdict]) -> Void) {
        guard isReady else {
            completion(batch.items.map {
                JudgeVerdict(tokenRange: $0.tokenRange, pick: nil, confidence: 0)
            })
            return
        }
        brain.judgeCandidates(batch, completion: completion)
    }
}

/// A judge that never runs: the seam's nil stand-in, so call sites never
/// branch on an optional.
struct NoSemanticJudge: SemanticJudge {
    var isReady: Bool { false }
    func judge(_ batch: JudgeBatch,
               completion: @escaping ([JudgeVerdict]) -> Void) {
        completion(batch.items.map {
            JudgeVerdict(tokenRange: $0.tokenRange, pick: nil, confidence: 0)
        })
    }
}
