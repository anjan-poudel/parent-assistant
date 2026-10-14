# Conversational Nepali replies — owner-approved proposal (2026-10-14)

**Source mandate for the `conversational-nepali-replies` ai-sdd feature.** Produced by the repo-exploration research pass and approved by the owner on 2026-10-14 ("please implement this as ai-sdd feature spec"). Feature workflow: `.ai-sdd/workflows/conversational-nepali-replies.yaml`; feature constitution: `specs/conversational-nepali-replies/constitution.md`.

---

# Proposal: conversational, grammatical Nepali replies for the brain

## 1. Diagnosis — why it sounds robotic and ungrammatical

From the code, four root causes:

1. **Chat is answered by a model that was never trained for chat.** The shipped brain is the intent fine-tune (`intentQwenS43` 1.7B default, `AppCoordinator.swift:2124`); chat turns fall through to it via `buildChat` (`IntentPrompt.swift:197-211`), so replies come from a 12-action intent model whose chat behavior is just base Qwen instruct training leaking through. `docs/multi-turn-conversation-feasibility.md:26,86` records this: stage-3 chat fine-tune never shipped, "shipped-brain chat quality is a known problem" (gibberish confirmed). The persona prompt fights it but can't override the model's prior.
2. **Greedy decoding** (`LlamaCommandInterpreter.swift:404-417`: temp 0, topK 40, topP 0.95). Temp 0 picks the single most probable token at every step — the most cliché, "assistant-like" phrasing. (The temp-0 + fixed-seed determinism is a correctness invariant from the NO-GIBBERISH fix and must stay.)
3. **Weak Nepali grammar in the base model.** Small Qwen bases have thin Nepali pretraining; with no Nepali conversational SFT, verb agreement, particles, and SOV structure come out wrong. `SpokenReplyPolisher` explicitly does surface cleanup only — "grammar stays the models' job" (`SpokenReplyPolisher.swift:21-26`).
4. **Style is declared, never demonstrated.** The persona says "warm grandchild, हजुर, short sentences" but the model has no training data showing what that register looks like in Nepali.

So the fix has three legs: a **Nepali conversation style spec** (one source of truth), **SFT data built from public conversation samples** shaped by that spec, and **runtime changes** (decode + grammar guard + cloud routing). The single-decode architecture (one JSON: `intent` + `response` + `confidence`) stays untouched — the router and its emergency gate must not regress.

## 2. The Nepali conversation pattern spec (the centerpiece)

Encode these as a single `seeds/nepali-chat-style-spec` (mirroring the byte-pinned `seeds/prompt_template.txt` discipline) consumed by personas, the data-generation prompts, the eval rubric, and the grammar guard:

| Pattern | Rule |
|---|---|
| **Register** | तपाईं + honorific verb agreement always (भन्नुभयो, खानुभयो, गर्नुहुन्छ); हजुर as the polite attention marker; never तिमी toward the elder. |
| **Particles** (the strongest "human" marker) | है (gentle tag), नि (emphasis), ल/ला (softening), अनि (continuation), हुन्छ नि. Budget: ≤1 per reply, to avoid overuse. |
| **Sentence shape** | SOV, one idea per sentence, ≤2 sentences (existing persona rule), question-tags for check-ins — "औषधि खानुभयो नि?" |
| **Small-talk repertoire** | हालखबर, खाना, निद्रा, छोराछोरी, मौसम, सम्झना/reminiscence — wellness-oriented, elder-family register. |
| **Code-switching** | Health/tech nouns stay English as actually spoken: प्रेसर, डाक्टर, मेडिसिन, फोन, चार्जर. Mirror the user's own register (the golden corpus + call transcripts show it). |
| **Forbidden AI-isms** | No lists/markdown, no "म एक AI हुँ", no canned service phrases ("कृपया नम्र निवेदन…"), no translation-ese ("यो प्रश्नको उत्तर…"), no over-politeness stacking. |

## 3. Data plan — publicly available conversation samples

Four layers, with license posture called out (important: DailyDialog/PersonaChat/EmpatheticDialogues/IndicDialogue are **CC BY-NC** — research-only; use them for the dev mix, keep the ship mix clean):

**Layer 1 — native Nepali conversation (style anchors, grammar ground truth)**
- **IndicDialogue Nepali**: 9,688 dialogues (CC BY-NC 3.0, research-only) — natural dialogue structure, weak register fit (movie subtitles).
- **Nepali call-center corpus** (InfoBayAI, CC BY 4.0-tagged but research-gated, audio-only): transcribe a sample (~100–300 h) with your existing Whisper pipeline on the training box — this is the only public source of *spoken* Nepali register; it's where है/नि/हजुर patterns live. Enterprise license needed before shipping anything trained on it.
- **kshitizgajurel/Devanagari-Ecommerce** (4,930 rows, **Apache 2.0** — commercial-safe): task-oriented reply politeness.
- Optionally **himalaya-ai/nepali-sft-dataset** and **Saugatkafley/alpaca-nepali-sft** (52k Google-translated pairs — mediocre MT quality, so teacher-cleaned and light-weight only).

**Layer 2 — translated + post-edited English dialogue (volume + topical diversity)**
- DailyDialog, PersonaChat/ConvAI2, EmpatheticDialogues (emotion/empathy — the elder-care tone) — research-only.
- Commercial-safe: **Taskmaster-1/2/3, SODA, ProsocialDialog (all CC-BY-4.0), OASST1 (Apache 2.0)**.
- Pipeline: en→ne with your own Qwen-1.7B translation tier (off-device, on the 4090 box) → **teacher post-edit** with Gemini 2.5 Flash-lite (your existing teacher, `train-intent/config.yaml:4-12`) given the style spec + few-shot real exemplars from Layer 1 → auto-filters (honorific-agreement checker, AI-ism blacklist, length) → human spot-check.

**Layer 3 — synthetic elderly-care dialogues (domain match, unlimited, commercial-safe)**
- Teacher-generated persona-grounded conversations: meds reminders, health talk, family, food, weather, memories, loneliness. Grounded in Layer-1 style anchors. ~10–20k turns.

**Layer 4 — retention claw-back (~30% of the mix)**
- Existing `eval/golden_corpus.jsonl` (8k rows), `emergency_nearmiss.jsonl`, abstain/honesty examples (the abstention ≥0.90 gate and the "abstain honesty 0.0" lesson must stay trained in), light instruction data.
- STT-noise user turns at the same 60% rate the suite already uses (`stt_noise.py`) — the model must understand *spoken* Nepali input.

**Bonus gold source**: consent-based transcripts of real Anzaan conversations (not public, but the exact target register) — the long-term ideal once you have opt-in.

Target: ~30–60k clean Nepali conversational turns post-filter.

## 4. Training — a chat-aware variant of the existing suite

Extend `tools/train-intent` with a `chat` variant (v17) rather than a new pipeline:

- **Same single-decode shape** (schema unchanged) → no chain/router surgery, catalog swap only. `LocalBrainChain` already routes chat by capability (`LocalBrainChain.swift:268-294`).
- **Base**: Qwen3-1.7B (device default, 5–8 s/turn) and Qwen3-4B for newer devices; prefer the Nepali extended-tokenizer base (`qwen4BNepali`, `ModelCatalog.swift:237`) — fewer tokens per Nepali sentence leaves budget inside the 1,024-token ceiling.
- **Recipe**: your proven QLoRA config (r=16, α=32, lr ~1e-4, 2–3 epochs, 1024 seq, Q4_K_M export), mixture 70% conversation / 30% claw-back.
- **Style via data, not prompt tokens**: no few-shot exemplars in the device prompt (they eat the 1,024 budget); the register is learned from the corpus. Add `seeds/chat_prompt_template.txt` byte-mirrored to `IntentPrompt.buildChat`, same discipline as the intent prompt.
- **Grammar comes from the data**: every assistant turn in the corpus is teacher-GEC'd before training — clean data is the grammar teacher. Optionally a short Nepali CPT phase on the [NepaliGPT Devanagari corpus](https://github.com/pudasainishushant/NepaliGPT) (383M tokens) if SFT alone doesn't fix agreement errors.

## 5. Runtime changes (P0, no training needed)

1. **Decode**: keep temp 0 + fixed seed for commands (invariant), but for **chat turns** use fixed-seed temp ~0.3 — still fully reproducible (the gibberish bug was *random* seed), yet it escapes greedy's most-cliché tokens. The GBNF `chatJSONSchema` constraint already exists.
2. **Grammar guard** at the polisher seam: a deterministic Nepali checker (तिमी/तपाईं–verb agreement, Devanagari purity, dangling particles). The polisher doc says grammar stays the models' job — so this *verifies*, never rewrites: on a flag, escalate that turn to the Gemini persona (already grammatical) or a safe template, and emit a `reply_grammar_flag` telemetry event.
3. **Cloud-first chat routing toggle**: when online, route chat to Gemini with the upgraded persona — instant grammar + conversationality for online users, local brain as fallback. Gemini's `GenerationConfig` currently sends no sampling params (`GeminiClient.swift:658-680`); set an explicit temperature for chat there.
4. **Persona upgrade**: bake the style spec's concrete rules (particles budget, code-switch nouns, forbidden AI-isms) into `chatSystemPrompt` (`LlamaCommandInterpreter.swift:552-563`) and `replyPersona` (`GeminiCommandInterpreter.swift:35-44`) — kept short for the token budget.

A future option from the [Nepali GEC literature](https://aryalsumit.com.np/nepali-grammar-correction): a QLoRA grammar-corrector on Qwen2.5-3B (F0.5 0.915 reported) — ~3.5 GB quantized is too heavy for the 6 GB-device tier today, but it's a good server-side corpus-cleaning tool now and a candidate for bigger devices later.

## 6. Evaluation and gates

- **New**: `eval/chat_golden.jsonl` (~500 held-out Nepali chat turns, teacher-authored + human-reviewed). New gates: honorific-agreement pass ≥0.98, no-AI-ism ≥0.98, LLM-judge (reuse the `stt_judge_eval` judge pattern or Gemini) mean ≥4/5 on naturalness/grammar/warmth/brevity.
- **Non-negotiable regressions** (same model, so the full suite must stay green): closed-intent ≥0.95, **emergency recall 1.00**, abstention precision ≥0.90, calibration ±0.10, latency p50 ≤1.0 s.
- **Device**: A/B on Anzaan behind the catalog pick; listening panel with actual elderly users (they are the judges of "human-like"); DV-style protocol with honorific-mismatch telemetry.

## 7. Phasing and risks

| Phase | Work | When |
|---|---|---|
| **P0** — prompt/decode/guard + cloud chat routing | Persona upgrade, chat temp 0.3 fixed-seed, grammar guard, Gemini-first chat | ~1 week, no training |
| **P1** — corpus + v17 fine-tune | Layers 1–4 build, suite extension, gates green, GGUF, A/B | ~2–4 weeks |
| **P2** — polish | DPO on judge preferences, romanized-Nepali chat, 4B tier, consent-based real transcripts | after P1 |

Risks: **gibberish history** → mitigated by keeping the temp-0/seed/GBNF discipline and shipping only past the gate harness; **intent regression** → 30% claw-back + full gate suite; **licensing** → ship mix uses only CC-BY/Apache/MIT + synthetic + own data, research layers stay in the dev mix; **latency** → 1.7B target, 4B only via the per-device resolver.

If you want to run this, it fits the ai-sdd flow as a feature spec (I'd scaffold it in a worktree, not the main checkout). The P0 items are individually small and could land as a normal PR first.

---

**Sources:**
- [IndicDialogue (Mendeley, CC BY-NC 3.0)](https://data.mendeley.com/datasets/wcb4bxbyxx/2) · [Data in Brief article](https://www.sciencedirect.com/science/article/pii/S2352340924006577)
- [InfoBayAI Nepali Call Center (audio, research-gated)](https://huggingface.co/datasets/InfoBayAI/Nepali_Call_Center_Audio_Dataset_Dual_Channel)
- [kshitizgajurel/Devanagari-Ecommerce-Dataset (Apache 2.0)](https://huggingface.co/datasets/kshitizgajurel/Devanagari-Ecommerce-Dataset)
- [himalaya-ai/nepali-sft-dataset](https://huggingface.co/datasets/himalaya-ai/nepali-sft-dataset) · [Saugatkafley/alpaca-nepali-sft](https://huggingface.co/datasets/Saugatkafley/alpaca-nepali-sft)
- [DailyDialog](https://huggingface.co/datasets/li2017dailydialog/daily_dialog) · [DailyDialog paper](https://aclanthology.org/I17-1099/) · [EmpatheticDialogues critical analysis](https://dl.acm.org/doi/pdf/10.1145/3588967.3588973) · [JPersonaChat/PersonaChat lineage](https://aclanthology.org/2025.sigdial-1.44.pdf)
- [NepaliGPT (Devanagari corpus + model)](https://github.com/pudasainishushant/NepaliGPT) · [paper](https://www.arxiv.org/pdf/2506.16399)
- [Sarvam-1 license (non-commercial — why it's excluded)](https://huggingface.co/sarvamai/sarvam-1-v0.5/blob/main/LICENSE.md)
- [Nepali GEC corpus & results](https://aryalsumit.com.np/nepali-grammar-correction) · [autoregressive Devanagari GEC framework (Zenodo)](https://zenodo.org/records/21636239)