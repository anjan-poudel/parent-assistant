# T-024: Tap-to-Hear and "Read This to Me"

## Metadata
- **Group:** [TG-08 — Voice Output and Session Commands](index.md)
- **Component:** C12 — spoken output over the shipped announcement and speech queue
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-002](../TG-01-foundations/T-002-translation-outcome-and-errors.md), [T-005](../TG-01-foundations/T-005-localisation-catalog-and-purpose-string.md), [T-017](../TG-06-cloud-translation-tier/T-017-scene-text-sanitiser.md), [T-020](../TG-07-overlay/T-020-overlay-placement.md), [T-021](../TG-07-overlay/T-021-overlay-view-and-states.md)
- **Blocks:** T-025, T-026
- **Requirements:** FR-LCT-021, FR-LCT-023, NFR-LCT-009, NFR-LCT-004 · **CL-8**

## Description

Speak what is on screen through the two explicit entry points the design allows — tapping a bubble
speaks that region's translation, and "read this to me" speaks the visible translations top-to-bottom —
using the shipped announcement path and the active-language voice. **Nothing is spoken automatically**,
and that is enforced structurally by the number of construction sites, not by convention.

Source: `Services/LiveTranslate/` `LiveTranslateSpeech.swift` over the shipped speech queue under
`ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Spoken translations

  Scenario: Tapping a bubble speaks that region and nothing else
    Given a resolved region on screen
    When the elder taps its bubble
    Then that region's translation is spoken
    And no other region's text is spoken (FR-LCT-021)

  Scenario: Read-all speaks the visible regions top-to-bottom
    Given several resolved regions on screen
    When the elder asks to read them
    Then the translations are spoken in order of the region boxes' vertical midpoints, ties broken by horizontal midpoint
    And each is spoken once, sequentially, in the active-language voice

  Scenario: Nothing is spoken automatically
    Given a translation that resolves while the overlay is showing
    When it becomes resolved
    Then no speech is enqueued
    And the only construction sites of an announcement in this feature are the tap handler and the command handler (no observer, no property hook)

  Scenario: Nothing quarantined is ever spoken
    Given a region whose text was quarantined by the sanitiser
    When the elder asks to read the view
    Then that region is not spoken
    And its exclusion does not prevent the remaining regions from being spoken (NFR-LCT-009)

  Scenario: Degraded regions are spoken honestly
    Given a region degraded with its original text
    When the view is read
    Then the original text is spoken for that region
    And it is not presented as a translation (FR-LCT-023)

  Scenario: Speech stops immediately on request
    Given speech is in progress
    When the elder says stop or closes the feature
    Then speech stops without finishing the current item
    And no queued item remains to play later

  Scenario: A speech failure leaves the visual path untouched
    Given the speech path fails
    When the failure surfaces
    Then the visual translation stays on screen, no retry loop starts, and no blocking state is shown (failure table row 22)

  Scenario: Reading does not re-translate or re-send
    Given translations already on screen
    When they are read
    Then no cloud request, no cache write and no consent prompt occurs
    And the spoken text is exactly the on-screen translation
```

## Implementation notes

- Two entry points only (C12): tap-to-hear and "read this to me". Both end in the shipped announcement
  path with the active-language Piper voice. Do not build a second speech path.
- **No auto-speak, enforced structurally**: the only two construction sites of an announcement in this
  feature are the tap handler and the command handler. No observer on resolution, no property hook that
  enqueues speech. A third construction site is a defect, and a test should count them.
- Reading order is derived from the placements (T-020): vertical midpoint ascending, ties broken by
  horizontal midpoint. Reuse the mapper's geometry rather than re-deriving it.
- The spoken text for a region is the same string the overlay shows; a divergence between what is read
  and what is shown would be a truthfulness failure. Quarantined strings are never spoken.
- Speech is interruptible at every point: the stop command (T-023) and session close (T-026) must both
  drain the queue.
- Emit `speak_requested` / `speak_failed` with a `mode` token only, never the spoken text (T-003).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts tap-to-hear speaks only its own region
- [ ] A test asserts reading order matches vertical-then-horizontal ordering
- [ ] A test counts announcement construction sites and fails if a third appears
- [ ] A test asserts stop and close both drain the queue with no late playback
- [ ] A test asserts a quarantined region is skipped without blocking the others
- [ ] No spoken or recognized text in any log or event, asserted by test
- [ ] `ios/build.sh` passes
