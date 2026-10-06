# Requirements — Spotify Music Integration

Feature: `spotify-music-integration` (worktree branch `feat/spotify-music-integration`, worktree
`elderly-ai-assistant-spotify-music-integration`).
Status: **submitted for owner HIL approval** (risk tier T1, per the feature workflow's
`define-requirements` task); no owner amendment is recorded at lock time — the locked snapshot in
`define-requirements.lock.yaml` is the drift-detection baseline.
Task: `define-requirements`, agent `ba`, contract `requirements_doc` + `requirements_lock`.
Date: 2026-10-06.

## Summary
- Functional requirements: **17** (`FR-SP-001` … `FR-SP-017`)
- Non-functional requirements: **12** (`NFR-SP-001` … `NFR-SP-012`)
- Areas covered: Music Playback / Router, Provider Selection, Degradation (free tier, unlinked,
  network failure, empty search), Spotify Tool and Deep Links, Plugin Architecture, Account
  Linking (caregiver OAuth), Credential Storage, Intent Routing (deterministic keyword rule,
  contact-search veto, route-ladder intake), Settings / Privacy Disclosure, Validation /
  Completion Gate. NFR categories: Performance, Privacy, Security, Reliability, Maintainability,
  Localisation, Accessibility, Compliance.
- v1 scope: replace the first-class music stub (`router.musicStub`, `case .music:` in
  `ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` ~line 2640) with real playback
  (FR-SP-001); search both providers with Spotify winning whenever linked and capable
  (FR-SP-002/003), YouTube for explicit YouTube requests (FR-SP-005) and the Spotify-cannot-serve
  fallback (FR-SP-004); `SpotifyPlugin` + `SpotifyTool` + account linking + encrypted credential
  store (FR-SP-006 … FR-SP-010); honest degradation for free tier / unlinked / network failure /
  empty search with the `spotify:` deep-link fallback (FR-SP-011/012); deterministic routing work
  (FR-SP-013/014/015); Settings linking/status with the privacy disclosure (FR-SP-016); and the
  DV-* device-validation completion gate (FR-SP-017).
- Primary sources of truth: `specs/spotify-music-integration/constitution.md` (feature
  constitution — Purpose & Scope, routing & degradation contract, Feature Constraints 1–12, the
  2026-10-06 amendment record, Open Decisions OD-S1/S2/S3, DV-* completion gate);
  `specs/spotify-music-integration/workflow.yaml` (the `define-requirements` scope comment);
  project `constitution.md` (amended 2026-10-06: Architecture Constraint 1 and the
  Required-integrations list now include Spotify).
- Read-only stakeholder briefs: `requirements.md` — its §4 "Out of Scope — Post-MVP" table lists
  "Music and bhajan playback" at lines 675–676 as Post-MVP; that placement is **superseded** by
  this feature (the project constitution is the operative document; the supersession is recorded
  in FR-SP-001). `requirements-dementia-supplement.md` is context only and changes nothing here.

## Contents
- [FR/index.md](FR/index.md) — functional requirements (17 files, `FR-SP-001` … `FR-SP-017`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (12 files, `NFR-SP-001` … `NFR-SP-012`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of
  this set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `FR/` and `NFR/` folders also still contain the previously shipped
live-camera-translation (`FR-LCT-*`, `NFR-LCT-*`) and profile-interview (`FR-PI-*`, `NFR-PI-*`)
requirement files, left in place untouched; the indexes on this page and the lock cover the
`spotify-music-integration` set only.

### Functional requirements
Core flip and provider selection: [FR-SP-001](FR/FR-SP-001-music-requests-start-real-playback.md),
[FR-SP-002](FR/FR-SP-002-both-provider-search.md),
[FR-SP-003](FR/FR-SP-003-spotify-preferred-when-linked-and-capable.md),
[FR-SP-004](FR/FR-SP-004-youtube-fallback-when-spotify-cannot-serve.md),
[FR-SP-005](FR/FR-SP-005-explicit-youtube-requests-unchanged.md) ·
Surfaces: [FR-SP-006](FR/FR-SP-006-spotifyplugin-assistantplugin-twin.md),
[FR-SP-007](FR/FR-SP-007-spotifytool-search-and-deeplink.md),
[FR-SP-008](FR/FR-SP-008-spotify-account-linking-by-caregiver.md),
[FR-SP-009](FR/FR-SP-009-encrypted-spotify-credential-store.md),
[FR-SP-010](FR/FR-SP-010-unlink-wipes-credentials-and-revokes.md) ·
Degradation: [FR-SP-011](FR/FR-SP-011-free-tier-deeplink-degradation.md),
[FR-SP-012](FR/FR-SP-012-honest-outcomes-no-silent-failure.md) ·
Routing: [FR-SP-013](FR/FR-SP-013-keyword-intent-rule-music-domain.md),
[FR-SP-014](FR/FR-SP-014-contact-search-veto-parity.md),
[FR-SP-015](FR/FR-SP-015-music-request-intake-in-route-ladder.md) ·
Settings and completion gate: [FR-SP-016](FR/FR-SP-016-settings-linking-and-privacy-disclosure.md),
[FR-SP-017](FR/FR-SP-017-device-validation-checklist-recorded-and-passed.md)

### Non-functional requirements
[NFR-SP-001](NFR/NFR-SP-001-provider-search-responsiveness.md) responsiveness ·
[NFR-SP-002](NFR/NFR-SP-002-log-safety.md) log safety ·
[NFR-SP-003](NFR/NFR-SP-003-no-new-network-egress.md) no new egress ·
[NFR-SP-004](NFR/NFR-SP-004-prompt-budget-preserved.md) prompt budget ·
[NFR-SP-005](NFR/NFR-SP-005-localisation.md) localisation ·
[NFR-SP-006](NFR/NFR-SP-006-no-regression.md) no regression ·
[NFR-SP-007](NFR/NFR-SP-007-credential-encryption-at-rest.md) encryption at rest ·
[NFR-SP-008](NFR/NFR-SP-008-deeplink-uri-hardening.md) URI hardening ·
[NFR-SP-009](NFR/NFR-SP-009-oauth-redirect-and-token-lifecycle.md) OAuth lifecycle ·
[NFR-SP-010](NFR/NFR-SP-010-accessibility-of-new-surfaces.md) accessibility ·
[NFR-SP-011](NFR/NFR-SP-011-compliance-and-release-gates.md) compliance gates ·
[NFR-SP-012](NFR/NFR-SP-012-plugin-isolation-and-model-stack-invariance.md) plugin isolation

## Open decisions
Carried from the feature constitution verbatim; **not resolved here**. None blocks the
requirement set; each has an owner-visible resolution point. Full text in the consolidated doc's
Open decisions section.

| # | Decision | Status in this requirement set | Resolve at |
|---|---|---|---|
| OD-S1 | **Client-secret handling for the Spotify search flow** — family-entered credential per the `YouTubeConfigStore`/`SearchConfigStore` Keychain precedent vs PKCE-only options where the flow permits; must satisfy constraint 2 and interact cleanly with OD-S2 | Open — architect / security review. The requirements bind the storage/log discipline for whichever path resolves (FR-SP-009, NFR-SP-002, NFR-SP-007) | design-l1 (recorded in `security-design-review` too) |
| OD-S2 | **Spotify development-mode rollout and quota-extension plan** — which accounts are registered during development/device validation, when the quota-extension request is filed, and what unregistered users experience before approval (honest messaging, no silent failure); includes the Developer Dashboard registration (client ID + secret, redirect URI, scopes) | Open — owner / architect. The requirements bind honest behaviour for unregistered users regardless (FR-SP-012, FR-SP-016) | owner + design-l1 |
| OD-S3 | **Premium-account degradation path** — exact UX and precedence when Spotify cannot perform playback (free tier, unlinked, network/service failure, empty search): which cases degrade to the `spotify:` deep-link fallback, which fall back to YouTube, the exact localized copy, and how both-provider search behaves in each case; must satisfy constraints 1, 5 and 9 | Open — architect. The requirements bind that each path is non-silent and honest (FR-SP-011, FR-SP-012, FR-SP-004); composition stays open | design-l1 / design-l2 |

### Assumptions recorded during this requirements pass
Recorded so nothing is silently assumed; all are design-input notes, not scope changes. The full
list is in the lock file (`assumptions`).

- The mapped integration surfaces exist as named in the feature constitution (YouTube pattern
  files, `CommandRouter` seams, `AppCoordinator` registration, Settings surfaces, string catalog);
  the scaffold probe (`specs/spotify-music-integration/init-report.md`) records the folder, not a
  code probe.
- The golden-corpus music block holds 15 utterances pinned to intent `music` at
  `ios/ElderlyAssistantTests/` `Services/Voice/GoldenCorpus.swift` lines 142–157, while the
  feature constitution says "16 utterances"; implementation reconciles the count against the
  source and records the result (NFR-SP-006).
- Provider identifiers used in examples are synthetic placeholders; no real identifier, credential
  or secret is recorded in this requirement set.
- Exact user-facing copy for the degradation paths is OD-S3; the Nepali/English examples in this
  set are illustrative and localization-bound (the keys must exist, NFR-SP-005).

## Out of scope
Explicitly not in scope (feature constitution "Out of scope (must not change)" plus the workflow
scope comment's explicit non-goals) — recorded so nothing is silently half-built:

- **Cloud LLM on the music path** — voice intent parsing and routing stay on-device; music
  queries go to the provider APIs directly (NFR-SP-003).
- **Brain/router model-stack changes** — no model, catalog, weights or routing-model changes
  beyond the pinned intent wording (NFR-SP-012, NFR-SP-004).
- **A new backend** — the Spotify Web API is called directly from the app; nothing is provisioned
  on our side (NFR-SP-003).
- **Explicit-YouTube routing changes** — 'युट्युबमा गीत चलाऊ' must still reach YouTube exactly as
  today (FR-SP-005).
- **Library/playlist edits and account modifications** — playback is read-only, user-initiated
  media control; no playlist mutations, no library writes (feature constitution Out of scope).
- **Emergency / medication / health surfaces** — no change of any kind; no new safety path is
  added or altered by this feature.
- **Any network egress beyond the two provider APIs** — no other host, no widened scope
  (NFR-SP-003).
- **Wake-word work, Android, and other deferred project items** — untouched by this feature.

## Related
- Consolidated copy: [`../define-requirements.md`](../define-requirements.md)
- Locked snapshot: [`../define-requirements.lock.yaml`](../define-requirements.lock.yaml)
- Feature constitution: [`../spotify-music-integration/constitution.md`](../spotify-music-integration/constitution.md)
- Feature workflow (scope comment): [`../spotify-music-integration/workflow.yaml`](../spotify-music-integration/workflow.yaml)
