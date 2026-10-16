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
    ///
    /// **PROHIBITION (AM-3 / CL-6): do not copy this table — or any part of
    /// it — into another file.** The live camera translation feature's
    /// scene-text path must ask `containsInjectionMarker(_:)` /
    /// `markerMatches(in:)` below instead. A second copy would let that
    /// path's policy drift away from the project's configured quarantine
    /// level, which is the contract this table *is*. The table stays
    /// `private` for exactly that reason; the two accessors are the only
    /// seam, and a source-level test fails if a copy appears under
    /// `Services/LiveTranslate/`.
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

    // MARK: - Detect-only seam (T-004, AM-3, CL-6)

    /// Detects marker shapes **without removing them**, single-sourced from
    /// the table above — the shipped function removes markers (that is the
    /// quarantine-level action for transcripts); the scene-text path
    /// (`SceneTextSanitiser`, C07) needs to know whether a string *still*
    /// carries one after sanitisation, and it must not carry a copy of the
    /// table to find out.
    ///
    /// Additive by construction: `sanitise(_:level:)` is untouched, and
    /// these accessors change nothing it does.
    ///
    /// Usage on the scene-text path is **strip, then detect**: call
    /// `sanitise` first, then ask this about the result. A residual match is
    /// the quarantine trigger (T-017). Calling it on the raw input answers a
    /// different question — "would the transcript path strip something?" —
    /// which is what the transcript call site compares against.
    ///
    /// Matching is case- and diacritic-insensitive, exactly as `sanitise`'s
    /// removal is, so the two cannot disagree about what a marker is.
    static func markerMatches(in text: String) -> [String] {
        injectionMarkers.filter { marker in
            text.range(of: marker,
                       options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Whether `text` still carries a marker shape (see `markerMatches(in:)`).
    static func containsInjectionMarker(_ text: String) -> Bool {
        for marker in injectionMarkers where
            text.range(of: marker,
                       options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        return false
    }
}
