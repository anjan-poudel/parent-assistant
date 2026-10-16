# TG-01 — Foundations: implementation notes

**Group:** TG-01 — Foundations (tasks T-001 … T-005)
**Worktree:** `.claude/worktrees/live-camera-translation` (branch `worktree-live-camera-translation`)
**Scope discipline:** no commit, no workflow state touched, no file outside TG-01's scope edited. Three shipped
components were extended **additively only** (NFR-LCT-012): `InputSanitiser`, `LogSanitiser`, and the String
Catalog / `Info.plist` copy surfaces.

## What was built

| Task | Created | Shipped file extended |
|------|---------|----------------------|
| T-001 | `Services/LiveTranslate/LiveTranslateConfig.swift` (151 lines), `LiveTranslateSettings.swift` (79) | — |
| T-002 | `Services/LiveTranslate/TranslationResult.swift` (499) | — |
| T-003 | `Services/LiveTranslate/LiveTranslateEvents.swift` (395) | `Services/Observability/LogSanitiser.swift` (additive keys + one bounded key) |
| T-004 | — | `Services/Voice/InputSanitiser.swift` (two detect-only accessors + prohibition comment) |
| T-005 | — | `Resources/Localizable.xcstrings` (+19 keys), `Info.plist` (`NSCameraUsageDescription`) |

All four production files live under `ios/ElderlyAssistant/Services/LiveTranslate/`, which the XcodeGen glob picks
up automatically — no `project.yml` edit was needed. `ios/seniOS.xcodeproj/project.pbxproj` is a **generated**
artifact: `build.sh` regenerates it, and the working-tree delta is exactly XcodeGen's registration of the new
files (90 added lines, nothing removed; `git diff --stat` = `90 insertions(+)`).

### T-001 — one owner for every operational constant
`LiveTranslateConfig` is an `Equatable` value type holding the design's parameter table verbatim: `ocrSampleInterval`
0.25, `thermalCadenceFactor` 2.0, `thermalStateThreshold` `.serious`, `trackingEnabled` true, `regionMatchIoU` 0.3,
`regionMatchCentroidDistance` 0.35, `regionAppearPasses` 2, `regionMissPasses` 2,
`declutterMergeCentroidDistance` 0.06, `declutterMaxRegions` 8, `inPlaceMaxSourceWordCount` 3,
`overlayMinPointSize` 18, `alwaysShowOriginalDefault` false, `cloudDeadlineGraceSeconds` 5, `cloudMaxRetries` 1,
`cloudBatchMaxStrings` 12, `cloudBatchMaxCharacters` 1200, `sceneTextMaxLength` 120, `translationMaxLengthRatio`
4.0, `translationMaxLengthAllowance` 64, `cacheGeneralEntryLimit` 200, `cacheTouchCoalescing` true,
`disclosureVersion`. No I/O, no singletons, no mutable static state, no configuration surface for the user.

`LiveTranslateSettings` owns the one persisted preference (`livetranslate.alwaysShowOriginal`) behind the
`featureKeyPrefix`, with an injectable `UserDefaults` and config, a `nonmutating set`, `setAlwaysShowOriginal(_:)`
and `toggleAlwaysShowOriginal()` so the touch control and the voice command take the same path.

### T-002 — the outcome is the single source of truth
`TranslationOutcome` is `pending(originalText:)` / `resolved(originalText:translation:tier:)` /
`degraded(originalText:reason:)` exactly as the design's C04 sketch; `text`, `sourceTier`, `degraded` and `isFinal`
are computed from the case, never stored beside it. `TranslationTier` has exactly two cases and no ordinal
reservation, so the deferred on-device tier has nothing to return. `LiveTranslateError` carries every case the
design names (plus `trackingUnsupported`), each with a constant log-safe code; `unavailableReason` is a total
switch with **no** `default` branch, so a new case cannot silently inherit a reason. The CL-4 conversion tables
(`fromGemini(_:)`, `fromTransport(_:)`) are the tier's only route from `GeminiClientError`, so T-019 does not
re-derive them.

### T-003 — content-free by schema, additive on the shipped allow-list
`LiveTranslateEventCatalogue` declares 32 event types with their outcome vocabulary and metadata keys;
`LiveTranslateEvents` exposes one typed emitter per event and a single private
`emit(_:outcome:errorCode:metadata:durationMs:)` that is the only `bus.emit(` call site in the file. Metadata is
keyed by `MetadataKey` (13 cases), so an undeclared key is a compile error rather than a silently dropped field.
`LogSanitiser.allowedKeys` gained 15 keys and nothing else; `errorCode` is additionally routed through the
existing `boundErrorCode`.

### T-004 — the seam, not a second table
`InputSanitiser.markerMatches(in:) -> [String]` and `containsInjectionMarker(_:) -> Bool` answer from the private
table using the same `.caseInsensitive, .diacriticInsensitive` matching the removal step uses. `sanitise(_:level:)`
is byte-for-byte untouched.

### T-005 — copy is data
19 `livetranslate.*` keys (empty-state hint, pending, unavailable, quarantined, five consent strings, cloud-activity
label, toggle label, two camera strings, six C12 command phrases) with Nepali first, all resolved through
`L10n.str(_:locale:)`. The close control reuses the shipped `common.close` rather than adding a twentieth key that
would say the same thing. The purpose string keeps its medication, appliance and cloud sentences and gains the
live-translation disclosure and the text-only send.

## Gherkin coverage — scenario to test

### T-001 `LiveTranslateConfig` / `LiveTranslateSettings`
| Scenario | Tests |
|---|---|
| Every parameter resolves from one value with its documented default | `LiveTranslateConfigTests.testDefaultsMatchTheDesignsParameterTableExactly`, `testDefaultIsTheDocumentedNominalValueBundle`; `LiveTranslateSourceHygieneTests.testNoConfiguredDefaultIsRedeclaredInTheFeaturesPipelineSources`, `testTheScanActuallyDetectsTheLiteralsWhereTheyLegitimatelyLive`, `testTheConfigIsTheOnlyFileDeclaringTheFeaturesDefaults` |
| The cloud base timeout has exactly one source of truth (CL-8) | `testCloudBaseTimeoutIsTheShippedClientConfigAndIsNotDuplicated`, `testCloudDeadlineIsDerivedFromTheTwoOwnedValues`, `testTheRequestTimeoutCannotBeGivenASecondDivergentValue` |
| The always-show-original setting persists without a restart | `LiveTranslateSettingsTests.testUnsetPreferenceReadsTheDesignsNominalDefault`, `testTheDefaultComesFromTheConfigNotASecondLiteral`, `testPreferenceRoundTripsAcrossASimulatedRelaunch`, `testTurningThePreferenceBackOffAlsoPersists`, `testTheChangeIsVisibleOnTheNextReadWithNoRestart` |
| The settings store carries no user content | `testThePersistedStoreCarriesOnlyTheBooleanPreference` (scans every `livetranslate.` entry), `testTheToggleIsReachableThroughTheDeclaredKeyAlone`, `testTouchControlAndVoiceCommandWriteTheSameSetting`, `testTheDisclosureVersionIsTheConfigsStamp`; OD7: `LiveTranslateConfigTests.testNoCostCapIsOwnedByThisFeature` |

### T-002 outcome, tier and error taxonomy
| Scenario | Tests |
|---|---|
| A tier that did not translate cannot be named | `TranslationResultTests.testADegradedResultNamesNoTierAndHonestlyShowsTheOriginal` |
| A resolved outcome names the tier that actually produced it | `testAResolvedResultNamesTheTierThatActuallyProducedIt`, `testACloudResolutionNamesTheCloudTierAndNotTheDictionary` |
| The deferred on-device tier has no representation to return | `testTheTierTypeHasExactlyTwoCasesAndNoOrdinalReservation` |
| A pending region claims nothing | `testAPendingResultClaimsNothing` |
| State transitions are monotone | `testAResolvedRegionNeverReturnsToPendingWhileItsTextIsUnchanged`, `testADegradedRegionNeverReturnsToPendingWhileItsTextIsUnchanged`, `testATextChangeReplacesTheOutcomeRatherThanMergingWithIt`, `testPendingBecomesResolvedThroughTheSameTransition`, `testTheAccessorsAreDerivedFromTheOutcomeAlone` |
| Every failure maps to a stable, content-free code and a reason (CL-4) | `LiveTranslateErrorTaxonomyTests.testEveryErrorCaseHasAStableCodeAndReason` (42 constructed cases, exhaustive switch, no `default`), `testEveryCodeSurvivesTheShippedErrorCodeBoundVerbatim`, `testEveryCodeSurvivesTheShippedErrorCodeMapperChokepoint`, `testConsentRecordUnreadableAndCostBudgetExhaustedNeverCollapse`, `testTheStatusCodeIntCarriesNoUpstreamText`, `testTheGeminiClientErrorConversionTableIsTotal`, `testTransportErrorsConvertByTheirURLCode`, `testAnUnclassifiableFailureNeverClaimsANetworkCause`; `TranslationResultTests.testTheUnavailableReasonVocabularyIsClosedAndStable`, `testNoReasonCanCarryUpstreamText` |
| Unsupported tracking degrades to OCR-only rather than failing | `testUnsupportedTrackingIsRepresentableAndNotASpecificCause`; `LiveTranslateEventsTests.testUnsupportedTrackingIsRecordedHonestly` |

### T-003 event catalogue and allow-list extension (AM-2)
| Scenario | Tests |
|---|---|
| Every key the feature emits survives sanitisation | `LiveTranslateAllowListTests` — one case per added key (`testRegionCountSurvivesSanitisation` … `testDisclosureVersionSurvivesSanitisation`, `testCapSurvivesSanitisation`, `testErrorCodeSurvivesSanitisationWithItsValue`); `LiveTranslateEventsTests.testEveryCatalogueMetadataKeySurvivesTheShippedSanitisingBus`, `testObservedMetadataKeysMatchThePinnedCatalogueExactly`, `testEveryCatalogueEntryIsActuallyEmitted` |
| Content cannot travel in a metadata value or an error code | `LiveTranslateEventsTests.testEveryEmittedMetadataValueIsCountTokenOrVersion`, `testEveryErrorCodeIsAClosedTokenOrAnIntegerSuffix`, `testQuarantineIsRecordedWithACountAndNothingElse`, `testTheDegradedEventCarriesOnlyTheReasonTokenAndARegionCount`, `testCameraEventsCarryOnlyClosedReasonTokens`; `LiveTranslateSourceHygieneTests.testNoEmitterAcceptsFreeText`, `testTheTypedEmitterIsTheOnlyRouteToTheBus`; end-to-end through the real console sink: `LiveTranslateAllowListTests.testTheFeaturesKeysReachTheRealConsoleSink` |
| A new key cannot be added without a deliberate decision | `LiveTranslateEventsTests.testTheEmitterKeySetIsPinnedToTheShippedAllowList`, `testObservedMetadataKeysMatchThePinnedCatalogueExactly`; `LiveTranslateAllowListTests.testTheExtensionIsAdditiveAndTheAllowListIsStillAnAllowList` (exact added-set assertion) |
| The shipped cap events keep their meaning | `LiveTranslateAllowListTests.testTheShippedCostGovernorCapEventsSurviveIntact` (drives the **real** `GeminiCostGovernor` over its cap), `testCapSurvivesSanitisation`; `LiveTranslateEventsTests.testTheFeatureAddsALatchEventAndNeverReEmitsTheShippedCapEvents` |
| Existing keys and their meanings are untouched (NFR-LCT-012) | `LiveTranslateAllowListTests.testEveryPreviouslyPresentKeyIsStillAllowed` (27-key pre-change pin), `testTheCamelCaseDurationKeyDidNotReplaceTheShippedSnakeCaseOne`, `testTheShippedSnakeCaseKeyKeepsItsExistingBehaviour`, `testTheTopLevelErrorCodeRemainsTheBoundedCarrier` |

### T-004 detect-only seam (AM-3, CL-6)
| Scenario | Tests |
|---|---|
| The scene-text path can detect a marker without copying the table | `InputSanitiserDetectOnlySeamTests.testTheSeamReportsAMarkerWhereOneIsPresent`, `testTheSeamReportsNoMatchForTextThatCarriesNone`, `testDetectionUsesTheSameMatchingAsRemoval` |
| The shipped transcript behaviour is unchanged | `testTheShippedTranscriptBehaviourIsUnchanged` (7 pinned input/output literals at both levels), `testTheLengthClampStillApplies`, `testAskingTheSeamDoesNotAlterTheRemovalPath` |
| Both call sites agree on the same table | `testBothCallSitesAgreeOverTheSharedFixtureSet`, `testAResidualMarkerAfterSanitisationIsDetectable` |
| No second copy of the list exists | `testNoMarkerListCopyExistsInTheFeaturesSources` (scans `Services/LiveTranslate/`), `testTheShippedTableIsTheOnlyDirectiveListInTheApp` (scans the whole app), `testTheShippedMarkerTableRemainsPrivate` |

### T-005 localised copy and purpose string
| Scenario | Tests |
|---|---|
| Every new user-visible string is a catalog entry with Nepali first | `LiveTranslateCopyTests.testEveryFeatureStringResolvesInNepaliAndEnglish`, `testEveryFeatureStringIsCatalogBackedRatherThanASwiftLiteral`, `testTheCatalogHoldsExactlyTheFeaturesDeclaredKeys`, `testTheCloseControlReusesTheShippedEntry` |
| The command phrases exist in both languages | `testTheCommandPhraseTableExistsInBothLanguages` (six C12 phrases pinned by key) |
| The camera purpose string discloses live translation and the conditional text send | `testThePurposeStringDisclosesLiveTranslationAndTheConditionalTextOnlySend`, `testTheShippedMedicationAndApplianceDisclosuresAreStillPresent` |
| The unavailable wording stays true in every failure case | `testTheUnavailableCopyNamesNoSpecificCause`, `testTheDegradedCopyStillPromisesTheOriginalText` |
| The draft copy is version-stamped for the consent record | `testTheDisclosureVersionIdentifiesThisCopyRevision`; `LiveTranslateSettingsTests.testTheDisclosureVersionIsTheConfigsStamp`; `LiveTranslateEventsTests.testTheDisclosureVersionMetadataComesFromTheConfig`; `LiveTranslateAllowListTests.testDisclosureVersionSurvivesSanitisation` |

## Decisions made during implementation

- **CL-8: the cloud timeout is derived, not stored.** `cloudRequestTimeout` is a computed property returning
  `GeminiClient.Config.default.timeoutSeconds` (25 s) — there is no stored field to diverge, so "documented as
  derived" is enforced by the type rather than by a comment. `cloudDeadlineSeconds` is likewise derived
  (`request + 5`). A divergent second value cannot be introduced by editing this type, because there is no field
  here to edit.
- **`disclosureVersion` is not a literal date run.** `livetranslate.disclosure.draft.16sep2026.r1` rather than
  `…2026-09-16…`: the shipped `LogSanitiser` PII scrub treats an 8+ digit run with separators as a phone shape and
  would redact the version out of the consent events the evidence depends on. `16sep2026` carries the same meaning
  and survives the bus intact (pinned by `testDisclosureVersionSurvivesSanitisation`). The value is a **draft**
  stamp for OD3; the review is an owner action.
- **AM-2, decision 1 — `cap` is allowed, and it was a defect that it was not.** The shipped `GeminiCostGovernor`
  emits `daily_cap_warning` / `daily_cap_reached` with metadata `count` and `cap` on component `gemini_cost`; the
  allow-list was dropping both, so the family-visible cap signal arrived with no count and no cap. `cap` is
  count-shaped and the feature does not touch the shipped payloads — `testTheShippedCostGovernorCapEventsSurviveIntact`
  drives the **real** governor over its cap and asserts `count` 8/`cap` 10 (warning) and 10/10 (reached).
- **AM-2, decision 2 — the metadata code key is allow-listed *and* bounded.** `errorCode` is in T-003's declared key
  list, but allow-listing it as a plain text key would have created the unbounded twin of the T-050/B2 defect. It is
  routed through the same `boundErrorCode` as the top-level field via a new private
  `codeShapedMetadataKeys: Set<String>` (currently `["errorCode"]`). The shipped snake_case `error_code` is
  deliberately **not** in that set: shipped emitters already write it and re-bounding it would change a shipped
  behaviour (NFR-LCT-012). Both halves are pinned.
- **`trackingUnsupported` closes the catalogue at 32 events.** The design's T-002 notes list an unsupported-tracking
  case; it is represented as an error case *and* an honest event, and FR-LCT-004's scenario is satisfied by
  `trackingEnabled` staying a live config flag and the state never being surfaced as an elder-facing error.
- **Residual markers are a real state, and the seam is why.** Pinned in
  `testAResidualMarkerAfterSanitisationIsDetectable`: `"you are<|system|> now"` sanitises to `"you are now"`, which
  *still* matches a marker shape — the removal loop walks the table once. That is the concrete justification for
  T-017's strip-then-detect order (sanitise, then quarantine on a residual) rather than detect-then-sanitise.
- **The source-hygiene exemption list is empty and must stay reasoned.** `LiveTranslateSourceHygieneTests` scans the
  feature sources for 11 distinctive default literals, guarded so `0.3` does not fire inside `0.35` and `120` not
  inside `1200`. Small bare integers (1, 2, 5, 8, 12) are deliberately out of scope — as bare tokens they appear in
  ordinary code far too often to be a signal, and a check that cries wolf gets switched off. The list is
  falsifiable: the same scanner must find all 11 literals in `LiveTranslateConfig.swift`, so a scan that stops
  detecting its own shape fails instead of passing forever.
- **No second copy of a default exists (T-001 DoD).** `testTheConfigIsTheOnlyFileDeclaringTheFeaturesDefaults`
  asserts exactly one file under the feature declares `static let \`default\``; `testNoCostCapIsOwnedByThisFeature`
  uses a `Mirror` walk to assert the feature config has no cap field at all, so OD7's "one cap, family-editable" is
  structural.
- **T-005: no new close-control key.** The close control reuses the shipped `common.close`; a twentieth key saying
  the same thing would be a second source of the same string.

## Verification performed

**Gate (scoped, per the workflow driver's correction): PASS — exit 0, 106 tests, 0 failures.**

```
cd ios
xcodebuild test -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveTranslateConfigTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSettingsTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/TranslationResultTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateErrorTaxonomyTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateEventsTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateAllowListTests \
  -only-testing:ElderlyAssistantTests/InputSanitiserDetectOnlySeamTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCopyTests
```

`Test Suite 'ElderlyAssistantTests.xctest' passed … Executed 106 tests, with 0 failures (0 unexpected) in 4.784 s`.
`ios/build.sh test:unit` cannot scope, so the raw `xcodebuild` invocation above mirrors its flags (`seniOS.xcodeproj`,
scheme `ElderlyAssistant`, warm `build/DerivedDataTests`, `-skip-testing:ElderlyAssistantUITests`) exactly.

**Corroboration in the full unit bundle.** `./build.sh test:unit` was also run end-to-end on a **private** simulator
device (`IOS_TEST_DESTINATION` → `990E1710…`, not the shared `0D2CED77…`): **3340 tests, 3312 passed, 21 failed,
7 skipped** — the repo's known red baseline (21 failures across 11 unrelated suites: `DialectIdentifierTests`,
`IntentEncoderArtifactTests`, `IntentEncoderInterpreterTests`, `IntentEncoderSideloadTests`, `IntentEncoderWiringTests`,
`InterpreterAvailabilityTests`, `LocalBrainChainTests`, `ModelCatalogSTTNamingTests`, `MultipartDownloadTests`,
`VoiceTurnLatencyTracerTests`, `VoiceTurnTimingSeamTests`). Extracted per class from that bundle, **all nine TG-01
suites passed (106/106), none among the 21.** Those failures are pre-existing and untouched; nothing outside
`Services/LiveTranslate/` and the two declared extension points was modified.

`errorCode`-bound regression check: `LiveTranslateAllowListTests.testEveryPreviouslyPresentKeyIsStillAllowed` pins the
27 shipped keys; no shipped test asserts the allow-list exhaustively (every shipped reference is a membership
`contains`), so the additive extension cannot re-mean one. The shipped `InputSanitiser.sanitise` behaviour is pinned
byte-identical by `testTheShippedTranscriptBehaviourIsUnchanged`.

### Environment findings (not source changes; the next task in this worktree will hit them)

- **A shared simulator silently runs another worktree's app.** The repo's default destination is the first available
  iPhone — `iPhone 17 Pro (0D2CED77-002C-4081-A4C7-6A0A97E60F18)` — and several agents' worktrees were running on it.
  `xcodebuild` installs the app into that device; if another worktree's install is current there, **the run executes
  *that* bundle**. My first two full-suite runs recorded test cases (`AppLauncherPluginTests`,
  `SwitchableCommandInterpreterTests`) that do not exist in this worktree, while the bundle built in this worktree
  demonstrably contained my classes. The evidence: `strings` on
  `…/Devices/0D2CED77…/data/Containers/Bundle/Application/086B5660…/ElderlyAssistant.app/PlugIns/ElderlyAssistantTests.xctest/ElderlyAssistantTests`
  (installed 21:35) → `AppLauncherPluginTests` 4 hits, `LiveTranslateConfigTests` 0. Two runs from the same source
  tree also disagreed on their test population (3340 vs 3591 cases). **Fix: pin `IOS_TEST_DESTINATION` to a device only
  this worktree uses**, and sanity-check any `-only-testing`-free result by confirming the recorded bundle contains a
  class you know you added. A full-suite result that lacks your own classes is not your result.
- **A crash inside one test takes the whole runner down.** `FeatureSourceScan.firstMatch` built an `NSRange` from a
  `Substring` and applied it to a `String` copy: `NSRange(_:in:)` requires the exact view it was built from, so it
  trapped and killed the shared process, producing ~32 collateral failures in unrelated suites. Fixed by materialising
  each line as a `String` first. Worth knowing because the collateral pattern looks like a wave of real regressions.
- **The gitignored model resources must exist or XcodeGen fails** ("missing source directory"): a symlink for
  `Resources/Models/whisper-medium-ne-q5_1.bin` (586 MB) and copies of `Resources/Models/kws/` and
  `Resources/Models/tts/{en_US-lessac-medium-int8,ne_NP-google-medium-int8}` were placed from the main checkout.
- **The warm `build/DerivedDataTests`** was cloned from the main checkout with `cp -c -R` to avoid a ~20-minute cold
  SwiftWhisper/sherpa-onnx compile.
- **`build.sh` pipes `xcodebuild` through `tail -40`**, so diagnostics come from
  `xcrun xcresulttool get test-results summary|tests` on the run's `.xcresult`, not from the log.

## Open items (reported, not silently closed)

- **T-005 DoD "every new key is reachable from the feature's code paths by key, not by literal"** cannot be satisfied
  by T-005 itself: its own scope line says "No Swift source is produced here", and the consumers of those keys are
  T-008 (empty state / pending), T-015 (consent prompt), T-021 (cloud label) and T-023 (command phrases). What is
  proven here is that each of the 19 keys resolves in en **and** ne through `L10n.str(_:locale:)` and that no Swift
  literal duplicates one; the reachability half lands with those four tasks.
- **OD3 copy review, purpose-string approval and App Store submission** are owner actions at `final-sign-off`. The
  consent and disclosure copy in this change is a **draft** (`disclosureVersion` ends `.draft.16sep2026.r1`), and the
  `NSCameraUsageDescription` text is a draft purpose string. This task does not claim the review.
- **OD7 family-visible cap.** The `cap` allow-list entry is a fix to evidence that was being dropped, but the
  family-editable range and the cap value remain the shipped `GeminiCostGovernor`'s; whether the family surface should
  show the cap is unchanged by this work.
- **The repo's unit suite is red on master, independent of this work.** 21 failures across 11 unrelated suites
  (intent-encoder wiring, dialect corpora, the T-036 artifact pins, multipart-download temp files, the turn-timing
  tracer) are present in the full bundle and are not TG-01's. Recorded here as the environment's starting state; no
  attempt was made to diagnose or fix them, per scope (`Services/LiveTranslate/` plus the two declared extension
  points only).

## Out-of-scope capabilities — confirmed absent, not stubbed

A scan of the four production files for `tier1|tier_1|on-device|arkit|phrasecard|auto_speak|caregiver|ne->en` returns
**only comments documenting the absence** of tier-1 on-device translation (the two-case `TranslationTier` has no case
to return). There is no NE→EN path, no phrase-card mode, no ARKit anchoring, no auto-speak, and no caregiver
configuration surface anywhere in TG-01's sources — and no placeholder that returns success.

Every asynchronous interface in this group names its timeout with a default (`cloudRequestTimeout`,
`cloudDeadlineGraceSeconds`, `cloudDeadlineSeconds`, `cloudMaxRetries`), and every interface declares an explicit
error return type — `Result`-based, with the one deliberate `throws` exception being the Gemini client chokepoint
that CL-4 converts at the boundary.
