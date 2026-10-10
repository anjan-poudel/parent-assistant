# Review — L2 Component Design (Spotify Music Integration)

**Task:** `review-l2` (contract `review_report`) · **Agent:** `reviewer`
**Artifacts under review (the design chain):** `specs/design-l1.md` (623 lines, contract `architecture_l1`)
and `specs/design-l2.md` (845 lines, contract `component_design_l2`)
**Feature:** `spotify-music-integration` · worktree `elderly-ai-assistant-spotify-music-integration`
(branch `feat/spotify-music-integration`)
**Workflow exit condition:** `review.decision == GO`.
**Inputs.** The two design artifacts; `specs/define-requirements.md` (17 FR-SP + 12 NFR-SP, Gherkin,
out-of-scope table); `specs/spotify-music-integration/constitution.md` (constraints 1–12, routing/degradation
contract, OD-S1…OD-S3, DV-1…DV-5, the 2026-10-06 amendment record); the project `constitution.md`
(Standards, Architecture Constraints, release gates, Agent Principles); `specs/spotify-music-integration/workflow.yaml`.
This review is read-only — no artifact under review was modified.

**Verification method.** Beyond the documentary review, the design’s claims about shipped code were checked
by reading that code (listed below), and the central measurements were reproduced independently rather than
taken on trust.

- Code claims verified (all held at the stated line/region unless a finding says otherwise):
  `CommandRouter.swift` — music stub at 2640 (`case .music:`), `command_music_stub` event at 2642,
  `router.musicStub` speech at 2643; tool seams 646–648 with nil-default init params; ladder sites
  898 / 1146 / 1189; `fireYouTubePlay` at 2386 (the keyless leg opens YouTube search); `logToolRequest`
  at ~2544 (nil store = no-op); `handlePluginCommand` at ~2922. `AppCoordinator.swift` — lazy stores
  1328–1360; plugin registration at ~2058; router construction 3704–3717; `topPresentingViewController()`
  as the presenter precedent. `YouTubePlugin.swift` — ids, prompt fragment, result shapes, nil
  presentation (the twin precedent). `VoiceContactSearchRoute.swift` — direct-call veto first, YouTube
  veto next (the insertion point), grapheme-cluster rules. `KeywordIntentRule.swift` — Domain set,
  rule-table shape, youtube keyword family (against L2 §14/§29). `SettingsTabs.swift` / `SettingsView.swift`
  — 21 visible rows, six hidden sheet rows (6 → 7 after the addition), `YouTubeSettingsView` at 768.
  `Localizable.xcstrings` — 1,341 keys, no `spotify*` keys yet, `router.musicStub` present; `App/L10n.swift`
  — `L10n.str` / `L10n.fmt` exist as the design uses them. `ToolLogReviewView.swift` — the kind → key
  mapping and the second exhaustive kind switch (see F-4). `GoldenCorpus.swift` — the 15-entry music
  block and the `>= 15` floor test. `IntentPrompt.swift` / `IntentPromptTests` — music wording already
  present; digest pins and the character baseline/ceiling exist. `check-release-log-safety.py` — the
  engine / feature / other role model with the rule scoping of F-2; per-rule fixtures present.
  `Info.plist` — no `spotify` scheme yet, one `CFBundleURLTypes` entry, a public-client-ID precedent.
  `StoragePlacement.swift` / `DependencyProtocols.swift` — the keychain-resident set and `StorageError`
  as §25 uses them.
- Measurements reproduced independently: YouTube plugin prompt fragment = **341 characters**; the L2 §27
  Spotify fragment text = **376 characters** (F-1). Golden music entries = **15** (F-3). Catalog keys =
  **1,341** (matches the L2’s stated baseline).

## Summary

**The design chain is cleared to feed `security-design-review`: no BLOCKER findings, one MAJOR (an
internal pin contradiction resolvable mechanically at implement), three MINOR and three NOTE items.**
All seven checklist items pass.

### 1. Explicit error return types — PASS

Every new interface declares its failure surface with concrete types; no `any`/`unknown`-style placeholder
crosses a component boundary. `SpotifyTool.FetchError` and `SpotifyTool.PlayError` (both `Error, Equatable`,
every case mapped to a matrix row), `SpotifyAuthError` (15 named cases covering configure / present /
cancel / redirect / state / provider / exchange / parse / verify / scope / refresh / revoke / storage /
network / presentation), `StorageError` for the store’s `Result<Void, StorageError>` returns, and
`Result<String, SpotifyAuthError>` from `validAccessToken()` and the callback parser. The JSON parsers
document their nil/throw semantics; the shapes mirror the shipped YouTube precedents.

### 2. Async/external calls: failure modes and recovery — PASS

Every network operation is single-shot with a named outcome: searches, play attempts, deep-link opens and
link flows have no implicit retry; the only automatic retry anywhere is the single token refresh per
request. Each failure class routes to a defined recovery — `invalid_grant` wipes and takes unlinked
treatment (row 10); transport-only refresh failure takes the search-failure shape (row 11); play 403/404/
network falls to the deep link (row 2); search empty/failed falls to YouTube where serveable, else the
honest line (rows 6/7); link failures store nothing (row 12). The 300-second link-flow timeout cancels
the seam into `.userCancelled`. No silent failure exists anywhere in the matrix — every row ends in
exactly one spoken line.

### 3. Timeouts and retry limits are configurable — PASS

All bounds are named parameters with injected defaults (§32): fetch timeout 8.0 s (`defaultFetchTimeoutSeconds`,
overridable at every call site), refresh attempts 1, capability staleness 3,600 s, link-flow timeout 300 s,
expiry skew 60 s, query caps 100. No timeout is a bare literal in the new code. The PKCE verifier/challenge
lengths are protocol-fixed, not tunable — a correct exclusion, argued in place.

### 4. Traceability — PASS (29/29)

All 17 FR-SP and 12 NFR-SP ids appear in the design-l2 traceability section mapped to components, seams,
tests and DV items; no unmapped requirement. Spot-checks against sections held: FR-SP-013 → §14 rule and
extractor fixtures; FR-SP-014 → §15 veto insertion (verified against the shipped veto site); FR-SP-016 →
§17/§31; FR-SP-017 → §23 DV protocol; NFR-SP-002 → §20/§28/§33; NFR-SP-008 → §24 grammar; NFR-SP-012 →
seams and diff-surface checks.

### 5. Operator-visible behaviour — PASS

The matrix describes what the user sees and hears in every state and failure mode (nine distinct spoken
outcomes across twelve rows, all honest, never the stub); the settings surface states linked/free/
not-linked/link-failed with the rollout note; DV-1…DV-7 (the constitution’s DV-1…DV-5 expanded with the
app-absent path and the console/sysdiagnose capture) record the device-visible acceptance.

### 6. Soundness claims — PASS (with the F-1 caveat)

Dormant-nil seams (`spotifyAccountSession`, `spotifyTransport`, `spotifyLinkOpener` defaulting nil) preserve
every pre-existing construction site and test, matching the verified 646–648 pattern and the 3704–3717
construction. L2-R1 (the keyless YouTube leg is not pre-opened when Spotify wins) is coherent with the
shipped keyless path. L2-R2 (link-time verification or scope failure stores nothing) matches state machine
A, where every failure transition is `record: none` and only a store-write failure leaves the prior record
unchanged. The golden-corpus supersession leaves the 15-entry music block unedited and the prompt digest
and baseline pins intact (dispatch-level supersession recorded in the music test suite). ADR-SP-15’s
tool-log contract is stricter than the YouTube precedent (empty query/response fields) and mechanical.

### 7. Scope and non-goals — PASS

No out-of-scope elements: read-only playback control (no library edits or mutations anywhere in the
interfaces), no backend, explicit-YouTube routing byte-identical (ladder ordering plus the rule-level
YouTube exclusion, ADR-SP-06), plugin isolation preserved (one plugin + three router seams), no
brain/router model-stack change, no cloud LLM on the music path, no new egress beyond the two providers.
Every component traces to an FR/NFR; no unspecified features found.

### Findings

| id | severity | finding | evidence | blocks GO? |
|---|---|---|---|---|
| F-1 | MAJOR | The plugin fragment’s size pin and its “exact text” contradict: the pin requires at-or-under the YouTube fragment’s size (341 chars measured), the §27 text is 376 chars — the pinned test cannot pass as written. | design-l2 §12, §22, §27 vs measured `YouTubePlugin.swift` fragment | No — mechanical, tripwired by its own pinned test; implement condition C-1 |
| F-2 | MINOR | “Rules 1–2 … apply to every file” misstates the verified gate: rule 1 is judged for every file, rule 2 for engine files only; rules 3–6 for feature roots. The operative `FEATURE_ROOTS` edit is correct as specified. | design-l2 §20 vs `check-release-log-safety.py` role model / judge call sites | No — doc precision; C-2 |
| F-3 | MINOR | The feature constitution says the golden music block has “16 utterances” at `GoldenCorpus.swift:142–157`; the block holds exactly 15 entries. design-l2 uses the correct 15 and keeps the floor test green. | `specs/spotify-music-integration/constitution.md` constraint 5 vs the corpus file | No — correct the count; C-3 |
| F-4 | MINOR | “The view file is not otherwise changed” / “one mapping case”: the tool-log view has a second exhaustive switch over `Kind` (the icon switch) with no default, so the new kind fails to compile until an icon case is added. | design-l2 §21, §30 vs `ToolLogReviewView.swift` lines 130–147 | No — compile-enforced, one line; C-4 |
| F-5 | NOTE | The design-l2 header self-describes Contract `design_l2`; the workflow state records `component_design_l2`. The path contract is honored. | design-l2 header vs workflow-state.json | No — cosmetic |
| F-6 | NOTE | Contact-veto residual: a contact whose name literally contains a full music marker (e.g. भजन) is no longer reachable via a search-marker utterance containing it; near-misses are protected by grapheme-cluster semantics. Deliberate trade-off under FR-SP-014. | design-l2 §15 vs `VoiceContactSearchRoute.swift` | No — accepted trade-off, recorded |
| F-7 | NOTE | `spotifySettings.removeConfirm` (“Music will use YouTube only.”) is slightly stronger than matrix row 8, which after unlink can still open the `spotify:search:` hand-off when YouTube is not serveable. Honest-line rules and DV-4 unaffected. | design-l2 §31 vs §13 row 8 | No — copy option |

**F-1 in full.** §12 pins the fragment “at or under the YouTube fragment’s size”; the §22/§27 test list pins
the assertion “length ≤ the YouTube fragment’s length”; §27 then fixes the “exact text”. Both cannot hold:
the YouTube fragment measures 341 characters, the §27 text measures 376. Resolve by trimming the §27 text
to ≤ 341 characters while keeping the required tokens (`spotify.play`, `query`) and the sentence routing
general music requests to the `music` intent (L2-D15); the length assertion is itself the tripwire. No
architecture, security or user-visible property depends on the exact wording.

### Independent corroboration of the measured facts

The design’s own size model was reproduced from the shipped source: the YouTube plugin’s prompt fragment
was extracted with Swift multiline-literal semantics (dedent by the closing delimiter) and counts 341
characters; the L2 §27 fragment text was extracted the same way and counts 376. The golden music block
holds exactly 15 entries against a `>= 15` floor test; the Localizable catalog holds exactly 1,341 keys
at this baseline; the release gate’s role model was read directly (engine prefix / feature prefix / other)
and the judge call sites confirm the rule scoping stated in F-2.

### Observations (non-blocking)

- The 1,024-token on-device context is untouched by construction: plugin fragments compose only on the
  cloud path, and the on-device path composes none — the design states this and the source confirms the
  composition site.
- The `sahayak-spotify://callback` constant is shared by the plist entry, the validator and the planned
  Dashboard registration; the single-constant contingency for Dashboard refusal is coherent and flagged
  to `security-design-review` by the design itself.
- The DV protocol artifact is planned at implement time with the LCT precedent on disk; the design does
  not pre-invent results.

## Decision

decision: GO

**Rationale.** The design chain covers all 29 requirements with verified traceability, honors the feature
constitution’s constraints 1–12 and its non-goals, resolves OD-S1 as a coherent PKCE-only public-client
flow (no secret anywhere, scopes at sign-in, exact-match callback validation, single-refresh bound, wipe
semantics coherent), and resolves OD-S3 as a total 12-row ladder with an honest spoken line in every state.
The security-relevant interfaces — URI grammar, callback validation, token lifecycle, log discipline, gate
roots — are sound and independently verified against the worktree source. All seven checklist items pass.
No BLOCKER findings; the one MAJOR item is an internal contradiction that is mechanical and tripwired by
its own pinned test, and the remaining items are documentation-, edit-list- and copy-level refinements.
This GO is conditioned on the items below.

### Conditions (implement)

1. **C-1 (from F-1):** trim the §27 fragment to ≤ 341 characters keeping the required tokens and the
   L2-D15 routing sentence, or re-derive the size assertion with the rationale recorded. The fragment-size
   assertion in the plugin test suite is the guard; without C-1 that test cannot pass.
2. **C-2 (from F-2):** correct the §20 sentence to the verified rule scope (rule 1 all files; rule 2
   engine-only; rules 3–6 feature roots).
3. **C-3 (from F-3):** correct the feature constitution’s golden-count sentence (or annotate it) to the
   code’s 15 entries.
4. **C-4 (from F-4):** add the icon case alongside the label case in the tool-log view (the edit list
   should name both switches).

### Carry-forwards (security-design-review)

1. **OAuth token lifecycle:** verify the PKCE-only resolution end-to-end (no secret in the repo or the app
   image), the scopes-at-sign-in set, exact-match callback validation, the single-refresh bound, and the
   second-401 / `invalid_grant` wipe paths and the unlink / no-remote-revoke stance.
2. **Redirect / scheme hijack:** assess the custom scheme interception residual against PKCE and state;
   confirm the Dashboard-acceptance contingency (one constant; the design’s marked gap 2).
3. **Deep-link / URI injection:** the base62-22 grammar, percent-encoding, scheme allowlist,
   titles-never-in-URIs, the hostile corpus, and the gate’s documented static-analysis limits where the
   design relies on runtime validation.
4. **Log sanitisation:** closed event vocabularies, empty metadata everywhere, the tool-log contract,
   the `FEATURE_ROOTS` additions, and the DV-7 console/sysdiagnose capture.
5. **Privacy disclosure:** the settings privacy copy against the actual data flow (music queries to
   Spotify; nothing else).
6. **OD-S2 owner inputs:** the Dashboard-owning account, the client-ID paste-in, test-user registration,
   the quota-extension filing, rollout-note copy approval, and the final-sign-off line.

Carried records, no action required for this gate: the keyless-YouTube dependency and the quota-window
recording, both marked in the design with revisit conditions.
