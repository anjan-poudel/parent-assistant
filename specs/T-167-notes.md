# T-167 — Local chat decode shape and upgraded local persona (implement notes)

**Status: implemented, scoped suites green.** Worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`). No commits, no `ai-sdd` mutating commands.

## What was built

### 1. `ios/ElderlyAssistant/Services/Voice/ChatSampling.swift` (new — declared)

The chat shape's decode parameters and the per-turn override, in one namespace:

- `chatTemperature: Float = 0.3` — the reviewed chat value (design-l1 OD-1), a named constant,
  deliberately NOT a mutation of `OnDeviceSampling.temperature` (the command constant is untouched).
- `chatSeed: UInt32 = OnDeviceSampling.fixedSeed` — one fixed seed for both shapes, recorded by name.
- `DecodeParameters { temperature, seed, schema }` (Equatable) — the requested-parameters record;
  `schema` is the GBNF schema string itself.
- `commandParameters` (temp 0, fixed seed, `LlamaGrammar.commandJSONSchema`),
  `chatParameters` (0.3, fixed seed, `LlamaGrammar.chatJSONSchema`),
  `deterministicParameters(schema:)` (temp 0 + fixed seed under a given schema — the judge path).
- `protocol ParameterHandle: AnyObject { func setDecodeParameters(temperature:seed:) async }` and
  `apply(_:to:) async -> DecodeParameters` — always writes, never skips on equal values
  (a skip-on-equal shortcut is the set-once defect the determinism tests exist to catch).
  Nothing here creates, loads or configures a model; no context allocation; no token-budget change.

### 2. `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift` (extended — declared)

- `lastDecodeParameters: ChatSampling.DecodeParameters?` — written at the START of every decode
  path: command, chat, the semantic judge, and the test seam.
- `generateOverrideWithParameters: ((String, String, Float) async throws -> String)?` — the
  parameter-carrying seam (additive; the pre-feature two-argument `generateOverride` keeps working
  and is adapted through `decodeSeam()`; when both are set the parameter variant wins).
- `ResponseShape` now derives its whole decode contract: `decodeParameters`, `temperature`,
  `schema` (from `decodeParameters.schema` — one source, no drift) and `systemPrompt`
  (command → the shipped `chatSystemPrompt` bytes; chat → the new persona constant).
- `runInference(prompt:shape:completion:)` — records the requested parameters first, then either
  runs the seam or, on the real path, awaits `ChatSampling.apply(parameters, to: llm.core)`
  immediately before `llm.core.generateWithConstraints(...)` (same actor → the write is ordered
  before the decode; the wrapper's fire-and-forget `LLM.temp` setter is NOT used).
- `judgeCandidates` — the judge is the second deterministic decode path on the same handle: it
  records and re-asserts `deterministicParameters(schema: LlamaGrammar.judgeJSONSchema)` (temp 0
  + fixed seed) before its own decode, so a chat turn at 0.3 cannot leak into a judge run.
- `extension LLMCore: ChatSampling.ParameterHandle` (file end, `#if canImport(LLM)`) — the real
  handle's conformance: `setParameters(seed:temp:)` onto the actor. The vendor chain rebuild
  (`llama_sampler_init_dist(seed)`) also restarts the dist RNG at the fixed seed per turn, which
  is what makes a repeated prompt decode byte-identically instead of continuing the previous
  turn's RNG stream.
- `chatPersonaSystemPrompt` (new constant) — the chat shape's system slot: a one-line transport
  wrapper (identity + the JSON wire contract) plus the spec's `persona_clause` line,
  **byte-identical to `tools/train-intent/seeds/nepali-chat-style-spec`** (see verification below).
  It is a single constant string so T-170's mirror script can read it.
- `isAvailable` and `warm` treat the parameter seam like the original seam (seam tests need no
  model, no load).

### 3. `ios/ElderlyAssistantTests/Services/Voice/ChatSamplingTests.swift` (new — declared)

20 tests. Acceptance mapping:

| Gherkin scenario | Test |
|---|---|
| chat turn decodes warm; record shows the chat value; chat schema unchanged | `testAChatTurnDecodesWarmAndTheRecordShowsTheChatValue` |
| command turn after chat re-asserts temp 0 + fixed seed + command GBNF | `testACommandTurnAfterAChatTurnReAsksForTemperatureZero` |
| two identical command decodes byte-identical | `testACommandDecodeIsByteIdenticalColdAndAfterAChatTurn`, `testCommandDecodesInterleavedWithChatTurnsStayIdentical` |
| chat reproducible at the fixed seed | `testRepeatedChatTurnsAskForTheSameBytesAtTheFixedSeed` (+ non-vacuity: `testTheSamplerDigestMovesWithTheParametersItPins`) |
| persona is the spec's persona | `testTheChatPersonaIsTheSpecClauseUnderATransportWrapper` (reads the artifact itself) |
| failure: set-once implementation fails the determinism check | `testASetOnceOverrideWouldLeaveTheChatTemperatureOnTheHandle` |
| failure: unreadable output abstains | `testUnreadableChatOutputAbstainsAndNeverFabricates` |
| failure: a second model instance | `testTheInterpreterCreatesExactlyOneModelHandle`, `testChatSamplingCannotCreateOrConfigureAModelHandle` |

Also: the named constants are pinned (`testChatSamplingConstantsAreTheReviewedValues`,
`testCommandParametersAreTheShippedDeterministicSet`), the per-turn handle discipline is pinned on
a recording handle (`testTheOverrideIsAppliedPerTurnAndNeverSkippedWhenValuesRepeat`,
`testCommandParametersGoBackOnTheHandleAfterAChatTurn`), the judge re-assertion is pinned
(`testTheJudgeReAssertsDeterminismAfterAChatTurn`), the command system slot is pinned byte-for-byte
(`testTheCommandSystemSlotIsUntouchedByThePersonaChange`), and the 1,024-token budget gets its
Character tripwire (`testTheAssembledChatPromptStaysInsideTheBudget`, ≤ 3,000 Characters,
chat assembly strictly smaller than the command assembly).

## Test results (exact commands)

1. `cd /Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies/ios && ./build.sh test:unit ChatSamplingTests`
   → `Executed 20 tests, with 0 failures (0 unexpected) in 0.105 (0.120) seconds`, `** TEST SUCCEEDED **`, exit 0.
   xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_20-12-24-+1100.xcresult`

2. Scoped regression over every touched class (run after the final source edit):
   `./build.sh test:unit ChatSamplingTests ChatResponseShapeTests ChatConfidenceFloorTests IntentRouterChatRoutingTests LlamaCommandInterpreterTests LlamaSemanticJudgeTests IntentPromptTests`
   → `Executed 123 tests, with 0 failures (0 unexpected) in 0.731 (0.815) seconds`, exit 0.
   xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_20-15-39-+1100.xcresult`

3. Gates (all run, all green):
   - `python3 tools/train-intent/src/style_spec.py --check-consumers ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift`
     → `style-spec drift check: clean (1 consumer file(s)); version=1 sha256=64ada91d...46788`, exit 0.
   - `ios/tools/check-release-log-safety.sh` → exit 0 (24 fixtures over 12 rules).
   - `ios/tools/check-prompt-mirror.sh` → exit 0 (seed mirrors `IntentPrompt.build`; self-tests green).
     Both also run inside `build.sh test:unit`.

Byte-identity checks made outside the suite:
- Command system slot, HEAD vs working copy (re-derivation of the Swift multiline literal):
  both 633 Characters, sha256 `8ba8f380c71238fa965dbc61d6c13b7fa988d04027e04760bd6c28e93b517d8e` — identical.
- `IntentPrompt.swift`, the intent prompt seed and the command JSON schema literal: not modified
  (git diff surface only names the files below).

## Decisions and deviations

1. **Vendored runtime patch (file outside the declared set — REPORTED, not hidden).**
   `ios/vendor/LLM.swift/Sources/LLM/LLM.swift`: `setParameters(...)` changed from internal to
   `public` (plus a doc comment). Access level only — body, defaults and in-module callers
   unchanged. Why it is unavoidable: the design's plumbing (`await llm.core.setParameters(...)`)
   cannot compile from the app module while the method is internal, and the wrapper's `LLM.temp`
   setter is the `configure {}`-chained fire-and-forget path the design explicitly rejects (§5.2).
   No plan unit declares this file; the repo's convention is to patch the vendored runtime in
   place (the LLM.swift package is vendored under `ios/vendor/`). If the reviewer prefers, the
   alternative is a design-level change to the wrapper, out of this unit's scope.

2. **The judge path re-asserts determinism (additive, beyond the letter of the task).**
   `judgeCandidates` runs on the SAME resident handle; after a chat turn at 0.3 an unre-asserted
   judge decode would sample warm. The unit's own §5.2 argument applies verbatim, so the judge now
   records and applies `deterministicParameters(schema: judgeJSONSchema)` before its decode. Its
   observable behaviour today is unchanged (temperature was already 0 on the handle by default).

3. **No `chat_sampling_override_failed` event.** The vendored `setParameters` is non-throwing, so
   the design's throwing-failure event has no seam in this runtime; no dead code was added, and the
   honest failure surface remains `inference_empty_output` / `inference_timeout`. If the event is
   required, the vendor method must first gain a throwing path (design-level change).

4. **`chatSystemPrompt` became internal (`private static let` → `static let`).** Bytes unchanged
   (proven against HEAD above); the access level changed only so the chat-sampling suite can pin
   the command slot byte-for-byte. The T-170 mirror script reads source text, so it is unaffected.

5. **Existing chat tests: none needed in-place updates.** Checked
   (`grep -rln "chatSystemPrompt\|chatJSONSchema\|lastDecodeParameters\|chatTemperature"`):
   `ChatResponseShapeTests`, `ChatConfidenceFloorTests` and `IntentRouterChatRoutingTests` assert
   the chat SCHEMA and routing, not the persona bytes or sampling values — nothing was deleted or
   weakened, and all three stay green (regression run above).

6. **Reproducibility is pinned in-process; the device confirmation stays a DV item.** A unit-test
   process has no GGUF, so the suite pins the full decode INPUT (prompt bytes, schema, temperature,
   fixed seed) across repetitions plus a non-vacuous digest stand-in, and the source scan holds the
   single-handle invariant. On-device byte-reproducibility remains T-187's DV item — stated in the
   suite's header rather than claimed.

7. **`ios/seniOS.xcodeproj/project.pbxproj` changed** — regenerated by `build.sh` (XcodeGen from
   `ios/project.yml`), not hand-edited; this is how the two new files enter the targets. The
   worktree is shared with the sibling unit agents, so the diff also carries their file entries.

## Open items

- Device-side items owned elsewhere: DV-5 (command-after-chat determinism on the real handle) and
  T-187's reproducibility run.
- T-170 (prompt mirror) consumes `chatPersonaSystemPrompt`; the citation markers
  (`@style-spec-section: persona_clause` / `-end`) are already in place and the spec's own drift
  check passes on the file today.
