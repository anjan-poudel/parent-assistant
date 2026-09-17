# Task Breakdown — Live Camera Translation (EN → NE, v1)

**Feature:** `live-camera-translation` · **Branch:** `worktree-live-camera-translation` · 2026-09-16
**Task:** `plan-tasks` (agent `le`) · **Contract:** `task_breakdown_l3` → this file + `specs/plan-tasks/tasks/`
**Inputs folded in:** `specs/design-component.md` (L2 component design, `review-l2` GO at 2026-09-16);
`specs/security-design-review.md` (`SECURITY-GO`, STRIDE, amendments AM-1 … AM-10, residual SR-1);
`specs/review-l2.md` (GO, clarifications CL-1 … CL-8); the signed-off requirement set
`specs/define-requirements/index.md` + `specs/define-requirements.md` (23 FR / 13 NFR, lock read-only);
the owner-approved first-pass design under `docs/superpowers/specs/`; `constitution.md` (Architecture
Constraint 1, Open Decision 13) and `specs/live-camera-translation/constitution.md`; and the workflow
`.ai-sdd/workflows/live-camera-translation.yaml`.

## Summary

- **Task groups: 10** (Jira Epics) — TG-01 … TG-10
- **Total tasks: 30** — T-001 … T-030, all leaf task files (no subtasks: single iOS codebase, no
  platform split, and no task's deliverables are separable enough to justify a second tracker level)
- **Estimated effort:** ~42–58 developer-days of work; ~29–33 days elapsed with two developers,
  bounded below by the critical path below (~29 days), which a third developer cannot shorten
- **Critical path:** `T-001 → T-003 → T-014 → T-018 → T-019 → T-026 → T-027 → T-028 → T-029 → T-030`
- **Security work:** every amendment AM-1 … AM-10 has a named task (map below). AM-1, AM-2 and AM-5
  gate `security-test`; AM-5 additionally gates `final-sign-off`. All CL-1 … CL-8 clarifications are
  routed into tasks (map below).
- **Requirement coverage:** all 23 FR-LCT and all 13 NFR-LCT map to at least one task. Nothing is
  unmapped.
- **Scope:** no task touches an out-of-scope capability. The v1 non-goals (NE→EN, phrase-card mode,
  world-anchored rendering, auto-speak, live full-scene explanation, on-device NMT tier 1, family
  configuration surface, feed translation) are absent by construction — several tasks carry an
  explicit acceptance scenario that keeps them absent rather than stubbed.

### Recommended execution order and parallelism

Tasks are numbered in dependency order, so executing T-001 → T-030 in order always satisfies every
dependency. The waves below are the recommended parallel packing for two developers.

| Wave | Tasks (parallel within a wave) | Note |
|---|---|---|
| 1 | T-001, T-002, T-003, T-004, T-005, T-011 | all dependency-free; T-011 is dictionary authoring and can start immediately |
| 2 | T-006, T-012, T-014, T-016, T-017, T-023 | the camera, cache, consent, cloud and voice tracks all open at once |
| 3 | T-007, T-008, T-013, T-015, T-018 | camera, cache, consent and cloud tracks run in parallel |
| 4 | T-009, T-019 | the two longest chains; one developer each |
| 5 | T-010 | decluttering needs the stabiliser |
| 6 | T-020 | placement needs the decluttered region set |
| 7 | T-021 | rendering needs placement |
| 8 | T-022, T-024 | both need the rendered overlay; T-024 also needs the sanitiser and the outcome taxonomy |
| 9 | T-025 | in-session capture needs the parser and the speech path |
| 10 | T-026 | joins the camera, cache, consent and cloud tracks — nothing downstream can start before it |
| 11 | T-027 | |
| 12 | T-028 | the gate extension needs the final sources |
| 13 | T-029 | the evidence suite needs the gate in place |
| 14 | T-030 | the device protocol needs both the gate and the suite |

Two independent tracks make the parallelism real: **camera/detection** (T-006 → T-007 → T-009 →
T-010) and **cloud translation** (T-004/T-017 → T-018 → T-019, with T-014 → T-015 alongside). The
cache track (T-011 → T-012 → T-013) is independent of both until T-026.

### Critical path

```
T-001 (config)
  → T-003 (event allow-list)
    → T-014 (consent gate)
      → T-018 (text-only translation client)
        → T-019 (cloud tier: latch, retry, deadline)
          → T-026 (pipeline + session model)
            → T-027 (plugin + session view)
              → T-028 (release log-safety gate)
                → T-029 (security evidence suite)
                  → T-030 (device validation protocol)
```

Sequential effort on this chain is ~24 days to T-028 and ~29 to T-030. It is the longest chain because
the consent gate must exist before the client method (the request builder takes a consent proof, AM-7),
the tier is the single point every cloud path passes through, and nothing downstream of T-026 can be
built until the pipeline publishes outcomes.

The **second-critical chain** is the camera track:
`T-001 → T-006 → T-007 → T-009 → T-010 → T-026`. It is roughly three days shorter and it must land on
a different developer, because T-026 depends on both chains.

The **release gate chain** (`T-026 → T-027 → T-028 → T-029 → T-030`) is what `security-test` and
`final-sign-off` read: T-028 makes the log-safety gate recognise this feature's content class and T-029
produces the evidence the security test cites.

### Key risks

1. **CRITICAL — tier-2 retry can re-issue after a consent withdrawal (T-019, AM-1/CL-2; evidence in
   T-029).** A cancelled transport surfaces as a transient-looking error, so the single retry is the
   one genuine consent-evasion window in the design. The task must treat a cancellation-shaped error
   as terminal, re-read the consent decision immediately before the second attempt, and deny on
   anything but `granted`. `security-test` cannot return `SECURITY-GO` while this is open.
2. **HIGH — the release log-safety gate does not recognise recognised or translated text today
   (T-028, AM-5).** The gate's shipped rules match transcript shapes and raw error objects only, so a
   content print in the new sources would pass. The extension must add a rule family for this
   feature's content class over the new scan roots, and the gate must exit 0. Gates both
   `security-test` and `final-sign-off`.
3. **HIGH — the consent evidence does not survive the bus today (T-003, AM-2/CL-5).** Every
   count-shaped and closed-vocabulary metadata key this feature introduces is dropped by
   `LogSanitiser.allowedKeys` today, so the auditability evidence NFR-LCT-007 requires would not
   exist. Additive allow-list extension plus a per-key test.
4. **HIGH — consent withdrawal write failure leaves egress open (T-014, AM-4/SD-1).** A failed
   withdrawal currently leaves the record granted. The gate must deny in memory first, verify the
   delete by reading back, surface a failure as a failure, and never silently re-grant on relaunch.
5. **HIGH — cache-at-rest integrity (T-012, AM-6/SD-3).** The stored ordering field must be a
   monotone counter, not a wall-clock timestamp: a wall-clock value written on lookup is scene-derived
   and fails NFR-LCT-008's "no scene timestamp" criterion literally.
6. **HIGH — in-flight dedupe has no stated terminal outcome (T-019, AM-8/CL-1).** A second observer
   of an already-claimed key must receive the in-flight request's terminal outcome, or the region sits
   pending forever — an unbounded pending state (NFR-LCT-001) and a de-facto silent drop
   (NFR-LCT-010).
7. **HIGH — shared-component regression (T-013, T-011, T-003, T-004; NFR-LCT-012).** Four tasks edit
   files the shipped appliance helper and voice pipeline depend on. All four changes must be additive;
   T-013 owns the helper-presentation regression test (dictionary hit, cache hit, localizer
   precedence) and T-011 pins the 47 shipped dictionary entries.
8. **MEDIUM — measure-vs-render divergence in the in-place predicate (T-020, R2).** The placement
   measurer and the view renderer must go through one shared measurer, pinned by a Devanagari and a
   Latin case, or a D1 in-place bubble can clip its own translation.
9. **MEDIUM — nominal device values unmeasured (T-030, OD1/OD2/OD5/R10).** Cadence, declutter
   thresholds, in-place default and microphone/speech arbitration ship as the design's nominal values
   and are confirmed at a human device run; T-030 delivers the protocol and the results record.
10. **MEDIUM — shared day cap with the voice pipeline (FR-LCT-013 / R7, accepted).** A heavy voice
    day can exhaust translation mid-session; the honest degraded state is the requirement's own
    authorised outcome. The latch task must not degrade anything else.

### Owner actions (not agent work — these gate `final-sign-off`)

These are recorded here as owner-held, and no task in this plan performs them:

- **OD-13 amendment.** Already recorded in `constitution.md` (2026-09-16) and verified at
  `final-sign-off`. **No agent may edit Open Decision 13 or `constitution.md`** — hash-locked.
- **Consent/disclosure copy review.** T-005 drafts the copy and the camera purpose string; the
  review and approval of that copy is the owner's, before the first App Store submission (OD3,
  2026-10-13 window). Changing the approved copy is a data change plus a `disclosureVersion` bump,
  owned by T-001.
- **Device demo confirmation** of the in-place default (OD2) and the declutter thresholds (OD5), and
  the device spike for the OCR cadence (OD1): T-030 delivers the protocol and the results record;
  the run itself is human.
- **SD-5** (two cloud paths, one indicator, when the cloud voice engine is active) is an input to the
  joint Open Decision 12 / 13 review — recorded, not scheduled here.
- **SR-1** (the provider block-reason token on the shared log surface) is a ruled residual; the
  feature adds no new emission of it. T-029 asserts zero upstream-derived `error_code` values on this
  feature's path.

### Security blockers and mandatory amendments (AM-1 … AM-10)

| Amendment | Landed in | Also required by |
|---|---|---|
| AM-1 cancellation is terminal; consent re-read before the retry; withdrawal-between-attempts evidence | **T-019** | T-029 (evidence) |
| AM-2 additive `LogSanitiser.allowedKeys` extension + per-key survival test | **T-003** | T-029 |
| AM-3 single-sourced detect-only marker accessor shared with the transcript sanitiser | **T-004** | T-017 (consumer) |
| AM-4 withdrawal write failure denies in memory, delete verified by read-back, failure surfaced | **T-014** | — |
| AM-5 release log-safety gate rule family for this feature's content class | **T-028** | T-029, `final-sign-off` |
| AM-6 monotone ordering counter replaces the stored wall-clock field | **T-012** | — (owner carve-out not needed) |
| AM-7 single-caller invariant; consent proof as a parameter of the request builder | **T-018** | T-019 |
| AM-8 terminal outcome for an already-claimed in-flight key + test | **T-019** | — |
| AM-9 single text channel with a delimited data block; absent tool set named as the load-bearing control | **T-018** | T-019 |
| AM-10 `security-test` assertion set | **T-029** | `security-test` |

**Blocker status:** `security-test` cannot return `SECURITY-GO` while AM-1, AM-2 or AM-5 is open;
`final-sign-off` additionally requires AM-5. No amendment is an owner decision, and none changes the
architecture or the scope.

### Review clarifications folded into tasks (CL-1 … CL-8)

| Clarification | Landed in |
|---|---|
| CL-1 dedupe terminal outcome in the batch result | T-019, T-026 |
| CL-2 consent re-read and cancellation handling on the retry | T-019, T-029 |
| CL-3 origin → tier mapping (a persisted entry is never tier 0 and never drawn in place) | T-019 (the mapper), T-026 (enforces it when publishing) |
| CL-4 error → unavailable-reason conversion table | T-002 |
| CL-5 event-metadata allow-list | T-003 |
| CL-6 detect-only marker seam | T-004 |
| CL-7 wording tightening + the helper-presentation regression test (three cases) | T-013, T-011 |
| CL-8 cosmetic sweep (`cloudRequestTimeout` derived or removed; the real Gemini extension path; the retryability table reference; the toggle's touch entry point; `repeatLast` traced; mapper-math test cases; the speech interface named) | T-001, T-018, T-019, T-022, T-023, T-020, T-024 |

### Out-of-scope guardrails (absent, not stubbed)

No task creates a tier-1 branch, a direction flag, a world-anchored placement path, an
auto-speak observer, a full-scene explanation call, a configuration surface for this feature, or any
change on the feed path. Tasks T-002 (no on-device tier case exists to return), T-020 (no world-space
input), T-024 (the only two speech construction sites are the tap handler and the command handler)
and T-027 (the plugin holds no cross-session state) each carry an acceptance scenario that would fail
if the absent capability were introduced.

### Planning assumptions for the driver to flag

1. **No subtasks were used.** The feature is a single iOS codebase with no platform split, so the
   second tracker level would add navigation without enabling parallelism. If the driver prefers the
   parent/subtask shape, the natural candidates are T-019 (tier orchestration) and T-029.
2. **The design names a `LiveTranslationPipeline` actor** in its data-flow and isolation sections
   (§5, §7 — the pipeline actor owns the stabiliser) but the C01 … C15 inventory gives it no ID. It
   is planned as **T-026** under the plugin/session model. If the owner wants a component ID for it,
   that is a design amendment, not new scope.
3. **The `NSCameraUsageDescription` update and the consent copy** are drafted by T-005 as
   implementation work (the shipped string does not mention live translation at all, so the feature
   cannot meet FR-LCT-002 without it); the **review** is the owner action above.
4. **`disclosureVersion`** ships with the draft-copy value from T-001 and is bumped when the owner
   approves the reviewed copy. Consent records are version-stamped, so a copy change invalidates a
   stale grant without a logic change.
5. **AM-6 is resolved by the counter option** (not by requesting an owner carve-out in the
   requirement text), so no read-only file needs to change.
6. **`repeatLast` is kept** among the session commands (permitted by FR-LCT-022's "at minimum"
   clause) and is traced explicitly in T-023.
7. **`SpokenOutput`** appears once in the design and is otherwise undefined (CL-8). No such type is
   introduced: T-024 uses the shipped `Announcement` plus `SpeakQueue` path and the design's
   `LiveTranslateSpeech.orderedForReading` helper.
8. **Build and test gate** is `ios/build.sh` (it runs `xcodebuild test`; a bare `xcodebuild build` is
   not the gate on this project). New sources under `Services/LiveTranslate/` are mirrored by
   `ElderlyAssistantTests/` `Services/LiveTranslate/`, so the project's test-impact mapping covers the
   new suites without a mapping change.

## Contents

- [tasks/index.md](tasks/index.md) — all task groups
- [tasks/TG-01-foundations/index.md](tasks/TG-01-foundations/index.md) — foundations: types, configuration, observability and copy
- [tasks/TG-02-camera-and-detection/index.md](tasks/TG-02-camera-and-detection/index.md) — camera capture and on-device text detection
- [tasks/TG-03-region-stabilisation/index.md](tasks/TG-03-region-stabilisation/index.md) — region stabilisation and decluttering
- [tasks/TG-04-dictionary-and-cache/index.md](tasks/TG-04-dictionary-and-cache/index.md) — tier-0 dictionary and the persistent translation cache
- [tasks/TG-05-consent-and-disclosure/index.md](tasks/TG-05-consent-and-disclosure/index.md) — consent gate, prompt, revocation and the cloud-activity indicator
- [tasks/TG-06-cloud-translation-tier/index.md](tasks/TG-06-cloud-translation-tier/index.md) — sanitising, the client method and the tier orchestration
- [tasks/TG-07-overlay/index.md](tasks/TG-07-overlay/index.md) — smart-mix placement, overlay rendering and the toggle
- [tasks/TG-08-voice-and-session-commands/index.md](tasks/TG-08-voice-and-session-commands/index.md) — session commands, spoken output and in-session capture
- [tasks/TG-09-plugin-session-pipeline/index.md](tasks/TG-09-plugin-session-pipeline/index.md) — pipeline, session model, plugin entry and session view
- [tasks/TG-10-release-gates-and-evidence/index.md](tasks/TG-10-release-gates-and-evidence/index.md) — release gate, security evidence and device validation

Requirement IDs referenced by the tasks resolve under `specs/define-requirements/` (`FR/` and `NFR/`
per-requirement files); the design's component IDs (C01 … C15) and parameter names are used verbatim
from `specs/design-component.md`.

### Task groups

| Group | Title | Tasks | Effort | Critical for |
|---|---|---|---|---|
| [TG-01](tasks/TG-01-foundations/index.md) | Foundations — types, configuration, observability, copy | 5 | ~4–5 days | every other group |
| [TG-02](tasks/TG-02-camera-and-detection/index.md) | Camera capture and on-device text detection | 3 | ~5–7 days | FR-LCT-001 … 004 |
| [TG-03](tasks/TG-03-region-stabilisation/index.md) | Region stabilisation and decluttering | 2 | ~3–4 days | the traffic gate |
| [TG-04](tasks/TG-04-dictionary-and-cache/index.md) | Tier-0 dictionary and persistent cache | 3 | ~4–7 days | offline behaviour |
| [TG-05](tasks/TG-05-consent-and-disclosure/index.md) | Consent gate, prompt, revocation, indicator | 3 | ~4–5 days | `security-test` |
| [TG-06](tasks/TG-06-cloud-translation-tier/index.md) | Sanitiser, client method, tier orchestration | 3 | ~6–7.5 days | `security-test` |
| [TG-07](tasks/TG-07-overlay/index.md) | Smart-mix placement, rendering, toggle | 3 | ~5–6.5 days | FR-LCT-015 … 018 |
| [TG-08](tasks/TG-08-voice-and-session-commands/index.md) | Session commands, spoken output, capture | 3 | ~3–5 days | FR-LCT-021, 022 |
| [TG-09](tasks/TG-09-plugin-session-pipeline/index.md) | Pipeline, session model, plugin, session view | 2 | ~5–7 days | the join point |
| [TG-10](tasks/TG-10-release-gates-and-evidence/index.md) | Release gate, security evidence, device protocol | 3 | ~5–6 days | `security-test`, `final-sign-off` |

### All tasks

| ID | Title | Group | Depends on | Scope (one line) | Effort | Risk |
|---|---|---|---|---|---|---|
| [T-001](tasks/TG-01-foundations/T-001-live-translate-config.md) | `LiveTranslateConfig` and `LiveTranslateSettings` | TG-01 | — | every operational parameter and the two persisted settings, one owner of every default | S | LOW |
| [T-002](tasks/TG-01-foundations/T-002-translation-outcome-and-errors.md) | Outcome, tier and error taxonomy (C04) | TG-01 | — | `TranslationOutcome` as the single source of truth, `LiveTranslateError`, the error → reason table | M | MEDIUM |
| [T-003](tasks/TG-01-foundations/T-003-observability-keys-allowlist.md) | Event catalogue and log allow-list (AM-2) | TG-01 | — | content-free event catalogue plus the additive `LogSanitiser.allowedKeys` extension and a per-key test | M | MEDIUM |
| [T-004](tasks/TG-01-foundations/T-004-input-sanitiser-detect-only-seam.md) | Detect-only marker seam (AM-3) | TG-01 | — | a single-sourced marker accessor on the shipped sanitiser, both call sites pinned | S | MEDIUM |
| [T-005](tasks/TG-01-foundations/T-005-localisation-catalog-and-purpose-string.md) | String Catalog entries and camera purpose string | TG-01 | — | all new user-visible strings externalised with Nepali first, plus the draft camera purpose string | M | MEDIUM |
| [T-006](tasks/TG-02-camera-and-detection/T-006-live-camera-session.md) | `LiveCameraSession` (C01) | TG-02 | T-001, T-003 | preview with no photo output, throttled frame tap with drop-not-queue, thermal cadence, lifecycle | L | HIGH |
| [T-007](tasks/TG-02-camera-and-detection/T-007-live-text-detector.md) | `LiveTextDetector` (C02) | TG-02 | T-001, T-003, T-006 | the OCR pass and the geometry-only tracking pass; a failed pass is dropped, tracking loss falls back | L | HIGH |
| [T-008](tasks/TG-02-camera-and-detection/T-008-camera-permission-surfaces.md) | Camera permission and denial surfaces | TG-02 | T-005, T-006 | explanation before the system permission prompt, denial screen with a Settings link, no dead end | S | MEDIUM |
| [T-009](tasks/TG-03-region-stabilisation/T-009-text-region-stabilizer.md) | `TextRegionStabilizer` (C03) | TG-03 | T-001, T-007 | geometry + string matching, two-sided hysteresis, change-only events | M | HIGH |
| [T-010](tasks/TG-03-region-stabilisation/T-010-decluttering-merge-and-cap.md) | Decluttering — merge and region cap (C03) | TG-03 | T-001, T-009 | same-string merge keeping the longest string, deterministic eight-region cap, one overlay per region | M | HIGH |
| [T-011](tasks/TG-04-dictionary-and-cache/T-011-curated-dictionary-extension.md) | Curated dictionary extension (C06, data only) | TG-04 | — | ~120 EN→NE entries, 47 shipped entries pinned, exact match, not reversible | M | MEDIUM |
| [T-012](tasks/TG-04-dictionary-and-cache/T-012-label-translation-cache.md) | `LabelTranslationCache` (C05, AM-6) | TG-04 | T-001, T-003, T-011 | encrypted single-key store, the key format, curated keys non-evicting, touch coalescing, self-healing | L | HIGH |
| [T-013](tasks/TG-04-dictionary-and-cache/T-013-appliance-helper-shared-cache-seam.md) | Appliance-helper label presentation seam | TG-04 | T-011, T-012 | localizer precedence over the shared cache, unchanged helper behaviour, three-case regression test | M | HIGH |
| [T-014](tasks/TG-05-consent-and-disclosure/T-014-consent-gate.md) | `LiveTranslateConsentGate` (C09, AM-4) | TG-05 | T-001, T-002, T-003 | version-stamped record, fail-closed read, revocation that takes effect in memory first | L | CRITICAL |
| [T-015](tasks/TG-05-consent-and-disclosure/T-015-consent-prompt-and-revocation.md) | Consent prompt and revocation surfaces | TG-05 | T-005, T-014 | prompt at the first cloud need with no timeout, revocation from the session view and Settings | M | CRITICAL |
| [T-016](tasks/TG-05-consent-and-disclosure/T-016-cloud-activity-indicator.md) | `CloudActivityIndicatorModel` (C10) | TG-05 | T-001, T-003 | indicator driven only by the in-flight counter, not suppressible, no dwell timer | S | MEDIUM |
| [T-017](tasks/TG-06-cloud-translation-tier/T-017-scene-text-sanitiser.md) | `SceneTextSanitiser` (C07) | TG-06 | T-001, T-004 | grapheme-safe truncation, per-string and per-batch bounds, detect-only quarantine verdicts | M | HIGH |
| [T-018](tasks/TG-06-cloud-translation-tier/T-018-gemini-translate-client-and-prompt.md) | `GeminiClient.translateStrings` and prompt handling (C08, AM-7, AM-9) | TG-06 | T-001, T-002, T-014, T-017 | text-only request builder on the existing chokepoint, items keyed by id, no tools, validated response | L | CRITICAL |
| [T-019](tasks/TG-06-cloud-translation-tier/T-019-cloud-translation-tier.md) | `CloudTranslationTier` orchestration (C08, C15) | TG-06 | T-001, T-002, T-012, T-014, T-016, T-017, T-018 | consent, cost latch, in-flight dedupe, one batch, retry ≤ 1, deadline, response validation | XL | CRITICAL |
| [T-020](tasks/TG-07-overlay/T-020-overlay-placement.md) | `LiveOverlayPlacement` (C11) | TG-07 | T-001, T-002, T-009, T-010 | the four-condition in-place predicate, callouts that never cover their own region | L | HIGH |
| [T-021](tasks/TG-07-overlay/T-021-overlay-view-and-states.md) | Overlay view, states and accessibility | TG-07 | T-005, T-020 | pending / resolved / degraded rendering, 44 pt targets, 18 pt bold, VoiceOver labels | L | HIGH |
| [T-022](tasks/TG-07-overlay/T-022-always-show-original-toggle.md) | "Always show original text" toggle | TG-07 | T-001, T-020, T-021 | the persisted setting, touch and voice reachability, effect on the next frame | M | MEDIUM |
| [T-023](tasks/TG-08-voice-and-session-commands/T-023-session-command-parser.md) | `LiveTranslateCommandParser` (C12) | TG-08 | T-005 | deterministic English and Nepali phrase table for the five commands, a miss re-prompts once | M | MEDIUM |
| [T-024](tasks/TG-08-voice-and-session-commands/T-024-spoken-output.md) | Tap-to-hear and "read this to me" | TG-08 | T-002, T-005, T-017, T-020, T-021 | the two explicit speech entry points, top-to-bottom ordering, no auto-speak, no retry loop | M | MEDIUM |
| [T-025](tasks/TG-08-voice-and-session-commands/T-025-in-session-capture-and-audio-arbitration.md) | In-session capture and audio arbitration | TG-08 | T-006, T-023, T-024 | single-utterance capture, microphone paused while speaking, no always-on listening | M | MEDIUM |
| [T-026](tasks/TG-09-plugin-session-pipeline/T-026-translation-pipeline-and-session-model.md) | Pipeline and session model (C13) | TG-09 | T-002, T-003, T-006, T-007, T-009, T-010, T-012, T-013, T-014, T-015, T-016, T-017, T-019, T-020, T-021, T-022, T-023, T-024, T-025 | owns the stabiliser, walks the tier ladder, publishes one coherent outcome set per cycle, resume recovery | XL | CRITICAL |
| [T-027](tasks/TG-09-plugin-session-pipeline/T-027-plugin-entry-and-session-view.md) | Plugin entry, registration and session view (C13) | TG-09 | T-005, T-006, T-008, T-015, T-021, T-025, T-026 | registry entry with no provider-availability guard, the full-bleed view, one close control | L | HIGH |
| [T-028](tasks/TG-10-release-gates-and-evidence/T-028-release-log-safety-gate-extension.md) | Release log-safety gate extension (AM-5) | TG-10 | T-003, T-019, T-027 | a content rule family over the new roots, the gate exits 0, documented limitations corrected | M | HIGH |
| [T-029](tasks/TG-10-release-gates-and-evidence/T-029-security-evidence-suite.md) | Security evidence suite (AM-10) | TG-10 | T-003, T-012, T-014, T-017, T-018, T-019, T-026, T-027, T-028 | the instrumented evidence set `security-test` cites, negative cases included | L | HIGH |
| [T-030](tasks/TG-10-release-gates-and-evidence/T-030-device-validation-protocol.md) | Device validation protocol (OD1, OD2, OD5, R10) | TG-10 | T-028, T-029 | fixture-image OCR plus the manual protocol: cadence and thermal, in-place default, declutter, arbitration | M | HIGH |

### Requirement → task trace

| Requirement | Tasks |
|---|---|
| FR-LCT-001 | T-006, T-027 |
| FR-LCT-002 | T-005, T-006, T-008 |
| FR-LCT-003 | T-007 |
| FR-LCT-004 | T-007 |
| FR-LCT-005 | T-009 |
| FR-LCT-006 | T-009, T-010 |
| FR-LCT-007 | T-011, T-012 |
| FR-LCT-008 | T-002 (the taxonomy owns truthful attribution; T-019 and T-026 consume it) |
| FR-LCT-009 | T-019 |
| FR-LCT-010 | T-012, T-014 |
| FR-LCT-011 | T-016 |
| FR-LCT-012 | T-012, T-014, T-015 |
| FR-LCT-013 | T-014, T-015, T-019 |
| FR-LCT-014 | T-017, T-018, T-029 |
| FR-LCT-015 | T-015, T-020 |
| FR-LCT-016 | T-017, T-020 |
| FR-LCT-017 | T-001, T-022 |
| FR-LCT-018 | T-002, T-019, T-021, T-026 |
| FR-LCT-019 | T-012 |
| FR-LCT-020 | T-012, T-013 |
| FR-LCT-021 | T-023, T-024, T-025 |
| FR-LCT-022 | T-023, T-026, T-027 |
| FR-LCT-023 | T-024, T-026, T-027 |
| NFR-LCT-001 | T-007, T-011, T-018, T-019, T-029, T-030 |
| NFR-LCT-002 | T-001, T-006, T-007, T-009, T-010, T-012, T-020, T-021, T-030 |
| NFR-LCT-003 | T-021 |
| NFR-LCT-004 | T-001, T-005, T-008, T-015, T-021, T-023, T-024, T-027 |
| NFR-LCT-005 | T-006, T-007, T-018, T-021, T-025, T-029, T-030 |
| NFR-LCT-006 | T-003, T-028, T-029 |
| NFR-LCT-007 | T-003, T-014, T-016, T-028, T-029 |
| NFR-LCT-008 | T-012, T-029 |
| NFR-LCT-009 | T-004, T-017, T-018, T-024 |
| NFR-LCT-010 | T-002, T-009, T-010, T-019, T-021, T-026 |
| NFR-LCT-011 | T-001, T-015, T-025, T-026, T-027, T-030 |
| NFR-LCT-012 | T-004, T-006, T-011, T-013, T-022, T-027, T-028, T-030 |
| NFR-LCT-013 | T-003, T-028, T-029, plus the owner actions above |
