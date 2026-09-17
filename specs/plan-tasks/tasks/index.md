# Implementation Tasks — Live Camera Translation (EN → NE, v1)

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-01](TG-01-foundations/index.md) | Foundations — types, configuration, observability, copy | 5 | ~4–5 days | PENDING |
| [TG-02](TG-02-camera-and-detection/index.md) | Camera capture and on-device text detection | 3 | ~5–7 days | PENDING |
| [TG-03](TG-03-region-stabilisation/index.md) | Region stabilisation and decluttering | 2 | ~2–2.5 days | PENDING |
| [TG-04](TG-04-dictionary-and-cache/index.md) | Tier-0 dictionary and persistent cache | 3 | ~4–7 days | PENDING |
| [TG-05](TG-05-consent-and-disclosure/index.md) | Consent gate, prompt, revocation and indicator | 3 | ~4–5 days | PENDING |
| [TG-06](TG-06-cloud-translation-tier/index.md) | Sanitiser, client method, tier orchestration | 3 | ~6–7.5 days | PENDING |
| [TG-07](TG-07-overlay/index.md) | Smart-mix placement, overlay rendering, toggle | 3 | ~5–6.5 days | PENDING |
| [TG-08](TG-08-voice-and-session-commands/index.md) | Session commands, spoken output, in-session capture | 3 | ~3–5 days | PENDING |
| [TG-09](TG-09-plugin-session-pipeline/index.md) | Pipeline, session model, plugin and session view | 2 | ~4–6 days | PENDING |
| [TG-10](TG-10-release-gates-and-evidence/index.md) | Release gate, security evidence, device protocol | 3 | ~5–7 days | PENDING |

**Totals:** 30 tasks (T-001 … T-030), all leaf tasks, ~42–58 developer-days sequential.

Execution order is T-001 → T-030 in numeric order; every dependency points at a lower task ID, so a
subagent executing top-to-bottom never assumes an unbuilt component. The recommended parallel packing
is in [../plan.md](../plan.md) (`## Summary` → recommended execution order).

Requirement IDs (FR-LCT-NNN / NFR-LCT-NNN) resolve under `../../define-requirements/`; component IDs
(C01 … C15) and parameter names are used verbatim from `../../design-component.md`; amendment IDs
(AM-1 … AM-10) come from `../../security-design-review.md` and clarification IDs (CL-1 … CL-8) from
`../../review-l2.md`.
