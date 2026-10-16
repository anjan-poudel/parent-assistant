import Foundation

/// [RELIABILITY-ROUTER] Which tier LEADS for a piece of text.
///
/// The cascade has always led with the on-device brain and handed the brain's
/// misses to the cloud. That order is right for the strings the on-device
/// model is proven on and wrong for the ones it is not, and the rounds'
/// safety-probe data is what says which is which:
///
///   · The gate rows that are short labels, menu items and pharma terms — a
///     few words, no clause structure — came back exact on every quant in
///     every round, with zero polarity failures.
///   · The rows where a quant did fail (round 2b's S02, and that checkpoint's
///     Q5 export) are full sentences: what the failure attaches to is a
///     clause the model has to hold together, not a token.
///
/// So the boundary this router draws is SHAPE — "is this within the size the
/// model is measured on" — and deliberately NOT content. In particular it does
/// not test for negation, which is the failure MODE rather than the class: a
/// negation-keyed router sends "Do not take with alcohol" somewhere else
/// because of a word, waves through "Avoid taking with alcohol" because the
/// word is missing, and answers a question about vocabulary when the gate's
/// evidence is about sentence structure.
///
/// Pure and synchronous on purpose: this is the part of routing that can be
/// tested exhaustively with no device, no network and no model.
enum TranslationReliabilityRouter {

    /// What kind of text this is, in the only terms the gate evidence speaks.
    enum TextClass: Equatable {
        /// A short label, menu item or pharma term — the shape every passing
        /// probe row has, and the only class the on-device model is proven on.
        case provenShortForm
        /// A sentence, an instruction, or any prose with clause structure —
        /// the class the cloud leads for whenever the cloud can answer.
        case sentence
    }

    /// The tier that leads for a class of text.
    enum LeadingTier: Equatable {
        /// The on-device brain translates first; the cloud takes what is left.
        case onDevice
        /// The cloud translates first; the brain takes what is left.
        case cloud
    }

    // MARK: - The bounds

    /// The widest word count still treated as a label. Four is the widest
    /// passing probe row: menu items ("Add contact", "Mobile data") and pharma
    /// lines ("Take one tablet daily") are inside it, while the sentences that
    /// failed carry a clause and run past it.
    ///
    /// A bound rather than a vocabulary: the curated dictionary already answers
    /// the strings it knows, and a router that only trusted listed words would
    /// route every unlisted label — the new medicine, the shop sign — to the
    /// cloud, which is backwards for the class the device is best at.
    static let maxProvenWords = 4

    /// The longest character count still treated as a label. Word count alone
    /// would call one long OCR token a label, so the character bound backs it
    /// up: a single unbroken run of 40+ characters is exactly the shape where
    /// recognition noise, not language, decides the answer.
    static let maxProvenCharacters = 40

    /// Punctuation that marks a clause rather than a label. A label does not
    /// end in a full stop and does not carry a clause separator; a line that
    /// does is a sentence however few words it uses.
    ///
    /// The Devanagari danda (`।`, U+0964) and double danda (`॥`, U+0965) are
    /// here because they are the full stop of the target script: a Nepali sign
    /// line ends with one, and the rest of the app already treats them as
    /// sentence stops (`NepaliOutputGate`, `NepaliTextNormalizer`) rather than
    /// as ordinary characters. Without them a Devanagari clause was classified
    /// as a proven short form on its word count alone and settled on the tier
    /// that is not proven on sentences.
    private static let clausePunctuation: [Character] = [".", "!", "?", ";", ":", "—", "–", "।", "॥"]

    // MARK: - The decision

    /// Which class `text` belongs to.
    ///
    /// Ambiguity resolves to `.sentence`, and that direction is the point: the
    /// requirement is that on-device answers SETTLE only for the classes the
    /// model is proven on, so the default has to be "not proven". A label
    /// misread as a sentence costs a cloud attempt that the label would have
    /// gotten anyway on the tick after the brain missed it; a sentence misread
    /// as a label settles on the tier that failed it.
    static func classify(_ text: String) -> TextClass {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .sentence }
        // A region's text can span lines; a block is never a single label.
        guard !trimmed.contains(where: \.isNewline) else { return .sentence }
        guard trimmed.count <= maxProvenCharacters else { return .sentence }
        guard LiveOverlayPlacement.wordCount(trimmed) <= maxProvenWords else { return .sentence }
        guard !trimmed.contains(where: { clausePunctuation.contains($0) }) else { return .sentence }
        return .provenShortForm
    }

    /// The tier that leads for `text`, given whether the cloud can answer at
    /// all right now.
    ///
    /// `cloudAvailable` is the CALLER's answer to "there is a network path and
    /// the household switch is on". This type does not ask the network itself:
    /// a pure decision that reached for a monitor would be untestable, and it
    /// would be answering a question it does not own (consent, the switch and
    /// the budget are the gate's).
    ///
    /// When the cloud cannot answer, EVERY class leads with the device. That
    /// guard is what makes the router safe to wire in ahead of the gate: it
    /// must never trade a translation the device can produce for one the
    /// network cannot, so the cloud-first order is only ever taken when the
    /// cloud is actually able to take it.
    static func leadingTier(for text: String, cloudAvailable: Bool) -> LeadingTier {
        guard cloudAvailable else { return .onDevice }
        return classify(text) == .sentence ? .cloud : .onDevice
    }
}
