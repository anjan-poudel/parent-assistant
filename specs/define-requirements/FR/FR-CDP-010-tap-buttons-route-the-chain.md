# FR-CDP-010: Address-book and family-contact call buttons route the chain

## Metadata
- **Area:** Call Paths / Tap Buttons
- **Priority:** MUST
- **Source:** Frozen design §4 ("`resolvedCallChannel` ... run the chain ... Call sites updated: address-book row buttons (`LeafViews.swift:1612`), family-contact buttons ...") and Goal 3; feature constitution "In scope" ("Applying the chain to **all** call paths: address-book + family-contact call buttons"); workflow scope comment; DV-6.

## Description
Every tap-initiated call button **must** resolve through the chain (FR-CDP-007):

- **Address-book row call buttons** (`LeafViews.swift` ~L1612, resolving through `AppCoordinator.resolvedCallChannel`) — the row's explicit `ChannelPreferenceStore` pick (when present) is preferred, else the settings primary; feasibility from the target's handle (FR-CDP-004) and the WhatsApp probe (FR-CDP-005); GSM terminal.
- **Family-contact call buttons** (audio/video) — the contact's preference as the button vocabulary yields it is preferred, else the settings primary; same chain and feasibility.

Binding properties:
- The existing button vocabulary **must** be preserved: audio buttons never resolve to FaceTime and video buttons never to the GSM dialer (`CallApp.supportsAudio` / `supportsVideo` gates unchanged); a deliberate tap still needs no voice confirmation (the tap IS the confirmation — unchanged).
- The previous Messenger-no-handle hard rule **must** become one case of the chain (an infeasible preferred channel hops to the fallback, then GSM).
- A tap **must never dead-end**: when the row's or contact's preferred channel is infeasible, the chain routes to the next attemptable channel and the call is attempted.

## Acceptance criteria

```gherkin
Feature: Tap call buttons route the chain

  Scenario: An infeasible row preference falls back instead of dead-ending
    Given an address-book row resolves to Messenger with no handle on file
    And the settings fallback is phone
    When the user taps the row's call button
    Then the call is attempted via the fallback channel
    And the tap never dead-ends

  Scenario: A feasible preference keeps today's behaviour
    Given a row's preferred channel is feasible
    When the user taps the row's call button
    Then the preferred channel is opened exactly as before the feature

  Scenario: Equal picks with an infeasible preferred channel reach the GSM floor
    Given the preferred and fallback channels are the same infeasible channel
    When the user taps a row's call button
    Then the channel is attempted at most once
    And the call is attempted via tel: (GSM)
```

## Related
- FR: FR-CDP-004/005 (feasibility inputs), FR-CDP-007 (the chain), FR-CDP-009 (preferred input), FR-CDP-011 (dial-back), FR-CDP-016 (routed-channel announcement)
- NFR: NFR-CDP-001 (never dead-ends), NFR-CDP-009 (no regression to shipped tap behaviour)
