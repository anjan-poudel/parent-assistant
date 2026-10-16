# T-014: `LiveTranslateConsentGate`

## Metadata
- **Group:** [TG-05 — Consent, Disclosure and the Cloud Indicator](index.md)
- **Component:** C09 — `LiveTranslateConsentGate` (`ConsentRecord`)
- **Agent:** dev
- **Effort:** L
- **Risk:** CRITICAL
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-002](../TG-01-foundations/T-002-translation-outcome-and-errors.md), [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md)
- **Blocks:** T-015, T-019, T-029
- **Requirements:** FR-LCT-010, FR-LCT-012, FR-LCT-013, NFR-LCT-007 · **Amendments AM-1, AM-4, AM-7** · **CL-2**

## Description

Own the decision that no recognized text leaves the device without a recorded grant: read the record at
the point of use, fail closed on every failure mode, and hand the cloud tier a decision the tier cannot
re-derive or work around. Revocation is effective without a restart, and a revocation that cannot be
persisted still denies.

Source: `Services/LiveTranslate/` `LiveTranslateConsentGate.swift` using the shipped encrypted storage
and `StoragePlacementPolicy` under `ios/ElderlyAssistant/`. Tests mirror under
`ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Fail-closed cloud translation consent

  Scenario: A grant for the current disclosure version allows the send
    Given a record granted for the current disclosure version
    When `currentDecision()` is read
    Then it returns granted
    And the tier may proceed (the request builder requires the gate's proof) (AM-7)

  Scenario: Every absence form denies, each with its own decision
    Given no record, an explicitly denied record, or an unreadable record
    When `currentDecision()` is read
    Then it returns notRecorded, denied or unreadable respectively
    And all three deny, and nothing is sent in any of them (FR-LCT-010)

  Scenario: A stale-version grant does not inherit
    Given a record granted for an older disclosure version
    When `currentDecision()` is read
    Then it does not return granted
    And the decision denies until a record for the current version is recorded (OD3 hook)

  Scenario: No configuration or context implies consent
    Given a configured provider key, an open camera and a family-managed account
    When `currentDecision()` is read with no record
    Then it denies
    And no configurable value can reach the cloud tier without a record (FR-LCT-010)

  Scenario: Withdrawal takes effect immediately, including between attempts
    Given a granted record and an in-flight cloud attempt
    When the record is revoked before the retry attempt
    Then the in-memory mirror is flipped, the in-flight task is cancelled and its regions degrade
    And the retry is not attempted and nothing is sent (AM-1)

  Scenario: A revocation whose write fails still denies
    Given a revocation whose storage write fails
    When the decision is read immediately afterwards and again after a re-read
    Then both reads deny
    And the failure is reported as its own outcome rather than silently leaving a grant in force (AM-4)

  Scenario: Recording a decision is explicit and minimal
    Given the elder grants or declines
    When the record is written
    Then it holds only the granted flag, the timestamp and the disclosure version
    And no free-form text or user identifier is stored

  Scenario: Every decision point is evidenced without content
    Given the record, revoke and read paths
    When the decision points fire
    Then each emits its content-free event from the catalogue
    And the negative case (no record → zero requests) is observable for `security-test` (NFR-LCT-007)
```

## Implementation notes

- **Fail-closed is the default everywhere**: unknown record shape, decode failure, unreadable file,
  failed revocation write, missing version, mismatched scope — every one denies. There is no
  default-on path and no cached grant that survives a re-read check.
- **AM-7**: the request builder (T-018) requires the gate's decision as a parameter and is the single
  call site; a missing proof is a compile error, which is the intended failure.
- **AM-1**: the gate is re-consulted per attempt, never once per session or per region, so a withdrawal
  between attempts blocks the retry. Record this case explicitly for `security-test`.
- **AM-4**: a revocation that cannot be persisted must deny in memory **and** on a subsequent re-read.
  An implementer is most likely to get this wrong by trusting the in-memory flag alone.
- Record shape: `ConsentRecord { granted, recordedAt, disclosureVersion }` under the declared storage
  key `plugin.live_translate.consent.v1`, on the encrypted file channel the placement policy selects.
  Absent, corrupt or unreadable ⇒ deny. Deleting the key is revocation.
- The prompt is presented **at the first cloud need** and has no timeout (T-015); this task defines the
  decision, not the presentation. While a prompt is on screen no request is in flight.
- Emit only the catalogue's consent events with `disclosureVersion` (T-003); never log the record body.
- This task is graded by `security-test` (T-029): the suite must show the gate permitting **and**
  refusing, case by case.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts the request builder cannot be reached without the gate's proof (AM-7)
- [ ] A test asserts the withdrawal-between-attempts case denies the retry, not merely the next session (AM-1)
- [ ] A test asserts a failed revocation write denies both in memory and after a re-read (AM-4)
- [ ] A test asserts each of notRecorded / denied / unreadable denies and is distinguishable
- [ ] Integration test against the stubbed storage layer, including its failure modes
- [ ] Verified that a crash or hang of the translation model cannot grant consent or bypass the gate
- [ ] `ios/build.sh` passes
