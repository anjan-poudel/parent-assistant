# Implementation review — W7 (multi-turn-conversation)

**Reviewer:** sdd-reviewer subagent (read-only), orchestrated by the main session
**Reviewed revision:** branch `feat/multi-turn-conversation`, HEAD `5860878` (W6) + uncommitted W7 files
**Date:** 2026-10-11
**Verdict:** **GO — Confidence 0.90**
**Blockers:** 0 (2 minor record corrections, 1 note; both corrections applied in place pre-commit)

## Scope and method

Unit under review: **T-142** (security evidence index). W7 is documentation-only: two new spec files, no production source, no test source, no builds.

Read-only review. Reviewed revision sha256 recomputed — both match the dispatch pins: `specs/MTC-security-evidence-index.md` `e6d1c17c9d4e4ed90c0ce88d700c7935939efd87ba7fe8c37839a1dc621d648d` (65 lines); `specs/T-142-notes.md` `bc7ebd847021d4d1db7f51850b4084c95980c350a91dbf04874dc0994100e95a` (234 lines). Working tree verified: only those two files plus the W6 hash-fill line in `specs/implement-notes.md` (not this unit's delta).

Re-derived mechanically (not sampled): row structure / emptiness / INCOMPLETE-in-cell, all `<Suite>.<test>` tokens resolved against `ios/ElderlyAssistantTests` (43 unique / 51 occurrences vs observed), the scenario-3 negative path on a `/tmp`-mutated copy, the Devanagari / marker-token / fixture-literal / secret scan, git ancestry of all cited commits, retained `/tmp` evidence existence, the M-row DoD line numbers opened in the task files, the V-1 and V-4 test bodies read, the gate scripts and the `--falsify` option inspected, the NFR descriptors checked, and the device protocol §7.3 checked. Sampled/read (not re-run, per the unit's honesty rule): every producer count — 114/114, 117/117, 157/157, 65/65, 204/204, 24/12, 17→21, 38→55, 78→84, 6638/6620/8/10, 6403/6357/36/10 — verified against the committed producer records. No suite or gate was re-executed; the author's checker script was not retained, so its runs were validated by reconstruction (an equivalent checker), not byte-for-byte.

## Adjudications

- **A — sha256 pins.** Both match; line counts match. Not a blocker.
- **B — E-row facts.** All eight rows trace verbatim to the producer records: E1/E2/E3 to T-139's witness map (command verbatim at `T-139-notes.md:93`; 114/114 = 21+36+17+8+8+24; per-leg facts incl. the forced-no-op clear, `emptyAfterStrip` + re-probe attempts=2, six-stage sweep, `superseded ×1`, `timedOut ×1` + 1 s clock leg); E4 to T-138/T-140 (24 cases / 12 rules, roots 17→21, fixtures 38→55, `--falsify` rc=0, scoped build 10/10, 117/117 runtime, eight legs, seven markers, sink-line scoping); E5 to T-137/T-140 (78→84 exactly +6 with the correct key names, `reason` untouched, 34/34, OOV → redacted, drop-whole, `reason=overLength` closure); E6 to T-140 (117/117, five legs, 20 spies, unique-ordered anchors, offline helper only); E7 to T-131/T-141 (65/65, 36/36, pure-merge + source scan; S3 digests re-derived, three prompt files base-byte-identical, Phase-2 vocabulary absent, 2,506 ≤ 3,000, 4/4 green); E8 to T-140 (four rows named correctly; seeded-entry A/B, never-interned, Mirror/counters/six-region pin + call-turn control, negative control writes=1). All six wave commits + base `0cbe4e6` exist with the claimed subjects and ancestry.
- **C — V-row facts.** V-1 test body read (attempts==1, resolutions empty, dialogueEvents empty, interpretCount==0 — matches the parenthetical). V-2 matches T-136-notes F-5 almost verbatim. V-3 ledger row 20 correctly says HOLDS (V-3, R4). V-4 test body read (too-long utterance rejected, no `command_emergency_keyword`, frame non-nil, reprompt spoken).
- **D — M-row DoD lines.** T-136 `:102`/`:103`/`:104`, T-137 `:64`, T-131 `:102`, T-139 `:73` all quoted verbatim and correct. Two line-reference slips found at the index's own extra citations (F-1 below) — T-133's C-3 DoD item is at `:117`, not `:120`.
- **E — W5 F-1 / F-3 discharge.** E4's absence claim is scoped to "bus-format sink lines" with the W5 F-1 tag; boundary item 1 names the did-you-mean spoken-output fact and residual R1 — exactly the required discharge. No fixture literals from T-139-notes' prose appear (scanned).
- **F — W6 F-3 / F-5 + measured base.** Boundary items 3-4 match W6 F-3/F-5 exactly; boundary item 5 is the measured inventory (6403/6357/36/10; 15+17+2+1+1; 6638/6620/8/10 run 2 authoritative; 5 exact-name + 2 family + 1 flake isolated-green; base 13 vs HEAD 4 on 173), explicitly superseding the "~21" figure. The cited T-141-notes sha equals the corrected `f3edd2a2…`.
- **G — Honesty / no overclaim.** Device boundary item 6 verified against `specs/MTC-device-validation-protocol.md` §7.3 (DV-1..DV-5 BLOCKED, step zero OUTSTANDING). M-2's T-136 F-4 scope and V-2's F-5 optional anchor are recorded open, not closed. T-138 boundary item 7 marked "recorded, not a gap".
- **H — NFR header mapping.** The `NFR-MTC-012 (E4, E6)` mapping is defensible (NFR-MTC-003's Measurable clause requires the code-surface audit as NFR-MTC-012 evidence); all four referenced NFR files exist with matching descriptors.
- **I — Retained evidence.** All header/row `/tmp` pointers exist (`/tmp/mtc-w5-evidence/`, its `w5-gate.xcresult`, `/tmp/mtc-w6-evidence/`, `/tmp/t139-run4-green.xcresult`, `/tmp/t140-gate2.xcresult`, red `/tmp/t140-gate-red.xcresult`, `/tmp/mtc-t138-gate.log`, `/tmp/t140-gate2.log`). Gate scripts exist; `--falsify` is a real option; the fixture script resolves its root from its own path, so the index's invocation form is valid.
- **J — Notes-file observations.** "43/43 tokens" reproduced exactly; "remaining abbreviations: 0" accurate for `…test…` citations (three residual `…` glyphs are non-test-citation uses — log-line renderings and a path prefix). The "22 occurrences" expansion count is not independently verifiable (pre-expansion draft not retained); the end state is verified.
- **K — Not verified from sources.** No re-runs (by design); the author's exact checker / run-1 transcript reconstructed, not reproduced; `/tmp` bundle contents existence-checked only; per-commit file lists not re-derived.

## Per-item results (dispatch items)

| # | Item | Result |
|---|---|---|
| 1 | Structure (mechanical) | PASS — E 8/8 (6 cells, non-empty, 8/8 reproducible pointers); V 4/4; M 5/5; R 5/5; INCOMPLETE only in header prose; 43/43 unique tokens resolve to the correct classes; scenario-3 mutation reproduced (frozen 0 failures, mutated E3 producer-empty → 1 failure) |
| 2 | Citation accuracy vs producers | PASS with 2 line-reference slips (F-1, F-2); all numerics/names/commands trace |
| 3 | Carried items | PASS — W5 F-1, W5 F-3, W6 F-3, W6 F-5, measured base all recorded and matching |
| 4 | Honesty / no overclaim | PASS — T-136 F-4, V-2 F-5, T-138 scoping, DV BLOCKED all open; corrected T-141 forms cited |
| 5 | NFR-MTC-004 discipline | PASS — zero Devanagari, zero markers, zero fixture literals, no secrets (the two `sk-` substring hits are false positives from "ask-line(s)") |
| 6 | Notes-file honesty | PASS — method, all three runs (incl. the red first pass and abbreviation expansion), files touched, open items recorded; the checker's design cannot catch line-number slips (consistent with F-1 being an unintentional slip) |
| 7 | Sanitizer-pattern awareness | Not a defect — long camelCase identifiers present (known INJ-009 false-positive class); gated file unaffected |

## Findings

- **F-1 (minor, record).** The M-4 row cited `T-133-router-dialogue-interception.md:120` for the C-3 (carried) DoD item; `:120` is the V-1/V-4 DoD item and the C-3 item ("C-3 direct event construction carries `reason`; the metadata is never dropped") is at `:117`. The C-3 fact itself is real, discharged and reviewed; only the line number was off. Corrected in place.
- **F-2 (minor, record).** The V-1 row cited "verification ledger rows 25-26"; row 26 is the candidate-execution-shape / M-5 GAP row and does not support V-1. Corrected to "row 25" (V-4 and R5 already cite row 25 correctly).
- **F-3 (note).** The E2 row cited a `§E-row witness map` section that does not exist in `specs/T-139-notes.md` (that name is T-140's); the pointer remains uniquely resolvable. Corrected to the actual section name ("Integration notes — row → evidence map for T-141 / T-142"); the sibling E3 pointer was tightened to the same section name in the same pass.

## Session post-review actions

- F-1, F-2, F-3 corrected in place in `specs/MTC-security-evidence-index.md` before the W7 commit (no errata block), plus the E3 pointer precision tightening. Four single-line edits; line count unchanged (65).
- Sha chain: index reviewed `e6d1c17c9d4e4ed90c0ce88d700c7935939efd87ba7fe8c37839a1dc621d648d` → corrected `d03d8dc4dc001807018145b6b58a1c99e26872bd532891b1cf84997c4c430617`; notes reviewed `bc7ebd847021d4d1db7f51850b4084c95980c350a91dbf04874dc0994100e95a` → corrected `753b77bb755820ef779f5610b07a36dc316c7fe7981ed08ceac3d6431b9fc725` (the notes gained the W7-review-corrections section). The corrected files are the committed artifacts.
- Structural validation re-run on the corrected index (equivalent reconstructed checker, retained at `/tmp/mtc-t142-validate.py`, output `/tmp/mtc-t142-validate.log`): E 8/8, V 4/4, M 5/5, R 5/5, all cells non-empty, no cell INCOMPLETE, 8/8 reproducible pointers, 43/43 tokens resolve, NFR self-scan clean — FAILURES 0.
- Sweep awareness (ungated file): the index carries 5 known-class false positives — 4 INJ-009 (long camelCase test-method names on lines mentioning run/runtime; mechanics verified with the exact JS regex) and 1 INJ-011 (the E4 row quotes the real gate command; the pattern matches backtick + bash + space). Both are honest evidence in a file no ai-sdd path scans; no real injection or secret content. The gated file `specs/implement-notes.md` is sweep-clean (0 hits). Awareness for the `security-test` step: its content file must not quote the gate command in backtick-bash form, and its rows must avoid the long-camelCase-on-run-lines shape.

## Commit conditions

1. Commit the corrected delta: NEW `specs/MTC-security-evidence-index.md` (corrected sha above); NEW `specs/T-142-notes.md` (corrected sha above, including the W7-review-corrections section); this review file; the `specs/implement-notes.md` W7/T-142 row + W6HASH fill; and the T-142 complete-task record in `.ai-sdd/state/evidence/tasks.jsonl`. No production or test source in this commit.
2. After the commit, fill the W7 hash into `specs/implement-notes.md` (rides the next worktree commit / the integration step).
3. Retain `/tmp/mtc-t142-validate.py` + `.log` alongside the `/tmp/mtc-w5-evidence/` and `/tmp/mtc-w6-evidence/` sets as the T-142 evidence trail.
4. The `.ai-sdd` state is untouched by this unit except the post-commit complete-task record; no HIL items are open (`hil list` empty at W7).
