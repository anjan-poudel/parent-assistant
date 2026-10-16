# SP security evidence bundle — Spotify music integration (T-123)

**Feature:** `spotify-music-integration` · **Task:** T-123 (`TG-23 — Release Gates, Security Evidence and Device Validation`) · **Component:** C-SP-16 (evidence artifact).
**Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration`
**Branch:** `feat/spotify-music-integration` · **HEAD:** `3519a34d3c93584f4acfee1d0982f5bb17a3b553` ("Implement spotify-music-integration W6 (T-120): Settings Spotify section") · **Date:** 2026-10-07.
**Source of the nine obligations:** `specs/security-design-review.md` § "Evidence obligations for security-test" (:134–144); the must-fix conditions M-1…M-3 (:89–105) and the verify-and-record items V-1…V-4 (:124–128).

This is the one document the `security-test` gate reads for the feature's nine evidence obligations. Every claim below names a **test**, a **gate or scanner run**, or an explicitly recorded **limit** — nothing is listed as covered because it was designed to be covered. Where a half cannot be closed in this worktree (a device capture, an owner registration), it is recorded as a pending with its dependency named, never marked passed.

**How the named tests are verified.** `SpotifySecurityEvidenceIndexTests` parses this file: it requires all nine obligations to carry a producer, a command or artifact, a recorded output and a passing status; requires every `<Suite>.<test>` token to exist in `ElderlyAssistantTests`; requires every cited suite to be covered by the recorded freshness run; and permits exactly the two pendings below. An index that names a test that does not exist fails the suite rather than reading as evidence. The tests' *passing* status comes from the recorded freshness run — not from this document's prose.

**Hard rule — NFR-SP-002 applies to the evidence itself.** No token, credential, query text, track title or track id, or provider body is copied into this bundle or its evidence excerpts. Provider material is described (a host, a count, a closed rule name), never pasted. The completeness test machine-checks the forbidden shapes (see "Integrity of this bundle").

| # | Obligation | Status | Open half |
|---|---|---|---|
| O1 | Built-artifact secret scan (PKCE-only proof) | PASS | — |
| O2 | Keychain placement and post-wipe sweep | PASS | — |
| O3 | Callback reject matrix | PASS | — |
| O4 | Refresh and revocation bounds, incl. the V-1 record | PASS | — |
| O5 | Hostile corpus | PASS | — |
| O6 | Log-surface checks | PASS-partial | DV-7 device capture (T-124) |
| O7 | Disclosure copy versus actual data flow | PASS | — |
| O8 | Scope equality | PASS-partial | Dashboard-registered column (OD-S2) |
| O9 | Egress allowlist | PASS | — |

---

## Environment and build identity

| What | Value | Recorded by |
|---|---|---|
| Worktree | `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration` | `pwd` |
| Branch | `feat/spotify-music-integration` | `git rev-parse --abbrev-ref HEAD` |
| HEAD | `3519a34d3c93584f4acfee1d0982f5bb17a3b553` ("Implement spotify-music-integration W6 (T-120): Settings Spotify section") | `git rev-parse HEAD` |
| Date | 2026-10-07 (AEDT) | `date` |
| Xcode | 26.6 (Build 17F113) | `xcodebuild -version` |
| iOS SDK (simulator) | 26.5 | `xcrun --sdk iphonesimulator --show-sdk-version` |
| Swift | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3) | `swift --version` |
| xcodegen | 2.46.0 | build log, `Generating Xcode project` |
| App image scanned (O1) | `ios/build/DerivedDataTests/Build/Products/Debug-iphonesimulator/ElderlyAssistant.app` | test-session build, present in this worktree |

## Freshness gate run

Command: `bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit SpotifySecurityEvidenceIndexTests SpotifyCredentialStoreTests StoragePlacementTests ASWebSpotifyAuthSessionTests SpotifyAuthFlowTests SpotifyAccountSessionTests SpotifyDeepLinkTests SpotifyToolTests SpotifyLocalizationTests CommandRouterMusicTests SpotifyPluginTests PinnedSurfaceGuardTests SpotifySettingsSurfaceTests`

Log: `/tmp/w7-gate.log` — exit 0, `** TEST SUCCEEDED **`; the run executes the release log-safety gate (24 fixtures over 12 rules) and the intent-prompt mirror gate ahead of every test scope.

Counts (per-class `Executed N tests, with 0 failures` lines, quoted from the log):

| Class | Tests |
|---|---|
| SpotifySecurityEvidenceIndexTests | 8 |
| SpotifyCredentialStoreTests | 11 |
| StoragePlacementTests | 7 |
| ASWebSpotifyAuthSessionTests | 17 |
| SpotifyAuthFlowTests | 37 |
| SpotifyAccountSessionTests | 45 |
| SpotifyDeepLinkTests | 20 |
| SpotifyToolTests | 39 |
| SpotifyLocalizationTests | 9 |
| CommandRouterMusicTests | 35 |
| SpotifyPluginTests | 19 |
| PinnedSurfaceGuardTests | 7 |
| SpotifySettingsSurfaceTests | 14 |

Total: `Executed 268 tests, with 0 failures (0 unexpected)` — `** TEST SUCCEEDED **`.

The class list is every suite this bundle cites (O1–O9 and the integrity tables), so no obligation rests on a stale run. Earlier producer runs are recorded in their own notes: T-107 (`specs/T-107-notes.md` § Gate, 59/59 green), T-110 (`specs/T-110-notes.md` § Gate, 45/45), T-116 (`specs/T-116-notes.md` § Gate, 124/124 across two runs), T-120 (`specs/T-120-notes.md` § Gate, 66/66, `/tmp/w6-gate.log`), T-121 (`specs/T-121-notes.md`, build-path log `/tmp/t121-build-gate.log`), and the W1 review's PASS verdicts for T-108/T-109 (`specs/implement-review-w1.md` :26, :29). The W1 review's F-2 finding (scope-set drift between the design prose and the M-3-mandated two-scope implementation) is carried into O8 below with its location state re-verified at the W7 closure: design-l2 §11:211, §26:540 and the OD-S2 appendix (:411) already carry the supersession annotation (landed in a198830), and the two remaining stale prose sites — §11:213 (test-seam text) and §22:383 (suite table) — were corrected at the W7 closure (2026-10-07; W7 review R1).

---

## The nine obligations

### O1 — Built-artifact secret scan: no client secret anywhere (PKCE-only proof)

- Producer: T-123 scan run (this bundle), with the no-secret and PKCE pins shipped by T-109 and T-120. Basis: ADR-SP-01 (`specs/design-l1.md:78-83`), security review Surface 2 (:70-73) and evidence obligation 1 (:136).
- Artifact: the app image above, the app build inputs under `ios/ElderlyAssistant/`, and the raw scan transcript `/tmp/t123-secret-scan.log`.
- Command: `grep -rInE 'client[_-]?secret|ClientSecret|SPOTIFY_CLIENT_SECRET|apiSecret|api_secret' ios/ElderlyAssistant/` — exit 1 (zero matches); `grep -rInE '(secret|Secret)[^ ]{0,20}[0-9a-f]{32}|[0-9a-f]{32}[^ ]{0,20}(secret|Secret)' ios/ElderlyAssistant/` — exit 1 (zero matches); `find "$APP" -type f -print0 | xargs -0 strings -a 2>/dev/null | grep -inE 'client[_-]?secret|ClientSecret|SPOTIFY_CLIENT_SECRET|apiSecret|api_secret'` — 23 raw matching lines, attributed below; the same image stream through `grep -E 'client_secret=[^ ]'` — exit 1; the same stream through `grep -E '(secret|Secret)[^ ]{0,20}([0-9a-f]{32})|([0-9a-f]{32})[^ ]{0,20}(secret|Secret)'` — exit 1.
- Output: zero findings on the defined predicate (a secret-shaped value in a secret-bearing context, or first-party code using a secret-bearing key). Repo input scans: no matches (exit 1). App image: all 23 raw word matches are attributed — 21 in `ElderlyAssistant.debug.dylib` are Objective-C property, ivar, selector and format-string names of the AppAuth / GTMAppAuth OAuth-client code (the generic library statically linked for the pre-existing Google calendar feature; property names such as the library's client-secret field spelling and its client-registration form-field builder, never a value), and 2 in the injected test bundle (`PlugIns/ElderlyAssistantTests.xctest`) are test method names of the negative pins below. 0 matches in the app binary, the preview dylib, `Info.plist`, `Frameworks/`, the resource bundles and the widget. The built `Info.plist` key audit finds one Spotify-shaped key, the public `SpotifyClientID` (empty in this build — the dormant state); no secret-named key of any kind exists. Repo-wide, outside the app inputs, the words occur only in specs, design and workflow documents and in that one test file — never in product code. The image was scanned for real (it is present in this worktree) rather than deferred; the device Release image is re-runnable against the same commands (recorded limit 2).
- Status: PASS
- Evidence: `SpotifyAuthFlowTests.testAuthorizeURLCarriesNoClientSecretAndNoCredentialMaterial`, `SpotifyAuthFlowTests.testAuthorizeURLCarriesPKCEMaterialStateAndTheCodeResponseType`, `SpotifyAuthFlowTests.testTokenExchangeRequestIsAFormEncodedPostWithPKCEMaterialOnly`, `SpotifyAuthFlowTests.testNeitherTokenRequestBodyCarriesAClientSecretOrAnAuthorizationHeader`, `SpotifyAuthFlowTests.testTokenRequestsPutNoCredentialInTheURL`, `SpotifySettingsSurfaceTests.testTheSectionHoldsNoCredentialFieldAndNoLogSurface`

The scan transcript (commands and exit codes only) is `/tmp/t123-secret-scan.log`. The attribution counts above are its S3 section; the raw lines themselves are not copied here because they are symbol names from a vendored library, not evidence a reviewer needs inline.

### O2 — Keychain placement and post-wipe sweep

- Producer: T-108 (`SpotifyCredentialStore` and its tests; W1 review PASS, `specs/implement-review-w1.md:26`), consumed by T-110's unlink and revocation paths.
- Artifact: `ios/ElderlyAssistant/Services/Storage/StoragePlacement.swift:58` (`spotify.session` in `keychainResidentKeys`) and the design's wipe-evidence sentence, `specs/design-l2.md:144`.
- Command: `bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit SpotifyCredentialStoreTests StoragePlacementTests` — both suites are also inside the recorded freshness run.
- Output: green. Placement: `spotify.session` resolves to the Keychain side and is not file-migratable, and the reviewed Keychain set is exact (set equality), so a rename on either side fails a test. Store: one record under one key with no second persistence path; a failed write is typed and keeps the previous record byte-identical; a failed clear is surfaced and the record stays visible; after the wipe nothing is loadable and the sweep finds no credential material in any channel (seam keys, memory, rendered failure text). Design-l2 :144's sentence — after `clear()` a sweep of the storage seam finds no Spotify value; the unlink test asserts the store reads not-configured and neither the tool log nor the console carries token material — is discharged by the unlink tests below plus the tool-log and content-free-failure pins; the console half's device-time proof is O6's DV-7.
- Status: PASS
- Evidence: `StoragePlacementTests.testSpotifySessionRecordStaysInTheKeychain`, `StoragePlacementTests.testTheKeychainSetIsExactlyTheReviewedSecrets`, `SpotifyCredentialStoreTests.testStorageKeyIsPinnedToTheSingleSpotifyKey`, `SpotifyCredentialStoreTests.testTheStoreTouchesExactlyOneKeyAndKeepsNoSecondPersistencePath`, `SpotifyCredentialStoreTests.testFailedWriteSurfacesTheTypedErrorAndKeepsThePreviousRecord`, `SpotifyCredentialStoreTests.testFailedClearSurfacesAndTheRecordStaysVisible`, `SpotifyCredentialStoreTests.testWipeLeavesNothingLoadable`, `SpotifyCredentialStoreTests.testPostWipeSweepFindsNoCredentialMaterialInAnyChannel`, `SpotifyCredentialStoreTests.testFailureSurfacingCarriesNoCredentialContent`, `SpotifyAccountSessionTests.testUnlinkWipesLocallyWithNoRemoteRevocationCall`, `SpotifySettingsSurfaceTests.testScenario2UnlinkConfirmsThenWipesTheStoreAndReturnsToNotLinked`, `CommandRouterMusicTests.testToolLogEntriesCarryNoQueryOrTitle`

### O3 — Callback reject matrix

- Producer: T-109 (`SpotifyAuthFlow` exact-match validator and parser; W1 review PASS, `specs/implement-review-w1.md:29`) and T-111 (`ASWebSpotifyAuthSession` in-session delivery; W4).
- Artifact: `ios/ElderlyAssistant/Services/Spotify/SpotifyAuthFlow.swift` (:178 onward) and `Services/Spotify/ASWebSpotifyAuthSession.swift`; security review Surface 1 (:61), Surface 4 (:83) and evidence obligation 3 (:138).
- Command: `bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit SpotifyAuthFlowTests ASWebSpotifyAuthSessionTests SpotifyAccountSessionTests` — also inside the recorded freshness run.
- Output: one named rejection per class — wrong scheme, wrong host, case-only scheme/host differences, non-empty path, authority tricks that keep the host, fragment, missing state, mismatched state, a replayed callback from an earlier attempt, an empty expected nonce, a missing or empty code, access-denied, every registered provider code, and unknown provider codes mapped to `malformedResponse` with the raw provider description never retained — plus the whole-matrix walk asserting every rejection returns a failure and never a code. Session level: the delivered callback is handed back unchanged and validates through the flow; user dismissal surfaces as user-cancelled; a second system report cannot resume twice. Nothing is stored on any rejection (the session's reject cases pin the store-nothing half) and nothing is logged by construction — the feature's log roots have no console write and the O6 gate is the build-time proof.
- Status: PASS
- Evidence: `SpotifyAuthFlowTests.testCallbackAcceptsTheExactRegisteredRedirectAndReturnsTheCode`, `SpotifyAuthFlowTests.testCallbackRejectsAWrongSchemeBeforeItParsesAnything`, `SpotifyAuthFlowTests.testCallbackRejectsAWrongHostBeforeItParsesAnything`, `SpotifyAuthFlowTests.testCallbackRejectsASchemeOrHostDifferingOnlyInCase`, `SpotifyAuthFlowTests.testCallbackRejectsANonEmptyPath`, `SpotifyAuthFlowTests.testCallbackRejectsAuthorityTricksThatKeepTheHost`, `SpotifyAuthFlowTests.testCallbackRejectsAFragment`, `SpotifyAuthFlowTests.testCallbackRejectsAMissingState`, `SpotifyAuthFlowTests.testCallbackRejectsAMismatchedState`, `SpotifyAuthFlowTests.testReplayedCallbackFromAnEarlierAttemptIsRejectedWithStateMismatch`, `SpotifyAuthFlowTests.testCallbackRejectsAnEmptyExpectedNonceEvenForAMatchingDelivery`, `SpotifyAuthFlowTests.testCallbackRejectsAMissingOrEmptyCode`, `SpotifyAuthFlowTests.testCallbackMapsAccessDeniedToUserCancelled`, `SpotifyAuthFlowTests.testCallbackMapsEveryRegisteredProviderCodeToProviderError`, `SpotifyAuthFlowTests.testUnknownProviderCodesMapToMalformedResponseAndNeverToProviderError`, `SpotifyAuthFlowTests.testRejectedCallbacksNeverRetainTheProviderErrorDescription`, `SpotifyAuthFlowTests.testEveryRejectedCallbackReturnsAFailureAndNeverACode`, `ASWebSpotifyAuthSessionTests.testDeliveredCallbackIsHandedBackUnchangedAndValidatesThroughTheFlow`, `ASWebSpotifyAuthSessionTests.testUserDismissalSurfacesAsUserCancelled`, `ASWebSpotifyAuthSessionTests.testASecondSystemReportIsIgnoredAndCannotResumeTwice`, `SpotifyAccountSessionTests.testRedirectMismatchStoresNothing`, `SpotifyAccountSessionTests.testStateMismatchStoresNothing`, `SpotifyAccountSessionTests.testProviderErrorCallbackStoresNothingAndReportsTheCaseNameOnly`

### O4 — Refresh and revocation bounds, including the V-1 stance verification record

- Producer: T-110 (the session's token lifecycle), with T-109's request shapes.
- Artifact: `specs/T-110-notes.md:123-162` — the V-1 record: six checks against primary provider documentation (July 2026). The official OpenAPI schema exposes no revocation endpoint (the single occurrence of the word is the 401 description, whose documented remedy is re-authentication); refresh is the one `accounts.spotify.com` token endpoint, with a six-month refresh-token lifetime; an invalidated grant is documented to return the `invalid_grant` error, handled by discarding the token and re-running the authorization flow; the documented OAuth surface is authorize plus token only; the developer policy imposes no app-side revocation obligation; and the enumerated developer-docs navigation contains no revocation page. The notes' recorded conclusion: the no-remote-revoke stance is VERIFIED, not assumed — the shipped behaviour (local wipe, `revoked`, relink prompt) matches the provider's own guidance.
- Command: `bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit SpotifyAccountSessionTests SpotifyAuthFlowTests` — also inside the recorded freshness run.
- Output: green. At most one refresh attempt per request (the bound is injected, default 1) and zero requests inside the expiry window; `invalid_grant` wipes the record and reports revoked with the unlink event; a transport failure keeps the record; the router's second-401 path wipes and takes unlinked treatment; `unlink()` and `markRevoked()` make zero transport calls — the V-1 stance is an assertion, not a comment; the link-flow bound is the injected 300 s and the refresh bound the injected 1.
- Status: PASS
- Evidence: `SpotifyAccountSessionTests.testValidAccessTokenWithinTheExpiryWindowMakesNoRequest`, `SpotifyAccountSessionTests.testExpiredTokenRefreshesExactlyOnceAndPersistsTheRefreshedRecord`, `SpotifyAccountSessionTests.testTheRefreshBoundIsExactlyOneAttemptPerRequest`, `SpotifyAccountSessionTests.testInvalidGrantWipesTheRecordAndReportsRevoked`, `SpotifyAccountSessionTests.testRefreshTransportFailureKeepsTheRecordAndReportsNetworkUnavailable`, `SpotifyAccountSessionTests.testUnlinkWipesLocallyWithNoRemoteRevocationCall`, `SpotifyAuthFlowTests.testRefreshRequestCarriesOnlyTheRefreshGrant`, `SpotifyAuthFlowTests.testTheInjectedBoundsAreTheThreeHundredSecondTimeoutAndOneRefresh`, `CommandRouterMusicTests.testRow10InvalidGrantOnRefreshWipesAndTakesTheUnlinkedTreatment`, `CommandRouterMusicTests.testSecondUnauthorizedWipesAndTakesTheUnlinkedTreatment`, `CommandRouterMusicTests.testRow11RefreshTransportFailureKeepsTheRecordAndTakesTheRow7Shape`

### O5 — Hostile corpus

- Producer: T-107 (corpus and suite), T-106 (tool grammar).
- Artifact: `ios/ElderlyAssistantTests/Services/Spotify/SpotifyHostileCorpus.swift` — 88 identifier fixtures across the 13 named clauses (wrong scheme, script-style scheme, control characters, off lengths 0/21/23/100, delimiters and whitespace, scheme text, `//`, quotes, path traversal, non-base62 Unicode, homoglyph case variants, whitespace variants, percent-encoding tricks) plus 14 query fixtures; 43 fixtures sit at exactly the valid 22-Character length, so rejection is proven on the scalar class, not the length.
- Command: `bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit SpotifyDeepLinkTests SpotifyToolTests` — also inside the recorded freshness run.
- Output: green. The whole-corpus walk builds zero URIs and makes zero opener calls; the corpus total is pinned, fixture names are unique, and every category is asserted non-empty (a silently emptied group fails loudly); hostile glyphs at the valid length are rejected on the scalar class; the query fixtures obey the grammar's bounds and delimiter encodings; the deep-link sources carry no log or event surface, and the scan is falsified against a source that does log; the tool-level pins hold (exact track-URI shape with no title, representative rejections, every construction inside the `spotify:` scheme). No rejected identifier reaches a spoken line that claims success.
- Status: PASS
- Evidence: `SpotifyDeepLinkTests.testWholeHostileCorpusIsRejectedWithoutReachingTheOpener`, `SpotifyDeepLinkTests.testHostileCorpusIsCompleteNamedAndCategoryCovered`, `SpotifyDeepLinkTests.testHostileGlyphsAtTheValidLengthAreRejectedOnTheScalarClass`, `SpotifyDeepLinkTests.testWrongSchemeIdentifiersAreRejected`, `SpotifyDeepLinkTests.testControlCharacterIdentifiersAreRejected`, `SpotifyDeepLinkTests.testOffLengthAndOversizeIdentifiersAreRejected`, `SpotifyDeepLinkTests.testDelimiterAndWhitespaceIdentifiersAreRejected`, `SpotifyDeepLinkTests.testSchemeTextIdentifiersAreRejected`, `SpotifyDeepLinkTests.testDoubleSlashIdentifiersAreRejected`, `SpotifyDeepLinkTests.testQuoteIdentifiersAreRejected`, `SpotifyDeepLinkTests.testPathTraversalIdentifiersAreRejected`, `SpotifyDeepLinkTests.testNonBase62UnicodeIdentifiersAreRejected`, `SpotifyDeepLinkTests.testCaseVariantHomoglyphIdentifiersAreRejected`, `SpotifyDeepLinkTests.testWhitespaceVariantIdentifiersAreRejected`, `SpotifyDeepLinkTests.testPercentEncodingTrickIdentifiersAreRejected`, `SpotifyDeepLinkTests.testSearchHandoffRejectsEveryEmptyOrOverCapFixture`, `SpotifyDeepLinkTests.testSearchHandoffEncodesHostileQueriesInsideTheSpotifyScheme`, `SpotifyDeepLinkTests.testTheDeepLinkSourcesHaveNoLogOrEventSurface`, `SpotifyDeepLinkTests.testTheLogSurfaceScanFiresOnASourceThatDoesLog`, `SpotifyToolTests.testTrackURIUsesTheExactSpotifyTrackShapeAndCarriesNoTitleOrQueryText`, `SpotifyToolTests.testTrackURIRejectsRepresentativeNonGrammarIdentifiers`, `SpotifyToolTests.testEveryDeepLinkConstructionStaysInsideTheSpotifyScheme`, `SpotifyToolTests.testProbeReportingTheAppAbsentIsNotOpenedWithNoOpenCall`, `SpotifyToolTests.testOpenOutcomeHasNoPathThatTreatsProbeFailureAsSuccess`

### O6 — Log-surface checks (release gate, build path, and the device capture)

- Producer: T-121 (`FEATURE_ROOTS` extension and the planted-violation transcript), T-114/T-115/T-116 (query-free fallback logging, the tool-log contract, and the pins), T-124 (DV-7 device capture — pending).
- Artifact: `specs/T-121-notes.md` — §2 clean-tree runs (the gate script exits 0; 24 fixtures over 12 rules) and §3 the planted-violation transcript: a temporary file planted in `Services/Spotify` produced **7 named Release-log violations** in one run (one `transcript-print`, four `feature-console-write`, two `feature-content-print`), and the run also observed the raw-error rule family staying engine-scoped; the file was then removed and the clean tree re-verified. The transcript lives in the notes; it is referenced here, never copied. Build-path proof: `/tmp/t121-build-gate.log` (the gate prints green inside a full `build.sh` scope, :17-21) and the gate block inside the freshness run's log.
- Command: `bash ios/tools/check-release-log-safety.sh` — exit 0 on the clean tree (re-run in this bundle's session, 2026-10-07). The same script runs ahead of every test scope inside `./build.sh test:unit`.
- Output: gate green over the new roots with per-rule positive and negative fixtures (24 over 12); the planted run proves rules 1, 3 and 4 fire when violated inside the new roots and that the raw-error family stays engine-scoped (observed, not reasoned); the music-turn pins hold — at most one `.spotify` tool-log entry per turn with a query that is always empty, and no title, id, token or provider body anywhere in the entries, and every Spotify event carries empty metadata with closed outcome and error vocabularies. **Device half:** the DV-7 console and sysdiagnose capture over the linked, unlinked, failure and unlink paths is produced by T-124 (owner and device dependent; the registration is OD-S2) and has not run — this obligation stays open for that half.
- Status: PASS-partial
- Pending: the DV-7 console and sysdiagnose device capture — produced by T-124 once the device and the OD-S2 registration are available; obligation 6's device half remains open until that record lands in `specs/SP-device-validation-protocol.md`.
- Evidence: `CommandRouterMusicTests.testToolLogEntriesCarryNoQueryOrTitle`, `CommandRouterMusicTests.testObservabilityEventsCarryNoMetadata`, `SpotifyPluginTests.testNoEmittedEventEverCarriesQueryTitleOrTokenContent`, `SpotifyAccountSessionTests.testEveryEmittedEventCarriesEmptyMetadataAndAClosedVocabulary`, `SpotifyAccountSessionTests.testErrorCodesNeverCarryAssociatedValues`

### O7 — Disclosure copy versus actual data flow

- Producer: T-117 (the shipped copy; F-7 record `specs/T-117-notes.md`), T-120 (the surface that renders it), and the check below, performed for this bundle.
- Artifact: `ios/ElderlyAssistant/Resources/Localizable.xcstrings`, key `spotifySettings.privacy` (en and ne, the M-2 amendment), rendered at `ios/ElderlyAssistant/App/SettingsView.swift:909`. The English copy, as shipped: "What you ask for — including play commands — is sent to Spotify to find music and control playback; no other app data is sent."
- Command: `python3 -c "import json;c=json.load(open('ios/ElderlyAssistant/Resources/Localizable.xcstrings'));print({l:c['strings']['spotifySettings.privacy']['localizations'][l]['stringUnit']['value'] for l in ('en','ne')})"` and `grep -rn "SpotifyTool.fetchTopTrack\|SpotifyTool.playTrack\|SpotifyTool.searchURI\|spotifySettings.privacy" ios/ElderlyAssistant/`
- Output: the shipped copy matches the implemented flow. What leaves the app, from which call sites: (a) the request text, from the two search call sites — `CommandRouter.swift:2828` (`SpotifyTool.fetchTopTrack`, the tool call under the router's `performMusicSearch` entry at :2792) and `SpotifyPlugin.swift:130` (`handle`) call the tool's search, which sends the text as the query parameter of a `GET /v1/search` on `api.spotify.com` with the credential in the header only; (b) the play command, from the two play call sites — `CommandRouter.swift:2923` (and the `:2946` retry) and `SpotifyPlugin.swift:177` send a `PUT /v1/me/player/play` whose body carries only the URI the tool built from a validated id, never a title; (c) the authorization material — `SpotifyAccountSession.swift:228` (authorize URL), `:262` (exchange carrying the code and PKCE verifier, no secret) and `:427` (refresh) reach `accounts.spotify.com` — that is the account authorization, not app data; (d) the free or unknown-product deep link and the unlinked search hand-off (`CommandRouter.swift:3044`, `:3074`, `SpotifyPlugin.swift:199`) hand the visit over to the Spotify app on the device, which the copy's "sent to Spotify" covers; (e) nothing else leaves on the music path — no cloud model, and the pre-existing YouTube fallback keeps its own unchanged disclosure. No discrepancy found. The one nuance recorded: the access token accompanies the provider requests as the linked account's authorization (header only, never a URL), which "no other app data is sent" does not contradict.
- Status: PASS
- Evidence: `SpotifyLocalizationTests.testThePrivacyDisclosureNamesPlaybackActivityInBothLanguages`, `SpotifyLocalizationTests.testThePrivacyDisclosureDoesNotClaimANarrowerDataFlow`, `SpotifySettingsSurfaceTests.testScenario3TheDisclosureAndRolloutNoteAreRenderedAndHonest`

### O8 — Scope equality: requested set = pinned set = Dashboard-registered set

- Producer: T-109's pin (`SpotifyAuthFlowTests`), with the W1 review's F-2 record.
- Artifact: `ios/ElderlyAssistant/Services/Spotify/SpotifyAuthFlow.swift:84-86` (the pinned `scopes` constant) and `SpotifyAuthFlowTests.swift:89-119` (the tripwire); design-l2 §11's M-3 supersession note (:211) and the W1 finding at `specs/implement-review-w1.md:57`.
- Command: `bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit SpotifyAuthFlowTests` — the suite is inside the recorded freshness run; the third column's command is the owner's OD-S2 Dashboard registration, which is not agent work.
- Output: requested equals pinned equals `{user-read-private, user-modify-playback-state}` exactly, with the read-playback scope ABSENT (M-3's least-privilege trim, asserted, not merely noted), no duplicates, and every scope carried on the authorize URL itself (the calendar-share addScopes lesson). The third column — the Dashboard-registered set — is not observable by any agent: it is the owner's OD-S2 step, and no agent's word may mark it passed. Recorded finding carried to that step (W1 review F-2, locations re-verified and completed at the W7 closure): the design's scope prose now agrees with the shipped constant everywhere — §11:211, §26:540 and the OD-S2 appendix (:411) carried the supersession annotation from a198830, and the last two stale prose sites (§11:213, §22:383) were corrected at the W7 closure (2026-10-07; W7 review R1). The two-scope shipped constant remains the authority the registration must follow.
- Status: PASS-partial
- Pending: the Dashboard-registered scope column — produced by the owner's OD-S2 registration step (the W1-F-2 design annotations are in place; nothing else gates the registration); it can never be marked passed on any agent's word.
- Evidence: `SpotifyAuthFlowTests.testAuthorizeURLRequestsExactlyThePinnedLeastPrivilegeScopeSet`

### O9 — Egress allowlist: the turn's URL set equals the two provider hosts

- Producer: T-116's pin (the router turn), with T-106's and T-109's host pins.
- Artifact: `CommandRouterMusicTests.swift:1002-1028`; the contract at design-l2 §28 (:642, with the credential discipline at :780) and NFR-SP-003.
- Command: `bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit CommandRouterMusicTests SpotifyToolTests SpotifyAuthFlowTests` — also inside the recorded freshness run.
- Output: green. Over four turn worlds (premium remote, free-tier deep link, unlinked keyless hand-off, refresh transport failure), every captured request host is one of the feature's two hosts — `api.spotify.com` and `accounts.spotify.com` — or the pre-existing YouTube endpoint `www.googleapis.com` whose disclosure is unchanged; no token ever appears in a URL and no credential travels as anything but a header; the opener is only ever handed `spotify:` scheme URLs; the tool-level pin keeps every built request on the API host and the flow-level pin keeps every built request on the accounts host.
- Status: PASS
- Evidence: `CommandRouterMusicTests.testNoEgressBeyondTheProviderAllowlist`, `SpotifyToolTests.testEveryRequestStaysOnTheApiHost`, `SpotifyToolTests.testApiPlayURLIsThePlayerPlayEndpoint`, `SpotifyAuthFlowTests.testEveryRequestThisFlowBuildsStaysOnTheAccountsHost`

---

## Related guards outside the nine obligations

| Guard | Evidence | What it protects |
|---|---|---|
| The intent-prompt music surface | `PinnedSurfaceGuardTests.testGoldenMusicBlockIsByteIdenticalAndHoldsExactlyFifteenEntries`, `PinnedSurfaceGuardTests.testTheMusicBlockPinFailsAndNamesTheSurfaceOnAnyMutation` | The 15-entry golden music block is byte-identical and its pin fails loudly on any mutation (T-122) |
| The scope tripwire's drift risk | `specs/implement-review-w1.md:57` (F-2), completed at the W7 closure (design-l2 §11:213, §22:383 corrected) | The design document's scope prose is pinned to the two-scope shipped set, so no stale three-scope sentence can leak into the registration |

## Integrity of this bundle

| Evidence | What it proves |
|---|---|
| `SpotifySecurityEvidenceIndexTests.testEveryObligationCarriesProducerCommandOrArtifactOutputAndAPassingStatus` | Exactly O1 … O9 are present; each carries a producer, a command or artifact, a recorded output and a passing status |
| `SpotifySecurityEvidenceIndexTests.testNoTestNamedAnywhereInTheBundleIsMissingFromTheTarget` | No named test has rotted — every `<Suite>.<test>` token exists in the target |
| `SpotifySecurityEvidenceIndexTests.testTheOnlyIncompleteEntriesAreTheExactlyAllowedPendings` | The only incomplete entries are O6's DV-7 half and O8's Dashboard column, each with its dependency named |
| `SpotifySecurityEvidenceIndexTests.testAnIncompleteObligationEntryIsRejectedByTheSameParser` | The rejection is exercised on fixtures — a row without a producer, command or output, a pending status, a placeholder — not asserted in prose |
| `SpotifySecurityEvidenceIndexTests.testAPendingOutsideTheAllowedSetIsRejectedByTheSameValidator` | A pending anywhere else, or without its dependency, is refused by the same validator |
| `SpotifySecurityEvidenceIndexTests.testTheBundleRecordsBuildIdentityAndAFreshnessRunCoveringEveryCitedSuite` | The identity above is recorded, and every cited suite was in the recorded freshness run |
| `SpotifySecurityEvidenceIndexTests.testTheBundleCarriesNoCredentialQueryOrTrackIdentifierShapes` | The hard rule is machine-checked (constructed track ids, bearer values, token-body shapes, verifier values) |
| `SpotifySecurityEvidenceIndexTests.testTheBundleRecordsLimitsGapsAndTheDeviceRecordItPointsAt` | What was not proven is recorded, and no device run is claimed |

## Recorded limits and gaps (not exercised, not dressed up as coverage)

1. **No device has run this build.** Every gate above is simulator and test-double evidence plus the recorded scans; no real Spotify account was driven, no Dashboard registration exists, and no device Release artifact was produced. Device facts live in `specs/SP-device-validation-protocol.md` (T-124), which this bundle references for its DV-7 half.
2. **The app-image scan covers the test-session simulator Debug artifact** (the image present in this worktree), not a device Release build. The device image is produced by T-124's device build; the O1 commands are re-runnable against it unchanged.
3. **The app image contains vendored OAuth-SDK symbol names** (the attributed 21 lines in O1). They are API names of a generic library's confidential-client support — not secrets and not first-party use; the predicate scans are the findings check, and the raw attribution is recorded so the claim can be audited.
4. **DV-7 — the device console and sysdiagnose capture — has not run** (T-124).
5. **The OD-S2 Dashboard registration has not been performed** (owner step); the scope-equality third column is pending, and the only remaining prerequisite is that registration itself — W1-F-2's design annotations are complete (§11:211, §26:540, appendix :411 from a198830; §11:213 and §22:383 at the W7 closure, 2026-10-07).
6. **The design §31 copy table matches the shipped catalog** (checked at the W7 closure): design-l2:758 shows the M-2-amended sentence with the W6-closure annotation (committed in 3519a34), and the pre-amendment wording survives only as a marked historical quote in the same cell. An earlier draft of this limit misstated the table as still stale; corrected per the W7 review (R2). O7 checks the shipped catalog, which is the authority.
7. **No network-level capture is offered** (no proxy or packet log): O9 rests on the recorded request URLs at the transport seam and the host pins, not on a packet capture.
