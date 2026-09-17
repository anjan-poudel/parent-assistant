# TG-03 + TG-04 — Region stabilisation, dictionary tier and translation cache: implementation notes

**Groups:** TG-03 — Region Stabilisation (T-009, T-010) · TG-04 — Dictionary Tier and Translation Cache
(T-011, T-012, T-013)
**Worktree:** `.claude/worktrees/live-camera-translation` (branch `worktree-live-camera-translation`)
**Scope discipline:** no commit, no `.ai-sdd/` workflow state touched, no `ai-sdd` command run, no file
outside these two groups' scope edited.

**Shipped-file edits (NFR-LCT-012): four code files, every one additive or behaviour-preserving, each
declared with its diff below.** T-009, T-010 and T-012 are **new files** (`TextRegionStabilizer.swift`,
`LabelTranslationCache.swift`); T-011 is **data only** in the shipped localizer; T-013 added one new
caller-side file and threaded an optional parameter through the shipped helper's call sites.

## What was built

| Task | Created | Shipped file extended |
|------|---------|----------------------|
| T-009 | `Services/LiveTranslate/TextRegionStabilizer.swift` (492 lines, shared with T-010) | — |
| T-010 | declutter stage in the same file | — |
| T-011 | — (data only) | `Services/Appliance/ApplianceLabelLocalizer.swift` — 73 entries appended, 47 shipped entries byte-identical |
| T-012 | `Services/LiveTranslate/LabelTranslationCache.swift` (374) | — |
| T-013 | `Services/Appliance/ApplianceLabelResolver.swift` (100) | `ApplianceHelperView.swift`, `ApplianceHelperPlugin.swift`, `App/AppCoordinator.swift` |

Tests mirror under `ios/ElderlyAssistantTests/`: `Services/LiveTranslate/TextRegionStabilizerTests.swift`
(406), `Services/LiveTranslate/TextRegionDeclutterTests.swift` (272),
`Services/LiveTranslate/LabelTranslationCacheTests.swift` (546),
`Services/LiveTranslate/LabelTranslationCacheTestStorage.swift` (85, a byte-level
`EncryptedLocalStorage` + `RawEncryptedStorage` double written for this group),
`Services/Appliance/ApplianceLabelDictionaryTests.swift` (187),
`Services/Appliance/ApplianceHelperLabelSeamTests.swift` (332). No existing test file was edited.

### T-009 — stable identity, one implementation of normalization

`TextRegionStabilizer` is a `struct` with mutating `consume(regions:now:)` and four members the spec
names: `visible`, `activeRegionCount`, `reset()`, and the static `declutter`. It has no camera, no
network, no storage, no clock and no bus — its only output is `[RegionChangeEvent]`, whose three cases
each carry a `RegionIdentity` **and nothing else** (`appeared(id:)`, `textChanged(id:)`,
`disappeared(id:)`), so there is no parameter a recognized string could travel in.

Identity is a **monotone counter** (`RegionIdentity(rawValue: Int)`), not a UUID and not an object
reference: an identity is released on removal and **never reissued**, which is what "never resurrected
by a later pass" means when the counter only goes up. `consume` matches each observation to a tracked
region by geometry (`regionMatchIoU` **or** `regionMatchCentroidDistance`) **and** normalized-string
equality; hysteresis is two-sided (`regionAppearPasses` publishes, `regionMissPasses` removes), and a
publish/removal/text-change event is emitted only when the emitted set actually changes. Every bound
is a `LiveTranslateConfig` field — no operational literal appears in the file
(`LiveTranslateSourceHygieneTests` scans this directory and passed).

`LiveTranslateTextNormalization` is the **one** normalization: `normalized` = trim + internal-whitespace
collapse + lowercase, `key(text:targetLanguage:)` = that string joined with the language code. T-012
calls the same implementation, so a region's text maps to exactly one cache key; the shared function is
pinned from both sides (`testTheNormalizedTextIsExactlyTheCacheKeyPrefix`,
`testTheKeyIsTheNormalizedTextPlusTheTargetLanguage`). No stemming, no synonym folding: a near-miss is a
miss.

### T-010 — declutter before emission

`declutter(_:config:)` runs inside `consume`, before the change comparison, so the set that is rendered
and the set that would be requested are the same set
(`testDeclutterRunsBeforeEmissionSoTheRenderSetAndTheRequestSetAgree`). It is a total function: merge while any pair qualifies (same normalized string
and centroid distance below `declutterMergeCentroidDistance` on either axis → longest rendering, union
box, the lower identity), then cap to `declutterMaxRegions` by confidence, tie-broken by centroid `y`
then `x`, then emit in canonical order. A capped region is **tracked, not destroyed**: `activeRegionCount`
keeps counting it, and when room appears it returns with its original identity
(`testTheCapIsNotAnErrorAndTheSameRegionReturnsWithTheSameIdentityWhenRoomAppears`). The stage has no
failure channel at all — no `throw`, no `Result<`, no `fatalError` (source scan), so "the cap is not an
error" is a property of the type.

### T-011 — the curated table, extended by data only

`ApplianceLabelLocalizer.dictionary` now holds **120 entries** (47 shipped + 73 added; 115 distinct
Nepali values, 5 deliberate collisions: फिर्ता, चिसो, पगाल्ने, स्रोत, नाजुक) covering remotes/TVs,
cooking, laundry, fridge/AC and general printed labels (warning, fragile, expiry, …). No new type, no
new file, no change to the localizer's contract: exact whole-label match after trim + case-fold,
pass-through for Devanagari, the `isNepali(locale)` gate, the `Display(primary:secondary:)` shape — all
as shipped, and the shipped suite (`ApplianceLabelLocalizerTests`) passes **unedited**. The 47 shipped
entries are frozen by a test that embeds the old mapping verbatim, key-for-key and value-for-value.
There is no reverse lookup and none can be built from this data (the collisions are pinned, not fixed).

### T-012 — one store, two layers, one name (OD8: the name stays `LabelTranslationCache`)

Layer A is answered by **lookup into the shipped dictionary** (`Origin.dictionary`/`curatedDictionary`),
never copied to disk; layer B is one encrypted payload under one key, `plugin.live_translate.cache.v1`
(`Persisted { schemaVersion, entries: [Entry { key, translation, lastAccessSequence }] }`). The placement
policy selects `.encryptedFile`; the feature never calls the file system itself (source scan), and the
whole payload is written through the shipped `EncryptedLocalStorage`.

- **AM-6 — the ordering field is a monotone counter, not a timestamp.** `lastAccessSequence` increments
  on touch, is restored above the payload's maximum on load, and orders entries exactly as an LRU
  timestamp would. A timestamp is forbidden here and no carve-out was taken: a touch happens on lookup,
  i.e. *while the text is on camera*, so a wall-clock value written there would record when that text
  was last in front of the camera — scene-derived metadata of the kind NFR-LCT-008 scenario 2 forbids,
  and one that would survive into the next session. This is why the type is `Int` (a counter needs a
  range, not a clock) and why the design's earlier `lastAccessedAt` wording was corrected (§C05 and the
  persistence table now say `lastAccessSequence`, with the rationale written out).
- **Eviction** is LRU at `cacheGeneralEntryLimit`, and a curated key is **never** a victim — the
  predicate asks the dictionary (`isCuratedKey`), it does not infer from size.
- **Touch coalescing**: one payload write per key per session (`cacheTouchCoalescing`); a dictionary
  hit writes nothing at all; turning coalescing off in config makes every touch write (pinned both
  ways).
- **Self-healing**: an unreadable payload or an unknown schema version is discarded, the reason is
  recorded as a content-free `cache_payload_reset`, and the store rebuilds from the dictionary layer
  and serves nothing stale. A **write** failure still renders the translation from the in-memory index
  and retries on the next resolution of the same key. No cache failure is ever surfaced to the elder;
  `lookup` returns `Result<Hit?, LiveTranslateError>` and every path in the feature treats a failure as
  a miss.
- **Absent vs corrupt** is decided by an optional `RawEncryptedStorage` probe: a store that has no
  payload reads as a **fresh install** (a miss, no reset announced), which is what a first run on a new
  device must look like.
- Exactly **two** `storage.delete(` call sites exist — the feature's own `removeAll()` and the
  self-healing discard — so no consent path can clear the cache (FR-LCT-012 scenario 3). Revocation is
  a non-event for this store, pinned behaviourally and structurally.

### T-013 — the appliance helper's label seam

`ApplianceLabelResolver.resolve(label:locale:cache:)` is the single new seam: the shipped localizer runs
**first** and its result is the answer whenever it produced a translation; the shared store is consulted
only under the shipped gates (Nepali-active locale, non-empty, not already Devanagari) and only for a
`.persisted` entry, which then renders as `Display(primary: translation, secondary: printedEnglish)` —
the same shape a curated label already renders in. A **dictionary-layer** hit is deliberately not
accepted: the localizer has just consulted that same table with its own rule, and accepting it would
render a translation for a label the localizer passes through — a delta outside the class R8 reviewed.

The seam makes no request and stores no entry (source-pinned: no `cache.store(`, no `URLSession`,
`URLRequest`, `GeminiClient`, `URLComponents` in the resolver); it only calls `lookup`, which — as for
any caller — may move the entry's ordering counter and persist the coalesced payload. No translation
data is added, changed or removed by the helper path.

## Shipped-file edits, with the reason each is additive (NFR-LCT-012)

1. **`Services/Appliance/ApplianceLabelLocalizer.swift`** — `+98/-3`. The three deletions are a
   re-wrapped doc comment; the 47 shipped dictionary entries are byte-identical (test-pinned). The 73
   new entries are appended after them. Behaviour of the shipped contract is untouched.
2. **`Services/Appliance/ApplianceHelperView.swift`** — `+16/-2`. Added one stored property
   (`var labelCache: LabelTranslationCache? = nil`, defaulted, so every existing construction site
   compiles unchanged) and replaced the direct
   `ApplianceLabelLocalizer.display(for: control.label, locale: locale)` call with
   `ApplianceLabelResolver.resolve(…).display`. That substitution is behaviour-preserving by
   construction — the resolver calls that same localizer first with the same arguments and returns its
   result whenever it translates — and it is pinned by
   `testR8CaseOneADictionaryKnownLabelRendersExactlyAsBeforeTheSeam` plus the presentation-path scan.
   It is the one edit that changes a shipped line rather than adding beside it, and it is exactly what
   "one caller-side resolver at the seam" means; with `labelCache == nil` (the default) the rendered
   result is the shipped result.
3. **`Services/Plugins/ApplianceHelperPlugin.swift`** — `+12/-3`. Both initialisers gained a defaulted
   `labelCache: LabelTranslationCache? = nil` parameter and one line in `presentationView` passes it on.
   Every existing call site and test keeps compiling and behaves as before.
4. **`App/AppCoordinator.swift`** — `+23/-4`. Added the `labelTranslationCache` property, built once in
   `init` next to the storage it writes through (construction does no I/O), registered it with the
   plugin and handed it to the two presentation sites. The four deletions are: the two-line storage
   assignment (hoisted into a local so the store can be built on the same instance — same object, same
   order), one `registry.register` line and the two `ApplianceHelperView` lines, each extended in
   place.
5. **`specs/design-component.md`** — CL-7 and AM-6 wording corrections the tasks explicitly require:
   §C05 now documents `lastAccessSequence` (and why the timestamp draft was wrong), §C06 now makes the
   honest claim about the labels the helper *translates* (naming the three R8 cases and keeping the R8
   pointer), the persistence table row matches, and the test-seam list gained the three named R8 tests
   the list was missing.

`ios/seniOS.xcodeproj/project.pbxproj` is regenerated by XcodeGen, not hand-edited.

## Gherkin coverage — scenario to test

### T-009 `TextRegionStabilizer`
| Scenario | Tests |
|---|---|
| The same sign keeps one identity across passes | `testARegionIsPublishedOnceTheAppearHysteresisIsSatisfiedAndKeepsItsIdentity`, `testAnUnchangedSceneEmitsNothingAfterThePublishPass` |
| A geometry match with a different string is a text change on the same region | `testAChangedStringOnTheSameBoxKeepsTheIdentityAndReportsATextChange`, `testADependentVowelSignOnTheSameBoxIsATextChangeNotASilentNoOp` |
| Matching uses geometry plus normalized-string equality | `testGeometryAndStringDecideTheMatch` (overlap route and centroid route both match; a disjoint, differently-worded observation starts a new identity), `testAMovedBoxWithTheSameStringIsNotATranslationEvent`, `testAnEmptyOrUnplaceableObservationIsNeverARegion` |
| Hysteresis prevents single-pass flicker in both directions | `testAFirstSightingDoesNotPaintAndAReappearingFlickerDoesNotPublish`, `testOneMissedPassKeepsTheRegionAndTheSecondRemovesItOnce` |
| A stale region is removed exactly once | `testAnIdentityIsReleasedOnRemovalAndNeverReissued`, `testResetDropsEveryRegionAndNeverReissuesAnIdentity` |
| Events are emitted only on a text change | `testAnUnchangedSceneEmitsNothingAfterThePublishPass`, `testATrackedPassMovesGeometryWithoutChangingTextOrEmitting` |
| The stabiliser is a total function and deterministic | `testTheSamePassSequenceTwiceProducesTheSameEventsAndRegions` (same sequence twice → identical identities and events), `testTheVisibleSetDoesNotDependOnTheOrderObservationsArriveIn`, `testAnEmptyOrUnplaceableObservationIsNeverARegion` |
| Normalization matches the cache key exactly | `testTheNormalizedTextIsExactlyTheCacheKeyPrefix`, `testNormalizationTrimsCollapsesAndCaseFoldsButNeverStemsOrFoldsSynonyms` |
| DoD: Devanagari cluster regression fixture (pinned, not "fixed") | `testDevanagariCharacterClustersArePinnedAndMatchingStaysWholeString`, `testADependentVowelSignOnTheSameBoxIsATextChangeNotASilentNoOp` |
| DoD: no recognized text in any event payload | `testNoRecognizedStringCanTravelInAnEvent` (structural: every case's payload is an identity and nothing else; behavioural: a real scene's events through `LiveTranslateSanitisingBus` carry no string, and the published event is `region_appeared` by type only) |

### T-010 decluttering
| Scenario | Tests |
|---|---|
| Same-string neighbours merge into one region | `testSameStringNeighboursMergeIntoOneRegionWithTheLongestTextAndTheUnionBox` (longest rendering, union box asserted edge by edge, lower identity kept), `testMergingIsAppliedUntilNothingQualifies` (merge applied until no pair qualifies) |
| Regions with different strings never merge | `testDifferentStringsOnTheSameBoxNeverMergeAndAreNeverConcatenated` |
| The region cap keeps the highest-confidence set deterministically | `testTheCapKeepsTheHighestConfidenceRegionsTieBrokenByPosition`, `testTheCapTieBreaksByXWhenTwoRegionsShareAConfidenceAndARow` |
| Every kept region produces exactly one overlay | `testExactlyOneOverlayPerKeptRegion` (identities unique in the emitted set; the merged pair is one overlay) |
| Decluttering is deterministic and order-independent | `testTheSameCandidatesInTwoOrdersProduceIdenticalRegions` (forwards, backwards, shuffled → identical regions, boxes and order) |
| The cap is not an error | `testTheCapIsNotAnErrorAndTheSameRegionReturnsWithTheSameIdentityWhenRoomAppears`, `testTheStabiliserCannotReportAFailureThroughItsResult` (no `throw`, no `Result<`, no `fatalError` in the source) |
| (DoD) the render set and the request set agree | `testDeclutterRunsBeforeEmissionSoTheRenderSetAndTheRequestSetAgree`, `testSameStringRegionsFurtherApartThanTheMergeDistanceOnBothAxesStayTwoRegions`, `testTheMergeRuleIsPerAxisSoSameStringRegionsSharingAColumnAxisMerge` (see Open item 2) |

### T-011 curated dictionary
| Scenario | Tests |
|---|---|
| Every shipped entry keeps its exact translation | `testEveryShippedEntryKeepsItsExactKeyAndValue` (the 47-entry mapping embedded verbatim in the test), `testTheExtensionReachedTheDesignsCoverageTargetAndAddedNoDuplicateSpellings` |
| A curated label resolves with no network | `testACuratedLabelResolvesWithNoNetworkPathInvolved` (behavioural + `import Foundation` is the only import; no `URLSession`/`URLRequest`/`GeminiClient`/`NWPathMonitor`/`Task {`), `testTheNewEntriesCoverTheDesignsCategories` (category probes) |
| Matching stays exact | `testMatchingStaysExactAndANearMissIsNeverAHit` (trim + case-fold are hits; `Washing`, `washer`, `child-lock`, `keep  warm` … are not), plus the shipped `ApplianceLabelLocalizerTests` unedited |
| Text already in Devanagari passes through | `testTextAlreadyInDevanagariIsPassedThroughRatherThanMapped`, plus the shipped `isNepali(locale)` assertions unedited |
| The dictionary is never reversed | `testTheDictionaryIsOneToManyAndNoReverseLookupExists` (the 5 collisions pinned; no Nepali-keyed entry in the source; a Nepali input under a Nepali locale never comes back as English) |

### T-012 `LabelTranslationCache`
| Scenario | Tests |
|---|---|
| A curated label is a hit on a fresh install | `testACuratedLabelIsAHitOnAFreshInstallWithNothingReadOrWritten` (zero reads, zero writes), `testANepaliOnlyCuratedHitIsNotServedForAnotherTargetLanguage` |
| A repeated cloud translation is served from the persisted layer | `testARepeatedCloudTranslationIsServedFromThePersistedLayerInThisAndALaterSession` (same and later session, `origin` recorded), `testTheBytesOnDiskAreOneProtectedEnvelopeAndNoSecondCopy` |
| The key is the normalized text plus the target language | `testTheKeyIsTheNormalizedTextPlusTheTargetLanguage` (identical to `LiveTranslateTextNormalization.key`), `testTheTargetLanguageIsPartOfTheKey`, `testAVariationInWhitespaceOrCaseIsTheSameEntryAndANearMissIsNot` |
| Nothing beyond the permitted fields is stored | `testEachStoredEntryHoldsOnlyTheKeyTheTranslationAndTheOrderingCounter` (decoded field set is exactly `{key, translation, lastAccessSequence}`; a forbidden-name scan for image/box/timestamp/identifier/location), `testTheBytesOnDiskAreOneProtectedEnvelopeAndNoSecondCopy` (one file, digest filename, no image or metadata sidecar) |
| The persisted payload is encrypted and reset-safe | `testThePayloadIsOnTheEncryptedFileChannelAndTheFeatureNeverTouchesTheFilesystem` (placement policy, `.completeFileProtection`, no file-system API in the feature), `testTheBytesOnDiskAreOneProtectedEnvelopeAndNoSecondCopy` (written through the real `EncryptedFileStorage`), `testAnUnreadablePayloadIsDiscardedAndRebuiltFromTheDictionaryLayer`, `testAnUnknownSchemaVersionIsTreatedLikeACorruptPayloadAndServesNothingStale`, `testAnUnreadableStoreReadsAsAnEmptyCacheOnAFreshInstallRatherThanAReset` |
| Eviction respects the curated set | `testEvictionIsLeastRecentlyUsedAndBoundedByTheConfiguredLimit`, `testACuratedKeyIsNeverChosenAsAVictimEvenAtTheBound` |
| LRU touching is coalesced | `testTouchCoalescingHoldsOverALongSyntheticRunAndDictionaryHitsTouchNothing` (50 lookups → one write for the key; dictionary hits write nothing), `testCoalescingCanBeTurnedOffByConfigurationAndThenEveryTouchWrites` |
| A write failure never breaks the feature | `testAWriteFailureStillRendersFromMemoryAndRetriesOnTheNextResolution`, `testNoEventCarriesTheRecognizedTextTheTranslationOrAnySceneMetadata` |
| Revocation does not clear the cache | `testNothingButTheFeaturesOwnRemovalPathEverDeletesTheCache` (no delete on any resolution path; exactly two delete call sites in the source), `testRemoveAllDeletesOnlyTheDeclaredStorageKeyAndRebuildsEmpty` |

### T-013 the helper seam
| Scenario | Tests |
|---|---|
| The same label resolves identically on both surfaces | `testTheSameLabelResolvesIdenticallyOnBothSurfaces` (curated and persisted labels: same translation, same tier, same origin), `testR8CaseTwoACachePopulatedLabelRendersTheCachedTranslation` |
| Localizer precedence is preserved | `testR8CaseThreeTheLocalizerWinsOverTheCacheWhenBothWouldAnswer` |
| A helper-rendered label is a cache hit for the live path | `testAHelperResolvedLabelIsACacheHitForTheLivePathWithNoCloudRequest` (the live lookup is a `.persisted` hit, no miss recorded, no translation batch requested, and the helper path adds no entry) |
| The helper's shipped behaviour is unchanged apart from the recording delta | the three named R8 cases, `testTheHelperDoesNotAugmentOutsideTheShippedGates` (English locale, Devanagari, empty, `nil` cache → the shipped pass-through), `testThePresentationViewResolvesThroughTheSeamAndDefaultsToTheShippedBehaviour` |
| There is exactly one store and one dictionary | `testThereIsExactlyOneStoreAndOneDictionaryAcrossTheSurfaces` (one `LabelTranslationCache` declaration, one curated table, no private store/`UserDefaults`/`FileManager` in the resolver, no storage write in the view), `testTheSameLabelResolvesIdenticallyOnBothSurfaces` |
| The helper is not exposed to the live path's consent state | `testTheHelperIsNotExposedToTheLivePathsConsentState` (no consent symbol can appear in the resolver; the helper's behaviour is identical with an absent, populated or corrupt store) |

## Decisions made during implementation

- **AM-6: the ordering field is a monotone counter, and the design text was corrected rather than
  worked around.** `lastAccessSequence: Int` orders entries exactly as an LRU timestamp would. No
  carve-out, no "cache-internal so it is not scene metadata" argument — see the §C05 text, which now
  says why the timestamp draft was wrong.
- **The identity is a counter, not a UUID.** "Released and never resurrected" is a comparison
  (`identity < nextIdentity`), and `RegionIdentity` stays `Hashable`/`Comparable`/`CustomStringConvertible`
  for deterministic ordering and readable test failures. A UUID would have made release unprovable and
  the canonical order random.
- **One normalization, two callers.** `LiveTranslateTextNormalization` lives in
  `TextRegionStabilizer.swift` and is called by both the stabiliser and the cache key. Neither side has
  its own trim/collapse/case-fold, and a test asserts the two agree character for character.
- **The merge rule is per-axis because the spec says per-axis — including its consequence.** "Closer
  than the merge distance on **either** axis" (T-010 §Merge rule, design §C03 item 1) means two
  occurrences of one word that share a column also merge, since their x-separation is zero. The
  implementation follows the written rule and the consequence is pinned by
  `testTheMergeRuleIsPerAxisSoSameStringRegionsSharingAColumnAxisMerge`; it is reported as Open item 2
  for the OD5 device spike rather than "fixed" against the rule.
- **A dictionary-layer hit is not accepted at the helper seam.** The localizer already consulted that
  table with its own rule, so accepting the cache's layer A would render a new translation for a
  pass-through label — a delta outside the class R8 reviewed. Only `.persisted` hits are used.
- **The seam "reads" is now stated precisely.** A lookup moves the entry's ordering counter and the
  coalesced payload may be rewritten; that is the cache's own bookkeeping and it happens for every
  caller. The resolver's doc comment and the test say that instead of claiming "writes nothing", which
  was a claim a single `writeCount` assertion could not keep (see Open item 3).
- **Absent vs corrupt is decided by a raw probe, not by guessing.** `EncryptedLocalStorage` cannot
  distinguish "no payload" from "unreadable payload"; the optional `RawEncryptedStorage` conformance
  answers it, so a first run reads as a fresh install (a miss) while a broken payload is a `reset`.
  Without the probe, a new device would have logged a reset on every first lookup.
- **Curated keys are non-evicting by predicate, not by size.** `isCuratedKey` asks the dictionary, so a
  future curated entry can never become a victim because it happens to be old.
- **Content-free events only.** Every emitter carries counts and closed tokens
  (`LiveTranslateCacheOrigin`, `origin`, `count`); the cache's whole event sweep is asserted against
  `LiveTranslateEventCatalogue`, and the stabiliser's event type structurally cannot carry a string.
- **The `UInt64` that never was.** The first draft typed the ordering counter `UInt64`; the sequence
  literal `64` is on T-003's banned token list for the feature directory
  (`LiveTranslateSourceHygieneTests` scans `Services/LiveTranslate/`), so it became `Int` — which is
  also the honest type for a counter.
- **CL-7's wording fix landed in the design, not just in the code.** §C06 no longer claims that "every
  label the helper renders today renders identically"; it says what is true — every label the helper
  *translates* today renders identically — names the three R8 cases, and states the one recorded delta
  (a pass-through label with a persisted entry now renders that translation).

## Verification performed

**Gate 1 (this group's suites + the shipped suites they can affect): PASS — exit 0, 107 tests, 0 failures.**

```
xcodebuild test \
  -project /Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/seniOS.xcodeproj \
  -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath /Users/anjan/workspace/projects/elderly-ai-assistant/.claude/worktrees/live-camera-translation/ios/build/DerivedDataTests \
  -resultBundlePath /tmp/tg0304-second.xcresult \
  -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/TextRegionStabilizerTests \
  -only-testing:ElderlyAssistantTests/TextRegionDeclutterTests \
  -only-testing:ElderlyAssistantTests/LabelTranslationCacheTests \
  -only-testing:ElderlyAssistantTests/ApplianceLabelDictionaryTests \
  -only-testing:ElderlyAssistantTests/ApplianceHelperLabelSeamTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/ApplianceLabelLocalizerTests \
  -only-testing:ElderlyAssistantTests/ApplianceHelperSessionTests
```

`** TEST SUCCEEDED **`, `xcrun xcresulttool get test-results summary` → `"result": "Passed"`,
`"totalTestCount": 107`, `"passedTests": 107`, `"failedTests": 0`, `"skippedTests": 0`, device
`iPhone 17 / iOS 26.5 (x86_64)`, simulator id `990E1710-4805-46E2-8FED-BD1DE12D1BE8`.

Per suite: `TextRegionStabilizerTests` 18, `TextRegionDeclutterTests` 12, `LabelTranslationCacheTests`
21, `ApplianceLabelDictionaryTests` 7, `ApplianceHelperLabelSeamTests` 9 (new: 67), plus the shipped
suites that read the files this group touched, **unedited**: `LiveTranslateSourceHygieneTests` 6,
`ApplianceLabelLocalizerTests` 9, `ApplianceHelperSessionTests` 25.

**Gate 2 (the shipped appliance area, unedited, as the NFR-LCT-012 evidence): PASS — exit 0, 137 tests,
0 failures.** Same invocation with `-resultBundlePath /tmp/tg0304-appliance.xcresult` and
`-only-testing` over `ApplianceCacheTests` 35, `ApplianceCategoryKeyTests` 9,
`ApplianceCropGeometryTests` 9, `ApplianceGuidancePolicyTests` 7, `ApplianceImagePreparerTests` 8,
`ApplianceManualLibraryTests` 18, `ApplianceOverlayMapperTests` 9, `ApplianceStepCardPlannerTests` 7,
`ApplianceZoomGeometryTests` 8, `BundledManualCatalogTests` 12, `DevanagariNumeralsTests` 4,
`UserManualCatalogTests` 11. `"result": "Passed"`, 0 failures. No assertion in any of those files was
edited — `git status` shows no test file modified, only added.

**Privacy guard.** `ios/tools/check-release-log-safety.sh` → exit 0 ("no transcript content or raw error
object can be printed in a non-Debug configuration"); `build.sh` runs it before every test gate.

**`ios/build.sh` (the DoD line): PASS — `./build.sh build`, exit 0, `** BUILD SUCCEEDED **`, Release
`iphoneos` compile-check of the `ElderlyAssistant` app target (unsigned, no `DEVELOPMENT_TEAM`), which
also re-runs XcodeGen (`✓ seniOS.xcodeproj regenerated`).**
`build.sh test:unit` runs the whole unit bundle, which is red on master independent of this work (21
failures in unrelated suites, the pre-existing baseline TG-01/TG-02 recorded); the two scoped gates
above mirror its flags exactly (generated `seniOS.xcodeproj`, scheme `ElderlyAssistant`, warm
`build/DerivedDataTests`, `-skip-testing:ElderlyAssistantUITests`) with the destination pinned to this
worktree's own simulator. The full unit bundle was **not** re-run by this group, so the claim here is
scoped to what was run: these 244 tests, in 20 suites, pass.

### T-009 DoD
- "All Gherkin scenarios covered by automated tests" — table above; 18 tests.
- "Determinism test over a fixed pass sequence, run twice" —
  `testTheSamePassSequenceTwiceProducesTheSameEventsAndRegions`.
- "A test asserts no event is emitted for an unchanged scene" —
  `testAnUnchangedSceneEmitsNothingAfterThePublishPass`.
- "A regression fixture pins the Devanagari normalization behaviour (character clusters)" —
  `testDevanagariCharacterClustersArePinnedAndMatchingStaysWholeString` (a conjunct is one `Character`
  and survives normalization intact; `म` ≠ `मा`; the fixture pins, it does not "fix").
- "No recognized text appears in any event payload, asserted by test" —
  `testNoRecognizedStringCanTravelInAnEvent`.
- "`ios/build.sh` passes" — see Open item 4.
- "Code reviewed and merged" — the driver's step; nothing was committed by this group.

### T-010 DoD
- "Determinism test: the same candidates in two orders produce identical output, and a capped set is
  reproducible" — `testTheSameCandidatesInTwoOrdersProduceIdenticalRegions`,
  `testTheCapKeepsTheHighestConfidenceRegionsTieBrokenByPosition`.
- "A test asserts the merged box is the union and the text is the longest of the set" —
  `testSameStringNeighboursMergeIntoOneRegionWithTheLongestTextAndTheUnionBox` (box edges asserted with
  `accuracy: 1e-9`).
- "A test asserts a capped set raises no error and no degraded marker" —
  `testTheCapIsNotAnErrorAndTheSameRegionReturnsWithTheSameIdentityWhenRoomAppears`,
  `testTheStabiliserCannotReportAFailureThroughItsResult`.
- "`ios/build.sh` passes" — see Open item 4.

### T-011 DoD
- "A regression test pins every shipped entry's key and value" —
  `testEveryShippedEntryKeepsItsExactKeyAndValue`.
- "A test asserts a near-miss is not reported as a hit" — `testMatchingStaysExactAndANearMissIsNeverAHit`.
- "`ios/build.sh` passes" — see Open item 4.

### T-012 DoD
- "A test inspects the on-disk bytes and asserts no plaintext translation is present" — **not literally
  satisfiable, reported rather than faked: see Open item 1.** What is asserted instead:
  `testTheBytesOnDiskAreOneProtectedEnvelopeAndNoSecondCopy`,
  `testThePayloadIsOnTheEncryptedFileChannelAndTheFeatureNeverTouchesTheFilesystem`,
  `testEachStoredEntryHoldsOnlyTheKeyTheTranslationAndTheOrderingCounter`.
- "A test asserts an unreadable or unknown-version payload resets to the dictionary layer and serves
  nothing stale" — `testAnUnreadablePayloadIsDiscardedAndRebuiltFromTheDictionaryLayer`,
  `testAnUnknownSchemaVersionIsTreatedLikeACorruptPayloadAndServesNothingStale`.
- "A test asserts a curated key is never evicted at the bound" —
  `testACuratedKeyIsNeverChosenAsAVictimEvenAtTheBound`.
- "A test asserts the touch coalescing bound holds over a long synthetic run" —
  `testTouchCoalescingHoldsOverALongSyntheticRunAndDictionaryHitsTouchNothing`.
- "No PII, no recognized text and no scene metadata in any event payload, asserted by test" —
  `testNoEventCarriesTheRecognizedTextTheTranslationOrAnySceneMetadata` (swept against
  `LiveTranslateEventCatalogue`).
- "`ios/build.sh` passes" — see Open item 4.

### T-013 DoD
- "The helper's existing test suite passes with no edits to its assertions" —
  `ApplianceHelperSessionTests` (25) and `ApplianceLabelLocalizerTests` (9) in Gate 1, plus the twelve
  other shipped appliance suites (137 tests) in Gate 2; none edited.
- "A three-case regression test covers localizer precedence, shared-store hits and the unchanged helper
  result" — the three named R8 cases in `ApplianceHelperLabelSeamTests`, also recorded in the
  design's test-seam list.
- "Pin the known Devanagari substring behaviour" — `TextRegionStabilizerTests`'
  cluster fixture (T-009 test file; the matching is whole-string by design, so no substring lookup
  exists to pin).
- "`ios/build.sh` passes" — see Open item 4.

## Environment findings (not source changes; the next task in this worktree will hit them)

- **The pinned simulator** `990E1710-4805-46E2-8FED-BD1DE12D1BE8` is iPhone 17 / iOS 26.5 / x86_64 and
  is the only destination any gate in this group used. Reading results with
  `xcrun xcresulttool get test-results summary --path <bundle>.xcresult` is the fast path; the plain
  log's `Executed N tests` line is the cheap per-suite count.
- **A float asserted with `XCTAssertEqual` at default accuracy fails on accumulated drift.** Union boxes
  computed from several edges produced `0.22000000000000003` vs `0.22`; every box-edge assertion in this
  group now passes `accuracy: 1e-9`.
- **`FeatureSourceScan.firstMatch` matches line by line and takes a regular expression** (invalid
  patterns fail the test), so multi-line patterns can never match and any token with regex
  metacharacters must go through `NSRegularExpression.escapedPattern(for:)`. Two scans in this group were
  rewritten for exactly that (`cache.store(`, `static func resolve(label: String,`).
- **`xcresulttool`'s per-suite counts are not in the summary**; the log's `Test Suite '<X>' passed`
  line followed by `Executed N tests` is the pairing to read.
- **A Debug test build compiles the whole test target even with `-only-testing`.** Both gates therefore
  prove that every file in `ElderlyAssistantTests` compiles, not just the selected suites.

## Open items (reported, not silently closed)

1. **T-012's "no plaintext translation is present on disk" is not literally satisfiable, and nothing was
   faked to make it look satisfied.** The placement policy selects the encrypted-file channel, but that
   channel is **Data Protection** (`completeFileProtection`) — an OS access-control property, not a
   cipher applied by this app. In the simulator the payload the store writes is readable JSON, and the
   in-memory `EncryptedFileStorage` envelope test can decode it. The strongest true properties are
   asserted instead: exactly one file at the declared key, filename = SHA-256 of the key, exactly the
   permitted fields (no image, no box, no scene timestamp, no device identifier, no location), no second
   copy or sidecar, and `.completeFileProtection` + backup exclusion pinned at the store. If the product
   requirement is "not readable by anyone with the file", that needs a key-management decision (a
   Keychain-held key and app-level encryption) — a change to the storage layer, not to this cache.
2. **The per-axis merge rule has a visible consequence: same-string regions sharing a column merge.**
   T-010 §Merge rule and design §C03 item 1 both say "closer than the merge distance on **either**
   axis", so two "Save" labels one above the other (x-separation 0) are merged into one overlay with a
   tall union box, even though they are far apart. The implementation follows the written rule and
   `testTheMergeRuleIsPerAxisSoSameStringRegionsSharingAColumnAxisMerge` pins it. This is exactly the
   kind of thing OD5's device spike should decide (merge distance, axis rule, and whether a column of
   identical labels should stay two) — it needs a spec decision, not a silent code change.
3. **A helper lookup is not a write-free operation.** The resolver only reads, but the cache's LRU
   bookkeeping moves the entry's counter and may rewrite the coalesced payload once per key per session;
   the first version of the seam test asserted `writeCount == 0` and failed for that reason (the
   behaviour was correct, the claim was not). The test now asserts the payload's entries are unchanged
   and that the resolver contains no `cache.store(`, and the resolver's doc comment states the precise
   property. If "the helper must never cause a store write" is a product requirement, the cache needs a
   `lookup(touching: false)` mode — not introduced here, because it is a new policy knob.
4. **The `ios/build.sh` DoD line.** `./build.sh build` was run in this worktree: **exit 0,**
   `** BUILD SUCCEEDED **` (Release `iphoneos`, unsigned compile-check of the app target). The stronger
   `./build.sh test:unit` mode runs the whole unit bundle, which is red on master independent of this
   work (the pre-existing 21 failures TG-01/TG-02 recorded in unrelated suites), so it cannot be green
   here; two scoped gates mirroring its flags were run instead (107 + 137 tests, 0 failures), and
   `ios/tools/check-release-log-safety.sh` (which `build.sh` runs first) exits 0. `Code reviewed and
   merged` remains the driver's step for all five tasks.
5. **T-012's "LRU bookkeeping timestamp" wording in the task file still says "timestamp"** while AM-6
   forbids one. The design was corrected (§C05, persistence table) and the implementation stores
   `lastAccessSequence`; the task file's scenario line "the key, the translation and the LRU bookkeeping
   timestamp" is left as written because task files are the plan's record of intent, and the binding
   decision (AM-6) is the one implemented. Flagged so the phrasing is not read as licence for a
   timestamp in T-019/T-026.
6. **The pipeline-level region events are T-026's.** The stabiliser is pure by spec (no bus), so
   `region_appeared` / `region_removed` / `text_change` are emitted by the pipeline that drives it. This
   group pins that the change event *cannot* carry text and that the cache's own emitters are
   content-free; the wiring that turns `RegionChangeEvent` into a catalogued event with counts lands
   with T-026, which must not add a string parameter on the way.
7. **Two `LiveTranslateConfig` knobs exist but are exercised only in tests here.** `cacheTouchCoalescing`
   and `declutterMaxRegions` are read by this group's code and covered by tests that vary them; the
   shipped values remain T-001's. No tuned value was introduced.

## Out-of-scope capabilities — confirmed absent, not stubbed

`LabelTranslationCache.swift` contains no `FileManager`, no `FileHandle`, no `Data(contentsOf:)`, no
`URLSession`/`URLRequest`/`dataTask`, no `UserDefaults` and no second storage key; it writes and reads
only through the injected `EncryptedLocalStorage` at `plugin.live_translate.cache.v1`. There are exactly
two `storage.delete(` call sites (its own `removeAll()` and the self-healing discard), asserted by
count. `TextRegionStabilizer.swift` contains no `throw`, no `Result<`, no `fatalError`, no `Date`, no
`DispatchQueue` and no I/O; it is a value type whose only output is an id-only event.
`ApplianceLabelResolver.swift` contains no store construction, no `UserDefaults`, no `FileManager`, no `static var`,
no consent symbol and no network symbol. The curated table has no reverse lookup and no network path
(`import Foundation` is its only import). Nothing in this group's code path contains a placeholder that
returns success without doing the work.
