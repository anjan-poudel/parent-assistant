# NFR-RIE-007: Storage footprint — one video per owner, ≤200 MiB, zero orphans after replace/delete

## Metadata
- **Category:** Storage / Reliability
- **Priority:** MUST
- **Source:** Feature constitution OD-1 (video caps 3 minutes / ~200 MB) and OD-5 (dedicated roots), both RESOLVED 2026-10-25; "Instruction Model & Storage Contract" binding properties 1 and 5 (delete with the owner, no orphans); "Fire-Time ... Contract" property 1 (no per-occurrence copy).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Decisions 1 and 5, §Instruction Model & Storage Contract properties 1, 4 and 5, §Feature Constraints 3. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineScheduler.swift:111–117`; `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:293–315,396–431`.

## Description
In v1 **zero or one** instruction video file must exist per routine entry or event, and each file **must** respect the ~200 MiB cap (FR-RIE-006: hard bound 209,715,200 bytes). Every replace and delete operation **must** leave **zero orphan files** under the instruction roots (verified by directory scan). Re-arming or editing other fields **must not** create per-occurrence or per-re-arm video copies. The per-owner directory **must** be at most the single accepted file plus negligible metadata.

Measurable targets: after N replacements, exactly 1 video file and ≤200 MiB for the owner; after delete or vanished-event reconcile, 0 files for the owner; after re-arm or time edit, the file count is unchanged.

## Acceptance criteria

```gherkin
Feature: Instruction storage stays bounded and orphan-free

  Scenario: Repeated replacements leave exactly one file
    Given a routine reminder whose video instruction is replaced five times
    When the store is scanned
    Then exactly one video file exists for that reminder
    And its size is at most 200 MiB

  Scenario: Delete and reconcile leave zero files
    Given a routine reminder and a vanished free-form event, each with a video instruction
    When the routine is deleted and the event is reconciled away
    Then zero instruction video files remain for either owner

  Scenario: Re-arming does not duplicate the video
    Given a routine reminder with a video instruction
    When its time is edited and the reminder is re-armed
    Then the number of video files for the reminder is unchanged
```

## Related
- FR: FR-RIE-006 (limits), FR-RIE-013 (replace), FR-RIE-014 (delete), FR-RIE-022 (no attachment copies)
- NFR: NFR-RIE-005 (at-rest protection)
