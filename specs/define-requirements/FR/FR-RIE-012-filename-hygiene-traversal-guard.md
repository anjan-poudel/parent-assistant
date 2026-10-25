# FR-RIE-012: Filename hygiene — plain names only; a hand-edited payload cannot escape the store root

## Metadata
- **Area:** Storage Hardening
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding property 7 (store plain, traversal-free file names under a per-entry directory, matching `VisualAidStore.fileURL` / `isPlainFilename`; a hand-edited payload must never smuggle a path out of the store root).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract property 7. Code surfaces: `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift:142,237–249`.

## Description
The instruction store **must** accept, persist, and resolve only plain, traversal-free file names under the per-owner directory, matching the `VisualAidStore.fileURL` / `isPlainFilename` discipline: no path separators, no `..`, no absolute paths, and no empty names. A payload containing a path or traversal sequence (for example `../EventPhotos/secret.jpg`) **must** fail safe: no file outside the instruction store root is read, the instruction is treated as missing, and the fire-time plain fallback (FR-RIE-020) is shown. The rejected lookup **must** be logged PII-free (event type and outcome only; no file name or path — NFR-RIE-004).

## Acceptance criteria

```gherkin
Feature: Instruction file names cannot escape the store root

  Scenario: A traversal payload is rejected and the reminder still presents (failure)
    Given a hand-edited routine payload whose instruction file name is "../EventPhotos/secret.jpg"
    When the reminder fires and the instruction is resolved
    Then no file outside the instruction store root is read
    And the instruction is treated as missing
    And the fired screen shows the plain unavailable message with the reminder title and time

  Scenario: A normal bare file name round-trips
    Given a stored video instruction with a plain file name
    When the instruction is loaded
    Then the file resolves inside the owner's instruction directory
    And the video is offered for playback

  Scenario: An absolute path is rejected the same way (edge)
    Given a payload whose instruction file name is an absolute path
    When the instruction is resolved
    Then the path is rejected as not a plain file name
    And no file outside the store root is accessed
```

## Related
- FR: FR-RIE-011 (store), FR-RIE-020 (plain fallback)
- NFR: NFR-RIE-004 (PII-free logging)
