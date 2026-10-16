# W8 Implementation Review — T-124 Device-validation protocol and record

**Reviewer:** sdd-reviewer subagent (read-only), orchestrated by the main session
**Reviewed revision:** worktree `feat/spotify-music-integration`, HEAD `4f6d4b1` + W8 working-tree changes (new `specs/SP-device-validation-protocol.md`, `specs/T-124-notes.md`; nothing else — verified by `git status --porcelain`)
**Date:** 2026-10-07
**Method:** everything below re-derived from disk, the binding sources, the recorded gates and parsed xcresults. The artifact's blocked statuses and honesty claims were treated as claims to falsify.

## Verdict (as returned)

**GO — Confidence: High.** All criteria met. The protocol records every DV item BLOCKED against its named dependency, matches the binding L1/L2 wording and shipped strings byte-for-byte, contains zero sensitive material, and is consistent with the T-123 bundle at the exact referenced path; the two gates are honestly green (8/8, TEST SUCCEEDED) and cannot be affected by these two new files. The two MINORs and four NITs are improvements for the owner-run phase, not rework conditions for this authoring task.

---

# W8 Review (T-124, device-validation protocol and record) — Verdict: GO

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration` (branch `feat/spotify-music-integration`, HEAD `4f6d4b1c3962eb8291ac2e3554b48d70345bf5a5`, matching the artifact's stated baseline). The two new files are `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration/specs/SP-device-validation-protocol.md` and `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration/specs/T-124-notes.md`.

## Scope verification

`git status --porcelain` shows exactly two untracked paths. No code, tests, pbxproj, or T-123 bundle bytes modified; the T-123 bundle is tracked and clean. HEAD unchanged (no commit), as instructed.

## Findings

- [MINOR] `specs/SP-device-validation-protocol.md:67,185,226` — the fixed-build re-run has no structured recording home. §4 item 5 (":68") instructs "re-run that item on the fixed build, record the fixed-build identity", but §6.1 (":185") declares §2's table "the single environment block for every item" and §8 rule 1 (":226") binds every row to that one block. A partial re-run after a FAIL (T-124 Gherkin scenario 2, and scenario 1's "each result is recorded with device, OS version, build identity") then has no field in which the per-item build identity can differ from §2 — precisely the case the LCT precedent's rule 1 forearms against ("in a column of its own", `specs/LCT-device-validation-protocol.md:276`). The result cell can informally carry it, so this is non-blocking; recommend a per-row run/build column or an explicit §6.1 sentence ("re-runs record their build in the row's Result cell; §2 keeps the original run's identity").
- [MINOR] `specs/T-124-notes.md:56` — overstated gate claim. "a green run here confirms the authored file lands at the referenced path" — the suite reads only the bundle (`SpotifySecurityEvidenceIndexTests.swift:49-56`, `:586-596`) and asserts the citation string is present; it cannot observe the file's existence. The file does land at the path (verified by `ls`/git), but that fact is not what the green run proves. The rest of the sentence (bundle unchanged, O6 kept PASS-partial) is accurate.
- [NIT] `specs/T-124-notes.md:12` — cites `specs/SP-security-evidence-index.md:126`,`:128`,`:183` as carrying the exact path. :128 and :183 carry it; :126 (O6's Output line) mentions the T-124 device capture but not the path string. Location-precision only.
- [NIT] `specs/SP-device-validation-protocol.md:157` — DV-6 attributes the app-absent `spotify.appMissing` outcome to "row 5"; the free-tier app-absent branch is row 4 (`specs/design-l1.md:295`), row 5 is the open-attempt-fails branch (`:296`). Both rows land on `spotify.appMissing`, and the item's source line (":154") correctly cites rows 4/5/8, so no content is lost — citing "rows 4/5" would be exact.
- [NIT] `specs/SP-device-validation-protocol.md:10` — attributes the "specifically no simulator run" statement jointly to "the T-124 implementation notes and FR-SP-017". The literal sentence is the task file's (`T-124-device-validation-protocol.md:52`); FR-SP-017:24 states the equivalent ("the device run is what signs the feature off"). Substance correct, attribution loose.
- [NIT] `specs/SP-device-validation-protocol.md:166` — DV-6's inclusion in the DV-7 scripted session is "where convenient", while T-124 scenario 3 asks that "the recorded capture shows the spoken outcome". DV-6's own line-key evidence field satisfies the record half; binding DV-6 into the session unconditionally would match the scenario more tightly.

None of these warrants rework: they are citation-precision items and structural improvements for the (not-yet-executed) owner run, not dishonest or incomplete protocol content.

## DV-1..DV-7 completeness (vs L1 table, L2 §23, task file)

| Item | Steps (utterance verbatim) | Expected outcome (L1-wording fidelity) | Pass/fail + evidence field | Status recorded | Verdict |
|---|---|---|---|---|---|
| DV-1 | 'भजन बजाऊ', unlinked, §2 YouTube state | `design-l1.md:160` quoted verbatim; line set matches matrix row 8 (`design-l1.md:299`) | Yes / line key + app + sound | BLOCKED (device + Release build) | Complete |
| DV-2 | 'गीत चलाऊ', linked Premium + real link flow = V-2 scheme acceptance (`security-design-review.md:126`) | `design-l1.md:161` verbatim + free-tier contingency (`design-l1.md:114`) | Yes / accepted scheme string, title heard yes-no | BLOCKED (OD-S2 + device + account) | Complete (Gherkin scenario 1's scheme clause explicitly carried) |
| DV-3 | 'युट्युबमा गीत चलाऊ', linked + YouTube key | `design-l1.md:162` verbatim | Yes / line key + deviation | BLOCKED | Complete |
| DV-4 | 4 sub-cases ('भजन बजाऊ' x3 + run-time utterance), each x2; rows 3/6/7/8 verified | Row-accurate, incl. airplane-mode keyless nuance | Yes per sub-case | BLOCKED; (a) names the free-tier-account dependency | Complete |
| DV-5 | Nepali re-run of DV-1..4 | `design-l1.md:164` verbatim; ne values byte-exact | Yes / all-Nepali yes-no | BLOCKED | Complete |
| DV-6 | 'भजन बजाऊ' + 'गीत चलाऊ', Spotify app removed, rows 4/5/8 | Matches app-absent path; V-4 `canOpenURL` probe semantics correct | Yes / line keys + status surface | BLOCKED | Complete (row-citation NIT above) |
| DV-7 | Scripted session = link, play, fallback, failure, unlink (`:166`) | Zero hits across both surfaces; scrub rule §7 | Yes / scrubbed capture + method + 0 hits | BLOCKED | Complete; "obligation 6's device half" consistent with bundle :121/:128/:183 and `security-design-review.md:141` |

Environment block §2: device, iOS version, commit, build number, build command, install method, tester, date, locale, Release mode — all present with `[OWNER INPUT]` for unknown values. OD-S2 block §3 covers client-ID paste (#4), scheme acceptance (#2), test users (#6), quota filing (#7), secret NOT USED (#5), sign-off (#8). All section/line citations spot-checked resolve (design-l1 156-168, design-l2 115/407-411/537/540, FR-SP-017, root constitution:95 verbatim, T-124 task).

## Honesty adjudication (load-bearing check)

- Headline at :9-10 states no device run, nothing filled from any run; §6 :181 repeats it; §6.4 :215 "No item is marked passed".
- All seven §6.2 rows BLOCKED with the clearing dependency named; §6.3 OA-1..OA-5 carry the owner actions.
- "No automation substitutes for this task: simulator runs do not satisfy FR-SP-017" present verbatim (:21; equivalent clause :10); plan.md risk 5 (`specs/plan-tasks/plan.md:79`) and the task file :52 support the citation.
- Unmet-item rule present (:22, :68, §6.3 OA-5); "PASS" appears only as the owner's future-write vocabulary and pass-criteria headings. `PASS-partial` occurs exactly once (:222), as the accurate O6 quote whose sentence says the obligation stays open.
- NFR-SP-002 on the file: independent scan (mirroring plus extending the T-123 suite's patterns at `SpotifySecurityEvidenceIndexTests.swift:571-576`) finds zero tokens, Bearer values, PKCE values, token-body JSON, emails, or URLs. Hits were only the intended commit hash, the worktree slug, test-method names, and the scheme descriptor `spotify:search:` / the pattern description `spotify:track:<22>` in the notes — no query text, no provider body, no real owner data anywhere.
- UI-string fidelity: every double-quoted UI string in the protocol is byte-identical to `ios/ElderlyAssistant/Resources/Localizable.xcstrings` — all 18 referenced keys checked (spotify.*, spotifySettings.*, youtube.*, router.musicStub), en and ne. The only non-catalog quoted strings are design/FR/task prose quotes, verified against their sources. The three protocol utterances appear verbatim in the feature constitution (:18/:51/:135), design-l1 (:160-162), and the golden corpus.
- Notable correctness strength: §3 row 3 correctly carries the M-3 two-scope supersession (`design-l2.md:211,:540`) against the stale three-scope wording still in `design-l1.md:125`, and warns against registering `user-read-playback-state` — matching the shipped test pin (`SpotifyAuthFlowTests.testAuthorizeURLRequestsExactlyThePinnedLeastPrivilegeScopeSet`, exists at `:89`).

## Gate honesty (parse-only)

- `/tmp/w8-gate.log`: `SpotifySecurityEvidenceIndexTests` only, 8/8, 0 failures, `** TEST SUCCEEDED **`; xcresult `Test-ElderlyAssistant-2026.10.07_03-35-44` — `xcresulttool` summary: 8 passed, 0 failed, result "Passed" (simulator, iPhone 17 Pro). Log-safety gate green ahead of scope (24 fixtures / 12 rules). The only "failure" strings in the log are the three "with 0 failures" lines, as the notes claim.
- `/tmp/w8-driver-gate.log`: same suite 8/8, `** TEST SUCCEEDED **`, run started after both files' mtimes (files 03:35/03:37; run 03:39:20), so it post-dates all W8 writes.
- The suite's inputs are `specs/SP-security-evidence-index.md` plus the `ios/ElderlyAssistantTests` test tree plus a `specs/` existence check — the two new `.md` files are outside all of them, and no file the suite reads changed at W8. The contains-check is exactly at `SpotifySecurityEvidenceIndexTests.swift:595`. The suite cannot be silently broken by this wave.
- Merged-file deviation (protocol + record in one artifact vs the LCT two-file split) is accepted: design-l2:407 names one path for the whole artifact, `specs/design-l2.md:115` says "(+ results)", and the T-123 bundle cites the exact single path; the protocol/record separation is preserved in-file (§5 vs §6, recording rule 4).

## Gherkin scenario adjudication (T-124)

| # | Scenario | Authoring-time verdict |
|---|---|---|
| 1 | Every DV item runs and is recorded | Satisfiable portion satisfied: the recording schema (device/OS/build §2, per-item rows §6.2), the DV-2 scheme-acceptance step, and the per-item evidence fields all exist. Execution is owner-dependent and explicitly not met (precondition "OD-S2 registration is in place" is stated as not done). Honest BLOCKED recording is the correct authoring-time state — the artifact does not pretend otherwise. |
| 2 | A failed DV item blocks completion | Rule fully recorded (:22, :68, :209, :215). Execution open by design. |
| 3 | App-absent degrades honestly | DV-6 defined against the design's app-absent path; execution open by design; NIT on binding DV-6 into the capture session. |
| 4 | DV-7 captures the log surface | Protocol fully specifies session coverage, inspection list, scrub rule, and attachment; execution open by design. |

DoD: item 1 (protocol authored) and item 4 (blocked items with dependencies named) satisfied; item 5 (record referenced from the T-123 bundle) satisfied — the bundle cites the exact path, now occupied; items 2-3 (executed records, DV-7 capture attached) remain open by design and are carried as such. Notes' §12 deviation claim verified true (design-l2 §12 is C-SP-05 SpotifyPlugin at :215; the app-absent rows are design-l1 §12), and the no-new-Swift-test reasoning checks out against the shipped test.

**Confidence:** High. Everything load-bearing — scope, honesty, string fidelity, gate honesty, citation accuracy — was verified directly against sources and recorded evidence; the residual findings are non-blocking precision/structure items.

---

## Post-review driver remediation (2026-10-07, main session)

Verdict was GO; all six non-blocking findings were applied pre-commit anyway (owner-run-phase improvements, as the reviewer framed them). Docs-only — no product code touched.

- **MINOR 1 (re-run build identity) — APPLIED.** §6.1 now adds: re-runs after a fix (§4 item 5) record their build identity in the row's Result cell; §2 keeps the first run's identity and the fixed-build row is the record the completion claim rests on.
- **MINOR 2 (notes overstatement) — APPLIED.** `specs/T-124-notes.md:56` now states exactly what the green run proves (bundle still parses, path cited, O6 PASS-partial kept) and that file existence is verified by git/`ls`, not by the run — the suite carries no file-existence check.
- **NIT:12 — APPLIED.** Citation corrected to `:128`, `:183` with O6's pending at `:147`.
- **NIT:157 — APPLIED.** DV-6's matrix citation reads "rows 4/5".
- **NIT:10 — APPLIED.** The simulator clause is attributed to the T-124 task file (literal) with FR-SP-017 as the equivalent.
- **NIT:166 — APPLIED.** DV-6 is now bound into the DV-7 scripted session unconditionally (its spoken app-absent outcome must appear in the capture — T-124 scenario 3), alongside DV-1/DV-3 where convenient.

**Gate standing.** No re-gate was required for these amendments: the completeness suite's inputs are the T-123 bundle and the test tree only (reviewer-verified at `SpotifySecurityEvidenceIndexTests.swift:595` and by source read; the driver's independent read agrees), and neither amended file is inside them. The authoritative W8 gates remain `/tmp/w8-gate.log` (agent, 8/8, xcresult `03-35-44`) and `/tmp/w8-driver-gate.log` (driver consolidated, 8/8, `** TEST SUCCEEDED **`, started 03:39:20 after all file writes). The six amendments changed no byte either run read.

**Residual state.** T-124's execution half stays open by design: all seven DV items BLOCKED with named dependencies (OD-S2 registration, owner device, real Spotify account), recorded honestly in `specs/SP-device-validation-protocol.md` §6. The T-123 bundle's O6/O8 PASS-partial pendings remain open pending the owner run and the OD-S2 registration. Nothing in W8 closes them, and nothing claims it does.
