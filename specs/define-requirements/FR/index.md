# Functional Requirements — Spotify Music Integration (v1)

17 functional requirements. IDs are namespaced `FR-SP-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention the live-camera-translation feature uses with `FR-LCT-NNN`, the dementia supplement
with `FR-DNN` and the profile-interview feature with `FR-PI-NNN`. This page covers the
`spotify-music-integration` set (`FR-SP-*`) only; the earlier feature files remain in this folder
and are not part of this feature's requirements or lock.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-SP-001](FR-SP-001-music-requests-start-real-playback.md) | Music requests start real playback (stub replacement) | Music Playback / Router | MUST |
| [FR-SP-002](FR-SP-002-both-provider-search.md) | Both-provider search for music requests | Provider Selection | MUST |
| [FR-SP-003](FR-SP-003-spotify-preferred-when-linked-and-capable.md) | Spotify preferred whenever linked and capable | Provider Selection | MUST |
| [FR-SP-004](FR-SP-004-youtube-fallback-when-spotify-cannot-serve.md) | YouTube fallback when Spotify cannot serve | Provider Selection / Degradation | MUST |
| [FR-SP-005](FR-SP-005-explicit-youtube-requests-unchanged.md) | Explicit YouTube requests unchanged | No-Regression / Routing | MUST |
| [FR-SP-006](FR-SP-006-spotifyplugin-assistantplugin-twin.md) | SpotifyPlugin as an AssistantPlugin (YouTubePlugin twin) | Plugin Architecture | MUST |
| [FR-SP-007](FR-SP-007-spotifytool-search-and-deeplink.md) | SpotifyTool search and spotify: deep-link construction | Spotify Tool | MUST |
| [FR-SP-008](FR-SP-008-spotify-account-linking-by-caregiver.md) | Spotify account linking by the caregiver (OAuth) | Account Linking | MUST |
| [FR-SP-009](FR-SP-009-encrypted-spotify-credential-store.md) | Encrypted Spotify credential and account store | Credential Storage | MUST |
| [FR-SP-010](FR-SP-010-unlink-wipes-credentials-and-revokes.md) | Unlink wipes credentials and revokes access | Account Linking / Security | MUST |
| [FR-SP-011](FR-SP-011-free-tier-deeplink-degradation.md) | Free-tier degradation to the spotify: deep-link fallback | Degradation | MUST |
| [FR-SP-012](FR-SP-012-honest-outcomes-no-silent-failure.md) | Honest localized outcomes — no silent failure on any path | Degradation / Honesty | MUST |
| [FR-SP-013](FR-SP-013-keyword-intent-rule-music-domain.md) | Deterministic music-domain rule in KeywordIntentRule | Intent Routing (no-model path) | MUST |
| [FR-SP-014](FR-SP-014-contact-search-veto-parity.md) | Music-request veto parity in VoiceContactSearchRoute | Intent Routing | MUST |
| [FR-SP-015](FR-SP-015-music-request-intake-in-route-ladder.md) | Music-request intake in the voice route ladder | Intent Routing | MUST |
| [FR-SP-016](FR-SP-016-settings-linking-and-privacy-disclosure.md) | Settings linking, status surface and privacy disclosure | Settings / Privacy | MUST |
| [FR-SP-017](FR-SP-017-device-validation-checklist-recorded-and-passed.md) | Device-validation checklist recorded and passed (DV-* completion gate) | Validation / Completion Gate | MUST |

## Areas
Music Playback / Router (1), Provider Selection (2), Provider Selection / Degradation (1),
No-Regression / Routing (1), Plugin Architecture (1), Spotify Tool (1), Account Linking (1),
Account Linking / Security (1), Credential Storage (1), Degradation (1), Degradation / Honesty (1),
Intent Routing (no-model path) (1), Intent Routing (2), Settings / Privacy (1),
Validation / Completion Gate (1).

## Traceability anchors
Every requirement traces to the feature constitution (Feature Purpose & Scope, Feature
Constraints 1–12, the routing & degradation contract, the amendment record, the DV-* completion
gate) and/or the `define-requirements` scope comment in `specs/spotify-music-integration/workflow.yaml`.
Nothing is derived from outside those sources; the supersession of `requirements.md`'s Post-MVP
music placement (lines 675–676) is recorded in [FR-SP-001](FR-SP-001-music-requests-start-real-playback.md).

## Related
- [NFR index](../NFR/index.md) — 12 non-functional requirements
- [Requirements index](../index.md)
- [Consolidated copy](../../define-requirements.md)
