# T-002: Outcome, Tier and Error Taxonomy

## Metadata
- **Group:** [TG-01 — Foundations](index.md)
- **Component:** C04 — `TranslationResult` / `TranslationTier` / `TranslationOutcome`
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** T-002-adjacent consumers: T-011, T-017, T-018, T-019, T-020, T-021, T-024, T-026
- **Requirements:** FR-LCT-008, FR-LCT-018, NFR-LCT-010 · **CL-4, CL-8**

## Description

Make truthful tier attribution and honest degradation **structural** rather than procedural: the
outcome enum is the single source of truth, a tier that did not translate is not nameable, and the
deferred on-device tier has no case to return. Add the feature's error taxonomy with stable,
content-free log-safe codes and the error → unavailable-reason conversion table the tier (T-019) reads
instead of re-deriving.

Source: `Services/LiveTranslate/` `TranslationResult.swift` under `ios/ElderlyAssistant/`. Tests
mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Truthful outcomes and typed errors

  Scenario: A tier that did not translate cannot be named
    Given a region for which no tier produced a translation
    When its outcome is read
    Then sourceTier is nil
    And degraded is true and isFinal is true
    And text is the original recognized text

  Scenario: A resolved outcome names the tier that actually produced it
    Given a string resolved from the curated dictionary
    When its outcome is read
    Then sourceTier is dictionary, degraded is false and text is the translation

  Scenario: The deferred on-device tier has no representation to return
    Given the tier type
    When it is inspected
    Then it has exactly two cases, dictionary and cloud
    And no resolution path can construct an outcome attributed to an on-device translation tier, and no ordinal tier number is reserved as a case (FR-LCT-008 scenario 4, D2)

  Scenario: A pending region claims nothing
    Given a region whose string is unresolved and a tier is in flight
    When its outcome is read
    Then the outcome is pending, sourceTier is nil and isFinal is false

  Scenario: State transitions are monotone
    Given a region resolved with its text unchanged
    When the pipeline publishes again
    Then the outcome stays resolved and never returns to pending
    And a later text change replaces the outcome for the same region id rather than merging with it (FR-LCT-018)

  Scenario: Every failure maps to a stable, content-free code and a reason
    Given the feature's error cases (camera, detection, consent, cost, cloud, sanitisation, cache, speech)
    When each case's log-safe code is read
    Then it is a constant token, never a description, an upstream body, a count or a status embedded in a description
    And the error → unavailable-reason conversion table is documented and unit-tested for every case (CL-4)

  Scenario: Unsupported tracking degrades to OCR-only rather than failing
    Given a device whose tracking request is unsupported
    When the detector reports it
    Then the feature continues with OCR only and records an honest event
    And the tracking-off state is not an error shown to the elder (FR-LCT-004 is a SHOULD)
```

## Implementation notes

- Design shapes (C04): `TranslationOutcome` is `pending` / `resolved(translation:tier:)` /
  `degraded(originalText:reason:)`; `text` is the translation when resolved and the original
  recognized text otherwise; `sourceTier` is non-nil **only** for resolved; `degraded` is true only
  for degraded; `isFinal` is false only for pending. Keep the documented accessors — do not store them
  inconsistently alongside the enum.
- `TranslationUnavailableReason`: `noNetwork`, `providerNotConfigured`, `consentNotGranted`,
  `costBudgetExhausted`, `providerRejected`, `textQuarantined`, `deadlineExceeded`, `noTierResolved`.
  The reason never carries upstream text.
- Error cases and their codes follow the design's per-component enums: `cameraPermissionDenied`,
  `cameraPermissionNotDetermined`, `noCaptureDevice` / configuration failure, `trackingUnsupported`,
  `consentNotRecorded` / `consentDenied` / `consentRecordUnreadable`, `costBudgetExhausted`,
  `cloudTransient`, `cloudRejected(status:)`, `cloudPolicyBlocked`, `cloudResponseUnusable`,
  `cloudDeadlineExceeded`, `providerNotConfigured`, `textQuarantined`, `cacheReadFailed` /
  `cacheWriteFailed`, `speechFailed`. `status` is an integer field, never part of a description.
- Retryability is **not** decided here: this task supplies the reason mapping and the codes. The tier
  (T-019) classifies through the design's **"Failure modes and retryability per asynchronous
  operation"** table in `specs/design-component.md` (rows 1–24). Do not re-derive it, and do not cite
  any "C23" — that identifier does not exist in the component inventory (CL-8).
- Keep `consentRecordUnreadable` and `costBudgetExhausted` distinguishable: they are different owner
  actions and must never collapse into a generic denial.
- Keep this file free of I/O so every case is unit-testable with no device, camera or network.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test constructs every error case and asserts its code and its mapped reason (exhaustive switch, no default branch)
- [ ] A test asserts no resolution path can produce a non-nil `sourceTier` on a degraded or pending outcome
- [ ] A test asserts the tier type has exactly two cases and that no ordinal tier number is reserved
- [ ] `ios/build.sh` passes
