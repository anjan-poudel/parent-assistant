# T-164 — device-validation DV-1..6 protocol and record: implementation notes

**Task:** T-164, TG-33 "Acceptance, Evidence and Device Validation" — `specs/plan-tasks/tasks/TG-33-acceptance-evidence-and-device-validation/T-164-device-validation-dv1-6.md`.
**Feature:** `family-contacts-unify` · **Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` · **Branch:** `feat/family-contacts-unify` · **Verified against:** `4d4d1e2852717b40e53b294338173cd619439323` · **Date:** 2026-10-12.

## What was built (deliverable)

**`specs/FCU-device-validation-protocol.md`** — the FR-FCU-017 device-validation protocol **and** record for the feature, merged into one artifact per the SP/MTC precedent (`specs/SP-device-validation-protocol.md`, `specs/MTC-device-validation-protocol.md`; the LCT precedent is the split pair protocol+results — the T-164 task frames its output as one "protocol and record", hence the merged shape):

- **DV-1…DV-6 exactly as recorded in the feature constitution** (`specs/family-contacts-unify/constitution.md:131-138`), each item carrying its verbatim item text plus: source of record, preconditions, exact steps (with the shipped Nepali/English UI copy, resolved against `Localizable.xcstrings`), expected outcome, pass/fail criteria, the NFR-FCU-005 accessibility spot-check where one belongs to the item, evidence to capture, and a per-item record template. No checklist content was re-interpreted or extended (T-164 implementation note; constitution comment above the DV block).
- **Record structure** (§5, §7): status vocabulary PASS / FAIL / BLOCKED; the §7.2 session-block template with per-item Status / Observed / Evidence columns so final-sign-off can verify mechanically (T-164 implementation note 4); `[OWNER INPUT]` cells for everything only the device session can produce — no value invented.
- **Environment/build identity** (§2): commit, bundle id/version **derived from the built artifact** (`ios/device-install.sh:52-60` recipe; `ai.voicebridge.senior.assistant` per `ios/project.yml:247`), configuration, install method (upgrade install — container preserved, required for DV-6's ordering), device/OS, access state.
- **Prerequisites and procedure** (§3/§4): the device-session bootstrap, "the merged tree builds" as a satisfied prerequisite, DV ordering (DV-1 → DV-2 → DV-3 → DV-5 → DV-4 → DV-6), the DV-6 pre-check-before-any-save ordering constraint, and the one-session-executable requirement (T-164 Gherkin scenario 1).
- **Completion-gate mechanics + Gherkin coverage table** (§8): FR-FCU-017's rules (only PASS closes an item; FAIL stays recorded, fix + re-run on the fixed build; no silent waiver), the final-sign-off consumer (`.ai-sdd/workflows/family-contacts-unify.yaml:213`), and where each T-164 Gherkin scenario (including the failure-path scenarios) is satisfied or will be satisfied.
- **Capture discipline** (§9, NFR-FCU-002) and **recording rules** (§10, mirroring the LCT/SP/MTC rules — protocol not edited to match results; every row gets a value or BLOCKED-with-reason).

**`specs/T-164-device-validation-notes.md`** — this file.

## DV status (honest record — the T-164 Gherkin "No session available" path)

**Protocol written; execution PENDING. No Anzaan device session was available to this session, so no DV item was executed and no item is marked PASS.** The record (§7.3 of the protocol) states every item **BLOCKED with its named dependency**, and the feature completion status explicitly **"device validation outstanding"** (FR-FCU-016 honest reporting; T-164 Gherkin scenario 3). No fabricated results; the simulator and the T-163 scoped suites are never substituted for a device observation (T-164 DoD: "If session unavailable: every item recorded BLOCKED with the reason; no PASS claimed"). The house rule stands: DV failures/absences block final sign-off until executed (FR-FCU-017).

## Decisions made during implementation

1. **Merged protocol+record in one artifact** — the task names one artifact ("the device-validation protocol and record"); SP/MTC precedent supports the merged shape with session blocks appended at run time.
2. **Artifact path `specs/FCU-device-validation-protocol.md`** — the house convention is `<PREFIX>-device-validation-protocol.md` (LCT-/SP-/MTC-); no other canonical path was named in the plan, task, or workflow.
3. **"design-l2 §17" in the assignment resolved to `design-l1.md` §17** — design-l2 has §0-§10; the device-gate line ("Device gate FR-FCU-017: DV-1 … DV-6 on Anzaan, recorded with the feature spec") is `design-l1.md:791`. Both specs were read for the steps' UI behavior (design-l2 §1.4/§1.5, §2.2-§2.7, §3.3/§3.4, §4.5, §5.2/§5.3).
4. **DV-6 staging made explicit** — any feature-build save rewrites the whole store in the new format, so the record instructs the pre-check before DV-1's first save (natural route) or a staged pre-change install (`81de796a` + fixture, route (b)), with the upgrade install (container preserved) as the migration event.
5. **DV-2 record must include STT-produced spellings** (record, don't fix) per the STT-invariant house rule; and a call-dialer attribution note was added to §1 because the confirmation seam is shared with `call-dialer-primary-secondary` (merged at `81de796a`), whose own DV-1..7 are outstanding — failures must be attributed with the observed line, never cross-attributed.
6. **Release-gate evidence section (§7.5) added without extending the checklist** — FR-FCU-017 requires the log-surface evidence (`check-release-log-safety.sh` + pre-release device console check) to accompany the record; the build-side half is done (T-163: exit 0 at `4d4d1e28`), the device-side half is an open owner action.
7. **Accessibility spot-checks embedded in the DV items that touch the surfaces** (DV-1/DV-2/DV-3/DV-4/DV-5 per NFR-FCU-005's three scenarios), per the T-164 note that they belong to the DV items.
8. **Notes path** — `specs/T-164-notes.md` is owned by call-dialer; this unit's notes are this file, per the assignment.

## Test results

None run for this unit — speed mode per the assignment: the unit is documentation + protocol and the DV execution happens on the Anzaan device, which is not available in this session. The evidence this artifact cites (T-163's 32/32 scoped sweep, the full-bundle baseline honesty record, the log-safety gate exit 0 at `4d4d1e28`) is recorded in `specs/T-163-acceptance-notes.md` and is **build-side supporting evidence only** — it fills no DV row.

## Build/install pointers (for the owner's session)

- **Install:** `ios/device-install.sh` (builds Debug, derives `CFBundleIdentifier` from the built artifact — the CoreDeviceError 10002 class fix — and upgrade-installs via `xcrun devicectl device install app`, container preserved).
- **Release build:** `ios/build.sh build` with `DEVELOPMENT_TEAM` set (signed Release product) or `ios/build.sh ipa` (Release archive/ipa) — `ios/build.sh` is canonical per T-164's implementation notes.
- **Build prerequisite:** satisfied — the merged tree builds (T-144's merge-gate build-green `6c743f32`; T-163 swept at `4d4d1e28`).

## Open items (owner)

- Execute DV-1…DV-6 on Anzaan per the protocol §4, filling §2/§7.2 of `specs/FCU-device-validation-protocol.md` (OA-1…OA-6 in the protocol §7.4).
- Run the pre-release device console check (§7.5) across the session and record the inspection outcome.
- Final sign-off remains gated until every DV item carries a PASS in the record (FR-FCU-017).
