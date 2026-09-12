# TG-03: On-Device AI

> **Jira Epic:** On-Device AI

## Description

Delivers the on-device LLaMA inference engine (llama.cpp, iOS + Android), the input sanitiser and context window manager that guard the LLM from prompt injection, and the intent classifier and entity extractor that interpret voice commands. This group is the cognitive core consumed by TG-05 (Voice Session Coordinator). It also owns the brain-model catalogue and the default-brain/auto-download contract (`ModelCatalog.availableBrainEntries`, `AppCoordinator.defaultBrainModelID`) that the Settings brain picker and the model-download gate consume.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-018](T-018-llama-inference-engine/) | LlamaInferenceEngine (llama.cpp) | L+L | T-002, T-004 | HIGH |
| [T-020](T-020-input-sanitiser-context-window-manager.md) | InputSanitiser + ContextWindowManager | S | T-018 | MEDIUM |
| [T-021](T-021-intent-classifier-entity-extractor.md) | IntentClassifier + EntityExtractor | M | T-020 | MEDIUM |
| [T-045](T-045-brain-catalogue-default-verification.md) | Brain catalogue + default-brain contract verification | S | — | MEDIUM |
| [T-046](T-046-chat-framing-per-offered-brain-id.md) | Chat framing per offered brain id | M | — | HIGH (EXPEDITE: production defect) |
| [T-047](T-047-catalogue-comment-reconciliation.md) | Catalogue comment reconciliation (brain default + STT hidden-list claims) | S | T-046 | MEDIUM |
| [T-048](T-048-deferred-brain-decisions.md) | Deferred brain decisions (LAN picker entry + interpreter default) | S | T-045 | MEDIUM |

## Group effort estimate

- Optimistic (full parallel, 2 devs on T-018 subtasks): 8–14 days
- Realistic (2 devs, sequential): 17–27 days
