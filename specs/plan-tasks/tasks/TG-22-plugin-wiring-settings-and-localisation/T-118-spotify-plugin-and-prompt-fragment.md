# T-118: SpotifyPlugin and trimmed prompt fragment (C-1)

## Metadata
- **Group:** [TG-22 — Plugin, Wiring, Settings and Localisation](index.md)
- **Component:** C-SP-05 `SpotifyPlugin` (`AssistantPlugin` twin of the YouTube plugin)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-106](../TG-18-spotify-tool-and-deep-link-hardening/T-106-spotify-tool-search-and-play.md), [T-107](../TG-18-spotify-tool-and-deep-link-hardening/T-107-deep-link-grammar-and-hardening.md), [T-110](../TG-19-account-linking-credential-store-and-session/T-110-spotify-account-session.md), [T-117](../TG-22-plugin-wiring-settings-and-localisation/T-117-localisation-catalog.md)
- **Blocks:** [T-119](T-119-app-coordinator-wiring.md), [T-121](../TG-23-release-gates-security-evidence-and-device-validation/T-121-release-log-safety-gate.md)
- **Requirements:** [FR-SP-006](../../../../define-requirements/FR/FR-SP-006-spotifyplugin-assistantplugin-twin.md), [FR-SP-007](../../../../define-requirements/FR/FR-SP-007-spotifytool-search-and-deeplink.md), [NFR-SP-004](../../../../define-requirements/NFR/NFR-SP-004-prompt-budget-preserved.md), [NFR-SP-012](../../../../define-requirements/NFR/NFR-SP-012-plugin-isolation-and-model-stack-invariance.md)

## Description
Implements `SpotifyPlugin` as the `AssistantPlugin` twin of the shipped YouTube plugin: tool id `spotify.play` with the `query` parameter, result shapes mirroring the YouTube precedent, and the cloud-path prompt fragment trimmed under C-1 to at or under the YouTube fragment's measured 341 characters while keeping the required tokens and the L2-D15 sentence that routes general music requests to the music intent.

## Acceptance criteria

```gherkin
Feature: Spotify plugin and prompt fragment

  Scenario: The plugin exposes the play tool and dispatches to SpotifyTool
    Given a linked session and a stubbed tool
    When the plugin executes the spotify.play tool with a query
    Then the tool is invoked with that query and the result shape mirrors the YouTube twin
    And the plugin registers exactly one tool under its id

  Scenario: The prompt fragment stays within the budget (C-1)
    Given the plugin's prompt fragment literal
    When its length is measured
    Then it is at or under the YouTube fragment's 341-character length
    And it still contains the spotify.play tool tokens and the sentence routing general music requests to the music intent

  Scenario: Tool failure surfaces a typed result with no presentation
    Given a tool failure (not linked, empty search, provider failure)
    When the plugin executes
    Then it returns the typed failure result without presenting anything
    And no presenter is dereferenced on the assistant path
```

## Implementation notes
- File: `ios/ElderlyAssistant/` + `Plugins/SpotifyPlugin.swift`; ids, result shapes and nil-presentation behaviour mirror `YouTubePlugin.swift` exactly where the twin contract applies (FR-SP-006).
- C-1: the fragment-size assertion is the guard; the exact §27 text measures 376 characters and must be trimmed to at or under the YouTube fragment's 341, keeping the tool tokens and the L2-D15 routing sentence. The prompt digest and character baseline/ceiling pins in `IntentPromptTests` must remain green (NFR-SP-004).
- Plugin isolation: one plugin, no cross-plugin reach; on-device intent composition is untouched (NFR-SP-012).
- Log discipline: plugin results carry outcome classifications only; no query text in plugin logs (NFR-SP-002).
- Test suite: `SpotifyPluginTests` mirroring `YouTubePluginTests`, including the fragment-length tripwire.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (SpotifyPluginTests)
- [ ] Fragment-length assertion green at or under 341 characters
- [ ] Intent prompt digest and baseline pins unchanged and green
- [ ] No PII in logs — no query text in plugin output or logs
- [ ] `ios/build.sh` passes for the touched targets
