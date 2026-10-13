# FR-CDP-016: Automatic routing with a spoken announcement — no ask-before-fallback

## Metadata
- **Area:** Call Paths / Announcement
- **Priority:** MUST
- **Source:** Frozen design "Decisions (owner-approved)" 1 ("Fallback trigger = pre-flight feasibility + launch-failure; routing is automatic with a spoken announcement — no ask-before-fallback step for the elder"); design §7 (new key `call.announce.fallbackRouted` — "routed-channel announcement"); feature constitution Success ("the call completes via the fallback with a spoken announcement naming the actually-routed channel"); workflow `security-design-review` focus ("no silent route changes"); DV-2, DV-3.

## Description
Fallback routing **must** be automatic: the elder is **never** asked "may I fall back?" before the chain routes — the routing happens, and the spoken output names what happened (owner decision 1).

Whenever the chain routes away from the preferred channel, the app **must** speak the routed channel and the skip:

- **Voice path** — inside the existing confirmation utterance (FR-CDP-013), composing from `fellBackFrom`; the confirmation is the announcement (no extra question).
- **Tap and dial-back paths** — via the existing spoken-outcome lane (the `call.announce.*` family the tap paths already use), composed from `fellBackFrom`, under the new key `call.announce.fallbackRouted` (ne/en).
- **Launch failure** — via the same lane, under `call.announce.launchFailedFallback` (FR-CDP-015).

Binding rules: there **must** be no silent route change on any path; and when nothing fell back, no fallback announcement is spoken (no added noise for the unchanged case). The exact trigger point of the tap-path announcement (at the open) is design's to fix at design-l1 — the existence, the routed-channel content and the ne/en key are binding.

## Acceptance criteria

```gherkin
Feature: Automatic, announced fallback routing

  Scenario: A tap-path fallback routes automatically and speaks the routed channel
    Given a tap resolves to an infeasible preferred channel
    When the user taps the call button
    Then the chain routes without asking the user first
    And the routed channel is spoken (call.announce.fallbackRouted), naming what was skipped

  Scenario: The voice path carries routing and disclosure in one confirmation
    Given the preferred channel is infeasible for the target
    When the user asks to call the contact
    Then a single confirmation utterance carries the routing decision and the disclosure
    And no separate ask-before-fallback question is spoken

  Scenario: No fallback produces no fallback announcement
    Given the preferred channel is feasible
    When any call path initiates the call
    Then no fallback announcement is spoken
```

## Related
- FR: FR-CDP-008 (provenance driving the copy), FR-CDP-013 (voice-path disclosure), FR-CDP-015 (launch-fail lane), FR-CDP-017 (localised keys)
- NFR: NFR-CDP-003 (announcement content/log policy), NFR-CDP-007 (localisation)
