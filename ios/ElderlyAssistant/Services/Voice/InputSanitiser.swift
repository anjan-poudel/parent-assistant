import Foundation

/// Input sanitisation before every LLM call (constitution NFR-013, review
/// H3, spec §5.2 — `sanitise(.quarantine)`).
///
/// Quarantine level (the only level today):
///  - strips control characters (keeps whitespace),
///  - collapses repeated whitespace,
///  - clamps length to `maxLength` (short transcripts; protects the LLM's
///    1024-token context window),
///  - drops known prompt-injection markers so a transcript can't re-role
///    the system prompt.
///
/// Pure and deterministic — unit-tested against the golden corpus's
/// adversarial entries.
enum InputSanitiser {

    enum Level {
        case quarantine
    }

    static let maxLength = 200

    /// Known injection markers removed from transcripts before they reach
    /// the prompt. English and transliterated variants only — Devanagari
    /// medication names must pass through untouched.
    private static let injectionMarkers: [String] = [
        "ignore previous instructions",
        "ignore all instructions",
        "disregard your instructions",
        "you are now",
        "system:",
        "<|system|>",
        "<|begin_of_text|>",
        "<|start_header_id|>",
        "<|end_header_id|>",
        "<|eot_id|>",
        "act as",
        "pretend to be"
    ]

    static func sanitise(_ raw: String, level: Level = .quarantine) -> String {
        switch level {
        case .quarantine:
            var text = raw
            // 1. Control characters → spaces (dropping them outright would
            // fuse the words on either side and change meaning);
            // whitespace stays as-is for the collapse step.
            text = text.unicodeScalars.map { scalar -> String in
                let value = scalar.value
                if value >= 0x20 || scalar == "\n" || scalar == "\t" {
                    return String(scalar)
                }
                return " "
            }.joined()
            // 2. Collapse repeated whitespace.
            text = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            // 3. Drop injection markers (case-insensitive).
            for marker in injectionMarkers {
                text = text.replacingOccurrences(
                    of: marker,
                    with: "",
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            }
            // 4. Clamp length.
            if text.count > maxLength {
                text = String(text.prefix(maxLength))
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
