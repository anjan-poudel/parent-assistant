# Review — L2 Component Design (Profile Interview + Address-as)

**Task:** `review-l2` (contract `review_report`) · **Agent:** `reviewer` (direct dispatch)
**Artifact under review:** `specs/design-l2.md` (1,203 lines, contract `component_design_l2`)
**Feature:** `profile-interview` · worktree branch `worktree-...-profile-interview` · 2026-10-05
**Workflow exit condition:** `review.decision == GO`.

**Inputs.** The artifact; `specs/design-l1.md` (C01–C12, ADR-01…ADR-11, hand-off §16, hooks §17);
`specs/profile-interview/constitution.md` (Field Contract, Address-as Behaviour Contract, Feature
Constraints 1–8, OD-F1…OD-F3, OD-PI-4 / OD-PI-5); the project `constitution.md` (Standards,
Architecture Constraints, release gates); `specs/define-requirements.lock.yaml` and all 16 FR-PI /
11 NFR-PI requirement files; `specs/profile-interview/workflow.yaml`. This review is read-only —
no artifact under review was modified.

**Verification method.** Beyond the documentary review, the design's claims about shipped code were
checked by reading that code (25+ spots, listed below), and the central budget measurements were
reproduced independently rather than taken on trust.

- Code claims verified: `OnboardingState.swift` (4-case `Step` enum; `status(of:)` ignoring unknown
  raw values via `flatMap`; `pendingSteps` / `firstPendingStep`); `OnboardingWizardView.swift`
  (`startingAt:` init at line 18; the four-case `stepContent`; `finishOnboarding()` calls
  `coordinator.start()`); `ContentView.swift` (wizard/Home branch; the `XCTestConfigurationFilePath`
  boot guard at line 27); `HomeView.swift` (`showWizard` fullScreenCover reading
  `firstPendingStep` at 208–209; reminder-card `onResumeSetup` at 372); `IntentPrompt.swift` (the
  three clause anchors at lines 99 / 185 / 249; `pluginSections` returning `""` when empty); the
  two `InterpreterContext(` construction sites (`CommandRouter.swift:1412`,
  `AppCoordinator.swift:3601`); `VoicePipeline.swift` (`handleWakeDetected` 714, guard +
  `captureGeneration` epoch 723–729, `simulateWakeWordDetection()` routing through the same
  handler 492–494); `Speaker.swift` (non-throwing `speak(_:locale:) async`; `PiperVoiceSpeaker`);
  coordinator `noteSpeakingStarted` / `noteSpeakingEnded`; `suspendForSampleCapture()` returning
  `true` with no live pipeline (10958–10959); `addFamilyContact` / `updateFamilyContact` carrying
  `isEmergencyContact` (6029 / 6080); `preferredEmergencyContact` first-flagged rule (6249–6251);
  the storage chain (`RawEncryptedStorage`; `EncryptedLocalStorage` typed write/read/delete;
  `MigratingEncryptedStorage` read precedence snapshot → files → Keychain + migration;
  `EncryptedFileStorage.url(for:)` nil root; Envelope {key, payload}; sha256 file naming;
  `.atomic` + `.completeFileProtection` + excluded-from-backup; `StoragePlacementPolicy`);
  `LogSanitiser` (`outcome` / `error_code` / `duration_ms` allow-listed; redaction applied before
  the allow-list filter); `check-release-log-safety.py` `FEATURE_ROOTS` (line 141); `L10n.str` /
  `L10n.fmt`; the planned `wakeAck` / `onboarding.aboutYou` / `profile.*` keys absent from the
  catalog; `SettingsTabMappingTests` visible-row count 20 (line 56).
- Budget proof independently reproduced: the `build()` literal was extracted from
  `IntentPrompt.swift` with Swift multiline-literal semantics (dedent by the closing delimiter;
  the blank line before the close yields one trailing `\n` — verified by compiling the shape),
  the fixture values substituted (`ne`, `(none)`, the weather transcript) and counted by the Swift
  compiler: **2,506 Characters / 2,718 UTF-8 bytes**, matching the design's measured table exactly.
  Template with placeholder tokens: **2,698 bytes** (matches). The seed file under
  `tools/train-intent` measures **2,699 bytes ending `request.\n\n`** (matches §13 item 3).

## Summary

**All seven checklist items pass; no blocking findings. The design is cleared to feed
`security-design-review`.**

### 1. Explicit error return types — PASS

Every interface in §5 declares its failure surface explicitly; nothing returns `any Error` or an
`unknown`-style placeholder (the design states this at §5, lines 372–374, and the claim holds).

- `UserProfileStoring.load() -> ProfileLoadResult` (enum carries `ProfileStoreError`) and
  `save(_:) -> Result<Void, ProfileStoreError>` — §5.1, lines 421–429.
- `ProfilePayloadStorage.readRawData(key:) -> Data?` / `hasPayload(key:) -> Bool?` — the optionals
  are explicitly documented tri-state semantics ("`nil` = unknowable… Never read as absent",
  lines 413–418); the absent-vs-unreadable discrimination is completed by the exhaustive
  load-state mapping table (§5.1, lines 472–484), which assigns every probe/read/decode outcome a
  defined route. Argued explicitly, as the checklist permits.
- `guarded(_:) -> String?` — nil semantics documented per case (§5.3, lines 617–633) with the
  drop route argued in C07 Errors (line 210: quarantine event + un-personalized turn).
- `WakeAcknowledging.begin/cancel` — no error return, argued: "No thrown errors; failures are the
  synchronous fallback completion plus a content-free event" (line 175), with the full failure
  mapping in the §7.1 state-machine table.
- `coldStartInterviewRoute() -> OnboardingState.Step?` — argued: "No error return: every failure
  mode has a defined route (C13's edge table) — the method never throws" (§5.8, lines 823–828).
- `saveProfile(...) -> Result<Void, ProfileStoreError>`; `currentProfileSnapshot() ->
  ProfileLoadResult` (§5.6, lines 779–788); `phrase(...) -> String?` nil-route documented (§5.4,
  lines 690–694); pure helpers (`clamped`, `merged(into:)`, `isComplete`, `terms(for:)`) have no
  failure mode.

### 2. Async/external calls: failure modes and named timeouts — PASS

- The one added async call is `Speaker.speak` from the ack service; its bound is the named
  configurable `wakeAckMaxHoldSeconds` (default 2.5, declared in the service init, wired in
  `AppCoordinator.start()` — §8 table, lines 975–976). Silent synthesis death is explicitly mapped
  to the timeout path (§7.1 note, lines 902–906). Recovery is documented: playback end, timer,
  failure or cancel all reach the single `settle` exit (line 900); worst case is today's silent
  start (E5/E6, §7.2).
- The store adds no async call and no timeout — argued, not omitted: synchronous local-disk I/O
  behind its lock, no network (§8, lines 983–986).
- The enrollment session keeps the existing mechanism with no new timeout (§8, line 986) — absence
  justified by the call-site-only contract (C12, NFR-PI-009).
- C13 adds no async call and no timeout — a single synchronous cached read, argued at §5.8
  (line 824) and §8 (lines 988–990).

### 3. Traceability — PASS (claims 16/16 FR + 11/11 NFR; spot-checks verified)

§11 (lines 1079–1104) claims coverage of 16/16 FR-PI and 11/11 NFR-PI. All 16 FR and 11 NFR ids
are present in the table; no id in the lock file is missing. Spot-checks against the actual
sections:

- **FR-PI-016 → C13 / §5.8**: the route rule (lines 333–339), the seven-row edge table (341–351),
  the shell wiring (353–367) and the §5.8 signature match the requirement: routing at the first
  pending step via the existing `pendingSteps`/`firstPendingStep`, mandatory-missing hard route to
  the earlier of the first pending step and About-you, optional-pending route with the soft-skip,
  complete → nil, failure → defined route.
- **FR-PI-002 / FR-PI-004 → §5.2**: `AboutYouDraft.isComplete` = trimmed non-empty name AND
  address-as (line 519–520); Skip stays, every step skippable (lines 498–501). Matches FR-PI-002's
  Next gate and FR-PI-004's skippable/pending pattern.
- **FR-PI-003 / FR-PI-015 → §5.1**: the load-state mapping table (472–484) is exhaustive;
  absent vs unreadable is real (the probe, 445–470); corrupt payload discarded, never retried in a
  loop, never partially applied, no placeholder — matches FR-PI-015's three scenarios.
- **FR-PI-008 / FR-PI-010 + NFR-PI-008 → §7.1 / §5.4**: phrase composition speaks the term
  verbatim inside a localized template (lines 690–694); the state machine gives the bounded hold
  and the fallback to today's silent start (886–906).
- **NFR-PI-005 → §9.1 / §9.2**: the measured budget proof (2,506 + 80 = 2,586 ≤ 3,000, headroom
  414; lines 996–1011) and the seed-mirror gate (1013–1030) — independently reproduced (above).

### 4. User/operator-visible behaviour — PASS

The overview carries an operator/user-visible summary (lines 74–81), and §7.5 (lines 955–965)
tabulates success and failure for every flow: About-you Next, emergency step, fingerprint,
Settings save, wake with term, store unreadable, and cold-start routing ("corrupt/unreadable
state → wizard from the first pending step; still skippable; no crash or stall"). §7.2 gives the
per-error user view and the content-free operator event. The route outcome itself is described
where the user meets it.

### 5. FR-PI-016 coverage — PASS (all six sub-items)

- **Existing resume mechanism, no new state**: "No new persisted state"; the resume is
  `OnboardingState.pendingSteps` / `firstPendingStep` + the wizard's `startingAt:` reopen
  (lines 302–304, 333, 355); the only addition is a shell `@State` one-shot (line 364). Verified
  against the shipped code: the mechanics and the `startingAt:` init exist as claimed.
- **Mandatory-missing hard route**: "The mandatory-missing route is a hard route on start"
  (line 338); edge row "Mandatory missing while About-you is marked completed" → `.aboutYou`
  (line 349); test pinned in §12 (`ColdStartRoutingTests`, line 1124).
- **Optional-pending route with the OD-F3 soft-skip preserved**: edge row at line 348 ("the
  soft-skip preserved, never trapped"); the route rule keeps the ADR-04 soft gate (lines 337–339).
- **Complete → no routing**: edge row "Interview complete" → none (line 347).
- **Corrupt/unreadable → no crash, stall, loop or trap**: edge row "Status map corrupt" reads as
  nothing recorded and routes without crash/stall/loop (line 350); E8 and §7.5 state the same;
  the routing read is a single synchronous evaluation (line 323) with no polling (§9.4, line 1055).
- **Background→foreground decision made and documented**: cold start only, no foreground re-check
  in v1, with the interruption rationale and revisit conditions (C13 Decision, lines 324–330;
  §8, line 990; §15, lines 1202–1203). This settles FR-PI-016's left-open question.

### 6. Consistency with L1 and the resolved open decisions — PASS

- **C13 is the single addition**, recorded under the 2026-10-05 owner amendment (FR-PI-016,
  Feature Constraint 8): scope statement (lines 298–304) and §13 item 6 (1155–1159), which records
  that the amendment supersedes the L1 §4.1 sentence for the app-start path while the
  `pendingSteps` / `firstPendingStep` / `startingAt:` mechanism stands — exactly the owner-recorded
  supersession this review is instructed to accept.
- **OD-F1** carried as ADR-02: C11 and §5.2 use the existing `isEmergencyContact` designation,
  no standalone next-of-kin field (lines 266–280); verified against the shipped coordinator APIs.
- **OD-F2** carried as ADR-06: on-demand TTS through the existing `Speaker`, localized template +
  term-as-data, not the pre-rendered AckFastLane cache (C05 / §5.4); the base-speaker wiring
  avoids double bookkeeping (§6, lines 876–880).
- **OD-F3** carried as ADR-04: Next gated, header Skip stays (soft gate) — §5.2, C13.
- **OD-PI-4**: chips + custom field via `AddressAsPresets` + free text (C03, §5.2).
- **OD-PI-5**: plain Settings editor, no new auth (C04, lines 144–158; §5.7).
- L1 §16 hand-off items all have settlements (front table, lines 52–61); §13 corrections 1–5 are
  evidenced (item 1's Swift semantics are accurate: a `let` property with a default is omitted
  from the synthesized memberwise init, so L1's sketch could not be set). L1's interface sketches
  are refined only within the announced hand-offs.

### 7. Scope — PASS

No out-of-scope elements: zero new egress (only the guarded term enters existing prompt paths,
§9.4 lines 1043–1055; NFR-PI-003 row); no new permissions and `Info.plist` untouched (line 1052);
wake-word recognition untouched — the diff is a seam property and a body extraction in
`VoicePipeline` (§5.4, lines 700–726); the fingerprint step is a call site only (C12); no forced
address-as — the clause says "never every sentence" (§5.5, line 752) and R9 keeps the per-turn
fallback non-punitive. No new components beyond C13; no persistence schema beyond the new store
key and the step enum.

### Independent corroboration of the measured facts

The design's central NFR-PI-005 evidence was reproduced from the shipped source, not accepted on
assertion: extracted `build()` literal + Swift compiler count → **2,506 Characters / 2,718 UTF-8
bytes** (design: 2,506 / 2,718); placeholder template **2,698 bytes** (design: 2,698); seed file
**2,699 bytes** ending `request.\n\n` (design §13 item 3: 2,699, `request.\n\n`). The clause
arithmetic (56 static + 24 term = 80; 2,586 ≤ 3,000; headroom 414) is correct. The 18-byte
`{address_as_clause}` placeholder and the net 2,716-byte seed figure are arithmetically
consistent (2,699 − 1 + 18 = 2,716).

### Observations (non-blocking; no rework required)

- **OB-1.** L1's `WakeAcknowledging` docstring says "always calls `completion` exactly once";
  §5.4/§7.1 refine this for the `cancel()` path (completion dropped when stale by definition).
  The refinement is documented in place and sits inside the L2 state-machine hand-off, but it is
  not listed in §13's corrections table. A one-line §13 entry at the next touch would keep the
  table exhaustive.
- **OB-2.** The wizard merge base when the snapshot is `.absent` / `.unreadable` (the
  `merged(into: base)` helpers take a non-optional `UserProfile`) is implied — an empty record —
  but not spelled out; C13's edge table relies on the ordinary Next-and-save gate repairing the
  record (line 349). Worth one clarifying clause at implementation time.
- **OB-3.** FR-PI-013's requirement file still carries its "No force-migration" scenario text
  unannotated; the supersession for the app-start path is recorded in FR-PI-016's file and in
  design-l2 §11/§13. Accepted, owner-recorded; an annotation on FR-PI-013 when the set is next
  touched would remove the residual text.
- **OB-4.** §9.2's phrasing "byte-identical to the pre-feature rendered prompt" is loose (it
  refers to the rendered/seed equivalence); the enforceable contract (gate byte equality between
  the extracted template and the seed) and the arithmetic are correct.
- **OB-5.** OD-A1 (device-measured ack latency vs the 1 s activation budget) and OD-A2 (English
  ack copy, owner eyeball) are correctly carried as evidence/eyeball items to
  `implement` / `security-test` and the owner (§15), not as design gaps.

## Decision

decision: GO

**Rationale.** The L2 component design is a faithful, buildable fold of the 16 FR / 11 NFR locked
set (including the FR-PI-016 owner amendment), with candidate-error-free interfaces, complete
failure/route documentation, verified traceability, an independently reproduced budget proof, and
no scope growth beyond the owner-authorised C13. All seven checklist items pass; the observations
above are refinements that can ride implementation or a later documentation touch — none blocks.
The feature proceeds to `security-design-review` (where its STRIDE focus areas are already
sharpened in §14) under the workflow exit condition `review.decision == GO`.
