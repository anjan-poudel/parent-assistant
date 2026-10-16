# TG-10 — Release gates and evidence: T-028 log-safety gate extension, T-029 security evidence suite, T-030 device validation protocol + results

**Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation`
(branch `worktree-live-camera-translation`, based on `95eb635acfe637096bf87a45162429b06cefb5a3`, changes uncommitted by instruction)
**Status:** implemented and verified in the worktree. Nothing committed; no `ai-sdd` command was run; `.ai-sdd/` was not touched; the file `specs/TG-10-notes.md` (a different feature's, tracked in git) was **not** written, modified or deleted — this file is `specs/LCT-TG-10-notes.md` by instruction.
**No product Swift source was changed by this group.** T-028 changes the gate's Python engine and its fixtures; T-029 and T-030 add tests and specs. The only shipped-document edit is the AM-5/SD-2 correction in `specs/design-component.md`.

---

## What was built

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/tools/check-release-log-safety.py` (818 lines, modified)

The B1/T-049 Release log-safety gate, extended with the feature's rule family over the feature's scan
roots (`Services/LiveTranslate/`, the Gemini translation client file). Four rules added:

| Rule id | Fires on | Configuration |
|---|---|---|
| `feature-console-write` | any console write in the feature's roots | **Release only** (a `#if DEBUG` region cannot be compiled into Release — keeps the shipped framing) |
| `feature-content-print` | a console write that renders recognized/translated text | **every configuration** — NFR-LCT-006 says content must not reach a log surface "in any build", and the feature has no legitimate content-bearing console write |
| `feature-unlisted-metadata-key` | an event metadata key outside `LogSanitiser.allowedKeys` | every configuration |
| `feature-text-interpolated-into-event` | a text value interpolated or rendered into an event field | every configuration |

Rules 3 and 4 are deliberately orthogonal: rule 3 catches the bypass whatever it renders, rule 4
catches content even where the Debug exemption would apply. Each positive fixture therefore trips
exactly one rule.

Also added: `--list-rules` (the registry, which the fixture harness reads), `--source-root`, `--quiet`,
`--disable-rule`, and a "Known limitations" docstring section. `--disable-rule` is deliberately
**command-line only** — no environment variable, config file or build setting can reach it, so it
cannot weaken a build; it exists for exactly one caller, the fixture suite's falsification run.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/tools/check-release-log-safety-fixtures.py` (229 lines, new)

The gate's own test suite, which did not exist in HEAD. Runs the real engine as a subprocess over
every fixture tree and inspects the real exit code — not imported, not stubbed. A `positive` case must
exit 1 **and name its rule**; a `negative` case must exit 0. A rule with no fixture is a failure, not
a skip, and a fixture directory that is not a declared rule is a failure too (a typo would silently
test nothing).

`--falsify` is the second discipline: for every rule, the engine re-runs its positive fixture with
`--disable-rule <rule>` and the case passes only if the gate **stops catching it**. A rule whose
positive fixture still fails with the rule disabled fires only in company and is reported as such.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/tools/check-release-log-safety.sh` (45 lines, modified)

Now runs the engine **and** the fixture suite; the fixture suite is non-optional. Failure is exit 1.
The script stays wired into `ios/build.sh`'s `run_tests` ahead of every test scope (that wiring is
pre-existing from B1/T-049 and was not touched — `ios/build.sh` is unmodified by this task).

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/tools/log-safety-fixtures/` (new)

24 fixtures over 12 rules: a `positive/` and a `negative/` tree for **every** rule the engine declares
— the 8 pre-existing voice rules and the 4 feature rules. New/rewritten feature fixtures:
`feature-console-write/` (positive: a Release-compiled content-free `print`; negative: a `#if DEBUG`
trace), `feature-content-print/` (positive: `debugPrint(translation)` and `print(region.text)` inside
`#if DEBUG` — rule 4 alone; negative: content-free Debug prints), `feature-unlisted-metadata-key/`,
`feature-text-interpolated-into-event/`, plus `log-safety-fixtures/README.md` (42 lines) describing
the layout and the two rules of the suite.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/ElderlyAssistantTests/Services/LiveTranslate/SecurityEvidenceBoundaryTests.swift` (604 lines, new)

Suite `SecurityEvidenceBoundaryTests`, 7 tests. Every assertion is made at a **boundary**: the client
double (`TierTranslationTransport`, which records every `URLRequest`), the log bus (`EvidenceRecorderBus`,
defined in this file — it keeps the raw event *and* the sanitised one, so "the emitter never produced
a bad key" can be told apart from "the sanitiser dropped it"), and the storage double. No test asserts
on a product internal.

| Test | Property |
|---|---|
| `testAM10EveryRecordedRequestCarriesOneTextPartAndNoMediaOfAnyKind` | Every recorded request decoded: exactly one content, one text part, no media/structure field at any level; the **retry** is inspected too |
| `testAM10TheBuiltBodyCarriesOnlyTheItemsAndTheLanguageParameters` | Exact top-level key set (`contents`, `generationConfig`), exact `generationConfig` key set, item entries restricted to `id`/`text`/`sourceLanguage`, instruction region free of scene text |
| `testAM1AM10AWithdrawalMidSceneLeavesZeroFurtherRequests` | Withdrawal mid-scene: no retry, later cycles issue **zero** requests, indicator off, zero in-flight, one billable call — and the expected answers would have *succeeded*, so a regression shows as a rendered translation, not a quiet degradation |
| `testAM10NoResultClaimsATierWithoutATranslation` | Swept over a run producing dictionary, cloud, cache-hit, quarantined and degraded outcomes: a result claims a tier only with a non-empty translation, otherwise it is honestly degraded, and never renders blank |
| `testAM9TheFeatureAddsNoUpstreamDerivedErrorCodeAndTheShippedResidualIsPinnedOnce` | With a token-shaped provider reason: the reason appears on exactly **one** event, on the pre-existing `gemini_client`/`gemini_blocked` site, never on a `livetranslate` event; the block surfaces as `translation_degraded` with `reason = provider_rejected` and **no error_code at all** |
| `testAM10AContentRichRunEmitsNoFeatureEventCarryingTextAndNoUnlistedKey` | Under a run where translations, quarantine and consent states all occur (asserted, anti-green-by-emptiness): no feature event carries text, every key is allow-listed **before** sanitisation, and no feature event is altered by sanitisation (the CL-5 fix, checked at the boundary) |
| `testAM10StructuralCharactersMarkerShapesAndOverLongTextCannotAlterTheRequestOrTheIDSet` | JSON-shaped, multi-line, marker-phrase, over-long, punctuation, control-character and **reconstituted-marker** strings: wire ids are exactly the positional enumeration, entry count and keys are exact, no string travels carrying a live marker, and each resolved translation is its own |

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/ElderlyAssistantTests/Services/LiveTranslate/SecurityEvidenceIndexTests.swift` (323 lines, new)

Suite `SecurityEvidenceIndexTests`, 5 tests. This is what keeps the index from rotting: every
amendment AM-1…AM-10 must name at least one test, **every** test named anywhere in the index must
exist in the target (and the suite must declare it), every test in the boundary suite must be indexed,
the index's residual/limitation/gap sections must exist and name SR-1, and AM-5's enforcement point
must actually be wired (engine + shell + fixture runner exist, the shell runs the fixture suite,
`build.sh` calls the gate inside `run_tests` **before** the first `xcodebuild`, and every rule the
engine declares has both fixtures). It asserts existence and structure, never passing status.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/ElderlyAssistantTests/Services/LiveTranslate/OCRFixturePageTests.swift` (166 lines, new)

Suite `OCRFixturePageTests`, 1 test — T-030's runnable half. Renders an 8-line menu page with CoreText
into a 1200×800 `CameraFrame` and reads it through the real `LiveTextDetector`/Vision path: several
regions, sane unit-square boxes, honest `regionCount`, no recognized text in any event field. It
records its measurement as an `XCTAttachment` (`ocr-fixture-measurement`) so the results record cites
a **number** rather than a threshold — counts only, never text.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/specs/LCT-security-evidence-index.md` (235 lines, new)

The one document the `security-test` gate reads: amendment → evidence tables (AM-1…AM-10, with AM-5
marked as a build gate rather than an XCTest), a table for guards outside the amendment list (the spend
latch, failure isolation), the E1–E8 egress-path enumeration with status, residual risks, known
limitations of the evidence, and 8 numbered **gaps** — paths that could not be exercised, recorded as
gaps rather than covered by assertion.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/specs/LCT-device-validation-protocol.md` (281 lines, new)

T-030's protocol: DV-1 … DV-16, each with procedure, pass condition, measurement method, recording
slot, and the named design parameter (OD1/OD2/OD5) a failure would edit — plus the recording rules
(including: every row names device model, OS version and build identifier; measurements and decisions
are different columns; the protocol is not edited to match the results).

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/specs/LCT-device-validation-results.md` (102 lines, new)

T-030's results record. **No device run happened**: every DV-1…DV-16 row reads **NOT RUN** with its
reason, and the five measurements that *were* taken are labelled as simulator measurements with the
simulator's device id and OS build. Owner actions are listed separately from measurements.

### `/Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/specs/design-component.md` (modified)

AM-5/SD-2 correction: the Observability section now states the four rules with their configuration
semantics, says the gate runs its own fixture suite, and has a "Stated limits, not implied ones"
paragraph naming `LiveTranslateAllowListTests` as the primary safeguard. The security-invariant table
row for "No recognized or translated text on the log surface" now names the runtime allow-list and the
four roots, and instructs reviewers to treat gate-invisible indirection as a gap.

---

## Decisions made during implementation

1. **A rule without a positive fixture is not a rule; a rule that fires only in company is not
   carrying its own weight.** Both are enforced mechanically (`--falsify`), not by convention.
2. **Rules 3 and 4 are orthogonal by design.** Making rule 4 configuration-independent was necessary
   for the falsification discipline: with a single content rule, disabling it did not make the
   positive fixture pass (`#if DEBUG` still tripped the console-write rule), which would have made
   "is this rule load-bearing?" unanswerable.
3. **`--disable-rule` is CLI-only.** It could not be allowed to be reachable from a build setting,
   because a rule that can be disabled by configuration is a rule that will be.
4. **The fixture suite runs in the build path; the falsification run does not.** Falsification is
   slower and destructive by intent, so it is a recorded manual run (M-5) rather than a per-build
   assertion — and the index says so rather than implying per-build falsification.
5. **Tests were corrected to the product's real guarantees, never weakened to go green.** Four of my
   first assertions were wrong about the product: (a) a curated-dictionary answer is reported as
   `.cache(.curatedDictionary)`, not `.cache(.persisted)`, and is not re-sent; (b) the translation
   client addresses items by **position**, so the ids on the wire are the batch enumeration rather
   than the caller's ids; (c) a provider block degrades as `translation_degraded` with
   `reason = provider_rejected` and **no** `error_code`, not as an event carrying
   `cloud_policy_blocked`; (d) a string whose marker is *stripped* is sent (stripped) rather than
   quarantined — only a **reconstituted** marker (the T-004 residual shape) quarantines. Each was
   corrected to assert the property the product actually guarantees; none was deleted.
6. **`FeatureSourceScan`/`repositoryRoot` reads the repo from the test's own path** rather than a
   hard-coded absolute path, so the evidence tests move with the checkout.
7. **T-032's byte-level ciphertext test is indexed as the cache-at-rest evidence, not duplicated**
   (instruction carried from the briefing): the index names
   `LiveTranslateCipherStorageTests.testAM10CacheAtRestInspectionOfTheAppContainerFindsNoPlaintext`
   and its two siblings, and records the *device container* as a gap.
8. **T-030 records rather than approximates.** The fixture OCR pass is recorded as a simulator
   measurement (M-1) with its numbers, never as a device check, and the protocol is not edited to
   match what happened.

## Amendment → evidence

| Amendment | Evidence (named test, gate, or recorded gap) |
|---|---|
| AM-1 | `CloudTranslationTierTests.testAM1A…` (3), `LiveTranslateConsentGateTests.testAWithdrawalBetweenTwoAttemptsDeniesTheRetry`, `CloudTranslationTierTests.testNoConsentRecordMeansZeroRequestsAndAnHonestReason`, `SecurityEvidenceBoundaryTests.testAM1AM10AWithdrawalMidSceneLeavesZeroFurtherRequests` |
| AM-2 | `LiveTranslateAllowListTests` (24 tests incl. per-key survival and the real console sink), `SecurityEvidenceBoundaryTests.testAM10AContentRichRunEmitsNoFeatureEventCarryingTextAndNoUnlistedKey` |
| AM-3 | `SceneTextSanitiserTests.testTheSanitiserConsultsTheShippedSeamAndRestatesNoMarkerFamily`, `…testTheVerdictAgreesWithTheShippedSeamOnEveryFixture` |
| AM-4 | `LiveTranslateConsentGateTests` (6 named revocation/read-back tests) |
| AM-5 | **Build gate, not an XCTest:** `ios/tools/check-release-log-safety.{py,sh}` + the fixture suite + `--falsify` (M-4, M-5) + `specs/design-component.md` + `SecurityEvidenceIndexTests.testAM5TheGateIsWiredAheadOfEveryTestScopeAndEveryRuleHasFixtures` |
| AM-6 | `LiveTranslationPipelineTests.testAM6TheMonotoneOrderingCounterNeverRegresses` |
| AM-7 | `GeminiClientTranslateTests.testAM7TheConsentParameterHasNoDefaultSoNoCallCanSkipTheGate`, `…testAM7AProofForAnotherDisclosureCopyFailsClosedWithNothingBuilt`, `…testAM9TheSignatureHasNoMediaToolOrAttachmentParameterAndExactlyOneCallSite` |
| AM-8 | `CloudTranslationTierTests.testAM8AKeyAlreadyInFlightIsNotRequestedAgainAndBothRegionsResolve`, `…testAM8NoRegionIsLeftPendingWhenItsKeyIsBridged`, `…testTwoRegionsWithTheSameStringInOneCycleAreOneRequestWithOneOutcome` |
| AM-9 | `GeminiClientTranslateTests` (4 tests incl. the prompt-boundary separation), `SecurityEvidenceBoundaryTests.testAM9TheFeatureAddsNoUpstreamDerivedErrorCodeAndTheShippedResidualIsPinnedOnce` |
| AM-10 | The eight assertions of the AM-10 table in the index, each with a named test; cache-at-rest rows point at T-032's tests; logs/events row at the boundary suite |
| SR-1 (residual, **not retired**) | Pinned, not removed: exactly one `gemini_client`/`gemini_blocked` event carries the provider reason, no `livetranslate` event does |
| E1–E8 | E1–E5 and E8 exercised; **E6 partially** (session layer only) and **E7 not exercisable** (the path does not exist) — both recorded as gaps |

## Gherkin coverage

### T-028

| Scenario | Evidence |
|---|---|
| A Release build fails when the feature logs content | `feature-console-write/positive` fails with the rule named; the shell gate exits 1 and `build.sh`'s `run_tests` exits 1 (not a warning); `SecurityEvidenceIndexTests.testAM5…` pins the wiring |
| The new roots are covered and the gate exits clean on the final sources | M-4: `bash ios/tools/check-release-log-safety.sh` → **exit 0** over the real tree |
| The rule family covers the real failure modes | 4 rules × (positive + negative) fixtures; 24 cases over 12 rules; README.md; M-5 falsification |
| The gate does not create false confidence | The engine's "Known limitations" section; the index's "Known limitations of the evidence"; the corrected `design-component.md` invariant table naming `LiveTranslateAllowListTests` as the primary safeguard |
| Existing rules and their fixtures still pass | All 8 pre-existing rules have both fixtures and behave; `mentions_transcript`, `is_error_identifier`, `strip_line_comments`, `paren_balance` are **AST-identical** to HEAD, and `error_object_offence`/`interpolation_bodies` differ only in returning the rule id / using the extracted `_interpolation_end` helper. See "Open items" for what this does *not* prove |

### T-029

| Scenario | Evidence |
|---|---|
| Every mandatory amendment has a named test | Index AM-1…AM-10 tables; `SecurityEvidenceIndexTests.testEveryAmendmentMapsToAtLeastOneNamedTestThatExists` |
| Consent guards proven by refusal, not only success | `LiveTranslateConsentGateTests` (unreadable, lying delete, failed delete, relaunch, silent-withdrawal); `…testNoConsentRecordMeansZeroRequestsAndAnHonestReason` |
| Zero requests are observed without a record | `CloudTranslationTierTests.testNoConsentRecordMeansZeroRequestsAndAnHonestReason` (0 requests, 0 billable, no indicator, typed reason); `…testAQuarantineAloneSendsNothingAndNeverShowsTheIndicator`; the retry's request is decoded in `SecurityEvidenceBoundaryTests.testAM10EveryRecordedRequestCarriesOneTextPartAndNoMediaOfAnyKind` |
| Egress is text-only and single-channel | `…testAM10EveryRecordedRequestCarriesOneTextPartAndNoMediaOfAnyKind`, `…testAM10TheBuiltBodyCarriesOnlyTheItemsAndTheLanguageParameters` |
| Structural characters and marker shapes cannot change behaviour | `GeminiClientTranslateTests.testAM10ASceneStringCannotAlterTheRequestsStructureOrItsIDs`, `SecurityEvidenceBoundaryTests.testAM10StructuralCharactersMarkerShapesAndOverLongTextCannotAlterTheRequestOrTheIDSet` |
| Logs and events are content-free under a content-rich run | `…testAM10AContentRichRunEmitsNoFeatureEventCarryingTextAndNoUnlistedKey` |
| The cache is encrypted at rest on a real write | T-032: `LiveTranslateCipherStorageTests.testAM10CacheAtRestInspectionOfTheAppContainerFindsNoPlaintext` + 2 siblings, indexed rather than duplicated |
| The spend guard holds under repeated pressure | `CloudTranslationTierTests.testASpentBudgetIsRefusedBeforeAnyRequestAndLatchesForTheSession`, `…testABudgetThatRunsOutWhileInFlightLatchesAndBlocksTheRetry`, `…testTheShippedGovernorCountsEveryBillableAttemptAndNothingElse` |
| Every enumerated egress path is exercised | E1–E8 table; E6 partial and E7 non-existent, both recorded as gaps |
| The evidence index states what was not proven | Residual risks, known limitations, 8 numbered gaps; `SecurityEvidenceIndexTests.testTheIndexRecordsResidualRisksKnownLimitationsAndUnexercisedPaths` |

### T-030

| Scenario | Evidence |
|---|---|
| The protocol names every device-only check | DV-1…DV-16 with pass condition, measurement, recording slot and the OD1/OD2/OD5 parameter a failure would edit (incl. DV-14 memory/NFR-LCT-005, DV-15 frame pacing/oldest supported device, DV-16 the clamped callout T-020 deferred) |
| The fixture-image OCR pass runs on the simulator | M-1: `OCRFixturePageTests` in the standard invocation — 8 regions from 8 lines, 6/6 expected words, boxes sane |
| The manual device scenarios are run as written | **NOT RUN** — no device. Recorded per row in the results file |
| Sustained use does not degrade into an unusable state | **NOT RUN** (DV-2/DV-10/DV-15) — no device, no thermal envelope |
| Memory stays under the ceiling in a dense scene | **NOT RUN** (DV-14) — no device, no Instruments run |
| Everything that works online works offline | **NOT RUN** (DV-4/DV-12) — no genuine airplane-mode run possible; the scripted `URLError` path is covered by tests and is *not* claimed as the offline check |
| The microphone path is validated with audio in use | **NOT RUN** (DV-8) — no device; flagged as input to the OD-12/OD-13 review |
| Results are recorded honestly, including gaps | The results record: every row NOT RUN with its reason, and no device model/OS/build/measurement invented |
| A defect found by the protocol becomes a traced fix | No defect was found by the checks that ran (M-1…M-5 all passed); stated as "no traced fix to report", scoped to the runnable subset |
| The record separates measurements from owner decisions | §2 measurements vs §4 owner actions (OA-1…OA-5) |

## Definition of done

**T-028:** all five boxes are met — each new rule has both fixtures with the pre-existing rules'
fixtures passing alongside; the gate blocks the build in the standard path; the evasion case is
documented in the engine's own limitations and in `design-component.md`; `ios/build.sh` passes.
*Not merged* (no commits are permitted in this worktree).

**T-029:** every box met except the merge; the index maps each amendment to named, **passing** tests
(205/205 in the recorded gate run); every guard has a refusal test; zero-request evidence is at the
instrumented client double; integration runs against the stubbed transport/storage; a crash of the
translation path is recorded as a gap (in-process crashes cannot be asserted) while a hang is covered
by the deadline test.

**T-030:** protocol and results exist with every scenario either covered or recorded NOT RUN with its
reason; the fixture OCR pass runs in the standard invocation; owner decisions are separated from
measurements; `ios/build.sh` passes. *Not merged.*

## Verification performed

Mandatory pre-step (XcodeGen globs new Swift files in; `project.pbxproj` is generated and was never
hand-edited):

```
cd /Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios
./build.sh generate
```

The gate run — every suite the evidence index names, plus T-030's fixture suite:

```
cd ios
xcodebuild test \
  -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/TG10DerivedData -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/CloudActivityIndicatorTests \
  -only-testing:ElderlyAssistantTests/CloudTranslationTierTests \
  -only-testing:ElderlyAssistantTests/GeminiClientTranslateTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateAllowListTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCipherStorageTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateConsentGateTests \
  -only-testing:ElderlyAssistantTests/LiveTranslatePluginTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSessionModelTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/LiveTranslationPipelineTests \
  -only-testing:ElderlyAssistantTests/SceneTextSanitiserTests \
  -only-testing:ElderlyAssistantTests/SecurityEvidenceBoundaryTests \
  -only-testing:ElderlyAssistantTests/SecurityEvidenceIndexTests \
  -only-testing:ElderlyAssistantTests/OCRFixturePageTests \
  -resultBundlePath build/TG10-gate.xcresult
```

Result: **`** TEST SUCCEEDED **`**; `xcrun xcresulttool get test-results summary --path
build/TG10-gate.xcresult` → `result: Passed · passedTests: 205 · failedTests: 0 · skippedTests: 0` on
iPhone 17, iOS 26.5 (23F77), x86_64, iOS Simulator.

Per suite, read from the same bundle with `xcrun xcresulttool get test-results tests` — never from the
exit code, because a suite whose class is missing from the generated project runs nothing and reports
success:

| Suite | Tests | Result |
|---|---|---|
| `CloudActivityIndicatorTests` | 15 | all passed |
| `CloudTranslationTierTests` | 25 | all passed |
| `GeminiClientTranslateTests` | 15 | all passed |
| `LiveTranslateAllowListTests` | 24 | all passed |
| `LiveTranslateCipherStorageTests` | 16 | all passed |
| `LiveTranslateConsentGateTests` | 29 | all passed |
| `LiveTranslatePluginTests` | 10 | all passed |
| `LiveTranslateSessionModelTests` | 17 | all passed |
| `LiveTranslateSourceHygieneTests` | 6 | all passed |
| `LiveTranslationPipelineTests` | 18 | all passed |
| `SceneTextSanitiserTests` | 17 | all passed |
| `SecurityEvidenceBoundaryTests` | 7 | all passed |
| `SecurityEvidenceIndexTests` | 5 | all passed |
| `OCRFixturePageTests` | 1 | all passed |

Self-check on the three suites this group added (a scoped re-run earlier in the same session, for the
record of a narrower command): 13 tests, 0 failures.

The gate itself:

```
bash ios/tools/check-release-log-safety.sh          # exit 0 — 24 fixture cases over 12 rules
python3 ios/tools/check-release-log-safety-fixtures.py --falsify   # exit 0 — 36 cases; 12/12 rules load-bearing
./build.sh build                                    # exit 0 — compile-check, 0 warnings, 0 errors
```

T-030's measurement, recovered from the bundle (counts only, no recognized text):

```
xcrun xcresulttool export attachments --path build/TG10-evidence.xcresult \
  --test-id "OCRFixturePageTests/testADenseMenuLikePageIsReadAsSeveralRegionsWithSaneBoxes()" \
  --output-path /tmp/tg10-attach
→ {"fixtureLines": 8, "regions": 8, "nonEmptyRegions": 8, "expectedWordsRead": 6, "expectedWords": 6}
```

(`build/TG10-evidence.xcresult` is the scoped three-suite bundle; the same attachment is produced by
the full gate run above, which includes `OCRFixturePageTests`.)

**Coverage of new code.** This group adds no product Swift, so there is no new production path to
cover. The new *executable* code is the Python fixture harness, exercised by its own runs (24 + 36
cases, and it is the thing that asserts on the engine); the new Swift is test code, whose job is
assertion rather than coverage of a product surface. The product suites named above are unchanged in
count — this group added tests, not product code.

## Environment findings

1. **A bootstrap crash is not a test failure.** One invocation of the evidence suites ended
   `Early unexpected exit, operation never finished bootstrapping (Test crashed with signal term
   before establishing connection)` and attributed three failures to an index test that had not run.
   The re-run of the identical command completed 13/13. Per the standing hazard note, this is
   simulator contention under load and is recorded as noise, not as a defect.
2. **The machine was at load average 150–390** for most of this session (simulator runtime processes
   from concurrent work, plus background indexing). The same OCR test took 28.9 s under load and 3.58 s
   without it. Timings from this session are not performance measurements.
3. **A concurrent agent's mid-edit file broke the test-module compile once**
   (`ElderlyAssistantTests/Services/LiveTranslate/SnapshotModeTests.swift`, a file this group does not
   own). Per the standing rule, it was left untouched; the run was retried after the owner's edit
   landed and compiled. `ElderlyAssistantTests` compiling as one unit means another agent's file can
   fail your build — it does not mean the failure is yours.
4. **`./build.sh generate` remains mandatory before any gate run**: the three new Swift files were
   globbed in by XcodeGen, and without the regenerate they would have run nothing while reporting
   success.
5. **The evidence index is now self-policing, and it caught two of my own defects**: a literal
   `SuiteName.testName` placeholder and two ellipsis-truncated test tokens in the E5/E6 rows. Both were
   real (a reader would have taken them for test names) and both are fixed.

## Open items and gaps (reported, not silently closed)

1. **No device run happened.** Every DV-1…DV-16 check is NOT RUN; OD1, OD2 and OD5 have **no
   measurement** behind them. The owner actions are listed in
   `specs/LCT-device-validation-results.md` §4 — the device run itself is OA-5.
2. **The pre-existing rules were refactored, not merely appended to.** `scan`/`_judge` became a
   per-region judge with a rule registry, and `error_object_offence`/`interpolation_bodies` were
   touched (returning a rule id; using the extracted `_interpolation_end`). An AST comparison shows
   `mentions_transcript`, `is_error_identifier`, `strip_line_comments` and `paren_balance` identical to
   HEAD, and the change to `error_object_offence` is *only* the added rule id. What is **not** proven:
   that the old and new engines agree on arbitrary inputs. What is proven: all 8 pre-existing rules
   fire on their positive fixtures and stay quiet on their negatives, and the shipped tree passes.
   This is recorded rather than glossed.
3. **No pre-existing fixture suite existed in HEAD**, so "the existing fixture suite passes unmodified"
   could not be satisfied literally: the fixtures for the 8 pre-existing rules were written in this
   task, alongside the 4 new rules'. They are covered by the same falsification discipline.
4. **AM-5's gate cannot see through indirection** — a helper's return, a `metadata:` variable, a
   wrapper function, an unknown sink spelling. This is documented in the engine, in the index and in
   `design-component.md`; the runtime allow-list (`LiveTranslateAllowListTests`) remains the primary
   safeguard.
5. **Falsification is not in the build path.** It is a recorded run (M-5), not a per-build assertion.
   A rule could regress to "fires only in company" between falsification runs; the fixture suite would
   still catch a rule that stops firing entirely.
6. **E6 (backgrounding) is exercised only at the session layer**, E7 (prefetch) does not exist, and
   neither is claimed as covered at the transport boundary.
7. **A genuine crash of the translation path cannot be asserted in-process**; a hang is covered
   (deadline test), and the isolation claim is structural. Recorded as gap 8 in the index.
8. **The `hi-in` probe finding** stays a recorded finding (`specs/hi-in-probe-notes.md`), not
   re-litigated here.
9. **Nothing is committed.** Per instruction this worktree's work stays uncommitted for the parent to
   integrate; the notes above describe the tree as it stands, not a commit.

## Addendum — independent verification pass (2026-09-17, 08:10)

A second TG-10 agent ran concurrently with the one that wrote the body above (the briefing that
started it asserted prior attempts had been killed before writing anything — that was not the case).
It wrote none of this group's artifacts and edited none of them; it re-derived every load-bearing
number from the recorded bundles and the live tree, so the parent can integrate on evidence that was
read twice rather than on one agent's word.

| Claim in the body | Re-derived by | Result |
|---|---|---|
| Full gate run: 205 tests, 14 suites, 0 failures | `xcrun xcresulttool get test-results summary --path ios/build/TG10-gate.xcresult` | `result: Passed · passedTests: 205 · failedTests: 0 · skippedTests: 0` — iPhone 17, iOS 26.5 (23F77), x86_64, iOS Simulator |
| Per-suite counts in the table above | `… get test-results tests --path ios/build/TG10-gate.xcresult`, counted per suite | Matches the table **suite by suite**, including the three new suites (7 + 5 + 1). No suite in the `-only-testing:` list ran zero tests |
| M-1 fixture-OCR measurement | `xcrun xcresulttool export attachments … --test-id "OCRFixturePageTests/testADenseMenuLikePageIsReadAsSeveralRegionsWithSaneBoxes()"` | `{"fixtureLines": 8, "regions": 8, "nonEmptyRegions": 8, "expectedWordsRead": 6, "expectedWords": 6, "fixture": "menu-page-1200x800-44pt"}` — identical to M-1 |
| M-4 gate exits clean | `bash ios/tools/check-release-log-safety.sh` | exit 0 — 24 fixture cases over 12 rules |
| M-5 every rule is load-bearing | `python3 ios/tools/check-release-log-safety-fixtures.py --falsify` | exit 0 — disabling any single rule makes its positive fixture pass; 12/12 rules carry their own weight |
| AM-5 wiring ahead of every test scope | read of `ios/build.sh` (unmodified) | gate called inside `run_tests` before the first `xcodebuild` line; the passing index suite enforces the same property mechanically |
| Index names only real tests | the passing `SecurityEvidenceIndexTests` (5/5) | `testNoTestNamedAnywhereInTheIndexIsMissingFromTheTarget` is the machine check; 62 `Suite.test` tokens in the index all resolve |
| Worktree state | `git log -1`, `git status --porcelain` | HEAD `95eb635`, nothing committed; the four `specs/LCT-*` documents and the feature tree are untracked additions |

**Not re-derived by the verification pass:** `./build.sh build` (the compile check). It was omitted
deliberately — five unrelated `xcodebuild test` runs from other sessions held the machine at load
average 220–530, and the standing rule is one heavy command at a time. The body records it as exit 0;
the same sources compiled and ran 205 tests in the gate run above, so the claim is consistent with
observed evidence but was not read twice like the rows above.

**Two bundles a reader should not mistake for evidence:** `build/TG10-ocr.xcresult` holds **0 tests**
(`result: unknown`) — an aborted attempt, not a measurement; the OCR evidence is the
`ocr-fixture-measurement` attachment inside `build/TG10-gate.xcresult`. `build/TG10-evidence.xcresult`
is the genuine narrower re-run (the three new suites, 13/13).
