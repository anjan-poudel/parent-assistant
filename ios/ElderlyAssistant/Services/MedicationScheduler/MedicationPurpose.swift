import Foundation

/// [MED-PURPOSE] (2026-09-17) What a medicine is FOR — the ten common
/// purposes the family can pick from when they add it, plus the elder's own
/// words when none of the ten fit.
///
/// The stored value is the chip's raw id ("bloodPressure"), NOT its label:
/// an id survives the app language changing under it, and the label is
/// resolved at DRAW time through the same L10n catalog every other string
/// uses (spec §3.2 — the active locale is the source of truth). Free text
/// is stored verbatim, which is why `MedicationEntry.purpose` is a single
/// `String?` and not an enum: a chip and a caregiver's sentence are the
/// same field, and an unversioned store payload must keep decoding either
/// shape (design §2).
///
/// Declaration order IS the editor's chip order — the ten labels the design
/// approved, blood pressure first.
enum MedicationPurpose: String, CaseIterable, Identifiable {
    case bloodPressure
    case diabetes
    case pain
    case heart
    case sleep
    case stomach
    case breathing
    case vitamins
    case antibiotics
    case other

    var id: String { rawValue }

    /// The catalog key for this chip's label ("meds.purpose.<id>").
    var labelKey: String { "meds.purpose.\(rawValue)" }

    /// The chip's label in `locale` — the text the button shows and the
    /// text the chip writes into the editor's free-text field.
    func label(locale: Locale) -> String { L10n.str(labelKey, locale: locale) }

    /// The words an elder may actually SAY for this purpose, in both
    /// languages. Deliberately short lists: every key here is a word the
    /// voice photo rule will claim an utterance on, so a loose synonym is a
    /// wrong-photo risk, not extra coverage. Devanagari postpositions fuse
    /// onto the stem ("रक्तचापको औषधि" ⊃ "रक्तचाप"), which the rule's
    /// phrase mode handles, so only the bare stem ships.
    var voiceKeys: [String] {
        switch self {
        case .bloodPressure: return ["रक्तचाप", "blood pressure", "pressure"]
        case .diabetes: return ["चिनी", "मधुमेह", "diabetes", "sugar"]
        case .pain: return ["दुखाइ", "दुखाई", "pain"]
        case .heart: return ["मुटु", "हृदय", "heart"]
        case .sleep: return ["निद्रा", "sleep"]
        case .stomach: return ["पेट", "stomach"]
        case .breathing: return ["सास फेर्न", "सास", "breathing"]
        case .vitamins: return ["भिटामिन", "vitamins", "vitamin"]
        case .antibiotics: return ["एन्टिबायोटिक", "antibiotics", "antibiotic"]
        case .other: return ["अन्य", "other"]
        }
    }

    /// The chip a stored value names, or nil when the value is free text
    /// (or nothing at all). Exact match on the id, and the ids of the
    /// single-word chips are ordinary words ("pain", "heart", "sleep") —
    /// so a caregiver who types one of them EXACTLY gets that chip: its
    /// localized label in the active language, and its keyword list for
    /// voice. Nothing they typed is lost — the typed word is one of the
    /// chip's own `voiceKeys` — and every other phrase ("for the heart
    /// valve") stays their words, verbatim.
    static func chip(forStored value: String?) -> MedicationPurpose? {
        guard let value else { return nil }
        return MedicationPurpose(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The display text for a stored purpose: a chip id renders as the
    /// chip's label in the active language, free text renders verbatim, and
    /// an empty/absent value is simply no purpose. The single place both
    /// the settings row and the photo caption resolve a stored value, so a
    /// chip and a custom phrase can never drift apart between surfaces.
    static func label(forStored value: String?, locale: Locale) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let chip = chip(forStored: trimmed) { return chip.label(locale: locale) }
        return trimmed
    }
}

/// [MED-PURPOSE] (2026-09-17) The voice vocabulary one medication answers
/// to, computed from the LIVE entry — never a table keyed by drug name.
///
/// Two callers read it and they must agree exactly:
///
///  - the settings editor / coordinator build the vocabulary the
///    `.medicationPhoto` keyword rule matches against, and
///  - the router resolves the key that rule returned back to the entries
///    carrying it.
///
/// Both go through `voiceKeys(for:)`, so a key can only ever be resolved by
/// the same derivation that produced it.
enum MedicationVoiceVocabulary {

    /// Lowercase + interior-whitespace collapse — the canonicalization the
    /// router applies to a transcript and `KeywordIntentRule` applies to
    /// its own keyword groups. Mirrored here so a key handed to the rule
    /// comes back byte-identical to the key the schedule holds.
    static func canonical(_ raw: String) -> String {
        raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Every key the entry answers to: its NAME first — the string the
    /// elder is likeliest to say — then whatever its purpose covers.
    /// Canonical, deduplicated, empty strings dropped; order is stable so
    /// the FIRST key that matches a transcript is deterministic.
    static func voiceKeys(for entry: MedicationEntry) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for raw in [entry.medicationName] + purposeKeys(forStored: entry.purpose) {
            let key = canonical(raw)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }

    /// The purpose half of the vocabulary: a chip contributes its keyword
    /// list (both languages), free text is its own single key. Empty text
    /// contributes nothing — a medicine with no purpose is still askable by
    /// name.
    static func purposeKeys(forStored value: String?) -> [String] {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let chip = MedicationPurpose.chip(forStored: trimmed) { return chip.voiceKeys }
        return [trimmed]
    }
}

// MARK: - The editor's purpose step

/// [MED-PURPOSE] (2026-09-17) The settings editor's purpose step as a
/// value: which chip is picked, what the free-text field holds, and — the
/// part with rules in it — what the entry should STORE.
///
/// The design's contract in one sentence: chips PRE-FILL the field, free
/// text OVERRIDES. So the stored value is the chip's id while the field
/// still reads as that chip's label, the typed words as soon as they
/// differ, and nil when the field is empty. A draft type rather than two
/// `@State` properties because this is the half of the step a test can
/// pin: the view only moves values in and reads the result out.
struct MedicationPurposeDraft: Equatable {
    /// The chip the family tapped, while the field still reads as it.
    private(set) var chip: MedicationPurpose?
    /// What the free-text field shows — the chip's label after a tap, the
    /// caregiver's own words once they type.
    private(set) var text: String
    /// The exact label the selected chip wrote into the field, so "free
    /// text overrides" is decided by comparison and not by ordering.
    private var chipLabel: String?

    init() {
        chip = nil
        text = ""
        chipLabel = nil
    }

    /// A chip was tapped: it becomes the selection and pre-fills the field.
    mutating func select(_ chip: MedicationPurpose, locale: Locale) {
        let label = chip.label(locale: locale)
        self.chip = chip
        chipLabel = label
        text = label
    }

    /// The free-text field was edited. Any divergence from what the chip
    /// pre-filled — including clearing the field — ends the chip's claim
    /// on the value: what the family typed is what they meant.
    mutating func editText(_ newValue: String) {
        text = newValue
        if newValue != chipLabel { chip = nil }
    }

    /// What `AppCoordinator.addMedication` stores: the chip's id, the
    /// caregiver's own words, or nil when nothing was chosen (an entry
    /// without a purpose is the pre-feature shape and stays valid).
    var storedValue: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let chip, let chipLabel, trimmed == chipLabel { return chip.rawValue }
        return trimmed
    }
}
