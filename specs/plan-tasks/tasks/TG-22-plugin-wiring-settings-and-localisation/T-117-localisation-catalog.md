# T-117: Localisation catalog — 20 keys ne/en incl. privacy disclosure (M-2)

## Metadata
- **Group:** [TG-22 — Plugin, Wiring, Settings and Localisation](index.md)
- **Component:** C-SP-11 `Localizable.xcstrings` (+ featured L10n inventory)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-118](T-118-spotify-plugin-and-prompt-fragment.md), [T-120](T-120-settings-surface.md), [T-123](../TG-23-release-gates-security-evidence-and-device-validation/T-123-security-evidence-bundle.md)
- **Requirements:** [FR-SP-016](../../../../define-requirements/FR/FR-SP-016-settings-linking-and-privacy-disclosure.md), [NFR-SP-005](../../../../define-requirements/NFR/NFR-SP-005-localisation.md)

## Description
Adds the full Spotify string inventory to the catalog: all 20 keys with Nepali and English values, including the settings privacy disclosure amended under M-2 so it names the playback activity — music requests and playback control go to Spotify — and the unlink confirmation copy. Both languages complete; parity is enforced by test.

## Acceptance criteria

```gherkin
Feature: Spotify localisation inventory

  Scenario: Every new key exists in both languages
    Given the catalog with the Spotify keys added
    When the parity test walks the new key list
    Then each key has a Nepali and an English value
    And no new key falls back to a raw identifier or the English value in the Nepali locale

  Scenario: The privacy disclosure names the playback activity (M-2)
    Given the settings privacy copy in both languages
    When it is read against the FR-SP-016 disclosure requirement
    Then it states that music requests and playback activity are sent to Spotify
    And it does not claim a narrower data flow than the implemented one

  Scenario: The catalog stays valid against the existing inventory
    Given the pre-existing keys at this baseline
    When the catalog is validated
    Then no pre-existing key value is modified except where the design's edit list says so
    And the catalog parses as a valid string catalog
```

## Implementation notes
- File: `ios/ElderlyAssistant/` + `Resources/Localizable.xcstrings`; the 20-key inventory (§31) includes `spotifySettings.*` rows, link/unlink outcomes and the disclosure paragraph. `L10n.str` / `L10n.fmt` usage mirrors the shipped pattern — no new accessor machinery.
- M-2 reference: security-design-review requires the disclosure copy to name playback activity per FR-SP-016; the copy shipped here is what T-123's disclosure evidence (obligation 7) is checked against, and T-120 consumes the keys.
- F-7 note (optional, recorded): `spotifySettings.removeConfirm` ("Music will use YouTube only.") is slightly stronger than matrix row 8, which can still open the `spotify:search:` hand-off when YouTube cannot serve; if the copy is kept as-is, the deviation from row 8 is recorded here and in T-120, not silently shipped.
- Any key orphaned by the stub deletion is handled exactly as the design's edit list specifies; do not delete keys beyond it.
- Catalog parity test mirrors existing catalog tests; keep it scoped to the new keys plus the unchanged-baseline assertion.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (catalog parity + validity tests)
- [ ] M-2 disclosure wording confirmed against FR-SP-016 in both languages
- [ ] F-7 copy decision recorded explicitly
- [ ] `ios/build.sh` passes for the touched targets
