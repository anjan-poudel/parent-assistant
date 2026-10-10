# T-118 — SpotifyPlugin and trimmed prompt fragment (C-1) — implementation notes

Status: COMPLETE (worktree `elderly-ai-assistant-spotify-music-integration`,
branch `feat/spotify-music-integration`; changes left uncommitted per
instructions — no `git add`/commit/push was run).
Date: 2026-10-07. Depends on shipped T-106 (SpotifyTool), T-107 (deep-link
half), T-110 (SpotifyAccountSession) and T-117 (localisation catalog); all
were used exactly as shipped and none was modified.

## What was built

### 1. `ios/ElderlyAssistant/Services/Plugins/SpotifyPlugin.swift` (NEW)

`final class SpotifyPlugin: AssistantPlugin` — the C-SP-05 `YouTubePlugin`
twin (design-l2 §12, §27; FR-SP-006), signature exactly §27:

```swift
init(accountSession: SpotifyAccountSession,
     credentialStore: SpotifyCredentialStore,
     transport: LocalToolTransport = URLSession.shared,
     linkOpener: CallLinkOpening = SystemCallLinkOpener())
```

- `pluginID = "spotify"`, `displayNameKey = "plugin.spotify.name"` (shipped
  T-117 catalog key), `isApplicable(locale:) == true` for both locales.
- `intentContribution`: exactly one action, `spotify.play`, with the trimmed
  C-1 fragment (below).
- `presentationView(for:) == nil` on every result; no view, no presenter.
- `handle(_:context:)` implements §27 exactly (events per §12, component
  `plugin_spotify`):
  - trim `entities["query"]`; empty → `spotify_plugin_no_query` (failure) +
    `.failed(spotify.unavailable)`;
  - not linked → `spotify_plugin_not_linked` + `.failed(spotify.notLinked)`;
  - linked: `validAccessToken()` — `.revoked` → the unlinked treatment
    (event `spotify_plugin_not_linked`, line `spotify.notLinked`); any other
    failure → `spotify_plugin_failed` + `.failed(spotify.unavailable)`;
  - `SpotifyTool.fetchTopTrack(query:accessToken:transport:)` — `.noResults`
    → `spotify_plugin_no_results` + `.failed(spotify.notFound)`; any other
    error → `spotify_plugin_failed` + `.failed(spotify.unavailable)`;
  - success: `product == .premium` → one `SpotifyTool.playTrack(trackURI:…)`
    attempt; 2xx → `spotify_plugin_played` (success) + `.spoken(L10n.fmt(
    "spotify.playing", title))`; ANY play failure (401 included) → the
    deep-link fallback, single-shot. `.free` / `.unknown` (L2-D14) → the
    deep link directly, no remote attempt;
  - deep link `SpotifyTool.open(trackURI, opener:)` — `.opened` →
    `spotify_plugin_play_opened` (opened_app) + `.spoken(spotify.openApp)`;
    `.notOpened` → `spotify_plugin_app_missing` + `.failed(spotify.appMissing)`.
- No YouTube chaining anywhere (`fetchTopTrack`/`playTrack`/`open` are the
  only tool calls); no console write; every event built by one private
  static constructor with `metadata: [:]`, `errorCode: nil` and no metadata
  parameter — the query, title and token have no path into an event.
- No new localisation keys; the file uses only the shipped T-117 catalog
  keys: `plugin.spotify.name`, `spotify.playing`, `spotify.notLinked`,
  `spotify.unavailable`, `spotify.notFound`, `spotify.appMissing`,
  `spotify.openApp` (`spotify.openSearch` is the router's unlinked search
  hand-off, not a plugin line per §27, and is untouched).
- NOT registered anywhere: no change to `AppCoordinator`, `PluginRegistry`
  or `project.yml` (registration is T-119; xcodegen picked the new files up
  automatically during the gate run — no hand-edit of `project.pbxproj`).

### 2. The C-1 fragment trim (the load-bearing deviation)

The §27 literal measures **368 Swift graphemes / 376 UTF-16 code units**;
the YouTube literal (`YouTubePlugin.intentContribution.promptFragment`)
measures **326 graphemes / 341 UTF-16 code units**. The design's budget
numbers (341, 376 — also quoted in the task) are the UTF-16 measures; a
Swift `String.count` is the extended-grapheme measure, which is smaller
because Devanagari aksharas fuse combining marks. The trimmed fragment,
shipped here, measures **319 graphemes / 327 UTF-16** — under BOTH measures
(trim of 49 in each), keeping:

- the `spotify.play` token and the `query` entity token,
- the Nepali example `"स्पोटिफाइमा गीत चलाऊ"`,
- the L2-D15 routing sentence verbatim, whitespace-normalised: *"General
  music or bhajan requests without the word Spotify are NOT this
  capability — use the "music" intent for those."*

Trimmed wording (changed lines only): `if the user asks to play or search
something on Spotify specifically ("play bhajan on spotify", "स्पोटिफाइमा
गीत चलाऊ")` → `if the user asks to play or search on Spotify
("स्पोटिफाइमा गीत चलाऊ")` (the English example and "something …
specifically" dropped; the L2-D15 sentence and the emitted
action/entity instruction are untouched).

### 3. `ios/ElderlyAssistantTests/Services/Plugins/SpotifyPluginTests.swift` (NEW)

19 tests, mirroring `YouTubePluginTests` and the `CommandRouterMusicTests`
harness (file-private doubles: `PluginStubTransport` host+path router,
`PluginLinkOpener` probe script, `PluginUnusedAuthSession`; shared
`SpotifyInMemoryStorage` / `RecordingObservabilityBus` /
`GeminiInMemoryStorage` / `FakeGeminiTransport` fixtures reused). Coverage:

- both locales applicable; exactly one action `["spotify.play"]`;
  `pluginID` / `displayNameKey` pins;
- the C-1 budget test: the YouTube model pinned as `utf16.count == 341`
  AND `count == 326`, the Spotify fragment ≤ both, contains `spotify.play`
  + `query`, and the whitespace-normalised L2-D15 sentence;
- no-query (missing and whitespace-only entities) with zero requests;
- the trimmed query is what reaches the tool (exact search URL equality);
- unlinked → `spotify.notLinked`, zero provider requests;
- linked+premium remote ok → `spotify.playing` with the title; token in the
  Authorization header only, never a URL; one search + one play request, no
  refresh, no probe; event pair `spotify_plugin_played|success`;
- free and unknown products → direct deep link, zero play requests
  (L2-D14), `spotify_plugin_play_opened|opened_app`, `spotify.openApp`;
- premium play 403 → deep link exactly once (no retry, no forced refresh —
  the router owns the ladder), `spotify.openApp`;
- app absent (probe false) → `spotify.appMissing` +
  `spotify_plugin_app_missing|failure`, nothing opened;
- `noResults` → `spotify.notFound`; network failure and non-200 →
  `spotify.unavailable`; both with the typed event;
- `.revoked` refresh (`invalid_grant`) → `spotify.notLinked`, session
  wiped, no search after the rejected grant, session's own
  `spotify_unlink|revoked` event present;
- refresh transport failure → `spotify.unavailable`, record KEPT (row 11);
- `presentationView` nil for spoken and failed results;
- event hygiene: exact event-pair pins per test plus a sweep asserting
  component `plugin_spotify`, `metadata: [:]`, `errorCode: nil` and that no
  event field ever carries the query, title, token or an egress host.

## Gate

Command (serialized through `/tmp/spotify-lockrun.sh` so the parallel agent
never shares an xcodebuild):

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
  ./build.sh test:unit SpotifyPluginTests YouTubePluginTests
```

Result: **TEST SUCCEEDED** — 27 tests, 0 failures (`SpotifyPluginTests` 19 +
`YouTubePluginTests` 8, the twin untouched), 0 compiler warnings. The run
also passed the wired-in release-log-safety gate (fixture self-test) and the
intent-prompt mirror gate. Log: `/tmp/t118-gate.log`; xcresult under
`ios/build/DerivedDataTests/Logs/Test/`.

## §27 ambiguities resolved (with rationale)

1. **`credentialStore` is genuinely unread by `handle`; the parameter is
   kept.** §27's behavior derives every decision from the session surface
   (`isLinked`, `product`, `validAccessToken()`), and the router's music
   path reads the session alone (`spotifyAccountSession?.isLinked`,
   CommandRouter.swift:2685); §26 pins that the session status and the
   store's record are written together so they cannot disagree (L2-R2).
   The property is retained (documented in the file) for §27 interface
   fidelity and for a possible direct record read by a future surface
   (Settings). A store-based "linked" gate would be a second source of
   truth and is deliberately NOT used.
2. **`validAccessToken` failure split.** `.revoked` → the *not_linked*
   event + `spotify.notLinked` line (the row-10 treatment; the session
   already wiped). Every other case (transport / refresh / storage) →
   `spotify_plugin_failed` + `spotify.unavailable`. §27 names the lines but
   not the events; §12's closed event set only leaves `spotify_plugin_failed`
   for this case.
3. **Play failure emits no separate event.** A failed `playTrack` produces
   only the fallback's event (`spotify_plugin_play_opened` /
   `spotify_plugin_app_missing`): §12's vocabulary has no plugin
   play-failure event, and the failed attempt itself is visible in the
   tool's exit classification only. The plugin never refreshes, never
   retries and never calls `markRevoked()` on a 401 — the router's matrix
   (rows 2/10/12) owns the ladder and the forced refresh; one plugin turn
   is one bounded attempt ending in one honest line.
4. **Unbuildable `trackURI` (defensive, unreachable).** `fetchTopTrack`
   guarantees a validated 22-char base62 id, so `trackURI(id:)` cannot
   return nil from `handle`; if it ever did, the plugin treats it like the
   router's identical guard (`CommandRouter.executeMusicDeepLink`) — the
   app-absent terminal, no chain.
5. **Fragment "341 characters".** §12/§27's 341 (and the task's pins) are
   UTF-16 code units; Swift's `String.count` reports 326 for the same
   literal. The test pins both measures of the YouTube model and asserts
   the Spotify fragment under both, so neither the design's budget number
   nor the grapheme measure can be weakened silently.
6. **`isApplicable`** returns true for every locale — §27 states it
   explicitly ("English and Nepali households alike"); only this plugin's
   link state gates behavior, never the locale.

## Definition of done

- [x] All Gherkin scenarios covered by automated tests (SpotifyPluginTests,
      19/19 green) — the registry scenario's registration half is T-119 by
      design; the declaration half (`spotify.play` + `query` entity) is
      pinned here.
- [x] Fragment-length assertion green at or under the YouTube model (319/327
      vs 326/341 graphemes/UTF-16).
- [x] Intent prompt digest/baseline pins untouched and green (the plugin is
      not registered, so `IntentPromptTests` composition is unchanged; the
      prompt-mirror gate passed in the same run).
- [x] No PII in logs/events — no query/title/token text in any event field,
      `metadata: [:]` on every event, no console write in the new file
      (release-log-safety gate passed in the same run).
- [x] `ios/build.sh` green for the touched targets (scoped unit gate above).
