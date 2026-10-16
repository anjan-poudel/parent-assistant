# T-116 — Router music path: seams, matrix, intake and pins (implementation notes)

**Status: COMPLETE — all scoped gates green. Changes left uncommitted for the orchestrator (no git add/commit/push).**

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration` (branch `feat/spotify-music-integration`).

## What was built

### 1. Seams (NFR-SP-012 dormant-nil discipline)

Three new init parameters on `CommandRouter`, defaulted nil, placed beside the shipped dormant-nil YouTube block (the T-106/T-107-era 646–648 pattern):

- `spotifyAccountSession: SpotifyAccountSession?`
- `spotifyTransport: LocalToolTransport?`
- `spotifyLinkOpener: CallLinkOpening?`

Every pre-existing construction site and test compiles and behaves unchanged (verified: the full scoped gates below build every touched suite against the untouched construction sites).

### 2. `selectMusicOutcome` + `MusicOutcome` (§28)

`MusicOutcome` is a pure, total, `Equatable` enum (`spotifyRemote(TrackResult)`, `spotifyDeepLink(TrackResult)`, `spotifySearchHandoff`, `youtube`, `honestLine(String)`); `static func selectMusicOutcome(...)` is internal for tests and encodes §13's 12 rows as ordered conditions:

1. unlinked (effective) → youtube / search-handoff / notLinked
2. linked but transport absent → row-7 shape
3. search nil → row-7 shape
4. search success → premium ? remote : (deepLinkCapable ? deepLink : youtube/appMissing)
5. search failure `.noResults` → youtube / notFound
6. other search failure → youtube / unavailable

### 3. Turn execution (§28)

- `fireMusicRequest(query:)` — main-thread entry, locale resolution, `speakPreAck(locale:)` parity with `fireYouTubePlay`, `attemptStartedAt` capture, then `Task { [weak self] }` into the async turn; speak/emit/log hop back through `await MainActor.run` exactly like `fireYouTubePlay`.
- Token flow: state machine B via `validAccessToken()` (frozen, unedited). Success → search with the token; `.revoked` → wipe semantics → effective-linked=false; other refresh failure → row-11 shape (record kept, search nil).
- Search: Spotify `/v1/search` + optional keyed YouTube prefetch, both legs in flight together (`async let`, joined) when a keyed YouTube config exists; status mapping 200/200/statusCode/nil.
- Play: remote attempt for premium; on 401 one retry through `validAccessToken()`, second 401 → `markRevoked()` + unlinked treatment; other play failures → deep link with the failure status.
- Exactly ONE spoken outcome line per turn (plus pre-ack); at most ONE `.spotify` tool-log entry per music turn, query ALWAYS `""`, response `""` except the terminal honest line, outcome `"ok"` only when Spotify served, statusCode from the last HTTP response when one exists; never a title/id/token/provider body.
- Closed observability vocabularies per §28's table, component `spotify`, `metadata: [:]` everywhere: `spotify_search` {usable, empty, failed}; `spotify_play` {ok, premium_required, restricted, no_active_device, unauthorized, network_failed}; `spotify_deeplink` {opened, not_opened}; `spotify_fallback` {youtube, not_linked, not_found, unavailable, app_missing}. `spotify_link`/`spotify_unlink` remain session-owned.

### 4. Intake (FR-SP-015)

- Ladder: `case .music:` → `fireMusicRequest(query: KeywordIntentRule.musicQuery(from: preText) ?? preText)`, then `.unrecognised(transcript:)` (the keyword-match observability event is emitted first, pre-existing pattern).
- `dispatchInterpreted`: the `case .music:` stub arm replaced with `fireMusicRequest(query: interpretedQuery ?? KeywordIntentRule.musicQuery(from: raw) ?? raw)`; `interpretedQuery` = trimmed non-empty `command.message`.
- The stub sites are deleted: the `command_music_stub` event and `router.musicStub` speech have NO reachable emission on any path. The catalog key is retained per ADR-SP-11 (asserted by `SpotifyLocalizationTests`, untouched).
- Explicit-YouTube path untouched: rule-level exclusion from T-112 means YouTube-marked utterances never enter the music domain.

### 5. YouTube fallback (rows 4/6/7/8)

`fireYouTubePlay(query:logProjection: .queryFree)` (T-114's F-5(a) variant), preceded by the `spotify_fallback` emission and followed by the turn's `.spotify` fail entry when a Spotify attempt happened.

## Files changed

| File | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` | +683 lines: seams, `MusicOutcome`/`selectMusicOutcome`, `fireMusicRequest`/`runMusicTurn`/`performMusicSearch`/`executeMusicTurn`/`executeRemoteMusicPlay`/`executeMusicDeepLink`/`executeMusicSearchHandoff`/`deliverUnlinkedMusicTreatment`/`deliverYouTubeFallback`/`deliverMusicLine`/`emitSpotify` + static mappers; stub arm deleted; ladder + dispatchInterpreted arms added |
| `ios/ElderlyAssistantTests/Services/Voice/CommandRouterMusicTests.swift` | NEW — 33 tests (all 12 rows + pins; full list below) |
| `ios/ElderlyAssistantTests/Services/Voice/CommandRouterYouTubeTests.swift` | 1 fixture supersession with documented comment (see Deviations); T-114 golden captures/baseline/fixtures untouched |
| `ios/ElderlyAssistantTests/Services/Intents/CommandRouterSafetyNetTests.swift` | 1 fixture supersession with documented comment (see Deviations) |
| `ios/seniOS.xcodeproj/project.pbxproj` | +4 lines, xcodegen-regenerated during `build.sh` (registers the new test file); NOT hand-edited |

Frozen files consumed, never edited: `SpotifyTool.swift`, `SpotifyAccountSession.swift`, `SpotifyTransport.swift`, `ASWebSpotifyAuthSession.swift`, `VoiceContactSearchRoute.swift`, `KeywordIntentRule.swift`, `AppCoordinator.swift`, Settings files, Localisation catalog.

## Gate command and results

Exact gate (through the lock, `./build.sh` truncated-log mode — never raw xcodebuild):

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit CommandRouterMusicTests CommandRouterYouTubeTests LocalToolLogStoreTests ToolLogKindMappingTests
```

Result: `** TEST SUCCEEDED **` — 63 tests, 0 failures (xcresult `Test-ElderlyAssistant-2026.10.07_01-16-45-+1100.xcresult`):

```
CommandRouterMusicTests:    Passed — 33 test cases, 0 failing
CommandRouterYouTubeTests:  Passed — 16 test cases, 0 failing   (T-114 golden green)
LocalToolLogStoreTests:     Passed —  9 test cases, 0 failing
ToolLogKindMappingTests:    Passed —  5 test cases, 0 failing
```

Collateral verification run (same lock/protocol; verifies the safety-net supersession and adjacent suites):

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit CommandRouterSafetyNetTests CommandRouterKeywordIntentTests CommandRouterPreAckTests GoldenCorpusTests
```

Result: `** TEST SUCCEEDED **` — 61 tests, 0 failures (xcresult `Test-ElderlyAssistant-2026.10.07_01-19-42-+1100.xcresult`):

```
CommandRouterSafetyNetTests:    Passed — 15 test cases, 0 failing (incl. testMidBandTierFreeBecomesAQuestion)
CommandRouterKeywordIntentTests: Passed — 28 test cases, 0 failing
CommandRouterPreAckTests:       Passed — 13 test cases, 0 failing
GoldenCorpusTests:              Passed —  5 test cases, 0 failing
```

Both runs: privacy guards green (24 log-safety fixtures over 12 rules), intent-prompt mirror green (self-test mutations all rejected), xcodegen green. Combined: 124 scoped tests, 0 failures.

Two earlier runs were red and drove fixes (recorded for the trail): run 1 = 6 compile errors in the new test file only (router code compiled clean); run 2 = 2 failing test methods in the new test file only (`testObservabilityEventsCarryNoMetadata` — the pre-existing `command_router`/`intent_keyword_match` event legitimately carries fixed-vocabulary metadata, so the pin is now scoped to the `spotify`/`youtube` components; `testRow2PlayFailureFallsToTheDeepLinkWithTheFailureStatus` — an incorrect "carded" assertion on the hand-off line, which the implementation speaks spoken-only per the youtube.openingSearch precedent, flipped to `XCTAssertFalse`).

## Matrix row → test mapping (all 12 rows)

| §13 row | Test(s) in `CommandRouterMusicTests` |
|---|---|
| 1 — premium remote ok | `testRow1PremiumRemotePlaySucceeds` |
| 2 — play fails → deep link | `testRow2PlayFailureFallsToTheDeepLinkWithTheFailureStatus`, `testRow2PlayNetworkFailureOpensTheDeepLinkWithNilStatus` |
| 3 — free usable → deep link, no remote attempt | `testRow3FreeTierOpensTheTrackDeepLinkWithoutARemoteAttempt` |
| 4 — free usable, app absent → YouTube else appMissing | `testRow4AppAbsentWithYouTubeServeableFallsBackToYouTube`, `testRow4AppAbsentWithoutYouTubeSpeaksAppMissing` |
| 5 — deep-link open attempted, fails at attempt time → terminal, appMissing, no chaining | `testRow5DeepLinkNotOpenedSpeaksAppMissingWithNoChaining` |
| 6 — search empty | `testRow6EmptySearchWithYouTubeServeableFallsBackToYouTube`, `testRow6EmptySearchWithoutYouTubeSpeaksNotFound` |
| 7 — search failure | `testRow7SearchFailureWithYouTubeServeableFallsBackToYouTube`, `testRow7SearchFailureWithoutYouTubeSpeaksUnavailable`, `testLinkedSessionWithoutTransportTakesTheRow7Shape` |
| 8 — unlinked | `testRow8UnlinkedFallsBackToYouTube`, `testRow8UnlinkedWithoutYouTubeHandsOffTheSearch`, `testRow8SearchHandoffNotOpenedSpeaksNotLinked` |
| 9 — unlinked + dormant + no opener → none | `testNeitherProviderAskableSpeaksNotLinked` (asserts `logStore.entries().isEmpty` — row 9's tool-log column is "none") |
| 10 — invalid_grant → wipe → unlinked treatment | `testRow10InvalidGrantOnRefreshWipesAndTakesTheUnlinkedTreatment`, `testSecondUnauthorizedWipesAndTakesTheUnlinkedTreatment` |
| 11 — refresh transport failure → row-7 shape, record kept | `testRow11RefreshTransportFailureKeepsTheRecordAndTakesTheRow7Shape` |
| 12 — link-time failure residue → unlinked treatment | `testRow12LinkFailedSessionBehavesAsUnlinked` |

Plus the §22 pins: `testBareMusicRequestNeverSpeaksTheStub`, `testNoMusicBranchSpeaksTheStubForInterpretedMusic`, `testYoutubeMarkedUtteranceNeverReachesTheMusicPath`, `testBothKeyedProvidersAreSearchedConcurrently`, `testKeylessYouTubeIsNotOpenedWhenSpotifyWins`, `testUnknownProductUsesTheDeepLink` (L2-D14), `testMusicTurnEndsInExactlyOneSpokenOutcomeLine` (6 data-driven cases), `testStubIsUnreachableOnEveryMusicBranch` (13 branches), `testToolLogEntriesCarryNoQueryOrTitle`, `testObservabilityEventsCarryNoMetadata`, `testNoEgressBeyondTheProviderAllowlist`, `testOneProviderUnavailableDoesNotBlockTheOther`, `testExpiredRecordRefreshesOnceAndSearchesWithTheNewToken`.

## §13 row-1 concurrency reading + L2-R1 evidence

- Reading: row 1's "search both legs" is the KEYED YouTube fetch path (a network search), run concurrently with the Spotify search — `async let` both legs, joined, only when a keyed YouTube config exists. The keyless YouTube leg ("askable via opener") is NOT part of the concurrent prefetch; its "search" (opening the search URL) is its outcome.
- Implementation evidence: `runMusicTurn` builds the prefetch tuple only when a keyed config is present; `performMusicSearch` launches both legs with `async let`; `prefetchYouTubeLeg` runs `_ = try? await YouTubeTool.fetchTopResult(...)` so its result is discardable without serializing the legs.
- Test evidence: `testBothKeyedProvidersAreSearchedConcurrently` — `MusicArrivalGate` actor parks the first arriving provider request; the second arrival sets `overlapObserved`; a sequential implementation parks to the gate's 2 s timeout and honestly fails the assertion (no hang). Asserts exactly 1 Spotify search + 1 googleapis request + the row-1 outcome line.
- L2-R1 evidence: `testKeylessYouTubeIsNotOpenedWhenSpotifyWins` — keyless opener armed, Spotify wins: `youtubeOpener.opened` empty, `canOpenChecks` empty, zero `www.googleapis.com` requests. Implementation-wise the keyless opener is only touched inside `deliverYouTubeFallback`, which only runs when Spotify did not serve.

## F-5(a)/(b) evidence

- F-5(a): `deliverYouTubeFallback` calls `fireYouTubePlay(query:logProjection: .queryFree)` — the T-114 query-free variant — on every fallback leg (rows 4/6/7/8); consumed via a call site, no edit to `YouTubeTool`.
- F-5(b): `testToolLogEntriesCarryNoQueryOrTitle` walks EVERY tool-log entry of THREE turn shapes (row 1 remote, row 3 deep link, row 8 keyless-YouTube fallback) and asserts, per entry: no query text in `query` or `response`, no track title in either field, no track id, no token; plus the per-kind pin that the fallback's YouTube entry logs an EMPTY query (`fallback.youtubeEntries.first?.query == ""`). The per-row tests additionally pin the exact `.spotify` entry shape (count 1, outcome/status/fields) for their own turns.

## Deviations and spec-tension readings (surfaced, not silent)

1. **Uniform `spotify_search` emission.** Every executed search emits `spotify_search` usable/empty/failed, including rows 2/4/5 where the §28 event lists read as highlights rather than exhaustive logs ("emit the event pair" presumes the search event whenever a search ran). Rows 2/5 tests pin the three-event sequences.
2. **`interpretedQuery` provenance.** `dispatchInterpreted`'s music query is the trimmed non-empty `command.message`, falling back to `KeywordIntentRule.musicQuery(from: raw)` then the raw transcript.
3. **"linked + transport missing → row-7 branch"** is implemented as a search-nil row-7 execution (honest line/YouTube) over the §10B askability wording; pinned by `testLinkedSessionWithoutTransportTakesTheRow7Shape`.
4. **Row 11** emits the `.spotify` fail entry with statusCode nil (no HTTP response existed).
5. **Rows 2/3 tool-log outcome/status per the matrix literally:** deeplink-after-failed-play → outcome `fail` + the play failure's statusCode; clean free-tier deep link → outcome `ok` + nil.
6. **Row 5 not-opened has NO `spotify_fallback` event** (terminal, no chaining) — only `spotify_deeplink|not_opened` + the appMissing line + the fail entry. The hand-off not-opened path speaks notLinked with no fallback event.
7. **Second-401 path writes NO `.spotify` entry** — row-10 treatment wholesale (two `spotify_play|unauthorized` events + the session's own `spotify_unlink|revoked`), per the matrix's row-10 tool-log column.
8. **Pre-ack cadence:** `fireMusicRequest` always pre-acks (§28 parity with fireYouTubePlay), so YouTube-fallback turns hear the music pre-ack then YouTube's verbatim pre-ack before the outcome, and interpreted turns hear the interpret-stage ack then the music pre-ack.
9. **"One forced refresh" on the play-401 retry** is implemented as calling `validAccessToken()` again (the frozen `SpotifyAccountSession` exposes no public forced-refresh API); a fresh record returns the same token, the retry executes, a second 401 marks revoked.
10. **Supersession fixture edits (2).** Design §22 listed `CommandRouterYouTubeTests` as "unchanged"; two pre-existing fixtures routed music-marked transcripts through non-music flows and are unavoidably superseded by FR-SP-013/FR-SP-015:
    - `CommandRouterYouTubeTests.testBarePlayWithoutYouTubeWordNeverReachesTheStage`: fixture "play some music" (music marker ∧ no YouTube word → now a music turn) → swapped to "play it" with a `[SUPERSEDED FIXTURE — T-116]` comment; the ordering intent (a bare play without a YouTube word never reaches the YouTube stage) is preserved and the music utterances' own ordering is pinned in `CommandRouterMusicTests`. The T-114 golden captures are untouched — byte-identity holds (16/16 green).
    - `CommandRouterSafetyNetTests.testMidBandTierFreeBecomesAQuestion`: fixture "केही भजन जस्तो बजाउनुस्" (भजन + बजाउनुस् → now terminates at the ladder's music arm before the interpreter) → swapped to the marker-free "केही राम्रो कुरा बताउनुस्" (already proven to fall through to the interpreter in the sibling test) with a `[MUSIC-PATH]` comment; the mid-band `action: .music` rephrase behavior itself is unchanged and green.
11. **`seniOS.xcodeproj/project.pbxproj` shows +4 lines** — xcodegen's automatic registration of the new test file during `build.sh` (the sanctioned "globs new files" workflow); not a hand edit.
12. **Defects found in frozen files: none.** No frozen file required a fix; the two supersessions above are test-fixture casualties of the new intake, not frozen-file defects.

## Requirements coverage

FR-SP-001 (real playback), FR-SP-003 (Spotify preferred when linked and capable), FR-SP-004 (YouTube fallback), FR-SP-005 (explicit-YouTube unchanged — T-114 golden green), FR-SP-011 (free-tier deep-link degradation), FR-SP-012 (honest outcomes, no silent failure — never-stub sweep over 13 branches + exactly-one-line pin), FR-SP-015 (intake in the route ladder), NFR-SP-002 (zero console writes — privacy gate green; no query/title/id/token in tool-log or metadata pins), NFR-SP-003 (egress allowlist pin: `api.spotify.com` + `accounts.spotify.com` + pre-existing YouTube hosts only), NFR-SP-012 (dormant-nil seams; construction sites unchanged).

## Confidence

**85/100.** All scoped gates green (124 tests), full matrix + pins covered, T-114 byte-identity verified green, both build-time gates (privacy, prompt mirror) green, frozen files untouched. Deductions are for the interpretation-dependent readings above (notably items 3, 7, 8 and the uniform-search reading in 1) — each is documented per-row at the site, but a W3 review may prefer alternate readings of §13/§28's terse event lists.

**Blockers: none.** Changes are deliberately uncommitted for the orchestrator's per-wave commit. Out of scope here: T-119 must pass the app's live `observabilityBus` into the session construction (W2 review item D1) — that wiring is T-119's, not this task's.
