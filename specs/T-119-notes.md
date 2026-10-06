# T-119 — AppCoordinator wiring for the Spotify services

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration`
(branch `feat/spotify-music-integration`, base HEAD `1dce327`). No git add/commit/push
was performed. Only the files listed under "Files changed" were touched.

## What was built

The three construction sites of design-l2 §16, exactly as sketched except for the
`assumeIsolated` wrapper described under Deviations:

1. `ios/ElderlyAssistant/App/AppCoordinator.swift:1377` — the lazy credential store
   (doc block 1360–1376, body 1377–1379):

   ```swift
   private(set) lazy var spotifyCredentialStore = MainActor.assumeIsolated {
       SpotifyCredentialStore(storage: storage)
   }
   ```

   Placed in the shipped keychain-store region, after
   `newsSourceStore` (searchConfigStore → youtubeConfigStore → localToolLogStore →
   newsSourceStore → **spotifyCredentialStore** → spotifyAccountSession).

2. `ios/ElderlyAssistant/App/AppCoordinator.swift:1401` — the account session
   (doc block 1381–1400, body 1401–1407):

   ```swift
   private(set) lazy var spotifyAccountSession: SpotifyAccountSession = MainActor.assumeIsolated {
       let session = SpotifyAccountSession(store: spotifyCredentialStore,
                                           flow: ASWebSpotifyAuthSession(),
                                           observabilityBus: observabilityBus)
       session.presenter = { [weak self] in self?.topPresentingViewController() }
       return session
   }
   ```

   Both are `lazy var`s — first use, never `init()` ([BOOT-REVIEW P0-1]). The
   presenter closure is resolved at PRESENT time (the `calendarShareSession`
   precedent; that property has since moved 9318 → 9322, anchors were located by
   content, not by the design's line numbers). The `observabilityBus:
   observabilityBus` argument is passed per [W2-review D1, mandatory] — omission
   would silently route `spotify_link`/`spotify_unlink` to the §26 dropping default.

3. `ios/ElderlyAssistant/App/AppCoordinator.swift:2116` — registration inside
   `makePluginRegistry()`, immediately after the `YouTubePlugin` registration
   (comment 2108–2115):

   ```swift
   registry.register(SpotifyPlugin(accountSession: spotifyAccountSession,
                                   credentialStore: spotifyCredentialStore))
   ```

   Registration order after the edit:
   `[nepali_calendar, appliance_helper, routine, youtube, spotify, live_translate, app_launcher]`.
   All pre-existing registrations untouched.

4. `ios/ElderlyAssistant/App/AppCoordinator.swift:3784–3786` — inside the
   `CommandRouter(...)` construction (call opens at 3747), after
   `youtubeLinkOpener: SystemCallLinkOpener(),`:

   ```swift
   spotifyAccountSession: spotifyAccountSession,
   spotifyTransport: URLSession.shared,
   spotifyLinkOpener: SystemCallLinkOpener(),
   ```

   No other argument was added, removed or reordered (the `CommandRouter(` source
   pin extracts the whole call block and asserts the three exact argument lines).

No log lines were added anywhere; the wiring logs no token, session state or any
Spotify value (NFR-SP-002). No Settings/CommandRouter/SpotifyPlugin/registry
implementation file was touched.

## Commit-time edit sites (provenance for review)

| # | File:line | What |
|---|-----------|------|
| 1 | `AppCoordinator.swift:1360–1379` | `spotifyCredentialStore` doc + lazy var |
| 2 | `AppCoordinator.swift:1381–1407` | `spotifyAccountSession` doc + lazy var (construction 1402–1404, presenter 1405) |
| 3 | `AppCoordinator.swift:2108–2117` | `SpotifyPlugin` registration call (register at 2116–2117) |
| 4 | `AppCoordinator.swift:3784–3786` | the three `CommandRouter` seam arguments |

## Deviations, decisions and their evidence

1. **`MainActor.assumeIsolated` wrappers (compile-forced).** §16's sketch as
   literally written does not compile: `SpotifyCredentialStore` and
   `SpotifyAccountSession` are `@MainActor` and `AppCoordinator` is not, so the
   bare `private(set) lazy var … = SpotifyCredentialStore(storage: storage)`
   fails with *"call to main actor-isolated initializer … in a synchronous
   nonisolated context"* (reproduced with an isolated `swiftc` probe before
   editing). Both initializers are wrapped in `MainActor.assumeIsolated { … }` —
   semantics-preserving for every shipping first-use path (all on main: the
   registry build inside `start()`'s main composition, the Settings surface,
   T-120), and the same stance the file already states for the live-translate
   settings-view seam. An off-main first use now traps rather than racing the
   published record, which is the intended behavior.
2. **Router clause is pinned source + seam-shape, not end-to-end through the
   launch.** The coordinator's `commandRouter` is `private` and built only inside
   the private `composePostFirstFrame()`, one main-actor turn after `start()`.
   Calling `start()` from the unit-test host would run `registerBackgroundTasks()`
   after launch finishes and trip the platform's
   NSInternalInconsistencyException (the [BOOT-REVIEW P0-1 fix] note at
   `AppCoordinator.swift:3251`). The scenario's router clause is therefore
   asserted in two honest halves:
   * a source pin of the exact `CommandRouter( … )` call (the file is the only
     witness to what the launch passes), and
   * a runtime router armed with the coordinator's own seam values, asserting
     (via Mirror) that the seams retain exactly that session, that shared
     transport and that opener type.
   No event, request or seam was faked anywhere.
3. **Scenario 4 drives unlink vocabulary only; `spotify_link` has no hermetic
   trigger.** `link()` would present the real ASWeb auth flow (the bundle has a
   `SpotifyClientID`), so it is not test-safe. `unlink()` and `markRevoked()` are
   synchronous, local-only wipes (V-1: no remote revocation endpoint exists to
   call), and clearing an already-empty record is a success
   (`KeychainEncryptedStorage.delete` treats `errSecItemNotFound` as success).
   The behavioural delivery test drives both and asserts
   `[spotify] spotify_unlink outcome=success` and `outcome=revoked` reach the
   console bus — the events the W2-D1 omission loses first. Bus identity
   (session ↔ registry ↔ coordinator, and `≠ SpotifyAccountSession.unwiredBus`)
   covers the link vocabulary structurally.
4. **`ios/seniOS.xcodeproj/project.pbxproj` was regenerated by xcodegen**
   during the gate build (`build.sh` runs `xcodegen generate`), which is how the
   new test file entered the project. It was never hand-edited.
5. The first gate run (02:05) surfaced one failure in my own source pin: the raw
   occurrence count of `spotifyAccountSession` is 4, not 3 — the router line
   `spotifyAccountSession: spotifyAccountSession` counts twice. Replaced with
   three site-specific needles (declaration / plugin registration / router
   argument), each exactly 1. Re-run green. The red run is kept at
   `/tmp/spotify-gate-T119-20261007-020552.log`; the green run at
   `/tmp/spotify-gate-T119-20261007-021148.log`.

## New test file

`ios/ElderlyAssistantTests/App/AppCoordinatorSpotifyWiringTests.swift` (new, 458
lines, one test per Gherkin scenario):

1. `testScenario1ServicesConstructLazilyAndOneSessionIsInjectedOnce` — Mirror
   reads of the compiler's `$__lazy_storage_$_…` slots prove neither seam is
   built before first use; exactly one store/session across repeated property
   reads, across the registered plugin's seams (Mirror) and across a router armed
   with the coordinator's values (runtime identity); source pins for the
   `CommandRouter( … )` block and the per-site occurrence counts (`SpotifyAccountSession(`,
   `SpotifyCredentialStore(` each exactly 1).
2. `testScenario2TheSpotifyPluginRegistersOnceBesideUnchangedPlugins` — registry
   plugin list equals the exact shipped ordered ID list and its exact shipped
   type list; `spotify` appears once; source pin of the `register(SpotifyPlugin(…)`
   call handing over both coordinator seams.
3. `testScenario3FreshInstallConstructionIsDormantAndMakesNoNetworkCall` — the
   fresh-install key is cleared through the app's own encrypted channel; a
   `URLProtocol` probe with a self-checking positive control
   (`http://127.0.0.1:1` control request answered by a canned 204) proves
   interception before the no-request assertion leans on it; constructing the
   coordinator and touching all three first-use seams builds them dormant
   (`record == nil`, `status == .notLinked`, `product == .unknown`, plugin
   present) with **zero** requests through `URLSession.shared`, and a fresh
   reader over the encrypted channel agrees no record was written.
4. `testScenario4SessionEventsReachTheAppBusNotTheDroppingDefault` — the
   session's, registry's and coordinator's buses are one object, it is the
   `ConsoleObservabilityBus`, and it is not `unwiredBus`; stdout capture around
   `unlink()` + `markRevoked()` observes both `spotify_unlink` outcomes on the
   app bus; source pin that the session construction passes
   `observabilityBus: observabilityBus)` by name.

Test techniques (verified on this toolchain before relying on them): Mirror
labels lazy storage `$__lazy_storage_$_<name>`; `as? T` unwraps one level of
`Optional` from an `Any`, which is what makes the optional seams readable; the
stdout-capture helper mirrors the shipped `LiveTranslateAllowListTests` pattern;
`URLProtocol.registerClass` intercepts `URLSession.shared` even after prior use.

## Gate

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
  ./build.sh test:unit AppCoordinatorSpotifyWiringTests SpotifyPluginTests \
  CalendarShareSettingsSeamTests PluginRegistryTests
```

* Green run: `/tmp/spotify-gate-T119-20261007-021148.log` — **39 tests, 0
  failures** (4 new + SpotifyPluginTests 19 + CalendarShareSettingsSeamTests +
  PluginRegistryTests); `=== Scoped unit run passed (baseline not advanced) ===`,
  exit 0. xcresult:
  `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.07_02-12-14-+1100.xcresult`.
* Red run (kept for provenance): `/tmp/spotify-gate-T119-20261007-020552.log` —
  the self-inflicted occurrence-count pin above; scenarios 2–4 and all three
  shipped suites were already green there.

## Files changed

* `ios/ElderlyAssistant/App/AppCoordinator.swift` — 3 edit sites (above).
* `ios/ElderlyAssistantTests/App/AppCoordinatorSpotifyWiringTests.swift` — new,
  4 tests.
* `specs/T-119-notes.md` — this file.
* (`ios/seniOS.xcodeproj/project.pbxproj` — regenerated by xcodegen in the gate
  build, not hand-edited.)
