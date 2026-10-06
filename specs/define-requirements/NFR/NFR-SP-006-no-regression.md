# NFR-SP-006: No regression to existing flows

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 ("Must-not-break paths") and "Success Criteria" ("Explicit YouTube requests behave exactly as before — existing route, plugin, and golden tests hold"); project constitution Standards (Quality)

## Description
The feature changes only what FR-SP-001 through FR-SP-016 require. Measurable properties:

- **Explicit YouTube unchanged**: `YouTubeRouteTests`, `YouTubePluginTests` and `CommandRouterYouTubeTests` pass; 'युट्युबमा गीत चलाऊ' reaches YouTube with the same route, action and lines (FR-SP-005).
- **Golden corpus holds**: the pinned music golden block in `ios/ElderlyAssistantTests/` `Services/Voice/GoldenCorpus.swift` (currently 15 utterances pinned to intent `music`, lines 142–157; the feature constitution refers to "16 utterances" — the implementation reconciles the count against the source and records the result) still resolves to intent `music`; any entry that the feature deliberately supersedes moves **with its new expectation recorded alongside** — no silent golden churn.
- **Other intents unchanged**: non-music stub intents (health query `router.healthNotAvailable`, video `router.featureNotYet`) and unrelated domains behave exactly as before; the touched suites listed in the feature constitution (`KeywordIntentRuleTests`, `VoiceContactSearchRouteTests`, `SettingsTabMappingTests`, `StoragePlacementTests`, plus the new Spotify suites) pass.
- **Dormant-seam discipline**: the existing router construction sites and legacy tests keep compiling and behaving as before when the Spotify seams are dormant (nil), mirroring the `[YOUTUBE]` seam pattern.
- **Project baseline recorded**: the unit gate runs against the project's known baseline; pre-existing failures unrelated to this feature are recorded as such (not silently included or excluded).

## Acceptance criteria

```gherkin
Feature: No regression to existing behaviours

  Scenario: The pinned YouTube suites pass unchanged
    Given the feature is built
    When the YouTube route, plugin and router test suites run
    Then they pass with no change other than recorded deliberate supersessions

  Scenario: The pinned music golden entries still resolve to the music intent
    Given the feature is built
    When the golden corpus music entries are exercised
    Then each entry resolves to intent "music"
    And any amended expectation is recorded alongside its entry

  Scenario: Non-music stubs keep their honest lines
    Given the feature is built
    When the health-query and video stub paths are exercised
    Then they speak their existing lines (router.healthNotAvailable, router.featureNotYet)
    And the music feature does not alter them

  Scenario: Dormant seams preserve legacy behaviour
    Given a router constructed without Spotify seams (nil)
    When an existing test scenario is exercised
    Then behaviour matches the pre-feature baseline
```

## Related
- FR: FR-SP-001 (flip), FR-SP-005 (explicit YouTube unchanged), FR-SP-013, FR-SP-014, FR-SP-015
- NFR: NFR-SP-004 (prompt budget), NFR-SP-012 (plugin isolation)
