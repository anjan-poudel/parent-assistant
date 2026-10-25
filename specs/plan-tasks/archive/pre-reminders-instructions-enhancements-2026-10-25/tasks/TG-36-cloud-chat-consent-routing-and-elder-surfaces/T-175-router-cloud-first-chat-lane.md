# T-175 — Router chat lane: cloud-first decision, egress-disabled local floor, same-turn fallback

## Metadata
- **Group:** [TG-36 — Cloud Chat Consent, Routing and Elder Surfaces](index.md)
- **Component:** Router chat lane (design-l1 sections 8.2, 8.7, 8.8)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** CRITICAL
- **Depends on**: T-167 ([T-167](../TG-34-style-spec-chat-decode-and-persona-seams/T-167-local-chat-decode-shape-and-persona.md)), T-168 ([T-168](../TG-34-style-spec-chat-decode-and-persona-seams/T-168-cloud-chat-responder-and-explicit-temperature.md)), T-172 ([T-172](T-172-cloud-chat-consent-gate.md)), T-173 ([T-173](T-173-cloud-chat-routing-decision.md))
- **Blocks:** T-177 ([T-177](T-177-indicator-revocation-and-coordinator-wiring.md)), T-185 ([T-185](../TG-38-release-gate-acceptance-and-device-validation/T-185-release-log-safety-gate-coverage.md)), T-186 ([T-186](../TG-38-release-gate-acceptance-and-device-validation/T-186-end-to-end-acceptance-and-scoped-sweep.md))
- **Requirements:** [FR-CNR-008](../../../define-requirements/FR/FR-CNR-008-cloud-first-chat-routing-toggle.md), [FR-CNR-009](../../../define-requirements/FR/FR-CNR-009-cloud-chat-consent-disclosure-indicator.md), [FR-CNR-010](../../../define-requirements/FR/FR-CNR-010-cloud-chat-egress-scope.md), [FR-CNR-013](../../../define-requirements/FR/FR-CNR-013-single-decode-schema-unchanged.md), [FR-CNR-014](../../../define-requirements/FR/FR-CNR-014-router-ladder-emergency-gate-unchanged.md), [NFR-CNR-002](../../../define-requirements/NFR/NFR-CNR-002-listening-turn-latency-envelope.md)

## Description
Divert only chat-classified turns through the new lane: ask the routing decision, and either answer in the cloud or answer locally with cloud escalation disabled for that turn — so a declined or revoked consent can never leak chat content through the command ladder's cloud path. Cloud attempt failure, offline and cost blocks fall back in the same turn to the local chat path with a classification-only fallback event; command, ladder, cascade and emergency utterances take the identical code path they take today.

## Acceptance criteria

```gherkin
Feature: Chat turns route through one decision

  Scenario: Cloud-first when the decision allows
    Given a chat-classified turn and a routing decision of cloud
    When the router handles the turn
    Then the cloud chat responder answers with the turn's sanitised transcript
    And the served reply arrives at the chat dispatch as a chat command (same shape as the local path)

  Scenario: Every local reason answers locally in the same turn
    Given a chat-classified turn and a routing decision of local (each reason in turn)
    When the router handles the turn
    Then the on-device chat entry point is asked and the turn is answered without any cloud call
    And the decision is read for this turn only — a change made between turns takes effect at the next turn

  Scenario: A cloud failure falls back in the same turn
    Given a chat-classified turn and a routing decision of cloud
    And the cloud attempt fails, times out or is rate/cost blocked
    When the router handles the turn
    Then the on-device chat path answers the turn
    And a cloud-chat-fallback event is emitted carrying the reason class only

  Scenario: Command and emergency utterances are untouched
    Given the pre-change routing of every non-chat utterance class (command, ladder, cascade, emergency)
    When the same utterances are routed after this change
    Then every routing decision is byte-identical to the pre-change reference
    And the chat classifier table has not been widened
```

## Acceptance criteria — failure paths

```gherkin
Feature: Lane failure behaviour

  Scenario: A declined chat turn cannot leak through the ladder
    Given consent denied (or revoked, or unreadable) and a chat-classified turn whose local chat entry point abstains
    When the turn completes
    Then the local ladder runs with cloud escalation disabled for that turn and no cloud call of any kind is made
    And a spy on the cloud path records zero attempts

  Scenario: Emergency isolation holds
    Given an emergency utterance
    When it is routed
    Then its path performs no new blocking call and no model-independent delay — the emergency gate's precedence is untouched

  Scenario: The fallback wait is bounded
    Given a cloud attempt that never answers
    When the turn resolves
    Then the answer arrives within the local envelope plus the cloud attempt's own timeout budget — never an indefinite wait, never a user-visible error where a reply is expected
```

## Inputs and expected result

**Input:** the routing decision (T-173) and consent gate (T-172) as injected closures; the cloud chat responder (T-168); the existing local chat entry point and lane (T-167's shape); the router's existing layer order (cache, cloud preparse, cloud-first selector) and its readiness inputs.

**Output:** the chat lane in the router with its cloud branch, the egress-disabled local branch, the same-turn fallback with its classification-only event, and tests pinning the untouched non-chat routing and the no-leak property.

**Declared files:** `ios/ElderlyAssistant/Services/Intents/IntentRouter.swift`, `ios/ElderlyAssistantTests/Services/Intents/IntentRouterCloudChatLaneTests.swift`

## Implementation notes
- Insertion point: after the cache layer and the cloud-preparse layer, before the cloud-first selector block; only `.chat`-classified turns take the new branch, and the branch returns — it never falls into the selector.
- Egress-disabled floor: for a chat turn the local lane runs with cloud escalation disabled for that turn (`chatEgressDisabled`), because otherwise a chat turn's abstention could escalate to the cloud command path and violate the consent guarantee. The lane body is otherwise untouched.
- Prepared transcripts: the lane uses the transcript as prepared by the existing preparation seam (the same input the local chat path receives); the cloud request carries that sanitised text only (the responder enforces the payload shape).
- Fallback event: `cloud_chat_fallback` with classification and reason only — no transcript, no reply text. Emitted through the existing observability bus.
- Gemini-stack context (recorded in the design): on a Gemini speech stack the transcript already travels to the provider for transcription under the stack-level consent; this feature neither widens nor claims to remove that. The chat consent gate governs the reply surfaces, which is exactly what this lane implements.
- No ladder refactor: keep the emergency gate's precedence and the ladder's existing timeout and retry behaviour byte-identical; the new lane performs no blocking work of its own beyond the existing seams.
- The classifier table (exact small-talk table) is not widened by this unit.

## Definition of done
- [ ] Chat turns divert after cache/preparse and before the cloud-first selector; the branch returns
- [ ] Cloud route calls the cloud chat responder with the prepared transcript; reply reaches the chat dispatch as a chat command
- [ ] Local route (every reason) answers locally with no cloud call; spy-verified zero attempts on the declined/revoked paths
- [ ] chatEgressDisabled prevents any ladder escalation of a chat turn's abstention
- [ ] Cloud failure/timeout/cost block falls back in the same turn with the classification-only event
- [ ] Non-chat routing decisions byte-identical to the pre-change reference (pinned test); classifier table unchanged
- [ ] Emergency gate precedence untouched; no new blocking call or delay
- [ ] No content in any log or event; scoped unit suite green
