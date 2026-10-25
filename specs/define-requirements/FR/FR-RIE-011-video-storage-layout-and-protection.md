# FR-RIE-011: Video store — dedicated Application Support roots, bare filenames, complete file protection

## Metadata
- **Area:** Storage
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding properties 1–2 (video instructions are app data under a video sibling of the photo layout; model stores only bare file names, never bytes; `.completeFileProtection`; never Photos/shared); OD-5 (RESOLVED 2026-10-25: dedicated `Application Support/InstructionVideos/<entryId>/` for routines and a separate event root; receive-as-is).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract properties 1–2, §Decisions 5, §Feature Constraints 3. Code surfaces: `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift:74–104,113–130,123`; `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:258–272`; `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift:25–45`.

## Description
Video instruction bytes **must** live under a dedicated app-managed root in Application Support: `Application Support/InstructionVideos/<entryId>/` for routine reminders, and a **separate** event root (a sibling such as `Application Support/EventInstructionVideos/<eventId>/`; the exact name belongs to design-l1/l2) for free-form events. They **must not** be mixed into the existing `VisualAids` or `EventPhotos` roots. The encrypted payloads (`RoutineEntry` / `EventExtras`) **must** store only bare file names (or an equivalent bare identifier) — never bytes and never a path. Every video file **must** be written with `.completeFileProtection`. Video instructions **must never** be saved to the Photos library, **must never** appear in the photo picker, and **must never** be exposed through share surfaces. The file format **must** be stored as provided (no transcode; FR-RIE-006).

## Acceptance criteria

```gherkin
Feature: Video instructions are app data under a protected dedicated store

  Scenario: A routine video is stored under the dedicated routine root
    Given a routine reminder with a video instruction
    When the caregiver saves the routine
    Then the video file exists under Application Support/InstructionVideos/<entryId>/
    And the encrypted reminder payload contains only a bare file name

  Scenario: An event video is stored under a separate event root
    Given a free-form event with a video instruction
    When the caregiver saves the event
    Then the video file exists under the dedicated event instruction root
    And it is not stored in EventPhotos or VisualAids
    And the encrypted event extras contain only a bare file name

  Scenario: The video is protected and not exposed outside the app
    Given a saved video instruction
    When the file attributes and the app's media surfaces are inspected
    Then the file reports complete file protection
    And the video is absent from the Photos library
    And no share surface lists the video
```

## Related
- FR: FR-RIE-012 (filename hygiene), FR-RIE-013 (transactional replace), FR-RIE-014 (delete with owner), FR-RIE-022 (not in notification attachments)
- NFR: NFR-RIE-005 (at-rest protection), NFR-RIE-007 (storage footprint)
