# T-169 — NepaliGrammarGuard core (implement notes)

**Status: implemented, scoped suite green (37 tests).** Worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`). No commits, no `ai-sdd` mutating commands.

The unit arrived as an interrupted draft (both declared files untracked, the suite never
built). I audited it against the unit spec's acceptance criteria and DoD, fixed one compile
break and one false-pass hole, and added the pins the DoD was missing. The draft's contract
shape, embedded spec blocks, decode validation and spec-traceability tests were kept — they
were right — and are recorded below as the shipped design.

## What was built

### 1. `ios/ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift` (new — declared)

The pure, total, synchronous guard (design-l1 §7.1–7.4):

- `enum GrammarCheckClass: String, CaseIterable { honorificAgreement, devanagariPurity,
  danglingParticle }` — the spec's `guard_checks` ids are the raw values (pinned 1:1 by
  test; T-171 already keys the safe templates on these names).
- `enum GrammarGuardVerdict: Equatable { pass, flag(classes:), unavailable(reason:) }` —
  a classification only. `flag` carries classes in declaration order; `unavailable` carries
  a member of the closed `GrammarGuardUnavailableReason` set (`localeNotNepali`,
  `lexiconsUnavailable`, `inputNotDevanagari`, `inputEmpty`) as its raw value.
- `static func verdict(spokenText:locale:)` — the contract entry point; a `lexicons:` seam
  overload feeds the failure-path and data-not-code tests. No overload returns text.
- Compiled tables decoded from **four spec machine blocks embedded byte-verbatim** between
  `// @style-spec-block: <name>` / `// @style-spec-block-end: <name>` markers
  (`register`, `particles`, `code_switch`, `guard_checks`); the literal value equals the
  spec's fenced block body (Swift multiline-literal dedent semantics documented in-file —
  the extraction contract T-170's mirror check consumes). The executable rule prose is
  cited between `@style-spec-section:` markers; `python3 tools/train-intent/src/style_spec.py
  --check-consumers <guard>` is clean on the file today.
- Checks: honorific = token membership in `forbidden_address_forms` ∪
  `non_honorific_verb_forms` (exactly the eval's `honorific_violations` set); purity =
  mixed-script tokens plus Latin runs outside the spec's `latin_allowlist` (empty by the
  spec; the code-switch allowance is validated as a property of `code_switch.nouns`, never
  hard-coded); particles = longest-match occurrences over the spec lexicon with the
  positional dangling rule, budget from the spec.
- Decode is total: any malformed block is a `LexiconLoadFailure` (block/field names only,
  content-free), mapped to `unavailable`, never a default and never a crash.
- Purity: no I/O, no async, no state, no clock, no randomness, no logging — pinned by a
  source scan (the verdict is the only thing that can leave the type).

### 2. `ios/ElderlyAssistantTests/Services/Voice/NepaliGrammarGuardTests.swift` (new — declared)

37 tests. Gherkin mapping:

| Gherkin scenario | Tests |
|---|---|
| clean reply passes | `testCleanReplyPasses` |
| each class flags on its own evidence | `testFamiliarVerbFlagsHonorificAgreementOnItsOwnEvidence`, `testForbiddenAddressFormFlagsHonorificAgreementOnItsOwnEvidence`, `testLatinRunFlagsDevanagariPurityOnItsOwnEvidence`, `testMixedScriptTokenFlagsDevanagariPurity`, `testParticleOverBudgetFlagsDanglingParticle`, `testAllThreeClassesFlagInCanonicalOrder` |
| particle budget counts occurrences, longest match first | `testParticleBudgetBoundaryOneVersusTwo`, `testMultiWordUnitAtReplyStartIsNotDangling`, `testMultiWordUnitDoesNotSpanASentenceTerminator`, `testPartialParticleSubstringsInsideLargerWordsDoNotCount`, `testTokenizationKeepsDevanagariConjunctsWhole`, `testBudgetIsSpecDataNotHardCoded` |
| verdict is the only output / no rewrite path | `testVerdictIsAClosedClassificationCarryingNoText`, `testNoRewriteOrCorrectionEntryPointExists`, `testEveryObservedUnavailableReasonIsAClosedSetMember`, `testGuardSourceCarriesNoConsoleWriteNoIOAndNoNondeterminism` |
| unavailable on lexicon-load failure | `testLexiconLoadFailureIsUnavailableNeverPassNeverFlag`, `testLexiconDecodeRejectsMalformedData`, `testLexiconDecodeRejectsMissingRegisterFieldsAndLatinRenderings` |
| romanized input is not misjudged | `testRomanizedReplyDeclinesNeverFlagsNeverPasses`, `testMixedReplyWithDevanagariIsJudged`, `testLetterlessInputDeclinesAsEmptyInput`, `testNonNepaliLocaleDeclines`, `testLatinRunExtractionAgreesWithTheEvalRegexClass` |
| determinism and idempotence | `testDeterministicAndIdempotentAcrossRepeatedCalls`, `testTheCompiledTablesAreAReproducibleFunctionOfTheSpecBytes` |
| spec traceability (T-170's seam) | `testEmbeddedBlocksEqualTheSpecBlocksByteForByte`, `testCitationMarkersCarryTheSpecRuleTextByteForByte`, `testCompiledTablesEqualTheSpecsOwnValues`, `testCheckInventoryMatchesTheSpecsGuardChecksBlock`, `testHonorificPartnersBackEveryBannedFormInTheShippedSpec`, `testTheLatinAllowlistIsSpecDataNotHardCoded`, `testAmbiguousPairTableFormsAreNotFlagged` |
| golden-set boundary | `testBareCliticAtReplyStartIsDangling`, `testCliticFollowingOnlyASentenceTerminatorIsDangling`, `testTheReviewedGoldenSetsOpeningParticlesFlagUnderThePositionalRule` |

## What changed from the interrupted draft (audit result)

1. **The draft did not compile.** `testCompiledTablesEqualTheSpecsOwnValues` called
   `nouns.map(\.english)` on `[String: String]` (two errors). Fixed to
   `compactMap { $0["english"] }` / `["spoken"]`.
2. **False pass closed (real semantic fix).** The draft's multi-word particle match ignored
   the gap between the unit's words, so `हुन्छ। नि, ठीक छ।` matched `हुन्छ नि` across the
   sentence terminator and returned **pass** — while the spec's particles section (cited
   into the file byte-for-byte) calls that `नि` dangling. Reproduced with the draft
   algorithm before changing anything (python analogue, tokens
   `[हुन्छ, नि(। ), ठीक, छ]` → `count 1`), then fixed: a multi-word unit now matches only
   when contiguous inside one clause (no sentence terminator in the inter-word gaps); the
   later clitic is judged on its own position and flags. Commas/spaces still attach
   (`हुन्छ, नि हजुर।` passes).
3. **Pins added for DoD items that had none** (7 new tests + scan tokens):
   `testMultiWordUnitDoesNotSpanASentenceTerminator`,
   `testPartialParticleSubstringsInsideLargerWordsDoNotCount` (a word carrying a particle as
   a substring — नियम, अनिवार्य, निद्रा — is not an occurrence; a substring scan false-flags
   these), `testTokenizationKeepsDevanagariConjunctsWhole` (grapheme boundary: the न्छ
   conjunct stays in one token), `testTheLatinAllowlistIsSpecDataNotHardCoded`,
   `testLatinRunExtractionAgreesWithTheEvalRegexClass`,
   `testNoRewriteOrCorrectionEntryPointExists` (declaration-scoped source scan),
   `testTheCompiledTablesAreAReproducibleFunctionOfTheSpecBytes`; the purity scan now also
   rejects `async`/`await`.
4. Kept unchanged from the draft (correct as shipped): the verdict/class/reason types, the
   four byte-verbatim embedded blocks and citation markers, the decode validation rules
   (including the Latin-rendering check on `code_switch.nouns`), the locale/script input
   classification, and the spec-traceability suite.

## Test results (exact commands)

1. `cd /Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/ios && ./build.sh test:unit NepaliGrammarGuardTests`
   → `Executed 37 tests, with 0 failures (0 unexpected) in 0.148 (0.171) seconds`, `** TEST SUCCEEDED **`, exit 0.
   xcresult (final state): `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_21-31-27-+1100.xcresult`
   (intermediate green runs after the compile fix, the particle fix and the golden-set pin: 29 → 36 → 37 tests, same suite; the 37-test run on the same state at 21-29-52 is the earlier bundle.)
2. House gates (all green; both scripts also run inside `build.sh test:unit`):
   - `python3 tools/train-intent/src/style_spec.py --check-consumers ios/ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift`
     → `style-spec drift check: clean (1 consumer file(s)); version=1 sha256=64ada91d…46788`, exit 0.
   - `./ios/tools/check-release-log-safety.sh` → exit 0. `./ios/tools/check-prompt-mirror.sh` → exit 0.
3. Standalone guard checks (fast, outside the suite):
   - `swiftc -typecheck -swift-version 5 ios/ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift` → exit 0.
   - behavioural probe (`swiftc` harness in `/tmp`, the real guard file + a `main.swift`):
     confirmed the draft's cross-sentence false pass, then the fixed verdicts; all probe
     cases match the suite's expectations.
4. **Cross-artifact integration probe (evidence, outside the suite):** every reviewed reply
   in `tools/train-intent/eval/chat_golden.jsonl` (490 turns) through the real guard →
   **486 pass, 4 flag, 0 unavailable**. The four: `cg-b026-06`, `cg-b034-02`, `cg-b034-09`,
   `cg-b035-10` — all `danglingParticle`, all at count 1 (within budget), all positional:
   three open the reply with `अनि`, one opens a second sentence with `ल,` after `?`. Their
   own `expected_qualities` are `particles_within_budget: true` because the eval executes
   the **count only** (no positional rule) — see decision 3.

Build contention: two runs were cancelled by a sibling agent's build holding
`DerivedDataTests/.../build.db`; both times I waited for `xcodebuild` to exit and retried
(no DerivedData deletion, no `clean`), per the wave contract.

## Decisions and deviations

1. **Honorific rule = the two curated sets, exactly as the eval checks them.** Design §7.2
   glosses the verb leg as "a `non_honorific_verb_forms` token *whose honorific pair exists*
   in `honorific_pairs`"; the spec's register section is explicit that "the banned list is
   the curated flag set … the guard and the eval check exactly that set", and the eval
   (`author_chat_golden.py:honorific_violations`) executes the union with no pair-existence
   condition. The guard follows the spec + eval (one rule, two execution sites). The pair
   table is decoded, structure-validated, and pinned as a data property (every banned form
   has a partner on the shipped spec; भयो/छ stay out of the banned list). No behaviour
   difference exists on the shipped spec.
2. **Dangling rule (positional) as the spec states it.** A particle token with no clause to
   attach to — the reply's first token, or one preceded only by a sentence terminator — is
   dangling; commas and plain spaces attach. Sentence enders are the eval's
   `_SENTENCE_SPLIT_RE` class (`।॥!?\n`), so the two execution sites read the same
   boundaries. A multi-word unit carries its clause head, so only a one-token clitic can be
   positionally dangling — and only when contiguous (fix above). Consequence: the spec's own
   illustrative coverage example `ल, म बिदा हुन्छु हजुर।` flags; the rule text is the
   contract, the example is illustrative (pinned in the suite's comment).
3. **The golden-set tension is deliberate and reported, not papered over.** 4/490 reviewed
   golden replies flag under the positional rule (ids above). The golden set's review
   executes count-only, so those turns were never approved *against* the positional rule;
   the spec's rule text and design §7.2 both state it, and the house doctrine is "a rule
   changes HERE first" (design §7.2: "if this proves too strict in device testing it is a
   spec change, not a code exception"). The four texts are pinned in
   `testTheReviewedGoldenSetsOpeningParticlesFlagUnderThePositionalRule` so the decision has
   one deliberate-change site. **Coordinator/owner decision point for the wave gate**: keep
   the strict reading (and correct the golden authoring / accept the flag→template path for
   those 4 of 490 turns), or amend the spec's particles rule text — never a code exception.
4. **`unavailable` reasons are a closed, additive set.** Design §7.4 names lexicon-loading
   as the example; the implementation adds the input-class reasons the failure-path Gherkin
   requires (romanized → `inputNotDevanagari`, letterless → `inputEmpty`, non-Nepali locale
   → `localeNotNepali`). The set is `CaseIterable` and pinned by test; T-174 maps them to
   the degraded event. `unavailable` is never a pass.
5. **`latinRuns` / `tokenize` are internal on purpose** — the suite pins the eval-parallel
   Latin-run class and the grapheme token boundaries against them. Neither returns
   corrected or substituted text; the no-rewrite scan is declaration-scoped and the verdict
   type carries no text (exhaustive switch = compile-time pin).
6. **Data-not-code pins.** The budget, the lexicon, the allowlist and the code-switch
   exception property are all exercised through the `lexicons:` seam with mutated data
   (raise the budget → the same text passes; add "BP" to the allowlist → the run passes), so
   a hard-coded constant would fail the suite.
7. **Determinism across processes.** `compiledLexicons` is a pure function of the embedded
   bytes; the suite recompiles from those bytes and asserts the tables are identical
   (in-process proof of NFR-CNR-001's cross-session stability; the device leg stays a DV
   item).
8. **No call site in this unit.** The guard is not referenced by production code yet —
   T-174 wires it at the dispatch seam, and T-171's template keys are already 1:1 with the
   class raw values. The scoped suite is the honest gate for this unit.
9. **`ios/seniOS.xcodeproj/project.pbxproj`** carries the two files' entries (generated by
   `build.sh`/XcodeGen from `project.yml` in this shared worktree — not hand-edited; the
   diff also carries sibling units' entries).

## Open items

- **T-170 (blocks on this unit):** the four embedded blocks and the `@style-spec-block:` /
  `@style-spec-block-end:` markers are the mirror surface; the file's header documents the
  Swift multiline-literal extraction semantics (dedent by the closing delimiter's
  indentation; the newline before it is not part of the value). The section citations
  already pass the loader's `--check-consumers`.
- **T-174 (blocks on this unit):** consumes `GrammarGuardVerdict`, the class raw values
  (space-joined for the event) and the reason raw values; the verdict is classification-only
  by construction.
- **Golden-set decision (above, decision 3)** — the one item the coordinator must surface at
  the wave gate: 4 reviewed replies (`cg-b026-06`, `cg-b034-02`, `cg-b034-09`,
  `cg-b035-10`) flag under the spec's positional dangling rule; the fix, if the owner wants
  one, belongs in the spec's particles section (then the guard's cited text and pins move
  with it).
- **Device validation:** none claimed for this unit — the guard is pure and its behaviour is
  fully pinned in-process; T-186's sweep can exercise it end-to-end once T-174 wires it.
