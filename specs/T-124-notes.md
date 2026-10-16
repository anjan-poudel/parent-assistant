# T-124 — DV-1..DV-7 device-validation protocol and record — notes

- Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration`
- Branch: `feat/spotify-music-integration`, HEAD `4f6d4b1c3962eb8291ac2e3554b48d70345bf5a5` ("Implement spotify-music-integration W7 (T-123): security evidence bundle")
- Date: 2026-10-07
- Task: `specs/plan-tasks/tasks/TG-23-release-gates-security-evidence-and-device-validation/T-124-device-validation-protocol.md` (binding; 4 Gherkin scenarios and the DoD checklist)
- No commit was made (instructed). No product code and no test code were modified; `git status` shows only the new artifacts.
- **Execution key frame honored:** this task is owner/device-dependent. The authoring agent executed nothing on device or simulator — no simulator run was used to fill any row (the brief and FR-SP-017 both forbid it). Every DV item is recorded BLOCKED with its dependency named, and the record states explicitly that no device run has occurred as of authoring.

## What was produced

1. **NEW `specs/SP-device-validation-protocol.md`** — the DV protocol **and** the record skeleton in one artifact (the T-123 bundle cites this exact path for O6's DV-7 half; `specs/SP-security-evidence-index.md:128`,`:183`, with O6's pending at `:147`). Contents: purpose/scope with the FR-SP-017 binding and the simulator clause; environment/build-identity fields; the OD-S2 prerequisite block (registration checklist, account classes, quota-extension criteria) with every owner-specific value as `[OWNER INPUT]`; the "how to run this" owner procedure including the write-back location; DV-1…DV-7 each with device state, exact steps (utterances verbatim), expected observable outcome in the L1 table's wording with shipped line keys, pass/fail criteria, evidence field and record-as pointer; the record section (all seven items **BLOCKED**, dependency named) plus owner actions; the capture-discipline section (NFR-SP-002 applied to the capture and to the file itself; the capture doubles as security evidence obligation 6's device half); recording rules mirroring the LCT precedent.
2. **This file.**

## Sources read (all in the worktree)

- `specs/plan-tasks/tasks/TG-23-.../T-124-device-validation-protocol.md` — 4 Gherkin scenarios, implementation notes, DoD; `specs/plan-tasks/plan.md` (§ key risks 5/6, owner actions, "DV wording" note: T-124 adopts the constitution's DV table + the design's DV-7 expansion verbatim).
- `specs/spotify-music-integration/constitution.md` — the completion gate and the DV-1…DV-5 minimum coverage.
- `specs/design-l1.md:103-168` — the OD-S2 draft (§5: account classes, quota criteria, Dashboard checklist, scheme note), the DV-1…DV-5 table (:156-166), the unmet-item rule (:168), the degradation matrix (§12 :278-307).
- `specs/design-l2.md` — §6 marked gaps, §12/§13 (plugin + router matrix mapping), §17/§19 (settings/plist), §23 (:407-411: the DV-1…DV-7 list and the OD-S2 appendix), §26 (:509-561: redirect constant `sahayak-spotify://callback`, the M-3 two-scope set), §31/§32/§33 (copy inventory, budgets, log discipline).
- `specs/LCT-device-validation-protocol.md` + `specs/LCT-device-validation-results.md` — the format/storage precedent (per-item steps/pass/record discipline; the results shape mirrored in §6).
- `specs/SP-security-evidence-index.md` (T-123) — O6 pending, O8 pending, recorded limits 1–5; `specs/security-design-review.md:85-144` (obligation 6, M-1, V-2); `specs/T-123-notes.md`.
- `specs/define-requirements/FR/FR-SP-017`, `FR-SP-008`, `FR-SP-011`; `NFR/NFR-SP-002-log-safety.md`; root `constitution.md` (release gates, pre-release device check).
- `ios/ElderlyAssistant/Resources/Localizable.xcstrings` — every quoted string was dumped from the catalog and matches byte for byte (`spotify.*`, `spotifySettings.*`, `youtube.*`, `router.musicStub`).

## DV item inventory and statuses (as authored)

| Item | What it validates | Status | Named dependency |
|---|---|---|---|
| DV-1 | Stub → real playback flip ('भजन बजाऊ', unlinked + YouTube configured) | **BLOCKED** | Owner's device (Anzaan) + device Release build |
| DV-2 | Spotify-preferred selection ('गीत चलाऊ', linked Premium) **+ Dashboard-scheme acceptance via a real on-device link flow (V-2)** | **BLOCKED** | OD-S2 registration + owner's device + real Spotify account |
| DV-3 | Explicit-YouTube routing unchanged ('युट्युबमा गीत चलाऊ') | **BLOCKED** | OD-S2 registration + linked account + YouTube key + owner's device |
| DV-4 | Honest lines: free-tier / unlinked / airplane-mode / empty-search, each repeated ×2 | **BLOCKED** | Owner's device; (a) needs the OD-S2 free-tier test account, (d) the linked state |
| DV-5 | Nepali end-to-end for DV-1…DV-4 | **BLOCKED** | Owner's device + the DV-1…DV-4 states |
| DV-6 | Spotify app removed → honest app-absent/fallback | **BLOCKED** | Owner's device + linked/unlinked states |
| DV-7 | Console/sysdiagnose capture during DV-1…DV-6; zero tokens, credentials, query text or provider bodies | **BLOCKED** | Owner's device + OD-S2 registered accounts + the scripted session; doubles as security obligation 6's device half |

No DV item carries a result; the record's §6.4 states this plainly. The owner writes PASS/FAIL/BLOCKED into §6.2 when the run happens; the protocol text (§5) is not edited to match results (recording rule 4).

## Gate (required, run after authoring)

Command (serialized under the build lock, full output redirected — build.sh truncates its own tail):

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
  ./build.sh test:unit SpotifySecurityEvidenceIndexTests > /tmp/w8-gate.log 2>&1
```

Result: **GREEN** — exit 0. Log: `/tmp/w8-gate.log`.

- `Test Suite 'Selected tests' passed … Executed 8 tests, with 0 failures (0 unexpected) in 80.360 seconds` (the log's three `Executed 8 tests` lines are xcodebuild's duplicate suite lines, all 0 failures; the only `failure` strings in the log are the three `with 0 failures` lines).
- `** TEST SUCCEEDED **` — `=== Scoped unit run passed (baseline not advanced) ===`.
- The run executed the release log-safety gate ahead of the scope: `log-safety fixtures: 24 case(s) over 12 rule(s)` (green).
- xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.07_03-35-44-+1100.xcresult`.

Why this is the right gate: `SpotifySecurityEvidenceIndexTests.testTheBundleRecordsLimitsGapsAndTheDeviceRecordItPointsAt` is the machine check that pins this artifact's **exact path** (`specs/SP-device-validation-protocol.md`) from the T-123 bundle; the suite also refuses any device-run claim in the bundle and keeps O6 PASS-partial until DV-7 lands. The suite reads the bundle, not this file: the green run confirms the bundle still parses unchanged with the path cited and O6 kept PASS-partial. That the authored file actually lands at that path is verified by git/`ls` (both true), not by this run — the suite carries no file-existence check.

## Decisions

1. **One combined protocol-and-record file, not the LCT two-file split.** The T-123 bundle and design-l2 §23 name exactly one path (`specs/SP-device-validation-protocol.md`, with "+ results" only parenthetically at design-l2:115). The DoD line "Record referenced from the T-123 evidence bundle" is satisfied by the exact path; merging the LCT results shape into a §6 record section keeps one artifact the owner fills and the bundle cites. The protocol/record separation discipline is preserved inside the file (§5 protocol, §6 record; recording rule 4).
2. **No Swift machine check added — and why.** The LCT precedent pairs its protocol with a machine check only at the **index** level: `SecurityEvidenceIndexTests` asserts the LCT index contains the protocol path; it does not parse the protocol file itself. The Spotify equivalent already exists and is shipped: `SpotifySecurityEvidenceIndexTests.testTheBundleRecordsLimitsGapsAndTheDeviceRecordItPointsAt` asserts the bundle contains `specs/SP-device-validation-protocol.md`. Adding a new test that parses this file would be neither the precedent nor honest: the file is explicitly designed to be edited by the owner at run time (statuses BLOCKED → results), so any structural pin (e.g. "all statuses BLOCKED") would have to be dismantled when the device run lands, and a pin that asserts nothing about content adds no verification. Per the brief, none was added and this records why.
3. **BLOCKED statuses, never implied progress.** Every item uses the single status word BLOCKED with its dependency named in the same row; the outcome vocabulary (PASS/FAIL/BLOCKED) is defined only as what the owner will write, and §6.4 states no row carries a result. The ONLY "PASS-partial" string in the file is the accurate quote of the T-123 bundle's O6 status in the capture-discipline section, where the sentence itself says the obligation stays open.
4. **NFR-SP-002 applied to the record itself.** The three scripted utterances from the design are the only query-shaped strings in the file (they are protocol fixtures appearing verbatim in the constitution/design/golden corpus). Everything else is a line key, a count or a yes/no; DV-4(d)'s run-time utterance is explicitly not transcribed; DV-7's captures must be inspected and scrubbed before attaching (raw hits stay out of the repo). A forbidden-shape scan of the file (`spotify:track:<22>`, `Bearer <token>`, token-body JSON, `code_verifier=<value>`) returns zero matches.
5. **Localization checked from the catalog, not the design table.** Every quoted en/ne string was dumped from `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (`spotify.*`, `spotifySettings.*`, `youtube.*`, `router.musicStub`) and matches the shipped values; none is paraphrased.
6. **Scope-of-item wording kept to the sources of record.** DV-1…DV-5 wording follows the L1 table (quoted); DV-6/DV-7 follow L2 §23; the DV-2 scheme-acceptance step materializes V-2 (`security-design-review.md:126`, plan.md risk 6); DV-7 names obligation 6's device half per the security review and the T-123 pending.

## Deviations from the brief

1. **"design-l2 §12 (app-absent)"** — in the shipped design-l2, §12 is C-SP-05 `SpotifyPlugin`; the app-absent matrix rows live in **design-l1 §12** (the state × outcome matrix, rows 4/5/8) and its code mapping in design-l2 §13. The DV-6 wording follows design-l1 §12 (quoted via L1 :165) and the L2 §23 list; no content was lost.
2. **None otherwise.** The file path matches the brief exactly; no product code, test code, or T-123 bundle bytes were modified (the T-123 bundle's O6/O8 pendings remain, unaltered, as the brief requires).

## Open items carried (unchanged by this task)

- The device run itself: OA-1…OA-5 in the record's §6.3 (OD-S2 registration → device run → quota filing → possible non-Premium DV-2 deviation → any FAIL/BLOCKED resolution).
- T-123/O6 stays PASS-partial until DV-7's scrubbed capture lands in this record; T-123/O8 stays PASS-partial until the owner's Dashboard registration lands. Neither may be moved on any agent's word.
