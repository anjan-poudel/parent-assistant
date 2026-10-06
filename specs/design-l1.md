# L1 Architecture — Spotify Music Integration (v1)

**Feature:** `spotify-music-integration` · **Branch:** `feat/spotify-music-integration` (worktree `elderly-ai-assistant-spotify-music-integration`, requirements baseline `bc1c495`)
**Task:** `design-l1` (agent `sdd-architect`) · **Contract:** `architecture_l1` → `specs/design-l1.md`
**Date:** 2026-10-06 · **Status:** for review; feeds `design-l2`, `review-l2` and `security-design-review`
**Resolves:** OD-S1 (client-secret handling → §4 ADR-SP-01), OD-S3 (degradation precedence → §12)
**Drafts:** OD-S2 (dev-mode rollout / quota extension → §5, owner decision, final T2 sign-off)

**Inputs folded in.** The feature constitution (`specs/spotify-music-integration/` `constitution.md`, including the 2026-10-06 amendment record, the Routing & Degradation Contract, Feature Constraints 1–12, and the DV completion gate); `specs/define-requirements.md` (FR-SP-001…FR-SP-017, NFR-SP-001…NFR-SP-012, 95 Gherkin scenarios); the root `constitution.md` (Architecture Constraint 1 as amended; Standards; release gates; Agent Principles); `specs/spotify-music-integration/` `workflow.yaml` (design-l1 scope comment and the `security-design-review` focus areas); and the source seams re-verified against the worktree for this document (§7).

**Path convention.** Paths are repo-relative. Where one path would exceed the release-log sanitiser's token limit (SEC-002: 40 consecutive characters from the class `[A-Za-z0-9/+=]`), it is split across adjacent code spans; `ios/ElderlyAssistant/Services/` + `Voice/SpotifyTool.swift` denotes the single path obtained by joining the spans with `/`. The split is a sanitizer convention only — do not read the `+` as concatenation in code.

---

## Overview

### 1. Purpose and the broken-to-working flip

Today a voice music request that reaches the music intent hits a first-class stub: the `case .music:` branch in `ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift` (line 2640) emits `command_music_stub` and speaks `router.musicStub` — "Music isn't ready yet. Coming soon." / "संगीत सुविधा अहिले तयार छैन। चाँडै आउनेछ।". Nothing plays. This feature replaces that branch with a real playback path: for a bare music request ('भजन बजाऊ', 'गीत चलाऊ', 'play a song') both providers are searched and **Spotify wins whenever it is linked and capable** (Feature Constraint 9); YouTube serves explicit YouTube requests exactly as today and the Spotify-cannot-serve fallback. Every path ends in an explicit, localized, spoken outcome — never the stub, never silence, never a fabricated "playing" claim.

The primary user is the elderly Nepali-first voice user; the family member/caregiver performs account linking and sees the Settings disclosure. The elderly user never touches OAuth, a client ID or a secret.

The architectural shape is deliberately small and brownfield-faithful: a new deterministic music stage beside the existing YouTube stage in the voice route ladder, a `SpotifyTool` that is a structural twin of `YouTubeTool`, a `SpotifyPlugin` that is a structural twin of `YouTubePlugin`, an account-linking service that follows the `GoogleAccountSession` (calendar-share) precedent, one encrypted session record, no backend, no model-stack change, and no network egress beyond the two provider APIs.

### 2. Scope

**In scope (v1):**

- Stub replacement: `case .music:` in `CommandRouter.swift` routes into the real music path; the stub wording is unreachable on any music branch (FR-SP-001).
- Both-provider search with Spotify preference for bare music requests; explicit YouTube requests untouched; YouTube fallback where YouTube can serve (FR-SP-002/003/004/005).
- `SpotifyPlugin` (`AssistantPlugin` twin), `SpotifyTool` (Spotify Web API search + validated `spotify:` deep links), a Spotify account-linking service and one encrypted credential/account store (FR-SP-006/007/008/009/010).
- Honest degradation for free tier, unlinked account, network failure, empty search, revoked grant and app-absent — with the `spotify:` deep-link fallback (FR-SP-011/012); precedence resolved in §12 (OD-S3).
- Deterministic routing work: the music domain in `KeywordIntentRule`, the music veto in `VoiceContactSearchRoute`, and music intake in the route ladder (FR-SP-013/014/015).
- Settings linking/status surface with the privacy disclosure (FR-SP-016), full ne/en localization, observability and encrypted tool-log integration, release-gate coverage, and the DV-* completion gate (FR-SP-017).

**Out of scope (must not change):** cloud LLM on the music path; brain/router model-stack changes; any new backend; explicit-YouTube routing changes; playlist/library/account mutations (playback is read-only, user-initiated media control); emergency/medication/health surfaces; any network egress beyond the two provider APIs; wake-word, Android and other deferred project items. (Requirement set "Out of scope" table, mirrored.)

### 3. Inherited binding constraints → design response

| # | Feature constraint (verbatim gist) | Design response | Where |
|---|---|---|---|
| 1 | Premium reality is an NFR — honest degradation, free-tier/unlinked degrades to `spotify:` deep link, never silent | Capability model + deep-link fallback + `spotify.appMissing`; full precedence ladder | §11, §12, §13 |
| 2 | Credential discipline — scopes at sign-in, verification, encrypted storage, header never URL, never logged (B2/T-050) | PKCE-only (no secret at all, ADR-SP-01); one encrypted session record; gate coverage | §4, §15, §16, §22 |
| 3 | Prompt budget — `IntentPromptTests` pins the budget; YouTube zero-prompt-token discipline is the model | Core prompt stays byte-identical; deterministic music rule is the zero-token path; plugin fragment mirrors YouTube's | §17, ADR-SP-09 |
| 4 | On-device stance — provider APIs only, never cloud LLM, no new egress | Egress allowlist (two hosts); no cloud call on the music path | §21, §22 |
| 5 | Must-not-break — explicit YouTube unchanged; Spotify-unavailable/unlinked → YouTube; golden churn only where recorded | YouTube stage untouched and ordered first; fallback reuses `fireYouTubePlay`; deliberate supersession recorded | §9, §12, §17 |
| 6 | No new backend | Direct app → Spotify Web API calls | §15, §21 |
| 7 | Rollout constraint — dev-mode test users until quota extension; unregistered still honest | OD-S2 draft (§5) + `spotify.rolloutLimited` honest path | §5, §23 |
| 8 | Device expectation — Spotify app installed for the deep-link fallback; without it honest messaging | `canOpenURL` pre-check + `spotify.appMissing` attempt-time line | §12, §14 |
| 9 | Preference semantics — both searched, Spotify wins when linked and capable; YouTube only for explicit or Spotify-cannot-serve | Capability predicate + selection rule | §11 |
| 10 | Constitution moves with the spec | Amendment already recorded in both constitutions (2026-10-06) — change set includes it | §7 |
| 11 | Plugin isolation — `AssistantPlugin`, no entanglement beyond mapped seams, no model-stack change | Component boundaries; dormant seams; removability smoke test | §19, §25, §27 |
| 12 | Localization discipline — all strings ne/en via `spotify.*` keys | Key inventory + no hardcoded literals | §23 |

### 4. Decision log

Full ADR entries for the load-bearing decisions; each records the alternatives and why they lost. OD-S1's full resolution is ADR-SP-01 below. OD-S3's full resolution is the ladder + matrix in §12 (ADR-SP-02 records the decision line). OD-S2 is intentionally **not** decided here — see §5.

| ADR | Decision (one line) |
|---|---|
| ADR-SP-01 | **OD-S1 resolved: PKCE-only public client.** No app-held client secret anywhere. Client ID (public) bundled in `Info.plist`; Authorization Code + PKCE (S256) in `ASWebAuthenticationSession`; search and playback run on the linked user's access token. |
| ADR-SP-02 | **OD-S3 resolved:** precedence ladder + state × outcome matrix (§12). Spotify outcome whenever linked and capable (remote control or deep-link hand-off); YouTube fallback wherever YouTube can serve; explicit honest line otherwise. |
| ADR-SP-03 | Music intake is a new deterministic stage in the existing ladder, implemented through the `KeywordIntentRule` domain switch; no new route stage type, no changes to `YouTubeRoute` internals. |
| ADR-SP-04 | Music query extraction mirrors `YouTubeRoute.extractQuery` (marker-drop with full grapheme enumerations); query cap 100 chars (mirrors `maxQueryLength`), configurable. |
| ADR-SP-05 | Both providers are searched **concurrently** when both are askable; Spotify is selected when it resolved a usable result and is capable of at least one outcome; per-provider budget 8 s (NFR-SP-001). |
| ADR-SP-06 | The YouTube fallback reuses `fireYouTubePlay(query:)` verbatim, so the fallback outcome is byte-identical to the explicit-YouTube outcome (FR-SP-004's "pinned YouTube behaviour"). |
| ADR-SP-07 | `SpotifyPlugin` handles the model-classified (`pluginAction`/interpreted) path; the router owns the deterministic path and the whole degradation ladder. The plugin never calls the network itself — it uses `SpotifyTool` + the session seams. |
| ADR-SP-08 | Token storage is **one** encrypted record `spotify.session` (Codable struct under one `EncryptedLocalStorage` key), not one key per value: atomic write, single-key wipe, one `keychainResidentKeys` addition. |
| ADR-SP-09 | The core intent prompt stays **byte-identical** (SHA-256 digest pins + the exact 2,506-char assertion in `IntentPromptTests` force this); the music intent wording already exists in `IntentPrompt`; `SpotifyPlugin` contributes a prompt fragment the size of YouTube's, budget-checked where plugin composition is pinned. |
| ADR-SP-10 | Golden corpus: the music block stays at its **true 15 entries** (lines 143–157; the constitution's "16" is reconciled in §7); the deliberate dispatch-level supersession (stub → real path) is recorded in a new `CommandRouterMusicTests`, which pins that no music branch speaks `router.musicStub`. |
| ADR-SP-11 | `case .music:` in `dispatchInterpreted` routes to the same music path; the `router.musicStub` key is retained in the catalog but has no reachable call site. |
| ADR-SP-12 | Deep-link hardening: track IDs must match the Spotify base62 identifier shape before URI construction; query components percent-encoded; titles never composed into URIs; only the `spotify:` scheme is ever produced (plus the pre-existing YouTube shapes in the fallback). |
| ADR-SP-13 | Remote control is gated by the stored `product` (premium) plus a bounded play attempt; HTTP 403/404 degrade to the deep link, a 401 triggers exactly one refresh per request. |
| ADR-SP-14 | Unlink wipes locally (single-key delete). Spotify exposes no third-party token-revocation endpoint; the design says so honestly instead of pretending a remote revoke happened. A provider-side `invalid_grant` is treated as unlinked. |
| ADR-SP-15 | **Stricter than the YouTube convention:** no Spotify tool-log entry carries the query text or a provider body at any time (query "" / response "" on success; the query-free spoken line on failure). NFR-SP-002 and the workflow security focus ("music queries … must not reach logs") win over copying `YouTubeTool`'s raw-query habit. |
| ADR-SP-16 | Concurrency: all Spotify-path mutable state is main-actor-confined; searches run off-main through the transport seam and marshal results back; one in-flight music attempt is superseded (not cancelled) by the next turn, matching the existing YouTube stage behaviour. |

#### ADR-SP-01 — OD-S1: PKCE-only public client, no app-held client secret

**Decision.** The Spotify integration is a **public client** using Authorization Code + PKCE (S256), performed by the caregiver in `ASWebAuthenticationSession`. The only credential in the change set is the **client ID**, which is public by definition and bundled in `Info.plist` as `SpotifyClientID` (mirroring the `GIDClientID` pattern). There is **no client secret anywhere**: not in the repository, not in `Info.plist`, not in a Settings field, not in the encrypted store, not in any log. Search executes with the linked user's access token (`/v1/search` is valid with a user token); the client-credentials flow — the only flow that would need the secret — is not used.

**Why this over the family-entered credential (the `YouTubeConfigStore`/`SearchConfigStore` Keychain precedent):**

- **Bundled secrets are extractable.** Any secret shipped in the binary or pushed to the device by a family member is recoverable by anyone with the device or the artifact; PKCE removes the secret from the device entirely, which is the strongest possible answer to security-review focus "bundled secrets are extractable".
- **PKCE defeats app-scheme callback hijack.** A malicious app that registers or intercepts the callback scheme still cannot exchange the stolen code without the `code_verifier` (S256), so the redirect is not a transferable credential by itself.
- **One flow serves both surfaces.** The same authorization yields search and (Premium) playback-control scopes; the family never manages a credential, and the OD-S2 test-user registration applies to the linked user regardless of which flow is chosen — the interaction OD-S1 was required to keep clean.
- **PKCE is Spotify's documented mobile flow** for apps without a backend (constraint 6: no backend). The client-secrets flow would additionally age badly: a secret in a shipped app cannot be rotated without a release.

**Storage/use/rotation discipline (constraint 2, unchanged by the choice):**

- The client ID is a constant; no rotation mechanism is needed or wanted. Tokens are the sensitive material and live only in the encrypted store (§16).
- Any credential presented to Spotify travels in an `Authorization` request header — never a URL, query parameter or deeplink (B2/T-050 precedent).
- No token, code, verifier or authorization header value reaches any log, telemetry event or diagnostic surface (§22); the release-log gate covers the new paths.

**Verifiability (for `security-design-review` / `security-test`):**

- A scan of the built artifact finds no secret-shaped value and no `client_secret` usage; the authorize URL carries `code_challenge_method=S256`; the token exchange carries `code_verifier`.
- The redirect is validated by exact match; a mismatched/hijacked callback stores nothing (NFR-SP-009).
- The `Settings` surface has **no** credential/secret field (the FR-SP-009 "family-entered credential path" branch is not exercised; the store holds tokens only).

**Recorded contingency (not implemented).** If device validation finds a hard reason user-token search cannot be used (e.g. an unexpected API restriction), the fallback is the family-entered client ID + secret held in the encrypted store, exactly per the `SearchConfigStore` precedent (`credentialField` secure entry, header not URL, never logged). That would be a design-l2 change with a `security-design-review` re-run; it is not built today, and nothing in this design blocks it later (the store and the Settings surface have a natural place for the field).

### 5. OD-S2 — draft for owner approval (final T2 sign-off)

**Status: DRAFT — architect proposal for an owner decision.** Nothing in this section is decided. Every value the architect cannot know is marked `[OWNER INPUT — …]`; no account, email, business detail or Dashboard field is invented. The final decision is recorded at `final-sign-off` (T2 + HIL) at the latest; the Dashboard registration steps must be completed **before** any device validation that links a real account (DV-1/DV-2 need a working link).

**Context.** A Spotify app in Development mode works only for accounts explicitly added to the app's allowlist ("User Management") in the Developer Dashboard; all other accounts get an error from Spotify during authorization. A quota-extension request moves the app to an extended mode with a service cap; until it is approved, only registered users are served. No requirement in this feature depends on external users; the requirements bound honest behaviour for unregistered users (FR-SP-012, FR-SP-016) regardless.

**(a) Which accounts are registered during development and device validation.**

| Purpose | Account class | Value |
|---|---|---|
| Developer account owning the Dashboard app | The owner's Spotify account | `[OWNER INPUT — the Spotify account email that will own the Dashboard app]` |
| DV-1 / DV-2 (flip + Spotify-preferred selection; the remote-control happy path needs Premium) | The Anzaan reference-device household account, Premium | `[OWNER INPUT — household Spotify account email; confirm Premium, else DV-2 must use the free-tier deep-link path and DV-1 accepts the deep-link outcome]` |
| DV-4 free-tier honest line + (recommended) a non-Premium negative case | A free-tier test account (may be a second account, or the household account temporarily downgraded if that is acceptable) | `[OWNER INPUT — free-tier test account, if any]` |
| Any additional caregiver/development device enrolled for linking tests | Additional test-user email(s) | `[OWNER INPUT — additional emails, if used]` |

Design-side requirements that do not depend on the owner: the linking flow must treat an unregistered account's authorize failure (or denial) as an explicit `linkFailed` status with the rollout note — never a half-link, never silence (FR-SP-008, FR-SP-016).

**(b) Quota-extension request: criteria and timeline.**

File the request when **all** of the following hold (architect-proposed criteria; owner may amend):

1. DV-1…DV-5 pass in Development mode on the Anzaan reference device (FR-SP-017) — evidence that the integration is real, not a probe.
2. Dashboard metadata is final and matches the shipped build: app name `[OWNER INPUT — final name]`, the exact redirect URI (§15; the single constant registered here is the same constant validated in code), the final scope list (`user-read-private`, `user-read-playback-state`, `user-modify-playback-state`; unchanged by the PKCE resolution), and the app description.
3. The Settings privacy disclosure (§23) and the release checklist's App Store privacy entries (NFR-SP-011) are in place, so any privacy-policy URL the form asks for exists and is accurate.
4. No further OAuth/scope changes are planned (a scope change after approval re-opens the review).

Timeline: **before the first distribution outside the registered test set** (i.e. before any TestFlight/App Store build reaches unregistered users) — the same class of prerequisite as the calendar-share Google OAuth console work. Owner files it; the project tracks Spotify's review outcome as a release gate input. `[OWNER INPUT — Spotify's current review window is not known to the architect; record the actual SLA observed at filing.]`

**(c) What unregistered users experience before approval.**

- **Linking attempt by an unregistered account:** Spotify shows its own error during authorization; our flow maps any non-success to the explicit `spotifySettings.linkFailed` status plus the rollout note (`spotifySettings.rolloutNote`) — the caregiver sees that the account isn't yet allowed, not a silent failure and not a fake "connected".
- **Music request while unlinked** (which is what every unregistered user is): the normal unlinked degradation applies — YouTube serves where it can, the `spotify:` search hand-off is offered where it can open, otherwise the honest `spotify.notLinked` line. The user still gets music (YouTube path); nothing is promised about Spotify.
- **Settings surface:** while the app is in Development mode, the Spotify settings surface must not hide the reality (FR-SP-016): the rollout note text is shown whenever the Dashboard app is still in development mode. `[OWNER INPUT — approve the note's final copy; design-l2 / implement finalize the ne/en strings.]`
- **Never:** a silent failure, a fabricated success, or a claim that Spotify played when it did not (FR-SP-012).

**(d) Spotify Developer Dashboard registration checklist (console-side).**

| # | Step | Value / owner |
|---|---|---|
| 1 | Create the app in the Spotify Developer Dashboard | `[OWNER INPUT — app name; use a recognizable product name]` |
| 2 | Add redirect URI | `sahayak-spotify://callback` — **exact string**, one constant shared by Dashboard, `Info.plist` and code. If the Dashboard refuses a custom scheme, re-shape per the scheme note in §15 and record the final value here. |
| 3 | Request scopes | `user-read-private`, `user-read-playback-state`, `user-modify-playback-state` (requested at sign-in; §15) |
| 4 | Client ID | Copy into `Info.plist` as `SpotifyClientID` `[OWNER INPUT — the ID value itself is a public identifier; copy it from the Dashboard into the plist at implementation time, not into any document]` |
| 5 | Client secret | **NOT USED** — PKCE public client (ADR-SP-01). Do not paste it anywhere; if the Dashboard displays one, ignore it. |
| 6 | User Management (test users while in Development mode) | Add the accounts from (a) `[OWNER INPUT — the list]` |
| 7 | Quota-extension request form | File per (b); business/contact details `[OWNER INPUT — owner's business info and privacy-policy URL]`; use-case description drafted in design-l2 as an appendix `[design-l2]` |

**Owner sign-off line (to be completed at final-sign-off):** `[OWNER INPUT — approve/amend sections (a)–(d); record the decision and date.]`

### 6. Success criteria and the DV completion gate

Success (feature constitution, restated as designed-for outcomes): music requests that hit the stub today start real playback; Spotify wins when linked and capable; every degradation path speaks an honest localized line; explicit YouTube requests behave exactly as before; a Nepali request for music produces sound on the Anzaan device.

**DV-1…DV-5 plan (FR-SP-017).** A DV-style checklist is recorded with the feature (pattern: `specs/LCT-device-validation-protocol.md` → the feature records `specs/SP-device-validation-protocol.md` with results alongside, naming device and build). Minimum coverage, with the design's expected observations:

| Item | Steps (summary) | Expected |
|---|---|---|
| DV-1 | Unlinked + YouTube configured; say 'भजन बजाऊ' on a Release build | A real outcome (YouTube path or deep-link hand-off); **never** the stub line; sound can start via the provider app |
| DV-2 | Linked Premium (registered test user); say 'गीत चलाऊ' | Both providers searched; Spotify selected; remote playback line names Spotify; music plays |
| DV-3 | Linked Spotify + YouTube key both present; say 'युट्युबमा गीत चलाऊ' | YouTube path exactly as before; music/Spotify path does not also handle it |
| DV-4 | Free-tier linked / unlinked / airplane-mode network failure / empty-search utterance; each repeated | Each path speaks its explicit localized line (or the YouTube fallback); no silence; no false "playing" claim |
| DV-5 | Nepali session end-to-end on Anzaan for DV-1…DV-4 scenarios | All spoken lines are Nepali; no English fallback |
| DV-6 (added by this design) | Spotify app removed from the device; free-tier or unlinked request | Honest app-absent/fallback behaviour per §12; no crash, no false claim |
| DV-7 (added by this design) | Console/sysdiagnose capture during DV-1…DV-6 | Zero tokens, credentials, query text or provider bodies (NFR-SP-002, project pre-release device check) |

An unmet item is recorded as failing and blocks the completion claim (FR-SP-017); deviation requires explicit owner resolution.

### 7. Source verification and reconciliations

All seams used by this design were re-read from the worktree at this task's baseline and the line numbers below are the verified ones (differences from the feature constitution's prose are reconciled here):

| Seam | Verified fact |
|---|---|
| Music stub | `case .music:` at `CommandRouter.swift:2640`; `command_music_stub` event and `router.musicStub` at 2642–2643. Neighbouring stubs (`router.healthNotAvailable`, `router.featureNotYet`) are separate branches and are untouched. |
| YouTube seams | `youtubeConfigStore` / `youtubeTransport` / `youtubeLinkOpener` declared optional in `CommandRouter.swift:646–648`; injected at 689–691; assigned 709–711 (dormant-nil pattern). |
| Route ladder order | sanity guard → emergency (761) → confirmation (771) → safety net → `VoiceContactSearchRoute.decide` (898) → directions → alarms/timers (963–1031) → briefing (1035) → full-article → news → `YouTubeRoute.decide` (1146) → `KeywordIntentRule.match` (1189) → topic pre-answer (1329) → sensitive-call → interpreter → `dispatchInterpreted`. |
| YouTube execution | `fireYouTubePlay(query:)` at 2386: keyless path opens the search deeplink (synchronous, no network) and speaks `youtube.openingSearch`; keyed path fetches via `YouTubeTool.fetchTopResult` and speaks `youtube.playing` (title spoken-only, never logged); failures via `deliverYouTubeFailure` speak `youtube.notFound` / `youtube.unavailable`. |
| Tool log | `logToolRequest(kind:query:response:outcome:statusCode:durationMs:)` at 2544; nil store = no-op; the log store is the encrypted `LocalToolLogStore` only, never observability. `Kind` currently `weather/search/youtube` — `.spotify` is added (§16). |
| Plugin path | `handlePluginCommand` at 2922; registry registration `registry.register(YouTubePlugin(configStore:))` at `AppCoordinator.swift:2058`; store wiring at 3715–3717 (`URLSession.shared`, `SystemCallLinkOpener()`); lazy store precedent at 1341. |
| Link-opener seam | `CallLinkOpening` (`Services/Intents/CallLinks.swift:37`) already has **both** `canOpenURL(_:) -> Bool` and `open(_:)`; `SystemCallLinkOpener` hops to main. The capability pre-check needs **no seam change**. |
| Transport seam | `LocalToolTransport` (`Services/Voice/LocalToolTransport.swift:13`) = `fetchData(for:) async throws -> (Data, URLResponse)`; `YouTubeTool.fetchTimeoutSeconds = 8` (line 59). |
| Intent prompt | Music wording already present (`IntentPrompt` schema list includes `"music"`; the music mapping line; the music intent bullet) — no core-template change is needed. |
| Settings | `YouTubeSettingsView` struct actually begins at `SettingsView.swift:768` (the constitution cites 759–840 as the neighborhood); `SettingsTabs` maps `.youtube` at 123/159/419 with `hiddenSheetRows` including `.youtube`. |

**Reconciliation 1 — golden music count: 15, not 16.** `GoldenCorpus.swift` lines 143–157 contain exactly 15 `.init(…, intent: "music")` entries (verified by source scan; the constitution's "16 utterances" is stale). `GoldenCorpusTests.testCorpusHasAtLeast15EntriesPerIntent` requires ≥15 per intent, so the block must not shrink. Implementation keeps the 15 and records the counted result (NFR-SP-006's own instruction).

**Reconciliation 2 — FR-SP-002 scenario 3 ("neither provider can be asked") vs the keyless YouTube path.** The shipped keyless YouTube behaviour intentionally opens the search deeplink and speaks `youtube.openingSearch` — the code's own comment calls it "the whole feature, not a degraded mode". YouTube is therefore "askable" without an API key whenever the link-opener seam is present. "Neither provider can be asked" occurs only when the YouTube seams are dormant (no transport and no opener) **and** Spotify is unlinked/incapable; the explicit localized line is then spoken. Implementers must not "fix" the keyless path into a failure — the scenario's requirement ("no silent outcome; an explicit localized line") is satisfied by the pinned behaviour.

**Reconciliation 3 — prompt digest pins are byte-level.** `IntentPromptTests` pins SHA-256 digests of the rendered no-term prompt (two fixtures) and asserts the exact 2,506-character baseline. Any core-template edit — even a byte-neutral-intent music wording tweak — breaks those pins. This design therefore treats the core prompt as immutable for this feature (ADR-SP-09) and notes that `SpotifyPlugin`'s composed fragment is checked wherever plugin-composed budgets are asserted (`[design-l2]`: confirm no existing suite composes the real registry set against the pinned ceiling; if one does, the Spotify fragment must fit inside it).

**Reconciliation 4 — the June amendment ordering constraint (constraint 10).** The root-constitution amendment (Constraint 1 + Required integrations, 2026-10-06) is already recorded in the same change as the feature spec (both constitutions carry it). The implement change set must not remove or reword it; if the amendment text needs adjustment it moves with the feature spec.

---

## Architecture

### 8. System context and end-to-end flow

```
 (voice turn)                         on-device only
 [STT] → transcript → CommandRouter.route(transcript:)
                          │  existing stages… (emergency/contacts/alarms/…)
                          │
                          ├─ YouTubeRoute.decide (explicit marker) ─→ fireYouTubePlay ─→ YouTube (unchanged today)
                          │
                          └─ KeywordIntentRule.match ─ .youtube ─→ fireYouTubePlay (unchanged)
                                                     └ .music  ─→ fireMusicRequest(query:)   ◄── NEW deterministic stage
                                                                        │
                    ┌───────────────────────────────────────────────────┤   both providers askable?
                    │                                                   │
             Spotify leg (linked)                                YouTube leg (mirrors fireYouTubePlay)
                    │                                                   │
        SpotifyTool.search ── api.spotify.com ──┐                      YouTubeTool.fetchTopResult ── googleapis
                    │                            │                      │            (or keyless deeplink open)
        select: Spotify wins if usable+capable   │                      │
                    │                            │                      │
     remote play ─→ api.spotify.com/v1/me/player/play          youtube://watch or search deeplink
        │ fail                                    │                      │
     deep link spotify:track:<id> ─→ Spotify app  │                      │
        │ fail                                    │                      │
     YouTube fallback ────────────────────────────┘                      │
                    │                                                   │
                    └────────────── one explicit localized spoken outcome ┘
 (interpreter / pluginAction "spotify.play" path) ─→ SpotifyPlugin.handle ─→ same router-owned ladder
```

**Egress (complete list):** `accounts.spotify.com` (OAuth token endpoint), `api.spotify.com` (search, `/v1/me`, player endpoints), plus the pre-existing YouTube endpoints on the YouTube leg. Nothing else — no LLM provider, no new host (NFR-SP-003).

**Turn-level flow (linked, Premium, happy path):** pre-ack spoken → both searches fire concurrently → Spotify resolves a usable result → remote play attempt → success → `spotify.playing` with the real track title (spoken only). Every leg is bounded by the configurable per-call budget (§20) and every branch ends in a spoken line (§12 matrix).

### 9. Voice route intake ladder (FR-SP-005, FR-SP-013, FR-SP-014, FR-SP-015)

**Design: one new deterministic stage inside the existing `KeywordIntentRule` domain switch, plus a veto in the contact-search stage. No new stage ordering, no `YouTubeRoute` internals change.**

1. **Contact search (existing stage at 898)** — `VoiceContactSearchRoute.decide` gains a **music veto** immediately after the existing YouTube veto: when the transcript contains a music-family token (the shared family constant, below), the contact-search decision is vetoed. Vetoes are token-presence-based, mirroring the existing YouTube veto (`"youtube"` token / `"युट्युब"` substring); the music veto uses the shared music-family tokens (`भजन`, `गीत`, `गाना`, `संगीत`, `सङ्गीत`, Latin `music`, `song`, `bhajan`). This cannot over-block a genuine contact request: a request without a music marker is untouched (FR-SP-014 scenario 2).
2. **Explicit YouTube (unchanged, 1146)** — `YouTubeRoute.decide` fires exactly as today and returns; the music stage is never reached for a YouTube-marked utterance. The music rule additionally refuses any utterance carrying a YouTube marker (belt and braces; FR-SP-013 scenario 2).
3. **New music domain (1189 switch)** — `KeywordIntentRule.Domain` gains `case music`; the rules array is ordered `news → youtube → music → appLaunch → festivalDate`. The router's existing domain switch gains `case .music:` → `fireMusicRequest(query: KeywordIntentRule.musicQuery(from: preText) ?? preText)`. This is the zero-prompt-token path (constraint 3): bare music never consults the model.
4. **Model-classified music (`dispatchInterpreted`, 2640)** — `case .music:` is replaced: `fireMusicRequest(query: interpretedQuery ?? KeywordIntentRule.musicQuery(from: transcript))`, where `interpretedQuery` is the command's query entity when the model supplied one. The `command_music_stub` emission and the `router.musicStub` call are deleted (key retained in the catalog, ADR-SP-11).
5. **No double-handling** — every firing stage returns; an utterance is handled by exactly one of the YouTube path and the music path; the ordering makes it deterministic (YouTube marker → stage 2; bare music → stage 3; model-classified music that slipped past both → stage 4).

**Extraction** (mirrors `YouTubeRoute.extractQuery`): drop leading/trailing music-family markers and the play/listen verb family using full grapheme-cluster enumerations (Devanagari matra/virama fusion means the families are enumerated explicitly, exactly as `youtubeVerbFamily` does today; a substring match on a base form is not sufficient — see the Swift Devanagari grapheme lesson recorded in project memory). Containment drops include the YouTube tokens. Result capped at 100 characters (mirrors `YouTubeRoute.maxQueryLength`), configurable (§20). Empty extraction falls back to the whole marker-stripped transcript, and finally to `preText`, so the search always has a query.

**Music rule shape** (mirrors the youtube rule exactly): `musicKeywords` × `musicVerbFamily` (relaxed co-occurrence), with the existing narration guard discipline (narration-style mentions must not fire; the youtube rule's narration comment is the model). Verb families are the shared play/listen/sing enumerations (reuse or deliberately duplicate the youtube verb-family constants within the file — one source of truth for both rules where practical). **Deliberate conservative choice:** noun-only musical phrases (e.g. 'देवीको भजन') do **not** fire the deterministic stage; they reach the same music path through the interpreter's already-present `"music"` intent (stage 4). This keeps the rule's precision high and avoids over-capture; it is recorded because FR-SP-013's scenario set only pins verb-bearing requests. `[design-l2]: exact keyword/verb enumerations, with the same test style as `KeywordIntentRuleTests`.]

### 10. Music query extraction details

- Extractor: `KeywordIntentRule.musicQuery(from:)` — pure, static, deterministic, unit-tested with the golden families and the YouTube-marker exclusion.
- Marker-drop lists: leading/trailing music nouns and verb forms; Devanagari enumeration includes the fused forms (`चलाऊ`, `चलाउनुस्`, `बजाऊ`, `बजाउनुस्`, `लगाऊ`, `लगाउनुस्`, `सुनाऊ`, `सुनाउनुस्`, `गाउनुस्`, plus the लगाउँ twin family the youtube route carries) — the full lists are finalized in design-l2 against the same fixtures the youtube route tests use.
- The extractor never strips a token that would leave an empty query if the utterance's remaining text is non-empty; worst case the full `preText` is used.
- Extraction happens on-device only; the query goes to provider APIs (`api.spotify.com` search `q=` parameter, percent-encoded; YouTube leg's existing behaviour) — never to a cloud LLM (NFR-SP-003).

### 11. Both-provider search, capability predicates, selection (FR-SP-002, FR-SP-003, constraint 9)

**Askability** (based on the shipped dormant-seam pattern — a missing seam simply means that provider is not asked):

| Predicate | Definition |
|---|---|
| `spotifyAskable` | A session record exists in the credential store (linked) **and** the Spotify transport seam is present. A refresh that ends in `invalid_grant` or a verification failure flips the account to unlinked *before* this check (FR-SP-010). |
| `youtubeAskable` | `youtubeConfigStore?.apiKey != nil` (keyed API search) **or** `youtubeLinkOpener != nil` (the keyless search-deeplink path — see Reconciliation 2). |

**Request-time behaviour:** when both are askable, both searches are fired **concurrently** (two child tasks; results joined before selection). When only one is askable, only that one is searched (an unavailable provider must not block the other — FR-SP-002 scenario 2). When neither is askable, the honest line is spoken immediately (FR-SP-002 scenario 3 semantics; §12 row 10).

**Outcome capability** (evaluated from the search result and the account state):

| Predicate | Definition |
|---|---|
| `spotifyUsable` | The Spotify search returned a validated result (shape-checked ID; §14) — not empty, not malformed. |
| `spotifyRemoteCapable` | Stored `product == "premium"` **and** a valid access token exists at attempt time. |
| `spotifyDeepLinkCapable` | The link-opener seam is present and `canOpenURL("spotify:…")` is true for the target URI. |
| `spotifyCapable` | `spotifyUsable && (spotifyRemoteCapable || spotifyDeepLinkCapable)` — exactly FR-SP-003's definition ("at least one Spotify outcome is available — remote playback control or the `spotify:` deep-link fallback"). |

**Selection:** if `spotifyCapable` → the Spotify outcome is selected (constraint 9; the both-provider search still ran when both were askable, and the recorded selection shows which provider won — FR-SP-002 scenario 1). Otherwise, if the YouTube leg can serve (served a result, or the keyless path can open), the YouTube outcome is selected. Otherwise the explicit honest line for the dominant failure (§12). The selection decision is recorded as a content-free observability event (`spotify_search` outcome + `spotify_fallback` outcome; no query text — ADR-SP-15).

**Premium capability source.** `product` is read from `GET /v1/me` at link time and refreshed on every successful token refresh; it is cached in the session record with a configurable staleness bound (§20). A stale `premium` with a lapsed subscription is caught honestly by the play attempt itself (403 → deep-link path, §13); a stale `free` costs at most one deep-link hand-off instead of remote control, which is honest and safe. The status surface (FR-SP-016) shows the same stored value the router acts on (NFR-SP-010 scenario 4).

### 12. OD-S3 — Degradation precedence and the state × outcome matrix

**Resolution (ADR-SP-02).** Precedence is *capability-first, then provider order*, with a single rule per state so the matrix is total (every state maps to exactly one outcome branch):

1. If Spotify is linked and capable → **Spotify serves** (remote control when Premium-capable, else the validated deep-link hand-off). This is constraint 1's deep-link degradation together with constraint 9's preference: free-tier linked accounts still win the selection and still get Spotify — via the honest hand-off, never a control pretense.
2. If Spotify is linked but cannot serve the *search* (empty/failure) or cannot produce *any* outcome (free-tier with the app absent), → **YouTube serves where it can** (constraint 5/FR-SP-004), with the identical behaviour an explicit YouTube request would get (ADR-SP-06).
3. If Spotify is not linked (or was revoked → unlinked treatment) → **YouTube serves where it can first** ("unlinked music requests fall back to YouTube"); where YouTube cannot serve at all, the `spotify:` **search hand-off** is offered as the constraint-1 degradation (opening the search for the user); where even that cannot open, the honest `spotify.notLinked` line.
4. If a deep-link hand-off was chosen and the open fails at attempt time → the honest `spotify.appMissing` line (FR-SP-011 scenario 2 / FR-SP-012's app-absent row — this is the one terminal point where no further chaining happens; the pre-check already gave YouTube its chance in the states where YouTube could serve).
5. Never: silence, a fabricated "playing", a raw error, or a retry loop against a dead grant.

**State × outcome matrix** (row = request-time state; "Both searched?" states what ran; outcome column is what the user hears/gets):

| # | Account / service state | Both searched? | Outcome branch | Spoken line (key) |
|---|---|---|---|---|
| 1 | Linked, Premium-capable, search usable, remote play **succeeds** | Yes (both askable) | Spotify remote control `PUT /v1/me/player/play` | `spotify.playing` (names Spotify + real title) |
| 2 | Linked, Premium-capable, search usable, remote play fails (403 premium lapsed / 404 no active device / network) | Yes | `spotify:track:<id>` deep link → opened | `spotify.openApp` ("Opening Spotify — play it there.") |
| 3 | Linked, free tier, search usable | Yes | `spotify:track:<id>` deep link → opened (remote control is not attempted) | `spotify.openApp` |
| 4 | Linked, free tier, search usable, **app absent** | Yes (search ran) | Not capable → YouTube fallback where it can serve; else `spotify.appMissing` | YouTube lines, or `spotify.appMissing` |
| 5 | Linked, search usable, deep-link open attempted and **fails** (2/3/4 attempt-time) | Yes | Terminal honest line (no chaining) | `spotify.appMissing` |
| 6 | Linked, search **empty** | Yes | YouTube fallback where it can serve; else `spotify.notFound` | YouTube lines, or `spotify.notFound` |
| 7 | Linked, search **network failure / timeout / non-200 / malformed** | Yes | YouTube fallback where it can serve; else `spotify.unavailable` | YouTube lines, or `spotify.unavailable` |
| 8 | **Unlinked** (never linked, wiped, or revoked→unlinked) | Spotify not askable; YouTube asked | YouTube serves where it can (keyed or keyless path, existing lines); else `spotify:search:<encoded>` hand-off → opened; else honest line | YouTube lines, `spotify.openSearch`, else `spotify.notLinked` |
| 9 | Unlinked + YouTube seams dormant + no opener | Neither | Explicit honest line | `spotify.notLinked` |
| 10 | Linked, refresh fails: `invalid_grant` (revoked) | — | Grant dropped (wipe), **unlinked treatment** (row 8); bounded refresh (1 attempt) — no retry loop | Row 8 lines |
| 11 | Linked, refresh fails: transport/network only | — | Treat as search failure (row 7): YouTube fallback where it can; else `spotify.unavailable` | Row 7 lines |
| 12 | Token verification failed at link time (`/v1/me` non-200 / missing scopes) | — | Account treated as not usable → unlinked treatment (row 8); Settings shows a failed/relink state | Row 8 lines; `spotifySettings.*` status |

**Both-provider behaviour per state, explicitly:** rows 1–7 search both (Spotify wins per `spotifyCapable`); row 8 searches YouTube only; rows 10–12 do not search at all until the link is re-established — and each row still produces exactly one spoken line. The YouTube leg of rows 4/6/7/8 is `fireYouTubePlay(query:)` reused verbatim, so the fallback outcome equals the explicit-YouTube outcome for the same query (FR-SP-004's pinned-behaviour clause).

**Copy approach (constraint 12, NFR-SP-005).** All lines exist as `spotify.*` keys with ne/en values; none embeds the query; only `spotify.playing` embeds the remote-sourced track title and it is spoken-only (never carded, never logged — mirroring the YouTube title discipline). The requirement set's Nepali examples are illustrative; the exact Nepali copy finalizes in design-l2/implement against the same review that approves the disclosure text. Keys: `spotify.playing`, `spotify.openApp`, `spotify.openSearch`, `spotify.notFound`, `spotify.unavailable`, `spotify.notLinked`, `spotify.appMissing`, `spotify.rolloutLimited` (OD-S2 unregistered guidance), plus the `spotifySettings.*` family (§23).

### 13. Playback hand-off and remote control (FR-SP-011, constraint 1)

- **Remote control (Premium-capable only):** `PUT https://api.spotify.com/v1/me/player/play` with JSON body `{"uris":["spotify:track:<id>"]}` and the access token in the `Authorization: Bearer …` header; bounded by the configurable tool timeout (§20). Success (204/2xx) → `spotify.playing`. `403` (premium required / restricted) and `404` (no active device) → deep-link path. `401` → exactly one refresh, then retry once; a second 401 → wipe as revoked (row 10). Network error → deep-link path.
- **Deep-link hand-off:** `SpotifyTool.trackURI(id:)` → `spotify:track:<id>` (id validated first, §14); if no validated track id exists, `SpotifyTool.searchURI(query:)` → `spotify:search:<percent-encoded query>`. Opened through the existing `CallLinkOpening` seam (`canOpenURL` then `open`); Spotify has no web fallback, so the seam's `OpenOutcome` is binary (opened / not opened).
- **App-absent honesty:** when the attempt-time open fails, the user hears `spotify.appMissing`; no playback success is ever claimed. The `Info.plist` `LSApplicationQueriesSchemes` entry makes the `canOpenURL` pre-check honest (constraint 8).
- **No silent hop:** every transition watches an explicit condition (status code, error enum) — there is no "try and hope"; the observability event pair (`spotify_play`, then `spotify_deeplink` or `spotify_fallback`) records the path taken.

### 14. SpotifyTool and deep-link hardening (FR-SP-007, NFR-SP-008)

`SpotifyTool` is a caseless enum of pure statics mirroring `YouTubeTool`, in `Services/Voice/` + `SpotifyTool.swift`, using the same seams (`LocalToolTransport`, `CallLinkOpening`) and the same test style (URL-shape and parsing tests, no real network).

```swift
enum SpotifyTool {
    struct TrackResult: Equatable { let id: String; let title: String }
    enum FetchError: Error, Equatable {
        case invalidResponse(statusCode: Int)   // non-2xx
        case noResults                          // 2xx but zero usable tracks
        case malformedResponse                  // unparseable payload
        case unusableResult                     // result present, ID failed validation
        case timedOut                           // URLError.timedOut (mapped distinctly)
        case transportUnavailable               // no transport seam / offline
    }
    static let defaultFetchTimeoutSeconds: TimeInterval = 8   // configurable; mirrors YouTubeTool

    static func apiSearchURL(query: String, market: String?) -> URL?        // GET api.spotify.com/v1/search
    static func parseSearchJSON(_ data: Data) throws -> TrackResult         // shape + ID validation
    static func fetchTopTrack(query: String, accessToken: String,
                              transport: LocalToolTransport,
                              timeoutSeconds: TimeInterval) async throws -> TrackResult
    static func playTrack(uri: URL, accessToken: String,
                          transport: LocalToolTransport,
                          timeoutSeconds: TimeInterval) async throws      // PUT /v1/me/player/play
    static func trackURI(id: String) -> URL?          // spotify:track:<id>; nil unless id matches the shape
    static func searchURI(query: String) -> URL?      // spotify:search:<percent-encoded>
    static func open(_ url: URL, opener: CallLinkOpening) -> OpenOutcome   // .opened / .notOpened
    enum OpenOutcome { case opened, notOpened }
    static func isSpotifyIdentifier(_ id: String) -> Bool   // base62, 22 chars — the validated shape
}
```

**Hardening rules (NFR-SP-008, non-negotiable):**

1. **Identifier validation before any URI construction.** A track ID is accepted only if it matches the Spotify identifier shape (base62 `[A-Za-z0-9]`, 22 characters — the shape every real Spotify ID has; the requirement's synthetic placeholder `01AbCdEfGhIjKlMnOpQrStU` is this shape). A hostile or malformed identifier (scheme text, `//`, quotes, control characters, traversal, over-long, percent-encoded traps) → the result is `unusableResult` → never a URI, never a partial URI.
2. **Titles never enter URIs.** The title is used only in the spoken confirmation (`spotify.playing`); it is never a URI component and never written to any log (ADR-SP-15).
3. **Query components are percent-encoded** via `URLComponents`/`URLQueryItem`; the search URI is built from the encoded query only.
4. **Scheme allowlist.** The tool constructs only `spotify:` URIs. (The YouTube fallback uses the pre-existing YouTube URI shapes unchanged.) A hostile corpus test asserts zero constructions/openings outside the allowlist.
5. **Every failure has a case** in `FetchError` and maps to an explicit matrix row (§12) — no fabrication, no guess, no silent forward.
6. **Timeout is a parameter** (`timeoutSeconds`), default 8 s, mirroring `YouTubeTool`; the negative budget is the caller's composition (search + play attempt ≤ 16 s worst case, §20).

### 15. Account linking (OAuth) and token lifecycle (FR-SP-008/010, NFR-SP-009)

**Flow (caregiver-performed, `GoogleAccountSession` precedent):** a new `SpotifyAccountSession` + `SpotifyAuthFlow` under a new `Services/Spotify/` group, `@MainActor`, with a `presenter` closure resolved at present time (the calendar-share pattern: `session.presenter = { [weak self] in self?.topPresentingViewController() }`).

1. **Authorize** — `SpotifyAuthFlow.authorizeURL(clientID:redirectURI:scopes:state:challenge:)` builds the request with **all required scopes at sign-in** (`addScopes` lesson: consent-screen-only scopes caused the calendar-share 401; here the scopes are on the authorization request itself): `user-read-private`, `user-read-playback-state`, `user-modify-playback-state`, `response_type=code`, `code_challenge_method=S256`, a fresh `state` nonce, and the redirect URI constant.
2. **Present** — `ASWebAuthenticationSession` via a thin seam (`SpotifyAuthFlow` protocol + production implementation) with `callbackURLScheme` = the app scheme; the seam is injectable so tests drive callback URLs without UI or network.
3. **Validate the callback (exact match, zero exceptions)** — parse the callback with `URLComponents`; require scheme `sahayak-spotify`, host `callback`, empty path, `state ==` the stored nonce, presence of `code`, absence of `error`; **exact match against the registered redirect constant**. Any mismatch (`redirectMismatch`, `stateMismatch`) → rejected, **nothing stored**, no token/code in any log (NFR-SP-009; security focus "redirect validation").
   - Scheme note: `sahayak-spotify://callback` is the design's plan of record (single constant shared by `Info.plist` `CFBundleURLTypes`, the Dashboard registration and the validator). If the Dashboard refuses the custom scheme at registration (OD-S2 step 2), the constant is re-shaped (e.g. the SDK-style `spotify-<clientid>://callback` form) and **which scheme is registered is the only thing that changes** — the validator's exact-match discipline is untouched. `[design-l2 / security-review: confirm the accepted scheme shape against the live Dashboard at registration time; no other mitigation depends on the specific string.]`
4. **Exchange** — `POST https://accounts.spotify.com/api/token` (form-encoded): `grant_type=authorization_code`, `code`, `redirect_uri` (the same constant), `client_id`, `code_verifier`. No secret (ADR-SP-01). Non-200 → `exchangeFailed(statusCode:)` → `linkFailed` status; nothing stored.
5. **Verify before trusting** — `GET https://api.spotify.com/v1/me` with the fresh token: 200 required; `product` extracted (`premium` → remote-capable); the granted scope string from the token response is checked to contain the required scopes (`missingScopes` → session stored but marked not usable, honest outcome at request time — the calendar-share "verify, don't assume" precedent). Then the single `spotify.session` record is written (§16).
6. **Refresh, bounded** — access tokens expire (~1 h); refresh via `grant_type=refresh_token` with the `client_id` + `refresh_token`, at most **one automatic attempt per request** (§20). `invalid_grant` → the grant is dead: **wipe the record** and treat as unlinked (row 10); transport failure → row 11. A refresh failure never loops and never hangs (FR-SP-010, NFR-SP-001).
7. **Unlink** — caregiver action: delete the single record (**local wipe is the guarantee** — ADR-SP-14; Spotify exposes no third-party revocation endpoint, so no remote revoke is attempted or claimed), emit a content-free `spotify_unlink` event, status → not linked. A later provider-side `invalid_grant` on a stale grant is also treated as unlinked (row 10). Re-link works through the same flow with no residual state (FR-SP-010 scenario 4).
8. **Status model** — `.notLinked` / `.linked(product: premium|free|unknown)`; the Settings surface (FR-SP-016) and the router read the same observable store, so the displayed status is never optimistic (NFR-SP-010 scenario 4).

**Failure taxonomy (`SpotifyAuthError`, every case explicit):** `notConfigured` (no client ID → feature dormant, never a crash — the `GoogleAccountSession` missing-client-ID degradation precedent), `userCancelled`, `redirectMismatch`, `stateMismatch`, `exchangeFailed(statusCode:)`, `verificationFailed(statusCode:)`, `missingScopes(granted:)`, `refreshFailed(statusCode:)`, `revoked`, `storageFailure(StorageError)`, `networkUnavailable`. Retryability per case is tabulated in §18.

### 16. Credential store and data model (FR-SP-009, NFR-SP-007)

**One encrypted record, one key** (ADR-SP-08): `SpotifyCredentialStore: ObservableObject` in `Services/Spotify/` + `SpotifyCredentialStore.swift`, backed by the existing `EncryptedLocalStorage` seam (Keychain-backed, `kSecAttrAccessible` + `WhenUnlockedThisDeviceOnly` = Data Protection Complete; `StorageError { encryptedWriteFailed, encryptedReadFailed }`).

```swift
struct SpotifySessionRecord: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var product: String?      // "premium" | "free" | nil (unknown)
    var scope: String?        // granted scope string (verification)
    var linkedAt: Date
}
// key: "spotify.session" — the ONE new storage key (StoragePlacementPolicy addition)
```

- **Placement:** the key is added to `StoragePlacementPolicy.keychainResidentKeys` (the exact-set test drives the addition both directions — `StoragePlacementTests` must be consciously updated; the encrypted-file path is never used for this key).
- **Empty/clear semantics:** `clear()` deletes the key (wipe); an unavailable/corrupt store reads as not-configured → honest degraded outcome, **no plaintext fallback ever** (NFR-SP-007 scenario 3).
- **No weak fallbacks:** never `UserDefaults`, never a plist/file, never the repository (FR-SP-009).
- **Observing:** the store is the single read point for the router and the Settings surface; `isLinked` is derived (`record != nil`), not stored separately, so there is no split-brain state.
- **What is NOT stored:** the client ID lives in `Info.plist` (public, not sensitive); no client secret exists at all (ADR-SP-01); no query history, no playback history, no titles.
- **Wipe evidence:** after `clear()`, a sweep finds no Spotify value; the unlink test asserts the store reads not-configured and the tool log/console carry no token material (FR-SP-010).

### 17. Intent/prompt layer and golden corpus (constraint 3, NFR-SP-004, NFR-SP-006)

- **Core prompt: zero delta.** The music intent wording already exists in `IntentPrompt` (schema list, mapping line, music bullet), and `IntentPromptTests` pins rendered-prompt digests and the exact 2,506-character baseline — any edit breaks the pins. No core-template change is made (ADR-SP-09). The deterministic rule (§9) is the primary music classification path (zero prompt tokens), exactly the youtube route's discipline.
- **Plugin fragment:** `SpotifyPlugin.intentContribution` mirrors `YouTubePlugin`'s shape (`actionNames: ["spotify.play"]` + a short prompt fragment). Plugin fragments compose only when plugins are active; the fragment is kept at or under the YouTube fragment's size. `[design-l2]: verify the plugin-composed budget wherever asserted; add a guard if none exists.]`
- **Seed mirror:** no prompt-template change → no seed-mirror change (`ios/tools/check-prompt-mirror.sh` stays green trivially); if design-l2 decides any wording change, the byte-mirrored seed updates in the same change (NFR-SP-004).
- **Golden corpus:** the 15 pinned music entries (lines 143–157) stay resolving to intent `music` (parser-level test unchanged; count reconciliation in §7). The feature's deliberate supersession is at the **dispatch** level, not the corpus: the stub is gone, so the new `CommandRouterMusicTests` records the new expectation — the same bar requests now produce a real outcome and **no music branch speaks `router.musicStub`** (FR-SP-001 scenario 4). No entry is removed or relabelled (the ≥15-per-intent test is the floor).
- **Other stub intents:** health-query and video stubs keep their lines; the interpreter's other intents are untouched (NFR-SP-006).

### 18. Interfaces and error taxonomy

Every interface declares explicit error types (Agent Principles), and every async operation declares its failure mode and retryability:

| Operation | Failure modes (explicit) | Retryable? | User-visible outcome |
|---|---|---|---|
| `SpotifyTool.fetchTopTrack` | `invalidResponse(statusCode:)`, `noResults`, `malformedResponse`, `unusableResult`, `timedOut`, `transportUnavailable` | No automatic retry (bounded by design; the single refresh is a token concern, not a search retry) | §12 rows 6/7 |
| `SpotifyTool.playTrack` | `unauthorized` (→ one refresh), `premiumRequired`, `restricted`, `noActiveDevice`, `invalidResponse`, `timedOut` | One refresh on 401 only | §12 rows 1/2 |
| `SpotifyTool.open` | `.notOpened` | No | `spotify.appMissing` / row 4/5 |
| `SpotifyAccountSession.link()` | `SpotifyAuthError` cases (`notConfigured`, `userCancelled`, `redirectMismatch`, `stateMismatch`, `exchangeFailed`, `verificationFailed`, `missingScopes`, `storageFailure`, `networkUnavailable`) | User-initiated re-attempt yes; automatic no | Settings status + `spotifySettings.*` message |
| `SpotifyAccountSession.validAccessToken()` | `refreshFailed`, `revoked`, `networkUnavailable`, `storageFailure` | 1 automatic refresh per request | Rows 10/11 |
| `SpotifyAccountSession.unlink()` | `StorageError` (`encryptedWriteFailed/ReadFailed` — surfaced, never swallowed) | User re-attempt yes | Status flips only on a confirmed wipe |
| `fireMusicRequest` (router) | Terminal by construction: every branch ends in a `speak` (the matrix is total) | n/a (a new turn starts fresh) | Exactly one spoken line per request |

All async work runs through the `LocalToolTransport` seam so failure injection is deterministic in tests. No operation blocks the main thread on network (URLSession async + main-actor marshalling). No API returns an untyped error or silently succeeds (root Agent Principle).

### 19. Concurrency and isolation

- **Actor confinement:** `SpotifyAccountSession` and `SpotifyCredentialStore` are `@MainActor` (`ObservableObject` state read by UI and the router). The router's music path runs on the main thread like the rest of the voice stack; network work hops off via the transport seam and results marshal back with `await MainActor.run` (the `fireYouTubePlay` pattern).
- **Parallel searches:** the Spotify and YouTube legs are child tasks joined before selection; each carries its own configurable timeout; the join is bounded by `max(provider budget)`, satisfying the 10 s outcome budget and the ≤16 s sequential-worst-case assertion (search + play attempt).
- **Turn overlap:** a new turn does not cancel an in-flight music attempt (parity with the YouTube stage; accepted existing behaviour). The outcome delivery is idempotent per attempt; observability records both attempts distinctly. `[design-l2: if a shared in-flight tracker is introduced later, it must stay inside the existing seams.]`
- **No shared mutable state across components:** the store is the single source of truth; the tool is stateless statics; the plugin holds only the store reference (the `YouTubePlugin` shape).
- **ASWebAuthenticationSession** presentation is main-actor and presenter-resolved at call time (no retained view-controller references).
- **Deadlock/livelock guards:** no locks are introduced; the only cross-thread reads are the store's main-actor-confined values; refresh retries are counted (≤1/request) and open attempts are single-shot.

### 20. Configurable parameters (timeouts are configuration — Agent Principles)

| Parameter | Default | Owner / where | Notes |
|---|---|---|---|
| `spotify.fetchTimeoutSeconds` | 8.0 | `SpotifyTool` (injectable; mirrors `YouTubeTool.fetchTimeoutSeconds`) | Per provider call: search, `/v1/me`, play attempt each bounded |
| `music.outcomeBudgetSeconds` (assertion, not code) | 10.0 | Test assertion (NFR-SP-001) | When ≥1 provider answers in budget |
| `music.negativeBudgetSeconds` (assertion) | 16.0 | Test assertion (NFR-SP-001) | Two sequential provider budgets worst case; no path waits longer before speaking |
| `spotify.maxRefreshAttemptsPerRequest` | 1 | Session | Bounded, counted (FR-SP-010) |
| `spotify.capabilityStalenessSeconds` | 3,600 | Session/status | Refresh `product` on TTL or on next successful refresh |
| `music.maxQueryLength` | 100 | Extractor (mirrors `YouTubeRoute.maxQueryLength`) | Bounds URIs and search params |
| PKCE verifier/challenge lengths | 43–128 / S256 | `SpotifyAuthFlow` | Spec-fixed values, not tunables |
| `spotify.linkFlowTimeoutSeconds` | 300 (user-interactive) | Session | The authorization is user-paced; the bound guards abandoned sessions |

No timeout is a bare literal in the new code; each is a parameter with an injected default, mirroring the project's tool pattern.

### 21. Security architecture (STRIDE pre-map for `security-design-review`)

| STRIDE | Threat (this feature) | Mitigation (designed) | Requirement |
|---|---|---|---|
| Spoofing | Malicious app intercepts the OAuth callback scheme | PKCE S256 (`code_verifier` never leaves the device flow); exact redirect match; state nonce; nothing stored on mismatch | NFR-SP-009, ADR-SP-01 |
| Spoofing | Fake "connected" state | Verification (`/v1/me` + scope check) before first trusted use; status derived from the store only | FR-SP-008, FR-SP-016 |
| Tampering | Hostile provider result crafts a URI/scheme | Identifier shape validation, percent-encoding, titles never in URIs, scheme allowlist, hostile corpus test | NFR-SP-008 |
| Tampering | Token tampering at rest | Encrypted store only (Keychain, Data Protection Complete); no plaintext fallback | NFR-SP-007 |
| Repudiation | Linking/unlink actions unverifiable | Content-free `spotify_link` / `spotify_unlink` events (who/what/outcome, no values) | NFR-SP-002 |
| Information disclosure | Secrets/keys in logs or URLs | No app secret exists; header-only credentials; no query/token/body in any log; release gate covers new paths | NFR-SP-002, §22 |
| Information disclosure | Egress beyond the two providers | Allowlist + seam-level egress assertions | NFR-SP-003 |
| Denial of service | Unbounded waits/retries; revoked-grant loop | Configurable budgets; ≤1 refresh/request; no retry loops | NFR-SP-001, FR-SP-010 |
| DoS | Token endpoint rate limits | Bounded attempts; honest unavailable outcome | NFR-SP-001 |
| Elevation of privilege | Over-broad scopes (library/playlist writes) | Minimal scope set (3 read/control scopes); playback read-only, user-initiated | Feature scope; FR-SP-016 |
| EoP | Client secret extraction | No secret shipped (ADR-SP-01) | Constraint 2 |

Also for review: deep-link handling treats Spotify as a hand-off (the app opens another app; no data is fetched from the opened page), and the OAuth `presenter` retains nothing. The full threat model with residual risks is the `security-design-review` artifact.

### 22. Privacy, log safety and compliance

- **No new egress beyond the allowlist** (§8): `accounts.spotify.com`, `api.spotify.com` + existing YouTube endpoints; music text never reaches a cloud LLM (NFR-SP-003); deep links are OS hand-offs, not fetches.
- **Log discipline (stricter than YouTube — ADR-SP-15):** no Spotify credential, token, code, verifier, authorization header, query text, title, or raw provider body reaches any console print, observability event, telemetry, or the encrypted tool log. The tool-log entries use `kind: .spotify` with query `""` and response `""` on success; failure entries carry the query-free spoken line the user heard (mirroring the YouTube failure-entry shape, minus the query). Observability events carry only non-content classifications (component `spotify`, outcome vocabulary).
- **Release gate:** `ios/tools/check-release-log-safety.sh` (build-blocking, wired into `ios/build.sh` ahead of every test scope) is extended: add the Spotify feature root(s) (e.g. `Services/Spotify/`) to `FEATURE_ROOTS`, and add a rule + fixture pair (positive/negative) so a re-introduced raw print or provider-body print in the new paths fails the gate. The new files under `Services/Voice/` and `Services/Plugins/` must be confirmed inside existing coverage or added explicitly. `[design-l2: verify which roots the gate already sweeps; make the addition deliberately, per the LiveTranslate precedent.]`
- **Pre-release device check (project gate):** DV-7 (§6) runs the console/sysdiagnose capture over the music paths.
- **Privacy disclosure (FR-SP-016, amendment):** Settings states plainly (ne/en) that linking sends music queries and playback activity to Spotify and nothing else (§23); the App Store privacy entries for this integration are recorded in the release checklist (NFR-SP-011); `Info.plist` carries the `spotify` query scheme (no new *UsageDescription is needed — no new permission-protected API is touched).
- **Data at rest:** one encrypted session record; wiped on unlink; no query/playback history stored anywhere (NFR-SP-007).
- **Consent posture unchanged:** recorded cloud exceptions (Open Decisions 12/13) are not invoked by this feature's music path.

### 23. Settings surface and localisation (FR-SP-016, NFR-SP-005/010/011)

**`SpotifySettingsView`** (new, in `SettingsView.swift`, mirroring `YouTubeSettingsView` at line 768) + a `SettingsDestination.spotify` entry in `SettingsTabs.swift` (title key, icon, `hiddenSheetRows` inclusion like `.youtube`, view mapping). Contents:

- **Status row** — not linked / linked (Premium) / linked (free tier — "playback opens the Spotify app") / link failed, derived from the store (never optimistic).
- **Actions** — Link (starts `SpotifyAccountSession.link()`, caregiver framing), Unlink with the `removeConfirm` confirmation pattern (wipes; §16). **No credential/secret field** (ADR-SP-01); if the recorded contingency is ever activated, the field uses the existing `credentialField` secure-entry style.
- **Privacy disclosure** — `spotifySettings.privacy`, plain language, ne/en: what is sent (the spoken query, to Spotify), what comes back (search results), what is not sent (nothing else; no health/family data); mirrors `youtubeSettings.privacy`'s shape. Illustrative: "गीत खोज्न तपाईंले भन्नुभएको कुरा स्पोटिफाइमा पठाइन्छ; अरू केही पठाइँदैन।" / "What you say is sent to Spotify to find the music; nothing else is sent."
- **Rollout note** — `spotifySettings.rolloutNote` while Development mode limits service (OD-S2); never hides the reality.
- **Accessibility (NFR-SP-010):** 44×44 pt controls, 18 pt-equivalent body text via appearance tokens, VoiceOver labels for all controls, status announced as text not colour.
- **Key inventory (ne/en, both required):** `plugin.spotify.name`; `spotify.playing`, `spotify.openApp`, `spotify.openSearch`, `spotify.notFound`, `spotify.unavailable`, `spotify.notLinked`, `spotify.appMissing`, `spotify.rolloutLimited`; `spotifySettings.title`, `.status.linked`, `.status.notLinked`, `.status.freeTier`, `.status.linkFailed`, `.link`, `.unlink`, `.removeConfirm`, `.privacy`, `.rolloutNote`; `toolLog.kind.spotify`. No hardcoded user-facing literals anywhere in the new paths (NFR-SP-005).

### 24. Infrastructure and build topology

- **No services, no Docker, no backend** (constraint 6). The only "infrastructure" surfaces are: the Spotify Developer Dashboard (console-side, §5), the two provider hosts, and the app's own build gates.
- **Build/gates:** `ios/build.sh` remains the canonical runner (`test:unit`, `test:impact`, etc.); the log-safety gate stays wired ahead of every scope; the prompt-mirror gate stays green (no template change).
- **Project file:** new Swift files are added to the Xcode target (`project.pbxproj`) in the same change; tests mirror the source tree (`test:impact` mapping convention).
- **Storage placement:** one new keychain-resident key `spotify.session` (§16); `StoragePlacementTests` updated deliberately.
- **Info.plist:** `LSApplicationQueriesSchemes` += `spotify`; `CFBundleURLTypes` += the Spotify callback scheme; `SpotifyClientID` string. No new permission usage descriptions.
- **Localization catalog:** `Localizable.xcstrings` gains the §23 keys (ne + en both present; a missing translation is a failure).
- **Android:** out of scope (project constraint; feature constitution scope).

---

## Components

### 25. Component inventory

| ID | Component | Type | File(s) | Primary requirements |
|---|---|---|---|---|
| C-SP-01 | `SpotifyTool` — search, playback call, deep-link construction, hardening | NEW | `Services/Voice/` + `SpotifyTool.swift` | FR-SP-007, NFR-SP-008, NFR-SP-001 |
| C-SP-02 | `SpotifyCredentialStore` — the one encrypted session record | NEW | `Services/Spotify/` + `SpotifyCredentialStore.swift` | FR-SP-009, NFR-SP-007 |
| C-SP-03 | `SpotifyAccountSession` — link/unlink/refresh/status | NEW | `Services/Spotify/` + `SpotifyAccountSession.swift` | FR-SP-008, FR-SP-010, NFR-SP-009 |
| C-SP-04 | `SpotifyAuthFlow` — PKCE + `ASWebAuthenticationSession` seam + redirect validation | NEW | `Services/Spotify/` + `SpotifyAuthFlow.swift` | NFR-SP-009, ADR-SP-01 |
| C-SP-05 | `SpotifyPlugin` — `AssistantPlugin` twin | NEW | `Services/Plugins/` + `SpotifyPlugin.swift` | FR-SP-006, NFR-SP-012 |
| C-SP-06 | Router music path — intake hook, search orchestration, selection, degradation ladder, telemetry, tool log | CHANGED | `Services/Voice/` + `CommandRouter.swift` | FR-SP-001…005, FR-SP-011/012, NFR-SP-001/002/006 |
| C-SP-07 | Music intent rule + query extractor | CHANGED | `Services/Voice/` + `KeywordIntentRule.swift` | FR-SP-013, FR-SP-015 |
| C-SP-08 | Contact-search music veto | CHANGED | `Services/Voice/` + `VoiceContactSearchRoute.swift` | FR-SP-014 |
| C-SP-09 | Wiring/registration (stores, session, plugin, router seams) | CHANGED | `App/` + `AppCoordinator.swift` | FR-SP-006, NFR-SP-012 |
| C-SP-10 | Settings surface | CHANGED | `App/` + `SettingsView.swift`, `SettingsTabs.swift` | FR-SP-016, NFR-SP-010 |
| C-SP-11 | Localisation catalog | CHANGED | `Resources/` + `Localizable.xcstrings` | NFR-SP-005 |
| C-SP-12 | Info.plist declarations | CHANGED | `Info.plist` | NFR-SP-011, constraint 8 |
| C-SP-13 | Release log-safety coverage | CHANGED | `tools/` + `check-release-log-safety.sh` (+ `.py`) | NFR-SP-002 |
| C-SP-14 | Tool-log + observability integration | CHANGED | `Services/Voice/` + `LocalToolLogStore.swift`, tool-log review view | NFR-SP-002, FR-SP-012 |
| C-SP-15 | Test suites (new + touched) | CHANGED/NEW | `ElderlyAssistantTests/` + `Services/Voice/` etc. | All |
| C-SP-16 | DV checklist artifact (protocol + results) | NEW | `specs/SP-device-validation-protocol.md` (+ results) | FR-SP-017 |

### 26. Component detail

**C-SP-01 `SpotifyTool`** — stateless statics (§14). Responsibilities: build/perform the `/v1/search` request with `Authorization: Bearer` (header only), parse + validate the top track, build validated `spotify:` URIs, perform the play call, map every failure to `FetchError`. Uses `LocalToolTransport` + `CallLinkOpening`; no state, no logging, no UI. Tests: URL shapes, parse fixtures, hostile corpus, timeout injection.

**C-SP-02 `SpotifyCredentialStore`** — `@MainActor ObservableObject`; one Codable record under `spotify.session`; `save`/`clear`/read; `Result`-typed errors; no other key, no plaintext path. Tests: round-trip, clear, corrupt-store degradation, placement.

**C-SP-03 `SpotifyAccountSession`** — `@MainActor`; owns the flow: `link() -> LinkOutcome`, `unlink()`, `validAccessToken()`, `status`; holds the `presenter` closure; stores nothing outside C-SP-02. Degrades to `isConfigured == false` when the client ID is absent (no crash). Tests: flow outcomes per `SpotifyAuthError`, refresh bounds, revoked → wipe, status transitions.

**C-SP-04 `SpotifyAuthFlow`** — pure-ish helpers + a presentable seam: PKCE pair generation (`SecRandomCopyBytes`/`CryptoKit`-based, S256), authorize-URL construction (all scopes at sign-in), callback parsing + exact-match/state validation, session-start seam. Tests: RFC 7636-style verifier/challenge vector, callback accept/reject matrix (mismatch, wrong host, missing state, error param), no token on rejection.

**C-SP-05 `SpotifyPlugin`** — twin of `YouTubePlugin`: `pluginID = "spotify"`, `displayNameKey = "plugin.spotify.name"`, `intentContribution` (`spotify.play` + short fragment), `handle` → `.spoken`/`.failed(spokenApology:)` with `spotify.*` lines, observability events with empty metadata, `presentationView` nil; inert without a link (the router owns degradation). Tests mirror `YouTubePluginTests`.

**C-SP-06 Router music path** — new private methods in `CommandRouter.swift` (mirroring the `fireYouTubePlay` family): `fireMusicRequest(query:)` (pre-ack, both-leg search, selection, ladder per §12), `deliverMusicOutcome(...)` (speak + emit + tool-log), the email-free capability reads from stores. Additions: `Kind.spotify` tool-log calls (query `""`); observability events `spotify_search`, `spotify_play`, `spotify_deeplink`, `spotify_fallback`, `spotify_link`, `spotify_unlink` (component `spotify`, no metadata); YouTube fallback via the existing `fireYouTubePlay`. The stub branch is deleted; the `case .music:` in `dispatchInterpreted` routes here. Tests: `CommandRouterMusicTests` (new) pin the matrix rows and the never-stub rule.

**C-SP-07 Music rule** — `KeywordIntentRule` changes: `Domain.music`, ordered rules, `musicKeywords` (shared constant) × `musicVerbFamily`, narration guard, YouTube-marker exclusion, `musicQuery(from:)` extractor. Tests: `KeywordIntentRuleTests` additions (music match, YouTube precedence, narration, extraction with Devanagari enumerations).

**C-SP-08 Contact veto** — `VoiceContactSearchRoute.decide`: music veto directly after the YouTube veto, using the shared music-family constant; no over-block. Tests: `VoiceContactSearchRouteTests` additions (veto fires, contact request unaffected, YouTube veto intact).

**C-SP-09 Wiring** — `AppCoordinator`: lazy stores (`spotifyCredentialStore`, `spotifyAccountSession` with the presenter closure), `registry.register(SpotifyPlugin(...))` beside line 2058, `CommandRouter` init params for the Spotify seams (dormant optionals) alongside 3715–3717. Tests: registry once-only, dormant construction compiles/behaves (removability smoke, NFR-SP-012).

**C-SP-10 Settings** — `SpotifySettingsView` + `SettingsDestination.spotify` mapping in `SettingsTabs.swift`. Tests: `SettingsTabMappingTests` (destination maps, counts updated deliberately), accessibility assertions per NFR-SP-010.

**C-SP-11 L10n** — the §23 key inventory in `Localizable.xcstrings`, ne+en each; no literals. Tests: catalog completeness (both languages), plus the router/plugin tests speak through L10n.

**C-SP-12 Info.plist** — three additions (§24); verified by a plist test where the project has one, else by the DV device run.

**C-SP-13 Log gate** — `FEATURE_ROOTS` + rule/fixture additions; the gate runs in every `ios/build.sh` scope; fixtures prove a raw print in the new paths fails.

**C-SP-14 Tool log/observability** — `LocalToolLogStore.Kind.spotify` + the review-view mapping. Tests: kind round-trip, review-row rendering, and the no-content rule (no query/title in entries).

**C-SP-15 Tests** — see §27.

**C-SP-16 DV artifact** — protocol + results recorded with the feature (§6); the checklist is the completion gate (FR-SP-017).

### 27. Testing strategy and suite plan

**New suites (mirroring the YouTube suite pattern):**

| Suite | Covers |
|---|---|
| `SpotifyToolTests` | Search URL construction (percent-encoding, header-only auth), parse fixtures (ok/empty/malformed), error mapping incl. `timedOut` injection, `trackURI` validation, search URI encoding, open outcomes with a fake opener, the **hostile corpus** (scheme text, `//`, quotes, control chars, traversal, over-long, percent-encoded traps → zero non-allowlisted constructions/opens) |
| `SpotifyCredentialStoreTests` | Save/read/clear round-trip via fake `EncryptedLocalStorage`; corrupt store → not configured; wipe leaves nothing; placement key |
| `SpotifyAccountSessionTests` | Authorize URL (scopes at sign-in, S256, state), callback accept/reject matrix, exchange failure, verification (`/v1/me` 200/product, missing scopes), refresh bounded + `invalid_grant` wipe, unlink wipe + event, re-link clean |
| `SpotifyAuthFlowTests` | PKCE pair (challenge = S256 of verifier), callback parsing, exact-match/state rules |
| `SpotifyPluginTests` | Registry shape (`spotify.play`, entity, display name key), handle outcomes, failure apology, dormant-without-link |
| `CommandRouterMusicTests` | The §12 matrix row by row (fake transports/opener/stores): Spotify wins when capable; free tier → deep link; deep-link fail → `spotify.appMissing`; empty/failure → YouTube leg; unlinked → YouTube leg; unlinked+no-YT → search hand-off/notLinked; revoked → wipe + unlinked treatment; **no music branch speaks `router.musicStub`**; YouTube-marked utterance never reaches the music path; no double-handling |

**Touched suites (must stay green):** `YouTubeRouteTests`, `YouTubePluginTests`, `CommandRouterYouTubeTests` (unchanged — the guard for FR-SP-005); `KeywordIntentRuleTests` (music additions, youtube unchanged); `VoiceContactSearchRouteTests` (veto additions, over-block guard); `GoldenCorpusTests` (unchanged; still 15/≥15); `IntentPromptTests` (byte-identical pins hold); `SettingsTabMappingTests` (new destination, deliberate count updates); `StoragePlacementTests` (the one new key). Plus the log-gate fixture suite.

**Baseline discipline (NFR-SP-006):** the project's known pre-existing unit-test failures are recorded as the baseline (a known master-branch condition); the feature's own suites must pass, and any touched suite's change must be a recorded deliberate one.

**Device validation:** DV-1…DV-7 per §6, run in Development mode with the OD-S2 registered accounts; results recorded as C-SP-16.

### 28. Traceability — every requirement mapped

| Requirement | Design components / sections | Verification path |
|---|---|---|
| FR-SP-001 stub → real playback | C-SP-06 (§9), C-SP-05 | `CommandRouterMusicTests` (never-stub), DV-1 |
| FR-SP-002 both-provider search | C-SP-06 (§11), C-SP-01 | `CommandRouterMusicTests` (both-legs, one-leg, neither), `SpotifyToolTests` |
| FR-SP-003 Spotify preferred | C-SP-06 (§11), C-SP-02 | `CommandRouterMusicTests` (selection rows), DV-2 |
| FR-SP-004 YouTube fallback | C-SP-06 (§12 rows 4/6/7/8), C-SP-01 | `CommandRouterMusicTests`; YouTube suites hold |
| FR-SP-005 explicit YouTube unchanged | C-SP-07 exclusion (§9), C-SP-06 | `YouTubeRouteTests` / `YouTubePluginTests` / `CommandRouterYouTubeTests` unchanged; DV-3 |
| FR-SP-006 SpotifyPlugin | C-SP-05, C-SP-09 | `SpotifyPluginTests`, registry-once test |
| FR-SP-007 tool + deep links | C-SP-01 (§14) | `SpotifyToolTests` (incl. hostile corpus), DV-1 |
| FR-SP-008 account linking | C-SP-03, C-SP-04 (§15) | `SpotifyAccountSessionTests`, `SpotifyAuthFlowTests` |
| FR-SP-009 encrypted store | C-SP-02 (§16) | `SpotifyCredentialStoreTests`, `StoragePlacementTests` |
| FR-SP-010 unlink wipe/revoke | C-SP-03, C-SP-02 (§15.7, §16) | `SpotifyAccountSessionTests` (wipe, revoked, re-link) |
| FR-SP-011 free-tier deep link | C-SP-06 (§12 rows 2/3/5), C-SP-01 | `CommandRouterMusicTests`, DV-4 |
| FR-SP-012 honest outcomes | C-SP-06 (§12 total matrix), C-SP-11 | `CommandRouterMusicTests` (every row speaks), DV-4 |
| FR-SP-013 keyword music rule | C-SP-07 (§9/§10) | `KeywordIntentRuleTests` additions |
| FR-SP-014 contact veto | C-SP-08 (§9.1) | `VoiceContactSearchRouteTests` additions |
| FR-SP-015 route intake | C-SP-06, C-SP-07 (§9) | `CommandRouterMusicTests` (intake/no-double-handling) |
| FR-SP-016 Settings + disclosure | C-SP-10, C-SP-11 (§23) | `SettingsTabMappingTests`, disclosure inspection, DV-5 |
| FR-SP-017 DV checklist | C-SP-16 (§6) | Checklist recorded + passed on Anzaan |
| NFR-SP-001 responsiveness/timeouts | C-SP-01, C-SP-06 (§19/§20) | Timeout-injection tests; budget assertions; DV-1/4 |
| NFR-SP-002 log safety | C-SP-06, C-SP-13, C-SP-14 (§22) | Log-gate fixtures + gate exit 0; no-content assertions; DV-7 |
| NFR-SP-003 no new egress | C-SP-01, C-SP-06 (§8/§21) | Seam-level egress assertions (allowlist only) |
| NFR-SP-004 prompt budget | C-SP-05, C-SP-07 (§17) | `IntentPromptTests` unchanged; plugin-budget check `[design-l2]` |
| NFR-SP-005 localisation | C-SP-11 (§23) | Catalog completeness (ne+en), spoken-line tests, DV-5 |
| NFR-SP-006 no regression | All (§7/§27) | YouTube suites unchanged; golden 15 hold; stubs intact; dormant seams; baseline recorded |
| NFR-SP-007 encryption at rest | C-SP-02 (§16) | Store tests + placement + wipe sweep |
| NFR-SP-008 URI hardening | C-SP-01 (§14) | Hostile-corpus suite |
| NFR-SP-009 redirect + token lifecycle | C-SP-03, C-SP-04 (§15) | Callback matrix, refresh bounds, wipe, log-free assertions |
| NFR-SP-010 accessibility | C-SP-10 (§23) | Accessibility assertions in settings tests |
| NFR-SP-011 compliance/release gates | C-SP-12, C-SP-13, C-SP-16 (§22/§24) | Gate exit 0, TLS hosts (allowlist), DV + release checklist |
| NFR-SP-012 plugin isolation | C-SP-05, C-SP-06, C-SP-09 (§19/§24) | Diff-surface check, registry test, dormant-seam/removability tests |

**Not architecturally touched:** none — every one of the 29 requirements maps to at least one component above. (Project-level surfaces outside this feature — emergency/meds/health — are explicitly unchanged; see §2 out-of-scope.)

### 29. Open items

**Owner input (OD-S2, §5 — all marked in place):** Dashboard-owning account email; household Premium account (DV-1/2); free-tier test account (DV-4); any extra test-user emails; final app name / business details / privacy-policy URL; the rollout-note copy approval; the final-sign-off decision line. **No account, email or Dashboard value is invented anywhere in this document.**

**For `design-l2`:** exact Nepali/English copy for all `spotify.*` keys (illustrative strings here); exact keyword/verb enumerations + extractor fixtures; the plugin-composed prompt-budget check; which feature roots the log gate must gain; `market` handling on search; the OD-S2 quota-request appendix text; the settings-surface component spec (layout/state machine) mirroring `YouTubeSettingsView`; the DV protocol document content.

**For `security-design-review` (SECURITY-GO):** the STRIDE table above as the starting model; PKCE-only posture (no secret) verification; redirect exact-match scheme acceptance at the Dashboard (§15 note); hostile-URI corpus adequacy; the stricter-than-YouTube log rule (ADR-SP-15) as an accepted design decision; refresh/revocation bounds; egress allowlist enforcement.

**For `security-test` (SECURITY-GO):** token storage (Keychain only), release log-surface coverage of the new paths, hostile track titles/IDs producing only validated `spotify:` URIs, redirect validation, credential wipe on unlink — per the workflow's focus list; DV-7 results as device evidence.

**Risks recorded (design-l1 level):**

1. Spotify Dashboard acceptance of the custom callback scheme is unverified (OD-S2 step 2); the exact-match validator is independent of the final string, so only the constant changes if the Dashboard requires a different shape.
2. `product`-based capability can be stale; the play attempt is the honest catch, so the worst case is an extra deep-link hand-off, never a false claim (§11/§13).
3. FR-SP-002 scenario 3's "neither provider can be asked" depends on the keyless YouTube path remaining as shipped; if that path is ever changed, this design's YouTube-askability predicate must be revisited with it (Reconciliation 2).
4. The strict log rule (ADR-SP-15) intentionally diverges from `YouTubeTool`'s raw-query tool-log habit; security review should confirm the stricter reading of NFR-SP-002 is the intended one (the requirement text and workflow focus both read that way).
