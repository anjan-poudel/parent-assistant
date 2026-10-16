# Constitution — conversational-nepali-replies (feature supplement)

Applies to the `conversational-nepali-replies` workflow only (canonical `specs/conversational-nepali-replies/workflow.yaml`; mirror `.ai-sdd/workflows/conversational-nepali-replies.yaml` — the pair is kept byte-identical, per the workflow header). The project constitution (`/constitution.md`) is inherited unchanged — Architecture Constraints 1–6, Standards, release gates, and Agent Principles all bind this feature. This supplement does not restate project-level rules; it records only what the feature adds, what it must not change, and the decisions left open.

Source of truth: the owner-approved proposal `docs/features/2026-10-14-conversational-nepali-replies-proposal.md` (approved 2026-10-14, "please implement this as ai-sdd feature spec") is the source mandate. No frozen design doc exists (the proposal fixes scope, not design); `design-l1`/`design-l2` elaborate this supplement, they do not re-open it. Integration surfaces are listed in `specs/conversational-nepali-replies/init-report.md` and in the orientation table below.

Cloud-egress exception shape: the project constitution's Open Decisions 12 (voice transcription) and 13 (OCR'd text translation) are the recorded pattern for cloud egress under Architecture Constraint 1 — explicit consent, plain-language disclosure, visible indicator, revocable, on-device fallback, header-only credentials. This feature's cloud-chat routing follows that shape and is recorded here as a new explicit exception (see Safety & Compliance Delta) — not a silent divergence.

## Feature Purpose & Scope

Purpose: make the brain/reply models conversational, human-like, and grammatically correct in Nepali — the owner's 2026-10-14 complaint: replies are "too robotic and AI like and sometimes incorrect grammatically". The proposal's diagnosis names four root causes: (1) chat is answered by a 12-action intent fine-tune never trained for chat (`IntentPrompt.buildChat` falls through to it); (2) greedy decoding (temp 0) picks the most cliché, assistant-like tokens; (3) thin Nepali grammar in the base model — no conversational SFT, so agreement, particles and SOV come out wrong; (4) the style is declared in a persona string, never demonstrated in training data. The fix has three legs: a **Nepali conversation style spec** (one source of truth), **SFT data built from publicly available conversation samples shaped by that spec**, and **runtime changes** (chat decode, persona, grammar guard, cloud-first chat routing).

Primary user: the elderly Nepali-speaking person (reference device: Anzaan). Success: spoken replies stop sounding robotic/AI-like and stop being grammatically wrong — correct तपाईं/honorific verb agreement, natural particles within budget, no AI-isms or translation-ese, warm elder-family register. Online users get instantly grammatical conversational replies (cloud-first chat, with consent and a visible indicator); offline users get a materially warmer local reply. Judged by the new chat gates, all existing regression gates green, a device A/B on Anzaan behind the catalog pick, and an elderly listening-panel verdict recorded in the sign-off.

In scope:

- **P0 — runtime, no training (~1 week; lands first):** persona upgrade in `chatSystemPrompt` + `replyPersona` from the style spec; fixed-seed temp ~0.3 for chat turns only; deterministic Nepali grammar guard at the polisher seam (verify-never-rewrite; flag → escalate to the cloud persona or a safe template + `reply_grammar_flag` telemetry); cloud-first chat routing toggle (online → Gemini chat with the upgraded persona, local fallback; consent + disclosure + visible indicator in the OD-12 shape); explicit Gemini chat temperature in `GenerationConfig`.
- **P1 — corpus + chat-aware v17 fine-tune (~2–4 weeks):** data Layers 1–4 per the proposal; 70% conversation / 30% claw-back; `tools/train-intent` chat variant; new `eval/chat_golden.jsonl` (~500 held-out teacher-authored + human-reviewed turns) + new gates; GGUF + `ModelCatalog` swap only behind the gates.
- **P2 — polish (after P1):** DPO on judge preferences, romanized-Nepali chat, 4B tier, consent-based real transcripts.
- The DV protocol on Anzaan (DV-1..DV-6 below) is part of the completion gate.

Out of scope (must not change):

- The single-decode schema — one JSON (`intent` + response/reply + `confidence`). No chain/router surgery; the v17 variant is a catalog swap.
- The router ladder and emergency gate behavior; the chat pre-check semantics beyond wiring the routing toggle.
- STT behavior — the speech pipeline is not part of this feature (the STT-engine invariant stands).
- Command-turn decode determinism: temp-0 + fixed seed + GBNF `commandJSONSchema` are the NO-GIBBERISH invariants and stay untouched.
- Any new device permission; any new data collection beyond the recorded cloud-chat egress.
- Few-shot exemplars in the on-device prompt — style travels via data, not prompt tokens.

## Nepali Conversation Style-Spec Contract

Single source of truth: `tools/train-intent/seeds/nepali-chat-style-spec` (byte-pinned discipline mirroring `seeds/prompt_template.txt`) is THE definition of the conversational register. Binding properties:

1. **Single source, four consumers, no forks.** The spec is consumed by: the personas (`chatSystemPrompt`, `replyPersona`), the data-generation/teacher prompts (all four layers), the eval rubric (chat gates), and the grammar guard. No consumer restates or re-authors the rules; a rule changes in the spec first, then in its consumers. (Artifact format and consumer wiring: Open Decision 2.)
2. **Register.** तपाईं + honorific verb agreement always (भन्नुभयो, खानुभयो, गर्नुहुन्छ); हजुर as the polite attention marker; never तिमी toward the elder.
3. **Particles — the strongest "human" marker; budget ≤1 per reply.** है (gentle tag), नि (emphasis), ल/ला (softening), अनि (continuation), हुन्छ नि. Overuse is a failure, not a style. (Enforcement mechanics: Open Decision 4.)
4. **Sentence shape.** SOV, one idea per sentence, ≤2 sentences (the existing persona rule; the polisher's brevity ceiling remains the downstream backstop); question-tags for check-ins ("औषधि खानुभयो नि?").
5. **Small-talk repertoire.** हालखबर, खाना, निद्रा, छोराछोरी, मौसम, सम्झना/reminiscence — wellness-oriented, elder-family register.
6. **Code-switching.** Health/tech nouns stay English as actually spoken (प्रेसर, डाक्टर, मेडिसिन, फोन, चार्जर); mirror the user's own register.
7. **Forbidden AI-isms.** No lists/markdown; no "म एक AI हुँ"; no canned service phrases ("कृपया नम्र निवेदन…"); no translation-ese ("यो प्रश्नको उत्तर…"); no over-politeness stacking.
8. **Binding on gates.** The honorific-agreement and no-AI-ism eval gates and the grammar guard's checks are implementations of this spec; a gate failure is a spec violation, and the spec — not a gate-specific heuristic — is the authority.

## Runtime Contract

### Chat decode (P0)

1. **Commands keep the NO-GIBBERISH invariants, byte-for-byte.** temp-0 + fixed seed (`OnDeviceSampling.fixedSeed` = 20_260_907) + GBNF `commandJSONSchema`; `OnDeviceSampling` (`LlamaCommandInterpreter.swift:404-417`) and the handle creation (`:1391-1398`) are not moved by this feature. Command determinism is regression-visible as DV-5.
2. **Chat turns: fixed seed + temp ~0.3 — chat turns ONLY.** Deterministic and reproducible: same transcript and state → same reply. The gibberish bug was a RANDOM seed; a fixed seed at 0.3 stays fully reproducible. (Exact value and sampling plumbing: Open Decision 1.)
3. **The GBNF `chatJSONSchema` constraint continues to apply** to the chat decode — one JSON object (`intent`/`reply`/`confidence`); a model that cannot produce a readable object ABSTAINS (nil), it never speaks malformed output.
4. **Feasibility honesty.** If fixed-seed temp ~0.3 does not hold reproducibly on any device tier (GBNF interplay, Metal backends), the design records it explicitly for the owner — no silent drop (workflow, design-l1).

### Grammar guard (P0)

1. **Verify, never rewrite.** The guard sits at the `SpokenReplyPolisher` seam (`SpokenReplyPolisher.swift:21-26`) and inherits its doctrine: deterministic, context-free, idempotent checks only — "grammar stays the models' job". The guard never edits, patches, or regenerates the model's words.
2. **Checks (deterministic at minimum):** तिमी/तपाईं–verb agreement; Devanagari purity; dangling particles.
3. **On a flag — honest degradation, never false success:** escalate that turn to the cloud persona (when available and consented) or speak a safe template. The user never hears a reply the guard proved wrong, and never hears a "fixed" one the guard invented.
4. **Telemetry:** a `reply_grammar_flag` event carrying NO user content (no transcript, no reply text) — observability-bus policy (PII-free), log discipline per B2/T-050.
5. **Every model reply passes it** — local and cloud alike (the polisher's existing contract); the verdict is reproducible (same input → same verdict).
6. **A guard that fails to run degrades honestly** (the turn proceeds as today, or escalates) — it never blocks speech with an error and never reports a success it did not verify.

### Cloud-first chat routing toggle (P0) — recorded exception

1. **Routing.** When online and consented, chat turns route to Gemini with the upgraded persona; otherwise the local brain answers. The toggle never blocks chat — an unavailable, declined, or revoked cloud degrades to the on-device brain. The command ladder and emergency gate are NOT altered by chat routing (non-goal).
2. **Consent and disclosure (OD-12 shape — binding):** explicit user consent at first cloud chat use with plain-language disclosure; a visible indicator while conversation content is going to the cloud; revocable at any time; revoking returns to on-device without losing assistant functionality.
3. **Scope of egress:** the chat turn's user content only. No health data, contacts, or profile content beyond what the user's own utterance contains. Emergency and command content flows through the existing (unchanged) paths, not this toggle.
4. **Credential + content hygiene (B2/T-050 binding precedent):** the provider key travels in a header only — never in a URL, never in logs; conversation content must not reach logs beyond the existing transcript policy; the release-build log-surface gate (`ios/tools/check-release-log-safety.sh`) must cover the new routing/guard paths.
5. **The grammar-guard escalation obeys the same consent/disclosure rules as the toggle** — escalation is a second, smaller cloud egress surface and is consent-gated exactly like routing.
6. **Recorded exception/amendment.** This is the explicit OD-12-shape record: the cloud chat egress extends beyond Open Decision 12 (voice transcription only) and Open Decision 13 (OCR'd text only), so it is recorded here as the feature-level exception rather than left as a silent divergence from Architecture Constraint 1. At final sign-off the root constitution's recorded-exceptions list (Architecture Constraint 1 / Open Decisions 12–13) is amended to reference this entry, so the project-level record remains the authority.
7. **Reuse, don't fork.** The toggle extends the existing cloud plumbing (`GeminiClient`, the router's cloud readiness inputs); it does not add a parallel cloud path.

### Persona seams and Gemini chat temperature (P0)

1. The style spec's concrete rules are baked into BOTH personas — `chatSystemPrompt` (`LlamaCommandInterpreter.swift:552-563`) and `replyPersona` (`GeminiCommandInterpreter.swift:35-44`) — kept SHORT for the token budget; the two carry the same contract so the local and cloud paths cannot drift.
2. The pinned intent prompt (`IntentPrompt.build` text, byte-mirrored by `seeds/prompt_template.txt`, pinned by `IntentPromptTests`) stays byte-identical. The chat template (`IntentPrompt.buildChat`, `IntentPrompt.swift:197-211`) follows the seed-mirror rule below.
3. `GeminiRequest.GenerationConfig` (`GeminiClient.swift:659-661`) gains an EXPLICIT chat temperature — today it sends no sampling params, so the value is a provider default; it becomes a stated, reviewed value. (Exact value: Open Decision 5.)

## Model & Training Contract

### Single-decode integrity and catalog swap

1. The single-decode schema is unchanged (one JSON: intent + response + confidence). No chain/router surgery: chat continues through the existing capability rule (`LocalBrainChain.respondToChat`, `:268-294`) and chat pre-check (`IntentRouter.interpretLocalLadder`, `:259-291`).
2. v17 is the SAME single-decode model family behind a NEW `ModelCatalog` entry — a versioned, reversible swap with a rollback path. Because it is the same model serving the intent path, every existing gate applies as a regression gate (below).
3. Device tiers: Qwen3-1.7B is the device default; 4B only via the per-device resolver; prefer the `qwen4BNepali` extended-tokenizer base (`ModelCatalog.swift:237`) — fewer tokens per Nepali sentence leave budget inside the 1,024-token ceiling.
4. Training runs on the training box (anjan-ubuntu, 4090). Corpus and GGUF are build artifacts; the app change is the catalog entry plus the swap discipline.

### Mixture and gate harness

1. **Mixture:** 70% conversation / 30% claw-back. Layers 1–4 per the proposal (native Nepali conversation; translated + teacher-post-edited English dialogue; teacher-generated synthetic elderly-care dialogues ~10–20k turns; claw-back — `eval/golden_corpus.jsonl` 8k, `eval/emergency_nearmiss.jsonl`, abstain/honesty examples, STT-noised user turns at the suite's existing 60% rate via `stt_noise.py`). Target ~30–60k clean turns post-filter. Recipe: the proven QLoRA config (r=16, α=32, lr ~1e-4, 2–3 epochs, 1024 seq, Q4_K_M export). Assistant turns are teacher-GEC'd before training — grammar comes from the data.
2. **The gate harness is THE ship gate.** Existing gates — non-negotiable regressions, same model: closed-intent ≥0.95, emergency recall 1.00, abstention precision ≥0.90, calibration ±0.10, latency p50 ≤1.0 s. New chat gates over `eval/chat_golden.jsonl`: honorific-agreement pass ≥0.98, no-AI-ism ≥0.98, LLM-judge mean ≥4/5 (naturalness/grammar/warmth/brevity). The catalog swap ships only with ALL gates green; harness output is release evidence.
3. A red gate is a stop, not a threshold to move: the swap does not ship. (Latency risk mitigation per proposal: 1.7B target, 4B only via the resolver.)

### Data provenance — binding

1. The SHIPPED training mix uses ONLY CC-BY / Apache / MIT + synthetic + own data. CC BY-NC sources — IndicDialogue, DailyDialog, PersonaChat, EmpatheticDialogues — are dev/research-only and must never contaminate a shipped artifact. The Nepali call-center corpus (research-gated; audio-only) requires an enterprise license before anything trained on it ships.
2. A provenance manifest accompanies the training run as evidence (security-design-review / security-test focus). Contaminating a shipped artifact is a compliance event, not a training-error class.
3. Layer mapping per the proposal. Ship-safe: kshitizgajurel/Devanagari-Ecommerce (Apache-2.0), Taskmaster-1/2/3, SODA, ProsocialDialog (CC-BY-4.0), OASST1 (Apache-2.0), synthetic Layer 3, own data. Dev-only: IndicDialogue, call-center transcripts, DailyDialog, PersonaChat, EmpatheticDialogues; optional nepali-sft sets teacher-cleaned and dev-mix only until provenance is cleared.
4. The en→ne translation tier (own Qwen-1.7B, off-device) and the teacher (`gemini-2.5-flash-lite`, the existing `train-intent/config.yaml` teacher) are tooling, not shipped artifacts, but their inputs inherit rule 1.

### Prompt/seed discipline

1. `tools/train-intent/seeds/chat_prompt_template.txt` byte-mirrors `IntentPrompt.buildChat` — the mirror lands in the SAME change as any `buildChat` edit (the `prompt_template.txt` discipline applied to the chat template).
2. The chat template stays within the pinned 1,024-token on-device budget (`IntentPromptTests`' ceiling).
3. NO few-shot exemplars in the device prompt — the register is learned from the corpus; style travels via data, not prompt tokens.

## Safety & Compliance Delta

New relative to the project baseline; everything else is inherited.

1. **Same model serves the safety-critical intent path.** The v17 chat variant is a catalog swap of the SAME single-decode model that answers commands and the emergency path — a chat-data regression is a safety regression. Therefore all existing gates (emergency recall 1.00 above all) are non-negotiable regressions and the 30% claw-back mixture is the mitigation. The swap ships only behind the full gate harness.
2. **NEW cloud egress surface: chat conversation content.** The cloud-first chat routing toggle and the grammar-guard escalation send chat-turn content to Gemini, beyond the recorded exceptions (Open Decision 12 — voice transcription only; Open Decision 13 — OCR'd text only). The same consent/disclosure treatment applies (explicit consent, plain-language disclosure, visible indicator, revocable, local fallback), recorded in the OD-12 shape as an explicit exception/amendment (above) — not a silent divergence from Architecture Constraint 1. Consent/disclosure copy and the indicator UX are reviewed before the first App Store submission, consistent with the OD-12/13 review clause.
3. **Guard integrity.** The grammar guard verifies and never rewrites; escalation or a safe template on a flag; honest degradation on guard failure; `reply_grammar_flag` carries no user content. A guard that "fixes" grammar would be an unverified rewrite spoken to a vulnerable user — forbidden.
4. **Determinism invariants preserved.** Command decode stays temp-0 + fixed seed + GBNF; chat decode is fixed-seed and reproducible; the NO-GIBBERISH class stays closed.
5. **License hygiene as compliance.** CC BY-NC contamination of a shipped artifact is a compliance event (App Store distribution); the provenance manifest is the evidence.
6. **Unchanged:** STT behavior; emergency-call logic; medication flow; device permissions; the intent prompt bytes; the router/emergency gates.
7. **Gates (the workflow file is the authority for mechanics):** `security-design-review` (STRIDE required; SECURITY-GO exit), `security-test` (SECURITY-GO exit), paired review + confidence 0.85 on implement, `final-sign-off` at T2 + HIL; release gate `ios/tools/check-release-log-safety.sh` exits 0.

## Success Criteria & Completion Gate

Success:

- Spoken chat replies are warm, grammatical Nepali: correct तपाईं/honorific verb agreement, particles within the ≤1 budget, no AI-isms or translation-ese, ≤2 sentences.
- Online users get grammatical conversational replies via cloud-first chat; consent + visible indicator work; offline degrades honestly to the local brain.
- The new chat gates pass (honorific ≥0.98, no-AI-ism ≥0.98, judge ≥4/5) with ALL existing regression gates green (emergency recall 1.00, abstention ≥0.90, closed-intent ≥0.95, calibration ±0.10, latency p50 ≤1.0 s).
- The v17 catalog swap is live behind the per-device resolver, versioned and reversible.
- The elderly listening panel's verdict is recorded.

Completion gate — DV-* device validation on Anzaan, recorded in final-sign-off (the workflow header is the authority):

- DV-1 — local chat: warm, grammatical replies (honorific agreement, no AI-isms) from the shipped tier.
- DV-2 — cloud-first chat: consent + visible indicator work; toggling off returns to the on-device brain without losing chat.
- DV-3 — offline chat degrades honestly to the local brain (no crash, no false success).
- DV-4 — emergency phrasing still triggers exactly (recall untouched on device).
- DV-5 — command determinism unchanged (temp-0 behaviors, e.g. reminders/alarms).
- DV-6 — elderly listening panel A/B verdict recorded.

Release gate: `ios/tools/check-release-log-safety.sh` must exit 0, covering the new chat/routing/guard paths (no conversation content, transcript, or key material).

## Integration Surfaces (orientation)

Line numbers are orientation, not contracts. Verified against master at scaffold time (2026-10-14).

| Surface | Role in this feature |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift` — `buildChat` :197-211 | Chat prompt template; 1,024-token budget pinned by `IntentPromptTests`; byte-mirrored by `seeds/chat_prompt_template.txt` |
| `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift` — `OnDeviceSampling` :404-417; handle creation :1391-1398; `chatSystemPrompt` :552-563; `chatJSONSchema` :350; `respondToChat` :709 | Chat decode (fixed-seed temp ~0.3 for chat only); persona; GBNF chat schema; command invariants stay |
| `ios/ElderlyAssistant/Services/Voice/GeminiCommandInterpreter.swift` — `replyPersona` :35-44 | Cloud persona (same style contract as `chatSystemPrompt`) |
| `ios/ElderlyAssistant/Services/Gemini/GeminiClient.swift` — `GenerationConfig` :659-661 | Explicit chat temperature (today: no sampling params) |
| `ios/ElderlyAssistant/Services/Voice/SpokenReplyPolisher.swift` — doctrine :21-26 | Grammar-guard seam (verify-never-rewrite) |
| `ios/ElderlyAssistant/Services/Intents/LocalBrainChain.swift` — `respondToChat` :268-294 | Chat-capability routing (unchanged semantics) |
| `ios/ElderlyAssistant/Services/Intents/IntentRouter.swift` — `interpretLocalLadder` :259-291; `runLocalLadder` :308-395 | Chat pre-check + ladder; cloud-first toggle wiring lives here |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` — `defaultBrainModelID` :2133 | Ladder wiring; default brain constant |
| `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` — `qwen4BNepali` :237 | v17 chat-variant catalog entry; extended-tokenizer base |
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` — `speakSequentially` :4353 | Multi-line reply path |
| `tools/train-intent/` — `config.yaml` (teacher), `stt_noise.py` (60% rate), `eval/golden_corpus.jsonl`, `eval/emergency_nearmiss.jsonl` | v17 chat-aware QLoRA variant; claw-back sources |
| `tools/train-intent/seeds/` — NEW `nepali-chat-style-spec`, NEW `chat_prompt_template.txt` | Style spec (single source of truth) + chat template mirror |
| `tools/train-intent/eval/` — NEW `chat_golden.jsonl` | ~500 held-out turns; new gate fixtures |
| Training box anjan-ubuntu (4090); device Anzaan | P1 training run; A/B + DV protocol |

## Open Decisions

Short list — everything else is settled by the proposal, the workflow, or the project constitution. Each item is a design decision for `design-l1`/`design-l2` (or an explicit owner question where noted), resolved before the phase that needs it — none blocks scaffold.

1. **Chat temperature value + sampling plumbing (and GBNF interplay).** The proposal fixes ~0.3 with the fixed seed. `design-l1` decides the exact value and where per-shape sampling lives — the LLM handle is created once with temp 0 + fixed seed (`LlamaCommandInterpreter.swift:1391-1398`), so per-turn override vs. a shape-specific handle is open. If temp > 0 + GBNF, or fixed-seed reproducibility, does not hold on any device tier, the design records it explicitly for the owner (feasibility honesty).
2. **Style-spec artifact format + consumer wiring.** `seeds/nepali-chat-style-spec`: prose spec vs. machine-readable rules; which parts the grammar guard and eval rubric execute directly vs. read as guidance; how all four consumers (personas, data-generation prompts, eval rubric, guard) resolve against one file without duplication.
3. **P0 landing path (owner question).** The owner's directive puts the full P0→P1→P2 scope in this feature run, P0 first; the proposal explicitly allows P0 to land as a normal PR first. Sequencing is undecided — if the owner prefers the PR-first path, only ordering changes; scope and contracts are identical.
4. **Particles-budget enforcement mechanics.** Which particle set counts (है/नि/ल/ला/अनि/हुन्छ नि and variants); who enforces ≤1 per reply (grammar-guard check, eval filter/LLM-judge rubric, or both); how the check interacts with the ≤2-sentence brevity ceiling and code-switched sentences.
5. **Gemini chat temperature value.** The proposal mandates an explicit chat temperature in `GenerationConfig` but does not fix the number; the on-device side is ~0.3. `design-l1` proposes the cloud value with a rationale, reviewed at design review like the on-device one.
