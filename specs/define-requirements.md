# Requirements — Spotify Music Integration

**Project:** Elderly AI Assistant · **Feature:** `spotify-music-integration` (v1) ·
**Branch:** `feat/spotify-music-integration` (worktree `elderly-ai-assistant-spotify-music-integration`)
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-10-06 · **Status:** submitted for owner HIL approval (risk tier T1, per the feature
workflow's `define-requirements` task); no owner amendment recorded at lock time — the locked
snapshot in `define-requirements.lock.yaml` is the drift-detection baseline.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file per
requirement, with index files at each level. Both are generated from the same content; the
per-requirement files are the unit of change, this document plus the lock file are the snapshot
downstream tasks (`design-l1`, `design-l2`, `review-l2`, `security-design-review`, `plan-tasks`,
`implement`, `security-test`, `final-sign-off`) consume.

**ID convention.** Requirement IDs are namespaced `FR-SP-NNN` / `NFR-SP-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`) and the dementia
supplement uses (`FR-DNN`). One file per requirement; every requirement carries at least one
Gherkin scenario, and every security-relevant requirement carries a failure scenario.

**Supersession note.** `requirements.md` lines 675–676 list "Music and bhajan playback" as
Post-MVP. That placement is superseded by this feature: the project constitution is the operative
document, and its 2026-10-06 amendment adds Spotify to Architecture Constraint 1's permitted
integrations and to the Required-integrations list (recorded in
`specs/spotify-music-integration/constitution.md`). The supersession is carried by FR-SP-001.

## Summary

- **Functional requirements: 17** (`FR-SP-001` … `FR-SP-017`)
- **Non-functional requirements: 12** (`NFR-SP-001` … `NFR-SP-012`)
- **Areas covered:** Music Playback / Router, Provider Selection, Degradation (free tier, unlinked
  account, network failure, empty search), Spotify Tool and deep links, Plugin Architecture,
  Account Linking (caregiver OAuth), Credential Storage, Intent Routing (deterministic keyword
  rule, contact-search veto, route-ladder intake), Settings / Privacy Disclosure, Validation /
  Completion Gate. NFR categories: Performance, Privacy, Security, Reliability, Maintainability,
  Localisation, Accessibility, Compliance.
- **v1 scope:** replace the first-class music stub (`router.musicStub`, `case .music:` in
  `ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` ~line 2640) with real playback
  (FR-SP-001); search both providers with Spotify winning whenever linked and capable
  (FR-SP-002/003), YouTube for explicit YouTube requests (FR-SP-005) and the Spotify-cannot-serve
  fallback (FR-SP-004); `SpotifyPlugin` + `SpotifyTool` + caregiver account linking + encrypted
  credential store (FR-SP-006 … FR-SP-010); honest degradation for free tier / unlinked / network
  failure / empty search with the `spotify:` deep-link fallback (FR-SP-011/012); deterministic
  routing work (FR-SP-013/014/015); Settings linking/status with the privacy disclosure
  (FR-SP-016); and the DV-* device-validation completion gate (FR-SP-017).
- **Primary sources of truth:** `specs/spotify-music-integration/constitution.md` (feature
  constitution — Purpose & Scope, the routing & degradation contract, Feature Constraints 1–12,
  the 2026-10-06 amendment record, Open Decisions OD-S1/S2/S3, the DV-* completion gate);
  `specs/spotify-music-integration/workflow.yaml` (the `define-requirements` scope comment);
  project `constitution.md` (amended 2026-10-06: Architecture Constraint 1 and the
  Required-integrations list).
- **Read-only stakeholder briefs:** `requirements.md` — its §4 "Out of Scope — Post-MVP" table
  lists "Music and bhajan playback" at lines 675–676 (superseded, see above).
  `requirements-dementia-supplement.md` is context only; it changes nothing here.

## Contents

- [`define-requirements/index.md`](define-requirements/index.md) — top-level feature index
- [`define-requirements/FR/index.md`](define-requirements/FR/index.md) — functional requirement
  list (17 files: `define-requirements/FR/FR-SP-NNN-*.md`)
- [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md) — non-functional
  requirement list (12 files: `define-requirements/NFR/NFR-SP-NNN-*.md`)
- [`define-requirements.lock.yaml`](define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (contract `requirements_lock`)
- Sections below: [Functional requirements](#functional-requirements) ·
  [Non-functional requirements](#non-functional-requirements) ·
  [Open decisions](#open-decisions) · [Out of scope](#out-of-scope) ·
  [How this set is verified downstream](#how-this-set-is-verified-downstream)

The `define-requirements/FR/` and `define-requirements/NFR/` folders also still contain the
previously shipped live-camera-translation (`FR-LCT-*`, `NFR-LCT-*`) and profile-interview
(`FR-PI-*`, `NFR-PI-*`) requirement files, left in place untouched; the indexes, this document and
the lock cover the `spotify-music-integration` set only.

### Requirement index

| ID | Title | Area / Category | Priority | File |
|----|-------|-----------------|----------|------|
| [FR-SP-001](define-requirements/FR/FR-SP-001-music-requests-start-real-playback.md) | Music requests start real playback (stub replacement) | Music Playback / Router | MUST | `FR-SP-001-music-requests-start-real-playback.md` |
| [FR-SP-002](define-requirements/FR/FR-SP-002-both-provider-search.md) | Both-provider search for music requests | Provider Selection | MUST | `FR-SP-002-both-provider-search.md` |
| [FR-SP-003](define-requirements/FR/FR-SP-003-spotify-preferred-when-linked-and-capable.md) | Spotify preferred whenever linked and capable | Provider Selection | MUST | `FR-SP-003-spotify-preferred-when-linked-and-capable.md` |
| [FR-SP-004](define-requirements/FR/FR-SP-004-youtube-fallback-when-spotify-cannot-serve.md) | YouTube fallback when Spotify cannot serve | Provider Selection / Degradation | MUST | `FR-SP-004-youtube-fallback-when-spotify-cannot-serve.md` |
| [FR-SP-005](define-requirements/FR/FR-SP-005-explicit-youtube-requests-unchanged.md) | Explicit YouTube requests unchanged | No-Regression / Routing | MUST | `FR-SP-005-explicit-youtube-requests-unchanged.md` |
| [FR-SP-006](define-requirements/FR/FR-SP-006-spotifyplugin-assistantplugin-twin.md) | SpotifyPlugin as an AssistantPlugin (YouTubePlugin twin) | Plugin Architecture | MUST | `FR-SP-006-spotifyplugin-assistantplugin-twin.md` |
| [FR-SP-007](define-requirements/FR/FR-SP-007-spotifytool-search-and-deeplink.md) | SpotifyTool search and spotify: deep-link construction | Spotify Tool | MUST | `FR-SP-007-spotifytool-search-and-deeplink.md` |
| [FR-SP-008](define-requirements/FR/FR-SP-008-spotify-account-linking-by-caregiver.md) | Spotify account linking by the caregiver (OAuth) | Account Linking | MUST | `FR-SP-008-spotify-account-linking-by-caregiver.md` |
| [FR-SP-009](define-requirements/FR/FR-SP-009-encrypted-spotify-credential-store.md) | Encrypted Spotify credential and account store | Credential Storage | MUST | `FR-SP-009-encrypted-spotify-credential-store.md` |
| [FR-SP-010](define-requirements/FR/FR-SP-010-unlink-wipes-credentials-and-revokes.md) | Unlink wipes credentials and revokes access | Account Linking / Security | MUST | `FR-SP-010-unlink-wipes-credentials-and-revokes.md` |
| [FR-SP-011](define-requirements/FR/FR-SP-011-free-tier-deeplink-degradation.md) | Free-tier degradation to the spotify: deep-link fallback | Degradation | MUST | `FR-SP-011-free-tier-deeplink-degradation.md` |
| [FR-SP-012](define-requirements/FR/FR-SP-012-honest-outcomes-no-silent-failure.md) | Honest localized outcomes — no silent failure on any path | Degradation / Honesty | MUST | `FR-SP-012-honest-outcomes-no-silent-failure.md` |
| [FR-SP-013](define-requirements/FR/FR-SP-013-keyword-intent-rule-music-domain.md) | Deterministic music-domain rule in KeywordIntentRule | Intent Routing (no-model path) | MUST | `FR-SP-013-keyword-intent-rule-music-domain.md` |
| [FR-SP-014](define-requirements/FR/FR-SP-014-contact-search-veto-parity.md) | Music-request veto parity in VoiceContactSearchRoute | Intent Routing | MUST | `FR-SP-014-contact-search-veto-parity.md` |
| [FR-SP-015](define-requirements/FR/FR-SP-015-music-request-intake-in-route-ladder.md) | Music-request intake in the voice route ladder | Intent Routing | MUST | `FR-SP-015-music-request-intake-in-route-ladder.md` |
| [FR-SP-016](define-requirements/FR/FR-SP-016-settings-linking-and-privacy-disclosure.md) | Settings linking, status surface and privacy disclosure | Settings / Privacy | MUST | `FR-SP-016-settings-linking-and-privacy-disclosure.md` |
| [FR-SP-017](define-requirements/FR/FR-SP-017-device-validation-checklist-recorded-and-passed.md) | Device-validation checklist recorded and passed (DV-* completion gate) | Validation / Completion Gate | MUST | `FR-SP-017-device-validation-checklist-recorded-and-passed.md` |
| [NFR-SP-001](define-requirements/NFR/NFR-SP-001-provider-search-responsiveness.md) | Provider search responsiveness and timeout budget | Performance | MUST | `NFR-SP-001-provider-search-responsiveness.md` |
| [NFR-SP-002](define-requirements/NFR/NFR-SP-002-log-safety.md) | Log safety — no credentials, queries or provider bodies in logs | Privacy / Security | MUST | `NFR-SP-002-log-safety.md` |
| [NFR-SP-003](define-requirements/NFR/NFR-SP-003-no-new-network-egress.md) | No new network egress; music stays off any cloud LLM | Privacy | MUST | `NFR-SP-003-no-new-network-egress.md` |
| [NFR-SP-004](define-requirements/NFR/NFR-SP-004-prompt-budget-preserved.md) | Prompt token budget preserved | Reliability / Maintainability | MUST | `NFR-SP-004-prompt-budget-preserved.md` |
| [NFR-SP-005](define-requirements/NFR/NFR-SP-005-localisation.md) | Localisation of all Spotify strings (ne/en) | Localisation | MUST | `NFR-SP-005-localisation.md` |
| [NFR-SP-006](define-requirements/NFR/NFR-SP-006-no-regression.md) | No regression to existing flows | Reliability | MUST | `NFR-SP-006-no-regression.md` |
| [NFR-SP-007](define-requirements/NFR/NFR-SP-007-credential-encryption-at-rest.md) | Credential and token encryption at rest | Security | MUST | `NFR-SP-007-credential-encryption-at-rest.md` |
| [NFR-SP-008](define-requirements/NFR/NFR-SP-008-deeplink-uri-hardening.md) | Deep-link URI construction hardening | Security | MUST | `NFR-SP-008-deeplink-uri-hardening.md` |
| [NFR-SP-009](define-requirements/NFR/NFR-SP-009-oauth-redirect-and-token-lifecycle.md) | OAuth redirect validation and token lifecycle | Security | MUST | `NFR-SP-009-oauth-redirect-and-token-lifecycle.md` |
| [NFR-SP-010](define-requirements/NFR/NFR-SP-010-accessibility-of-new-surfaces.md) | Accessibility of the new touch surfaces | Accessibility | MUST | `NFR-SP-010-accessibility-of-new-surfaces.md` |
| [NFR-SP-011](define-requirements/NFR/NFR-SP-011-compliance-and-release-gates.md) | Compliance and release gates | Compliance | MUST | `NFR-SP-011-compliance-and-release-gates.md` |
| [NFR-SP-012](define-requirements/NFR/NFR-SP-012-plugin-isolation-and-model-stack-invariance.md) | Plugin isolation and model-stack invariance | Maintainability / Architecture | MUST | `NFR-SP-012-plugin-isolation-and-model-stack-invariance.md` |

## Functional requirements

### FR-SP-001: Music requests start real playback (stub replacement)

#### Metadata
- **Area:** Music Playback / Router
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" (the broken-to-working flip), "Music Request Routing & Degradation Contract" and "Success Criteria" (DV-1); workflow `define-requirements` scope comment; the current stub at `ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` (`case .music:`, ~line 2640, speaking `router.musicStub`)

#### Description
A voice music request that reaches the music intent today **must** start a real playback flow instead of the first-class stub. The `case .music:` branch in `ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` currently emits a `command_music_stub` event and speaks `router.musicStub` ("Music isn't ready yet. Coming soon." / "संगीत सुविधा अहिले तयार छैन। चाँडै आउनेछ।"). That branch **must** be replaced by the real music path:

- the request is resolved through both-provider search (FR-SP-002) with Spotify preferred whenever linked and capable (FR-SP-003);
- the outcome is a real one — playback control, the `spotify:` deep-link fallback (FR-SP-011), the YouTube fallback where YouTube can serve (FR-SP-004), or an explicit localized line (FR-SP-012);
- the user **must never** hear the stub wording ("Music isn't ready yet" / "संगीत सुविधा अहिले तयार छैन") on a music request in a build that ships this feature.

The neighbouring stub intents are untouched: the health-query stub (`router.healthNotAvailable`) and the video stub (`router.featureNotYet`) keep their current honest lines (NFR-SP-006).

#### Acceptance criteria

```gherkin
Feature: Music requests start real playback

  Scenario: A bare Nepali music request produces a real outcome, not the stub
    Given the assistant is configured with at least one provider able to serve music
    When the user says "भजन बजाऊ"
    Then the request enters the music playback path
    And a real outcome is produced (playback started, a provider deep link opened, or a provider fallback line spoken)
    And the user does not hear the "Music isn't ready yet" stub line

  Scenario: The English bare music request behaves the same
    Given the assistant is configured as above
    When the user says "play a song"
    Then the request enters the music playback path and produces a real outcome

  Scenario: A total failure is still an explicit spoken outcome, never silence
    Given neither provider is reachable
    When the user says "गीत चलाऊ"
    Then the assistant speaks an explicit localized failure line
    And no silent success and no silent failure occurs

  Scenario: The stub wording is not reachable through the music intent
    Given the feature is built
    When every music-path branch is exercised in tests
    Then no music branch speaks the stub wording
    And the non-music stub intents keep their existing lines
```

#### Related
- NFR: NFR-SP-006 (no regression), NFR-SP-012 (plugin isolation)
- Depends on: FR-SP-002 (both-provider search), FR-SP-003 (Spotify preference)

### FR-SP-002: Both-provider search for music requests

#### Metadata
- **Area:** Provider Selection
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 9 (preference semantics — top-level rule) and "Music Request Routing & Degradation Contract" (routing table); DV-2

#### Description
For a music request — a bare request such as 'भजन बजाऊ', 'गीत चलाऊ' or 'play a song' with no explicit YouTube marker — the system **must** search both providers before selection:

- **Spotify** via the Spotify Web API, when the account is linked and Spotify credentials are configured (FR-SP-008, FR-SP-009);
- **YouTube** via the existing YouTube tool, when a YouTube API key is configured (keyed lookup) and, where YouTube is the selected provider, through its existing search-deeplink path.

A provider that cannot be asked (unlinked account, no credential, in-flight failure) **must not** block the other provider's search; the failure is recorded and resolved by the degradation rules (FR-SP-004, FR-SP-011, FR-SP-012). The search **must** use the user's spoken query (or its resolved music query) and **must** treat every provider response as untrusted data (NFR-SP-008). The recorded observability events carry no query text (NFR-SP-002).

#### Acceptance criteria

```gherkin
Feature: Both-provider search for music requests

  Scenario: A music request searches both configured providers
    Given a Spotify account is linked with credentials configured
    And a YouTube API key is configured
    When the user says "भजन बजाऊ"
    Then a Spotify search and a YouTube search are both attempted for the request
    And the recorded selection shows which provider won

  Scenario: An unavailable provider does not block the other
    Given the Spotify account is not linked
    And a YouTube API key is configured
    When the user says "गीत चलाऊ"
    Then the YouTube search proceeds
    And the outcome is resolved by the Spotify-cannot-serve fallback rules

  Scenario: Neither provider can be asked
    Given no Spotify account is linked and no YouTube key is configured
    When the user says "play a song"
    Then no silent outcome occurs
    And an explicit localized line is spoken (FR-SP-012)
```

#### Related
- FR: FR-SP-003 (preference), FR-SP-004 (YouTube fallback), FR-SP-007 (Spotify search tool)
- NFR: NFR-SP-003 (no new egress), NFR-SP-008 (untrusted provider results)
- Depends on: FR-SP-001 (real playback path)

### FR-SP-003: Spotify preferred whenever linked and capable

#### Metadata
- **Area:** Provider Selection
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 9 (top-level rule: "Spotify wins whenever it is linked and capable"); "Music Request Routing & Degradation Contract" (routing table row 1); DV-2

#### Description
For a music request, Spotify **must** win the selection whenever it is linked and capable of serving the request. "Linked and capable" means: the account is linked and credentials are present (FR-SP-008, FR-SP-009), the Spotify search resolves a usable result for the request (FR-SP-007), and at least one Spotify outcome is available — remote playback control or the `spotify:` deep-link fallback (FR-SP-011). The spoken confirmation **must** name the provider that actually served the request in the user's language, for example:

- playing: "स्पोटिफाइमा %@ चलाउँदैछु।" / "Playing %@ on Spotify." (illustrative copy, mirroring `youtube.playing`);
- deep-link fallback: "स्पोटिफाइ खोल्दैछु — त्यहाँ बजाउनुहोस्।" / "Opening Spotify — play it there." (illustrative; exact copy for degradation paths is OD-S3).

Spotify **must not** be preferred into silence: when Spotify is linked but cannot serve (empty search, failure, free tier), selection falls through per FR-SP-004 and FR-SP-011, and the outcome is always spoken (FR-SP-012). Explicit YouTube requests are not subject to this preference (FR-SP-005).

#### Acceptance criteria

```gherkin
Feature: Spotify preferred whenever linked and capable

  Scenario: Spotify wins a music request while linked and capable
    Given a Spotify account is linked and capable of serving the request
    When the user says "भजन बजाऊ"
    Then the Spotify result is selected
    And the spoken confirmation names Spotify

  Scenario: A linked Spotify that cannot serve falls through, never into silence
    Given a Spotify account is linked
    And the Spotify search yields no usable result for the request
    When the user says "गीत चलाऊ"
    Then the request falls through to the fallback rules (FR-SP-004, FR-SP-011)
    And an explicit spoken outcome is produced

  Scenario: The preference does not capture explicit YouTube requests
    Given a Spotify account is linked and capable
    When the user says "युट्युबमा गीत चलाऊ"
    Then YouTube serves the request exactly as before (FR-SP-005)
    And the Spotify preference is not applied
```

#### Related
- FR: FR-SP-002 (both-provider search), FR-SP-004 (YouTube fallback), FR-SP-005 (explicit YouTube unchanged), FR-SP-011 (deep-link fallback)
- NFR: NFR-SP-006 (no regression)

### FR-SP-004: YouTube fallback when Spotify cannot serve

#### Metadata
- **Area:** Provider Selection / Degradation
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 ("Spotify-unavailable/unlinked falls back to YouTube") and the routing table ("Spotify cannot serve the request → YouTube fallback where it can serve; otherwise an honest localized line"); DV-2

#### Description
When Spotify cannot serve a music request — unlinked account, missing credentials, empty search result, provider failure, or free-tier remote-control unavailability — and YouTube can serve it, the request **must** fall back to the existing YouTube path:

- the request goes through the existing YouTube route/plugin behaviour (`youtube.play`, `youtube.*` localized lines) with no new YouTube-side semantics;
- the fallback **must** follow the pinned YouTube behaviour (FR-SP-005) so the fallback result is the same YouTube outcome the user would get from an explicit YouTube request;
- the spoken line names YouTube as the serving provider (mirroring `youtube.playing` / `youtube.openingSearch` / `youtube.notFound`).

When neither provider can serve, the request **must** end in an explicit localized line (FR-SP-012), never silence. The exact precedence between the free-tier deep-link fallback (FR-SP-011) and the YouTube fallback, case by case, and the copy for each path, is OD-S3 — this requirement binds only that the fallback exists wherever YouTube can serve and that no path is silent.

#### Acceptance criteria

```gherkin
Feature: YouTube fallback when Spotify cannot serve

  Scenario: An unlinked Spotify request is served by YouTube
    Given no Spotify account is linked
    And YouTube can serve the request
    When the user says "भजन बजाऊ"
    Then the request is served through the existing YouTube path
    And the spoken line names YouTube

  Scenario: An empty Spotify search falls back to YouTube where it can serve
    Given a Spotify account is linked
    And the Spotify search yields no usable result
    And YouTube can serve the request
    When the user says "गीत चलाऊ"
    Then the request is served through the existing YouTube path
    And the user hears the YouTube outcome, not a fabricated Spotify outcome

  Scenario: Neither provider can serve — explicit line, no silence
    Given Spotify cannot serve the request and YouTube cannot serve it either
    When the user says "गीत चलाऊ"
    Then the assistant speaks an explicit localized line naming the situation
    And nothing is claimed to have played
```

#### Related
- FR: FR-SP-003 (preference), FR-SP-005 (explicit YouTube unchanged), FR-SP-011 (deep-link fallback), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-006 (no regression)
- Depends on: FR-SP-002 (both-provider search)

### FR-SP-005: Explicit YouTube requests unchanged

#### Metadata
- **Area:** No-Regression / Routing
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 ("Must-not-break paths") and "Out of scope" ('युट्युबमा गीत चलाऊ' must still reach YouTube exactly as today); routing table row 2; DV-3

#### Description
An explicit YouTube request **must** route to YouTube exactly as it does today. 'युट्युबमा गीत चलाऊ' ("play a song on YouTube"), 'युट्युबमा भजन खोज' and every utterance the existing YouTube route recognizes **must** keep:

- the same route decision (`ios/ElderlyAssistant/Services/Voice/` `YouTubeRoute.swift` behaviour and its marker/veto rules);
- the same plugin execution (`youtube.play` through `YouTubePlugin`, `ios/ElderlyAssistant/Services/Plugins/` `YouTubePlugin.swift`);
- the same localized lines and the same honest failure behaviour;
- the same existing tests and golden expectations (`YouTubeRouteTests`, `YouTubePluginTests`, `CommandRouterYouTubeTests`).

The music feature **must not** re-route, delay, re-order or duplicate-handle an explicit YouTube request: the Spotify preference (FR-SP-003) is not applied to it, and the music path (FR-SP-015) must not fire in addition. Golden-corpus and route-expectation changes against explicit YouTube utterances are permitted only where this feature deliberately supersedes them, and each such move **must** be recorded with its new expectation alongside (NFR-SP-006).

#### Acceptance criteria

```gherkin
Feature: Explicit YouTube requests unchanged

  Scenario: An explicit Nepali YouTube request still reaches YouTube
    Given the music feature is built and a Spotify account is linked
    When the user says "युट्युबमा गीत चलाऊ"
    Then the request routes to the YouTube path exactly as before
    And the YouTube plugin serves it with the existing localized lines
    And the music/Spotify path does not also handle it

  Scenario: The existing YouTube behaviour holds under the new routing
    Given the music feature is built
    When the existing YouTube route, plugin and router test suites run
    Then they pass with no change other than recorded deliberate supersessions

  Scenario: A bare music request is not treated as an explicit YouTube request
    Given the music feature is built
    When the user says "भजन बजाऊ" with no YouTube word
    Then the explicit-YouTube route does not fire for it (FR-SP-015 applies)
```

#### Related
- FR: FR-SP-003 (preference), FR-SP-004 (YouTube fallback), FR-SP-015 (route-ladder intake)
- NFR: NFR-SP-006 (no regression)

### FR-SP-006: SpotifyPlugin as an AssistantPlugin (YouTubePlugin twin)

#### Metadata
- **Area:** Plugin Architecture
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" (ships as an `AssistantPlugin`), Feature Constraint 11 (plugin isolation), "Integration Surfaces" (NEW `ios/ElderlyAssistant/Services/Plugins/` `SpotifyPlugin.swift` — twin of `YouTubePlugin`)

#### Description
Spotify **must** ship as an `AssistantPlugin` (`ios/ElderlyAssistant/Services/Plugins/` `SpotifyPlugin.swift`), a structural twin of `YouTubePlugin`:

- it declares the action `spotify.play` (mirroring `youtube.play`) with a `query` entity, a `displayNameKey`, and plugin metadata in the registry shape;
- it executes through the shared tool (`SpotifyTool`, FR-SP-007) and the shared router seams (config store, transport, link opener), not through bespoke networking;
- its failure contract **must** return explicit failures with a localized spoken apology (mirroring `YouTubePlugin`'s `failed(spokenApology:)` lines) — never a silent success;
- it emits observability events in the plugin/action vocabulary without query text (NFR-SP-002);
- it is registered (and its store wired) through the existing `AppCoordinator` registration pattern, and it introduces no entanglement beyond the mapped `CommandRouter` seams (Feature Constraint 11, NFR-SP-012).

Without a linked account or configured credential the plugin **must** remain inert in the honest sense: it does not fire `spotify.play` into a dead end; the router's degradation rules (FR-SP-004, FR-SP-011, FR-SP-012) own the outcome.

#### Acceptance criteria

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

#### Related
- FR: FR-SP-007 (Spotify tool), FR-SP-008 (linking), FR-SP-015 (routing intake)
- NFR: NFR-SP-002 (log safety), NFR-SP-012 (plugin isolation)

### FR-SP-007: SpotifyTool search and spotify: deep-link construction

#### Metadata
- **Area:** Spotify Tool
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (NEW `ios/ElderlyAssistant/Services/Voice/` `SpotifyTool.swift` — Spotify Web API search + `spotify:` deep-link construction, mirroring `YouTubeTool`; credential/account store on `EncryptedLocalStorage`); workflow security-design-review focus ("Deep-link/URI injection: track names/IDs must be validated before URI construction; a crafted result must not open arbitrary schemes")

#### Description
The Spotify tool **must** provide, mirroring `YouTubeTool`:

- **Search** via the Spotify Web API (`https://api.spotify.com/v1/search`), resolving the top usable result for the spoken query. With a working search the result is a REAL API hit — its identifier and title are used as returned; never a fabricated title, and a title is spoken only once (honesty contract mirroring `YouTubeTool`).
- **Deep-link construction**: `spotify:` URIs built from validated components only (e.g. `spotify:track:<id>`, `spotify:search:<query>`), opened through the `CallLinkOpening` seam with the honest open outcome (app accepted / cannot open). The `spotify` query scheme is declared in the app's `Info.plist` `LSApplicationQueriesSchemes` so the installed-check is honest.
- **Failure mapping**: every failure (timeout, network error, non-200/quota/rate-limit, empty or malformed payload, unusable result) maps to an explicit case that the router turns into an honest localized line (FR-SP-012). No guess, no fabricated fallback.
- **Untrusted-input discipline**: track names, identifiers and any provider-controlled text are remote-controlled input. Before URI construction the identifier **must** be validated against the expected identifier shape and any query component **must** be percent-encoded; a crafted result containing scheme text, delimiters, control characters or path traversal **must not** produce a URI outside the `spotify:` scheme (NFR-SP-008). Titles are never composed into a URI.
- **Seams**: network goes through the `LocalToolTransport`-style seam and link-opening through `CallLinkOpening`, so tests exercise URL shape, parsing and open decisions with no real network (mirroring `YouTubeTool`), and the timeout is a configurable parameter, not a hardcoded constant (project Agent Principles for design agents).

#### Acceptance criteria

```gherkin
Feature: SpotifyTool search and deep-link construction

  Scenario: A real search result becomes a validated spotify: deep link
    Given a configured Spotify search transport returns a top result with identifier "01AbCdEfGhIjKlMnOpQrStU" (synthetic base62-shaped placeholder)
    When the tool constructs the playback deep link
    Then the URI is "spotify:track:01AbCdEfGhIjKlMnOpQrStU"
    And it is opened through the link-opener seam with the observed open outcome

  Scenario: A hostile track name or identifier cannot open an arbitrary scheme
    Given a search result whose title contains "https://evil.example/x" and whose identifier contains scheme or delimiter characters
    When the tool constructs the deep link
    Then the constructed URI uses only the spotify: scheme with a validated identifier or the result is rejected
    And no non-spotify scheme is opened
    And the title does not appear in any URI

  Scenario: An empty or malformed payload is an honest failure
    Given the search transport returns an empty, malformed or non-200 payload
    When the tool resolves the request
    Then it returns the corresponding explicit failure
    And no title is fabricated and no deep link is opened

  Scenario: The app is not present for the deep link
    Given the spotify: scheme cannot be opened by any installed app
    When the tool attempts the open
    Then the outcome is recorded as "not opened"
    And the spoken line follows the honest-app-absent rule (FR-SP-012)
```

#### Related
- FR: FR-SP-006 (plugin), FR-SP-009 (credential store), FR-SP-011 (deep-link fallback), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-002 (log safety), NFR-SP-008 (URI hardening)

### FR-SP-008: Spotify account linking by the caregiver (OAuth)

#### Metadata
- **Area:** Account Linking
- **Priority:** MUST
- **Source:** Feature constitution Constitutional Amendment Record 2026-10-06 ("Account-linking discipline (calendar-share Google OAuth pattern). Scopes are requested at sign-in (`addScopes`), tokens are verified, tokens are stored encrypted on-device") and Feature Constraint 2; "Integration Surfaces" (NEW Spotify account-linking service — `GoogleAccountSession` precedent); workflow `define-requirements` scope comment (caregiver-performed)

#### Description
A Spotify account-linking service **must** implement user OAuth following the `GoogleAccountSession` precedent (calendar-share), performed by the family member/caregiver — the elderly primary user never touches OAuth:

- **Scopes at sign-in**: the required scopes are requested at sign-in/at the linking step itself (`addScopes` precedent; scope-at-consent-screen-only was the calendar-share 401 root cause and is not acceptable);
- **Token verification**: a token is verified before it is trusted for a request (the tokeninfo-style truth check precedent);
- **Redirect validation**: the OAuth redirect URI **must** be validated by exact match; a mismatched redirect or a hijacked app-scheme callback **must be rejected** and **must not** result in a stored token;
- **Storage**: tokens land only in the encrypted on-device store (FR-SP-009); the linking service stores nothing of its own outside it;
- **Status**: the link state (not linked / linked / linked-but-unusable-free-tier) is observable to the Settings surface (FR-SP-016) and to the router's degradation rules (FR-SP-011, FR-SP-012);
- **Honest failure**: a cancelled or denied authorization leaves no partial state and produces an explicit status; a failed linking attempt **must not** silently present as linked.

The client-secret handling for the search flow (client-credentials) is OD-S1 and remains open; whatever the resolution, no credential may enter the repository or a log (NFR-SP-002, NFR-SP-007).

#### Acceptance criteria

```gherkin
Feature: Spotify account linking by the caregiver

  Scenario: The caregiver completes linking and the account becomes usable
    Given the caregiver is on the Spotify linking surface in Settings
    When they complete the OAuth flow with the required scopes granted
    Then the account is linked and the status surface shows connected
    And the token is verified before first use
    And the token is stored only in the encrypted on-device store

  Scenario: A denied or cancelled authorization leaves no partial state
    Given the caregiver starts the linking flow
    When they cancel or deny the authorization
    Then no token or account state is stored
    And the status remains not linked
    And the failure is explicit on the surface, never a silent half-link

  Scenario: A mismatched redirect is rejected
    Given an authorization callback arrives for a redirect URI that does not exactly match the registered callback
    When the linking service validates the callback
    Then the callback is rejected
    And no token is stored
    And the rejection is recorded without any token or code in the log

  Scenario: An unverified token is not trusted
    Given a stored token fails verification
    When a music request needs Spotify
    Then the account is treated as not usable per the degradation rules
    And the user hears an explicit localized outcome (never a silent failure)
```

#### Related
- FR: FR-SP-009 (credential store), FR-SP-010 (unlink), FR-SP-011 (free-tier degradation), FR-SP-016 (Settings surface)
- NFR: NFR-SP-007 (encryption at rest), NFR-SP-009 (redirect validation and token lifecycle)
- Depends on: —

### FR-SP-009: Encrypted Spotify credential and account store

#### Metadata
- **Area:** Credential Storage
- **Priority:** MUST
- **Source:** Feature constitution Constitutional Amendment Record 2026-10-06 (tokens stored encrypted on-device — Keychain / `EncryptedLocalStorage`, Data Protection Complete; credentials never in the repository or any log — header, never URL) and Feature Constraint 2; "Integration Surfaces" (Spotify credential/account store on `EncryptedLocalStorage`; the `YouTubeConfigStore` / `SearchConfigStore` Keychain precedent); OD-S1 (client-secret handling — open)

#### Description
The Spotify credential/account store **must** mirror the `YouTubeConfigStore` / `SearchConfigStore` precedent:

- **Storage**: all Spotify credentials, tokens and account state live in `EncryptedLocalStorage` (Keychain-backed, Data Protection class Complete). Never `UserDefaults`, never a plist, never a plain file, never the repository, never a log (NFR-SP-002, NFR-SP-007).
- **Access shape**: an observable store (`ObservableObject`-style, mirroring `YouTubeConfigStore`) exposing save, clear and `isConfigured`-style status; empty input clears; clearing stops the keyed path and degrades honestly (FR-SP-012).
- **Transport discipline**: any credential presented to a provider travels in a request header, never in a URL; query strings, error bodies and diagnostics never carry it (the B2/T-050 precedent — `ios/tools/check-release-log-safety.sh`).
- **Family-entered credential path**: where the resolved OD-S1 design uses a family-entered credential (the `SearchConfigStore` precedent), the store accepts it from the Settings surface (FR-SP-016); where OD-S1 resolves to a flow without an app-held secret, the store holds only tokens. The requirement binds the storage discipline for whichever path OD-S1 selects.
- **Free of side effects at rest**: no credential is written outside the encrypted store on any path, including diagnostics, crash metadata or debug logs.

#### Acceptance criteria

```gherkin
Feature: Encrypted Spotify credential and account store

  Scenario: Credentials and tokens are readable only from the encrypted store
    Given a Spotify credential and a token have been saved
    When the app relaunches and reads its configuration
    Then the values are read back from the encrypted store
    And a storage-placement check shows no Spotify value in UserDefaults or any plain file

  Scenario: Saving empty input clears the credential
    Given a Spotify credential is configured
    When the family member saves an empty value
    Then the stored credential is cleared
    And the Spotify keyed path stops firing and the feature degrades to the honest outcomes

  Scenario: No credential is written to any log or repository path
    Given a Release build with a configured Spotify credential
    When a music session and its error paths are exercised
    Then no credential, token or authorization header value appears in any log
    And the release log-safety gate covers the new paths and exits 0
```

#### Related
- FR: FR-SP-007 (tool), FR-SP-008 (linking), FR-SP-010 (unlink), FR-SP-016 (Settings surface)
- NFR: NFR-SP-002 (log safety), NFR-SP-007 (encryption at rest)
- Depends on: FR-SP-008 (the linking flow that populates the store)

### FR-SP-010: Unlink wipes credentials and revokes access

#### Metadata
- **Area:** Account Linking / Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` and `security-test` focus ("OAuth token lifecycle … revocation on unlink", "credential wipe on unlink"); feature constitution amendment (credential handling discipline); project constitution Standards (Security)

#### Description
Unlinking Spotify **must** remove the account's access from the device, cleanly:

- **Wipe**: the unlink action clears every Spotify token, credential and account-state value from the encrypted store (FR-SP-009) — after unlink, the store reads as not configured; a storage sweep finds no recoverable Spotify credential.
- **Revocation**: where the linking service supports it, the grant is revoked upstream; where it does not, the local wipe is the guarantee. A token that the provider reports as revoked/invalid **must** be treated as unlinked: the cached grant is dropped, no retry loop runs against a dead grant, and the user is not told a lie about being connected.
- **Behaviour after unlink**: music requests follow the unlinked-account rules (FR-SP-002, FR-SP-004, FR-SP-012) — an explicit localized outcome every time. The status surface (FR-SP-016) shows not linked.
- **No residue**: no credential survives in logs, diagnostics, caches or backups of the encrypted store beyond what the platform's Data Protection semantics allow (NFR-SP-007); the wipe itself logs only a non-content outcome (NFR-SP-002).
- **Re-link**: after unlink, the caregiver can re-link through the same flow (FR-SP-008) without a residual-state conflict.

#### Acceptance criteria

```gherkin
Feature: Unlink wipes credentials and revokes access

  Scenario: Unlink removes all stored Spotify credentials
    Given a linked Spotify account with stored tokens
    When the caregiver unlinks the account
    Then the encrypted store holds no Spotify token or credential
    And the status surface shows not linked
    And a later music request follows the unlinked-account degradation rules

  Scenario: A revoked grant is treated as unlinked, without a retry loop
    Given a linked account whose grant the provider rejects as revoked
    When a music request reaches Spotify
    Then the cached grant is dropped
    And the request follows the unlinked-account path with an explicit localized outcome
    And no unbounded retry against the revoked token occurs

  Scenario: The wipe leaves no credential in logs
    Given the unlink action runs in a Release build
    When the console and log output are inspected
    Then no token, credential or authorization header value appears
    And only a non-content unlink outcome is recorded

  Scenario: Re-linking after unlink succeeds cleanly
    Given the account was unlinked
    When the caregiver completes the linking flow again
    Then the account is linked with fresh credentials
    And no stale state from the previous link affects the new one
```

#### Related
- FR: FR-SP-008 (linking), FR-SP-009 (store), FR-SP-016 (status surface)
- NFR: NFR-SP-002 (log safety), NFR-SP-007 (encryption at rest), NFR-SP-009 (token lifecycle)
- Depends on: FR-SP-008, FR-SP-009

### FR-SP-011: Free-tier degradation to the spotify: deep-link fallback

#### Metadata
- **Area:** Degradation
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 1 ("Premium reality is an NFR — degradation must be honest… free-tier or unlinked-account remote control must degrade to the `spotify:` deep-link fallback with clear messaging, never a silent failure") and "Music Request Routing & Degradation Contract" (degradation bullets); DV-4; OD-S3 (exact precedence and copy — open)

#### Description
Playback control requires a Spotify Premium account. When a music request reaches a linked Spotify account that cannot be remote-controlled — free tier, or any account state where remote control is unavailable — the system **must** degrade to the `spotify:` deep-link fallback with clear messaging:

- a validated `spotify:` deep link (FR-SP-007) is opened for the resolved request (e.g. the track, or `spotify:search:<encoded query>`);
- the user hears an explicit localized line that says what actually happened, never a claim that remote playback was started. Illustrative copy (exact copy for the degradation paths is OD-S3): "स्पोटिफाइ खोल्दैछु — त्यहाँ बजाउनुहोस्।" / "Opening Spotify — play it there.";
- the honest free-tier line **must not** be skipped in favour of pretending control succeeded, and the deep link **must not** be suppressed silently;
- if the `spotify:` scheme cannot be opened (app absent — Feature Constraint 8), the outcome follows the honest-app-absent rule (FR-SP-012), never a fabricated success.

The precedence between this free-tier deep-link path and the YouTube fallback (FR-SP-004), per account/service state, and the exact copy for each path, is OD-S3. Both rules bind; OD-S3 resolves composition. Whether a Premium account is detected ahead of the request or by the provider response is a design decision constrained only by this honesty rule.

#### Acceptance criteria

```gherkin
Feature: Free-tier degradation to the spotify: deep-link fallback

  Scenario: A free-tier linked account degrades to the deep link with clear messaging
    Given a Spotify account is linked on the free tier
    When the user says "भजन बजाऊ" and Spotify cannot remote-control playback
    Then a validated spotify: deep link is opened for the request
    And the user hears an explicit localized line saying Spotify was opened
    And the line does not claim remote playback was started

  Scenario: The deep link cannot be opened — honest outcome, no pretense
    Given the free-tier degradation path is chosen
    And the spotify: scheme cannot be opened on the device
    Then the user hears the honest app-absent line (FR-SP-012)
    And no playback success is claimed

  Scenario: A controllable Premium account does not take this path
    Given a Premium linked account capable of remote control
    When the user says "गीत चलाऊ"
    Then playback control is attempted normally
    And the free-tier deep-link messaging is not used
```

#### Related
- FR: FR-SP-003 (preference), FR-SP-004 (YouTube fallback), FR-SP-007 (deep-link construction), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-006 (no regression)

### FR-SP-012: Honest localized outcomes — no silent failure on any path

#### Metadata
- **Area:** Degradation / Honesty
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 1 and the degradation contract ("Never a silent failure anywhere in the chain. Unlinked account, free tier, network failure, and empty search each produce an explicit, localized, spoken outcome"); root constitution Agent Principles ("No silent stubs"); DV-4

#### Description
Every music path **must** end in an explicit, localized, spoken outcome. The enumerated paths that must each produce one:

| Path | Required outcome |
|---|---|
| Unlinked account | An explicit line (and the YouTube fallback where it can serve, FR-SP-004) |
| Linked, free tier / remote control unavailable | The deep-link degradation line (FR-SP-011) |
| Network failure / timeout | An explicit service-unavailable line; where YouTube can serve, the fallback (FR-SP-004); never a hang |
| Empty search result | An explicit not-found line, or the YouTube fallback where it can serve |
| Provider error (non-200, quota/rate-limit, malformed payload) | The network/service failure treatment above, never a raw error spoken or logged |
| Deep link cannot open (app absent, Feature Constraint 8) | The honest app-absent line |
| Spotify linked but not usable (credential missing after wipe, revoked token) | The unlinked-account treatment (FR-SP-010) |

Rules that bind every row:

- **Never silence**: no path may return without speaking; no path may end in a spinner, a log-only failure, or a dropped request.
- **Never pretense**: "Playing…" / "चलाउँदैछु" is spoken only when playback or an open actually happened; a failure is described as a failure.
- **Localized**: every line exists in Nepali and English via `spotify.*` keys (NFR-SP-005), mirroring the YouTube plugin's line family (`spotify.unavailable`, `spotify.notFound`, `spotify.notLinked`, `spotify.openApp`, …).
- **Observable**: the outcome classification (success / fallback / unavailable / not-found / not-linked / free-tier) is recorded without query text (NFR-SP-002).

#### Acceptance criteria

```gherkin
Feature: Honest localized outcomes on every music path

  Scenario: Network failure is spoken, not silent
    Given the Spotify search transport times out or errors
    When the user says "भजन बजाऊ"
    Then the user hears an explicit localized service-unavailable outcome (or the YouTube fallback where it can serve)
    And no path returns without an audible outcome

  Scenario: Empty search is spoken as not found, never fabricated
    Given both providers return no usable result
    When the user says "गीत चलाऊ"
    Then the user hears the explicit not-found line
    And no title is fabricated and no playback is claimed

  Scenario: An unlinked account is spoken as not linked
    Given no Spotify account is linked and YouTube cannot serve the request
    When the user says "play a song"
    Then the user hears the explicit not-linked/not-available line in the active language

  Scenario: No "playing" claim without a real open or playback
    Given any failure path above is exercised
    When the spoken output is inspected
    Then no line claims music is playing or being played
```

#### Related
- FR: FR-SP-001 (the flip), FR-SP-004 (YouTube fallback), FR-SP-007 (tool failures), FR-SP-011 (free tier)
- NFR: NFR-SP-005 (localisation), NFR-SP-002 (log safety)

### FR-SP-013: Deterministic music-domain rule in KeywordIntentRule

#### Metadata
- **Area:** Intent Routing (no-model path)
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (`ios/ElderlyAssistant/Services/Voice/` `KeywordIntentRule.swift` — deterministic music domain rule, no-model path) and "Feature Purpose & Scope"; Feature Constraint 3 (prompt budget — the deterministic rule is the no-prompt-token path);

#### Description
The deterministic no-model intent path **must** classify bare music requests into the music domain, so a music request works without a model call and without prompt-budget growth:

- a music keyword group (the natural Nepali and English families: भजन, गीत, गाना, संगीत/सङ्गीत, "song", "music", "bhajan" …) combined with the play/listen verb families routes to the music domain, mirroring the structure of the existing `youtube` rule (`youtubeKeywords` × `youtubeVerbFamily`);
- the rule **must not** capture explicit YouTube utterances: an utterance carrying a YouTube marker (युट्युब / "youtube") continues to match the YouTube domain, not music (FR-SP-005);
- narration guards follow the existing YouTube-rule discipline (a narration such as "I listened to music yesterday" style phrasing must not fire the stage, mirroring the `youtubeVerbFamily` narration comment);
- the emitted intent/domain for the example golden utterances stays `music` (the pinned music golden block, NFR-SP-006).

The rule is the zero-prompt-token path (Feature Constraint 3); any prompt-layer music wording added alongside it must fit the pinned budget (NFR-SP-004).

#### Acceptance criteria

```gherkin
Feature: Deterministic music-domain rule

  Scenario: A bare music request matches the music domain without a model call
    Given the keyword intent rule is evaluated
    When the transcript is "भजन बजाऊ"
    Then the matched domain is music
    And no model call is required for the classification

  Scenario: A YouTube-marked utterance still matches the YouTube domain
    Given the keyword intent rule is evaluated
    When the transcript is "युट्युबमा गीत चलाऊ"
    Then the matched domain is youtube, not music
    And the existing YouTube rule behaviour is unchanged

  Scenario: A narration is not captured as a request
    Given the keyword intent rule is evaluated
    When a text mentions music in narration form without a request shape
    Then the music stage does not fire
```

#### Related
- FR: FR-SP-005 (explicit YouTube unchanged), FR-SP-014 (contact veto), FR-SP-015 (route intake)
- NFR: NFR-SP-004 (prompt budget), NFR-SP-006 (no regression)

### FR-SP-014: Music-request veto parity in VoiceContactSearchRoute

#### Metadata
- **Area:** Intent Routing
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (`ios/ElderlyAssistant/Services/Voice/` `VoiceContactSearchRoute.swift` — YouTube-veto parity so music requests never open the Contacts screen); Feature Constraint 5 (must-not-break paths)

#### Description
A music request **must never** open the Contacts screen. The existing contact-search route already runs a YouTube veto ("a YouTube utterance is a YouTube search, never a contact search"); the music feature **must** add music-request veto parity so that an utterance such as 'गीत चलाऊ' or 'भजन बजाऊ' — whose tokens can resemble a contact search ("play <name>") — is not misread as a contact search:

- the music veto **must** recognize the same music families the keyword rule recognizes (FR-SP-013) and must run before the contact-search decision, in the same order position as the existing YouTube veto;
- the veto is a *veto*, not a capture: it prevents the Contacts screen from opening; the music path (FR-SP-015) owns the request;
- the veto **must not over-block**: a genuine contact request that carries no music marker still opens contact search exactly as today (NFR-SP-006);
- the existing YouTube veto behaviour is unchanged (FR-SP-005).

#### Acceptance criteria

```gherkin
Feature: Music requests never open the Contacts screen

  Scenario: A bare music request is vetoed from contact search
    Given the contact-search route is evaluated
    When the transcript is "गीत चलाऊ" or "भजन बजाऊ"
    Then the contact search does not fire
    And the Contacts screen is not opened

  Scenario: The music veto does not over-block a genuine contact request
    Given the contact-search route is evaluated
    When the transcript is a plain contact request with no music marker (for example "आरवलाई फोन गर")
    Then the contact search fires exactly as before

  Scenario: The YouTube veto still holds alongside the music veto
    Given the contact-search route is evaluated
    When the transcript is "युट्युबमा गीत खोज"
    Then the YouTube veto fires as before and contact search does not open
```

#### Related
- FR: FR-SP-013 (keyword rule), FR-SP-015 (route intake), FR-SP-005 (explicit YouTube unchanged)
- NFR: NFR-SP-006 (no regression)
- Depends on: FR-SP-013 (shared music-family recognition)

### FR-SP-015: Music-request intake in the voice route ladder

#### Metadata
- **Area:** Intent Routing
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (`ios/ElderlyAssistant/Services/Voice/` `YouTubeRoute.swift` — a bare "play some music" with no YouTube word deliberately falls through today; the music path changes or sits alongside it while explicit YouTube must still reach YouTube); routing table row 1; Feature Constraint 5

#### Description
Bare music requests **must** reach the music playback path through the voice route ladder:

- today a bare "play some music" with no YouTube word deliberately falls through the YouTube route (and can then be mis-handled by downstream stages). The music feature **must** add music-request intake such that a bare music utterance — 'भजन बजाऊ', 'गीत चलाऊ', 'play a song' — is recognized as a music request at the route stage and handed to the music path (FR-SP-001);
- the intake **must** run so that explicit YouTube requests still reach YouTube first (FR-SP-005): a YouTube-marked utterance is never claimed by the music intake;
- **no double-handling**: an utterance is handled by exactly one of the YouTube path and the music path, and the stage ordering must make that deterministic (whether the music intake changes `YouTubeRoute` or sits alongside it is the architect's call in design-l1/design-l2);
- the intake **must not** capture non-music utterances: chat, queries, calls and other domains keep their current handling (NFR-SP-006);
- the route decision for the ladder's other stages (including the contact-search veto, FR-SP-014) is unchanged except for the music intake itself.

#### Acceptance criteria

```gherkin
Feature: Music requests reach the music path from the route ladder

  Scenario: A bare music request is recognized and handed to the music path
    Given the voice route ladder is evaluated
    When the transcript is "भजन बजाऊ" with no YouTube word
    Then the music intake fires and hands the request to the music path
    And the request is not dropped, and not answered as a chat/query

  Scenario: An explicit YouTube request still reaches YouTube first
    Given the voice route ladder is evaluated
    When the transcript is "युट्युबमा गीत चलाऊ"
    Then the YouTube stage fires exactly as before
    And the music intake does not also handle the utterance

  Scenario: A non-music utterance is not captured by the music intake
    Given the voice route ladder is evaluated
    When a non-music utterance (for example a chat or a call request) is spoken
    Then the music intake does not fire
    And the utterance follows its existing stage
```

#### Related
- FR: FR-SP-001 (playback flip), FR-SP-005 (explicit YouTube unchanged), FR-SP-013 (keyword rule), FR-SP-014 (contact veto)
- NFR: NFR-SP-006 (no regression)
- Depends on: FR-SP-013

### FR-SP-016: Settings linking, status surface and privacy disclosure

#### Metadata
- **Area:** Settings / Privacy
- **Priority:** MUST
- **Source:** Feature constitution Constitutional Amendment Record 2026-10-06 ("Privacy disclosure. Linking the account sends the user's music queries and playback activity to Spotify. The privacy/settings surface discloses this") and "Integration Surfaces" (`ios/ElderlyAssistant/App/` `SettingsView.swift` + `SettingsTabs.swift` — Spotify linking/status surface, mirror of `YouTubeSettingsView`); Feature Constraint 12 (localization)

#### Description
The Settings app **must** carry a Spotify linking and status surface, mirroring `YouTubeSettingsView`:

- **Status**: shows whether Spotify is linked/connected, and the state the router will act on (linked / not linked / linked but remote control unavailable — free tier). Status is derived from the credential store (FR-SP-009), never optimistic.
- **Actions**: the caregiver can link (starts the OAuth flow, FR-SP-008) and unlink (wipes credentials, FR-SP-010), with the same confirm pattern as the YouTube surface (`youtubeSettings.removeConfirm` precedent); where OD-S1 resolves to a family-entered credential, the surface carries that field in the `credentialField` style (secure entry, never echoed).
- **Privacy disclosure**: the surface **must** state, in plain language and in both languages, that linking sends the user's music queries and playback activity to Spotify — mirroring the existing `youtubeSettings.privacy` disclosure shape. Illustrative copy: "गीत खोज्न तपाईंले भन्नुभएको कुरा स्पोटिफाइमा पठाइन्छ; अरू केही पठाइँदैन।" / "What you say is sent to Spotify to find the music; nothing else is sent."
- **Honesty about rollout**: while Spotify development mode limits service to registered test users (OD-S2), the surface **must not** hide that reality; the unregistered case still behaves honestly at request time (FR-SP-012).
- **Localization**: all surface strings live under the `spotify.*` key family (including the settings sub-family mirroring `youtubeSettings.*`) with ne/en entries (NFR-SP-005); the surface follows the project accessibility standards (NFR-SP-010).
- The elderly primary user is never asked to handle OAuth or credentials; the surface is written for and operated by the family member/caregiver (amendment; `YouTubeSettingsView` family framing).

#### Acceptance criteria

```gherkin
Feature: Settings linking, status and privacy disclosure

  Scenario: The linked state is shown truthfully
    Given a Spotify account is linked
    When the caregiver opens the Spotify Settings surface
    Then the connected status is shown
    And an unlink action is available

  Scenario: The unlinked state offers linking
    Given no Spotify account is linked
    When the caregiver opens the Spotify Settings surface
    Then the surface shows not linked and offers the linking action
    And the linking flow follows the caregiver-performed OAuth requirement (FR-SP-008)

  Scenario: The privacy disclosure is present and localized
    Given the Spotify Settings surface is presented in Nepali and in English
    When the disclosure text is inspected
    Then it states that music queries and playback activity are sent to Spotify
    And it is present in both languages via spotify.* keys

  Scenario: Unlink is confirm-guarded and effective
    Given a linked account
    When the caregiver confirms unlink
    Then the surface shows not linked
    And the credentials are wiped (FR-SP-010)
```

#### Related
- FR: FR-SP-008 (linking), FR-SP-009 (store), FR-SP-010 (unlink), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-005 (localisation), NFR-SP-010 (accessibility), NFR-SP-011 (compliance gates)

### FR-SP-017: Device-validation checklist recorded and passed (DV-* completion gate)

#### Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Source:** Feature constitution "Success Criteria & Completion Gate" (the DV-* device-validation checklist is the completion gate; the feature is done only when it carries the checklist and passes it on the reference device, Anzaan); the DV-1..DV-16 pattern used by prior shipped features

#### Description
The feature **must** carry a DV-* style acceptance checklist recorded with the feature (the pattern used by prior shipped features) and **must** pass it on the reference device (Anzaan) before it is considered done. The checklist **must** cover at minimum the constitution's items:

| Item | What it validates |
|---|---|
| DV-1 | Stub → real playback flip: a bare music request produces sound |
| DV-2 | Spotify-preferred selection: both-provider search with Spotify winning while linked and capable |
| DV-3 | Explicit-YouTube routing unchanged: 'युट्युबमा गीत चलाऊ' still reaches YouTube |
| DV-4 | Honest lines for free-tier, unlinked-account, network-failure and empty-search paths (no silent failure) |
| DV-5 | Nepali-language end-to-end on the Anzaan reference device |

Requirements on the checklist itself:

- it is **recorded with the feature** (the feature's spec/validation artifacts), with each item's steps, expected outcome and observed result;
- every item has an explicit pass/fail record; a failed item is recorded as failing — the feature is **not** declared done on an unmet item;
- results are captured on a Release build on the reference device where the item's nature requires it (the project's pre-release device-check discipline applies to console output too, NFR-SP-002);
- the checklist is the completion gate regardless of unit-test status: tests are necessary, the device run is what signs the feature off.

#### Acceptance criteria

```gherkin
Feature: DV-* device-validation checklist is recorded and passed

  Scenario: The checklist exists with at least the constitution's coverage
    Given the feature deliverable set
    When the recorded device-validation checklist is inspected
    Then it contains at least DV-1 (flip), DV-2 (Spotify preferred), DV-3 (explicit YouTube), DV-4 (honest degradation lines) and DV-5 (Nepali end-to-end)
    And each item carries steps, expected outcome and a result record

  Scenario: An unmet item blocks the completion claim
    Given a checklist item fails on the reference device
    When completion is assessed
    Then the item is recorded as failing
    And the feature is not declared done until the item passes or the deviation is explicitly resolved with the owner

  Scenario: The passed checklist is recorded with the feature
    Given the checklist items pass on the Anzaan reference device
    When the feature is signed off
    Then the results are recorded alongside the feature artifacts
    And the record names the device and build used
```

#### Related
- FR: FR-SP-001 (DV-1), FR-SP-003 (DV-2), FR-SP-005 (DV-3), FR-SP-012 (DV-4)
- NFR: NFR-SP-011 (compliance and release gates)

## Non-functional requirements

### NFR-SP-001: Provider search responsiveness and timeout budget

#### Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (the Spotify tool mirrors `YouTubeTool`, whose fetch budget is the project's tool-timeout precedent) and the degradation contract (no silent failure / no hang); project constitution Agent Principles (timeouts are configurable parameters, not hardcoded constants)

#### Description
A music request **must** resolve to a spoken outcome within a bounded time — an elderly voice-first user is never left in silence with no feedback. Measurable targets:

- **Provider round-trip budget**: each provider search uses a configurable timeout with a default of **8 s**, mirroring `YouTubeTool.fetchTimeoutSeconds` = 8 s (the same budget as the weather/search tools). The timeout is a parameter of the tool, not a hardcoded constant.
- **Outcome budget**: when at least one configured provider answers within its budget, the user hears the outcome (playback line, deep-link line, or fallback line) within **10 s** of the request being recognized, on a working network.
- **Negative budget**: when a provider exceeds its budget, the honest timeout outcome (FR-SP-012) is produced by the budget deadline; **no path blocks for more than 16 s total** (two sequential provider budgets) before speaking.
- **No unbounded waits**: no music path waits on an unbounded socket, an infinite retry, or a revoked-grant loop (FR-SP-010); retries are bounded and counted.

#### Acceptance criteria

```gherkin
Feature: Provider search responsiveness

  Scenario: An answered request produces a spoken outcome within the budget
    Given a working network and a provider that answers within its budget
    When the user says "भजन बजाऊ"
    Then the spoken outcome occurs within 10 s of the request being recognized

  Scenario: A slow provider is cut off at the budget with an honest line
    Given a provider that does not answer
    When the budget (default 8 s) elapses
    Then the timeout outcome is produced by the deadline
    And the user hears the corresponding localized line

  Scenario: The timeouts are configurable, not hardcoded
    Given the tool is constructed with an injected timeout
    When the value differs from the default
    Then the tool uses the injected value in its request budget
```

#### Related
- FR: FR-SP-002 (search), FR-SP-007 (tool), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-006 (no regression)

### NFR-SP-002: Log safety — no credentials, queries or provider bodies in logs

#### Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 2 (credentials never in the repository or logs — header, never URL; the B2/T-050 release-log-gate precedent `ios/tools/check-release-log-safety.sh` is binding) and the amendment; workflow `security-design-review` focus ("Log sanitisation: music queries, provider responses and error bodies must not reach logs"); project constitution Standards (Privacy: logs must not contain PII; release gates)

#### Description
No Spotify credential, token, authorization header, music query text or raw provider body **must** reach any log, telemetry event or diagnostic surface, in any build. Measurable properties:

- **Zero occurrences**: in a Release build exercising linking, unlinking, a successful music session, every failure path (timeout, non-200, malformed payload, revoked token) and the settings surface, the console and log output contain **0** credentials, tokens, client secrets, authorization header values, query strings or raw response/error bodies.
- **Header, never URL**: credentials travel in request headers; no credential appears in any URL, query parameter or deeplink — checked over the new code paths.
- **Sanitiser coverage**: the log sanitiser treats the new fields/values as sensitive; diagnostic call sites redact or omit them; observability events carry only non-content classifications ("provider: spotify; outcome: not_found") and never query text (mirroring `YouTubeTool`'s "observability events carry no query text" discipline).
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) covers the new Spotify plugin, tool, linking and settings paths and **exits 0** — a build-blocking gate, not a report. The pre-release device console check (project release gates) covers the same paths.

#### Acceptance criteria

```gherkin
Feature: Log safety for the Spotify paths

  Scenario: A full linked session produces no sensitive output
    Given a Release build with a linked Spotify account
    When a music request, a fallback, a failure and an unlink are exercised
    Then no credential, token, authorization header, query text or provider body appears in the console or logs

  Scenario: A provider error body is never logged raw
    Given the provider returns an error body
    When the failure is handled
    Then only a non-content classification is recorded
    And no raw body or provider message reaches the log

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's logging paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new Spotify plugin, tool, linking and settings paths
```

#### Related
- FR: FR-SP-007 (tool), FR-SP-008 (linking), FR-SP-009 (store), FR-SP-010 (unlink)
- NFR: NFR-SP-007 (encryption at rest), NFR-SP-011 (compliance gates)

### NFR-SP-003: No new network egress; music stays off any cloud LLM

#### Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 4 ("On-device stance. Voice intent parsing and routing stay on-device; music queries go to the provider APIs directly, never through a cloud LLM. No network egress beyond the two provider APIs"), Constraint 6 ("No new backend"), and the amendment ("Scope limited to Spotify. No other network egress is added or widened"); project constitution Architecture Constraint 1 (amended)

#### Description
The feature adds exactly two outbound surfaces and nothing else. Measurable properties:

- **Egress allowlist**: network calls on the music path go only to the Spotify OAuth endpoint (`accounts.spotify.com`), the Spotify Web API (`api.spotify.com`), and the pre-existing YouTube endpoints used by the YouTube path. **Zero** calls to any other host are introduced by the feature.
- **No new backend**: nothing is provisioned server-side; the app calls the Spotify Web API directly.
- **No cloud LLM on the music path**: the spoken query, its text and any provider response are never sent to a cloud LLM/chat provider; classification and routing stay on-device (the deterministic rule, FR-SP-013, is a no-prompt path). The recorded cloud exceptions (project Open Decisions 12/13: voice transcription, OCR text translation) are untouched and are not invoked by this feature's music path.
- **Deep links are OS hand-offs, not egress**: opening `spotify:` / `youtube:` / https deep links hands the request to another installed app; the feature itself does not fetch those pages.
- **Verifiable**: a network-seam test (the `LocalToolTransport` pattern) asserts the exact request set per flow; no other host is contacted for any of the exercises in the scenarios below.

#### Acceptance criteria

```gherkin
Feature: No new network egress on the music path

  Scenario: A music session contacts only the allowlisted hosts
    Given a linked account and a configured YouTube key
    When a full music request, a fallback request and a linking request are exercised
    Then only accounts.spotify.com, api.spotify.com and the existing YouTube endpoints are contacted
    And no other host is contacted

  Scenario: The music path never reaches a cloud LLM
    Given any of the music flows is exercised
    When egress is inspected
    Then no request carries the spoken query or provider content to any cloud LLM/chat provider

  Scenario: No new backend is introduced
    Given the feature change set
    When its network surfaces are inspected
    Then the app calls the Spotify Web API directly
    And nothing new is provisioned on the project's side
```

#### Related
- FR: FR-SP-002 (search), FR-SP-007 (tool), FR-SP-008 (linking)
- NFR: NFR-SP-011 (compliance gates)

### NFR-SP-004: Prompt token budget preserved

#### Metadata
- **Category:** Reliability / Maintainability
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 3 ("`IntentPromptTests` pins the intent prompt's token budget; music/Spotify prompt additions must fit it. The YouTube route's zero-prompt-token discipline is the model"); the project precedent `NFR-PI-005-prompt-budget-and-seed-mirror`

#### Description
Music-intent wording changes in the intent/prompt layer **must** fit inside the existing pinned prompt budget, without raising the pin. Measurable properties:

- **Pinned budget holds**: `IntentPromptTests` (the token/character ceiling on the intent prompt) passes unchanged; the pinned ceiling value is not increased to accommodate music wording.
- **Zero-token preference is exercised**: the deterministic keyword path (FR-SP-013) is the primary music classification route, so the model prompt's music wording can stay small; whatever wording is added must fit the remaining budget.
- **Seed mirror**: if any prompt template text changes, the byte-mirrored training seed (`tools/train-intent/seeds/prompt_template.txt`) is updated in the same change and the project's prompt-mirror check passes (`ios/tools/check-prompt-mirror.sh`).
- **No behaviour drift**: the budget-preservation must not regress existing intents — the prompt's other rules are unchanged except for the deliberate music wording (NFR-SP-006).

#### Acceptance criteria

```gherkin
Feature: Prompt budget preserved

  Scenario: The pinned intent prompt budget still passes with music wording
    Given the music wording has been added to the intent/prompt layer
    When IntentPromptTests run
    Then they pass with the pinned ceiling unchanged

  Scenario: The prompt and seed mirror stay in sync
    Given the intent prompt template text changed
    When the prompt-mirror check runs
    Then the training seed mirror matches byte-for-byte
    And the check passes

  Scenario: An over-budget wording change is rejected, not accommodated
    Given a wording change that would exceed the pinned ceiling
    When the change is proposed
    Then it fails IntentPromptTests
    And the pinned ceiling is not raised to accept it
```

#### Related
- FR: FR-SP-013 (deterministic rule — the zero-prompt path), FR-SP-015 (routing)
- NFR: NFR-SP-006 (no regression)

### NFR-SP-005: Localisation of all Spotify strings (ne/en)

#### Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 12 ("All Spotify user-facing strings are localized (ne/en) via `spotify.*` keys, mirroring the YouTube plugin's L10n pattern; spoken output follows the same formatting discipline as the rest of the voice stack") and the amendment; project constitution Standards (Localisation: all UI strings externalised; TTS output in the user's configured language)

#### Description
Every user-facing string this feature adds **must** be localized, in both launch languages, through the `spotify.*` key family. Measurable properties:

- **Key coverage**: 100% of the new user-facing strings exist as keys under the `spotify.*` family (including the settings sub-family mirroring `youtubeSettings.*`) with both **ne** and **en** values present in `ios/ElderlyAssistant/Resources/` `Localizable.xcstrings`; a missing translation is a failure, not a fallback to English.
- **No hardcoded literals**: the new plugin, tool, linking, settings and router paths contain **zero** hardcoded user-facing strings (spoken or displayed); all go through the L10n lookup/format helpers.
- **Spoken discipline**: spoken lines use the existing formatting discipline (locale-aware formatting helpers; spoken-only text never logged — NFR-SP-002). The provider name is spoken in the user's language ("स्पोटिफाइ" in Nepali sessions).
- **Coverage of the degradation set**: the lines required by FR-SP-011 and FR-SP-012 (free tier, unlinked, unavailable, not found, app absent) exist in both languages — exact copy per OD-S3, but the keys must exist and be localized at implementation time.

#### Acceptance criteria

```gherkin
Feature: Spotify strings are localized in Nepali and English

  Scenario: Every new key has both languages
    Given the feature's string changes
    When the string catalog is inspected
    Then every spotify.* key has both a ne and an en value
    And no key is missing a translation

  Scenario: A Nepali session speaks Nepali lines on every path
    Given the app's configured language is Nepali
    When a music request, a fallback and each degradation path are exercised
    Then the spoken lines are Nepali
    And no English fallback line is spoken

  Scenario: No hardcoded user-facing literal exists in the new paths
    Given the new Spotify code paths
    When they are inspected for user-facing literals
    Then all display and spoken strings resolve through the L10n keys
```

#### Related
- FR: FR-SP-011 (free-tier line), FR-SP-012 (honest outcomes), FR-SP-016 (settings surface)
- NFR: NFR-SP-006 (no regression)

### NFR-SP-006: No regression to existing flows

#### Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 ("Must-not-break paths") and "Success Criteria" ("Explicit YouTube requests behave exactly as before — existing route, plugin, and golden tests hold"); project constitution Standards (Quality)

#### Description
The feature changes only what FR-SP-001 through FR-SP-016 require. Measurable properties:

- **Explicit YouTube unchanged**: `YouTubeRouteTests`, `YouTubePluginTests` and `CommandRouterYouTubeTests` pass; 'युट्युबमा गीत चलाऊ' reaches YouTube with the same route, action and lines (FR-SP-005).
- **Golden corpus holds**: the pinned music golden block in `ios/ElderlyAssistantTests/` `Services/Voice/GoldenCorpus.swift` (currently 15 utterances pinned to intent `music`, lines 142–157; the feature constitution refers to "16 utterances" — the implementation reconciles the count against the source and records the result) still resolves to intent `music`; any entry that the feature deliberately supersedes moves **with its new expectation recorded alongside** — no silent golden churn.
- **Other intents unchanged**: non-music stub intents (health query `router.healthNotAvailable`, video `router.featureNotYet`) and unrelated domains behave exactly as before; the touched suites listed in the feature constitution (`KeywordIntentRuleTests`, `VoiceContactSearchRouteTests`, `SettingsTabMappingTests`, `StoragePlacementTests`, plus the new Spotify suites) pass.
- **Dormant-seam discipline**: the existing router construction sites and legacy tests keep compiling and behaving as before when the Spotify seams are dormant (nil), mirroring the `[YOUTUBE]` seam pattern.
- **Project baseline recorded**: the unit gate runs against the project's known baseline; pre-existing failures unrelated to this feature are recorded as such (not silently included or excluded).

#### Acceptance criteria

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

#### Related
- FR: FR-SP-001 (flip), FR-SP-005 (explicit YouTube unchanged), FR-SP-013, FR-SP-014, FR-SP-015
- NFR: NFR-SP-004 (prompt budget), NFR-SP-012 (plugin isolation)

### NFR-SP-007: Credential and token encryption at rest

#### Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution Amendment Record 2026-10-06 ("tokens are stored encrypted on-device (Keychain / `EncryptedLocalStorage`, Data Protection Complete)") and Feature Constraint 2; project constitution Standards (Security: sensitive data in encrypted app storage, Data Protection class Complete; key material never in plaintext)

#### Description
Every Spotify credential, token and account-state value **must** be encrypted at rest, exclusively in the platform-protected store. Measurable properties:

- **Storage location**: 100% of Spotify credential/token values live behind `EncryptedLocalStorage` (Keychain-backed) with Data Protection class **Complete**; **zero** Spotify values appear in `UserDefaults`, plists, plain files, caches or the repository — proven by a storage-placement test (mirroring the existing `StoragePlacementTests` discipline) across save, read-back, relaunch and clear.
- **Read-back**: values survive relaunch through the encrypted store only; a corrupt/unreadable store degrades to not-configured and an honest outcome (FR-SP-012), never a crash.
- **Unlink semantics**: after unlink (FR-SP-010), a storage sweep finds no recoverable Spotify credential; the store reports not configured.
- **No weak fallbacks**: no plaintext fallback is permitted if the secure store is unavailable — the feature degrades to not-linked with honest messaging instead.

#### Acceptance criteria

```gherkin
Feature: Spotify credentials encrypted at rest

  Scenario: Values are stored in the encrypted store only
    Given a Spotify credential and token are saved
    When storage placement is inspected across the app's stores
    Then every value is in the Keychain-backed encrypted store with Data Protection Complete
    And no Spotify value exists in UserDefaults or any plain file

  Scenario: Read-back survives relaunch
    Given a saved linked state
    When the app relaunches
    Then the linked state and credentials are read back from the encrypted store

  Scenario: An unavailable secure store degrades honestly, not insecurely
    Given the encrypted store cannot be read
    When a music request is made
    Then the account is treated as not configured
    And the user hears the honest line (no plaintext fallback, no crash)

  Scenario: After unlink nothing is recoverable
    Given the account is unlinked
    When the storage is swept
    Then no Spotify credential or token is found
```

#### Related
- FR: FR-SP-009 (store), FR-SP-010 (unlink), FR-SP-008 (linking)
- NFR: NFR-SP-002 (log safety), NFR-SP-009 (token lifecycle)

### NFR-SP-008: Deep-link URI construction hardening

#### Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` focus ("Deep-link/URI injection: `spotify:` URIs are built from remote-controlled search results — track names/IDs must be validated before URI construction; a crafted result must not open arbitrary schemes") and `security-test` focus ("hostile track titles/IDs producing only validated `spotify:` URIs"); feature constitution Safety & Compliance Delta (new integration-class concern)

#### Description
Track names and identifiers from provider search results are **remote-controlled input** and must never be trusted as URI components. Measurable properties:

- **Scheme allowlist**: 100% of URIs constructed by the Spotify tool use only the `spotify:` scheme (and, in the YouTube fallback, only the pre-existing `youtube:`/https YouTube URI shapes). A hostile corpus of crafted titles/IDs (scheme text, `//`, quotes, control characters, path traversal, percent-encoded traps, very long strings) yields **zero** constructions outside the allowlist and **zero** opens of a non-allowlisted scheme.
- **Component validation**: identifiers are matched against the expected Spotify identifier shape before use (rejected otherwise); query components are percent-encoded; titles are never composed into a URI; rejected results resolve to an honest outcome (FR-SP-012), never a partial URI.
- **No silent pass-through**: an invalid result is dropped or the request fails honestly — it is never forwarded as-is "because the provider returned it".
- **Verifiable corpus**: the tool's test suite includes a hostile-input corpus (the `YouTubeTool`-style URL/parse seams make this testable with no real network) with at least the cases above, each asserting the constructed URI or the rejection.

#### Acceptance criteria

```gherkin
Feature: Untrusted provider results cannot fabricate arbitrary URIs

  Scenario: A hostile identifier is rejected before URI construction
    Given a search result whose identifier contains scheme delimiters, control characters or path traversal
    When the tool builds the deep link
    Then no URI is constructed from the identifier, or the identifier is rejected
    And the outcome is an honest failure

  Scenario: A hostile title cannot leak into a URI or an open
    Given a search result title containing "spotify://", "https://", quotes and control characters
    When the tool builds and opens the deep link
    Then the constructed URI contains no title text
    And only the spotify: scheme is opened

  Scenario: The hostile corpus yields zero escapes
    Given the hostile-input test corpus (at least the cases above)
    When the tool is exercised over the whole corpus
    Then every constructed URI uses an allowlisted scheme
    And zero non-allowlisted schemes are opened
```

#### Related
- FR: FR-SP-007 (tool and deep-link construction), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-009 (OAuth redirect validation)

### NFR-SP-009: OAuth redirect validation and token lifecycle

#### Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` focus ("OAuth redirect validation: reject mismatched redirect URIs (token interception via app-scheme hijacking)"; "OAuth token lifecycle: scopes at sign-in, Keychain/EncryptedLocalStorage at rest, refresh handling, revocation on unlink; no tokens in logs"); feature constitution amendment (account-linking discipline); `GoogleAccountSession` precedent

#### Description
The Spotify OAuth implementation **must** hold the calendar-share discipline as measurable properties:

- **Redirect validation**: the callback redirect URI is validated by **exact match** against the registered callback; a mismatch is rejected and **no token, code or account state is stored** — zero exceptions. App-scheme callback hijack attempts therefore yield no token.
- **Scopes at sign-in**: the required scopes are requested during the sign-in/linking step itself (the `addScopes` lesson from calendar-share: consent-screen-only scopes produced 401s); a session with missing scopes is treated as not usable for the request and degrades honestly.
- **Token verification**: a token is verified before first trusted use; verification failure ⇒ not-linked treatment (FR-SP-010), never a blind retry loop.
- **Refresh and expiry**: token expiry/refresh is handled with a bounded, counted retry; a failed refresh produces an explicit status and an honest re-link prompt rather than a silent hang or a repeated failing call.
- **Revocation on unlink**: unlink revokes upstream where supported and always wipes locally (FR-SP-010).
- **Log safety**: zero tokens/authorization codes in logs across the linking, refresh, failure and unlink paths (NFR-SP-002).

#### Acceptance criteria

```gherkin
Feature: OAuth redirect validation and token lifecycle

  Scenario: A mismatched redirect is rejected with no token stored
    Given a callback whose redirect URI does not exactly match the registered callback
    When the linking service validates it
    Then the callback is rejected
    And no token, code or account state is stored
    And nothing sensitive is written to the log

  Scenario: Scopes are requested at sign-in
    Given the caregiver starts the linking flow
    When the authorization request is built
    Then the required Spotify scopes are requested in that flow
    And a session lacking them is treated as not usable, with an honest outcome

  Scenario: A failed refresh produces an explicit re-link state, not a loop
    Given a stored token that can no longer be refreshed
    When a music request needs Spotify
    Then the account is treated as not linked
    And a bounded number of retries is made, after which the user hears the honest line

  Scenario: Revocation on unlink is effective
    Given a linked account
    When the caregiver unlinks it
    Then the grant is revoked where the service supports it
    And the local credentials are wiped
```

#### Related
- FR: FR-SP-008 (linking), FR-SP-010 (unlink), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-002 (log safety), NFR-SP-007 (encryption at rest)

### NFR-SP-010: Accessibility of the new touch surfaces

#### Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Standards (Accessibility: large tap targets minimum 44x44 pt; minimum 18 pt body text; high-contrast text; voice-first UI); feature constitution "Integration Surfaces" (the Settings linking/status surface mirrors `YouTubeSettingsView`)

#### Description
The touch surfaces this feature adds — the Settings Spotify linking/status surface (FR-SP-016) — **must** meet the project's accessibility standards, because a caregiver and, in the family-helps pattern, potentially the elderly user interact with it. Measurable properties:

- **Tap targets**: every interactive control is at least **44 x 44 pt** (the project `DesignTokens.minTapTargetSize` pattern used by `YouTubeSettingsView`).
- **Text size**: body text at least **18 pt** equivalent and rendered through the appearance typography tokens, not fixed sizes; the surface respects the app's configured appearance/contrast.
- **Contrast**: text and controls use the appearance colour roles (no ad-hoc colours with insufficient contrast).
- **VoiceOver/labels**: every control carries a meaningful accessibility label (localized through the `spotify.*` key family); status is announced as status, not implied by colour alone.
- **Voice-first parity**: where a setting has a voice-reachable effect, the state change is honest and observable by voice (the status the router uses matches what the surface shows).

#### Acceptance criteria

```gherkin
Feature: The Spotify settings surface is accessible

  Scenario: Controls meet the tap-target minimum
    Given the Spotify Settings surface is presented
    When each interactive control is measured
    Then each is at least 44 x 44 pt

  Scenario: Text meets the minimum and uses appearance tokens
    Given the surface is presented at the app's default appearance
    When text styles are inspected
    Then body text is at least the 18 pt-equivalent token size
    And no fixed-size ad-hoc text style is used

  Scenario: Labels and status are announced
    Given VoiceOver is enabled
    When the surface is traversed
    Then every control has a localized label
    And the linked/not-linked status is announced as text, not only by colour

  Scenario: The surface's status matches the router's state
    Given the account is linked or unlinked
    When the surface's status and the router's acting state are compared
    Then they agree
```

#### Related
- FR: FR-SP-016 (settings surface)
- NFR: NFR-SP-005 (localisation)

### NFR-SP-011: Compliance and release gates

#### Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Standards (Security: TLS 1.2+ for outbound connections, encrypted storage, STRIDE at security design review; Privacy: logs without PII, log sanitiser; release gates) and the feature constitution amendment; workflow gates (`security-design-review` SECURITY-GO, `security-test` SECURITY-GO, `final-sign-off` T2 with the release-build log gate)

#### Description
The feature **must** satisfy the project's compliance and release gates, measurably:

- **Transport security**: every Spotify endpoint the app calls uses **TLS 1.2+** (no cleartext, no downgrade); the OAuth callback uses the declared app scheme and validated redirect (NFR-SP-009).
- **Store compliance**: the `spotify` query scheme and OAuth callback URL are declared correctly in `Info.plist` (`LSApplicationQueriesSchemes` for the installed-check) and the privacy disclosure (FR-SP-016) is in place; App Store policy obligations for the new integration are recorded in the release checklist.
- **Untrusted input**: provider-controlled text is treated as untrusted throughout (NFR-SP-008); injection detection at the project's `quarantine` level applies to any untrusted content that reaches a prompt (the music path should add none — NFR-SP-003).
- **Release gates**: `ios/tools/check-release-log-safety.sh` exits **0** and covers the new paths (NFR-SP-002); the pre-release device console/sysdiagnose check (project release gates) is performed on a Release build; the DV-* checklist (FR-SP-017) is recorded and passed.
- **Workflow gates**: `security-design-review` returns **SECURITY-GO** against the STRIDE focus areas of this feature, `security-test` returns **SECURITY-GO** against the evidence (token storage, log surface, hostile URIs, redirect validation, wipe on unlink), and `final-sign-off` (T2) records the release-gate results.

#### Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: All Spotify traffic is TLS 1.2 or better
    Given the Spotify OAuth, search and deep-link paths
    When their endpoints are inspected
    Then every network endpoint uses TLS 1.2+
    And no cleartext call exists

  Scenario: The release log-surface gate passes with the new paths covered
    Given the feature's code is in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And the new Spotify paths are within its coverage

  Scenario: The device-validation checklist is recorded and passed
    Given the feature is complete
    When the DV-* checklist (FR-SP-017) is inspected
    Then it is recorded with results from the reference device
    And all minimum items pass before sign-off

  Scenario: The security gates close on this feature's focus areas
    Given the design and implementation are complete
    When security-design-review and security-test run
    Then both return SECURITY-GO against the feature's threat focus areas
```

#### Related
- FR: FR-SP-017 (DV checklist), FR-SP-016 (disclosure), FR-SP-008, FR-SP-010
- NFR: NFR-SP-002 (log safety), NFR-SP-007, NFR-SP-008, NFR-SP-009

### NFR-SP-012: Plugin isolation and model-stack invariance

#### Metadata
- **Category:** Maintainability / Architecture
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 11 ("The feature ships as an `AssistantPlugin` (`SpotifyPlugin`) with no entanglement beyond the mapped `CommandRouter` seams, preserving the plugin-isolation architecture… No changes to the brain/router model stack") and "Out of scope" (no brain/router model-stack changes); project constitution Architecture Constraint 1 (on-device inference unchanged)

#### Description
The feature **must** keep the plugin-isolation architecture and the model stack untouched. Measurable properties:

- **Change surface**: the implementation diff is confined to the new Spotify files (plugin, tool, linking service, credential store), the mapped seams named in the feature constitution (`ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` tool seams, `YouTubeRoute.swift`, `KeywordIntentRule.swift`, `VoiceContactSearchRoute.swift`), `ios/ElderlyAssistant/App/` `AppCoordinator.swift` registration/wiring and `SettingsView.swift`/`SettingsTabs.swift`, the string catalog and `Info.plist` — plus tests. **Zero** changes to brain/model-stack files: no model catalog entries, no model weights, no router-model prompts beyond the pinned intent-wording change (NFR-SP-004).
- **Plugin conformance**: `SpotifyPlugin` conforms to the `AssistantPlugin` contract and registers through the existing plugin registry/`AppCoordinator` pattern; the registry test shows the action declared once.
- **Dormant seams**: every new router seam defaults to dormant (nil) like the `[YOUTUBE]` seams, so pre-existing construction sites compile and behave as before (NFR-SP-006).
- **Removability smoke**: with the Spotify plugin registration removed, the app compiles and the non-music paths behave as today — evidence that the entanglement is only the mapped seams.
- **No new backend**: nothing is provisioned server-side (NFR-SP-003).

#### Acceptance criteria

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

#### Related
- FR: FR-SP-006 (plugin), FR-SP-015 (routing intake)
- NFR: NFR-SP-003 (no new egress), NFR-SP-006 (no regression)

## Open decisions

Carried from the feature constitution verbatim; **not resolved here**. None blocks the
requirement set; each has an owner-visible resolution point.

### Carried from the feature constitution

**OD-S1 — Client-secret handling for the Spotify search flow (OPEN — architect / security
review).** *Verbatim:*

> Spotify client-credentials search requires the app to hold the client secret, and there is no
> backend. Choose: family-entered credential per the `YouTubeConfigStore`/`SearchConfigStore`
> Keychain precedent (never in the repo, header not URL, never logged — B2 is the binding
> precedent) versus PKCE-only options where the flow permits. The choice must satisfy constraint 2
> and interact cleanly with the dev-mode test-user limit (OD-S2).

Status in this requirement set: open. The requirements bind the storage/log discipline for
whichever path resolves — FR-SP-009 (encrypted store), NFR-SP-002 (log safety), NFR-SP-007
(encryption at rest). Resolve at: design-l1; recorded in `security-design-review` as well.

**OD-S2 — Spotify development-mode rollout and quota-extension plan (OPEN — owner / architect).**
*Verbatim:*

> The Spotify app in development mode works only for registered test users until a quota-extension
> request is approved. Define which accounts are registered during development and device
> validation, when and how the quota-extension request is filed, and what unregistered users
> experience before approval (honest messaging; no silent failure). This includes the console-side
> Spotify Developer Dashboard registration (client ID + secret, redirect URI, scopes) — the same
> class as the Google OAuth console work from calendar-share.

Status in this requirement set: open. The requirements bind honest behaviour for unregistered
users regardless — FR-SP-012 (no silent failure), FR-SP-016 (the Settings surface must not hide
the rollout reality). Resolve at: owner + design-l1.

**OD-S3 — Premium-account degradation path (OPEN — architect).** *Verbatim:*

> The exact UX and precedence when Spotify cannot perform playback: free-tier linked account,
> unlinked account, network/service failure, empty search. Which cases degrade to the `spotify:`
> deep-link fallback with clear messaging (constraint 1), which fall back to YouTube where it can
> serve (constraint 5), the exact localized copy for each, and how the both-provider search
> behaves in each case. Must satisfy constraints 1, 5, and 9 and the no-silent-failure rule.
> Resolve in design-l1/design-l2.

Status in this requirement set: open. The requirements bind that each path is non-silent and
honest — FR-SP-011 (free-tier deep-link fallback), FR-SP-012 (honest outcomes), FR-SP-004
(YouTube fallback) — while the composition and exact copy stay open. Resolve at: design-l1 /
design-l2.

### Assumptions recorded during this requirements pass

Recorded so nothing is silently assumed; all are design-input notes, not scope changes. The full
list is in the lock file (`assumptions`).

- The mapped integration surfaces exist as named in the feature constitution (YouTube pattern
  files, `CommandRouter` seams, `AppCoordinator` registration, Settings surfaces, string catalog);
  the scaffold probe (`specs/spotify-music-integration/init-report.md`) records only the scaffold
  step, not a code probe.
- The golden-corpus music block holds 15 utterances pinned to intent `music`
  (`ios/ElderlyAssistantTests/` `Services/Voice/GoldenCorpus.swift` lines 142–157), while the
  feature constitution says "16 utterances"; implementation reconciles the count against the
  source and records the result (NFR-SP-006).
- Provider identifiers used in the examples are synthetic placeholders; no real identifier,
  credential or secret is recorded in this requirement set.
- Exact user-facing copy for the degradation paths is OD-S3; the Nepali/English examples in this
  set are illustrative and localization-bound (the keys must exist in both languages —
  NFR-SP-005).
- The project's known pre-existing unit-test failures (unrelated to this feature) remain the
  baseline for NFR-SP-006; the feature's own suites must pass.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)" plus the workflow
scope comment's explicit non-goals) — recorded so nothing is silently half-built:

| Non-goal | Why it is stated |
|---|---|
| Cloud LLM on the music path | Voice intent parsing and routing stay on-device; music queries go to the provider APIs directly (NFR-SP-003). |
| Brain/router model-stack changes | No model, catalog, weights or routing-model changes beyond the pinned intent wording (NFR-SP-012, NFR-SP-004). |
| A new backend | The Spotify Web API is called directly from the app; nothing is provisioned on our side (feature constraint 6; NFR-SP-003). |
| Explicit-YouTube routing changes | 'युट्युबमा गीत चलाऊ' must still reach YouTube exactly as today (FR-SP-005). |
| Library/playlist edits and account modifications | Playback is read-only, user-initiated media control — no playlist mutations, no library writes (feature constitution Out of scope). |
| Emergency / medication / health surface changes | No change of any kind; no new safety path is added or altered by this feature. |
| Any network egress beyond the two provider APIs | No other host, no widened scope (NFR-SP-003). |
| Wake-word work, Android, and other deferred project items | Untouched by this feature. |

## How this set is verified downstream

| Gate | What it checks against this set |
|---|---|
| `design-l1` / `design-l2` | Resolve OD-S1 and OD-S3; address OD-S2 (owner/architect); design the musicStub replacement at `CommandRouter.swift:2640`, the `YouTubeRoute` fall-through interplay, the Spotify plugin/tool seams, the account-linking service and store, and the pinned golden-corpus music entries (NFR-SP-006). |
| `review-l2` | `review.decision == GO` against the component design and this set. |
| `security-design-review` | STRIDE focus: OAuth token lifecycle (NFR-SP-009, FR-SP-008/010), credential storage (NFR-SP-007, FR-SP-009), deep-link/URI injection (NFR-SP-008, FR-SP-007), redirect validation (NFR-SP-009), log sanitisation (NFR-SP-002), privacy disclosure (FR-SP-016); `SECURITY-GO` required. |
| `plan-tasks` / `implement` | Units trace back to `FR-SP-*` / `NFR-SP-*` ids; paired review and the 0.85 confidence threshold on implementation output; rework bound 5. |
| `security-test` | Evidence: token storage (NFR-SP-007), release log-surface coverage of the new paths (NFR-SP-002), hostile track titles/IDs producing only validated `spotify:` URIs (NFR-SP-008), OAuth redirect validation (NFR-SP-009), credential wipe on unlink (FR-SP-010); `SECURITY-GO` required. |
| `final-sign-off` | T2 + HIL; release gate `ios/tools/check-release-log-safety.sh` exits 0 (NFR-SP-002, NFR-SP-011); the DV-* checklist is recorded and passed on the reference device (FR-SP-017); the privacy disclosure is recorded (FR-SP-016). |
