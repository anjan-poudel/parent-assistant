# FR-FCU-014: An ambiguous nickname never silently dials the wrong person

## Metadata
- **Area:** Nicknames / Ambiguity Safety
- **Priority:** MUST
- **Source:** Feature constitution Nickname & Variation Contract binding property 6 ("Ambiguity is conservative and deterministic: a nickname matching several contacts resolves like `ContactResolver`'s existing rivals rule — the system disambiguates; it never guesses. **Core guarantee: resolution must never silently dial the wrong person**"); Safety & Compliance Delta (Voice-resolution correctness; workflow `security-design-review` focus "an ambiguous match must never silently pick the wrong person for an elderly user"); DV-2 ("an ambiguous nickname never silently dials a wrong person (disambiguation, not a guess)"). Integration surface: `ContactResolver` rivals rule (accept :61, margin :62; `.ambiguous([FamilyContact])` outcome; `nearMiss` discipline).

## Description
When a nickname/variation matches several contacts, resolution **must** be conservative and deterministic, mirroring `ContactResolver`'s existing rivals rule:

- Two or more plausible matches within the ambiguity margin → **ambiguous**: the system disambiguates (the existing candidate/disambiguation flow) — it **never guesses**.
- **Core guarantee: resolution must never silently dial the wrong person.** No dial occurs until the person is resolved unambiguously or explicitly confirmed by the user.
- **Deterministic**: identical inputs produce identical outcomes and ordering across runs — stable ordering, no random tie-breaks, no fuzzy guessing.
- A nickname hit competing with an exact stored-name hit follows the scoring bands: the exact name wins, the nickname contact is not dialed off that utterance alone (FR-FCU-013's no-upgrade rule).
- The phone-search surface shows ALL matching rows — a list is legitimate and is not a dial decision; the guarantee binds the resolution/dial decisions (voice path and any single-target action).
- Ambiguity is not over-triggered: a nickname matching exactly one contact resolves directly.

## Acceptance criteria

```gherkin
Feature: Ambiguity safety for nicknames

  Scenario: An ambiguous nickname asks instead of dialing
    Given the nickname "sanu" matches two contacts within the ambiguity margin
    When the user says "call sanu"
    Then the system reports ambiguity and asks which person
    And no call is placed until the choice is resolved
    And the finally chosen person is the one dialed

  Scenario: Exact name beats a competing nickname (no wrong dial)
    Given the spoken query exactly equals contact A's stored name
    And the same query matches contact B only by nickname
    When resolution runs
    Then contact A is resolved
    And contact B is not dialed off that utterance

  Scenario: Resolution is deterministic across runs
    Given the same contact set and the same ambiguous nickname
    When resolution is run repeatedly
    Then the outcome and candidate ordering are identical every time
    And no flaky or random selection occurs

  Scenario: A unique nickname resolves without false disambiguation
    Given a nickname recorded for exactly one contact
    When the user says that nickname
    Then that contact resolves directly
    And no unnecessary disambiguation is triggered
```

## Related
- FR: FR-FCU-013 (voice matching discipline), FR-FCU-004 (one person in voice), FR-FCU-011 (nickname storage)
- NFR: NFR-FCU-005 (voice-path accessibility), NFR-FCU-009 (security-test evidence for the no-wrong-dial guarantee)
