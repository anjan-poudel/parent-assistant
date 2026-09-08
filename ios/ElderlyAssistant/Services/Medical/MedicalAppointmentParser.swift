import Foundation

/// Parses appointment text — a pasted confirmation SMS or a future
/// voice phrase — into an `MedicalAppointment`-shaped draft
/// (medical task + SMS-confirmation scope extension, 2026-09-07).
///
/// English example it must handle:
///     "hi joe, this is to confirm you have appointment with Dr Jane
///      tomorrow at 2.30pm at Xyz medical centre"
///     → doctorOrPlace "Dr Jane", place "Xyz medical centre",
///       date = tomorrow 14:30 (relative to the injected `now`).
///
/// Nepali example (same clock):
///     "डा. जेनसँग भोलि २:३० बजे Xyz मेडिकल सेन्टरमा भेट छ"
///     → doctorOrPlace "डा. जेन", place "Xyz मेडिकल सेन्टर",
///       date = tomorrow 14:30.
///
/// Date/time vocabulary deliberately mirrors `NepaliTimeParser`
/// (Services/Voice/NepaliTimeParser.swift) — the day words
/// (आज/भोलि/पर्सि, today/tomorrow/day after tomorrow), weekday names
/// (आइतबार…शनिबार, sunday…saturday) and the `normalise()` digit/letter
/// folding are reused verbatim; the tables below are mirrored (with
/// attribution) because `NepaliTimeParser` reads the CURRENT date from
/// `Date()` and cannot take an injected `now`/`calendar`, which this
/// parser must for deterministic tests. See `resolveDate` for the full
/// fallback ladder.
///
/// Text WITHOUT an appointment marker ("appointment"/"appt"/"भेट") or
/// without ANY date/time signal returns nil — so a stray "confirm your
/// appointment" line is never saved as something. A marker with neither
/// day nor time also returns nil: the Medical leaf's voice phrase "add a
/// doctor appointment" hits exactly that branch, which is the intended
/// hook the voice integration uses to OPEN the add form instead of
/// saving (see the CommandRouter note at the bottom).
///
/// Everything this parser produces is a DRAFT: the caller must show it
/// for confirmation before saving (the paste button does; a future
/// voice route must do the same).
enum MedicalAppointmentParser {

    /// What `parse` extracted — enough to pre-fill the add form or save
    /// straight through `AppointmentStore` after confirmation.
    struct ParsedAppointment: Equatable {
        /// Doctor's name when the text names one ("डा. जेन"/"Dr Jane"),
        /// else the venue when the text names a venue, else the honest
        /// default "डाक्टर"/"Doctor".
        var doctorOrPlace: String
        /// Venue when the text names a venue SEPARATELY from the doctor;
        /// nil otherwise (a venue-only message folds the venue into
        /// `doctorOrPlace`).
        var place: String?
        /// Resolved appointment date; seconds zeroed.
        var date: Date
    }

    // MARK: - Public entry point

    /// Parses appointment text. `now` and `calendar` are injectable so
    /// tests are deterministic; production callers use the defaults.
    static func parse(_ raw: String,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> ParsedAppointment? {
        let text = normalise(raw)
        guard !text.isEmpty else { return nil }
        guard containsAppointmentMarker(text) else { return nil }

        // One date/time signal is required: a clock time, a relative day
        // word, or a weekday name. Marker-only text ("…appointment is
        // confirmed…") yields nil — see the file doc.
        let dayOffset = relativeDayOffset(in: text)
        let weekday = weekdayIndex(in: text)
        let time = findTime(in: text)
        guard time != nil || dayOffset != nil || weekday != nil else { return nil }

        let isNepali = containsDevanagari(text)
        let doctorName = extractDoctorName(from: text)
        let place = extractPlace(from: text, after: time, isNepali: isNepali)

        let doctorOrPlace: String
        var finalPlace: String?
        // A separately-kept venue gets the same presentation capitalisation
        // as the label — `normalise` lowercased the whole SMS, so the
        // source's "Xyz …" must be restored here ("Xyz medical centre").
        if let doctorName, !doctorName.isEmpty {
            doctorOrPlace = capitaliseWords(doctorName)
            finalPlace = place.map(Self.capitaliseWords)
        } else if hasDoctorWord(text) {
            doctorOrPlace = isNepali ? "डाक्टर" : "Doctor"
            finalPlace = place.map(Self.capitaliseWords)
        } else if let place, !place.isEmpty {
            // Venue-only message ("…appointment tomorrow at 2.30pm at
            // Xyz medical centre"): the venue IS the appointment label.
            doctorOrPlace = capitaliseWords(place)
            finalPlace = nil
        } else {
            doctorOrPlace = isNepali ? "डाक्टर" : "Doctor"
            finalPlace = nil
        }

        guard let date = resolveDate(dayOffset: dayOffset, weekday: weekday,
                                     time: time, now: now, calendar: calendar) else {
            return nil
        }
        return ParsedAppointment(doctorOrPlace: doctorOrPlace,
                                 place: finalPlace,
                                 date: date)
    }

    // MARK: - Markers and script detection

    /// "appointment"/"appt" (English) or "भेट" (Nepali — the word any
    /// clinic SMS uses for a consultation). Substring matching mirrors
    /// `NepaliTimeParser`.
    private static func containsAppointmentMarker(_ text: String) -> Bool {
        text.contains("appointment") || text.contains("appt") || text.contains("भेट")
    }

    private static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// Reuses `NepaliTimeParser.normalise` — lowercases, trims, maps
    /// Devanagari digits to ASCII, unifies "॥" with ":".
    private static func normalise(_ raw: String) -> String {
        NepaliTimeParser.normalise(raw)
    }

    // MARK: - Day words and weekdays (mirrored from NepaliTimeParser)

    /// आज → 0, भोलि → 1, पर्सि → 2 (+ English). Mirrors
    /// `NepaliTimeParser.relativeDayOffset`; the longer English phrase
    /// is checked before "tomorrow" because "the day after tomorrow"
    /// CONTAINS it.
    private static func relativeDayOffset(in text: String) -> Int? {
        if text.contains("पर्सि") || text.contains("day after tomorrow") { return 2 }
        if text.contains("भोलि") || text.contains("tomorrow") { return 1 }
        if text.contains("आज") || text.contains("today") { return 0 }
        return nil
    }

    /// Nepali and English weekday names → 0=Sunday … 6=Saturday,
    /// mirroring `NepaliTimeParser.weekdays`.
    private static let weekdays: [(word: String, index: Int)] = [
        ("आइतबार", 0), ("सोमबार", 1), ("मंगलबार", 2), ("बुधबार", 3),
        ("बिहीबार", 4), ("शुक्रबार", 5), ("शनिबार", 6),
        ("sunday", 0), ("monday", 1), ("tuesday", 2), ("wednesday", 3),
        ("thursday", 4), ("friday", 5), ("saturday", 6)
    ]

    private static func weekdayIndex(in text: String) -> Int? {
        weekdays.first { text.contains($0.word) }?.index
    }

    // MARK: - Clock time ("2.30pm", "२:३० बजे", "3 pm", "at 3")

    private struct TimeSpan {
        let range: Range<String.Index>
        let hour: Int
        let minute: Int
    }

    /// Finds the first credible clock time in normalised text. Handles
    /// "2:30"/"2.30"/"2॥30" (normalise folds ॥→:), optional attached or
    /// spaced "am"/"pm", Nepali "N बजे", and a bare hour ("at 3") when
    /// followed by end-of-text, punctuation, "बजे" or "o'clock".
    ///
    /// Rejects digit runs that are NOT clock times: phone numbers/ids
    /// (runs over 2 digits), dates ("12/05", "9-5" — the whole group is
    /// skipped), hour 0, minutes past 59, and bare hours glued to
    /// letters ("3rd", "2p"). A decimal like "2.5" is rejected as a
    /// minute-less separator — only two-digit minutes after ":"/"."
    /// count, so "2.30pm" reads minutes 30 (the dot-minute reading
    /// NepaliTimeParser misses is intentional here).
    private static func findTime(in text: String) -> TimeSpan? {
        var cursor = text.startIndex
        let end = text.endIndex

        while cursor < end {
            guard text[cursor].isNumber else {
                text.formIndex(after: &cursor)
                continue
            }

            // Read the digit run.
            let runStart = cursor
            while cursor < end, text[cursor].isNumber {
                text.formIndex(after: &cursor)
            }
            let run = String(text[runStart..<cursor])
            guard (1...2).contains(run.count), let hour = Int(run) else { continue }
            guard hour > 0 else { continue }

            // "12/05" / "9-5" date-or-range groups: skip the whole group.
            if cursor < end, text[cursor] == "/" || text[cursor] == "-" {
                text.formIndex(after: &cursor)
                while cursor < end, text[cursor].isNumber {
                    text.formIndex(after: &cursor)
                }
                continue
            }

            var minute = 0
            /// Where the span ends for the venue cut: after the digits,
            /// extended over an attached suffix; for a SPACED am/pm the
            /// suffix word belongs to the clock too; for "बजे"/"o'clock"
            /// the span ends BEFORE the word so the Nepali venue logic
            /// can skip the clock word itself.
            var spanEnd = cursor

            // Optional ":MM" / ".MM" minutes (exactly two digits).
            if cursor < end, text[cursor] == ":" || text[cursor] == "." {
                let firstDigit = text.index(after: cursor)
                guard firstDigit < end, text[firstDigit].isNumber else { continue }
                let secondDigit = text.index(after: firstDigit)
                guard secondDigit < end, text[secondDigit].isNumber else { continue }
                let minuteDigits = String(text[firstDigit...secondDigit])
                guard let parsed = Int(minuteDigits), parsed <= 59 else { continue }
                minute = parsed
                cursor = text.index(after: secondDigit)
                spanEnd = cursor
            }

            // Attached "am"/"pm" — "2.30pm". A letter that is not am/pm
            // means the run is a word fragment ("3rd") — reject it.
            var isPM: Bool?
            if spanEnd < end, text[spanEnd].isLetter {
                let rest = text[spanEnd...]
                if rest.hasPrefix("pm") {
                    isPM = true
                    spanEnd = text.index(spanEnd, offsetBy: 2)
                } else if rest.hasPrefix("am") {
                    isPM = false
                    spanEnd = text.index(spanEnd, offsetBy: 2)
                } else {
                    continue
                }
            }

            // Spaced "am"/"pm"/"बजे"/"o'clock" — "at 3 pm", "३ बजे".
            // Any OTHER word after a bare hour ("6 hours", "30 day")
            // rejects the candidate.
            if isPM == nil, spanEnd < end, text[spanEnd].isWhitespace {
                let wordStart = text.index(after: spanEnd)
                if wordStart < end {
                    let wordEnd = text[wordStart...]
                        .firstIndex(where: { $0.isWhitespace }) ?? end
                    let word = String(text[wordStart..<wordEnd])
                        .trimmingCharacters(in: .punctuationCharacters)
                    if word == "pm" {
                        isPM = true
                        spanEnd = wordEnd
                    } else if word == "am" {
                        isPM = false
                        spanEnd = wordEnd
                    } else if word == "बजे" || word == "o'clock" || word == "oclock" {
                        // Bare hour with a clock word — accepted; the
                        // span stays BEFORE the word (venue logic skips
                        // "बजे" itself).
                    } else {
                        continue
                    }
                }
            }

            // 12-hour bookkeeping. Period words (बेलुका/साँझ/राति/
            // दिउँसो, and English "pm") force the afternoon shift like
            // NepaliTimeParser's; a bare hour 1–6 with NO morning word
            // and NO am/pm suffix gets the clinic-hours heuristic (an
            // afternoon "see you at 3" far outnumbers 3 a.m. in
            // appointment text) — documented fallback, and every parse
            // is confirmed before saving. An EXPLICIT "am" is never
            // shifted: "3am" stays 03:00.
            var pm = false
            if let isPM {
                pm = isPM
            } else if text.contains("बेलुका") || text.contains("साँझ")
                || text.contains("राति") || text.contains("दिउँसो") {
                pm = true
            }
            var finalHour = hour
            if hour == 12 {
                // Explicit "12am" is midnight; bare "12" and "12pm" are
                // noon (a bare twelve in appointment text is lunchtime,
                // not the middle of the night).
                if isPM == false { finalHour = 0 }
            } else if pm {
                finalHour = hour + 12
            } else if isPM == nil, hour <= 6, !text.contains("बिहान") {
                finalHour = hour + 12
            }
            guard finalHour <= 23 else { continue }

            return TimeSpan(range: runStart..<spanEnd,
                            hour: finalHour, minute: minute)
        }
        return nil
    }

    // MARK: - Doctor name ("with Dr Jane", "डा. जेनसँग")

    /// Doctor-name stop words for the Nepali branch, compared token-wise
    /// after possessive-suffix stripping: the name runs from the
    /// डा./डाक्टर token until one of these. Mirrors the NepaliTimeParser
    /// day/period vocabulary so "डा. जेनसँग भोलि …" stops at भोलि.
    private static let nepaliNameStopWords: Set<String> = [
        "आज", "भोलि", "पर्सि", "बिहान", "दिउँसो", "साँझ", "बेलुका",
        "राति", "बजे", "भेट", "भेटघाट", "छ", "हो", "हुन्छ", "हुनेछ",
        "तपाईं", "तपाई", "कृपया", "लाई", "को", "मा", "पछि",
        "सँग", "संग", "सँगै",
        "tomorrow", "today", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday"
    ]

    /// Boundary phrases that end an English doctor name ("with Dr Jane
    /// tomorrow at 2.30pm …" → "Dr Jane"). Weekday/day words and time
    /// connectors are the realistic endings; space-prefixed so "with"
    /// mid-word never cuts.
    private static let englishNameBoundaries = [
        " tomorrow", " today", " at ", " on ", " this ", " next ",
        " monday", " tuesday", " wednesday", " thursday", " friday",
        " saturday", " sunday", " please"
    ]

    /// Strips the Nepali possessive particle ("सँग"/"संग"/"सँगै") that
    /// clings to the name in "डा. जेनसँग" — the name itself is "डा. जेन".
    private static func strippingNepaliSuffix(from token: String) -> String {
        var stripped = token
        for suffix in ["सँगै", "सँग", "संग"] where stripped.hasSuffix(suffix) {
            stripped.removeLast(suffix.count)
            break
        }
        return stripped
    }

    private static func extractDoctorName(from text: String) -> String? {
        // Nepali branch: the डा./डाक्टर token and what follows until a
        // stop word ("डा. जेनसँग भोलि …", "डाक्टरसँग आज …"). Tokens are
        // stored WITHOUT the possessive particle — "जेनसँग" appends as
        // "जेन" — so the draft reads "डा. जेन", not "डा. जेनसँग".
        let allTokens = tokens(in: text)
        if let doctorIndex = allTokens.firstIndex(where: { $0.text.hasPrefix("डा") }) {
            var pieces: [String] = []
            for token in allTokens[doctorIndex...] {
                if pieces.count >= 4 { break }
                let stripped = strippingNepaliSuffix(from: token.text)
                if !pieces.isEmpty, nepaliNameStopWords.contains(stripped) { break }
                if !stripped.isEmpty {
                    // Canonical form keeps the abbreviation dot the SMS
                    // writes: "डा" is tokenised dot-less (punctuation is
                    // trimmed for comparisons), but the standard reading
                    // of the title is "डा.".
                    pieces.append(pieces.isEmpty && stripped == "डा"
                                  ? "डा." : stripped)
                }
            }
            let name = pieces.joined(separator: " ")
            if !name.isEmpty { return name }
        }

        // English branch: text after "with" — the FIRST "with" that is
        // its own word ("within", "withdraw" never count).
        var searchRange = text.startIndex..<text.endIndex
        var withRange: Range<String.Index>?
        while let found = text.range(of: "with", range: searchRange) {
            if found.lowerBound == text.startIndex {
                withRange = found
                break
            }
            let before = text.index(before: found.lowerBound)
            if text[before].isWhitespace {
                withRange = found
                break
            }
            searchRange = found.upperBound..<text.endIndex
        }
        guard let withRange else { return nil }

        var region = text[withRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else { return nil }

        // Cut at the earliest boundary phrase.
        var earliest = region.endIndex
        for boundary in englishNameBoundaries {
            if let found = region.range(of: boundary), found.lowerBound < earliest {
                earliest = found.lowerBound
            }
        }
        if earliest < region.endIndex {
            region = String(region[..<earliest])
        }
        region = region.trimmingCharacters(in: .punctuationCharacters)
        // Articles produce the generic "the doctor" — strip them.
        while region.hasPrefix("the ") || region.hasPrefix("a ")
            || region.hasPrefix("an ") {
            if let space = region.firstIndex(of: " ") {
                region = String(region[region.index(after: space)...])
            }
        }
        return region.isEmpty ? nil : region
    }

    /// Doctor-word evidence when no "with"/डा. phrase exists: an exact
    /// token "doctor"/"dr"/"dr."/"doc" ("…appointment with the doctor
    /// tomorrow…" minus the with-name case).
    private static func hasDoctorWord(_ text: String) -> Bool {
        tokens(in: text).contains { ["doctor", "dr", "dr.", "doc"].contains($0.text) }
    }

    // MARK: - Venue ("at Xyz medical centre", "Xyz मेडिकल सेन्टरमा")

    /// Tokens that open the Nepali venue region after the clock time
    /// ("२:३० बजे Xyz मेडिकल सेन्टरमा भेट छ" → skip बजे).
    private static let nepaliPlaceSkipWords: Set<String> = ["बजे", "बजेका", "बजेको"]
    /// Stop tokens that end the Nepali venue — the rest of the sentence
    /// ("भेट छ", "हुनेछ", politeness phrases) is not the venue.
    private static let nepaliPlaceStopWords: Set<String> = [
        "भेट", "भेटघाट", "छ", "हो", "हुन्छ", "हुनेछ", "गरिने", "रहेको",
        "तपाईं", "तपाई", "कृपया", "लाई", "नि", "है"
    ]

    /// Phrases that end the English venue region — what follows is
    /// sentence courtesy ("…centre. please bring your reports") or a
    /// doctor name written AFTER the clock ("…at 2.30pm with Dr Jane" —
    /// the name is not the venue), never the address.
    private static let englishPlaceBoundaries = [
        " please", " thanks", " kindly", " regards", " call us",
        " text us", " to confirm", " for your", " with "
    ]

    /// Venue text AFTER the clock time. Only positions after the time
    /// are read (both sample shapes put the venue after the clock); a
    /// venue written before the time is simply not captured — the
    /// caller's confirm step shows what WAS found. Returns nil when the
    /// tail holds no venue words.
    private static func extractPlace(from text: String, after time: TimeSpan?,
                                     isNepali: Bool) -> String? {
        guard let time else { return nil }
        // `tail` is a fresh String (trimmingCharacters copies), so every
        // token range below indexes TAIL — never `text`.
        let tail = String(text[time.range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }

        if isNepali {
            // Skip the clock word, then collect until a stop token. A
            // डा./डाक्टर token ends the region too — a doctor name
            // written AFTER the clock ("…२ बजे डा. जेनसँग भेट छ") is
            // the subject, not the venue.
            let tailTokens = tokens(in: tail)
            var kept: [Token] = []
            for token in tailTokens {
                if kept.isEmpty, nepaliPlaceSkipWords.contains(token.text) { continue }
                if token.text.hasPrefix("डा") { break }
                if nepaliPlaceStopWords.contains(token.text) { break }
                kept.append(token)
                if kept.count >= 6 { break }
            }
            guard !kept.isEmpty else { return nil }
            var place = kept.map { String(tail[$0.range]) }
                .joined(separator: " ")
                .trimmingCharacters(in: .punctuationCharacters)
            // Locative particle: "सेन्टरमा" → "सेन्टर".
            if place.hasSuffix("मा") { place.removeLast(1) }
            place = place.trimmingCharacters(in: .punctuationCharacters)
            return place.isEmpty ? nil : place
        }

        // English: strip connectors (", at ", "at ", "in ", "near "),
        // cut at the EARLIEST sentence-courtesy phrase, trim.
        var cleaned = tail
        while true {
            let trimmed = cleaned.trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var advanced = false
            for connector in ["at ", "in ", "near "] where trimmed.hasPrefix(connector) {
                cleaned = String(trimmed.dropFirst(connector.count))
                advanced = true
                break
            }
            if !advanced {
                cleaned = trimmed
                break
            }
        }
        var earliestCut = cleaned.endIndex
        for boundary in englishPlaceBoundaries {
            if let found = cleaned.range(of: boundary), found.lowerBound < earliestCut {
                earliestCut = found.lowerBound
            }
        }
        if earliestCut < cleaned.endIndex {
            cleaned = String(cleaned[..<earliestCut])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cleaned = cleaned.trimmingCharacters(in: .punctuationCharacters)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Date resolution ladder

    /// Resolves the extracted day/time signals against `now`:
    ///
    ///  1. A relative day word (आज/भोलि/पर्सि, today/tomorrow/day after
    ///     tomorrow): that day at the clock time, or NOON when only the
    ///     day was said. Explicit days are NOT pushed forward when the
    ///     clock has already passed — "आज २ बजे" said at 3 p.m. still
    ///     saves today 14:00 (the senior sees the past row and removes
    ///     it; the SMS is stale).
    ///  2. A weekday name: the next such weekday at the clock time
    ///     (strictly after `now`, so "on Friday at 3" said on Friday
    ///     morning lands Friday 15:00, not a week later), or at NOON
    ///     when only the day was said.
    ///  3. Neither day nor weekday but a clock time ("…at 2.30pm"):
    ///     today at that time, pushed to tomorrow when it already
    ///     passed — a bare clock time is a forward-looking statement.
    ///  4. Nothing but the marker survived: `now` + 1 hour (the
    ///     documented fallback default).
    ///
    /// Seconds are always zeroed for deterministic storage/display.
    private static func resolveDate(dayOffset: Int?, weekday: Int?,
                                    time: TimeSpan?, now: Date,
                                    calendar: Calendar) -> Date? {
        let hour = time?.hour ?? 12
        let minute = time?.minute ?? 0

        var target: Date?
        if let dayOffset {
            let base = calendar.date(byAdding: .day, value: dayOffset,
                                     to: calendar.startOfDay(for: now))
            target = base.flatMap {
                calendar.date(bySettingHour: hour, minute: minute, second: 0, of: $0)
            }
        } else if let weekday {
            // Calendar.weekday is 1=Sunday…7=Saturday; our index is
            // 0-based (mirrors NepaliTimeParser.attachDate).
            target = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute,
                                         weekday: weekday + 1),
                matchingPolicy: .nextTime)
        } else if let time {
            target = calendar.date(bySettingHour: hour, minute: minute,
                                   second: 0, of: calendar.startOfDay(for: now))
            if let existing = target, existing <= now {
                target = calendar.date(byAdding: .day, value: 1, to: existing)
            }
        } else {
            target = calendar.date(byAdding: .hour, value: 1, to: now)
            if let existing = target {
                target = calendar.date(bySettingHour: calendar.component(.hour, from: existing),
                                       minute: calendar.component(.minute, from: existing),
                                       second: 0, of: calendar.startOfDay(for: existing))
            }
        }
        return target
    }

    // MARK: - Presentation helpers

    private struct Token {
        /// Normalised token text, punctuation-trimmed (for comparisons).
        let text: String
        /// Raw range in the source (for faithful re-joining).
        let range: Range<String.Index>
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard let start = text[index...]
                .firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = text[start...].firstIndex(where: { $0.isWhitespace })
                ?? text.endIndex
            let trimmed = String(text[start..<end])
                .trimmingCharacters(in: .punctuationCharacters)
            if !trimmed.isEmpty {
                result.append(Token(text: trimmed, range: start..<end))
            }
            index = end
        }
        return result
    }

    /// Clinic nouns and function words kept lowercase in English output
    /// ("Xyz medical centre", "Patan hospital"); every other token gets
    /// its first letter capitalised ("dr jane" → "Dr Jane"). Devanagari
    /// tokens are untouched — capitalisation does not exist there.
    private static let keepLowercaseWords: Set<String> = [
        "medical", "centre", "center", "clinic", "hospital", "care",
        "health", "surgery", "dental", "practice", "physio", "nursing",
        "polyclinic", "of", "the", "a", "an", "and", "at", "in", "on",
        "to", "for", "with", "near", "per", "&"
    ]

    private static func capitaliseWords(_ raw: String) -> String {
        raw.split(separator: " ").map { word in
            let token = String(word)
            guard let first = token.first, first.isLowercase,
                  !keepLowercaseWords.contains(token) else { return token }
            return String(first).uppercased() + token.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: - Voice hook point (documentation for the integrator)

/// VOICE NOTE (medical task, 2026-09-07): the Medical leaf's voice
/// prompt — "add a doctor appointment" — is NOT routed to speech in this
/// worktree. Saving via speech is a sensitive write (a hallucinated
/// doctor or date would arm a native-calendar entry), so it needs a
/// confirm-before-save surface that has no UX contract yet; wiring it
/// blind was judged worse than documenting the hook:
///
///  - Route the phrase in `CommandRouter` exactly where
///    `CalculatorTool.decide` (Services/Voice/CommandRouter.swift,
///    pre-interpreter tool stage) hooks "calculate …": a marker+doctor
///    phrase with NO date/time returns nil from `parse` BY DESIGN, which
///    is the signal to OPEN the Medical leaf's add form rather than
///    save. A phrase WITH a date/time ("…appointment on Friday at 3")
///    returns a `ParsedAppointment` for a speak-back confirm prompt
///    ("डाक्टर डा. जेनसँग शुक्रबार ३ बजे — थप्ने हो?") before saving
///    through the coordinator's `addAppointment`.
///  - New coordinator requirement on `VoiceCommandCoordinating` (the
///    requirement-with-extension-default pattern) plus a dedicated
///    parser/save route file beside `MedicalAppointmentParser.swift`.
///  - The seam writer is called by `AppointmentStore.add` itself, so the
///    voice route only saves via the store — it never touches the
///    calendar protocol directly.
