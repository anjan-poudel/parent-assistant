# FR-MSR-013: Photo of the medication as intake evidence — augments, never replaces, never creates a record

## Metadata
- **Area:** Photo Evidence / Safety
- **Priority:** MUST
- **Source:** Owner's brief scope point 5 (2026-10-15); feature constitution "Photo-as-Evidence Contract" binding properties 1, 3, 4, 5 and "Safety & Compliance Delta" (c); Open Decision 8 (OPEN — carried to the design chain); `requirements-dementia-supplement.md` FR-D04a–FR-D04e (read-only input).

## Description
A photo of the medication **must** serve as intake evidence (owner point 5), **augmenting and never replacing** the acknowledgement + confirmation chain (safety_delta (c)). Recording still happens through the acknowledgement path (FR-MSR-009); evidence attaches to a record — it does not create one.

Binding properties:

- **Evidence attaches, never creates.** A photo alone can never produce a taken record, and a photo can never substitute for the FR-D01 challenge or the FR-D03 check.
- **On-device only.** Medication photos stay on the device; nothing sends medication photos to cloud (NFR-MSR-003). The recorded cloud exceptions (voice transcription, OCR'd-text translation) do not apply here.
- **Verified state of the shipped machinery.** The existing photo-verification machinery (FR-D04a–e shapes: size-capped, end-to-end delivery discipline, delete-after-delivery, graceful camera fallback) exists as components but is **not wired end-to-end** in the app today. The feature must not assume that delivery works; where the design builds on it, wiring it is part of that work, and its state is surfaced honestly (FR-MSR-018).
- **Delivery discipline if evidence leaves the device.** Where evidence does leave the device it follows the existing dementia-photo discipline: compression cap, end-to-end encryption, on-device retention until delivered then deletion within 1 hour, never stored on the relay, never used for any other purpose — and a delivery failure is never silent.
- **Open Decision 8 is carried to the design chain**: the mechanism (reuse the existing photo-verification path once wired, an on-device-only variant, or an extension of the per-medication/per-time-of-day dementia mechanism), the capture semantics and the recipient/judge of the photo are design-level decisions — bounded by the properties above. Removal of the dementia mechanism is forbidden in every case (FR-MSR-020).

## Rationale
The owner wants photographing to be easier than dictating when several medications share a slot. The safety-relevant line is the same as the scan line: a new capture surface must not become a new recording path. Evidence improves caregiver confidence; it must not dilute the confirmed acknowledgement that protects the elder from double-dosing.

## Acceptance criteria

```gherkin
Feature: Photo evidence augments the acknowledgement chain

  Scenario: Evidence attaches to a confirmed intake
    Given the elder completed the acknowledgement and confirmation challenge for a medication
    When the elder photographs the medication as evidence
    Then the evidence is attached to the intake record
    And the record exists because the acknowledgement chain completed, not because of the photo

  Scenario: A photo alone never records a dose (misuse guard)
    Given no acknowledgement has been made for a medication
    When only a photo of the medication is captured
    Then no taken record is created
    And the intake still requires the acknowledgement and confirmation sequence

  Scenario: Medication photos stay on-device (failure guard)
    Given a captured medication photo, with or without delivered evidence state
    When the device's network activity and stores are inspected
    Then no medication photo has been sent to any cloud service
    And any evidence leaving the device follows the size-cap, encryption, retention-and-deletion discipline with no silent delivery failure
```

## Related
- FR: FR-MSR-009 (safety sequence), FR-MSR-014 (shared-slot resolution), FR-MSR-018 (honest state of the unwired machinery), FR-MSR-020 (dementia machinery preserved)
- NFR: NFR-MSR-003 (no new egress), NFR-MSR-002 (no photo content in observability)
