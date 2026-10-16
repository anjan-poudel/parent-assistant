# T-172 — CloudChatConsentGate: fail-closed consent record (OD-12 shape)

## Metadata
- **Group:** [TG-36 — Cloud Chat Consent, Routing and Elder Surfaces](index.md)
- **Component:** Consent gate (design-l1 sections 8.3 and 12)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** HIGH
- **Depends on**: —
- **Blocks:** T-173 ([T-173](T-173-cloud-chat-routing-decision.md)), T-175 ([T-175](T-175-router-cloud-first-chat-lane.md)), T-176 ([T-176](T-176-consent-prompt-and-disclosure.md)), T-177 ([T-177](T-177-indicator-revocation-and-coordinator-wiring.md))
- **Requirements:** [FR-CNR-009](../../../define-requirements/FR/FR-CNR-009-cloud-chat-consent-disclosure-indicator.md), [NFR-CNR-011](../../../define-requirements/NFR/NFR-CNR-011-compliance-and-release-gates.md)

## Description
Build the cloud chat consent record and its one-writer gate in the OD-12 shape the project has already shipped twice (LiveTranslate, PointAsk): a decision of granted / notRecorded / denied / unreadable where only granted allows egress, an encrypted-at-rest record carrying the disclosure version, and revoke-verify semantics. This is the elder's act recorded as a fact, not a default: no path may produce a silent grant.

## Acceptance criteria

```gherkin
Feature: Cloud chat consent as a fail-closed record

  Scenario: First use records an explicit decision
    Given a device with no consent record
    When the decision is read
    Then it is notRecorded and egress is refused
    And no chat content has been sent anywhere to establish that answer

  Scenario: A grant is the only state that allows egress
    Given a recorded grant at the current disclosure version
    When the decision is read
    Then it is granted and allows egress
    And notRecorded, denied and unreadable each refuse egress with their own reason

  Scenario: Revocation clears memory before storage
    Given a granted record
    When revoke is called
    Then in-memory state is cleared before the stored record is rewritten
    And the next read returns denied (or notRecorded, per the revoke semantics) — egress refused

  Scenario: One writer under a lock
    Given concurrent grant and revoke calls
    When both complete
    Then the stored record is one of the two outcomes, never a torn write
    And every call reports its own success or failure truthfully
```

## Acceptance criteria — failure paths

```gherkin
Feature: Consent failure behaviour

  Scenario: An unreadable record never collapses into an answer
    Given a corrupt or undecodable stored payload
    When the decision is read
    Then it is unreadable — distinct from notRecorded and denied
    And it refuses egress (fail-closed) and never crashes

  Scenario: A write that did not take effect is not a success
    Given a storage write that fails or does not persist
    When grant completes
    Then the call surfaces the failure and the decision remains non-granted on the next read
    And no code path reports success for a record that is not on disk

  Scenario: A stale disclosure version re-asks
    Given a stored grant whose disclosure version differs from the current constant
    When the decision is read
    Then it is notRecorded (re-disclosure required), never granted
```

## Inputs and expected result

**Input:** the shipped consent-store mechanism and gate shape from the LiveTranslate/PointAsk precedent (reuse, not a fork); the decision-type contract in design-l1 section 8.3; the current disclosure-version constant convention.

**Output:** the gate with its decision type, record type, one-writer grant/revoke with revoke-before-storage ordering and write-failure honesty, plus tests covering the four states, corruption, stale version and torn-write behaviour.

**Declared files:** `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatConsentGate.swift`, `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatConsentGateTests.swift`

## Implementation notes
- Reuse the encrypted-at-rest consent storage mechanism (Keychain-backed) exactly as the shipped gates use it; this is a new feature-scoped record, not a new mechanism. `ConsentRecord { granted, recordedAt, disclosureVersion }`, Codable.
- Fail-closed is the whole point: `allowsEgress` is true for `.granted` only. `.unreadable` must never be reported as `notRecorded` or `denied` (the precedent's distinction is deliberate — it tells a future reader the difference between "never asked" and "cannot read").
- Revocation is a record state, not a separate preference flag: there is exactly one source of truth for whether chat may egress (design section 12).
- No transcript, no reply text and no key material touches this unit; it logs nothing content-bearing (its events, if any, are classification-only like the shipped gates').
- Keep the write path synchronous and locked (NSLock), matching the shipped precedent; the read path is a per-turn read (no caching — the routing decision reads it every turn, T-173).

## Definition of done
- [ ] Decision type with the four states; `allowsEgress` true only for granted
- [ ] Record stored via the shipped encrypted consent mechanism; `disclosureVersion` checked
- [ ] One writer, revoke clears memory before storage, write failure surfaced (never a false success)
- [ ] Corrupt payload → unreadable, fail-closed, no crash
- [ ] Stale disclosure version → notRecorded
- [ ] Tests cover the four states, corruption, stale version, failure-to-persist and concurrent access
- [ ] No content-bearing log statement in the unit
