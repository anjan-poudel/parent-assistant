# T-005: String Catalog Entries and Camera Purpose String

## Metadata
- **Group:** [TG-01 — Foundations](index.md)
- **Component:** String Catalog + `Info.plist` `NSCameraUsageDescription` + the C13 view copy surfaces
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** T-008, T-015, T-021, T-023, T-027
- **Requirements:** NFR-LCT-004, FR-LCT-002 (camera disclosure), CL-8 · OD3 (draft only)

## Description

Externalise every new user-visible string in the String Catalog with **Nepali first**, including the
C12 command phrase table in English and Nepali, and draft the `NSCameraUsageDescription` update that
discloses the live-translation use and the conditional text-only cloud fallback. The shipped purpose
string describes medication verification and appliance photos only, so the feature cannot satisfy
FR-LCT-002 without this change — but the **review** of the copy is an owner action at `final-sign-off`,
not agent work.

Sources: `ios/ElderlyAssistant/` `Resources/Localizable.xcstrings` and `ios/ElderlyAssistant/`
`Info.plist`. No Swift source is produced here.

## Acceptance criteria

```gherkin
Feature: Localised copy and purpose string

  Scenario: Every new user-visible string is a catalog entry with Nepali first
    Given the feature's user-visible strings (empty-state hint, pending state, unavailable indication, consent prompt, cloud-activity label, toggle label, close control, command phrases, degraded messages)
    When the String Catalog is inspected
    Then each string has an entry with a Nepali (Devanagari) translation
    And no user-visible string is a Swift literal (NFR-LCT-004)

  Scenario: The command phrases exist in both languages
    Given the C12 command vocabulary (read-all, stop, set-show-original on and off, repeat-last, close)
    When the phrase table is inspected
    Then each command has an English and a Nepali entry in the catalog
    And no phrase is a Swift literal (NFR-LCT-004)

  Scenario: The camera purpose string discloses live translation and the conditional text send
    Given the shipped purpose string
    When it is inspected
    Then it states that live translation uses the camera
    And it states that recognized text — never images — may be used by the assistant's cloud service when the dictionary cannot translate it (FR-LCT-002)
    And the existing medication-verification and appliance-photo disclosure is still present

  Scenario: The unavailable wording stays true in every failure case
    Given the copy for the degraded state
    When it is read
    Then it does not claim a network cause specifically
    And it remains true when the cause is a spent daily budget, withheld consent or an unreadable consent record

  Scenario: The draft copy is version-stamped for the consent record
    Given the drafted consent and disclosure copy
    When `disclosureVersion` in `LiveTranslateConfig` is read
    Then it identifies this copy revision
    And a later approved copy change bumps it, so a stale grant is invalidated rather than inherited (OD3)
```

## Implementation notes

- Nepali first in the catalog; overlay translations and spoken output reuse the existing Devanagari
  rendering and the active-language Piper voice — no new font, shaping or voice work.
- The consent prompt copy must be plain language, in the active language, and must not read as a
  default-on or buried setting; it is presented at the first cloud need (T-015 consumes it).
- These strings are a **draft for owner review** (OD3). The copy review, the purpose-string approval
  and the App Store submission gate are owner actions; the T2 `final-sign-off` gate verifies them. Do
  not present this task as satisfying the review.
- The wording for a degraded region must cover all four reasons the elder can see (no network,
  provider not configured, consent withheld, budget spent) without naming a wrong cause — the design
  states degradation as "original text plus an honest unavailable indication".
- Do not edit any existing catalog entry except to add the new keys; do not weaken the existing
  purpose-string disclosures.

## Definition of done
- [ ] Copy and plist change reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (a catalog-completeness test over the feature's string keys)
- [ ] Every new key is reachable from the feature's code paths by key, not by literal
- [ ] The copy is marked in the change description as a draft awaiting the owner's OD3 review
- [ ] `ios/build.sh` passes
