# T-177 — Indicator, revocation surfaces and coordinator wiring

## Metadata
- **Group:** [TG-36 — Cloud Chat Consent, Routing and Elder Surfaces](index.md)
- **Component:** Coordinator wiring and elder-facing surfaces (design-l1 sections 8.5, 8.6, 12)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** HIGH
- **Depends on**: T-171 ([T-171](../TG-35-grammar-guard-prompt-mirrors-and-copy/T-171-localisation-consent-and-safe-template-copy.md)), T-172 ([T-172](T-172-cloud-chat-consent-gate.md)), T-175 ([T-175](T-175-router-cloud-first-chat-lane.md)), T-176 ([T-176](T-176-consent-prompt-and-disclosure.md))
- **Blocks:** T-184 ([T-184](../TG-37-v17-chat-aware-training-suite/T-184-v17-catalog-entry-and-gated-swap.md)), T-185 ([T-185](../TG-38-release-gate-acceptance-and-device-validation/T-185-release-log-safety-gate-coverage.md)), T-186 ([T-186](../TG-38-release-gate-acceptance-and-device-validation/T-186-end-to-end-acceptance-and-scoped-sweep.md))
- **Requirements:** [FR-CNR-008](../../../define-requirements/FR/FR-CNR-008-cloud-first-chat-routing-toggle.md), [FR-CNR-009](../../../define-requirements/FR/FR-CNR-009-cloud-chat-consent-disclosure-indicator.md), [NFR-CNR-007](../../../define-requirements/NFR/NFR-CNR-007-telemetry-content-hygiene.md), [NFR-CNR-009](../../../define-requirements/NFR/NFR-CNR-009-accessibility.md), [NFR-CNR-010](../../../define-requirements/NFR/NFR-CNR-010-localisation-ne-en.md)

## Description
Wire the feature into the app: the coordinator supplies the routing decision's inputs (consent, online, key, cost) and owns the gate's lifecycle, the status slot shows a persistent cloud-activity badge from the moment a cloud turn is decided until its reply is spoken, and revocation is reachable three ways — a Settings row, an elder voice keyword and a spoken state query — with the next turn already local. Nothing here is touch-only, and the badge never claims activity that is not happening.

## Acceptance criteria

```gherkin
Feature: Truthful indication and reachable revocation

  Scenario: The badge is present for the whole cloud-active window
    Given a chat turn whose routing decision is cloud
    When the turn is served
    Then the status slot shows the badge from the decision until the reply is spoken
    And the badge also reflects the enabled state in Settings

  Scenario: The badge is never shown for a local turn
    Given a chat turn whose routing decision is local (any reason)
    When the turn is served
    Then the badge does not appear for that turn

  Scenario: One short spoken notice per session
    Given the first cloud-active chat turn in a session
    When the reply is prepared
    Then a short notice in the user's language is spoken once, with the badge remaining visible regardless
    And the notice is not repeated for later turns in the same session

  Scenario: Revocation works from Settings and by voice
    Given cloud chat is active
    When the elder says the revoke phrase (one deterministic keyword rule, no model involvement) or the Settings row is toggled off
    Then the gate records the revocation through its one writer
    And the next chat turn routes local and is answered by the on-device brain, losing no chat functionality

  Scenario: The state question is answerable by voice
    Given the elder asks whether the cloud is on
    When the deterministic state rule fires
    Then the app answers truthfully from the gate's current decision, in the user's language
```

## Acceptance criteria — failure paths

```gherkin
Feature: Indicator and revocation failure behaviour

  Scenario: A badge without egress is a false statement
    Given a turn where nothing is sent to the cloud
    When the surfaces are inspected
    Then the badge is absent; a build in which the badge shows during local-only traffic fails this unit's test

  Scenario: No cached route survives revocation
    Given a cloud-active turn, then a revocation
    When the next chat turn is routed
    Then the decision reads the new consent state (revocation takes effect at the next turn, never earlier, never later)

  Scenario: The keyword rules change no other routing
    Given the pre-change behaviour of every existing keyword rule
    When the new revoke and state rules are added
    Then no existing rule's behaviour changes (pinned by test) and the safety-net rules remain deterministic with no model involvement
```

## Inputs and expected result

**Input:** the routing decision (T-173) and gate (T-172); the chat lane (T-175); the prompt (T-176); the catalogue copy and spoken forms (T-171); the shipped indicator-model precedent from LiveTranslate; the coordinator's existing readiness closures and the status-slot surface; the existing keyword safety net.

**Output:** the coordinator wiring and gate lifecycle, the chat activity indicator model, the badge in the existing status slot, the Settings row, the revoke/state keyword rules with their tests, plus the indicator/revocation tests.

**Declared files:** `ios/ElderlyAssistant/App/AppCoordinator.swift`, `ios/ElderlyAssistant/App/HomeSubviews.swift`, `ios/ElderlyAssistant/App/SettingsView.swift`, `ios/ElderlyAssistant/Services/Voice/KeywordIntentRule.swift`, `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatActivityIndicator.swift`, `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatIndicatorAndRevocationTests.swift`, `ios/ElderlyAssistantTests/Services/Voice/KeywordIntentRuleTests.swift`

## Implementation notes
- Wiring: the readiness closures (`cloudChatConsent`, `cloudChatOnline`) join the existing key/cost closures the router already takes; the gate's decision is read per turn — never cached in the coordinator. Reuse the LiveTranslate indicator-model pattern for the chat badge rather than inventing a second mechanism; the badge is bound to the routing decision of a turn and its reply-spoken moment (one input, one lifetime).
- The badge reflects both an active turn and the enabled state in Settings (design section 8.5): the enabled state is read from the gate's current decision, so a revoked device shows nothing.
- Voice revocation (design section 8.6): one small deterministic keyword-rule family in the existing safety net — revoke, plus the state query. Exact phrases are authored at implementation; no NLU, no model, no widening of the chat classifier.
- The spoken notice is once per session, first cloud-active turn, in the user's language; it never replaces or delays the reply.
- Accessibility (NFR-CNR-009): every one of these behaviours is reachable without touch; the Settings row is a second path, not the only path. Large-type friendly labels; no technical terminology anywhere in the visible or spoken copy.
- No content and no identity in any event or log line this unit adds; the badge carries no text with content, only the classification of activity.
- This unit is the coordinator-file owner for the P0 window; T-184 later re-touches the same file for the catalog default resolution and declares its dependency on this unit, so the file is never edited by two units in one wave.

## Definition of done
- [ ] Gate lifecycle and routing closures wired in the coordinator; decision read per turn
- [ ] Badge present for the whole cloud-active window, absent for local turns (both pinned by test)
- [ ] One spoken notice per session at the first cloud-active turn, in the user's language
- [ ] Settings row and voice revoke both write through the gate's one writer; next turn is local
- [ ] Voice state query answered truthfully from the current decision
- [ ] Existing keyword rules unchanged (pinned); no model involvement in the new rules
- [ ] No new app permission, no Info.plist change (FR-CNR-015 boundary)
- [ ] No content or identity in any event or log line; scoped unit suites green
