# NFR-CDP-005: `secondaryCallApp` persistence round-trip reliability

## Metadata
- **Category:** Reliability (Persistence)
- **Priority:** MUST
- **Source:** Frozen design §1 (UserDefaults seam, default `.phone`) and §8 ("Settings persistence: `secondaryCallApp` round-trip + `.phone` default"); feature constitution Feature Constraint 4 and DV-1; workflow `design-l1` scope ("persistence for existing installs (secondaryCallApp absent → GSM)").

## Description
The `secondaryCallApp` preference **must** be durably persisted through the existing house seam. Measurable properties:

- **Round-trip**: for each of the four channels, select → relaunch → the restored value equals the selection in **100%** of runs of the settings-persistence suite (0 mismatches across repeated runs).
- **Default**: a fresh install and an upgraded install without the key resolve to `.phone` in **100%** of runs; an unrecognised raw value also resolves to `.phone`.
- **Immediate durability**: the write is bound to the selection action (`didSet` house pattern) and survives a process kill immediately after selection (relaunch returns the just-selected value).
- **Isolation**: writing `secondaryCallApp` never mutates `defaultCallApp` and vice versa — **0 cross-writes** in the suite; no other stored key changes value on a fallback selection.

## Acceptance criteria

```gherkin
Feature: Fallback preference durability

  Scenario: Every channel round-trips identically
    Given each of FaceTime, phone, Messenger and WhatsApp is selected as the fallback in turn
    When the app relaunches after each selection
    Then the restored secondaryCallApp equals the selection in 100% of runs

  Scenario: Upgraded installs default to GSM
    Given an install whose stored state has no secondaryCallApp key
    When the app launches after the upgrade
    Then the fallback is phone with no user action required

  Scenario: The two preferences are isolated
    Given a stored primary and a stored fallback
    When either preference is re-selected
    Then the other preference's stored value is unchanged
```

## Related
- FR: FR-CDP-003 (the seam), FR-CDP-002 (the picker), FR-CDP-007 (the chain reading it)
- NFR: NFR-CDP-008 (the suite that pins this), NFR-CDP-010 (DV-1 evidence)
