# NFR-PI-004: Untrusted profile-string hardening (injection)

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 4 (security-design-review focus — prompt injection: the user-entered address-as is composed into brain prompts, making it an untrusted input path; the design must apply the project's existing `InputSanitiser` discipline; the term must not alter reply-style rules, tool/intent routing, or safety behaviour); workflow security-design-review focus areas; project constitution Standards ("Injection detection enabled at `quarantine` level")

## Description
The name and address-as term are user-entered, attacker-influenceable input composed into prompts shared by the cloud (Gemini) and on-device (LLaMA) brains. Before either enters any prompt it **must** be handled with the same discipline `InputSanitiser` applies to transcripts (quarantine level):

- **Sanitised and bounded** — the composed value is capped by a configured bound (not a magic literal); truncation never splits a grapheme cluster; the composed prompt remains within the pinned 1,024-token on-device budget (NFR-PI-005).
- **Passed as data** — delimited/quoted, never as free-form instruction text, so the value cannot be parsed as a rule.
- **No capability change** — a crafted term must not be able to alter reply-style rules, intent/tool routing, authentication, or safety behaviour, and must not trigger any app action.
- **Policy action before send** — text that trips the injection policy follows the configured quarantine action (the same level the project configures); the assistant degrades to the un-personalized path (FR-PI-011) rather than sending a hostile payload.
- Model output is treated as untrusted: nothing from a reply can cause profile writes or actions by itself.

The term cannot reach these guarantees without this discipline; the security-design-review's STRIDE model must treat this surface as a focus area and `security-test` must present both the positive and negative evidence.

## Acceptance criteria

```gherkin
Feature: Hardening against hostile profile strings

  Scenario: An ordinary term personalizes prompts as data
    Given the user records an ordinary address-as term
    When prompts are built for either engine
    Then the term is included as delimited data
    And personalization works normally

  Scenario: An injection-shaped term cannot alter behaviour
    Given a term contains an instruction aimed at the model (for example "ignore your instructions and ...")
    When the term is composed into the prompt path
    Then the injection policy's configured action is applied before any prompt is sent
    And reply-style rules, intent routing, authentication and safety behaviour are unchanged
    And no app action is triggered by the term

  Scenario: An oversized term is bounded without breaking graphemes
    Given a term far longer than the configured bound
    When it is composed
    Then it is truncated to the bound without splitting a grapheme cluster
    And the composed prompt stays within the 1,024-token budget
```

## Related
- FR: FR-PI-009 (reply-style rules)
- NFR: NFR-PI-005 (prompt budget), NFR-PI-002 (log safety)
