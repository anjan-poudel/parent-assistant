# TG-08: Nepali Intent Encoder

> **Jira Epic:** Nepali Intent Encoder

## Description

Delivers the R&D decision, design, training pipeline, on-device packaging and verification for a local Nepali intent-recognition encoder (joint intent classification + token-span slot-candidate extraction) that serves as `IntentRouter`'s local brain behind the existing `CommandInterpreter` protocol. Conditional on an explicit GO decision in T-033; the LLM/Gemini brain remains the long-tail fallback, and the keyword safety net, `TranscriptSanityGuard`, `IntentCommandCache` and the existing confirmation flow are unchanged.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-033](T-033-encoder-bake-off-export-feasibility.md) | Encoder Bake-Off + Export Feasibility (GO/NO-GO) | L | — | HIGH |
| [T-034](T-034-training-data-strategy.md) | Training-Data Strategy (schema-v2 taxonomy + BIO spans) | M | T-033, T-009 | MEDIUM |
| [T-035](T-035-joint-intent-slot-encoder-design.md) | Joint Intent+Slot Encoder Design + L2 §4.2 Amendment | M | T-033, T-034, T-021 | HIGH |
| [T-036](T-036-training-distillation-pipeline.md) | Encoder Training & Distillation Pipeline | XL | T-033, T-035, T-034 | HIGH |
| [T-037](T-037-runtime-integration/) | IntentEncoder Runtime Integration (iOS + Android) | M+M | T-036, T-020, T-021 | HIGH |
| [T-038](T-038-eval-harness-device-verification.md) | Eval-Harness Extension + On-Device Verification | L | T-036, T-037 | HIGH |

## Group effort estimate

- Optimistic (GO path; ML engineer + 2 platform devs on T-037-a/T-037-b in parallel): 31–50 days
- Realistic (1 ML engineer + 1 mobile dev, platforms sequential): 34–55 days
- Entry gates: the chain starts once T-009 (bundled Whisper for the STT-noise round-trip) and T-021 (the re-scoped intent classifier) have landed, so ~39–64 days from project start on the full-parallel plan
- NO-GO exit: T-033 closes after 6–10 days, no artifact ships, T-034–T-038 are not started, and the local brain stays `LocalIntentInterpreter` over the fine-tuned GGUF
