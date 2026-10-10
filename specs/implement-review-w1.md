Reviewer: sdd-reviewer subagent (read-only), orchestrated by the main session
Reviewed revision: feat/spotify-music-integration @ 489645a + uncommitted W1 implementation (2026-10-07)
Verdict: GO — Confidence 0.90

# W1 Implementation Review — spotify-music-integration

## Scope and method

Read-only review of the uncommitted W1 implementation in `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration` (HEAD `489645a`), diffed with `git diff master -- ios/ElderlyAssistant ios/ElderlyAssistantTests ios/seniOS.xcodeproj/project.pbxproj` (1,452 insertions / 24 deletions across 11 modified files plus 10 new files: 5 app, 5 test). All seven W1 task files, the constitution, `specs/design-l2.md`, `specs/security-design-review.md`, and `specs/review-l2.md` were consulted. No file was modified. The xcresult bundle was parsed fresh by this review; the three `/tmp` gate logs were read, not re-executed.

Post-review drift check: at review time the uncommitted set contains exactly the W1 files; no T-110/T-111 artifacts (Info.plist, `SpotifyAccountSession`) have appeared. The only non-implementation changes are `.ai-sdd` run-state files (orchestrator activity). The revision reviewed is therefore stable.

## Adjudication of the three flagged context items

1. **Placeholder arm (CommandRouter.swift:1205-1210) — VERIFIED INERT.** `case .music:` contains only the `[SPOTIFY]` comment and `break`. A `break` exits the `if let relaxed` switch; execution continues identically at the TopicPreAnswer stage (`CommandRouter.swift:1324`) — the exact continuation a baseline nil match produced. No `speak`, no `emit`, no `logToolRequest`, no coordinator call. The comment names the driver direction and T-116 ownership. Confirmed as an acknowledged, behavior-neutral compile unblock for the T-112/T-114 coupling.

2. **T-114 completion — VERIFIED GENUINE.** `YouTubeLogProjection` (CommandRouter.swift:2379-2390) with `.explicit` identity / `.queryFree` → `""` (2384-2388); `fireYouTubePlay(query:logProjection: = .explicit)` (2418-2419); `deliverYouTubeFailure(...logProjection: = .explicit...)` (2525-2526). All 3 `logToolRequest(kind: .youtube, ...)` sites are threaded (2447, 2489, 2532) and all 6 pass-throughs (2432, 2461, 2474, 2497, 2504, 2511). The defaults leave every pre-existing call site byte-identical. I independently re-derived the byte-identity proof: the Swift-embedded `explicitYouTubeT114Baseline` (CommandRouterYouTubeTests.swift:197+) equals `/tmp/t114-golden-clean.txt`, which equals the raw pre-variant capture extracted from `/tmp/t114-baseline-pre.log` after normalizing duration values. `testT114CaptureExplicitYouTubeBaseline` (:184-190) is capture-only (not a circular assertion); the harness projection (:73-126) excludes id/timestamp/duration values and includes every user-visible and logged string across 10 fixtures (:132-182). Residual risks are stated under T-114 below (no production `.queryFree` caller until T-116; a dropped pass-through would compile silently due to the `.explicit` default).

3. **Fixture move (T-112) — JUSTIFIED, NOT A COVERAGE LOSS.** "गीत चलाऊ" and "play some music" would now fail the old nil assertion because FR-SP-013 makes them music requests; the supersession is documented in place (KeywordIntentRuleTests.swift:89-95). "गीत चलाऊ" is re-seated literally as a positive music fixture (:304); "play some music" is covered via "play a song" (:310), the full marker×verb cross product (:326-336), and the noisy-text fixture "can you listen to some music with me" (:342). The YouTube-no-fire discipline is preserved by the remaining rows (:96-99, :102-108), the ordering/precedence tests (:430-442, :444+), and — strongest — the router-level byte-identical harness, which still pins "युट्युबमा गीत चलाऊ" (CommandRouterYouTubeTests.swift:140-142) and "search songs on youtube" (:178-180) through the full ladder. This is the correct reconciliation of Gherkin scenarios 1 and 2 of T-112.

## Per-task verdicts

### T-106 — SpotifyTool search and remote-play — PASS
`Services/Spotify/SpotifyTool.swift` and `SpotifyTransport.swift` match design §24's exact interface for the search+play half: typed `FetchError`/`PlayError` (SpotifyTool.swift:64-103), `defaultFetchTimeoutSeconds = 8.0` injected per call site (:111, :176, :213), 22-char base62 gate (:285-290), single-request discipline with no retry, header-only Bearer credential, egress to `api.spotify.com` only (:135-164), zero console writes anywhere in the new files (verified by direct sweep). `SpotifyToolTests.swift` covers percent-encoding, the identifier corpus, timeout classification, the 401/403-premium/403-restricted/404/500 mappings, invalid-URI-no-request, and the api.spotify.com-only pin. The deep-link half (`trackURI`/`searchURI`/`open`, design-l2.md:465-467) is correctly absent — it is T-107, a separate task in the same group.

### T-108 — SpotifyCredentialStore — PASS
`SpotifyCredentialStore.swift` implements the single `spotify.session` record (six fields), `@discardableResult save/clear -> Result<Void, StorageError>`, corrupt/absent/unreadable → nil with no plaintext fallback. Tests: field-by-field round-trip across a relaunch (SpotifyCredentialStoreTests.swift:43-69), constant↔placement pin against the `StoragePlacement` literal (:72-81), failed-write typed and previous record kept in memory and on disk (:110-136), failed-clear keeps status (:139-163), honest degradation (:168-204), target wipe leaves exactly the neighbouring `family.contacts` payload and zero credential material across every seam key (:209-261), failure rendering content-free (:266-282). `StoragePlacement.swift` places the key in `keychainResidentKeys`; `StoragePlacementTests.swift` updates the set-equality pin and adds the keychain pin (:26-41) — a rename on either side fails a test.

### T-109 — SpotifyAuthFlow (PKCE) — PASS
PKCE S256 matching the RFC 7636 appendix-B vector; authorize URL carries `code_challenge`/`S256`/state; callback validation is exact-match on scheme/host/empty-path with userinfo/port/fragment rejection, then state (including non-empty expected state), then the error registry, then non-empty code — with one named test per rejection class and a whole-matrix walk asserting nothing is returned for any rejection (SpotifyAuthFlowTests.swift). No client secret exists anywhere in bundle, exchange, refresh, or vocabulary (asserted). Tokens travel only in the `Authorization` header. The 15-case content-free error enum is exactly as specified. Two scoping notes (both task-sanctioned, see findings): the M-3 two-scope trim is pinned in tests while design-l2's §26/appendix still list three scopes; the refresh-bound/link-timeout enforcement lands in T-110 with the constants injected from these defaults.

### T-112 — KeywordIntentRule music domain + extractor — PASS
`Domain.music`, `Rule.excluded: [Group]` with `[]` default (KeywordIntentRule.swift:329-344) and the per-rule exclusion check (:176); the music rule sits between youtube and appLaunch (:363-376); `musicMarkers` (:536-540), `musicVerbFamily` with the narration guard exclusions (:557-585), `mentionsMusic` (:730-734), `musicQuery` with the L2-D10 fallbacks (:752-779) and the drop sets (:787-843). Fixtures: golden verb-bearing corpus, marker×verb cross product, noisy text, matched-keys payload, noun-only non-fire, narration guard, exclusion forms, grapheme pins, YouTube precedence and the YouTube-marked-never-music pins (:301-460+), extractor fixtures. `t112-gate2.log` shows 48 tests / 0 failures. One MINOR finding on a test comment's factual claim (F-1 below) — behavior itself is as designed.

### T-114 — YouTube query-free logging — PASS
Implementation, threading and byte-identity proof all verified (see adjudication 2). The three T-114 tests are `Passed` in the parsed xcresult (case names `testT114CaptureExplicitYouTubeBaseline`, `testT114ExplicitYouTubeTurnsStayByteIdentical`, `testT114QueryFreeProjectionNeverCarriesTheQuery`, all in CommandRouterYouTubeTests.swift:184, :345, :353). Residual risk, explicitly carried by the task's own note (T-114 file line 43): the music-turn per-entry tool-log walk moves to T-116's pin set, and a future dropped `logProjection` pass-through would silently default to `.explicit` — T-116's pin set is the stated mitigation. `testT114QueryFreeProjectionNeverCarriesTheQuery` pins the projection semantics (empty output; no query fragment survives; `.explicit` is identity).

### T-115 — Tool-log Spotify kind — PASS
`LocalToolLogStore.swift` adds `Kind.spotify` with the §21 contract documented at the enum and at `query`/`response` (query ALWAYS empty; response empty except the terminal honest line). Tests cover the round-trip across store instances, the four §21 row shapes, the export allowed-keys set, and the empty-query assertion. `ToolLogReviewView.swift` gains exhaustive `kindIconName`/`kindLabelKey` switches (both no-default, C-4) with `.spotify` → `"music.note"` / `"toolLog.kind.spotify"`; `ToolLogKindMappingTests.swift` pins the kind set, label key, icon, distinctness, and both-language resolution. The Gherkin's "written by the router" clause is T-116's by the task file's own note (T-115 line 43).

### T-117 — Localisation catalog — PASS
20 keys (8 spoken + 10 settings + 2 singletons) in ne+en, `manual` extraction, both states `translated`; ne values carry no ASCII letters — provider loanwords are Devanagari (SpotifyLocalizationTests.swift:81-107). The M-2 amended privacy copy ships verbatim in both languages and the pre-amendment "nothing else is sent"/"अरू केही पठाइँदैन" clauses are asserted absent (:143-193), matching `specs/security-design-review.md` M-2. `spotify.playing` carries the runtime title in both languages (:109-126). Catalog count pinned at baseline 1341 + 20 = 1361 with alphabetical-neighbour instrumentation (:197-218); the orphaned `router.musicStub` key is retained per ADR-SP-11 (:223-227). The F-7 `removeConfirm` deviation is recorded (test doc comment :17-22 and pinned copy :233-237; T-120's task file carries the same note at its line 47).

## Findings

### [MINOR] F-1 — Test comment states a false grapheme fact; the real over-block class for the T-113 veto is narrow but untested
KeywordIntentRuleTests.swift:402-404 claims "a contact named गीता carries the substring गीत". Empirically false under the pinned 2026-09-07 grapheme semantics. Minimal repro:

```
swift -e 'print("गीता".contains("गीत"), "गीतांजलि".contains("गीत"), "गीतहरू".contains("गीत"), "भजनको".contains("भजन"), "गीतमाया".contains("गीत"))'
→ false false true true true
```

Impact: (a) the fixture "गीतालाई फोन गर" (:406) passes for the verb-absence reason alone — the marker-side homonym protection the comment describes is not actually exercised by any fixture; (b) the genuine residual class for the T-113 contact-search veto is names where the marker stem survives clustering — "गीतमाया" (true), or a postposition after a marker name like "भजनलाई फोन गर" (true) — for which `mentionsMusic` returns true and contact search will be vetoed. The common names गीता/गीतांजलि are empirically safe. The veto semantics are exactly as design §15 specifies (Devanagari substring, shared marker family), so this is not an implementation defect — but T-113 should (1) decide the class explicitly, (2) add a fixture such as "भजनलाई फोन गर" to the rule-exclusion table (rule stays nil) and a `mentionsMusic` = true/known-veto fixture for the fused class, and (3) fix the comment. Fix here is comment-only; fixture additions belong to T-113 (W1 does not ship the veto).

### [MINOR] F-2 — Scope-set drift between design-l2 and the M-3-mandated implementation
`SpotifyAuthFlow.swift:85-95` ships two scopes (`user-read-private`, `user-modify-playback-state`); `SpotifyAuthFlowTests` pins them and asserts `user-read-playback-state` absent. But design-l2 §11/§26 and the OD-S2 appendix (design-l2.md:408, "scopes = the three in §26") still say three. Impact: the owner OD-S2 Dashboard-registration step reads the design, not the security review, and could register an extra scope. The deviation is recorded in the T-109 task file and code/tests, but the design doc was not amended. Minimal fix: amend design-l2 §26 and the appendix (or annotate them "superseded by M-3 — two scopes"), no code change.

### [MINOR] F-3 — T-106 Gherkin names an "artist" the binding design does not expose
T-106 file line 25: "the returned track exposes its 22-character base62 id, name and artist". Design §24's `TrackResult` (design-l2.md:418-421) and the implementation expose id + title only; the T-106 impl note line 48 binds signatures to §24, and SpotifyToolTests.swift:31-35 records the choice. Impact: the written acceptance criterion is literally unmet while its binding authority says otherwise — amend the task wording (or carry artist downstream, which §24 and NFR-SP-002 argue against).

### [MINOR] F-4 — Release log-safety gate does not yet scan the new Spotify sources
`ios/tools/check-release-log-safety.py:141` scopes rules 3-6 to the live-camera-translation feature roots; no Spotify/`Services/Voice` root is added yet (T-121 owns this). W1 mitigation is solid: `build.sh`'s gate ran exit 0 (rules 1-2 do scan all Swift files for transcript content), and my direct sweep found zero `print`/`os_log`/`NSLog`/`debugPrint`/`Logger` in `Services/Spotify/` with per-file log-discipline headers (design §33). Impact: a future content-bearing console write in the Spotify files would not be gate-caught until T-121 lands. No W1 action; flag for T-121's root list to include the new directories.

### [MINOR] F-5 — Deferrals acknowledged by the tasks themselves (no W1 action)
(a) `.queryFree` has no production caller until T-116 wires `fireMusicRequest`; (b) T-114's music-turn per-entry tool-log walk is carried into T-116's pin set (T-114 file line 43); (c) T-115 Gherkin scenario 3's "written by the router" is T-116 (T-115 file line 43); (d) T-109's refresh-attempt enforcement and link-flow-timeout injection execute in T-110 (`SpotifyAccountSession` init), with the constants pinned now. Each has a named owning task; none is silently dropped.

## Security-relevant checks performed (all clean)

- NFR-SP-002 / M-1: no query, title, token, code, verifier, or provider body reaches any log surface in the new files (direct grep sweep plus per-file comments); the tool log's Spotify rows are contractually `query == ""`; `.queryFree` exists precisely for the music-turn YouTube leg; the T-114 projection test pins it.
- Hostile input: `parseSearchJSON` validates the id against `^[A-Za-z0-9]{22}$` before anything downstream; `playTrack` rejects any non-`spotify` scheme before a request exists; titles are never composed into URIs (uri construction is T-107's, under the same gate).
- Egress: only `api.spotify.com` (tool/transport) and `accounts.spotify.com` (auth flow), pinned by tests (SpotifyToolTests, SpotifyAuthFlowTests).
- Secrets: no client secret anywhere; PKCE S256 per RFC 7636 (vector-tested); redirect exact-match incl. userinfo/port/fragment rejection; credential at rest keychain-resident with a single-key targeted wipe proven residue-free.
- pbxproj: all 5 new app files and 5 new test files registered in the correct Sources phases (both-target grep, 42 registration lines); `project.yml` untouched (globs; `build.sh` regenerates the project, which the gate log confirms).
- Constitution: the root-constitution Spotify amendment is committed on the branch (b897ea6).

## Could not verify

- Device/simulator-visible behavior (DV-1..DV-5) — unit-level review only; no on-device run in this read-only review. T-123/device validation owns this.
- The Spotify Dashboard registration itself (OD-S2 owner action) — only the tripwire test and the M-3 trim could be verified.
- Live provider behavior (real Spotify API responses) — all tests use stub transports by design.
- The runtime enforcement clauses that execute only in later waves: refresh-attempt limiting and link timeout (T-110), the music router path and its pin set (T-116), plugin/prompt wiring (T-118), settings surface (T-120), gate-root extension (T-121).
- The gate logs were read and the xcresult was parsed fresh (172/172 Passed including the three T-114 cases; A/B exits 0; T-112 gate 48/0), but I did not re-execute xcodebuild in the worktree (read-only mandate).

## Verdict rationale

Seven units, zero FAIL, zero MAJOR. The strongest claims in this wave survived hostile verification: the T-114 byte-identity proof holds against the raw pre-variant capture, the placeholder arm is provably inert, the fixture move is forced by FR-SP-013 and fully compensated, and the credential/scope/privacy constraints hold. The MINOR findings are documentation-accuracy, gate-coverage, and deferral notes — none undermines the correctness, privacy, or scope of the shipped W1 code. GO, confidence 0.90.
