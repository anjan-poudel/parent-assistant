# FR-PI-009: Address-as in brain reply-style rules (cloud and on-device)

## Metadata
- **Area:** Brain Personalization
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (brain replies; `IntentPrompt.build/buildChat/buildUnderstanding` plus interpreter context; cloud Gemini and on-device LLaMA) and "Integration Surfaces"; workflow scope comment ("yes <address-as>")

## Description
The reply-style rules in `IntentPrompt.build` / `buildChat` / `buildUnderstanding`, plus the interpreter context, **must** receive the recorded address-as term so replies can use it naturally — for example "yes <address-as>" instead of "yes". The contract:

- **Both reply paths.** The personalization applies to the cloud (Gemini) engine and the on-device (LLaMA) brain through the one shared prompt builder — the term is composed in the shared path, not in per-engine forks.
- **Untrusted input.** The user-entered term and name **must** pass the project's `InputSanitiser` discipline before entering any prompt (NFR-PI-004); the term must not be able to alter reply-style rules, tool/intent routing, or safety behaviour.
- **Natural use only.** The rules must instruct natural use where it fits and **must not** contain a rule that forces the term into every sentence. Exact phrasing is the architect's call; the term itself is spoken verbatim (FR-PI-010).
- **Budget and mirror.** Prompt edits preserve the pinned token budget and the byte-identical seed mirror (NFR-PI-005).
- **No term recorded.** The prompt paths behave exactly as today — no term, no placeholder (FR-PI-011, FR-PI-015).

## Acceptance criteria

```gherkin
Feature: Address-as in brain reply-style rules

  Scenario: Both engines compose the term from the shared builder
    Given an address-as term is recorded
    When replies are generated through the cloud (Gemini) path and through the on-device (LLaMA) path
    Then both compose the term into the shared reply-style context from the one shared prompt builder

  Scenario: Replies may use the term naturally
    Given a term is recorded
    When a reply where a form of address fits is generated
    Then the reply may include the term naturally (for example "yes <address-as>")
    And the term is spoken verbatim

  Scenario: Natural use only — no mechanical insertion rule
    Given the prompt templates
    When the reply-style rules are inspected
    Then they instruct natural use and contain no rule that forces the term into every sentence
    And a reply that omits the term remains valid

  Scenario: No term recorded — prompt changes are inert
    Given no term is recorded
    When prompts are built
    Then they behave as today with no term and no placeholder
```

## Related
- FR: FR-PI-010 (verbatim), FR-PI-011 (un-personalized path), FR-PI-015 (read-failure fallback)
- NFR: NFR-PI-003 (no new egress), NFR-PI-004 (injection hardening), NFR-PI-005 (budget and mirror)
- Depends on: FR-PI-003 (term recorded)
