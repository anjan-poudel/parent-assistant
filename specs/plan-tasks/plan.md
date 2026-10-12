# Task Breakdown — Call Dialer Primary/Secondary (call-dialer-primary-secondary)

## Summary
- Task groups: 4 (Jira Epics, TG-29 through TG-32)
- Total units: 14 (T-144 through T-157; no subtask layer — every unit is a leaf)
- Estimated effort: ~13.5 dev-days of work; critical path ~10 dev-days; about 10 to 12 calendar days with the width-2 parallel slots
- Critical path: T-144 → T-145 → T-146 → T-147 → T-148 → T-149 → T-150 → T-152 → T-153 → T-157
- Wave plan: verified schedulable against the installed runtime's wave planner — 10 waves, max width 2, no cycles, group order TG-29 → TG-30 → TG-31 → TG-32
- Implement stage: unit-based, executed wave by wave from the dependency graph below; every unit is paired with a challenger reviewer and must meet the confidence threshold of 0.85 before merge; rework is bounded at 5.
- Scope fences: no router service and no per-contact primary/secondary storage anywhere in this plan (FR-CDP-018); the five-key bound, the GSM floor and the untouched emergency/override surfaces are enforced as acceptance criteria, not conventions.

## Contents
- [tasks/index.md](tasks/index.md) — navigation, wave order, numbering convention
- [tasks/TG-29-chain-core-and-record-corrections.md](tasks/TG-29-chain-core-and-record-corrections.md) — T-144..T-147
- [tasks/TG-30-voice-confirmation-and-launch-fail-hop.md](tasks/TG-30-voice-confirmation-and-launch-fail-hop.md) — T-148..T-150
- [tasks/TG-31-tap-paths-dial-back-and-settings.md](tasks/TG-31-tap-paths-dial-back-and-settings.md) — T-151..T-154
- [tasks/TG-32-localisation-gates-and-evidence.md](tasks/TG-32-localisation-gates-and-evidence.md) — T-155..T-157

## Task breakdown overview

| Group | Title | Units | Effort | Highest risk |
|-------|-------|-------|--------|--------------|
| TG-29 | Chain Core and Design-Record Corrections | T-144..T-147 | ~5 days | CRITICAL (T-145) |
| TG-30 | Voice Confirmation and Launch-Fail Hop | T-148..T-150 | ~4 days | HIGH |
| TG-31 | Tap Paths, Dial-Back and Settings | T-151..T-154 | ~4 days | HIGH |
| TG-32 | Localisation, Log-Safety Gate and Release Evidence | T-155..T-157 | ~1.5 days | HIGH (T-157 final barrier) |

Unit map in one line each: T-144 design-record corrections; T-145 chain file plus never-dead-ends matrix; T-146 coordinator resolution seams and secondary settings storage; T-147 resolver global-default closure; T-148 chain-before-prompt and disclosure; T-149 hop machinery; T-150 honesty guards (phone floor and whatsappChat disposition); T-151 address-book rows; T-152 family tiles; T-153 missed-call dial-back; T-154 secondary picker and accessibility (storage in T-146); T-155 five ne/en keys and coverage; T-156 privacy gate root; T-157 final integration and evidence sweep (final marker).

## Wave plan
Dependencies are declared per unit (plain ids in each group file's table and section Metadata); file ownership adds an overlap edge between any two units sharing a file. The installed runtime's planner computes from that input:

1. W1: T-144, T-155
2. W2: T-145
3. W3: T-146, T-156
4. W4: T-147, T-154
5. W5: T-148
6. W6: T-149
7. W7: T-150
8. W8: T-151, T-152
9. W9: T-153
10. W10: T-157 (final barrier; nothing runs after it)

Declared depends-on graph (edge means "must finish before"): T-144 → T-145, T-147; T-145 → T-146, T-156; T-146 → T-148, T-151, T-152, T-153, T-154; T-145 → T-154; T-148 → T-149; T-149 → T-150, T-152, T-153; every unit T-144..T-156 → T-157. File overlap additionally chains the coordinator-file units strictly in build order: T-146 → T-147 → T-148 → T-149 → T-150 → T-152 → T-153, and the resolution suite chains T-145 → T-146 → T-149 → T-150 → T-151. M-1 ordering requirement: T-144 (the disposition record) strictly precedes T-150 (the affected branch implementation).

## Critical path
T-144 → T-145 → T-146 → T-147 → T-148 → T-149 → T-150 → T-152 → T-153 → T-157, about 10 dev-days. It starts on the design-record corrections (they gate the chain tests' assertions), then runs through the chain file and the coordinator seams, and afterward serializes the coordinator-file units in build order — the file is owned by seven units and can never take two writers in a wave. The resolution suite adds the same constraint for its five owners. T-154 (settings screen) sits off the path in W4 because it is file-disjoint from the coordinator chain. The parallel slots that shorten wall-clock time are W1, W3, W4 and W8 (width 2 each).

## Key risks
1. M-1 ordering (HIGH): the whatsappChat false-result honesty change must not be implemented before the disposition record lands (T-144 before T-150). The dependency chain enforces this; the T-150 report must cite the T-144 anchor.
2. Coordinator-file serialization (MEDIUM): seven units touch one very large file; any rework in T-146 or T-148 cascades through all later waves. Mitigate by keeping the replace-not-widen discipline and by running the resolution suite at every coordinator unit.
3. Announcement byte-identity pin (MEDIUM): the no-fallback prompt must stay byte-identical while gaining a disclosure branch; the pin (testNoFallbackKeepsPromptByteIdentical) is source-level. If it proves brittle, tighten the composed-parts assertion rather than weakening the guarantee.
4. Numbering discipline (MEDIUM): the plan tree is cumulative; ids continue at T-144. Any reuse or renumber breaks the unit planner hard. Do not touch earlier units.
5. Pre-existing red baseline (LOW): the full test bundle has about 21 known unrelated failures; only scoped suites are the gate. Do not "fix" unrelated suites and do not treat the full bundle as evidence.
6. Fresh-worktree link (LOW): new worktrees need the whisper model and kws symlinks before the first link; budget for it in the first wave.
7. Residual security items R-1..R-7 (LOW): bounded by design (probe spoofing bounded by local-only probes; the pre-existing false-claim site closes in T-150); no plan change needed beyond the units as written.

## Security blockers and conditions
The security-design-review returned SECURITY-GO with zero open BLOCKERs; the plan nevertheless binds its two must-fix items and all six verify-and-record items as unit work, with the SA evidence obligations mapped to units:

- M-1 — design-l2.md:799 signature correction, :609 attribution correction, and the explicit disposition (i) recorded in the record: T-144 (corrections and disposition record); disposition (i) implemented and exercised in T-150 (speaks the shipped no-usable-number line on false; records no success, learning or activity); the pre-existing silent-false site closes there. T-144 strictly precedes T-150.
- M-2 — containment wording in design-l1.md:147 and design-l2.md section 6 plus section 19: T-144; the renamed order test (`testOrderContainsPhonePreferredFirst`) asserting containment + isFeasible(routed) + preferred-first and never last-element, with the attempt order not reordered: T-145.
- V-1 (.facebook to .faceTime), V-2 ("five shipped" to four verified constructions), V-3 (replacing() comment), V-4 record half (:975, :1174), V-5 (section 25 reader/writer list): T-144. V-4 implementation half (non-visual selected signal on both picker sections plus heading semantics): T-154, asserted in the picker suite. V-6 (test rename): recorded in T-144, executed in T-145.
- SA-1 (64-cell matrix, per-surface floor reachability): T-145 core, T-146 seam cells; SA-2 (at-most-once, termination, depth at most two, never re-pending): T-145 chain half, T-149 hop half, T-150 terminal halts; SA-3 (GSM floor per surface — voice, rows, family audio and video tiles, dial-back): T-146, T-148, T-149, T-151, T-152, T-153; SA-4 (emergency preservation, byte-unchanged regions, diff-clean override gate, no escalation-delaying awaits): T-148 pins, T-153 no-await inspection, T-157 full audit; SA-5 (announcement honesty, byte-identical no-fallback prompt, M-1 variant): T-148, T-149, T-150, T-157 sweep; SA-6 (privacy gate exit zero with the calls root, closed-token hop event, no new console writes): T-149, T-150, T-156, T-157 re-run; SA-7 (no new egress surface, plist byte-diff, single new store key, no per-contact storage): T-146, T-154, T-157 audit; SA-8 (exactly five keys, ne/en parity, no literals): T-154, T-155, T-157; SA-9 (persistence round-trip, absent and garbage fallback, legal equal picks deduped): T-145, T-146, T-154, T-157.

## Requirement coverage
- FR-CDP-001..003: T-146 (storage), T-154 (screen and tests); FR-CDP-004..005: T-146; FR-CDP-006..008: T-145; FR-CDP-009: T-146, T-152; FR-CDP-010: T-151, T-152; FR-CDP-011: T-153; FR-CDP-012: T-147 (consumed by T-148); FR-CDP-013: T-148; FR-CDP-014: T-148 (preservation pins); FR-CDP-015 .. 016: T-148, T-149, T-151; FR-CDP-017: T-155; FR-CDP-018: T-150, T-152, T-153, T-157; FR-CDP-019: T-157 (device checklist prepared; device pass is the downstream sign-off gate).
- NFR-CDP-001: T-145; NFR-CDP-002: T-146, T-151; NFR-CDP-003: T-150, T-156; NFR-CDP-004: T-149; NFR-CDP-005: T-146, T-154; NFR-CDP-006: T-154; NFR-CDP-007: T-155; NFR-CDP-008: T-145, T-157; NFR-CDP-009: T-148, T-152, T-153, T-157; NFR-CDP-010: T-156, T-157.

## Test-gate note
The honest per-unit gate is a scoped run, for example `ios/build.sh test:unit CallChannelResolutionTests`; each run also executes the source privacy guard before the tests. The full bundle carries a known pre-existing red baseline (about 21 failures, unrelated to this feature) and is never the per-unit gate. Fresh worktrees must symlink the whisper medium ne model and the kws assets from the main checkout before the first link. The final unit sweeps the whole feature family in one scoped command and re-runs the privacy gate formally.

## Ownership note
One recorded placement refinement against the design's presentational component list: the secondary settings storage (property, key, restore shape — design-l2.md section 11's C6 storage half) is implemented in the T-146 seams unit, so every seam consumer has its backing store from the first integration wave; the C6 view unit T-154 then owns the screen, the section semantics and the picker plus persistence tests. All other file ownership matches the design's component map.
