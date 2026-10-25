# FR-RIE-006: Video acceptance limits — 3 minutes, ~200 MB, as provided, unsupported codecs rejected at pick time

## Metadata
- **Area:** Video Constraints
- **Priority:** MUST
- **Source:** Feature constitution OD-1 (RESOLVED 2026-10-25): "video caps 3 minutes / ~200 MB stored as provided (no transcode); an unsupported codec is rejected at pick time with a plain message"; "Fire-Time Playback, Accessibility & Failure Contract" property 5 (plain failure); Instruction Model & Storage Contract property 1.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Decisions 1 and 5, §Instruction Model & Storage Contract property 1, §Fire-Time contract property 5, §Feature Constraints 5. Code surfaces: `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift:113–130` (local, as-written file storage precedent).

## Description
A video selected as an instruction **must** be accepted only if it is at most **3 minutes (180 seconds)** long and at most **~200 MB** (encoded for verification as a hard bound of **200 MiB = 209,715,200 bytes**). Accepted video **must** be stored **as provided** — no on-device transcode, re-encode, or format conversion — and replayed from that stored file. A file that AVKit/AVFoundation cannot play on the supported iOS deployment target (unsupported codec or container) **must** be rejected at pick time with a short, plain-language, localized message; a raw error, OSStatus code, or technical format name **must not** be shown. Rejection **must** leave the caregiver's previous instruction (or unsaved draft) intact (FR-RIE-010, FR-RIE-013). A video exceeding either limit **must** be rejected the same way. The limits **must** be enforced before the file is copied into the instruction store.

## Acceptance criteria

```gherkin
Feature: Only compliant videos are accepted as instructions

  Scenario: A video within both limits is accepted unchanged
    Given a 2-minute, 150 MB video in a codec AVKit supports on the deployment target
    When the caregiver selects it as the instruction
    Then the video is accepted and stored as provided
    And the stored bytes are identical to the selected file (no transcode)
    And no warning or error is shown

  Scenario: A video longer than 3 minutes is rejected (failure)
    Given a 4-minute video
    When the caregiver selects it as the instruction
    Then the video is rejected at pick time with a short plain-language message
    And the previous instruction remains intact

  Scenario: A video larger than the size cap is rejected (failure)
    Given a video larger than 200 MiB
    When the caregiver selects it as the instruction
    Then the video is rejected at pick time with a short plain-language message
    And the previous instruction remains intact

  Scenario: An unsupported codec is rejected with a plain message (failure)
    Given a video file whose codec AVKit cannot play on the deployment target
    When the caregiver selects it as the instruction
    Then the video is rejected at pick time with a short plain-language message
    And no raw error, OSStatus code, or codec name is shown
    And the previous instruction remains intact
```

## Related
- FR: FR-RIE-004 (library pick), FR-RIE-005 (recording), FR-RIE-010 (plain feedback), FR-RIE-013 (transactional replace), FR-RIE-020 (playback fallback)
- NFR: NFR-RIE-004 (PII-free logs), NFR-RIE-007 (storage footprint)
