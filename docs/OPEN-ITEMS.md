# Open Items

Tracked work not yet landed on `master`. New items get added at the top of
the table; completed items are struck through with the landing commit noted.


> **Ready-to-merge (2026-09-06):** the Home widget system merge is complete
> and verified on branch `merge/home-widgets` (commit `e1b9999`, 555 unit
> tests green) — one fast-forward step ahead of `master`. It is deliberately
> NOT on master yet because the main tree has another session's in-flight
> contacts work in 4 files; run `git merge merge/home-widgets` once that
> tree is clean. (A cross-session message was sent too, but may be pending
> approval — this note is the reliable channel.)

| # | Item | Status | Branch / Worktree | Notes |
|---|------|--------|-------------------|-------|
| 7 | Query path structured-response contract ([QUERY-FIX]): kill the invariant "माफ गर्नुहोस्" apology for correctly-transcribed questions | landed `7ac8b33` | ~~`fix-query-end-to-end` (`.claude/worktrees/fix-query-end-to-end`)~~ | e2e suite `QueryEndToEndRegressionTests`; train-intent must mirror the canonical contract — see section below |
| 6 | Intent-model base bake-off (Gemma 3 1B vs Qwen 3 1.7B) | eval complete (2026-09-07) — BOTH legs fail the §10 ship gates on the golden corpus; no winner published (data-quality call for the user); gemma v7 artifact stays the only real intent brain | none (runs on GPU server 192.168.1.117 via `tools/train-intent/`) | Spec: design 2026-09-05 §7/§9.5, ship gates §10; gemma 0.882 / qwen 0.706 closed-intent, emergency recall 0.667 both — full numbers + diagnosis in the section below |
| 4 | ~~Wake word ("Hey Sahayak")~~ | landed `95b7ff7` | ~~`task/wake-word` (`.claude/worktrees/wake-word`)~~ | ~~Brief at `TASK.md` in that worktree~~ |
| 5 | ~~Gemini cost governance~~ | landed `a50b61c` | ~~`task/cost-governance` (`.claude/worktrees/cost-governance`)~~ | ~~Brief at `TASK.md` in that worktree~~ |

---

## #6 — Intent-model base bake-off (phase-2 eval outcome, 2026-09-07)

Phase 2 ran on the GPU server (`tools/train-intent/`): the Qwen leg was
re-trained with the context-truncation fix (`max_seq_len` 1024→1536, commit
2b0ccdc on the server checkout) and both legs were exported to Q4_K_M GGUF
(gemma `models/intent-ne-gemma-q4_k_m.gguf` 814,261,088 B sha
58e59847… — already published as models v7; qwen
`models/intent-ne-qwen-q4_k_m.gguf` 1,107,408,576 B sha
e4e8b748… — NOT published) and evaluated against the held-out golden
corpus (`eval/golden_corpus.jsonl`, 20 rows) on the fixed harness
(`src/eval_golden.py`; earlier `--backend gguf` row-1 crash = llama-cpp
`n_ctx` 1024 < 1214-token prompt, already fixed in the working copy to
2048; this phase added an env-controlled thread cap
`LLAMA_N_THREADS`/`LLAMA_N_THREADS_BATCH` — llama-cpp-python's default
~cpu-count OpenMP threads thrashed a shared box to ~1 tok/s).

| metric | gate | gemma-q4_k_m | qwen-q4_k_m | gemini baseline |
|---|---|---|---|---|
| closed-intent accuracy | ≥ 0.95 | **0.882** FAIL | **0.706** FAIL | 1.000 |
| contact slot F1 | ≥ 0.90 | 1.000 | 1.000 | 1.000 |
| time slot F1 | ≥ 0.90 | 0.909 | 0.923 | 1.000 |
| emergency recall | = 1.00 | **0.667** FAIL | **0.667** FAIL | 1.000 |
| call/message precision | ≥ 0.97 | 1.000 | 1.000 | 1.000 |
| Δ closed vs gemini | ≥ −3 pts | −11.8 FAIL | −29.4 FAIL | — |
| calibration (±10%) | — | 0.9+ bucket 0.89 (16/18); 1 row at conf 0.0 | 0.8+ bucket 0.79 (11/14); 0.3+ 0.67 | 1.00 all |

Per-intent (correct/n): gemma — ack_med 0/1, call 5/5, emergency 2/3,
guide 1/1, health_query 2/2, music 2/2, none 2/2, query 0/1,
send_message 1/1, set_reminder 2/2. Qwen — same except guide 0/1,
health_query 0/2, query 1/1.

**Diagnosis (raw-output probes on the missed rows):** both legs share two
generation faults — no EOS discipline (most rows run to the 700-token cap;
gemma stacks multiple JSON objects, qwen appends prose/degrades into
repetition) and wrong labels on edge intents. Gemma misses the bare
emergency "मद्दत गर्नुहोस्" (gc-emergency-001 → `none` + "के समस्या छ?" at
conf 0.9), "औषधि खाएँ" (ack → set_reminder), and the weather query
(echoes the prompt template, never reaches JSON). Qwen over-collapses onto
`query` (both health_query rows + guide row → `query`), also ack →
set_reminder, and misses "म लडेँ, उठ्न सकिन" ONLY because the correct
`{"action":"emergency"…}` JSON was truncated by repetition before its
closing brace.

**Decision left to the user (data quality, not code):** neither leg clears
the gates → NOT published; `ModelCatalog` stays with `intentGemma1B`
(v7) only, no `intentQwen1B` entry, `intentNepali1B` placeholder
untouched. Canonical eval rows sit in `tools/train-intent/eval/results.csv`
on the server. Candidate next steps: fix the data (bare-emergency and
ack/health/guide rows under-represented or mis-taught in the mixture),
emergency adversarial near-miss set (§10, not yet in the corpus), then
retrain; also the on-device latency leg (p50 ≤ 1.0 s) is still open on
real hardware.

---

## #4 — Wake word ("Hey Sahayak")

**Goal:** always-on mic activation per the original product brief ("always on
mic — like Siri"), replacing tap-to-talk as the primary entry point.

**Scope (per the staged `TASK.md`):**
- Settings → "Voice activation" screen: honest status (active / needs setup),
  plain-language (en+ne) explanation, a persisted on/off toggle. Disabled or
  unconfigured = today's exact behavior, no dead ends.
- `AppCoordinator.makeWakeWordEngine()` honors the toggle (off →
  `NullWakeWordEngine` even when key + .ppn exist) and gains an
  `EncryptedLocalStorage` fallback read for the Picovoice access key (paste-in
  field on the Settings screen) when the Info.plist key is absent.
- `docs/wake-word-setup.md`: family-facing steps — Picovoice Console account,
  train "Hey Sahayak" (document the no-Nepali-phonemes caveat and the
  English-phoneme phrase choice), drop the iOS `.ppn` into
  `ios/ElderlyAssistant/Resources/`, enter the key.
- Self-hearing mitigation: suppress wake-word processing while the speaker is
  speaking (flag consulted from `noteSpeakingStarted/Ended`; do NOT switch the
  global audio-session mode — regression risk).
- Battery-honesty copy on the Settings screen (always-listening costs battery).

**Hard constraints:** no fake/placeholder keys or .ppn files anywhere;
`NullWakeWordEngine` stays the honest default until real artifacts exist; do
not touch HomeView, CommandRouter, VoicePipeline's state machine, or
GeminiClient.

**Activation requires (not in repo, by design):** a Picovoice access key and a
trained `hey-sahayak_ios.ppn`.

## #5 — Gemini cost governance (daily counter + soft cap)

**Goal:** a local per-day Gemini call counter with a family-configurable soft
daily cap, so a failure mode (false wake-word loops, retry storms) can never
become a runaway bill. Flagged as the blocking prerequisite for safely shipping
the vision features to a real user (v2 design §3.2/§7; appliance design §8).

**Scope (per the staged `TASK.md`):**
- `GeminiCostGovernor` (new, `Services/Gemini/`): persisted daily counts
  (date-rolled, old days pruned), `softDailyCap` (default 200,
  family-editable), `allowsCall()` / `recordCall()`. Thread-safe (serial queue
  or lock — `send(_:)` is called concurrently). Date injected for testability.
- `GeminiClient` takes an optional governor (default nil = unlimited, current
  behavior preserved). Cap reached → throw `dailyCapReached` BEFORE the network
  call; success AND HTTP/network failures count as billable attempts;
  `notConfigured` does not count. Plugins inherit the cap for free through the
  shared client (no per-plugin special-casing).
- Settings → Gemini AI screen (extend, no new row): today's count + cap,
  cap editor, plain-language en+ne explanation.
- Observability: `gemini_cost/daily_cap_reached` event; `daily_cap_warning`
  once per day at 80%.
- User-facing behavior at cap: invisible to the elder — the existing
  deterministic keyword fallback (medication/emergency keep working with zero
  network). Verify `GeminiCommandInterpreter.interpret`'s generic error path
  actually engages the fallback for `dailyCapReached`.

**Hard constraints:** no time-zone cleverness beyond local-calendar day
rollover; do not touch IntentPrompt, CommandRouter, HomeView, or the plugin
registry/plugins.

---

## #7 — Query path structured-response contract ([QUERY-FIX])

**Problem (real-device, invariant):** Nepali open-domain questions ("भोलिको
मौसम कस्तो छ?") transcribed correctly, then `llama_interpreter` reported
`inference_done` outcome=success, `command_router` emitted
`command_unrecognised`, and the speaker ALWAYS said the generic apology
(`router.reprompt`). Root cause: the pre-fix `IntentPrompt` text measured
2,361 tokens against the on-device 1,024-token context
(`LLM(from:maxTokenCount: 1024)`); the runtime finished with an EMPTY
completion that was logged as success, `parse("")` returned nil, and every
utterance fell through to the apology.

**Fix:** canonical structured-response contract shared by both brains —
the interpreter answers with ONE JSON object: `intent` (12-value enum),
`response` (ALWAYS non-empty; for a question it IS the actual answer the
router speaks), `confidence`, `actionType`/`actionUrl`, plus the entity/slot
fields. `IntentPrompt.build` rewritten inside the measured on-device budget
(~919 formatted tokens at the canonical fixture vs 1,024, verified on the
real llama3.2:1b tokenizer; the completed one-shot example + closing
imperative is load-bearing for the 1B base model). `LlamaCommandInterpreter`
parse maps canonical (`intent`/`response`) onto `InterpretedCommand`, still
accepts the legacy wire shape (`action`/`reply` — intent cache, cloud
collapsed path, grammar-bound fine-tuned local brain), and REJECTS
empty/missing/whitespace `response` (a reply-less command would make the
router speak nothing — a silent dead-end worse than the re-prompt); missing
`confidence` defaults to 0.5 (rephrase band). Empty inference output is now
an observable `inference_empty_output` failure, never `inference_done`
success. Gemini shares the prompt + parse via `IntentPrompt.build` and
`LlamaCommandInterpreter.parse`, so the cloud path got the same contract.

**Verification:** `QueryEndToEndRegressionTests` drives the REAL chain
(`CommandRouter` → `IntentRouter` with real cache → `LocalBrainChain` → real
`LlamaCommandInterpreter` via the `generateOverride` seam; Gemini via stubbed
transport): Q&A transcript → structured JSON → spoken answer via
`noteGenericReply` + `speak`, no `command_unrecognised`, no apology; empty
output and empty `response` fall back to the honest re-prompt. Size-budget
regression tripwire pinned in `IntentPromptTests`.

**Train-intent mirror obligation:** the fine-tuned local brain
(`LocalIntentInterpreter.intentSchema` grammar) still emits the LEGACY keys
(`action`/`reply`) — the tolerant parse keeps it dispatchable, but when the
train-intent workstream adopts the canonical contract it must mirror it
exactly on every output surface: `LABEL_FIELDS`,
`seeds/prompt_template.txt`, `LocalIntentInterpreter.intentSchema`, and
`LlamaGrammar.commandJSON` (already canonical) must all teach
`intent`/`response`/`actionType`/`actionUrl` with an always-non-empty
`response`, so both brains speak one contract.

---

*Process note: each item ships via its own worktree branch, full build + test
(`310` baseline has since grown — current suite is `552` unit tests), commit
with the bracketed label prefix, merge to `master` after verification, then
strike the row here with the landing commit.*
