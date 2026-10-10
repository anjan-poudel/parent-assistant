# NFR-SP-012: Plugin isolation and model-stack invariance

## Metadata
- **Category:** Maintainability / Architecture
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 11 ("The feature ships as an `AssistantPlugin` (`SpotifyPlugin`) with no entanglement beyond the mapped `CommandRouter` seams, preserving the plugin-isolation architecture… No changes to the brain/router model stack") and "Out of scope" (no brain/router model-stack changes); project constitution Architecture Constraint 1 (on-device inference unchanged)

## Description
The feature **must** keep the plugin-isolation architecture and the model stack untouched. Measurable properties:

- **Change surface**: the implementation diff is confined to the new Spotify files (plugin, tool, linking service, credential store), the mapped seams named in the feature constitution (`ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` tool seams, `YouTubeRoute.swift`, `KeywordIntentRule.swift`, `VoiceContactSearchRoute.swift`), `ios/ElderlyAssistant/App/` `AppCoordinator.swift` registration/wiring and `SettingsView.swift`/`SettingsTabs.swift`, the string catalog and `Info.plist` — plus tests. **Zero** changes to brain/model-stack files: no model catalog entries, no model weights, no router-model prompts beyond the pinned intent-wording change (NFR-SP-004).
- **Plugin conformance**: `SpotifyPlugin` conforms to the `AssistantPlugin` contract and registers through the existing plugin registry/`AppCoordinator` pattern; the registry test shows the action declared once.
- **Dormant seams**: every new router seam defaults to dormant (nil) like the `[YOUTUBE]` seams, so pre-existing construction sites compile and behave as before (NFR-SP-006).
- **Removability smoke**: with the Spotify plugin registration removed, the app compiles and the non-music paths behave as today — evidence that the entanglement is only the mapped seams.
- **No new backend**: nothing is provisioned server-side (NFR-SP-003).

## Acceptance criteria

```gherkin
Feature: Plugin isolation and model-stack invariance

  Scenario: The diff is confined to the mapped surfaces
    Given the feature change set
    When the changed files are inspected against the mapped-seam list
    Then no brain/router model-stack file is changed
    And the changes are confined to the new Spotify files, the mapped seams, settings, strings, Info.plist and tests

  Scenario: The plugin conforms and registers once
    Given the app builds its plugin registry
    When the registry is inspected
    Then SpotifyPlugin is present exactly once with the spotify.play action
    And it conforms to the AssistantPlugin contract

  Scenario: Dormant seams preserve the legacy construction path
    Given a router constructed without any Spotify seam
    When the existing scenarios run
    Then the behaviour matches the pre-feature baseline

  Scenario: Removing the registration leaves the rest intact
    Given the Spotify plugin registration is removed
    When the app is built and the non-music paths are exercised
    Then the app compiles and behaves as today on those paths
```

## Related
- FR: FR-SP-006 (plugin), FR-SP-015 (routing intake)
- NFR: NFR-SP-003 (no new egress), NFR-SP-006 (no regression)
