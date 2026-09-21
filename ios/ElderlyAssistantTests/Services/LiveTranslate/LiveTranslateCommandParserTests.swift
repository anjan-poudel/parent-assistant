import XCTest
@testable import ElderlyAssistant

/// T-023 — C12's session-command parser: every phrase in the vocabulary
/// routes to its own action and nothing else, matching is deterministic and
/// entirely local, every command exists in both languages as catalog copy,
/// a miss re-prompts once and never drops the turn silently, a command never
/// leaks into the shipped intent handling, and repeat is honoured as the
/// design's minimum (FR-LCT-021, FR-LCT-022, NFR-LCT-004, NFR-LCT-012,
/// CL-8).
///
/// The phrase fixtures below are the **same six values** `LiveTranslateCopyTests`
/// pins for T-005. They are repeated here deliberately: that suite pins the
/// *copy*, this one pins what the *matcher accepts*, and a reword has to be
/// deliberate in both places because it changes the words the elder must say.
final class LiveTranslateCommandParserTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    /// The C12 vocabulary as the String Catalog holds it: seven phrases over
    /// six commands (the toggle has one phrase per state), the seventh being
    /// Workstream B's focus command.
    private let phrases: [(key: String, command: LiveTranslateCommand, en: String, ne: String)] = [
        ("livetranslate.command.readAll", .readAll,
         "read this to me", "यो पढेर सुनाउनुहोस्"),
        ("livetranslate.command.stop", .stopSpeaking,
         "stop reading", "पढ्न रोक्नुहोस्"),
        ("livetranslate.command.showOriginal", .setShowOriginal(true),
         "show the original", "मूल अक्षर देखाउनुहोस्"),
        ("livetranslate.command.hideOriginal", .setShowOriginal(false),
         "hide the original", "मूल अक्षर लुकाउनुहोस्"),
        ("livetranslate.command.repeatLast", .repeatLast,
         "say that again", "फेरि भन्नुहोस्"),
        ("livetranslate.command.close", .close,
         "close translation", "अनुवाद बन्द गर्नुहोस्"),
        // Workstream B: the focus mode's spoken half, the same action the
        // anchored box's Translate button performs.
        ("livetranslate.command.translateHere", .translateHere,
         "translate here", "यहाँ अनुवाद गर्नुहोस्")
    ]

    private let parserFile = "ElderlyAssistant/Services/LiveTranslate/LiveTranslateCommandParser.swift"
    private let featureDirectory = "ElderlyAssistant/Services/LiveTranslate"

    // MARK: Fixtures

    private var phraseTable: LiveTranslateCommandPhraseTable {
        .resolved(activeLocale: nepali)
    }

    private func parserCode() -> String {
        let url = FeatureSourceScan.iosDirectory().appendingPathComponent(parserFile)
        let code = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(code.isEmpty, "the parser source scanned as empty — a scan proves nothing")
        return code
    }

    /// The enum case a command value is an instance of, for counting the
    /// vocabulary's *commands* separately from its phrases.
    private func caseName(of command: LiveTranslateCommand) -> String {
        String(String(describing: command).prefix { $0 != "(" })
    }

    private func firstMatch(of token: String, in text: String) -> Int? {
        let pattern = NSRegularExpression.escapedPattern(for: token)
        return FeatureSourceScan.firstMatch(of: pattern, in: text)?.line
    }

    // MARK: Scenario: each command in the vocabulary routes to its action

    func testEachCommandPhraseInBothLanguagesRoutesToItsAction() {
        for phrase in phrases {
            XCTAssertEqual(L10n.str(phrase.key, locale: english), phrase.en,
                           "\(phrase.key): the English form the matcher accepts has changed")
            XCTAssertEqual(L10n.str(phrase.key, locale: nepali), phrase.ne,
                           "\(phrase.key): the Nepali form the matcher accepts has changed")

            XCTAssertEqual(LiveTranslateCommandParser.parse(phrase.en, locale: english),
                           phrase.command, "the English form of \(phrase.key) did not route")
            XCTAssertEqual(LiveTranslateCommandParser.parse(phrase.ne, locale: nepali),
                           phrase.command, "the Nepali form of \(phrase.key) did not route")
        }
    }

    /// The DoD's "full five-command vocabulary resolves in both languages":
    /// the six phrases produce exactly the design's command set — no phrase
    /// is missing and none routes anywhere else.
    func testTheFullVocabularyResolvesInBothLanguages() {
        var resolved: [LiveTranslateCommand] = []
        for phrase in phrases {
            for language in AppLanguage.allCases {
                let utterance = L10n.str(phrase.key, locale: language.locale)
                guard let command = LiveTranslateCommandParser.parse(utterance, locale: language.locale) else {
                    XCTFail("\(phrase.key) did not resolve in \(language.rawValue)")
                    continue
                }
                resolved.append(command)
            }
        }
        XCTAssertEqual(resolved.count, LiveTranslateCommand.allCommands.count * AppLanguage.allCases.count,
                       "every phrase of the vocabulary resolves in every language")
        for value in LiveTranslateCommand.allCommands {
            XCTAssertEqual(resolved.filter { $0 == value }.count, AppLanguage.allCases.count,
                           "\(value) was not reached by exactly one phrase per language")
        }
    }

    /// Seven phrases, six commands: `set-show-original` is one command with
    /// two phrases, which is what makes "on" and "off" unambiguous.
    func testTheVocabularyIsSixCommandsOverSevenPhrases() {
        XCTAssertEqual(LiveTranslateCommand.allCommands.count, phrases.count)
        XCTAssertEqual(Set(LiveTranslateCommand.allCommands.map(caseName)).count, 6,
                       "C12's vocabulary plus the focus read: read-all, stop, "
                       + "set-show-original, repeat-last, close, translate-here")
    }

    /// "No other action is invoked": of C12's five commands only
    /// `set-show-original` writes anything, and it writes the one setting —
    /// read-all, stop, repeat-last and close write nothing at all.
    func testOnlyTheTogglePhrasesWriteASetting() {
        let suiteName = "livetranslate.command.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = LiveTranslateSettings(defaults: defaults)

        var writers: [String] = []
        for phrase in phrases {
            for utterance in [phrase.en, phrase.ne] {
                guard let command = LiveTranslateCommandParser.parse(utterance, locale: nepali) else {
                    XCTFail("\(phrase.key) did not parse")
                    continue
                }
                if command.applySetting(to: settings) { writers.append(phrase.key) }
            }
        }

        // Fourteen utterances (seven phrases × two languages), four of which
        // are the toggle — and nothing else in the vocabulary writes.
        XCTAssertEqual(writers.sorted(),
                       ["livetranslate.command.hideOriginal", "livetranslate.command.hideOriginal",
                        "livetranslate.command.showOriginal", "livetranslate.command.showOriginal"].sorted(),
                       "only the set-show-original command may write a setting")
    }

    /// The command and the touch control take the **same** path (TG-01's
    /// pin): the voice command writes through `LiveTranslateSettings`, under
    /// the one declared key, and the value is written rather than flipped —
    /// saying "show the original" twice leaves it on.
    func testTheVoiceCommandWritesTheSameSettingAsTheTouchControl() {
        let suiteName = "livetranslate.command.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = LiveTranslateSettings(defaults: defaults)

        // The touch control writes first…
        settings.setAlwaysShowOriginal(true)
        // …then the voice command turns it off, through the same store.
        guard let hide = LiveTranslateCommandParser.parse("hide the original", locale: english),
              let show = LiveTranslateCommandParser.parse("मूल अक्षर देखाउनुहोस्", locale: nepali) else {
            return XCTFail("the toggle phrases did not parse")
        }
        XCTAssertEqual(hide, .setShowOriginal(false))
        XCTAssertTrue(hide.applySetting(to: settings))
        XCTAssertFalse(settings.alwaysShowOriginal,
                       "the voice write and the touch read disagree")

        // The same phrase twice is idempotent: a written value, not a toggle.
        XCTAssertEqual(show, .setShowOriginal(true))
        XCTAssertTrue(show.applySetting(to: settings))
        XCTAssertTrue(show.applySetting(to: settings), "a second 'show' must not invert the setting")

        let written = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(LiveTranslateSettings.featureKeyPrefix) }
        XCTAssertEqual(Set(written), [LiveTranslateSettings.alwaysShowOriginalKey],
                       "the command must not introduce a second persisted key")
    }

    // MARK: Scenario: matching is deterministic and local

    func testTheSameUtteranceAlwaysYieldsTheSameResult() {
        for phrase in phrases {
            for utterance in [phrase.en, phrase.ne, phrase.en.uppercased(),
                              phrase.en + "?", phrase.en + ".", "  " + phrase.en + "  "] {
                let first = LiveTranslateCommandParser.parse(utterance, locale: nepali)
                for _ in 0..<25 {
                    XCTAssertEqual(LiveTranslateCommandParser.parse(utterance, locale: nepali), first,
                                   "the same utterance produced two different results")
                }
                XCTAssertEqual(first, phrase.command,
                               "\(phrase.key) must survive case, punctuation and surrounding space")
            }
        }
    }

    /// The active language decides which form is tried first; it does not
    /// decide which forms are recognised. An elder's spoken language is not
    /// the app's display language, so both are matched in every locale.
    func testBothLanguagesMatchInEveryLocale() {
        let locales = [Locale(identifier: "en"), Locale(identifier: "en-US"),
                       Locale(identifier: "ne"), Locale(identifier: "ne-NP"),
                       Locale(identifier: "ne-IN"), Locale(identifier: "fr-FR")]
        for phrase in phrases {
            for locale in locales {
                XCTAssertEqual(LiveTranslateCommandParser.parse(phrase.en, locale: locale),
                               phrase.command, "the English form failed in \(locale.identifier)")
                XCTAssertEqual(LiveTranslateCommandParser.parse(phrase.ne, locale: locale),
                               phrase.command, "the Nepali form failed in \(locale.identifier)")
            }
        }
    }

    /// The security property, scanned: no network, no model, no clock, no
    /// file, no concurrency, no log surface — the utterance is matched
    /// against local copy and nothing else can happen to it.
    private let forbiddenInParser: [(token: String, why: String)] = [
        ("URLSession", "a network client"),
        ("URLRequest", "a network request"),
        ("URLComponents", "a URL"),
        ("http://", "a URL scheme"),
        ("https://", "a URL scheme"),
        ("NWConnection", "a network connection"),
        ("GeminiClient", "the feature's cloud client"),
        ("translateStrings", "the cloud translation entry point"),
        ("Data(contentsOf", "a file or network read"),
        ("FileManager", "file access"),
        ("UserDefaults", "persisted state"),
        ("Timer", "a clock"),
        ("DispatchQueue", "work handed off the call"),
        ("Task", "concurrency"),
        ("async", "concurrency"),
        ("await", "concurrency"),
        ("Date(", "the clock"),
        ("ObservabilityEvent", "the log surface"),
        ("LiveTranslateEvents", "the event emitters"),
        ("print(", "a console write"),
        ("debugPrint(", "a console write"),
        ("NSLog(", "a console write"),
        ("os_log(", "a console write")
    ]

    func testTheParserIsLocalOfflineAndModelFree() {
        let code = parserCode()
        for entry in forbiddenInParser {
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: entry.token), in: code),
                         "the parser names \(entry.token) (\(entry.why)) — matching must stay local")
        }
    }

    /// The scan is falsifiable: it must find every shape where it actually
    /// appears, so a scan that stops detecting its own tokens fails instead
    /// of passing forever.
    func testTheOfflineScanDetectsItsOwnShapes() {
        let synthetic = forbiddenInParser.map(\.token).joined(separator: "\n")
        for entry in forbiddenInParser {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: entry.token), in: synthetic),
                            "the scan cannot see \(entry.token), so its silence proves nothing")
        }
        XCTAssertNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: "definitelyNotInTheParser"), in: synthetic))
    }

    // MARK: Scenario: every command exists in both languages

    func testEveryCommandHasAnEnglishAndANepaliForm() {
        let table = phraseTable
        for phrase in phrases {
            let forms = table.entries.filter { $0.command == phrase.command }
            XCTAssertEqual(Set(forms.map(\.language)), Set(AppLanguage.allCases),
                           "\(phrase.key) must exist in both languages")
            XCTAssertEqual(forms.count, 2,
                           "one phrase per language per command, not a paraphrase list")
            XCTAssertTrue(forms.allSatisfy { $0.key == phrase.key })
        }
        XCTAssertEqual(table.entries.count, phrases.count * AppLanguage.allCases.count)
    }

    /// The phrases are catalog entries, not Swift literals: the production
    /// source contains no Devanagari at all, and every entry the table holds
    /// is the normalized form of the catalog's own value.
    ///
    /// Comments are stripped before the scan (`FeatureSourceScan.codeText`),
    /// so a doc comment may quote the run-time text as documentation while a
    /// literal in code cannot hide.
    func testThePhraseTableIsResolvedFromTheCatalogAndNotFromSwiftLiterals() {
        let code = parserCode()
        XCTAssertFalse(code.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                       "the parser source carries Devanagari — the phrases belong in the catalog")
        for phrase in phrases {
            XCTAssertNil(firstMatch(of: phrase.en, in: code),
                         "the parser source carries the literal \(phrase.en.debugDescription)")
        }

        for entry in phraseTable.entries {
            let catalogValue = L10n.str(entry.key, locale: entry.language.locale)
            XCTAssertNotEqual(catalogValue, entry.key, "\(entry.key) did not resolve")
            XCTAssertEqual(entry.phrase, LiveTranslateCommandParser.normalized(catalogValue),
                           "the table's phrase is not the catalog's own value")
        }
    }

    func testTheTableReadsExactlyTheSevenDeclaredCommandKeys() {
        XCTAssertEqual(LiveTranslateCommandPhraseTable.catalogKeys.map(\.key).sorted(),
                       phrases.map(\.key).sorted(),
                       "a command whose phrase is not catalogued cannot be localised")
        XCTAssertEqual(Set(LiveTranslateCommandPhraseTable.catalogKeys.map { String(describing: $0.command) }).count, 7,
                       "each key must mean its own command value, including the toggle's two states")
    }

    // MARK: Scenario: matching is whole-phrase (the Devanagari pin)

    /// Swift's `Character` is an extended grapheme cluster, so a partial-word
    /// or substring test behaves differently in Devanagari than the same code
    /// does in Latin text. This fixture pins the fact on the real phrase and
    /// the parser's answer to it: matching is whole-phrase, and every
    /// fragment is a near miss.
    func testAWordIsNotASequenceOfScalarsWhichIsWhyMatchingIsWholePhrase() {
        let stop = L10n.str("livetranslate.command.stop", locale: nepali)

        // The pinned shape: 7 Characters over 15 scalars (today's values are
        // in the source's comment; the relation is what must hold).
        XCTAssertLessThan(Array(stop).count, stop.unicodeScalars.count,
                          "a Devanagari phrase must cluster below its scalar count; if this ever fails the fixture, not the parser, is wrong")

        // Dropping the final *scalar* leaves a string a scalar-level search
        // finds inside the phrase and Swift's Character-based search does not.
        var scalars = stop.unicodeScalars
        scalars.removeLast()
        let scalarTruncated = String(scalars)
        XCTAssertNotEqual(scalarTruncated, stop)
        XCTAssertFalse(stop.contains(scalarTruncated),
                       "Character-based containment does not see a scalar-level substring — the hazard this matcher must not depend on")
        XCTAssertTrue(scalarLevelContains(scalarTruncated, in: stop),
                      "at scalar level the fragment IS present, which is exactly why a substring matcher would behave differently here")

        // And the parser's answer, either way: a fragment is not a command.
        XCTAssertNil(LiveTranslateCommandParser.parse(scalarTruncated, locale: nepali))
        XCTAssertNil(LiveTranslateCommandParser.parse(String(stop.dropLast()), locale: nepali))
    }

    /// A partial phrase never acts, in either language: the words on their
    /// own, the phrase with a word added, and the phrase with one removed.
    func testEveryFragmentOfAPhraseIsANearMissRatherThanAnAction() {
        for phrase in phrases {
            for (utterance, locale) in [(phrase.en, english), (phrase.ne, nepali)] {
                let words = utterance.split(separator: " ").map(String.init)
                for word in words where words.count > 1 {
                    XCTAssertNil(LiveTranslateCommandParser.parse(word, locale: locale),
                                 "\(word.debugDescription) is one word of a phrase, not a command")
                }
                XCTAssertNil(LiveTranslateCommandParser.parse(utterance + " extra", locale: locale),
                             "a phrase with a word added is a near miss, not a command")
                XCTAssertNil(LiveTranslateCommandParser.parse(String(utterance.dropLast()), locale: locale),
                             "a phrase with its last character missing is a near miss, not a command")
            }
        }
    }

    func testEmptyAndUnrelatedUtterancesAreNotCommands() {
        for utterance in ["", "   ", "\n", ".", "?", "।", "um", "नमस्ते", "read", "रोक्नुहोस् भन्नुहोस्"] {
            XCTAssertNil(LiveTranslateCommandParser.parse(utterance, locale: nepali),
                         "\(utterance.debugDescription) is not a C12 command")
        }
    }

    // MARK: Scenario: a miss re-prompts once and never drops the turn

    func testAMissRepromptsOnceAndTheTurnThenEndsExplicitly() {
        var turn = LiveTranslateCommandTurn()

        XCTAssertEqual(turn.accept("what's the weather today", locale: english), .reprompt,
                       "the first miss must re-prompt rather than be dropped")
        XCTAssertEqual(turn.accept("still not a command", locale: english), .turnEnded,
                       "C12 allows one re-prompt per turn; the end is explicit")
        XCTAssertEqual(turn.accept("and another miss", locale: english), .reprompt,
                       "a new turn is entitled to its own single re-prompt")
    }

    func testAMatchAnswersTheTurnAndTheNextMissIsAFreshReprompt() {
        var turn = LiveTranslateCommandTurn()
        XCTAssertEqual(turn.accept("say that again", locale: english), .command(.repeatLast))
        XCTAssertEqual(turn.accept("nonsense", locale: english), .reprompt)
        XCTAssertEqual(turn.accept("read this to me", locale: english), .command(.readAll))
        XCTAssertEqual(turn.accept("nonsense", locale: english), .reprompt,
                       "a command resets the turn, so the next miss gets its own re-prompt")
    }

    /// "No action is taken for a non-command": the only outcome that can act
    /// carries a command, and the two miss outcomes carry nothing at all.
    func testNoMissOutcomeCanActAndNoOutcomeCanCarryTheUtterance() {
        var turn = LiveTranslateCommandTurn()
        let suiteName = "livetranslate.command.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = LiveTranslateSettings(defaults: defaults)

        var outcomes: [LiveTranslateCommandTurn.Outcome] = []
        for utterance in ["what's the weather today", "um", "मौसम कस्तो छ", "call my son"] {
            let outcome = turn.accept(utterance, locale: nepali)
            outcomes.append(outcome)
            switch outcome {
            case .command(let command):
                XCTFail("a non-command produced \(command)")
            case .reprompt, .turnEnded:
                break
            }
        }
        XCTAssertEqual(outcomes.count(where: { $0 == .reprompt }), 2)
        XCTAssertEqual(outcomes.count(where: { $0 == .turnEnded }), 2)

        XCTAssertEqual(defaults.dictionaryRepresentation().keys
                        .filter { $0.hasPrefix(LiveTranslateSettings.featureKeyPrefix) }.count, 0,
                       "a miss must not write anything")
        XCTAssertFalse(settings.alwaysShowOriginal)

        // No outcome can hand the utterance to a caller: every case's
        // children are commands and Bools, never a String.
        for outcome in outcomes + [.command(.readAll), .command(.setShowOriginal(true))] {
            XCTAssertTrue(stringChildren(of: outcome).isEmpty,
                          "an outcome carried a String — the utterance would be expressible")
        }
    }

    // MARK: Scenario: the utterance never reaches the log surface

    /// Two halves of one guarantee. The parser holds no emitter and no log
    /// call (the scan), and the shipped sanitising bus is not a speech
    /// scrubber — an utterance handed to it as metadata survives intact — so
    /// the defence has to be that this code never emits, not that a sink
    /// would redact.
    func testTheUtteranceCannotReachTheLogSurface() {
        let code = parserCode()
        for token in ["bus.emit(", "emit(", "ObservabilityBus", "LogSanitiser", "Logger", "telemetry"] {
            XCTAssertNil(firstMatch(of: token, in: code),
                         "the parser can reach \(token) — the utterance must never be loggable")
        }

        let bus = LiveTranslateSanitisingBus()
        let utterance = L10n.str("livetranslate.command.readAll", locale: nepali)
        bus.emit(ObservabilityEvent(component: "livetranslate",
                                    eventType: "speak_requested",
                                    durationMs: nil,
                                    outcome: "success",
                                    errorCode: nil,
                                    metadata: ["mode": utterance]))
        XCTAssertEqual(bus.events.first?.metadata["mode"], utterance,
                       "the sanitising bus keeps free text in an allow-listed field — so the parser must never emit one")
    }

    // MARK: Scenario: a command does not leak into the shipped intent handling

    /// The shipped intent vocabulary's own exemplars, in both languages
    /// (sources: the shipped intent prompt's action list, the shipped
    /// `AlarmTimerCommandParser` examples, the user manual and the shipped
    /// corpus tests). None of them may be consumed by this feature — spoken
    /// in session they are not commands, and outside the session the parser
    /// is unreachable at all.
    func testShippedIntentPhrasesAreNeverClaimedAsCommands() {
        let shippedIntentPhrases = [
            "set an alarm for 6 am",
            "what's the weather today",
            "remind me to take medicine at 8",
            "is it raining in Arncliffe",
            "बिहान ६ बजे अलार्म लगाऊ",
            "आजको मौसम कस्तो छ?",
            "औषधि खाएँ",
            "मैले औषधि खाएँ, समाचार सुनाऊ"
        ]
        for utterance in shippedIntentPhrases {
            for locale in [english, nepali] {
                XCTAssertNil(LiveTranslateCommandParser.parse(utterance, locale: locale),
                             "\(utterance.debugDescription) belongs to the shipped pipeline")
            }
        }
    }

    /// NFR-LCT-012's inert-when-closed half, structurally: no shipped source
    /// names the feature's parser or its turn, so while the feature is not
    /// open nothing in the shipped pipeline can run it. The plugin that
    /// *does* reach it lives inside the feature's own directory (T-026), so
    /// this scan keeps its meaning after that task lands.
    func testNoShippedSourceCanReachTheParserWhileTheFeatureIsClosed() {
        let root = FeatureSourceScan.iosDirectory()
        let featureRoot = root.appendingPathComponent(featureDirectory).path
        let files = FeatureSourceScan.swiftFiles(in: "ElderlyAssistant")
            .filter { !$0.path.hasPrefix(featureRoot) }
        XCTAssertGreaterThan(files.count, 100, "the shipped tree must actually be scanned")

        for file in files {
            let code = FeatureSourceScan.codeText(of: file)
            for token in ["LiveTranslateCommandParser", "LiveTranslateCommandTurn", "LiveTranslateCommand"] {
                XCTAssertNil(firstMatch(of: token, in: code),
                             "\(FeatureSourceScan.relativePath(of: file)) reaches \(token) — "
                             + "the feature must only be dispatchable through its plugin, never the shipped pipeline")
            }
        }
    }

    // MARK: Scenario: repeat is honoured as the design's minimum (CL-8)

    /// `repeatLast` is kept, not dropped: it is one of the six catalogued
    /// phrases (T-005), it routes from both languages, and it carries
    /// nothing — no text, no region, no tier — so a replay cannot become a
    /// second translation by accident.
    func testRepeatLastIsKeptAndCarriesNothing() {
        for (utterance, locale) in [("say that again", english), ("फेरि भन्नुहोस्", nepali)] {
            guard let command = LiveTranslateCommandParser.parse(utterance, locale: locale) else {
                XCTFail("the repeat phrase did not route: \(utterance)")
                continue
            }
            XCTAssertEqual(command, .repeatLast)
            XCTAssertTrue(stringChildren(of: command).isEmpty,
                          "the repeat command carries a value that could be re-sent")
            XCTAssertEqual(command.speechMode, .repeatLast,
                           "repeat maps to the shipped mode documented as replaying what was already spoken")
        }
    }

    /// The DoD's "the repeat path performs no translation, send or consent
    /// work": the command holds no content to translate, and the parser that
    /// produces it cannot reach a tier, the cloud or the consent gate.
    func testTheRepeatPathPerformsNoTranslationSendOrConsentWork() {
        var turn = LiveTranslateCommandTurn()
        XCTAssertEqual(turn.accept("say that again", locale: nepali), .command(.repeatLast))

        // The entry points that could make a command do more than replay:
        // translation (local or cloud), egress, consent and budget. Named as
        // they are spelled in the code, so the scan cannot be satisfied by
        // the word "translate" appearing inside a `livetranslate.*` key.
        for token in ["translateStrings", "GeminiClient", "GeminiTransport",
                      "CloudTranslationTier", "LabelTranslationCache",
                      "URLSession", "URLRequest", "ConsentGate", "ConsentPromptController",
                      "authorize", "Grant", "costGovernor", "EncryptedLocalStorage"] {
            XCTAssertNil(firstMatch(of: token, in: parserCode()),
                         "the parser names \(token) — a command may not translate, send or re-consent")
        }

        // The repeat command writes no setting either.
        let suiteName = "livetranslate.command.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(LiveTranslateCommand.repeatLast.applySetting(
            to: LiveTranslateSettings(defaults: defaults)))
        XCTAssertEqual(defaults.dictionaryRepresentation().keys
                        .filter { $0.hasPrefix(LiveTranslateSettings.featureKeyPrefix) }.count, 0)
    }

    /// The speaking commands are the two the design names, and nothing else
    /// in the vocabulary asks for speech.
    func testOnlyReadAllAndRepeatAskForSpeech() {
        XCTAssertEqual(LiveTranslateCommand.readAll.speechMode, .readAll)
        XCTAssertEqual(LiveTranslateCommand.repeatLast.speechMode, .repeatLast)
        XCTAssertNil(LiveTranslateCommand.stopSpeaking.speechMode)
        XCTAssertNil(LiveTranslateCommand.close.speechMode)
        XCTAssertNil(LiveTranslateCommand.setShowOriginal(true).speechMode)
        XCTAssertNil(LiveTranslateCommand.setShowOriginal(false).speechMode)
        // "translate here" speaks nothing *as a command*: its answer is a
        // picture with a card under it, so the vocabulary gains a sixth
        // command without gaining a third speaker.
        XCTAssertNil(LiveTranslateCommand.translateHere.speechMode)
    }

    // MARK: Helpers

    private func stringChildren(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap { $0.value as? String }
    }

    /// A scalar-level substring search, which is what a byte- or
    /// scalar-oriented implementation of "contains" would do — the behaviour
    /// Swift's Character-based `contains` deliberately differs from.
    private func scalarLevelContains(_ needle: String, in haystack: String) -> Bool {
        let h = Array(haystack.unicodeScalars)
        let n = Array(needle.unicodeScalars)
        guard !n.isEmpty, h.count >= n.count else { return false }
        for start in 0...(h.count - n.count) where Array(h[start..<(start + n.count)]) == n {
            return true
        }
        return false
    }
}
