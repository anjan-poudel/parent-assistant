# T-173 — CloudChatRouting: the single fail-closed routing decision

## Metadata
- **Group:** [TG-36 — Cloud Chat Consent, Routing and Elder Surfaces](index.md)
- **Component:** Routing decision chokepoint (design-l1 section 8.1)
- **Agent:** dev
- **Effort:** S (about 1 day)
- **Risk:** HIGH
- **Depends on**: T-172 ([T-172](T-172-cloud-chat-consent-gate.md))
- **Blocks:** T-174 ([T-174](T-174-guard-flag-resolution-at-the-dispatch-seam.md)), T-175 ([T-175](T-175-router-cloud-first-chat-lane.md))
- **Requirements:** [FR-CNR-008](../../../define-requirements/FR/FR-CNR-008-cloud-first-chat-routing-toggle.md), [FR-CNR-009](../../../define-requirements/FR/FR-CNR-009-cloud-chat-consent-disclosure-indicator.md), [FR-CNR-010](../../../define-requirements/FR/FR-CNR-010-cloud-chat-egress-scope.md), [NFR-CNR-002](../../../define-requirements/NFR/NFR-CNR-002-listening-turn-latency-envelope.md)

## Description
Build the one pure function that decides whether a chat turn may leave the device: consent granted AND online AND key configured AND cost allowed, or a classified local reason — nothing else can produce egress. It is the only place the feature decides to send, which is what makes "enforced at the routing decision, not merely in the UI" a structural property: the routing lane and the guard escalation both ask this function, and the consent gate is read per turn through injected closures.

## Acceptance criteria

```gherkin
Feature: Fail-closed cloud chat routing

  Scenario: The single yes
    Given consent granted, online, key configured and cost allowed
    When the decision runs
    Then it returns cloud

  Scenario: Every other combination is local with its own reason
    Given the sixteen cells of consent x online x key x cost
    When the decision runs for each
    Then exactly one cell returns cloud and the other fifteen return local with a reason that names the first blocking input (consent state, offline, key missing, cost blocked)

  Scenario: The reason names the consent state truthfully
    Given a notRecorded, denied or unreadable consent decision
    When the decision runs
    Then the reason distinguishes the three consent states (they are read by a human later to know why the cloud was not used)

  Scenario: The decision reads state per turn
    Given a granted, online, keyed, cost-allowed device
    When consent is revoked and the decision runs again
    Then it returns local with the revocation reason — there is no cached route
```

## Acceptance criteria — failure paths

```gherkin
Feature: Routing failure behaviour

  Scenario: An unknown or missing input fails closed
    Given a closure that is absent, returns no value, or throws
    When the decision runs
    Then the result is local (the absent value reads as not-granted / not-allowed), never cloud
    And no code path turns an unknown input into egress

  Scenario: A non-granted state reaching cloud is a defect
    Given any decision where consent is not granted
    When the route is evaluated
    Then the route is local; a build in which any non-granted state yields cloud fails this unit's test and does not ship
```

## Inputs and expected result

**Input:** the consent decision type from T-172; the existing router readiness inputs (the key-configured and cost-allowed closures the router already holds); the existing reachability discipline the LiveTranslate indicator uses (injected as a closure so tests can drive it).

**Output:** the pure routing type with its route and reason enums and the sixteen-cell decision, plus exhaustive tests including the fail-closed unknown-input behaviour.

**Declared files:** `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatRouting.swift`, `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatRoutingTests.swift`

## Implementation notes
- Shape (design section 8.1): `ChatRoute { cloud, local(reason: LocalReason) }` with `LocalReason { consentNotRecorded, consentDenied, consentRevoked, consentUnreadable, offline, keyMissing, costBlocked }`; the decision takes the consent decision plus online / keyConfigured / costAllows. Pure static function, no I/O, deterministic — the exhaustiveness of its test is the safety argument.
- Absent closures read as not-granted: every pre-feature construction site and test must keep compiling and must select local honestly, with no behavioural surprise at call sites that never opted in to chat egress.
- Reason classification is for humans and for the fallback telemetry (classification only); it never carries content.
- Keep the type free of UI concerns: the indicator, the prompt and the revocation surfaces all consume it, but it knows nothing about them.

## Definition of done
- [ ] Route and reason types present; the decision is pure and deterministic
- [ ] All sixteen cells unit-tested; exactly one returns cloud
- [ ] Unknown/absent inputs fail closed (tested)
- [ ] Per-turn read: a revocation between two decisions changes the second result (tested)
- [ ] No content or identity in the reason values; no logging of transcript or reply
- [ ] Scoped unit suite green
