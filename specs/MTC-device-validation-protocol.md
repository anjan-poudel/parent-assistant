# Multi-turn conversation — device-validation protocol and record (T-143)

**Feature:** `multi-turn-conversation` · **Task:** T-143 (`TG-28 — Acceptance, Evidence and Device Protocol`) · **Component:** the FR-MTC-020 device-validation protocol-and-record artifact.
**Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation` · **Branch:** `feat/multi-turn-conversation` · **Authored at HEAD:** `cc065b07b9ae889041fec254f60ece942f1650be` ("Implement multi-turn-conversation W4: T-134, T-136") · **Date:** 2026-10-10.
**Governing requirements:** FR-MTC-020 (`specs/define-requirements/FR/FR-MTC-020-device-validation-completion-gate.md`), NFR-MTC-007 (`specs/define-requirements/NFR/NFR-MTC-007-sustained-multi-turn-stability.md`), NFR-MTC-012 (`specs/define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md`).
**Binding sources of record for the item wording:** the feature constitution's completion gate (`specs/multi-turn-conversation/constitution.md:111-119` — the DV-1…DV-5 table and the Phase 0 line); `specs/design-l1.md` §6 (`:197-209` — the DV paragraph at `:209` and the Phase 0 prerequisite); FR-MTC-020's description and Gherkin (`:9-42`); the T-143 task file (`specs/plan-tasks/tasks/TG-28-acceptance-evidence-and-device-protocol/T-143-device-validation-protocol.md`, 4 Gherkin scenarios and the DoD checklist).
**Format precedent:** `specs/SP-device-validation-protocol.md` (T-124) and the `specs/LCT-device-validation-protocol.md` → `specs/LCT-device-validation-results.md` pair. This file follows the SP shape (protocol + record merged into one artifact, because the plan records the outstanding smoke "as the first step of T-143, not as a task" — `specs/plan-tasks/plan.md:239-241`).

> **Headline, stated first because everything below depends on it: no device run has happened.**
> No physical device run was made available to this authoring work; the Phase 0 PR #156 device smoke is outstanding; no session of this feature has been driven on Anzaan. **Every DV item below is recorded as BLOCKED with the dependency that must clear it.** Nothing in this file is a device observation, and no simulator or unit-test run was used to fill any row — the feature's focused suites prove the wiring lives in the build (W4 wave gate 204/204, `specs/implement-notes.md` §3), but only a device run proves the dialogue works for the person holding the phone. The file is the protocol plus the empty record the owner fills in on the Anzaan reference device.

> **Deliverable versus gate (read together with the paragraph above).**
> This unit's **deliverable is this protocol and its record structure** — complete when this file exists with DV-1…DV-5, step zero and the record format, per the T-143 DoD. **Executing** the run is owner/device-dependent (T-143 metadata: "authoring is agent work; execution is owner/device-dependent") and does not happen in this authoring task. At the workflow's final review, a missing execution is an **open gate item** — final sign-off cannot pass while the record is empty or while any item is not PASS — **not a missing deliverable of this unit**.

---

## 1. Why this protocol exists, and what binds it

The feature gives Pip a one-deep dialogue frame: a short spoken clarifying probe (template text, on-device catalog), the user's spoken answer captured by name, index word, repetition or free-form correction, a deterministic merge into the pending command, and the merged command executed through the existing executor — with cancel, emergency precedence, strong-command barge-in and a silent 45 s expiry keeping the frame from ever trapping the user (`specs/multi-turn-conversation/constitution.md:11-16`, `design-l2.md` §21-§25). Unit tests prove the mechanisms; the device run proves the *dialogue* — a real microphone, a real 45 s wait, a real call placed mid-probe, a real sustained session on a 6 GB-class phone, and a real JetsamEvent pull afterwards.

What binds this protocol:

- **FR-MTC-020 — the completion gate.** The feature **must not** be considered done until the DV-* checklist is executed on the reference device (Anzaan) and recorded with the feature spec (`FR-MTC-020`:10); "each DV item is recorded as passed/failed with the evidence (log pulls, session notes) attached to the feature spec; **a failure blocks final sign-off until fixed and re-run — no silent waiver**" (`FR-MTC-020`:18). Its Gherkin adds the failing scenario verbatim: "Given any DV item fails (e.g. DV-5 shows a voice-stack jetsam kill) … Then the feature does not pass final sign-off / And the failure is fixed and the item re-run before sign-off proceeds" (`:37-42`).
- **NFR-MTC-007 — sustained stability, measurable.** "a sustained dialogue session (the DV scripted sequence, ≥ 10 consecutive dialogue turns including probe→answer pairs and one degraded-brain turn) on Anzaan produces **0 jetsam kills attributable to the voice stack**; a post-conversation JetsamEvent log pull is the evidence" (`NFR-MTC-007`:12); "if a jetsam occurs, the JetsamEvent log pull is recorded with the feature and the feature fails its completion gate (FR-MTC-020)" (`:15`).
- **NFR-MTC-012 — release discipline.** "final sign-off is T2 + HIL with the DV-* results recorded (FR-MTC-020)" (`NFR-MTC-012`:14); the pre-release device console check covers the dialogue paths; the release log-safety gate and the focused-suite discipline are build-side (already green; `specs/implement-notes.md` §3) and are not re-run here.
- **The Phase 0 prerequisite.** "**Phase 0 prerequisite.** PR #156 voice-OOM hardening is merged (`437631e`, 2026-10-10); its device smoke (conversation → no jetsam → pull JetsamEvent logs) is outstanding — that outstanding smoke is the Phase 0 prerequisite for this feature" (`constitution.md:79`); "Phase 0 prerequisite: the outstanding PR #156 device smoke — conversation → no jetsam → pull JetsamEvent logs — must be run as the Phase 0 gate" (`:119`). §3 is that gate, as step zero.
- **The design's DV paragraph** is the intermediate wording the constitution expands to; it names the forcing method for DV-4 and the exact barge-in utterance for DV-3 (`design-l1.md:209`, quoted verbatim per item in §6).
- **No automation substitutes.** These are device-only items. The simulator has no jetsam, no thermal state, no real call flow to Contacts/FaceTime, and no speaker/microphone path; its observations may not fill any row. Focused-suite and gate evidence from this worktree is recorded in `specs/implement-notes.md` and is the *supporting* evidence, never the DV item's own.
- **The workflow's final gate.** The workflow comment for `final-sign-off` (mirrored at `specs/multi-turn-conversation/workflow.yaml:179`) reads "DV-* device validation on Anzaan is part of the completion gate". §8 states the gate mechanics.

## 2. Environment and build identity

Recorded for reproducibility; a measurement without a device and a build is not reproducible. Values marked `[OWNER INPUT]` do not exist yet and are **not invented here** — a cell that has no value says so.

| Field | Value |
|---|---|
| Reference device | **the Anzaan reference device** (named by the feature constitution and FR-MTC-020). Recorded at 2026-10-10 in the voice-OOM investigation: iPhone 14 Pro Max, 6 GB class, iOS 26.6.2 beta 23G90 (`docs/2026-10-10-voice-oom-hardening-brief.md:5`); `[OWNER INPUT — confirm model, storage and the OS version actually installed at run time, e.g. Settings ▸ General ▸ About]` |
| Build configuration | **Release required for DV-5** ("a 6 GB-class reference device in Release configuration", NFR-MTC-007:19) and strongly preferred for every item — the project's pre-release device-check discipline is Release (`constitution.md` Release gates). A Debug observation is recorded **as Debug** and never satisfies DV-5. `[OWNER INPUT — the configuration actually installed]` |
| Build identity — commit | `[OWNER INPUT — git rev-parse HEAD in this worktree at build time]`. The authoring baseline (this file) is `cc065b07b9ae889041fec254f60ece942f1650be`; the tested build must be at least this commit |
| Build identity — bundle id / version | `[OWNER INPUT — the built app's CFBundleIdentifier and CFBundleVersion]`. Read them from the artifact, not from memory: the product was rebranded once already (the bundle-id drift that produced CoreDeviceError 10002 on Anzaan on 2026-10-10, `ios/device-install.sh:52-56`), and Anzaan has previously carried more than one installed build of the app |
| Build produced by | `[OWNER INPUT — e.g. cd ios && DEVELOPMENT_TEAM=<team> ./build.sh ipa (archives with -configuration Release, ios/build.sh:216-224), or an Xcode Product ▸ Archive]`. Note: the shipped `ios/device-install.sh` convenience script builds the **Debug** configuration (`Debug-iphoneos`); it may be used for launch/console convenience, but it is not the Release path for DV-5 and the configuration used must be recorded either way |
| Install method | `[OWNER INPUT — Xcode Devices / TestFlight / devicectl / device-install.sh; record it]` |
| Tester (holds the phone) | `[OWNER INPUT]` |
| App language under test | The sessions run in the owner's normal configuration — Nepali (`ne`) is the launch language (project constitution Architecture Constraint 6); probe copy exists in ne and en (`design-l2.md:717-741`). `[OWNER INPUT — record the app/device language actually set]` |
| Music providers at run time | `[OWNER INPUT — Spotify linked or not, YouTube keyed or keyless — DV-1's playback and the DV-5 script go through the existing music path, whose outcome set is the SP feature's]` |
| Console capture (optional for DV-4 evidence) | `[OWNER INPUT — method, e.g. xcrun devicectl device process launch --console --device <name> <bundle id>]`; if captured, only content-free event names/fields may be quoted into this record — §9 |

## 3. Step zero — the Phase 0 PR #156 device smoke (HARD PREREQUISITE)

**Status as of authoring: outstanding.** The code is merged; the device smoke is owed (`constitution.md:79`; `docs/multi-turn-conversation-feasibility.md:173`; `specs/plan-tasks/plan.md:239-241`). FR-MTC-020 carries it as its own acceptance scenario (`:31-35`): "Given PR #156's device smoke has not yet been run / When device validation is about to start / Then the smoke (conversation → no jetsam → JetsamEvent pull) is run and recorded first / And its result is attached to the feature record". The recorded merge gate it must satisfy is, verbatim (`specs/fix-summary.md:213-221`):

> 1. A real conversation turn (talk → ack → reply) with the explicit 4B pick active — **no jetsam kill**.
> 2. A fresh `JetsamEvent` log pull after the smoke, compared against the 2026-10-10 08:57/08:59 events.

The comparison baseline is the recorded pre-fix kill pair (2026-10-10 08:57:38 and 08:59:08, both `vm-pageshortage`; `docs/2026-10-10-voice-oom-hardening-brief.md:6`) plus, where present, the most recent pull taken before this session.

**Steps:**

1. **Install and launch the build** with the device's *explicit* brain pick active (the household's remembered pick — the smoke's whole point is the 4B pick being resident; the pressure ladder is allowed to step down if the device genuinely needs it, and if it does, that is recorded as an observation, not suppressed).
2. **Run one real conversation turn** end to end: user speaks → assistant ack → assistant reply. The turn must complete; the app must not be killed.
3. **Pull the JetsamEvent logs** after the turn. Record the exact pull method and the pull time. Pull routes (use the one that lists the files; the method actually used is what the record names): on-device Settings ▸ Privacy & Security ▸ Analytics & Improvements ▸ Analytics Data ▸ `JetsamEvent-*.ips` entries around the session window, exported; or the host-side devicectl file domain used for the 2026-10-10 investigation (`xcrun devicectl device info files --device <name> --domain-type systemCrashLogs`, then `xcrun devicectl device copy from --device <name> --domain-type systemCrashLogs --source <file> --destination <local-file>`; device unlocked).
4. **Compare** the pull against the 2026-10-10 08:57/08:59 baseline and any earlier pull: no new JetsamEvent naming the app (and none for the voice stack) after the smoke's start time.

**Pass criteria:** the conversation turn completes with the explicit brain pick active; no app kill; the fresh pull shows no new event for the app relative to the baseline; the pull and its method are recorded and attached (§7.2 session block, step-zero row).

**A failed step zero stops the session, without partial results.** If the smoke fails (a kill, a crash, or a new JetsamEvent for the app), **no DV item runs** and **no DV observation is recorded from that session** — not even a partial one — because every DV item below is measured against the PR #156 hardening, and a session that starts after a failed smoke measures an unsound base. The failure is recorded as the session's step-zero result (FAIL, with the pull attached); the DV items stay BLOCKED; the feature's gate stays blocked until the smoke passes on a fixed build and is re-run (FR-MTC-020's fix-and-re-run rule applies to step zero as it does to every item).

## 4. How to run this (owner procedure)

Written so a person holding the phone can execute it without this document's author present. Say every utterance **once per repetition**, wait for the spoken outcome, and touch the screen only where a step says so.

1. **Clear step zero (§3) first.** Do not start a DV session before it passes; a failed step zero stops the session with no partial results.
2. **Build and install the Release build** (§2). Fill the `[OWNER INPUT]` fields (commit, bundle id/version, configuration, install method).
3. **Run each item in §6 literally**, from its preconditions, in order — DV-1 through DV-5. Reset the state between items where the item says so (DV-1 starts from a cold start / no live frame).
4. **Write the results into a new session block in §7.2, in the same change** — one block per session for date, device, build, step-zero result, the per-item rows (transcript, outcome, evidence) and the JetsamEvent pull attachment. The protocol text of §6 is **not** edited to match results (recording rule 4, §10). Keep the keys of §9's capture discipline.
5. **A failed (or blocked) item stays recorded as failing/blocked.** Fix the build, re-run that item on the fixed build, and record the fixed-build identity in the re-run's session block. Only a PASS closes an item; the feature is not declared done while any item is unmet (§8).
6. **After the session:** keep this file as the record; the final sign-off step (§8) consumes it — the T2 human gate cannot pass while the record is empty or any item is not PASS.

## 5. Record fields (defined per item; the format the owner fills)

For every session (§7.2), one appended block carrying:

- **Session-level fields** (they qualify every item row in the block): **date**, **device** (model + OS), **build** (commit + `CFBundleIdentifier`/`CFBundleVersion` + configuration), the **step-zero result** with its pull reference.
- **Per-item fields**, one row per DV item:
  - **Transcript** — the **dialogue transcript**: the turn script (the fixture utterances actually spoken, or an equivalent description) with the observed outcome beside each turn.
  - **Outcome** — PASS / FAIL / BLOCKED, and the observed outcome itself: line keys heard, the capture form, whether sound started, the pill state, etc.
  - **Evidence** — the pointer (line key, event name, pill label, count, yes/no) and, for DV-5, the pull.
- **The JetsamEvent pull attachment** (session-level): the pull's path/attachment, method, time, and the comparison against the baseline.
- **Notes / deviations / tester.**

**Status vocabulary:** **PASS** / **FAIL** (BLOCKED stays only for an item whose dependency is still unmet at run time, with the dependency named). No other value is valid; no value is written before the observation exists. **Only PASS closes an item** — FAIL and BLOCKED both hold the completion gate (§8).

## 6. The DV items (the protocol)

Each item below carries its **verbatim item text** from the three binding sources (feature constitution `:113-117`; design-l1 §6 `:209`; FR-MTC-020 `:12-16`) — not paraphrased — then preconditions, steps, pass criteria, evidence. Line keys name shipped catalog values (`ios/ElderlyAssistant/Resources/Localizable.xcstrings`, the 17 `dialogue.*` keys of `design-l2.md:717-741`). Record a **line key**, never a transcript of audio or console content (§9).

### DV-1 — probe → answer → correct playback (the bhajan example)

- **Item text (verbatim, feature constitution):** "DV-1 — probe → answer → correct playback (the bhajan example)."
- **Item text (verbatim, design-l1 §6):** "DV-1 probe → answer → correct playback (the bhajan example, one shot, owner-path)."
- **Item text (verbatim, FR-MTC-020):** **DV-1 — probe → answer → correct playback** (the owner's bhajan example): "play bhajans" → probe → "dasain durga bhajans" → dasain durga bhajan playback.
- **Source of record:** constitution DV-1; design-l1 §6; FR-MTC-020; FR-MTC-002/003/006 (mechanisms); the owner's example (`constitution.md:9`, `docs/multi-turn-conversation-feasibility.md`).
- **Preconditions:** step zero passed (§3); Release build installed (§2); the device in its normal configuration; music providers in a state where a music command can play (record which provider is configured — `[OWNER INPUT]`); **no live dialogue frame** — start from a cold start (no probe asked since launch), so the first utterance of the item is also the frame's first utterance.
- **Steps (one shot — the first answer counts):**
  1. Confirm no probe has been asked since launch.
  2. Say **'भजन बजाऊ'**.
  3. Listen: the expected outcome is the **slotFill probe** on that same turn — `dialogue.probe.bhajanKind` ("कस्तो भजन? %@ … वा आफैँ भन्नुहोस्") naming the bhajan-kind options (शिव / दुर्गा / विष्णु / देवी — `dialogue.option.bhajan.*`) plus the always-offered default (`dialogue.option.anyPlay`, "जे पनि बजाऊ"). Nothing plays yet; no dead-end line. Record the labels heard and the count.
  4. Answer **once, free-form**, with the owner's example: **'दशैं दुर्गा भजन'** (the free-form capture — the design's pinned merge vector V4; do not repeat the answer and do not fall back to an option name).
  5. Observe the execution: the merged command dispatches through the existing music path (the same path a directly spoken music request uses) — sound starts at the dasain-durga content, or the music path speaks its existing honest outcome line for that query. Record which provider served, and "title heard: yes/no" — never the title itself (§9).
- **Pass criteria:** the probe is heard on the probe turn, decided with no model or network wait (template text + on-device catalog; NFR-MTC-001); the first answer is captured free-form; the merged command executes through the ordinary music path **on the first answer** — no re-probe, no "didn't understand", no literal top-hit guess; the dasain-durga bhajan (or the honest music-path outcome for that query) results; no stuck state — after execution the frame is gone (an unrelated following utterance is treated fresh); no crash.
- **Fail criteria:** no probe (a dead-end or a guess); a re-probe or an "understood: no" line after the first answer; the answer not carried into the execution (the literal top search hit plays instead); silence; a stuck state (the next utterance consumed as an answer); a crash.
- **Evidence to capture:** the probe line key(s) and labels heard; the answer's capture form (free-form); the execution outcome line key / the provider app that served; title heard yes/no; time from answer to outcome; optionally the content-free `dialogue_probe_spoken` / `dialogue_answer` event names if the console was captured (NFR-MTC-004 vocabularies).
- **Record as:** the DV-1 row of the session block (§7.2).

### DV-2 — timeout: 45 s expiry drops the frame silently and re-arms

- **Item text (verbatim, feature constitution):** "DV-2 — timeout: 45 s expiry drops the frame silently and re-arms."
- **Item text (verbatim, design-l1 §6):** "DV-2 timeout: 45 s expiry drops silently, next utterance is a fresh command."
- **Item text (verbatim, FR-MTC-020):** "**DV-2 — timeout**: 45 s expiry drops the frame silently and re-arms; the next utterance is a fresh command."
- **Source of record:** constitution DV-2; design-l1 §6; FR-MTC-020; FR-MTC-013 (silent expiry and re-arm); `design-l2.md` §25/§27 (the 45 s is the existing confirmation timer value, one source; the slot timeout is silent by design — the `dialogue.timeout` key is deliberately absent, `design-l2.md:740`).
- **Preconditions:** step zero passed; the build from §2; a clock or stopwatch to time the ~45 s; a candidate fresh command for step 4.
- **Steps:**
  1. Arm the probe: say **'भजन बजाऊ'**; wait for the probe; **do not answer**.
  2. Wait past the deadline without speaking and without touching the Talk control (a stopwatch from the moment the probe ends; past 45 s).
  3. Listen at and after expiry: **silence** — no spoken timeout notice, no re-ask, no continuation of the question.
  4. **Without relaunching the app**, say the fresh command **'गीत चलाऊ'**. This utterance is chosen because it also discriminates: a surviving frame would consume it as a degenerate answer (visible as a re-probe or an "understood: no" line), whereas a properly re-armed session runs the ordinary music flow.
- **Pass criteria:** silence at expiry (no line heard from the moment of expiry onward); no automatic re-probe; the next utterance is processed **as a fresh command** — it executes through its normal single-turn path (here: the music flow), is not consumed as an answer, and provokes no dialogue question; no stuck state, and the 60 s voice watchdog is never reached by the dialogue (the window state is never `.listening`, NFR-MTC-001).
- **Fail criteria:** a spoken timeout line; a re-ask at or after expiry; the next utterance consumed as an answer / answered with a re-probe / executed with the dead frame's defaults; a stuck session (watchdog recovery as the only way out).
- **Evidence to capture:** elapsed time at which the owner stopped waiting (stopwatch, from probe end); "no line heard at expiry: yes/no"; the next utterance's outcome line key; the discriminating observation for step 4.
- **Record as:** the DV-2 row of the session block (§7.2).

### DV-3 — barge-in: "मेरो छोरालाई फोन गर" mid-probe

- **Item text (verbatim, feature constitution):** "DV-3 — barge-in: a strong new command mid-frame executes and drops the frame."
- **Item text (verbatim, design-l1 §6):** DV-3 barge-in: "मेरो छोरालाई फोन गर" mid-probe places the call (its normal confirmation runs) with no residual frame.
- **Item text (verbatim, FR-MTC-020):** "**DV-3 — barge-in**: a strong new command mid-frame executes and drops the frame."
- **Source of record:** constitution DV-3; design-l1 §6 (the exact utterance); FR-MTC-020; FR-MTC-012 (the strong-predicate barge-in); `design-l2.md` §22 `V12` (the same utterance pinned as `.bargeIn`); the feature constitution's barge-in rule (`constitution.md:56`).
- **Preconditions:** step zero passed; the build from §2; a nominated family contact configured so the call command resolves (the "son" contact — `[OWNER INPUT — which configured contact the phrase resolves to]`); the call flow's normal confirmation runs as it always does (the owner may confirm or cancel it — cancel with the normal "होइन" — and records which; the item is about the frame, not the call).
- **Steps:**
  1. Arm the probe: say **'भजन बजाऊ'**; wait for the probe.
  2. Mid-window (before the 45 s), say **'मेरो छोरालाई फोन गर'**.
  3. Observe: the call flow starts and **its normal confirmation runs** — the same confirmation the same phrase produces with no dialogue frame anywhere. No probe re-ask; no answer-capture behaviour on this utterance.
  4. Resolve the call flow normally (confirm or cancel). Then verify **no residual frame**: say the fresh-command discriminator **'गीत चलाऊ'** — with no frame live it runs the ordinary music flow; a residual frame would consume it as a degenerate answer (visible as a re-probe).
- **Pass criteria:** the barge-in utterance drops the frame and executes the new command through its own normal tiers (the call's confirmation runs); no residual frame after the call flow — the next utterance behaves freshly (no re-probe, no answer consumption); no crash.
- **Fail criteria:** the call utterance consumed as a probe answer (re-probe / "understood: no" / the frame executes music instead); the call flow skipping its normal confirmation; a residual frame (the next utterance consumed or answered with a re-probe); a crash.
- **Evidence to capture:** the call flow's line keys heard (whether the normal confirmation ran); whether the call was confirmed or cancelled; the step-4 discriminator's outcome line key; optionally the `dialogue_frame_resolved` event name with outcome `bargedIn` if the console was captured.
- **Record as:** the DV-3 row of the session block (§7.2).

### DV-4 — mid-dialogue degraded-brain turn: the deterministic merge carries the dialogue

- **Item text (verbatim, feature constitution):** "DV-4 — mid-dialogue degraded-brain turn: the deterministic merge carries the dialogue."
- **Item text (verbatim, design-l1 §6):** "DV-4 mid-dialogue degraded-brain turn: force the pressure pick (or unload), answer the probe; the deterministic merge carries the dialogue."
- **Item text (verbatim, FR-MTC-020):** "**DV-4 — mid-dialogue degraded-brain turn**: the deterministic merge carries the dialogue when the brain is degraded/absent."
- **Source of record:** constitution DV-4; design-l1 §6; FR-MTC-020; FR-MTC-006 (the merge never needs the brain); NFR-MTC-005 (degraded-brain deterministic path); the PR #156 mechanism (`docs/2026-10-10-voice-oom-hardening-brief.md:132`, `specs/fix-summary.md` §3).
- **Preconditions:** step zero passed; the build from §2; the design's forcing route chosen **and its effect observed** (below); an armed probe.
- **Force the degradation — one of the two routes the design names; record which was used and how it was confirmed in force:**
  - **(a) force the pressure pick.** The per-turn pick resolves at the top of every turn from the live memory-pressure signal and available process memory (`AppCoordinator.applyPressureBrainPickForTurn`), so the owner forces it by bringing the device into genuine pressure — memory-heavy apps opened alongside the assistant until the system clamps — and **the confirmation is the degraded-mode pill** (`home.degradedMode.pill`): `home.degradedMode.smallerBrain` when the pick steps down, `home.degradedMode.lightweight` when nothing installed fits. If the console is captured, the content-free `pressure_brain_pick` event confirms the same.
  - **(b) unload / lightweight.** The `.lightweight` pick drops the resident brain handle so that turn's router answers from its deterministic path — the same pill label (`home.degradedMode.lightweight`) is the observation.
  - **Honesty rule:** the degraded state must be **observed in force for the answer turn** (pill state recorded, and/or the console event). If it cannot be produced on the day, the item is recorded **BLOCKED with that dependency named** — never marked pass on a healthy-brain run, and never marked pass on the strength of the design's structural argument alone.
- **Steps:**
  1. Arm the probe: say **'भजन बजाऊ'**; wait for the probe.
  2. Force the degradation by (a) or (b); **confirm it in force** (pill label and/or console event). Do not proceed until the confirmation exists.
  3. While the degradation is in force, answer the probe **once** (the owner's choice of capture form — name, index word, repetition or free-form; record which).
  4. Observe: the answer turn is carried by the **deterministic merge** — the answer resolves and the merged command executes through the music path exactly as in DV-1; no brain-generated text appears anywhere; no dead-end line that would indicate the dialogue needed the brain.
  5. Optional stronger variant (record if run): with the brain absent (route b), re-run DV-1's steps end to end — the full dialogue completes with no brain involved.
- **Pass criteria:** the degradation was observed in force for the answer turn (evidence recorded); the probe→answer→execute sequence completes **without the brain** — the merge carries it, the merged command executes through the ordinary executor, and nothing on the dialogue path gated on the brain; no crash; no stuck state.
- **Fail criteria:** no degradation in force (an unmet precondition — record BLOCKED, do not pass); the answer turn failing without the brain (a dead-end line, no merge, no execution); a re-probe caused by the brain being absent; a crash.
- **Evidence to capture:** which forcing route; the pill label observed (and its timing relative to the answer turn); the `pressure_brain_pick` event name if captured; the capture form of the answer; the execution outcome line key for the merged command.
- **Record as:** the DV-4 row of the session block (§7.2).

### DV-5 — sustained multi-turn without jetsam (post-conversation JetsamEvent log pull)

- **Item text (verbatim, feature constitution):** "DV-5 — sustained multi-turn without jetsam (post-conversation jetsam log pull)."
- **Item text (verbatim, design-l1 §6):** "DV-5 sustained multi-turn without jetsam (post-conversation JetsamEvent log pull, the PR #156 protocol)."
- **Item text (verbatim, FR-MTC-020):** "**DV-5 — sustained multi-turn without jetsam**: post-conversation JetsamEvent log pull shows no voice-stack kills (NFR-MTC-007)."
- **Measurable (verbatim, NFR-MTC-007):** "a sustained dialogue session (the DV scripted sequence, ≥ 10 consecutive dialogue turns including probe→answer pairs and one degraded-brain turn) on Anzaan produces **0 jetsam kills attributable to the voice stack**; a post-conversation JetsamEvent log pull is the evidence."
- **Source of record:** constitution DV-5; design-l1 §6; FR-MTC-020; NFR-MTC-007; the PR #156 protocol (`specs/fix-summary.md:213-221` — step zero's harness, reused here); NFR-MTC-001 (the envelope).
- **Preconditions:** step zero passed **and its pull available as the immediately previous pull** (this is why step zero is a hard prerequisite — its pull is the baseline the post-session pull is compared against, over and above the 2026-10-10 08:57/08:59 events); Release configuration (NFR-MTC-007); the device on charge or adequately charged for a sustained session; the build from §2; the owner ready to run the scripted session to its end.
- **Scripted session (the DV scripted sequence — ≥ 10 consecutive dialogue turns; this script is 12 and includes probe→answer pairs, all four capture forms, one degraded-brain turn and one cancel):**

  | # | Utterance | Expected behaviour (the item's script) |
  |---|---|---|
  | 1 | 'भजन बजाऊ' | slotFill probe spoken (`dialogue.probe.bhajanKind`) |
  | 2 | 'दुर्गा' | answer by **option name**; merged execution (provider serves) |
  | 3 | 'भजन बजाऊ' | probe again |
  | 4 | 'पहिलो' | answer by **index word** (the first option); merged execution |
  | 5 | 'भजन बजाऊ' | probe again |
  | 6 | 'दुर्गा भजन बजाऊ' | answer by **repetition** (scaffold stripped, catalog matched); merged execution |
  | 7 | 'भजन बजाऊ' | probe again |
  | 8 | 'दशैं दुर्गा भजन' | answer **free-form**; merged execution |
  | 9 | 'भजन बजाऊ' | probe again (arming the degraded turn) |
  | 10 | (answer) | the **degraded-brain turn** — force the degradation per DV-4's route, confirm it in force, answer once; the deterministic merge carries it |
  | 11 | 'गीत चलाऊ' | a normal single-turn music command between dialogues (freshness check inside the session) |
  | 12 | 'भजन बजाऊ' then 'होइन' | arm the probe, then **cancel** — `dialogue.cancelled` ("ठीक छ।"), nothing executes; trap-resistance inside the sustained run |

  The fixture utterances are the design's pinned material (V1-V4, V9; `design-l2.md:839-847`) plus the owner's example; record each turn's observed line key. Where the owner also wants a did-you-mean leg in the session, it runs as an extra turn — attempt it with an utterance the owner knows Pip does not understand; if no candidate probe fires on the day, record that observation and continue; the script above does not depend on it.
- **Steps:**
  1. **Note the pull baseline** (the step-zero pull and the 2026-10-10 08:57/08:59 events).
  2. Run the scripted session above, turns 1-12, in one sitting, without relaunching the app between turns.
  3. After the session, **pull the JetsamEvent logs** — the PR #156 protocol: the same pull route as §3 step 3, taken after the session's end; record the pull time and method.
  4. **Compare**: no new JetsamEvent naming the app (none for the voice stack) with a timestamp after the session start.
- **Pass criteria:** the scripted session completes without a crash; every turn behaves as its row states (or the run records the honest deviation with its line key); **the post-conversation pull shows no new event for the app** compared against the baseline; the pull is attached to the record; PR #156's policies remain in effect (the per-turn STT release and pressure-tiered picks are untouched by this feature — structural at design level, `design-l1.md` §16 and `design-l2.md` §4/§28; the device half of that claim is exactly this no-kill result).
- **Fail criteria:** any new JetsamEvent for the app after the session start (a voice-stack kill fails the item and blocks the completion gate — FR-MTC-020's failing scenario); a crash mid-session; the session aborted (record it; a partial session is not DV-5).
- **Evidence to capture:** the full session transcript (turn script and outcome line keys per turn); the post-session pull (path/attachment), its method and time, and the comparison result; session start/end times; whether the app was relaunched during the session (it must not be); the degraded-turn evidence from turn 10.
- **Record as:** the DV-5 row of the session block (§7.2), with the pull attachment at the session level.

## 7. Record (to be filled by the owner at run time)

**State as of authoring: no device run has occurred.** No session block exists below; every item is BLOCKED. The outcome vocabulary the owner writes when the run happens: **PASS** / **FAIL** / **BLOCKED** (BLOCKED only with the dependency named). No other value is valid; no value is written before the observation exists.

### 7.1 Environment and build identity (run record)

Fill §2's table in place — it is the single environment block for every session in this file. **Re-runs after a fix record their build identity in the re-run's session block** (device/OS follow §2 unless the re-run moved devices); §2 keeps the first run's identity, and the fixed-build session block is the record the completion claim rests on.

### 7.2 Session blocks (one per session, accumulated — copy the template)

<!-- TEMPLATE — copy for each session, fill, leave nothing blank (a field that has no value says so). -->

**Session 1 — [OWNER INPUT — date]**

- **Date:** `[OWNER INPUT]`
- **Device:** `[OWNER INPUT — model + OS version; "Anzaan" reference device]`
- **Build:** `[OWNER INPUT — commit + CFBundleIdentifier + CFBundleVersion + configuration]`
- **Step zero (§3):** `[OWNER INPUT — PASS/FAIL; pull reference; comparison vs baseline]`
- **Per-item results:**

| Item | Status (PASS / FAIL / BLOCKED) | Dialogue transcript (turns + observed outcome) | Evidence (line keys / event names / pill / counts / yes-no) |
|---|---|---|---|
| DV-1 — probe → answer → correct playback | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-2 — 45 s timeout: silent drop, fresh next command | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-3 — barge-in 'मेरो छोरालाई फोन गर' mid-probe | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-4 — mid-dialogue degraded-brain turn | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-5 — sustained multi-turn, no jetsam | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |

- **JetsamEvent pull (post-session):** `[OWNER INPUT — attachment path/ref; pull method; pull time; comparison: no new event for the app / findings]`
- **Notes / deviations:** `[OWNER INPUT]`
- **Tester:** `[OWNER INPUT]`

### 7.3 Item status as of authoring (not observations)

| Item | Status as of authoring | Named dependency (what must clear it) |
|---|---|---|
| DV-1 — probe → answer → correct playback | **BLOCKED** | Step zero (§3) + the owner's device + the Release build |
| DV-2 — 45 s timeout | **BLOCKED** | Step zero (§3) + the owner's device + the Release build + a clock |
| DV-3 — barge-in | **BLOCKED** | Step zero (§3) + the owner's device + the Release build + a configured call contact |
| DV-4 — degraded-brain turn | **BLOCKED** | Step zero (§3) + the owner's device + the Release build + a forcing route reproduced in force (pill observed) |
| DV-5 — sustained multi-turn, no jetsam | **BLOCKED** | Step zero (§3) + the owner's device + the Release build + the scripted session + the post-session pull |
| Step zero — the Phase 0 PR #156 smoke | **OUTSTANDING** | The owner's device; the smoke (conversation → no jetsam → pull), recorded before any DV item |

### 7.4 Owner actions carried (decisions, not measurements)

| # | Owner action | Why it is the owner's | State |
|---|---|---|---|
| OA-1 | Run step zero (§3) — the Phase 0 PR #156 device smoke — and record it | Only the owner has the device; the smoke is the standing prerequisite (`constitution.md:79`) | Open — outstanding at planning and at authoring (`plan.md:239-241`) |
| OA-2 | Execute DV-1…DV-5 on Anzaan against the Release build and fill §7.2 | Only the owner has the device and the accounts | Open — BLOCKED |
| OA-3 | Resolve any FAIL or BLOCKED item: fix, re-run on the fixed build, or record an explicit owner resolution | FR-MTC-020: a failure blocks final sign-off until fixed and re-run — no silent waiver | Open |
| OA-4 | Confirm OD-M1..OD-M4 at the T2 final sign-off (the design's defaults are implemented meanwhile) | The feature constitution's open decisions are owner-facing; the DV record is where their consequences are measured | Open |
| OA-5 | Review the probe/did-you-mean copy (the 17 `dialogue.*` keys, draft) at the review or before sign-off | Copy review is an owner-facing step (`plan.md:287`) | Open |

### 7.5 Honesty notes about this record

- **No device model, OS version, build identifier, measurement or outcome in this file is fabricated.** Where a value does not exist, the cell says it does not exist (`[OWNER INPUT]`).
- **The simulator is not used as a substitute.** No simulator observation fills any row; the focused suites' 204/204 green (`implement-notes.md` §3) is supporting evidence, never a DV item's own.
- **No item is marked passed, and no incomplete item is dressed up as complete.** The completion claim is blocked until every item carries a PASS from the owner's device run (§8).
- **The step-zero rule is absolute.** A failed step zero means no session and no partial DV results.

## 8. The completion gate (FR-MTC-020)

The gate, verbatim from FR-MTC-020 (`:18`): "**Recorded results**: each DV item is recorded as passed/failed with the evidence (log pulls, session notes) attached to the feature spec; a failure blocks final sign-off until fixed and re-run — no silent waiver." Its Gherkin failing scenario (`:37-42`): "Given any DV item fails (e.g. DV-5 shows a voice-stack jetsam kill) / When completion is assessed / Then the feature does not pass final sign-off / And the failure is fixed and the item re-run before sign-off proceeds."

Mechanics:

1. **Only PASS closes an item.** FAIL and BLOCKED both hold the gate. A failed item stays recorded as failing; the fix is made, the item re-run on the fixed build, and the re-run recorded with the fixed build's identity — sign-off stays blocked until then.
2. **Step zero gates every session** (§3): a failed step zero stops the session without partial results, and the DV items stay BLOCKED until it passes.
3. **DV-5's pull is part of the gate**: no new event for the app in the post-session pull (NFR-MTC-007); a build-side claim about the memory policy cannot move this — only the pull can.
4. **Consumers of this protocol:** the workflow's `final-sign-off` (T2 + HIL; `NFR-MTC-012:14`, `workflow.yaml:179` — "DV-* device validation on Anzaan is part of the completion gate") evaluates this record before sign-off can pass; the plan's owner-actions list carries it forward to the same gate (`plan.md:288-289`). The project release checklist's pre-release device check (`constitution.md` Release gates) is the console-surface sibling of these items; where it runs on the dialogue paths, its result is recorded in the release checklist, not here.
5. **Missing execution is an open gate item, not a missing deliverable.** The T-143 deliverable is this protocol and its record structure; the run is owner/device-dependent. At the workflow's final review, an empty record — or any item not PASS — is an open gate item that holds final sign-off, exactly as a FAIL would.

**Coverage of this unit's Gherkin (T-143 task file `:26-51`):**

| T-143 scenario | Where the protocol satisfies it |
|---|---|
| The protocol covers all five device items | §6 — DV-1…DV-5 each with verbatim item text (constitution / design-l1 §6 / FR-MTC-020), preconditions, steps, pass criteria; §5 + §7.2 define the record fields per item (date, device, build, transcript, outcome, evidence pull) |
| The Phase 0 prerequisite gates the run | §3 — step zero, hard prerequisite; "a failed step zero stops the session without partial results" |
| A failed item blocks final sign-off | §8 (FR-MTC-020) + §7.2's block/states |
| The run leaves no jetsam behind | §6 DV-5 + §7.2's session-level pull attachment ("No new jetsam event for the app appears in the pull", the T-143 scenario; NFR-MTC-007) |

## 9. Capture discipline (NFR-MTC-004, applied to the record and the pull)

- **This file contains no sensitive material.** No raw transcript beyond the **protocol fixtures** is written into this file: the fixture utterances of §6 ('भजन बजाऊ', 'दुर्गा', 'पहिलो', 'दुर्गा भजन बजाऊ', 'दशैं दुर्गा भजन', 'गीत चलाऊ', 'मेरो छोरालाई फोन गर', 'होइन') are design fixtures — the owner example in the feature constitution and FR-MTC-020, `design-l1.md:209`, and the design's pinned vectors (`design-l2.md:839-849`) contain them (in Nepali or transliteration) — and are the only query-shaped strings permitted. Any ad-hoc run-time utterance beyond the script is **described**, not transcribed, unless the owner explicitly chooses otherwise; the record is otherwise line keys, counts and yes/no answers.
- **No console content is pasted.** If the console is captured (DV-4's optional evidence), only the four content-free dialogue event names and their closed vocabularies (`dialogue_degenerate_query` / `dialogue_probe_spoken` / `dialogue_answer` / `dialogue_frame_resolved`; `design-l2.md:897-908`) go into the record. The release log-safety gate covers exactly these files and keys (T-137's allow-list, T-138's feature roots; `implement-notes.md` §1) — the record keeps the same discipline by construction.
- **The JetsamEvent pull is attached as a file, unedited.** It contains system process metadata, not user content; attach it (path or attachment) rather than inlining it, and never edit it — an edited pull is not evidence.
- **The line keys are the evidence, not the audio.** A "title heard: yes/no" is the recording form for playback content; the title itself stays out of the record.

## 10. Recording rules

1. **Every row gets a value or BLOCKED with a reason.** No row is left blank, and no row is filled from a simulator observation. Every row names the session (date, device, build) it was observed on.
2. **Measurements and decisions are different columns.** An observed outcome is not a decision to change anything; owner decisions are recorded as such (§7.4).
3. **A failed check is a finding, not a tuning invitation.** Fixing an item is valid only with the observation and the fixed-build identity recorded next to it.
4. **This protocol is not edited to match the results.** Results go in §7. If an item turns out to be unexecutable as written, §7 records that and §6 is updated in a separate, visible edit.
