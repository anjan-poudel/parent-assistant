# FR-CDP-009: Preferred input — an explicit per-contact/family pick wins as the chain's preferred

## Metadata
- **Area:** Chain Resolution / Input
- **Priority:** MUST
- **Source:** Frozen design §4 ("the explicit per-contact/family pick (when present) is `preferred`, else `defaultCallApp`; `secondaryCallApp` is `secondary`") and Goal 3 ("Per-contact and family picks keep winning as the chain's preferred input"); feature constitution Feature Constraint 5 ("No per-contact primary/secondary storage. Per-contact and family picks keep winning as the input to the chain; this feature adds only the settings-level preference."); workflow scope comment ("per-contact pick wins as preferred").

## Description
The chain's **preferred** input **must** be determined as follows:

- When the call target has an explicit pick, that pick is preferred. Sources, per existing seam: the address-book row's `ChannelPreferenceStore` preference (`resolvedCallChannel`'s `explicit`), and the family contact's pick as the button/dial-back vocabulary yields it (audio buttons: `FamilyContact.resolvedAudioApp`; video buttons: `resolvedVideoApp`; missed-call dial-back: the matched family contact's audio pick, as today).
- When no explicit pick exists, the settings **primary** (`defaultCallApp`) is preferred.

The settings **fallback** (`secondaryCallApp`) is always the chain's secondary step, and `.phone` always the terminal floor (FR-CDP-007). Consequence to pin: when an explicit pick exists and is infeasible, the next attempt is the settings fallback — the settings primary is not consulted in that case (the chain is `preferred → secondary → phone`, not `explicit → primary → secondary → phone`).

**No per-contact primary/secondary storage is introduced**: explicit picks remain inputs to the settings-level chain only (Feature Constraint 5, out of scope otherwise).

## Acceptance criteria

```gherkin
Feature: Chain preferred input precedence

  Scenario: An explicit per-contact pick is the preferred input
    Given an address-book row has an explicit channel preference of WhatsApp
    And the settings primary is FaceTime
    When the row's call resolves
    Then the chain's preferred input is whatsApp

  Scenario: Without an explicit pick the settings primary is the preferred input
    Given the target has no per-contact or family pick
    And the settings primary is Messenger
    When the call resolves
    Then the chain's preferred input is messenger

  Scenario: An infeasible explicit pick moves to the settings fallback, not the settings primary
    Given the target's explicit pick is Messenger with no handle on file
    And the settings primary is FaceTime
    And the settings fallback is WhatsApp
    When the call resolves
    Then the chain attempts whatsApp next
    And FaceTime is not consulted as a chain step
```

## Related
- FR: FR-CDP-007 (the chain), FR-CDP-010/011 (call paths that supply the explicit input), FR-CDP-012 (voice path's separate chain)
- NFR: NFR-CDP-009 (regression pin on per-contact behaviour)
