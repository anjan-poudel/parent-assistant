# Implementation review — W6 (multi-turn-conversation)

**Reviewer:** sdd-reviewer subagent (read-only), orchestrated by the main session
**Reviewed revision:** branch `feat/multi-turn-conversation`, HEAD `ac89744` (W5) + uncommitted W6 implementation
**Date:** 2026-10-11
**Verdict:** **GO — Confidence 0.90**
**Blockers:** 0 (3 minor record corrections, 3 note-level items)

## Scope and method

Unit under review: **T-141** (end-to-end acceptance and no-regression sweep). W6 is test-only + evidence; no production source in the delta.

Read-only review. Sha256 recomputed for all four dispatched files — all match: `DialogueAcceptanceTests.swift` `3e8e942a76f112de8e0f2c1500be7800f9314b75474d5f2bb80dacf563e4ce0b`; `SpotifyLocalizationTests.swift` `160381dee98f5093c3ea2a09ff2752e5ee1362c5dee4e622b58011a67c216487`; `LiveTranslateAllowListTests.swift` `5535886d5ddc32c07aaf97ad2826f915235a63e404a18a83eb6b89e7623e5d48`; `specs/T-141-notes.md` `54ede97797b9e06cccb4442452551539f775edc4645c3d716d4b7f3ea75afc90` (the notes-vs-draft difference is exactly the 2 declared SHA abbreviations). Walked all six xcresult bundles in `/tmp/mtc-w6-evidence/bundles/` plus the retained logs `/tmp/mtc-t141-*.log` with `xcrun xcresulttool` (summary + full test-tree walks, per-suite counts). Independently re-derived: `Localizable.xcstrings` key counts (base 1364, HEAD 1381, `dialogue.*` 17, Spotify inventory 20); `LogSanitiser.allowedKeys` base 78 → HEAD 84; the golden music block digest and the prompt-file base digests; the full ai-sdd INJ-001..020 + SEC-001..015 pattern sweep of the delta. Per the dispatch the full gate was not re-run; the retained bundles are the record. Prior reviews `specs/implement-review-w1..w5.md` were consulted for continuity only.

## Flagged-context adjudications

**A — Classification soundness: SOUND (all four sub-items).**
(a) `testTheSessionOpens…` family membership: bundle-true — the test failed in run1 only, is drawn in neither base sample, and its suite (`LiveTranslateSessionModelTests`) is red at base in both samples (base full: 3 members; base scoped: 8), same delivered-frame timeout family; the feature diff (16 production files) has zero contact with the LiveTranslate test tree (59 files scanned; 0 references to any touched Voice/Dialogue type). BASELINE-class family attribution holds; one record cell needed correction (F-1).
(b) `IntentEncoderSideloadTests` flake call: sound — the run2-only failure passed at base full, passed in run1, and the sideload bundle re-read is 11/11 green; its inputs are not in the diff; load context (run2's operation 2440 s vs run1's 1229 s).
(c) Run-to-run churn: real and disclosed — run1 ∩ run2 failure names = exactly 2. The classification rests on suite/family-level stability plus base reproduction, not per-name stability.
(d) Bundle walk: run1 6638/6620/8/10 with 8/8 names as recorded; run2 6638/6620/8/10 with 8/8 names as recorded; base full 6403/6357/36/10 with the 15+17+2+1+1 = 36 grouping reproduced exactly; base scoped 173/160/13 with 13/13 names reproduced; livediag 173/169/4; sideload 11/11. All match the record verbatim.

**B — W1 F-4 pin discharge: DISCHARGED.** Bounded edit (doc comment + `1341` → `1361`). Arithmetic re-derived: base 1341+3+20 = 1364; HEAD 1364+17 = 1381 = 1361+20; the assertion `catalog.count == baselineKeyCount + inventory.count` holds at HEAD. Pre-fix redness real (base's 36 includes the Spotify pin, old expectation 1361 vs 1364). Green in scoped3, run1 (not drawn), livediag, run2. Correct and minimal.

**C — LiveTranslateAllowListTests fix: CORRECT AND MINIMAL.** `LogSanitiser.allowedKeys` 78 → 84 with the added set = exactly {intake, probe_kind, attempt, option_count, capture_form, merge_source} (the T-137 keys; `LogSanitiserTests` declares the same six). The cross-check survives — the assertion still computes the declared union against the runtime set, so an undeclared production addition would still red the suite; not a rubber stamp. Feature-caused regression, fixed in-unit, green in livediag and run2.

**D — DialogueAcceptanceTests fidelity: FAITHFUL.** S1: anchor catalog re-verified (group 0 has exactly 4 options; दुर्गा → "durga bhajan"); frame assertions candidates==4 / defaultQuery "भजन"; merge equality `.answered(DialogueMerge(value: durga.query, capture: .optionName, source: .catalog))`; opener == `[YouTubeTool.appSearchURL(query:)]`; `L10n.fmt("youtube.openingSearch")`; guard legs interpretCount 0 (control 1) and all four egress spies empty. S2: A/B equality across RoutingResult, assistantSpoken, reminders title/hour/minute, calendarEventRequests (title-level — F-4), acknowledged/challenge IDs; live arm frame nil, empty resolutions, zero dialogue_* events; interpreter call fixed-points. S3: three base prompt digests re-verified against worktree and base; Phase-1 clause absence asserted on the default prompt (F-5); 2_506 pin and pinned homes present. S4: golden music digest independently re-derived; `musicBlockSlice` logic verified byte-identical to the PinnedSurfaceGuardTests technique. Determinism: synchronous completions, fixed 0.6 s / 5.0 s waits, no model on deterministic paths; green in both full runs and the dedicated scoped run (4/4). Self-containment: doubles file-private; repoRoot walks up from `#filePath`.

**E — Sweep record quality for T-142: CITABLE, with corrections.** All inventory numbers re-derived: totals, per-test names/suites for every sample, the 36-failure grouping, the console-vs-bundle discrepancies (run1 console 9 vs bundle 8, duplicate visible in the log; run2 console 13 vs bundle 8; base full console per-session line 1744/41 vs bundle 6403/36; base scoped console 16 records vs bundle 13), and the durations (run1 1229.440 s; run2 2440.153 s). Run1/run2/base records are non-sanitized and honest. Corrections required before T-142 cites it: F-1, F-2, F-6.

**F — Awareness items: CONFIRMED; nothing beyond.** The replicated ruleset shows exactly 6 INJ-009-class hits in `specs/T-141-notes.md` (long camelCase identifier runs on lines that mention runs), zero real injection content, and 0 hits in `specs/implement-notes.md`. The 2 abbreviated git SHAs resolve uniquely. One naming item for the reviewer-of-record process, not a defect: `specs/implement-review-w6.md` in the worktree was the Spotify feature's W6 record inherited at the feature base; the multi-turn wave pattern (w1..w5 already replaced in their wave commits) continues with w6 — the PR-time integration owns the collision.

**G — Delta hygiene: CLEAN.** W6 touches no production source. Exactly the four dispatched files plus `project.pbxproj` — which is exactly 4 insertions, additions-only, internally consistent (E74266D14019153DFC7DBC71 ×2, 819F386644095F0779C7B506 ×3). Only the two test-file edits touch existing files; the implement-notes change is the pre-existing W5HASH fill only.

## Per-unit results

| Unit | Verdict | Evidence |
|---|---|---|
| T-141 | **PASS** | Run2 full (bundle `Test-ElderlyAssistant-2026.10.10_22-00-27-+1100.xcresult`): 6638 executed / 6620 passed / 8 failed / 10 skipped; all 8 classified — 5 exact-name at base, 2 same-suite family members, 1 load flake isolated-green 11/11; base strictly redder in every paired comparison (base full 36 incl. the 15-record pre-existing timing family; base scoped 13 vs HEAD scoped 4 on identical 173 tests); DialogueAcceptanceTests 4/4 green in both full runs and scoped; log-safety gate 24 fixtures / 12 rules and prompt mirror (2717 bytes, 4 placeholders, 7 self-tests) green in-run. |

Scenario map: S1–S4 witnessed by `testScenario1..4` in `ios/ElderlyAssistantTests/Services/Voice/DialogueAcceptanceTests.swift`; S5 (full-suite record) discharged by the two full runs plus the measured base.

## Cross-cutting checks

- **Fidelity:** every S1–S4 witness traces to a shipped resource or pinned digest (catalog, prompt files, golden slice, L10n keys); no fixture-only overclaims found; resource facts independently re-derived.
- **Determinism:** the new suite has no network, no model on deterministic paths, synchronous completion, bounded waits; run-to-run membership churn is confined to the pre-existing timing family and disclosed.
- **Test hygiene:** doubles file-private; digests and counts pinned as literals; no sleeps beyond the bounded delivery wait; no test-order coupling.
- **No production delta:** verified — W6 is test-only plus pbxproj (additions-only) plus spec notes; `LogSanitiser.swift` untouched in W6 (its 78→84 state is W1/T-137, unchanged since).
- **Gate continuity:** release log-safety gate and the intent-prompt mirror ran and passed inside both full runs; W1–W5 pins carried forward by S3/S4 and remained green; no closed W1–W5 item regressed; W5 F-3 advisory stands as documented.

## Findings

- **F-1 (minor, record).** `specs/T-141-notes.md` line 108 stated "3 same-signature members in each sample"; the base scoped sample drew 8 members (3 is the base full number). Correction: "3 at base full / 8 at base scoped". Understates base redness only; no classification change.
- **F-2 (minor, record).** Lines 45 ("pre-fix tree"), 65, 131 framed run1 as preceding both declaration fixes. The F-4 pin fix demonstrably preceded run1 (scoped3 green at 20:06:53, before run1's 20:09:01 bundle; run1 draws no Spotify pin failure); only the allow-list fix postdates run1. Correction applied to all three passages.
- **F-6 (minor, record).** The `testScenarioTheDictionaryPathNeedsNoNetworkAtAll` classification row claimed "exact name reproduced", but run1's failure is the `LiveTranslateSessionModelTests` timeout variant while the base samples draw the sibling `LiveTranslationPipelineTests` consent-prompt variant (two distinct methods: SessionModel ~:278, Pipeline ~:532). Softened to family membership for the run1 variant (suite red 3 full / 8 scoped), sibling-suite variant as corroboration. BASELINE unchanged; the "7 of 8 exact-name or family" summary still holds.
- **F-3 (note).** FR-MTC-019's literal missing-time / missing-title ask-line cases are tested nowhere. Mitigated: the handlers are source-untouched (no CommandRouter hunk touches handleSetReminder/handleCreateCalendarEvent) and design-l2 scopes reminder/calendar behaviour as no-change in Phase 1. Carry to T-142 as a recorded coverage boundary.
- **F-4 (note).** S2's calendar A/B comparator compares request titles only, not startDate; prose tightened to "calendarEventRequests (titles)". No functional gap for the frame-guard claim.
- **F-5 (note).** S3's "Address them as" absence is asserted on the default prompt only; broader absence pins live at the home suite (`IntentPromptTests`). Record the division of labour when T-142 cites S3.

## Session post-review actions

- F-1, F-2, F-6 corrected in place in `specs/T-141-notes.md` before the commit (no errata block); F-4 wording tightened; a stray "scripted scripted" duplication repaired. F-3 and F-5 carried to T-142 as recorded notes (not blockers).
- Notes sha: reviewed `54ede97797b9e06cccb4442452551539f775edc4645c3d716d4b7f3ea75afc90` → corrected `f3edd2a20f6696d8b46e51e4101bada763c0271d11550bb31e64dd8c322a6cd2`; the corrected file is the committed artifact.
- Naming hazard (awareness): the w6 review file in the worktree carried the Spotify feature's record at the feature base; w1..w5 were already replaced by multi-turn reviews in their wave commits. The integration/PR step owns the collision decision for master's Spotify review files.

## Commit conditions

Commit the reviewed delta as-is: NEW `DialogueAcceptanceTests.swift`; M `SpotifyLocalizationTests.swift`; M `LiveTranslateAllowListTests.swift`; regenerated `ios/seniOS.xcodeproj/project.pbxproj`; NEW `specs/T-141-notes.md` **with the F-1/F-2/F-6 corrections applied** (done, in place) — plus this review file. No production source in this commit; leave the pre-existing W5HASH fill in `specs/implement-notes.md` as-is and append the W6/T-141 row there after this review lands. Retain `/tmp/mtc-w6-evidence/` bundles and JSONs plus `/tmp/mtc-t141-*.log` as the T-142 evidence source; T-142 should cite the measured base full (6403/6357/36/10; 36 = 15 timing family incl. SnapshotModeTests 10 + 17 /tmp-path artifacts + 2 timing margins + 1 pin + 1 glyph) as the supersession of the old "~21 pre-existing failures" figure.
