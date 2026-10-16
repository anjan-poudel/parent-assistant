# T-184 — v17 catalog entry and the gated, reversible swap

## Metadata
- **Group:** [TG-37 — v17 Chat-Aware Training Suite](index.md)
- **Component:** Model catalog and default resolution (design-l1 section 11.6)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** HIGH
- **Depends on**: T-177 ([T-177](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-177-indicator-revocation-and-coordinator-wiring.md)), T-183 ([T-183](T-183-v17-chat-aware-qlora-run.md))
- **Blocks:** T-186 ([T-186](../TG-38-release-gate-acceptance-and-device-validation/T-186-end-to-end-acceptance-and-scoped-sweep.md)), T-189 ([T-189](../TG-39-p2-polish-and-feasibility-honesty/T-189-p2-romanized-nepali-chat.md)), T-190 ([T-190](../TG-39-p2-polish-and-feasibility-honesty/T-190-p2-4b-tier-candidate-and-admission.md)), T-191 ([T-191](../TG-39-p2-polish-and-feasibility-honesty/T-191-p2-consent-based-real-transcripts.md))
- **Requirements:** [FR-CNR-022](../../../define-requirements/FR/FR-CNR-022-v17-catalog-entry-versioned-reversible.md), [NFR-CNR-003](../../../define-requirements/NFR/NFR-CNR-003-memory-and-jetsam-device-tiers.md)

## Description
Ship the v17 chat variant as a new versioned catalog entry beside the current on-device model, with its real hash and tier fields, and express the default promotion through the catalog's default-resolution seam — so a rollback to the previous entry is a catalog-level operation with no code change and no gate re-run. The entry is the only way the new model reaches a device; promotion happens only with every gate green and the provenance manifest attached, and exactly one model stays resident.

## Acceptance criteria

```gherkin
Feature: A versioned, reversible, gate-backed swap

  Scenario: The new entry exists beside the current one
    Given the shipped catalog
    When the available on-device model entries are listed
    Then the v17 chat variant appears with its real hash, size and tier fields
    And the previous entry remains present and selectable (the rollback target)

  Scenario: Selecting the entry serves the new model with no wiring change
    Given the v17 entry selected
    When a chat turn and a command turn are served
    Then the selected model answers both through the existing chain, router and prompt seams — no chain, router or prompt change is part of this unit

  Scenario: Promotion is gated and recorded
    Given all gates green and the provenance manifest attached in the run evidence
    When the default resolution is changed
    Then the default serves the v17 entry and the promotion is recorded with the gate evidence and the manifest hash

  Scenario: Rollback is a catalog operation
    Given a promoted v17 default
    When the default resolution is reverted to the previous entry
    Then devices serve the previous model with no code change and no gate re-run
    And chat behaviour falls back to the previous model's shape without any other change

  Scenario: Exactly one model is resident
    Given either entry selected
    When the app loads the model
    Then exactly one handle is resident on the reference tier (no second instance, no double allocation)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Swap failure behaviour

  Scenario: A red gate blocks promotion
    Given a run whose gate report has any gate below threshold, or whose manifest is missing
    When promotion is attempted
    Then the v17 entry does not become the default and the violation is reported
    And the entry may remain selectable only where the run's evidence is quoted (it is never silently promoted)

  Scenario: The artifact does not match its evidence
    Given a GGUF whose hash differs from the one the gate report and catalog entry name
    When the entry is validated
    Then the mismatch is reported and the entry is not served

  Scenario: A tier cannot hold it
    Given a device tier whose memory envelope cannot hold the v17 model beside the rest of the app
    When the entry is resolved for that tier
    Then the resolver keeps the tier's admissible model (the previous entry or a smaller candidate) rather than risking a jetsam kill
    And the decision is recorded with the tier named
```

## Inputs and expected result

**Input:** the run's evidence (T-183: candidate artifact, manifest, gate report with artifact identity); the shipped catalog and its entry structure; the default-resolution seam (the per-language remembered pick and default map); the coordinator's catalog wiring (T-177's file, extended here).

**Output:** the v17 catalog entry and the promotion/rollback expression through the default-resolution seam, with tests covering selection, promotion gating, rollback and single residency.

**Declared files:** `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift`, `ios/ElderlyAssistant/Services/ModelStore/LanguageModelResolver.swift`, `ios/ElderlyAssistant/App/AppCoordinator.swift`, `ios/ElderlyAssistantTests/Services/ModelStore/ModelCatalogChatVariantTests.swift`

## Implementation notes
- Versioned and reversible is the requirement: the previous entry stays addressable, and reverting the default must not require a code change, a rebuild or a gate re-run (the previous entry already carries its own green evidence). Model the promotion as reference data (the default map and the remembered pick), not as code.
- Promotion precondition: all gates green plus the manifest attached, with the gate evidence recorded at promotion time (the manifest hash and artifact identity are the binding pieces).
- No wiring changes: the entry is served through the existing chain, router and prompt seams; the chat behaviour comes from T-167/T-168's shape, which is model-independent. If a swap appears to require a router or prompt change, that is a defect in the entry, not a wiring task for this unit.
- Tiers: 1.7B is the default target; the 4B candidate (T-190) exists only through this resolver and only if the tier holds the latency envelope and the memory behaviour — the reference 6 GB tier's verdict is recorded in the design's section 20 and must not be silently overridden.
- Memory discipline (NFR-CNR-003): one resident handle, no double allocation during a swap; the tier test asserts single residency.
- The catalog entry is the only container change: no new device schema, no new permission, no Info.plist change.
- If T-183's run ended red, this unit still completes with the entry present but not promoted, and the run's shortfall is carried into the sign-off evidence (honest partial delivery) — promotion is the blocked action, not the unit's existence.

## Definition of done
- [ ] v17 entry present with real hash, size and tier fields; previous entry present and selectable
- [ ] Selection serves the new model through existing seams (no chain/router/prompt change)
- [ ] Promotion only with all gates green and the manifest attached; promotion recorded with evidence
- [ ] Rollback to the previous entry requires no code change and no gate re-run (tested)
- [ ] Single residency on the reference tier (tested); tier-inadmissible resolution keeps an admissible model
- [ ] Red gate or missing manifest blocks promotion and is reported
- [ ] Hash/evidence mismatch rejected at entry validation
- [ ] No new schema, permission or Info.plist change; focused suite green
