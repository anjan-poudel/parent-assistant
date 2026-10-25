# TG-36 — Cloud Chat Consent, Routing and Elder Surfaces

> **Jira Epic:** Cloud Chat Consent, Routing and Elder Surfaces

## Description
The cloud chat egress surface, end to end: the fail-closed consent record, the single routing decision that is the only place egress is decided, the guard's flag resolution at the dispatch seam (the feature's second, smaller egress surface), the router lane that diverts chat turns and can never leak through the command ladder, the plain-language consent prompt, and the truthful indicator plus voice-reachable revocation. This is the group the OD-12-shape exception is actually about.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-172](T-172-cloud-chat-consent-gate.md) | CloudChatConsentGate: fail-closed consent record (OD-12 shape) | M | — | HIGH |
| [T-173](T-173-cloud-chat-routing-decision.md) | CloudChatRouting: the single fail-closed routing decision | S | T-172 | HIGH |
| [T-174](T-174-guard-flag-resolution-at-the-dispatch-seam.md) | Guard flag resolution at the dispatch seam: escalation, safe templates, telemetry | M | T-168, T-169, T-171, T-173 | CRITICAL |
| [T-175](T-175-router-cloud-first-chat-lane.md) | Router chat lane: cloud-first decision, egress-disabled local floor, same-turn fallback | M | T-167, T-168, T-172, T-173 | CRITICAL |
| [T-176](T-176-consent-prompt-and-disclosure.md) | Consent prompt and plain-language disclosure at first cloud chat need | M | T-171, T-172 | HIGH |
| [T-177](T-177-indicator-revocation-and-coordinator-wiring.md) | Indicator, revocation surfaces and coordinator wiring | M | T-171, T-172, T-175, T-176 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~10 days
- Realistic (2 devs): ~6 days

## Group-wide gates and conventions
- Scoped-suite gate and the pre-existing baseline note hold as in TG-34. The source privacy guard runs ahead of the scoped suites; the extended release log gate (T-185) covers this group's paths once they exist.
- The egress rule of the group, in one sentence: the only path to the cloud is `CloudChatRouting.decide` returning `.cloud` — every other route (including the guard's escalation) asks that same function, and every non-granted state fails closed.
- The consent record has exactly one writer; the coordinator reads the decision per turn, never caches it, and the badge is bound to the routing decision (no second source of truth for "is the cloud on").
- Voice-first: every new behaviour (consenting, revoking, learning whether the cloud is active) is reachable without touch; the Settings row is an additional path, not the only one.
- No content and no key material in any log line or event this group adds; `reply_grammar_flag` and the fallback events carry classification only.
- Content hygiene precedent (B2/T-050): the provider key travels in the request header only, never in a URL, never in a log.
