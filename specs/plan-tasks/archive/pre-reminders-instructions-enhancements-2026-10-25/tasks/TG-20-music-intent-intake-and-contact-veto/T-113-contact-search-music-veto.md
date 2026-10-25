# T-113: VoiceContactSearchRoute music veto

## Metadata
- **Group:** [TG-20 — Music Intent Intake and Contact Veto](index.md)
- **Component:** C-SP-08 `VoiceContactSearchRoute` (music veto insertion)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-112](T-112-keyword-intent-rule-music.md)
- **Blocks:** [T-116](../TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md)
- **Requirements:** [FR-SP-014](../../../../define-requirements/FR/FR-SP-014-contact-search-veto-parity.md), [NFR-SP-006](../../../../define-requirements/NFR/NFR-SP-006-no-regression.md)

## Description
Inserts the music veto into `VoiceContactSearchRoute` at the verified insertion point: after the direct-call veto and before the YouTube veto. A search-marker utterance that carries a music marker must not be routed to contact search; the veto mirrors the shipped YouTube veto shape and preserves grapheme-cluster semantics.

## Acceptance criteria

```gherkin
Feature: Contact-search veto for music utterances

  Scenario: A music utterance is vetoed before contact search
    Given a search-marker utterance that also carries a music marker
    When the route ladder evaluates it
    Then the music veto fires and contact search does not
    And the utterance proceeds toward the music path

  Scenario: Existing vetoes and matching semantics are unchanged
    Given the shipped direct-call and YouTube veto fixtures
    When the route ladder evaluates them
    Then each behaves exactly as at baseline
    And partial-word grapheme-cluster matching for contact names is preserved
```

## Implementation notes
- File: `ios/ElderlyAssistant/` + `Voice/VoiceContactSearchRoute.swift`; one veto block in the verified position (after direct-call, before YouTube).
- F-6 residual (accepted trade-off, record it): a contact whose name literally contains a full music marker is no longer reachable through a search-marker utterance containing that name; near-misses stay protected by grapheme-cluster semantics. Add a test comment naming F-6 at the fixture that documents it.
- Extend `VoiceContactSearchRouteTests` with the music veto fixtures plus the baseline veto fixtures unchanged.
- No log changes; utterance text must not enter logs (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (VoiceContactSearchRouteTests additions)
- [ ] Baseline direct-call and YouTube veto fixtures pass unchanged
- [ ] F-6 trade-off recorded at the documenting fixture
- [ ] `ios/build.sh` passes for the touched targets
