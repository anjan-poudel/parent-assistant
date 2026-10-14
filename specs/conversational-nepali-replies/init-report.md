# Scaffold Report — conversational-nepali-replies

**Mode:** brownfield-feature
**Date:** 2026-10-14
**Owner request:** "propose how to make the brain and any reply models conversational and human like using publicly available conversation samples. the current conversation is too robotic and AI like and sometimes incorrect grammatically" → approved as an ai-sdd feature spec on 2026-10-14.

## Files Created

- `specs/conversational-nepali-replies/workflow.yaml` — canonical feature workflow, hardened to the project's safety-critical baseline (design-l1 → design-l2 → review-l2 → security-design-review (STRIDE) → plan-tasks → implement (paired review, confidence 0.85, max rework 5) → review-implementation → security-test → final-sign-off (T2 + HIL)).
- `.ai-sdd/workflows/conversational-nepali-replies.yaml` — byte-identical mirror (the path `ai-sdd run --workflow conversational-nepali-replies` loads).
- `specs/conversational-nepali-replies/constitution.md` — feature constitution supplement.
- `docs/features/2026-10-14-conversational-nepali-replies-proposal.md` — the owner-approved proposal (source mandate: style spec, 4-layer data plan, v17 training, P0 runtime changes, gates, phasing).

## Inputs

- Owner-approved proposal (2026-10-14) — `docs/features/2026-10-14-conversational-nepali-replies-proposal.md`.
- Root `constitution.md` (project constitution — architecture constraints, standards, release gates bind unchanged; the cloud-chat routing needs an OD-12-shape consent/disclosure amendment).
- `requirements.md` (project brief).

## Key integration surfaces

- `ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift` — `buildChat`; templates pinned by `IntentPromptTests` (1,024-token budget) and byte-mirrored to `tools/train-intent/seeds/prompt_template.txt`.
- `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift` — decode (:404-417) + `chatSystemPrompt` (:552-563).
- `ios/ElderlyAssistant/Services/Voice/GeminiCommandInterpreter.swift` (`replyPersona`) + `Services/Gemini/GeminiClient.swift` (`GenerationConfig` — explicit chat temperature).
- `ios/ElderlyAssistant/Services/Voice/SpokenReplyPolisher.swift` — grammar-guard seam (verify-only; "grammar stays the models' job").
- `ios/ElderlyAssistant/Services/Intents/LocalBrainChain.swift` + `IntentRouter.swift` — chat-capability routing / ladder.
- `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` — v17 chat-variant catalog entry (`qwen4BNepali` extended-tokenizer base).
- `tools/train-intent/` — chat-aware v17 QLoRA variant; `seeds/` (new `nepali-chat-style-spec`, `chat_prompt_template.txt`), `eval/` (new `chat_golden.jsonl` + gates); `eval/golden_corpus.jsonl` + `eval/emergency_nearmiss.jsonl` claw-back.

## Gates

Same model serves the safety-critical intent path — the full existing suite is a non-negotiable regression (emergency recall 1.00, abstention ≥0.90, closed-intent ≥0.95, calibration ±0.10, latency p50 ≤1.0 s). New chat gates: honorific-agreement ≥0.98, no-AI-ism ≥0.98, LLM-judge ≥4/5 over `eval/chat_golden.jsonl`. Ship-mix provenance: CC-BY/Apache/MIT + synthetic + own data only.

## Next Steps

1. Review `specs/conversational-nepali-replies/constitution.md` — resolve any Open Decisions.
2. Run `ai-sdd validate-config` to verify configuration.
3. Type `/sdd-run` to start the workflow.
