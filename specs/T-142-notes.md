# T-142 — Security evidence index (E1..E8, V-1..V-4, M-1..M-5, R1..R5) — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`, HEAD `5860878` = W6). Unit: TG-28, wave W7;
task type documentation-only (no builds, no tests run, no build lock, no git
actions). Requirements: NFR-MTC-004 (log safety), NFR-MTC-008 (answer
sanitisation / injection safety), NFR-MTC-012 (compliance and release gates).

## Status

**Done.** `specs/MTC-security-evidence-index.md` exists with every E/V/M/R row
populated from the committed producer record; the row structure passed the
mechanical check (E 8/8, V 4/4, M 5/5, R 5/5, all cells non-empty, all 8 E-row
pointers reproducible, 43/43 cited `<Suite>.<test>` tokens exist in the test
target) and the scenario-3 failure path was exercised on a mutated copy. No row
is incomplete; no content, user text or fixture literal is embedded. No commits;
this notes file and the index are the only files touched.

## Files created

- NEW `specs/MTC-security-evidence-index.md` — the deliverable; sha256 as
  reviewed `e6d1c17c9d4e4ed90c0ce88d700c7935939efd87ba7fe8c37839a1dc621d648d`,
  corrected final
  `d03d8dc4dc001807018145b6b58a1c99e26872bd532891b1cf84997c4c430617`
  (W7-review corrections applied in place, no errata block; see the W7 review
  corrections section below).
- NEW `specs/T-142-notes.md` (this file).

Nothing else was touched: no Swift, test, tooling or `.ai-sdd/` file; no
`specs/implement-notes.md` edit (its uncommitted hash fill was left alone); no
build ran; no `git` command was issued.

## Sources read

- `specs/security-design-review.md` — the ledger: evidence obligations E1..E8
  (row identities and obligation text), verify-and-record V-1..V-4, conditions
  carried M-1..M-5, accepted residuals R1..R5.
- Producer records: `specs/T-138-notes.md`, `specs/T-139-notes.md`,
  `specs/T-140-notes.md`, `specs/T-141-notes.md` (the committed, corrected
  revision — W6 review F-1/F-2/F-6 were applied in place pre-commit),
  `specs/T-143-notes.md` (context; not an E producer), `specs/T-131-notes.md`,
  `specs/T-133-notes.md`, `specs/T-136-notes.md`, `specs/T-137-notes.md`.
- `specs/implement-notes.md` §1 per-unit rows, §2 wave log, §3 gate bullets
  (W1..W6; the W5 and W6 bullets carry the gate commands and numbers).
- `specs/implement-review-w5.md` (F-1 scoped marker-scan citation, F-3 fixture
  literals) and `specs/implement-review-w6.md` (F-3 coverage boundary, F-5 S3
  division of labour, the measured-base supersession).
- The suites for exact class/method names and invocation evidence:
  `ios/ElderlyAssistantTests/Services/Voice/DialogueHostileCorpusTests.swift`,
  `…/DialogueTrapMatrixTests.swift`, `…/DialogueCacheBypassTests.swift`,
  `…/DialogueAcceptanceTests.swift`, `…/CommandRouterDialogueTests.swift`,
  `…/DialogueAnswerPathTests.swift`,
  `ios/ElderlyAssistantTests/App/DialogueCoordinatorWiringTests.swift`,
  `ios/ElderlyAssistantTests/Services/Observability/DialogueLogAndEgressTests.swift`,
  `…/LogSanitiserTests.swift`.
- The task files for the M-row DoD lines: T-131 (`:102`), T-133 (`:118`),
  T-136 (`:102-104`), T-137 (`:64`), T-139 (`:73`).
- `specs/multi-turn-conversation/workflow.yaml` (`:165-173`, the `security-test`
  step this document feeds). Prior-feature evidence indexes
  (`specs/LCT-security-evidence-index.md`, `specs/SP-security-evidence-index.md`)
  were consulted for format discipline only.

## What was built

### 1. Structure (the required shape)

Header (row identities, requirements mapping, honesty rule, validation note,
producer evidence records and retained-evidence pointers), then one table per
section:

| Section | Rows | Columns |
|---|---|---|
| E-rows | E1..E8 | ID \| obligation \| producer \| test or command \| observed result | pointer |
| V-rows | V-1..V-4 | # \| claim \| disposition \| where verified |
| M-rows | M-1..M-5 | # \| condition \| pinning task + DoD line \| pin (observed) |
| R-rows | R1..R5 | # \| residual \| accepted disposition |

Closing "Coverage boundaries / notes" (7 carried items + a record-status line).

### 2. E-row producer mapping (as the task file assigns)

- E1/E2/E3 → T-139 (hostile corpus + trap matrix); exact unit gate command,
  per-row method names, 114/114 with the W5 wave gate 157/157 as re-green.
- E4 → T-138 gate output (`bash ios/tools/check-release-log-safety.sh` rc=0;
  24 cases / 12 rules; `FEATURE_ROOTS` 17→21; fixtures 38→55 files; `--falsify`
  rc=0) plus T-140 capture (`DialogueLogAndEgressTests`, eight legs, seven
  markers, the claim SCOPED to bus-format sink lines per W5 F-1).
- E5 → T-137 allow-list (78→84 exactly +6; `reason` reused) plus T-140 runtime
  diff re-verification (84 keys; OOV redaction; producer-closed `reason`).
- E6/E8 → T-140 suites (source audit + 20 spy transports; the four cache-bypass
  rows incl. the causal A/B and the `pendingTranscript` pin).
- E7 → T-131 determinism (`testMergeIsAPureFunctionAndTheSourceConsultsNoModelNetworkOrCache`)
  plus T-141 prompt pins (`DialogueAcceptanceTests.testScenario3ThePhaseOnePromptPinsAndFileBytesHold`),
  with the W6 F-5 division-of-labour note (S3 covers the default prompt only;
  broader pins in `IntentPromptTests`).
- The V-3 re-verification → T-140 (recorded in the E8 row and the V-3 row).

Every E row carries the exact command (full `cd ios && ./build.sh test:unit …`
invocations, the gate script, or the fixtures `--falsify` command) and the
observed counts from the notes; every pointer names a `specs/…-notes.md`
section, a commit hash and/or a retained `/tmp` bundle.

### 3. Carried items recorded (constraints from the wave reviews)

- W5 F-1 — marker-scan claim cited scoped to bus-format sink lines only (E4 row
  and boundary item 1), with the did-you-mean spoken-output fact and R1 named.
- W5 F-3 — no test-fixture literals reproduced; hostile fixtures described, never
  pasted (boundary item 2 and the header honesty rule).
- W6 F-3 — FR-MTC-019 missing-time / missing-title ask-lines tested nowhere;
  recorded as a coverage boundary with the mitigations (handlers untouched;
  design-l2 Phase-1 no-change scope) (boundary item 3).
- W6 F-5 — S3's "Address them as" absence is default-prompt-only; division of
  labour recorded in the E7 row and boundary item 4.
- Measured base inventory (W6) — base `0cbe4e6` 6403 / 6357 / 36 / 10 with the
  36-item grouping, HEAD 6638 / 6620 / 8 / 10, scoped 13 vs 4, explicitly
  superseding the old "~21 pre-existing failures" figure (boundary item 5).
- Additional honest records: device validation outstanding by design (boundary
  item 6, pointing at `specs/MTC-device-validation-protocol.md`), and T-138's
  fixture scoping for rules 5/6 (boundary item 7).

### 4. NFR-MTC-004 discipline

The document is a pointer index: no raw console output, no transcripts, no user
or fixture content, no secrets, no marker tokens. All Nepali utterance text and
all fixture literals quoted elsewhere in the wave notes are referenced, never
reproduced (a machine self-scan for Devanagari characters, marker tokens and
fixture-domain shapes is part of the validation below).

## Structural validation (task Gherkin scenario 3 — ran and recorded)

Method: a python checker over the written markdown — it locates each `## <section>`
table, walks every row, and fails on: a missing/duplicate row id; a wrong column
count; any empty cell; any cell marked INCOMPLETE; and an E-row pointer cell with
no reproducible token (a `specs/…` file, a commit-ish hash, a command or a
`/tmp` path). A second check extracts every `<Suite>.<test>` token and requires a
matching `func` in `ios/ElderlyAssistantTests`. A third scan enforces the
NFR-MTC-004 self-discipline. Commands run in this worktree against the frozen
file; outputs below are verbatim summaries.

**Run 1 (first pass) — one checker artifact.** The run failed with a single
line: `the file contains the INCOMPLETE marker`. The token was the *rule
definition* in the header prose ("a row lacking its pointer is marked
INCOMPLETE"), not a row status — the checker's first pass matched the whole
file. Recorded so the false alarm is not read as a real row problem.

**Run 2 (cell-precise) — clean:**

```
== MTC-security-evidence-index.md structural validation (cell-precise) ==
E-rows: 8/8 rows, 6 cells each, all non-empty: PASS
V-rows: 4/4 (V-1..V-4): PASS
M-rows: 5/5 (M-1..M-5): PASS
R-rows: 5/5 (R1..R5): PASS
E-row pointers with a reproducible token: 8/8
No table cell marked INCOMPLETE: PASS
'INCOMPLETE' in prose (rule definition only, outside all tables): 2 occurrence(s)
NFR-MTC-004 self-scan (no user-language text, no marker tokens, no fixture-domain literals): PASS
FAILURES: 0
```

**Run 3 (frozen) — abbreviation expansion + token existence.** The first token
scan found one non-resolving entry: `DialogueTrapMatrixTests.testE3TrapRow` — an
artifact of an abbreviated citation (`…testE3TrapRow…` prefix form) in the E3
row, not a rotted name. Every abbreviated `…test…` citation in the document was
then expanded to its full `Suite.test` form (E1..E3/E5/E6/E8 rows and the V-1,
M-5 rows; 22 occurrences; final count of remaining abbreviations: 0). The
re-run:

```
== final validation (frozen) ==
E-rows 8/8 non-empty; V 4/4; M 5/5; R 5/5
E-row reproducible pointers: 8/8
cited tokens 43, all existing: True
NFR-MTC-004 self-scan: PASS
FAILURES: 0 []
sha256 e6d1c17c9d4e4ed90c0ce88d700c7935939efd87ba7fe8c37839a1dc621d648d specs/MTC-security-evidence-index.md
```

**Scenario-3 exercise (negative path).** On a /tmp-mutated copy (the E3 row's
producer cell emptied — "a row without a producer result"), the same checker
fails the record, while the frozen index passes:

```
scenario-3 exercise (mutated copy, E3 producer cell emptied):
  frozen index failures:  0
  mutated index failures: 1
   - E-rows E3: empty cell in column 2
  result: the mutated row fails the record (scenario 3 exercised)
```

## W7 review corrections (post-review, applied in place)

The W7 read-only review (verdict GO — Confidence 0.90, 0 blockers; report in
`specs/implement-review-w7.md`) returned three record corrections, applied in
place to the index by the session with no errata block (W6 precedent). The
reviewed revision was index sha
`e6d1c17c9d4e4ed90c0ce88d700c7935939efd87ba7fe8c37839a1dc621d648d`, notes sha
`bc7ebd847021d4d1db7f51850b4084c95980c350a91dbf04874dc0994100e95a`.

- F-1 (minor): the M-4 row cited `T-133-router-dialogue-interception.md:120` for
  the C-3 (carried) DoD item; the C-3 DoD item is on `:117` (`:120` is the
  V-1/V-4 DoD item). Corrected to `:117`.
- F-2 (minor): the V-1 row cited "verification ledger rows 25-26"; row 26 is the
  candidate-execution-shape / M-5 GAP row and does not support V-1. Corrected to
  "row 25".
- F-3 (note): the E2 row cited a `§E-row witness map` section that does not
  exist in `specs/T-139-notes.md` (that name is T-140's); the cited file's map
  section is "Integration notes — row → evidence map for T-141 / T-142".
  Corrected to the actual section name; the sibling E3 pointer was tightened to
  the same section name in the same pass.

The structural validation was re-run on the corrected index (equivalent
reconstructed checker, `/tmp/mtc-t142-validate.py`, output in
`/tmp/mtc-t142-validate.log`): E-rows 8/8 (6 cells each), V 4/4, M 5/5, R 5/5,
all cells non-empty, no table cell INCOMPLETE, E-row reproducible pointers 8/8,
cited `<Suite>.<test>` tokens 43/43 resolve to funcs in the test tree, NFR
self-scan clean (devanagari 0, marker tokens 0, fixture literals none) —
FAILURES: 0. Corrected index sha256
`d03d8dc4dc001807018145b6b58a1c99e26872bd532891b1cf84997c4c430617`; line count
unchanged (65). This notes file's own sha changes with this section; the review
file records the reviewed → corrected shas for both files.

## DoD checklist (task file `:57-61`)

- [ ] Code reviewed and merged — not this unit's to close (integration).
- [x] All Gherkin scenarios covered by the index structure check:
  scenario 1 — every E row carries producer, test/command and result; no row
  without a reproducible pointer (runs 2-3);
  scenario 2 — V-1..V-4, M-1..M-5, R1..R5 each recorded with disposition and
  evidence (run 2; V/M/R = 4/5/5);
  scenario 3 — a row without a producer result fails the record (mutation
  exercise above; a failing row is marked incomplete and no closure is claimed —
  no row is incomplete in the frozen file).
- [x] `specs/MTC-security-evidence-index.md` exists with every E/V/M/R row
  populated.
- [x] Each E-row records producer task, test or command and result — no assumed
  rows (8/8 pointer check; every command appears in the producer notes).
- [x] No content, PII or secrets embedded (self-scan PASS; no user-language
  text, no marker tokens, no fixture-domain literals).

## Deviations / open items

1. **Checker first pass had one recorded artifact** (the prose INCOMPLETE
   token); fixed by making the check cell-precise. Recorded above so the red
   first pass is understood, T-143 precedent.
2. **Abbreviated citations expanded.** The document cites every test method in
   full `Suite.test` form (no `…` prefixes) so each named test is machine-
   resolvable; the intermediate token check that forced the expansion is part of
   the record.
3. **No independent re-derivation of the producers' numbers.** Per the honesty
   rule and the dispatch, the index cites what was observed and committed (the
   producer notes, wave gates and retained bundles); it does not re-run suites
   or re-derive counts. Where a note's wording was corrected by a wave review
   (W5 F-1; W6 F-1/F-2/F-6 applied in place pre-commit), the corrected form is
   what is cited.
4. **M-2 residual scope carried, not closed:** the opener's supersede also
   covers `pendAppLaunch` and the voice-ack confirmation, only the four M-2
   sites are source-pinned, and the medication-challenge supersede path is
   behaviourally untested (T-136 F-4; recorded in the M-2 row as an open
   candidate for the next touch).
5. **V-2 anchor extension remains optional-at-next-touch** (T-136 F-5; recorded
   in the V-2 row).
6. **Device validation is out of scope here** and explicitly not claimed
   (boundary item 6): all DV items BLOCKED / step zero OUTSTANDING per
   `specs/MTC-device-validation-protocol.md`.
7. The `security-test` workflow step (`workflow.yaml:165-173`, focus comment
   naming emergency precedence, probe/answer log safety, recovery, degraded
   fallback and ladder bypass) reads this document directly; the coverage
   boundaries section names what the gate does **not** cover so the step cannot
   infer more than the evidence supports.
