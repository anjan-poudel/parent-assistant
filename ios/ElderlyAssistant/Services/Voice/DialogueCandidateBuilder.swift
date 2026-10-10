import Foundation

// [MULTI-TURN] (2026-10-10, design-l2 §10, C-MTC-03) — the did-you-mean
// candidate assembly: the bounded near-match readings (C-MTC-06) mapped
// to the four framable domains' compose forms, the denied rephrase
// hypothesis appended LAST and only alongside near-match candidates,
// and a hard cap at the frame config's maximum.
//
// Responsibility fence: pure statics — no state, no frame mutation (the
// caller, T-134, arms the frame), no execution knowledge beyond the
// candidate's domain tag, no catalog load, no speech, no side effects.
// Keeping the assembly pure is what keeps the trap surface narrow
// (NFR-MTC-010): nothing here can arm, re-probe, execute or clear
// anything.
//
// Never fabricate (FR-MTC-004): every candidate derives from a rule
// reading or the catalog vocabulary. The near-match candidates carry the
// rule's own matched keys and the utterance's own extracted words; the
// hypothesis candidate carries only the denied command's own field
// (message / topic) and is omitted, silently, when it has none — the
// builder never invents a domain query.
//
// Log safety by construction: no console output and no observability
// metadata (the coordinator's funnel emits the closed-vocabulary events
// instead). No network. This file is one of the four new files the
// release log gate covers (T-138).

/// Assembles the did-you-mean candidate list deterministically from the
/// sources L1 ADR-MTC-07 pins (design-l2 §10). Stateless and pure: the
/// same input always produces the same candidate list.
enum DialogueCandidateBuilder {

    /// The four candidate compose forms — the T-129 `dialogue.*` label
    /// templates (design-l2 §10 mapping table), one per framable domain.
    /// Never re-worded here; the copy review owns the values.
    private enum Key {
        static let news = "dialogue.candidate.news"
        static let youtube = "dialogue.candidate.youtube"
        static let music = "dialogue.candidate.music"
        static let appLaunch = "dialogue.candidate.appLaunch"
    }

    // MARK: - Did-you-mean assembly (design-l2 §10)

    /// Sources in priority order: relaxed near-matches (L2-D10), then
    /// the denied rephrase hypothesis appended LAST and ONLY when at
    /// least one near-match candidate exists (R2) — a re-offer alongside
    /// alternatives, never alone (re-asking a just-denied single option
    /// would ignore the "no": a trap). Returns `[]` when nothing is
    /// eligible ("never fabricate", FR-MTC-004 scenario 3): the caller
    /// arms no frame and keeps its existing honest dead-end line.
    ///
    /// The near-match candidates keep priority under the cap; the
    /// hypothesis occupies the last position and is therefore the first
    /// draft dropped. `maxCandidates` is the frame config's value
    /// (`DialogueConfig.maxCandidates`) passed in as a parameter — no
    /// literal here (design-l2 §27).
    ///
    /// - Parameters:
    ///   - utterance: the transcript the readings are taken from (the
    ///     caller passes the ORIGINAL utterance on the rephrase path,
    ///     not the "no" that denied the hypothesis).
    ///   - excludingDomain: a domain the caller does not want re-offered
    ///     from the near-match readings (design-l2 §10); both live
    ///     trigger sites pass nil.
    ///   - rephraseHypothesis: the denied rephrase-band interpretation,
    ///     re-offered last when the near-matches carried the probe.
    ///   - maxCandidates: the frame's configured candidate maximum.
    static func build(for utterance: String,
                      excludingDomain: KeywordIntentRule.Domain?,
                      rephraseHypothesis: InterpretedCommand?,
                      maxCandidates: Int = DialogueConfig.maxCandidates) -> [DialogueCandidate] {
        var candidates: [DialogueCandidate] = []
        for reading in KeywordIntentRule.nearMatches(transcript: utterance) {
            guard reading.domain != excludingDomain else { continue }
            guard let candidate = candidate(for: reading, utterance: utterance) else { continue }
            candidates.append(candidate)
        }
        if !candidates.isEmpty,
           let hypothesis = hypothesisCandidate(from: rephraseHypothesis) {
            candidates.append(hypothesis)
        }
        // A defensive clamp: `prefix` traps on a negative count, and a
        // non-positive maximum can only mean "offer nothing".
        return Array(candidates.prefix(max(0, maxCandidates)))
    }

    /// One near-match reading → one candidate in its domain's compose
    /// form (design-l2 §10 mapping table). Returns nil when the domain
    /// cannot be composed into an executable candidate — a video
    /// near-match with no quotable query is OMITTED, never invented.
    /// Every domain contributes at most one candidate; `nearMatches`
    /// already reports one reading per domain in rule order, and this
    /// function never fans a reading out.
    private static func candidate(for reading: KeywordIntentRule.NearMatch,
                                  utterance: String) -> DialogueCandidate? {
        switch reading.domain {
        case .news:
            // `%@`-less template: the label reads "The news?".
            return DialogueCandidate(id: nearMatchID(for: .news),
                                     labelKey: Key.news,
                                     domain: .news,
                                     query: nil,
                                     appID: nil,
                                     matchKeys: reading.matchedKeys)
        case .youtube:
            // The executable-query rule (design-l1 ADR-MTC-07 source 2):
            // no quotable query ⇒ no candidate. The composer renders the
            // label's `%@` from this query.
            guard let query = YouTubeRoute.extractQuery(from: utterance) else { return nil }
            return DialogueCandidate(id: nearMatchID(for: .youtube),
                                     labelKey: Key.youtube,
                                     domain: .youtube,
                                     query: query,
                                     appID: nil,
                                     matchKeys: reading.matchedKeys)
        case .music:
            // The extractor's own reading of the same utterance — the
            // user's words, never generated. A degenerate extraction
            // (marker fallback) still names the marker the elder said;
            // the execution side chains a fresh slotFill probe for it.
            return DialogueCandidate(id: nearMatchID(for: .music),
                                     labelKey: Key.music,
                                     domain: .music,
                                     query: KeywordIntentRule.musicQuery(from: utterance),
                                     appID: nil,
                                     matchKeys: reading.matchedKeys)
        case .appLaunch:
            // `%@` renders from the primary match key (no query field);
            // the catalog id rides `appID`, mirroring `Match.appID`.
            return DialogueCandidate(id: nearMatchID(for: .appLaunch),
                                     labelKey: Key.appLaunch,
                                     domain: .appLaunch,
                                     query: nil,
                                     appID: reading.appID,
                                     matchKeys: reading.matchedKeys)
        default:
            // Not a framable domain (festivalDate, medicationPhoto).
            // `nearMatches` never emits these — the reading itself is
            // restricted to the four — so this is defensive totality,
            // never a reachable path.
            return nil
        }
    }

    /// The denied hypothesis → its re-offer candidate (design-l2 §10):
    /// `.music` → `.music` (query = `command.message`); `.suggestVideo`
    /// → `.youtube` (query = `command.topic`); any other action →
    /// omitted (silent). `matchKeys` is empty — the candidate is
    /// index-word pickable only, and an empty list can never seed a
    /// name match.
    ///
    /// A mapped action whose own field is absent carries no renderable
    /// label content (`DialogueProbeComposer` would resolve `%@` to an
    /// empty string), so the hypothesis is omitted exactly like an
    /// unmapped action: the builder must not invent a domain query for
    /// it (FR-MTC-004).
    private static func hypothesisCandidate(from command: InterpretedCommand?) -> DialogueCandidate? {
        guard let command else { return nil }
        switch command.action {
        case .music:
            guard let query = ownWords(command.message) else { return nil }
            return DialogueCandidate(id: hypothesisID(for: .music),
                                     labelKey: Key.music,
                                     domain: .music,
                                     query: query,
                                     appID: nil,
                                     matchKeys: [])
        case .suggestVideo:
            guard let query = ownWords(command.topic) else { return nil }
            return DialogueCandidate(id: hypothesisID(for: .youtube),
                                     labelKey: Key.youtube,
                                     domain: .youtube,
                                     query: query,
                                     appID: nil,
                                     matchKeys: [])
        default:
            return nil
        }
    }

    /// The command's own words, carried verbatim; nil when the field is
    /// absent or blank — a blank field names no interpretation, and
    /// nothing is substituted for it.
    private static func ownWords(_ raw: String?) -> String? {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    /// Stable process-local candidate ids (never logged with content):
    /// one per (source, domain), so the deterministic list is comparable
    /// across builds without touching the user's words.
    private static func nearMatchID(for domain: KeywordIntentRule.Domain) -> String {
        "near.\(domain.rawValue)"
    }

    private static func hypothesisID(for domain: KeywordIntentRule.Domain) -> String {
        "hypothesis.\(domain.rawValue)"
    }

    // MARK: - Slot-fill candidates (design-l2 §10)

    /// The slot-fill candidates for one catalog group: at most
    /// `DialogueConfig.maxSlotOptions` options in file order, with ids,
    /// label keys, canonical queries and match keys (the option's own
    /// aliases) taken verbatim from the catalog data. Phase 1 has one
    /// slot (`DialogueSlot.musicQuery`), so `domain` is `.music` — the
    /// seam the pick executes through.
    ///
    /// The group is re-resolved from the catalog by id, so the shipped
    /// catalog is the single source of the option data (design-l2 §10:
    /// "ids from the catalog"); a group the catalog does not carry
    /// yields no candidates — fail closed, nothing is offered that the
    /// catalog does not own.
    static func slotFillCandidates(from group: DialogueOptionGroup,
                                   catalog: DialogueOptionCatalog) -> [DialogueCandidate] {
        guard let source = catalog.group(group.id) else { return [] }
        return source.options
            .prefix(DialogueConfig.maxSlotOptions)
            .map { option in
                DialogueCandidate(id: option.id,
                                  labelKey: option.labelKey,
                                  domain: .music,
                                  query: option.query,
                                  appID: nil,
                                  matchKeys: option.aliases)
            }
    }
}
