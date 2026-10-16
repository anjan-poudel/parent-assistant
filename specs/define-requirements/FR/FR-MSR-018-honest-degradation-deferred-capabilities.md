# FR-MSR-018: Honest degradation — deferred capabilities surfaced as themselves, never a false success

## Metadata
- **Area:** Honesty / Delivery Integrity
- **Priority:** MUST
- **Source:** Feature constitution "Feature Constraints" 9 ("No silent stubs; honest degradation") and "Safety & Compliance Delta" (verified risk notes: the photo-verification machinery is unwired; the push transport is a stub); project constitution Agent Principles ("No silent stubs"); workflow scope comment (owner brief, 2026-10-15).

## Description
Every deferred or unwired capability this feature touches **must** be surfaced as itself — never presented as working, never a silent success:

- **Unwired photo verification is surfaced as itself.** The existing photo-verification machinery exists as components but is not wired end-to-end. The feature must not assume it delivers and must not present photo verification as active where it is not; where the design builds on it, wiring it is part of that work (FR-MSR-013, Open Decision 8).
- **Undelivered notifications are never "success".** Where the push transport cannot deliver, the outcome is reported as not delivered (FR-MSR-016); no surface or report claims the caregiver was notified when the notification did not happen.
- **No unverified write presented as success.** A persistence or scheduling failure (for example, a storage write refusal) surfaces as an error and blocks its dependent step (FR-MSR-022) — it never masquerades as a completed write.
- **Delivery claims are scoped to what actually fires.** Feature-level claims (for example "caregivers are always notified") are made only for the paths that actually fire; transport-dependent claims are named as inherited tracked work until the transport lands.

## Rationale
This feature's teeth are safety claims — "notified", "recorded", "verified". A false success in any of those three is the exact failure class the Agent Principles forbid. The requirement names the three known deferred capabilities so none can be quietly claimed as done.

## Acceptance criteria

```gherkin
Feature: Deferred capabilities are surfaced honestly

  Scenario: Photo verification state is reported as itself
    Given the photo-verification machinery in its unwired state
    When a surface or report describes the feature's photo-evidence capability
    Then it describes the capability's actual state (wired and delivering, on-device-only, or not wired)
    And it does not present photo verification as active where no capture-to-caregiver path exists

  Scenario: A failed delivery is never success
    Given a significant-event notification whose transport cannot deliver
    When the outcome is recorded and reported
    Then it is recorded as not delivered
    And no report or copy describes the caregiver as notified

  Scenario: A failed persistence write surfaces and blocks (failure)
    Given a storage write that fails while a reminder or acknowledgement is being persisted
    When the dependent step (alarm arming or acknowledgement completion) would proceed
    Then the failure surfaces as an error
    And the dependent step does not proceed as if the write had succeeded

  Scenario: Feature claims match fired paths (review guard)
    Given the feature's completion report
    When its notification and photo claims are checked against what actually fires
    Then every claim is limited to paths that fire
    And transport-dependent statements are labelled as inherited tracked work
```

## Related
- FR: FR-MSR-013 (photo evidence), FR-MSR-016 (delivery honesty), FR-MSR-022 (persistence before alarm)
- NFR: NFR-MSR-009 (release gates)
