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
| 6 | Intent-model base bake-off (Gemma 3 1B vs Qwen 3 1.7B) | **round-2 retrain ARMED (2026-09-07)** — EOS-in-training fix + spec 60/25/15 mix (achieved exactly) + ack_med/bare-emergency edge rows (commit `e150223` + this docs row); `queue_bakeoff.sh` waiting on the GPU (STT owner's whisper v5 fine-tune holds the 3090); when it frees: dataset rebuild → gemma → qwen, then export + §10 eval via the fixed harness | none (runs on GPU server 192.168.1.117 via `tools/train-intent/`) | Spec: design 2026-09-05 §7/§9.5, ship gates §10; round-1 outcome + failure clusters + round-2 prep details in the section below |
| 4 | ~~Wake word ("Hey Sahayak")~~ | landed `95b7ff7` | ~~`task/wake-word` (`.claude/worktrees/wake-word`)~~ | ~~Brief at `TASK.md` in that worktree~~ |
| 5 | ~~Gemini cost governance~~ | landed `a50b61c` | ~~`task/cost-governance` (`.claude/worktrees/cost-governance`)~~ | ~~Brief at `TASK.md` in that worktree~~ |

---

## #6 — Intent-model base bake-off (phase-3 degenfix eval outcome, 2026-09-07)

### Phase-2 → phase-3 summary

Phase 2 (2026-09-07) ran both legs (`models/intent-ne-gemma-q4_k_m.gguf`
sha 58e59847…, already published as models v7; qwen
`models/intent-ne-qwen-q4_k_m.gguf` sha e4e8b748…, NOT published) against
the held-out golden corpus (`eval/golden_corpus.jsonl`, 20 rows) with the
fixed harness (`n_ctx` 2048, `LLAMA_N_THREADS`/`LLAMA_N_THREADS_BATCH` env
caps, `max_tokens` 700). Both legs failed the §10 gates with a shared
symptom: **no-EOS degeneration — every row ran to the 700-token cap
without emitting any end-of-generation token**, and Qwen's gc-emergency-003
produced a correct `{"action":"emergency"…}` truncated before its closing
brace.

Phase 3 (this item, commit `[EVAL-DEGENERATION]` on `master`) fixed the
harness and re-ran all three legs. Before/after (label `-degenfix` rows in
`tools/train-intent/eval/results.csv` on the server):

| metric | gate | gemma before | gemma after | qwen before | qwen after | gemini baseline |
|---|---|---|---|---|---|---|
| closed-intent accuracy | ≥ 0.95 | 0.882 FAIL | **0.882** FAIL | 0.706 FAIL | **0.765** FAIL | 1.000 |
| contact slot F1 | ≥ 0.90 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| time slot F1 | ≥ 0.90 | 0.909 | 0.909 | 0.923 | 0.923 | 1.000 |
| emergency recall | = 1.00 | 0.667 FAIL | **0.667** FAIL | 0.667 FAIL | **1.000** PASS | 1.000 |
| call/message precision | ≥ 0.97 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| Δ closed vs gemini | ≥ −3 pts | −11.8 FAIL | −11.8 FAIL | −29.4 FAIL | −23.5 FAIL | — |
| calibration (±10%) | — | 0.9+ 0.89 (16/18); conf-0 abstention ×1 | same | 0.3+ 0.67 (3 rows) | 0.8+ 0.81 (13/16); 0.3+ 0.67 (misses) | 1.00 all |

Per-intent after (correct/n): gemma — ack_med 0/1, call 5/5, emergency
2/3, guide 1/1, health_query 2/2, music 2/2, none 2/2, query 0/1,
send_message 1/1, set_reminder 2/2. Qwen — same except emergency 3/3,
guide 0/1, health_query 0/2, query 1/1.

**Root cause (evidence-first, probes at temp 0 over all 20 rows):**
`train_qlora.py` builds training text as raw `prompt_template.txt` +
`\n` + JSON label — tokenized **without chat-template wrapping and with no
EOS appended** (`to_text`, `tokenizer(batch["text"])`, CLM collator). The
models therefore never learned a terminator: llama.cpp's EOG tokens
(gemma `<eos>`/`<end_of_turn>`, qwen `<|endoftext|>`) are never emitted
(0 EOG hits in 2×20×320 probe tokens), so greedy decoding continued into
synthetic "next training row" continuations (`\n\nUser said: …`, stacked
JSON objects, template-fragment echo) until the cap cut it — truncating
late JSON (qwen gc-emergency-003) or producing unparseable preamble
(gemma gc-query-001 weather row). The eval template itself MATCHES
training (both raw — no chat-template wrap anywhere), so no template
mismatch exists; the diagnosis in OPEN-ITEMS phase-2 text ("template
echo") was the model continuing mid-template text, not an eval-format
bug. `n_ctx` was never the issue at 2048 (longest prompt 1224 tokens).

**Fixes (`src/eval_golden.py`, phase-3):** per-family stop strings
(EOG tokens + observed `\n\nUser said:` / `\n\n{` stacking markers);
`max_tokens` 700 → 956; `n_ctx` 4096; per-family repeat penalty
(qwen 1.05 — breaks the gc-emergency-003 repetition attractor at 1.0
where the correct emergency JSON never closed; gemma stays 1.0 because
higher penalties perturb fine-grained slots, e.g. contact
माइया → माइयालाई at 1.15); JSON extraction now takes the FIRST complete
JSON object anywhere in the output (template-echo preamble / stacked
objects / trailing prose skipped) instead of first-brace-to-last-brace.
Temperature stays 0. Result: qwen 0 parse-loss rows (was 1), gemma 1
(un-gated weather row, unchanged); rows now terminate at 33–216 tokens
instead of running to the cap — a full leg takes ~1.5–4 min instead of
the phase-2 ~10 min.

**Remaining failure clusters (model/data quality, not harness):**
- gemma gc-emergency-001 "मद्दत गर्नुहोस्" (bare help) → `none` conf
  0.9, reply "के समस्या छ?" — hard-gate miss on the canonical bare
  emergency; qwen gets this row right.
- both legs gc-ack-001 "औषधि खाएँ" → `set_reminder` (gemma adds
  medication "औषधि"; qwen fabricates time "७:३०") — ack intent never
  fires.
- qwen gc-health-001/002 and gc-guide-001 over-collapse onto `query`
  (health questions about blood pressure / kidney diet, and the
  microwave guide) at conf 0.3.
- gemma gc-query-001 "भोलि मौसम कस्तो हुन्छ" degenerates into
  mid-template text continuation (no JSON; un-gated query row).

**Decision left to the user (data quality, not code):** neither leg
clears the gates → NOT published; `ModelCatalog` stays with
`intentGemma1B` (v7) only, no `intentQwen1B` entry. Candidate next
steps: teach a terminator (append EOS in `to_text`) on retrain; fix the
data (bare-emergency and ack/health/guide rows under-represented or
mis-taught in the mixture); emergency adversarial near-miss set (§10,
not yet in the corpus); then retrain + re-export + re-eval. On-device
latency leg (p50 ≤ 1.0 s) still open on real hardware.

### Round-2 retrain — ARMED 2026-09-07 (commit `e150223`)

Training-side fixes for the round-1 root causes, landed server-side and
synced to master byte-identical:

1. **EOS in training** (`src/train_qlora.py`): `to_text` now appends the
   base model's OWN eos token after the JSON label — gemma `<eos>` (id 1),
   qwen `<|im_end|>` (id 151645; qwen3's eos is NOT `<|endoftext|>`).
   Injected per leg at train time (train.jsonl is shared between bases);
   a guard asserts the eos text round-trips to exactly the tokenizer's
   eos id. Verified: longest row + eos = 1,329 tokens < 1,536 cap.
2. **Mixture 60/25/15** (`src/build_dataset.py`, achieved EXACTLY):
   round-1 deduped all sources against one lossy skeleton key (matras
   stripped) — noised rows mostly vanished as "dups" → 86/14 corpus.
   Now three register buckets (stt_noised / clean_devanagari =
   devanagari + elder_fragmented / romanized_codeswitched) deduped
   inside with a matra-preserving key; the noised supply anchors the
   total. Final: 2,827 rows = 1,696 stt_noised (60.0%) + 707 clean
   devanagari (25.0%) + 424 rom/cs (15.0%); train 2,686 / valid 141.
3. **Edge rows** (`data/edge_cases.jsonl`, server-only, 57 rows, always
   kept): ack_med positives + refusals (the whole teacher corpus has
   ZERO ack_med rows — seeds never defined the intent), bare/short
   emergency pleas incl. English "help", plea+pain vs calm-pain
   boundary pairs, a few guides. Golden corpus untouched (leak guard
   refused 12 rows as usual).

**Data-supply findings that shaped round 2 (flagged for the STT owner):**
noised.jsonl holds 29,304 rows but only **2,458 distinct utterances** —
the whisper-medium noise run collapses hard (≈12 copies per text), and
**703 distinct texts carry contradictory labels** (two different parents
transcribed identically) — all dropped rather than taught an arbitrary
label. The noised pool is therefore ~6× smaller than its row count
implies and caps the whole corpus at ~2.8k rows (~250 steps ×3 epochs —
short; if round-2 is under-trained, regenerate noised with whisper v5 +
more variants, which also enlarges the 60% axis). teacher.jsonl is
call-heavy (5.9k of 14.7k) and 4 rows carry schema-invalid actions
(dropped); ack_med must be added to `seeds/intents.yaml` before the
next gen_teacher run.

**Armed chain:** `queue_bakeoff.sh` (pid live on server, launched
23:54:32) — waits on the GPU (whisper v5 fine-tune, PID 3235731,
untouched), rebuilds the dataset deterministically, then trains
gemma → qwen (fresh: round-1 checkpoints parked in
`checkpoints/_round1_artifacts/` so no resume contamination), each leg
behind its own gpu_free gate. Logs on the server:
`logs/bakeoff_chain_20260907_235432.log`, `logs/train_{gemma,qwen}_*.log`.
**Next (when the GPU frees):** train → `queue_export.sh` (writes
`models/intent-ne-{gemma,qwen}-q4_k_m.gguf` — round-1 gemma v7 artifact
will be overwritten; version-bump care needed before any publish) →
`eval_golden.py` round-2 eval with the fixed harness. NOTE: local master
`config.yaml` still says `max_seq_len: 1024` (server lineage fixed it to
1536, commit `2b0ccdc`) — sync it when this branch lands.

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
