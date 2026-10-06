# T-110 — SpotifyAccountSession (C-SP-03) — implementation notes

Status: COMPLETE (worktree `elderly-ai-assistant-spotify-music-integration`, branch
`feat/spotify-music-integration`; changes left uncommitted per instructions).
Date: 2026-10-07. Depends on W1 (T-108 `SpotifyCredentialStore`, T-109
`SpotifyAuthFlow`/`SpotifyAuthError`, committed at a198830) — both were used
exactly as shipped and neither was modified.

## What was built

### 1. `ios/ElderlyAssistant/Services/Spotify/SpotifyAccountSession.swift` (NEW)

`@MainActor final class SpotifyAccountSession: ObservableObject`, the C-SP-03
state machine (design-l2 §10/§26). It composes ONLY the W1 store and flow; no
third persistence path and no second token path exists in the file.

- Public types, exactly §26 (router T-116 / Settings T-120 consume them as
  specified, nothing added or renamed): `Product { premium, free, unknown }`,
  `Status { notLinked, linking, linked(Product), linkFailed(SpotifyAuthError) }`,
  `LinkOutcome { linked(Product), failed(SpotifyAuthError), cancelled }`, plus
  `Equatable` (additive conformance needed for call-site comparison; the case
  sets are untouched).
- Core surface: `link() async -> LinkOutcome`, `unlink() -> Result<Void, StorageError>`,
  `markRevoked() -> Result<Void, StorageError>`,
  `validAccessToken() async -> Result<String, SpotifyAuthError>`,
  `@Published private(set) var status`, `isLinked`, `product`,
  `var presenter: (() -> UIViewController?)?`, `static var bundledClientID`
  (reads Info.plist `SpotifyClientID`, trimmed; blank = nil = dormant).
- Initializer: the §26 signature, store + flow required, `transport` /
  `clientID` / the four §32 knobs defaulted, plus one TRAILING defaulted
  `observabilityBus` (see "Bus seam" below).
- `link()`: clientID guard → `.notConfigured`; presenter resolved at PRESENT
  time → `.noPresenter`; fresh PKCE + 32-byte hex state nonce per attempt;
  `sk=linking`; the flow runs under the injected `linkFlowTimeoutSeconds`
  bound via a `withTaskGroup` race and is CANCELLED on expiry (L2-D7);
  callback parsed with the W1 exact-match/state validator; exchange through
  the injected transport; scope check (pinned two-scope set ⊆ granted) runs
  BEFORE the `/v1/me` request (L2-D5: an insufficient grant must not drive
  egress); missing refresh token in a code-exchange response =
  `.malformedResponse` (an address that can never refresh is not stored);
  `GET /v1/me` verification (2xx = the truth check; the profile `product` is
  read best-effort — an unparseable 2xx body is still verified, product
  unknown); the six-field record is written through `store.save` and the
  status flips only on a confirmed write. Success writes exactly ONE record;
  every failure writes none and leaves any previous record byte-identical.
- `validAccessToken()`: `Date() < record.expiry` → the current token with no
  egress; otherwise exactly one bounded refresh (`refreshAttemptLimit`,
  default 1; every attempt terminal, so no loop). `invalid_grant` (recognised
  only from a well-formed JSON body whose `error` is exactly `invalid_grant`)
  → wipe + status `.notLinked` + `spotify_unlink`/`revoked` event →
  `.failure(.revoked)`. Transport error / non-HTTP → `.networkUnavailable`
  with the record KEPT (matrix row 11). Other non-2xx →
  `.refreshFailed(statusCode:)`, record kept. Unparseable 2xx body →
  `.malformedResponse`, record kept. Successful refresh rewrites the record
  (rotated access token; refresh token rotated or retained; fresh expiry;
  `linkedAt` never moves) and opportunistically re-verifies `product` first
  (see "Staleness" below); best-effort failure keeps the stored value.
  Store write failure → `.failure(.storageFailure)` — not persisted, so not
  handed out.
- `unlink()` / `markRevoked()`: LOCAL wipes — `store.clear()` only, zero
  transport calls (V-1 / ADR-SP-14: Spotify documents no third-party
  revocation endpoint, so none is attempted or claimed). Status flips to
  `.notLinked` only on a confirmed wipe; a failed wipe keeps the record
  visible and reports `failed`/`storageFailure`.
- Log discipline (NFR-SP-002): no print/os_log/NSLog/Logger anywhere; the
  single `emit()` takes no metadata and no free-form error parameter, so a
  token, expiry, callback URL or provider body has nowhere to go.
  `metadata` is `[:]` on every event; `errorCode` is the `SpotifyAuthError`
  case NAME only, via a total explicit switch (associated values — a status
  code, a registry code, a storage reason — cannot ride along, and a future
  case breaks the switch at compile time instead of defaulting).

### 2. `ios/ElderlyAssistantTests/Services/Spotify/SpotifyAccountSessionTests.swift` (NEW)

45 tests, all passing. Doubles: the W1 test target's own
`SpotifyInMemoryStorage` (recording `EncryptedLocalStorage`) and
`RecordingObservabilityBus`, plus two new scripted doubles — a
`SpotifyAuthSession` seam fake (records calls; can "stay open" for the
timeout path; builds its callback by echoing the nonce it was handed — the
only way a test can satisfy a nonce minted internally) and a scripted
`LocalToolTransport` that captures every request and classifies it by host +
grant body so counts are per-endpoint facts (`exchangeRequests`,
`refreshRequests`, `profileRequests`). Per the DoD, the load-bearing tests
assert call COUNTS and STORED STATE: raw payloads are compared byte-for-byte
across failure paths, `writtenKeys` pins "exactly one write", and
`keysCarryingMaterial` proves no credential material survives a wipe.

## Gate

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
  ./build.sh test:unit SpotifyAccountSessionTests
```

Result (attempt 3; attempts 1–2 surfaced compile issues in my own new files,
fixed without touching any other task's files):

```
Test Suite 'SpotifyAccountSessionTests' passed at 2026-10-07 00:31:55.226.
	 Executed 45 tests, with 0 failures (0 unexpected) in 0.203 (0.232) seconds
** TEST SUCCEEDED **
  ✓ unit tests passed
=== Scoped unit run passed (baseline not advanced) ===
GATE EXIT: 0
```

The same build ran the source privacy guards (NFR-SP-002's release gate):
"Checking source privacy guards..." printed green with 12 rules / 24
fixtures ("every rule has a positive and a negative fixture, and every
fixture behaves"), including the console-write, content-print and
interpolated-into-event rules that cover the two new files.

## Gherkin scenario → test mapping

| Gherkin (T-110 task file) | Tests |
|---|---|
| 1. Successful link stores one record; linked status with a fresh capability timestamp | `testSuccessfulLinkStoresExactlyOneRecordAndReportsLinkedWithAFreshCapabilityTimestamp` (outcome/status/product; `rawPayloads.count == 1`; `writtenKeys == [storageKey]`; field-by-field record; expiry = issuedAt+3600-60 window; `linkedAt` window; authorize=1, exchange=1, profile=1; token header-only, never in a URL; one `spotify_link`/success event, metadata `[:]`), `testALinkedRecordOnDiskDrivesTheLinkedStatusAtConstruction`, `testConstructionMapsTheStoredProductIntoTheClosedVocabulary` (premium/free/open→free/unknown/nil), `testSessionConstructsWithTheExactDesignInitializerShape` (the §26 `(store:flow:)` call shape) |
| 2. Every link failure stores nothing; any previous record unchanged | `testCancelledLinkStoresNothingAndLeavesThePreviousRecordUnchanged`, `testFlowTimeoutCancelsTheAttemptAndStoresNothing` (seam cancelled; no exchange), `testAccessDeniedCallbackIsReportedAsCancelledAndStoresNothing`, `testPresentationFailureStoresNothingAndReportsTheCaseNameOnly`, `testNoPresenterStoresNothingAndNeverStartsTheFlow`, `testNotConfiguredIsDormantAndTouchesNeitherFlowNorTransport`, `testProviderErrorCallbackStoresNothingAndReportsTheCaseNameOnly`, `testRedirectMismatchStoresNothing`, `testStateMismatchStoresNothing`, `testExchangeNon2xxStoresNothing`, `testExchangeTransportFailureStoresNothing`, `testNonHTTPAnswerAtExchangeStoresNothing`, `testMalformedTokenBodyStoresNothing`, `testMissingRefreshTokenInTheExchangeStoresNothing`, `testMissingScopesStoresNothingAndSkipsTheProfileRequest` (zero profile egress), `testVerificationNon2xxStoresNothing`, `testVerificationTransportFailureStoresNothing`, `testUnparseableProfileBodyStillVerifiesWithAnUnknownProduct`, `testStorageWriteFailureLeavesThePreviousRecordAndReportsStorageFailure`, `testFailedReLinkAfterASuccessfulLinkLeavesTheStoredRecordUnchanged` — every failure case asserts the byte-identical stored snapshot AND that no new write occurred |
| 3. Exactly one refresh attempt; wipe only on definitive rejection (matrix rows 10/11) | `testValidAccessTokenWithinTheExpiryWindowMakesNoRequest` (zero egress), `testExpiredTokenRefreshesExactlyOnceAndPersistsTheRefreshedRecord` (refresh count = 1; rotated fields; linkedAt fixed; single key), `testRefreshRetainsTheStoredRefreshTokenWhenTheResponseOmitsOne`, `testRefreshTransportFailureKeepsTheRecordAndReportsNetworkUnavailable` (row 11: record kept, no wipe, one attempt), `testInvalidGrantWipesTheRecordAndReportsRevoked` (row 10: record gone, `keysCarryingMaterial` empty, `spotify_unlink`/`revoked`), `testRefreshNonInvalidGrantErrorKeepsTheRecordAndReportsRefreshFailed`, `testUnparseableRefreshBodyKeepsTheRecordAndReportsMalformedResponse`, `testRefreshStoreWriteFailureKeepsTheStoredRecordAndReportsStorageFailure`, `testTheRefreshBoundIsExactlyOneAttemptPerRequest` (two sequential calls = 1+1 attempts, never more), `testProductIsReverifiedOnRefreshAndAFailedReverifyKeepsTheStoredValue`, `testCapabilityStalenessSkipsTheReverifyWhenTheDerivedAgeIsYoung`, `testLinkedRecordWithoutAClientIDReportsNotConfiguredAndMakesNoRequest`, `testValidAccessTokenWithNoRecordReportsRevokedWithoutAWipeOrEvent`, `testANonPositiveRefreshLimitForbidsTheRequest` |
| 4. Unlink wipes locally; no remote revocation | `testUnlinkWipesLocallyWithNoRemoteRevocationCall` (record gone from store AND seam; status `.notLinked`; `transport.requests.count == 0` — the V-1 stance as an assertion; `spotify_unlink`/success event), `testUnlinkWipeFailureKeepsTheRecordAndReportsFailed`, `testMarkRevokedWipesAndReportsRevoked`, `testMarkRevokedWipeFailureKeepsTheRecordAndReportsFailed`, `testReLinkAfterUnlinkWritesExactlyOneFreshRecordWithNoResidualState` (one key again, fresh values, event sequence link→unlink→link) |
| NFR-SP-002 (release gate) | `testEveryEmittedEventCarriesEmptyMetadataAndAClosedVocabulary` (component `spotify`; `metadata == [:]`; `durationMs == nil`; outcome ∈ the closed per-event set; errorCode ∈ the 15 case names), `testErrorCodesNeverCarryAssociatedValues` (provider registry code, numeric presentation code and status code never appear in `errorCode`) |

## V-1 — no-remote-revoke stance verified against provider documentation

All pages fetched and quoted 2026-10-07 (re-verified this session via curl).

1. `https://developer.spotify.com/reference/web-api/open-api-schema.yaml` —
   the official OpenAPI schema: 70 paths, and the single occurrence of
   "revoke(d)" in the whole document is the 401 description:
   "Bad or expired token. This can happen if the user revoked a token or the
   access token has expired. You should re-authenticate the user."
   There is NO revocation endpoint to call — the documented remedy for a
   token invalidated by the user is re-authentication, which is exactly what
   this implementation does (wipe + relink prompt).
2. `https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens` —
   refresh is `POST https://accounts.spotify.com/api/token` only; refresh
   tokens "have a lifetime of 6 months"; "After 6 months, the refresh token
   can no longer be used. Reauthorization: Your app must send the user
   through the authorization flow again."; "Build reauthorization into your
   app before refresh tokens expire." A denial/revocation by the user is
   therefore surfaced to this client exactly as `invalid_grant` on that one
   endpoint.
3. `https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration` —
   "When a refresh token expires, the Spotify token endpoint ... will return
   a 400 Bad Request response with an invalid_grant error. Your app must
   handle this case by discarding the token and sending the user through the
   authorization code flow to obtain a new one." (New apps: affected
   immediately; existing apps: from July 20, 2026.) This is verbatim the
   wipe-on-invalid_grant path implemented here.
4. `https://developer.spotify.com/documentation/web-api/concepts/authorization` —
   the documented OAuth surface is authorize + token only; no revocation
   grant/endpoint appears.
5. `https://developer.spotify.com/policy` — no app-side revocation
   obligation appears in the developer policy.
6. Enumeration of the developer-docs navigation (133 documented slugs) found
   no token-revocation page.

Conclusion: the stance is VERIFIED, not assumed — no third-party revocation
endpoint exists, the documented handling of an invalidated grant is discard +
re-authenticate, and this implementation's `invalid_grant` → local wipe →
`revoked` → relink-prompt behavior matches the provider's own guidance. No
BLOCKER. Evidence above is ready for the T-123 bundle.

## Design ambiguities resolved (surfaced, not hidden)

1. **Bus seam (§26 shows no bus, §10 requires events).** §26's initializer
   has no `observabilityBus` parameter, while §26/§10 require `spotify_link`
   and `spotify_unlink` events. Least-invasive resolution, following the
   `GoogleAccountSession` precedent: ONE trailing, defaulted
   `observabilityBus: ObservabilityBus = SpotifyAccountSession.unwiredBus`
   (a file-private dropping sink). The §26 initializer stays callable
   exactly as written; unit tests inject a recording bus. **T-119 must pass
   the app's bus at the production call site** — wiring that skips the
   parameter loses this component's events and nothing else.
2. **Expiry skew, applied once.** `TokenResponse.expiryInstant(issuedAt:
   skewSeconds:)` (W1, whose doc names the session as the caller) applies
   the 60 s skew at record-write time, so the STORED `expiry` is the instant
   the token stops being usable, and `validAccessToken()` checks
   `Date() < record.expiry` — the same cushion §10 states as
   `Date() < expiry - 60 s` against the provider's raw expiry. Applying the
   skew again at read time (double application) was rejected as a misread.
3. **Staleness arithmetic made design-literal.** design-l2 §10: "the derived
   verification age is `expiry - 3,600 s` (Spotify's token lifetime); when a
   request finds that age older than `spotify.capabilityStalenessSeconds`,
   the opportunistic `/v1/me` re-check runs". Implemented as: verification
   instant = `expiry - assumedTokenLifetimeSeconds (3,600)`; re-check when
   `now - verificationInstant > capabilityStalenessSeconds`. (An earlier
   draft used `capabilityStalenessSeconds` for BOTH the subtraction and the
   threshold, which made the injected parameter unobservable on the refresh
   path; corrected before the gate.) With the shipped defaults (3,600/3,600)
   the re-check runs on essentially every refresh — the risk table's
   "re-verify on every refresh" — while an injected bound can suppress it,
   which `testCapabilityStalenessSkipsTheReverifyWhenTheDerivedAgeIsYoung`
   pins.
4. **`nonisolated` statics (compile-required; no interface change).** The
   class is `@MainActor` (design concurrency: the Spotify path's mutable
   state is main-actor confined, and the store is `@MainActor`), so its
   statics are main-actor isolated — but §26 uses `bundledClientID` (and the
   bus default `unwiredBus`) as default-argument expressions, which are
   evaluated outside the actor. Both are marked `nonisolated` (a `Bundle.main`
   read and a stateless immutable sink — thread-safe by construction). The
   alternative (dropping `@MainActor` from the class, as
   `GoogleAccountSession` does) was rejected because the §26-instantiated
   W1 store requires it.

## Classification decisions (each pinned by a test)

- No record at `validAccessToken()` → `.failure(.revoked)` — the case whose
  treatment is unlinked (row 10); defensive only (the router's askability
  gate means it is unreachable in normal flow); no wipe, no event (nothing
  was wiped, so nothing is reported).
- A callback `error=` that is `access_denied` → W1 already maps it to
  `.userCancelled` (a decision, not a failure) → `LinkOutcome.cancelled` and
  the `cancelled` event outcome.
- A non-HTTP `URLResponse` anywhere → `.networkUnavailable` (a transport
  anomaly, never a provider verdict, never a store write).
- A 2xx refresh body this client cannot parse → `.malformedResponse`, record
  KEPT (only the provider's definitive rejection wipes).
- `refreshAttemptLimit < 1` → `.networkUnavailable` with zero requests (the
  injected bound is honoured absolutely; same for a missing client id at
  refresh time → `.notConfigured`).
- Wipe failure on the `invalid_grant` path: the caller still receives
  `.failure(.revoked)` (row-10 treatment), but the status and the event say
  what actually happened on disk (`failed`/`storageFailure`, record visible).
  The attempt is never repeated by this call.
- The refresh path emits NO events: §26's vocabulary for this component is
  `spotify_link` / `spotify_unlink`; refresh failures surface through the
  returned `Result` and the status, not as invented event types.

## Findings surfaced for other tasks (not fixed here)

1. The `/v1/me` `product` field is marked `deprecated: true` in Spotify's
   official schema, while design L2-D13/D14 build the capability read on it.
   The honest degradation is implemented (missing/unrecognised product →
   `.unknown`, treated exactly like `.free` — deep-link-only), but if the
   field is ever removed, L2-D14's `.premium` determination needs a new
   source. Worth a line in the T-123 bundle / future design pass.
2. The 6-month refresh-token lifetime (effective for existing apps since
   July 20, 2026) makes `invalid_grant` a ROUTINE, expected event for every
   linked household — the surfaces (T-116/T-120) should present the relink
   prompt as normal maintenance copy, not as an error.

## Files changed (uncommitted, per instructions)

- A `ios/ElderlyAssistant/Services/Spotify/SpotifyAccountSession.swift`
- A `ios/ElderlyAssistantTests/Services/Spotify/SpotifyAccountSessionTests.swift`
- A `specs/T-110-notes.md` (this file)

No other file was written: `CommandRouter.swift`, `AppCoordinator.swift`,
`Info.plist`, `SpotifyTool.swift`/`SpotifyTransport.swift`,
`VoiceContactSearchRoute.swift`, `KeywordIntentRule.swift`, the W1
T-108/T-109 files and `project.pbxproj` were never edited by this task
(xcodegen picked both new files up from the directory globs). Nothing was
committed, staged or pushed.

## Confidence

High (90/100). All four Gherkin scenarios and every §22 seam item are covered
with call-count and stored-state assertions; the full scoped gate is green
(45/45) including the log-discipline lint; V-1 is verified against primary
provider documentation. The residual 10 reflects: (a) the two resolved design
readings (bus seam, staleness arithmetic) are interpretations a reviewer may
want to re-confirm against §26/§10, and (b) the live device behavior of the
real `ASWebSpotifyAuthSession` seam (T-111) and the router's consumption
(T-116) are out of this task's scope.
