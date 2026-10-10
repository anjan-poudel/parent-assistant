# W7 Implementation Review — T-123 Security evidence bundle

**Reviewer:** sdd-reviewer subagent (read-only), orchestrated by the main session
**Reviewed revision:** worktree `feat/spotify-music-integration`, HEAD `3519a34` + W7 working-tree changes (new `specs/SP-security-evidence-index.md`, `ios/ElderlyAssistantTests/Services/Spotify/SpotifySecurityEvidenceIndexTests.swift`, `specs/T-123-notes.md`; `project.pbxproj` [xcodegen])
**Date:** 2026-10-07
**Method:** everything below re-derived from code, artifacts, the recorded gate logs and parsed xcresults. Prose in the bundle and notes was treated as a claim to falsify, not evidence.

## Verdict (as returned)

**NO_GO** — narrow rework required. All nine obligations carry valid, executed, passing evidence and the machine enforcement is real, but two carried-forward claims in the bundle and notes assert design-l2 staleness that was already remediated before the bundle was finalized, and they omit the two locations that are genuinely still stale. The misstatement sits inside O8 — the entry whose pending gates the owner's OD-S2 registration — so it misdirects the one action the bundle instructs.

Confidence: 0.90.

---

# Wave W7 adversarial review — T-123 security evidence bundle

**VERDICT: NO_GO** — narrow rework required. All nine obligations carry valid, executed, passing evidence and the machine enforcement is real, but two carried-forward claims in the bundle and notes assert design-l2 staleness that was already remediated before the bundle was finalized, and they omit the two locations that are genuinely still stale. The misstatement sits inside O8 — the entry whose pending gates the owner's OD-S2 registration — so it misdirects the one action the bundle instructs.

Artifacts reviewed (worktree root `W = /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration`): `W/specs/SP-security-evidence-index.md`, `W/ios/ElderlyAssistantTests/Services/Spotify/SpotifySecurityEvidenceIndexTests.swift`, `W/specs/T-123-notes.md`, `W/ios/seniOS.xcodeproj/project.pbxproj`.

## Findings

**[MAJOR] R1 — O8's carried W1-F-2 finding names already-remediated locations and misses the genuinely stale ones, misdirecting the owed annotation.**
- Claims: `W/specs/SP-security-evidence-index.md:145` ("design-l2 §26 and the OD-S2 appendix still list three scopes … the §26 and appendix annotation is owed before or with the registration"), `:68` ("design-l2 §26 still lists three scopes"), `W/specs/T-123-notes.md:121` (same, citing the appendix as ":408").
- Disk state (verified): `W/specs/design-l2.md:540` (§26 constant) already reads two scopes with the M-3 supersession comment; `:411` (OD-S2 appendix) already reads "scopes = the two in §26 (M-3 supersession…)"; `:211` (§11 sign-in sentence) already carries the supersession note. All three landed in commit `a198830` (2026-10-07 00:14:46) — before the bundle's final write (03:03:08, mtime) and before the recorded run (03:03:12).
- Genuinely stale and unnamed: `W/specs/design-l2.md:213` ("authorize-URL contents (all three scopes…)" in §11's test-seam text) and `:383` (§22 suite table "authorize URL (three scopes…)").
- Impact: a verifier re-checking the claim finds it false (the same failure class the bundle's own "Related guards" row at `:166` exists to prevent); an owner or agent acting on O8's pending annotates §26/the appendix — a no-op — while the two sentences still claiming three scopes remain unflagged. Severity is MAJOR because the false text is inside the obligation entry and its pending instruction, and it under-warns where real staleness exists.
- Rework: correct the location/status text in `W/specs/SP-security-evidence-index.md:68,:145` and `W/specs/T-123-notes.md:121` to name §11:213 and §22:383 as the owed annotation and record that §26/:411 were fixed in `a198830`. Since bundle bytes feed the completeness suite, apply the task's freshness rule to the edited text (re-run or record the re-verified delta).

**[MINOR] R2 — Limit 6 misstates the design §31 copy table.**
- Claims: `W/specs/SP-security-evidence-index.md:188` ("The design §31 copy table on disk still shows the pre-amendment privacy sentence (T-120 decision D5)") and `W/specs/T-123-notes.md:122`.
- Disk: `W/specs/design-l2.md:758` shows the M-2-amended copy with the W6-closure annotation ("the row originally carried the pre-amendment sentence …; it now shows the M-2-amended copy exactly as shipped … so this sign-off artifact and the catalog agree"), committed in `3519a34` (02:46:25), before the bundle's final write. The pre-amendment wording survives only as an explicitly-marked historical quote. The error direction is conservative, but the claim is false as written.

**[NIT] R3 — the pending validator has no total-count cap.** `W/ios/ElderlyAssistantTests/Services/Spotify/SpotifySecurityEvidenceIndexTests.swift:277-301` enforces (obligation → required markers) per pending line; a second Pending line on O6/O8 containing the markers would pass. The shipped bundle has exactly the two expected pendings, so the "exactly two" property holds on the artifact; consider pinning the count if you want it machine-held.

## Verification performed (positives)

- **Machine enforcement** (code read + fixtures + seed run): missing obligation (`missingObligation`, `:123`; real-bundle set equality `:327`), duplicate sections (`:212-216`), missing/empty producer/command-or-artifact/output (`:140-167`), non-passing status incl. `PENDING` (`:169-171`), PASS/PASS-partial disagreement (`:174-184`), disallowed pending (O3) and missing-marker pending (O8) (`:511-541`), placeholder and unknown-test-token rejections (`:192-197`, `:252-266`) — each exercised by fixtures, and `/tmp/w7-gate-seed.log:66-78` records 11 failures in the rejection-fixture test plus 1 counts-seeding failure = the recorded 268/12, matching the notes' documented fix (the 11 are exactly the `rejects()` calls whose headings are not O1 under the pre-fix default range; the parser did throw — the naming asserts failed). Note: the seed xcresult (02:56:56) is no longer on disk; the log remains — retention observation, not a bundle defect.
- **Allowed pendings**: the validator permits O1 (optional, requires "T-124"+"device-build") — this matches T-123 scenario 3's clause — plus O6 (T-124/DV-7) and O8 (OD-S2/Dashboard). The shipped bundle uses exactly O6/O8, both PASS-partial with dependencies named, never implied pass.
- **Gate honesty**: xcresult `Test-ElderlyAssistant-2026.10.07_03-03-12-+1100.xcresult` parses to 268 total / 268 passed / 0 failed, result Passed; per-suite counts match the bundle's table digit-for-digit (13 suites). All 97 cited `<Suite>.<test>` tokens resolve to declarations and appear as executed, Passed cases in the xcresult. `SpotifyHostileCorpusTests` is confirmed not a class (helper enum only, `W/ios/ElderlyAssistantTests/Services/Spotify/SpotifyHostileCorpus.swift:16`); the 13-class set covers every cited suite — adequate freshness. `LiveTranslatePluginTests` is not among the 13, its branch-base red is established in `W/specs/implement-review-w6.md:105-118` (byte-identical `HomeSubviews.swift` at base `e2e2ae0`), and the W7 diff touches no product code (uncommitted set = 3 new files + pbxproj +4 lines adding only the new test file), so the exclusion cannot mask a W7 regression. An in-flight driver-gate result bundle (03:11:22) exists and was left untouched.
- **Secret scan re-derived independently**: repo predicates over `ios/ElderlyAssistant/` zero (exit 1); app image count 23 with identical attribution (0 app binary / 21 `ElderlyAssistant.debug.dylib` / 0 preview dylib / 0 plist / 2 test-bundle executable); S4a/S4b zero; the sole value-form candidate is a bare `client_secret=` with no value (byte-verified); all 23 lines are vendored AppAuth/GTMAppAuth symbol names plus two test-method names — predicates legitimate. Built plist: `SpotifyClientID` empty, no secret-named key. The three W7 deliverable files contain zero matches for the four forbidden shapes (track-id, bearer value, token-body, verifier). No sensitive values exist to report; nothing copied.
- **O7 spot-checks**: `W/ios/ElderlyAssistant/App/SettingsView.swift:909` renders the key; catalog en/ne values match the quoted copy exactly; `CommandRouter.swift` :2828/:2923/:2946/:3044/:3074, `SpotifyPlugin.swift` :130/:177/:199, `SpotifyAccountSession.swift` :228/:262/:427 all pin as cited; transport is header-only `Authorization: Bearer`, search `q=` = request text, play body `{"uris":[uri]}` only — the copy matches the flow, including the recorded token nuance. The bundle's O7 grep reproduces exactly the cited files.
- **Counts re-derived**: corpus = 88 entries / 13 categories / 43 at exactly 22 graphemes / 5+9 = 14 query fixtures (`W/specs/T-110-notes.md:123-162` V-1 record and `W/specs/T-121-notes.md` §2/§3 also check out; 24/12 gate in both logs; planted file removed, tree clean).

## Per-obligation adjudication

| # | Entry present | Evidence valid | Pending status honest |
|---|---|---|---|
| O1 | Yes | Yes — scan re-run by me; commands reproducible; tests executed+passed | n/a (PASS; no pending needed — image scanned, not deferred) |
| O2 | Yes | Yes — `StoragePlacement.swift:58`, `design-l2.md:144` verified; tests executed+passed | n/a (PASS) |
| O3 | Yes | Yes — validator/parser lines verified; 23 tokens executed+passed | n/a (PASS; device-console half routed to O6/DV-7, stated) |
| O4 | Yes | Yes — V-1 record at the cited range; tests executed+passed | n/a (PASS) |
| O5 | Yes | Yes — corpus counts re-derived (88/13/43/14); tests executed+passed | n/a (PASS) |
| O6 | Yes | Yes — gate re-ran clean; T-121 transcript referenced not copied | Honest — PASS-partial, DV-7/T-124 named, "has not run" |
| O7 | Yes | Yes — copy and all cited call sites verified against source | n/a (PASS) |
| O8 | Yes | Pin valid and executed; **carried F-2 finding text wrong (R1)** | Honest — PASS-partial, OD-S2 named, never passed on agent word |
| O9 | Yes | Yes — pin at `CommandRouterMusicTests.swift:1002-1028` verified; tests executed+passed | n/a (PASS) |

## To reach GO

Fix R1 (required) and R2 (recommended) in the bundle and notes, then re-verify the edited bundle bytes per the task's own freshness rule. Everything else in the W7 diff is GO-grade; no other change is requested.

**Confidence: 0.90.** All facts above were verified directly from disk, the recorded logs/xcresult, and commit history; the only judgment call is R1's severity (MAJOR vs MINOR) — I rate it MAJOR because the false claim under-warns about stale text and sits inside the gate-read artifact's obligation entry and pending instruction, but the facts themselves are not in doubt.

---

## Post-review driver remediation (2026-10-07, main session)

All three findings applied pre-commit; no product code touched.

**R1 (MAJOR) — APPLIED.** The stale-location text was corrected everywhere it appeared, naming the real state: §11:211, §26:540 and the OD-S2 appendix (`:411`) already carried the supersession annotation from `a198830`; the two genuinely stale prose sites were corrected at this closure, not left "owed":
- `specs/SP-security-evidence-index.md`: the pre-table note (`:68`), O8's Output tail (`:145`), O8's Pending line (`:147` — markers `OD-S2`/`Dashboard` preserved), the Related-guards row (`:166`), and gap 5 (`:187`).
- `specs/T-123-notes.md`: findings entry 1 (`:121`), pending 2 (`:117`), the O8 section prose (`:71` — same defect class, found by a driver sweep beyond the reviewer's cited lines; corrected for consistency).
- `specs/design-l2.md` §11:213 and §22:383 — the annotations the finding said were owed are now in place: §11:213 reads the two shipped scopes with `user-read-playback-state` asserted absent plus a dated `[M-3 supersession — W7 closure, 2026-10-07; W7 review R1]` marker; §22:383 reads "the two shipped scopes — M-3; read-playback pinned absent".

**R2 (MINOR) — APPLIED.** `specs/SP-security-evidence-index.md:188` (limit 6) and `specs/T-123-notes.md:122` now state the truth: `design-l2.md:758` shows the M-2-amended copy with the W6-closure annotation (committed `3519a34`); the pre-amendment wording survives only as a marked historical quote; no design-vs-catalog gap remains, and each corrected text records that the earlier wording was wrong (per W7 review R2).

**R3 (NIT) — APPLIED.** `SpotifySecurityEvidenceIndexTests.pendingViolations` now enforces at most one `- Pending:` entry per obligation (a second entry is a violation even when it names the dependency), and `testAPendingOutsideTheAllowedSetIsRejectedByTheSameValidator` gained the exercising fixture (duplicate marker-bearing pending on O6 must violate). Test count unchanged (8). Notes `:114` and `:81` updated to match the enforcement.

**Freshness rule applied (task's own re-verify clause).**
- Re-gate #1 `/tmp/w7-regate.log` — post-agent prose edits: `SpotifySecurityEvidenceIndexTests` 8/8, 0 failures, exit 0 (03:11:49–03:13:26).
- Re-gate #2 `/tmp/w7-regate2.log` — the final bundle + test bytes after the remediation edits: `Executed 8 tests, with 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`.
- The subsequent notes-only edits (`:71`, `:81`) touch no byte the suite reads: its inputs are the bundle file and the test-tree sources only (verified by source read — no reference to the notes or design docs).

**Residual state.** The recorded freshness run (`Test-ElderlyAssistant-2026.10.07_03-03-12-+1100.xcresult`, 268/0) remains the wave gate for the producer suites; the two re-gates above cover the W7-owned bytes. The reviewer's retention observation (seed xcresult no longer on disk; seed log kept) is accepted as-is — the log carries the failure transcript. No other change requested; the verdict conditions for GO are met at the amended revision.
