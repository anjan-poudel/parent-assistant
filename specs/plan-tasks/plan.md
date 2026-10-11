# Task Breakdown — Family Contacts Unification (family-contacts-unify)

Decomposition source: `specs/design-l2.md` (rev 3, commit e687f075). Requirements: `specs/define-requirements.md` + lock (FR-FCU-001..017, NFR-FCU-001..009). Security: `specs/security-design-review.md` (SECURITY-GO; advisories F1–F8 folded into tasks below).

## Summary

- Task groups: 5 (Jira Epics) — TG-29 … TG-33
- Total tasks: 22 (+ 0 subtasks; leaf tasks only, per the house convention that every task file is directly dispatchable)
- Estimated effort: ~31 developer-days nominal; ~17 days critical path; realistic 2-developer schedule 20–24 days including buffer and one Anzaan device session
- Execution: `unit_based` (workflow `.ai-sdd/workflows/family-contacts-unify.yaml`), per-unit overlays — paired review (challenger: reviewer) + confidence ≥ 0.85
- Critical path: T-144 → T-145 → T-148 → T-149 → T-152 → T-159 → T-160 → T-162 → T-163 → T-164

## Contents

- [tasks/index.md](tasks/index.md) — all task groups
- [tasks/TG-29-sequencing-gate-and-identity-foundations/index.md](tasks/TG-29-sequencing-gate-and-identity-foundations/index.md) — Sequencing gate and identity foundations (4 tasks)
- [tasks/TG-30-contacts-access-link-verification-and-matching/index.md](tasks/TG-30-contacts-access-link-verification-and-matching/index.md) — Contacts access, link verification and matching (6 tasks)
- [tasks/TG-31-write-seam-and-coordinator-integration/index.md](tasks/TG-31-write-seam-and-coordinator-integration/index.md) — Write seam and coordinator integration (5 tasks)
- [tasks/TG-32-editor-and-call-surface-ui/index.md](tasks/TG-32-editor-and-call-surface-ui/index.md) — Editor and call-surface UI (4 tasks)
- [tasks/TG-33-acceptance-evidence-and-device-validation/index.md](tasks/TG-33-acceptance-evidence-and-device-validation/index.md) — Acceptance, evidence and device validation (3 tasks)

## Wave order (dependency-driven)

Waves are the parallelisable slices implied by the declared dependencies. Same-file units are chained by explicit dependencies and never run in the same wave.

| Wave | Tasks | Notes |
|------|-------|-------|
| 0 | T-144, T-146 | T-144 is the sequencing gate — must complete before any shared-surface work |
| 1 | T-145, T-147 | Wizard/coordinator/model restructure; L10n + disclosure |
| 2 | T-148, T-151 | Contacts-access gate; index skeleton |
| 3 | T-149, T-153, T-154 | Link service; resolver bands; photo writer |
| 4 | T-150, T-152, T-155, T-156 | Missed-call resolver; search tiers; log-safety roots; coordinator identity |
| 5 | T-157, T-158 | Coordinator faces; link/unlink seam |
| 6 | T-159, T-161 | Wizard find/link steps; CallView faces |
| 7 | T-160 | Wizard photo step + save flow |
| 8 | T-162 | Family list chip + face migration + legacy API deletion |
| 9 | T-163 | Acceptance + release gates (scoped sweep → full suite once) |
| 10 | T-164, T-165 | Device validation protocol; security evidence + honesty report |

## Critical path

T-144 (sequencing gate) → T-145 (identity model) → T-148 (access gate) → T-149 (link service) → T-152 (unified search) → T-159 (wizard find/link) → T-160 (wizard photo/save) → T-162 (family list + migration) → T-163 (acceptance) → T-164 (device validation). It runs through TG-29 → TG-30 → TG-32 → TG-33. The longest segment is inside TG-30: the access gate must be compile-complete before the link service, the link service before the search tier work. T-163 is a join point (it also waits on T-146, T-147, T-150, T-153, T-155, T-161), and T-164 (DV-1..6 on Anzaan) is the terminal completion gate per FR-FCU-017 / NFR-FCU-009.

## Key risks

1. **Call-dialer merge availability (NFR-FCU-008) — HIGH.** Every shared surface (AppCoordinator, LeafViews, SettingsView/CallingSettingsView-adjacent, wizard files) is frozen until T-144 verifies that the call-dialer work is on master (`Services/Calls/CallChannelChain.swift` present) and master is merged into the feature branch. Tasks that must not start before T-144 completes: T-145, T-147, T-148, T-149, T-152, T-154, T-156, T-157, T-158, T-159, T-160, T-161, T-162, T-163.
2. **Write seam is unit-untestable (SECURITY advisory F1) — HIGH.** The real `CNContactStore` write cannot be exercised in unit tests. Mitigation in T-154: source-level assertion test (only `imageData` is assigned; CNSaveRequest is update-only) plus the confinement scan in T-155 (`FeatureSourceScan` extension against the new FEATURE_ROOTS). Residual accepted in the security review.
3. **Resolver threshold brittleness (F2) — HIGH.** T-153 pins the consequence table: 0.90-vs-0.75 and 0.75-vs-0.60 at-margin pairs plus the documented 1.00/0.85 row, including the IEEE-754 `0.15000000000000002` gap.
4. **Nickname index performance and long-string worst case (F5, NFR-FCU-001) — MEDIUM.** T-151 asserts build/search/resolve ceilings (≤20 ms at 12 contacts × 8 nicknames) including a 256-char worst-case entry; T-145/T-160 cap editor input at 64 chars.
5. **Migration correctness for historical stores (FR-FCU-002, NFR-FCU-006) — MEDIUM.** T-145 must decode every historical shape (no nickname, single `nickname`, multi, link present, corrupt link) without data loss.
6. **Device validation dependency (FR-FCU-017) — MEDIUM.** DV-1..6 cannot run until an Anzaan device session is available; T-164 produces the protocol/record and must report BLOCKED honestly rather than claim completion.
7. **Photo byte equality at scale (FR-FCU-008/010) — MEDIUM.** T-154 read-back byte equality and T-146 byte-store access are the pins; F3 pins the unlink copy path (photoFilename assignment) in T-158/T-162.

## Security blockers

None. Security design review returned **SECURITY-GO** (no BLOCKERs). The eight advisories are work items, all scheduled:

| Advisory | Folded into |
|----------|-------------|
| F1 write-surface confinement evidence | T-154 (source-level assertion), T-155 (FEATURE_ROOTS + scan) |
| F2 resolver at-margin consequence rows | T-153 |
| F3 unlink copy path (`photoFilename` assignment) | T-158, T-162 |
| F4 `.written` → `family.photo.state.updatedInSystem` shown + comment alignment | T-160 (UI), T-165 (design-record comment) |
| F5 nickname length bound | T-145 (64-char editor cap), T-151 (256-char worst-case assertion) |
| F6 §3.5 footnote for `AppCoordinator.makeDialectBiasProfileProvider` (:2529) | T-165 |
| F7 no action (reason codes already raw values) | noted in T-154 |
| F8 shared-number fingerprint residual | recorded in T-165 expectations for security-test |

## Requirement coverage

| Requirement | Tasks |
|-------------|-------|
| FR-FCU-001 link system contact as family | T-149, T-158, T-159 |
| FR-FCU-002 link reference storage + migration | T-145, T-149, T-156 |
| FR-FCU-003 link-aware dedupe in unified search | T-152, T-159 |
| FR-FCU-004 one person on every surface | T-150, T-156, T-157, T-161, T-162 |
| FR-FCU-005 unlink leaves both records intact | T-145, T-158, T-162 |
| FR-FCU-006 stale-link degradation | T-149, T-150, T-156, T-158 |
| FR-FCU-007 photo display precedence | T-146, T-157, T-161, T-162 |
| FR-FCU-008 photo write confined to edited contact | T-154, T-160 |
| FR-FCU-009 write-authorization honest states | T-147, T-148, T-160 |
| FR-FCU-010 non-writable photo fallback | T-146, T-154, T-161 |
| FR-FCU-011 multi-nickname storage + migration | T-145, T-151 |
| FR-FCU-012 nickname matching in search | T-151, T-152, T-159 |
| FR-FCU-013 nickname matching in voice resolution | T-153 |
| FR-FCU-014 ambiguous nickname never wrong person | T-152, T-153 |
| FR-FCU-015 nickname management editor UI | T-145, T-160, T-162 |
| FR-FCU-016 feasibility honesty reporting | T-163, T-164, T-165 |
| FR-FCU-017 device validation completion gate | T-164 |
| NFR-FCU-001 nickname index performance | T-151, T-152, T-153 |
| NFR-FCU-002 PII log safety | T-147, T-154, T-155, T-163, T-165 |
| NFR-FCU-003 no new network egress | T-149, T-156 (asserted in unit gates) |
| NFR-FCU-004 localisation en+ne | T-147, T-159, T-160, T-161, T-162 |
| NFR-FCU-005 accessibility / voice-first | T-148, T-159, T-160, T-161, T-164 |
| NFR-FCU-006 migration compatibility | T-145, T-146 |
| NFR-FCU-007 Devanagari grapheme regression pin | T-151, T-152, T-153 |
| NFR-FCU-008 delivery sequencing (call-dialer) | T-144 |
| NFR-FCU-009 test and release gates | T-144, T-155, T-163 |

## ID numbering

The task-tree accumulates across features: the previous maximum was TG-28 / T-143, so this plan continues at **TG-29 / T-144** and every dependency points to a strictly lower task ID (ascending IDs are a valid topological order). There are no subtasks: the ai-sdd unit planner treats every non-`index.md` file under `specs/plan-tasks/tasks/**` as a dispatchable unit and derives the unit id from the leading `T-<digits>` token, so subtask files would collide with their parent task id.

## Preconditions

- T-144 (sequencing gate) is the only task allowed to start immediately alongside T-146 (byte-store work, which does not touch shared surfaces).
- All other work waits until T-144 has merged master (with the call-dialer work) into `feat/family-contacts-unify` and the merged tree builds.
- Work happens in the feature worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` only.
