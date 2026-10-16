# FR-CNR-008: Cloud-first chat routing toggle — online routes to Gemini, local brain is the floor

## Metadata
- **Area:** Cloud Chat Routing
- **Priority:** MUST
- **Source:** Proposal §5.3 ("**Cloud-first chat routing toggle**: when online, route chat to Gemini with the upgraded persona — instant grammar + conversationality for online users, local brain as fallback"); feature constitution "Cloud-first chat routing toggle (P0)" properties 1 and 7 ("The toggle never blocks chat — an unavailable, declined, or revoked cloud degrades to the on-device brain. The command ladder and emergency gate are NOT altered by chat routing"; "Reuse, don't fork … extends the existing cloud plumbing (`GeminiClient`, the router's cloud readiness inputs) — it does not add a parallel cloud path"); workflow scope comment. Surfaces: `IntentRouter.interpretLocalLadder` (:259-291) / `runLocalLadder` (:308-395), `LocalBrainChain.respondToChat` (:268-294), `GeminiClient`.

## Description
Chat turns **must** route to the cloud (Gemini, with the upgraded persona from FR-CNR-002) when the device is online and consented; otherwise the on-device brain answers. Binding properties:

- **Routing applies to chat turns only.** The command ladder, the emergency gate and the chat pre-check semantics beyond wiring the toggle are unchanged (FR-CNR-014).
- **The toggle never blocks chat.** An unavailable cloud (offline, error, timeout, rate cap), declined consent, or revocation degrades to the on-device brain; the turn is still answered. No silent failure, no dropped turn, no user-visible error where a reply is expected.
- **Honest degradation is visible to the developer path, not a false success:** a cloud-routed turn that degrades records the fallback (classification only, no content — NFR-CNR-007) rather than reporting a cloud success.
- **Reuse, not fork.** The toggle extends the existing cloud plumbing (`GeminiClient`, the router's cloud-readiness inputs); it does not add a parallel cloud path or a second provider integration.
- The on-device engine remains a first-class peer (project rule: the cloud engine is one option, never the only path).

## Acceptance criteria

```gherkin
Feature: Cloud-first chat routing with a never-failing local floor

  Scenario: Online and consented chat routes to the cloud persona
    Given the device is online and cloud chat is consented
    When the user speaks a chat turn
    Then the turn is answered through the cloud chat path using the upgraded persona

  Scenario: Offline chat is answered by the on-device brain
    Given the device is offline
    When the user speaks a chat turn
    Then the on-device brain answers
    And the reply is spoken without crash, delay beyond the envelope, or loss of the turn

  Scenario: A cloud error mid-turn degrades to the local brain
    Given cloud chat is consented and online
    When the cloud request fails or times out
    Then the turn degrades to the on-device brain
    And the degradation is recorded as a classification
    And the user still receives a reply

  Scenario: Consent is declined or revoked (failure)
    Given cloud chat consent is declined or has been revoked
    When the user speaks a chat turn
    Then no chat content leaves the device
    And the on-device brain answers the turn
```

## Related
- FR: FR-CNR-009 (consent governs routing), FR-CNR-010 (egress scope), FR-CNR-011 (cloud sampling), FR-CNR-014 (ladder/emergency unchanged), FR-CNR-006 (flag escalation uses the same path)
- NFR: NFR-CNR-002 (latency), NFR-CNR-006 (log safety)
