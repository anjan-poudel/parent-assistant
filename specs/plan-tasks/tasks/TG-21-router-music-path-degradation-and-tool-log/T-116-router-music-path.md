# T-116: Router music path — seams, matrix, intake and pins

## Metadata
- **Group:** [TG-21 — Router Music Path, Degradation and Tool Log](index.md)
- **Component:** C-SP-06 `CommandRouter` music path (seams, `selectMusicOutcome`, intake)
- **Agent:** dev
- **Effort:** XL
- **Risk:** CRITICAL
- **Depends on:** [T-106](../TG-18-spotify-tool-and-deep-link-hardening/T-106-spotify-tool-search-and-play.md), [T-107](../TG-18-spotify-tool-and-deep-link-hardening/T-107-deep-link-grammar-and-hardening.md), [T-110](../TG-19-account-linking-credential-store-and-session/T-110-spotify-account-session.md), [T-112](../TG-20-music-intent-intake-and-contact-veto/T-112-keyword-intent-rule-music.md), [T-113](../TG-20-music-intent-intake-and-contact-veto/T-113-contact-search-music-veto.md), [T-114](T-114-youtube-query-free-logging.md), [T-115](T-115-tool-log-spotify-kind.md)
- **Blocks:** [T-119](../TG-22-plugin-wiring-settings-and-localisation/T-119-app-coordinator-wiring.md), [T-122](../TG-23-release-gates-security-evidence-and-device-validation/T-122-golden-corpus-supersession.md), [T-123](../TG-23-release-gates-security-evidence-and-device-validation/T-123-security-evidence-bundle.md), [T-124](../TG-23-release-gates-security-evidence-and-device-validation/T-124-device-validation-protocol.md)
- **Requirements:** [FR-SP-001](../../../../define-requirements/FR/FR-SP-001-music-requests-start-real-playback.md), [FR-SP-003](../../../../define-requirements/FR/FR-SP-003-spotify-preferred-when-linked-and-capable.md), [FR-SP-004](../../../../define-requirements/FR/FR-SP-004-youtube-fallback-when-spotify-cannot-serve.md), [FR-SP-005](../../../../define-requirements/FR/FR-SP-005-explicit-youtube-requests-unchanged.md), [FR-SP-011](../../../../define-requirements/FR/FR-SP-011-free-tier-deeplink-degradation.md), [FR-SP-012](../../../../define-requirements/FR/FR-SP-012-honest-outcomes-no-silent-failure.md), [FR-SP-015](../../../../define-requirements/FR/FR-SP-015-music-request-intake-in-route-ladder.md), [NFR-SP-002](../../../../define-requirements/NFR/NFR-SP-002-log-safety.md), [NFR-SP-003](../../../../define-requirements/NFR/NFR-SP-003-no-new-network-egress.md), [NFR-SP-012](../../../../define-requirements/NFR/NFR-SP-012-plugin-isolation-and-model-stack-invariance.md)

## Description
Replaces the music stub with the real path: three dormant-nil seams (`spotifyAccountSession`, `spotifyTransport`, `spotifyLinkOpener`) defaulting nil exactly like the shipped 646–648 pattern, `selectMusicOutcome` implementing the full 12-row §13 matrix, `fireMusicRequest` / `deliverMusicLine` / `emitSpotify` with closed vocabularies and empty metadata, music intake into the route ladder (FR-SP-015), deletion of the stub sites, and the pin tests: never-stub, byte-identical explicit-YouTube, tool-log contract, egress allowlist.

## Acceptance criteria

```gherkin
Feature: Router music path

  Scenario: A linked capable account plays the requested song remotely (matrix row 1)
    Given a linked session and a capable provider and a transport that accepts the play attempt
    When a music request arrives through the route ladder
    Then the tool searches and the play attempt succeeds
    And the honest success line is spoken and the keyless YouTube leg was never pre-opened

  Scenario: Play failure degrades to the deep link (matrix row 2)
    Given a linked session whose play attempt fails with 403, 404 or a network error
    When the request runs
    Then the outcome falls to the deep-link open through the link-opener seam
    And the spoken line reflects the actual outcome

  Scenario: Search failure degrades to YouTube or the honest line (matrix rows 6 and 7)
    Given a linked session whose search returns empty or fails
    When the request runs while YouTube is serveable
    Then the fallback plays through the query-free helper variant from T-114
    And when YouTube cannot serve, the honest failure line is spoken instead

  Scenario: Unlinked, revoked and refresh-failure states speak honest lines (matrix rows 8, 10, 11)
    Given the unlinked state, an invalid_grant rejection, and a transport-level refresh failure
    When a music request arrives in each state
    Then each row takes its defined treatment: search hand-off where applicable, wipe plus unlinked treatment on the revocation, record kept with the search-failure shape on the transport failure
    And no row ends silently

  Scenario: No implemented outcome falls back to the stub
    Given every state and failure combination the matrix defines
    When the music path resolves each one
    Then no path emits the command_music_stub event or the stub speech
    And every path ends in exactly one spoken line

  Scenario: Explicit-YouTube turns stay byte-identical
    Given the shipped explicit-YouTube fixtures
    When they run through the updated router
    Then their routing decisions and output are byte-identical to the baseline capture

  Scenario: Tool-log, metadata and egress pins hold
    Given a music turn that exercises search, play and fallback
    When its tool-log entries, observability events and network calls are inspected
    Then each entry follows the §21 contract: empty query and response except the terminal honest line, and empty metadata
    And no network call targets a host outside the api.spotify.com and accounts.spotify.com pair
```

## Implementation notes
- File: `ios/ElderlyAssistant/` + `Voice/CommandRouter.swift`. Seams are init-parameter additions with nil defaults; every pre-existing construction site and test must compile unchanged (dormant-nil discipline, NFR-SP-012).
- Delete the stub: the `case .music:` arm, the `command_music_stub` event and the `router.musicStub` speech are replaced by the real path; the never-stub pin test asserts their absence after the matrix runs.
- Intake: music requests enter at the shipped ladder sites; ordering keeps explicit-YouTube behaviour identical (rule-level exclusion from T-112 plus ladder order here). L2-R1: the keyless YouTube leg is not pre-opened when Spotify wins.
- Rows 4, 6, 7, 8 use the T-114 query-free logging variant; M-1 usage is verified by walking every entry of a music turn, not only the terminal one.
- Tool log: `logToolRequest` stays nil-store-safe (no-op), new kind from T-115; closed event vocabularies; `metadata: [:]` everywhere; query `""` and response `""` except the terminal honest line.
- Egress allowlist pin (security evidence obligation 9): the turn's URL set must equal the two provider hosts; nothing else, no analytics.
- The 12-row matrix is the spec of record (§13); implement row by row with a named test per row in `CommandRouterMusicTests` (mirroring `CommandRouterYouTubeTests` and `YouTubeRouteTests`).
- Status and capability data come from T-110's `Status` only; no local re-derivation.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests; one named test per matrix row plus the never-stub, byte-identical and egress pins
- [ ] No PII in logs — every touched log call site classified; zero query text, token or provider body on any music path
- [ ] `logToolRequest` nil-store no-op behaviour unchanged
- [ ] `ios/build.sh` passes for the touched targets
