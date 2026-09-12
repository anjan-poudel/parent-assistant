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

Two iOS unit tests fail on master (reported at `6e3eb93` via `ios/build.sh test:unit` and independently reproduced by a reviewer from the `.xcresult`), keeping the aggregate unit gate red:

- `BrainModelSelectionTests.testAvailableBrainEntriesIsTheCuratedList` — ios/ElderlyAssistantTests/Services/Voice/BrainModelSelectionTests.swift:14-19 — expects `ModelCatalog.availableBrainEntries` to be exactly `[intentNepali1B, qwen3_4BInstruct, qwen3_1_7BInstruct]`. The catalogue (ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift:774-779) now also offers `qwen4BNepali` (`intent-ne-qwen3-4b-nepali-q4km`, entry at ModelCatalog.swift:603-622), added by master commit `7d42852`.
- `InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact` — ios/ElderlyAssistantTests/Services/Intents/InterpreterAvailabilityTests.swift:165-178 — expects `AppCoordinator.defaultBrainModelID == ModelCatalog.llama3_2_1B` (line 170) and that the default is a real hosted `.llamaBase` artifact. The default is `ModelCatalog.intentNepali1B` (ios/ElderlyAssistant/App/AppCoordinator.swift:1170, switched by `7d42852`; its artifact was replaced with the v14 slim-template seed-43 GGUF by `d19a8de`, see ModelCatalog.swift:513-529).

This task is not "make the tests green". For each failing test it must prove, with evidence, one of two outcomes:

(a) **Stale expectation** — the test pins pre-`7d42852` state; update the expectation to the current source of truth, preserving the assertion's original intent; or
(b) **Real defect caught** — the assertion describes required behaviour and the catalogue/default violates it; record a production-fix finding with file:line evidence and route it as its own task. The failing assertion stays red until that fix lands.

Weakening, skipping (`XCTSkip` / `XCTExpectFailure`), commenting out, renaming away or deleting an assertion is forbidden in either case.

## Acceptance criteria

```gherkin
Feature: Brain catalogue and default-brain contract

  Scenario: Curated-list determination is evidenced per brain id
    Given commit 7d42852 added qwen4BNepali to ModelCatalog.availableBrainEntries
    And its entry is a LAN-only URL (http://192.168.1.117:8765/..., ModelCatalog.swift:613) with a 4 GB RAM floor (ModelCatalog.swift:620)
    When the finding for testAvailableBrainEntriesIsTheCuratedList is recorded
    Then it states (a) stale expectation or (b) production defect with file:line evidence for every offered and every hidden id
    And it accounts for the hidden-model convention (ModelCatalog.swift:765-773), the picker consumers (SettingsView.swift:3216, 3225) and the "anything offered must be fetchable" rule (AppCoordinator.swift:1258-1263)

  Scenario: Default-brain determination verifies the hosted artifact
    Given AppCoordinator.defaultBrainModelID resolves to ModelCatalog.intentNepali1B (AppCoordinator.swift:1170, 1176-1179)
    And the intentNepali1B entry claims GitHub release v14 with size 1_107_408_576 and sha256 c2135f... (ModelCatalog.swift:513-529)
    When the finding for testDefaultBrainModelIsTheRealHostedLlamaArtifact is recorded
    Then the v14 artifact's availability and its size/sha256 are verified or refuted against the release metadata, with the method and result recorded
    And the stale doc comments still describing LLaMA 3.2 1B (AppCoordinator.swift:1158-1167, ModelCatalog.swift:498-504) are reconciled in code or recorded as defect findings

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
    Given both tests fail on master at 6e3eb93
    When ios/build.sh test:unit (build.sh:407-408, 488-493) is run on the completed branch
    Then the gate is green if and only if every determination was (a) or the routed (b) production fix has landed
    And both test functions still exist and execute, with no assertion removed and no skip scope added
```

## Implementation notes

- Requirements trace: FR-007 / FR-008 at requirements.md:40-44; NFR-001 / NFR-002 at requirements.md:208-212 (mirrored in .ai-sdd/outputs/define-requirements.md:36-40, 375-379). The catalogue/default contract serves FR-007 (on-device model, no cloud LLM) and FR-008 (intent classification/response generation), and the RAM floor is measured against the NFR-001/NFR-002 reference device.
- Reproduce: `ios/build.sh test:unit` runs the whole `ElderlyAssistantTests` target (ios/build.sh:407-408); the `test:unit` case is build.sh:488-493. The two failing functions live in `BrainModelSelectionTests.swift` and `InterpreterAvailabilityTests.swift` under ios/ElderlyAssistantTests/Services/.
- Source-of-truth map:
  - Curated/offered brains: `ModelCatalog.availableBrainEntries` (ModelCatalog.swift:774-779); full catalogue `ModelCatalog.all` (ModelCatalog.swift:205 onward); consumers SettingsView.swift:3216, 3225 and AppCoordinator.swift:1261-1264.
  - Default brain: `AppCoordinator.defaultBrainModelID` (AppCoordinator.swift:1170) and `resolvedBrainModelID` (1176-1179); download wiring `applyBrainModel` (1188-1194) and `shouldAutoDownloadAssistantBrain` (1209-1214).
  - RAM gate: `MemoryProbe.canFit` (MemoryProbe.swift:35-37) called from ModelDownloadService.swift:81-85.
- Change history (read-only evidence: `git show 7d42852`, `git show 09b037e`, `git show d19a8de`):
  - `7d42852` added the `qwen4BNepali` entry + `availableBrainEntries` membership and switched `defaultBrainModelID` from `llama3_2_1B` to `intentNepali1B`.
  - `09b037e` lowered `qwen4BNepali.minDeviceRAMBytes` from 6 GB to 4 GB.
  - `d19a8de` replaced the `intentNepali1B` artifact (filename, URL, sha256) with the v14 slim-template seed-43 GGUF.
- `qwen4BNepali` facts: `kind: .llamaBase`, filename `intent-ne-qwen3-4b-nepali-q4_k_m.gguf`, size 2_529_263_424, sha256 `eb5ce805…`, LAN-only `http://192.168.1.117:8765/...` URL. Its own comment says "Served from the home server for TESTING (LAN-only URL); public hosting needs a >2GiB route — parts sit on release v13" (ModelCatalog.swift:607-611). Info.plist:105-108 (`NSAllowsLocalNetworking`) and Info.plist:110-111 (`NSLocalNetworkUsageDescription`, "Download on-device voice models from your home server") show the LAN fetch is deliberately supported in dev/LAN builds — weigh that against the shipped-picker question; `availableBrainEntries` is shipped product surface, not a test-only seam.
- Hidden-model convention: models kept in `ModelCatalog.all` but not offered (so a device that cached one can still delete it) are documented at ModelCatalog.swift:765-773 and pinned by `testHiddenBrainsStayInTheCatalogButAreNotOffered` (BrainModelSelectionTests.swift:23-35); `intentGemma1B` is hidden by the emergency hard-gate rule (ModelCatalog.swift:530-537, test at BrainModelSelectionTests.swift:37-57).
- Default-brain artifact: the original test intent (InterpreterAvailabilityTests.swift:166-169) is "the auto-download target must be a real hosted artifact, not the `.invalid` placeholder convention". Verify the v14 URL resolves and its size/sha256 match the release metadata (HTTP metadata / release tag check); if they do not, that is outcome (b) — a real wiring defect.
- Doc drift: AppCoordinator.swift:1158-1167 and ModelCatalog.swift:498-504 still describe LLaMA 3.2 1B as the auto-download default, contradicting AppCoordinator.swift:1170. Reconcile in code (if (a), or as part of the routed fix) or record as a finding.
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
- [ ] Code reviewed and merged
