# T-174 — Guard flag resolution at the dispatch seam: escalation, safe templates, telemetry

## Metadata
- **Group:** [TG-36 — Cloud Chat Consent, Routing and Elder Surfaces](index.md)
- **Component:** Dispatch seam — guard call site and flag outcome (design-l1 sections 7.1, 7.3, 7.4, 7.5)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** CRITICAL
- **Depends on**: T-168 ([T-168](../TG-34-style-spec-chat-decode-and-persona-seams/T-168-cloud-chat-responder-and-explicit-temperature.md)), T-169 ([T-169](../TG-35-grammar-guard-prompt-mirrors-and-copy/T-169-nepali-grammar-guard-core.md)), T-171 ([T-171](../TG-35-grammar-guard-prompt-mirrors-and-copy/T-171-localisation-consent-and-safe-template-copy.md)), T-173 ([T-173](T-173-cloud-chat-routing-decision.md))
- **Blocks:** T-185 ([T-185](../TG-38-release-gate-acceptance-and-device-validation/T-185-release-log-safety-gate-coverage.md)), T-186 ([T-186](../TG-38-release-gate-acceptance-and-device-validation/T-186-end-to-end-acceptance-and-scoped-sweep.md))
- **Requirements:** [FR-CNR-005](../../../define-requirements/FR/FR-CNR-005-grammar-guard-verify-never-rewrite.md), [FR-CNR-006](../../../define-requirements/FR/FR-CNR-006-guard-flag-escalation-honest-degradation.md), [FR-CNR-007](../../../define-requirements/FR/FR-CNR-007-reply-grammar-flag-telemetry-no-content.md), [NFR-CNR-006](../../../define-requirements/NFR/NFR-CNR-006-log-safety.md), [NFR-CNR-007](../../../define-requirements/NFR/NFR-CNR-007-telemetry-content-hygiene.md)

## Description
Wire the guard into the chat dispatch: the verdict is computed over the exact post-polish text that would be spoken, and a flag resolves honestly and permanently — escalate once to the cloud chat call when the local shape flagged and the routing decision allows egress, otherwise speak a localised safe template — while the flagged text is never spoken. Every outcome emits the content-free reply-grammar-flag event, and a guard that cannot answer emits degraded rather than pretending to have verified.

## Acceptance criteria

```gherkin
Feature: Honest resolution of a flagged chat reply

  Scenario: A pass speaks the text byte-identically
    Given a chat reply whose guard verdict is pass
    When the reply is dispatched
    Then the polished text is spoken byte-identically (the guard changes nothing)
    And the flag event carries the not-applicable outcome

  Scenario: A flagged local reply escalates once
    Given a flagged reply that came from the on-device chat shape
    And the routing decision yields cloud for this turn
    When the flag resolves
    Then the cloud chat call is issued for the same turn's transcript
    And the escalation reply is itself run through the guard before speaking

  Scenario: A flagged reply with no reachable cloud speaks a safe template
    Given a flagged reply and a routing decision that yields local (any reason)
    When the flag resolves
    Then a localised safe template from the bounded, spec-authored set is spoken
    And the event records the safe-template outcome with the check classes that flagged

  Scenario: A flagged cloud reply takes the safe-template path only
    Given a flagged reply that came from the cloud shape
    When the flag resolves
    Then the safe template is spoken (no escalation back to the same cloud)

  Scenario: The turn is always answered
    Given any flag resolution above
    When the turn completes
    Then the user hears a reply in every case — the turn is never dropped, never met with silence or an error
```

## Acceptance criteria — failure paths

```gherkin
Feature: Flag resolution failure behaviour

  Scenario: The flagged text must never be spoken
    Given any resolution path (escalation, safe template, escalation failure)
    When the spoken sequence is captured
    Then the flagged text is absent from it

  Scenario: A failed or re-flagged escalation stops at the safe template
    Given an escalation that times out, fails, or whose reply also flags
    When the flag resolves
    Then the safe template is spoken in the same turn
    And exactly one escalation attempt is made (no retry loop)

  Scenario: A guard that cannot answer degrades visibly
    Given a guard verdict of unavailable
    When the reply is dispatched
    Then today's behaviour stands (the polished text is spoken) and the event records the degraded outcome
    And no "verified" outcome is ever reported for a reply the guard did not verify

  Scenario: The event carries no user content
    Given any emitted flag event
    When its payload is inspected
    Then it contains only the permitted fields (event kind, serving path, check classes, outcome, counters, timestamps)
    And adding any content-bearing field fails this unit's test
```

## Inputs and expected result

**Input:** the guard core (T-169); the cloud chat responder (T-168) for the escalation call; the routing decision (T-173); the safe-template copy (T-171); the existing chat dispatch case, the polisher call site and the observability bus with its allowed-keys policy.

**Output:** the guard call site and flag resolution in the chat dispatch, the content-free reply-grammar-flag event on the existing bus, and tests covering pass, escalate, safe template, degraded and the failure paths above.

**Declared files:** `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift`, `ios/ElderlyAssistantTests/Services/Voice/ReplyGrammarFlagResolutionTests.swift`

## Implementation notes
- Call site: the `.chat` case of the dispatch, after the confidence floor (unchanged) and after the polisher's candidate text is computed, before speaking — the verdict is computed over the exact text that would be spoken, and the transcript is still in scope for the escalation. Both local and cloud chat replies arrive at this one case, so "every model reply passes the guard, local and cloud alike" holds structurally.
- Escalation guard: the escalation reply is verified by the same guard before speaking; if it passes, speak it; if it flags or the call fails/times out, the safe template owns the turn. One attempt only.
- Safe templates: deterministic selection keyed by check class from the bounded set in the catalogue; they are the localised, register-correct fallbacks, never free-form text.
- Event schema (frozen before implementation, per the design): event kind; serving path (on-device/cloud, read from the existing provenance record); check classes (space-joined, empty for degraded); outcome (escalated / safeTemplate / degraded / notApplicable); counters; timestamps. Forbidden fields: transcript, reply text, identity, health values, contacts, profile, key material. This unit's test asserts the emitted payload's key set exactly.
- Guard-unavailable keeps today's behaviour (speak the polished text) and emits degraded — a guard that is not running must be visible rather than silently absent, and it must never block speech.
- Do not add any Release-compiled console write: the event goes through the observability bus, and T-185 extends the release log gate over this file.
- Readiness closures for the escalation come in from the coordinator wiring (T-177); this unit consumes them as injected inputs so it stays testable without the coordinator.

## Definition of done
- [ ] Guard verdict computed over the post-polish text at the chat dispatch; a pass speaks byte-identically
- [ ] Flag resolution: escalate once when local-shape and cloud-allowed; otherwise safe template; flagged cloud reply takes the safe-template path
- [ ] Escalation reply verified by the guard; failure or re-flag stops at the safe template with exactly one attempt
- [ ] Flagged text never spoken (asserted on every path)
- [ ] unavailable → today's behaviour plus degraded outcome; never a false verified
- [ ] reply-grammar-flag event emitted with exactly the permitted fields; content-bearing field fails the test
- [ ] No Release-compiled console write; no content in any log line
- [ ] Scoped unit suite green, including the flagged-command-regression guard that command replies are untouched by this case
