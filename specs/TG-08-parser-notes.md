# TG-08 — In-session voice commands: T-023 `LiveTranslateCommandParser` implementation notes

Task: **T-023 `LiveTranslateCommandParser`** (C12) — **T-023 only**. T-024 (spoken output) and T-025
(in-session capture) belong to the same group but were **not** built here; the seams left for them and
what they must still do are the dedicated section near the end, and they are also listed as open items.
No API of theirs was invented, stubbed or forward-declared.
Worktree: `.claude/worktrees/live-camera-translation`. Uncommitted, per the workflow (no commits made).
Requirements: FR-LCT-021, FR-LCT-022, NFR-LCT-004 · **CL-8 (`repeatLast`)** from `specs/review-l2.md` ·
NFR-LCT-012 (shipped code additive only) · NFR-LCT-006/007 as they bind this surface (the utterance is
content and may never be logged).

## What was built

### `LiveTranslateCommandParser.swift` (307 lines, new)

`ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateCommandParser.swift`. Four types, no state
outside the turn, no resource of any kind:

- **`LiveTranslateCommand`** — C12's closed vocabulary exactly as `specs/design-component.md` pins it:
  `Equatable`, cases `readAll`, `stopSpeaking`, `repeatLast`, `setShowOriginal(Bool)`, `close`. Five
  commands. `allCommands` is the phrase-level list (six values, because the toggle has one phrase per
  state) and it is what the tests assert against. `speechMode` maps the two speaking commands onto
  T-003's shipped `LiveTranslateSpeechMode` tokens (`.readAll`, `.repeatLast`) and answers `nil` for the
  rest — the single seam T-024 needs, so no handler invents a second mapping. `applySetting(to:)` is the
  one command that writes anything: `setShowOriginal` writes through
  **`LiveTranslateSettings.setAlwaysShowOriginal(_:)`, the same setter the touch control calls**, and
  returns `false` for every other command (which is what makes "no other action is invoked" checkable
  at a call site).
- **`LiveTranslateCommandPhraseTable`** — the phrase table, resolved **from the String Catalog, by
  key**, never from Swift literals. `catalogKeys` is the six-key list T-005 pinned
  (`livetranslate.command.readAll` / `.stop` / `.showOriginal` / `.hideOriginal` / `.repeatLast` /
  `.close`); `resolved(activeLocale:)` calls `L10n.str(_:locale:)` for **every language the app ships**
  (`AppLanguage.allCases`, active language first) and normalizes each phrase once, so a match is one
  string comparison per entry. A phrase that resolves to its own key (unresolved copy) or to nothing is
  **dropped, not compared** — a key-shaped string is not something an elder said — and a test fails if a
  language ever loses a form. The file's **code** carries no phrase literal and no Devanagari scalar at
  all: the phrases quoted in its comments are documentation, and the test scans comment-stripped source
  (`FeatureSourceScan.codeText`), so a literal in code cannot hide behind a doc comment.
- **`LiveTranslateCommandParser`** — the parser itself, one line of contract:
  `static func parse(_ utterance: String, locale: Locale) -> LiveTranslateCommand?` (plus an overload
  that takes a pre-resolved table, so a session parsing many utterances need not re-resolve the catalog
  per utterance). `nil` is **not an error** — it is the design's re-prompt path. Matching is
  **whole-phrase equality after normalization**, never a substring or prefix.
  `normalized(_:)`: NFC (`precomposedStringWithCanonicalMapping`) → lowercased → whitespace, punctuation
  and symbols each become **one space** (replaced, not deleted — deleting the hyphens of
  "read-this-to-me" would fuse it into a token that no longer matches) → runs collapse, ends trim. Trailing
  `।` or `.` from a recognizer is therefore not a miss, and canonically equivalent Devanagari spellings
  compare equal.
- **`LiveTranslateCommandTurn`** — C12's turn rule: "a miss re-prompts once and never silently drops the
  turn". `Outcome { command(LiveTranslateCommand), reprompt, turnEnded }`; state is one `Bool`; a match
  or an ended turn resets it, so a session of utterances is a pure function of the utterances in order.
  This is the smallest in-scope way to make the DoD's "a miss re-prompts once" assertable, since capture
  and dispatch are T-025's.

### `LiveTranslateCommandParserTests.swift` (573 lines, new, 24 tests)

`ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslateCommandParserTests.swift`. Mirrors the
feature's existing test style (`FeatureSourceScan`, `LiveTranslateSanitisingBus`, `ResultVoidAssertions`
where they apply). The fixtures are the **same 12 phrase values T-005's `LiveTranslateCopyTests` pins**
(six keys × `en`/`ne`), so a catalog reword breaks this suite loudly rather than silently re-pointing
the match.

## Shipped-file edits (NFR-LCT-012)

**None.** This task created two files and edited nothing that exists at `HEAD`:

1. `ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateCommandParser.swift` — new (`??` in git).
2. `ios/ElderlyAssistantTests/Services/LiveTranslate/LiveTranslateCommandParserTests.swift` — new (`??`).

`ios/seniOS.xcodeproj/project.pbxproj` was **regenerated by `./build.sh generate`** (XcodeGen), never
hand-edited; the regeneration also picks up the two other agents' in-flight files. The modified files
visible in `git status` (`AppCoordinator.swift`, `SettingsView.swift`, `Localizable.xcstrings`,
`LogSanitiser.swift`, `InputSanitiser.swift`, the `Appliance/*` files) were changed by TG-01–TG-07, not
by this task. No `LiveTranslateEvents` change was needed either (see decision 7).

## Gherkin coverage — scenario to test

| Scenario (T-023 spec) | Tests |
|---|---|
| Each command in the vocabulary routes to its action | `testEachCommandPhraseInBothLanguagesRoutesToItsAction` (all 12 phrases → command), `testOnlyTheTogglePhrasesWriteASetting` (the other four write nothing), `testTheVoiceCommandWritesTheSameSettingAsTheTouchControl` |
| Matching is deterministic and local | `testTheSameUtteranceAlwaysYieldsTheSameResult`, `testTheParserIsLocalOfflineAndModelFree` (23-token source scan: no `URLSession`, `Gemini`, `Model`, `Task`, `async`, `await`, `Timer`, `Date`, `FileManager`, …; no `LiveTranslateEvents`/bus either), `testTheOfflineScanDetectsItsOwnShapes` (the scan is falsifiable — a probe string with each shape is caught) |
| Every command exists in both languages | `testTheFullVocabularyResolvesInBothLanguages` (DoD), `testTheVocabularyIsFiveCommandsOverSixPhrases`, `testEveryCommandHasAnEnglishAndANepaliForm`, `testThePhraseTableIsResolvedFromTheCatalogAndNotFromSwiftLiterals` (comment-stripped production source contains **no Devanagari scalar** and no phrase literal), `testTheTableReadsExactlyTheSixDeclaredCommandKeys`, `testBothLanguagesMatchInEveryLocale` (all 12 phrases in all 4 `AppLocale`s) |
| A miss re-prompts once and never drops the turn silently | `testAMissRepromptsOnceAndTheTurnThenEndsExplicitly`, `testAMatchAnswersTheTurnAndTheNextMissIsAFreshReprompt`, `testNoMissOutcomeCanActAndNoOutcomeCanCarryTheUtterance`, `testEmptyAndUnrelatedUtterancesAreNotCommands`, `testEveryFragmentOfAPhraseIsANearMissRatherThanAnAction` (every prefix, suffix and word of every phrase → `nil`), `testAWordIsNotASequenceOfScalarsWhichIsWhyMatchingIsWholePhrase` (the grapheme-cluster pin) |
| A command does not leak into the shipped intent handling | `testShippedIntentPhrasesAreNeverClaimedAsCommands` (8 shipped exemplars in both languages, incl. `"set an alarm for 6 am"`, `"what's the weather today"`, `"बिहान ६ बजे अलार्म लगाऊ"`, `"आजको मौसम कस्तो छ?"`), `testNoShippedSourceCanReachTheParserWhileTheFeatureIsClosed` (source scan: nothing outside `Services/LiveTranslate/` names `LiveTranslateCommandParser`/`LiveTranslateCommandTurn`/`LiveTranslateCommand`) |
| Repeat is honoured as the design's minimum | `testRepeatLastIsKeptAndCarriesNothing` (CL-8 decision below: the command is kept and traced — catalogued phrase, `speechMode == .repeatLast`, `applySetting` returns `false`, `Mirror` shows no payload), `testOnlyReadAllAndRepeatAskForSpeech` (the other four commands ask for no speech at all) |
| Commands are inert while the feature is not open | `testNoShippedSourceCanReachTheParserWhileTheFeatureIsClosed` (the same scan: the plugin/session wiring that could call the parser does not exist outside the feature yet — T-026's contract), plus `testTheUtteranceCannotReachTheLogSurface` |
| (NFR-LCT-006/007 for this surface) | `testTheUtteranceCannotReachTheLogSurface` — a source scan for any logging reachability **plus** a live demonstration through the real `LiveTranslateSanitisingBus` that the shipped sanitiser does **not** scrub free speech, so the parser must never emit; `LiveTranslateCommand` cannot carry a `String` |

## Definition of done

| DoD item | Where it stands |
|---|---|
| Code reviewed and merged | Not applicable to this task run — the driver's step; **nothing was committed** (workflow rule). |
| All Gherkin scenarios covered by automated tests | The table above: 7/7 scenarios mapped, 24 tests. |
| A test asserts the full five-command vocabulary resolves in both languages | `testTheFullVocabularyResolvesInBothLanguages` (6 commands incl. both toggle states × 2 languages = 12 resolutions × 4 locales), `testEveryCommandHasAnEnglishAndANepaliForm`. |
| A test asserts a miss re-prompts once and no action is taken for a non-command | `testAMissRepromptsOnceAndTheTurnThenEndsExplicitly`, `testNoMissOutcomeCanActAndNoOutcomeCanCarryTheUtterance`. |
| A test asserts shipped intent phrases behave unchanged when the feature is closed | `testShippedIntentPhrasesAreNeverClaimedAsCommands` + `testNoShippedSourceCanReachTheParserWhileTheFeatureIsClosed`. |
| A test asserts the repeat path performs no translation, send or consent work | `testTheRepeatPathPerformsNoTranslationSendOrConsentWork` (source scan anchored on exact entry points: `translateStrings`, `GeminiClient`, `URLRequest`, `URLSession`, `ConsentGate`, `ConsentPromptController`, `authorize`, `Grant`, `costGovernor`, …), `testRepeatLastIsKeptAndCarriesNothing`. |
| `ios/build.sh` passes | `./build.sh build` — see § Verification performed. |

## Decisions made during implementation

1. **CL-8, `repeatLast`: kept, and traced here.** The design's C12 row names the case and the
   `LiveTranslateCommand` sketch in `specs/design-component.md` defines it; FR-LCT-022 explicitly
   permits it ("at minimum" read-all, the toggle phrase and stop/close); T-005 already catalogues its
   phrase in both languages; T-003 already ships `LiveTranslateSpeechMode.repeatLast` with the semantics written into
   the enum ("replayed from what was already spoken; it never re-translates, re-sends or re-consents").
   Dropping it would have meant deleting catalogued copy and a shipped speech mode. **The trace the
   review asked for**: the phrase is catalogued (`livetranslate.command.repeatLast`), parsing it yields
   `.repeatLast` (pinned by test), the command exposes `speechMode == .repeatLast` for T-024 to act on,
   it carries nothing (`Mirror` on the command shows no children other than the case), it writes no
   setting (`applySetting` returns `false`), and two source scans show the parser and the repeat path
   reach no translation, send, consent or cost code. The actual replay is T-024's; this task's job was
   to make the command exist, be matchable, and be provably inert beyond speech.
2. **CL-8, `SpokenOutput`: do not define it — use the shipped speech path.** `SpokenOutput` is named in
   exactly two places (the C12 row in `specs/design-component.md` and CL-8) and is defined nowhere. The
   repo already has the shipped speech interface: `Announcement(.interactive)` → `SpeakQueue`, and the
   design's own C12 prose says the speech half ends in that path. T-003 additionally ships
   `LiveTranslateSpeechMode` and the `speak_requested`/`speak_failed` events carrying the `mode` token.
   **Recommendation for T-024: build `Announcement`s on the shipped `SpeakQueue`, record the mode token,
   and do not introduce a `SpokenOutput` type** — it would be a second speech abstraction beside the one
   the project ships, and the design's phrase would remain undefined-but-implemented. This task exposes
   `LiveTranslateCommand.speechMode` as the seam and nothing else.
3. **Matching is whole-phrase after normalization — deliberately, with the grapheme hazard pinned.**
   Swift's `Character` is an extended grapheme cluster: the stop phrase "पढ्न रोक्नुहोस्" is **7
   Characters and 15 Unicode scalars**, so substring/prefix tests behave differently than the
   scalar-level search a Latin string suggests. `testAWordIsNotASequenceOfScalarsWhichIsWhyMatchingIsWholePhrase`
   pins the hazard both ways: a scalar-level `contains` says `true` where `String.contains` says `false`
   for a truncated cluster-aligned candidate, and every *fragment* of every phrase is asserted to be a
   near miss (`nil`), never an action. NFC normalization means canonically equivalent spellings match;
   nothing depends on where a cluster boundary falls.
4. **Both languages are always matchable; the active locale only orders the table.** An elder speaks
   their own language, which is configured independently of the app's display language. Restricting the
   match to the active language would re-prompt for a phrase the app itself ships. Ordering the active
   language first keeps the match deterministic even in the hypothetical where two languages carried the
   same normalized phrase for different commands (asserted).
5. **`setShowOriginal` writes through `setAlwaysShowOriginal(_:)`, not `toggleAlwaysShowOriginal()`.**
   Both are `LiveTranslateSettings`'s declared API and TG-01 pins that both paths write the one declared
   key (`livetranslate.alwaysShowOriginal`). A *value* write is what makes the voice path idempotent: a
   second "show the original" leaves the setting on, where a toggle would flip it off — for an elder a
   phrase that means the opposite the second time it is spoken is a defect. The test asserts the voice
   path and the touch path converge on the same stored value and that only one key is written.
6. **Unrecognised utterance is not an error — no error surface was invented.** `parse` returns
   `LiveTranslateCommand?`; the turn turns a miss into `.reprompt` once and then `.turnEnded`. No
   `Result`, no error enum, no thrown error, no "unknown command" token: C12's path is a re-prompt, not
   a failure. The `nil` contract is stated in the source and asserted in tests.
7. **The parser emits no events, and that is a finding rather than an omission.** The feature's event
   schema (`LiveTranslateEventCatalogue`, T-003) has **no command-matched or command-unmatched event**,
   and `specs/design-component.md`'s event table does not define one. Adding an event would mean
   changing `LiveTranslateEvents` + the catalogue + the log allow-list — shared files other agents were
   editing concurrently — on my own initiative. Instead the parser is **structurally silent**: it holds
   no bus, and its result can carry no `String`, so there is no path by which the utterance (or even the
   *identity* of the utterance) reaches the log surface. If per-command evidence is wanted, it is one
   deliberate catalogue entry (a closed `command` token, never the text) — reported as an open item, not
   invented here. The two speaking commands are already evidenced by T-003's
   `speak_requested`/`speak_failed` with `mode`.
8. **`LiveTranslateCommandTurn` exists so the re-prompt rule is testable in scope.** Capture is T-025's
   and dispatch is T-024's, so without the turn type the DoD's "a miss re-prompts once" could only be
   asserted as a comment. The type is pure (one `Bool`), makes every utterance produce an explicit
   outcome (command / reprompt / turnEnded), and hands T-025 an unambiguous rule to drive.

## Verification performed

Command — the **final** run, made after the last source edit. It used a private derived-data path,
because three agents' builds were sharing `build/DerivedDataTests` and one run died with
`unable to attach DB: error: accessing build database` (see Environment findings 6):

```
cd ios
./build.sh generate                       # XcodeGen — mandatory before testing new files
rm -rf build/TG08-parser-gate.xcresult
xcodebuild test \
  -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/DerivedDataT023 -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCommandParserTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCopyTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSettingsTests \
  -resultBundlePath build/TG08-parser-gate.xcresult
```

Result: **`** TEST SUCCEEDED **`**, zero compile errors, and
`xcrun xcresulttool get test-results summary --path build/TG08-parser-gate.xcresult` →
`result: Passed · totalTestCount: 49 · passedTests: 49 · failedTests: 0 · skippedTests: 0`
(iPhone 17, iOS 26.5 build 23F77, x86_64; "ElderlyAssistant · Built with macOS 26.6.2").

Per-suite (from the same run): `LiveTranslateCommandParserTests` **24/24** (all new),
`LiveTranslateCopyTests` 10/10, `LiveTranslateSettingsTests` 9/9, `LiveTranslateSourceHygieneTests`
6/6 — every suite this task could plausibly affect is in the gate.

`./build.sh build` (the DoD's build check): **`** BUILD SUCCEEDED **`**, exit code 0.

`./tools/check-release-log-safety.sh` (run from `ios/`) → **exit 0**.

The scoped gate was run repeatedly while the failures below were found and fixed, and twice more while
concurrent agents' in-flight files blocked the shared test target (Environment findings 3–4). The run
reported above is the last one: it started after the final source edit — a comment-only wording fix in
the production file's header (an over-broad "no Devanagari scalar at all" claim, now scoped to code,
since the same file's comments quote the phrases as documentation) — so it reflects the delivered
source. Real defects found and fixed in that loop:

- `Set<LiveTranslateCommand>` does not compile — the design pins `LiveTranslateCommand: Equatable` and
  the production type was kept exactly as pinned; three test assertions were rewritten without `Set`;
- my own offline scan false-positived on line 139 of the parser: the token `"translate"` matched inside
  the catalog-key literal `"livetranslate.command.readAll"` — fixed by anchoring the scan on precise
  entry-point identifiers (`translateStrings`, `GeminiClient`, `URLRequest`, …), never generic English
  words;
- `xcodebuild: error: Existing file at -resultBundlePath` if the bundle is not removed first.

### Full unit bundle — not obtainable in this window (reported honestly)

A full `ElderlyAssistantTests` run (all suites, to compare against the known-red baseline of ≈21
pre-existing failures) was attempted and **could not build**: the shared test target failed to compile on
**another agent's in-flight files**, `LiveOverlayPlacementGeometryTests.swift` (a bad
`LiveOverlayTextMetrics.measure` call) and the missing `OverlayRenderProbe` type it referenced — every
compile error named those files. Zero compile errors were reported in either of this task's files, and
the same log shows `LiveTranslateCommandParserTests.swift` compiling cleanly. The overlay agent fixed
the file while this task was running, and the scoped gate above then ran green on the same target. The
full-bundle baseline comparison itself was not re-attempted in this window: with other agents' suites
mid-edit, a full run's failures would not be attributable, and the scoped gate already covers every
suite this task could affect.

## Environment findings

1. **A generic English token scan false-positives on this feature's own catalog keys.** The substring
   `translate` occurs inside every key of the form `livetranslate.command.*`, so a "does this file reach
   the translation tier?" scan that looks for the word `translate` flags a file that merely names a
   catalog key. Scans in this feature must anchor on the exact entry-point spelling (`translateStrings`,
   `GeminiClient`, …). Recorded because later tasks in this group will write similar scans.
2. **The design pins `LiveTranslateCommand: Equatable`, so `Set<LiveTranslateCommand>` is unavailable.**
   Tests that want a set-like comparison must use arrays or `String(describing:)`. Adding `Hashable`
   would have been a design change made for the convenience of a test; it was not made.
3. **Concurrent agents share `build/DerivedDataTests` and the simulator.** Three `xcodebuild` runs from
   three agents were alive at once; and a neighbouring suite (`LiveTranslateSourceHygieneTests`) went red
   mid-session on another agent's in-flight `CloudTranslationTier.swift:153` and was green on the next
   run with no change from this task. A red run caused by a file you did not touch is not evidence about
   your own work — check which file the error names before reacting.
4. **A whole-target compile is blocked by any one agent's in-flight file.** Because `ElderlyAssistantTests`
   compiles as one target, a single mid-edit test file prevents *every* scoped gate from running,
   including one that names only your own suites. Two distinct halves, with two different remedies: the
   overlay agent's new `OverlayRenderProbe.swift` was on disk but not yet in the generated project — a
   `./build.sh generate` fixed that half for everyone; the same file's bad call to
   `LiveOverlayTextMetrics.measure` was a real source error that only its author could fix (they did,
   ~7 minutes later). Expect to wait, and re-run, rather than to conclude your own work is broken.
5. `./build.sh generate` before the first test run was reconfirmed as mandatory (consistent with TG-05's
   finding): a scoped run naming a class absent from the generated project **runs nothing and reports
   success**. Per-suite counts in the result bundle — not the exit code — are what verifies a green run.
6. **The shared build database is a second contention point beyond the generated project.** With three
   agents' `xcodebuild test` runs live against the same `-derivedDataPath`, one run failed to launch at
   all: `unable to attach DB: error: accessing build database … build.db is locked`. Retrying is the
   documented remedy, but the deterministic one is a **private derived-data path** for the run
   (`build/DerivedDataT023`), which is what the final gate used — at the cost of a cold build. The
   simulator itself may be shared safely (the `-destination` id was free throughout).

## What T-024 and T-025 must still do (and the seams left for them)

Nothing below was built here; each item names the seam this task leaves.

| Task | Must still do | Seam left |
|---|---|---|
| **T-024** (spoken output) | Perform `readAll` (speak visible regions top-to-bottom), `repeatLast` (replay the last spoken item), `stopSpeaking`, and the close acknowledgement. Build `Announcement`s on the shipped `SpeakQueue` — **not** a new `SpokenOutput` type (decision 2). Record `speak_requested`/`speak_failed` with the `mode` token. Decide and implement the honest behaviour for repeat-with-nothing-spoken. | `LiveTranslateCommand.speechMode` (`.readAll` / `.repeatLast` / `nil`); `LiveTranslateSpeechMode` (T-003, shipped). The ordering helper sketched as `LiveTranslateSpeech.orderedForReading` in the design belongs to this task, not to T-023. |
| **T-024 / T-025** | Render and speak the re-prompt copy. **There is no catalog key for it** — T-005's `LiveTranslateCopyTests` pins the catalog to an exact key set, so adding one is a deliberate copy change (open item 2). | `LiveTranslateCommandTurn.Outcome.reprompt` says *that* it happens, exactly once; the wording is theirs. |
| **T-025** (in-session capture) | Drive `LiveTranslateCommandTurn` with the utterance exactly as spoken (the entry phrase's wake word already stripped by the plugin's entry path, T-026), pause the microphone while speaking, and end the turn on `.turnEnded`. | `LiveTranslateCommandTurn.accept(_:locale:)` / `accept(_:in:)`; `LiveTranslateCommandParser.parse(_:locale:)`. |
| **T-026** (plugin wiring) | Consult the parser only while the session is open; while closed, the shipped pipeline must see the utterance unchanged (this task's scans establish the "nothing outside the feature can reach the parser" half). Note that the plugin's own entry phrase ("translate this" / "अनुवाद गर्ने") is **not** a session command and correctly returns `nil`. | The whole parser API; `applySetting(to:)` for the toggle phrase so the voice path and the touch control stay one write path. |

## Open items (reported, not silently closed)

1. **The re-prompt copy key does not exist.** C12 requires the elder be re-prompted once, but there is no
   catalog key for the re-prompt sentence, and T-005's pin (`LiveTranslateCopyTests.featureKeys` +
   `testTheCatalogHoldsExactlyTheFeaturesDeclaredKeys`) forbids adding one silently. T-024/T-025 must
   either add a key deliberately (updating T-005's pin, with the OD3 copy review) or speak no re-prompt —
   which would contradict C12. Flagged for the group.
2. **Near-miss utterances return `nil` by design.** A bare "stop" / "रोक्नुहोस्", "translate this",
   politeness wrappers ("please read this to me"), or a wake-word prefixed form are *not* commands — they
   are re-prompted. Aliases would need new catalog keys (and would re-open T-005's pin), so they were not
   invented. If the owner wants tolerance for wrappers, that is a copy/requirements decision.
3. **Per-command evidence events are not emitted** (decision 7). If `security-test` (T-029) or the
   observability review wants matched/unmatched evidence, it needs a deliberate
   `LiveTranslateEventCatalogue` entry plus its `LogSanitiser.allowedKeys` entry and a design-table row.
   The parser is silent today, and the utterance can never be the payload.
4. **`repeatLast` semantics under CL-8 stop at this task's boundary.** The command is kept and traced, but
   "the last spoken item is spoken again" is only true once T-024 implements the replay; nothing was
   stubbed to pretend otherwise.
5. **The full-bundle baseline comparison could not be run** (see § Verification): another agent's in-flight
   test file blocked the shared test target's compile. The scoped gate is the evidence for this task.
6. **`LiveTranslateCommandTurn` is a rule, not the session.** It decides the re-prompt; until T-025 drives
   it, no runtime path takes an utterance from the microphone to it. That is the group's sequencing, not a
   gap in this task.
7. **The design's own C12 sketch (`LiveTranslateSpeech.orderedForReading`) is unbuilt and untouched** —
   it belongs to T-024. No design text was edited by this task; `specs/design-component.md` is unchanged.
8. **`SpokenOutput` remains undefined in `specs/design-component.md`** (CL-8's second finding). The
   recommendation is in decision 2; resolving the phrase in the design text is a design-owner action, and
   this task's constraint forbids editing the design.
