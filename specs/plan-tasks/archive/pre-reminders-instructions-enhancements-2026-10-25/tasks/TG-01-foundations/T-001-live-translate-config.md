# T-001: `LiveTranslateConfig` and `LiveTranslateSettings`

## Metadata
- **Group:** [TG-01 — Foundations](index.md)
- **Component:** C14 — `LiveTranslateConfig` / `LiveTranslateSettings`
- **Agent:** dev
- **Effort:** S
- **Risk:** LOW
- **Depends on:** —
- **Blocks:** every task that reads an operational constant (T-006 … T-030)
- **Requirements:** NFR-LCT-011 (primary), FR-LCT-017, NFR-LCT-002, NFR-LCT-004 (copy owner), CL-8

## Description

Declare the single `Equatable` configuration value that owns **every** operational constant this
feature introduces, with the design's documented defaults and injectable at construction, plus the
two genuinely user-facing settings with persisted state. No component declares its own copy of a
default and no operational literal appears in the pipeline — that is what makes NFR-LCT-011 true
rather than aspirational.

Source: `Services/LiveTranslate/` `LiveTranslateConfig.swift` under `ios/ElderlyAssistant/`.
Tests: `Services/LiveTranslate/` under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Operational parameters and persisted settings

  Scenario: Every parameter resolves from one value with its documented default
    Given the feature's pipeline code
    When it needs the OCR cadence, a matching threshold, a declutter bound, the in-place bounds, the batch bounds, the scene-text bound, the retry count, the deadline grace, the cache bound or the touch-coalescing flag
    Then the value comes from LiveTranslateConfig.default
    And the defaults equal the design's parameter table exactly

  Scenario: The cloud base timeout has exactly one source of truth
    Given the tier-2 deadline derivation
    When the base timeout is read
    Then it is GeminiClient.Config.default.timeoutSeconds (the shipped 25 s)
    And the config's own request-timeout field is documented as derived or removed, so a second divergent value cannot exist (CL-8)

  Scenario: The always-show-original setting persists without a restart
    Given the elder enabled "always show original text"
    When the app is relaunched and a new session opens
    Then the setting is still enabled
    And toggling it takes effect on the next rendered frame

  Scenario: The settings store carries no user content
    Given the persisted settings store
    When its keys and values are inspected
    Then the only feature key holds the always-show-original boolean
    And no recognized or translated text is stored there
```

## Implementation notes

- Parameter names and defaults must match the design's table verbatim: `ocrSampleInterval` 0.25 s,
  `thermalCadenceFactor` 2.0, `thermalStateThreshold` `.serious`, `trackingEnabled` true,
  `regionMatchIoU` 0.3, `regionMatchCentroidDistance` 0.35, `regionAppearPasses` 2,
  `regionMissPasses` 2, `declutterMergeCentroidDistance` 0.06, `declutterMaxRegions` 8,
  `inPlaceMaxSourceWordCount` 3, `overlayMinPointSize` 18, `alwaysShowOriginalDefault` false,
  `cloudDeadlineGraceSeconds` 5, `cloudMaxRetries` 1, `cloudBatchMaxStrings` 12,
  `cloudBatchMaxCharacters` 1200, `sceneTextMaxLength` 120, `translationMaxLengthRatio` 4.0,
  `translationMaxLengthAllowance` 64, `cacheGeneralEntryLimit` 200, `cacheTouchCoalescing` true,
  `disclosureVersion` (placeholder string until the OD3 copy freeze).
- `alwaysShowOriginal` persists through the `UserDefaults` precedent already used for the active
  language; it is a UI preference containing no user content.
- `disclosureVersion` is owned here so the OD3 copy review changes one place. Changing an approved
  copy is a data change plus a bump of this constant; the consent record's version stamp (T-014) is
  what makes a stale grant invalid rather than silently inherited.
- The **cost-governor cap is not owned by this feature** (OD7): `GeminiCostGovernor.softDailyCap`
  is consumed exactly as shipped, with its family-editable range. Do not add a second cap here.
- There is **no user-facing configuration surface** for these parameters in v1. The device-spike
  values for OD1 and OD5 land as edits to this one type (T-030 produces the measurements).
- Pure value type: `Equatable`, no I/O, no singletons; every component that needs a parameter takes
  the config at construction.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test pins the defaults against the design's parameter table, so a silent drift fails
- [ ] A source-level check (test or lint) fails if an operational literal for a configured parameter appears in the feature's pipeline sources
- [ ] `diffReview` note records that no second copy of a default exists
- [ ] `ios/build.sh` passes
