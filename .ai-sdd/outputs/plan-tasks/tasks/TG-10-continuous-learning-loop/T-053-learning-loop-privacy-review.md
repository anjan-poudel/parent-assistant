# T-053: Learning-Loop Privacy Review (R&D)

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** The consent basis for the hashed egress path; `constitution.md` Open Decision 12 (`:128-132`) as the consent/disclosure precedent; NFR-015/NFR-016/NFR-032 (`requirements.md:262-266`, `:329-330`); the retention window for captured signals
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-054](T-054-capture-schema-egress-contract-design.md), [T-056](T-056-capture-egress-implementation.md)
- **Requirements:** NFR-015, NFR-016, NFR-032
- **Origin:** TG-10 recorded decision D-1 (opt-in) and D-2 (hashed-only egress) in `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §2; the constitution's recorded cloud voice-stack exception (`constitution.md:128-132`) is the only consent-gated exception this project has

## Description

Produce the written privacy determination the hashed egress path requires, before anything is built on it. The determination must answer four things concretely enough that [T-054](T-054-capture-schema-egress-contract-design.md) and [T-056](T-056-capture-egress-implementation.md) can implement against it without re-deciding:

1. **Consent basis.** Does the loop need its own disclosure and consent, or is it an amendment to Open Decision 12's recorded consent/disclosure regime? Open Decision 12 is the project's only worked precedent for a consent-gated, non-default data path (`constitution.md:128-132`): it fixes scope, requires explicit consent and plain-language disclosure *at the point of selection*, requires a visible indicator while the path is active, and requires a way back without losing functionality. The loop is not a cloud AI processing path for content — it is a hashed-signal path — but it is still a collection, so the same questions apply: what is disclosed, when, and what the user can turn off.
2. **What the hashed payload may contain.** The design fixes the rule ("closed-vocabulary identifiers, buckets, counters, salted hashes", `…continuous-learning-loop-design.md` §5.1) but not the field list; the determination must either bless that rule as sufficient or narrow it, and must rule on §5.2's salt requirement (per-install, device-held) — including whether the salt may ever be escrowed or rotated.
3. **Retention.** The `IntentLogStore` cap is a device-side bound, not a retention policy (`IntentLogStore.swift:17`, `:49`); the egress side has no bound at all. A retention window must be set for both, and the determination must say who can delete what and by when.
4. **Review obligations.** The consent copy, the opt-out behaviour, and the review date. The constitution's existing monitoring bullet has an owner and a review date (`constitution.md:95`, owner Anjan Poudel, review by 2026-10-13) and Open Decision 11 is re-reviewed on the same date (`:121-126`) — the determination should slot the loop's own review into that cadence rather than inventing a parallel one.

**Deliverable: the determination, the specific consent copy it requires (both languages), and the retention window.** The copy is a deliverable, not a suggestion: if the review says the loop needs disclosure, the exact strings must exist for [T-056](T-056-capture-egress-implementation.md) to externalise (NFR-023/NFR-024).

**Open questions carried in, not decided here.** The design records OQ-1 (own disclosure vs. OD-12 amendment), OQ-2 (does the family export consent cover teacher transit through `gen_teacher.py`) and OQ-3 (retention window) as genuinely unresolved (`…continuous-learning-loop-design.md` open questions). This task resolves all three. OQ-2 gates [T-057](T-057-correction-miner-implementation.md): no mined row may be fed to the teacher until the determination says the consent covers that transit.

## Acceptance criteria

```gherkin
Feature: Learning-loop privacy determination

  Scenario: The consent basis is determined against Open Decision 12
    Given the recorded cloud voice-stack exception (constitution.md:128-132) — scope, point-of-selection consent, plain-language disclosure, visible indicator, a way back
    And the loop's recorded decisions D-1 (opt-in) and D-2 (hashed-only egress)
    When the determination is written
    Then it states whether the loop needs its own disclosure/consent or an amendment to Open Decision 12's regime, and cites the specific clause it relies on
    And it states whether the consent must be re-obtained when the payload changes, or whether the published payload definition is the consent's scope

  Scenario: The hashed payload's permissible fields are ruled on
    Given the design's egress table (hashed-only: closed-vocabulary ids, buckets, counters, salted hashes)
    When the determination rules on the payload
    Then it states whether each category may egress, and for the hash it rules on the per-install salt (required / optional / forbidden) and on rotation and escrow
    And it records whether an unsalted hash would be acceptable, with the reasoning made explicit (the design's §5.2 position is that a hash is a pseudonym, not anonymity)

  Scenario: A retention window is set for both sides of the boundary
    Given IntentLogStore's cap of 500 records is a device-side bound, not a retention policy (IntentLogStore.swift:17, :49)
    And the egress side has no bound today
    When the determination is written
    Then it names a retention window for captured on-device signals and for egressed records, in days or in a deletion trigger, and says what deletes them
    And it states what an opt-out deletes immediately versus what already egressed is retained under the window

  Scenario: The required consent copy is delivered in both supported languages
    Given NFR-023/NFR-024 (all UI strings externalised; Nepali primary, English secondary)
    And NFR-032 (the privacy policy must accurately describe what is collected, stored and transmitted)
    When the determination closes
    Then it contains the exact consent string, the opt-in explanation, the opt-out string and the visible-indicator string, in Nepali and English
    And it names the localisation key convention T-056 must use so the strings are not hard-coded (the app's general rule)
    And the privacy-policy text required by NFR-032 is delivered or a specific amendment is proposed

  Scenario: The determination is PII-free and its open questions are resolved or explicitly escalated
    Given NFR-016 and the precedent that this project's own artifacts must never carry secrets (the security-test's false-positive on a long opaque string)
    When the determination is written
    Then it contains no PII, no real credential, no hostname and no full 40-character hash — sentinel placeholders only where a credential-shaped value would be needed
    And each of the design's OQ-1, OQ-2 and OQ-3 is answered, or explicitly escalated to a named owner with the reason it cannot be answered here
```

## Implementation notes

- Read the precedent it must fit: `constitution.md:43` (Architecture Constraint 1 and its recorded exception), `:72-76` (Privacy standard), `:92-95` (release gates and the post-deploy monitoring bullet), `:121-126` (Open Decision 11), `:128-132` (Open Decision 12); `requirements.md:262-266` (NFR-015/016), `:329-330` (NFR-032).
- Read what is actually collected before ruling on it: `IntentLogStore.swift:11-14` (the log is *deliberately* content-bearing and separate from PII-free telemetry) and `AppCoordinator.swift:4938-4944`, `:5076-5079` (what is written today). The determination must not describe a collection that does not exist, or bless one that does.
- The existing T-036 governance is an input, not a substitute: consented export admission is stated at `docs/superpowers/specs/2026-09-13-encoder-training-data-strategy.md` §7, and `run_encoder_pipeline.py:598-600` records that consent-export ingestion is not implemented and refuses loudly. Reconcile the determination with both.
- OQ-2 is the sharp one: `gen_teacher.py` uses a cloud teacher (`config.yaml:4-12`), so feeding a real utterance as a seed sends that text to it. The determination must say whether the export consent covers that transit; [T-057](T-057-correction-miner-implementation.md) is blocked on the answer.
- Escalation is legitimate output: if a question needs the project owner (the constitution's Open Decisions are owner-decided, `:99`), record it as such with a name and a date rather than deciding it unilaterally.
- [T-059](T-059-privacy-audit.md) will audit the implementation against this determination, so every ruling must be checkable (a yes/no or a number), not a principle.

## Definition of done
- [ ] Written determination committed under `specs/` (T-053 notes)
- [ ] Consent basis decided, with the Open Decision 12 clause it relies on cited
- [ ] Payload ruling per category, including the salt (required/optional/forbidden), rotation and escrow
- [ ] Retention window for on-device signals and for egressed records, with deletion ownership
- [ ] Exact consent / opt-in / opt-out / indicator copy in Nepali and English, plus the NFR-032 privacy-policy text or a specific amendment
- [ ] OQ-1, OQ-2, OQ-3 answered or escalated with a named owner
- [ ] No PII, no secret, no full 40-character hash in the deliverable
- [ ] Handed to [T-054](T-054-capture-schema-egress-contract-design.md) and [T-056](T-056-capture-egress-implementation.md) as a binding input, and to [T-059](T-059-privacy-audit.md) as the audit's criterion
