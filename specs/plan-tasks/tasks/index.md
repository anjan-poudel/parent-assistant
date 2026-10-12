# Implementation Tasks

Task breakdown for the feature `call-dialer-primary-secondary` (call dialer primary/secondary channel selection). The tree continues the cumulative project convention: group files live at this level, named `TG-NN-<slug>.md`, each holding the group's unit table and one `## T-NNN:` section per unit.

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-29](TG-29-chain-core-and-record-corrections.md) | Chain Core and Design-Record Corrections | 4 units (T-144..T-147) | ~5 days | PENDING |
| [TG-30](TG-30-voice-confirmation-and-launch-fail-hop.md) | Voice Confirmation and Launch-Fail Hop | 3 units (T-148..T-150) | ~4 days | PENDING |
| [TG-31](TG-31-tap-paths-dial-back-and-settings.md) | Tap Paths, Dial-Back and Settings | 4 units (T-151..T-154) | ~4 days | PENDING |
| [TG-32](TG-32-localisation-gates-and-evidence.md) | Localisation, Log-Safety Gate and Release Evidence | 3 units (T-155..T-157) | ~1.5 days | PENDING |

Totals: 4 groups, 14 units, ~13.5 dev-days of effort; critical path ~10 dev-days.

## Critical path
T-144 → T-145 → T-146 → T-147 → T-148 → T-149 → T-150 → T-152 → T-153 → T-157 (about 10 dev-days). The coordinator file serializes T-147 through T-153 behind T-146; the final unit is the barrier.

## Wave order (file-disjoint)
Computed with the installed runtime's wave planner against the declared dependencies plus file ownership (10 waves, max width 2, no cycles, group order TG-29 → TG-30 → TG-31 → TG-32):

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

The coordinator file is the dominant serialization resource: units T-146, T-147, T-148, T-149, T-150, T-152 and T-153 each own it and can never share a wave. The resolution suite file serializes T-145, T-146, T-149, T-150 and T-151 by the same mechanism. Parallel slots exist in W1, W3, W4 and W8.

## ID numbering convention
Groups TG-01 through TG-28 and units T-001 through T-143 belong to earlier features and remain in place (live-camera-translation T-001..T-030, profile-interview T-090..T-105, spotify-music-integration T-106..T-124, multi-turn-conversation T-125..T-143). This feature continues at TG-29 / T-144 (reserved by multi-turn-conversation's index). The next feature continues at TG-33 / T-158. Do not renumber or reuse ids: discovery spans the whole tree and duplicate ids hard-fail the unit planner.

## Requirement ID resolution
Requirement files live at `specs/define-requirements/FR/` and `specs/define-requirements/NFR/`. From unit sections in this folder, relative links climb two levels to reach them (target example: `specs/define-requirements/FR/FR-CDP-007-chain-preferred-secondary-phone.md`). Unit ids are plain (T-NNN) in every Depends on value; markdown links are used only for requirement links.

## Gates at a glance
- Scoped suites are the honest per-unit gate (the full bundle carries a known pre-existing red baseline and is not the gate). Every scoped run through the build script also executes the source privacy guard.
- The implement stage runs unit by unit in dependency waves with a paired challenger reviewer and a confidence threshold of 0.85, rework bound 5.
- Security conditions M-1, M-2 and V-1..V-6 are applied in T-144 before any affected unit runs; SA-1..SA-9 evidence lands per the mapping in the plan summary.
