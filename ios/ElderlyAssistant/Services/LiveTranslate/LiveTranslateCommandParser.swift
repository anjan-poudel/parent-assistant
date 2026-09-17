import Foundation

// T-023 — C12's session-command vocabulary, its phrase table, and the
// deterministic, offline parser that matches an in-session utterance against
// it (FR-LCT-021, FR-LCT-022, NFR-LCT-004, CL-8).
//
// Three properties are **structural** here rather than promised:
//
//  1. **The utterance never leaves the device and never reaches a log.**
//     This file has no network client, no model, no clock, no file access and
//     no `Task`/`async`: matching is a string comparison against a table of
//     catalog copy, so a two-word command costs no round trip and no cloud
//     budget. The parser holds no observability bus and returns no text —
//     `LiveTranslateCommand` is a closed enum whose only payload is a `Bool`,
//     so the words the elder spoke are not expressible in anything this file
//     hands back to a caller.
//
//  2. **Every phrase is copy, not code.** The table resolves its phrases from
//     the String Catalog (`livetranslate.command.*`, T-005) in both languages
//     the app ships, so a reword is a catalog change and the matcher cannot
//     drift from the copy the tests pin (NFR-LCT-004). This file's **code**
//     carries no phrase literal and no Devanagari scalar: the phrases quoted
//     in these comments are documentation, and the test scans
//     comment-stripped source (`FeatureSourceScan.codeText`), so a literal in
//     code cannot hide behind them.
//
//  3. **Matching is whole-phrase, never a substring.** Swift's `Character` is
//     an extended grapheme cluster — "पढ्न रोक्नुहोस्" (the stop phrase) is
//     7 Characters and 15 Unicode scalars — so a substring or prefix test
//     behaves differently in Devanagari than the scalar-level search a Latin
//     string makes it look like. Whole-phrase equality after normalization
//     never depends on where a cluster boundary falls, and a near miss
//     returns `nil` (C12's re-prompt path) rather than risking the wrong
//     action on an elder's two-word instruction.
//
// Capture, arbitration and the spoken results are not here: the utterance
// arrives from the plugin's in-session microphone (T-025) and the commands
// that speak are performed by the session (T-024). This parser recognises,
// and nothing else.

/// C12's session-command vocabulary: read-all, stop, set-show-original (one
/// command, two phrases), repeat-last and close — five commands, six phrases.
enum LiveTranslateCommand: Equatable {

    /// "read this to me" (FR-LCT-021): speak the visible regions
    /// top-to-bottom. The ordering is the session's (T-024).
    case readAll

    /// "stop reading": halt the reading in progress.
    case stopSpeaking

    /// "say that again" (CL-8): replay the last spoken item. The command
    /// carries nothing — see `speechMode`, whose `repeatLast` case is the
    /// vocabulary T-003 documents as "replayed from what was already spoken;
    /// it never re-translates, re-sends or re-consents".
    case repeatLast

    /// "show the original" / "hide the original": the FR-LCT-017 preference,
    /// written through `LiveTranslateSettings` (see `applySetting(to:)`).
    /// One command with a value, so a phrase can never mean "flip it" — the
    /// elder's second "show the original" leaves the setting on.
    case setShowOriginal(Bool)

    /// "close translation": the session's one explicit exit.
    case close

    /// The vocabulary's phrase-level values in C12 order: six phrases over
    /// the five commands, because the toggle has one phrase per state. The
    /// parser's results are asserted against exactly this set.
    static let allCommands: [LiveTranslateCommand] = [
        .readAll,
        .stopSpeaking,
        .setShowOriginal(true),
        .setShowOriginal(false),
        .repeatLast,
        .close
    ]

    /// The speech mode this command asks for, or `nil` when it asks for no
    /// speech. `LiveTranslateSpeechMode` is T-003's shipped closed vocabulary
    /// — the token the `speak_requested` / `speak_failed` events carry — so
    /// the command handler does not need a second mapping of its own.
    var speechMode: LiveTranslateSpeechMode? {
        switch self {
        case .readAll: return .readAll
        case .repeatLast: return .repeatLast
        case .stopSpeaking, .setShowOriginal, .close: return nil
        }
    }

    /// Applies the one command that writes a setting, through **the same
    /// setter the touch control calls** (T-022): TG-01 pins that the two
    /// paths write the one declared key, so there is no second write path to
    /// keep honest. Returns whether a setting was written, which is what
    /// makes "no other action is invoked" checkable at a call site.
    ///
    /// Nothing else here writes anything: read-all, stop and repeat-last are
    /// performed by the session, close ends it, and none of the five starts
    /// a translation, a cloud send, a consent change or a cost decision.
    @discardableResult
    func applySetting(to settings: LiveTranslateSettings) -> Bool {
        switch self {
        case .setShowOriginal(let showOriginal):
            settings.setAlwaysShowOriginal(showOriginal)
            return true
        case .readAll, .stopSpeaking, .repeatLast, .close:
            return false
        }
    }
}

/// The C12 phrase table, resolved from the String Catalog (NFR-LCT-004) in
/// every language the app ships.
///
/// Resolution is by **key**: `livetranslate.command.*` are the entries T-005
/// pinned, and the phrase text lives in `Localizable.xcstrings` in `en` and
/// `ne`. A reword is therefore a copy change with no Swift change — and a
/// missing form cannot silently become matchable, because a phrase that
/// resolves to its own key is dropped rather than compared (see
/// `resolved(activeLocale:)`).
struct LiveTranslateCommandPhraseTable: Equatable {

    /// One command in one language.
    struct Entry: Equatable {
        /// What a match on this phrase means.
        let command: LiveTranslateCommand
        /// The language this form was resolved for. Both languages are
        /// matched regardless of the active one (the elder's spoken language
        /// is not the app's display language), so this is provenance.
        let language: AppLanguage
        /// The catalog key the phrase came from, kept so a failure can name
        /// the copy rather than the resolved text.
        let key: String
        /// The phrase, already normalized for matching, so a match is one
        /// string comparison per entry.
        let phrase: String
    }

    /// The catalog keys that carry the vocabulary, and what each one means.
    /// Keys are identifiers; every phrase is catalog copy.
    static let catalogKeys: [(key: String, command: LiveTranslateCommand)] = [
        ("livetranslate.command.readAll", .readAll),
        ("livetranslate.command.stop", .stopSpeaking),
        ("livetranslate.command.showOriginal", .setShowOriginal(true)),
        ("livetranslate.command.hideOriginal", .setShowOriginal(false)),
        ("livetranslate.command.repeatLast", .repeatLast),
        ("livetranslate.command.close", .close)
    ]

    /// The resolved table. Ordered: the active language's forms first, so if
    /// two languages ever carried the same normalized phrase for different
    /// commands the active language decides — the match stays deterministic
    /// within a language and across them.
    let entries: [Entry]

    /// Resolves every phrase for every language the app ships.
    ///
    /// `activeLocale` selects which language is tried first; it does **not**
    /// restrict the match to that language. An elder speaks their own
    /// language, which is configured independently of the display language
    /// (`AppLanguage`), and a command that failed to match because of that
    /// would be a re-prompt for a phrase the app itself ships.
    static func resolved(activeLocale: Locale) -> LiveTranslateCommandPhraseTable {
        let identifier = activeLocale.language.languageCode?.identifier
        let active = AppLanguage.allCases.first { $0.rawValue == identifier }
        let ordered = active.map { first in
            [first] + AppLanguage.allCases.filter { $0 != first }
        } ?? AppLanguage.allCases

        var entries: [Entry] = []
        for language in ordered {
            for declared in catalogKeys {
                let phrase = L10n.str(declared.key, locale: language.locale)
                // `L10n.str` answers with the key itself when the catalog
                // carries no entry for that language, and an unresolved form
                // must not be matchable — a key-shaped string is not
                // something an elder said. Dropping it costs that language
                // its match (the elder is re-prompted, C12's path) instead of
                // acting on a phrase no one wrote; the test suite fails if a
                // language ever loses a form.
                guard phrase != declared.key, !phrase.isEmpty else { continue }
                let normalized = LiveTranslateCommandParser.normalized(phrase)
                guard !normalized.isEmpty else { continue }
                entries.append(Entry(command: declared.command,
                                     language: language,
                                     key: declared.key,
                                     phrase: normalized))
            }
        }
        return LiveTranslateCommandPhraseTable(entries: entries)
    }
}

/// C12's deterministic, offline parser.
enum LiveTranslateCommandParser {

    /// The parser's whole contract: the command the utterance asked for, or
    /// `nil` when it is not one of the phrases.
    ///
    /// `nil` is **not an error** — it is the design's re-prompt path
    /// (`review-l2` records the same: `parse` "returns an optional, where
    /// `nil` means 'not a command' … not an error"). `LiveTranslateCommandTurn`
    /// is what turns it into the single re-prompt C12 allows, so a miss
    /// neither acts nor disappears.
    static func parse(_ utterance: String, locale: Locale) -> LiveTranslateCommand? {
        parse(utterance, in: .resolved(activeLocale: locale))
    }

    /// The same match against a table the caller has already resolved — for
    /// a session that parses many utterances and should not re-resolve the
    /// catalog for each one. The result is identical to `parse(_:locale:)`
    /// for a table resolved from that locale.
    static func parse(_ utterance: String,
                      in table: LiveTranslateCommandPhraseTable) -> LiveTranslateCommand? {
        let normalized = normalized(utterance)
        guard !normalized.isEmpty else { return nil }
        return table.entries.first { $0.phrase == normalized }?.command
    }

    /// Normalization for matching, applied identically to the utterance and
    /// to every table entry.
    ///
    ///  - **Canonical composition** (NFC) first: the same word can arrive
    ///    with its vowel signs or nukta in a different scalar order, and two
    ///    canonically equivalent strings must compare equal.
    ///  - **Lowercased**, so a recognizer's capitalization is not a miss.
    ///  - **Whitespace, punctuation and symbols become a single space.**
    ///    Replacing rather than deleting is deliberate: deleting the hyphens
    ///    of "read-this-to-me" would fuse it into one token that no longer
    ///    matches "read this to me". A run of spaces collapses to one and the
    ///    ends are trimmed, so trailing punctuation from a recognizer
    ///    ("read this to me.", the Devanagari danda "।") is not a miss.
    ///
    /// The result is compared as a whole string, never as a substring: a
    /// fragment of a phrase is a near miss and returns `nil`.
    static func normalized(_ text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        var spaced = ""
        for scalar in text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if separators.contains(scalar) {
                spaced.unicodeScalars.append(" ")
            } else {
                spaced.unicodeScalars.append(scalar)
            }
        }
        return spaced.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}

/// C12's turn rule: "a miss re-prompts once and never silently drops the
/// turn".
///
/// The parser answers *what was said*; this answers *what happens to the
/// turn*. A miss is a decision the caller must take — the elder is prompted
/// once, and the turn then ends explicitly — so no outcome is "nothing
/// happened": every utterance produces a command, a re-prompt, or an
/// explicit end. The re-prompt's wording and its speech are the session's
/// (T-024/T-025); this type decides only that it happens, exactly once.
///
/// Deterministic and free of any resource: state is one `Bool`, and a match
/// (or an ended turn) starts the next turn, so a session of utterances is a
/// pure function of the utterances in order.
struct LiveTranslateCommandTurn {

    /// What the caller does with one utterance.
    enum Outcome: Equatable {
        /// A command was recognised. The caller performs it — and only it
        /// (`LiveTranslateCommand.applySetting(to:)` is the one setting
        /// write).
        case command(LiveTranslateCommand)
        /// Nothing matched. C12 allows exactly one re-prompt: the caller
        /// re-prompts now, and takes no other action.
        case reprompt
        /// Nothing matched, and the one re-prompt has already been given.
        /// The turn ends here — explicitly, so no caller can end it silently
        /// and no loop can form.
        case turnEnded
    }

    /// Whether this turn has already spent its single re-prompt.
    private(set) var hasReprompted = false

    /// A turn starts unanswered: the first miss is always the one that
    /// re-prompts. Explicit, so the only way to hold one of these is to
    /// begin a turn.
    init() {}

    /// Parses one utterance and advances the turn.
    mutating func accept(_ utterance: String, locale: Locale) -> Outcome {
        accept(utterance, in: .resolved(activeLocale: locale))
    }

    /// The same step against a pre-resolved table.
    mutating func accept(_ utterance: String,
                         in table: LiveTranslateCommandPhraseTable) -> Outcome {
        if let command = LiveTranslateCommandParser.parse(utterance, in: table) {
            hasReprompted = false   // the turn is answered; the next is fresh
            return .command(command)
        }
        guard !hasReprompted else {
            hasReprompted = false   // the turn ends; the next is fresh
            return .turnEnded
        }
        hasReprompted = true
        return .reprompt
    }
}
