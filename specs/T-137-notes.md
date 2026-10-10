# T-137 — LogSanitiser dialogue metadata keys (M-4) — Implementation Notes

**Unit:** T-137 (multi-turn-conversation, TG-27) — **Status: complete, focused suite green**
**Worktree:** /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation (branch `feat/multi-turn-conversation`)
**Date:** 2026-10-10

## What was built

The dialogue feature's four observability events (design-l2 §26) carry exactly seven
metadata keys: six NEW keys plus `reason`, which already exists in the allow-list. This
unit adds the six new keys with closed value vocabularies and fail-closed enforcement at
the choke point, and pins the reused `reason` key.

### Files modified

1. `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Services/Observability/LogSanitiser.swift`
   - `allowedKeys` (declared line 56): the six keys appended after `translated_text`
     (lines 343-348) with a `[MULTI-TURN-CONVERSATION T-137]` justification comment
     (lines 305-342) naming each key's closed token set. `reason` deliberately NOT
     re-declared — it has been in the list since the live-camera-translation work
     (line 175), so the dialogue feature reuses it.
   - New `static let closedVocabularyMetadataKeys` table (lines 447-454), with a doc
     comment (ending line 446) explaining the emission enums, why the bus bounds these
     six, and why `reason` is deliberately absent.
   - Enforcement branch in `sanitise(_:)` (lines 583-597): after the allow-list drop
     guard, before the code-shaped branch; out-of-vocabulary value is replaced by
     `redactionToken` and the pair is kept as `[redacted]`.
2. `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Observability/LogSanitiserTests.swift`
   - New section `// MARK: - Dialogue metadata keys (multi-turn-conversation T-137; M-4/E5)`
     (lines 391-636): 8 new tests plus two private fixtures — the pre-change 78-key
     allow-list snapshot (including `reason`) and the six-key vocabulary table pinned
     independently of production.

### The six keys and their closed vocabularies (design-l2 §26)

| key | closed tokens | emitting enum / bound |
|---|---|---|
| `intake` | `ladder`, `interpreted`, `candidate` | `DialogueDegenerateIntake` |
| `probe_kind` | `slotFill`, `candidateChoice` | `ProbeKind` |
| `attempt` | `"1"`, `"2"` | `DialogueConfig.maxProbes` = 2 |
| `option_count` | `"0"`..`"4"` | `DialogueConfig.maxSlotOptions` = 4; `0` = degraded probe |
| `capture_form` | `indexWord`, `optionName`, `repetition`, `freeText` | `CaptureForm` |
| `merge_source` | `catalog`, `freeText`, `candidate`, `defaultQuery` | `MergeSource` |

`reason` (reused): dialogue values are the `InvalidAnswerReason` raw values
(overLength / emptyAfterStrip / degenerateAnswer / noCandidateClaimed), closed at the
construction site; the bus does not constrain it (shipped generic key).

### Semantics

- Allow-list growth: **78 → 84 keys** (exactly +6). The default-deny drop of unlisted
  keys is unchanged.
- Fail-closed: an out-of-vocabulary value under any of the six new keys is replaced by
  `[redacted]` at the choke point (the pair is kept, so the event skeleton survives and
  a broken emitter is visible as a redacted legal key). This satisfies the Gherkin
  "out-of-vocabulary token values fail closed" scenario at the filter; for `reason` the
  producer (construction site) validates, per the scenario's "filter **or** event
  producer" wording.
- `redactedKeys` (content-by-declaration) runs first and is unchanged; the six new keys
  carry enum raw values or bounded counts by construction (NFR-MTC-004).

## Tests

Suite: `LogSanitiserTests` — 8 new tests added (26 → 34 total).

New tests (file lines 453-636):
1. `testTheSixNewDialogueKeysAreAdmittedAndInVocabularyPairsSurvive` — scenario 1; all
   eight in-vocabulary pairs (six keys + `reason`) survive; exact key set asserted.
2. `testEveryDocumentedDialogueTokenSurvivesTheFilter` — every token of every vocabulary.
3. `testTheDialogueVocabulariesAreClosedAndExactlyAsDocumented` — pins the exact table
   (count 6; `reason` absent from it).
4. `testAnUnlistedDialogueKeyIsDroppedAndTheAllowedPairsAreUnaffected` — scenario 3;
   camelCase near-twins and a Devanagari answer marker dropped whole.
5. `testAnOutOfVocabularyDialogueTokenFailsClosed` — scenario 4; near-miss shapes
   redacted, boundary tokens pass.
6. `testVerbatimAnswerTextUnderADialogueKeyIsReplacedNotScrubbed` — content-shaped
   values under all six keys become `[redacted]`; no-trace sweep over the whole
   sanitised event.
7. `testTheReusedReasonKeySurvivesDialogueTokensWithoutAnAllowListChange` — scenario 2;
   four `InvalidAnswerReason` tokens plus an unrelated shipped ledger token survive;
   pins that the bus does not constrain `reason`.
8. `testTheAllowListDiffIsExactlyTheSixNewKeysAndReasonIsUntouched` — the allow-list
   diff: added == exactly the six; `reason` in the pre-change snapshot; total 78+6.

Command (build lock held, per shared-worktree protocol):

```
cd /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios && ./build.sh test:unit LogSanitiserTests
```

Result (run 15:30:43–15:31:26, log `/tmp/mtc-t137-run-4.log`):

```
Test Suite 'LogSanitiserTests' passed
  Executed 34 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
  ✓ unit tests passed
=== Scoped unit run passed (baseline not advanced) ===
```

The release-log safety gate ran inside the same build (24 fixtures over 12 rules, all
green); it parses `LogSanitiser.allowedKeys`, so the 84-key list is gate-validated.
Standalone pre-checks before the suite went green: `xcrun swiftc -parse` (rc=0),
`xcrun swiftc -typecheck DependencyProtocols.swift LogSanitiser.swift` (rc=0),
`ios/tools/check-release-log-safety.sh` (rc=0).

## Definition of done

- [x] Code reviewed and merged — code complete and scoped suite green in the worktree;
  integration/merge happens from the main checkout per project rule, outside this unit.
- [x] All Gherkin scenarios covered by automated tests (`LogSanitiserTests` extended) —
  4/4 scenarios; 34/34 tests pass.
- [x] Exactly six new keys; `reason` untouched; unlisted-key drop pinned (E5 producer
  line) — diff test proves added == {intake, probe_kind, attempt, option_count,
  capture_form, merge_source}; total 78→84.
- [x] Justification comments with closed token sets present for every new key — lines
  305-342 (per key) and the table doc comment.
- [x] Focused suite green: `LogSanitiserTests`; no new full-suite failures — 34 tests,
  0 failures; run is scoped ("baseline not advanced"); full suite not run per standing
  protocol (focused tests + typecheck per unit; full suite once at the end).

## Decisions and deviations

1. **Vocabulary reconciliation (deviation from the T-137 task file's parenthetical token
   lists).** The T-137 file's implementation notes name `intake {keyword, interpreted,
   rephrase, remainder}`, `capture_form {catalog, anyOption, freeText, index}`,
   `merge_source {catalog, default, freeText, amendment}`. Those token sets appear
   nowhere else in the spec tree (grep-verified: only in the T-137 file itself, lines
   52-55) and match no emitting enum; two of the three would redact every legitimate
   emitted value. Implemented the design-l2 §26 vocabularies (authoritative; they match
   the emitting enums `DialogueDegenerateIntake` / `CaptureForm` / `MergeSource` and the
   already-landed sibling code). `probe_kind`, `attempt` and the option_count bound
   agree between both sources.
2. **Fail-closed at the bus for the six new keys; `reason` constrained at the producer.**
   `reason` is a shipped generic key (ModelBudgetPolicy denial/abandon tokens,
   live-translate cost reasons); narrowing it at the bus would re-mean it for existing
   emitters. M-4's closed-value requirement for `reason` is satisfied at the dialogue
   construction site and pinned by test 7. This matches the scenario's "filter **or**
   the event producer" wording.
3. **`option_count` pinned as 0..4** (`DialogueConfig.maxSlotOptions` = 4; `0` =
   catalog-unavailable degraded probe) rather than an open-ended count; T-137's
   "0..n bounded" is realized as design-l2 §26's `0..4`.
4. **Test-run timing:** earlier attempts (14:33–15:26) were blocked by cross-unit
   mid-edit compile state (sibling files T-131/T-136 in flight: `DialogueMerge`,
   `DialogueFrameResolution: Equatable`); per protocol these were retried, never fixed,
   and no file outside this unit's two was touched. The 15:30 run is the first clean
   compile and it is green.
5. **E5's end-to-end half** (capture sink through the production pipeline) is T-140's;
   this unit is the E5 producer line (allow-list + closed vocabularies + drop pin).

## Open items

- None blocking. Feature-level integration/merge and the full-suite sweep happen at the
  feature gate, not in this unit.
