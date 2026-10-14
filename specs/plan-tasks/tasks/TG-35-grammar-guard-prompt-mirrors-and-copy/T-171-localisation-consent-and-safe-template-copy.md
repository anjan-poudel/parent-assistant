# T-171 — Localisation: consent, disclosure, indicator, revocation and safe-template copy

## Metadata
- **Group:** [TG-35 — Grammar Guard, Prompt Mirrors and Localised Copy](index.md)
- **Component:** Catalogue and copy (design-l1 section 17)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** MEDIUM
- **Depends on**: T-166 ([T-166](../TG-34-style-spec-chat-decode-and-persona-seams/T-166-nepali-chat-style-spec-and-loader.md))
- **Blocks:** T-174 ([T-174](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-174-guard-flag-resolution-at-the-dispatch-seam.md)), T-176 ([T-176](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-176-consent-prompt-and-disclosure.md)), T-177 ([T-177](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-177-indicator-revocation-and-coordinator-wiring.md))
- **Requirements:** [FR-CNR-006](../../../define-requirements/FR/FR-CNR-006-guard-flag-escalation-honest-degradation.md), [FR-CNR-009](../../../define-requirements/FR/FR-CNR-009-cloud-chat-consent-disclosure-indicator.md), [NFR-CNR-009](../../../define-requirements/NFR/NFR-CNR-009-accessibility.md), [NFR-CNR-010](../../../define-requirements/NFR/NFR-CNR-010-localisation-ne-en.md)

## Description
Author and catalogue every user-visible string the feature introduces — the cloud chat consent question and its answers, the plain-language disclosure, the cloud-activity indicator label, the revocation confirmation and the voice state answer, and the bounded set of guard safe templates — in Nepali and English, with the catalogue coverage suite extended so an untranslated or internal-sounding string cannot ship. The copy is written from the style spec's register, in words an elderly speaker hears as a person talking, never as a system.

## Acceptance criteria

```gherkin
Feature: Bilingual, plain-language copy for the new surfaces

  Scenario: Every new key resolves in both languages
    Given the catalogue entries for the feature's key families (consent question and answers, disclosure, indicator, revocation confirmation and state answer, guard safe templates)
    When the coverage suite resolves each key in Nepali and English
    Then every key resolves in both languages with equal format-slot counts
    And the suite's existing families remain untouched and green

  Scenario: Safe templates are a bounded, spec-authored set
    Given the guard's safe-template keys
    When each template is compared with the spec's register section
    Then each is a short warm sentence from the spec register, none is an apology boilerplate or a list
    And the set is enumerable (a bounded set, not free-form text generated at runtime)

  Scenario: The copy speaks to a person
    Given the consent question, disclosure and indicator labels
    When a reviewer reads them (and the accessibility check runs)
    Then none names a model, a provider, a route or a setting category as a technical term
    And each fits the accessibility bar (plain language, short sentences, readable at the large-type setting)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Copy failure behaviour

  Scenario: A missing translation
    Given a key added with Nepali only
    When the coverage suite runs
    Then it fails naming the key and the missing language
    And the feature cannot claim its localisation criterion with the gap present

  Scenario: A hardcoded user-visible string
    Given a user-visible string authored in code instead of the catalogue
    When the coverage sweep inspects the new surfaces
    Then it reports the string and its location
    And the fix is to add it to the catalogue in both languages — never to leave it in code
```

## Inputs and expected result

**Input:** the style spec's register and forbidden-AI-ism sections (T-166); the key families recorded in design-l1 section 17; the shipped catalogue conventions (family ordering, alphabetical adjacency, format-slot parity) and the existing coverage suite.

**Output:** the new catalogue entries in both languages, the extended coverage suite for the feature's families, and the final copy for every surface T-174, T-176 and T-177 speak.

**Declared files:** `ios/ElderlyAssistant/Resources/Localizable.xcstrings`, `ios/ElderlyAssistant/App/L10n.swift`, `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift`

## Implementation notes
- The final wording is authored at implementation time (the design defers final en/ne copy); the keys' purposes are fixed by the design's section 17 key set, and the surfaces that speak them are T-174 (safe templates), T-176 (consent question, answers, disclosure) and T-177 (indicator label, revocation confirmation, state answers).
- Nepali register: respectful forms (हजुर, भन्नुभयो, गर्नुभयो), one idea per sentence, no abbreviations, numbers and units as spoken words; no English technical nouns except where the spec's noun section allows the code-switched health/tech terms an elderly speaker already uses.
- Consent copy must be comprehensible without any technical framing: what will be sent, who answers when it is sent, that they can say no, and that saying no keeps the assistant working (locally). No "server", "cloud", "API", "model" as bare technical terms in the Nepali text — the design's confidentiality/plainness bar.
- Safe templates: keep the set small (a handful), each a warm short sentence inviting another try; they are the honest fallback when a flagged reply cannot be escalated. No emoji, no list formatting, no "sorry, I am an AI".
- Format-slot parity: any template with a substitution slot (for example a name) must have equal slot counts in both languages, enforced by the suite.
- The catalogue is shared with other features' families: add entries contiguously and alphabetically per house convention; do not reorder or rewrite existing families (their baselines stay green).

## Definition of done
- [ ] All feature key families present in Nepali and English with equal format-slot counts
- [ ] Coverage suite extended for the feature's families; existing families untouched and green
- [ ] Safe-template set bounded, spec-register authored, enumerable, and no answer boilerplate
- [ ] Consent/disclosure/indicator copy free of technical framing; accessibility-reviewed at large type
- [ ] No user-visible string left hardcoded in code on the new surfaces
- [ ] Scoped unit suite green
