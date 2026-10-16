# FR-CNR-015: STT pipeline, device permissions and data collection unchanged

## Metadata
- **Area:** Preserved Behaviours / Privacy & Permissions
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope (must not change)" ("STT behavior — the speech pipeline is not part of this feature (the STT-engine invariant stands)"; "Any new device permission; any new data collection beyond the recorded cloud-chat egress") and Safety & Compliance Delta 6 ("Unchanged: STT behavior; emergency-call logic; medication flow; device permissions; the intent prompt bytes; the router/emergency gates"); owner-declared STT-engine invariant ("functioning STT is the invariant of any change; transcript regressions cascade into intent and everything downstream"); workflow `define-requirements` non-goals.

## Description
The feature **must not** touch the speech pipeline, add device permissions, or add data collection:

- **STT untouched.** No change to transcription models, decoding, the transcript path, noise handling or the engine stack selection. The only interaction is that chat turns *consume* transcripts exactly as today; the reply-side changes (persona, decode, guard, routing) begin after the transcript exists.
- **Transcript-regression visibility.** Any observed change in transcript behaviour during this feature is a stop-and-investigate event, not an acceptable side effect — the STT-engine invariant is owner-declared and cascades into intent and every downstream path.
- **No new device permission.** No new `Info.plist` usage key, no new capability prompt; the cloud chat path reuses the existing network access and the existing cloud plumbing (FR-CNR-008).
- **No new data collection** beyond the recorded cloud-chat egress (FR-CNR-010) and the classification-only telemetry this set defines (FR-CNR-007).
- **Medication flow and emergency-call logic unchanged** (also FR-CNR-014 for the routing side).

## Acceptance criteria

```gherkin
Feature: The speech pipeline and permissions are unchanged

  Scenario: The speech pipeline is byte-identical
    Given the pre-change STT path, its configuration and its engine-stack selection
    When the feature's change set is inspected
    Then no STT source file, model selection or decode setting is modified
    And the transcript behaviour for a given audio input is unchanged

  Scenario: No new permission or data collection appears
    Given the shipped feature build
    When the app's permission set and data flows are inspected
    Then no usage-description key was added
    And the only new egress is the consented cloud-chat path
    And no new collection exists beyond the classification-only events this set defines

  Scenario: A transcript regression appears during the work (failure)
    Given a build in which transcription output differs from the pre-change baseline for the same audio
    When the difference is observed
    Then the work stops and the divergence is reported against the STT-engine invariant
    And it is not accepted as an acceptable side effect of this feature
```

## Related
- FR: FR-CNR-010 (egress scope), FR-CNR-014 (safety path), FR-CNR-005 (the guard is not an STT-stage correction)
- NFR: NFR-CNR-011 (release gates and baseline honesty)
