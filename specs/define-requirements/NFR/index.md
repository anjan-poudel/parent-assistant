# Non-Functional Requirements — Spotify Music Integration (v1)

12 non-functional requirements. IDs are namespaced `NFR-SP-NNN` to avoid colliding with the
project-level `NFR-NNN` set in the root stakeholder brief (`requirements.md`) — the same
convention the live-camera-translation feature uses with `NFR-LCT-NNN` and profile-interview with
`NFR-PI-NNN`. This page covers the `spotify-music-integration` set (`NFR-SP-*`) only; the earlier
feature files remain in this folder and are not part of this feature's requirements or lock.

| ID | Title | Category | Priority |
|----|-------|----------|----------|
| [NFR-SP-001](NFR-SP-001-provider-search-responsiveness.md) | Provider search responsiveness and timeout budget | Performance | MUST |
| [NFR-SP-002](NFR-SP-002-log-safety.md) | Log safety — no credentials, queries or provider bodies in logs | Privacy / Security | MUST |
| [NFR-SP-003](NFR-SP-003-no-new-network-egress.md) | No new network egress; music stays off any cloud LLM | Privacy | MUST |
| [NFR-SP-004](NFR-SP-004-prompt-budget-preserved.md) | Prompt token budget preserved | Reliability / Maintainability | MUST |
| [NFR-SP-005](NFR-SP-005-localisation.md) | Localisation of all Spotify strings (ne/en) | Localisation | MUST |
| [NFR-SP-006](NFR-SP-006-no-regression.md) | No regression to existing flows | Reliability | MUST |
| [NFR-SP-007](NFR-SP-007-credential-encryption-at-rest.md) | Credential and token encryption at rest | Security | MUST |
| [NFR-SP-008](NFR-SP-008-deeplink-uri-hardening.md) | Deep-link URI construction hardening | Security | MUST |
| [NFR-SP-009](NFR-SP-009-oauth-redirect-and-token-lifecycle.md) | OAuth redirect validation and token lifecycle | Security | MUST |
| [NFR-SP-010](NFR-SP-010-accessibility-of-new-surfaces.md) | Accessibility of the new touch surfaces | Accessibility | MUST |
| [NFR-SP-011](NFR-SP-011-compliance-and-release-gates.md) | Compliance and release gates | Compliance | MUST |
| [NFR-SP-012](NFR-SP-012-plugin-isolation-and-model-stack-invariance.md) | Plugin isolation and model-stack invariance | Maintainability / Architecture | MUST |

## Coverage of the security-relevant surfaces (workflow focus areas)

| Surface (workflow `security-design-review` / `security-test` focus) | Covered by |
|---|---|
| OAuth token lifecycle: scopes at sign-in, encrypted at rest, refresh, revocation on unlink, no tokens in logs | [NFR-SP-009](NFR-SP-009-oauth-redirect-and-token-lifecycle.md), [FR-SP-008](../FR/FR-SP-008-spotify-account-linking-by-caregiver.md), [FR-SP-010](../FR/FR-SP-010-unlink-wipes-credentials-and-revokes.md), [NFR-SP-007](NFR-SP-007-credential-encryption-at-rest.md) |
| Client-secret handling for the client-credentials search flow (OD-S1 — open): bundled secrets extractable; family-entered credential per the SearchConfigStore precedent is the candidate pattern | [FR-SP-009](../FR/FR-SP-009-encrypted-spotify-credential-store.md), [NFR-SP-002](NFR-SP-002-log-safety.md) (property binding either OD-S1 resolution) |
| Deep-link/URI injection: remote-controlled track names/IDs validated before URI construction; a crafted result must not open arbitrary schemes | [NFR-SP-008](NFR-SP-008-deeplink-uri-hardening.md), [FR-SP-007](../FR/FR-SP-007-spotifytool-search-and-deeplink.md) |
| OAuth redirect validation: mismatched redirect URIs rejected (token interception via app-scheme hijacking) | [NFR-SP-009](NFR-SP-009-oauth-redirect-and-token-lifecycle.md), [FR-SP-008](../FR/FR-SP-008-spotify-account-linking-by-caregiver.md) |
| Log sanitisation: music queries, provider responses and error bodies must not reach logs (check-release-log-safety.sh coverage) | [NFR-SP-002](NFR-SP-002-log-safety.md), [NFR-SP-011](NFR-SP-011-compliance-and-release-gates.md) |
| Privacy disclosure: music-query/playback data flow to Spotify disclosed | [FR-SP-016](../FR/FR-SP-016-settings-linking-and-privacy-disclosure.md), [NFR-SP-011](NFR-SP-011-compliance-and-release-gates.md) |
| Credential wipe/revocation on unlink | [FR-SP-010](../FR/FR-SP-010-unlink-wipes-credentials-and-revokes.md), [NFR-SP-007](NFR-SP-007-credential-encryption-at-rest.md) |
| No new egress / no cloud LLM on the music path | [NFR-SP-003](NFR-SP-003-no-new-network-egress.md) |

## Related
- [FR index](../FR/index.md) — 17 functional requirements
- [Requirements index](../index.md)
- [Consolidated copy](../../define-requirements.md)
