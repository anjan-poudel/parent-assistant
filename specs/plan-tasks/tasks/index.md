# Implementation Tasks

Feature: **conversational-nepali-replies** (Conversational Nepali Replies — CNR)
Decomposition source: `specs/design-l1.md` (combined L1+L2 design of record, 2026-10-14). Total: 6 groups, 27 tasks, 0 subtasks, about 50.5 developer-days nominal.

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-34](TG-34-style-spec-chat-decode-and-persona-seams/index.md) | Style Spec, Chat Decode and Persona Seams | 3 tasks | ~5.5 days | PENDING |
| [TG-35](TG-35-grammar-guard-prompt-mirrors-and-copy/index.md) | Grammar Guard, Prompt Mirrors and Localised Copy | 3 tasks | ~4.5 days | PENDING |
| [TG-36](TG-36-cloud-chat-consent-routing-and-elder-surfaces/index.md) | Cloud Chat Consent, Routing and Elder Surfaces | 6 tasks | ~10 days | PENDING |
| [TG-37](TG-37-v17-chat-aware-training-suite/index.md) | v17 Chat-Aware Training Suite | 7 tasks | ~16 days | PENDING |
| [TG-38](TG-38-release-gate-acceptance-and-device-validation/index.md) | Release Gate, Acceptance and Device Validation | 3 tasks | ~4.5 days | PENDING |
| [TG-39](TG-39-p2-polish-and-feasibility-honesty/index.md) | P2 Polish and Feasibility Honesty | 5 tasks | ~10 days | PENDING |

Execution mode: `unit_based` with the default wave parallelism. The plan is leaf-task-only (no subtasks): the ai-sdd unit planner dispatches every non-`index.md` file under `specs/plan-tasks/tasks/**` as a unit keyed by its leading `T-<digits>` token, so subtask files would collide with their parent's id. The wave order, the critical path and the risk list live in [plan.md](../plan.md).

## ID numbering

The task tree accumulates across features: the maximum before this plan was TG-33 / T-165, so this plan continues at **TG-34 / T-166** and runs to **T-192** with no gaps. Dependencies always point to strictly lower task IDs, so ascending IDs form a valid topological order and the wave planner can build its parallel groups from the declared lines alone.

## Dependency line format

Each unit file declares its dependency as a bare id first (machine-readable for the unit planner's dependency parser), followed by a relative link (human-readable) — for example `- **Depends on**: T-166 ([T-166](TG-34-style-spec-chat-decode-and-persona-seams/T-166-nepali-chat-style-spec-and-loader.md))` (inside a unit file the same link is written relative to its group folder). `- **Depends on**: —` means the unit has no dependencies and starts in the first wave.

## Inputs, outputs and acceptance

Every unit file carries: the metadata block (group, component, agent, effort, risk, dependency line, requirement links), an acceptance criteria section in Gherkin (Given / When / Then, with a separate failure-path block for the HIGH and CRITICAL units), an explicit **Input** and **Output** statement naming what the unit consumes and produces, and a declared file list in backticks. The declared files are the unit's ownership: units that share a file are serialized into different waves by the planner, and units in the same wave own disjoint files. Each unit's deliverable is listed in its file (changed sources, new artifacts, or a notes/evidence document), together with its definition of done.

## Preconditions

- All work runs in the feature worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies` (branch `feat/conversational-nepali-replies`), never in the main checkout.
- The P0 runtime slice (TG-34, TG-35, TG-36, plus the T-185 gate and the T-186 acceptance sweep over runtime-only behaviour) is independently landable: no P0 unit depends on any P1 or P2 artifact, and the chat/P0 behaviour is specified against the currently shipped on-device model. Ordering between the P0 slice and the P1 swap is the project's open question (the design's OD-3, recorded not decided); this plan does not presume the answer, and both orderings keep the declared dependency graph valid.
- The lean workflow of 2026-10-14 is in force: no review or security-gate units exist in this plan (design-l1 is combined; review gates are dropped; one advisory non-blocking security pass rides the final sign-off). The hard safety gates (emergency recall 1.00, abstention at or above 0.90, closed-intent at or above 0.95, calibration within plus or minus 0.10) are enforced by T-181 and T-182 as code, not by review tasks.
- The device-validation completion gate (T-187) depends on an Anzaan session; without one it records every DV item as BLOCKED with the reason, and the feature stays outstanding until a session runs.
- Training legs (TG-37, TG-39) execute on the training box and produce build artifacts, not app changes; the only catalog-visible output is the gated, reversible entry of T-184.

## Top-level plan

- [plan.md](../plan.md) — summary, wave order, critical path, key risks, security-advisory mapping and requirement coverage
- [amendments/](amendments/) — plan amendments recorded against this feature run
