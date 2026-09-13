# T-054: Capture Schema & Egress Contract Design

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** The on-device capture record (`ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift`, `Record` at `:20-47`) and the egress payload definition; the opt-in/opt-out UX contract consumed by [T-056](T-056-capture-egress-implementation.md)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-052](T-052-continuous-learning-signal-quality-feasibility.md) (which signals are derivable from the shipped shape), [T-053](T-053-learning-loop-privacy-review.md) (what may egress, consent copy, retention)
- **Blocks:** [T-055](T-055-shadow-scoring-healing-protocol-design.md), [T-056](T-056-capture-egress-implementation.md)
- **Requirements:** NFR-011, NFR-015, NFR-016, NFR-032
- **Origin:** TG-10 recorded decisions D-1 and D-2 (`docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §2); the shipped `IntentLogStore` contract (`IntentLogStore.swift:3-17`); the T-052/T-053 determinations

## Description

Fix two contracts and hand them to the implementation:

1. **The on-device capture record.** The design extends `IntentLogStore.Record` rather than inventing a store, but the shipped `Record` is a plain `Codable` struct whose lines are decoded directly from the JSONL file (`IntentLogStore.swift:20-47`, `:131-137`) — a non-optional new field would make every existing on-disk line fail to decode. Two additional constraints come from [T-052](T-052-continuous-learning-signal-quality-feasibility.md): the confidence signal is not derivable today (no confidence field exists), and the 500-record cap with oldest-first trimming (`:17`, `:49`, `:88-92`) can roll the signal out of the window before the weekly retrain sees it. The design must therefore specify either a compact derived-signal digest that survives trimming, or state why trimming is acceptable — one of the two, explicitly.

2. **The egress payload.** Exactly what leaves: field names, types, which are mandatory, and the salt handling [T-053](T-053-learning-loop-privacy-review.md) rules on. The design's rule is "hashed-only" (`…continuous-learning-loop-design.md` §5.1): closed-vocabulary identifiers (action, outcome, correction kind), confidence and latency buckets, counters, and salted per-record hashes. Raw audio, raw transcript, slot values and health values never egress. The payload definition must be written so that a reviewer can check a serialised example field by field, and so that adding a field is a **consent-relevant change** (T-053 rules on whether that re-triggers consent).

The transport is the loop's own opt-in uploader, **not** `ObservabilityBus` — the design's §5.3 records why: the shipped bus implementation prints to the console (`AppCoordinator.swift:7260-7278`) and its contract is PII-free local diagnostics, not network egress. NFR-011 (TLS 1.2+) applies to the uploader's connection.

**The opt-in/opt-out UX contract.** What the user (or the configuring family member) sees, when the control is offered, what it says, what turning it off does immediately, and what the visible indicator is while the loop is active. The copy itself comes from [T-053](T-053-learning-loop-privacy-review.md); this task fixes the states, the transitions and the externalisation requirement (NFR-023/NFR-024). The design's D-1 fixes "opt-in, revocable, default OFF"; the no-silent-stub rule applies — an opt-out that only flips a flag while egress continues is a defect, not a simplification.

**Explicitly out of scope.** No runtime code (that is [T-056](T-056-capture-egress-implementation.md)), no shadow-scoring protocol (that is [T-055](T-055-shadow-scoring-healing-protocol-design.md)), no change to the encoder or the training pipeline. This task produces a design document plus the machine-checkable payload definition; it does not build.

## Acceptance criteria

```gherkin
Feature: Capture schema and egress contract

  Scenario: The capture record extends Record without breaking existing data
    Given IntentLogStore.Record's shipped fields (id, timestamp, path, action, slots, outcome, correctedTo, latencyMs) at Services/Intents/IntentLogStore.swift:20-47
    And records are decoded straight from the JSONL file (:131-137), so a non-optional new field would fail every existing line
    When the capture schema is designed
    Then every added field is optional or defaulted, and a design-stage test vector proves a pre-extension JSONL line still decodes
    And the design names which added fields come from T-052's derivability gaps (at minimum the confidence signal, if T-052 found it absent)

  Scenario: The 500-record cap's effect on the weekly window is resolved, not ignored
    Given maxRecords = 500 with oldest-first trimming (IntentLogStore.swift:17, :49, :88-92)
    And the recorded weekly cadence decision D-3
    When the capture schema is designed
    Then the design either specifies a compact derived-signal digest that survives trimming, or states explicitly why a trimmed window is sufficient, with T-052's roll-off measurement cited
    And the choice is recorded as a decision with its consequence for mining yield

  Scenario: The egress payload is specified field by field and is hashed-only
    Given the design's egress rule (closed-vocabulary ids, buckets, counters, salted hashes) and T-053's payload ruling
    When the payload contract is written
    Then every field has a name, a type, and a statement of what it can and cannot reveal, and no field can carry raw transcript, audio, slot values, or health values
    And a worked serialised example is included with realistic-but-synthetic values, showing the hash and its salt handling exactly as T-053 ruled
    And the design states that adding a field is a consent-relevant change and whether it re-triggers consent

  Scenario: The transport contract is explicit and the bus is not reused
    Given ConsoleObservabilityBus prints every sanitised event (AppCoordinator.swift:7260-7278)
    And NFR-011 requires TLS 1.2 or higher on all outbound connections
    When the egress transport is designed
    Then the design specifies a dedicated opt-in uploader (endpoint shape, failure behaviour, retry policy as configurable parameters) and states why the observability bus is not used for egress
    And every failure mode is enumerated with its user-visible behaviour, and no failure path silently discards captured signals without saying so

  Scenario: The opt-in and opt-out contract is honest and externalised
    Given recorded decision D-1 (default OFF, revocable) and the consent copy from T-053
    When the UX contract is designed
    Then it defines the state machine (default off -> offered -> enabled -> revoked), what each transition does to already-captured and already-egressed data, and where the control lives for the primary user and for the family
    And it fixes that every string is externalised for Nepali and English (NFR-023/NFR-024) and that an opt-out stops future egress and deletes not-yet-egressed signal as T-053 requires
    And it defines the visible indicator shown while the loop is active, consistent with the disclosure precedent in Open Decision 12 (constitution.md:130)
```

## Implementation notes

- Read before designing: `IntentLogStore.swift:3-17` (the stated contract this amends), `:20-47` (fields), `:49-56` (cap and amortized count), `:88-92` (trim), `:100-123` (read/export), `:131-137` (decode path); `AppCoordinator.swift:4938-4944`, `:5076-5079` (the only append sites today); `DependencyProtocols.swift:23-34` and `LogSanitiser.swift:56-70` (the bus and its allow-list, for the "why not the bus" argument); `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §4.1, §5, §8.1.
- The design's §4.1 already fixes the docstring reconciliation: `IntentLogStore` says the log "leaves only via the family's explicit export" (`:11-14`), which stops being literally true once derived signals egress. This task specifies the amendment's wording; [T-056](T-056-capture-egress-implementation.md) lands it.
- Keep the payload definition machine-checkable if at all possible (a small schema file beside the design, in the `annotation_rules.yaml` / `encoder_contract.yaml` house pattern) so [T-056](T-056-capture-egress-implementation.md) and [T-059](T-059-privacy-audit.md) check the same artifact rather than re-reading prose.
- The salt requirement is in the design at §5.2; T-053 rules on it. Do not design an unsalted hash "temporarily" — the design's position is that a hash is a pseudonym, not anonymity, and the schema must reflect the ruling.
- Failure modes to enumerate: upload failure, partial upload, opt-out mid-flight, salt unavailable, clock skew, and a payload that fails its own schema check at the boundary (fail closed: do not send).
- Hand-off to [T-055](T-055-shadow-scoring-healing-protocol-design.md): the divergence telemetry is a *different* channel from this egress payload — it rides `ObservabilityBus` and its keys must be declared in `LogSanitiser`; state the boundary between the two in this design so the two documents cannot drift.

## Definition of done
- [ ] Capture schema specified: added fields, optionality/defaults, the pre-extension decode proof, and the confidence-signal gap resolved or named
- [ ] The 500-cap question answered (derived-signal digest specified, or trimmed-window sufficiency argued with T-052's numbers)
- [ ] Egress payload specified field by field, hashed-only, with a worked synthetic example and the salt ruling applied
- [ ] Transport contract: dedicated opt-in uploader, TLS 1.2+ (NFR-011), configurable timeouts/retries, every failure mode with its user-visible behaviour
- [ ] Opt-in/opt-out state machine with the exact transitions, the indicator, and the externalisation requirement (NFR-023/NFR-024)
- [ ] The `IntentLogStore` docstring amendment wording specified (§4.1 reconciliation)
- [ ] The boundary with [T-055](T-055-shadow-scoring-healing-protocol-design.md)'s telemetry channel stated
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable
