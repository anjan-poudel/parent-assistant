# T-176 — Consent prompt and plain-language disclosure at first cloud chat need

## Metadata
- **Group:** [TG-36 — Cloud Chat Consent, Routing and Elder Surfaces](index.md)
- **Component:** Consent prompt (design-l1 section 8.4)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** HIGH
- **Depends on**: T-171 ([T-171](../TG-35-grammar-guard-prompt-mirrors-and-copy/T-171-localisation-consent-and-safe-template-copy.md)), T-172 ([T-172](T-172-cloud-chat-consent-gate.md))
- **Blocks:** T-177 ([T-177](T-177-indicator-revocation-and-coordinator-wiring.md)), T-186 ([T-186](../TG-38-release-gate-acceptance-and-device-validation/T-186-end-to-end-acceptance-and-scoped-sweep.md))
- **Requirements:** [FR-CNR-009](../../../define-requirements/FR/FR-CNR-009-cloud-chat-consent-disclosure-indicator.md), [NFR-CNR-009](../../../define-requirements/NFR/NFR-CNR-009-accessibility.md), [NFR-CNR-010](../../../define-requirements/NFR/NFR-CNR-010-localisation-ne-en.md)

## Description
Present the disclosure and ask for consent at the first moment a chat turn would route to the cloud: a blocking prompt with no timeout and no auto-dismiss, answerable by voice (yes/no through the existing spoken-confirmation capture) or by touch, worded in plain language that names what is sent, who answers it and how to stop it. Until it is answered the turn is answered locally; a decline is recorded and chat keeps working.

## Acceptance criteria

```gherkin
Feature: Consent is asked once, plainly, and by the elder

  Scenario: The first cloud chat need presents the disclosure
    Given no consent record and a chat turn that would route to the cloud
    When the turn is handled
    Then the blocking prompt is presented with the plain-language disclosure in the user's language
    And no chat content is sent while the decision is pending

  Scenario: The talkative turn is never blocked by the question
    Given the prompt is on screen awaiting an answer
    When the same turn completes
    Then it is answered by the local chat path (the elder never loses a turn to the question)

  Scenario: Voice answers work
    Given the prompt is presented
    When the elder says yes (or no) through the existing spoken-confirmation capture
    Then the answer is recorded through the gate's one writer as granted (or denied)
    And revocation later remains possible from the same surfaces

  Scenario: A decline is final for the session
    Given the elder declines
    When a later chat turn would route to the cloud
    Then the decision reads denied, the turn answers locally, and the prompt is not shown again in this session

  Scenario: Copy comes from the catalogue in both languages
    Given the prompt, its answers and the disclosure
    When they are rendered
    Then every string resolves from the catalogue in Nepali and English with matching format slots
```

## Acceptance criteria — failure paths

```gherkin
Feature: Consent prompt failure behaviour

  Scenario: Auto-dismissal is implicit consent
    Given an implementation that dismisses the prompt after a timeout, or treats a dismissal, a backgrounding or a screen change as an answer
    When the consent test runs
    Then it fails (the doctrine is no timeout and no auto-dismiss)
    And no git state may ship a prompt with an implicit-grant path

  Scenario: A hidden default grant
    Given a device that has never answered
    When the prompt is shown and then the app is relaunched without an answer
    Then the decision is still notRecorded and egress is still refused

  Scenario: A write failure
    Given the gate reports that the grant did not persist
    When the prompt completes
    Then the failure is surfaced to the caller (and the routing decision keeps refusing egress on the next turn)
    And no success is claimed for a record that is not on disk
```

## Inputs and expected result

**Input:** the consent gate and its one writer (T-172); the catalogue copy in both languages (T-171); the existing spoken-confirmation capture and the LiveTranslate consent-prompt doctrine as the implementation precedent (blocking decision, no timer); the routing decision's consent state so the prompt appears exactly at the first cloud need.

**Output:** the prompt controller (present → answer → record, with the pending-state local answer path) and its sheet view, plus tests covering present, voice answer, decline-for-session, no-answer-on-relaunch and write-failure honesty.

**Declared files:** `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatConsentPrompt.swift`, `ios/ElderlyAssistant/Services/Intents/CloudChat/Views/CloudChatConsentSheet.swift`, `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatConsentPromptTests.swift`

## Implementation notes
- Doctrine (shipped precedent): a consent prompt is a blocking decision — no timeout, no auto-dismiss, no "dismissed means yes". Model the controller on the shipped consent-prompt pattern rather than inventing a new one.
- Presentation trigger: the first chat turn whose routing decision needs a consent answer. Do not prompt at launch, in Settings navigation, or speculatively — the prompt appears where the question becomes real, and the pending turn is answered locally meanwhile.
- Voice path: the yes/no answer rides the existing spoken-confirmation capture; the confirmation strings are part of T-171's answer keys. Touch path: the sheet's answer controls with accessibility labels; large-type friendly; no technical terms anywhere (no provider, model, server, route names).
- Write path: answers go through the gate's one writer; a failed write is surfaced and leaves the decision non-granted. Decline → denied for the session with no re-prompt (re-asking only after an explicit revoke/re-enable or an app-level reset).
- No content anywhere: the prompt never renders or logs transcript text; its events (if any) are classification-only.
- The prompt itself must not be reachable from a stranger's utterance alone: the trigger is the routing decision, which already requires a chat-classified turn (and on a Gemini speech stack, the recorded transcription exception stands — recorded in the design, not silently dropped).

## Definition of done
- [ ] Prompt presents at the first cloud chat need with the plain-language disclosure in the user's language
- [ ] No timeout or auto-dismiss path exists; a dismissal is not an answer (test-pinned)
- [ ] Pending decision → the turn is answered locally, never sent, never dropped
- [ ] Voice yes/no answers recorded through the gate's one writer; touch answers equally work
- [ ] Decline → denied, no re-prompt in the session; relaunch without an answer stays notRecorded
- [ ] Write failure surfaced; no success claimed without a persisted record
- [ ] Copy from the catalogue, both languages, matching format slots
- [ ] Accessibility: large-type friendly labels, plain language, no technical framing
