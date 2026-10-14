# TG-37 — v17 Chat-Aware Training Suite

> **Jira Epic:** v17 Chat-Aware Training Suite

## Description
The P1 leg: a chat-aware QLoRA variant of the intent suite trained on a four-layer, license-tracked Nepali conversation corpus, gated by three new chat metrics plus the unchanged hard safety gates, and shipped as a versioned, reversible catalog entry. The hard gates (emergency recall 1.00, abstention at or above 0.90, closed-intent at or above 0.95, calibration within plus or minus 0.10) stay enforced here — they are gate code, not review gates.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-178](T-178-chat-golden-heldout-set.md) | chat_golden.jsonl: the held-out chat evaluation set | L | T-166 | HIGH |
| [T-179](T-179-four-layer-chat-corpus-pipeline.md) | Four-layer chat corpus pipeline with spec-driven filters and teacher GEC | L | T-166, T-178 | HIGH |
| [T-180](T-180-provenance-manifest-and-ship-mix-enforcement.md) | Provenance manifest and ship-mix enforcement | M | T-179 | CRITICAL |
| [T-181](T-181-chat-gate-harness.md) | Chat gate harness: honorific rate, AI-ism rate and the recorded judge | M | T-166, T-178 | HIGH |
| [T-182](T-182-chat-variant-config-and-full-harness.md) | Chat-variant config and the full ship gate over one candidate | M | T-179, T-180, T-181 | HIGH |
| [T-183](T-183-v17-chat-aware-qlora-run.md) | The v17 chat-aware QLoRA run and its gate evidence | L | T-180, T-181, T-182 | HIGH |
| [T-184](T-184-v17-catalog-entry-and-gated-swap.md) | v17 catalog entry and the gated, reversible swap | M | T-177, T-183 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~16 days (the run itself is mostly unattended box time)
- Realistic (2 devs): ~12 days

## Group-wide gates and conventions
- This group is the feature's one review-free zone of trust: the gates are the review. A red gate stops the swap and the shortfall is reported to the owner — thresholds, fixtures and measurements are never adjusted to turn a gate green.
- Training-suite discipline: the pipeline and harness run locally and on the training box; the flag-off path must stay byte-identical so the suite's recorded runs remain reproducible.
- Compliance constants: the ship mix is CC-BY/Apache/MIT + synthetic + own data only; the CC BY-NC research layers and the research-gated transcripts exist in dev mixes only and can never reach a shipped artifact.
- Data honesty: no real user utterances enter any fixture or corpus without a recorded consent (the P2 transcript leg owns that regime); the held-out chat set is synthetic and reviewed.
- The training artifacts (corpus, GGUF, manifests, gate reports) are build artifacts, not app changes; only T-184 touches the iOS tree in this group.
