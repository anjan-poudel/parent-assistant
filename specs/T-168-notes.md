# T-168 notes — Cloud chat responder: conformance, spec persona and explicit temperature

**Status:** complete, tests green (27/27). Declared files only, nothing committed.
**Branch/worktree:** `feat/conversational-nepali-replies` @ `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`

## Files written (the declared set, exactly)

| File | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Gemini/GeminiClient.swift` | extend: `GenerationConfig.temperature: Double? = nil` (declared second, after `responseMimeType`); `generateJSON(prompt:useSearchGrounding:systemInstruction:temperature:)` gains the defaulted parameter and threads it into the config. Every existing call site is untouched and still passes no temperature. |
| `ios/ElderlyAssistant/Services/Voice/GeminiCommandInterpreter.swift` | extend: file-scope `GeminiChatConfig` (the reviewed chat temperature, `0.3`); `ChatResponding` conformance; `replyPersona` re-authored from the spec's `persona_clause`; `respondToChat` — the chat pipeline. |
| `ios/ElderlyAssistantTests/Services/Gemini/CloudChatResponderTests.swift` | new: 27 tests (below). Rides XcodeGen's directory-based sources — no pbxproj edit; `build.sh` regenerates the project each run. |

No other file was modified by this unit (verified with `git status`; the other dirty paths in the worktree belong to concurrent units T-167/T-172/T-173).

## What was built

### `respondToChat` (the responder seam)

Pipeline exactly as design §22: sanitise (`InputSanitiser`, `.quarantine` — the same shipping policy/level as `interpret`) → `IntentPrompt.buildChat` → `replyPersona` as the API system instruction → `generateJSON` with `useSearchGrounding: false` and `temperature: GeminiChatConfig.temperature` (0.3, OD-5, chat-only).

- **Egress scope (FR-CNR-010):** the payload carries the sanitised transcript rendered by the shared chat builder plus the persona — nothing else. Root keys are exactly `{contents, generationConfig, systemInstruction}`; ONE content (no history); no tools; the one context field the chat template never renders (`pendingMedications`) is constructed AWAY (`InterpreterContext(pendingMedications: [], …)`) so it cannot become reachable through a future template change; the plugin registry is never consulted on this path. `addressAs` and `userLanguageHint` are KEPT: the shared chat template renders both by design (§6.3, byte-mirrored by T-170) and the local chat path passes them identically.
- **Hygiene (FR-CNR-012):** the key travels in the `x-goog-api-key` header only (inherited from `GeminiClient.send`); zero console writes in the chat region; the whole file passes a source scan asserting every `print(`/`debugPrint(`/`NSLog(`/`os_log(`/`fputs(`/`dump(` sits inside `#if DEBUG` (the three pre-existing diagnostics remain Debug-only).
- **Governed transport:** the same `GeminiCostGovernor` gate sits before the network in `send` — no bypass exists on this path; the daily cap maps to a plain classified `nil` (`.quotaCapped`), never a substitute reply (the cap-honesty COMMAND belongs to the interpreter lane; T-175 owns the chat fallback).
- **Failure paths:** no usable key → `nil` + `.notConfigured` WITHOUT any network call or prompt construction; empty-after-sanitise → `nil`; malformed/empty/wrong-shape cloud answer (a non-`.chat` or unparseable body) → `nil` + `.invalidResponse`, never a fabricated or partial reply — the router's same-turn fallback owns the turn. Completion lands on the main queue (`ChatResponding` contract).
- **No confidence gate:** the local chat shape deliberately completes below its floor (a low-confidence chat answer is still a chat answer); the cloud lane keeps that contract identical. Only the SHAPE is gated: a non-nil result must be `.chat` (a chat turn never executes).

### The persona (FR-CNR-002)

`GeminiCommandInterpreter.replyPersona` is ONE constant: a minimal transport wrapper (role + answer-language line) whose last line is the spec's `persona_clause`, byte-identically (519 UTF-8 bytes, verified by python comparison and by the T-166 drift checker). Purpose: T-170 byte-mirrors the clause against `persona_clause()` so the local and cloud personas cannot drift. The constant carries the marker block (`@style-spec-section: persona_clause` / `@style-spec-section-end`) so the check reads this file like T-167's:

```
python3 tools/train-intent/src/style_spec.py --check-consumers \
  ios/ElderlyAssistant/Services/Voice/GeminiCommandInterpreter.swift
→ style-spec drift check: clean (1 consumer file(s)); version=1
   sha256=64ada91d2562bb71f446ea95d4e24d66e294184b4395ad2f99494ab5d0a46788 (exit 0)
```

`interpret()` is unchanged in behavior and still sends the same `replyPersona` (design §10/§22: the cloud persona is ONE constant; T-167 owns the local prompt). The intent call keeps its shipped request shape — no temperature ever — pinned below.

## Tests

Command (from the worktree's `ios/`):

```
./build.sh test:unit CloudChatResponderTests
```

Result (final run): **27 tests executed, 0 failures (0 unexpected), 1.271 s — TEST SUCCEEDED.**
xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_20-21-26-+1100.xcresult`

Coverage against the acceptance criteria:

- **Chat conformance / happy path:** answer delivered with the SAME `.chat` shape the local path returns (action/entryId/contact/time/medication/message/callType/requestedApp/confidence/reply); one transport send; completion on the main thread (asserted in the waiter).
- **Low-confidence still delivered** (no confidence gate, parity with the local chat shape).
- **Explicit temperature (OD-5):** `generationConfig == {responseMimeType, temperature: 0.3}` with the key set EXACT; `GeminiChatConfig.temperature == 0.3`; raw body carries `"temperature":0.3` as a number.
- **Chat request shape:** root key set exactly `{contents, generationConfig, systemInstruction}`; one content; prompt == `IntentPrompt.buildChat(transcript: clean, context:)`; systemInstruction == `replyPersona`; no `tools` (grounding stays an interpretation-call property).
- **Other call sites untouched (FR-CNR-011):** transcription (root keys `{contents}`), translation (root keys `{contents, generationConfig}`, config keys exactly `{responseMimeType}`), and `interpret` (root keys `{contents, generationConfig, tools, systemInstruction}`, config keys `{responseMimeType}`, `tools == [{google_search: {}}]`, prompt == `IntentPrompt.build(transcript:clean,context:activePlugins:[])`, systemInstruction == `replyPersona`) each compared to the shipped construction and checked raw for `temperature` ABSENCE.
- **Egress scope:** sanitiser pin (a control char + injection marker input is actually changed; prompt carries the cleaned text); no medication doses anywhere in the body; a registered `FakePlugin` probe's fragment never appears; no identifier/history/context-like keys anywhere in the tree; `addressAs: "अम्मा"` + `hint: "ne"` present exactly as the shared builder renders them (design, not leak).
- **Hygiene:** key header-only, absent from URL and body; no transcript/persona/key/error text on the bus (success or failure); chat region zero console tokens; whole-file DEBUG-gating scan; code-line count unchanged (`rawLines.count == codeLines.count`).
- **Failure paths:** malformed plain text → `nil` + `.invalidResponse` + `chat_respond_unusable`; `{}` → `nil`; a slot-bearing (action "call") answer → `nil` and never executed; missing key → `.notConfigured` + `sendCount == 0`; transport failure → `.transportFailed`; HTTP 429 → `.rateLimited` + `http_429` event code; provider block → `.invalidResponse`; capped governor → `.quotaCapped` + `sendCount == 0`.
- **Governor:** the chat attempt increments the persisted daily payload (asserted on storage, not the async `@Published` mirror); sharing the ONE budget — after the chat call fills the day to 10, a second chat turn is capped with `sendCount` still 1.
- **Persona:** embeds the spec clause byte-identically as its last line, exactly once, two lines total, under 1024 bytes; marker lines verbatim.

## Decisions, assumptions, deviations

1. **Wire-identity pin instead of raw byte equality (recorded deviation, with evidence).** The acceptance text says the untouched call sites stay "byte-for-byte". On this Foundation `JSONEncoder` fixes NO key order: two encodes of the same request in one process reordered members (run-2 diagnostics: chat captured led `{"generationConfig":{"temperature":0.3,"responseMimeType":…` where the shipped-construction expectation led `{"systemInstruction":…`, same 1377 bytes; `interpret` took 3348/3348 bytes with a different root order; the translate items reordered to `{"sourceLanguage","text","id"}`). Lengths and every key/value matched — only member order differed. The pin therefore compares CANONICAL bytes (parsed, re-serialised with `.sortedKeys`), which still moves on any added, removed or changed field — plus exact key-set assertions and raw `"temperature"`-absence checks on the captured body. No byte of controllable contract is unpinned. (Deliberate interpretation of the criterion, not a silent weakening.)
2. **`replyPersona` rewrite resolution:** design §10 (line 567) and §22 name it decisive — the cloud persona is rewritten from the same `persona_clause`, and `interpret()` keeps sending it unchanged. Implemented as ONE constant; the intent-call pins assert the shipped shape (no temperature) and the persona byte-identity.
3. **`GeminiChatConfig` naming/placement:** a file-scope enum next to the class (design §9 names `GeminiChatConfig.temperature`); file-scope keeps it reviewable and lets T-170's mirror check cite it without instantiating the interpreter.
4. **Cap → plain classified `nil`, no cap COMMAND.** The deterministic cap-honesty reply is defined for the interpretation lane; a chat turn has no such contract, and inventing one here would pre-empt T-175's fallback. `.quotaCapped` is still reported for the chain's bottom-out honesty line.
5. **Governor clamp discovery:** `setSoftDailyCap` clamps to `[10, 1000]` (`minimumSoftDailyCap`), so cap-of-1 premises are impossible; the cap tests use the Settings minimum (10) filled with ten `recordCall()`s, and the counting assertion reads the PERSISTED payload (`storage.read(key:type:)` with `dayKey(from:)`) because the `@Published` mirror lands on main asynchronously — the shipped `GeminiCommandInterpreterTests` pattern.
6. **No consent/routing wiring** (T-172/T-173/T-175 by contract): this unit is the responder seam only; conformance alone changes no routing (the cloud interpreter is never the `localBrain`).
7. **The DEBUG diagnostics in `interpret` were left exactly as they were** (T-185 considerations do not apply — nothing here changed them; the source scan pins that every console write in the file, including the three pre-existing ones, stays inside `#if DEBUG`).
8. **No confidence threshold consulted on the chat path** — the shape gate (`.chat`) is the only gate; this mirrors the local chat completion rule rather than `interpret`'s 0.7 floor.
9. **Build contention hit once** (a second xcodebuild holding the build database, run 2): waited 120 s and retried per the stated protocol; build/DerivedDataTests were never deleted or wiped.

## Open items for the chain

- T-170: read the marker block and byte-mirror the clause from `persona_clause()` — the checker is already clean against this file.
- T-172/T-173: consent + routing; T-175: same-turn fallback for `nil` + `lastCloudFailureClass`.
- Device/simulator smoke of a real chat turn is the usual DV gate — not in this unit's scope.
