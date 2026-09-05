import Foundation

/// Shared text normalization for Nepali + English mixed input — the single
/// normalization used by the intent cache (key generation) and the contact
/// resolver (both sides of a match), so "same utterance" means the same
/// thing everywhere (spec 2026-09-05 §4.2 key design).
///
/// What it does:
///  - NFC canonical form (Devanagari has multiple valid byte sequences for
///    the same visible text; STT output is not consistent)
///  - Devanagari digits folded to ASCII ("८" -> "8")
///  - lowercased (Latin only; Devanagari has no case)
///  - punctuation stripped, INCLUDING the Devanagari danda "।" and the
///    double danda "॥" (CharacterSet.punctuationCharacters misses danda)
///  - whitespace collapsed + trimmed
///
/// What it deliberately does NOT do (v1):
///  - No Devanagari<->Latin transliteration. Folding "माइया" and "maiya"
///    onto one key needs a transliterator, and a lossy one turns "maiya"
///    and "maya" (different people) into the same key — the exact hazard
///    spec §4.2 calls out for fuzzy matching. Exact-match-only in v1
///    keeps the cache honest; transliteration is a v2 consideration with
///    the same conservative-threshold discussion.
enum NepaliTextNormalizer {

    private static let devanagariDigits: [Character: Character] = [
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
        "५": "5", "६": "6", "७": "7", "८": "8", "९": "9"
    ]

    /// Extra punctuation the system set misses: danda + double danda.
    private static let extraStrippedScalars = CharacterSet(charactersIn: "।॥")

    static func normalize(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        let digitsFolded = String(nfc.map { devanagariDigits[$0] ?? $0 })
        let lowered = digitsFolded.lowercased()

        var scalars = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars
        where !CharacterSet.punctuationCharacters.contains(scalar)
            && !extraStrippedScalars.contains(scalar) {
            scalars.append(scalar)
        }
        let noPunctuation = String(scalars)
        return noPunctuation
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Honorific tokens stripped as a SECOND, optional step — never folded
    /// into `normalize` itself, because "जी" can be part of an actual name
    /// and stripping must be a match-time choice, not a storage-time one.
    /// Covers the common address suffixes: ज्यू (jyu), जी (ji).
    private static let honorificTokens: Set<String> = [
        "ज्यू", "जी", "jyū", "jyu", "jiu", "jee", "ji"
    ]

    static func strippingHonorifics(_ normalized: String) -> String {
        normalized
            .split(separator: " ")
            .map(String.init)
            .filter { !honorificTokens.contains($0) }
            .joined(separator: " ")
    }
}
