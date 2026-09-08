import Foundation

// MARK: - Accent adaptation: dialect-tagged decode biasing
//
// Doc: docs/research-sections/accent-adaptation.md §6 P0.3 ("Per-user decode
// biasing", problem C) — the highest-value increment that is offline and
// cheap (no retraining, no model downloads). Composes ON TOP of the shipped
// P0 slice D (`DialectIdentifier` + centroid-table prompt tokens): the
// dialect label stays the gate, this layer adds the per-dialect lexicon
// (tag line + known dialect words), per-user profile terms (contact names,
// medication names, app names — the Nepanglish/name errors that dominate
// day-to-day failures), and the honest seams the doc requires.
//
// Seam contract (extends DialectIdentifier.swift's):
// - `.default` label (which is what the classifier returns for
//   unknown/low-confidence dialect ID) → `.defaultLabel` plan → the
//   recognizers apply NOTHING. Existing STT behaviour stays byte-identical
//   for every user who has not been confidently classified — this is the
//   coordinator-mandated fallback, and slice D's contract, preserved.
// - Disabled via `DialectBiasSettings` (UserDefaults toggle, default ON
//   when a label is set; the toggle only matters for non-default labels)
//   → `.disabledByUser` → recognizers apply nothing and say so once.
// - A corrupt lexicon or centroid table degrades to the parts that are
//   trustworthy (profile terms / calibrated ids), never to a guess; the
//   recognizer reports the degradation honestly once per session.
// - PII safety: profile terms come from an injected provider (default
//   empty) and are sanitised + capped here; nothing leaves the device and
//   nothing is persisted by this file.
//
// Prompt-token budget (research §4.1): biasing is a soft lexical lever,
// effective at ~5–50 domain terms, degrading past ~200 shared-context
// tokens. P0 budget: ≤100 tokens total (dialect phrases + profile terms +
// tag line), enforced at decode time after tokenization.

// MARK: - Per-user profile terms

/// Per-user decode-biasing terms sourced from the profile. Empty by
/// default — the recognizers bias nothing unless the coordinator wires a
/// provider. Never persisted, never leaves the device.
struct DialectBiasProfile: Equatable, Sendable {
    var contactNames: [String] = []
    var medicationNames: [String] = []
    var appNames: [String] = []

    /// The app names the assistant can act on, in both the Latin
    /// (Nepanglish) and Devanagari renderings the recognizer actually
    /// confuses. Ship-standard list; the coordinator's provider may
    /// substitute its own.
    static let standardSupportedAppNames: [String] = [
        "WhatsApp", "व्हाट्सएप", "वाट्सएप",
        "Messenger", "म्यासेन्जर",
        "Viber", "भाइबर",
        "FaceTime", "फेसटाइम",
        "YouTube", "युट्युब",
    ]

    var isEmpty: Bool {
        contactNames.isEmpty && medicationNames.isEmpty && appNames.isEmpty
    }
}

// MARK: - Enable/disable seam

/// UserDefaults toggle for the whole dialect biasing path (same shape as
/// `DialectPreference`). When disabled, the recognizers behave exactly as
/// they did before adaptation existed, and say so once per session.
/// Injected defaults keep tests hermetic.
enum DialectBiasSettings {
    static let defaultsKey = "dialectBiasEnabled"

    /// Default is enabled — the toggle is an inspection/escape hatch, not
    /// an opt-in gate.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil
            ? true
            : defaults.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

// MARK: - Bundled per-dialect lexicon

/// The bundled per-dialect lexicon (`Resources/DialectLexicon.json`):
/// a dialect tag line plus known dialect words/phrases per label —
/// "per-dialect lexica" from the research (§2 problem C). Content, not
/// code: the calibration/linguist pipeline replaces the JSON without an
/// app change (same shape as `DialectCentroidTable`).
///
/// The shipped file is SEED-LEXICON: tag lines plus a small set of
/// attested items per dialect, marked linguist-review-pending. Phrases
/// bias the decoder softly (≤100-token budget shared with profile
/// terms), so imperfect seed content degrades gracefully — but the
/// honesty rule from the centroid table applies: a *structurally
/// corrupt* lexicon must not bias at all.
struct DialectLexicon: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let dialect: String
        /// One short conditioning line naming the variety (the doc's
        /// "dialect tag line"). Applied last in the composed prompt.
        let tagLine: String
        /// Known dialect words/phrases for this variety.
        let phrases: [String]
    }

    struct Generation: Decodable, Sendable {
        /// "SEED-LEXICON" while linguist review is pending; "calibrated"
        /// once the pipeline has replaced the content.
        let status: String
        let path: String
        let date: String?
    }

    let formatVersion: Int
    let generation: Generation
    let entries: [Entry]

    static let bundledResourceName = "DialectLexicon"

    /// Loads the shipped lexicon from the given bundle. Returns nil when
    /// the resource is absent; throws when it exists but cannot decode.
    static func bundled(in bundle: Bundle = .main) throws -> DialectLexicon? {
        guard let url = bundle.url(forResource: bundledResourceName,
                                   withExtension: "json") else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DialectLexicon.self, from: data)
    }

    /// Process-wide cache for the decode hot path. Missing/corrupt caches
    /// as nil — the decode path then degrades to profile terms only and
    /// the recognizer reports the reason honestly once per session.
    static let bundledCached: DialectLexicon? = {
        try? DialectLexicon.bundled()
    }()

    func entry(for label: DialectLabel) -> Entry? {
        guard label != .default else { return nil }
        return entries.first { $0.dialect == label.rawValue }
    }

    // MARK: Honest validation

    enum Issue: Equatable, Sendable {
        case unsupportedFormatVersion(Int)
        case emptyEntries
        case duplicateDialect(String)
        case unknownDialect(String)
        case emptyTagLine(String)
    }

    /// Structural checks in deterministic order. A lexicon with any issue
    /// must not bias — its answers would be silently wrong, so the caller
    /// treats it as absent (and the recognizer reports the degradation).
    func issues() -> [Issue] {
        var found: [Issue] = []
        if formatVersion != 1 { found.append(.unsupportedFormatVersion(formatVersion)) }
        if entries.isEmpty { found.append(.emptyEntries) }
        var seen = Set<String>()
        for entry in entries {
            if !seen.insert(entry.dialect).inserted {
                found.append(.duplicateDialect(entry.dialect))
            } else if DialectLabel(rawValue: entry.dialect) == nil
                        || DialectLabel(rawValue: entry.dialect) == .default {
                found.append(.unknownDialect(entry.dialect))
            }
            if entry.tagLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(.emptyTagLine(entry.dialect))
            }
        }
        return found
    }
}

// MARK: - Composition result

/// The resolved adaptation for one decode: either a state that applies
/// nothing (byte-identical to the unadapted path) or `.active` with the
/// composed prompt. Pure value — no I/O, no user data beyond what the
/// caller passed in.
struct DialectBiasPlan: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Adaptation applies: `promptText` (and/or `calibratedTokenIds`)
        /// carry material.
        case active
        /// Adaptation disabled by the user.
        case disabledByUser
        /// No dialect identified (the classifier's honest
        /// unknown/low-confidence output IS `.default`) → the unadapted
        /// path, byte-identical to today.
        case defaultLabel
        /// A label is set but there is nothing trustworthy to bias with.
        case noMaterial
    }

    let state: State
    let label: DialectLabel
    /// Composed prompt text (dialect tag line + dialect phrases + profile
    /// terms), nil unless `.active`. Consumed as text by whisper.cpp
    /// (tokenizes itself) and tokenized on-device by the WhisperKit path.
    let promptText: String?
    /// Calibrated whisper BPE ids from the centroid table (empty while
    /// seeds ship; filled by the server calibration pipeline). WhisperKit
    /// only — whisper.cpp's initial_prompt is text-only.
    let calibratedTokenIds: [Int]
    // Source counts (observability metadata; also honest evidence that
    // nothing was silently dropped by sanitation caps).
    let lexiconPhraseCount: Int
    let contactCount: Int
    let medicationCount: Int
    let appCount: Int

    /// True when the plan carries no bias material at all.
    var hasNoMaterial: Bool {
        (promptText ?? "").isEmpty && calibratedTokenIds.isEmpty
    }
}

// MARK: - Composer

/// Pure, deterministic composition of the dialect decode-biasing prompt.
/// No I/O, no audio, no user data beyond the arguments.
enum DialectBiasComposer {
    /// P0 prompt budget (research §4.1; `DialectCentroidTable` uses the
    /// same number for its precomputed ids).
    static let maxPromptTokenCount = 100
    /// Loose character guard applied before tokenization; the token cap
    /// above is the real enforcement (Devanagari words are typically
    /// 2–3 BPE tokens each, so this comfortably exceeds 100 tokens and
    /// only exists to bound pathological profile data).
    static let maxPromptCharacters = 600
    static let maxContactTerms = 20
    static let maxMedicationTerms = 10
    static let maxAppTerms = 5
    /// Per-term length cap (characters) — long fields are truncated, not
    /// dropped, so a long contact name still biases its first-name core.
    static let maxTermLength = 40
    static let maxLexiconPhrases = 8
    static let maxTagLineLength = 120

    /// Resolves the plan for one decode. `table` and `lexicon` are the
    /// bundled caches (nil when missing/corrupt — handled honestly);
    /// `profile` comes from the recognizer's injected provider (empty by
    /// default); `label` is the persisted dialect label.
    static func plan(label: DialectLabel,
                     table: DialectCentroidTable?,
                     lexicon: DialectLexicon?,
                     profile: DialectBiasProfile,
                     enabled: Bool) -> DialectBiasPlan {
        let empty = DialectBiasPlan(state: .disabledByUser,
                                    label: label,
                                    promptText: nil,
                                    calibratedTokenIds: [],
                                    lexiconPhraseCount: 0,
                                    contactCount: 0,
                                    medicationCount: 0,
                                    appCount: 0)
        guard enabled else {
            return withState(.disabledByUser, base: empty)
        }
        guard label.selectsPack else {
            // Unknown / low-confidence dialect ID lands here (the
            // classifier returns .default below the confidence gate):
            // the unadapted path, byte-identical to today.
            return withState(.defaultLabel, base: empty)
        }

        // A corrupt table must not bias (mirrors the classifier's
        // `tableCorrupt` refusal); a corrupt lexicon degrades to profile
        // terms only.
        let validTable = table.flatMap { $0.issues().isEmpty ? $0 : nil }
        let calibrated = validTable?.promptTokenIds(for: label) ?? []

        let entry = lexicon.flatMap { $0.issues().isEmpty ? $0 : nil }
            .flatMap { $0.entry(for: label) }

        // Doc order (P0.3): contact names, medication names, app names,
        // known dialect words, then the dialect tag line.
        let contacts = sanitizedTerms(profile.contactNames,
                                      maxCount: maxContactTerms)
        let medications = sanitizedTerms(profile.medicationNames,
                                         maxCount: maxMedicationTerms)
        let apps = sanitizedTerms(profile.appNames,
                                  maxCount: maxAppTerms)
        let phrases = sanitizedTerms(entry?.phrases ?? [],
                                     maxCount: maxLexiconPhrases)

        var parts = contacts + medications + apps + phrases
        parts = deduplicatedPreservingOrder(parts)
        var textParts = parts
        if let tagLine = entry?.tagLine,
           !tagLine.isEmpty {
            textParts.append(String(tagLine.prefix(maxTagLineLength)))
        }
        var promptText = textParts.joined(separator: " ")
        if promptText.count > maxPromptCharacters {
            promptText = truncated(atWordBoundary: promptText,
                                   maxCharacters: maxPromptCharacters)
        }
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)

        let plan = DialectBiasPlan(state: .active,
                                   label: label,
                                   promptText: trimmed.isEmpty ? nil : trimmed,
                                   calibratedTokenIds: calibrated,
                                   lexiconPhraseCount: phrases.count,
                                   contactCount: contacts.count,
                                   medicationCount: medications.count,
                                   appCount: apps.count)
        if plan.hasNoMaterial {
            return withState(.noMaterial, base: plan)
        }
        return plan
    }

    /// Merges calibrated ids (server-precomputed BPE ids) with
    /// runtime-tokenized text ids into the final prompt-token list:
    /// calibrated first, exact duplicates dropped, capped at
    /// `maxPromptTokenCount`. Empty input → empty output (callers treat
    /// that as "apply nothing").
    static func mergeTokenIDs(calibrated: [Int],
                              tokenized: [Int],
                              maxCount: Int = maxPromptTokenCount) -> [Int] {
        var seen = Set<Int>()
        var merged: [Int] = []
        for id in calibrated + tokenized where seen.insert(id).inserted {
            merged.append(id)
        }
        return Array(merged.prefix(maxCount))
    }

    // MARK: Term sanitation (pure)

    /// Trims/collapses whitespace, drops empty results, truncates long
    /// terms, caps the count. Deterministic.
    static func sanitizedTerms(_ terms: [String], maxCount: Int) -> [String] {
        var out: [String] = []
        for raw in terms {
            guard out.count < maxCount else { break }
            let collapsed = raw
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            out.append(String(collapsed.prefix(maxTermLength)))
        }
        return out
    }

    /// Case-insensitive dedupe preserving first occurrence (contacts and
    /// medications can overlap — "Sita" the contact and "sita" the
    /// medication must not eat two prompt slots).
    static func deduplicatedPreservingOrder(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in terms {
            let key = term.lowercased()
            if seen.insert(key).inserted {
                out.append(term)
            }
        }
        return out
    }

    /// Truncates at a word boundary so a partial word never enters the
    /// prompt: when the cap lands exactly after a complete word (next
    /// char is a space) everything through the cap is kept; otherwise
    /// the trailing partial word is dropped; a hard cut only when there
    /// is no space at all before the cap.
    static func truncated(atWordBoundary text: String,
                          maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let boundary = text.index(text.startIndex, offsetBy: maxCharacters)
        // Cap lands right after a complete word.
        if text[boundary] == " " {
            return String(text[..<boundary])
        }
        let prefix = text[..<boundary]
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(text[..<lastSpace])
        }
        return String(prefix)
    }

    private static func withState(_ state: DialectBiasPlan.State,
                                  base: DialectBiasPlan) -> DialectBiasPlan {
        DialectBiasPlan(state: state,
                        label: base.label,
                        promptText: base.promptText,
                        calibratedTokenIds: base.calibratedTokenIds,
                        lexiconPhraseCount: base.lexiconPhraseCount,
                        contactCount: base.contactCount,
                        medicationCount: base.medicationCount,
                        appCount: base.appCount)
    }
}

// MARK: - Runtime resolution (shared by both recognizers)

/// Glue the recognizers share so the two decode paths can never drift on
/// what "the current adaptation" is. Arguments default to the process
/// caches; tests pass explicit values.
enum DialectBiasResolver {
    static func resolve(profile: DialectBiasProfile,
                        table: DialectCentroidTable? = DialectCentroidTable.bundledCached,
                        lexicon: DialectLexicon? = DialectLexicon.bundledCached,
                        enabled: Bool = DialectBiasSettings.isEnabled(),
                        label: DialectLabel = DialectPreference.persisted()) -> DialectBiasPlan {
        DialectBiasComposer.plan(label: label,
                                 table: table,
                                 lexicon: lexicon,
                                 profile: profile,
                                 enabled: enabled)
    }
}
