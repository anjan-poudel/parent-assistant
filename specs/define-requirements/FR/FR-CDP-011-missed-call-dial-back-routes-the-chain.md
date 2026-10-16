# FR-CDP-011: Missed-call dial-back routes the chain

## Metadata
- **Area:** Call Paths / Missed-Call Dial-back
- **Priority:** MUST
- **Source:** Frozen design §4 ("`resolvedMissedCallChannel` ... run the chain ... missed-call dial-back") and Goal 3; feature constitution "In scope" ("missed-call dial-back") and Out of scope ("Emergency-contact semantics"); workflow `security-design-test` focus ("dial-back must never delay an emergency escalation"); DV-6.

## Description
Missed-call dial-back **must** run the chain: `resolvedMissedCallChannel` / `missedCallDialAction` resolve preferred → secondary → `.phone` with feasibility from the row's matched family contact (handle availability) and the WhatsApp probe (FR-CDP-005). The preferred input is the matched family contact's audio pick when one exists (as today, FaceTime excluded by the audio vocabulary), else the settings primary (`defaultCallApp`).

Existing honest dial-back behaviours **must** be preserved unchanged:
- A row with no number opens the Phone app (the call genuinely lives in Recents) — no resolution chain involved.
- A number that normalizes to nothing dialable speaks the existing honest line (`call.announce.noPhoneNumber`) and places no call — never a silent dead tap.
- No silent tap: every dial-back outcome is either an open or a spoken line.

Emergency-contact semantics are untouched by this requirement (FR-CDP-018); dial-back routing **must not** delay or reroute an emergency escalation.

## Acceptance criteria

```gherkin
Feature: Missed-call dial-back routes the chain

  Scenario: A dial-back with an infeasible preferred channel falls back
    Given a missed-call row matches a family contact
    And the preferred channel for that dial-back is infeasible (e.g. Messenger with no handle)
    And the settings fallback is feasible
    When the user taps the row to dial back
    Then the chain resolves to the fallback (or GSM) channel
    And the dial-back is attempted, never dead-ended

  Scenario: A numberless row keeps the honest Phone-app open
    Given a missed-call row has no number
    When the user taps the row
    Then the Phone app opens (the call lives in Recents)
    And no call is placed by the app

  Scenario: A non-dialable number keeps the honest spoken line
    Given a missed-call row has a number that normalizes to nothing dialable
    When the user taps the row
    Then the app speaks the existing honest line (call.announce.noPhoneNumber)
    And no call is placed
    And no silent tap occurs
```

## Related
- FR: FR-CDP-007 (the chain), FR-CDP-009 (preferred input), FR-CDP-010 (button paths), FR-CDP-016 (routed-channel announcement), FR-CDP-018 (emergency semantics untouched)
- NFR: NFR-CDP-001 (never dead-ends), NFR-CDP-009 (regression pin on dial-back)
