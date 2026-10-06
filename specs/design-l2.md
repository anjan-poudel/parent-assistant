# L2 Component Design — Spotify Music Integration (v1)

**Feature:** `spotify-music-integration` · **Branch:** `feat/spotify-music-integration` (worktree `elderly-ai-assistant-spotify-music-integration`; requirements baseline `bc1c495`, L1 architecture `bb51be7`)
**Task:** `design-l2` (agent `sdd-principal-engineer`) · **Contract:** `design_l2` → `specs/design-l2.md`
**Date:** 2026-10-06 · **Status:** for `review-l2`, `security-design-review`, `plan-tasks` and `implement`
**Refines:** `specs/design-l1.md` (binding architecture) to implementation-grade component interfaces.

**Path convention (inherited from L1 §Path convention).** Paths are repo-relative. Where one path would exceed the release-log sanitiser's token limit (40 consecutive characters from the class `[A-Za-z0-9/+=]`), it is split across adjacent code spans; `` `ios/ElderlyAssistant/Services/` + `Voice/SpotifyTool.swift` `` denotes the single path obtained by joining the spans with `/`. The split is a sanitiser convention only — do not read the `+` as concatenation in code.

**Identifier-break convention.** The same 40-character limit applies to any single identifier (including test names): where its text would form one run of 40 or more characters from the class above, it is broken across adjacent code spans at a word boundary, and the spans join with no separator — a `/` when the break falls on a path separator, nothing otherwise. Example: `` `testKeylessYouTubeIsNotOpenedWhen` + `SpotifyWins` `` denotes the single test name formed by joining those two spans directly. Every break of this kind in this document follows this convention.

**Sanitizer discipline.** This document contains no credential-shaped values, no `Authorization: Bearer` token samples (the header is always written as the `` `Authorization: Bearer` `` header — header name only), no `apiKey` assignments and no secret material of any kind. A request that carries a credential carries it in a request header, never in a URL, query parameter or deeplink.

**Sources verified for this document.** Every interface below was written against the worktree source, not against L1 prose alone: `YouTubeTool` / `YouTubeConfigStore`, `YouTubePlugin` / `AssistantPlugin`, `LocalToolTransport`, `CallLinkOpening` / `SystemCallLinkOpener`, `EncryptedLocalStorage` / `StorageError`, `StoragePlacementPolicy`, `GoogleAccountSession` / `GoogleAuthFlow`, `LocalToolLogStore` / `ToolLogReviewView`, `SettingsView.YouTubeSettingsView` / `SettingsTabs` / `SettingsTabMappingTests`, `KeywordIntentRule` (rule table, `Alternative` / `Group` / `Variant` / `Rule`, keyword enumerations), `VoiceContactSearchRoute` (veto site), `YouTubeRoute` (extractor mechanics), `IntentPrompt` / `IntentPromptTests` (budget pins), `GoldenCorpus` (15 music entries) / `GoldenCorpusTests`, `CommandRouter` (seams 646–648, ladder 898/1146/1189, `fireYouTubePlay` 2386, `logToolRequest` 2544, `dispatchInterpreted` 2640, `handlePluginCommand` 2922), `AppCoordinator` (lazy stores 1328–1360, registry registration 2058, router construction 3704–3717), `Info.plist`, `Localizable.xcstrings` (1341 keys at this baseline), `ios/tools/` + `check-release-log-safety.py` (`FEATURE_ROOTS` role model) and `check-release-log-safety-fixtures.py` (per-rule fixtures), `check-prompt-mirror.sh`.

---

## Overview

### 1. Purpose

Today a voice music request that reaches the music intent hits a first-class stub: the `case .music:` branch in `ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift` (line 2640) emits `command_music_stub` and speaks `router.musicStub` ("Music isn't ready yet. Coming soon." / "संगीत सुविधा अहिले तयार छैन। चाँडै आउनेछ।"). Nothing plays. This feature replaces that branch with the real playback path resolved by L1 (OD-S1 = PKCE-only public client, ADR-SP-01; OD-S3 = capability-first precedence with the 12-row state × outcome matrix, ADR-SP-02).

This document fixes what `plan-tasks` turns into coding tasks and what `implement` builds: the exact Swift surfaces (types, signatures, error enums), the data model and the one storage key, the two state machines (account-linking lifecycle, music playback attempt), the error mapping from every failure to exactly one matrix row, the complete `spotify.*` ne/en copy inventory, the intent/prompt-layer diffs with the test that pins each, the test seams per component, the log-surface contract and the release-gate roots, and a full traceability table over all 29 requirements.

### 2. Inputs

- `specs/define-requirements.md` + `specs/define-requirements/FR/FR-SP-00*.md`, `.../NFR/NFR-SP-00*.md` — FR-SP-001…017, NFR-SP-001…012.
- `specs/design-l1.md` — binding architecture; all ADR-SP-01…16 decisions, the §12 matrix, §15 auth flow, §16 data model, §20 parameters, §23 key inventory, §29 open items.
- `specs/spotify-music-integration/constitution.md` — feature constraints 1–12, routing/degradation contract, DV gate.
- `specs/spotify-music-integration/workflow.yaml` — task scope; `security-design-review` / `security-test` focus areas; release-gate requirement.
- `constitution.md` (root) — Architecture Constraint 1 as amended 2026-10-06; standards; release gates; agent principles (explicit error types, configurable timeouts, no silent stubs).

### 3. What this document resolves (the L1 §29 "For design-l2" list)

| L1 open item | Answered in |
|---|---|
| Exact Nepali/English copy for all `spotify.*` keys | §31 (complete inventory; the reviewable artifact) |
| Exact keyword/verb enumerations + extractor fixtures | §14 (rule + extractor) and §29 (signatures), tests in §22 |
| Plugin-composed prompt-budget check | §12 / §27 — no existing suite composes the real registry set against a ceiling (verified: `IntentPromptTests` composes `FakePlugin`s only); the guard added is a fragment-size assertion in `SpotifyPluginTests` plus the untouched digest/baseline pins |
| Which feature roots the log gate must gain | §20 — `Services/Spotify/`, `Services/Voice/SpotifyTool.swift`, `Services/Plugins/SpotifyPlugin.swift`; no new rule or fixture is needed (rules already exist and are fixture-covered per `check-release-log-safety-fixtures.py`) |
| `market` handling on search | §24 — omitted (`market` parameter exists for test shape, defaults `nil`); rationale below |
| OD-S2 quota-request appendix text | §23 — draft for the owner, `[OWNER INPUT]` markers, nothing invented |
| Settings-surface component spec (layout/state machine) | §17 (view spec + leaf state machine) |
| DV protocol document content | §23 (C-SP-16 outline; the artifact itself is written at implement/DV time) |

### 4. Cross-cutting conventions

**Error typing (agent principle: every interface declares its error types).** No new API returns an untyped error. `SpotifyTool.FetchError`, `SpotifyTool.PlayError`, `SpotifyAuthError` and `StorageError` are the complete error vocabulary; every case has a matrix row (§13). No `Error` existential is surfaced across a component boundary in the new code; thrown values are always one of these concrete enums.

**Timeouts are configuration.** Every network call carries an explicit timeout parameter with an injected default (§32). No timeout is a bare literal in the new code.

**Async failure mode + retryability.** §32's table states, per operation, whether it is retryable and what bounds it. The only automatic retry anywhere in the feature is the single token refresh per request (ADR-SP-13); searches, play attempts, deep-link opens and link flows are single-shot.

**Concurrency (explicit).** All Spotify-path mutable state (`SpotifyCredentialStore.record`, `SpotifyAccountSession.status`) is `@MainActor`-confined; the router's music path runs on the main thread like every other voice stage; network work runs off-main through the `LocalToolTransport` seam and results marshal back with `await MainActor.run` (the `fireYouTubePlay` pattern). Read/write rules per component are in §7–§23 ("Concurrency" paragraphs). No locks are introduced. A new turn does not cancel an in-flight music attempt (parity with the YouTube stage; accepted existing behaviour) — the outcome delivery of a superseded attempt is still exactly one spoken line, and both attempts record distinct observability events.

**No silent stubs.** Every path through `fireMusicRequest` ends in exactly one `speak(...)` call; the matrix is total (§13). The stub branch is deleted, not bypassed.

### 5. L2 decision log (refinements of L1; each is implemented, tested and reviewable)

| ID | Decision | Rationale / pin |
|---|---|---|
| L2-D1 | **`market` is omitted from the search request** (`apiSearchURL(query:market:)` carries `market` only when non-nil; the router passes `nil`). | The linked user token already scopes results to the account's market; a hardcoded country would be wrong for a household abroad. The parameter stays on the interface so tests can pin both shapes. `SpotifyToolTests.` + `testApiSearchURLOmitsMarketWhenNil` + `AndIncludesItWhenGiven` |
| L2-D2 | **Search is track-only** (`type=track`, `limit=1`). Playlists/albums/artists are not searched. | v1 scope is "music plays"; a track id has the validated 22-char shape this design hardens. `SpotifyToolTests.` + `testApiSearchURLIsTrackOnly` + `AndPercentEncoded` |
| L2-D3 | **Playback never manages devices.** No `device_id` is sent; 404 `NO_ACTIVE_DEVICE` degrades to the deep link. | Device transfer/selection is out of scope; the deep link lets the user start playback where they are. ADR-SP-13 |
| L2-D4 | **The YouTube leg of the concurrent search runs only when the YouTube path is keyed.** The keyless path is "askable" but is not pre-opened — its "search" *is* its outcome; pre-opening would start YouTube even when Spotify wins. | Reconciliation L2-R1 (below). `CommandRouterMusicTests.` + `testKeylessYouTubeIsNotOpenedWhen` + `SpotifyWins` |
| L2-D5 | **A link-time verification or scope failure stores nothing**; status becomes `.linkFailed(error)` and routing treats the account as unlinked (matrix row 12). | L1 §15.5 wording ("session stored but marked not usable") is reconciled to avoid a stored record that makes `isLinked` disagree with routing. Reconciliation L2-R2. `SpotifyAccountSessionTests.` + `testMissingScopesStoresNothingAnd` + `ShowsLinkFailed` |
| L2-D6 | **`SpotifyAuthError` gains four cases** — `noPresenter`, `presentationFailed(code:)`, `providerError(code:)`, `malformedResponse` — completing the "every failure has a case" rule; all content-free (numeric codes / fixed OAuth error vocabulary). | The L1 taxonomy could not map ASWebAuthenticationSession failures or an OAuth `error=` callback without leaking text or lying. `SpotifyAccountSessionTests` / `SpotifyAuthFlowTests` |
| L2-D7 | **The link-flow timeout cancels the session and surfaces `userCancelled`.** No dedicated timeout case. | The user-interactive flow has no "failure" semantics to add beyond the existing cancel path; the bound exists to guard abandoned sessions. `SpotifyAccountSessionTests.` + `testLinkFlowTimeoutCancelsAnd` + `ReportsCancelled` |
| L2-D8 | **The music rule excludes YouTube-marked utterances structurally**: `Rule` gains `excluded: [Group]` (default `[]`); the music rule sets `excluded: [youtubeKeywords]`. | Belt-and-braces to L1 §9.2/§9.3 (the YouTube stage runs first anyway). `KeywordIntentRuleTests.` + `testYouTubeMarkedUtteranceStill` + `MatchesTheYoutubeDomainDataDriven` |
| L2-D9 | **English narration forms `played`, `listened`, `sang`, `sung` are excluded from `musicVerbFamily`**; progressive forms (`playing`, `listening`, `singing`) are kept. | Mirrors the `youtubeVerbFamily` narration comment ("searched stays out"); the golden "play a song" needs `play`. `KeywordIntentRuleTests.` + `testMusicRuleNeverFiresOn` + `NarrationDataDriven` |
| L2-D10 | **When every query token is dropped, the extractor falls back to the first music-marker token, then to the raw transcript.** | L1 §10's "never leave an empty query" rule, made deterministic: "भजन बजाऊ" searches "भजन", not the verb phrase. `KeywordIntentRuleTests.` + `testMusicQueryFallsBackToThe` + `MarkerNounWhenEverythingDrops` |
| L2-D11 | **Provider markers are query noise**: `spotify` (Latin token) and `स्पोटिफाइ` (Devanagari containment) are dropped like the YouTube markers. | "स्पोटिफाइमा गीत चलाऊ" must not search the provider name. `SpotifyToolTests`/`KeywordIntentRuleTests.testMusicQueryDropsProviderMarkers` |
| L2-D12 | **Observability outcome vocabularies are closed sets** (§28). No free-form string is ever emitted from the Spotify path. | NFR-SP-002; the events carry no metadata dictionary keys at all (`metadata: [:]`), so no `LogSanitiser.allowedKeys` change is needed. |
| L2-D13 | **`product` freshness needs no new field**: `SpotifySessionRecord` keeps ADR-SP-08's exact six fields; the verification age is derived from `expiry` (Spotify issues ~3,600 s tokens). | Keeps one-key atomic write and single-key wipe. §25, §32 |
| L2-D14 | **`.unknown` product behaves as not-remote-capable** (deep link only), exactly like `.free`; `spotifyRemoteCapable` is `product == .premium` per L1 §11. | No fabricated capability; an actually-Premium account with an unknown product still gets Spotify via the deep link. `CommandRouterMusicTests.testUnknownProductUsesTheDeepLink`. **W2 amendment (2026-10-07):** the provider's OpenAPI schema marks `/v1/me`'s `product` field deprecated (verified 2026-10-07) — if it is ever removed, this row's `.unknown` degradation is the shipped safe fallback; T-123's bundle carries the record. |
| L2-D15 | **`SpotifyPlugin` handles explicit-Spotify requests; its prompt fragment explicitly routes general music requests to the `music` intent.** | Keeps the router's degradation ladder (including the YouTube fallback) on every bare-music utterance; the plugin path cannot chain to YouTube without entangling the plugin (ADR-SP-07 / NFR-SP-012). §27 |

**Reconciliation L2-R1 (keyless YouTube leg).** L1 §11 reads "when both are askable, both searches are fired concurrently". The keyless YouTube path's "search" is the terminal open of the search deeplink (`YouTubeTool.openSearch`), so pre-running it would open YouTube even when Spotify wins the selection. L2 narrows the concurrent leg to the keyed (fetch) path: `youtubeAskable` is unchanged; when YouTube is askable only keylessly, only the Spotify fetch runs and the YouTube outcome is executed (unmodified `fireYouTubePlay`) only if Spotify cannot serve. The concurrency claim that matters to NFR-SP-001 (two network legs joined, bounded by `max(provider budget)`) applies whenever both *fetches* exist. Pinned by `CommandRouterMusicTests.` + `testKeylessYouTubeIsNotOpenedWhen` + `SpotifyWins` and `testBothKeyedProvidersAre` + `SearchedConcurrently`.

**Reconciliation L2-R2 (verification failure storing).** L1 §15.5 says a scope failure leaves "session stored but marked not usable". A stored record makes `spotifyAskable` (`store.record != nil` per §16) true while routing must take unlinked treatment (matrix row 12) — two sources of truth. L2 stores nothing on `verificationFailed`/`missingScopes`; the status shows the failed/relink state, and routing is unlinked because the store is empty. The requirement's substance (verify before trusting; honest relink surface) is preserved; the storage mechanics change deliberately.

### 6. Marked gaps (not guessed — carried for the named owner)

1. **OD-S2 owner inputs** (L1 §5): Dashboard-owning account, household Premium account, free-tier test account, extra test-user emails, final app name / business details / privacy-policy URL, rollout-note copy approval, the final-sign-off line. Every one remains `[OWNER INPUT — …]` in §23; no account, email or Dashboard value is invented here.
2. **Dashboard scheme acceptance** (L1 risk 1): whether the Spotify Dashboard accepts `sahayak-spotify` as a redirect scheme is unverifiable from the codebase. The validator is exact-match against a single constant (§26); if the Dashboard refuses the custom scheme, only the constant's value changes (`sahayak-spotify` → the re-shaped scheme), and the validator, its tests and the `Info.plist` entry move with it. Flagged for `security-design-review`.
3. **The keyless YouTube path remaining as shipped** (L1 Reconciliation 2 / risk 3): this design's `youtubeAskable` predicate and L2-R1 depend on it. If that path ever changes, revisit §13 with it.
4. **Spotify's quota-extension review window** (L1 §5(b)): unknown to the design; recorded at filing time by the owner.

---

## Components

### 7. Component map

C-SP-01…16 per L1 §25. File paths as declared by L1; state ownership and concurrency are stated per component. `NEW` = new file in the change set; `CHANGED` = existing file edited.

| ID | Component | Files | State ownership | Concurrency |
|---|---|---|---|---|
| C-SP-01 | `SpotifyTool` | NEW `ios/ElderlyAssistant/Services/` + `Voice/SpotifyTool.swift` | none (pure statics) | stateless; safe to call from any task |
| C-SP-02 | `SpotifyCredentialStore` | NEW `ios/ElderlyAssistant/Services/` + `Spotify/SpotifyCredentialStore.swift` | the one record (`spotify.session`) | `@MainActor` |
| C-SP-03 | `SpotifyAccountSession` | NEW `ios/ElderlyAssistant/Services/` + `Spotify/SpotifyAccountSession.swift` | status + flow in flight | `@MainActor`; network via transport seam, results marshalled back |
| C-SP-04 | `SpotifyAuthFlow` (+ `SpotifyAuthSession` seam) | NEW `ios/ElderlyAssistant/Services/` + `Spotify/SpotifyAuthFlow.swift` | PKCE pair + state nonce for the duration of one link attempt | `@MainActor` presentation; pure helpers stateless |
| C-SP-05 | `SpotifyPlugin` | NEW `ios/ElderlyAssistant/Services/` + `Plugins/SpotifyPlugin.swift` | references to session/store/seams only | plugin holds no mutable state |
| C-SP-06 | Router music path | CHANGED `ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift` | none beyond turn-local values | main-thread turn; transport off-main |
| C-SP-07 | Music rule + extractor | CHANGED `ios/ElderlyAssistant/Services/` + `Voice/KeywordIntentRule.swift` | none (pure statics) | stateless |
| C-SP-08 | Contact-search music veto | CHANGED `ios/ElderlyAssistant/Services/` + `Voice/VoiceContactSearchRoute.swift` | none | stateless |
| C-SP-09 | Wiring | CHANGED `ios/ElderlyAssistant/App/` + `AppCoordinator.swift` | lazy composition | boot path |
| C-SP-10 | Settings surface | CHANGED `ios/ElderlyAssistant/App/` + `SettingsView.swift`, `SettingsTabs.swift` | binds the coordinator's live session/store | `@MainActor` (view) |
| C-SP-11 | Localisation catalog | CHANGED `ios/ElderlyAssistant/Resources/` + `Localizable.xcstrings` | none | n/a |
| C-SP-12 | Info.plist | CHANGED `ios/ElderlyAssistant/Info.plist` | none | n/a |
| C-SP-13 | Release log-safety gate | CHANGED `ios/tools/` + `check-release-log-safety.py` | none | n/a |
| C-SP-14 | Tool-log + observability | CHANGED `ios/ElderlyAssistant/Services/` + `Voice/LocalToolLogStore.swift`, `App/ToolLogReviewView.swift` | the encrypted tool log | store `@MainActor` |
| C-SP-15 | Tests | NEW/CHANGED under `ios/ElderlyAssistantTests/` | n/a | n/a |
| C-SP-16 | DV protocol artifact | NEW `specs/SP-device-validation-protocol.md` (+ results) | n/a | n/a |

### 8. C-SP-01 — `SpotifyTool`

**Responsibility.** Search (`GET https://api.spotify.com/v1/search`), remote playback control (`PUT https://api.spotify.com/v1/me/player/play`), validated `spotify:` deep-link construction, and deep-link opening through the shared `CallLinkOpening` seam. Caseless enum of pure statics, mirroring `YouTubeTool`: no state, no logging, no UI, no retries.

**Data flows.**
- Search: caller supplies the query + an access token + a `LocalToolTransport`; the tool builds the URL, sets the request timeout, performs the request, maps transport/HTTP errors to `FetchError`, parses `tracks.items[0]`, validates the id shape, returns `TrackResult`.
- Play: caller supplies a validated `spotify:track:` URI + token + transport; the tool sends a PUT with the URI in the JSON body `{"uris":["<uri>"]}` and maps status to `PlayError`.
- Deep link: caller supplies a query or a validated id; the tool returns a `spotify:` URL (or nil), then `open(_:opener:)` probes with `canOpenURL` and opens; result is `OpenOutcome`.

**Credentials.** The access token travels in the request header only (the `` `Authorization: Bearer` `` header, set from the parameter). No token is ever a URL component, query parameter or deeplink. No token is logged, echoed in an error, or included in an event.

**Hostile-input boundary.** `trackURI(id:)` never constructs a URI from unvalidated input; `searchURI(query:)` percent-encodes the query and caps it; the only scheme the tool can produce is `spotify` (plus the pre-existing YouTube shapes, which the tool never builds). The full grammar is §24.

**Failure behavior.** Every `FetchError`/`PlayError` case maps to a matrix row in §13; the tool itself makes no decisions about speaking, fallback or retry.

**Test seam.** `SpotifyToolTests` (§22) with a fake `LocalToolTransport` and a fake `CallLinkOpening`; URL-shape assertions, parse fixtures, error injection, the hostile corpus. No real network.

### 9. C-SP-02 — `SpotifyCredentialStore`

**Responsibility.** Own the single encrypted record `SpotifySessionRecord` under the single key `spotify.session`, backed by the existing `EncryptedLocalStorage` seam (Keychain-backed, Data Protection Complete). `@MainActor ObservableObject`.

**Data model.** Exactly ADR-SP-08 / L1 §16 (six fields, no additions): `accessToken`, `refreshToken`, `expiry`, `product`, `scope`, `linkedAt`. One Codable value under one key: atomic write, single-key wipe, one `StoragePlacementPolicy.keychainResidentKeys` addition (`"spotify.session"`). No other key, no plaintext fallback, no `UserDefaults`, no file path, never the repository.

**Read semantics.** The store loads the record in `init`; a missing or corrupt record reads as not configured (`record == nil`, `isLinked == false`) with no plaintext fallback. `save`/`clear` return `Result<Void, StorageError>`; a failed write leaves the previous record in place (or nil), and a failed clear is surfaced, never swallowed (the status flips only on a confirmed wipe).

**Single source of truth.** The store is the one read point for the router (askability), the account session and the Settings surface; `isLinked` is derived (`record != nil`), never stored separately, so there is no split-brain state (NFR-SP-010 scenario 4).

**Wipe evidence.** After `clear()` a sweep of the storage seam finds no Spotify value; the unlink test asserts the store reads not-configured and neither the tool log nor the console carries token material.

**Test seam.** `SpotifyCredentialStoreTests` with a fake `EncryptedLocalStorage` (`GeminiInMemoryStorage` precedent): round-trip of all six fields, clear, corrupt-store degradation, write/clear failure surfacing, and the key constant pinned so `StoragePlacementTests`' exact-set edit is forced.

### 10. C-SP-03 — `SpotifyAccountSession`

**Responsibility.** The caregiver-facing account lifecycle: `link()`, `unlink()`, `markRevoked()`, `validAccessToken()`, `status`. `@MainActor ObservableObject`; holds the presenter closure; stores nothing outside C-SP-02; uses `SpotifyAuthFlow` (C-SP-04) for PKCE/URLs/parsing and its own transport for token exchange, `/v1/me` verification and refresh.

**State machine A — linking lifecycle** (guards in parentheses; every transition is a test):

```
 .notLinked ──link()──► .linking ──callback valid + exchange ok + verify ok ──► .linked(.premium | .free | .unknown)
     ▲                     │   │
     │                     │   ├─ user cancels / denies / flow times out ──► .linkFailed(.userCancelled)   [record: none]
     │                     │   ├─ redirect/state mismatch ──► .linkFailed(.redirectMismatch|.stateMismatch) [record: none]
     │                     │   ├─ provider error param ──► .linkFailed(.providerError(code:))              [record: none]
     │                     │   ├─ token endpoint non-200 ──► .linkFailed(.exchangeFailed(statusCode:))     [record: none]
     │                     │   ├─ /v1/me non-200 ──► .linkFailed(.verificationFailed(statusCode:))         [record: none]
     │                     │   ├─ scope check fails ──► .linkFailed(.missingScopes(granted:))              [record: none]  (L2-D5)
     │                     │   └─ store write fails ──► .linkFailed(.storageFailure)                       [record: unchanged]
     │                     └─ no presenter / no client ID ──► .linkFailed(.noPresenter | .notConfigured)
     │
 .linked ──unlink()──► .notLinked            (record cleared; only on a confirmed wipe)
 .linked ──validAccessToken() refresh + invalid_grant──► .notLinked   (wipe; emit spotify_unlink outcome revoked)
 .linkFailed ──link()──► .linking            (re-attempt starts clean; no residual state)
```

`.notConfigured` (no client ID in `Info.plist`) is the dormant state: `link()` returns `.failed(.notConfigured)` immediately, the Settings row hides the Link action, and nothing crashes (the `GoogleAccountSession` missing-client-ID precedent). A `.linkFailed` status is transient UI state, cleared when the next attempt starts.

**State machine B — music playback attempt** (in the router, C-SP-06; here for the transitions the session participates in):

```
 IDLE
  └─ askable? (record present AND transport seam present)
      ├─ no  ─► UNLINKED-TREATMENT branch of the matrix (rows 8/9/12)
      └─ yes ─► TOKEN: validAccessToken()
                  ├─ .revoked           → session wiped → UNLINKED-TREATMENT (row 10)
                  ├─ .refreshFailed/.networkUnavailable/.storageFailure → SEARCH-FAILURE branch (row 11 → row 7 shape)
                  └─ .success(token)    → SEARCH (concurrent legs per §13)
                       ├─ usable        → SELECT: remote (Premium) | deep link | YouTube | honest line
                       │     ├─ REMOTE: playTrack → ok → SPOKEN spotify.playing
                       │     │            ├─ 401 → one forced refresh → retry once → second 401 → wipe → UNLINKED-TREATMENT
                       │     │            └─ 403/404/network → DEEP-LINK branch
                       │     └─ DEEP-LINK: canOpenURL → open → opened → SPOKEN spotify.openApp
                       │                                   └─ not opened → SPOKEN spotify.appMissing (terminal)
                       ├─ empty/failed  → YouTube fallback where it can serve, else the honest line
                       └─ not capable   → YouTube fallback where it can serve, else spotify.appMissing
```

**`validAccessToken()` contract.** Returns the current token when `Date() < expiry - 60 s` (60 s skew, a named constant `expirySkewSeconds`); otherwise performs exactly one refresh (`spotify.maxRefreshAttemptsPerRequest` = 1), persists the refreshed record (updating `expiry`; `refreshToken` retained or rotated per the response), and opportunistically re-verifies `product` with the refreshed token via `GET /v1/me` (best-effort; failure keeps the previous value). `invalid_grant` from the token endpoint → wipe + `.failure(.revoked)`. Transport error → `.failure(.networkUnavailable)`. Non-200 other → `.failure(.refreshFailed(statusCode:))`. Store write failure → `.failure(.storageFailure)`. Never loops.

**Product staleness (L2-D13).** `product` is written at link time and on every successful refresh. The derived verification age is `expiry - 3,600 s` (Spotify's token lifetime); when a request finds that age older than `spotify.capabilityStalenessSeconds`, the opportunistic `/v1/me` re-check runs on the refresh path — one request, no schema change. A stale `premium` with a lapsed subscription is caught honestly by the play attempt (403 → deep link); a stale `free` costs at most one deep-link hand-off (L1 §11).

**Unlink discipline.** `unlink()` deletes the single record. Spotify exposes no third-party revocation endpoint, and the design says so honestly: no remote revoke is attempted or claimed (ADR-SP-14). Emit one `spotify_unlink` event (outcome `success` or `failed`; `revoked` when the wipe was triggered by `invalid_grant`). Re-link works through the same flow with no residual state.

**Observability.** `spotify_link` per attempt (outcomes `success` / `failed` / `cancelled` / `not_configured` / `no_presenter`; `errorCode` = the `SpotifyAuthError` case name); `spotify_unlink` per wipe. No metadata. Never a token, code, verifier or state value.

**Test seam.** `SpotifyAccountSessionTests` with a fake `EncryptedLocalStorage`, a fake transport, and a fake `SpotifyAuthSession` seam; covers every transition above including refresh bounds, the wipe on `invalid_grant`, re-link cleanliness, the flow timeout (L2-D7) and the `notConfigured` dormancy.

### 11. C-SP-04 — `SpotifyAuthFlow`

**Responsibility.** PKCE generation (S256), authorize-URL construction with all scopes at sign-in, callback parsing and exact-match validation, token-exchange and refresh request bodies, token-response parsing — plus the injectable presentation seam `SpotifyAuthSession` (production: `ASWebSpotifyAuthSession` over `ASWebAuthenticationSession`).

**Flow (caregiver-performed).** `link()` resolves the presenter at present time; builds a fresh PKCE pair and a fresh `state` nonce; starts the seam with `callbackURLScheme` = the app scheme and `spotify.linkFlowTimeoutSeconds` (300 s); on callback, validates (exact match) before anything else; exchanges; verifies; stores. Nothing is stored, and no token/code/verifier/state value reaches any log (NFR-SP-009).

**Validation rules (exact match, zero exceptions).** Parse with `URLComponents`; require `scheme == "sahayak-spotify"` (case-sensitive), `host == "callback"`, empty path; require `state` present and equal to the stored nonce; require `code` present when no `error`; `error=access_denied` maps to `.userCancelled`, any other `error` value maps to `.providerError(code:)` (the fixed OAuth error vocabulary). Missing `state` or a mismatch → `.stateMismatch`; scheme/host/path mismatch → `.redirectMismatch`. On any rejection nothing is stored and no value is logged. The redirect constant is shared by `Info.plist` `CFBundleURLTypes`, the Dashboard registration and the validator; if the Dashboard refuses the scheme (gap 2), the constant moves and the validator/tests move with it.

**Scopes at sign-in.** `user-read-private`, `user-read-playback-state`, `user-modify-playback-state` are requested on the authorization request itself (the calendar-share `addScopes` lesson; `GoogleAccountSession.grantsRequiredScopes` is the verification precedent). **[M-3 supersession, 2026-10-06 — W1 review F-2]** the SHIPPED scope set is TWO scopes: `user-read-private` + `user-modify-playback-state`; `user-read-playback-state` was trimmed by the security design review (M-3) and is pinned absent by `SpotifyAuthFlowTests`. The two-scope set is the authority for implementation and for the OD-S2 Dashboard registration. No client secret exists anywhere (ADR-SP-01); the token exchange carries `code_verifier` only.

**Test seam.** `SpotifyAuthFlowTests`: RFC 7636-style verifier/challenge vector (verifier length 43–128, challenge = S256 of verifier), authorize-URL contents (all three scopes, `response_type=code`, `code_challenge_method=S256`, state), the callback accept/reject matrix, request-body shapes (form-encoded; no secret field), and token-response parse ok/malformed.

### 12. C-SP-05 — `SpotifyPlugin`

**Responsibility.** The `AssistantPlugin` twin of `YouTubePlugin`: `pluginID = "spotify"`, `displayNameKey = "plugin.spotify.name"`, one action `spotify.play` with a `query` entity, `handle` → `.spoken` / `.failed(spokenApology:)` with `spotify.*` lines, `presentationView` nil. It handles **explicit-Spotify** requests (the fragment below routes general music requests to the `music` intent, L2-D15): no link → honest `.failed(spotify.notLinked)`; linked → same `SpotifyTool` calls (search → remote/deeplink) → `spotify.playing` / `spotify.openApp` / honest failure lines. It never calls the network outside `SpotifyTool`/session seams and never chains to YouTube (the router's ladder owns degradation, ADR-SP-07).

**Prompt fragment.** Kept at or under the YouTube fragment's size (the YouTube fragment is the size model; the compositor indents fragments identically). Exact text in §27. Plugin fragments compose only on the cloud path (`IntentPrompt.pluginSections(activePlugins)`); the on-device path composes none, so the 1,024-token context is unaffected.

**Observability.** Component `plugin_spotify` (the `YouTubePlugin` precedent), events `spotify_plugin_no_query`, `spotify_plugin_play_opened`, `spotify_plugin_played`, `spotify_plugin_no_results`, `spotify_plugin_failed`, `spotify_plugin_not_linked`, `spotify_plugin_app_missing`; outcomes `opened_app` / `success` / `failure`; no metadata.

**Test seam.** `SpotifyPluginTests` mirroring `YouTubePluginTests`: applicable to both locales; one action + a fragment that contains `spotify.play` and `query` and whose length is ≤ the YouTube fragment's length; no-query failure; unlinked failure line; linked handle speaks a `spotify.*` line and emits metadata-free events; app-absent failure; network-failure failure; `presentationView` nil.

### 13. C-SP-06 — Router music path

**Seams (dormant-nil pattern, added beside 646–648, injected at 689–691 and 709–711, wired by C-SP-09):** `spotifyAccountSession: SpotifyAccountSession?`, `spotifyTransport: LocalToolTransport?`, `spotifyLinkOpener: CallLinkOpening?`. All default nil so every pre-existing construction site and router test keeps compiling and behaving as before.

**Intake.** Three entry points, all terminal for the turn, exactly one of them fires per utterance:
1. ladder stage at ~1189: `case .music:` of the existing domain switch → `fireMusicRequest(query: KeywordIntentRule.musicQuery(from: preText) ?? preText)` (zero prompt tokens);
2. `dispatchInterpreted` `case .music:` (2640–2643, stub deleted): `fireMusicRequest(query: interpretedQuery ?? KeywordIntentRule.musicQuery(from: transcript) ?? transcript)`; emits nothing under the old stub names;
3. the plugin path (2922) is untouched; `SpotifyPlugin` serves explicit-Spotify requests per its fragment.

**Askability and selection (pure helpers, test-pinned).**
- `spotifyAskable` = `session?.isLinked == true && spotifyTransport != nil`.
- `youtubeAskable` = `youtubeConfigStore?.apiKey != nil || youtubeLinkOpener != nil` (L1 §11; unchanged).
- `spotifyRemoteCapable` = `product == .premium` (L2-D14).
- `spotifyDeepLinkCapable` = `spotifyLinkOpener != nil && opener.canOpenURL(trackURI)` for the resolved track.
- `youtubeServeable` for the selection = `youtubeAskable` (the YouTube leg's own outcome decides success; ADR-SP-06 keeps its behavior byte-identical to an explicit-YouTube request).

**Matrix → code mapping (rows exactly as L1 §12; every row is one test).**

| # | Condition at request time | Code path | Spoken line | Events | Tool-log |
|---|---|---|---|---|---|
| 1 | linked, Premium-capable, usable, remote play ok | search both legs (keyed YT) → `playTrack` 2xx | `spotify.playing` (fmt, title) | `spotify_search` usable; `spotify_play` ok | `.spotify` ok, query "", response "", status 204 |
| 2 | linked, Premium-capable, usable, remote play fails (403/404/network) | → deep link `spotify:track:` opened | `spotify.openApp` | `spotify_play` premium_required/restricted/no_active_device/network_failed; `spotify_deeplink` opened | `.spotify` fail, response "", status 403/404/nil |
| 3 | linked, free tier, usable | → deep link `spotify:track:` opened (no remote attempt) | `spotify.openApp` | `spotify_search` usable; `spotify_deeplink` opened | `.spotify` ok, response "", status nil |
| 4 | linked, free tier, usable, app absent | not capable → YouTube if serveable, else honest line | YouTube lines, or `spotify.appMissing` | `spotify_deeplink` not_opened (when attempted) / `spotify_fallback` youtube or app_missing | `.spotify` fail |
| 5 | deep-link open attempted and fails at attempt time | terminal, no chaining | `spotify.appMissing` | `spotify_deeplink` not_opened | `.spotify` fail, response = line |
| 6 | linked, search empty | YouTube if serveable, else honest line | YouTube lines, or `spotify.notFound` | `spotify_search` empty; `spotify_fallback` youtube/not_found | `.spotify` fail, status 200 |
| 7 | linked, search network/timeout/non-200/malformed/unusable | YouTube if serveable, else honest line | YouTube lines, or `spotify.unavailable` | `spotify_search` failed; `spotify_fallback` youtube/unavailable | `.spotify` fail, status or nil |
| 8 | unlinked (never/wiped/revoked) | YouTube only (keyed or keyless); else `spotify:search:` opened; else honest line | YouTube lines, `spotify.openSearch`, else `spotify.notLinked` | `spotify_fallback` youtube / spoken(not_linked key) ; `spotify_deeplink` opened on the search hand-off | `.spotify` entry only if a Spotify attempt happened |
| 9 | unlinked + YouTube seams dormant + no opener | honest line | `spotify.notLinked` | `spotify_fallback` not_linked | none |
| 10 | `invalid_grant` on refresh | session wipes → unlinked treatment (row 8) | row 8 lines | `spotify_unlink` revoked; row 8 events | none |
| 11 | refresh transport failure only | search-failure treatment (row 7 shape) | row 7 lines | `spotify_search` failed (when a search runs) / `spotify_fallback` | `.spotify` fail |
| 12 | link-time verification/scope failure | stored nothing → unlinked treatment (row 8); Settings shows linkFailed | row 8 lines; `spotifySettings.*` | `spotify_link` failed | none |

**Turn flow.** `fireMusicRequest(query:)`: resolve locale; `speakPreAck(locale:)` (parity with `fireYouTubePlay`); mark `attemptStartedAt`; run the askability checks; obtain the token (state machine B); search; select; execute; deliver exactly one spoken line; write at most one `.spotify` tool-log entry; emit the event pair. Async delivery mirrors `fireYouTubePlay`: main-thread entry, `Task` for network, `await MainActor.run` for speak/emit/log.

**YouTube fallback.** `fireYouTubePlay(query:)` is called verbatim (ADR-SP-06), preceded by `spotify_fallback` emission (outcome `youtube`) and followed by the turn's `.spotify` fail entry (when a Spotify attempt happened). No YouTube internals change.

**Double-handling guard.** The ordering makes it deterministic: YouTube-marked utterances are claimed at 1146 and never reach 1189; the music rule additionally excludes YouTube markers (L2-D8); every firing stage returns. Pinned by `CommandRouterMusicTests.` + `testYoutubeMarkedUtterance` + `NeverReachesTheMusicPath`.

**Test seam.** `CommandRouterMusicTests` (§22) — one test per matrix row plus the cross-cutting pins (never-stub, one-line-per-turn, keyless-not-opened (L2-R1), no-metadata events, no query/title in the tool log, egress allowlist).

### 14. C-SP-07 — `KeywordIntentRule` music rule + extractor

**What is added (exact):** `Domain.music`; `Rule.excluded: [Group]` (default `[]`); `musicMarkers` (internal, shared with the veto); `musicVerbFamily`; one rule entry ordered between the YouTube rule and the first `appLaunch` rule; `mentionsMusic(_:)` (internal, for C-SP-08); `musicQuery(from:maxLength:)` + `maxMusicQueryLength = 100`.

**`musicMarkers` (the shared family, exactly L1 §9.1):** भजन, गीत, गाना, संगीत, सङ्गीत (all as substring/phrase alternatives — postpositions fuse), Latin `music`, `song`, `bhajan` (whole-token). The plural "songs" is deliberately not a marker (out of the reviewed vocabulary; such an utterance still reaches the music path through the interpreter, stage 4 of §13).

**`musicVerbFamily` (full enumeration; the virama/matra fusion rule applies — every form ships explicitly, per the YouTube/grapheme precedent):**
- English whole tokens: `play`, `plays`, `playing`, `listen`, `listens`, `listening`, `sing`, `sings`, `singing` (L2-D9: `played`, `listened`, `sang`, `sung` excluded — narration guard).
- Nepali play family (identical to the `youtubeVerbFamily` block): चलाऊ / चलाऊँ / चलाउ / चलाउनुहोस् / चलाउनुस् / चलाइदिनुहोस् / चलाइदिनुस् / चलाइदिनु / चलाइदेऊ / चलाइदेऊँ / चलाइदेउ; the same eleven-form बजाऊ block; the twelve-form लगाऊ block (including the लगाउँ twin).
- Nepali listen family (identical to the `newsVerbFamily` सुनाऊ block): सुनाऊ / सुनाऊँ / सुनाउ / सुनाउनुहोस् / सुनाउनुस् / सुनाइदिनुहोस् / सुनाइदिनुस् / सुनाइदिनु / सुनाइदेऊ / सुनाइदेऊँ / सुनाइदेउ.
- Nepali sing family (new): गाऊ / गाऊँ / गाउ / गाउनुहोस् / गाउनुस् / गाइदिनुहोस् / गाइदिनुस् / गाइदिनु / गाइदेऊ / गाइदेऊँ / गाइदेउ.

**Rule shape.** `Rule(domain: .music, excluded: [youtubeKeywords], variants: [[musicMarkers, musicVerbFamily]])` — relaxed co-occurrence, exactly the youtube rule's shape. Deliberate conservative choice (L1 §9): noun-only phrases (उदाहरण "देवीको भजन") do not fire this stage; they reach the same music path via the interpreter's existing `music` intent. The खोज search family is deliberately NOT a music verb: "गीत खोज" falls to the interpreter, same treatment.

**Ordering.** `news → youtube → music → appLaunch (camera, photos, settings, weather, whatsapp, youtube, facebook, magnifier, health, instagram, calendar) → festivalDate → (dynamic) medicationPhoto`. The music rule is evaluated before every appLaunch rule so "युट्युब खोल र गीत चलाऊ"-class utterances keep resolving as the strict ladder would.

**Extractor `musicQuery(from:maxLength:)`** (mirrors `YouTubeRoute.extractQuery` mechanics exactly): split on whitespace/newlines; trim punctuation + danda per token; drop a token when `isMusicDropToken` — Latin whole-token drop set = the YouTube `latinDrops` set plus `music`, `song`, `bhajan`, `spotify`, `listen`, `listens`, `listening`, `sing`, `sings`, `singing`; Devanagari whole-token drop set = the YouTube `devanagariDrops` set plus भजन, गीत, गाना, संगीत, सङ्गीत, the सुनाऊ family and the गाऊ family; Devanagari containment drops = `युट्युब`, `स्पोटिफाइ` (any token containing them is dropped wholesale). If nothing survives, the first surviving *marker* token is used (L2-D10); if there is none, the raw transcript's tokens are used. Normalize with `NepaliTextNormalizer.normalize`, cap at `maxLength` (default 100), return nil only when the input canonicalizes empty. Worked fixtures (test-pinned): "भजन बजाऊ" → "भजन"; "पुरानो हिन्दी गीत बजाऊ" → "पुरानो हिन्दी"; "देवीको भजन" → "देवीको"; "युट्युबमा गीत चलाऊ" → "गीत" (only reachable in tests — the YouTube stage claims it in the ladder); "play a song" → "song"; "स्पोटिफाइमा गीत चलाऊ" → "गीत".

**Test seam.** `KeywordIntentRuleTests` additions (§22): match data-driven over the golden verb-bearing utterances, matched-keys payload, YouTube precedence, narration guard (L2-D9 examples), bare-noun non-fire, ordering after youtube/before appLaunch, the extractor fixtures above, the cap, and `mentionsMusic` data-driven against the veto vocabulary.

### 15. C-SP-08 — `VoiceContactSearchRoute` music veto

**Change (one insertion).** Immediately after the existing YouTube veto in `decide(transcript:)` (line 83 region), before the search-marker check:

```
if isYouTubeUtterance(text) { return .notSearch }      // existing
if KeywordIntentRule.mentionsMusic(text) { return .notSearch }   // [SPOTIFY] music veto — parity
```

`mentionsMusic` reuses the same `musicMarkers` alternatives (Latin whole-token, Devanagari substring) and canonicalizes internally, so the call is order-independent. Position parity with the YouTube veto; the direct-call veto above it is untouched.

**Non-over-block proof.** A contact request without a music marker ("आरवलाई फोन गर", "call ram", "मेरो छोरालाई फोन लगाऊ") does not match any marker → veto does not fire → unchanged behavior. The YouTube veto and the direct-call veto hold independently.

**Test seam.** `VoiceContactSearchRouteTests` additions: `testMusicShapedUtterances` + `AreNotContactSearches` (data-driven: "गीत चलाऊ", "भजन बजाऊ", "play a song", "संगीत सुनाऊ"), `testMusicVetoDoesNot` + `OverBlockContactRequests`, `testYoutubeVetoStillHolds` + `WithTheMusicVeto` ("युट्युबमा गीत खोज"), plus the existing contact-search suites unchanged.

### 16. C-SP-09 — `AppCoordinator` wiring

**Lazy stores (beside 1328–1360; first-use, not `init`, per BOOT-REVIEW P0-1):**

```
private(set) lazy var spotifyCredentialStore = SpotifyCredentialStore(storage: storage)
private(set) lazy var spotifyAccountSession: SpotifyAccountSession = {
    let session = SpotifyAccountSession(store: spotifyCredentialStore, flow: ASWebSpotifyAuthSession(),
                                        observabilityBus: observabilityBus)
    session.presenter = { [weak self] in self?.topPresentingViewController() }
    return session
}()
```

The presenter closure is resolved at present time, never captured (the `calendarShareSession` precedent at 9314–9322).

**[W2-review D1 amendment, 2026-10-07] The `observabilityBus:` argument is mandatory.** `SpotifyAccountSession`'s §26 init carries the bus as a trailing *defaulted* parameter whose default is a dropping sink (the GoogleAccountSession precedent), so a construction that omits it silently loses every `spotify_link` / `spotify_unlink` event (§10/§28, ADR-SP-14). The `calendarShareSession` construction passes `observabilityBus: observabilityBus` (AppCoordinator.swift:9318-9320); T-119 pins the same here with an event-delivery test.

**Registry (beside 2058):** `registry.register(SpotifyPlugin(accountSession: spotifyAccountSession, credentialStore: spotifyCredentialStore))`.

**Router construction (beside 3704–3717):** `spotifyAccountSession: spotifyAccountSession, spotifyTransport: URLSession.shared, spotifyLinkOpener: SystemCallLinkOpener()`.

**Removability (NFR-SP-012).** With all three router seams nil and the plugin unregistered, the feature is dormant: music requests reach the old stub-branch location and take the unlinked/no-seam honest path (§13 row 9 semantics); no crash; pre-existing tests compile unchanged. Pinned by the dormant-construction test in `CommandRouterMusicTests` and the registry-once test pattern.

### 17. C-SP-10 — Settings surface

**`SettingsDestination.spotify` (in `SettingsTabs.swift`).** `titleKey` = `spotifySettings.title`; `icon` = `music.note` (new row icon; the YouTube row uses `play.rectangle.fill`); no tab (`tab` derived, hidden-sheet membership); added to `hiddenSheetRows` in sheet order after `.youtube`: `[.geminiAI, .voiceEngine, .webSearch, .youtube, .spotify, .intentLog, .toolLog]`. `SettingsDestinationView` gains `case .spotify: SpotifySettingsView()`. Visible row count stays 21; the hidden sheet goes 6 → 7.

**`SpotifySettingsView` (new struct in `SettingsView.swift`, mirroring `YouTubeSettingsView` at 768):** `LeafScreen(titleKey: "spotifySettings.title")` containing, in order: the status card (icon + `spotifySettings.status.*` line + Link/Unlink actions), the privacy disclosure text (`spotifySettings.privacy`), the rollout note (`spotifySettings.rolloutNote`, shown while the Dashboard app is in development mode — honest, never hidden, OD-S2(c)), and the shared confirmation dialog for unlink (`spotifySettings.removeConfirm`, destructive confirmed, cancel = `common.back`). No credential field of any kind (ADR-SP-01); if the recorded contingency ever activates, the field uses the YouTube `credentialField` secure-entry recipe.

**Leaf state machine (derived from `SpotifyAccountSession.status`, never optimistic):**

```
notLinked      → status.notLinked;  primary action = Link (spotifySettings.link)
linking        → buttons disabled;   no status change until an outcome exists
linked(.premium) → status.linked;   primary action = Unlink (spotifySettings.unlink)
linked(.free)  → status.freeTier;   primary action = Unlink
linked(.unknown) → status.freeTier (L2-D14 wording: playback opens the app)
linkFailed(e)  → status.linkFailed; primary action = Link (re-attempt)
```

**Accessibility (NFR-SP-010).** 44×44 pt minimum controls; body text through `appearance.typography` tokens (18 pt-equivalent); VoiceOver labels on every control; status conveyed as text (never colour alone); the disclosure and rollout note readable at caption size with high contrast.

**Test seam.** `SettingsTabMappingTests` deliberate edits: `testHiddenSheetHoldsThe` + `RemovedTechnicalSections` gains `.spotify` in position; the partition/round-trip tests cover the new destination automatically; `testEveryRowTitleResolves` + `InBothLanguages` pins `spotifySettings.title` in the real catalog. The `testCloudProviderKeyScreens` + `AllLiveInTheHiddenSheet` peer set is unchanged (Spotify has no key screen).

### 18. C-SP-11 — Localisation catalog

`Localizable.xcstrings` gains the 20 keys of §31 with `ne` and `en` values both present and `extractionState` per the catalog's existing convention (`manual`, `state: translated` — the YouTube entries' shape). No hardcoded user-facing literal exists anywhere in the new paths; spoken lines go through `L10n.str` / `L10n.fmt` and settings text through the catalog. The full copy inventory is the reviewable artifact in §31 (owner sign-off requested there).

### 19. C-SP-12 — `Info.plist`

Three additive edits, no removals: (1) `LSApplicationQueriesSchemes` gains `spotify` (the `canOpenURL` pre-check must be honest — constraint 8); (2) `CFBundleURLTypes` gains one dict `{CFBundleTypeRole: Editor, CFBundleURLName: com.elderlyassistant.spotify, CFBundleURLSchemes: [sahayak-spotify]}` (the calendar-share entry is the shape precedent); (3) a new `SpotifyClientID` string whose value is copied from the Dashboard at implementation time — `[OWNER INPUT — public identifier; paste from the Dashboard into the plist, never into a document]`. No new usage description is added (no permission-protected API is touched).

### 20. C-SP-13 — Release log-safety gate

**Verified mechanics.** `check-release-log-safety.py` roles every `*.swift` under the source root as `engine` / `feature` / `other`. Rules 1–2 (transcript taint, raw-error rendering) apply to every file; rules 3–6 (any console write, content-worded console writes, unlisted metadata keys, content-derived event fields) apply only inside `FEATURE_ROOTS`. `check-release-log-safety-fixtures.py` requires one positive and one negative fixture per **rule** (not per root) and runs in every gate invocation. [W5-closure annotation, 2026-10-07 (T-121 / C-2): exact for rule 1 — the transcript rules are unconditional; LOOSE for rule 2 — the raw-error family (`string-describing`/`error-description`/`error-interpolation`/`error-argument`) is gated on the `engine` role (`ENGINE_FILES` only). The correct model, matching the shipped engine and plan.md's C-2 disposition (:141-143): rule 1 all files, rule 2 engine files, rules 3–6 `FEATURE_ROOTS`. Reproduced 2026-10-07: a raw-error print in a feature root is named only `feature-console-write`.]

**Change (exactly):** `FEATURE_ROOTS` gains three entries — `Services/Spotify/` (the whole new group: store, session, auth flow), `Services/Voice/SpotifyTool.swift`, `Services/Plugins/SpotifyPlugin.swift`. No new rule and no new fixture is required (the four feature rules exist and are fixture-covered); the gate's own verdict proves the sweep because a console write or content-derived event field in any newly listed file fails it. Files changed in place (`CommandRouter.swift`, `KeywordIntentRule.swift`, `VoiceContactSearchRoute.swift`, `LocalToolLogStore.swift`, `ToolLogReviewView.swift`, `SettingsView.swift`, `SettingsTabs.swift` and the `AppCoordinator`) stay in the `other` role — they are large pre-existing files whose coverage under rules 1–2 is the project's established position, exactly as today. `LogSanitiser.allowedKeys` is not touched (the new events carry no metadata keys at all). [W5-closure annotation, 2026-10-07 (T-121): shipped as TWO entries, not three — `Services/Voice/SpotifyTool.swift` is a stale path (that directory holds `YouTubeTool.swift`; `SpotifyTool.swift` lives in the `Services/Spotify` group and is covered by the group entry). Entries carry NO trailing slash: the match is `path == root or path.startswith(root + os.sep)`, so the prose `Services/Spotify/` must not be copied literally — a trailing-slash entry matches nothing. Shipped values: `"Services/Spotify"`, `"Services/Plugins/SpotifyPlugin.swift"` (15 → 17 entries), with this correction recorded in the list's comment.]

### 21. C-SP-14 — Tool log + observability

`LocalToolLogStore.Kind` gains `case spotify`; `ToolLogReviewView`'s kind→key mapping gains `case .spotify: key = "toolLog.kind.spotify"` (the view file is not otherwise changed). Entry contract (ADR-SP-15, stricter than YouTube):

| Situation | query | response | outcome | statusCode |
|---|---|---|---|---|
| Spotify served (remote or deep link opened) | "" | "" | "ok" | 204 on remote; nil on deep link |
| Spotify attempted, Spotify failed, fallback taken | "" | "" | "fail" | the Spotify failure status when known, else nil |
| Spotify attempted, terminal honest line spoken | "" | the spoken static line | "fail" | status when known, else nil |
| No Spotify attempt (unlinked rows, YouTube-only) | no entry — the YouTube leg writes its own existing entry | | | |

The tool log is the encrypted `LocalToolLogStore` only; nothing here reaches the observability bus. Events and their closed vocabularies are §28; `metadata: [:]` always. No query text, no track title, no track id, no token, no provider body reaches any log, event, telemetry or console — DV-7 and the gate are the evidence.

**Test seam.** `LocalToolLogStoreTests` gains a `spotify` kind round-trip; `CommandRouterMusicTests` pins the no-query/no-title/no-metadata assertions and the entry taxonomy above.

### 22. C-SP-15 — Test seams (suite-by-suite)

**New suites** (paths under `ios/ElderlyAssistantTests/` + `Services/...`; style mirrors the YouTube suites — XCTest, fake seams, `waitForDelivery()` async settling, `Locale(identifier: "ne-NP")` fixtures):

| Suite | Load-bearing assertions |
|---|---|
| `SpotifyToolTests` | URL shapes (track-only, percent-encoding, market nil/given, cap, rejection of empty/overlong); header-only credential (fake transport inspects the `URLRequest`; URL carries no token); parse ok/empty/malformed/unusable-id; timeout injection → `timedOut`; transport error → `transportUnavailable`; non-200 → `invalidResponse(statusCode:)`; `trackURI` hostile corpus (scheme text, `//`, quotes, controls, traversal, over-long, percent traps, 21/23-char, non-base62) all nil; `searchURI` encode + cap; open outcomes via a fake opener (`canOpenURL` probed before `open`); play request shape (PUT, body, timeout) and 401/403/404/network mapping |
| `SpotifyCredentialStoreTests` | six-field round-trip; clear wipes; corrupt/absent store reads not configured; write/clear failures surface `StorageError`; `storageKey == "spotify.session"` |
| `SpotifyAuthFlowTests` | PKCE pair (length bounds, challenge = S256 of verifier); authorize URL (three scopes, S256, state); callback accept matrix (valid; wrong scheme/host/path; missing state; state mismatch; missing code; `error=access_denied` → userCancelled; other error → providerError); form-encoded exchange/refresh bodies containing no secret field; token parse ok/malformed |
| `SpotifyAccountSessionTests` | every transition of state machine A; missingScopes/verification failure stores nothing (L2-D5); refresh within window makes no request; expired → exactly one refresh; `invalid_grant` wipes + status + event; refresh transport failure does not wipe; product re-verified on refresh, failure keeps the old value; unlink wipe + event; re-link clean; `notConfigured` dormant; flow timeout cancels (L2-D7) |
| `SpotifyPluginTests` | both locales; one action `spotify.play` + fragment contains the action and `query`, length ≤ YouTube fragment length; no-query failure; unlinked failure line; linked speaks Spotify line; app-absent; network failure; events carry no metadata; `presentationView` nil |
| `CommandRouterMusicTests` | one test per §13 matrix row (1–12); `testBareMusicRequestNeverSpeaksTheStub`; `testNoMusicBranchSpeaksThe` + `StubForInterpretedMusic` (scripted interpreter emits the music action with a query); `testYoutubeMarkedUtterance` + `NeverReachesTheMusicPath`; `testBothKeyedProvidersAre` + `SearchedConcurrently`; `testKeylessYouTubeIsNotOpenedWhen` + `SpotifyWins` (L2-R1); `testUnknownProductUsesTheDeepLink` (L2-D14); `testMusicTurnEndsInExactly` + `OneSpokenOutcomeLine` (data-driven over the rows); `testToolLogEntriesCarryNoQueryOrTitle`; `testObservabilityEventsCarryNoMetadata`; `testNoEgressBeyondTheProviderAllowlist` (every fake-transport request host ∈ `api.spotify.com`, `accounts.spotify.com`, the pre-existing YouTube hosts) |

**Touched suites (must stay green; each change deliberate).**
- `KeywordIntentRuleTests` — §14's additions (match, ordering, narration, bare-noun, extractor fixtures, `mentionsMusic`).
- `VoiceContactSearchRouteTests` — §15's additions; all existing tests unchanged.
- `SettingsTabMappingTests` — the §17 edits (hidden-sheet list content; the new destination rides the partition tests).
- `StoragePlacementTests` — `testTheKeychainSetIsExactly` + `TheReviewedSecrets` gains `"spotify.session"` (set equality forces the conscious edit; no other change).
- `LocalToolLogStoreTests` — the `spotify` kind round-trip.
- `IntentPromptTests` / `GoldenCorpusTests` / `YouTubeRouteTests` / `YouTubePluginTests` / `CommandRouterYouTubeTests` — **unchanged**; their greenness is the NFR-SP-004/005/006 guard (prompt bytes, the 15-entry music block, explicit-YouTube behavior). [W3-review M3 amendment, 2026-10-07: `CommandRouterYouTubeTests` is no longer *literally* unchanged — two fixtures are force-superseded because the utterance now terminates at the music stage before the assertion's stage ("play some music" → "play it", which re-exercises both original assertions) and `CommandRouterSafetyNetTests` moves one music-marked fixture to its marker-free twin (mirroring that file's [NO-GIBBERISH] precedent). Both edits are single-hunk, intent-preserving and documented in-code; the T-114 golden region and the explicit-YouTube behavior remain byte-identical and green — the review independently confirmed this in the parsed xcresult.]

**Golden-corpus supersession mechanics (constraint 5).** The corpus file is not edited: the 15 music utterances at `GoldenCorpus.swift` lines 143–157 all keep `intent: "music"` (the parser-level expectation is unchanged; `testCorpusHasAtLeast15EntriesPerIntent` keeps its floor). The deliberate supersession is at the **dispatch level**, recorded alongside the new expectation in `CommandRouterMusicTests` as a supersession block:

| Pinned item | Old expectation (pre-feature) | New expectation (this feature) |
|---|---|---|
| `case .music:` dispatch (2640–2643) | emits `command_music_stub`; speaks `router.musicStub` | routes to `fireMusicRequest`; speaks exactly one real outcome line; the stub event name is unreachable on every music branch |
| `router.musicStub` catalog key | reachable, spoken | retained in the catalog, **no reachable call site** (ADR-SP-11) |
| Golden music block (15 utterances) | parse to `intent: "music"` | parse to `intent: "music"` (unchanged); verb-bearing entries additionally reach the deterministic music stage |
| YouTube-marked request ("युट्युबमा गीत चलाऊ") | YouTube stage | YouTube stage (unchanged; test-verified) |

**Baseline discipline (NFR-SP-006).** The project's known pre-existing unit-test baseline stands; the feature's own suites must pass, and every touched-suite edit is one of the deliberate ones enumerated above.

### 23. C-SP-16 — DV protocol artifact (`specs/SP-device-validation-protocol.md`)

Written at implement/DV time (pattern: the LCT protocol). It records, per item: exact steps, the build/device, the expected observation, pass/fail, and the evidence. Items = L1 §6 DV-1…DV-7: (1) unlinked + YouTube configured, 'भजन बजाऊ' → a real outcome, never the stub; (2) linked Premium test user, 'गीत चलाऊ' → both providers searched, Spotify selected, sound; (3) 'युट्युबमा गीत चलाऊ' → YouTube exactly as before; (4) free-tier / unlinked / airplane-mode / empty-search, each repeated → its explicit localized line (or the fallback), no silence, no false "playing"; (5) Nepali end-to-end on Anzaan for 1–4; (6) Spotify app removed → honest app-absent/fallback; (7) console/sysdiagnose capture during 1–6 → zero tokens, credentials, query text or provider bodies. Run with the OD-S2 registered accounts; an unmet item is a recorded failure that blocks the completion claim (FR-SP-017).

**OD-S2 quota-request appendix (draft copy for the owner — `[OWNER INPUT]` to confirm/amend; nothing here is decided).** Use-case description for the extension form: a personal, voice-first assistant app for an elderly household (Nepali-first) that plays user-requested music; the integration searches the Spotify Web API with the linked household account's own token and, for Premium accounts, starts playback of the found track on the household's own devices; only the household's own accounts are served; no third-party users, no library or playlist writes, no data collection beyond what the API returns for the request. Dashboard app name `[OWNER INPUT — final name]`; redirect URI = the single registered constant; scopes = the two in §26 (M-3 supersession: `user-read-private` + `user-modify-playback-state`); contact/business details `[OWNER INPUT]`; privacy-policy URL `[OWNER INPUT]`.

---

## Interfaces

### 24. `SpotifyTool` — exact interface

```swift
enum SpotifyTool {
    struct TrackResult: Equatable {
        let id: String        // validated: base62, exactly 22 characters
        let title: String     // spoken-only; never in a URI, never logged
    }

    enum FetchError: Error, Equatable {
        case invalidResponse(statusCode: Int)   // non-2xx (incl. 401 on search — row 7 treatment)
        case noResults                          // 2xx but zero usable tracks
        case malformedResponse                  // unparseable payload / empty title
        case unusableResult                     // id present but failed validation
        case timedOut                           // URLError.timedOut
        case transportUnavailable               // other URL error / offline
    }

    enum PlayError: Error, Equatable {
        case invalidURI                         // defensive: uri.scheme != "spotify"
        case unauthorized                       // 401 (already after the single refresh)
        case premiumRequired                    // 403 with reason PREMIUM_REQUIRED
        case restricted                         // other 403
        case noActiveDevice                     // 404
        case invalidResponse(statusCode: Int)   // other non-2xx
        case timedOut
        case transportUnavailable
    }

    enum OpenOutcome: Equatable { case opened, notOpened }

    static let defaultFetchTimeoutSeconds: TimeInterval = 8   // injectable at every call site
    static let maxIdentifierLength = 22
    static let maxSearchQueryLength = 100                     // mirrors music.maxQueryLength

    static func apiSearchURL(query: String, market: String?) -> URL?   // nil: empty or over-cap query
    static func apiPlayURL() -> URL                                    // https://api.spotify.com/v1/me/player/play

    static func fetchTopTrack(query: String, accessToken: String,
                              transport: LocalToolTransport,
                              timeoutSeconds: TimeInterval = SpotifyTool.defaultFetchTimeoutSeconds)
        async throws -> TrackResult                                    // throws FetchError

    static func playTrack(uri: URL, accessToken: String,
                          transport: LocalToolTransport,
                          timeoutSeconds: TimeInterval = SpotifyTool.defaultFetchTimeoutSeconds)
        async throws -> Void                                           // throws PlayError

    static func parseSearchJSON(_ data: Data) throws -> TrackResult    // throws FetchError

    static func isSpotifyIdentifier(_ id: String) -> Bool              // ^[A-Za-z0-9]{22}$
    static func trackURI(id: String) -> URL?                           // spotify:track:<id>, nil unless validated
    static func searchURI(query: String) -> URL?                       // spotify:search:<percent-encoded>
    static func open(_ url: URL, opener: CallLinkOpening) -> OpenOutcome
}
```

**URI validation boundary (NFR-SP-008) — accepted-input grammar.**
- `trackURI(id:)`: accepted iff `id` matches `isSpotifyIdentifier` exactly — length 22, every scalar in `[A-Za-z0-9]`, nothing else. Rejected inputs include (test corpus): any `/`, `:`, `?`, `#`, `%`, `.`, `-`, `_`, whitespace or control character; scheme text; `//`; quotes; path traversal; non-base62 Unicode; lengths 0, 21, 23, 100. A rejected id returns nil and produces no partial URI.
- `searchURI(query:)`: accepted iff the trimmed query is non-empty and its `Character` count ≤ `maxSearchQueryLength` (100). The query is percent-encoded with `CharacterSet.urlQueryAllowed` minus `+&=?/%#`, so no unencoded query delimiter survives; the result must parse with scheme `spotify`. Empty/over-cap → nil.
- `apiSearchURL(query:market:)`: accepted iff same query bounds; built with `URLComponents`/`URLQueryItem` (`q`, `type=track`, `limit=1`, plus `market` only when non-nil); returns a `https` URL on `api.spotify.com` only.
- **Scheme allowlist:** the tool constructs only `spotify:` URIs (deep links) and `https:` URLs on the two allowlisted hosts (API calls). The hostile corpus asserts every construction/opener call in the suite stays inside the allowlist.

**Request hardening.** The search and play requests set `timeoutInterval = timeoutSeconds` and carry the credential in the `` `Authorization: Bearer` `` header only. Play body: `{"uris":["<uri.absoluteString>"]}` where `uri` is a `spotify:track:` URL produced by `trackURI`. 403 handling inspects the JSON `error.reason` for `PREMIUM_REQUIRED` (content stays in memory, is never logged, echoed or stored); unparsable → `.restricted`. 401 on `playTrack` is returned to the caller for the single-refresh dance; 401 on `fetchTopTrack` is a row-7 search failure.

### 25. `SpotifyCredentialStore` — exact interface

```swift
struct SpotifySessionRecord: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var product: String?      // "premium" | "free" | nil
    var scope: String?        // granted scope string (verification)
    var linkedAt: Date
}

@MainActor
final class SpotifyCredentialStore: ObservableObject {
    static let storageKey = "spotify.session"
    @Published private(set) var record: SpotifySessionRecord?
    var isLinked: Bool { record != nil }

    init(storage: EncryptedLocalStorage)

    @discardableResult func save(_ record: SpotifySessionRecord) -> Result<Void, StorageError>
    @discardableResult func clear() -> Result<Void, StorageError>
}
```

Placement: `StoragePlacementPolicy.keychainResidentKeys` gains `"spotify.session"` (the exact-set test is edited deliberately). Corrupt/absent storage → `record == nil`, no plaintext fallback.

### 26. `SpotifyAccountSession` + `SpotifyAuthFlow` — exact interfaces

```swift
enum SpotifyAuthError: Error, Equatable {
    case notConfigured                  // no client ID → feature dormant, never a crash
    case noPresenter                    // no host controller at present time               (L2-D6)
    case userCancelled                  // cancel, deny, or flow timeout                   (L2-D7)
    case redirectMismatch               // scheme/host/path mismatch
    case stateMismatch                  // missing or unequal state nonce
    case providerError(code: String)    // OAuth error param, fixed vocabulary             (L2-D6)
    case exchangeFailed(statusCode: Int)
    case malformedResponse              // token endpoint 2xx but unparseable              (L2-D6)
    case verificationFailed(statusCode: Int)
    case missingScopes(granted: String)
    case refreshFailed(statusCode: Int)
    case revoked                        // provider said invalid_grant
    case storageFailure(StorageError)
    case networkUnavailable
    case presentationFailed(code: Int)  // ASWebAuthenticationSession failure, numeric code (L2-D6)
}
```

**`SpotifyAuthFlow` (statics) + the presentation seam.**

```swift
enum SpotifyAuthFlow {
    static let authorizeEndpoint: URL      // https://accounts.spotify.com/authorize
    static let tokenEndpoint: URL          // https://accounts.spotify.com/api/token
    static let redirectURI = "sahayak-spotify://callback"   // one constant: plist + Dashboard + validator
    static let callbackScheme = "sahayak-spotify"
    static let callbackHost = "callback"
    static let scopes = ["user-read-private", "user-modify-playback-state"]   // M-3 supersession: two scopes (see the §11 note; W1 review F-2)

    static func makePKCE() -> (verifier: String, challenge: String)      // verifier 43–128 chars, S256
    static func authorizeURL(clientID: String, state: String, challenge: String) -> URL?
    static func parseCallback(_ url: URL, expectedState: String) -> Result<String, SpotifyAuthError>  // .success(code)
    static func tokenExchangeRequest(code: String, verifier: String, clientID: String) -> URLRequest
    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest

    struct TokenResponse: Equatable {
        let accessToken: String
        let refreshToken: String?          // present on authorization_code; may be absent on refresh
        let expiresIn: TimeInterval
        let scope: String
    }
    static func parseTokenResponse(_ data: Data) -> TokenResponse?       // nil = malformed
}

protocol SpotifyAuthSession: AnyObject {
    @MainActor func authorize(url: URL, callbackURLScheme: String) async throws -> URL
}
@MainActor final class ASWebSpotifyAuthSession: SpotifyAuthSession { /* ASWebAuthenticationSession */ }
```

**`SpotifyAccountSession`.**

```swift
@MainActor
final class SpotifyAccountSession: ObservableObject {
    enum Product: Equatable { case premium, free, unknown }
    enum Status: Equatable {
        case notLinked
        case linking
        case linked(Product)
        case linkFailed(SpotifyAuthError)
    }
    enum LinkOutcome: Equatable {
        case linked(Product)
        case failed(SpotifyAuthError)
        case cancelled                        // userCancelled / timeout, surfaced distinctly for the UI copy
    }

    static var bundledClientID: String? { get }   // Info.plist key "SpotifyClientID"; nil → notConfigured

    var presenter: (() -> UIViewController?)?
    @Published private(set) var status: Status
    var isLinked: Bool                    // status is .linked(...) only
    var product: Product

    init(store: SpotifyCredentialStore,
         flow: SpotifyAuthSession,
         transport: LocalToolTransport = URLSession.shared,
         clientID: String? = SpotifyAccountSession.bundledClientID,
         refreshAttemptLimit: Int = 1,                    // spotify.maxRefreshAttemptsPerRequest
         capabilityStalenessSeconds: TimeInterval = 3600, // spotify.capabilityStalenessSeconds
         linkFlowTimeoutSeconds: TimeInterval = 300,      // spotify.linkFlowTimeoutSeconds
         expirySkewSeconds: TimeInterval = 60)

    func link() async -> LinkOutcome
    func unlink() -> Result<Void, StorageError>
    func markRevoked() -> Result<Void, StorageError>
    func validAccessToken() async -> Result<String, SpotifyAuthError>
}
```

`isLinked` is true exactly when `status` is `.linked(…)`; the store's `record != nil` and the status are written together by the session, so routing and UI cannot disagree (L2-D5/L2-R2). `markRevoked()` is the wipe used by both the refresh path (`invalid_grant`) and the router's second-401 path; it emits `spotify_unlink` outcome `revoked`.

**Observability (both components).** `spotify_link` per attempt — outcomes `success` / `failed` / `cancelled` / `not_configured` / `no_presenter`; `errorCode` = the `SpotifyAuthError` case name only (never an associated value except the numeric status inside `refreshFailed`-class events, which are not emitted here). `spotify_unlink` — `success` / `failed` / `revoked`; `errorCode` `"storageFailure"` on failure. `metadata: [:]` always.

### 27. `SpotifyPlugin` — exact interface

```swift
final class SpotifyPlugin: AssistantPlugin {
    let pluginID = "spotify"
    let displayNameKey = "plugin.spotify.name"

    init(accountSession: SpotifyAccountSession,
         credentialStore: SpotifyCredentialStore,
         transport: LocalToolTransport = URLSession.shared,
         linkOpener: CallLinkOpening = SystemCallLinkOpener())

    func isApplicable(locale: Locale) -> Bool { true }        // English and Nepali households alike

    var intentContribution: PluginIntentContribution          // actionNames: ["spotify.play"]; fragment below

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult
    func presentationView(for result: PluginResult) -> AnyView? { nil }
}
```

**Prompt fragment (exact text; routes bare music to the `music` intent, L2-D15):**

```
PLUGIN CAPABILITY (Spotify): if the user asks to play or search
something on Spotify specifically ("play bhajan on spotify",
"स्पोटिफाइमा गीत चलाऊ"), set action to "plugin", pluginAction to
"spotify.play", and pluginEntities to {"query": "<what they want>"}.
General music or bhajan requests without the word Spotify are NOT this
capability — use the "music" intent for those.
```

**`handle` behavior.** Trim `entities["query"]`; empty → event `spotify_plugin_no_query`, `.failed(spokenApology: L10n.str("spotify.unavailable"))`. Not linked → event `spotify_plugin_not_linked`, `.failed(L10n.str("spotify.notLinked"))`. Linked: `validAccessToken()` (failure → `.failed` with `spotify.unavailable`, or `spotify.notLinked` for `.revoked`); `fetchTopTrack`; on `noResults` → `spotify.notFound`; on another fetch failure → `spotify.unavailable`; on success: Premium-capable → `playTrack` (ok → `.spoken(L10n.fmt("spotify.playing", title))`; 403/404/network → deep link); free/unknown → deep link `trackURI`; deep-link open not-opened → `spotify.appMissing`. Events per §12; no metadata; no YouTube chaining. [W4-review M1 annotation, 2026-10-07: a remote-play 401 takes the same single-shot deep-link fallback as every other play failure — the plugin never refreshes, retries or calls `markRevoked`; the router's music path owns the forced refresh (matrix rows 2/10/12; ADR-SP-07).]

### 28. Router music path — exact interface, events, tool-log contract

**Seams (added to the `init` signature and stored beside 646–648):**

```swift
private let spotifyAccountSession: SpotifyAccountSession?
private let spotifyTransport: LocalToolTransport?
private let spotifyLinkOpener: CallLinkOpening?
```

**Methods (new, private; the pure selection helper is internal for tests).**

```swift
private func fireMusicRequest(query: String)
private func deliverMusicLine(locale: Locale, key: String, statusCode: Int?,
                              outcome: String, startedAt: Date)      // static lines
private func emitSpotify(eventType: String, outcome: String,
                         durationMs: Int?, errorCode: String?)

enum MusicOutcome: Equatable {
    case spotifyRemote(SpotifyTool.TrackResult)
    case spotifyDeepLink(SpotifyTool.TrackResult)
    case spotifySearchHandoff
    case youtube
    case honestLine(String)        // L10n key: notFound | unavailable | notLinked | appMissing
}
static func selectMusicOutcome(spotifyLinked: Bool,
                               spotifyTransportPresent: Bool,
                               search: Result<SpotifyTool.TrackResult, SpotifyTool.FetchError>?,
                               product: SpotifyAccountSession.Product,
                               deepLinkCapable: Bool,
                               youtubeServeable: Bool,
                               spotifySearchOpenerPresent: Bool) -> MusicOutcome
```

`selectMusicOutcome` is pure, total and data-driven-tested; it encodes §13's rows as conditions, in order: linked+usable+remote-capable → remote; linked+usable+deep-link-capable → deep link; linked+usable+not capable → YouTube if serveable else appMissing; linked+search failure → YouTube if serveable else notFound/unavailable by error class; unlinked → YouTube if serveable, else search hand-off if an opener exists, else notLinked; linked+transport missing → the row-7 branch.

**Observability vocabulary (component `spotify`; `metadata: [:]` on every event; `durationMs` only where stated).**

| eventType | When | Closed outcome set |
|---|---|---|
| `spotify_search` | once per Spotify search attempt | `usable`, `empty`, `failed` |
| `spotify_play` | once per remote-play attempt | `ok`, `premium_required`, `restricted`, `no_active_device`, `unauthorized`, `network_failed` |
| `spotify_deeplink` | once per deep-link attempt (track or search hand-off) | `opened`, `not_opened` |
| `spotify_fallback` | once per fallback/terminal branch | `youtube`, `not_linked`, `not_found`, `unavailable`, `app_missing` |
| `spotify_link` | once per link attempt (session) | `success`, `failed`, `cancelled`, `not_configured`, `no_presenter` |
| `spotify_unlink` | once per wipe (session/router) | `success`, `failed`, `revoked` |

**Tool-log contract.** At most one `.spotify` entry per music turn, written iff a Spotify search or play/deep-link attempt happened; `query` is always `""`; `response` is `""` unless a terminal honest line was spoken (then the exact line); `outcome` `"ok"` only when Spotify served; `statusCode` from the last HTTP response when one exists; `durationMs` from the attempt start. Never a title, id, token or provider body.

**Turn guarantee.** Exactly one `speak(...)` per turn from the music path (plus the pre-ack, which is the existing convention and not an outcome line); every branch of `selectMusicOutcome` and every failure of the execute step reaches a `speak` call before the turn returns.

### 29. Intent layer — exact interface additions

```swift
// KeywordIntentRule.swift
enum Domain: String { case news, youtube, music, appLaunch, festivalDate, medicationPhoto }  // + music

private struct Rule {
    let domain: Domain
    let variants: [Variant]
    let appID: String?
    let excluded: [Group]        // NEW — a variant never fires when any excluded group matches
}

// internal (used by VoiceContactSearchRoute):
static let musicMarkers: Group                       // भजन, गीत, गाना, संगीत, सङ्गीत, music, song, bhajan
static func mentionsMusic(_ raw: String) -> Bool     // canonicalizes internally; same alternatives
static let maxMusicQueryLength = 100
static func musicQuery(from raw: String,
                       maxLength: Int = KeywordIntentRule.maxMusicQueryLength) -> String?
```

`Rule`'s memberwise init gains `excluded: [Group] = []` so every existing rule table entry is untouched. The music rule entry sits between the youtube rule and the camera rule (§14). `VoiceContactSearchRoute` calls `KeywordIntentRule.mentionsMusic(text)` (§15). No change to `YouTubeRoute.swift`, `IntentPrompt.swift`'s core template, `ChatIntentClassifier`, or any encoder/interpreter action list: the music wording already exists in the prompt and the interpreter's music action already exists (pinned by `IntentPromptTests.testMentionsAllCanonicalIntentValues`, the digest pins and `testPromptStaysWithin` + `OnDeviceCharacterBudget`); the only intent-layer addition is `spotify.play` in `SpotifyPlugin.intentContribution`.

### 30. Wiring, settings, plist, gate — exact edit list

| File | Edit |
|---|---|
| `ios/ElderlyAssistant/App/` + `AppCoordinator.swift` | two lazy stores (§16); one `registry.register(SpotifyPlugin(...))`; three `CommandRouter` init arguments |
| `ios/ElderlyAssistant/Services/` + `Voice/CommandRouter.swift` | three seams + init params; `fireMusicRequest`/`deliverMusicLine`/`emitSpotify`/`selectMusicOutcome`; ladder `case .music:`; dispatch stub replacement; `Kind.spotify` log calls |
| `ios/ElderlyAssistant/Services/` + `Voice/KeywordIntentRule.swift` | §14/§29 additions |
| `ios/ElderlyAssistant/Services/` + `Voice/VoiceContactSearchRoute.swift` | the one music-veto insertion (§15) |
| `ios/ElderlyAssistant/Services/` + `Voice/LocalToolLogStore.swift` | `case spotify` |
| `ios/ElderlyAssistant/App/` + `ToolLogReviewView.swift` | one mapping case |
| `ios/ElderlyAssistant/App/` + `SettingsTabs.swift` | `case spotify` destination + title/icon/tab/hidden-sheet/view mapping |
| `ios/ElderlyAssistant/App/` + `SettingsView.swift` | `SpotifySettingsView` struct |
| `ios/ElderlyAssistant/Resources/` + `Localizable.xcstrings` | the 20 keys (§31) |
| `ios/ElderlyAssistant/Info.plist` | the three additions (§19) |
| `ios/tools/` + `check-release-log-safety.py` | three `FEATURE_ROOTS` entries (§20) |
| `ios/seniOS.xcodeproj/project.pbxproj` | new Swift files in the app target and the test target (same change) |
| `specs/SP-device-validation-protocol.md` | NEW artifact (§23) |

### 31. Localisation inventory — the complete `spotify.*` copy (REVIEWABLE ARTIFACT)

20 keys, `ne` and `en` both mandatory; a missing translation is a failure, not a fallback to English. No `ne` value contains English prose (the provider name is the Devanagari loanword स्पोटिफाइ; the existing `YouTube` loanword precedent applies to युट्युब in the `removeConfirm` line). Only `spotify.playing` embeds a runtime value (the remote-sourced track title; spoken-only, never carded, never logged, never part of any URI). **This table is the artifact for owner sign-off** (FR-SP-016, NFR-SP-005; the rollout note's copy is an OD-S2 owner approval item).

| Key | English | Nepali | Used by |
|---|---|---|---|
| `spotify.playing` | "Playing %@ on Spotify." | "स्पोटिफाइमा %@ चलाउँदैछु।" | matrix row 1 (remote play ok); plugin success |
| `spotify.openApp` | "Opening Spotify — play it there." | "स्पोटिफाइ खोल्दैछु — त्यहाँ बजाउनुहोस्।" | rows 2/3 (deep-link hand-off opened) |
| `spotify.openSearch` | "Opening Spotify search." | "स्पोटिफाइमा खोज खोल्दैछु।" | row 8 (unlinked, search hand-off opened) |
| `spotify.notFound` | "I couldn't find that music on Spotify." | "स्पोटिफाइमा त्यो संगीत भेटिएन।" | row 6 (empty search, no YouTube) |
| `spotify.unavailable` | "Spotify isn't available right now. Please try again." | "अहिले स्पोटिफाइ उपलब्ध छैन। फेरि प्रयास गर्नुहोस्।" | row 7 (search/refresh failure, no YouTube) |
| `spotify.notLinked` | "Spotify isn't set up yet. A family member can add it in Settings." | "स्पोटिफाइ अझै जोडिएको छैन। परिवारका सदस्यले सेटिङमा जोड्न सक्नुहुन्छ।" | rows 8/9/12 (unlinked, nothing else can serve) |
| `spotify.appMissing` | "The Spotify app isn't on this phone, so I can't play the music." | "यो फोनमा स्पोटिफाइ एप छैन, त्यसैले संगीत बजाउन सकिनँ।" | rows 4/5 (app absent; terminal after an attempted open) |
| `spotify.rolloutLimited` | "Spotify hasn't approved this account yet. Please try again later." | "स्पोटिफाइले यो खातालाई अझै स्वीकृति दिएको छैन। पछि फेरि प्रयास गर्नुहोस्।" | OD-S2 unregistered-account guidance |
| `plugin.spotify.name` | "Spotify" | "स्पोटिफाइ" | plugin display name |
| `spotifySettings.title` | "Spotify" | "स्पोटिफाइ" | settings row + leaf title |
| `spotifySettings.status.linked` | "Connected (Premium)" | "जोडिएको (प्रिमियम)" | status row, Premium |
| `spotifySettings.status.freeTier` | "Connected (free — playback opens the Spotify app)" | "जोडिएको (निःशुल्क — गीत स्पोटिफाइ एपमा खुल्छ)" | status row, free/unknown |
| `spotifySettings.status.notLinked` | "Not connected" | "जोडिएको छैन" | status row |
| `spotifySettings.status.linkFailed` | "Couldn't connect. Please try again." | "जोड्न सकिएन। फेरि प्रयास गर्नुहोस्।" | status row after a failed link |
| `spotifySettings.link` | "Connect Spotify" | "स्पोटिफाइ जोड्नुहोस्" | Link action (caregiver framing) |
| `spotifySettings.unlink` | "Remove Spotify" | "स्पोटिफाइ हटाउनुहोस्" | Unlink action + dialog confirm button |
| `spotifySettings.removeConfirm` | "Remove the Spotify connection? Music will use YouTube only." | "स्पोटिफाइ जडान हटाउने हो? संगीत युट्युबबाट मात्र बज्नेछ।" | unlink confirmation dialog |
| `spotifySettings.privacy` | "What you ask for — including play commands — is sent to Spotify to find music and control playback; no other app data is sent." | "गीत खोज्न र बजाउन तपाईंले भन्नुभएको कुरा — बजाउने आदेश सहित — स्पोटिफाइमा पठाइन्छ; अरू कुनै डेटा पठाइँदैन।" | privacy disclosure (FR-SP-016) [W6-closure annotation, 2026-10-07 (M-2 / security-design-review.md:121): the row originally carried the pre-amendment sentence ("What you ask for is sent to Spotify to find the music; nothing else is sent." / "संगीत खोज्न तपाईंले भन्नुभएको कुरा स्पोटिफाइमा पठाइन्छ; अरू केही पठाइँदैन।"); it now shows the M-2-amended copy exactly as shipped in `Localizable.xcstrings`, so this sign-off artifact and the catalog agree — the amendment is made before the owner's copy sign-off as required.] |
| `spotifySettings.rolloutNote` | "Spotify's service is still being tested; for now only approved accounts can connect." | "स्पोटिफाइ सेवा अझै परीक्षणमा छ; अहिले स्वीकृत खाताले मात्र जोड्न सकिन्छ।" | rollout note while in development mode (OD-S2(c)) |
| `toolLog.kind.spotify` | "Spotify" | "स्पोटिफाइ" | tool-log review row label |

### 32. Configuration parameters

| Parameter | Interface (exact name) | Default | Owner | Retryability / failure mode |
|---|---|---|---|---|
| `spotify.fetchTimeoutSeconds` | `timeoutSeconds` on `fetchTopTrack` / `playTrack`, default `SpotifyTool.defaultFetchTimeoutSeconds` | 8.0 | call sites (router/plugin) | single-shot; timeout → `timedOut` → matrix row 7 (search) / deep-link (play) |
| `music.outcomeBudgetSeconds` | test assertion in `CommandRouterMusicTests` | 10.0 | test | assertion: when at least one provider answers, the outcome line lands within budget |
| `music.negativeBudgetSeconds` | test assertion | 16.0 | test | assertion: no path waits longer than two sequential provider budgets before speaking |
| `spotify.maxRefreshAttemptsPerRequest` | `refreshAttemptLimit` on the session init | 1 | AppCoordinator call site | counted; never loops (ADR-SP-13) |
| `spotify.capabilityStalenessSeconds` | `capabilityStalenessSeconds` on the session init | 3,600 | AppCoordinator call site | best-effort re-check on the refresh path; failure keeps the stored product (§10) |
| `music.maxQueryLength` | `maxLength` on `musicQuery`, default `KeywordIntentRule.maxMusicQueryLength`; `maxSearchQueryLength` on the tool | 100 | extractor/tool | over-cap input → nil URI / capped extraction |
| PKCE verifier / challenge | `makePKCE()` | 43–128 chars / S256 | `SpotifyAuthFlow` | spec-fixed, not tunable |
| `spotify.linkFlowTimeoutSeconds` | `linkFlowTimeoutSeconds` on the session init | 300 | AppCoordinator call site | timeout cancels the seam → `userCancelled` (L2-D7) |

### 33. Log-surface discipline (interface level, NFR-SP-002 / ADR-SP-15)

- **No new console writes.** The new files contain zero `print` statements in any configuration (the gate's feature-role rule enforces this for the three new roots).
- **No content in events.** Every Spotify event is `component: "spotify"` (or `plugin_spotify`) with `metadata: [:]` and the closed vocabularies of §28; `errorCode` is only a case name or a numeric status. No `LogSanitiser.allowedKeys` change is needed or made.
- **No content in the tool log.** Query always `""`; response `""` unless a terminal static line was spoken; never a title, id, token or provider body (§28).
- **No credential anywhere except the header.** The token travels in the `` `Authorization: Bearer` `` header on the two API hosts only; the authorize/token exchange bodies carry the PKCE verifier (a per-attempt secret, discarded after use) and never a client secret, which does not exist.
- **The gate.** `ios/tools/check-release-log-safety.sh` runs in every `ios/build.sh` scope; it must exit 0 before any unit or Release gate runs. The three feature-root additions (§20) are the feature's deliberate change to it.

---

## Traceability — every requirement mapped

All 29 requirements are touched by this design; none is untouched, and no requirement is silently dropped.

| Requirement | Component(s) | Interface (exact symbol) | Test seam |
|---|---|---|---|
| FR-SP-001 stub → real playback | C-SP-06 | `fireMusicRequest` replacing the `command_music_stub` branch | `CommandRouterMusicTests.testBareMusicRequestNeverSpeaksTheStub`, `testNoMusicBranchSpeaksThe` + `StubForInterpretedMusic`; DV-1 |
| FR-SP-002 both-provider search | C-SP-06, C-SP-01 | `selectMusicOutcome(...)`, concurrent keyed fetches (L2-R1) | `testBothKeyedProvidersAre` + `SearchedConcurrently`, `testOneProviderUnavailable` + `DoesNotBlockTheOther`, `testNeitherProviderAskable` + `SpeaksNotLinked` |
| FR-SP-003 Spotify preferred | C-SP-06, C-SP-03 | `spotifyRemoteCapable`, `spotifyDeepLinkCapable` inside `selectMusicOutcome` | `testSpotifyWinsWhenLinkedAndCapable`, `testFreeTierGoesStraightToTheDeepLink`; DV-2 |
| FR-SP-004 YouTube fallback | C-SP-06 | rows 4/6/7/8 → `fireYouTubePlay(query:)` verbatim (ADR-SP-06) | matrix-row tests 4/6/7/8; YouTube suites unchanged; DV-4 |
| FR-SP-005 explicit YouTube unchanged | C-SP-07 (exclusion), C-SP-06 (ordering) | `Rule.excluded = [youtubeKeywords]`; ladder 1146 first | `KeywordIntentRuleTests.` + `testYouTubeMarkedUtteranceStill` + `MatchesTheYoutubeDomainDataDriven`; `YouTubeRouteTests`/`CommandRouterYouTubeTests` unchanged; DV-3 |
| FR-SP-006 SpotifyPlugin | C-SP-05, C-SP-09 | `SpotifyPlugin: AssistantPlugin`, `registry.register` | `SpotifyPluginTests`; registry-once pattern |
| FR-SP-007 tool + deep links | C-SP-01 | `SpotifyTool.fetchTopTrack` / `playTrack` / `trackURI` / `searchURI` / `open` | `SpotifyToolTests` incl. the hostile corpus; DV-1 |
| FR-SP-008 account linking | C-SP-03, C-SP-04 | `SpotifyAccountSession.link()`, `SpotifyAuthFlow.authorizeURL/parseCallback` | `SpotifyAccountSessionTests`, `SpotifyAuthFlowTests` |
| FR-SP-009 encrypted store | C-SP-02 | `SpotifyCredentialStore.save/clear`, `storageKey` | `SpotifyCredentialStoreTests`; `StoragePlacementTests` |
| FR-SP-010 unlink wipe / revoked | C-SP-03, C-SP-02 | `unlink()`, `markRevoked()`, `validAccessToken()` `.revoked` | `SpotifyAccountSessionTests` (wipe, revoked, re-link) |
| FR-SP-011 free-tier deep link | C-SP-06, C-SP-01 | rows 2/3/5 → `spotifyDeepLink` / `spotifySearchHandoff`; `OpenOutcome` | `testPremiumRemotePlayFailure` + `FallsToTheDeepLink`, `testDeepLinkOpenFailureSpeaks` + `AppMissingTerminal`; DV-4 |
| FR-SP-012 honest outcomes | C-SP-06, C-SP-11 | total matrix; `deliverMusicLine` | `testMusicTurnEndsInExactly` + `OneSpokenOutcomeLine` (all rows); DV-4 |
| FR-SP-013 keyword music rule | C-SP-07 | `Domain.music`, `musicMarkers`, `musicVerbFamily`, the rule entry | `KeywordIntentRuleTests` additions (§14) |
| FR-SP-014 contact veto | C-SP-08 | `mentionsMusic(_:)` insertion after the YouTube veto | `VoiceContactSearchRouteTests` additions (§15) |
| FR-SP-015 route intake | C-SP-06, C-SP-07 | ladder `case .music:`; `musicQuery(from:)` | `CommandRouterMusicTests` intake/no-double-handling tests |
| FR-SP-016 Settings + disclosure | C-SP-10, C-SP-11 | `SettingsDestination.spotify`, `SpotifySettingsView`, §31 copy | `SettingsTabMappingTests` edits; catalog completeness; DV-5 |
| FR-SP-017 DV checklist | C-SP-16 | `specs/SP-device-validation-protocol.md` | Checklist recorded and passed on Anzaan |
| NFR-SP-001 responsiveness/timeouts | C-SP-01, C-SP-06 | `timeoutSeconds` parameters; §32 budgets | timeout-injection tests; budget assertions; DV-1/4 |
| NFR-SP-002 log safety | C-SP-06, C-SP-13, C-SP-14 | §28 event vocabulary; §28 tool-log contract; `FEATURE_ROOTS` additions | `testToolLogEntriesCarryNoQueryOrTitle`, `testObservabilityEventsCarryNoMetadata`; gate exit 0; DV-7 |
| NFR-SP-003 no new egress | C-SP-01, C-SP-06 | `apiSearchURL`/`apiPlayURL` hosts; seams | `testNoEgressBeyondTheProviderAllowlist` |
| NFR-SP-004 prompt budget | C-SP-05, C-SP-07 | fragment size guard; zero core-template delta | `IntentPromptTests` unchanged; `SpotifyPluginTests` fragment-size assertion |
| NFR-SP-005 localisation | C-SP-11 | §31 (20 keys, ne+en) | catalog completeness in both languages; spoken-line tests; DV-5 |
| NFR-SP-006 no regression | all | ordering, exclusions, dormant seams, untouched `YouTubeRoute` | YouTube suites unchanged; golden 15 hold; baseline recorded |
| NFR-SP-007 encryption at rest | C-SP-02 | `SpotifySessionRecord` under `spotify.session` | store tests; placement; wipe sweep |
| NFR-SP-008 URI hardening | C-SP-01 | `isSpotifyIdentifier`, `trackURI`, `searchURI` grammar (§24) | hostile-corpus suite |
| NFR-SP-009 redirect + token lifecycle | C-SP-03, C-SP-04 | `parseCallback`, `validAccessToken`, `SpotifyAuthError` | callback matrix; refresh bounds; wipe; log-free assertions |
| NFR-SP-010 accessibility | C-SP-10 | `SpotifySettingsView` per §17 | accessibility assertions in settings tests |
| NFR-SP-011 compliance/release gates | C-SP-12, C-SP-13, C-SP-16 | plist entries; gate roots; DV protocol | gate exit 0; TLS hosts (allowlist); DV + release checklist |
| NFR-SP-012 plugin isolation | C-SP-05, C-SP-06, C-SP-09 | dormant seams; plugin boundaries | registry/dormant-construction tests; diff-surface check |

## Technical risks and mitigations

| # | Risk | Mitigation (implemented where) | Residual |
|---|---|---|---|
| 1 | Dashboard refuses the custom redirect scheme | One constant in `SpotifyAuthFlow`; validator/tests/plist move together; nothing else depends on the string (§11, gap 2) | Recorded at registration; flagged for security review |
| 2 | Stale `product` misroutes one attempt | Play attempt is the honest catch (403 → deep link); re-verify on every refresh; stale `free` costs one hand-off (L1 §11) | Accepted, bounded |
| 3 | Keyless-YouTube pre-open hazard (would start YouTube when Spotify wins) | L2-R1: no pre-open; pinned by `testKeylessYouTubeIsNotOpenedWhen` + `SpotifyWins` | None if the keyless path is unchanged (gap 3) |
| 4 | A hostile/odd provider payload crafting a URI or a spoken claim | id shape validation, percent-encoding, titles never in URIs, scheme allowlist, hostile corpus; `spotify.playing` spoken only on a confirmed 2xx or a confirmed open | Static-analysis limits stated in the gate docs |
| 5 | Off-main state mutation / interleaved turns | Main-actor confinement (C-SP-02/03), seams for network, one spoken line per attempt; superseded attempts do not cancel (documented parity) | Existing stage behaviour, accepted |
| 6 | Prompt-budget growth | Core template untouched (digest pins); fragment is cloud-path only; fragment-size guard added | None |
| 7 | Log regressions in the new files (raw print, body, metadata key) | Gate feature-roots additions; closed event vocabularies; tool-log contract; DV-7 | Gate's documented static limits |
| 8 | Xcode target drift (new files not added) | `project.pbxproj` edit is part of the change set; test:impact mapping mirrors the source tree | Build-time detection |
| 9 | L10n drift (missing `ne`) | Catalog completeness test both languages; no literals in new paths | None |
| 10 | Refresh/revocation loops | `refreshAttemptLimit` = 1; `invalid_grant` wipes and never retries; play retry once on 401 only | None |

## Not in this design

Explicit boundary (constraints 4, 6, 11 and the L1 out-of-scope list). None of the following is built, changed or prepared for:

- **No brain/router model-stack changes.** No model swap, no prompt-model change, no classifier change; the interpreter's existing `music` action and the core prompt's existing music wording are used as-is.
- **No new backend.** The Spotify Web API is called directly from the app; nothing is provisioned on our side.
- **No cloud LLM on the music path.** The query goes to the two provider APIs only; the cloud voice stack's recorded exceptions (Open Decisions 12/13) are not invoked by this feature.
- **No playback beyond track search + play:** no playlists, albums, artists, library edits, playlist mutations or account modifications; playback is read-only, user-initiated control (or an OS hand-off).
- **No remote token revocation**: Spotify exposes no third-party revocation endpoint; unlink is a local wipe and the design never claims otherwise (ADR-SP-14).
- **No device management**: no `device_id`, no transfer-playback.
- **No credential/secret field**: no client secret exists anywhere; the recorded OD-S1 contingency (family-entered credential) is not built.
- **No changes to `YouTubeRoute.swift` internals**, no changes to the emergency/medication/health surfaces, no wake-word, no Android, no new `Info.plist` usage descriptions, no new observability metadata keys, no `LogSanitiser` allow-list change.
- **No edits to the pinned test surfaces**: `IntentPrompt.swift`'s core template, `GoldenCorpus.swift`, `tools/train-intent/seeds/prompt_template.txt` (the mirror gate stays green trivially), and the YouTube suites.
