# FR-SP-006: SpotifyPlugin as an AssistantPlugin (YouTubePlugin twin)

## Metadata
- **Area:** Plugin Architecture
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" (ships as an `AssistantPlugin`), Feature Constraint 11 (plugin isolation), "Integration Surfaces" (NEW `ios/ElderlyAssistant/Services/Plugins/` `SpotifyPlugin.swift` — twin of `YouTubePlugin`)

## Description
Spotify **must** ship as an `AssistantPlugin` (`ios/ElderlyAssistant/Services/Plugins/` `SpotifyPlugin.swift`), a structural twin of `YouTubePlugin`:

- it declares the action `spotify.play` (mirroring `youtube.play`) with a `query` entity, a `displayNameKey`, and plugin metadata in the registry shape;
- it executes through the shared tool (`SpotifyTool`, FR-SP-007) and the shared router seams (config store, transport, link opener), not through bespoke networking;
- its failure contract **must** return explicit failures with a localized spoken apology (mirroring `YouTubePlugin`'s `failed(spokenApology:)` lines) — never a silent success;
- it emits observability events in the plugin/action vocabulary without query text (NFR-SP-002);
- it is registered (and its store wired) through the existing `AppCoordinator` registration pattern, and it introduces no entanglement beyond the mapped `CommandRouter` seams (Feature Constraint 11, NFR-SP-012).

Without a linked account or configured credential the plugin **must** remain inert in the honest sense: it does not fire `spotify.play` into a dead end; the router's degradation rules (FR-SP-004, FR-SP-011, FR-SP-012) own the outcome.

## Acceptance criteria

```gherkin
Feature: SpotifyPlugin as an AssistantPlugin

  Scenario: The plugin declares the spotify.play action in the registry
    Given the app registers its plugins
    When the plugin registry is inspected
    Then SpotifyPlugin is registered with the spotify.play action and its query entity
    And the declaration mirrors the YouTubePlugin registry shape

  Scenario: A plugin execution failure is an explicit localized apology
    Given SpotifyPlay is invoked and the tool fails
    When the plugin returns
    Then the result is an explicit failure carrying the localized Spotify apology
    And no silent success is returned

  Scenario: The plugin is dormant without a linked account
    Given no Spotify account is linked
    When the app is constructed
    Then the Spotify plugin cannot produce a fabricated playback claim
    And the degradation path owns the spoken outcome (FR-SP-011, FR-SP-012)
```

## Related
- FR: FR-SP-007 (Spotify tool), FR-SP-008 (linking), FR-SP-015 (routing intake)
- NFR: NFR-SP-002 (log safety), NFR-SP-012 (plugin isolation)
