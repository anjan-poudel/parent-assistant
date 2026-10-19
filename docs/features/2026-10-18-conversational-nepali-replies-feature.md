# Feature: Conversational Nepali Replies (CNR)

**Shipped:** P0 runtime 2026-10-14 ([#224](https://github.com/anjan-poudel/parent-assistant/pull/224), merge `28bce639`) · catalog/evidence batch 2026-10-16 ([#231](https://github.com/anjan-poudel/parent-assistant/pull/231), merge `bdcef697`) · 4B catalog rows 2026-10-17 ([#232](https://github.com/anjan-poudel/parent-assistant/pull/232), [#233](https://github.com/anjan-poudel/parent-assistant/pull/233)) · **Branch:** `feat/conversational-nepali-replies` · **Status:** P0 accepting; both v17 chat variants published as labeled test candidates, neither promoted; DV-1..DV-6 BLOCKED

**Source mandate:** [owner-approved proposal (2026-10-14)](2026-10-14-conversational-nepali-replies-proposal.md) · **Spec trail:** `specs/conversational-nepali-replies/` (constitution, init-report, acceptance/feasibility/DV notes), `specs/plan-tasks/plan.md`, `specs/CNR-v17-run-notes.md`, `specs/CNR-v17-evidence/` (on branch `feat/conversational-nepali-replies`)

## 1. Overview

The owner's complaint, verbatim from the scaffold report (`specs/conversational-nepali-replies/init-report.md`, 2026-10-14): *"propose how to make the brain and any reply models conversational and human like using publicly available conversation samples. the current conversation is too robotic and AI like and sometimes incorrect grammatically."* The proposal was approved the same day as an ai-sdd feature.

The proposal's diagnosis named four causes, all verified against the code:

1. **Chat answered by a model never trained for chat.** The shipped brain is the intent fine-tune (`intentQwenS43`, 1.7B default); chat turns fall through to it via `IntentPrompt.buildChat`, so replies leak a 12-action intent model's prior. Stage-3 chat training never shipped.
2. **Greedy decoding.** `LlamaCommandInterpreter` decoded at temperature 0, topK 40, topP 0.95 — temp 0 picks the most probable, most cliché "assistant" phrasing at every step. Temp-0 plus a fixed seed is a NO-GIBBERISH correctness invariant and had to stay for commands.
3. **Weak Nepali grammar in the base model.** Small Qwen bases have thin Nepali pretraining; without Nepali conversational SFT, verb agreement, particles and SOV order come out wrong. `SpokenReplyPolisher` was explicitly surface cleanup only — "grammar stays the models' job".
4. **Style declared, never demonstrated.** The persona said "warm grandchild, हजुर, short sentences", but no training data showed what that register looks like in Nepali.

The fix therefore had three legs, all in scope: a Nepali conversation **style spec** (one source of truth), **SFT data** from public conversation samples shaped by that spec, and **runtime changes** (chat decode, grammar guard, cloud-chat consent/routing). The single-decode architecture — one JSON carrying `intent` + `reply`/`response` + `confidence` — is unchanged, and the router's emergency gate is untouched.

P0 (waves 0–4) landed first by explicit decision (OD-3, 2026-10-14) and is accepting. P1 delivered the v17 corpus, the 1.7B and 4B chat-aware QLoRA variants, and two catalog rows; both rows remain unpromoted because the full gate report is not green. Device validation is the feature's completion gate and has not run.

## 2. The Nepali conversation style spec

Single source: `tools/train-intent/seeds/nepali-chat-style-spec` (222 lines; machine-readable sections, not prose). It is consumed by four kinds of consumer — the two personas (`GeminiCommandInterpreter.replyPersona`, `LlamaCommandInterpreter.chatSystemPrompt`), the data-generation prompts, the eval rubric, and the runtime guard and its style-spec loader (`NepaliGrammarGuard`, whose compiled tables carry `@style-spec-block` markers). The chat prompt template `tools/train-intent/seeds/chat_prompt_template.txt` is byte-mirrored to `IntentPrompt.buildChat`, and the persona clause carries a `@style-spec-section: persona_clause` marker so drift is a test failure, not a code review hope.

The binding rules:

| Pattern | Rule |
|---|---|
| **Register** | तपाईं + honorific verb agreement always — भन्यो → भन्नुभयो, गर्यो → गर्नुभयो, खायो → खानुभयो; हजुर as the polite attention marker. तिमी/तँ toward the elder are forbidden. |
| **Particles** | The strongest "human" marker: है (gentle tag), नि (emphasis), ल/ला (softening), अनि (continuation), and the units हुन्छ नि, होला नि, हो नि, छ नि. Budget: **≤1 per reply**. |
| **Sentence shape** | SOV, one idea per sentence, **≤2 short sentences**, no echo of the user's question, numbers spoken as words, question-tags for check-ins — "औषधि खानुभयो नि?" |
| **Small talk** | हालखबर, खाना, निद्रा, छोराछोरी, मौसम, सम्झना/reminiscence — wellness-oriented elder-family register. |
| **Code-switching** | Health/tech nouns stay English as actually spoken: प्रेसर, डाक्टर, मेडिसिन, फोन, चार्जर, भिडियो कल. Mirror the speaker's own register. |
| **Forbidden AI-isms** | No lists/markdown, no "म एक AI हुँ", no canned service phrases ("कृपया नम्र निवेदन…"), no translation-ese ("यो प्रश्नको उत्तर…"), no hedging stacks or over-politeness. |

The spec also carries the rubric (honorific agreement ≥0.98, no-AI-ism ≥0.98, judge mean ≥4.0/5), the guard checks (honorificAgreement, devanagariPurity, danglingParticle — with an empty Latin allowlist outside the code-switch lexicon), the persona clause, and the coverage classes. "Spoken units" are part of the same discipline: the polisher's `SpokenUnits.normalizeTemperatures` turns "15°C"/"15c" into "15 degrees Celsius" / "१५ डिग्री सेल्सियस" before the brevity cut, so no `°`/`C` token reaches the synthesizer.

## 3. P0 runtime (shipped)

PR **#224** (merged 2026-10-14, merge `28bce639`, waves 0–4) carried the runtime slice; PR **#231** (merged 2026-10-16, merge `bdcef697`) added the v17 catalog entry, v23 publication record and T-183/184/186/187/192 evidence on top.

| Piece | Where | What it does |
|---|---|---|
| `ChatSampling` | `ios/ElderlyAssistant/Services/Voice/ChatSampling.swift` | Per-turn decode parameters on the ONE resident handle. Chat: `chatTemperature = 0.3`, `chatSeed = OnDeviceSampling.fixedSeed` (20_260_907), `chatJSONSchema`. Command: temperature 0, same fixed seed, `commandJSONSchema` — re-asserted before every command decode, so a chat turn cannot leak temperature into commands. |
| Chat prompt/persona | `IntentPrompt.buildChat`, `LlamaCommandInterpreter.chatSystemPrompt`, `GeminiCommandInterpreter.replyPersona` | Style-spec-authored register, byte-mirrored to `seeds/chat_prompt_template.txt`; prompt budget stays inside the 1,024-token discipline. |
| `NepaliGrammarGuard` | `ios/ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift` | Verify-only. It returns a verdict and never rewrites a reply; the dispatch seam turns a flag into escalation, a safe template, or an honest degraded event, and a flagged reply is never spoken. The `reply_grammar_flag` telemetry carries no reply content. |
| `SpokenReplyPolisher` | `ios/ElderlyAssistant/Services/Voice/SpokenReplyPolisher.swift` | Deterministic cleanup and formatting before the speaker: whitespace, repeated terminal punctuation (।।→।, !!, ??), enumeration artifacts, adjacent-word dedupe ("हजुर हजुर" → "हजुर"), spoken units, brevity. Profiles: brief = 2 sentences / 25 words; standard = 4 / 45. It deliberately does not touch grammar. |
| `CloudChatConsentGate` | `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatConsentGate.swift` | Fail-closed consent store. `.granted` is the only state that allows egress; not-recorded, denied, revoked and unreadable all deny. `record(granted:)` is the only writer and `revoke()` the only deleter; a corrupt store behind the gate denies rather than guessing. |
| `CloudChatRouting` | `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatRouting.swift` | One yes: consent granted AND online AND key present; decision order consent → online → key → cost. Non-granted consent states keep distinct names for honest reasons; there is no second consent source. |
| Consent surfaces | `CloudChatConsentPrompt.swift`, `Views/CloudChatConsentSheet.swift`, `CloudChatActivityIndicator.swift` | Bilingual disclosure prompt and sheet, an activity indicator when a chat turn is in the cloud, and revocation that stops later turns. Chat is never blocked: the local answer is available while consent is pending. |

P0 acceptance: 716 tests across 30 classes — 711 passed, 4 failed in 3 cases, 1 skipped; the one flake (`CloudChatConsentGateTests.testConcurrentGrantAndRevokeNeverLeaveATornOrMixedRecord()`) went 3/3 green on re-run; the three remaining reds are pre-existing stale `intentQwen4BSlotCanon` pins. Python: 539 tests OK. Release log-safety gate `RELEASE_GATE_EXIT=0`, 33 roots / 7 event types / 24 cases / 12 rules. The catalog entry was blocked with `.gateReportMissing`, `defaultBrainModelID` stayed `intentQwenS43`, and no serving path resolved to the new entry.

## 4. The v17 corpus — four layers

Build: `tools/train-intent/src/build_chat_corpus.py`, run `cnr-v17-20261015-0209` (started 2026-10-15 02:09:41 +11:00). Target mixture: **70% conversation (L1+L2+L3) / 30% retention claw-back (L4)**.

**L1 — native Nepali conversation.** The intended style anchor was IndicDialogue Nepali (9,688 dialogues, CC BY-NC 3.0, subtitle-style movie dialogue) — natural turn structure, weak elder-register fit. It is **admissible only to the dev mix**: `indic_dialogue_ne` is pinned in the builder and provenance tests as `eligible_to_ship: false`, and the ship-mix check fails on any nonzero count. The same refusal applies to the InfoBayAI call-center corpus (CC BY 4.0-tagged but research-gated, audio-only) and to DailyDialog / PersonaChat / EmpatheticDialogues. The **ship** L1 was kshitizgajurel/Devanagari-Ecommerce (4,929 rows, Apache-2.0): 2,083 admitted after filters — task-oriented politeness, not chat, but commercially clean.

**L2 — translated + post-edited English dialogue.** Taskmaster (3,005 candidates), SODA (2,501), ProsocialDialog (1,000), all CC-BY-4.0; OASST1 (1,200, Apache-2.0) was **rejected with evidence**. Post-editing collapsed OASST1 samples 20→1, 20→9 and 20→5, with the 20→1 case collapsing to the constant sentence `म खेद व्यक्त गर्दछु, तर म तपाईंले सोधेको कुरा बुझिनँ।`; the surviving rows were assistant-QA essays, the exact register the feature exists to remove. L2: 7,706 candidates → 5,085 post-edit → **4,723 admitted**.

**L3 — teacher synthetic.** Gemini-generated persona-grounded elderly-care dialogue (meds, health, family, food, weather, memories, loneliness), grounded in L1 style anchors: 12,080 candidates → **5,609 admitted** against a 10,000 target — a recorded shortfall bound by the generation call budget.

**L4 — retention claw-back.** Existing intent material + abstain/honesty examples + edge cases: `intent_training_teacher` 20,294 own-data rows, `noised` 29,304 rows (STT-noise user turns at the same 60% rate the suite already uses), `edge_cases` 109. The eval fixtures `golden_corpus.jsonl` and `emergency_nearmiss.jsonl` were **refused as claw-back sources** so the held-out set could not leak. L4: 10,109 → 7,414 → **5,321 admitted** against a 12,000 target.

Assembled mixture: conversation 12,414 + claw-back 5,321 = **17,735 rows** after a one-row repair (pre-repair 17,736), **70.0% chat**. Train file `data/train-v17.jsonl`: **17,235 rows** (12,064 chat / 5,171 command), sha256 `52f98e20408166c31c2f8444c45cfcce2af4b8274e8a731ecea552f3d6a286ad`. Valid `data/valid-v17.jsonl`: **500 rows** (350 chat / 150 command), sha256 `62e83a9e3b1400c6638c812613c6da451e1ea7a4cb05d96614f0b3186e20b59b`.

Filter counters (rejections, in order): duplicate 8,372; held_out_user_turn 3,400; sentence_shape 1,301; devanagari_purity 1,182; length 1,025; dangling_particle 552; honorific_agreement 363; no_ai_isms 89.

Provenance manifest sha256 `fb7f7779c801706caddc74ef499198eb14c1ddc05dd89da1a7766cd476adab55`, content_hash `add5954f…`, `ship_mix_eligible: true`. The ship mix is CC-BY / Apache-2.0 / MIT + synthetic + own data only; every non-commercial or research-gated source is refused by code, not by convention.

**The defect that decided the emergency gate:** the shipped mixture contained **96 emergency rows — 0.6% of 17,235**. That is the recorded root cause of the 2026-10-17 emergency-recall failure and the reason for the claw-back top-ups in section 7.

## 5. v17 1.7B — model, floor saga, full-gate verdict

Base: `checkpoints/qwen-s43-merged` (1.7B). Base `model.safetensors` sha256 `06e326f4381858355e5b00cc01ec6f4b459d6e63fc47ab3243e4dcf20d776f95`; config `511f4cbb…`; tokenizer `edfc0debe…`; base Q4_K_M sha256 `c2135f78…`, 1,107,408,576 bytes — byte-identical to the app's existing pin.

Recipe: QLoRA NF4, r=16 / alpha=32, lr 1.5e-4, 3 epochs, `max_seq_len` 1024, bf16, batch 4 × grad-accum 4, cosine with 3% warmup, seed 42, ~3,234 steps. Training completed **2026-10-16 16:09:05 (exit 0)** after 4:49:33 of stepping; `eval_loss` 0.1656 (≈0.187 at step 1,000).

**Floor saga.** The run carried the stack's inherited token-accuracy floor of 0.90 at mid-run steps. It aborted twice:

- **step 300:** token_acc **0.862** (command 0.935, chat 0.831, json_start 1.000), checkpoint preserved as `cnr-cnr-v17-20261015-0209.abort300-preserved`;
- **step 1,000:** token_acc **0.884** (command 0.945, chat 0.857, json_start 1.000).

The owner ratified relocating the floor out of the mid-run abort (2026-10-16): the guard was disabled (`--floor-step 0`) and the same measurement retained as an end-of-run post-hoc probe. Final probe: **0.8940** token accuracy — 0.006 below the stack's 0.90 default, recorded as-is. Export at 2026-10-16 23:00:19: `intent-ne-qwen-s43-chat-v17-q4_k_m.gguf`, **1,107,408,736 bytes**, sha256 `e05cc8a266198336f508cef2f6d2a8887b3db1eee3f4a4159cdeb2ab3df59d71`.

**Full gate verdict, 2026-10-17 (recording box run):** the variant is **not swap-eligible**. The two recorded red rows are:

- `honorific_agreement` **0.974** — gate ≥0.98;
- `emergency_recall` **0.8225** — gate 1.00, downstream of the 96 emergency rows in the mixture.

The remaining gate rows and the full report are an open item (section 12); the verdict stands as "test candidate only". Catalog row `intentQwenS43ChatV17` (`intent-ne-qwen-s43-chat-v17-q4km`) is published to release **v23** — `intent-ne-qwen-s43-chat-v17-q4_k_m.gguf`, size 1,107,408,736 B, same sha — under display name **"Brain — Qwen 1.7B · Nepali chat-aware (v17 · gates pending)"**. It is explicit-pick only; `chatVariantPromotionRecord` stays blocked `.gateReportMissing`, `isAutomaticPickEligible` guards the 160-byte arithmetic promotion hazard, and `defaultBrainModelID` remains `intentQwenS43`.

## 6. v17 4B — the tier candidate

Base: `checkpoints/qwen4b-s43-merged`. Same corpus (17,235 train / 500 valid), same recipe (~3,234 steps), floor disabled (`--floor-step 0`) per the ratified restart discipline. Run id **`cnr-v17-4b-20261017-0437`**, launched 2026-10-17T04:37 box-local, ETA 9–10 hours.

End-probe: **0.9056** token accuracy — passed the 0.90 floor. This is a probe, not the full safety harness: the 4B has **no full-harness gate report** and **no tier admission measurement** yet.

Export: Q4_K_M, **2,497,278,912 bytes**, sha256 `6bb4a8b8712714861d00da2429195c1405c644c9d3228917703aeb0d2602d376`. Because GitHub caps a release asset at 2 GiB, release **v24** ships it as **two parts** (`.partaa` / `.partab`) — PR #233. Catalog row `intentQwen4BS43ChatV17` (`intent-ne-qwen4b-s43-chat-v17-q4km`), display name **"Brain — Qwen 4B · Nepali chat-aware (v17 · gates pending)"**, `minDeviceRAMBytes` 4,000,000,000. Explicit pick only, exactly like the 1.7B row; promotion untouched; tier admission on the 17 Pro Max unmeasured.

## 7. Emergency claw-back top-ups

**Round 1.** After the 2026-10-17 verdict, the claw-back was topped up with **+4,300 emergency rows** (≈19% of the new mixture) plus **~1,000 honorific rows**. Reported effect: emergency recall **0.8225 → 0.9106**. The honorific leg was not restated in that record.

**Round 2 (in flight at authoring).** The 76 exact miss rows from the round-1 gate were replicated **×20** (≈1,520 examples) and mixed into a **~24,000-row** training set. Training was running at the time of writing; the verdict is expected the evening of **2026-10-18**. If emergency recall reaches **1.00**, the next step is the **22-hour full gate decode** plus the Gemini judge leg over the 8,000-row corpus.

Both rounds are box-side records; the numbers are relayed from the training box's gate/top-up log, not from a committed file in this repo.

## 8. Gates and verification

Gate thresholds (feature constitution): honorific_agreement ≥**0.98**; no-AI-ism ≥**0.98**; judge mean ≥**4.0/5**; emergency recall **1.00**; abstention ≥**0.90**; closed-intent ≥**0.95**; calibration **±0.10**; chat latency p50 **5–8 s** (NFR-CNR-002). Command decode determinism, the emergency gate and the single-decode schema are unchanged regression gates.

**Eval sets.** `tools/train-intent/eval/golden_corpus.jsonl` is the ~8,000-row full harness; `eval/chat_golden.jsonl` is the 500-row chat fixture. The owner reviewed the chat fixture accept-all: 500/500, fixture sha moved `83283663…` → `40bec05deb7f2cc57c38a2dab3130bd93fe4c007c45aabc9ec331864aa19da47` (2026-10-16 box record; acceptance bundle dated 2026-10-17). Candidate replies: 500/500, `no_json` 0, `raw_fallback` 0, wall 1,653.2 s; meta records temp 0.0, seed 20260907, max_tokens 256, n_ctx 2048, grammar sha `76cc2583…`.

**Decode + judge.** The 8,000-row decode is paid once; the additive `--preds-out` seam (41/41 tests, sha `ee0aca33…`) records scored predictions for fixture replay. The first attempt, CPU-only, was killed at 159/8,000 turns with a ~23 h ETA, superseded and with zero evidence derived; the live rate measured 3.5–3.9 s/turn over ~8,050 rows (ETA ~08:00–08:30 on 2026-10-17). The judge is Gemini 2.5 Flash-lite, funded key staged to `secrets/gemini.env` (commit `def0d98e`) after an earlier HTTP 402 prepayment-depleted block.

**Harness parse defect (found and fixed).** `_first_complete_json` required the legacy `"action"` key while the model emits the canonical `"intent"` key, so every correct GGUF completion scored as an abstention `{"action":"none"}`. The fix is a minimal canonical-key bridge: 38/38 tests, harness sha `9a1e7484…` (was `357962ae…`). `results.csv` had zero GGUF rows before that — the path had never actually run. The 0.8940 post-hoc probe is a different code path and was unaffected.

**P0 acceptance.** Recorded in section 3: 716 tests / 30 classes (711 passed), Python 539 tests OK, release gate exit 0 (33 roots / 7 event types / 24 cases / 12 rules), and the catalog entry blocked `.gateReportMissing` with `defaultBrainModelID` unchanged.

## 9. Training-box infrastructure saga

The RTX 3090's display-engine Xid 62 lineage predates this feature; the CNR run inherited it. The sequence:

- **2026-10-15 ~03:25** — sshd wedged (banner-less) for ~14 hours and recurred later in the run. Build #1 never completed; only `l2-review.json` was written. The run resumed 2026-10-15 18:00:53 after a power-cycle.
- The assumption that a **detached chain was unaffected** by the box fault was wrong. Phase B of the run notes corrects it: the sshd wedge and the builder stall shared the box-wide fault.
- **GPU failure** surfaced as `CUDA_ERROR_UNKNOWN 999` out of `cuDevicePrimaryCtxRetain`. Two cold power-cycles (2026-10-15 17:53 and 23:31) did not clear it.
- **Final fix, 2026-10-16 06:12:** a long power-off plus a physical **3090 reseat**. The training run relaunched at 06:14:42 and completed.
- **Checkpoint resume is broken.** Hugging Face transformers rejects PEFT checkpoints for resume in this setup, so any abort means a full restart from step 0 — which is why the two floor aborts cost complete runs.
- **Speed restart** (relayed 2026-10-15 ~20:50): an 8-thread teacher pool (`CNR_TEACHER_CONCURRENCY=8`), Gemini `requests_per_minute` 25→300 for the build only, and a build-#2 skip fallback. About **$2** of mid-L3 generation was discarded in the restart.

## 10. PRs and integration

| PR | What | Merge commit | Merged |
|---|---|---|---|
| [#224](https://github.com/anjan-poudel/parent-assistant/pull/224) | `[CNR]` P0 waves 0–4: chat path, consent gates, corpus provenance, ship-gate harnesses | `28bce639` | 2026-10-14 |
| [#231](https://github.com/anjan-poudel/parent-assistant/pull/231) | Post-P0 batch: v17 catalog entry (unpromoted) + v23 publication + T-183/184/186/187/192 evidence + T-190 re-open records | `bdcef697` | 2026-10-16 |
| [#232](https://github.com/anjan-poudel/parent-assistant/pull/232) | `[CNR-4B]` 4B chat-variant catalog row (explicit pick, unpromoted) | `b105880d` | 2026-10-17 |
| [#233](https://github.com/anjan-poudel/parent-assistant/pull/233) | `[CNR-4B]` Multipart delivery for the 4B variant (v24 two-part assets) | `8ae13420` | 2026-10-17 |
| [#234](https://github.com/anjan-poudel/parent-assistant/pull/234) | Hotfix: `IntentLogReviewView` DesignTokens regression from the t056 merge | `9e29cc10` | 2026-10-17 |
| [#235](https://github.com/anjan-poudel/parent-assistant/pull/235) | Hotfix: remaining stale color tokens (accent/textPrimary/textSecondary) | `4bcfa736` | 2026-10-17 |
| [#236](https://github.com/anjan-poudel/parent-assistant/pull/236) | Hotfix: final `DesignTokens.card` sites (t056 SettingsView sections) | `3e41ebf9` | 2026-10-17 |

**Same-window sweep** (all merged 2026-10-16 23:24–23:30 UTC, immediately after #231): [#160](https://github.com/anjan-poudel/parent-assistant/pull/160) romanized-STT query extraction (`6f22812e`), [#137](https://github.com/anjan-poudel/parent-assistant/pull/137) English voice+text pairing pinned at the router (`c61cdb41`), [#15](https://github.com/anjan-poudel/parent-assistant/pull/15) TestFlight beta packaging (`3d08f42d`), [#28](https://github.com/anjan-poudel/parent-assistant/pull/28) real-model truncation gate (`531f4347`), [#16](https://github.com/anjan-poudel/parent-assistant/pull/16) cascade runtime fixes (`72282b19`), [#2](https://github.com/anjan-poudel/parent-assistant/pull/2) learning-loop capture (`b7e62cf0`).

**Integration incidents.** The t056 capture merge required three DesignTokens hotfixes (#234–#236) to keep master buildable; the failure was silent in the sense that the master build had been failing without a red signal, and a stale-derived-data trap masked the first fix attempt. Verified fixed **2026-10-18** by a `strings` check against the debug dylib, not by trusting the build log alone.

## 11. Device testing

Both chat rows are **manual picks**, not defaults. Path: **Settings → AI Models → Brain**. The rows are:

- `Brain — Qwen 1.7B · Nepali chat-aware (v17 · gates pending)`
- `Brain — Qwen 4B · Nepali chat-aware (v17 · gates pending)`

Commands and emergencies continue to resolve through the intent fine-tune; `defaultBrainModelID` is still `intentQwenS43`, and neither chat row is auto-pick eligible. The 4B row requires a 4 GB-RAM device tier; the 1.7B row requires 3 GB.

Install notes from the field (not committed to a repo doc): the **11 Pro Max** went into lock-screen loops during install and needed unlocking first; the **17 Pro Max** needed network pairing; **Anzaan** installed over USB. Device identities from the medication feature doc: Anzaan = iPhone 14 Pro Max, Amrit-1 = 17 Pro Max, Amrit = 11 Pro Max.

DV-1..DV-6 remain **BLOCKED** — no Anzaan session. Protocol and record: `specs/CNR-device-validation-protocol.md`; order DV-2 → DV-1 → DV-3 → DV-4 → DV-5 → DV-6. DV-5 covers command determinism on device; DV-6 covers latency (NFR-CNR-002 p50 5–8 s) and one-brain-resident memory (NFR-CNR-003). Anzaan's last recorded tier is iPhone 14 Pro Max, 6 GB, iOS 26.6.2 beta 23G90.

## 12. Open items

1. **Round-2 top-up verdict** — ~24,000-row mix trained from 76 misses ×20; verdict due the evening of 2026-10-18.
2. **Full gate report** — the 2026-10-17 verdict names honorific 0.974 and emergency 0.8225; the complete row-by-row report is not committed.
3. **T2 HIL sign-off + Anzaan DV-1..DV-6** — the feature's completion gate; all items BLOCKED.
4. **4B tier admission** — the full-harness gate report and the 17 Pro Max memory/latency measurement are outstanding; the end-probe is not a substitute.
5. **P2 pointer** — `docs/features/2026-10-15-p2-conversation-polish-initiative.md` (T-188 DPO, T-189 romanized, T-190 4B tier, T-191 consent transcripts). T-190 was re-opened 2026-10-17 (amendment 7) and is executing; T-188/T-189/T-191 stay descoped. Re-entry is via the ai-sdd scaffold.
6. **Promotion** — `chatVariantPromotionRecord` and `isAutomaticPickEligible` remain the only promotion path; neither row qualifies until the gates are green.

## 13. Decision log

| Date | Decision |
|---|---|
| 2026-10-14 | Lean workflow: combined design-l1, review gates dropped, one advisory non-blocking security pass at final sign-off (amendment 3). |
| 2026-10-14 | Wave-end testing: per-unit build/typecheck only, one scoped test pass per wave, full suite once at the end (amendment 4). |
| 2026-10-14 | **OD-3 resolved P0-first**: the runtime slice lands first; P1 continues on top of the P0 PR head, with the catalog swap still behind green gates (amendment 5). |
| 2026-10-15 | **P2 descope**: T-188, T-189, T-190, T-191 out of the run (amendment 6); each closes with an explicit owner-descope record, and T-192 accounts for all four. |
| 2026-10-16 | **Floor-gate ratification**: relocate the 0.90 token-accuracy floor from the mid-run abort to an end-of-run post-hoc probe; record the value whatever it is. |
| 2026-10-15/16 | **Power-cycle approvals**: two cold boots (2026-10-15 17:53 / 23:31), then the long power-off + 3090 reseat at 2026-10-16 06:12. |
| 2026-10-17 | **Super-lean + teacher parallelism**: 8-thread teacher pool, Gemini rpm 25→300 for the build, build-#2 skip (relayed to the box 2026-10-15 ~20:50). |
| 2026-10-17 | **T-190 re-open** (amendment 7): 4B tier executes in-run; T-188/T-189/T-191 remain descoped. |
| 2026-10-17 | **v23 / v24 publication as labeled test candidates**: both chat rows are explicit-pick only, display names carry "gates pending", and promotion is untouched. |
| 2026-10-18 | **Top-up round 2 launched**: 76 exact miss rows ×20 in a ~24,000-row mix; verdict that evening, then the 22-hour gate decode + Gemini judge if recall reaches 1.00. |
