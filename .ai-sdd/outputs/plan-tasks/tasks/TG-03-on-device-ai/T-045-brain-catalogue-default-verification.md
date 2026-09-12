# T-045: Brain catalogue and default-brain contract verification

## Metadata
- **Group:** [TG-03 — On-Device AI](../index.md)
- **Component:** ModelCatalog (brain catalogue) + AppCoordinator default-brain wiring
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** —
- **Requirements:** FR-007, FR-008, NFR-001, NFR-002

## Description

Two iOS unit tests fail on master (reported at `6e3eb93` via `ios/build.sh test:unit`, independently reproduced by a reviewer from the `.xcresult`, still red at `2061566`), keeping the aggregate unit gate red:

- `BrainModelSelectionTests.testAvailableBrainEntriesIsTheCuratedList` — ios/ElderlyAssistantTests/Services/Voice/BrainModelSelectionTests.swift:14-19 — expects `ModelCatalog.availableBrainEntries` to be exactly `[intentNepali1B, qwen3_4BInstruct, qwen3_1_7BInstruct]`. The catalogue (ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift:793-798) now offers `[intentQwenS43, qwen4BNepali, qwen3_4BInstruct, qwen3_1_7BInstruct]`: `intentQwenS43` is the v14 slim-template entry added by `af7e981` (ModelCatalog.swift:175, entry at 533-548), `intentNepali1B` is now the superseded v12 seed-42 entry (ModelCatalog.swift:516-532), and `qwen4BNepali` (`intent-ne-qwen3-4b-nepali-q4km`, entry at ModelCatalog.swift:622-641) was added by master commit `7d42852`.
- `InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact` — ios/ElderlyAssistantTests/Services/Intents/InterpreterAvailabilityTests.swift:165-178 — expects `AppCoordinator.defaultBrainModelID == ModelCatalog.llama3_2_1B` (line 170) and that the default is a real hosted `.llamaBase` artifact. The default is `ModelCatalog.intentQwenS43` (ios/ElderlyAssistant/App/AppCoordinator.swift:1170; `af7e981` moved it to the new v14 id after `7d42852` had switched it from `llama3_2_1B` to `intentNepali1B`; the v14 artifact originally landed on the old id via `d19a8de` and now sits in the `intentQwenS43` entry, ModelCatalog.swift:533-548).

This task is not "make the tests green". For each failing test it must prove, with evidence, one of two outcomes:

(a) **Stale expectation** — the test pins pre-`7d42852` state; update the expectation to the current source of truth, preserving the assertion's original intent; or
(b) **Real defect caught** — the assertion describes required behaviour and the catalogue/default violates it; record a production-fix finding with file:line evidence and route it as its own task. The failing assertion stays red until that fix lands.

Weakening, skipping (`XCTSkip` / `XCTExpectFailure`), commenting out, renaming away or deleting an assertion is forbidden in either case.

## Acceptance criteria

```gherkin
Feature: Brain catalogue and default-brain contract

  Scenario: Curated-list determination is evidenced per brain id
    Given commit 7d42852 added qwen4BNepali to ModelCatalog.availableBrainEntries
    And af7e981 added the v14 id intentQwenS43 (ModelCatalog.swift:175, 533-548) as the first curated entry (ModelCatalog.swift:794), superseding intentNepali1B (ModelCatalog.swift:516-532)
    And the qwen4BNepali entry is a LAN-only URL (http://192.168.1.117:8765/..., ModelCatalog.swift:632) with a 4 GB RAM floor (ModelCatalog.swift:639)
    When the finding for testAvailableBrainEntriesIsTheCuratedList is recorded
    Then it states (a) stale expectation or (b) production defect with file:line evidence for every offered and every hidden id
    And it accounts for the hidden-model convention (ModelCatalog.swift:784-792), the picker consumers (SettingsView.swift:3216, 3225) and the "anything offered must be fetchable" rule (AppCoordinator.swift:1258-1263)

  Scenario: Default-brain determination verifies the hosted artifact
    Given AppCoordinator.defaultBrainModelID resolves to ModelCatalog.intentQwenS43 (AppCoordinator.swift:1170, 1176-1179)
    And the intentQwenS43 entry claims GitHub release v14 with size 1_107_408_576 and sha256 c2135f... (ModelCatalog.swift:533-548)
    When the finding for testDefaultBrainModelIsTheRealHostedLlamaArtifact is recorded
    Then the v14 artifact's availability and its size/sha256 are verified or refuted against the release metadata, with the method and result recorded
    And the stale doc comments (AppCoordinator.swift:1158-1167, 1168-1169; ModelCatalog.swift:501-507) and the seed-43 comment carried by the superseded v12 entry (ModelCatalog.swift:520-525) are reconciled in code or recorded as defect findings

  Scenario: RAM floor is measured against a device that can actually run the model
    Given qwen4BNepali declares minDeviceRAMBytes 4_000_000_000 (lowered from 6 GB by 09b037e)
    And the download gate compares physical device RAM (MemoryProbe.swift:35-37) at ModelDownloadService.swift:81
    And NFR-001 names the iPhone 12 (4 GB) as the reference device
    When the brain-catalogue determination is recorded
    Then it states whether a device admitted by the 4 GB floor can hold the model's ~3.5–4 GB live footprint, with evidence
    And an admitted-but-unrunnable case is recorded as a production defect, not encoded as a test expectation

  Scenario: A caught production defect routes to a fix, not a test edit
    Given an assertion is found to describe required behaviour
    When the catalogue or the default wiring violates it
    Then a separate production-fix finding with file:line evidence is recorded and routed as its own task
    And the affected test stays red until that fix lands
    And no assertion is weakened, skipped, commented out or deleted

  Scenario: A stale expectation is updated without losing its intent
    Given an assertion is found to pin pre-7d42852 state
    When the expectation is updated to the current source of truth
    Then every original assertion intent survives (real hosted, non-placeholder URL; correct kind; curated set vs hidden set)
    And the diff changes only expectation values and their explanatory comments

  Scenario: The aggregate unit gate reflects the determination honestly
    Given both tests fail on master at 6e3eb93 and remain red at 2061566
    When ios/build.sh test:unit (build.sh:407-408, 488-493) is run on the completed branch
    Then the gate is green if and only if every determination was (a) or the routed (b) production fix has landed
    And both test functions still exist and execute, with no assertion removed and no skip scope added
```

## Implementation notes

- Requirements trace: FR-007 / FR-008 at requirements.md:40-44; NFR-001 / NFR-002 at requirements.md:208-212 (mirrored in .ai-sdd/outputs/define-requirements.md:36-40, 375-379). The catalogue/default contract serves FR-007 (on-device model, no cloud LLM) and FR-008 (intent classification/response generation), and the RAM floor is measured against the NFR-001/NFR-002 reference device.
- Reproduce: `ios/build.sh test:unit` runs the whole `ElderlyAssistantTests` target (ios/build.sh:407-408); the `test:unit` case is build.sh:488-493. The two failing functions live in `BrainModelSelectionTests.swift` and `InterpreterAvailabilityTests.swift` under ios/ElderlyAssistantTests/Services/.
- Source-of-truth map (master `2061566`):
  - Curated/offered brains: `ModelCatalog.availableBrainEntries` (ModelCatalog.swift:793-798); full catalogue `ModelCatalog.all` (ModelCatalog.swift:208 onward); consumers SettingsView.swift:3216, 3225 and AppCoordinator.swift:1261-1264.
  - Model ids: `intentQwenS43` (ModelCatalog.swift:175; entry 533-548 — v14 slim-template seed-43, default and first curated entry); `intentNepali1B` (ModelCatalog.swift:172; entry 516-532 — superseded v12 seed-42, kept in `all`, no longer offered); `qwen4BNepali` (entry 622-641).
  - Default brain: `AppCoordinator.defaultBrainModelID` (AppCoordinator.swift:1170) and `resolvedBrainModelID` (1176-1179); download wiring `applyBrainModel` (1188-1194) and `shouldAutoDownloadAssistantBrain` (1209-1214).
  - RAM gate: `MemoryProbe.canFit` (MemoryProbe.swift:35-37) called from ModelDownloadService.swift:81-85.
- Change history (read-only evidence: `git show 7d42852`, `git show 09b037e`, `git show d19a8de`, `git show af7e981`):
  - `7d42852` added the `qwen4BNepali` entry + `availableBrainEntries` membership and switched `defaultBrainModelID` from `llama3_2_1B` to `intentNepali1B`.
  - `09b037e` lowered `qwen4BNepali.minDeviceRAMBytes` from 6 GB to 4 GB.
  - `d19a8de` replaced the `intentNepali1B` artifact (filename, URL, sha256) with the v14 slim-template seed-43 GGUF — leaving the v14 file behind an id devices may already have cached.
  - `af7e981` gave the v14 artifact its own `ModelID` (`intentQwenS43`, ModelCatalog.swift:175) so cached v12 devices download fresh, added its entry (533-548), made it the first `availableBrainEntries` element (794) and the default (AppCoordinator.swift:1170); `intentNepali1B` remains as the superseded v12 entry (516-532).
- `qwen4BNepali` facts: `kind: .llamaBase`, filename `intent-ne-qwen3-4b-nepali-q4_k_m.gguf`, size 2_529_263_424, sha256 `eb5ce805…`, LAN-only `http://192.168.1.117:8765/...` URL. Its own comment says "Served from the home server for TESTING (LAN-only URL); public hosting needs a >2GiB route — parts sit on release v13" (ModelCatalog.swift:626-630). Info.plist:105-108 (`NSAllowsLocalNetworking`) and Info.plist:110-111 (`NSLocalNetworkUsageDescription`, "Download on-device voice models from your home server") show the LAN fetch is deliberately supported in dev/LAN builds — weigh that against the shipped-picker question; `availableBrainEntries` is shipped product surface, not a test-only seam.
- Hidden-model convention: models kept in `ModelCatalog.all` but not offered (so a device that cached one can still delete it) are documented at ModelCatalog.swift:784-792 and pinned by `testHiddenBrainsStayInTheCatalogButAreNotOffered` (BrainModelSelectionTests.swift:23-35); `intentGemma1B` is hidden by the emergency hard-gate rule (ModelCatalog.swift:549-556, test at BrainModelSelectionTests.swift:37-57); the superseded `intentNepali1B` is likewise kept in `all` (516-532) but not offered.
- Default-brain artifact: the original test intent (InterpreterAvailabilityTests.swift:166-169) is "the auto-download target must be a real hosted artifact, not the `.invalid` placeholder convention". Verify the `intentQwenS43` v14 URL (ModelCatalog.swift:543) resolves and its size/sha256 match the release metadata (HTTP metadata / release tag check); if they do not, that is outcome (b) — a real wiring defect.
- Doc drift to reconcile or record as findings: AppCoordinator.swift:1158-1167 (doc comment) and 1168-1169 (inline "v12, seed 42") against the default at 1170; ModelCatalog.swift:501-507 (the hidden LLaMA entry still claims to be the auto-download default); ModelCatalog.swift:520-525 (the superseded v12 entry's comment claims to be "seed 43 … supersedes v12 seed-42" while being the v12 seed-42 entry itself); ModelCatalog.swift:784-785 (the picker header calls the first entry "the v12 bake-off winner" while the list now leads with the v14 `intentQwenS43`).
- iOS-only: the Android tree contains no brain catalogue (`ModelCatalog` / `availableBrainEntries` / `defaultBrainModelID` have no matches under `android/`), so no platform split is needed — this is a single iOS task in TG-03.
- Scope: test edits only in outcome (a); production fixes are routed as their own task in outcome (b).

## Definition of done
- [ ] Per-test determination recorded as (a) or (b), each backed by file:line evidence from the current source of truth
- [ ] Hosted-artifact verification for the default brain (v14 URL, size, sha256) recorded with method and result
- [ ] RAM-floor check for `qwen4BNepali` against the NFR-001 reference device recorded with evidence
- [ ] Outcome (a): expectations updated to the current catalogue/default; original assertion intent preserved; no unrelated assertion touched
- [ ] Outcome (b): production-defect finding (file:line + evidence) recorded and routed as its own task; affected assertion left failing until that fix lands
- [ ] No assertion weakened, skipped (`XCTSkip` / `XCTExpectFailure`), commented out, renamed away or deleted
- [ ] No test-target, scheme or skip-list change takes either test out of the unit gate
- [ ] `ios/build.sh test:unit` outcome consistent with the determinations (green, or red only where a routed production fix is open)
- [ ] The rework run's `.xcresult` and untruncated `xcodebuild` output are preserved (ios/build.sh pipes through `tail -40`; the previous run's skip identities were unverifiable after its DerivedData was deleted)
- [ ] Code reviewed and merged
