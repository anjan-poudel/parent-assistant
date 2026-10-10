# Multi-Turn Conversation — Feasibility Study

**Date:** 2026-10-10
**Prepared:** Claude Code, based on repo review of `elderly-ai-assistant` (master @ `0cbe4e6`) — voice pipeline, intent engine, brain serving, Spotify integration, and existing dialogue precedents.
**Audience:** Project owner / decision-makers

---

## 1. Executive summary

**Requested behaviour** (owner's example):

```
user:  play bhajans
pip:   WHAT KIND OF BHAJANS? shiva, durga, bishnu, devi … (probe to narrow down)
user:  dasain durga bhajans
pip:   playing dasain durga bhajans, please wait.
```

**Verdict: feasible, and the app is closer to it than it looks — but not as a brain-only feature.** The app already has a proven turn-state mechanism (the confirmation protocol), already has slot-filling trained into the v16 brain (`intentQwen4BSlotCanon`), and already speaks missing-slot questions (reminders, calendar). What is missing is (1) a free-form *answer-capture* mode (today only yes/no is captured), (2) a dialogue frame object to hold pending slots, (3) probe option data for music, and (4) follow-up-turn training data for the intent fine-tune.

| Dimension | Assessment |
|---|---|
| **Complexity** | MEDIUM — mechanics reuse existing confirmation infra; the NLU fine-tune iteration is the long pole |
| **Effort** | Phase 1 (frame mechanics + bhajan probe, deterministic): ~1–2 weeks AI-augmented. Phase 2 (follow-up fine-tune v17): ~1 week (training pipeline exists). Phase 3 (rollout to reminders/calendar, device validation): ~3–5 days. Total ~3–4 weeks |
| **Can the 4B / 1.7B handle multi-turn?** | Yes for **slot-filling** (their trained skill), with a follow-up-training-data iteration. No for **open conversation** — stage-3 chat fine-tune was never done, and shipped-brain chat quality is a known problem |
| **Binding constraints** | 1024-token context is a hard memory ceiling (2048 already crashed 6 GB devices); intent fine-tunes are single-turn-trained with `.raw` framing (no system turn, no history); model churn is fixed (PR #156) but per-turn STT reload (~1.0 GB) remains on over-budget brains |
| **Biggest risks** | Follow-up utterances out-of-distribution for the fine-tune (mitigated by intercepting answers *before* the routing ladder); prompt-identity drift from the frame clause; OOM on sustained multi-turn conversations |

**Product alignment:** the voice-OS vision already anticipates this — "clarification rate", "cancellation and correction rate" are named success metrics (`docs/personal-os-enhancement-proposals.md:1007-1014`).

---

## 2. Today's behaviour: why "play bhajans" never asks

The music request never reaches a point where a question is possible, and there is nothing to ask *from*:

1. **The deterministic ladder fires before the brain.** `CommandRouter.route` runs gibberish guard → emergency → confirmation follow-up → … → relaxed keyword table (`KeywordIntentRule.match`, `CommandRouter.swift:1207-1234`). "play bhajans" / "भजन बजाऊ" match the music rule (`KeywordIntentRule.swift:375-377`, markers at 536-540) with no model involved.
2. **The query is whatever survives token-stripping — or the marker itself.** `musicQuery(from:)` (`KeywordIntentRule.swift:752-779`) drops marker/verb/scaffold tokens; if nothing survives it falls back to the first music marker (L2-D10). So "play bhajans" → query `"bhajans"`, "भजन बजाऊ" → `"भजन"`.
3. **The execution path takes the literal top hit.** `fireMusicRequest` (`CommandRouter.swift:2667`) → `runMusicTurn` (2684) → `SpotifyTool.fetchTopTrack`: `GET /v1/search?q=bhajans&type=track&limit=1` (`SpotifyTool.swift:178-208`) → remote play / deep link / YouTube fallback per the `selectMusicOutcome` matrix (2614-2647).
4. **Spotify metadata is discarded.** Only `tracks.items[0].id` + `.name` are parsed (`SpotifyTool.swift:267-283`) — genre, artist, album, playlist are thrown away, and no playlist/genre endpoints exist in `SpotifyTool`. There is no queue anywhere.

The only questions the voice layer can ask today are **yes/no** (section 4). The model path's `music` intent has **no query slot of its own** — it reuses the free-text `message` entity (`CommandRouter.swift:3336-3355`).

---

## 3. Why the app is single-turn today (the baked-in assumptions)

1. **One transcript → one `RoutingResult`.** `CommandRouter.route(transcript:)` (`CommandRouter.swift:740`) has no turn array, no turn counter, nothing carrying context across utterances. Per-turn scratch (`pendingTranscript`) is set and cleared inside one dispatch (3307, 1516-1518).
2. **`InterpreterContext` has no history field.** Only `pendingMedications` (hardcoded `[]` at both construction sites — `CommandRouter.swift:1467-1471`, `AppCoordinator.swift:3751`), `userLanguageHint`, `addressAs` (`LlamaCommandInterpreter.swift:95-118`).
3. **The pipeline re-arms after every turn.** STT completes → `router.route(transcript:)` (`VoicePipeline.swift:949`) → `resumeWakeListening()`. There is no "capture answer" listening mode; VAD just re-arms for the next fresh turn.
4. **The fine-tunes are single-turn by training.** The intent brains are "a frozen 12-action surface with no conversational mode" (`LocalBrainChain.swift:212-219`). Production framing is `.raw` — prompt alone, **no system turn** — because that is the text the fine-tunes were trained on (`LlamaCommandInterpreter.swift:973-1000`, 1176-1184). The training prompt is byte-mirrored by `tools/train-intent/seeds/prompt_template.txt`.
5. **Conversation history is display-only.** `ChatHistoryStore` (200 exchanges, encrypted) feeds the Home card and history sheet only — never a prompt (`AppCoordinator.swift:588-596`).

---

## 4. What already exists to build on

| Existing mechanism | Where | Relevance to multi-turn |
|---|---|---|
| **Confirmation interception** — while `isAwaitingConfirmation`, the next STT turn is parsed as an answer, not a command | `CommandRouter.swift:785-886` | The turn-capture mechanism to generalize: add a free-form-answer mode alongside yes/no |
| **`VoiceSessionStateMachine.awaitingConfirmation`** with legal transitions + 45 s timeout | `VoiceSessionStateMachine.swift:15-16, 91-127` | The dialogue state slot to extend (`awaitingSlotAnswer`) |
| **Slot-override precedent** — "no-with-amendment" call correction parses an answer that amends a slot ("होइन, फोन नै गर") | `CommandRouter.swift:811-821` | Proof that answer-with-content parsing works; the frame merge is the generalization |
| **Rephrase-as-question** — confidence [0.4, 0.7) tier-`free` → spoken "did you mean…?" yes/no | `CommandRouter.swift:794-809, 1493-1519`; `AppCoordinator.swift:7391-7405` | The probe UX skeleton; music is tier `.free` (`ConfirmationTier.swift:23-28`) |
| **Missing-slot ask-lines** — reminder w/o time, calendar w/o subject/time each speak a question | `CommandRouter.swift:3462-3485, 3510-3548` | Today these are **stateless re-prompts** — the follow-up is routed as a fresh command. The frame manager fixes exactly this |
| **Slot-filling training** — v16 is the *slot-canonical* retrain; "fill ONLY slots you heard — never invent" | `ModelCatalog.swift:252-258`; `IntentPrompt.swift` | The NLU skill multi-turn needs; today it runs without frame context |
| **RepetitionGuard** — cross-turn memory of recent confirmed actions (dementia loop) | `RepetitionGuard.swift:13-66` | Existing cross-turn memory pattern to respect in the frame manager |
| **Input seam** — STT-error corrector + dialect canonicalizer, once per turn | `LocalBrainChain.swift:275-285` | Follow-up answers need the same sanitisation before frame merge |
| **Pipeline timers** — 22 s capture, 45 s pending-turn hold, 60 s watchdog | `VoicePipeline.swift:130, 275`; `AppCoordinator.swift:4865` | The probe window's time budget |

---

## 5. Hard constraints (measured, not assumed)

### 5.1 Context: 1024 tokens is a memory ceiling, not a choice

`LlamaCommandInterpreter.swift:1159-1163`: with Whisper resident, **2048 overflowed the app's memory ceiling and crashed `llama_context::output_reserve` on 6 GB devices**. The handle is created with `maxTokenCount: 1024` (line 1199). The composed intent prompt measures **~696 qwen3 tokens** (`IntentPrompt.swift:29-42`), leaving **~300 tokens** for utterance + output (~128 reserved). Two overflow bugs have shipped (2,361 → empty completion; 818 → truncated utterance).

**Why 1024 when Qwen3 supports 32K natively?** 32K is the model's architectural maximum; the app chooses `n_ctx` at load time. llama.cpp allocates the full KV cache up front — `n_ctx × layers × KV-heads × head_dim × 2 × 2 bytes` — roughly ~140 KB per token for a 4B GQA model: ~150 MB at 1024, ~300 MB at 2048 (that delta is what crashed), ~4.5 GB at 32K (larger than the 2.5 GB model file). iOS has no swap, and the brain runs co-resident with Whisper (~1 GB) and TTS voices; 1024 is the measured largest value that survives a 6 GB device. Additionally the fine-tune was trained on exactly this ~700-token prompt shape — a bigger window would be untrained territory.

**Consequence:** multi-turn state cannot be raw transcript history. A compact frame clause (~30–60 tokens, section 6.4) fits comfortably inside the remaining headroom; anything bigger does not. Dialogue state must live in the app, not in the model.

### 5.2 Model capability: intent fine-tunes vs conversation

- The 4B/1.7B are Qwen3 QLoRA **intent fine-tunes**: 12-action surface, grammar-constrained JSON decode, deterministic sampling (temp 0, fixed seed — the 2026-09-07 NO-GIBBERISH fix).
- Chat exists only as stage 1: a heuristic `ChatIntentClassifier` for greetings/thanks + a `chatJSONSchema` — with the fine-tunes explicitly unable to serve it ("a chat ask probably abstains", `IntentRouter.swift:259-291`). **Stage-3 chat fine-tuning was never done** (no artifacts in repo or docs), and the shipped brain's chat output was confirmed gibberish (stage-3 memory).
- **Probes must therefore be template-generated, never model-generated.** The model's job in multi-turn is narrow: classify the *answer* utterance against the active frame — which is exactly slot extraction, the v16 brain's trained skill (it was retrained precisely because seed-43 failed the contact/time slot gates).
- Out-of-distribution risk: the fine-tune has never seen a follow-up turn. Bare "dasain durga bhajans" would likely be misclassified today. Two levers: (a) intercept answers *before* the routing ladder (structural — the answer never reaches general routing), and (b) follow-up-turn training data in the next fine-tune iteration (section 7, Phase 2).

### 5.3 Memory: multi-turn multiplies the turn-count risk

The 4B is ~3.4 GB live on a 6 GB-class device, but the worst churn is fixed. **PR #156 (merged 2026-10-10, `437631e`) landed the voice-OOM hardening**: the post-turn policy now releases STT after the turn and never re-warms it when an over-budget brain is resident (`WhisperPostTurnPolicy.ReleaseReason.brainOverBudget`, `WhisperPostTurnPolicy.swift:97-157`) — the brain stays resident and the per-turn churn is the ~1.0 GB STT reload instead of the old ~4.4 GB brain↔STT ping-pong. The same PR added the pressure-tiered per-turn brain pick (4B → 1.7B → 1B → lightweight, `PressureBrainPick.swift:69-193`), the boot-warm headroom gate, encoder evictability, and the degraded-mode pill. **Outstanding: the PR's device-checklist gate — Anzaan smoke test with a post-conversation jetsam log pull.**

A probe + answer = two consecutive full turns. Multi-turn inherits the degradation ladder: the frame survives a degraded or skipped brain turn, and the deterministic merge (section 6.3) is the no-brain fallback.

**Side benefit — KV-cache prefix reuse exists.** The vendored `LLM.swift` implements prompt-prefix KV reuse: `prepareContext(for:)` diffs the new prompt against the previous context and only decodes the divergent tail (`llama_memory_seq_rm`, `ios/vendor/LLM.swift/Sources/LLM/LLM.swift:262-293`). With the brain resident across turns, each subsequent turn in a conversation re-decodes only the utterance tail (~tens of tokens), not the ~700-token template — multi-turn turns are *cheaper* than the pre-fix churn. The reuse depends on the template prefix being byte-stable between turns, which is one more reason the frame clause must not mutate the template (section 6.4).

### 5.4 Data: probe options need a source

`SpotifyTool` has no genre/playlist endpoints and discards artist/genre metadata. Options for the bhajan probe ("shiva, durga, devi…"):

1. **Curated on-device option lists** per request type (recommended MVP): a small localisable `BhajanCatalog` (deity → canonical search query, e.g. दुर्गा → "durga bhajan"), consistent with the on-device stance, zero latency, works offline. Free-text answers are still accepted (the user's "dasain durga bhajans" flows through regardless of the list).
2. **Spotify search with `type=playlist`** (later): the search endpoint supports playlists — probe options become live curated playlists. Costs network + latency + a `SpotifyTool` extension; privacy is already disclosed for music queries.

---

## 6. Recommended design: frame-based slot-filling with a deterministic dialogue manager

### 6.1 The dialogue frame (new, in-memory)

```
DialogueFrame {
  activeCommand: InterpretedCommand     // the pending command ("play music")
  missingSlot: Slot                     // what the probe asked for (query)
  probeKind: ProbeKind                 // .slotFill ("bhajan.deity") | .candidateChoice ("didYouMean")
  candidates: [InterpretedCommand]     // candidate interpretations for didYouMean probes
  attempts: Int                         // capped (default 2 probes → execute with defaults)
  deadline: Date                         // 45 s, reusing the confirmation timer
}
```

Held by a small `DialogueManager`, owned by the coordinator — the same one-deep pattern as today's `pendingRephraseCommand` / `pendingConfirmationEntryId`, but structured instead of a bare command.

### 6.2 The probe trigger

After routing resolves a music intent whose query is degenerate (empty, or `musicQuery(from:)`'s marker-fallback — `KeywordIntentRule.swift:764-775`), instead of executing `fetchTopTrack` blindly:

- Speak a template probe: *"कस्तो भजन? शिव, दुर्गा, विष्णु, देवी — वा आफैँ भन्नुहोस्। अहिलेलाई जे पनि बजाउन भन्नुभए 'जे पनि' भन्नुहोस्।"* — ≤3–4 named options, one default ("just play anything"). Options come from the curated catalog (5.4), never the model.
- Enter `awaitingSlotAnswer` in `VoiceSessionStateMachine` (new state alongside `awaitingConfirmation`, same 45 s timer).

**No-understanding probe (owner requirement, 2026-10-10).** When pip cannot understand an utterance, it must say so honestly *and* offer a narrowing probe — "did you mean X or Y?" — instead of the bare re-prompt. Candidates come from what the pipeline already computes: the rephrase band's low-confidence hypothesis (confidence 0.4–0.7, `CommandRouter.swift:794-809`), relaxed keyword near-matches, and the active frame when one exists. The user picks by voice — the option's name, its index ("पहिलो" / "first"), or repeating the candidate — or answers free-form; the answer turn runs the same interception and frame merge as §6.3. Candidate probes obey the same constraints: ≤2–3 spoken options, template-generated text, 45 s deadline, and a "no — let me say it again" escape that re-arms a fresh capture. This upgrades today's honest-but-dead-end `routeKeywordRemainder` lines (`CommandRouter.swift:1968-2030`) into a narrowing dialogue.

The same mechanism upgrades the existing **stateless** missing-slot re-prompts (reminder "what time?", calendar "what title?") — section 7, Phase 3.

### 6.3 The answer turn: intercept, merge, execute

On the next utterance, the interception in `CommandRouter.route` (the confirmation hook at 789-886, generalized) runs **before the routing ladder**:

1. **Cancel detection** — "होइन", "रद्द", "never mind" → drop frame, honest "ठीक छ" line.
2. **Emergency override** — emergency keywords always win, even mid-frame (safety constraint).
3. **Frame merge (deterministic)** — sanitise the answer through the existing input seam (`LocalBrainChain.InputSeam`), then:
   - strip answer scaffolding ("दशैं दुर्गा भजन" → query `"dasain durga bhajan"`),
   - if the curated catalog matches (दुर्गा → "durga bhajan"), use the canonical query; else keep the free text,
   - merge into `activeCommand` (music: query slot), dispatch through the normal executor (`runMusicTurn`).
4. **Optional brain resolution** (Phase 2) — if the deterministic merge can't extract a value (e.g. "the one from yesterday"), ask the brain once with a compact frame clause (§6.4). Brain unavailable → speak one more probe, then execute with defaults.
5. **Timeout / abandonment** — 45 s expiry: drop the frame silently, re-arm; the user's next utterance is a fresh command. No stuck state, no persistence needed.

**Barge-in rule:** an utterance that looks like a *different* command mid-frame (strong deterministic match — e.g. "call my son") drops the frame and executes the new command. Ambiguous → treat as answer. This is the behaviour elderly users expect and it prevents the frame from trapping them.

### 6.4 The frame clause (what the brain sees in Phase 2)

Inside the ~300-token headroom, append to the user turn (~30–60 tokens):

```
Answer to the earlier question about music. Missing detail: kind of bhajan.
```

Constraints: must stay inside the pinned prompt budget (`IntentPromptTests` ceiling), must be mirrored in the training seeds (`tools/train-intent/seeds/prompt_template.txt`), and must not alter the `.raw` framing. Any clause variant ships only as part of the Phase-2 fine-tune iteration — injecting it without training data is the prompt-drift hazard (the LLaMA branch comment at `LlamaCommandInterpreter.swift:973-977` documents exactly how brittle the framing identity is).

### 6.5 What the user hears and sees

- Probe: spoken, short, with a default option. Reuses `speak(text:)` → `ReplySpeakLane`; the probe can pre-ack like any reply.
- Answer turn: normal STT→merge→execute→speak path; no extra round trip versus today's music turn.
- Latency budget: one probe adds exactly one full turn's latency (seconds), within the existing 22 s capture / 45 s hold / 60 s watchdog envelope.
- The probe appears in chat history (`noteAssistantSpoke`) like any reply — no new UI required.

---

## 7. Phasing and effort

| Phase | Work | Depends on | Effort |
|---|---|---|---|
| **0 — Prerequisite** | Voice-OOM hardening: **code merged (PR #156, `437631e`, 2026-10-10)** — post-turn policy, pressure-tiered picks, warm gate, degraded pill. Remaining: the PR's device smoke gate on Anzaan (conversation → no jetsam → pull JetsamEvent logs) | — | merged; device smoke owed |
| **1 — Frame mechanics + bhajan probe (deterministic MVP)** | `DialogueManager` + `DialogueFrame`; `awaitingSlotAnswer` state + interception before the ladder; probe templates (ne/en) + curated `BhajanCatalog`; degenerate-query detection in the music path; cancel/emergency/timeout rules; focused tests (pattern: confirmation-protocol suites) | Phase 0 merged | ~1–2 weeks |
| **2 — Follow-up NLU (fine-tune v17)** | Follow-up-turn training data (golden corpus + synthetic follow-ups, e.g. bare "दशैं दुर्गा भजन" against frame-marked contexts); prompt_template mirror update; LoRA run on the existing training pipeline; new slot gates (query-slot accuracy) alongside the existing contact/time gates; brain-assisted frame merge (§6.3.4) | Phase 1 (mechanics), independent of it (data authoring can start in parallel) | ~1 week |
| **3 — Rollout + validation** | Fix the stateless reminder/calendar re-prompts through the same frame path; RepetitionGuard interplay; DV-* checklist on Anzaan (probe → answer → correct playback; timeout; barge-in; degraded-brain turn mid-dialogue) | Phases 1–2 | ~3–5 days |

Phase 1 is shippable on its own: the deterministic merge covers the owner's bhajan example end-to-end without any training run. Phase 2 turns the same mechanism from curated to general. Phase 3 makes multi-turn a platform capability rather than a music feature.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Follow-up answers out-of-distribution for the fine-tune ("dasain durga bhajans" misrouted) | Structural: interception happens *before* the routing ladder, so an answer never reaches general routing. Phase 2 adds the training data to make brain-resolution reliable |
| Prompt-identity drift from the frame clause | Clause shipped only with the v17 training iteration; prompt byte-mirror updated in the same change; golden corpus + slot gates re-run (the slot-canon precedent: gates failed → retrain, don't ship) |
| OOM on sustained multi-turn (probe → answer → follow-up) | PR #156 merged: brain stays resident, STT per-turn release; pressure-tiered pick degrades 4B→1.7B→1B→lightweight; frame survives degraded turns; deterministic merge needs no brain; Anzaan device smoke still owed |
| Elderly user walks away mid-dialogue | 45 s expiry, silent drop, re-arm; no persistence, no stuck state |
| Probe fatigue / option overload | Max 2 probes then execute with defaults; ≤3–4 spoken options; always a default; free text always accepted |
| STT errors on Nepali answer terms (दुर्गा/दशैं) | Existing input seam (STT-error corrector + dialect canonicalizer) applied to answers before merge; curated catalog adds canonicalisation |
| `IntentCommandCache` short-circuits the frame | During `awaitingSlotAnswer`, bypass the transcript cache (answers are never cacheable inputs); only confirmed *merged* commands are recorded |

---

## 9. Open decisions (owner)

- **OD-M1 — probe policy:** 1 probe vs up-to-2 before executing with defaults, and the default-play wording ("जे पनि बजाऊ"). Recommend: 2 probes max, default offered on the first probe.
- **OD-M2 — probe option source:** curated on-device catalog (recommended for MVP, zero latency, on-device stance) vs live Spotify playlist search (richer, needs `SpotifyTool` extension + network per probe).
- **OD-M3 — sequencing:** ship Phase 1 deterministic-only first, or run Phase 2 fine-tune in parallel. Recommend: Phase 1 first (it covers the bhajan example), v17 data authoring in parallel.
- **OD-M4 — scope:** whether Phase 3's reminder/calendar answer-capture (fixing today's stateless re-prompts) rides the same release as the music probe.

---

## 10. Key file references

| Concern | File |
|---|---|
| Turn interception point (confirmation hook to generalize) | `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift:785-886` |
| Routing ladder + LLM fast path | `CommandRouter.swift:740-1539` |
| Music path (trigger → search → outcome matrix) | `CommandRouter.swift:2614-3136`; `KeywordIntentRule.swift:752-779` |
| Spotify tool (limit-1 track search, discarded metadata) | `ios/ElderlyAssistant/Services/Spotify/SpotifyTool.swift:178-283` |
| Session states + 45 s timer | `ios/ElderlyAssistant/App/VoiceSessionStateMachine.swift:15-16, 91-127` |
| Interpreter context (no history field) | `Services/Voice/LlamaCommandInterpreter.swift:95-118` |
| Prompt builder + 696-token measurement | `Services/Voice/IntentPrompt.swift:29-42, 94-128` |
| 1024-token hard ceiling (2048 crashed) | `LlamaCommandInterpreter.swift:1159-1202` |
| `.raw` framing / no system turn | `LlamaCommandInterpreter.swift:973-1000, 1176-1184` |
| Slot-canon v16 + default brain | `Services/ModelStore/ModelCatalog.swift:252-258`; `App/AppCoordinator.swift:1961` |
| Chat stage 1 (heuristic classifier, fine-tunes excluded) | `Services/Intents/ChatIntentClassifier.swift:53-241`; `LocalBrainChain.swift:212-219` |
| Pressure-tiered pick (multi-turn survival) | `Services/Voice/PressureBrainPick.swift:69-193`; `AppCoordinator.swift:6203` |
| Training prompt mirror | `tools/train-intent/seeds/prompt_template.txt` |
