# T-052: Continuous-Learning Signal Quality — Feasibility (R&D)

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** `ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift` (record shape and roll-off under the 500 cap), the two append sites `App/AppCoordinator.swift:4938-4944` and `:5076-5079`, and the harness surface in `tools/train-intent/eval/results.csv`
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-054](T-054-capture-schema-egress-contract-design.md), [T-057](T-057-correction-miner-implementation.md)
- **Requirements:** NFR-015, NFR-016
- **Origin:** TG-10 capacity boundary — "TG-10 must NOT extend the TG-08 critical path"; the loop's first unknown is whether the signal justifies the loop (`docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §2 D-3, §4.1–4.2, R-1, R-2)

## Description

Answer one question with measurements, not a plan: **do the signals the app already records predict errors, at what yield, and is the shipped `IntentLogStore.Record` shape sufficient to mine them?** This is R&D — the deliverable is a feasibility report over the on-device record shape, not a plan to build the miner (that is [T-057](T-057-correction-miner-implementation.md)).

Three signals are claimed by the design (`…continuous-learning-loop-design.md` §4.2): corrections (`outcome == "corrected"` plus `correctedTo`), repeat-after-abstention (a `nil`/override result followed by the same action), and low-confidence clusters. Each claim is testable against what the store actually contains:

- the record fields are `path`, `action`, `slots`, `outcome`, `correctedTo`, `latencyMs`, `timestamp` (`IntentLogStore.swift:20-47`) — note there is **no confidence field** and no utterance hash in the shipped shape, so "low-confidence cluster" is currently *not* derivable from a `Record` alone;
- only two append sites exist (`AppCoordinator.swift:4938-4944`, `:5076-5079`), both for `call`; the remaining actions' outcomes are not logged at all today;
- `maxRecords = 500` with oldest-first trimming (`IntentLogStore.swift:17`, `:49`, `:88-92`) — the D-3 risk is that a weekly cadence mines an ever-shrinking, recency-biased window.

**What the report must state.** (a) the measured per-signal yield over a real or fixture-populated store; (b) which signals are derivable from `Record` as shipped and which need a schema extension (T-054's input); (c) the roll-off rate under the 500 cap and what fraction of a weekly window survives; (d) a falsifiable statement of whether the loop's expected yield clears the AUGMENT floors it must feed (`stt_noised ≥ 0.55`, corpus ≥ 8 000, per-action ≥ 0.25 × target — `tools/train-intent/src/build_encoder_dataset.py:31-35`). A "not worth it" answer is a valid outcome and must be said plainly rather than padded into a green light (`…continuous-learning-loop-design.md` R-1).

**What it is not.** Not a miner, not a schema change, not a pipeline run. If the report concludes the shape is insufficient, it names the missing fields and hands them to [T-054](T-054-capture-schema-egress-contract-design.md); it does not edit `IntentLogStore`.

## Acceptance criteria

```gherkin
Feature: Continuous-learning signal quality feasibility

  Scenario: The three claimed signals are measured against the shipped record shape
    Given IntentLogStore.Record's fields (id, timestamp, path, action, slots, outcome, correctedTo, latencyMs) at Services/Intents/IntentLogStore.swift:20-47
    And the two append sites AppCoordinator.swift:4938-4944 (correction) and :5076-5079 (confirmed call)
    When the feasibility measurement runs over a populated store (real consented data or a fixture the report describes)
    Then it reports, per signal (correction, repeat-after-abstention, low-confidence cluster), how many records are derivable from Record as shipped and how many need a field that does not exist
    And it states explicitly that "low-confidence cluster" is not derivable today because Record carries no confidence field, if that is what the measurement shows

  Scenario: Yield is measured against the floors the loop must feed
    Given the AUGMENT floors (stt_noised share >= 0.55, corpus >= 8000 rows, per-action >= 0.25 x target) at tools/train-intent/src/build_encoder_dataset.py:31-35
    When the measured per-week signal yield is projected onto the T-034 target table (tools/train-intent/annotation_rules.yaml taxonomy.targets)
    Then the report states whether any single week's mined rows can move any action toward its floor, with the arithmetic shown
    And if the answer is no for every action, the report says so and does not recommend proceeding to T-054 on the strength of the loop's accuracy benefit alone

  Scenario: Roll-off under the 500-record cap is quantified
    Given maxRecords = 500 with oldest-first trimming (IntentLogStore.swift:17, :49, :88-92)
    When the measurement reports the record arrival rate and the window it implies
    Then the report gives the fraction of a weekly window that survives to a weekly retrain, and the recency bias that trimming introduces
    And it records whether the cap, the cadence, or the derived-signal summary is the thing that has to change to keep the signal addressable

  Scenario: The report is PII-free and cites only real evidence
    Given NFR-016 (logs and reports must not contain PII) and NFR-015 (no personal data to cloud for AI processing)
    When the feasibility report is written
    Then it contains counts, rates, distributions and file:line citations only — no utterance, contact name, medication name or message body, and no hostname, key or other secret
    And a claim that cannot be grounded in a file read is marked UNKNOWN rather than asserted
```

## Implementation notes

- Read the shipped shape first: `IntentLogStore.swift:20-47` (fields), `:58-65` (Application Support + `NSFileProtectionComplete`), `:100-102` (`recent(limit:)`), `:108-123` (`exportURL`), and the append sites `AppCoordinator.swift:4938-4944`, `:5076-5079`. Anything the report asserts about the record must cite one of these.
- A fixture-filled store is acceptable evidence if no consented real data exists, provided the report says so. Do not read on-device log content that has not been exported under the family's consent (NFR-015); do not put a fixture's utterance content in the report (NFR-016).
- The 500-record cap arithmetic is in the store itself: `estimatedCount` is amortized and the trim fires above `maxRecords + 50` (`:52-56`, `:86-92`). Report the *effective* window, not the nominal one.
- Cross-check with the spec's recorded flywheel cadence ("monthly or at 500 corrections", `docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md:610`) and say where the weekly proposal (design §2 D-3) beats or loses to it.
- Hand-off: the derivability table is [T-054](T-054-capture-schema-egress-contract-design.md)'s schema input; the yield numbers are [T-057](T-057-correction-miner-implementation.md)'s expected-yield baseline. [T-053](T-053-learning-loop-privacy-review.md) consumes the report's statement of *what* is collected as input to the consent copy.
- No build, no test run, no training run. This is a measurement over data and code that already exist.

## Definition of done
- [ ] Written feasibility report committed under `specs/` (T-052 notes), with the four acceptance scenarios answered explicitly
- [ ] Per-signal derivability table against `IntentLogStore.Record` as shipped, including the confidence-field gap
- [ ] Measured yield per signal, with the arithmetic against the AUGMENT floors shown
- [ ] Roll-off measurement under the 500 cap and its implication for the weekly cadence
- [ ] A plain recommendation: proceed / proceed with a named schema extension / stop — with the evidence that supports it
- [ ] No PII in the report; every claim carries a file:line citation or is marked UNKNOWN
