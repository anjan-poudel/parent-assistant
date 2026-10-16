# T-123 — Security evidence bundle (nine obligations) — notes

- Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration`
- Branch: `feat/spotify-music-integration`, HEAD `3519a34d3c93584f4acfee1d0982f5bb17a3b553` ("Implement spotify-music-integration W6 (T-120): Settings Spotify section")
- Date: 2026-10-07
- Task: `specs/plan-tasks/tasks/TG-23-release-gates-security-evidence-and-device-validation/T-123-security-evidence-bundle.md` (binding; 3 Gherkin scenarios)
- Source of the nine obligations: `specs/security-design-review.md` § "Evidence obligations for security-test" (:134–144); must-fix conditions M-1…M-3 (:89–105); verify-and-record items V-1…V-4 (:124–128)
- No commit was made (instructed). `ios/seniOS.xcodeproj/project.pbxproj` shows as modified because xcodegen regenerated it during the gate build (the new test file was picked up automatically); it was not hand-edited. **No product code was modified.**

## What was produced

1. **NEW `specs/SP-security-evidence-index.md`** — the bundle the `security-test` gate reads: nine obligations O1 … O9, each with producer, artifact, verbatim reproducible command, recorded output, status and named-test evidence; plus environment and build identity, the recorded freshness run with per-class counts, related guards, an integrity table, and a "Recorded limits and gaps (not exercised…)" section.
2. **NEW `ios/ElderlyAssistantTests/Services/Spotify/SpotifySecurityEvidenceIndexTests.swift`** — 8 tests that keep the bundle honest: completeness, token existence against the test tree, exactly-allowed pendings, freshness coverage, machine-checked no-secret/no-paste rule, and recorded limits. The rejection path is exercised on fixtures through the same parser the real bundle uses.
3. **Real secret-scan evidence** — `/tmp/t123-secret-scan.log` (commands, exit codes, per-artifact attribution).
4. **Freshness run records** — `/tmp/w7-gate.log` (the recorded green run) and `/tmp/w7-gate-seed.log` (the seed run, kept for the record).
5. **This file.**

## The nine obligations — status table

| # | Obligation | Producer | Status |
|---|---|---|---|
| O1 | Built-artifact secret scan (PKCE-only proof) | T-123 scan run; T-109/T-120 no-secret pins | PASS |
| O2 | Keychain placement + post-wipe sweep | T-108 (+ T-110 unlink path) | PASS |
| O3 | Callback reject matrix | T-109, T-111 | PASS |
| O4 | Refresh + revocation bounds, incl. the V-1 record | T-110 (V-1 record `specs/T-110-notes.md:123-162`) | PASS |
| O5 | Hostile corpus | T-107, T-106 | PASS |
| O6 | Log-surface checks | T-121, T-114/115/116; DV-7 half T-124 | **PASS-partial** (allowed pending) |
| O7 | Disclosure copy vs actual data flow | T-117 shipped copy; T-120 surface; the check below | PASS |
| O8 | Scope equality (requested = pinned = Dashboard) | T-109 pin; Dashboard column OD-S2 | **PASS-partial** (allowed pending) |
| O9 | Egress allowlist | T-116 pin (+ T-106/T-109 host pins) | PASS |

The two `PASS-partial` entries are the exactly-allowed pendings; the completeness test requires both to be recorded with their dependency named (O6: T-124 / DV-7; O8: OD-S2 / Dashboard) and fails on any other incomplete entry.

## Secret scan (O1) — the actual run

The scan was performed for real in this worktree (task scenario 3), not inherited. Raw transcript: `/tmp/t123-secret-scan.log`.

**Defined predicate.** A bare 32-hex "secret shape" alone is not evidence: the built image contains 167 distinct 32-hex runs in data tables, ICU data and hashes, and the app sources contain Apple help-image asset IDs of the same shape. The predicate that is a finding is (a) a secret-bearing KEY name (`client_secret`, `ClientSecret`, `SPOTIFY_CLIENT_SECRET`, `api_secret`, `apiSecret` or a secret/Secret token adjacent to a 32-hex literal) anywhere in first-party code or the app image stream, or (b) the literal `client_secret=` form with a value. Both are zero.

**Commands and results** (all recorded in the log):

| # | Command (abbreviated) | Result |
|---|---|---|
| S1 | `grep -rInE 'client[_-]?secret\|ClientSecret\|SPOTIFY_CLIENT_SECRET\|apiSecret\|api_secret' ios/ElderlyAssistant/` | exit 1 — zero matches |
| S2 | `grep -rInE '(secret\|Secret)[^ ]{0,20}[0-9a-f]{32}\|…' ios/ElderlyAssistant/` | exit 1 — zero matches |
| S3 | image stream through the same key-name pattern | 23 raw word lines, fully attributed (below) |
| S4a | image stream through `grep -E 'client_secret=[^ ]'` | exit 1 — zero matches |
| S4b | image stream through the shape-in-context pattern | exit 1 — zero matches |
| S5 | built `Info.plist` key audit | one public key: `SpotifyClientID` (empty → dormant state); no secret-named key of any kind |
| S6 | repo-wide word occurrences outside app inputs | docs/specs/workflow documents + one test file's method names; no product code |

**App image:** `ios/build/DerivedDataTests/Build/Products/Debug-iphonesimulator/ElderlyAssistant.app` (present in this worktree — scanned, not deferred to a device build). S3 attribution: 21 lines in `ElderlyAssistant.debug.dylib` are Objective-C property, ivar, selector and format-string names of the vendored AppAuth / GTMAppAuth OAuth-client code (the generic library statically linked for the pre-existing Google calendar feature) — API names such as the library's client-secret field spelling, never a value and never first-party use; 2 lines in `PlugIns/ElderlyAssistantTests.xctest` are test method names of the negative pins in `SpotifyAuthFlowTests`; 0 in the app binary, the preview dylib, `Info.plist`, `Frameworks/`, resource bundles and the widget. The counts are recorded in the bundle's O1 Output so the claim is auditable; the raw symbol lines are not copied into the bundle, and no token or value is copied anywhere.

## O7 — disclosure copy vs actual data flow (the check performed)

Verdict: **the shipped copy matches the implemented flow; no discrepancy.** Shipped English copy (key `spotifySettings.privacy`, en + ne, M-2-amended; rendered at `SettingsView.swift:909`): "What you ask for — including play commands — is sent to Spotify to find music and control playback; no other app data is sent."

What actually leaves the app, call site by call site (all verified by reading the sources, not the summaries):

| Flow | Call sites | What leaves |
|---|---|---|
| Search | `CommandRouter.swift:2828` (`SpotifyTool.fetchTopTrack`, under the router's `performMusicSearch` entry at :2792), `SpotifyPlugin.swift:130` (`handle`) | the request text as the `q` parameter of `GET /v1/search` on `api.spotify.com`; credential in the header only |
| Play | `CommandRouter.swift:2923` and the `:2946` refreshed-token retry, `SpotifyPlugin.swift:177` | `PUT /v1/me/player/play` with a body carrying only the URI built from a validated id — never a title |
| Authorization | `SpotifyAccountSession.swift:228` (authorize URL), `:262` (code + PKCE verifier exchange, no secret), `:427` (refresh) | PKCE material and tokens to `accounts.spotify.com` — the linked account's authorization, not app data |
| Free-tier / unlinked hand-off | `CommandRouter.swift:3044`, `:3074`, `SpotifyPlugin.swift:199` | a `spotify:` deep link opened by the device's Spotify app — covered by "sent to Spotify" |

Nothing else leaves on the music path (no cloud model; the pre-existing YouTube fallback keeps its own unchanged disclosure). One nuance recorded: the access token accompanies the provider requests as authorization (header only, never a URL), which "no other app data is sent" does not contradict.

## O8 — scope equality (recorded finding carried)

Requested = pinned = `{user-read-private, user-modify-playback-state}` exactly, read-playback scope absent (M-3 trim), asserted by the tripwire at `SpotifyAuthFlowTests.swift:89-119` over the constant at `SpotifyAuthFlow.swift:84-86`. Finding recorded and carried to the owner's OD-S2 registration step (**not papered over**): W1 review F-2 (`specs/implement-review-w1.md:57`) — the design scope prose is now annotation-complete (§11:211, §26:540 and the appendix:411 since a198830; §11:213 and §22:383 corrected at the W7 closure, 2026-10-07), so no stale three-scope sentence remains to misdirect the registration. The two-scope shipped constant is the authority the registration must follow. The Dashboard column is never marked passed on any agent's word (the completeness test refuses a PASS status for O8 while this pending exists).

## The completeness test — what it enforces

`SpotifySecurityEvidenceIndexTests` (8 tests, all green in the recorded run):

1. `testEveryObligationCarriesProducerCommandOrArtifactOutputAndAPassingStatus` — exactly O1 … O9; each with a producer, a command or artifact, a non-empty output and a passing status (PASS or PASS-partial).
2. `testNoTestNamedAnywhereInTheBundleIsMissingFromTheTarget` — every `<Suite>.<test>` token must name a real class and method in `ElderlyAssistantTests` (97 unique tokens verified).
3. `testTheOnlyIncompleteEntriesAreTheExactlyAllowedPendings` — O6 and O8 must be PASS-partial with their dependency named; a pending anywhere else fails; O1's app-image pending is tolerated-but-not-required (it was not needed — the image was scanned).
4. `testAnIncompleteObligationEntryIsRejectedByTheSameParser` — the rejection is genuinely exercised: fixture strings run through the **same** `parseObligations` (no producer / no command or artifact / no output / empty output / PENDING status / PASS with a pending / PASS-partial without one / a TODO placeholder / no evidence token / a missing obligation / a duplicate), plus the token-existence mechanism against fixture sources with a deliberately absent suite and method.
5. `testAPendingOutsideTheAllowedSetIsRejectedByTheSameValidator` — an O3 pending fails; an O8 pending without OD-S2 fails; the allowed O8 shape passes; and a second pending on an allowed obligation fails the same validator (W7 review R3 — the one-per-obligation cap is held by the validator, not incidental to the artifact).
6. `testTheBundleRecordsBuildIdentityAndAFreshnessRunCoveringEveryCitedSuite` — branch, git revision, toolchain, `/tmp/w7-gate.log`, the `Executed N tests, with 0 failures` counts, and every cited suite must appear in the recorded gate command's class list.
7. `testTheBundleCarriesNoCredentialQueryOrTrackIdentifierShapes` — machine-checks the hard rule (constructed track ids, bearer values, token-body JSON shapes, verifier values).
8. `testTheBundleRecordsLimitsGapsAndTheDeviceRecordItPointsAt` — "recorded limits" and "not exercised" must be present, the device protocol must be referenced, and no device run may be claimed.

## Freshness gate run

Command (serialized via `/tmp/spotify-lockrun.sh`):

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
  ./build.sh test:unit SpotifySecurityEvidenceIndexTests SpotifyCredentialStoreTests StoragePlacementTests \
  ASWebSpotifyAuthSessionTests SpotifyAuthFlowTests SpotifyAccountSessionTests SpotifyDeepLinkTests \
  SpotifyToolTests SpotifyLocalizationTests CommandRouterMusicTests SpotifyPluginTests \
  PinnedSurfaceGuardTests SpotifySettingsSurfaceTests
```

Result: **GREEN** — `Executed 268 tests, with 0 failures (0 unexpected)`; exit 0; `** TEST SUCCEEDED **`; `=== Scoped unit run passed (baseline not advanced) ===`. The run executes the release log-safety gate (24 fixtures over 12 rules, all green) and the intent-prompt mirror gate ahead of every test scope.
Log: `/tmp/w7-gate.log` (the recorded run). xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.07_03-03-12-+1100.xcresult`.

Per-class counts (quoted in the bundle): SpotifySecurityEvidenceIndexTests 8 · SpotifyCredentialStoreTests 11 · StoragePlacementTests 7 · ASWebSpotifyAuthSessionTests 17 · SpotifyAuthFlowTests 37 · SpotifyAccountSessionTests 45 · SpotifyDeepLinkTests 20 · SpotifyToolTests 39 · SpotifyLocalizationTests 9 · CommandRouterMusicTests 35 · SpotifyPluginTests 19 · PinnedSurfaceGuardTests 7 · SpotifySettingsSurfaceTests 14 — total 268.

**Seed run** (kept at `/tmp/w7-gate-seed.log`): the first run after writing bundle + test produced 268 tests / 12 failures — 11 were a genuine bug in my new suite (see Decisions 2), and 1 was the intended counts-seeding assertion (the bundle cannot quote the run's counts before the run exists). Both were fixed, and the recorded green run was produced afterwards. The other 12 suites were 260/260 green in the seed run too.

**The recorded run covers the final bundle.** The last bundle write was at 03:03:08; the run's test session started at 03:03:12 and its suites ended at 03:06:41 — the bundle bytes the tests read are the bytes on disk now (prose-only edits afterwards were re-verified: 97/97 tokens resolve, counts line present).

### Gate class list — deviation from the brief's literal list

- Removed `SpotifyHostileCorpusTests`: that is a helper FILE (`SpotifyHostileCorpus.swift`), not a class — the T-107 tests live in `SpotifyDeepLinkTests` (the brief anticipated this adjustment).
- Added `StoragePlacementTests` (carries the `spotify.session` Keychain placements pinned in O2) and `SpotifyToolTests` (the grammar and host pins cited in O5/O9) so the recorded run covers **every** suite the bundle cites — the completeness test enforces this.
- Excluded `LiveTranslatePluginTests` per instruction (known branch-base red, unrelated).
- Net: 13 classes, listed above.

## Pendings (the allowed halves, machine-enforced: allowed set, named dependency, at most one entry per obligation)

1. **O6 device half — DV-7 console/sysdiagnose capture** (T-124; owner device dependent). The release gate is green on the clean tree and its planted-violation transcript (7 named violations) is recorded in `specs/T-121-notes.md` §3; the device-time console proof stays open until T-124's record lands in `specs/SP-device-validation-protocol.md`.
2. **O8 Dashboard column — the owner's OD-S2 registration.** Not observable by any agent; never to be marked passed on an agent's word; the W1-F-2 design annotations are in place (§11:211, §26:540 and the appendix:411 since a198830; §11:213 and §22:383 corrected at the W7 closure).

## Findings recorded (carried to their owners, not papered over)

1. **W1 review F-2** — scope-set drift between design prose and the shipped two-scope constant. State re-verified at the W7 closure: §11:211, §26:540 and the OD-S2 appendix (:411) carry the supersession annotation from a198830; the two genuinely stale sites — §11:213 and §22:383 — were corrected at the W7 closure (2026-10-07). (This entry's earlier wording named §26/:408 as still stale and missed :213/:383; corrected per W7 review R1.) Matters directly for the OD-S2 registration step (O8).
2. **§31 copy table matches the shipped catalog** (checked at the W7 closure) — design-l2:758 shows the M-2-amended sentence with the W6-closure annotation (committed in 3519a34); the pre-amendment wording survives only as a marked historical quote. (Earlier wording claimed the table was still stale; corrected per W7 review R2.) The shipped `Localizable.xcstrings` key is the authority O7 checks.
3. **App-image scan covers the simulator Debug artifact** from this worktree's test session, not a device Release build; the O1 commands are re-runnable against T-124's device image unchanged.
4. **Vendored OAuth-SDK symbol names** in the debug dylib are attributed (21 lines) rather than suppressed; they are API names, not secrets.
5. **No network-level capture** is offered: O9 rests on the recorded request URLs at the transport seam and the host pins.

## Decisions

1. **Scan predicate defined by context, not raw shape** — rationale in the O1 section (167 distinct bare-shape false positives in the image; Apple asset-id shapes in sources). Zero findings on the defined predicate; raw counts attributed.
2. **Counts-seeding cycle** — the completeness test must not predict a run's counts, so run 1 legitimately fails that one assertion; the counts were then transcribed from the log into the bundle and the recorded run re-ran green. The seed log is kept.
3. **Fixture-helper bug in my own suite, found by run 1 and fixed** — `rejects()` defaulted to `required: 1...1`, so an O4 fixture was rejected for the absent O1 rather than the O4 defect (11 XCTAssert failures). Fixed by deriving each fixture's required range from its own heading (explicit wider range only for the missing-obligation case). This is exactly the kind of rejection-path bug the fixture tests exist to catch, and it was caught by running them.
4. **Citation precision from source reads** — e.g. O7's `CommandRouter.swift:2828` is the `SpotifyTool.fetchTopTrack` call under the `performMusicSearch` entry at :2792 (not `performMusicSearch` itself); `SpotifyAuthFlow.swift:84-86` is the scopes constant. All cited line numbers were verified against the files before submission (StoragePlacement :58, SettingsView :909, plugin/session/test lines).
5. **Describe, never copy** — NFR-SP-002 is applied to the bundle itself and machine-checked; the T-121 planted-violation transcript is referenced in its notes, not copied; the scan log keeps commands, exit codes and attributable file names, not symbol-line contents in the bundle.
6. **V-1 cited, not duplicated** — the verification record lives where the plan requires it (`specs/T-110-notes.md:123-162`, six provider-documentation checks, conclusion VERIFIED); the bundle references it precisely.

## Deviations and limitations

1. The brief's literal gate list named one non-class (`SpotifyHostileCorpusTests`); the class list was adjusted to the real classes plus the two added suites (above) — all 13 named classes ran in the recorded run.
2. Obligation-6 and obligation-8 device/owner halves remain open (the allowed pendings); no device run happened in this work, and the bundle says so.
3. The bundle's O6 record references T-121's transcript and the build-path log `/tmp/t121-build-gate.log` rather than re-running the plant in this task (the plant is T-121's evidence; re-running it here would modify log-shaped fixtures, and the gate itself was re-run clean in this session, exit 0).
4. No commit/push, per instruction; `project.pbxproj` xcodegen regeneration only.
