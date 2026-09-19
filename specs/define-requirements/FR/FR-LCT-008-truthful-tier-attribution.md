# FR-LCT-008: Truthful tier attribution and no success without translation

## Metadata
- **Area:** Translation
- **Priority:** MUST
- **Source:** Feature constitution "v1 non-goals" (deferred work must be absent, not a silent stub); Design §4.4, §11 (D2).
  **Amended 2026-09-17** by owner directive (see "Amendment" below): the deferred-tier clause is
  superseded by the on-device brain tier.
  **Amended 2026-09-20** by owner-approved reliability routing (see "Amendment" below): the tier
  order above is narrowed **by string class** — the device leads for the short forms the gate data
  shows it is exact on, the cloud leads for the sentence class when it can lead, and anything the
  cloud does not answer falls back to the device.

## Description
Every translated string **must** carry the tier that actually produced it
(`TranslationResult.sourceTier`), and a tier **must not** return success when it did not translate.

- The tiers that may produce a translation, in the order the pipeline consults them, are
  **tier 0 (dictionary)**, **tier 1 (on-device brain, no egress)** and **tier 2 (cloud,
  consent-gated)**. A string is asked of the next tier only when the tier before it did not
  answer it, and a result is always attributed to the tier that produced it — never to a tier
  that did not run.
- The **on-device brain tier is the app's own installed Nepali language model**, running entirely
  on the device. It is "tier 1 in spirit": a device-local translation stage between the curated
  dictionary and the consent-gated cloud. It is not a dedicated NMT model, and it is not a stub,
  a passthrough or a "translate later" placeholder: it either produces a translation from a model
  that is installed, or it reports an honest reason and the string continues down the cascade.
- **It requires no consent and no network.** Nothing about this tier leaves the device, so
  Open Decision 13 (consent/disclosure) is untouched by it, and the consent prompt still appears
  at the point of first **cloud** need — not over a scene the device could answer by itself.
- A tier that cannot be used **must not** hold the cycle open or answer silently: an unavailable
  model, a failed load, a failed generation and a generation that outlives its configured deadline
  are each recorded with a closed-vocabulary reason, and the unresolved strings fall through to
  the next tier.
- When no tier produced a translation, the result **must** report the failure honestly:
  `isFinal = true`, `degraded = true`, and the text shown is the original recognized text — never a
  fabricated or unmarked string.

## Acceptance criteria

```gherkin
Feature: Truthful tier attribution

  Scenario: A dictionary hit is attributed to tier 0
    Given a recognized label matches the curated dictionary
    When the translation resolves
    Then sourceTier reports dictionary
    And isFinal is true and degraded is false

  Scenario: An on-device brain translation is attributed to tier 1
    Given a recognized string is unresolved by the dictionary and a brain model is installed
    When the on-device brain returns a translation
    Then sourceTier reports the on-device brain tier
    And the cloud tier is never asked
    And no consent is required and no network request is made

  Scenario: A cloud translation is attributed to tier 2
    Given a recognized string is unresolved by the dictionary and the brain
    And consent is recorded
    When the cloud tier returns a translation
    Then sourceTier reports cloud
    And degraded is false

  Scenario: No tier can translate
    Given the dictionary cannot resolve the string, the brain cannot be used, and the cloud tier is unavailable
    When the resolution completes
    Then sourceTier does not claim a tier that did not translate
    And degraded is true
    And the text shown is the original recognized text

  Scenario: An unavailable brain is reported rather than stubbed
    Given the on-device brain tier cannot run (no model installed, no runtime, or a failed attempt)
    When the resolution completes
    Then the reason is recorded with a closed-vocabulary outcome
    And the string is left unresolved for the next tier rather than answered with a fabricated, empty or echoed string

  Scenario: The sentence class leads with the cloud when the cloud can lead
    Given a recognized sentence-class string is unresolved by the dictionary
    And the household's cloud switch is on and a network path exists
    And the cloud tier is consent-gated and consent is recorded
    When the cloud returns a translation
    Then sourceTier reports cloud
    And the device brain tier was not asked for this string

  Scenario: A string the cloud cannot answer falls back to the device
    Given a recognized sentence-class string led with the cloud
    And the cloud produced no translation for it
    When the resolution completes
    Then the string is translated on the device rather than degraded
    And sourceTier reports the on-device brain tier
```

## Amendment
**2026-09-17, owner directive (supersedes the deferred-tier clause of Design §11 D2 for v1).**
The original text required the on-device tier to be *absent* from v1 — not a stub, not a
placeholder. The owner's directive re-opens that non-goal and lands the tier as **tier 1 (the
on-device brain)**, because the shipped cascade (dictionary → consent-gated cloud) degrades every
string the ~120-label dictionary misses to "can't translate" the moment the elder is offline or
has declined the cloud — and the model that fixes that is already installed on the device.

What the original requirement existed to protect is unchanged and is what the amended acceptance
criteria still pin: **no success without translation**, and **no result attributed to a tier that
did not translate it**. The prohibition was never on the tier existing; it was on the tier lying.
The narrow "must be absent" clause is what this amendment retires.

**2026-09-20, owner-approved reliability routing (narrows the order in the description by string
class).** The order in the description — tier 1 then tier 2, for every string — is the order the
pipeline runs for the class the round-1/2/3 gate data shows the device model is **exact** on:
short labels, menu items and pharmaceutical names (at most four words, at most forty characters,
no clause punctuation). For the **sentence class** — instructions, sentences, anything longer —
the same gate data does not show that, and the owner approved leading with the cloud for that
class **when and only when the cloud can lead**: the household's switch on and a live network
path. Whatever the cloud does not answer for those strings comes back to the device, so the
routing trades a *tier order* for reliability and never trades a translation away.

What this narrowing keeps is the whole of what the requirement protects: **no success without
translation** (a string the cloud fails is translated on the device rather than degraded) and **no
result attributed to a tier that did not translate it** (the router decides only the *order*; the
tier that answers is always the tier named). The cloud stays consent-gated at the point of need
(FR-LCT-011, FR-LCT-020), and a string the device answers still costs no request and no egress.

The rule lives in one place, `TranslationReliabilityRouter`, and it is keyed on **measured
reliability** — the class the gate data separates — deliberately not on negation, keywords or any
other shape a translator could game.

## Related
- NFR: NFR-LCT-010 (offline degradation integrity)
- Depends on: FR-LCT-007 (tier 0), FR-LCT-009 (tier 2), FR-LCT-020 (consent at the point of cloud need)
