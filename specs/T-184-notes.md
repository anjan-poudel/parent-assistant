# T-184 notes — v17 chat-variant catalog entry and the gated swap

Unit: T-184 (TG-37, v17 chat-aware training suite), depends on T-177/T-183.
Feature: conversational-nepali-replies (CNR); branch `feat/conversational-nepali-replies`;
worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(base `9cafa3cc`, "[CNR] T-183: record the box-side v17 trainer workspace").
Spec: `specs/plan-tasks/tasks/TG-37-v17-chat-aware-training-suite/T-184-v17-catalog-entry-and-gated-swap.md`.
No push; one commit; no chain/router/prompt changes, no Info.plist/schema/permission
changes. No network, no billed calls, no artifact publication in this unit.

**Ship state: the entry is PRESENT BUT NOT PROMOTED.** That is the complete and
honest outcome of this unit: the run's full-gate report does NOT exist (the chat
judge is blocked on a funded API key; the latency gate is unmeasured until the
Anzaan DV session), so the promotion record ships BLOCKED and every automatic
serving path resolves to the previous entry. Promotion is the blocked action,
gated and recorded — never a hardcoded green.

## What was built

### 1. `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` (+318/-7)

**The entry** — `intentQwenS43ChatV17` (`ModelID("intent-ne-qwen-s43-chat-v17-q4km")`),
a new id BESIDE `intentQwenS43`, never in place of it:

| field | value |
|---|---|
| kind | `.llamaBase` |
| displayName | `Brain — Qwen 1.7B · Nepali chat-aware (v17 · gates pending)` |
| filename | `intent-ne-qwen-s43-chat-v17-q4_k_m.gguf` |
| downloadURL | `https://invalid.invalid/cnr-v17/…` — RFC 2606 placeholder, PUBLICATION PENDING (the digest is the REAL local artifact's identity, so an untimely tap is an honest failed download, never a wrong file; only the URL changes when the asset publishes) |
| sizeBytes | `1_107_408_736` |
| sha256 | `e05cc8a266198336f508cef2f6d2a8887b3db1eee3f4a4159cdeb2ab3df59d71` |
| minDeviceRAMBytes | `3_000_000_000` (same floor as the seed-43 sibling) |
| dependsOn | nil |
| languages | `["ne"]` |

Identity from T-183's run `cnr-v17-20261015-0209`: same `checkpoints/qwen-s43-merged`
1.7B lineage and Q4_K_M quantizer as the shipped seed-43 file (sha `c2135f78…`,
`1_107_408_576` bytes — the v17 file is 160 bytes larger). Both land in the same
`ModelLifecycleBudget.brainClasses` rung (file ≤ 1.5 GB), so the memory class is
the sibling's; the eviction question stays `ModelBudgetPolicy`'s.

Offered in `availableBrainEntries` at index 1 (after the slot-canonical 4B, before
the seed-43 sibling — `intentQwen4BSlotCanon` stays `.first`, which a multipart
test pins). The previous entry remains offered and selectable with its own
unchanged evidence — that is the rollback target.

**The promotion record** — new MARK section "The v17 chat-variant promotion
(reference data, gated)":

* `ChatVariantPromotionRecord` — the evidence a promotion must carry:
  `modelID`; `artifactSHA256` + `artifactSizeBytes` (binding identity, checked
  against the shipped entry); `provenanceManifestSHA256`; `gateReportPath` +
  `gateReportSHA256` (the FULL-GATE report's location and digest, recorded at
  promotion time so the evidence the promotion was decided on stays addressable);
  `gates: [GateVerdict]` (`name`, `passed`, in the report's own order).
* `ChatVariantPromotionBlock` — closed vocabulary, `reasonCode`: `artifact_mismatch` /
  `gate_report_missing` / `manifest_missing` / `no_gates_recorded` / `gate_failed`.
  No report path or gate name ever reaches a log surface.
* `promotionVerdict(for:)` — deterministic block precedence: artifact identity →
  gate report → manifest → non-empty gates → per-gate. `.promoted` is the LAST
  case: evidence complete enough to reach it is evidence complete enough to ship.
  (Hand-written `==` on `ChatVariantPromotionVerdict`, comparing promoted verdicts
  by entry id — `ModelCatalogEntry` deliberately carries no `Equatable`, the
  `AutomaticPick` house pattern.)
* `chatVariantPromotionRecord` — the SHIPPED state: a complete attempt, honestly
  blocked. It carries the real artifact identity (matching the entry pin) and the
  run's manifest hash `fb7f7779c801706caddc74ef499198eb14c1ddc05dd89da1a7766cd476adab55`;
  `gateReportPath`/`gateReportSHA256`/`gates` are empty ON PURPOSE (no full-gate
  report exists), so the verdict resolves to `.blocked(.gateReportMissing)`.
* `promotedChatVariantEntry(record:)` — the entry a record admits, or nil.
* `isAutomaticPickEligible(_:record:)` — a record-named chat variant is eligible
  for the automatic ladder only once `.promoted`; everything the record does not
  name is untouched; nil record gates nothing.

**Enforcement at the resolution seams** — the gate is expressed where serving
happens, not in a comment on the map:

* `defaultEntry(kind:language:promotionRecord:)` — new step −1: the promoted chat
  variant serves first when the record is `.promoted` and it serves the kind and
  language (language compatibility inlined; a reverse call into
  `LanguageModelResolver` would make the pair mutually recursive). While the
  shipped record is blocked this step answers nothing and every step below is
  byte-identical to pre-CNR behavior.
* `explicitDefaultEntry(kind:language:promotionRecord:)` — a `languageDefaultPicks`
  entry that names a record-BLOCKED chat variant is refused (nil → the generic
  steps answer). Pointing the map at v17 while the record is blocked does not
  promote it; it falls through exactly as if the map had not moved.
* `isAutomaticPickEligible` filter inside `resolvedAutomaticPick`'s candidate
  ladder — without it the v17 file's 160 extra bytes would make it the step-2
  "largest fitting" winner on classes the seed-43 entry serves when the warm-STT
  footprint tightens the budget, i.e. it would be silently promoted by arithmetic.
  This is the reason the filter exists; it is pinned by
  `testTheVariantsExtraBytesNeverWinTheLargestFittingStepWhileBlocked`.

### 2. `ios/ElderlyAssistant/Services/ModelStore/LanguageModelResolver.swift` (+45/-13)

* `AutomaticPick` gains `deviceClass: ModelLifecycleBudget.DeviceClass` (the policy's
  own class, set in all four constructors, included in the hand-written `==`) —
  the "decision recorded with the tier named" field for FR-CNR-022's
  tier-inadmissible failure path, without re-deriving the class from the probe.
* `resolvedAutomaticPick(…, promotionRecord: = ModelCatalog.chatVariantPromotionRecord)`
  threads the record into `ModelCatalog.defaultEntry` (step 1) and filters the
  candidate ladder with `ModelCatalog.isAutomaticPickEligible`. The default
  argument is the SHIPPED record, so every pre-existing caller — including every
  pre-existing test — is gated by the shipped evidence state without passing
  anything.

### 3. `ios/ElderlyAssistant/App/AppCoordinator.swift` (+70/-2)

* `resolveBrainModelID` rule 2 passes `ModelCatalog.chatVariantPromotionRecord`
  explicitly (one grep finds the wiring); rule 1 (explicit pick) deliberately
  does NOT gate — a household that picks v17 by hand is served it, which is what
  "selectable" means and what the entry's name ("gates pending") discloses.
  `defaultBrainModelID` itself is UNTOUCHED (still `intentQwenS43`).
* `recordAutomaticBrainResolutionIfMoved` emits the decision record with
  `slot=brain`, `tier=<compact|standard|roomy>` (`pick.deviceClass`),
  `reason=<token>` — all three keys are shipped `LogSanitiser.allowedKeys`
  entries ("tier" included; disjoint value vocabularies, closed either way).
* New `chatVariantPromotionEvent(block:)` (static/pure, testable without an
  instance) + `recordChatVariantPromotionIfBlocked()`, called from
  `ensureAssistantBrainDownloadIfNeeded()` beside the resolution record: while
  the shipped record is blocked, one `chat_variant_promotion` event per launch
  carrying `slot=brain` and the block's `reasonCode` (`gate_report_missing` in
  the shipped state); silent the moment the record promotes.

### 4. `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift` (+11)

One `measuredFramings` row: `intentQwenS43ChatV17: .qwen3  // inherited (see above)` —
INHERITED from the seed-43 measurement (same base lineage, same training
pipeline), per the `intentQwen4BSlotCanon` precedent. An offered brain without a
row would fail `BrainModelSelectionTests.testEveryOfferedBrainHasAMeasuredChatFraming`
and would otherwise fall to the LLaMA 3.2 `default:` branch — wrong framing.
Re-run `tools/train-intent/src/framing_check.py` on the v17 artifact when it
publishes and replace the row with its own measurement. **This file is a
documented necessity deviation — not in the unit's declared file list** (see
Deviations).

### 5. Tests — `ios/ElderlyAssistantTests/Services/ModelStore/ModelCatalogChatVariantTests.swift` (new, 535 lines, 20 tests)

| DoD coverage area | tests |
|---|---|
| entry listing/selection | `testTheChatVariantEntryPinsTheRealArtifactFacts`, `testTheEntryIsOfferedBesideThePreviousEntry`, `testTheChatVariantSpeaksTheSameMeasuredChatSchemeAsItsBaseLineage`, `testExplicitSelectionServesTheChatVariantWhileItIsUnpromoted` |
| promotion blocked + reported | `testTheShippedPromotionRecordIsBlockedAndSaysWhy`, `testABlockedRecordKeepsTheDefaultOnThePreviousAnswer`, `testABlockedChatVariantIsNeverServedByTheAutomaticLadder`, `testTheShippedBlockIsReportedWithAClosedVocabularyToken` |
| hash/evidence mismatch rejected | `testAMissingManifestBlocksAPromotion`, `testARedGateBlocksAPromotionAndIsNamed`, `testAnEmptyGateListIsNotAGreenReport`, `testAnArtifactMismatchIsRejectedAndTheEntryIsNotServed`, `testAMapPickPointingAtABlockedVariantIsRefused` |
| promotion (green path, fixture record) | `testGreenEvidencePromotesTheDefaultToTheVariant`, `testPromotionServesTheVariantOnTheTierThatHoldsIt` |
| rollback as a catalog operation | `testRollbackRevertsTheRecordAndThePreviousEntryServesAgain` |
| single residency (one handle) | `testTheVariantAndItsSiblingShareTheSingleBrainHandle`, `testTheInterpreterKeepsExactlyOneHandleSlot` |
| tier-inadmissible keeps the admissible model | `testATierThatCannotHoldTheVariantKeepsTheAdmissibleModelAndNamesTheTier` |
| the 160-byte arithmetic hazard | `testTheVariantsExtraBytesNeverWinTheLargestFittingStepWhileBlocked` |

The single-residency pair exercises `switchBaseModel` between the variant and its
siblings (handle dropped both ways, `lifecycle.didUnload(.brain, owner: self)`)
and structurally pins `LlamaCommandInterpreter.swift` (exactly one
`var llmInstance`; the switch path nils it) via `FeatureSourceScan.codeText(of:)`.

Rebased pin (same fact-moved, not a behavior change): `BrainModelSelectionTests`
(+38/-5) — the curated-list pin gains v17 at index 1; new
`testThePreviousBrainEntryStaysSelectableBesideTheChatVariant` pins the rollback
target (filename / size `1_107_408_576` / sha `c2135f78…` / kind); the
determination table gains `(intentQwenS43ChatV17, .qwen3)`. These pins
INEVITABLY move when an entry joins the picker; they are the tests that would
fail if the entry were missing.

## Evidence (scoped xcodebuild; no full suite; no clean, no DerivedData deletion)

**Baseline, pre-edit** (2026-10-16 23:41, `/tmp/cnr-t184-baseline.log`):
`./build.sh test:unit` over the pre-existing pin classes (BrainModelSelectionTests,
LanguageModelResolverTests, ModelCatalogLanguageTests, MultipartDownloadTests) —
`Executed 102 tests, with 1 test skipped and 1 failure`; the captured failure is
the pre-existing stale pin
`MultipartDownloadTests.swift:232: XCTAssertEqual failed: ("intent-ne-qwen-s43-q4km") is not equal to ("intent-ne-qwen4b-slotcanon-q4km")`.

**Unit run** (2026-10-17 00:33–00:36, `/tmp/cnr-t184-run4.log`):

```
./build.sh test:unit ModelCatalogChatVariantTests BrainModelSelectionTests \
  LanguageModelResolverTests ModelCatalogLanguageTests ModelBudgetPolicyTests \
  InterpreterAvailabilityTests MultipartDownloadTests ModelPreferenceMemoryTests
```

Result: `Executed 186 tests, with 1 test skipped and 5 failures (0 unexpected)`.
The console capture truncates most per-case lines (xcodebuild parallel-output
capture), so the authoritative enumeration is the run's xcresult at
`ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.17_00-33-54-+1100.xcresult`
(`xcrun xcresulttool get test-results summary|tests`): **182 passed, 3 failed,
1 skipped** — the "5 failures" are 5 ASSERTION failures inside 3 test cases:

| suite | tests | failed |
|---|---|---|
| ModelCatalogChatVariantTests (new) | 20 | 0 |
| BrainModelSelectionTests | 13 | 0 |
| LanguageModelResolverTests | 50 | 0 |
| ModelBudgetPolicyTests | 38 | 0 |
| ModelCatalogLanguageTests | 19 | 0 |
| ModelPreferenceMemoryTests | 13 | 0 |
| InterpreterAvailabilityTests | 12 | 2 (pre-existing) |
| MultipartDownloadTests | 21 | 1 (pre-existing, the baseline red) |

The 3 failed cases are ALL the same pre-existing stale pin — the shipped default
moved to `intentQwenS43` on 2026-10-12 ([ON-DEVICE-LATENCY]) while these tests
still assert `intentQwen4BSlotCanon`:

* `InterpreterAvailabilityTests.testAutomaticBrainStepsOffTheFourBDefaultOnASixGBPhone`
  — 1 assertion, `:255` (the `defaultBrainModelID` constant pin; its `:243`
  automatic-pick expectation `qwen3_1_7BInstruct` PASSED with this change, i.e.
  the eligibility filter did not disturb the ladder).
* `InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact`
  — 3 assertions, `:173` (same constant) and `:191`/`:197` (its multipart-parts
  pins, downstream: the current default is the 1.1 GB single-asset S43, not the
  >2 GiB multipart 4B).
* `MultipartDownloadTests.testSlotCanonBrainDeclaresItsTwoOrderedParts` — 1
  assertion, `:232` — the measured baseline red, unchanged.

Base-identity proof these are not caused by T-184 (no runtime re-run needed,
they are deterministic):

```
git diff HEAD --name-only           # InterpreterAvailabilityTests.swift and
                                    # MultipartDownloadTests.swift are NOT among
                                    # the modified files — byte-identical to base
git show HEAD:ios/ElderlyAssistant/App/AppCoordinator.swift | grep defaultBrainModelID
                                    # line 2202: static let defaultBrainModelID =
                                    # ModelCatalog.intentQwenS43 — the asserted
                                    # equality with intentQwen4BSlotCanon was
                                    # already FALSE at 9cafa3cc
git diff HEAD -- .../AppCoordinator.swift | grep defaultBrainModelID
                                    # the T-184 diff never touches the constant
                                    # (only context near its fallback use)
```

The skipped test in both runs is the pre-existing
`MultipartDownloadTests.testLiveCatalogAssetURLsResolveAgainstTheRealRelease`
(live-URL check; exempts the `.invalid` placeholder by design).

Also checked: the log-safety gate runs in `build.sh` and passes with the new
emission (`chat_variant_promotion` carries only `slot`/`reason`, both allowed
keys); `AppCoordinator.swift` is not in the gate's `FEATURE_ROOTS`, and the
framing-row addition in `LlamaCommandInterpreter.swift` is inert under the
per-statement rules (no console writes, no content-bearing fields).

## Files changed

| file | +/- | note |
|---|---|---|
| `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` | +318/-7 | entry, promotion record, gating seams |
| `ios/ElderlyAssistant/Services/ModelStore/LanguageModelResolver.swift` | +45/-13 | record threading, eligibility filter, `deviceClass` |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | +70/-2 | rule-2 wiring, tier metadata, promotion event |
| `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift` | +11/-0 | inherited framing row (declared-list deviation, above) |
| `ios/ElderlyAssistantTests/Services/ModelStore/ModelCatalogChatVariantTests.swift` | new, 535 lines | the unit's test suite (20 tests) |
| `ios/ElderlyAssistantTests/Services/Voice/BrainModelSelectionTests.swift` | +38/-5 | revived pins (curated list, rollback target, framing table) |
| `ios/seniOS.xcodeproj/project.pbxproj` | +4/-0 | xcodegen registration of the new test file (generated by `build.sh test:unit`; committed so the file stays registered) |

Excluded from the commit: `.ai-sdd/**` (workflow state) and the pre-existing
untracked `specs/CNR-*` run artifacts.

## Decisions and deviations

1. **Promotion is reference data.** `chatVariantPromotionRecord` is a static
   data value; `promotionVerdict`/`promotedChatVariantEntry`/`isAutomaticPickEligible`
   read it. Promotion = editing the record (gate report path/sha + verdicts
   filled in from a green run); rollback = reverting it. Resolution CODE is
   identical either way, and the rollback target's green evidence is already
   carried by the previous entry — no gate re-run, no migration.
2. **Rule 1 not gated** — explicit selection is the household's choice; the entry
   name quotes the gate state ("gates pending"), which is the honest posture the
   spec's failure path asks for ("may stay selectable where its evidence posture
   is stated"). Rule 2 (automatic) is gated at all three points above.
3. **`LlamaCommandInterpreter.swift` (+11) is a documented necessity deviation**
   from the unit's declared file list: the offered-brain test requires every
   offered id to carry a measured framing, and omitting the row would send v17
   through the LLaMA 3.2 fallback. The row is inherited (same lineage/pipeline),
   explicitly marked for replacement by its own measurement at publication.
4. **`BrainModelSelectionTests` rebase** — same class of necessity: its pins
   enumerate the picker and the framing determination, both of which this unit
   deliberately moves. No assertion was weakened; one new rollback-target test
   was added.
5. **Placeholder URL** — `.invalid` RFC 2606 host, following the
   `intentEncoderSpike` precedent; the MultipartDownloadTests live-URL check
   exempts `.invalid` by design. Replacing it is the only publication-time edit.
6. **`deviceClass` in `AutomaticPick`'s `==`** — a 6 GB-tier pick never compares
   equal to the "same" pick on the 8 GB tier; the equality is a record of the
   decision, and the tier is part of the decision.

## Open items

* **Publication** (outside this unit): upload the artifact, then replace the
  entry's `downloadURL` — nothing else.
* **Promotion** (a later run, gated): once the full-gate report exists (funded
  chat-judge key; latency measured in an Anzaan DV session), fill
  `gateReportPath`/`gateReportSHA256`/`gates` in `chatVariantPromotionRecord`;
  identity and manifest fields stay binding. The verdict then resolves
  `.promoted` and step −1 serves v17 on `ne`.
* **Framing check** on the published v17 artifact (`framing_check.py`) to
  replace the inherited row.
* **Pre-existing reds recorded, not fixed** (out of scope, files not declared):
  the three stale `intentQwen4BSlotCanon` default pins listed under Evidence —
  same root cause as the measured baseline red, zero overlap with T-184.
* **Anzaan DV session** — the latency gate's measurement and the on-device
  serve/rollback smoke (tap the v17 row ⇒ download honesty: placeholder URL ⇒
  failed download, no wrong file).
