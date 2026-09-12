# T-048: Deferred brain decisions (LAN picker entry + interpreter default)

## Metadata
- **Group:** [TG-03 — On-Device AI](../index.md)
- **Component:** ModelCatalog (curated picker surface), LlamaCommandInterpreter construction default, AppCoordinator default-brain wiring
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-045](T-045-brain-catalogue-default-verification.md)
- **Blocks:** —
- **Requirements:** FR-007, FR-008

## Description

Two decisions were deliberately deferred and currently exist nowhere as decisions. This task closes both with a written, owned outcome: either implemented under its own follow-up task or recorded as an explicit Open Decision — an undocumented divergence is not an acceptable outcome.

**Placement rationale.** Both decisions are about the brain catalogue and the default-brain contract, which TG-03's charter owns (`availableBrainEntries`, `AppCoordinator.defaultBrainModelID`). The plan keeps decision-style tasks in the group that owns their subject — T-033/T-034/T-035 in TG-08 (encoder), T-039/T-040 in TG-09 (plugin contract) — so these decisions sit here, not in an unrelated group. T-045 (contract verification) is the dependency; T-046 (framing) is cross-referenced where relevant. Neither is re-derived here.

**(i) May the LAN-only entry `qwen4BNepali` be offered in the shipped picker at all?** It is a member of `availableBrainEntries` (ModelCatalog.swift:795), which the Settings picker renders (SettingsView.swift:3216, 3225) and which the downloads-management rows mirror under the rule "anything the picker offers must be fetchable" (AppCoordinator.swift:1255-1263). Its `downloadURL` is LAN-only `http://192.168.1.117:8765/...` (ModelCatalog.swift:632), and its own comment records that public hosting needs a ">2GiB route" and that parts sit on release v13 (ModelCatalog.swift:626-630). Inputs that must be stated in the decision record: the App Store / Play compliance constraints (constitution.md:61-64) and the review risk of a shipped picker row that cannot fetch on a normal household network (including the local-network permission prompt it triggers, Info.plist:110-111); the on-device-only constraint FR-007 (requirements.md:40-42) — inference stays on-device regardless of how the artifact is delivered; the hidden-model convention (ModelCatalog.swift:784-792: a model kept in `all` but not offered stays manageable and deletable); and the Nepal-first user impact (a LAN-only row is a dead control for every user except the developer). Options to weigh: host it properly behind a real hosted (>2GiB-capable) https route with size/sha256 re-pinned (entry facts at ModelCatalog.swift:633-634) and the curated-list test updated; or keep it out of the shipped picker behind a debug/internal affordance, with the affordance, the exclusion test and the deletability path specified. Android has no counterpart today — no `ModelCatalog` / `availableBrainEntries` / `defaultBrainModelID` / chat-format code exists under `android/` — so Play policy is recorded as a not-yet-applicable input with the trigger that would make it apply.

**(ii) Should `LlamaCommandInterpreter`'s construction default follow `AppCoordinator.defaultBrainModelID`?** The initializer default is `ModelCatalog.llama3_2_1B` (LlamaCommandInterpreter.swift:386); the app's default brain is `ModelCatalog.intentQwenS43` (AppCoordinator.swift:1170). Production never uses the initializer default — `AppCoordinator` constructs the interpreter with `preferredBaseId: resolvedBrainModelID` (AppCoordinator.swift:1062-1070) — so the blast radius is: every caller that omits the argument, today only tests (LlamaCommandInterpreterTests.swift:26, 31, 45, 272, 292, 301, 370, 382, 404; QueryEndToEndRegressionTests.swift:86-87), plus `isAvailable` derived from the cached state of that id (LlamaCommandInterpreter.swift:374-382) and the load path (601, 620, 690). The divergence is pinned by `testSwitchBaseModelRepointsInferenceAndDropsLoadedHandle` (BrainModelSelectionTests.swift:145-161 at `2061566`; the `baseModelID == llama3_2_1B` assertion at 153 at `2061566` / 157 at `d31c4be`). Options to weigh with trade-offs: (a) one canonical constant owned by the model layer (e.g. a `ModelCatalog` default id) referenced by both the interpreter default and `AppCoordinator.defaultBrainModelID`, so no Services→App dependency is introduced — moves product policy into the catalogue and touches the pinning assertion; (b) make `preferredBaseId` required, deleting the default so every caller states its brain — larger test diff, removes the divergence class; (c) keep the divergence and record it as an explicit Open Decision in `constitution.md` §Open Decisions (constitution.md:93), stating that the interpreter default is a test/legacy default that production overrides. The later paired-review repair (`a952a1b`) already added an https assertion on the default-brain URL precisely because a LAN entry could otherwise become the auto-download default unnoticeably (InterpreterAvailabilityTests.swift:182 at `d31c4be`) — that hazard is closed, but the interpreter-default divergence this task decides is not.

## Acceptance criteria

```gherkin
Feature: Deferred brain decisions are made and recorded

  Scenario: The LAN-entry decision is recorded with its policy and safety inputs stated
    Given qwen4BNepali is offered in the shipped picker (ModelCatalog.swift:795) with a LAN-only URL (632) and a public-hosting note (626-630)
    And the picker renders availableBrainEntries (SettingsView.swift:3216, 3225) under the rule that everything offered must be fetchable (AppCoordinator.swift:1255-1263)
    When decision (i) is recorded
    Then it states the App Store / Play compliance input (constitution.md:61-64), the on-device-only constraint FR-007 (requirements.md:40-42), and the Nepal-first user-facing impact of a row that cannot fetch outside the developer's LAN
    And it states that Android has no catalogue today (no ModelCatalog/availableBrainEntries/defaultBrainModelID match under android/) and what would make Play policy an input
    And it names exactly one outcome: host it properly, or keep it out of the shipped picker behind a debug/internal affordance

  Scenario: The chosen LAN-entry outcome is concretely specified and pinned
    Given the decision names host-it-properly
    When the follow-up implementation task is written
    Then it specifies the hosted (>2GiB-capable) https URL, the re-pinned size/sha256 (ModelCatalog.swift:633-634), and the curated-list test update (BrainModelSelectionTests.swift:14-21 at 2061566)
    Given the decision names keep-it-out
    When the follow-up implementation task is written
    Then it specifies the debug/internal affordance and who can reach it, keeps the entry in all under the hidden-model convention (ModelCatalog.swift:784-792) so a cached copy stays deletable, and adds a test that the shipped picker excludes it
    And in both cases no route may make qwen4BNepali the auto-download default

  Scenario: The interpreter-default blast radius is recorded, not assumed
    Given the construction default ModelCatalog.llama3_2_1B (LlamaCommandInterpreter.swift:386) and the app default ModelCatalog.intentQwenS43 (AppCoordinator.swift:1170)
    And production always passes preferredBaseId explicitly (AppCoordinator.swift:1062-1070)
    When decision (ii)'s blast radius is recorded
    Then it lists every reader of the default: the test call sites that omit the argument (LlamaCommandInterpreterTests.swift:26, 31, 45, 272, 292, 301, 370, 382, 404; QueryEndToEndRegressionTests.swift:86-87), the cache-gated isAvailable (374-382) and the load/framing call sites (601, 620, 690)
    And it states what the pinning test asserts (BrainModelSelectionTests.swift:145-161 at 2061566; assertion at 153 at 2061566 / 157 at d31c4be) and exactly how that assertion changes under each option

  Scenario: The interpreter-default options are recorded with trade-offs
    Given options (a) one canonical default constant in the model layer, (b) make preferredBaseId required, (c) keep the divergence and record it
    When decision (ii) is recorded
    Then each option states its diff scope, its effect on the pinning test, and whether it removes or preserves the divergence class
    And option (c) is only acceptable as an explicit Open Decision, never as silence

  Scenario: The resolution is landed or recorded — never left undocumented
    Given a decision outcome
    When the task completes
    Then the outcome is either implemented under its own named follow-up task with file:line scope, or recorded as an explicit Open Decision in constitution.md §Open Decisions (constitution.md:93) with an owner and a trigger for resolution
    And no undocumented divergence or unrecorded picker-surface decision remains at completion

  Scenario: Neighbours' determinations are consumed, not duplicated
    Given T-045 verified the catalogue/default contract (which tests pin what, and which ids exist)
    And T-046 determines the chat framing per offered id
    When this task's decision records are written
    Then they cite T-045's determinations and T-046's framing outcome as inputs
    And they do not re-run T-045's verifications or T-046's framing checks, and do not edit either task's record

  Scenario: No decision may weaken the on-device or safety posture
    Given FR-007 requires on-device inference and FR-009 keeps safety paths independent of the LLM
    When any option or outcome is chosen
    Then the decision record states that inference remains on-device, that no LAN/cloud dependency is added to the emergency or medication paths, and that the auto-download default remains a real hosted artifact (ModelCatalog.swift:543)
```

## Implementation notes

- This task produces decision records and routed follow-ups only; it ships no production code change. Where the chosen outcome needs code, the follow-up task carries it.
- Current facts to cite when writing the record (master `2061566`): curated list ModelCatalog.swift:793-798; LAN entry id 168, entry 622-641, URL 632, size/sha256 633-634, hosting comment 626-630; hidden-model convention 784-792 and its comment on management rows (750-754); fetchability rule AppCoordinator.swift:1255-1263 (code at 1261-1263); picker consumers SettingsView.swift:3216, 3225; default brain AppCoordinator.swift:1170 with resolution 1176-1179; interpreter default LlamaCommandInterpreter.swift:386.
- The record's landing zone: append to the decision notes for this workstream (a committed decision note alongside the T-045/T-046 records is acceptable) plus, for option (c) of (ii) or an unresolved (i), an entry in `constitution.md` §Open Decisions. Paths are the task's choice but must be committed; both mirrored plan trees must receive the same text.
- If T-045 recorded a production defect about the LAN entry or the default wiring, its finding is the primary input to (i)/(ii); do not re-litigate it. If T-046 changes framing for `qwen4BNepali`, that does not change this decision and must not be used to justify keeping it offered.
- Android: verified absent for these components — `grep` for `ModelCatalog`, `availableBrainEntries`, `defaultBrainModelID` under `android/` matches nothing; a broader model-name search matches only Gradle `org.jetbrains` strings. Record the trigger (a catalogue landing on Android) rather than a Play analysis now.
- No PII in decision records (NFR-016); the LAN host name is development infrastructure, keep it out of user-facing text.

## Definition of done
- [ ] Decision (i) recorded and resolved: host-it-properly with hosted URL + re-pinned facts, or keep-it-out with a specified debug affordance, exclusion test and deletability path
- [ ] Decision (ii) recorded and resolved: align the default, make it required, or an explicit Open Decision in constitution.md §Open Decisions — no undocumented divergence
- [ ] Blast radius + pinning-test effect recorded for (ii), including every test call site that omits `preferredBaseId`
- [ ] App Store / Play policy input, FR-007 and the Nepal-first user impact stated in (i); Android-absence and its trigger recorded
- [ ] T-045 and T-046 determinations cited as inputs; neither record edited and neither scope duplicated
- [ ] Any follow-up implementation task named with file:line scope; no production code changed by this task
