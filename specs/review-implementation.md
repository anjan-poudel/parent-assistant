# Review — implementation, profile-interview (re-issued after rework pass 1)

Artifact under review: the profile-interview worktree (`feat/profile-interview`) and `specs/implement-notes.md` (final, including section 8 for rework pass 1), for task `review-implementation`.
Read with: `specs/design-l2.md`, `specs/review-l2.md`, `specs/security-design-review.md`, the task files T-090 ... T-105, the feature constitution and the requirements lock.
Method: verification re-derived, not taken on trust — sources read directly, result bundles re-read with xcresulttool, both static gates re-run read-only from this worktree. No build was run.

## Summary

Re-issued decision after rework pass 1. The single blocking defect from the first review (D-1: the voice-fingerprint step had no mid-recording teardown) is closed at the source, the recommended T-100 test is in place and green, the notes corrections are applied, and the re-run gates reproduce green. Nothing reviewed now requires rework.

### 1. D-1 closure (verified)

- The step now carries the canonical hygiene in exact form: `.onDisappear { Task { await enrollment.stopRecording() } }` on the enrollment host in `ProfileInterviewSteps.swift` (lines 466-474, with the rationale comment). Same call as the canonical site (`VoiceSettingsView.swift` lines 119-124); `stopRecording()` guards on `.recording` (no-op when idle) and is the normal resume path.
- All exits fire it: step swap Next/Skip/Back replaces the switch branch in the wizard shell (view identity changes, so the outgoing step disappears); completing the interview removes the whole wizard branch in `ContentView.swift`; dismissing the Home cover tears its content down.
- Behavioral corroboration: the scoped UI cold-start walk (which skips through the voice step on the live path) is green — re-read from the bundle (Passed 1/1, 2m 17s). The walk does not itself exercise a record-then-leave sequence; the mid-recording guarantee rests on the canonical call form plus the session's unit-tested no-op and resume semantics. Recorded as the declared verification basis, matching the notes.

### 2. T-100 test and the extraction (verified)

- `KinDesignationTests.swift` (4 tests) pins the singular designation: tapped flagged true, other currently-flagged cleared, unflagged never written, values carried verbatim, a same-id edited snapshot planned once.
- `KinDesignation.plan` is the pure helper (clear flagged others excluding the tapped id, then set the tapped); `EmergencyContactsStep.designate` executes exactly that plan through `updateFamilyContact`, one call per entry with the entry's values and flag, aggregating failure into the inline copy.
- The extraction is semantics-verified against the T-100 definition of done; the step file is untracked in this worktree, so no pre/post byte-diff exists — the basis is the plan's tests plus the designate path read directly.
- The reworked unit gate ran the class: bundle re-read shows 188 passed, 0 failed, 0 skipped, result Passed, with `KinDesignationTests` present in the result.

### 3. Gate evidence re-read (observed, not asserted)

| Evidence | Observed |
| --- | --- |
| Unit gate (02-29-58) | 188 passed, 0 failed, 0 skipped, Passed; KinDesignationTests in the result |
| Scoped UI (pi_rework_scoped) | the cold-start wizard test Passed 1/1, 2m 17s |
| Prompt-mirror gate | re-run here: exit 0, 2717 bytes, 4 placeholders, all six drift classes rejected |
| Log-safety gate | re-run here: exit 0, 24 fixtures over 12 rules, positive and negative per rule |
| Flake record | two intermediate ack-suite flakes documented (the same two wall-clock tests as the pre-rework session, green 10/10 isolated, no source change between attempts); accepted as declared |

### 4. Working-tree check (nothing else moved)

- Files touched in the rework window: `ProfileInterviewSteps.swift`, `KinDesignationTests.swift` (new), `specs/implement-notes.md` — as declared.
- Two further files carry rework-window mtimes with no undeclared content: the project file gained exactly the KinDesignationTests build-file, file-reference and group/sources wiring (the project uses explicit wiring, no synchronized groups), and the shared scheme was rewritten byte-identically to HEAD (clean against git, no diff) at the same timestamp. Both are the consequence of wiring the new test; recorded as a declaration nit only.
- No other feature-path file changed; the two concurrently updated spec files are this review and the security report.

### 5. Notes corrections (verified)

- Section 7 now carries the exact save-failure coverage map and retires the earlier overclaim.
- Section 8 records D-1, the fix, the verification basis, the flake record, and the pruned-bundle annotations; sections 3 and 6 keep the 4-of-7 full-suite claim as a recorded claim with the retention note.

### 6. Residuals carried (declared, not blockers)

- Device-only obligations (Release-session inspection, container and WAV checks, offline journey, OD-A1) remain not-run with reasons; they belong to security-test and final-sign-off.
- OD-A2 owner copy and the App Store disclosure remain open owner items.
- The three pre-existing UI tests remain red with base-and-master evidence, unmodified and declared.
- The optional T-099 step-prefill test was not added (the prefill semantics are draft-layer tested; the remainder is view glue on par with the other steps). Acceptable.

### 7. Role checklist

| Item | Verdict | Basis |
| --- | --- | --- |
| Every interface method has an explicit error return type | Pass | `Result<Void, ProfileStoreError>` and typed enums throughout; no untyped escape hatch |
| Every async or external call documents failure mode and recovery | Pass | store, guard, ack paths as before; the wizard backout path now closes the loop |
| Timeouts and retry limits are configurable | Pass | hold bound, term bound and entry bounds are parameters with defaults; keys are design constants |
| Every element traces to an FR or NFR | Pass | all 16 FR and 11 NFR anchored; the T-100 definition-of-done gap is now covered by tests |
| The design shows what the operator sees on success and failure | Pass | inline failure copy, saved state, ack silent and failed paths, cold-start presentation |

## Decision

decision: GO

All criteria met. The D-1 defect is fixed with the canonical teardown, verified at source across every exit path; the recommended T-100 coverage is added and green; the gates re-run green and were re-read from their bundles; the notes corrections are applied. The declared residuals (device obligations, owner items, the pre-existing red UI trio) carry to the remaining gates and do not block review-implementation. The workflow exit condition (review GO) is met.
