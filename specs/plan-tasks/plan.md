# Task Breakdown — Profile Interview (v1)

**Feature:** `profile-interview` · **Branch:** `feat/profile-interview` · 2026-10-05
**Task:** `plan-tasks` (agent `le`) · **Contract:** `task_breakdown_l3` → this file + `specs/plan-tasks/tasks/`
**Inputs folded in:** `specs/design-l2.md` (L2 component design C01–C13, `review-l2` GO at 2026-10-05;
includes the C13 app-start routing under the 2026-10-05 owner amendment FR-PI-016);
`specs/security-design-review.md` (`SECURITY-GO`, STRIDE, findings SD-1 … SD-7, amendments
AM-1 … AM-4, 10 evidence obligations, accepted residuals); `specs/review-l2.md` (GO, observations
OB-1 … OB-5); the signed-off requirement set `specs/define-requirements.lock.yaml` +
`specs/define-requirements/` (16 FR-PI / 11 NFR-PI); `constitution.md` and
`specs/profile-interview/constitution.md`.

## Summary

- **Task groups: 4** (Jira Epics) — TG-14 … TG-17
- **Total tasks: 16** — T-090 … T-105, all leaf task files (no subtasks: single iOS codebase, no
  platform split, and no task's deliverables are separable enough to justify a second tracker level)
- **ID numbering convention:** the accumulated global maxima before this plan are T-089 and TG-13,
  so Profile Interview continues at T-090 and TG-14 (stated per the dispatch rule; computed by the
  prescribed scan before writing). No existing T-NNN or TG-NN file or folder is reused.
- **Estimated effort:** ~41–52 developer-days of work; ~21–26 days elapsed with two developers,
  bounded below by the critical path (~19–22 sequential days on the chain), which a third developer
  cannot shorten
- **Critical path:** `T-090 → T-097 → T-098 → T-099 → T-102 → T-104 → T-105`
- **Security work:** every amendment AM-1 … AM-4 has a named task, and all 10 evidence obligations
  have a named task and DoD line (both maps below). No blocker exists (`SECURITY-GO`); the
  amendments are folded non-blockingly, and no finding was turned into a gate.
- **Requirement coverage:** all 16 FR-PI and all 11 NFR-PI map to at least one task. Nothing is
  unmapped.
- **Scope:** iOS only; no task touches an out-of-scope capability. No post-MVP work, no new egress,
  no new permission, no `Info.plist` change, and no Android work appear anywhere; several tasks
  carry an acceptance scenario that would fail if an absent capability were introduced rather than
  stubbed.

### Recommended execution order and parallelism

Tasks are numbered in dependency order, so executing T-090 → T-105 in order always satisfies every
dependency (the `implement` dispatch is a single sequential pass; this order is that pass). The
waves below are the recommended parallel packing for two developers.

| Wave | Tasks (parallel within a wave) | Note |
|---|---|---|
| 1 | T-090, T-093, T-095 | store, strings and the pipeline extraction are dependency-free and open three independent tracks |
| 2 | T-091, T-097 | the guard needs the store; the drafts need the record type |
| 3 | T-092, T-098, T-101 | the coordinator seam needs the guard; the field needs bounds and clamp; the fingerprint step needs only copy |
| 4 | T-094, T-096, T-099, T-100, T-103 | the clause/seed unit, the ack service, two wizard steps and the Settings editor all open once their foundations exist |
| 5 | T-102 | the enum and routing wait for all three step views so the exhaustive switch compiles |
| 6 | T-104 | the log-safety coverage needs every feature source in place |
| 7 | T-105 | the release evidence bundle needs the gate and the whole journey |

Two independent tracks make the parallelism real: the **reply/prompt track** (T-090 → T-091 →
T-092 → T-094, with the mirror gate) and the **wake/ack track** (T-095 → T-096). The wizard track
(T-097 → T-098 → T-099 → T-102) joins them at T-102, and the Settings/evidence track (T-103 →
T-104 → T-105) closes the feature.

### Critical path

```
T-090 (encrypted store)
  → T-097 (drafts, bounds, mandatory predicate)
    → T-098 (address-as field)
      → T-099 (about-you step)
        → T-102 (step enum + cold-start routing + shell wiring)
          → T-104 (log-safety coverage)
            → T-105 (release evidence bundle)
```

Sequential effort on this chain is roughly 19–22 days, and it is the longest chain because the
routing predicate is single-sourced with the About-you Next gate (T-097 must exist first), the
step views must compile before the exhaustive `stepContent` switch gains its cases (T-099 before
T-102), and the release evidence cannot run before the gate covers the final sources (T-104 before
T-105). The **second-critical chain** is the reply track:
`T-090 → T-091 → T-092 → T-103 → T-104 → T-105` (~16–19.5 days), which the store work clusters
behind. The ack track (`T-095 → T-096 → T-105`) is the shortest of the three and must land on the
other developer.

### Key risks

1. **HIGH — seed/template drift on a one-byte boundary (T-094, R3/R11).** The seed ends with an
   extra newline today (2,699 vs 2,698 bytes); the template edit, the seed edit, the renderer
   default and the new build-blocking gate must land as one unit, or byte equality breaks in the
   middle of the change. The worst-case composition (2,586 of the pinned 3,000 Characters) is
   re-measured in the same task so the next trim starts from truth.
2. **HIGH — the capture-start extraction must be behavior-preserving (T-095, NFR-PI-010).** Moving
   the capture-start body into `beginCapture` changes the pipeline's most safety-adjacent path;
   the nil-seam path must equal today's code exactly and the existing seam suites must stay green
   unchanged. AM-3 additionally requires the racing-detection window to be covered.
3. **HIGH — acknowledgement latency vs the activation budget (T-096, T-105, OD-A1, R1/R5).** The
   detection-to-first-audio budget (≤ 1 s) is unmeasured on device; the hold bound is injectable
   and the design's fallback ladder (warm engine, memory-only pre-synthesis, shorter copy) is the
   lever. No default changes without the T-105 measurement and a recorded decision.
4. **HIGH — corrupt-store removal semantics (T-090, R7, FR-PI-015).** A present-but-undecodable
   payload is removed exactly once and cached; any retry loop or partial application would turn a
   corrupt record into a startup hazard. Absent vs unreadable must stay distinct through the
   tri-state probe.
5. **HIGH — guard policy boundary for instruction-shaped terms (T-091, T-094, SD-1/AM-1).** The
   shared marker table is English/transliterated by design, so out-of-table shapes (including the
   requirement's own example) pass as quoted data; the containment statement and the split fixtures
   (in-table vs out-of-table, with an A/B routing assertion) make the boundary explicit and
   evidenced rather than silently assumed.
6. **MEDIUM — guard false positives reject a legitimate term (T-091, R9).** A benign term phrased
   like a marker is dropped for that turn only: no crash, no user error, the event makes it
   visible, and the acknowledgement still speaks the stored term verbatim.
7. **MEDIUM — Devanagari grapheme handling in clamps (T-091, T-098, R10).** Every clamp goes
   through `Character` prefixes and the tests pin a Devanagari conjunct fixture, where a naive
   count would split a cluster.
8. **MEDIUM — cold-start routing repeats until the interview is completed (T-102, R13).** The
   repetition is the owner's amendment, not an implementation choice; the soft-skip and the
   dismissible presentation guarantee the user is never trapped, and the decision is once per
   process (no foreground re-check).
9. **MEDIUM — shared-file regressions in the coordinator and the shell (T-092, T-102,
   NFR-PI-010).** Both edits must be additive; the existing coordinator and wizard suites keep
   passing, and the boot guard keeps hosted unit tests on today's behavior.
10. **MEDIUM — log-safety coverage gap in shared files (T-104, SD-4/AM-4).** The strict gate rules
    cover the feature's dedicated sources (including the dedicated step-view file); the coordinator
    edits remain best-effort by the amendment's own wording, contained by the runtime
    redaction/allow-list choke point; the gate exit-0 obligation is carried in the release
    checklist (T-105).

### Owner actions (not agent work — these gate `final-sign-off`)

These are recorded here as owner-held, and no task in this plan performs them:

- **OD-A2 — English ack copy eyeball.** The en template `Yes, %@` is confirmed by the owner at
  review of the T-093 / T-096 changes; the term is never translated or reformatted.
- **App Store privacy-disclosure update** for the new profile fields (NFR-PI-011 item 2) — an
  owner/compliance action inside the 2026-10-13 window; named in the T-105 bundle so it is not
  lost.
- **Accepted residual (OD-PI-5 / SD-6): plain Settings editor, no biometric gate.** Owner-accepted
  2026-10-05; the project-wide gate remains a recorded follow-up outside this feature. T-103
  references the record; no agent work re-litigates it.
- **Optional, not scheduled:** extending the shared injection-marker family is a project-level
  decision recorded by SD-1; this feature neither requires nor performs it.

### Security findings and mandatory amendments (AM-1 … AM-4, SD-1 … SD-7)

| Amendment / finding | Landed in | Also required by |
|---|---|---|
| AM-1 containment statement + split fixtures for in-table vs out-of-table terms (SD-1) | **T-091** (documentation + in-table fixtures), **T-094** (A/B routing assertion) | T-105 (evidence index) |
| AM-2 quote-family neutralisation incl. U+2018 / U+2019 / U+201C / U+201D and backtick (SD-2) | **T-091** | — |
| AM-3 correct the "closes the gate synchronously" claim + racing-detection test (SD-3) | **T-095** (documentation + seam test), **T-096** (supersede test) | — |
| AM-4 step views inside the strict gate rules via a dedicated file; keep the gate exit-0 obligation in the release checklist (SD-4) | **T-104** (scan roots), **T-099 / T-100 / T-101** (dedicated file), **T-105** (checklist item) | T-105 |
| SD-5 ack temp WAV evidence | T-096 (pin), T-105 (device run) | evidence obligation 5 |
| SD-6 plain editor residual | T-103 (referenced, accepted) | owner action above |
| SD-7 routing tampering/corrupt map accepted | T-102 (documented, stores nothing) | evidence obligation 9 |

**Blocker status:** none. `security-design-review` returned `SECURITY-GO` with no blocker; every
amendment is a non-blocking precision or coverage item and is folded into the tasks above. No
non-blocking finding was turned into a gate.

### Security evidence obligations → task and DoD line

| # | Obligation (from the security review) | Task(s) | Where the DoD line lives |
|---|---|---|---|
| 1 | In-table marker term: quarantine fires, un-personalized turn, byte-identical prompt, content-free event | T-091, T-094 | T-091 "Evidence (obligation 1)"; T-094 "Evidence (obligation 1, clause half)" |
| 2 | Out-of-table payloads (the requirement's example + a Nepali instruction-shaped term) with the A/B routing assertion | T-091, T-094 | T-091 "Evidence (obligation 2)"; T-094 "Evidence (obligation 2, clause half)" |
| 3 | Quote-family break attempts + grapheme-boundary truncation against the 24-grapheme bound and the pinned budget | T-091, T-094 | T-091 "Evidence (obligation 3, guard half)"; T-094 "Evidence (obligation 3, clause half)" |
| 4 | Personalized Release session: zero profile values in console, logs, telemetry; extended gate exits 0 | T-104, T-105 | T-104 "Evidence (obligation 4, gate half)"; T-105 "Evidence (obligation 4)" |
| 5 | Container inspection: no plaintext anywhere; ack WAV gone after playback; key material required | T-090, T-096, T-105 | T-090 "Evidence (obligation 5, store half)"; T-096 "Evidence (obligation 5, WAV half)"; T-105 "Evidence (obligation 5)" |
| 6 | Corrupt-payload run: removed once, never partially applied, no loop, startup unaffected | T-090 | T-090 "Evidence (obligation 6)" |
| 7 | Offline full journey: zero feature-attributable network | T-105 | T-105 "Evidence (obligation 7)" |
| 8 | Ack failure injection: unresolved template, timeout, cancel — silent start, completion exactly once, balanced bookkeeping | T-096 | T-096 "Evidence (obligation 8)" |
| 9 | Cold-start routing: corrupt map and unreadable profile — no crash, stall, loop or trap; skip/dismiss present | T-102 | T-102 "Evidence (obligation 9)" |
| 10 | Voice fingerprint: diff-level mechanism/storage/permission non-change; no biometric value in the new store, logs or payloads | T-101 | T-101 "Nothing about the mechanism changed" scenario + DoD |

### Review observations folded into tasks (OB-1 … OB-5)

| Observation | Landed in |
|---|---|
| OB-1 `WakeAcknowledging` "always calls completion exactly once" refined by the state machine's cancel exception | T-096 (contract documented incl. the cancel path) |
| OB-2 wizard merge base for `.absent` / `.unreadable` spelled out as the empty record | T-097 (documented in the helpers) |
| OB-3 FR-PI-013's "No force-migration" scenario superseded for the app-start path | Context only — no task; the supersession is recorded in FR-PI-016 and design-l2, and an annotation on FR-PI-013 rides the next touch of the set |
| OB-4 §9.2's "byte-identical" phrasing made precise | T-094 (the renderer-default equality is asserted directly, not only through the gate) |
| OB-5 OD-A1 and OD-A2 carried as evidence/eyeball items | T-105 (OD-A1 protocol) + the owner action for OD-A2 above |

### Out-of-scope guardrails (absent, not stubbed)

No task creates: a step that blocks the interview (every step stays skippable; the About-you gate
applies to its Next button only); any new persisted state for routing; a background-to-foreground
re-check; a second profile store or any plaintext copy; new egress, permissions or plist changes;
prompt changes beyond the one clause and its seed mirror; per-language fine-tuned models; or any
Android work. Tasks T-100 (emergency-call path unchanged), T-101 (mechanism unchanged), T-102
(stores nothing, grants nothing), T-103 (no new authentication) and T-096 (single bookkeeping
owner) each carry an acceptance scenario that would fail if the absent capability were introduced.

### Planning assumptions for the driver to flag

1. **No subtasks were used.** The feature is a single iOS codebase with no platform split; the repo
   precedent for this shape uses leaf tasks only. If the driver prefers the parent/subtask shape,
   the natural candidates are T-090 (store) and T-102 (enum + routing).
2. **ID numbering continues the global maxima** (T-089 → this plan starts at T-090; TG-13 → starts
   at TG-14), per the dispatch convention; the pre-existing TG-01 … TG-13 files and folders are
   untouched, and only the two replaced files carry the new feature's content.
3. **The step views land in a dedicated `App/ProfileInterviewSteps.swift`** (AM-4's option) even
   though design-l2 sketched them inside the wizard file; AM-4's text is the binding one and the
   dedicated file is what puts them inside the strict gate rules.
4. **The seed, template, renderer and mirror gate land as one task (T-094)** per design-l2's
   hand-off note; splitting them would break byte equality mid-landing.
5. **`implement` is a single sequential dispatch** — numeric order is a valid topological order
   (every dependency points at a lower id), so the driver can execute top-to-bottom without
   re-planning.
6. **`ios/build.sh` is the build/test gate** (it runs `xcodebuild test`); the new suites live under
   `ElderlyAssistantTests/` mirroring the source paths, so the project's test-impact mapping covers
   them without a mapping change.
7. **OD-A1's fallback ladder is invoked only if the T-105 measurement misses the budget**; any
   default change is a recorded decision (`wakeAckMaxHoldSeconds` is injectable by design), not a
   silent edit.
8. **No new observability metadata keys are introduced**; every event the feature emits uses
   `outcome` / `error_code` / `duration_ms`, all already in the shipped allow-list, and the five
   profile field names are added to the redaction set only (fail-closed).

## Contents

- [tasks/index.md](tasks/index.md) — all task groups
- [tasks/TG-14-profile-foundations/index.md](tasks/TG-14-profile-foundations/index.md) — store, guard, coordinator seams and strings
- [tasks/TG-15-personalization-paths/index.md](tasks/TG-15-personalization-paths/index.md) — prompt clause, seed mirror gate, wake acknowledgement
- [tasks/TG-16-interview-wizard-and-startup-routing/index.md](tasks/TG-16-interview-wizard-and-startup-routing/index.md) — drafts, steps and app-start routing
- [tasks/TG-17-settings-release-and-evidence/index.md](tasks/TG-17-settings-release-and-evidence/index.md) — Settings editor, log-safety coverage and the release evidence bundle

Requirement IDs referenced by the tasks resolve under `specs/define-requirements/` (`FR/` and
`NFR/` per-requirement files); component IDs (C01 … C13) and parameter names are used verbatim from
`specs/design-l2.md`; amendment and finding IDs come from `specs/security-design-review.md`;
observation IDs come from `specs/review-l2.md`.

### Task groups

| Group | Title | Tasks | Effort | Critical for |
|---|---|---|---|---|
| [TG-14](tasks/TG-14-profile-foundations/index.md) | Profile Foundations — store, guard, seams, strings | 4 | ~9.5–12 days | every other group |
| [TG-15](tasks/TG-15-personalization-paths/index.md) | Personalization Paths — prompt clause, seed mirror, wake ack | 3 | ~9.5–12 days | FR-PI-008 … 011 |
| [TG-16](tasks/TG-16-interview-wizard-and-startup-routing/index.md) | Interview Wizard and Startup Routing | 6 | ~14.5–18 days | FR-PI-001 … 007, 013, 016 |
| [TG-17](tasks/TG-17-settings-release-and-evidence/index.md) | Settings, Log Safety and Release Evidence | 3 | ~8–10 days | `security-test`, `final-sign-off` |

### All tasks

| ID | Title | Group | Depends on | Scope (one line) | Effort | Risk |
|---|---|---|---|---|---|---|
| [T-090](tasks/TG-14-profile-foundations/T-090-user-profile-store.md) | `UserProfileStore` — encrypted profile record (C01) | TG-14 | — | one encrypted record, whole-record decode, tri-state absent/unreadable discrimination, atomic writes, content-free events | L | HIGH |
| [T-091](tasks/TG-14-profile-foundations/T-091-profile-prompt-guard-and-personalization.md) | `ProfilePromptTextGuard` + `ProfilePersonalization` (C07, AM-1, AM-2) | TG-14 | T-090 | the guard pipeline, quote-family neutralisation, grapheme clamp, and the guarded/verbatim read seam | M | HIGH |
| [T-092](tasks/TG-14-profile-foundations/T-092-coordinator-profile-seams.md) | Coordinator profile seams — writer, snapshot, personalization (C01) | TG-14 | T-090, T-091 | the single writer, the cached snapshot and the `init()`-built personalization seam | M | MEDIUM |
| [T-093](tasks/TG-14-profile-foundations/T-093-l10n-catalog-additions.md) | L10n catalogue additions (C09) | TG-14 | — | every new string keyed in en + ne, the ack template included; data never catalogued | M | MEDIUM |
| [T-094](tasks/TG-15-personalization-paths/T-094-prompt-clause-and-seed-mirror-gate.md) | Prompt clause + seed mirror + build gate (C06, C08) | TG-15 | T-091, T-092 | the clause at its three anchors, the seed placeholder, the renderer default and the build-blocking mirror gate as one unit | L | HIGH |
| [T-095](tasks/TG-15-personalization-paths/T-095-capture-extraction-and-ack-seam.md) | `VoicePipeline.beginCapture` extraction + ack seam (C05) | TG-15 | — | behavior-preserving extraction, the nil-default seam, the `stop()` cancel and the epoch protection | M | HIGH |
| [T-096](tasks/TG-15-personalization-paths/T-096-wake-acknowledgment-service.md) | `WakeAcknowledgmentService` + coordinator wiring (C05) | TG-15 | T-092, T-093, T-095 | the two-state ack machine, phrase composition, the timeout/cancel paths and the base-speaker wiring | L | HIGH |
| [T-097](tasks/TG-16-interview-wizard-and-startup-routing/T-097-onboarding-drafts-and-bounds.md) | Onboarding drafts, bounds and mandatory predicate (C02) | TG-16 | T-090 | pure draft/merge helpers, entry bounds and the single-sourced trimmed-non-empty predicate | S | MEDIUM |
| [T-098](tasks/TG-16-interview-wizard-and-startup-routing/T-098-address-as-field.md) | `AddressAsField` — chips + custom entry (C03) | TG-16 | T-091, T-093, T-097 | preset chips as data plus a grapheme-clamped free-text field, shared by wizard and Settings | M | MEDIUM |
| [T-099](tasks/TG-16-interview-wizard-and-startup-routing/T-099-about-you-step.md) | About-you step (C02) | TG-16 | T-092, T-093, T-097, T-098 | name, address-as and optional component-only DOB with the gated Next and the open Skip | M | MEDIUM |
| [T-100](tasks/TG-16-interview-wizard-and-startup-routing/T-100-emergency-contacts-step.md) | Emergency contacts step + family list (C02, C11) | TG-16 | T-092, T-093, T-097 | singular kin designation through existing APIs, GP/hospital, and the family-step confirmation list | M | MEDIUM |
| [T-101](tasks/TG-16-interview-wizard-and-startup-routing/T-101-voice-fingerprint-step.md) | Voice fingerprint step (C12) | TG-16 | T-093 | hosts the existing enrollment session as an optional skippable step — a call site only | M | MEDIUM |
| [T-102](tasks/TG-16-interview-wizard-and-startup-routing/T-102-step-enum-and-cold-start-routing.md) | Step enum extension + cold-start routing + shell wiring (C02, C13) | TG-16 | T-092, T-097, T-099, T-100, T-101 | the three enum cases, the exhaustive switch, the route rule and its once-per-process consumption | L | HIGH |
| [T-103](tasks/TG-17-settings-release-and-evidence/T-103-profile-settings-editor.md) | Profile Settings editor + destination row (C04) | TG-17 | T-092, T-093, T-097, T-098 | the post-interview editor, the destination row and the updated Settings expectations | M | MEDIUM |
| [T-104](tasks/TG-17-settings-release-and-evidence/T-104-log-safety-coverage.md) | Log-safety coverage — redacted keys + feature roots (C10) | TG-17 | T-102, T-103 | fail-closed redaction for the five field names and strict gate coverage for the feature's sources | M | HIGH |
| [T-105](tasks/TG-17-settings-release-and-evidence/T-105-release-evidence-and-device-validation.md) | Release evidence bundle + device validation (obligations 4, 5, 7; OD-A1) | TG-17 | T-094, T-096, T-102, T-103, T-104 | the Release-session, container and offline-journey evidence plus the device latency measurement | L | HIGH |

### Requirement → task trace

| Requirement | Tasks |
|---|---|
| FR-PI-001 | T-099, T-100, T-101, T-102 |
| FR-PI-002 | T-097, T-098, T-099, T-102 |
| FR-PI-003 | T-090, T-092 |
| FR-PI-004 | T-099, T-100, T-101, T-102 |
| FR-PI-005 | T-100 |
| FR-PI-006 | T-100 |
| FR-PI-007 | T-101 |
| FR-PI-008 | T-095, T-096 |
| FR-PI-009 | T-094 |
| FR-PI-010 | T-091, T-094, T-096, T-098, T-099, T-103 |
| FR-PI-011 | T-090, T-091, T-095, T-096, T-103 |
| FR-PI-012 | T-092, T-103 |
| FR-PI-013 | T-102 (the resume mechanics; FR-PI-016 supersedes its "No force-migration" scenario for the app-start path, recorded in FR-PI-016) |
| FR-PI-014 | T-090, T-100 |
| FR-PI-015 | T-090, T-092, T-102 |
| FR-PI-016 | T-097 (predicate), T-102 (route + shell) |
| NFR-PI-001 | T-090, T-096, T-100, T-105 |
| NFR-PI-002 | T-090, T-091, T-096, T-104 |
| NFR-PI-003 | T-090, T-105 |
| NFR-PI-004 | T-091, T-094 |
| NFR-PI-005 | T-094 |
| NFR-PI-006 | T-093, T-098, T-103 |
| NFR-PI-007 | T-098, T-099, T-103 |
| NFR-PI-008 | T-096 |
| NFR-PI-009 | T-101, T-105 |
| NFR-PI-010 | T-090, T-092, T-095, T-096, T-101, T-102 |
| NFR-PI-011 | T-104, T-105, plus the owner action above |
