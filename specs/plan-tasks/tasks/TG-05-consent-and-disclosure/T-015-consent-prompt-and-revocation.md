# T-015: Consent Prompt and Revocation Surfaces

## Metadata
- **Group:** [TG-05 — Consent, Disclosure and the Cloud Indicator](index.md)
- **Component:** C09 + C13 — the consent prompt, the revocation control and their presentation
- **Agent:** dev
- **Effort:** M
- **Risk:** CRITICAL
- **Depends on:** [T-005](../TG-01-foundations/T-005-localisation-catalog-and-purpose-string.md), [T-014](T-014-consent-gate.md)
- **Blocks:** T-026, T-027
- **Requirements:** FR-LCT-012, FR-LCT-013, FR-LCT-015, NFR-LCT-004, NFR-LCT-011 · **CL-2**

## Description

Present the consent decision at the point of first need, in plain language in the active language: no
default, no bundling and no timeout. Provide an equal-weight decline that leaves the dictionary path
fully working, and a revocation control reachable from the session view and from Settings that takes
effect without a restart. The prompt copy itself is the owner-reviewed draft from T-005; this task
presents it.

Source: `Services/LiveTranslate/` `Views/` `ConsentView.swift` plus the Settings entry point under
`ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Consent prompt and revocation

  Scenario: The prompt appears at the first cloud need, not at session open
    Given the elder has not yet been asked
    When live translation opens and every visible string resolves from the dictionary
    Then no prompt is shown and the cloud indicator stays off
    And the prompt appears only when an unresolved string would otherwise be sent (FR-LCT-013)

  Scenario: The prompt is a blocking decision with no timeout
    Given the prompt is on screen
    When the elder waits without choosing
    Then the prompt remains until the elder chooses
    And no request is in flight and no auto-dismiss occurs, because an automatic dismissal would be an implicit consent

  Scenario: Granting records a decision and lets the send proceed
    Given the prompt is shown
    When the elder grants
    Then a record is written for the current disclosure version
    And the pending send proceeds without a second prompt

  Scenario: Declining keeps the dictionary path intact
    Given the prompt is shown
    When the elder declines
    Then no cloud send occurs for that string or any later string until the elder changes the decision
    And the dictionary tier and the cache continue to translate normally
    And the region shows its original text with the honest unavailable indication (FR-LCT-012)

  Scenario: The decline choice is presented with equal weight
    Given the prompt
    When it is inspected
    Then granting and declining are equally reachable, with no pre-selected default and no guilt wording
    And the explanation states in the active language that only recognized text — never images — is involved

  Scenario: Revocation is reachable and immediate from both surfaces
    Given a recorded grant
    When the elder revokes from the session view or from Settings
    Then the record is deleted, the in-memory mirror is flipped and any in-flight request is cancelled
    And the next attempt is denied without a restart (FR-LCT-015)
    And the feature continues with the dictionary tier and cached translations (FR-LCT-012)

  Scenario: A decline or revocation is not re-asked in a loop
    Given a declined or revoked state
    When another unresolved string appears
    Then the prompt is not re-shown automatically in that session
    And the unavailable indication is shown instead (failure table row 8)
```

## Implementation notes

- The prompt is a plain view presented by the session view over the live camera; it is not a system
  alert and never appears over a decision the elder did not initiate.
- Equal weight is a testable property: assert no default-selected style, comparable hit targets, and no
  wording that pressures consent. This is a graded behaviour, not a nicety.
- No timeout parameter exists for the prompt: the design states this as an explicit exception to the
  "timeouts are configurable parameters" principle, because any value for it would be wrong.
- Copy comes from the catalog by key (T-005); the disclosure version stamped into the record is owned
  by `LiveTranslateConfig` (T-001) so the OD3 copy review changes one place.
- Revocation is available from the **session view and Settings**, so it does not depend on the camera
  running.
- Emit `consent_prompt_shown`, `consent_recorded`, `consent_denied`, `consent_revoked`,
  `consent_unreadable` with `disclosureVersion` only (T-003).
- **Owner action, not agent work:** the review and approval of the consent and disclosure copy gating
  `final-sign-off`. The implementer drafts and wires it; the review is recorded at the gate.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts no prompt is shown when every string resolves from the dictionary
- [ ] A test asserts a decline suppresses automatic re-prompting and disables sends
- [ ] A test asserts revocation cancels an in-flight request and blocks the next attempt
- [ ] An accessibility test asserts equal reachability of grant and decline
- [ ] Copy is marked as a draft awaiting the owner's review at `final-sign-off`
- [ ] `ios/build.sh` passes
