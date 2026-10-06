# W6 Implementation Review — T-120 Settings Spotify section

**Reviewer:** sdd-reviewer subagent (read-only), orchestrated by the main session
**Reviewed revision:** worktree `feat/spotify-music-integration`, HEAD `f55e74f` + W6 working-tree changes (`SettingsTabs.swift`, `SettingsView.swift`, `userManual.json`, `SettingsTabMappingTests.swift`, `project.pbxproj` [xcodegen]; new `SpotifySettingsSurfaceTests.swift`, `specs/T-120-notes.md`, `specs/T-117-notes.md`)
**Date:** 2026-10-07
**Method:** everything below re-derived from code, catalog, git history and parsed xcresults. Prose in notes was treated as a claim to falsify, not evidence.

## Verdict

**GO — Confidence 0.92** (threshold ≥0.85 met).

The revision implements T-120 exactly as `design-l2.md` §17 specifies, all four Gherkin scenarios are covered by tests whose assertions genuinely exercise the shipped state machine, both gate runs reproduce green from their parsed xcresults, and the pre-existing-failure classification was independently confirmed against the branch base. Two MINOR notes-record/design-doc items and one NOTE are listed for closure; none blocks GO.

## Revision set integrity

| Check | Result |
|---|---|
| `git status --porcelain` equals the claimed set (5 modified + 3 untracked, nothing else) | PASS — exactly ` M` SettingsTabs.swift, SettingsView.swift, userManual.json, SettingsTabMappingTests.swift, project.pbxproj; `??` SpotifySettingsSurfaceTests.swift, specs/T-117-notes.md, specs/T-120-notes.md |
| No staged changes | PASS — `git diff --cached --stat` empty |
| No commit made | PASS — HEAD remains `f55e74f` ("W5: T-119, T-121") |
| `project.pbxproj` = xcodegen regeneration of the new test file only | PASS — 4-hunk diff adds only `SpotifySettingsSurfaceTests.swift` (PBXBuildFile `40D875CF…`, PBXFileReference `7A42C240…`, group, test-target Sources); the consolidated gate log shows "seniOS.xcodeproj regenerated" (xcodegen 2.46.0) during the build; no hand-edit smell (single-file, deterministic-style IDs, registered in the test target beside the other Spotify test files) |

## Per-aspect verification

### 1. SettingsTabs.swift — destination, row, routing — PASS

| Claim | Evidence |
|---|---|
| `SettingsDestination.spotify`, rawValue `"spotify"`, titleKey `spotifySettings.title` | `SettingsTabs.swift:105` (case), `:131` (titleKey); enum is `String`-raw so rawValue is the case name |
| icon `music.note` | `SettingsTabs.swift:169` |
| `hiddenSheetRows` = `[.geminiAI, .voiceEngine, .webSearch, .youtube, .spotify, .intentLog, .toolLog]` (6→7, `.spotify` after `.youtube`) | `SettingsTabs.swift:199-202`; doc comments updated at `:84-87`, `:185`, `:186-198` |
| Routing `case .spotify: SpotifySettingsView(session: coordinator.spotifyAccountSession)` | `SettingsTabs.swift:435` |
| One session, no second construction (L2-R2) | `grep -c "SpotifyAccountSession(" SettingsTabs.swift` = 0; the only reference is the coordinator property access |

### 2. SpotifySettingsView — §17 order, no credential UI, no log lines, no catalog delta — PASS

| Claim | Evidence |
|---|---|
| §17 order: status card → privacy → rollout note → dialog | `SettingsView.swift:887` struct; `:909` `Text("spotifySettings.privacy")`; `:923` `Text("spotifySettings.rolloutNote")`; `:930` `.confirmationDialog("spotifySettings.removeConfirm", …)` |
| Dialog: destructive confirm = `spotifySettings.unlink` running `session.unlink()`, cancel = `common.back` | `:931-937` (`Button("spotifySettings.unlink", role: .destructive) { _ = session.unlink() }`, `Button("common.back", role: .cancel)`) |
| NO credential field (ADR-SP-01) | Read the full section: no `SecureField`/`TextField`/token echo; also asserted by `SpotifySettingsSurfaceTests.swift:363-376` |
| No new log lines (NFR-SP-002) | `git diff | grep "print(\|os_log\|Logger\|NSLog"` → no matches |
| No new/changed catalog keys | `git status`/`git diff` show **no** `Localizable.xcstrings` change; the 11 consumed keys pre-exist (T-117), verified by reading each value from the shipped catalog |

### 3. Leaf state machine — total over the real Status — PASS

Real API: `SpotifyAccountSession.Status` = `.notLinked`, `.linking`, `.linked(Product)` with `Product = {premium, free, unknown}`, `.linkFailed(SpotifyAuthError)` (`Services/Spotify/SpotifyAccountSession.swift:71-79`).

- `SpotifySettingsLeafState.init(state:)` (`SettingsView.swift:1019-1028`) switches over all four cases with `linked` split exhaustively over the three products — total, no default.
- `.linking` keeps the not-linked line (`:1037`) with the action visible but disabled (`:1054` `actionEnabled == self != .linking`; `:991` `.disabled`), matching §17 "buttons disabled; no status change until an outcome exists". No invented "connecting…" copy.
- `.linked(.unknown)` → `.linkedFree` (`:1026`) — L2-D14 non-optimistic, verified against `product(fromStored:)` which maps nil/unknown → `.unknown` (`SpotifyAccountSession.swift:662-668`).
- All `linkFailed` errors → one leaf (`:1027` ignores the associated error), matching the error-agnostic shipped copy.
- Status→line mapping is one-to-one: `.linkedPremium`→`status.linked`, `.linkedFree`→`status.freeTier`, `.notLinked`/`.linking`→`status.notLinked`, `.linkFailed`→`status.linkFailed` (`:1036-1042`); each key's en+ne values read from the catalog and match design §31 rows exactly (privacy being the M-2 amendment, see D5).

### 4. W2-D3 — link-failed/retry as routine maintenance — PASS

- Shipped copy (catalog, both locales, `state: translated`): en "Couldn't connect. Please try again.", ne "जोड्न सकिएन। फेरि प्रयास गर्नुहोस्।"
- Adjudication: the sentence is a plain statement plus a retry instruction — no fault vocabulary ("error", "failed to authenticate", "token", no blame), no red, no alarm glyph. Glyph `arrow.clockwise` (`:1071`) and tone `.neutral` (`:1080-1086`) ship as claimed. The W2-D3 premise (6-month refresh-token expiry makes `invalid_grant` → unlink → relink routine) is verified in `specs/T-110-notes.md:238-240` ("the surfaces (T-116/T-120) should present the relink prompt as normal maintenance copy") and the task file's own line 48. The retry affordance is the same Connect action (`:1046-1047`), so the state reads as "try again", not a fault. PASS.

### 5. F-7 — ruling verified, deviation recorded in both files — PASS

- `specs/review-l2.md:121` — F-7, blocks-GO column: "No — copy option" (the sentence is a slightly stronger summary than matrix row 8's `spotify:search:` hand-off, but does not block; a copy change is optional). The notes' reading ("the sentence stays") is faithful to the default the brief pinned ("if kept, record the deviation").
- Recorded in `specs/T-120-notes.md:120-122` (D10) and throughout `specs/T-117-notes.md`.
- T-117-notes provenance verified against git history: `git log --all -- specs/T-117-notes.md` is empty and the file is untracked — it never existed; T-117 shipped in `a198830` (W1); its catalog-side F-7 record is in `SpotifyLocalizationTests.swift` (doc comment :15-23, pin :233-237), and `specs/implement-review-w1.md:42` carries the F-7 note on the review side — all three claims in the provenance paragraph check out. The file states in its first paragraph why it was created.

### 6. Deviations adjudication

| Deviation | Adjudication |
|---|---|
| **D2 session-only injection** (view takes `@ObservedObject session`, no store; design :109 says "binds the coordinator's live session/store") | **ACCEPTED.** The store's `record` (fields: accessToken/refreshToken/expiry/product/scope/linkedAt — `SpotifyCredentialStore.swift:27-40`) carries nothing renderable beyond what `session.status` already surfaces, and both actions (`link()`/`unlink()`) are session methods. One lazy session over one store (L2-R2) means a second injected source could only disagree. The view's own comment and `SpotifySettingsSurfaceTests.swift:382-392` pin the single-session wiring. Sufficient. |
| **D3 rollout note unconditional** (with OD-S2(c) comment) | **ACCEPTED.** "Development mode / approved accounts only" is console-side state the client cannot observe; rendering the note unconditionally while that remains true is the honest maximum of design :329's "shown while … in development mode — honest, never hidden". A client-side flag would be a placebo gate. Exit path (note leaves with the §31 copy inventory) is stated in-code (`SettingsView.swift:916-922`). |
| **D5 §31 privacy table stale vs shipped amended catalog** | **ACCEPTED as a task-scope call; annotation owed at closure (see Finding 2).** Verified: `design-l2.md:758` still shows pre-amendment copy ("What you ask for is sent to Spotify to find the music; nothing else is sent.") while the shipped catalog carries the M-2-amended copy in both locales ("…including play commands…control playback; no other app data is sent." / "…बजाउने आदेश सहित…अरू कुनै डेटा पठाइँदैन।"). W1 already adjudicated the catalog amendment (`implement-review-w1.md:42`); the surface correctly consumes the catalog, and design-doc governance (amendment by closure annotation, the §17/§20 precedent) makes not rewriting it mid-task correct — but the annotation itself is owed before the owner's copy sign-off, because `security-design-review.md:121` (M-2, must-fix) requires amending the copy table before sign-off. |
| **D6 "account identity" = tier line** | **ACCEPTED.** The ADR-SP-08 record has no identifier field (verified: `SpotifyCredentialStore.swift:27-40` — no e-mail/name/id), the catalog ships no identity copy, and §17's linked state is defined as `status.linked` "Connected (Premium)". The tier line is the identity the design defines; anything more would be a new field plus new copy. |
| **F-7 keep copy** | **ACCEPTED** (see aspect 5). |
| **`.linking` keeps the notLinked line** | **ACCEPTED.** Exactly §17's "no status change until an outcome exists"; inventory-compliant (no unshipped copy invented). |
| **Manual edit + generalised pin** | **ACCEPTED.** Not in the brief, but the shipped manual paragraph enumerates the hidden sheet and the shipped test class owns manual-drift pins; leaving Spotify unnamed would ship a manual that omits a shipped surface. Both locales updated (parsed JSON confirms en "Spotify" / ne "स्पोटिफाइ" clauses), and the pin genuinely loops `Destination.hiddenSheetRows` (`SettingsTabMappingTests.swift:342-362`). Recorded as deviation 3 in the notes. |
| **Pre-existing failure classification** | **CORRECT — independently verified.** See aspect 9 below. |

### 7. userManual.json + generalised pin — PASS

- JSON parses (python json load); `settings` tour paragraph carries the Spotify clause in both `paragraphsEn` (line 447) and `paragraphsNe` (line 478).
- `testTheManualNamesEveryHiddenSheetRowWhereItLives` (`SettingsTabMappingTests.swift:342-362`) loops ALL `Destination.hiddenSheetRows` × both locales — not YouTube alone (diff verified; the old test is gone).

### 8. SettingsTabMappingTests pins — PASS

- Visible count stays 21: `:53-59` (`flattened.count == 21`).
- Partition invariant (every destination in exactly one half, so `.spotify` is hidden and not visible): `:61-72`; hidden rows have no tab: `:83-89`; exact hidden list = the 7-entry array with `.spotify` after `.youtube`: `:93-101`.
- The cloud-provider-key peer set is deliberately unchanged (`:103-114`, `.geminiAI/.webSearch/.youtube`) — matching §17's test-seam note (Spotify has no key screen). All 25 cases green in both scoped runs.

### 9. SpotifySettingsSurfaceTests (14 tests) — PASS

All 14 executed 14/14 green in three parsed xcresults. Assertion quality spot-checked against the brief's asks:

- **Scenario 2 end-to-end wipe on real storage** (`:185-217`): drives the real `SpotifyAccountSession` over the real store + `SpotifyInMemoryStorage` (the same double the store suite uses); asserts `store.record == nil`, the raw payload key gone, `keysCarryingMaterial(accessToken/refreshToken) == []`, status `.notLinked`, and exactly `["spotify_unlink|success"]` with empty metadata. This observes the wipe on the storage bytes, not on the session's self-report.
- **Both-locale resolution against the shipped catalog** (`:242-267`): `L10n.str` must differ from the key and from the other locale for all 11 consumed keys — a missing translation fails here.
- **Accessibility** (`:302-357`): labels are keys that resolve in both locales; the action button binds `DesignTokens.minTapTargetSize` (verified constant = 44, `DesignTokens.swift:127`) and the test rejects a hard-coded 44; glyph `.accessibilityHidden(true)` (code `:953`) with text-first status; stable identifiers `settings.spotify.status`/`settings.spotify.action` (`:960`, `:999`).
- **Wiring scan** (`:382-392`): pins the exact routing line, zero `SpotifyAccountSession(` in SettingsTabs.swift (my own grep: 0), row icon and title key.
- Scenario 1 runs the real session through a state-echoing auth seam (authorize seam executed, one record on disk, premium → `linkedPremium` + Remove action); abandoned and hard-failed flows both land in the single `linkFailed` leaf with the enabled Connect retry (`:89-116`); `.linking` in-flight gated via a latch actor (`:157-178`).
- Scenario 3 note: the Nepali disclosure *content* is pinned in T-117's `SpotifyLocalizationTests` (green in the same gate), with the surface test pinning resolution both locales plus the rendered-both-notes source scan — a reasonable split, since the surface must not restate catalog content.

### 10. Gate evidence — independently re-parsed — PASS

| Run | Log | xcresult | Parsed verdict |
|---|---|---|---|
| Unit gate | `/tmp/w6-gate.log` (6 classes listed at :59) | `Test-ElderlyAssistant-2026.10.07_02-31-51-+1100.xcresult` | 66 passed / 0 failed / result Passed — matches the claim |
| Consolidated | `/tmp/w6-gate-consolidated.log` ("only-testing: 10 class(es)" at :60) | `Test-ElderlyAssistant-2026.10.07_02-41-09-+1100.xcresult` | 140 passed / 0 failed / result Passed; classes = the 9 non-LiveTranslate classes of the failed run + SpotifySettingsSurfaceTests(14) + SpotifyLocalizationTests(9) etc. |
| Log-safety inside both builds | both logs | — | "log-safety fixtures: 24 case(s) over 12 rule(s)", every rule has a positive+negative fixture and behaves; prompt-mirror gate green; xcodegen regenerated the project |

### 11. Pre-existing failure classification — CORRECT (re-verified independently)

- Failed run `Test-ElderlyAssistant-2026.10.07_02-38-25-+1100.xcresult` parsed: 11 classes, 154 tests, **153 passed / 1 failed** — `LiveTranslatePluginTests.testScenarioTheFeatureIsReachableInOneClearAction()` at `LiveTranslatePluginTests.swift:383`, "the tile draws the feature's own glyph".
- That assertion is `assertMatches(#"LiveTranslateEntry\.iconName"#, in: HomeSubviews.swift)` (`LiveTranslatePluginTests.swift:381-383`). `HomeSubviews.swift:725` is `tile(artwork: "translate", titleKey: LiveTranslateEntry.labelKey, onRail: false)` — **byte-identical at `e2e2ae0` and HEAD** (`git diff e2e2ae0..HEAD -- HomeSubviews.swift` empty). `LiveTranslateEntry.iconName` exists (= "text.viewfinder", `LiveTranslatePlugin.swift:60`) but is never referenced in HomeSubviews.swift (grep: only `labelKey` at :725).
- Branch touched no Home file and no LiveTranslate test/helper: `git log e2e2ae0..HEAD -- HomeSubviews.swift HomeView.swift` empty; LiveTranslatePluginTests.swift unchanged; `FeatureSourceScan.swift` unchanged. Merge-base of `e2e2ae0` and HEAD **is** `e2e2ae0`; `337302c` and `d93be02` are ancestors of it. Therefore the test fails identically at the branch base (master) — the driver's classification is right, and it is not attributable to this branch.
- All other 10 classes in that run passed, including every Spotify/settings class.

## Findings

| id | severity | finding | evidence / repro |
|---|---|---|---|
| N-1 | MINOR | `specs/T-120-notes.md` D1 state table mis-states the shipped card glyphs for three rows — it says `.linking`, `.linkedPremium`, `.linkedFree` all draw `music.note`; the code ships `ellipsis.circle` and `checkmark.circle.fill`. Notes-accuracy only; the shipped code is correct and the design pins no per-state card glyph. | Repro: compare `specs/T-120-notes.md:72-76` (icon column) with `SettingsView.swift:1065-1072` (`statusIcon`: `.linking` → `ellipsis.circle` at :1068, `.linkedPremium/.linkedFree` → `checkmark.circle.fill` at :1069, `.linkFailed` → `arrow.clockwise` at :1071). Fix the notes at closure. |
| N-2 | MINOR | The `design-l2.md` §31 privacy row remains the pre-amendment copy on disk while the shipped catalog (and the surface) carry the M-2-amended sentence. Not rewriting the design doc inside W6 is the correct call (design-doc governance; the W2/W5 closure-annotation precedent), but the closure annotation **is owed**: `security-design-review.md:121` makes the copy-table amendment a precondition of the owner's sign-off on §31, which is the sign-off artifact. | Repro: `design-l2.md:758` (old copy, both locales) vs shipped catalog `spotifySettings.privacy` (amended, verified by parsing `Localizable.xcstrings`); `security-design-review.md:121` ("amend before the owner sign-off on the copy table"). Closure action: annotate/amend §31's privacy row (en+ne) in the same convention as the §17 "[W2-review D1]" / §20 "[W5-closure]" annotations. |
| N-3 | NOTE | No test pins the per-state card `statusIcon`/`tone` values (only statusKey/action/actionEnabled are pinned); a future silent glyph/tone change would pass the suite. Accepted: the design pins no per-state card glyph, the glyph is decorative and accessibility-hidden, and the tested contract (status line + action) is the design's. D4's glyph/tone claims were verified directly in code, not via a test. | `SpotifySettingsSurfaceTests.swift:302-357` cover label keys/tap target/text-first but assert no `statusIcon`/`tone` equality; `SettingsView.swift:1065-1086` is the only definition. |

No MAJOR findings. No out-of-scope elements found: the diff touches only the Settings surface, its tests, the manual, the notes and the regenerated project file; no credential surface, no logging, no new egress, no new catalog keys.

## Could not verify

1. **Rendered VoiceOver traversal order, assigned traits, dynamic-type layout and truncation at render time** — genuinely outside unit-test reach (the suite says so honestly at its file header :14-20 and D9). Source-level assertions plus DV-5 on the device are the evidence chain; DV-5 remains outstanding as designed.
2. **Whether the Spotify console is still in development mode today** (OD-S2's extended-quota filing is an external console-side state) — the note's honesty claim holds either way; if OD-S2 had closed, removing the note is a catalog change owed, which the code and D3 both state.
3. **Definitive tool-vs-hand origin of the pbxproj diff** — content is exactly regeneration output (single file, four canonical insertions, test target, deterministic ID style) and the gate log records xcodegen regenerating the project in the same build; I did not re-run xcodegen myself because that would rewrite the project file (read-only constraint).

## Rationale

GO. The binding task's four Gherkin scenarios each have tests that observe the real session/store rather than a mock of it; the leaf state machine is total over the shipped `Status` API; §17's order, the no-credential posture, the no-log posture and the no-catalog-delta constraint all verify by direct reading of code and `git diff`; both gate runs reproduce exactly (66/0 and 140/0 from parsed xcresults, with the log-safety gate and its 24/12 fixtures green inside the build); and the one red test in the 11-class run is provably pre-existing on the branch base, not a regression from this branch. The deviations are small, well-reasoned, and all recorded; the two MINOR items are notes/design-doc bookkeeping (one owed annotation before owner copy sign-off) and do not affect the shipped artifact. Confidence 0.92 — the residual 0.08 is the unreproducible-at-unit-level rendered accessibility behavior (DV-5) and normal acceptance uncertainty, not any observed defect.

---

## Post-review driver remediation (2026-10-07, main session)

Applied before the wave commit, per the review's actionable items:

1. **[N-1] applied — notes glyph-table fix.** `specs/T-120-notes.md` D1 table: `.linking` icon corrected to `ellipsis.circle`, `.linkedPremium`/`.linkedFree` to `checkmark.circle.fill` (matching the shipped `SpotifySettingsLeafState.statusIcon`, `SettingsView.swift:1065-1072`), with a bracketed W6-review correction marker under the table.
2. **[N-2] applied — §31 privacy-row closure annotation.** `specs/design-l2.md` §31's `spotifySettings.privacy` row now carries the M-2-amended copy exactly as shipped in `Localizable.xcstrings` (en "What you ask for — including play commands — is sent to Spotify to find music and control playback; no other app data is sent."; ne "गीत खोज्न र बजाउन तपाईंले भन्नुभएको कुरा — बजाउने आदेश सहित — स्पोटिफाइमा पठाइन्छ; अरू कुनै डेटा पठाइँदैन।") plus the closure annotation naming the original sentence, the M-2 requirement (`security-design-review.md:121`) and the sign-off precondition.
3. **[N-3] no action** — accepted as recorded (design pins no per-state card glyph; the glyph is decorative and accessibility-hidden; the tested contract is the status line + action).

Remediation is notes-only + design-doc-only; no Swift, catalog, manual or test file was touched, so both gate runs (`66/0`, `140/0`) stand for the committed revision.

Reviewed revision ≡ committed revision modulo the above remediation.
