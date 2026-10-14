# NFR-CNR-009: Accessibility — voice-first, house touch standards, and no routing reasoning asked of the elderly user

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Standards Accessibility ("Voice-first UI — every function accessible by voice command without requiring any touch"; "Touch UI … must use large tap targets (minimum 44x44 pt iOS …), high-contrast text, and minimum 18pt font size for body text"; "At minimum, support the primary user's configured language for all TTS output") and Compliance constraints ("Permissions must be requested at the point of use with clear plain-language explanation visible to elderly users"); feature constitution "Cloud-first chat routing toggle (P0)" property 2 (plain-language disclosure) and Success Criteria; proposal §6 (the elderly listening panel are the judges of "human-like"). Surfaces: the consent/disclosure surface, the cloud-activity indicator, the toggle/revocation control.

## Description
The new user-facing surfaces **must** meet the house accessibility standards, and the elderly user **must** never be asked to reason about routing internals. Measurable properties:

- **Voice-first**: every function on the new surfaces — consenting, revoking, learning whether the cloud is active — is reachable by voice command without requiring touch; no new behaviour is touch-only.
- **House touch standards** on each new/edited screen: tap targets at least **44x44 pt**, body text at least **18 pt**, high-contrast text; the consent/disclosure surface and the indicator obey them.
- **Indicator legibility**: while cloud chat is active, the indicator is rendered in the user's configured language at body size, and it is present for **100%** of cloud-active chat turns in the DV-2 session (FR-CNR-025) — not a one-time toast.
- **No internals asked of the user**: the disclosure and controls speak in plain language about *what happens* (their words go to a service to be answered), never in engineering terms (routing, model tiers, fallback ladders). No screen requires the user to understand the toggle to use chat.
- **Spoken feedback**: TTS output in the user's configured language covers the consent acknowledgement and any state change, so a user who cannot read the screen still knows the cloud path is on or off.
- **Non-punitive revocation**: revoking is a single clear action, and the UI states plainly that chat keeps working — the elderly user is never led to believe turning the cloud off disables the assistant.

## Acceptance criteria

```gherkin
Feature: The new surfaces are accessible and free of internals

  Scenario: The consent and revocation path is voice-reachable
    Given a user with no touch interaction
    When they give or revoke cloud chat consent by voice
    Then the state changes and is confirmed by spoken feedback in their configured language
    And no step requires touch

  Scenario: New surfaces meet the house touch standards
    Given the consent/disclosure screen and the cloud-activity indicator
    When their layout is measured
    Then every tap target is at least 44x44 pt
    And body text is at least 18 pt with high contrast

  Scenario: The indicator is present for every cloud-active turn
    Given cloud chat active during the DV-2 session
    When chat turns are exercised
    Then the indicator is shown for 100% of turns in which content goes to the cloud

  Scenario: The UI asks the user to reason about routing (failure)
    Given consent/disclosure copy or controls that describe routing, model tiers or fallback mechanics
    When the copy is reviewed
    Then it is rejected and rewritten in plain language
    And the user is never required to understand the mechanism to keep using chat
```

## Related
- FR: FR-CNR-009 (consent/disclosure/indicator/revocation), FR-CNR-025 (DV-2 evidence)
- NFR: NFR-CNR-010 (localisation of the same surfaces), NFR-CNR-011 (release gates)
