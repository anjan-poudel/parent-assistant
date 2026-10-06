# Task Breakdown — Spotify Music Integration (v1)

**Feature:** `spotify-music-integration` (brownfield, iOS only)
**Worktree:** `elderly-ai-assistant-spotify-music-integration` · branch `feat/spotify-music-integration`
**Task:** `plan-tasks` (contract `task_breakdown_l3`) · **Agent:** `lead-engineer`
**Inputs:** `specs/design-l1.md`, `specs/design-l2.md`, `specs/review-l2.md` (GO),
`specs/security-design-review.md` (SECURITY-GO, no BLOCKERs), `specs/define-requirements.md`
(17 FR-SP + 12 NFR-SP), the feature constitution and the project `constitution.md`.

## Summary

- **Task groups:** 6 (TG-18..TG-23).
- **Total tasks:** 19 (T-106..T-124), 0 subtasks — every task is a single-owner leaf task
  (rationale under Marked gaps).
- **Estimated effort:** ~45.5 developer-days nominal; ~26–30 days elapsed with two
  developers. Critical-path floor ~24 days.
- **Critical path:** T-109 → T-110 → T-116 → T-119 → T-120 → T-123 → T-124.
- **Requirement coverage:** all 29 requirement documents (17 FR-SP, 12 NFR-SP) link from
  at least one task; map below.
- **Security work:** the three security requirements M-1..M-3 and verifications V-1..V-4
  from `security-design-review` are folded into named tasks; the nine evidence obligations
  each have a producer task and a DoD line; no BLOCKERs exist.
- **Release gate:** `ios/tools/` + `check-release-log-safety.sh` (wired into `ios/build.sh`)
  is binding; T-121 extends `FEATURE_ROOTS` with `Services/Spotify/`,
  `Voice/SpotifyTool.swift` and `Plugins/SpotifyPlugin.swift`.
- **Scope:** MVP only. No brain/router model-stack changes, no backend, no cloud LLM on
  the music path, no post-MVP items appear as tasks.

### Recommended execution order and parallelism

Dependencies point at lower IDs only, so ascending ID order is a valid topological order.
Waves below are file-disjoint within each wave.

| Wave | Tasks | Note |
|------|-------|------|
| W1 | T-106, T-108, T-109, T-112, T-114, T-115, T-117 | all foundational, no deps |
| W2 | T-107, T-110, T-111, T-113 | build on W1 |
| W3 | T-116 | router music path — the integration point |
| W4 | T-118, T-122 | plugin + corpus supersession |
| W5 | T-119, T-121 | wiring + release gate |
| W6 | T-120 | settings surface (needs the wired app) |
| W7 | T-123 | evidence bundle (needs gate + surface + guard) |
| W8 | T-124 | device validation (owner/device-dependent) |

### Critical path

```
T-109 ──► T-110 ──► T-116 ──► T-119 ──► T-120 ──► T-123 ──► T-124
 PKCE      session    router    wiring     settings   evidence   device record
 (4d)      (4d)       (6d)      (1.5d)     (3d)       (2d)       (3d)
```

T-108 sits beside T-109 (both feed T-110). The chain runs through the OAuth lifecycle
because every user-visible outcome depends on the session's truth; it then passes through
the single integration point (T-116), the wiring that makes it reachable (T-119), the
surface the caregiver uses (T-120), and closes on evidence and the device record. Nothing
on this chain parallelises: T-124 cannot start before the app is wired and the gate is in,
and the constitution's DV completion gate makes it non-skippable.

### Key risks

1. **T-116 (CRITICAL) — matrix breadth.** Twelve state x outcome rows, each with an
   honest spoken line and exactly one side effect. Mitigation: one named test per row, the
   never-stub pin, and the byte-identical explicit-YouTube assertion.
2. **T-114 (HIGH) — M-1 log regression.** The query-free variant must not change
   explicit-YouTube behaviour. Mitigation: baseline capture before the change; byte-identical
   assertion after; every entry of a music turn walked, not just the terminal one.
3. **T-118 (HIGH) — C-1 fragment trim.** The §27 text measures 376 characters against a
   341-character budget pin. Mitigation: trim while keeping the `spotify.play` / `query`
   tokens and the L2-D15 routing sentence; the length assertion is the tripwire.
4. **T-109 / T-110 (HIGH) — OAuth lifecycle.** Exact-match callback, single refresh,
   wipe-on-definitive-rejection. Mitigation: callback reject matrix test, refresh-bound
   call-count assertions, V-3 registry constraint, and the V-1 stance verification recorded
   into the evidence bundle before close.
5. **T-124 (HIGH) — owner/device dependency.** No simulator or agent substitute satisfies
   FR-SP-017. Mitigation: protocol authored early; execution scheduled against the owner's
   device and the OD-S2 registration; a failed item blocks completion.
6. **T-111 / T-124 (MEDIUM) — V-2 Dashboard scheme acceptance.** Contingency is a single
   shared constant plus the plist entry; owner action, re-verified on device (DV-2).
7. **T-113 (MEDIUM) — F-6 contact-veto trade-off.** A contact whose name contains a full
   music marker is unreachable via search-marker utterances; accepted, recorded at the
   documenting fixture.
8. **T-117 / T-120 (MEDIUM) — F-7 copy nuance.** The remove-confirm copy is stronger than
   matrix row 8 (search hand-off can still occur when YouTube cannot serve); if kept, the
   deviation is recorded explicitly.

### Owner actions (not agent work)

- **OD-S2 Dashboard registration:** owning account, client-ID paste-in, redirect-scheme
  registration (`sahayak-spotify://callback`, V-2), test-user registration, quota-extension
  filing, rollout-note copy approval, final sign-off. Marked as a dependency at T-109
  (M-3 scope step), T-111 (V-2), T-123 (scope-equality column) and T-124 (execution).
- **Device validation execution (T-124):** owner's device, real Spotify account; the
  constitution's DV completion gate is binding.
- **M-3 advisory:** decide trim vs justify for `user-read-playback-state` before the
  Dashboard registration step; the pinned scope test in T-109 is the tripwire.
- **Quota-window recording** (carried design note) stays with the owner's registration
  records.

### Condition fold-ins (review-l2)

| Condition | Where it lands |
|-----------|----------------|
| C-1 fragment ≤ 341 chars | T-118 — trim keeping tokens + L2-D15 sentence; length assertion is the tripwire |
| C-2 gate rule-scope wording | No implement task — documentation-only correction of the §20 sentence; recorded below under Marked gaps |
| C-3 golden block = 15 entries | T-122 — 15-entry block unedited, count annotated, guard added; T-116 must not edit the corpus |
| C-4 icon switch | T-115 — both exhaustive `Kind` switches (label and icon) get the case; no default arm |

### Security fold-ins (security-design-review)

| Item | Where it lands |
|------|----------------|
| M-1 query-free logging on music turns | T-114 (variant; explicit-YouTube byte-identical) + T-116 (usage; every-entry tool-log walk) |
| M-2 privacy copy names playback activity | T-117 (copy, both locales) + T-120 (surface) + T-123 obligation 7 |
| M-3 least-privilege scope trim | T-109 — pinned scope set; trim-or-justify before Dashboard registration; owner step marked |
| V-1 revocation-endpoint stance verification | T-110 — verified and recorded into the T-123 bundle before close |
| V-2 Dashboard scheme acceptance | T-111 (single-constant contingency + plist) + T-124 DV item; owner action |
| V-3 `providerError(code:)` constrained | T-109 — only OAuth-registry codes; unknown codes map to `malformedResponse` |
| V-4 `OpenOutcome` pinned to probe | T-107 — pinned to the `canOpenURL` probe result |

### Security evidence obligations → task and DoD line

| # | Obligation | Producer | DoD line |
|---|-----------|----------|----------|
| 1 | Artifact secret scan (repo + app image) | T-123 | "no secrets, tokens or query text inside the bundle"; scan output recorded |
| 2 | Keychain placement and post-wipe sweep | T-108 | "Keychain placement sweep test asserts zero credential material after wipe" |
| 3 | Callback reject matrix | T-109 | "Callback reject matrix complete: one named assertion per rejection class" |
| 4 | Refresh / revocation bounds | T-110 | "Refresh-bound and wipe-path tests assert call counts and stored state" |
| 5 | Hostile corpus | T-107 | "the full hostile corpus has one test case per fixture" |
| 6 | Log-surface checks incl. DV-7 capture | T-121 + T-124 | "zero sensitive material" gate fixture + DV-7 capture inspection |
| 7 | Disclosure copy vs data flow | T-117 + T-120 | "M-2 disclosure wording confirmed against FR-SP-016 in both languages" |
| 8 | Scope equality (requested = pinned = Dashboard) | T-109 (+ OD-S2) | "Scope-pinning test asserts exact equality with the least-privilege set" |
| 9 | Egress allowlist | T-116 | "no network call targets a host outside the two provider hosts" |

### Planning assumptions and marked gaps

- **ID numbering.** This tree accumulates across features (TG-01..TG-10, TG-14..TG-17 on
  disk from earlier features). New IDs continue at the global maxima: **TG-18..TG-23**,
  **T-106..T-124**. The generic TG-01/T-001 boilerplate in older templates is not
  applicable — those IDs are taken.
- **C-2 disposition.** Documentation-only correction of the §20 rule-scope sentence (rule 1
  all files, rule 2 engine files, rules 3–6 feature roots). No task exists for it because
  no code changes; T-121 implements the correct scoping and notes this.
- **No subtasks.** Every task is a single-owner leaf. The two natural split candidates —
  the router music path and the auth flow — share single files (`CommandRouter.swift`,
  the auth component files) and shared test files, so parallel subtasks would collide on
  the same working tree. Instead the router unit was carved into three sequential tasks
  (T-114, T-115, T-116) and the remaining tasks are wave-disjoint. If the implement phase
  needs finer units, it should split by file, not by scenario.
- **Design section references.** Task files cite component IDs (C-SP-01..16) as the stable
  anchor; section numbers are used only where the review reproduced them.
- **DV wording.** The constitution's DV table plus the design's expansion to DV-7 is the
  source of record for each item's text; T-124 adopts it verbatim rather than re-inventing
  item wording.
- **Gate scope.** The binding local release check is `ios/build.sh` including the
  log-safety gate; there is no Android/other-platform work.

## Contents

- [tasks/index.md](tasks/index.md) — all task groups and the ID numbering convention
- [TG-18 — Spotify Tool and Deep-Link Hardening](tasks/TG-18-spotify-tool-and-deep-link-hardening/index.md)
- [TG-19 — Account Linking, Credential Store and Session](tasks/TG-19-account-linking-credential-store-and-session/index.md)
- [TG-20 — Music Intent Intake and Contact Veto](tasks/TG-20-music-intent-intake-and-contact-veto/index.md)
- [TG-21 — Router Music Path, Degradation and Tool Log](tasks/TG-21-router-music-path-degradation-and-tool-log/index.md)
- [TG-22 — Plugin, Wiring, Settings and Localisation](tasks/TG-22-plugin-wiring-settings-and-localisation/index.md)
- [TG-23 — Release Gates, Security Evidence and Device Validation](tasks/TG-23-release-gates-security-evidence-and-device-validation/index.md)

### Task groups

| Group | Title | Tasks | Effort | Risk profile |
|-------|-------|-------|--------|--------------|
| TG-18 | Spotify Tool and Deep-Link Hardening | 2 | ~5.5 d | 2x HIGH |
| TG-19 | Account Linking, Credential Store and Session | 4 | ~11 d | 3x HIGH, 1x MEDIUM |
| TG-20 | Music Intent Intake and Contact Veto | 2 | ~3.5 d | 1x HIGH, 1x MEDIUM |
| TG-21 | Router Music Path, Degradation and Tool Log | 3 | ~8 d | 1x CRITICAL, 2x HIGH/MEDIUM |
| TG-22 | Plugin, Wiring, Settings and Localisation | 4 | ~9.5 d | 2x HIGH, 2x MEDIUM |
| TG-23 | Release Gates, Security Evidence and Device Validation | 4 | ~8 d | 3x HIGH, 1x MEDIUM |

### All tasks

| ID | Title | Group | Depends on | Effort | Risk |
|----|-------|-------|------------|--------|------|
| [T-106](tasks/TG-18-spotify-tool-and-deep-link-hardening/T-106-spotify-tool-search-and-play.md) | SpotifyTool search and remote-play client | TG-18 | — | L | HIGH |
| [T-107](tasks/TG-18-spotify-tool-and-deep-link-hardening/T-107-deep-link-grammar-and-hardening.md) | Deep-link grammar, hostile corpus and open probe | TG-18 | T-106 | M | HIGH |
| [T-108](tasks/TG-19-account-linking-credential-store-and-session/T-108-spotify-credential-store.md) | SpotifyCredentialStore with keychain-resident encrypted record | TG-19 | — | M | HIGH |
| [T-109](tasks/TG-19-account-linking-credential-store-and-session/T-109-spotify-auth-flow-pkce.md) | SpotifyAuthFlow: PKCE authorize, callback validation, exchange, refresh | TG-19 | — | L | HIGH |
| [T-110](tasks/TG-19-account-linking-credential-store-and-session/T-110-spotify-account-session.md) | SpotifyAccountSession: link, refresh, unlink, status | TG-19 | T-108, T-109 | L | HIGH |
| [T-111](tasks/TG-19-account-linking-credential-store-and-session/T-111-web-auth-session-and-plist.md) | ASWebSpotifyAuthSession presenter and Info.plist declarations | TG-19 | T-109 | M | MEDIUM |
| [T-112](tasks/TG-20-music-intent-intake-and-contact-veto/T-112-keyword-intent-rule-music.md) | KeywordIntentRule music domain, markers and extractor | TG-20 | — | L | HIGH |
| [T-113](tasks/TG-20-music-intent-intake-and-contact-veto/T-113-contact-search-music-veto.md) | VoiceContactSearchRoute music veto | TG-20 | T-112 | S | MEDIUM |
| [T-114](tasks/TG-21-router-music-path-degradation-and-tool-log/T-114-youtube-query-free-logging.md) | Query-free logging variant for reused YouTube helpers (M-1) | TG-21 | — | M | HIGH |
| [T-115](tasks/TG-21-router-music-path-degradation-and-tool-log/T-115-tool-log-spotify-kind.md) | LocalToolLogStore spotify kind and tool-log view switches (C-4) | TG-21 | — | S | MEDIUM |
| [T-116](tasks/TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md) | Router music path: seams, matrix, intake and pins | TG-21 | T-106, T-107, T-110, T-112, T-113, T-114, T-115 | XL | CRITICAL |
| [T-117](tasks/TG-22-plugin-wiring-settings-and-localisation/T-117-localisation-catalog.md) | Localisation catalog: 20 keys ne/en incl. privacy disclosure (M-2) | TG-22 | — | M | HIGH |
| [T-118](tasks/TG-22-plugin-wiring-settings-and-localisation/T-118-spotify-plugin-and-prompt-fragment.md) | SpotifyPlugin and trimmed prompt fragment (C-1) | TG-22 | T-106, T-107, T-110, T-117 | L | HIGH |
| [T-119](tasks/TG-22-plugin-wiring-settings-and-localisation/T-119-app-coordinator-wiring.md) | AppCoordinator wiring for the Spotify services | TG-22 | T-110, T-111, T-116, T-118 | M | MEDIUM |
| [T-120](tasks/TG-22-plugin-wiring-settings-and-localisation/T-120-settings-surface.md) | Settings linking surface, unlink and privacy disclosure | TG-22 | T-110, T-117, T-119 | L | MEDIUM |
| [T-121](tasks/TG-23-release-gates-security-evidence-and-device-validation/T-121-release-log-safety-gate.md) | Release log-safety gate FEATURE_ROOTS extension | TG-23 | T-107, T-110, T-118 | S | HIGH |
| [T-122](tasks/TG-23-release-gates-security-evidence-and-device-validation/T-122-golden-corpus-supersession.md) | Golden-corpus supersession mechanics and pinned-surface guard (C-3) | TG-23 | T-116 | M | HIGH |
| [T-123](tasks/TG-23-release-gates-security-evidence-and-device-validation/T-123-security-evidence-bundle.md) | Security evidence bundle (nine obligations) | TG-23 | T-120, T-121, T-122 | M | HIGH |
| [T-124](tasks/TG-23-release-gates-security-evidence-and-device-validation/T-124-device-validation-protocol.md) | DV-1..DV-7 device-validation protocol and record (FR-SP-017) | TG-23 | T-119, T-120, T-121 | L | HIGH |

### Requirement → task trace

| Requirement | Tasks |
|-------------|-------|
| FR-SP-001 music requests start real playback | T-116 |
| FR-SP-002 both-provider search | T-106, T-116 |
| FR-SP-003 Spotify preferred when linked and capable | T-116 |
| FR-SP-004 YouTube fallback when Spotify cannot serve | T-114, T-116 |
| FR-SP-005 explicit YouTube requests unchanged | T-112, T-114, T-116 |
| FR-SP-006 SpotifyPlugin / AssistantPlugin twin | T-118, T-119 |
| FR-SP-007 SpotifyTool search and deep link | T-106, T-107, T-118 |
| FR-SP-008 account linking by caregiver | T-109, T-110, T-111, T-119, T-124 |
| FR-SP-009 encrypted Spotify credential store | T-108 |
| FR-SP-010 unlink wipes credentials and revokes | T-108, T-110, T-120 |
| FR-SP-011 free-tier deep-link degradation | T-107, T-116, T-124 |
| FR-SP-012 honest outcomes, no silent failure | T-106, T-110, T-115, T-116 |
| FR-SP-013 keyword intent rule music domain | T-112 |
| FR-SP-014 contact-search veto parity | T-113 |
| FR-SP-015 music request intake in route ladder | T-116 |
| FR-SP-016 settings linking and privacy disclosure | T-117, T-120 |
| FR-SP-017 device validation recorded and passed | T-124 |
| NFR-SP-001 provider search responsiveness | T-106 |
| NFR-SP-002 log safety | T-106, T-107, T-108, T-109, T-110, T-111, T-114, T-115, T-116, T-118, T-120, T-121, T-123, T-124 |
| NFR-SP-003 no new network egress | T-106, T-109, T-116 |
| NFR-SP-004 prompt budget preserved | T-118, T-122 |
| NFR-SP-005 localisation | T-117, T-120 |
| NFR-SP-006 no regression | T-112, T-113, T-114, T-116, T-122 |
| NFR-SP-007 credential encryption at rest | T-108 |
| NFR-SP-008 deep-link URI hardening | T-107 |
| NFR-SP-009 OAuth redirect and token lifecycle | T-109, T-110, T-111 |
| NFR-SP-010 accessibility of new surfaces | T-120 |
| NFR-SP-011 compliance and release gates | T-111, T-121, T-123 |
| NFR-SP-012 plugin isolation and model-stack invariance | T-116, T-118, T-119, T-122 |
