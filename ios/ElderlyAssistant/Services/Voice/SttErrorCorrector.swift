// [STT-CORRECT] TG-12 addendum §5 — the STT error corrector, Phase 1.
//
// WHAT THIS LAYER IS. A table lookup with a bounded search, a calibrated
// confidence gate and a decision log (§5: "it is not a model"). It runs BEFORE
// `DialectCanonicalizer` (§6.1: `sanitise → correct → canonicalize → tokenize`)
// because correction restores the token the canonical table is keyed on: a
// truncated `गइ` is in no table, and no rule can fire on a token that is not
// spelled the way the rule's variant side is spelled.
//
// WHAT PHASE 1 IS. Corrections apply (above the calibrated threshold, inside
// the vetoes), every token considered produces exactly one decision from a
// CLOSED vocabulary, and the whole thing is observable to a human debugger.
// Nothing downstream branches on the signal (A-14, "passed, never compelled"):
// no band, no cache, no route changes here, and none in `LocalBrainChain` or
// `CommandRouter`.
//
// SAFETY, MADE STRUCTURAL. The corrected text feeds only the intent model. The
// keyword safety net, the emergency matcher and the medication-ack path keep
// reading the ORIGINAL transcript (`IntentTranscriptPair.safetyNetInput`), so
// no rewrite this file produces can gate, suppress or delay a safety match
// (D-1). On top of that a candidate that touches the frozen set is REFUSED
// rather than applied (§5.8), through `CanonicalSafetyFreeze.touches` — the
// same matcher the canonicalizer's whole-file validator uses, so an entry
// cannot be admitted at build time and vetoed at run time by two different
// definitions of "touches".
//
// PHASE 2 SEAMS — NOT IMPLEMENTED, DELIBERATELY. Two consumers are reserved by
// the design and are not built here: (a) an encoder-side confidence discount
// applied at the routing layer after the forward pass, and (b) a structured
// reasoning block on the 4B rung. Both are flag-defaulted-off and additive by
// contract (§6.7). What this file provides for them is the SHAPE they would
// read — `CorrectionResult.decisions` (one decision per token, closed
// vocabulary), `applications`, `thresholdUsed`, `lexiconRevision` — and
// nothing else. C-11 refuses any Phase-2 activation without its own numeric
// record measured from Phase-1 logs, so no code here branches on a Phase-2
// flag, and deleting every Phase-2 mention would leave this file compiling and
// behaving identically (A-13).
//
// THE SIGNAL IS LOGGED, NOT OBEYED. `CorrectionResult` is returned to the
// caller; the caller (the encoder interpreter) emits it and passes the text
// on. There is no return path from a correction into routing, thresholds,
// retries or escalation.

import Foundation

// MARK: - Error classes (§4.3)

/// The measured error classes the pair bank carries. `script_drift` and
/// `numeral_fold` are NOT here: §5.9 refuses transliteration outright and O-5's
/// digit fold is already a builtin canonicalizer stage, so neither class is
/// carried into the bank (`excluded_classes` in the calibration report).
enum STTErrorClass: String, Equatable, Sendable, CaseIterable {
    case truncation
    case prefixExtension = "prefix_extension"
    case phoneticConfusion = "phonetic_confusion"
    case substitutionOther = "substitution_other"
    case insertion
    case deletion
    case merger
    case split

    /// The id prefix the build artifact uses, which is also the fallback when
    /// an entry carries no `errorClass` (the one authored entry does not).
    static func fromEntryID(_ id: String) -> STTErrorClass? {
        let parts = id.split(separator: "-")
        guard parts.count >= 2, parts[0] == "stt" else { return nil }
        switch parts[1] {
        case "trunc": return .truncation
        case "ext":   return .prefixExtension
        case "phon":  return .phoneticConfusion
        case "subst": return .substitutionOther
        case "ins":   return .insertion
        case "del":   return .deletion
        case "merg":  return .merger
        case "split": return .split
        default:      return nil
        }
    }
}

/// How an application's class was obtained (A-9 — "evidence or gap; chosen
/// numbers are labelled chosen", applied to a class rather than a number).
///
/// Not every repair the corrector applies is a row of the pair table, and the
/// difference is a MEASUREMENT, not a preference: §5.3 generates candidates
/// against the corpus lexicon, §5.5.1's calibration swept exactly that space,
/// and at the shipped operating point **0 of the 8 applications the
/// calibration counted carry a top-K pair row**. Requiring one would make the
/// layer inert while its manifest claimed an operating point — so the class of
/// an unrowed application is derived from the SHAPE of the repair (the
/// taxonomy §4.3 classified the corpus with) and labelled here as derived,
/// never presented as a corpus measurement.
enum STTClassOrigin: String, Equatable, Sendable {
    /// The pair is a measured row: class, id and occurrences come from the
    /// extraction run.
    case measured
    /// The pair has no measured row; the class is derived from the repair's
    /// shape and the id names the generating lexicon row.
    case derivedFromShape = "derived_from_shape"
}

// MARK: - Evidence (§5.4)

/// Which signals fired for one candidate, and how strongly.
///
/// Scores are NUMBERS, not content: they may be counted, binned and logged.
/// The candidate's surface may not leave the device, and the event builder
/// below is the only place that decides what does.
struct CorrectionEvidence: Equatable, Sendable {
    let similarity: Double
    let prefixCompletion: Double
    let phoneticKey: Double
    let frameFit: Double
    let pairedKeyword: Double
    /// Where this application's `errorClass` came from (see `STTClassOrigin`).
    /// `var` because it is attached after scoring, which is what produces the
    /// numbers above — the classification is evidence ABOUT the repair, not a
    /// term in it.
    var classOrigin: STTClassOrigin = .measured

    /// The measured part of the score — the part §5.5.1's calibration was
    /// computed over, because the calibration set carries pairs without
    /// contexts. THE GATE COMPARES THIS (`STTCorrector.correct`'s clause 1).
    var surface: Double {
        STTCorrector.weights.similarity * similarity
            + STTCorrector.weights.prefixCompletion * prefixCompletion
            + STTCorrector.weights.phoneticKey * phoneticKey
    }

    /// The context part. Bounded by `frameFit + pairedKeyword` (0.10), which is
    /// strictly below the shipped `marginThreshold` (0.15): a context
    /// agreement can never clear the margin rule on its own, so at least 0.05
    /// of any passing margin is corroboration the text itself carries.
    var context: Double {
        STTCorrector.weights.frameFit * frameFit
            + STTCorrector.weights.pairedKeyword * pairedKeyword
    }

    var total: Double { surface + context }

    /// The enum-case names of the signals that fired — for the log line and
    /// the internal card. Names only, never values.
    var fired: [String] {
        var out: [String] = []
        if prefixCompletion > 0 { out.append("prefix") }
        if similarity > 0 { out.append("similarity") }
        if phoneticKey > 0 { out.append("phonetic_key") }
        if frameFit > 0 { out.append("frame_fit") }
        if pairedKeyword > 0 { out.append("paired_keyword") }
        return out
    }
}

// MARK: - Applications (§5.2)

/// One applied correction. Every application is recorded; there is no silent
/// repair path and no partial application.
struct STTCorrectionApplication: Equatable, Sendable {
    /// The pair table's row id — `<class>-<n>`, NEVER a surface form (§7 C-6:
    /// a row id containing the corrected word leaks the utterance through an
    /// id; `CorrectionLexicon.Issue.identityLeak` refuses such a bank).
    let entryID: String
    let lexiconID: String
    let lexiconRevision: String
    let errorClass: STTErrorClass
    /// Half-open ranges in **Unicode scalar** units, base 0, end-exclusive —
    /// the contract's `slots.offsets.unit`. NOT UTF-16 offsets, NOT `Character`
    /// counts: an offset space that mixes the three is the classic way a
    /// Devanagari span ends up one grapheme off.
    let originalRange: Range<Int>
    let correctedRange: Range<Int>
    let score: Double
    let margin: Double
    let evidence: CorrectionEvidence
}

// MARK: - Decision vocabulary (§5.2)

/// Why a token was corrected or left alone. CLOSED vocabulary — it is the
/// substrate the Phase-2 activation statistics are computed from (A-16), so
/// the `reason` strings are pinned here and Phase-2 code must not invent new
/// ones without a contract change.
enum CorrectionDecision: Equatable, Sendable {
    case corrected(STTCorrectionApplication)
    /// Generation found no candidate the BANK evidences. The candidate space
    /// is the corpus's own clean vocabulary, but a candidate may only be
    /// applied when the pair table carries it: every application must name its
    /// evidence (A-12), so a near-miss with no measured row is a pass-through
    /// rather than an unattributable rewrite.
    case noCandidate
    /// The best candidate's surface score is under the calibrated threshold.
    case belowThreshold(best: Double)
    /// The best candidate is not separated from the runner-up by
    /// `marginThreshold`.
    case ambiguous(margin: Double)
    /// §5.8 — a veto refused the candidate.
    case safetyVeto(rule: SafetyVetoRule)
    /// §5.7 — a token inside a required span may only be a strict prefix
    /// completion, and this one was not.
    case requiredSpan(spanClass: SpanClass)
    /// The lexicon is absent or structurally corrupt: fail closed, pass
    /// through, and say so.
    case degraded
    /// The A/B control arm (or the compile gate is off).
    case disabled

    /// The closed-vocabulary token the log line and the event carry.
    var reason: String {
        switch self {
        case .corrected:      return "corrected"
        case .noCandidate:    return "no_candidate"
        case .belowThreshold: return "below_threshold"
        case .ambiguous:      return "ambiguous"
        case .safetyVeto:     return "safety_veto"
        case .requiredSpan:   return "required_span"
        case .degraded:       return "degraded"
        case .disabled:       return "disabled"
        }
    }

    var isCorrected: Bool {
        if case .corrected = self { return true }
        return false
    }
}

/// §5.8's vetoes, named so a log line says WHICH rule refused the candidate.
enum SafetyVetoRule: String, Equatable, Sendable {
    /// A surface the candidate would write (or read) is in the frozen set.
    case safetySetTouched = "safety_set_touched"
    /// The candidate MANUFACTURES a frozen marker out of a fragment — the
    /// mirror of the canonicalizer's hazard (`नखा` → `नखाए` would create a
    /// medication acknowledgement where the token denied one).
    case completionHazard = "completion_hazard"
    /// §5.8.3 — an entity-position token whose completion is ambiguous.
    case entityAmbiguity = "entity_ambiguity"
}

/// The closed span classes (§5.7).
enum SpanClass: String, Equatable, Sendable, CaseIterable {
    case contact, time, medication, topic, app, appliance, bhajan, none
}

/// One token's outcome, with the surfaces it was about. In memory only: it is
/// what the log line and the internal card read, and it never reaches an event
/// (§6.6.3-4).
struct TokenDecision: Equatable, Sendable {
    let originalRange: Range<Int>
    /// The token as it appeared, punctuation included.
    let surface: String
    let decision: CorrectionDecision
    /// The winning candidate, when generation produced one — the card shows
    /// it, the event carries only its BUCKET and its entry id.
    let best: BestCandidate?
    /// Best minus runner-up, before the gate.
    let margin: Double

    struct BestCandidate: Equatable, Sendable {
        let surface: String
        let entryID: String?
        let errorClass: STTErrorClass?
        let score: Double
    }
}

// MARK: - Result (§5.2)

struct CorrectionResult: Equatable, Sendable {
    /// The model-input transcript. Byte-identical to the input when nothing
    /// applied, and byte-identical when the lexicon is absent or structurally
    /// corrupt (fail-closed — TG-12 D-4 transfers verbatim).
    let corrected: String
    /// Empty iff `corrected == original`.
    let applications: [STTCorrectionApplication]
    /// One entry per token considered, including the pass-throughs.
    let decisions: [TokenDecision]
    let lexiconRevision: String
    /// The threshold actually used, so a log line can name it (A-12).
    let thresholdUsed: Double
    /// True when an absent or structurally corrupt bank forced pass-through.
    let degraded: Bool
    let mode: STTCorrector.Mode
    /// The input, so the result can state its own identity claim.
    let original: String

    var isIdentity: Bool { corrected == original }

    /// The card's readout, or nil when there is nothing to say (no tokens).
    var readout: CorrectionReadout? { CorrectionReadout(result: self) }

    /// §6.6.4 — the egressing counterpart, COUNT-ONLY (A-16): no surface form,
    /// no raw score, no transcript. Ratios are BINNED, pairs are row ids, and
    /// every key here must be in `LogSanitiser.allowedKeys` or it is dropped on
    /// the way out (which is the intended failure mode, and the lists are
    /// pinned by tests so a new key cannot be added silently).
    var observabilityMetadata: [String: String] {
        var metadata: [String: String] = [
            "correction_mode": mode.rawValue,
            "correction_lexicon_revision": lexiconRevision,
            "correction_tokens_considered": String(decisions.count),
            "correction_applied_count": String(applications.count),
            "correction_threshold_bucket": Self.bucket(thresholdUsed),
            "correction_state": {
                if degraded { return "degraded" }
                if mode == .off { return "disabled" }
                if mode == .shadow { return "shadow" }
                return applications.isEmpty ? "passed" : "applied"
            }()
        ]
        var reasons: [String: Int] = [:]
        for decision in decisions {
            reasons[decision.decision.reason, default: 0] += 1
        }
        metadata["correction_reasons"] = reasons.keys.sorted()
            .map { "\($0):\(reasons[$0] ?? 0)" }
            .joined(separator: ",")
        if let veto = decisions.compactMap({ decision -> String? in
            if case .safetyVeto(let rule) = decision.decision { return rule.rawValue }
            return nil
        }).first {
            metadata["correction_veto"] = veto
        }
        // Entry ids and classes: the layer's own identities, never the words
        // they rewrite. `lex-<n>` is the generating lexicon row's ordinal and
        // carries no surface form by construction (§7 C-6).
        if !applications.isEmpty {
            metadata["correction_entry_ids"] = applications.map(\.entryID)
                .sorted().joined(separator: ",")
            var classes: [String: Int] = [:]
            var origins: [String: Int] = [:]
            for application in applications {
                classes[application.errorClass.rawValue, default: 0] += 1
                origins[application.evidence.classOrigin.rawValue, default: 0] += 1
            }
            metadata["correction_classes"] = classes.keys.sorted()
                .map { "\($0):\(classes[$0] ?? 0)" }
                .joined(separator: ",")
            // A-9 in telemetry: measured classes and shape-derived ones are
            // counted apart, so a Phase-2 activation statistic can never
            // silently mix an inference into a measurement.
            metadata["correction_class_origins"] = origins.keys.sorted()
                .map { "\($0):\(origins[$0] ?? 0)" }
                .joined(separator: ",")
            metadata["correction_best_bucket"] = Self.bucket(
                applications.map(\.score).max() ?? 0)
            metadata["correction_margin_bucket"] = Self.bucket(
                applications.map(\.margin).min() ?? 0)
        }
        return metadata
    }

    /// §6.6.2 — one line per considered token. ON-DEVICE DEBUG OUTPUT: the
    /// surfaces are the user's own words, shown to the person holding the
    /// device. This array is never persisted, never written to
    /// `IntentLogStore`, and never placed in an event.
    var logLines: [String] {
        decisions.map { decision in
            let token = decision.surface
            switch decision.decision {
            case .corrected(let application):
                let to = decision.best?.surface ?? "?"
                let origin = application.evidence.classOrigin == .measured
                    ? "" : "+"     // `+` marks a shape-derived class (A-9)
                return "[STT-CORRECT] corrected \(token)→\(to) "
                    + "(conf \(Self.score(application.score)), "
                    + "margin \(Self.score(application.margin)), "
                    + "class \(application.errorClass.rawValue)\(origin), "
                    + "entry \(application.entryID), lex \(lexiconRevision))"
            case .noCandidate:
                return "[STT-CORRECT] no correction (no candidate) — \(token)"
            case .belowThreshold(let best):
                let target = decision.best.map { "\(token)→\($0.surface)" } ?? token
                return "[STT-CORRECT] no correction (below threshold, best "
                    + "\(target) conf \(Self.score(best)) < "
                    + "\(Self.score(thresholdUsed)), lex \(lexiconRevision))"
            case .ambiguous(let margin):
                return "[STT-CORRECT] no correction (ambiguous, margin "
                    + "\(Self.score(margin)) < "
                    + "\(Self.score(STTCorrector.defaultMarginThreshold))) — \(token)"
            case .requiredSpan(let spanClass):
                return "[STT-CORRECT] no correction (required span "
                    + "\(spanClass.rawValue), not a prefix completion) — \(token)"
            case .safetyVeto(let rule):
                return "[STT-CORRECT] no correction (safety veto: "
                    + "\(rule.rawValue)) — \(token)"
            case .degraded:
                return "[STT-CORRECT] no correction (degraded lexicon "
                    + "\(lexiconRevision) — no usable bank)"
            case .disabled:
                return "[STT-CORRECT] no correction (disabled) — \(token)"
            }
        }
    }

    /// Two decimals, the card's and the log line's shared formatting.
    static func score(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// §6.6.4 — a raw score in telemetry is a fingerprint of an utterance
    /// shape, so only the bucket leaves the device.
    ///
    /// The separator is `~`, NOT `-`, and that is load-bearing. MEASURED: with a
    /// hyphen, `LogSanitiser`'s phone-number guard (`\+?\d[\d\s\-().]{6,}\d` —
    /// six or more digits joined by `.`/`-`/space) matches "0.80-0.85" and
    /// replaces it with `[redacted]`, so every bucket in the `turn_correction`
    /// payload — the one number the event carries, and the number Phase 2's
    /// activation read is supposed to read — arrived empty. A tilde is not in
    /// the guard's separator class, so `0.80~0.85` survives the egress boundary
    /// verbatim while reading as the range it is.
    ///
    /// (The guard is not weakened for this: it is defence in depth behind the
    /// key allow-list, and a value that must reach the log is the value's
    /// problem, not the guard's.)
    static func bucket(_ value: Double) -> String {
        let step = 0.05
        let lower = (value / step).rounded(.down) * step
        return String(format: "%.2f~%.2f", lower, lower + step)
    }
}

// MARK: - Card readout (§6.6.3)

/// The "Last correction" line's data. Mirrors `TurnTimingBreakdown`'s shape:
/// rows of label + value, in memory on the coordinator, LAST TURN ONLY, never
/// persisted, never logged, gone with the process.
struct CorrectionReadout: Equatable, Sendable {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let rows: [Row]

    var isEmpty: Bool { rows.isEmpty }

    init?(result: CorrectionResult) {
        guard !result.decisions.isEmpty else { return nil }
        var rows: [Row] = []
        if let application = result.applications.first {
            let pair = result.decisions.first { $0.decision.isCorrected }
            rows.append(Row(label: "corrected",
                            value: "\(pair?.surface ?? "?")→"
                                + "\(pair?.best?.surface ?? "?")"))
            if result.applications.count > 1 {
                rows.append(Row(label: "applied",
                                value: "\(result.applications.count) tokens"))
            }
            rows.append(Row(label: "conf",
                            value: "\(CorrectionResult.score(application.score))"
                                + "  τ "
                                + "\(CorrectionResult.score(result.thresholdUsed))"))
            rows.append(Row(label: "class",
                            value: "\(application.errorClass.rawValue)  "
                                + "\(application.entryID)"))
            self.rows = rows
            return
        }
        switch result.decisions.first(where: { !$0.decision.isCorrected })?.decision {
        case .disabled:
            rows.append(Row(label: "no correction", value: "disabled"))
        case .degraded:
            rows.append(Row(label: "no correction", value: "degraded bank"))
        case .belowThreshold(let best):
            rows.append(Row(label: "no correction", value: "below threshold"))
            if let candidate = result.decisions.compactMap(\.best)
                .max(by: { $0.score < $1.score }) {
                rows.append(Row(label: "best",
                                value: "\(candidate.surface)  "
                                    + CorrectionResult.score(candidate.score)
                                    + " < "
                                    + CorrectionResult.score(result.thresholdUsed)))
            } else {
                rows.append(Row(label: "best", value: CorrectionResult.score(best)))
            }
        case .ambiguous(let margin):
            rows.append(Row(label: "no correction", value: "ambiguous"))
            rows.append(Row(label: "margin",
                            value: CorrectionResult.score(margin) + " < "
                                + CorrectionResult.score(
                                    STTCorrector.defaultMarginThreshold)))
        case .safetyVeto(let rule):
            rows.append(Row(label: "no correction", value: "safety veto"))
            rows.append(Row(label: "rule", value: rule.rawValue))
        case .requiredSpan(let spanClass):
            rows.append(Row(label: "no correction",
                            value: "required span: \(spanClass.rawValue)"))
        case .noCandidate, .none:
            rows.append(Row(label: "no correction", value: "no candidate"))
        case .corrected:
            break   // unreachable: handled above
        }
        rows.append(Row(label: "tokens", value: "\(result.decisions.count) seen"))
        self.rows = rows
    }
}

// MARK: - Lexicon

/// The corrector's data: the measured pair entries, the completion lexicon,
/// the entity banks, the three-level paired-keyword prior and the CALIBRATED
/// threshold — all loaded as data from the shipped banks (A-12). Nothing here
/// is a Swift literal except the fail-closed fallback, so a re-fit ships by
/// dropping in a new JSON file and nothing else.
struct CorrectionLexicon: Sendable {

    static let tableID = "canonical-stt-reductions"
    static let phoneticTableID = "phonetic-key"
    static let resourceSubdirectory = VariantTableSet.resourceSubdirectory

    // MARK: Types

    struct Entry: Equatable, Sendable {
        let id: String
        let variant: String
        let canonical: String
        let errorClass: STTErrorClass
        let occurrences: Int
    }

    struct Candidate: Equatable, Sendable {
        let token: String
        let occurrences: Int
        let entityClass: String?
    }

    struct Scoring: Equatable, Sendable {
        var levenshteinBound = 2
        var lengthWindow = 2
        var maxPrefixSlack = 4
        var prefixPenaltyStep = 0.25
        var maxCandidates = 8
        var marginThreshold = 0.15
    }

    /// §5.5.1's manifest block, read from the bank.
    struct Calibration: Equatable, Sendable {
        let correctThresholdDefault: Double
        let kneeThreshold: Double?
        let precisionAtDefault: Double?
        let recallAtDefault: Double?
        let precisionFloor: Double
        let appliedAtDefault: Int?
        let bindingConstraint: String
        let calibratedFallback: Double
        let lowerBound: Double
        let upperBound: Double
        let stale: Bool
        let runRevision: String
        let corpusRevision: String?

        /// The card's selectable range, in numeric order. A card that could
        /// slide BELOW the calibrated floor would let a debugger move the
        /// operating point past what the evidence supports (§5.5.1 step 5,
        /// C-9d), so the range is the bank's, not a UI constant.
        var range: ClosedRange<Double> {
            guard lowerBound < upperBound else { return Calibration.failClosedRange }
            return lowerBound...upperBound
        }

        var isUsable: Bool {
            lowerBound < upperBound
                && correctThresholdDefault >= lowerBound
                && correctThresholdDefault <= upperBound
        }

        /// The inert end: no achievable surface score reaches the weight sum
        /// (the largest term needs a candidate equal to the token, which is
        /// never a candidate), so a corrector that cannot prove its threshold
        /// corrects nothing. §5.5.1 step 6's `calibratedFallback`.
        static let failClosedThreshold = 1.0
        static let failClosedRange: ClosedRange<Double> = 1.0...1.0
    }

    /// §4.6's phonetic key over SCALARS. Read from the bank's `resolvedKey`
    /// block — never re-derived from the fold entries at run time: three
    /// scalars are claimed by two groups each and the resolution is a
    /// MEASUREMENT (the fold with the higher count wins), so re-deriving it
    /// here would be a second implementation of a measurement, and any
    /// disagreement would silently change every score the calibration fitted.
    struct PhoneticKey: Sendable {
        let unify: [Unicode.Scalar: Unicode.Scalar]
        let elide: Set<Unicode.Scalar>
        let conflictCount: Int

        /// One pass, one lookup per scalar — NOT a fixpoint. `र` folds to `ल`
        /// and `ल` folds to `न`, and the fitted key is `key(र) = ल`, because
        /// that is what the fold table says and what the calibration measured.
        func key(of token: String) -> [Unicode.Scalar] {
            key(ofScalars: Array(token.unicodeScalars))
        }

        func key(ofScalars scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(scalars.count)
            for scalar in scalars {
                if elide.contains(scalar) { continue }
                out.append(unify[scalar] ?? scalar)
            }
            return out
        }
    }

    // MARK: Contents

    let entries: [Entry]
    let lexicon: [Candidate]
    let entities: [String: [String]]
    let calibration: Calibration
    let weights: STTCorrector.Weights
    let scoring: Scoring
    let phonetic: PhoneticKey
    /// The landing table's `generation.status` and the bank's run id, so a log
    /// line names exactly which data produced a decision (A-12).
    let tableRevision: String
    let revision: String

    /// §5.6's integrity rules, split by what they refuse — a distinction that
    /// is itself fail-closed. A WHOLE-BANK issue means the data cannot be
    /// trusted at all and the corrector degrades: nothing applies, every token
    /// passes through untouched. An ENTRY issue refuses one row and leaves the
    /// rest of the bank usable, which is the safe direction (a refused row can
    /// only remove an application) and the only direction that keeps one bad
    /// row from silencing a layer over a thousand good ones.
    enum Issue: String, Equatable, Sendable {
        // Whole bank.
        case unsupportedFormatVersion
        case emptyEntries
        case calibrationStale
        case thresholdRangeInvalid
        case phoneticTableUnusable
        case foldWithoutSupport
        case unsupportedGroupCarriesFolds
        case resolvedKeyFoldsUnknownScalar
        case resolvedKeyMissingFold
        /// §5.8.1 — an entry mapping onto or away from the frozen set refuses
        /// the WHOLE file, the addendum's own rule (`safetySetTouched`). It is
        /// the one entry-level finding that is not a skip: a shipped lexicon
        /// that tries to rewrite a denial or a distress phrase is not a lexicon
        /// with one bad row, it is a lexicon whose authoring filter failed.
        case safetySetTouched
        // Entry. Refused, counted, and reported — never silently dropped.
        case emptySurface
        case noisyEqualsCorrected
        case evidenceMissing
        case evidenceContradictsRun
        case unknownErrorClass
        case identityLeak
    }

    /// One row the loader refused, with the rule that refused it. Carried so
    /// the refusals are observable (`CorrectionResult` reports the count) —
    /// A-9's "evidence or gap" applies to the DATA too, not only to numbers.
    struct Skipped: Equatable, Sendable {
        let id: String
        let issue: Issue
    }

    /// Whole-bank refusals. Empty ⇒ the bank may be consulted.
    let issues: [Issue]

    /// Rows refused individually. Does NOT affect usability.
    let skipped: [Skipped]

    var isUsable: Bool { issues.isEmpty }

    // MARK: Indexes (built once, at wiring time — §5.3's "no scan on the hot path")

    private let prefixIndex: [String: [String]]
    private let lengthBuckets: [Int: [String]]
    private let keyIndex: [[Unicode.Scalar]: [String]]
    private let keyOf: [String: [Unicode.Scalar]]
    private let entryByPair: [String: Entry]
    private let candidateOccurrences: [String: Int]
    /// `lex-<n>` — the opaque ordinal of a lexicon row, used to attribute a
    /// correction whose pair the measured table does not carry. Stable for a
    /// given bank revision (the array is shipped in a deterministic order), and
    /// an id that contains no surface form by construction.
    private let candidateOrdinal: [String: Int]
    private let entityTags: [String: String]
    private let l1: [String: [String: Double]]
    private let l2: [String: [String: Double]]
    private let l3: [String: [String: Double]]

    // MARK: Loading

    /// The landing table plus its bank, decoded and validated. Nil when a
    /// resource is absent or undecodable — the caller degrades.
    static func load(bundle: Bundle = .main) -> CorrectionLexicon? {
        guard let tableURL = resourceURL(name: tableID, bundle: bundle),
              let phoneticURL = resourceURL(name: phoneticTableID, bundle: bundle),
              let tableData = try? Data(contentsOf: tableURL),
              let phoneticData = try? Data(contentsOf: phoneticURL) else { return nil }
        return decode(tableData: tableData, phoneticData: phoneticData)
    }

    /// Process-wide cache for the interpreter hot path (a `static let` is
    /// lazily initialised once, thread-safely), mirroring
    /// `VariantTableSet.bundled` and `DialectLexicon.bundledCached`.
    static let bundled: CorrectionLexicon? = load()

    private static func resourceURL(name: String, bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "json",
                   subdirectory: resourceSubdirectory)
            ?? bundle.url(forResource: name, withExtension: "json")
    }

    static func decode(tableData: Data, phoneticData: Data) -> CorrectionLexicon? {
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode(RawTable.self, from: tableData),
              let rawPhonetic = try? decoder.decode(RawPhoneticTable.self,
                                                    from: phoneticData) else {
            return nil
        }
        return build(raw: raw, rawPhonetic: rawPhonetic)
    }

    // MARK: Build + validate

    private static func build(raw: RawTable,
                              rawPhonetic: RawPhoneticTable) -> CorrectionLexicon {
        var issues: [Issue] = []
        let bank = raw.correctionBank

        if raw.formatVersion != 1 || bank.formatVersion != 1
            || rawPhonetic.formatVersion != 1 {
            issues.append(.unsupportedFormatVersion)
        }
        if raw.entries.isEmpty { issues.append(.emptyEntries) }

        // --- entries (§5.6's rules, one by one) ---------------------------
        var entries: [Entry] = []
        var skipped: [Skipped] = []
        for entry in raw.entries {
            func skip(_ issue: Issue) { skipped.append(Skipped(id: entry.id, issue: issue)) }
            let variant = entry.variant
            let canonical = entry.canonical
            if variant.isEmpty || canonical.isEmpty {
                skip(.emptySurface)
                continue
            }
            if variant == canonical {
                skip(.noisyEqualsCorrected)
                continue
            }
            guard let evidence = entry.evidence, let source = evidence.source else {
                skip(.evidenceMissing)
                continue
            }
            if source == "corpus" {
                // A corpus claim without a count and a revision is not a
                // measurement (E-2): fail closed rather than trust it.
                if (evidence.occurrences ?? 0) < 1
                    || (evidence.corpusRevision ?? "").isEmpty {
                    skip(.evidenceContradictsRun)
                    continue
                }
            }
            let errorClass: STTErrorClass?
            if let rawClass = evidence.errorClass {
                errorClass = STTErrorClass(rawValue: rawClass)
                if errorClass == nil {
                    skip(.unknownErrorClass)
                    continue
                }
            } else {
                // The authored entry predates the class column; its id and its
                // (स / ह) substitution say `substitution_other`.
                errorClass = STTErrorClass.fromEntryID(entry.id) ?? .substitutionOther
            }
            // C-6: an id is opaque. A Devanagari scalar in an id is a surface
            // form in an id, which is how a "count-only" event would leak one.
            if entry.id.unicodeScalars
                .contains(where: { (0x0900...0x097F).contains($0.value) }) {
                skip(.identityLeak)
                continue
            }
            // §5.8.1 — defense in depth behind the build-time filter (the
            // report lists 59 refused pairs). An entry that reaches this file
            // some other way, e.g. hand-added, is refused here rather than
            // shipped and then vetoed at run time by the same matcher. This is
            // the one entry-level finding that refuses the WHOLE bank.
            if CanonicalSafetyFreeze.touches(variant: variant, canonical: canonical) {
                issues.append(.safetySetTouched)
                continue
            }
            // The pair is keyed on the LEXICON KEY of both sides — punctuation
            // stripped — because that is the space the runtime looks a token up
            // in: a transcript token `'खाना` and a row written for `खाना` are
            // the same repair (`§4.2`: punctuation is retained through
            // alignment and stripped from keys). A row whose two keys are equal
            // is therefore a no-op under that lookup (`सम्झाउनुहोस्। →
            // सम्झाउनुहोस्` changes no token the corrector can address) and is
            // refused here rather than shipped as an entry that can never fire
            // — the same rule as `noisyEqualsCorrected`, one normalisation
            // later, and the reason the check is not redundant.
            let variantKey = STTCorrector.lexiconKey(of: variant)
            let canonicalKey = STTCorrector.lexiconKey(of: canonical)
            if variantKey.isEmpty || canonicalKey.isEmpty {
                skip(.emptySurface)
                continue
            }
            if variantKey == canonicalKey {
                skip(.noisyEqualsCorrected)
                continue
            }
            entries.append(Entry(id: entry.id, variant: variantKey,
                                 canonical: canonicalKey,
                                 errorClass: errorClass ?? .substitutionOther,
                                 occurrences: evidence.occurrences ?? 0))
        }

        // --- calibration ---------------------------------------------------
        let rawCalibration = bank.calibration
        let calibration = Calibration(
            correctThresholdDefault: rawCalibration.correctThresholdDefault,
            kneeThreshold: rawCalibration.kneeThreshold,
            precisionAtDefault: rawCalibration.precisionAtDefault,
            recallAtDefault: rawCalibration.recallAtDefault,
            precisionFloor: rawCalibration.precisionFloor,
            appliedAtDefault: rawCalibration.appliedAtDefault,
            bindingConstraint: rawCalibration.bindingConstraint,
            calibratedFallback: rawCalibration.calibratedFallback,
            lowerBound: rawCalibration.lowerBound,
            upperBound: rawCalibration.upperBound,
            stale: rawCalibration.stale,
            runRevision: rawCalibration.runRevision,
            corpusRevision: rawCalibration.corpusRevision)
        if calibration.stale { issues.append(.calibrationStale) }
        if !calibration.isUsable { issues.append(.thresholdRangeInvalid) }

        // --- phonetic key ---------------------------------------------------
        // The resolved block is consumed AS DATA (see `PhoneticKey`): the
        // conflict resolution is a measurement and is never re-derived here.
        var unify: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (from, to) in rawPhonetic.resolvedKey.unify {
            guard let scalar = STTCorrector.singleScalar(from), let representative = STTCorrector.singleScalar(to)
            else {
                issues.append(.resolvedKeyFoldsUnknownScalar)
                continue
            }
            unify[scalar] = representative
        }
        let phonetic = PhoneticKey(
            unify: unify,
            elide: Set(rawPhonetic.resolvedKey.elide.compactMap(STTCorrector.singleScalar)),
            conflictCount: rawPhonetic.resolvedKey.conflicts.count)
        if phonetic.unify.isEmpty || rawPhonetic.entries.isEmpty {
            issues.append(.phoneticTableUnusable)
        }
        // A-3, preserved as a runtime check: a group with no measured support
        // contributes NO fold, and an admitted fold carries a count.
        var foldScalars: Set<Unicode.Scalar> = []
        for fold in rawPhonetic.entries {
            if rawPhonetic.unsupportedGroups.contains(fold.group) {
                issues.append(.unsupportedGroupCarriesFolds)
            }
            if (fold.evidence?.occurrences ?? 0) < 1 {
                issues.append(.foldWithoutSupport)
            }
            if fold.scalars.isEmpty || !["unify", "elide"].contains(fold.foldKind) {
                issues.append(.phoneticTableUnusable)
            }
            foldScalars.formUnion(fold.scalars.compactMap(STTCorrector.singleScalar))
            // The other direction, checked per ENTRY rather than per scalar:
            // an entry whose scalars are all representatives carries no fold
            // the runtime applies, so the two files have drifted apart. Per
            // scalar would be wrong — an entry's representative side is
            // legitimately unfolded (`स` in `श → स`), and the fold's DIRECTION
            // is not positional in the shipped data (some entries list the
            // folded scalar first, some second), which is exactly why the
            // resolved block is the runtime's only authority.
            let carriesFoldedScalar = fold.scalars.contains { value in
                guard let scalar = STTCorrector.singleScalar(value) else { return false }
                return phonetic.unify[scalar] != nil || phonetic.elide.contains(scalar)
            }
            if !carriesFoldedScalar { issues.append(.resolvedKeyMissingFold) }
        }
        // Every fold the runtime APPLIES must be a fold the evidence carries.
        // A resolved fold whose scalar no entry mentions has no support — and
        // an unsupported fold is precisely how the halanta elision went missing
        // once (see the run-id note in the calibration report).
        for scalar in Set(phonetic.unify.keys).union(phonetic.elide)
        where !foldScalars.contains(scalar) {
            issues.append(.resolvedKeyFoldsUnknownScalar)
        }

        // --- indexes --------------------------------------------------------
        var prefixIndex: [String: [String]] = [:]
        var lengthBuckets: [Int: [String]] = [:]
        var keyIndex: [[Unicode.Scalar]: [String]] = [:]
        var keyOf: [String: [Unicode.Scalar]] = [:]
        for candidate in bank.lexicon {
            let token = candidate.token
            guard !token.isEmpty else { continue }
            lengthBuckets[token.unicodeScalars.count, default: []].append(token)
            for stop in 1...max(1, token.unicodeScalars.count) {
                let prefix = String(String.UnicodeScalarView(
                    token.unicodeScalars.prefix(stop)))
                prefixIndex[prefix, default: []].append(token)
            }
            let key = phonetic.key(of: token)
            keyOf[token] = key
            keyIndex[key, default: []].append(token)
        }
        var entryByPair: [String: Entry] = [:]
        for entry in entries {
            entryByPair["\(entry.variant)\u{1}\(entry.canonical)"] = entry
        }
        // The candidate's own corpus frequency, kept beside the pair rows: an
        // application the pair table does not carry is still attributed, and
        // its evidence is the shipped count of the token it corrected TO.
        var candidateOccurrences: [String: Int] = [:]
        var candidateOrdinal: [String: Int] = [:]
        for (offset, candidate) in bank.lexicon.enumerated()
        where !candidate.token.isEmpty {
            candidateOccurrences[candidate.token] = candidate.occurrences
            candidateOrdinal[candidate.token] = offset + 1
        }
        var entityTags: [String: String] = [:]
        for (name, values) in bank.entities {
            for value in values {
                let key = STTCorrector.lexiconKey(of: value)
                if !key.isEmpty { entityTags[key] = name }
            }
        }
        for candidate in bank.lexicon {
            if let tag = candidate.entityClass {
                entityTags[STTCorrector.lexiconKey(of: candidate.token)] = tag
            }
        }

        // --- priors (§5.4's three levels) -----------------------------------
        var l1: [String: [String: Double]] = [:]
        for row in bank.priors.l1 {
            l1[row.w, default: [:]][row.c] = row.score
        }
        var l2: [String: [String: Double]] = [:]
        for frame in bank.priors.l2 {
            var table: [String: Double] = [:]
            for candidate in frame.candidates { table[candidate.c] = candidate.score }
            l2[frame.frame] = table
        }
        var l3: [String: [String: Double]] = [:]
        for cue in bank.priors.l3 {
            var table = l3[cue.cue] ?? [:]
            for candidate in cue.candidates { table[candidate.c] = candidate.score }
            l3[cue.cue] = table
        }

        return CorrectionLexicon(
            entries: entries, lexicon: bank.lexicon, entities: bank.entities,
            calibration: calibration,
            weights: STTCorrector.Weights(
                similarity: bank.weights.similarity ?? STTCorrector.weights.similarity,
                prefixCompletion: bank.weights.prefixCompletion
                    ?? STTCorrector.weights.prefixCompletion,
                phoneticKey: bank.weights.phoneticKey
                    ?? STTCorrector.weights.phoneticKey,
                frameFit: bank.weights.frameFit ?? STTCorrector.weights.frameFit,
                pairedKeyword: bank.weights.pairedKeyword
                    ?? STTCorrector.weights.pairedKeyword),
            scoring: Scoring(levenshteinBound: bank.scoring.levenshteinBound,
                             lengthWindow: bank.scoring.lengthWindow,
                             maxPrefixSlack: bank.scoring.maxPrefixSlack,
                             prefixPenaltyStep: bank.scoring.prefixPenaltyStep,
                             maxCandidates: bank.scoring.maxCandidates,
                             marginThreshold: bank.scoring.marginThreshold),
            phonetic: phonetic,
            tableRevision: raw.generation?.status ?? "unknown",
            revision: bank.runRevision,
            issues: issues,
            skipped: skipped,
            prefixIndex: prefixIndex, lengthBuckets: lengthBuckets,
            keyIndex: keyIndex, keyOf: keyOf, entryByPair: entryByPair,
            candidateOccurrences: candidateOccurrences,
            candidateOrdinal: candidateOrdinal,
            entityTags: entityTags, l1: l1, l2: l2, l3: l3)
    }

    // MARK: Queries

    /// The bank row for a (token, candidate) pair, or nil when the pair is not
    /// one of the measured rows the table carries.
    ///
    /// NOT a precondition for applying — see `attribution(forToken:candidate:)`
    /// and the note there. `nil` means "the class must be derived", not "this
    /// repair is unauthorised".
    func entry(forToken token: String, candidate: String) -> Entry? {
        entryByPair["\(token)\u{1}\(candidate)"]
    }

    /// What an application is attributed to, and where its class came from.
    struct Attribution: Equatable, Sendable {
        let entryID: String
        let errorClass: STTErrorClass
        let classOrigin: STTClassOrigin
        /// The measured frequency behind it: the pair row's occurrences when
        /// the pair is measured, else the corrected token's own corpus count.
        let occurrences: Int
    }

    /// §5.2 requires every application to name an `entryID`, and §5.3's
    /// generation is over the LEXICON — the two together are why this method
    /// exists rather than a `guard let entry = … else { continue }`.
    ///
    /// The measured pair row wins whenever the corpus evidences that exact
    /// repair. When it does not, the application is still real and still
    /// attributed: the id names the generating lexicon row (`lex-<n>`, opaque
    /// — §7 C-6, no surface form in an id) and the class is DERIVED from the
    /// shape of the repair by the taxonomy §4.3 classified the corpus with,
    /// labelled `derivedFromShape` so a reader never mistakes it for a
    /// measurement (A-9). The alternative — refusing every unrowed pair —
    /// makes the layer inert: measured on the calibration set the shipped
    /// threshold acts on 8 pairs and NONE of the 8 is a top-K row, so a
    /// corrector that demanded one would ship a manifest describing
    /// applications it can never make.
    func attribution(forToken token: String, candidate: String) -> Attribution {
        if let row = entry(forToken: token, candidate: candidate) {
            return Attribution(entryID: row.id, errorClass: row.errorClass,
                               classOrigin: .measured,
                               occurrences: row.occurrences)
        }
        let occurrences = candidateOccurrences[candidate] ?? 0
        return Attribution(
            entryID: "lex-\(candidateOrdinal[candidate] ?? 0)",
            errorClass: Self.derivedClass(variant: token, canonical: candidate,
                                          keysEqual: phonetic.key(of: token)
                                              == phonetic.key(of: candidate)),
            classOrigin: .derivedFromShape,
            occurrences: occurrences)
    }

    /// The repair's SHAPE as an error class — §4.3's own taxonomy, which is
    /// how the extractor classified the corpus in the first place (a class is
    /// a statement about which side carries the extra or changed material):
    ///
    /// - the corrected form extends the noisy one → the noisy was **truncated**;
    /// - the noisy form extends the corrected one → the noisy **extended** it
    ///   (`सम्झाउनुहोस्। → सम्झाउनुहोस्`, the class name §4.3 uses);
    /// - equal length: a **phonetic confusion** when the two share a
    ///   phonetic key (the fold table says the difference is a fold the
    ///   measurement recorded) and a **substitution** otherwise;
    /// - otherwise the longer side says which way material moved.
    static func derivedClass(variant: String, canonical: String,
                             keysEqual: Bool) -> STTErrorClass {
        let from = variant.unicodeScalars.count
        let to = canonical.unicodeScalars.count
        if hasScalarPrefix(canonical, variant), to > from { return .truncation }
        if hasScalarPrefix(variant, canonical), from > to { return .prefixExtension }
        if from == to { return keysEqual ? .phoneticConfusion : .substitutionOther }
        return from < to ? .deletion : .insertion
    }

    /// The entity class a token sits in, when it is an entity or an entity's
    /// part (`बिहान ८ बजे` contributes `बिहान`), for §5.8.3's veto.
    func entityClass(of token: String) -> String? {
        entityTags[STTCorrector.lexiconKey(of: token)]
    }

    func phoneticKey(of token: String) -> [Unicode.Scalar] {
        keyOf[token] ?? phonetic.key(of: token)
    }

    /// The cue token this transcript is built around, when it carries one —
    /// L3's key. The design's L3 is `P(c | intent)`; the corrector runs BEFORE
    /// any intent exists, so the corpus's own measured cue distribution plays
    /// that role (the deviation is recorded in the builder's `build_priors`).
    func cueKey(in tokens: [String]) -> String? {
        for token in tokens {
            let key = STTCorrector.lexiconKey(of: token)
            if l3[key] != nil { return key }
        }
        return nil
    }

    /// §5.4's three-level backoff for one candidate.
    ///
    /// L1 exact pair MI over adjacent content words, L2 frame affinity over the
    /// CLASS of the neighbour, L3 cue-token affinity. Each contributes
    /// independently and the strongest wins; a pair with no corpus support
    /// contributes ZERO rather than falling through to a number that was
    /// measured for a different question.
    func priorScore(forCandidate candidate: String,
                    neighbours: [String],
                    cue: String?) -> (frameFit: Double, paired: Double) {
        var paired = 0.0
        for neighbour in neighbours {
            let forward = l1[neighbour]?[candidate] ?? 0
            let backward = l1[candidate]?[neighbour] ?? 0
            paired = max(paired, max(forward, backward))
        }
        var frameFit = 0.0
        for neighbour in neighbours {
            guard let frame = frameClass(of: neighbour),
                  let table = l2[frame] else { continue }
            frameFit = max(frameFit, table[candidate] ?? 0)
        }
        if paired == 0, frameFit == 0, let cue, let table = l3[cue] {
            paired = table[candidate] ?? 0
        }
        return (frameFit, paired)
    }

    /// The frame class of a neighbour: an entity bank tag when the token is an
    /// entity, else `content` — the class the priors were fitted under.
    func frameClass(of token: String) -> String? {
        let key = STTCorrector.lexiconKey(of: token)
        guard !key.isEmpty else { return nil }
        if let tag = entityTags[key] { return tag }
        return l2["content"] != nil ? "content" : nil
    }

    /// §5.3's three generators, unioned, deduplicated and bounded at
    /// generation (C-5).
    ///
    /// The tiers are ordered by the strength of their evidence — prefix
    /// completion (an exact anchor), then bounded edit distance (increasing
    /// cost), then the phonetic key — and the pool is capped at three tiers'
    /// worth of `maxCandidates`, so a pathological token cannot hand the
    /// scorer an unbounded list. Ordering is by Unicode scalar, matching the
    /// order the fit used (`sorted` over Python code points), so the same token
    /// produces the same pool in the same order on two hosts (NFR-029).
    func candidates(for token: String) -> [String] {
        let scalars = Array(token.unicodeScalars)
        let tokenLength = scalars.count
        guard tokenLength > 0 else { return [] }
        let window = scoring.lengthWindow
        let slack = scoring.maxPrefixSlack
        let cap = 3 * scoring.maxCandidates
        let allowed = min(scoring.levenshteinBound, tokenLength / 3)

        var pool: [String] = []
        var seen: Set<String> = []

        var prefixTier: [(Int, String)] = []
        for candidate in prefixIndex[token] ?? [] {
            let added = candidate.unicodeScalars.count - tokenLength
            if candidate != token, added >= 1, added <= slack {
                prefixTier.append((added, candidate))
            }
        }
        prefixTier.sort { $0.0 == $1.0 ? Self.scalarLess($0.1, $1.1) : $0.0 < $1.0 }
        for (_, candidate) in prefixTier where !seen.contains(candidate) {
            seen.insert(candidate)
            pool.append(candidate)
        }

        if allowed > 0 {
            var editTier: [(Int, String)] = []
            for length in max(1, tokenLength - window)...(tokenLength + window) {
                for candidate in lengthBuckets[length] ?? [] {
                    guard candidate != token, !seen.contains(candidate) else { continue }
                    let other = Array(candidate.unicodeScalars)
                    guard STTCorrector.withinBound(scalars, other, allowed) else {
                        continue
                    }
                    editTier.append((STTCorrector.editDistance(scalars, other),
                                     candidate))
                }
            }
            editTier.sort { $0.0 == $1.0 ? Self.scalarLess($0.1, $1.1) : $0.0 < $1.0 }
            for (_, candidate) in editTier where !seen.contains(candidate) {
                seen.insert(candidate)
                pool.append(candidate)
            }
        }

        var keyTier: [String] = []
        let key = phonetic.key(of: token)
        for candidate in keyIndex[key] ?? [] {
            if candidate != token,
               abs(candidate.unicodeScalars.count - tokenLength) <= window {
                keyTier.append(candidate)
            }
        }
        keyTier.sort(by: Self.scalarLess)
        for candidate in keyTier where !seen.contains(candidate) {
            seen.insert(candidate)
            pool.append(candidate)
        }

        return Array(pool.prefix(cap))
    }

    /// Scalars, not Characters — `String.hasPrefix` is the wrong relation here.
    ///
    /// MEASURED DEFECT, FIXED HERE: `String.hasPrefix` compares EXTENDED
    /// GRAPHEME CLUSTERS, and for Devanagari a virama binds to the consonant it
    /// follows (`स` + `्` is one Character "स्"), so `"होस्".hasPrefix("होस")`
    /// is FALSE while `len("होस्") - len("होस")` is 1. Every halanta completion
    /// — which is the whole shipped applied set, all 8 of §5.5.1's applications
    /// — read as "not a prefix": `prefixEvidence` was 0, the score fell to
    /// 0.41-0.47, and the runtime applied NOTHING at a 0.8125 threshold whose
    /// manifest claimed 8 applications. The fit is Python, where `startswith`
    /// and `len` are code-point based; this is the scalar-prefix test that
    /// matches it (the same relation `candidates(for:)` builds its prefix tier
    /// from, so generation and scoring cannot disagree about what a completion
    /// is).
    static func hasScalarPrefix(_ candidate: String, _ prefix: String) -> Bool {
        var candidateScalars = candidate.unicodeScalars.makeIterator()
        for scalar in prefix.unicodeScalars {
            guard let next = candidateScalars.next(), next == scalar else {
                return false
            }
        }
        return true
    }

    /// Code-point ordering, the order the calibration's `sorted()` produced.
    /// Swift's `String` `<` is canonical-equivalence ordering, which is not the
    /// same relation for a script with combining marks; the pool order is part
    /// of what was measured, so the comparison is pinned to scalars.
    static func scalarLess(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.unicodeScalars.makeIterator()
        var right = rhs.unicodeScalars.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let l?, let r?):
                if l.value != r.value { return l.value < r.value }
            }
        }
    }
}

// MARK: - Raw bank decoding

private struct RawTable: Decodable {
    let formatVersion: Int
    let generation: RawGeneration?
    let entries: [RawEntry]
    let correctionBank: RawBank

    struct RawGeneration: Decodable {
        let status: String?
    }
}

private struct RawEntry: Decodable {
    let id: String
    let kind: String?
    let variant: String
    let canonical: String
    let evidence: RawEvidence?
}

private struct RawEvidence: Decodable {
    let source: String?
    let errorClass: String?
    let occurrences: Int?
    let corpusRevision: String?
    let runRevision: String?
}

private struct RawPhoneticTable: Decodable {
    let formatVersion: Int
    let tableID: String
    let resolvedKey: RawResolvedKey
    let entries: [RawPhoneticEntry]
    let unsupportedGroups: [String]

    struct RawResolvedKey: Decodable {
        let unify: [String: String]
        let elide: [String]
        let conflicts: [RawConflict]

        struct RawConflict: Decodable {
            let scalar: String
        }
    }
}

private struct RawPhoneticEntry: Decodable {
    let id: String
    let group: String
    let foldKind: String
    let scalars: [String]
    let evidence: RawEvidence?
}

private struct RawBank: Decodable {
    let formatVersion: Int
    let toolRevision: String?
    let runRevision: String
    let corpusRevision: String?
    let weights: RawWeights
    let scoring: RawScoring
    let calibration: RawCalibration
    let lexicon: [CorrectionLexicon.Candidate]
    let entities: [String: [String]]
    let priors: RawPriors
}

private struct RawWeights: Decodable {
    let similarity: Double?
    let prefixCompletion: Double?
    let phoneticKey: Double?
    let frameFit: Double?
    let pairedKeyword: Double?
}

private struct RawScoring: Decodable {
    let levenshteinBound: Int
    let lengthWindow: Int
    let maxPrefixSlack: Int
    let prefixPenaltyStep: Double
    let maxCandidates: Int
    let marginThreshold: Double
}

private struct RawCalibration: Decodable {
    let correctThresholdDefault: Double
    let kneeThreshold: Double?
    let precisionAtDefault: Double?
    let recallAtDefault: Double?
    let precisionFloor: Double
    let appliedAtDefault: Int?
    let bindingConstraint: String
    let calibratedFallback: Double
    let lowerBound: Double
    let upperBound: Double
    let stale: Bool
    let runRevision: String
    let corpusRevision: String?
}

private struct RawPriors: Decodable {
    struct Row: Decodable {
        let w: String
        let c: String
        let count: Int
        let score: Double
    }
    struct Candidate: Decodable {
        let c: String
        let count: Int
        let score: Double
    }
    struct Frame: Decodable {
        let frame: String
        let candidates: [Candidate]
    }
    struct Cue: Decodable {
        let cue: String
        let intent: String?
        let candidates: [Candidate]
    }
    let l1: [Row]
    let l2: [Frame]
    let l3: [Cue]
}

extension CorrectionLexicon.Candidate: Decodable {
    private enum CodingKeys: String, CodingKey {
        case token, occurrences, entityClass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        self.occurrences = try container.decode(Int.self, forKey: .occurrences)
        self.entityClass = try container.decodeIfPresent(String.self,
                                                         forKey: .entityClass)
    }
}

// MARK: - The corrector

enum STTCorrector {

    /// §5.4's authored weights, mirrored here ONLY as the fail-closed default:
    /// the bank's own weights win whenever they decode, because the data is the
    /// authority (a re-fit that moves a weight ships as a file).
    struct Weights: Equatable, Sendable {
        var similarity: Double
        var prefixCompletion: Double
        var phoneticKey: Double
        var frameFit: Double
        var pairedKeyword: Double

        static let authored = Weights(similarity: 0.35, prefixCompletion: 0.40,
                                      phoneticKey: 0.15, frameFit: 0.05,
                                      pairedKeyword: 0.05)

        /// The context terms are a deliberately small share of the total: they
        /// are measured over the corpus's co-occurrence statistics, which is
        /// weaker evidence about one utterance than the text itself.
        var contextBonus: Double { frameFit + pairedKeyword }
    }

    static let weights = Weights.authored
    static let defaultMarginThreshold = 0.15

    /// §6.4's arms.
    enum Mode: String, Equatable, Sendable, CaseIterable {
        /// Generate, score, decide and log — apply NOTHING. The counterfactual
        /// arm: what would have been corrected on a turn whose transcript was
        /// left alone.
        case shadow
        /// The control arm.
        case off
        /// The arm that rewrites `modelInput`. Selected deliberately, never by
        /// default (see `Policy.runtime`).
        case apply
    }

    /// §5.2's policy. Every value is data or a documented constant; the
    /// threshold is CALIBRATED and loaded from the manifest (A-12).
    struct Policy: Equatable, Sendable {
        var mode: Mode = .off
        /// The calibrated operating point. The default value here is the
        /// FAIL-CLOSED end (`Calibration.failClosedThreshold`), not the shipped
        /// default: a corrector whose bank failed to load must correct nothing
        /// rather than fall back to some livelier number.
        var correctThreshold: Double =
            CorrectionLexicon.Calibration.failClosedThreshold
        var marginThreshold: Double = STTCorrector.defaultMarginThreshold
        var thresholdRange: ClosedRange<Double> =
            CorrectionLexicon.Calibration.failClosedRange
        var maxCandidates: Int = 8
        /// §5.7 — inside a required span, only a strict prefix completion.
        var prefixOnlyInRequiredSpans: Bool = true

        /// The shipped runtime policy. INERT UNLESS BOTH GATES ARE ON: the
        /// compile-time `INTENT_ENCODER` condition (read through the SHIPPED
        /// gate function `IntentEncoderWiring.isServingEnabled`, so "both gates
        /// are required" cannot drift between the encoder's switch, the
        /// canonicalizer's and this one) and the persisted mode, which reads an
        /// ABSENT key as OFF (house pattern: `CanonicalizerPreferences`,
        /// `IntentEncoderPreferences`, `DialectBiasSettings`). A release build
        /// therefore cannot rewrite model input by accident, and a gated build
        /// still ships the control arm until someone opts in — including the
        /// `.shadow` arm, which is why the mode is a three-way setting rather
        /// than a boolean.
        ///
        /// When the bank is missing or unusable the threshold is the inert end
        /// and the range collapses to it, so the card cannot offer a setting
        /// the data does not support.
        static func runtime(defaults: UserDefaults = .standard,
                            isCompiledIn: Bool = IntentEncoderFeature.isEnabled,
                            isModeOn: Mode? = nil,
                            lexicon: CorrectionLexicon? = CorrectionLexicon.bundled)
            -> Policy {
            let settings = STTCorrectionSettings(defaults: defaults, lexicon: lexicon)
            let mode = isModeOn ?? settings.mode
            let serving = IntentEncoderWiring.isServingEnabled(
                isCompiledIn: isCompiledIn, isToggleOn: mode != .off)
            var policy = Policy()
            policy.mode = serving ? mode : .off
            if let lexicon, lexicon.isUsable {
                policy.correctThreshold = settings.threshold
                    ?? lexicon.calibration.correctThresholdDefault
                policy.thresholdRange = lexicon.calibration.range
                policy.marginThreshold = lexicon.scoring.marginThreshold
                policy.maxCandidates = lexicon.scoring.maxCandidates
            }
            return policy
        }
    }

    /// What the caller knows about the turn: the required spans (§5.7, A-8)
    /// and, when a caller has them, the neighbouring content words. The
    /// corrector derives neighbours and the cue itself when this is empty —
    /// which is the shipped path, because the corrector runs before anything
    /// has parsed the utterance.
    struct CorrectionContext: Equatable, Sendable {
        var requiredSpans: [Range<Int>: SpanClass] = [:]
        var neighbours: [String] = []

        static let none = CorrectionContext()
    }

    // MARK: Entry point

    /// Applies the layer to one transcript. Pure, synchronous, non-throwing, no
    /// I/O (A-1).
    ///
    /// A nil or unusable lexicon is a VALUE — `degraded: true`, every token
    /// passed through untouched — never a throw and never a trap. `mode` is the
    /// answer to "may this rewrite model input at all"; the threshold is the
    /// answer to "is THIS candidate good enough".
    static func correct(_ transcript: String,
                        lexicon: CorrectionLexicon?,
                        context: CorrectionContext = .none,
                        policy: Policy = Policy()) -> CorrectionResult {
        let tokens = tokenize(transcript)

        func result(_ corrected: String,
                    _ applications: [STTCorrectionApplication],
                    _ decisions: [TokenDecision],
                    degraded: Bool) -> CorrectionResult {
            CorrectionResult(corrected: corrected, applications: applications,
                             decisions: decisions,
                             lexiconRevision: lexicon?.revision ?? "absent",
                             thresholdUsed: policy.correctThreshold,
                             degraded: degraded, mode: policy.mode,
                             original: transcript)
        }

        guard policy.mode != .off else {
            return result(transcript, [], tokens.map {
                TokenDecision(originalRange: $0.range, surface: $0.text,
                              decision: .disabled, best: nil, margin: 0)
            }, degraded: false)
        }
        guard let lexicon, lexicon.isUsable else {
            return result(transcript, [], tokens.map {
                TokenDecision(originalRange: $0.range, surface: $0.text,
                              decision: .degraded, best: nil, margin: 0)
            }, degraded: true)
        }

        var decisions: [TokenDecision] = []
        decisions.reserveCapacity(tokens.count)
        var applications: [STTCorrectionApplication] = []
        var replacements: [String] = []
        replacements.reserveCapacity(tokens.count)
        for token in tokens {
            let decision = decide(token: token, in: transcript, lexicon: lexicon,
                                  context: context, policy: policy)
            decisions.append(decision)
            switch decision.decision {
            case .corrected(let application):
                applications.append(application)
                replacements.append(decision.best?.surface ?? token.text)
            default:
                replacements.append(token.text)
            }
        }

        // `.shadow` decides and logs and applies NOTHING (§6.4): the decisions
        // are the counterfactual and the text is untouched, so a turn can be
        // compared against what it would have been.
        guard policy.mode == .apply else {
            return result(transcript, [], decisions, degraded: false)
        }
        let corrected = splice(transcript, tokens: tokens,
                               replacements: replacements)
        return result(corrected, applications, decisions, degraded: false)
    }

    // MARK: One token

    private static func decide(token: Token, in transcript: String,
                               lexicon: CorrectionLexicon,
                               context: CorrectionContext,
                               policy: Policy) -> TokenDecision {
        let core = lexiconKey(of: token.text)
        func pass(_ decision: CorrectionDecision,
                  _ best: TokenDecision.BestCandidate?,
                  _ margin: Double) -> TokenDecision {
            TokenDecision(originalRange: token.range, surface: token.text,
                          decision: decision, best: best, margin: margin)
        }
        guard !core.isEmpty else { return pass(.noCandidate, nil, 0) }

        let pool = lexicon.candidates(for: core)
        guard !pool.isEmpty else { return pass(.noCandidate, nil, 0) }

        let allTokens = context.neighbours.isEmpty ? tokenize(transcript) : []
        let neighbours = context.neighbours.isEmpty
            ? neighbouringTokens(of: token, in: allTokens) : context.neighbours
        let cue = context.neighbours.isEmpty
            ? lexicon.cueKey(in: allTokens.map(\.text)) : nil

        // EVERY generated candidate ranks. The apply rule is §5.5's gate, not
        // pair-table membership: §5.3 generates against the corpus lexicon and
        // §5.5.1's calibration swept exactly that space (measured: the shipped
        // threshold acts on 8 pairs, 0 of which are top-K rows — filtering by
        // the table here would make the layer inert while its manifest claimed
        // an operating point). The pair row is consulted at ATTRIBUTION time
        // instead (`attribution(forToken:candidate:)`), where a measured class
        // beats a derived one.
        var ranked: [(attribution: CorrectionLexicon.Attribution,
                      evidence: CorrectionEvidence, candidate: String)] = []
        for candidate in pool {
            let attribution = lexicon.attribution(forToken: core, candidate: candidate)
            let prior = lexicon.priorScore(forCandidate: candidate,
                                           neighbours: neighbours, cue: cue)
            var evidence = score(token: core, candidate: candidate,
                                 lexicon: lexicon, frameFit: prior.frameFit,
                                 paired: prior.paired)
            evidence.classOrigin = attribution.classOrigin
            ranked.append((attribution, evidence, candidate))
        }
        guard !ranked.isEmpty else { return pass(.noCandidate, nil, 0) }
        ranked.sort {
            $0.evidence.total == $1.evidence.total
                ? CorrectionLexicon.scalarLess($0.candidate, $1.candidate)
                : $0.evidence.total > $1.evidence.total
        }
        let best = ranked[0]
        let runnerUp = ranked.count > 1 ? ranked[1].evidence.total : 0
        let margin = best.evidence.total - runnerUp
        let bestRef = TokenDecision.BestCandidate(
            surface: best.candidate,
            entryID: best.attribution.entryID,
            errorClass: best.attribution.errorClass,
            score: best.evidence.total)

        // §5.5 clause 1 — the floor, compared on the SURFACE evidence.
        // RECORDED DEVIATION, stated where it can be checked: τ was fitted on
        // surface scores because the calibration set carries pairs without
        // contexts (§5.5.1), so letting the bounded context bonus (≤ 0.10) move
        // a candidate across τ would move the operating point the calibration
        // cannot see. The deviation is conservative in the safe direction — a
        // candidate whose surface evidence is under τ never applies, whatever
        // its context says — and when no context fires (the shipped state, and
        // the only state the calibrator could score) the total order IS the
        // surface order and the applied set is exactly the calibrated set.
        guard best.evidence.surface >= policy.correctThreshold else {
            return pass(.belowThreshold(best: best.evidence.surface), bestRef, margin)
        }
        // §5.5 clause 2 — the margin over the runner-up for the SAME token.
        guard margin >= policy.marginThreshold else {
            return pass(.ambiguous(margin: margin), bestRef, margin)
        }
        // §5.7 — a required span takes a strict prefix completion or nothing.
        if policy.prefixOnlyInRequiredSpans,
           let spanClass = context.requiredSpans[token.range] {
            let added = best.candidate.unicodeScalars.count - core.unicodeScalars.count
            guard added >= 1, CorrectionLexicon.hasScalarPrefix(best.candidate, core) else {
                return pass(.requiredSpan(spanClass: spanClass), bestRef, margin)
            }
        }
        // §5.8 — the vetoes, last, so nothing reaches application without
        // passing them. (Order is not load-bearing for safety — a veto can
        // only refuse — but it is load-bearing for the log: the rule that
        // fired is named, not inferred.)
        if let rule = veto(token: core, candidate: best.candidate,
                           lexicon: lexicon, pool: pool) {
            return pass(.safetyVeto(rule: rule), bestRef, margin)
        }

        let application = STTCorrectionApplication(
            entryID: best.attribution.entryID,
            lexiconID: CorrectionLexicon.tableID,
            lexiconRevision: lexicon.revision,
            errorClass: best.attribution.errorClass,
            originalRange: token.range,
            correctedRange: token.range,
            score: best.evidence.total,
            margin: margin,
            evidence: best.evidence)
        return pass(.corrected(application), bestRef, margin)
    }

    // MARK: Scoring (§5.4)

    static func score(token: String, candidate: String,
                      lexicon: CorrectionLexicon,
                      frameFit: Double, paired: Double) -> CorrectionEvidence {
        let a = Array(token.unicodeScalars)
        let b = Array(candidate.unicodeScalars)
        let span = max(a.count, b.count)
        let similarity = span == 0 ? 0 : 1 - Double(editDistance(a, b)) / Double(span)
        let added = b.count - a.count
        var prefixEvidence = 0.0
        // Scalar prefix, not `hasPrefix` — see `hasScalarPrefix`. This is the
        // term the whole calibrated operating point rests on (w₂ = 0.40), so a
        // grapheme-cluster reading of "prefix" silently deletes the layer.
        if CorrectionLexicon.hasScalarPrefix(candidate, token), added >= 1,
           added <= lexicon.scoring.maxPrefixSlack {
            prefixEvidence = max(0, 1 - lexicon.scoring.prefixPenaltyStep
                                    * Double(added - 1))
        }
        let keyHit = lexicon.phonetic.key(ofScalars: a)
            == lexicon.phonetic.key(ofScalars: b) ? 1.0 : 0.0
        return CorrectionEvidence(similarity: similarity,
                                  prefixCompletion: prefixEvidence,
                                  phoneticKey: keyHit, frameFit: frameFit,
                                  pairedKeyword: paired)
    }

    // MARK: Vetoes (§5.8)

    /// Returns the rule that refused the candidate, or nil when it may apply.
    static func veto(token: String, candidate: String,
                     lexicon: CorrectionLexicon,
                     pool: [String]) -> SafetyVetoRule? {
        // (1) The inherited frozen set, and (2) the completion hazard, through
        // ONE matcher. `touches` is the canonicalizer's shipped whole-file
        // validator, reused deliberately: the authoring filter, this runtime
        // veto and the canonicalizer cannot drift into three definitions of
        // "touches the safety set".
        if CanonicalSafetyFreeze.touches(variant: token, canonical: candidate) {
            let tokenAloneIsClean = !CanonicalSafetyFreeze.touches(variant: token,
                                                                   canonical: token)
            return tokenAloneIsClean ? .completionHazard : .safetySetTouched
        }
        // (3) The entity veto — contacts and medications only, the two banks
        // whose wrong resolution dials or doses the wrong thing. A prefix
        // completion with exactly one continuation and no second entry sharing
        // the key; anything else is ambiguity, and ambiguity here is refused
        // rather than resolved (§5.8.3).
        if let entity = lexicon.entityClass(of: token),
           entity == "contact" || entity == "medication" {
            let added = candidate.unicodeScalars.count - token.unicodeScalars.count
            guard CorrectionLexicon.hasScalarPrefix(candidate, token), added >= 1 else {
                return .entityAmbiguity
            }
            let key = lexicon.phonetic.key(of: token)
            let sharing = pool.filter { lexicon.phonetic.key(of: $0) == key }
            guard sharing.count <= 1 else { return .entityAmbiguity }
        }
        return nil
    }

    // MARK: Text handling

    struct Token: Equatable, Sendable {
        let text: String
        /// Unicode scalar range, half-open.
        let range: Range<Int>
    }

    /// Whitespace-delimited tokens with **Unicode scalar** ranges; punctuation
    /// stays in the surface (the offset unit the contract states), and the
    /// lexicon lookup strips it.
    static func tokenize(_ text: String) -> [Token] {
        let scalars = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var start: Int?
        var offset = 0
        for scalar in scalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if let lower = start {
                    tokens.append(makeToken(scalars, lower..<offset))
                    start = nil
                }
            } else if start == nil {
                start = offset
            }
            offset += 1
        }
        if let lower = start { tokens.append(makeToken(scalars, lower..<offset)) }
        return tokens
    }

    private static func makeToken(_ scalars: [Unicode.Scalar],
                                  _ range: Range<Int>) -> Token {
        Token(text: String(String.UnicodeScalarView(scalars[range])), range: range)
    }

    /// The lexicon key for a surface token: punctuation stripped from both
    /// ends, the same normalisation the build artifact applied — so a `'खाना`
    /// in a transcript keys the entry the bank authored for `खाना`.
    static func lexiconKey(of token: String) -> String {
        var scalars = Array(token.unicodeScalars)
        while let first = scalars.first, isPunctuation(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, isPunctuation(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A one-scalar string as its scalar, or nil when the bank's string is not
    /// a single code point — the key the fit folded over is a SCALAR key, and a
    /// multi-scalar "scalar" would be a different (and unmeasured) fold.
    static func singleScalar(_ text: String) -> Unicode.Scalar? {
        let scalars = text.unicodeScalars
        guard scalars.count == 1 else { return nil }
        return scalars.first
    }

    /// The punctuation a token may be wrapped in. ASCII is a literal set (the
    /// STT punctuation the corpus carries) and anything above it asks
    /// `CharacterSet` — which covers the danda and double danda (U+0964/65,
    /// category Po) that Devanagari STT emits, and which is why the class is
    /// consulted rather than a hand-copied list of Devanagari marks.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 { return asciiPunctuation.contains(scalar) }
        return CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    private static let asciiPunctuation: Set<Unicode.Scalar> =
        Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)

    /// The content words around a token, for the paired-keyword prior.
    private static func neighbouringTokens(of token: Token,
                                           in tokens: [Token]) -> [String] {
        guard let index = tokens.firstIndex(where: { $0.range == token.range })
        else { return [] }
        var out: [String] = []
        if index > 0 { out.append(lexiconKey(of: tokens[index - 1].text)) }
        if index + 1 < tokens.count {
            out.append(lexiconKey(of: tokens[index + 1].text))
        }
        return out.filter { !$0.isEmpty }
    }

    /// Rebuilds the transcript from the ORIGINAL scalars, token by token —
    /// never by replacing over the whole utterance, which is how a rewrite
    /// lands on the wrong occurrence of a repeated word. Whitespace and every
    /// scalar outside the tokens pass through untouched, so the only
    /// difference between input and output is the tokens that applied.
    static func splice(_ text: String, tokens: [Token],
                       replacements: [String]) -> String {
        let original = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(original.count)
        var cursor = 0
        for (token, replacement) in zip(tokens, replacements) {
            if cursor < token.range.lowerBound {
                output.append(contentsOf: original[cursor..<token.range.lowerBound])
            }
            output.append(contentsOf: preserveAffixes(of: token.text,
                                                      replacement: replacement)
                .unicodeScalars)
            cursor = token.range.upperBound
        }
        if cursor < original.count {
            output.append(contentsOf: original[cursor...])
        }
        return String(String.UnicodeScalarView(output))
    }

    /// Only the stripped core is replaced, so `'खाना` stays `'`-prefixed and a
    /// trailing danda is not eaten by the correction.
    private static func preserveAffixes(of surface: String,
                                        replacement: String) -> String {
        let scalars = Array(surface.unicodeScalars)
        var prefixCount = 0
        while prefixCount < scalars.count,
              isPunctuation(scalars[prefixCount]) { prefixCount += 1 }
        var suffixCount = 0
        while suffixCount < scalars.count - prefixCount,
              isPunctuation(scalars[scalars.count - 1 - suffixCount]) {
            suffixCount += 1
        }
        let leading = prefixCount > 0
            ? String(String.UnicodeScalarView(scalars.prefix(prefixCount))) : ""
        let trailing = suffixCount > 0
            ? String(String.UnicodeScalarView(scalars.suffix(suffixCount))) : ""
        return leading + replacement + trailing
    }

    // MARK: Distances

    /// Bounded Levenshtein: the generator's FILTER, with an early exit so a
    /// non-match is rejected after the first row rather than after the full
    /// table (§5.3's "Bound" — this is what keeps generation `O(candidates)`
    /// rather than `O(candidates × len²)`).
    static func withinBound(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar],
                            _ bound: Int) -> Bool {
        if a == b { return true }
        if bound <= 0 || abs(a.count - b.count) > bound { return false }
        if a.isEmpty || b.isEmpty { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            var best = i
            for j in 1...b.count {
                let value = min(previous[j] + 1, current[j - 1] + 1,
                                previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                current.append(value)
                if value < best { best = value }
            }
            if best > bound { return false }
            previous = current
        }
        return previous[b.count] <= bound
    }

    /// The exact scalar edit distance the similarity term needs. Two rows, not
    /// a full matrix: nothing here reads the trace back.
    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            current.reserveCapacity(b.count + 1)
            for j in 1...b.count {
                current.append(min(previous[j] + 1, current[j - 1] + 1,
                                   previous[j - 1]
                                       + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Settings (§5.5.1, A-12)

/// The persisted mode and threshold, in the shape the house uses
/// (`DialectBiasSettings`, `CanonicalizerPreferences`): an absent key reads the
/// conservative value, `reset()` restores it, and a value written through
/// `setThreshold` is CLAMPED to the calibrated range on the way in — so a
/// preference written before a re-fit cannot outlive it.
struct STTCorrectionSettings {

    static let modeKey = "sttCorrection.mode"
    static let thresholdKey = "sttCorrection.threshold"

    private let defaults: UserDefaults
    private let lexicon: CorrectionLexicon?

    init(defaults: UserDefaults = .standard,
         lexicon: CorrectionLexicon? = CorrectionLexicon.bundled) {
        self.defaults = defaults
        self.lexicon = lexicon
    }

    /// The kill switch. ABSENT READS OFF: this layer rewrites the text a model
    /// reads, so serving it is an explicit decision (the same rule as
    /// `CanonicalizerPreferences.canonicalizerEnabled`).
    var mode: STTCorrector.Mode {
        guard let raw = defaults.string(forKey: Self.modeKey),
              let mode = STTCorrector.Mode(rawValue: raw) else { return .off }
        return mode
    }

    func setMode(_ mode: STTCorrector.Mode) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    /// The threshold in force: nil when no debugger has moved it, so the caller
    /// uses the calibrated default. Always inside the calibrated range.
    var threshold: Double? {
        guard defaults.object(forKey: Self.thresholdKey) != nil else { return nil }
        let range = lexicon?.calibration.range
            ?? CorrectionLexicon.Calibration.failClosedRange
        return min(max(defaults.double(forKey: Self.thresholdKey), range.lowerBound),
                   range.upperBound)
    }

    /// Returns what was stored, which is the clamped value.
    @discardableResult
    func setThreshold(_ value: Double) -> Double {
        let range = lexicon?.calibration.range
            ?? CorrectionLexicon.Calibration.failClosedRange
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        defaults.set(clamped, forKey: Self.thresholdKey)
        return clamped
    }

    func reset() {
        defaults.removeObject(forKey: Self.thresholdKey)
        defaults.removeObject(forKey: Self.modeKey)
    }
}
