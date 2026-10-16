# FR-CNR-001: Nepali conversation style spec — one source of truth for the conversational register

## Metadata
- **Area:** Style Spec / Single Source
- **Priority:** MUST
- **Source:** Owner-approved proposal §2 "The Nepali conversation pattern spec (the centerpiece)" (approved 2026-10-14: "please implement this as ai-sdd feature spec"); feature constitution "Nepali Conversation Style-Spec Contract" binding properties 1–8 and Feature Purpose & Scope ("a **Nepali conversation style spec** (one source of truth)"); workflow `define-requirements` scope comment ("persona upgrade … from a single Nepali conversation style spec (register/honorifics, particles budget, small-talk repertoire, code-switched health/tech nouns, forbidden AI-isms)"). Surfaces: `tools/train-intent/seeds/` (new artifact `nepali-chat-style-spec`), consumed by `LlamaCommandInterpreter.chatSystemPrompt` (:552-563), `GeminiCommandInterpreter.replyPersona` (:35-44), the data-generation/teacher prompts, the eval rubric and the grammar guard.

## Description
The feature **must** define the Nepali conversational register in exactly one artifact — `tools/train-intent/seeds/nepali-chat-style-spec` — and every consumer **must** resolve against it. The artifact format (prose spec vs. machine-readable rules, and which parts the guard/eval execute directly) is design-level (feature constitution OD-2); the artifact's byte-pinned discipline mirrors `seeds/prompt_template.txt`. Binding properties:

- **Single source, four consumers, no forks.** The spec is consumed by (a) the personas (`chatSystemPrompt`, `replyPersona`), (b) the data-generation/teacher prompts of all four data layers, (c) the eval rubric (the chat gates), and (d) the grammar guard. No consumer restates or re-authors a rule; a rule changes in the spec first and in its consumers second. A divergence between a consumer and the spec is a defect of the consumer, never a second authoritative definition.
- **Register.** तपाईं + honorific verb agreement always (भन्नुभयो, खानुभयो, गर्नुहुन्छ); हजुर as the polite attention marker; never तिमी toward the elder.
- **Particles — budget ≤1 per reply** (the strongest "human" marker). The draw comes from है (gentle tag), नि (emphasis), ल/ला (softening), अनि (continuation), हुन्छ नि. Overuse is a failure, not a style.
- **Sentence shape.** SOV; one idea per sentence; ≤2 sentences (the existing persona rule; the polisher's brevity ceiling remains the downstream backstop); question-tags for check-ins ("औषधि खानुभयो नि?").
- **Small-talk repertoire.** हालखबर, खाना, निद्रा, छोराछोरी, मौसम, सम्झना/reminiscence — wellness-oriented, elder-family register.
- **Code-switching.** Health/tech nouns stay English as actually spoken (प्रेसर, डाक्टर, मेडिसिन, फोन, चार्जर); the reply mirrors the user's own register.
- **Forbidden AI-isms.** No lists/markdown; no "म एक AI हुँ"; no canned service phrases ("कृपया नम्र निवेदन…"); no translation-ese ("यो प्रश्नको उत्तर…"); no over-politeness stacking.
- **Binding on gates.** The honorific-agreement and no-AI-ism eval gates and the grammar guard's checks are *implementations* of this spec: a gate failure is a spec violation, and the spec — not a gate-local heuristic — is the authority.

The document itself is written in English with Nepali strings quoted as normative examples (project Docs-in-English convention).

## Acceptance criteria

```gherkin
Feature: The Nepali conversation style spec is the single source of truth

  Scenario: Every consumer resolves to the one artifact
    Given the shipped feature
    When the personas, the data-generation prompts, the eval rubric and the grammar guard are inspected
    Then each derives its rules from tools/train-intent/seeds/nepali-chat-style-spec
    And no consumer carries an independently authored copy of the rules

  Scenario: The spec covers each named pattern class
    Given the style spec artifact
    When it is reviewed against the proposal's pattern table
    Then it states the register rule (तपाईं + honorific agreement, हजुर; never तिमी)
    And the particles budget (≤1 per reply, from the named set)
    And the sentence shape (SOV, ≤2 sentences, check-in question tags)
    And the small-talk repertoire
    And the code-switching rule for health/tech nouns
    And the forbidden AI-isms list

  Scenario: A consumer drifts from the spec (failure)
    Given a consumer whose rules disagree with the spec
    When the set is reviewed
    Then the disagreement is reported as a consumer defect
    And the change is rejected until the spec is updated first
```

## Related
- FR: FR-CNR-002 (personas implement it), FR-CNR-005 (the guard's checks), FR-CNR-017 (data-generation prompts), FR-CNR-020 (eval gates)
- NFR: NFR-CNR-005 (prompt-template byte-mirror discipline)
