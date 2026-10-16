# T-143 — DV-1..DV-5 device-validation protocol and record — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`, base cc065b0 — W4 committed). Unit: TG-28,
wave W5; task type **PROTOCOL** — authoring is agent work, execution is
owner/device-dependent. Requirements: FR-MTC-020, NFR-MTC-007, NFR-MTC-012.
Design references: the feature constitution's DV table (`:111-119`), design-l1 §6
(`:197-209`), design-l2 §16/§25-§28, `plan.md:239-241`/`:251-252`/`:283-289`.

## Status

**Done — deliverable complete; the device run is outstanding by design.**
`specs/MTC-device-validation-protocol.md` (new, 300 lines) carries DV-1..DV-5 with
verbatim item text from the three binding sources, step zero as the outstanding
Phase 0 PR #156 smoke (hard prerequisite; a failure stops the session with no
partial results), the per-session record format and the FR-MTC-020 completion
gate. The execution block is clearly owner/device-dependent: nothing in this unit
ran on a device, and **no DV item is claimed passed** — §7.3 records all five as
BLOCKED and step zero as OUTSTANDING. Missing execution is an open gate item at
final sign-off, not a missing deliverable (§8 mechanics item 5). No code, no
build, no lock, no git action, no `.ai-sdd/` touch.

## Files created

- NEW `specs/MTC-device-validation-protocol.md` — the deliverable: protocol body
  (§1-§5), the five DV items (§6), the record (§7), the completion gate (§8),
  capture discipline (§9), recording rules (§10).
- NEW `specs/T-143-notes.md` (this file).

Nothing else was touched. `specs/implement-notes.md` shows as modified in the
worktree but predates this unit (the W4 session's own edits); it was not opened
for edit. No Swift file, no test file, no `build.sh`/`device-install.sh` edit, no
`.ai-sdd/` file, no git command.

## What was built

### 1. Protocol body (§1-§5)

Governing quotes with cites (FR-MTC-020 `:10`/`:18`, NFR-MTC-007 `:12`/`:15`,
NFR-MTC-012 `:14`, feature constitution `:79`/`:119`, design-l1 `:209`); the
no-substitutes rule (simulator observations fill no row); the
environment/build-identity table (§2) with every unknown as `[OWNER INPUT]`; the
owner procedure (§4, six steps) written for a person holding the phone; and the
record fields + status vocabulary (§5): PASS / FAIL / BLOCKED, only PASS closes.

### 2. Step zero — the Phase 0 PR #156 smoke (§3)

Recorded as the hard prerequisite, **status outstanding at authoring**, quoting
the FR-MTC-020 Phase-0 Gherkin (`:31-35`) and the recorded merge gate of the fix
(`specs/fix-summary.md:213-221`, both bullets: a real conversation turn with the
explicit 4B pick, no jetsam kill; a fresh `JetsamEvent` pull compared against the
2026-10-10 08:57/08:59 baseline). Four steps (install/launch with the explicit
pick; one real turn; pull the JetsamEvent logs via the two documented routes;
compare). The failure rule is stated in §3, §4 step 1 and §8: **a failed step
zero stops the session, without partial results** — no DV item runs, nothing is
partially recorded; the items stay BLOCKED until the smoke passes on a fixed
build and is re-run.

### 3. The five DV items (§6)

Each item carries its item text **verbatim from all three binding sources**
(feature constitution `:113-117`; design-l1 §6 `:209`; FR-MTC-020 `:12-16`),
then source of record, preconditions, numbered steps, pass criteria, fail
criteria, evidence to capture (line keys / event names / counts / yes-no), and
the record-as pointer. Notable item content:

- **DV-1** one shot from a cold start (no live frame), free-form answer
  'दशैं दुर्गा भजन' (the design's pinned merge vector V4), pass rule includes
  "no re-probe" and "no literal top-hit guess" (the owner's example,
  `constitution.md:9`).
- **DV-2** the discriminating follow-up is 'गीत चलाऊ' — it would visibly re-probe
  if the frame had survived; the 45 s window is the single source
  `VoiceSessionStateMachine.Config.confirmationTimeoutSeconds` (design-l2
  deliberately has no `dialogue.timeout` key, `:740`).
- **DV-3** the design's pinned barge-in utterance 'मेरो छोरालाई फोन गर' mid-probe
  places the call with its normal confirmation and no residual frame.
- **DV-4** forcing honesty: no debug toggle exists to force the degraded pick, so
  the item gives the two design routes (pressure step-down per
  `PressureBrainPickResolver`; lightweight unload via
  `applyPressureBrainPickForTurn`) and requires the degraded pill
  (`home.degradedMode.pill`) as the in-force observation — otherwise the item is
  recorded **BLOCKED**, never passed on the structural argument that the merge is
  deterministic.
- **DV-5** a 12-turn scripted session (≥ 10 consecutive dialogue turns with
  probe→answer pairs and one degraded turn, NFR-MTC-007's measurable), covering
  all four capture forms (name, index word 'पहिलो', repetition, free-form), one
  cancel ('होइन', vector V9), and the post-session JetsamEvent pull attached;
  the did-you-mean leg is an optional extra turn (device brain/STT variance — the
  fixed fixtures remain the automated proof).

### 4. Record (§7) and completion gate (§8)

§7 defines the filling structure: 7.1 environment (one block, first run), 7.2 the
**session-block template, one per session, accumulated** (session-level date,
device, build, step-zero result + pull reference; per-item rows for dialogue
transcript, outcome, evidence; the session-level JetsamEvent pull attachment;
notes; tester), 7.3 item status as of authoring (all BLOCKED / step zero
OUTSTANDING — explicitly "not observations"), 7.4 owner actions OA-1..OA-5
(decisions, not measurements), 7.5 honesty notes (nothing fabricated; simulator
not a substitute; the step-zero rule is absolute).

§8 writes the FR-MTC-020 gate as the consumer: only PASS closes an item; FAIL and
BLOCKED hold sign-off; a failure blocks until a fix and a re-run are recorded
with the fixed build's identity; step zero gates every session; DV-5's pull is
part of the gate; and item 5, verbatim: "Missing execution is an open gate item,
not a missing deliverable." It also carries the T-143 Gherkin coverage table.

### 5. Capture discipline (§9) and recording rules (§10)

Line keys are the evidence, not audio; only the four content-free event names and
their closed vocabularies may quote from a console capture (NFR-MTC-004); the
JetsamEvent pull is attached as a file, unedited; no sensitive material beyond
the design fixtures enters the record. §10: every row filled or BLOCKED with
reason; measurements vs decisions as different columns; a failed check is a
finding, not a tuning invitation; this protocol is **not** edited to match
results (results go in §7).

## Verification (this unit's checks — a document, not a build)

### T-143 Gherkin coverage (task file `:26-51`)

| Scenario | Where the protocol satisfies it |
|---|---|
| The protocol covers all five device items | §6: DV-1..DV-5 each with verbatim item text (three sources), preconditions, steps, pass criteria; §5/§7.2 define the record fields per item (date, device, build, transcript, outcome, evidence pull) |
| The Phase 0 prerequisite gates the run | §3: step zero, hard prerequisite; "a failed step zero stops the session without partial results"; §4 step 1; §8 mechanics 2 |
| A failed item blocks final sign-off | §8 (FR-MTC-020 quote + mechanics 1), §7.2's block carries the re-run's fixed-build identity, §10 rule 3 |
| The run leaves no jetsam behind | §6 DV-5 + §7.2's session-level pull attachment; §8 mechanics 3 ("no new event for the app in the post-session pull") |

### Mechanical verification (run this session against the written files)

Normalized containment (whitespace collapsed; markdown emphasis and presentation
quote marks excluded on both sides), protocol vs sources:

```
15 item texts, 15 OK, 0 MISS   (5 per source: feature constitution :113-117,
                                design-l1 :209, FR-MTC-020 :12-16)
10 gate-quote phrases, 10 OK   (FR-MTC-020 Phase-0 Gherkin given/then/attach +
                                recorded-results; fix-summary.md:213-221 both
                                gate bullets incl. the trailing period;
                                NFR-MTC-007 measurable part A/B, evidence tail,
                                Release phrase)
backtick-parity scan: clean (no odd code-span lines)
```

An earlier extraction script had one artifact — it compared protocol text with
`**` stripped against source text with `**` kept, flagging the five FR-MTC-020
items; with symmetric normalization all fifteen are exact. Recorded so the check
is reproducible and the false alarm is not mistaken for a source mismatch.

## DoD checklist (task file `:67-72`)

- [ ] Code reviewed and merged — not this unit's to close (integration).
- [x] All Gherkin scenarios covered by the protocol structure and its checks
  (mapping table above).
- [x] `specs/MTC-device-validation-protocol.md` exists with DV-1..DV-5, step zero
  and the record format.
- [x] Phase 0 prerequisite recorded as step zero (PR #156 smoke outstanding —
  §3 status line, §7.3 table row, §7.4 OA-1).
- [x] Execution marked owner/device-dependent (§7.3, §8 mechanics 5); the
  completed record is verified at final sign-off before the gate can pass
  (§8 consumers).

## Open items / deviations

1. **The DV table lives in the feature constitution**
   (`specs/multi-turn-conversation/constitution.md:111-119`), not the root
   `constitution.md` — a root-file grep for "DV-1" finds only the Phase 0
   references (`:79`, `:119`). All DV item text is cited from the feature
   constitution; the root file is cited only for Phase 0 status and the owner
   example (`:9`).
2. **The record is merged into the protocol file (§7)** rather than a separate
   results document. The task file allows it ("or an appended record section",
   `:59-61`), and `plan.md:239-241` puts the feature record with the feature
   spec; one artifact means the §8 gate consumes one file, with one session-block
   template to copy per session.
3. **The JetsamEvent pull method is an owner choice with two documented routes**
   (on-device Analytics Data export; devicectl `systemCrashLogs` domain) because
   no canonical command is documented in the repo; the record names the method
   actually used.
4. **`ios/device-install.sh` builds Debug**, so DV-5's Release requirement must
   come via `ios/build.sh ipa` (Release archive, `build.sh:216-224`) or an Xcode
   archive; recorded in §2, and a Debug observation is recorded as Debug and
   never satisfies DV-5.
5. **DV-4 forcing has no debug toggle**: the protocol requires the degraded state
   observed in force (pill) and records BLOCKED if it cannot be forced — it is
   never passed on the structural argument. Stated in the item and in §7.3's
   dependency column.
6. **The did-you-mean leg in the DV-5 script is optional**: candidate-probe
   firing depends on the device brain/STT state on the day; the script does not
   depend on it, and the fixed fixtures remain the automated proof.
7. **Presentation conventions around the verbatim text**: the FR-MTC-020 item
   texts keep the source's internal bold and carry outer presentation quotes
   where the source uses a bold-prefix list format; the Phase-0 Gherkin is quoted
   joined across its Given/When/Then lines with " / " separators. The item text
   itself is byte-verbatim modulo those presentation marks (checker above).
   Chosen so a reader sees exactly which words are the source's, not the
   author's.
8. **Each item carries all three source texts, not one**: the three sources
   differ slightly in wording, and "do not paraphrase pass criteria" (task file
   `:54-55`) is honored by quoting each rather than merging. The pass criteria
   are the strictest reading of the three.
9. DV-3's utterance 'मेरो छोरालाई फोन गर' is also the regression-pinned
   zero-near-match utterance in `CommandRouterDegenerateTriggerTests` — the
   barge-in item is the live counterpart of that pinned seam, which is why its
   step text keeps the utterance exact.

## Integration notes for sibling units

- **Final sign-off consumes this protocol.** The workflow's `final-sign-off`
  comment (`specs/multi-turn-conversation/workflow.yaml:179`) — "DV-* device
  validation on Anzaan is part of the completion gate" — is the gate that
  evaluates §7: it cannot pass while the record is empty or any item is not
  PASS. This is the file that gate reads.
- **FR-MTC-020 is the gate requirement** (quote in §8): a failure blocks until
  fixed and re-run, no silent waiver; step zero is also the outstanding merge
  gate of the voice-OOM fix (`fix-summary.md:213-221`) — one smoke closes both.
- **NFR-MTC-012 release gates**: DV-5 must run on a Release build (NFR-MTC-007's
  "6 GB-class reference device in Release configuration"); the record must show
  it, or the gate holds.
- **W5 siblings (T-139, T-140, T-141, T-142)**: no interface with this unit.
  One caution: if any land changes affecting observable voice-turn behaviour
  before the owner runs the sessions, the tested HEAD differs from this
  authoring baseline (cc065b0) — the protocol covers this via build identity
  (§2), and the protocol text is never edited to match results (§10 rule 4).
  The owner schedules step zero after the tree is quiet for the smoke to mean
  what it says.
