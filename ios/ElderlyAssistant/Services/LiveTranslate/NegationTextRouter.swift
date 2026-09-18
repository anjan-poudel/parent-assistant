import Foundation

// [NEGATION-ROUTER] (owner decision, 2026-09-19) — the source-side negation
// router.
//
// The decision, in one sentence: **test the standard-class quant on positive
// scenes, and never let a negation-bearing source string be answered by the
// local tier.**
//
// The measured fact behind it. The r2b Q5_K_M build — the 1.17 GB quant that
// fits a standard phone — scores 85.3% usable on the held-out eval, and two of
// its failures are probe rows that are negation-bearing safety instructions:
// "Do not store the medicine in the bathroom" came back as the positive
// instruction. A wrong translation of a positive sign is a bad translation; a
// wrong translation of a negation is the *opposite instruction*, and the elder
// acts on it. The published tier head (Q8_0) scored zero polarity failures, but
// the tier also runs the intent-brain fallbacks on a device that holds one, and
// the owner wants the positive-scene measurement to be safe by construction
// rather than by which artifact happens to be on disk.
//
// So the negation decision is taken **on the source text, before the tier is
// asked**, by a classifier with no model, no state, no I/O and no clock. What
// it buys is that the tier's polarity weakness cannot be reached by a string
// that carries a negation: those strings are left to the cloud, which is the
// tier that is measured on them.
//
// **The bias is the safe one, and it is stated as a rule rather than a hope.**
// A false positive — a positive string routed away — costs one cloud call on a
// string the device could have answered. A false negative — a negation
// answered locally — costs the elder a wrong safety instruction. The two are
// not comparable, so anything that looks like a negation routes away: the
// marker tables below deliberately include shapes whose reading is *usually*
// harmless ("no" as a determiner in "no signal"), and the classifier is
// deliberately not scope-aware (a "not" anywhere in the sentence routes the
// whole sentence).
//
// What it is NOT, said plainly so the claim is not read as wider than it is:
//
//   - **Not a polarity classifier.** It keys on negation. Opposite-action
//     verbs ("stop"/"start", "on"/"off", "unplug"/"plug") and warning labels
//     ("Hot surface", "Caution") are outside its scope: a mistranslated
//     opposite action is the same hazard class as a mistranslated negation, and
//     this component does not claim to catch it. The owner's decision named
//     negation, and the honest scope of the router is exactly that.
//   - **Not scope-aware.** "Clean the filter if the light is not on" routes
//     away because of "not", though the prohibition governs nothing. That is
//     the safe direction and it is intentional.
//   - **Not a translator, and not a gate on output.** It never sees a
//     translation and never judges one; `NepaliOutputGate` remains the rule
//     that decides whether an *answer* may settle a region.
//   - **Not a content channel.** Nothing here is logged. The one event the
//     routing produces (`brain_negation_routed`) carries counts, and the
//     marker that fired is for tests and for a reader, never for the log
//     surface — the same rule every other source-side string lives under
//     (NFR-LCT-006).
//
// Where it runs: the pipeline's per-string dispatch (see
// `LiveTranslationPipeline.dispatchResolutionNeeds`), which is the tier's only
// production caller — so a routed string is not merely unanswered by the local
// tier, it is never handed to it. A string the curated dictionary or the
// persisted cache already answered never reaches the dispatch at all, which is
// what keeps a curated translation authoritative (tier 0 is reviewed Nepali;
// the router does not get to second-guess it).

/// The source-side negation router (owner decision, 2026-09-19).
///
/// Pure by construction: static functions over a `String`, no instance state,
/// no configuration of its own. `LiveTranslateConfig.negationRouterEnabled`
/// is read by the *call site* rather than here, so this type stays a decision
/// about a string and nothing else — which is what makes it unit-testable
/// without a configuration, a bus or a model.
enum NegationTextRouter {

    // MARK: The curated marker tables

    /// Negation words, matched as **whole tokens** (trimmed, case-folded).
    ///
    /// Whole tokens rather than substrings, because the substring reading is
    /// how a router becomes wrong in the unsafe direction and noisy in the
    /// safe one at the same time: "note", "notice", "nothing", "normal",
    /// "north" and "Nos." all contain a marker's letters and none of them is a
    /// negation — and "note" is a curated dictionary key (`नोट`), so a
    /// substring rule would route a reviewed tier-0 translation away from a
    /// tier that never sees it in the first place. The token rule is pinned by
    /// `NegationTextRouterTests.testAWordThatMerelyContainsAMarkerIsNotNegation`.
    ///
    /// Each entry is here for a shape that actually reaches this feature (sign
    /// text, a medicine label, a manual's warning line), and the probe row the
    /// owner's decision came from is spelled out under the entry that catches
    /// it.
    static let negationWords: Set<String> = [
        // "Do not store the medicine in the bathroom" — THE probe row, and the
        // reason there is a router at all. Every "do not" / "does not" / "must
        // not" / "should not" / "do not use if" / "not for" / "not … while" /
        // "not … until" shape in the eval set is this token plus words the
        // table has no reason to name, so they are not re-listed below: one
        // rule, one home. "Not" is also the token that makes the phrase table
        // small — see its comment.
        "not",
        // "No entry", "No open flame", "No water". The negative determiner.
        // Also the marker with the highest false-positive rate ("no signal",
        // "No. 5") and kept anyway: the cost of a false positive is a cloud
        // call, and the cost of the false negative is a prohibition read as an
        // instruction.
        "no",
        // "Never put water in the oil", "Never run the microwave empty" — the
        // absolute prohibition, the strongest negation the source language has
        // and one a 4B model can drop silently (it is a single word with no
        // "not" to hold on to).
        "never",
        // "Use without water" — the elided negation. The "not" is not there to
        // be found, and the string inverts to "use with water" if the model
        // reads it as a plain preposition.
        "without",
        // "Avoid contact with eyes", "Avoid direct sunlight" — a prohibition
        // that carries no negative particle at all.
        "avoid",
        // "Cannot" (and the "can not" spelling, which is the "not" token).
        // "Can't" is the contraction rule's.
        "cannot",
        // The negative connectives and pronouns: "neither … nor", "none of the
        // vents", "nor", "nothing". Rare on a sign and cheap to carry.
        "nor", "none", "neither",
        // "Nothing on top of the microwave", "Nothing should block the vent" —
        // a prohibition with a negative pronoun for a subject. It reads as an
        // instruction to place something there once the negative is dropped,
        // which is the polarity failure class this router exists to keep off
        // the device. The token is whole, so "note" and "notice" are not this
        // word (the token rule's test pins that).
        "nothing",
        // The negative-polarity adjectives of a safety predicate: "unsafe with
        // pacemakers", "unsuitable for children". They are the same statement
        // as "not safe" / "not suitable", which the token table already
        // routes, and they are what a warning line reaches for when it is
        // short. **Not a general "un-" rule** — "under", "unit", "until" and
        // "unplug" all open with the same two letters. "Unplug before cleaning"
        // is an *opposite action*, not a negation, and is out of this table's
        // scope on purpose (see the file header).
        "unsafe", "unsuitable"
    ]

    /// The negation spelled as a contraction, as a **rule over the token**.
    ///
    /// Any token ending in this suffix is a negation: "don't", "doesn't",
    /// "didn't", "isn't", "aren't", "wasn't", "weren't", "can't", "won't",
    /// "shouldn't", "mustn't", "hasn't", "haven't". Listing the spellings
    /// instead would invite exactly one of them being missed, and the class is
    /// closed — no English word ends in "n't" that is not a negation — so the
    /// rule is the suffix. The apostrophe is folded before matching
    /// (`normalised`), because recognition and print both produce the
    /// typographic form: a router that only knew "don't" would miss "don’t",
    /// which is the same negation with a different code point.
    ///
    /// "Must not" and "should not" arrive here only when they are written as
    /// contractions; spelled out, they are the "not" token.
    static let negationContractionSuffix = "n't"

    /// Prohibition **phrases** whose words contain no negation marker at all.
    ///
    /// This is the table the token rules cannot replace: each of these is a
    /// complete prohibition with no "not", "no" or "never" in it, so a router
    /// built only on negation words would let every one of them through to the
    /// local tier. "Keep away from children" is the shape the owner's decision
    /// names by example, and it is the *second* probe class the eval set
    /// carries: a storage instruction whose polarity lives entirely in a
    /// preposition.
    ///
    /// Phrases are matched against the token stream joined by single spaces and
    /// padded with spaces, so punctuation between the words ("keep away, not
    /// near") and line breaks do not defeat the match, and so a phrase can
    /// never match inside a longer word.
    ///
    /// "Do not heat", "must not touch" and "don't use if" are deliberately NOT
    /// in this table: their polarity is the token table's and the contraction
    /// rule's, and a second spelling of the same rule is a second place for it
    /// to drift out of step.
    static let prohibitionPhrases: [String] = [
        // "Keep away from children", "Stay away from the edge" — and, with the
        // words in the other order, "Store away from heat". Proximity is the
        // whole instruction; there is no particle to find.
        "away from",
        // "Keep away!" with nothing after it. A covered case of the phrase
        // above, listed because a bare "keep away" is a complete line on a
        // label and the pair reads as one rule to a reviewer.
        "keep away",
        // "Keep out of reach of children" — the child-safety formula, whose
        // first half has no negation.
        "keep out",
        // The same formula in the other word order: "Store out of reach of
        // children".
        "out of reach"
    ]

    // MARK: Matching

    /// Which table matched, and the entry that did.
    ///
    /// For tests and for a reader: a test that pins "this sentence routes"
    /// cannot tell a marker that fired from a marker that was renamed, and the
    /// curated tables are only load-bearing if every entry can be observed
    /// firing (`NegationTextRouterTests.testEveryCuratedMarkerIsExercised`).
    ///
    /// Never a log value. The entry is one of this file's own constants, so it
    /// is not user content — but it is not a token the observability schema
    /// declares either, and the routing's own event carries counts only.
    enum Marker: Equatable {
        /// A whole word from `negationWords`.
        case word(String)
        /// A token ending in `negationContractionSuffix`.
        case contraction(String)
        /// A phrase from `prohibitionPhrases`.
        case phrase(String)

        /// The entry's spelling, for a test's failure message.
        var spelling: String {
            switch self {
            case .word(let entry), .contraction(let entry), .phrase(let entry):
                return entry
            }
        }
    }

    /// The first marker in `text`, or nil when the text carries none.
    ///
    /// Deterministic and stable: whole tokens in the order they appear, then
    /// the phrase table in its declared order. The order is a convenience for
    /// a reader, not a precedence — the answer this function exists for is the
    /// boolean below, and any marker is enough of one.
    static func match(in text: String) -> Marker? {
        let tokens = words(in: text)
        for token in tokens {
            if negationWords.contains(token) { return .word(token) }
            if token.hasSuffix(negationContractionSuffix) { return .contraction(token) }
        }
        let joined = " " + tokens.joined(separator: " ") + " "
        for phrase in prohibitionPhrases where joined.contains(" " + phrase + " ") {
            return .phrase(phrase)
        }
        return nil
    }

    /// Whether the local tier must not be asked about this string.
    ///
    /// The one call the dispatch makes. Reading it as "is this string
    /// negative" is the misreading the file header warns about: it is "may
    /// this string be answered on the device", and it answers `true` for
    /// anything that might be a negation.
    static func routesAway(_ text: String) -> Bool {
        match(in: text) != nil
    }

    /// One dispatch's strings, split into the ones the local tier may be asked
    /// about and the ones the next tier takes.
    ///
    /// Both halves keep the caller's order, so the batch the local tier
    /// receives is still the scene's own order and the first-N bound stays
    /// deterministic (the pipeline's rule for the batch it builds by walking
    /// the visible regions). Nothing is dropped: `local + routed` is the input
    /// as a set and, within each half, as a sequence.
    static func partition(_ texts: [String]) -> Partition {
        var local: [String] = []
        var routed: [String] = []
        for text in texts {
            if routesAway(text) {
                routed.append(text)
            } else {
                local.append(text)
            }
        }
        return Partition(local: local, routed: routed)
    }

    /// The two halves of one dispatch, in the caller's order within each.
    struct Partition: Equatable {
        /// The strings the local tier may be asked about.
        let local: [String]
        /// The strings the negation router keeps away from it — for the next
        /// tier, and counted on `brain_negation_routed`.
        let routed: [String]
    }

    // MARK: Tokenising

    /// `text`, lower-cased and with every apostrophe spelling folded onto the
    /// ASCII one.
    ///
    /// The fold is the half of normalisation that matters here: "don’t" with
    /// U+2019 and "don't" with U+0027 are the same word to a reader and two
    /// different strings to a matcher, and the typographic form is what
    /// recognition and print produce. The other look-alikes (the backtick and
    /// the acute accent) are folded with it — no negation is spelled with them,
    /// so folding them can only make the match happen.
    static func normalised(_ text: String) -> String {
        var folded = text.lowercased()
        for apostrophe in ["\u{2019}", "\u{2018}", "\u{201B}", "`", "\u{00B4}"] {
            folded = folded.replacingOccurrences(of: apostrophe, with: "'")
        }
        return folded
    }

    /// The words of `text`, in order.
    ///
    /// A letter-or-digit run with apostrophes kept inside it, so "don't" is one
    /// token (the contraction rule needs it whole) and punctuation, digits-only
    /// separators, hyphens and line breaks split everything else. Hyphens split
    /// on purpose: "not-hot" and "do-not" are spellings a label or a
    /// recognition pass can produce, and splitting them finds the marker that
    /// the compound hid.
    ///
    /// A non-Latin script produces its own tokens and matches nothing here —
    /// including Devanagari, which is a *source* possibility but not one this
    /// feature's recognition language produces (the vision runtime reads
    /// English scene text). Those strings keep the behaviour they had before
    /// this router existed.
    static func words(in text: String) -> [String] {
        normalised(text)
            .components(separatedBy: wordSeparators)
            .filter { !$0.isEmpty }
    }

    /// Everything that is not part of a word: not a letter, not a decimal
    /// digit, not an apostrophe. Built once.
    private static let wordSeparators: CharacterSet = {
        var allowed = CharacterSet.letters
        allowed.formUnion(CharacterSet.decimalDigits)
        allowed.insert("'")
        return allowed.inverted
    }()
}
