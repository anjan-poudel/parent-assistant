import Foundation

// MARK: - Time-slot provenance guard (intent root fixes, 2026-09-17)

/// The one check that keeps a HALLUCINATED time out of a reminder or a
/// calendar event.
///
/// Root problem this exists for: the local interpreter committed to
/// `set_reminder` for "दशैँ कहिले हो" (a date question with no time in
/// it), then FABRICATED a time slot — "बिहान १०:३०" — that parsed
/// cleanly and was spoken back as a confirmed reminder. Every downstream
/// check passed because the invented time was syntactically perfect;
/// nothing compared it to what the elder actually said.
///
/// The guard therefore asks one question: did the transcript contain ANY
/// time material at all? When it did not, the model's time cannot have
/// come from the utterance — it is an invention, and the caller must
/// treat the time as missing (the honest "what time?" line) instead of
/// confirming a slot nobody asked for.
///
/// Deliberately PERMISSIVE, not an exact matcher: "आधा घण्टामा सम्झाऊ"
/// passes because it contains time words even though the model's parsed
/// time shares no digits with it — an exact match would reject real
/// utterances. The guard only ever catches the clear case: a transcript
/// with zero time material and a model slot full of time.
enum TimeSlotProvenance {

    /// Time-material words: explicit clock/calendar vocabulary in both
    /// languages. Question words ("कहिले", "when") are deliberately NOT
    /// here — asking when something happens is not saying a time.
    private static let timeWords: Set<String> = [
        // Nepali clock words
        "बजे", "बजेर", "घण्टा", "घण्टामा", "मिनेट", "आधा", "पौने", "सवा",
        "बिहान", "दिउँसो", "बेलुका", "साँझ", "राति", "आज", "भोलि", "पर्सि",
        // English clock words
        "am", "pm", "morning", "afternoon", "evening", "night", "today",
        "tomorrow", "o'clock", "oclock", "hour", "hours", "minute", "minutes",
    ]

    private static let digitCharacters = CharacterSet.decimalDigits

    /// True when `raw` contains enough time material that a model time
    /// COULD have been extracted from it: any digit run, or any time
    /// word. False = the transcript carried no time at all, so a
    /// non-empty `time` slot is an invention.
    static func containsTimeMaterial(_ raw: String) -> Bool {
        let canonical = raw.lowercased()
        guard !canonical.unicodeScalars.contains(where: {
            digitCharacters.contains($0)
        }) else { return true }
        let tokens = canonical.split(whereSeparator: {
            $0.isWhitespace || $0.isPunctuation
        }).map(String.init)
        return tokens.contains { timeWords.contains($0) }
    }

    /// Whether a model-extracted `time` slot is defensible given the raw
    /// transcript. Empty time is the caller's existing missing-time path;
    /// a non-empty time over a transcript with no time material is a
    /// fabrication.
    static func timeSlotIsDefensible(raw: String, time: String?) -> Bool {
        guard let time, !time.isEmpty else { return true }
        return containsTimeMaterial(raw)
    }
}
