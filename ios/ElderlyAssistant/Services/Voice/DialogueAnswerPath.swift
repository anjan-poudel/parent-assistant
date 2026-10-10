import Foundation

// [MULTI-TURN] (2026-10-10, design-l2 §9/§11/§22, C-MTC-02) — the answer
// path: the classifier, the barge-in predicates, the strip/canonicalise
// pipeline, the input vocabularies and the deterministic merge.
//
// Responsibility fence: pure, synchronous, model-free. Nothing here has
// state, side effects, logging or a router dependency beyond the internal
// statics the barge-in rows consume (B1–B6, each the same single-source
// predicate its ladder stage reads). No exit path of any function in this
// file consults a model, the network or the intent cache (NFR-MTC-003,
// E7 producer): the merge is a pure function over the frame's captured
// command and deterministic inputs.
//
// Sanitisation discipline (NFR-MTC-008, M-3). `classify` reads `raw`
// exactly once — the over-length gate (`raw.count`, L2-D5) — and every
// content decision derives from `prepared`, the value the shared
// preparation helper produced (`IntentTranscriptPreparation.prepare`,
// T-127: `InputSanitiser.sanitise(level: .quarantine)` first, then the
// input seam exactly once). No raw transcript ever reaches a merge: a
// merged value is by construction a function of the prepared text.
//
// Vocabulary single-sourcing. `CaptureForm`, `MergeSource` and
// `DialogueMerge` are declared in `DialogueManager.swift` (wave-order
// hoist, T-125) — this file is a pure consumer and must not re-declare
// them. `KeywordIntentRule.isMusicScaffoldToken` / `isMusicMarkerToken`,
// `CommandRouter.sensitiveCallPhrases` /
// `isExplicitMedicationAcknowledgement`,
// `VoiceContactSearchRoute.isDirectCallUtterance` and the two route
// `decide(transcript:)` functions are all consumed by reference — no
// vocabulary table is copied into this file.
//
// Scaffold readings (`S3`, §22). The pinned `stripScaffold(_:)`
// vocabulary (music scaffold ∨ probe echo, design-l2 §22 preamble) is
// the REQUEST reading. The candidate reading strips probe-echo words
// only, because a candidate's own matchKey word can itself be a music
// drop — `isMusicScaffoldToken("युट्युब")` is true via
// `musicDevanagariContainmentDrops` (the extractor drops the trigger
// morpheme as a query component), and stripping it would make the
// pinned V13 pick unreachable. `isScaffoldToken(_:probeKind:)` is the
// one predicate every call site shares.
//
// Log safety: no console output and no observability metadata are
// produced here — the router's interception block emits the
// closed-vocabulary events (design-l2 §26). This file is one of the four
// new files the release log gate covers (T-138).

/// Why an answer did not resolve (design-l2 §9, C-MTC-02) — the closed
/// invalid vocabulary. `rawValue` is the telemetry vocabulary (§26:
/// `reason` is one of exactly these strings).
enum InvalidAnswerReason: String, Equatable {
    /// The raw answer exceeds `InputSanitiser.maxLength` (L2-D5).
    case overLength
    /// The scaffold strip left nothing to answer with.
    case emptyAfterStrip
    /// Only markers/scaffold survived (e.g. "गीत चलाऊ").
    case degenerateAnswer
    /// candidateChoice free-form and no extractor claimed it (L2-D9).
    case noCandidateClaimed
}

/// One answer's classification (design-l2 §9, C-MTC-02) — the closed
/// outcome set the router's interception block switches over (§12.2).
enum AnswerClassification: Equatable {
    /// The frame's window closed before the classifier ran (half-open,
    /// `DialogueFrame.isExpired(at:)`).
    case expired
    /// An escape phrase — the frame drops and the turn ends (R5).
    case escape
    /// A bare cancel — the frame drops, nothing executes.
    case cancel
    /// A strong command: the frame drops and the utterance falls through
    /// to the unaltered ladder, which executes it exactly once (L2-D18).
    case bargeIn
    /// `index` is the 1-based spoken position (the executor decrements,
    /// §12.2 `executeDialogueCandidate(index - 1, …)`).
    case candidatePick(index: Int, capture: CaptureForm)
    /// A resolved slot value with its capture form and merge source.
    case answer(DialogueMerge)
    /// `index` is 0-based (the executor consumes it directly, §12.2).
    case freeFormForCandidate(index: Int, value: String)
    /// No answer — the frame re-probes under the attempt cap.
    case invalid(InvalidAnswerReason)
}

/// Input vocabularies — matched, never spoken (design-l2 §9; L2-D3/D4).
/// Matched by canonical token comparison, so the table stays permissive
/// about case and punctuation; nothing here is ever spoken, so no label
/// key is involved.
enum DialogueAnswerVocabulary {

    /// Leading position words → list position (1-based).
    static let indexWords: [(token: String, position: Int)] = [
        ("पहिलो", 1), ("first", 1),
        ("दोस्रो", 2), ("second", 2),
        ("तेस्रो", 3), ("third", 3)
    ]

    /// Escape phrases (L2-D4): containment anywhere in the prepared
    /// text; checked before every other reading. Probes never advertise
    /// them — `dialogue.escape` is the acknowledgement, not an
    /// instruction.
    static let escapePhrases: [String] = [
        "फेरि भन्छु", "फेरि भन्न दिनु", "फेरि भन्नुहोस्", "म फेरि भन्छु",
        "let me say it again", "let me repeat", "i'll say it again"
    ]

    /// The leading-position cancel table (L2-D3): {no, nope, wrong,
    /// छैन, होइन, होइनन्} mirrored from `CommandRouter.isNoResponse`
    /// plus the constitution's {रद्द, never mind, cancel}. LEADING
    /// position only — a non-leading negation is a correction, not a
    /// cancel (V11).
    static let cancelTokens: [String] = [
        "no", "nope", "wrong", "छैन", "होइन", "होइनन्",
        "रद्द", "never mind", "cancel"
    ]

    /// The any-option default-answer aliases (the `dialogue.option.anyPlay`
    /// label forms). The default option is deliberately not a catalog
    /// entry (§11).
    static let anyPlayAliases: [String] = [
        "जे पनि", "जे पनि बजाऊ", "जे भए पनि", "anything", "anything works"
    ]

    /// Probe question words — scaffold when they echo the probe's own
    /// wording (V6), stripped by the scaffold strip.
    static let probeEchoWords: [String] = [
        "कस्तो", "कुन", "के", "what", "which", "kind"
    ]
}

/// The pure answer brain (design-l2 §9/§22). See the file header for the
/// fences this type keeps.
enum DialogueAnswerPath {

    // MARK: - Classification

    /// Classifies one utterance against one live frame, in the pinned
    /// order (design-l2 §9 `C0`–`C6`, L2-D1):
    ///
    /// 1. `C0` deadline — an expired frame is `.expired` (the router then
    ///    treats the utterance as a fresh command).
    /// 2. `C1` raw length — `raw.count > InputSanitiser.maxLength` is
    ///    `.invalid(.overLength)`, checked first because
    ///    `InputSanitiser.sanitise` CLAMPS at that bound and a truncated
    ///    merge is forbidden (L2-D5): no prefix of an over-length raw
    ///    answer is ever merged, echoed or stored.
    /// 3. `C2` escape — containment of any `escapePhrases` entry.
    /// 4. `C3` barge-in — `isBargeIn` (L2-D1 places it before the
    ///    cancel/amendment split).
    /// 5. `C4` cancel/amendment — a leading cancel token with nothing
    ///    meaningful after it is `.cancel`; with content after it, the
    ///    remainder is the answer (the no-with-amendment precedent).
    /// 6. `C5` resolve — the `S1`–`S6` ladder of §22 on the (possibly
    ///    amended) value.
    ///
    /// `C6` (the empty-frame guard) holds by construction: `frame` is
    /// non-optional and the router only ever passes `liveFrame`.
    ///
    /// - Parameters:
    ///   - raw: the transcript verbatim. Read for the length gate ONLY —
    ///     never as content (NFR-MTC-008).
    ///   - prepared: the shared preparation helper's answer value
    ///     (`IntentTranscriptPreparation.prepare(...).prepared`) — the
    ///     only text this function classifies.
    ///   - frame: the live frame (already expiry-checked by the caller;
    ///     re-checked here as `C0`).
    ///   - catalog: the loaded option catalog, or nil on the degraded
    ///     path (E3) — then slotFill has no addressable options and the
    ///     resolution degrades to free text.
    ///   - locale: the active locale for the localized any-option label.
    ///   - now: the turn's clock reading (the same one the expiry-aware
    ///     frame read used).
    ///   - medicationNames: the live medication vocabulary B6's keyword
    ///     match consults (B1, the static acknowledgement predicate,
    ///     does not read it). Defaulted so the pinned six-argument call
    ///     shape in design-l2 §12.2 compiles unchanged; the router
    ///     computes the value right there and must pass it — with the
    ///     default, the medication-photo half of B6 is inert.
    static func classify(raw: String,
                         prepared: String,
                         frame: DialogueFrame,
                         catalog: DialogueOptionCatalog?,
                         locale: Locale,
                         now: Date,
                         medicationNames: [String] = []) -> AnswerClassification {
        // C0 — the answer window (half-open).
        if frame.isExpired(at: now) { return .expired }

        // C1 — the raw-length gate (L2-D5): checked on the RAW answer,
        // before any use. `InputSanitiser.sanitise` clamps at the same
        // bound, so accepting here would merge a truncated prefix.
        if raw.count > InputSanitiser.maxLength { return .invalid(.overLength) }

        // The canonical working text — every decision below derives from
        // the prepared value, never from the raw transcript.
        let text = canonical(prepared)

        // C2 — escape first: the escape phrase embeds a negation, so it
        // must be recognised before cancel and before barge-in (L2-D4).
        if DialogueAnswerVocabulary.escapePhrases.contains(where: { text.contains($0) }) {
            return .escape
        }

        // C3 — barge-in, before the cancel/amendment split (L2-D1): the
        // counterexample "होइन, मेरो छोरालाई फोन गर" must reach the call
        // shields, not the amendment branch.
        if isBargeIn(text, frame: frame, medicationNames: medicationNames) {
            return .bargeIn
        }

        // C4 — cancel/amendment, then C5 — resolve.
        switch cancelReading(of: text, probeKind: frame.probeKind) {
        case .cancel:
            return .cancel
        case .amendment(let remainder):
            return resolve(remainder, frame: frame, catalog: catalog, locale: locale)
        case .notACancel:
            return resolve(text, frame: frame, catalog: catalog, locale: locale)
        }
    }

    // MARK: - Barge-in (B1–B7)

    /// The pinned barge-in predicate set (design-l2 §6/§9, L2-D18): an
    /// answer classified as barge-in leaves the frame and falls through
    /// to the unaltered ladder, so an answer can never carry med-ack,
    /// sensitive-call or strong-command vocabulary into a merge. Pure,
    /// total and synchronous — every input yields a Bool.
    ///
    /// The prepared text is canonicalised once and every predicate reads
    /// the same single source its ladder stage reads; no vocabulary is
    /// duplicated.
    ///
    /// - Parameters:
    ///   - prepared: the prepared answer text (its case is folded here;
    ///     the predicate contracts call for lowercase input and receive
    ///     the canonical text).
    ///   - frame: the live frame — `B6` compares the matched domain
    ///     against `frame.domain`, and `B7` is the negative pin: a
    ///     music-domain match inside the music frame is an ANSWER, not a
    ///     barge-in (FR-MTC-005 scenario 3).
    ///   - medicationNames: the live medication vocabulary, exactly as
    ///     the safety net's `isExplicitMedicationAcknowledgement` uses it.
    static func isBargeIn(_ prepared: String,
                          frame: DialogueFrame,
                          medicationNames: [String]) -> Bool {
        let text = canonical(prepared)
        guard !text.isEmpty else { return false }

        // B1 — a dose acknowledgement is never an answer.
        if CommandRouter.isExplicitMedicationAcknowledgement(text) { return true }
        // B2 — the sensitive-call vocabulary (containsPhrase semantics:
        // containment over lowercased text).
        if CommandRouter.sensitiveCallPhrases.contains(where: { text.contains($0) }) { return true }
        // B3 — a direct call request (lowercase-input contract).
        if VoiceContactSearchRoute.isDirectCallUtterance(text) { return true }
        // B4 — the contact-search decision (a phone-screen open request).
        if case .openPhone = VoiceContactSearchRoute.decide(transcript: text) { return true }
        // B5 — a YouTube play request.
        if case .play = YouTubeRoute.decide(transcript: text) { return true }
        // B6 — any keyword match whose domain is not the frame's own; a
        // candidateChoice frame has no domain, so any match barge-ins.
        if let match = KeywordIntentRule.match(transcript: text, medicationNames: medicationNames),
           match.domain != frame.domain {
            return true
        }
        // B7 — a music-domain match mid-music-frame is an answer.
        return false
    }

    // MARK: - The strip pipeline (S2/S3/S6)

    /// `S3`'s strip (pinned signature, design-l2 §9): drops every token
    /// that is a music scaffold token (`KeywordIntentRule.isMusicScaffoldToken`
    /// — verbs, particles, filter words) or a probe-echo word (`कस्तो`,
    /// `what`, …). This is the REQUEST reading's vocabulary (slotFill);
    /// the candidateChoice ladder strips probe-echo words only — see
    /// `isScaffoldToken(_:probeKind:)`. Markers are kept: the free-text
    /// fallback is never marker-stripped (V4), and markers drop only
    /// through `markerDroppedVariant`. Returns the canonical token join.
    static func stripScaffold(_ text: String) -> String {
        stripScaffold(text, probeKind: .slotFill)
    }

    /// The frame reading of the same strip (private): `S3` on the live
    /// ladder — and `merge` — selects its vocabulary by probe kind.
    private static func stripScaffold(_ text: String, probeKind: ProbeKind) -> String {
        tokens(in: canonical(text))
            .filter { !isScaffoldToken($0, probeKind: probeKind) }
            .joined(separator: " ")
    }

    /// `S6`'s variant: drops every music-marker token (`भजन`, `गीत`, …)
    /// — the value the repetition capture matches (V3) and the
    /// degenerate test: empty ⇔ only markers survived (V5/V6).
    static func markerDroppedVariant(_ text: String) -> String {
        tokens(in: canonical(text))
            .filter { !KeywordIntentRule.isMusicMarkerToken($0) }
            .joined(separator: " ")
    }

    // MARK: - Candidate matched (M-5)

    /// The total candidate matcher (design-l2 §9; L2-D10): the 0-based
    /// position of the FIRST candidate (list order) whose `matchKeys` the
    /// value hits under the repo's script-split idiom — Devanagari keys
    /// by containment ("युट्युबमा" ⊃ "युट्युब"), Latin keys whole-token
    /// only — or nil when nothing claims it.
    ///
    /// Totality (M-5, security-design-review): the result is always a
    /// valid index into `frame.candidates` or nil; no answer text can
    /// address outside the frame's candidate list, and no input crashes.
    static func matchCandidate(_ value: String, frame: DialogueFrame) -> Int? {
        let text = canonical(value)
        guard !text.isEmpty else { return nil }
        for (index, candidate) in frame.candidates.enumerated() {
            for key in candidate.matchKeys where wholeTokenMatch(text, key: key) {
                return index
            }
        }
        return nil
    }

    // MARK: - Merge

    /// The deterministic merge (design-l2 §9/§11; FR-MTC-006): resolves
    /// a captured answer value into the `DialogueMerge` the frame
    /// execution carries. This is the `S3`–`S6` value half of §22 —
    /// scaffold strip, then catalog by name, then by marker-dropped
    /// repetition, then the kind's free-form rule. The
    /// classification-only steps (escape, barge-in, cancel, the index
    /// word, the any-option default) live in `classify`.
    ///
    /// Throws `DialogueError.emptyMerge` when the value resolves to
    /// nothing (empty after strip; marker-only — the degenerate
    /// reading; candidateChoice with no claiming extractor) — the
    /// caller treats that as invalid (L2-D9).
    ///
    /// Pure: the result is a function of `value`, `frame` and `catalog`
    /// alone — no model, network or cache is consulted (E7).
    static func merge(_ value: String,
                      into frame: DialogueFrame,
                      catalog: DialogueOptionCatalog?) throws -> DialogueMerge {
        let stripped = stripScaffold(value, probeKind: frame.probeKind)
        guard !stripped.isEmpty else { throw DialogueError.emptyMerge }

        // By name, then by repetition (the `S4` tables).
        if let option = matchingOption(stripped, frame: frame, catalog: catalog) {
            return DialogueMerge(value: option.query, capture: .optionName, source: .catalog)
        }
        let variant = markerDroppedVariant(stripped)
        if !variant.isEmpty, let option = matchingOption(variant, frame: frame, catalog: catalog) {
            return DialogueMerge(value: option.query, capture: .repetition, source: .catalog)
        }

        switch frame.probeKind {
        case .slotFill:
            // `S6` — a marker-only value resolved to nothing: the same
            // degenerate reading `classify` reports as
            // `.invalid(.degenerateAnswer)`.
            guard !variant.isEmpty else { throw DialogueError.emptyMerge }
            // Free text, markers kept.
            return DialogueMerge(value: stripped, capture: .freeText, source: .freeText)
        case .candidateChoice:
            // `S6` — a marker-only value is the degenerate reading: the
            // same `variant.isEmpty` gate `classify` applies before the
            // claim step (W2 review F-3), so a claim on nothing can
            // never merge.
            guard !variant.isEmpty else { throw DialogueError.emptyMerge }
            // `S6`/L2-D9 — only a candidate's own extractor may claim it.
            guard let claim = firstClaimingCandidate(stripped, frame: frame) else {
                throw DialogueError.emptyMerge
            }
            return DialogueMerge(value: claim.value, capture: .freeText, source: .candidate)
        }
    }

    // MARK: - C5 resolution (S1–S6)

    /// The `S1`–`S6` ladder on one working value (design-l2 §22).
    private static func resolve(_ value: String,
                                frame: DialogueFrame,
                                catalog: DialogueOptionCatalog?,
                                locale: Locale) -> AnswerClassification {
        // S1 — normalize; nothing at all.
        let allTokens = tokens(in: canonical(value))
        guard !allTokens.isEmpty else { return .invalid(.emptyAfterStrip) }

        // S2 — the leading index word.
        var working = allTokens
        if let position = DialogueAnswerVocabulary.indexWords
            .first(where: { $0.token == allTokens[0] })?.position {
            let remainder = Array(allTokens.dropFirst())
            if remainder.isEmpty {
                // A bare position word picks when the frame can address
                // it; otherwise it carried no answer content (and must
                // never be merged as free text).
                switch frame.probeKind {
                case .slotFill:
                    guard let group = slotFillGroup(frame: frame, catalog: catalog) else {
                        return .invalid(.emptyAfterStrip)
                    }
                    let options = cappedOptions(of: group)
                    guard position <= options.count else { return .invalid(.emptyAfterStrip) }
                    return .answer(DialogueMerge(value: options[position - 1].query,
                                                 capture: .indexWord,
                                                 source: .catalog))
                case .candidateChoice:
                    guard position <= frame.candidates.count else {
                        return .invalid(.emptyAfterStrip)
                    }
                    return .candidatePick(index: position, capture: .indexWord)
                }
            }
            // With content after it, the index token is scaffold and the
            // remainder continues through the ladder.
            working = remainder
        }

        // S3 — the scaffold strip.
        let stripped = working
            .filter { !isScaffoldToken($0, probeKind: frame.probeKind) }
            .joined(separator: " ")
        guard !stripped.isEmpty else { return .invalid(.emptyAfterStrip) }

        // S4(a) — the whole stripped value against the kind's tables.
        if let classification = tableMatch(stripped,
                                            capture: .optionName,
                                            frame: frame,
                                            catalog: catalog) {
            return classification
        }
        // S4(b) — the marker-dropped variant, captured as the
        // repetition (V3).
        let variant = markerDroppedVariant(stripped)
        if !variant.isEmpty,
           let classification = tableMatch(variant,
                                           capture: .repetition,
                                           frame: frame,
                                           catalog: catalog) {
            return classification
        }

        // S5 — the any-option pick (slotFill with a pending default).
        if frame.probeKind == .slotFill,
           let fallback = frame.defaultQuery,
           matchesAnyPlay(stripped: stripped, canonicalValue: canonical(value), locale: locale) {
            return .answer(DialogueMerge(value: fallback,
                                         capture: .optionName,
                                         source: .defaultQuery))
        }

        // S6 — degenerate first: only markers survived (V5/V6).
        if variant.isEmpty { return .invalid(.degenerateAnswer) }

        switch frame.probeKind {
        case .slotFill:
            // Free text, markers kept — the never-reject reading of
            // FR-MTC-005 (V4).
            return .answer(DialogueMerge(value: stripped,
                                         capture: .freeText,
                                         source: .freeText))
        case .candidateChoice:
            // L2-D9 — the first candidate whose own extractor claims
            // the value; no claim ⇒ invalid (never fabricate).
            if let claim = firstClaimingCandidate(stripped, frame: frame) {
                return .freeFormForCandidate(index: claim.index, value: claim.value)
            }
            return .invalid(.noCandidateClaimed)
        }
    }

    // MARK: - Match tables

    /// One `S4` table pass: slotFill against the catalog group's option
    /// aliases (strict whole-value equality), candidateChoice against the
    /// candidates' `matchKeys` (the script-split idiom). nil = no match.
    private static func tableMatch(_ value: String,
                                   capture: CaptureForm,
                                   frame: DialogueFrame,
                                   catalog: DialogueOptionCatalog?) -> AnswerClassification? {
        switch frame.probeKind {
        case .slotFill:
            guard let option = matchingOption(value, frame: frame, catalog: catalog) else {
                return nil
            }
            return .answer(DialogueMerge(value: option.query, capture: capture, source: .catalog))
        case .candidateChoice:
            guard let index = matchCandidate(value, frame: frame) else { return nil }
            // The spoken position is 1-based; the executor decrements.
            return .candidatePick(index: index + 1, capture: capture)
        }
    }

    /// The slotFill group claimed by the frame's pending query, or nil
    /// (no catalog — the degraded E3 path; no pending query).
    private static func slotFillGroup(frame: DialogueFrame,
                                      catalog: DialogueOptionCatalog?) -> DialogueOptionGroup? {
        guard frame.probeKind == .slotFill,
              let catalog,
              let pending = frame.defaultQuery else { return nil }
        return catalog.groupForMusicQuery(pending)
    }

    /// The spoken slice of a group: at most `DialogueConfig.maxSlotOptions`
    /// options, in file order — exactly what the probe offers, so only
    /// what was offered is addressable (by index word or by name).
    private static func cappedOptions(of group: DialogueOptionGroup) -> [DialogueOption] {
        Array(group.options.prefix(DialogueConfig.maxSlotOptions))
    }

    /// A strict whole-value alias match against the slotFill group's
    /// option vocabulary — the `S4` name capture.
    ///
    /// Deliberately STRICTER than
    /// `DialogueOptionCatalog.option(matchingWholeValue:in:)`'s
    /// containment semantics (§11): the vectors discriminate. V3 pins
    /// that "दुर्गा भजन बजाऊ"'s stripped value ("दुर्गा भजन") must
    /// capture the repetition — not the दुर्गा option — so the name step
    /// may not containment-match "दुर्गा" inside a longer phrase; V11
    /// pins that "दुर्गा होइन" stays free text. The catalog API keeps
    /// its shipped containment semantics for its own callers untouched;
    /// the classifier passes the value and its marker-dropped variant
    /// separately, as §11 documents.
    private static func matchingOption(_ value: String,
                                       frame: DialogueFrame,
                                       catalog: DialogueOptionCatalog?) -> DialogueOption? {
        guard let group = slotFillGroup(frame: frame, catalog: catalog) else { return nil }
        return cappedOptions(of: group).first { option in
            option.aliases.contains { wholeValueEquals(value, $0) }
        }
    }

    /// L2-D9's bounded free-form reading: the first candidate (list
    /// order) whose own domain extractor claims the value. Only music
    /// and youtube accept free text; news and appLaunch candidates can
    /// never be claimed, so nothing is fabricated and nothing executes
    /// unasked (R2).
    private static func firstClaimingCandidate(_ value: String,
                                               frame: DialogueFrame) -> (index: Int, value: String)? {
        let text = canonical(value)
        for (index, candidate) in frame.candidates.enumerated() {
            switch candidate.domain {
            case .music:
                if let extracted = KeywordIntentRule.musicQuery(from: text) {
                    return (index, extracted)
                }
            case .youtube:
                if let extracted = YouTubeRoute.extractQuery(from: text) {
                    return (index, extracted)
                }
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - C4 cancel/amendment

    /// The C4 reading (L2-D3): LEADING-position cancel detection over
    /// `cancelTokens` (single tokens and the two-word "never mind"),
    /// consuming consecutive leading cancel entries, then the
    /// bare-whole-utterance test — nothing meaningful remains ⇔ every
    /// leftover token is scaffold or a probe echo ⇒ `.cancel` (this is
    /// the `isNoResponse` semantics for bare utterances). Anything that
    /// does remain is an amendment: that remainder is the answer (the
    /// no-with-amendment precedent, V10). A non-leading negation is
    /// never a cancel (V11). The leftover-scaffold test reads the
    /// frame's own scaffolding vocabulary (`isScaffoldToken(_:probeKind:)`).
    private enum CancelReading {
        case notACancel
        case cancel
        case amendment(String)
    }

    private static func cancelReading(of text: String, probeKind: ProbeKind) -> CancelReading {
        let all = tokens(in: text)
        guard let (_, leadLength) = cancelLead(in: all) else { return .notACancel }
        var rest = Array(all.dropFirst(leadLength))
        while let (_, nextLength) = cancelLead(in: rest) {
            rest = Array(rest.dropFirst(nextLength))
        }
        if rest.allSatisfy({ isScaffoldToken($0, probeKind: probeKind) }) { return .cancel }
        return .amendment(rest.joined(separator: " "))
    }

    /// The leading cancel entry of a token list, if any: the first
    /// `cancelTokens` entry whose token sequence prefixes the list.
    private static func cancelLead(in list: [String]) -> (entry: [String], length: Int)? {
        guard !list.isEmpty else { return nil }
        for entry in DialogueAnswerVocabulary.cancelTokens {
            let entryTokens = tokens(in: canonical(entry))
            guard !entryTokens.isEmpty, entryTokens.count <= list.count else { continue }
            if Array(list.prefix(entryTokens.count)) == entryTokens {
                return (entryTokens, entryTokens.count)
            }
        }
        return nil
    }

    // MARK: - S5 any-option

    /// The S5 test: the value equals the localized
    /// `dialogue.option.anyPlay` label (as spoken or as its content-word
    /// join) or one of the pinned `anyPlayAliases`. Both the canonical
    /// value and the scaffold-stripped value are checked so the en label
    /// ("just play anything" — no alias covers its stripped "just
    /// anything") and the ne label ("जे पनि बजाऊ", also an alias) both
    /// resolve.
    private static func matchesAnyPlay(stripped: String,
                                       canonicalValue: String,
                                       locale: Locale) -> Bool {
        let label = canonical(L10n.str("dialogue.option.anyPlay", locale: locale))
        if !label.isEmpty, stripped == label || canonicalValue == label { return true }
        return DialogueAnswerVocabulary.anyPlayAliases.contains { alias in
            let aliasNorm = canonical(alias)
            return stripped == aliasNorm || canonicalValue == aliasNorm
        }
    }

    // MARK: - Canonicalisation and token primitives

    /// `normalize` (§22): lowercase + interior-whitespace collapse. Every
    /// comparison in this file runs on canonical text.
    private static func canonical(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The whole-token split (the `containsToken` idiom, mirrored
    /// locally), with the danda/viram union the shipped extractor trims
    /// with. Callers pass canonical text; tokens come out lowercase and
    /// punctuation-free.
    private static func tokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "।॥")))
            .filter { !$0.isEmpty }
    }

    /// `S3`'s per-token predicate, frame-kind aware. Probe-echo words
    /// are scaffold for both kinds; the music scaffold family (verbs,
    /// particles, filter words) is the REQUEST reading's vocabulary —
    /// the slotFill ladder (V3/V5/V6). On a candidateChoice frame the
    /// elder is answering "which one?" with the candidates' own words,
    /// and a matchKey word can itself be a music drop: `युट्युब` is in
    /// `musicDevanagariContainmentDrops` (the extractor drops it as a
    /// query trigger), so `isMusicScaffoldToken("युट्युब")` is true —
    /// stripping it would make the pinned V13 pick unreachable. The
    /// request vocabulary therefore never applies to the candidate
    /// reading (design-l2 §22 S3 names "probe-echo words" for it).
    private static func isScaffoldToken(_ token: String, probeKind: ProbeKind) -> Bool {
        if DialogueAnswerVocabulary.probeEchoWords.contains(token) { return true }
        switch probeKind {
        case .slotFill:
            return KeywordIntentRule.isMusicScaffoldToken(token)
        case .candidateChoice:
            return false
        }
    }

    /// Strict whole-value equality (`S4`'s catalog tables): the value's
    /// token sequence equals the alias's, after canonicalisation.
    /// Punctuation- and case-insensitive; token equality is
    /// grapheme-cluster equality, so the गीत/गीता near-pair stays
    /// distinct.
    private static func wholeValueEquals(_ value: String, _ alias: String) -> Bool {
        let valueTokens = tokens(in: canonical(value))
        let aliasTokens = tokens(in: canonical(alias))
        return !aliasTokens.isEmpty && valueTokens == aliasTokens
    }

    /// The script-split matching idiom (L2-D10), mirrored locally:
    /// Devanagari and multi-word keys match by grapheme-aware
    /// containment ("युट्युबमा" ⊃ "युट्युब", "भजनहरू" ⊃ "भजन"), single
    /// Latin keys match whole-token only ("bhajans" never matches
    /// "bhajan").
    private static func wholeTokenMatch(_ text: String, key: String) -> Bool {
        let textNorm = canonical(text)
        let keyNorm = canonical(key)
        guard !keyNorm.isEmpty else { return false }
        let hasDevanagari = keyNorm.unicodeScalars.contains { scalar in
            (0x0900...0x097F).contains(scalar.value)
        }
        if hasDevanagari || keyNorm.contains(" ") {
            return textNorm.contains(keyNorm)
        }
        return tokens(in: textNorm).contains(keyNorm)
    }
}

// MARK: - The merged command (L2-D13)

extension InterpretedCommand {
    /// The merged music command (design-l2 §9, L2-D13; FR-MTC-006): the
    /// free-text `message` entity replaced with the merged answer value —
    /// every other stored field copied verbatim, in the shipped
    /// memberwise-initialiser order (all 14 fields; all are `let`, so
    /// this is the only way to produce a merged command). The result
    /// travels the same executor a fresh interpreted `.music` command
    /// uses (`dispatchInterpreted`), so the parity claim is structural.
    ///
    /// A field added to `InterpretedCommand` surfaces here: the
    /// memberwise call names every non-defaulted field, and the suite's
    /// field-count assertion fails on this line's target until the field
    /// is threaded through.
    func merging(message: String) -> InterpretedCommand {
        InterpretedCommand(action: action, entryId: entryId, contact: contact,
                           time: time, medication: medication, message: message,
                           callType: callType, requestedApp: requestedApp,
                           topic: topic, steps: steps, pluginAction: pluginAction,
                           pluginEntities: pluginEntities,
                           confidence: confidence, reply: reply)
    }
}
