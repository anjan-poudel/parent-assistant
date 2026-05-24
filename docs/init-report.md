# Project Setup Report

## What was scaffolded

| File | Action | Notes |
|---|---|---|
| `constitution.md` | Written (replaced placeholder) | Full project constitution — all sections populated |
| `.ai-sdd/ai-sdd.yaml` | Updated | Greenfield scale + safety-critical overlays + App Store/Play Store compliance settings |
| `.ai-sdd/workflows/default-sdd.yaml` | Updated | Based on 05-greenfield-product.yaml + safety-critical and security customisations |
| `docs/init-report.md` | Created | This file |

The following files were already present and were not modified:
- `requirements.md` (existing brief — used as input)
- `CLAUDE.md` (project instructions)
- `.ai-sdd/state/` (engine state directory)
- `.ai-sdd/agents/` (project agents directory, empty — using framework defaults)
- `.ai-sdd/outputs/` (task output directory)
- `.claude/` (Claude Code project config)

`ai-sdd validate-config --project <project-path>` passed with no errors.

---

## Open decisions

These decisions must be resolved before running `/sdd-run`. Update `constitution.md` ## Open Decisions with your answers.

1. **HIPAA applicability.** Does HIPAA apply? The app processes health data (blood pressure, medications). If distributing in the US and any data is shared with a covered entity, HIPAA applies. Assumed: not applicable for initial personal-use release. Confirm or correct.

2. **GDPR applicability.** Does GDPR apply? If distributing in EU/UK, GDPR applies to health and biometric (voice) data. Assumed: deferred to a future release, but architecture must not block future compliance. Confirm or correct.

3. **On-device LLM model selection.** Which on-device LLM should be used? Must run on mid-range smartphones (e.g. iPhone 12 / Android with 6 GB RAM). Candidates: Gemma 3, Phi-3 Mini, LLaMA 3.2, Apple MLX models. Assumed: architect will propose with trade-off analysis. Confirm or correct.

4. **Cross-platform framework vs. native.** Should the app use React Native, Flutter, Kotlin Multiplatform, or fully native Swift + Kotlin? Assumed: architect will propose. Confirm or correct.

5. **Remote configuration push channel mechanism.** How should family members push config to the parent's phone end-to-end encrypted? Options: Signal Protocol over relay, FCM/APNs with payload encryption, peer-to-peer. Assumed: architect will propose. Confirm or correct.

6. **WhatsApp integration method.** WhatsApp has no public API for third-party apps. Feasibility and approach (Accessibility Services, Share Extension, WhatsApp Business API) must be evaluated. Assumed: architect will evaluate and propose. Confirm or correct.

7. **Emergency call trigger thresholds.** What are the specific blood pressure (or other metric) values that trigger emergency calling? Assumed: configurable per user via remote config, with clinically-derived safe defaults. Confirm or correct.

8. **Supported languages and dialects at launch.** Which languages must be supported at v1.0? Assumed: at least one South Asian language (Hindi, Punjabi, or Gujarati), with architecture supporting pluggable language models. Confirm or correct.

9. **Data residency.** Is there a geographic requirement for where the remote config relay server (if used) is hosted? Assumed: no requirement beyond on-device AI processing constraint. Confirm or correct.

10. **Voice activation keyword.** What is the wake-word or hotword for the always-on assistant? Assumed: architect will propose an on-device hotword detection model and default keyword. Confirm or correct.

---

## Steps to start

1. Review the open decisions above and update `constitution.md` ## Open Decisions with your answers (especially HIPAA, supported languages, and emergency thresholds — these affect architecture decisions).
2. Review `.ai-sdd/ai-sdd.yaml` — confirm `cost_budget_per_run_usd: 25.00` is acceptable for your run.
3. Review `.ai-sdd/workflows/default-sdd.yaml` — confirm the 10-task workflow matches your expected scope.
4. Open the project in Claude Code and type `/sdd-run` to begin.

---

## Configuration rationale

| Setting | Value | Default | Reason |
|---|---|---|---|
| `cost_budget_per_run_usd` | 25.00 | 10.00 | Greenfield scale — 10-task workflow with security reviews and final sign-off |
| `injection_detection_level` | quarantine | warn | App Store/Play Store health app compliance requires strict input handling; quarantine halts the task on detection |
| `overlays.hil.enabled` | true | true | Safety-critical project — retained and cannot be disabled globally |
| Workflow `define-requirements` policy_gate | T2 | T0 | Safety-critical health app — requirements need senior human sign-off before design begins |
| Workflow `implement` `paired.enabled` | true | false | Safety-critical project — paired agentic review required on all implementation output |
| Workflow `implement` `confidence.threshold` | 0.85 | 0.80 | Elevated above greenfield default — emergency call logic and health alert monitoring require higher confidence |
| Workflow `implement` `max_rework_iterations` | 5 | 4 | Multi-platform (iOS + Android) with on-device LLM + health APIs — complex enough to need extra rework budget |
| Workflow-level `max_rework_iterations` | 5 | 2 | Same rationale — safety-critical multi-platform greenfield |
| Added `security-design-review` task | — | not in base | Voice biometrics, health data, emergency calls, and E2E encrypted config all require a STRIDE threat model before implementation |
| Added `security-test` task | — | not in base | App Store and Play Store health app policies require security test evidence; voice input and health data are high-value attack surfaces |
| Added `final-sign-off` task | — | not in base | T2 human gate before app store submission — produces compliance checklist and requirements traceability document |

---

## What each agent will produce

| Task | Agent | Output | Key decisions the agent will make |
|---|---|---|---|
| `define-requirements` | BA (ba) | `.ai-sdd/outputs/define-requirements.md` — FRs, NFRs, Gherkin acceptance criteria | Decompose the brief into traceable requirements; identify gaps in health thresholds, language support, and WhatsApp integration feasibility |
| `design-l1` | Architect (architect) | `.ai-sdd/outputs/design-l1.md` — L1 system architecture | Select on-device LLM, cross-platform framework, voice biometric architecture, remote config E2E encryption approach, emergency call module isolation design, background service design for iOS and Android |
| `design-l2` | Architect (architect) | `.ai-sdd/outputs/design-l2.md` — component design | Define component interfaces, data models, API contracts for health monitoring, voice pipeline, remote config, and third-party integrations |
| `review-l2` | Reviewer (reviewer) | `.ai-sdd/outputs/review-l2.md` — GO / NO_GO | Verify component design completeness; flag safety-critical paths lacking fail-safe design; must issue GO before proceeding |
| `security-design-review` | Reviewer (reviewer) | `.ai-sdd/outputs/security-design-review.md` — SECURITY-GO / SECURITY-NO_GO | STRIDE threat model; evaluate voice biometric spoofing, health data interception, emergency call trigger manipulation, remote config interception, on-device LLM prompt injection via voice |
| `plan-tasks` | Planning Engineer (pe) | `.ai-sdd/outputs/plan-tasks.md` — implementation task breakdown | Decompose the design into implementation tasks with clear acceptance criteria; sequence tasks to de-risk safety-critical paths first |
| `implement` | Developer (dev) | `.ai-sdd/outputs/implement-notes.md` + source code | Implement per task spec; write unit tests for all safety-critical paths (100% coverage required); paired agentic review on each output |
| `review-implementation` | Reviewer (reviewer) | `.ai-sdd/outputs/review-implementation.md` — GO / NO_GO | Code quality, test coverage, safety-critical path correctness, multi-platform consistency |
| `security-test` | Reviewer (reviewer) | `.ai-sdd/outputs/security-test.md` — SECURITY-GO / SECURITY-NO_GO | Voice input injection, health data PII in logs, auth bypass, emergency call trigger validation, encrypted config payload verification |
| `final-sign-off` | Reviewer (reviewer) | `.ai-sdd/outputs/final-sign-off.md` — sign-off document | Requirements traceability matrix, security posture summary, compliance checklist (App Store / Play Store), open items, rollback plan |

---

## Estimated cost

| Item | Estimate |
|---|---|
| Budget per run | $25.00 USD |
| Number of tasks | 10 |
| Average task cost (greenfield, safety-critical) | ~$2.00 – $4.00 |
| High-cost tasks | `design-l1` (architecture decisions), `implement` (multi-platform code with paired review), `security-design-review` (STRIDE analysis) |
| Expected total | ~$20.00 – $25.00 per full run |

The `cost_enforcement: pause` setting will halt the workflow and request confirmation if the budget is reached mid-run, rather than failing hard.

---

## Validate config output

```
Validating configuration...

  ✓ ai-sdd.yaml (project config)
  — workflow.yaml (not found, using default)
  ✓ default agents (6/6)
  ✓ project agents

All configurations valid.
```

Note: "workflow.yaml (not found, using default)" is expected. The workflow is at `.ai-sdd/workflows/default-sdd.yaml`, which is the second lookup path in the engine's workflow lookup order and will be resolved correctly at runtime.
