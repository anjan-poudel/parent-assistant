# T-127 — Shared input-seam helper (`IntentTranscriptPreparation`) — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`). Unit: C-MTC-08c, TG-24.

## Status

Done. Helper + tests landed and the focused gate is green (37/37 tests over the
two named suites, 2026-10-10 15:32 AEDT). One transient cross-unit compile
blocker was worked around by retrying the locked gate, per protocol — details
under "Open items / deviations".

## Files created / modified

- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Services/Intents/IntentTranscriptPreparation.swift`
- MODIFIED `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Services/Intents/LocalBrainChain.swift` (two additive edits: `turnInput` rewire, `transcriptPreparationSeam` accessor)
- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Intents/IntentTranscriptPreparationTests.swift`

No other file was touched (no `specs/` or `.ai-sdd/` edits beyond this notes
file; no git commands; no ai-sdd CLI).

## What was built

`IntentTranscriptPreparation.prepare(_ transcript: String, seam: LocalBrainChain.InputSeam?) -> Prepared`
— the ONE order both callers now run (`L2-D14`, design-l2 §15):

- `Prepared { raw, sanitised, prepared, pair }`, `Equatable`.
- **Nil seam** ⇒ `raw == sanitised == prepared == transcript`, `pair == nil`,
  and the sanitiser is deliberately **not called** — byte-parity with the
  shipped nil-seam path `LocalBrainChain.swift:275-285` (which returns
  `plainText: transcript` untouched). Test-only parity; production always
  wires the seam non-nil (`AppCoordinator.swift:1824`; M-3).
- **Non-nil seam** ⇒ `InputSanitiser.sanitise(transcript, level: .quarantine)`
  FIRST, then `seam.prepare(clean)`; `sanitised == clean`,
  `prepared == pair.pickerBrainInput` (the dialogue answer value),
  `pair == the seam's output`. The seam runs exactly once per call.
- Pure: no caching, no logging, no observability metadata, no clock
  (NFR-MTC-012 log-safety by construction).

### Chain rewire (behaviour-preserving byte-for-byte)

- `LocalBrainChain.turnInput(for:)` now calls the helper. Nil seam: returns
  `TurnInput(pair: nil, plainText: preparation.prepared)` (== transcript).
  Non-nil: keeps `Self.plainText(for: pair, raw: transcript)` unchanged.
- `LocalBrainChain.plainText(for:raw:)` is untouched, so the brain input is
  byte-identical for every pre-existing fixture (the existing
  `LocalBrainChainTests` suite is unmodified and is the regression gate).
- Both callers of `turnInput` (the command entry point and the `[CHAT]`
  `respondToChat` entry point) travel the helper with no behaviour change.
- NEW internal accessor `var transcriptPreparationSeam: InputSeam? { inputSeam }`
  (design-l2 §15, C-MTC-08c) for T-136's
  `prepareDialogueAnswerText` = `IntentTranscriptPreparation.prepare(raw, seam:
  brainChain.transcriptPreparationSeam).prepared`. Nothing consumes it inside
  this unit.

### Design / security obligations carried

- **C-5 (review-l2)**: the nil-seam raw-passthrough parity comment sits next to
  the `seam` parameter in the helper and cites the shipped path
  `LocalBrainChain.swift:275-285`; it also names `AppCoordinator.swift:1824`
  and states production wires non-nil and the branch is test-only. A
  source-scan test (`FeatureSourceScan` idiom) pins the wording and the
  existence of the two cited files/call sites.
- **M-3 (security-design-review)**: with a seam, the answer value derives from
  the sanitiser's output (`pair.pickerBrainInput`, whose `original` is the
  sanitiser's output), so no production path consumes an unsanitised answer;
  the nil-seam branch is documented as parity-only. T-136 re-pins the
  production wiring behaviourally per the task file.

## Tests

`ios/ElderlyAssistantTests/Services/Intents/IntentTranscriptPreparationTests.swift`
(8 tests):

1. `testT1TransformHitMatchesTheHistoricalTurnInputOutputsByteForByte`
2. `testT2TransformMissPassesThroughByteIdentically`
3. `testT3NilSeamIsARawPassThroughAndNeverRunsTheSanitiser`
4. `testT4ATransformHitNeverYieldsTheUntransformedTextAsPrepared`
5. `testM3TheAnswerValueIsSanitisedEvenWhenTheBrainReadsTheRawText`
6. `testTheShippedSeamComposesWithTheHelper`
7. `testPrepareIsPureAndRunsTheSeamOncePerCall`
8. `testTheNilSeamBranchIsDocumentedAndProductionWiresTheSeamNonNil`

Parity method: the oracle is the shipped caller, not a re-implementation — the
same fixture is driven through a real `LocalBrainChain` (the text actually
delivered to a brain, `StubCommandInterpreter.lastTranscript`, and the pair the
seam actually produced) and compared against the helper's values, plus literal
expected strings as an independent oracle. The transform-hit seam is the
production composition (`IntentInputCanonicalization.prepare` — the body of
`IntentEncoderWiring.localSlotInputSeam`) with an explicitly enabled policy and
a synthetic orthographic rule, since the shipped persisted toggle defaults OFF
and could not exercise a hit fixture; the shipped seam itself is exercised
policy-agnostically by test 6.

### Gherkin coverage

| Scenario | Tests |
|---|---|
| A non-nil seam produces the same prepared text as the historical path | T1 (hit), T2 (miss), `testTheShippedSeamComposesWithTheHelper` |
| A nil seam is a raw pass-through and is test-only parity | T3 + `testTheNilSeamBranchIsDocumented...` |
| A transform-hit input never yields an unprepared value | T4 (+ T1's pair/`prepared` equality) |
| The chain rewire changes no existing behaviour | existing `LocalBrainChainTests` unmodified + T1/T2/T3 chain-parity assertions |

### Results — GREEN (2026-10-10 15:32 AEDT)

Command (locked, per the protocol; worktree `ios/`):

```
./build.sh test:unit IntentTranscriptPreparationTests LocalBrainChainTests
```

- `IntentTranscriptPreparationTests`: **8 executed, 0 failures** — all eight
  passed individually, including `testTheNilSeamBranchIsDocumented...`
  (`xcresult` `Test-ElderlyAssistant-2026.10.10_15-32-24-+1100.xcresult`:
  37 passed / 0 failed, result `Passed`).
- `LocalBrainChainTests` (existing suite, **unmodified**): **29 executed, 0
  failures**.
- Total 37 tests, 0 failures; the log-safety and prompt-mirror gates ran ahead
  of the scope and passed.
- No full-suite run was made (per the dispatch protocol: focused suites only).

One defect was found and fixed by the evidence loop: the first draft of the
helper's C-5 doc comment line-wrapped the phrase "production always wires the
seam non-nil" across two lines, so the source-scan assertion
(`source.contains(...)`) could not match it. The sentence was re-wrapped so the
phrase is contiguous on one line; the green run above is the post-fix evidence.

## DoD checklist

- [ ] Code reviewed and merged — not in this unit (no git actions permitted here; the session integrates).
- [x] All Gherkin scenarios covered by automated tests (`IntentTranscriptPreparationTests`)
- [x] C-5 parity comment present in the helper (and pinned by a source-scan test)
- [x] Existing `LocalBrainChainTests` pass unmodified; no output diff on fixtures — 29/29 pass, suite file untouched
- [x] Focused suites green: `IntentTranscriptPreparationTests` (8/8) + `LocalBrainChainTests` (29/29) — no new failures introduced; a full-suite comparison was not run (protocol: focused only; baseline ~21 pre-existing master failures untouched by this unit).

## Open items / deviations

1. **Transient focused-run blocker (cross-unit, resolved).** The first attempt
   (14:34) could not compile the app target: `DialogueManager.swift` (T-125,
   concurrent unit) declared `case answered(DialogueMerge)` and
   `enum DialogueFrameResolution: Equatable` while `DialogueMerge` (planned
   home: T-131's `Services/Voice/DialogueAnswerPath.swift`) had not landed
   ("Cannot find type 'DialogueMerge' in scope" + the Equatable cascade). No
   error referenced this unit's files. Per protocol the gate was retried under
   the shared lock, never fixed here; the T-125 session landed a "wave-order
   home" for the three types in `DialogueManager.swift` at 15:26 and the
   retried run at 15:30 went green. Integration note for the session: T-131
   must NOT re-declare those types (a redeclaration is a compile error).
2. **`prepared` vs the brain path's `plainText` (intentional, documented).**
   With a non-nil seam whose pair is inert on a transcript the sanitiser
   rewrites, the dialogue answer value (`prepared` = `pair.pickerBrainInput` =
   sanitised) intentionally differs from the brain path's `plainText` (which
   keeps its raw-vs-picker equality mapping, i.e. the raw transcript). This is
   the L2-D14 split and the M-3 discipline; it is pinned by
   `testM3TheAnswerValueIsSanitisedEvenWhenTheBrainReadsTheRawText` so a future
   "unification" cannot silently reintroduce an unsanitised answer value.
3. `transcriptPreparationSeam` has no consumer inside this unit by design
   (T-136 wires it); it is internal and additive.
