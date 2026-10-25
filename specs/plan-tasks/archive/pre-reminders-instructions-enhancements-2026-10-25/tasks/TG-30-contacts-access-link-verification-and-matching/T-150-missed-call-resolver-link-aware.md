# T-150: MissedCallContactResolver link-aware resolution

## Metadata
- **Group:** [TG-30 — Contacts Access, Link Verification and Matching](index.md)
- **Component:** MissedCallContactResolver (call surfaces)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-148 ([T-148](T-148-contacts-access-limited-gate.md)), T-149 ([T-149](T-149-system-contact-link-service.md))
- **Blocks:** [T-163](../TG-33-acceptance-evidence-and-device-validation/T-163-acceptance-and-release-gates.md)
- **Requirements:** [FR-FCU-004](../../../define-requirements/FR/FR-FCU-004-one-person-every-surface.md), [FR-FCU-006](../../../define-requirements/FR/FR-FCU-006-stale-link-degradation.md)

## Description
Make missed-call name resolution link-aware: a number that matches a verified system-contact link resolves to the linked family contact first, before the existing unlinked resolution path, so the missed-call and dial-back surfaces show one person consistently (FR-FCU-004). Unlinked numbers behave exactly as before.

## Acceptance criteria

```gherkin
Feature: Link-aware missed-call name resolution

  Scenario: Linked number resolves to the family contact
    Given a verified link between system number "9841..." and family contact "Aama"
    When the resolver resolves a missed call from "9841..."
    Then it returns the family contact "Aama"
    And the dial-back surface shows the same single identity

  Scenario: Unlinked numbers are unchanged
    Given a number with no family link
    When the resolver resolves it
    Then the result is identical to the pre-feature behaviour (parity, no regression)

  Scenario: Stale link degrades to the unlinked path
    Given a stored link that the verification snapshot no longer contains (stale)
    When the resolver resolves the number
    Then it falls back to normal unlinked resolution (system/missed-call name)
    And it never shows the wrong family contact
```

## Acceptance criteria — failure paths

```gherkin
Feature: Resolution failure handling

  Scenario: Resolution runs while access is denied
    Given contacts authorization is denied
    When a missed call arrives
    Then resolution returns no family match without crash (honest empty result)

  Scenario: Two family contacts claim the same number after unlink/re-link churn
    Given the snapshot contains one verified claimant for the number
    When resolution runs during a drain (snapshot swap)
    Then it uses a single consistent snapshot per resolution (no torn read across two snapshots)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/Services/Contacts/MissedCallContactResolver.swift`; suites: `ios/ElderlyAssistantTests/Services/Contacts/MissedCallContactResolverTests.swift` plus the existing `ios/ElderlyAssistantTests/App/MissedCallDialBackTests.swift`.
- Order of precedence: verified linked family contact → existing unlinked resolution. Document the precedence in the resolver.
- Read the snapshot from T-149 (`VerifiedLinksSnapshot`); do not query the address book directly here.
- Safety-adjacent call path: verify the resolver holds no new dependency on the LLM/brain path and still works if the brain process crashes (dial-back naming is deterministic and local).
- Unit gate (focused): `MissedCallContactResolverTests` + `MissedCallDialBackTests` + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `MissedCallContactResolverTests` + `MissedCallDialBackTests` + typecheck
- [ ] Unlinked parity verified (no regression in pre-feature cases)
- [ ] Verified LLM/brain process crash does not affect this path (resolver is local and deterministic)
- [ ] No PII in logs
