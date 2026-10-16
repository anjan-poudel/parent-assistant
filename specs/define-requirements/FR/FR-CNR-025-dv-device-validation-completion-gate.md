# FR-CNR-025: DV-1 … DV-6 device validation on Anzaan — the recorded completion gate

## Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Source:** Proposal §6 ("**Device**: A/B on Anzaan behind the catalog pick; listening panel with actual elderly users (they are the judges of 'human-like'); DV-style protocol with honorific-mismatch telemetry"); feature constitution "Success Criteria & Completion Gate" (the DV-1..DV-6 list and the release gate) and Safety & Compliance Delta 7; workflow `final-sign-off` task comment (the DV list is repeated there and `final-sign-off` is T2 + HIL). Reference device: Anzaan.

## Description
The feature is **not complete** until the DV protocol has been executed on the reference device (Anzaan) and its results are recorded with the feature spec at final sign-off. Each item **must** be recorded with its outcome, and a failed item blocks completion:

- **DV-1 — local chat quality**: warm, grammatical replies from the shipped tier (honorific agreement, particles within budget, no AI-isms) — the elderly-user-facing quality claim measured on device.
- **DV-2 — cloud-first chat**: consent + plain-language disclosure + visible indicator work; toggling off (revocation) returns to the on-device brain without losing chat.
- **DV-3 — offline/honest degradation**: with no cloud available, chat degrades honestly to the local brain — no crash, no false success, no dropped turn.
- **DV-4 — emergency phrasing recall on device**: emergency phrasing still triggers exactly; recall is untouched by the chat work (the gate form is 1.00, FR-CNR-014/021).
- **DV-5 — command determinism unchanged**: temp-0 behaviours (e.g. reminders/alarms) are unchanged on device (FR-CNR-004).
- **DV-6 — elderly listening panel A/B verdict recorded**: real elderly listeners judge the A/B behind the catalog pick; their verdict is the "human-like" authority and is recorded, whatever it says.
- **Release gate**: `ios/tools/check-release-log-safety.sh` exits 0 covering the new chat/routing/guard paths (NFR-CNR-006), and the pre-release device console check covers the same paths.
- **Honorific-mismatch telemetry** is captured during the DV session (classification only) so on-device performance is observable after ship.

## Acceptance criteria

```gherkin
Feature: DV-1..DV-6 executed on the reference device and recorded

  Scenario: Each DV item is executed and recorded
    Given the feature build installed on Anzaan
    When the DV protocol is run
    Then each of DV-1..DV-6 is executed against its stated criterion
    And each result is recorded with the feature spec at final sign-off

  Scenario: The listening panel's verdict is recorded
    Given an A/B comparison behind the catalog pick
    When the elderly listening panel gives its verdict
    Then the verdict is recorded verbatim
    And it is not summarised into a claim the panel did not make

  Scenario: A DV item fails or is skipped (failure)
    Given a DV item that failed or was not executed
    When final sign-off is prepared
    Then completion is withheld
    And the failure or omission is stated explicitly for the owner (FR-CNR-024)
```

## Related
- FR: FR-CNR-004 (DV-5), FR-CNR-008/009 (DV-2, DV-3), FR-CNR-014 (DV-4), FR-CNR-022 (the catalog pick A/B), FR-CNR-024 (honest reporting)
- NFR: NFR-CNR-002 (latency observed on device), NFR-CNR-003 (memory/jetsam observed on device), NFR-CNR-006 (release log gate), NFR-CNR-011 (final sign-off gates)
