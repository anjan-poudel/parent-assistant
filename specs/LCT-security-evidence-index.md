# Live camera translation — security evidence index (T-029 / AM-10)

**Feature:** live-camera-translation (EN→NE live camera translation)
**Gate this index is written for:** `security-test` (AM-5 additionally gates `final-sign-off`)
**Basis:** `specs/security-design-review.md` — amendments AM-1 … AM-10, findings SD-1 … SD-6,
clarifications CL-1 … CL-8, residual SR-1, egress paths E1 … E8.

This is the one document the `security-test` gate reads to find the evidence for each amendment.
Every claim below names a **test**, a **gate run**, or an explicitly recorded **gap**. Nothing is
listed as covered because it was designed to be covered: the point of this file is to make the
difference between *proven*, *inspected* and *not exercised* impossible to miss.

How the named tests are verified. `SecurityEvidenceIndexTests` (see the last row of every table)
parses this file, requires every amendment and every exercised egress path to name at least one
`<Suite>.<test>` token, requires every name it finds to exist in `ElderlyAssistantTests`, and requires
every test in `SecurityEvidenceBoundaryTests` to be indexed here. An index that names a test that
does not exist fails the suite rather than reading as evidence. The tests' *passing* status comes
from the recorded gate run in `specs/LCT-TG-10-notes.md` (exact command, per-suite counts), not from
this document.

**Boundary discipline.** Every new assertion below is made at a seam — the client double that
records what left the app (`TierTranslationTransport`), the log bus that records what a sink would
see (`EvidenceRecorderBus`, which keeps the raw event *and* the sanitised one), or the storage
double. No new test asserts on a product internal, and none of them is a restatement of a design
document.

---

## Amendment → evidence

### AM-1 — a cancellation-shaped transport error is terminal; the gate is re-read before the retry; withdrawal between attempts

| Evidence | What it proves |
| --- | --- |
| `CloudTranslationTierTests.testAM1ACancellationShapedTransportErrorIsTerminalAndNeverRetried` | A `URLError.cancelled` is never retried, whatever the retry budget says |
| `CloudTranslationTierTests.testAM1AWithdrawalWhileTheFirstAttemptIsInFlightBlocksTheRetry` | The second attempt re-reads the gate and is refused — the retry is blocked by the re-read, not by a remembered flag |
| `CloudTranslationTierTests.testAM1AWithdrawalCancelsTheRequestInFlightAndNothingIsRetried` | A withdrawal cancels the in-flight work and nothing is retried |
| `LiveTranslateConsentGateTests.testAWithdrawalBetweenTwoAttemptsDeniesTheRetry` | The gate-side form of the same property |
| `SecurityEvidenceBoundaryTests.testAM1AM10AWithdrawalMidSceneLeavesZeroFurtherRequests` | Scene-level: after a withdrawal mid-scene, later cycles issue **zero** requests, and any request that were wrongly made would have succeeded and rendered a translation — the failure would be loud, not a quietly degraded region |
| `CloudTranslationTierTests.testNoConsentRecordMeansZeroRequestsAndAnHonestReason` | A dictionary miss with **no consent record at all**: zero requests, zero billable calls, no indicator, and the typed `.consentNotGranted` reason rather than a generic miss. The retry path is unreachable without a first request, so "no record ⇒ no retry" is implied rather than separately asserted; the *withdrawal*-blocked retry is the test below |
| `CloudTranslationTierTests.testAQuarantineAloneSendsNothingAndNeverShowsTheIndicator` | A scene made entirely of quarantined strings sends nothing and shows no indicator |

### AM-2 — the allow-list extension is additive, per-key, and reaches the real sink

| Evidence | What it proves |
| --- | --- |
| `LiveTranslateAllowListTests.testEveryPreviouslyPresentKeyIsStillAllowed` | No shipped key was removed or renamed (NFR-LCT-012) |
| `LiveTranslateAllowListTests.testTheExtensionIsAdditiveAndTheAllowListIsStillAnAllowList` | The added set is exactly the declared set — the extension is closed, not "anything with a count in it" |
| `LiveTranslateAllowListTests.testRegionCountSurvivesSanitisation` (and the sibling per-key tests: `…StringCount…`, `…BatchIndex…`, `…BatchCount…`, `…ResolvedCount…`, `…UnresolvedCount…`, `…DurationMs…`, `…KeyCount…`, `…Count…`, `…Origin…`, `…Mode…`, `…Reason…`, `…DisclosureVersion…`, `…Cap…`) | Each key survives sanitisation by name |
| `LiveTranslateAllowListTests.testTheFeaturesKeysReachTheRealConsoleSink` | The values arrive at the shipped `ConsoleObservabilityBus`, not only at a test double |
| `SecurityEvidenceBoundaryTests.testAM10AContentRichRunEmitsNoFeatureEventCarryingTextAndNoUnlistedKey` | Under a content-rich run, every key the emitters hand over is allow-listed **before** sanitisation, and no feature event is altered by it (the CL-5 fix, checked at the boundary rather than by reading the emitters) |

### AM-3 — one detect-only marker source, no copied table

| Evidence | What it proves |
| --- | --- |
| `SceneTextSanitiserTests.testTheSanitiserConsultsTheShippedSeamAndRestatesNoMarkerFamily` | Source-level: no marker family is restated under the feature's sources; the accessor is referenced by name |
| `SceneTextSanitiserTests.testTheVerdictAgreesWithTheShippedSeamOnEveryFixture` | The verdict and the shipped seam cannot disagree about what a marker is |

### AM-4 — a withdrawal write failure denies in memory, and a lying delete is caught by the read-back

| Evidence | What it proves |
| --- | --- |
| `LiveTranslateConsentGateTests.testARevocationDeniesInMemoryEvenWhenStorageCannotBeRead` | Deny-in-memory on unreadable storage |
| `LiveTranslateConsentGateTests.testARevocationWhoseDeleteFailsStillStopsTheNextAttempt` | A failed delete still denies the next attempt |
| `LiveTranslateConsentGateTests.testADeleteThatReportsSuccessAndKeepsTheRecordIsCaughtByTheReadBack` | The read-back, not the delete's return value, is the evidence |
| `LiveTranslateConsentGateTests.testARevocationWhoseDeleteLiesAndCannotBeReadIsReportedAsAFailure` | The failure is reported rather than swallowed |
| `LiveTranslateConsentGateTests.testAWithdrawalThatCannotBeMadeToTakeEffectIsNeverSilent` | The elder is told |
| `LiveTranslateConsentGateTests.testARelaunchCannotReadBackAGrantThatWasWithdrawn` | The state does not come back across a relaunch |

### AM-5 — the release log-safety gate's rule family, and the corrected invariant table

This amendment's enforcement point is a **build gate, not an XCTest**, and this index says so
rather than substituting a weaker test for it.

| Evidence | What it proves |
| --- | --- |
| `ios/tools/check-release-log-safety.py` | Four feature rules added to the shipped engine: `feature-console-write` (Release framing), `feature-content-print` (every configuration), `feature-unlisted-metadata-key`, `feature-text-interpolated-into-event`. Its docstring carries the **stated limits** — indirection, `metadata:` variables, wrapper functions, unknown sink spellings are documented gaps, and the runtime allow-list remains the primary safeguard |
| `ios/tools/log-safety-fixtures/` + `ios/tools/check-release-log-safety-fixtures.py` | 24 fixtures over 12 rules — a positive and a negative tree for every declared rule, including all six pre-existing ones. `--falsify` additionally proves each rule is load-bearing (disabling a rule makes its positive fixture pass); all 12 were falsified green on 2026-09-17 (recorded in `specs/LCT-TG-10-notes.md`) |
| `ios/tools/check-release-log-safety.sh` | Runs the engine **and** the fixture suite on every invocation; it is wired into `ios/build.sh`'s `run_tests` ahead of every test scope, and a missing fixture is a failure, not a skip |
| `specs/design-component.md` (§Components → Observability, and the security-invariant table) | The invariant table now describes what the gate actually enforces, rule by rule, with its limits — the SD-2 correction |
| `LiveTranslateSourceHygieneTests.testTheFeatureSourcesContainNoPrintStatements` | The test-layer arm of the same property |
| `LiveTranslateSourceHygieneTests.testNoEmitterAcceptsFreeText`, `LiveTranslateSourceHygieneTests.testTheTypedEmitterIsTheOnlyRouteToTheBus` | No emitter can carry free text; the typed emitter is the only route |
| `SecurityEvidenceIndexTests.testAM5TheGateIsWiredAheadOfEveryTestScopeAndEveryRuleHasFixtures` | From the test side: the gate is called inside `run_tests` *before* the first `xcodebuild`, and every rule id the engine declares has both fixtures |

### AM-6 — a monotone ordering counter, not a scene timestamp

| Evidence | What it proves |
| --- | --- |
| `LiveTranslationPipelineTests.testAM6TheMonotoneOrderingCounterNeverRegresses` | The stored ordering field cannot co-vary with when the text was on camera (SD-3) |

### AM-7 — the consent proof is a parameter with no default, and there is one caller

| Evidence | What it proves |
| --- | --- |
| `GeminiClientTranslateTests.testAM7TheConsentParameterHasNoDefaultSoNoCallCanSkipTheGate` | A call that skips the gate does not compile |
| `GeminiClientTranslateTests.testAM7AProofForAnotherDisclosureCopyFailsClosedWithNothingBuilt` | A stale proof fails closed before anything is built |
| `GeminiClientTranslateTests.testAM9TheSignatureHasNoMediaToolOrAttachmentParameterAndExactlyOneCallSite` | Exactly one call site — the tier, which reads the gate per call |

### AM-8 — every claimed key reaches a terminal outcome

| Evidence | What it proves |
| --- | --- |
| `CloudTranslationTierTests.testAM8AKeyAlreadyInFlightIsNotRequestedAgainAndBothRegionsResolve` | The dedupe does not create a second request, and both regions resolve |
| `CloudTranslationTierTests.testAM8NoRegionIsLeftPendingWhenItsKeyIsBridged` | No unbounded pending state (CL-1) |

### AM-9 — the prompt boundary's real controls, and the provider-reason residual

| Evidence | What it proves |
| --- | --- |
| `GeminiClientTranslateTests.testAM9TheRequestIsOneTextPartWithNoToolsAndAJSONResponse` | One text channel, no tools, JSON-bound response |
| `GeminiClientTranslateTests.testAM9TheSignatureHasNoMediaToolOrAttachmentParameterAndExactlyOneCallSite` | An image part is inexpressible at the call site, not merely absent |
| `GeminiClientTranslateTests.testThePromptKeepsTheInstructionRegionAndTheDataRegionSeparate` | Scene text is a value in a structured document, not part of the instruction channel (SD-6) |
| `GeminiClientTranslateTests.testAPolicyRefusalKeepsTheShippedEmissionAndTheFeatureAddsNoneOfItsOwn` | The feature adds no second block-reason emission |
| `SecurityEvidenceBoundaryTests.testAM9TheFeatureAddsNoUpstreamDerivedErrorCodeAndTheShippedResidualIsPinnedOnce` | With a token-shaped provider reason (the shape the bus *does* carry), the reason appears on exactly one event, on the pre-existing `gemini_client`/`gemini_blocked` site, and never on a `livetranslate` event; every code the feature emits is a lower_snake constant. The block itself surfaces as the closed-vocabulary `translation_degraded` with `reason = provider_rejected` and **no `error_code` at all** — the upstream classification has no field to travel in |

### AM-10 — the assertion set

| AM-10 assertion | Evidence | Note |
| --- | --- | --- |
| Zero image or media parts on every path including the retry | `SecurityEvidenceBoundaryTests.testAM10EveryRecordedRequestCarriesOneTextPartAndNoMediaOfAnyKind` | Every recorded request decoded: one text part, no media field at any level; the retry's request is inspected too |
| The built body contains only items and language parameters | `SecurityEvidenceBoundaryTests.testAM10TheBuiltBodyCarriesOnlyTheItemsAndTheLanguageParameters` | Exact top-level key set, exact `generationConfig` key set, item entries restricted to `id`/`text`/`sourceLanguage`, instruction region free of scene text (I-2) |
| The consent key cannot be written by any configuration path | `LiveTranslateConsentGateTests.testNoConfigurationValueReachesTheConsentDecision`, `LiveTranslateConsentGateTests.testTheConfigTypeCarriesNoConsentSetting`, `LiveTranslateConsentGateTests.testTheConsentKeyIsDeclaredOnceAndOnlyTheGateWritesIt` | Source-level and behavioural, on the gate side |
| Cache-at-rest inspection of the app container | `LiveTranslateCipherStorageTests.testAM10CacheAtRestInspectionOfTheAppContainerFindsNoPlaintext`, `LiveTranslateCipherStorageTests.testAM10TheConsentRecordAtRestCarriesNoPlaintextFieldAndNeverTheKey`, `LiveTranslateCipherStorageTests.testAM10APayloadThatFailsAuthenticationIsTreatedAsAbsentRemovedAndNeverServed` | **T-032's byte-level test is the cache-at-rest evidence; it is indexed here rather than duplicated** (NFR-LCT-008) |
| The indicator is not suppressible while a request is in flight | `CloudActivityIndicatorTests.testTheViewHasNoWayToSuppressItWhileActive`, `CloudActivityIndicatorTests.testTheStateIsNotSettableFromAnywhere` | Plus `CloudActivityIndicatorTests.testItStaysOnUntilTheLastRequestEnds` for the in-flight window |
| Withdrawal mid-scene yields zero further requests, including the retry | `SecurityEvidenceBoundaryTests.testAM1AM10AWithdrawalMidSceneLeavesZeroFurtherRequests` | Also AM-1's evidence |
| The count of results claiming a tier without a translation is zero | `SecurityEvidenceBoundaryTests.testAM10NoResultClaimsATierWithoutATranslation` | Swept over a run that produces dictionary, cloud, cache-hit, quarantined and degraded outcomes |
| No `error_code` derived from upstream text | `SecurityEvidenceBoundaryTests.testAM9TheFeatureAddsNoUpstreamDerivedErrorCodeAndTheShippedResidualIsPinnedOnce` | Also AM-9's evidence; see SR-1 below |
| Structural characters and marker shapes cannot change behaviour | `GeminiClientTranslateTests.testAM10ASceneStringCannotAlterTheRequestsStructureOrItsIDs`, `SecurityEvidenceBoundaryTests.testAM10StructuralCharactersMarkerShapesAndOverLongTextCannotAlterTheRequestOrTheIDSet` | Client-level and tier-level; the tier-level one also drives the over-long and the quarantined cases and asserts each string's answer is its own |
| Logs and events are content-free under a content-rich run | `SecurityEvidenceBoundaryTests.testAM10AContentRichRunEmitsNoFeatureEventCarryingTextAndNoUnlistedKey` | Translations, quarantine and consent states all occur, and the run is asserted to have produced them (anti-green-by-emptiness) |

### Guards outside the amendment list (still security evidence)

| Requirement | Evidence | What it proves |
| --- | --- | --- |
| NFR-LCT-013 — the spend guard | `CloudTranslationTierTests.testASpentBudgetIsRefusedBeforeAnyRequestAndLatchesForTheSession`, `CloudTranslationTierTests.testABudgetThatRunsOutWhileInFlightLatchesAndBlocksTheRetry` | The latch closes, is checked *before* a request is built, and survives pressure in both directions (already spent / spent mid-flight) |
| NFR-LCT-013 — the counter itself | `CloudTranslationTierTests.testTheShippedGovernorCountsEveryBillableAttemptAndNothingElse` | The count is of billable attempts, not of resolved regions |
| Failure isolation — a translation failure never reaches capture, consent or the dictionary | `LiveTranslationPipelineTests.testScenarioADetectionFailureDropsNoRegionAndStopsNothing`, `LiveTranslationPipelineTests.testScenarioACloudFailureDegradesOneRegionAndTheOtherStillResolves`, `LiveTranslationPipelineTests.testScenarioTheDictionaryPathNeedsNoNetworkAtAll`, `LiveTranslationPipelineTests.testScenarioClosingCancelsInFlightWorkAndTearsEverythingDown`, `CloudTranslationTierTests.testTheDeadlineTerminatesTheBatchAndEveryRegionDegrades` | A detection failure, a cloud failure, a closed session and a **provider that never answers** (the deadline) each degrade the region or stop cleanly, and none of them takes down the dictionary path, the consent state or the capture loop |

### Integrity of this index

| Evidence | What it proves |
| --- | --- |
| `SecurityEvidenceIndexTests.testEveryAmendmentMapsToAtLeastOneNamedTestThatExists` | AM-1 … AM-10 each name a real test |
| `SecurityEvidenceIndexTests.testEveryBoundaryEvidenceTestIsIndexedHere` | No evidence test is orphaned from this index |
| `SecurityEvidenceIndexTests.testTheIndexRecordsResidualRisksKnownLimitationsAndUnexercisedPaths` | This document's honesty sections exist and name SR-1 and the gaps |
| `SecurityEvidenceIndexTests.testAM5TheGateIsWiredAheadOfEveryTestScopeAndEveryRuleHasFixtures` | AM-5's enforcement point is wired, and every declared rule is fixtured |

---

## Egress path enumeration (E1 … E8)

Every path into the cloud tier, from `security-design-review.md`, with what exercises it.

| # | Path | Evidence | Status |
| --- | --- | --- | --- |
| E1 | Initial resolve from a region text-change event | `CloudTranslationTierTests.testAM1AWithdrawalWhileTheFirstAttemptIsInFlightBlocksTheRetry` (per-call gate read), `SecurityEvidenceBoundaryTests.testAM10EveryRecordedRequestCarriesOneTextPartAndNoMediaOfAnyKind` | Exercised |
| E2 | The single automatic retry inside `resolve` | `CloudTranslationTierTests.testAM1ACancellationShapedTransportErrorIsTerminalAndNeverRetried`, `SecurityEvidenceBoundaryTests.testAM1AM10AWithdrawalMidSceneLeavesZeroFurtherRequests`, and the retry request is decoded in `…EveryRecordedRequestCarriesOneTextPartAndNoMediaOfAnyKind` | Exercised — the CL-2 gap is closed |
| E3 | Session-resume re-attempt after an interruption | `SecurityEvidenceBoundaryTests.testAM1AM10AWithdrawalMidSceneLeavesZeroFurtherRequests` (a later cycle re-enters `resolve` and re-reads the gate) | Exercised, at the tier boundary |
| E4 | Second observation of a key already in flight (dedupe) | `CloudTranslationTierTests.testAM8AKeyAlreadyInFlightIsNotRequestedAgainAndBothRegionsResolve` | Exercised |
| E5 | Plugin entry (`handle` / `presentationView`) | `LiveTranslatePluginTests.testScenarioTheEntryCostsNothingUntilTheFeatureIsOpened`, `GeminiClientTranslateTests.testAM9TheSignatureHasNoMediaToolOrAttachmentParameterAndExactlyOneCallSite` | Exercised at its own layer; no cloud call site exists on the entry path |
| E6 | Backgrounded app (frame stream stops ⇒ no OCR ⇒ no request) | `LiveTranslateSessionModelTests.testScenarioBackgroundingPausesAndForegroundingResumesOnce`, `GeminiClientTranslateTests.testAM9TheSignatureHasNoMediaToolOrAttachmentParameterAndExactlyOneCallSite` | Exercised at the session layer. **Not exercised at the transport boundary** — no test in this run attaches the recording transport to a backgrounded session, so "no request after backgrounding" is evidenced structurally (one call site, inside the consent-checked `resolve`) rather than by a recorded zero. Recorded as a gap below, not as a covered case |
| E7 | Prefetch / speculative translation | — | **Not exercisable: the path does not exist.** A test cannot exercise a path that is absent. The absence is structural (the cache is written only by a completed resolution, and `LabelTranslationCacheTests` pins the read path) and is recorded as a structural claim, not as covered by assertion |
| E8 | Cache hit (tier 0 or persisted) | `CloudTranslationTierTests.testANewCycleReResolvesAlreadyTranslatedTextWithoutARequest` | Exercised |

---

## Residual risks (recorded, not retired)

- **SR-1 — the provider's block reason on the shared log surface.** The shipped `GeminiClient`
  emits `gemini_blocked` with the decoded `promptFeedback.blockReason` on component
  `gemini_client`. That emission is pre-existing, was reviewed and passed at `57abb2e`, and this
  feature neither adds to it nor removes it (removing it would weaken shared behaviour that
  NFR-LCT-012 forbids this feature from changing). The feature maps a block to the constant
  `.cloudPolicyBlocked` → `cloud_policy_blocked`, and reports the region as a degradation whose
  `reason` is the closed-vocabulary constant `provider_rejected` — carrying no `error_code`
  derived from anything the provider said.
  Evidence: `SecurityEvidenceBoundaryTests.testAM9TheFeatureAddsNoUpstreamDerivedErrorCodeAndTheShippedResidualIsPinnedOnce`
  *pins* the residual to its single site and asserts that no `livetranslate` event carries it.
  The stated follow-up (validating the block reason against a closed token set at the decode site,
  converting the shape bound into a closed-set bound) is **out of this feature's scope** and is not
  claimed here.
- **SD-5 — the in-session microphone under the cloud voice engine.** Raised at the joint OD-12 /
  OD-13 review by the design review, not owned by this feature; FR-LCT-011's indicator is scoped to
  the translation tier. Recorded as an **owner action**, not as coverage.
- **T-2 — on-device modification of the consent record.** Integrity rests on platform file
  protection, not on a tag. The design review recommends recording this as a written residual;
  it is recorded here rather than presented as tested.
- **OD3 — the consent/disclosure copy review** and the `NSCameraUsageDescription` wording remain
  open release gates owned by the owner. The feature's copy is tested against the app's
  accessibility floors (`LiveTranslateCopyTests`, `LiveTranslatePluginTests`), which is not the
  same thing as the copy review.
- **OD1 / OD2 / OD5 — cadence, default and thresholds.** Device-dependent values with no device in
  this run; see `specs/LCT-device-validation-protocol.md` and `…-results.md`.

## Known limitations of the evidence itself

- **AM-5's gate is a source-level check.** It cannot follow indirection (a helper's return, a
  `metadata:` variable, a wrapper function, an unknown sink spelling). The engine's "Known
  limitations" section is the authoritative list; the runtime allow-list (`LiveTranslateAllowListTests`)
  remains the primary safeguard, and the gate is the backstop. Expressed in prose above and in
  `specs/design-component.md`, and it is not restated as stronger coverage anywhere.
- **AM-5's fixture suite is run without `--falsify` in the build path.** The falsification run
  (proving each rule is load-bearing) is opt-in and slower; its result is a recorded run in
  `specs/LCT-TG-10-notes.md`, not a per-build assertion.
- **The consent record's own at-rest protection is asserted at the byte level by T-032's tests on
  a test key store.** The device's real Data Protection class (a platform property) is not
  inspectable from a simulator test; that is a device-validation item.
- **`LogSanitiser.boundErrorCode` is a shape bound, not a closed-set bound** (SR-1's own wording).
  Nothing in this suite turns it into a closed set, and the suite does not claim it.

## Paths and behaviours not exercised in this run (gaps, recorded rather than covered)

1. **E6 at the transport boundary** — no request is *observed* to be absent after backgrounding;
   only the frame stream's stop and the single call site are asserted.
2. **E7** — the prefetch path does not exist; its absence is structural, not asserted by a test.
3. **A real provider** — every request assertion is made against the recorded `URLRequest`; no
   response from the live Gemini API was produced or inspected in this run.
4. **Airplane mode / no-network on a device** — the offline behaviour is exercised only through a
   scripted `URLError`.
5. **The app container on a device** — cache-at-rest evidence is T-032's byte-level test over the
   storage double and the cipher storage; the physical container is a device-validation item.
6. **Voice-path interaction (SD-5)** — no test in this suite drives the cloud voice engine
   concurrently with a translation session.
7. **The `hi-in` probe finding** — recorded in `specs/hi-in-probe-notes.md`; not re-litigated here.
8. **A genuine crash (process death) of the translation path** — an in-process crash kills the test
   host, so no test can assert what survives it. A **hang** is covered
   (`CloudTranslationTierTests.testTheDeadlineTerminatesTheBatchAndEveryRegionDegrades`), and the
   *isolation* claim rests on the structure asserted in the failure-isolation row above — consent
   state, the dictionary layer and the capture loop hold no reference to the cloud tier's outcome.
   The structural claim is not the same as a crash test, and it is not presented as one.

Every item above is a gap this index declines to dress up as coverage. If a later change closes
one, it should be added to the tables above with the test that closes it, and moved out of this
section — not marked done here by hand.
