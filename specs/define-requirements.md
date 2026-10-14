# Requirements — Conversational Nepali Replies (feature)

**Project:** Elderly AI Assistant · **Feature:** `conversational-nepali-replies` (v1) ·
**Branch:** `feat/conversational-nepali-replies` (worktree
`elderly-ai-assistant-conversational-nepali-replies`; scaffold base master `91deddca`)
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-10-14 · **Status:** **HIL gate RESOLVED** (risk tier T1, per the feature workflow's
`define-requirements` task): the owner approved the feature story on 2026-10-14 ("please implement
this as ai-sdd feature spec"), so the `define-requirements` owner-story HIL is resolved by that
approval rather than re-asked at this step; the artifact is submitted for the coordinator's
completion. The T2 human gate sits at `final-sign-off`. The locked snapshot is the drift-detection
baseline.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file per
requirement, with index files at each level. Both are generated from the same content; the
per-requirement files are the unit of change, this document plus the lock file are the snapshot
downstream tasks (`design-l1`, `design-l2`, `review-l2`, `security-design-review`, `plan-tasks`,
`implement`, `review-implementation`, `security-test`, `final-sign-off`) consume.

**ID convention.** Requirement IDs are namespaced `FR-CNR-NNN` / `NFR-CNR-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`),
spotify-music-integration used (`FR-SP-NNN`), multi-turn-conversation used (`FR-MTC-NNN`),
family-contacts-unify used (`FR-FCU-NNN`) and call-dialer-primary-secondary used (`FR-CDP-NNN`).
One file per requirement; every requirement carries at least one Gherkin scenario, and every
safety-relevant requirement carries a failure scenario.

**Stakeholder brief.** The stakeholder input is the owner-approved proposal
`docs/features/2026-10-14-conversational-nepali-replies-proposal.md` (approved 2026-10-14), which
fixes scope — the owner's complaint ("the current conversation is too robotic and AI like and
sometimes incorrect grammatically"), the four diagnosed root causes, the Nepali conversation
pattern spec, the four-layer data plan, the P0/P1/P2 phases, the gate thresholds and the risks.
The project-root `requirements.md` is a read-only input, not modified by this feature and not
addressed beyond its standing constraints.

**Scope summary.** 29 functional requirements (`FR-CNR-001` … `FR-CNR-029`; 25 MUST, 1 SHOULD,
3 COULD) and 11 non-functional requirements (`NFR-CNR-001` … `NFR-CNR-011`, all MUST). The fix has
three legs, and the requirement set follows them: **a style spec** as the single source of truth
(FR-CNR-001, binding on the personas, the data-generation prompts, the eval rubric and the grammar
guard); **data** built from public conversation samples shaped by that spec (FR-CNR-016 … FR-CNR-019,
with ship-mix licence hygiene as FR-CNR-018); and **runtime changes** — the persona upgrade, the
chat-only fixed-seed decode, the deterministic verify-never-rewrite grammar guard, and cloud-first
chat routing with a never-failing local floor (FR-CNR-002 … FR-CNR-012). Around them sit the
guardrails that make the change safe: the single-decode schema, the router/emergency path, the STT
pipeline, command determinism and the device permission set all stay untouched
(FR-CNR-013/014/015); the full existing gate suite plus three new chat gates gate the catalog swap
(FR-CNR-020/021/022); prompt discipline is byte-locked (FR-CNR-023); infeasibility is reported
rather than absorbed (FR-CNR-024); and completion is the recorded DV-1 … DV-6 protocol on Anzaan
with the release log-safety gate green (FR-CNR-025).

## Summary

- Functional requirements: **29** (`FR-CNR-001` … `FR-CNR-029`), priority breakdown 25 MUST /
  1 SHOULD (`FR-CNR-026`) / 3 COULD (`FR-CNR-027`, `FR-CNR-028`, `FR-CNR-029`).
  - **P0 — runtime, no training (~1 week; lands first):** FR-CNR-001 … FR-CNR-012, plus the shared
    guardrails FR-CNR-013/014/015/023/024/025.
  - **P1 — corpus + chat-aware v17 fine-tune (~2–4 weeks):** FR-CNR-016 … FR-CNR-022.
  - **P2 — polish (after P1):** FR-CNR-026 … FR-CNR-029.
- Non-functional requirements: **11** (`NFR-CNR-001` … `NFR-CNR-011`), all MUST.
- Areas covered: Style Spec / Single Source; Persona (local + cloud seams); Decode (chat sampling;
  the command determinism invariant); Grammar Guard (verification, degradation, telemetry); Cloud
  Chat (routing, consent & disclosure, egress scope, sampling config, hygiene); Single-Decode
  Integrity; Preserved Behaviours (safety path; STT / permissions / data collection); Training (v17
  suite extension, corpus construction, provenance); Evaluation (held-out set, chat gates, full
  regression harness, ship gate); Model Delivery (catalog swap, device tiers); Prompt Discipline;
  Feasibility Reporting; Completion Gate; and the P2 polish set. NFR categories: Reliability /
  Determinism, Performance, Reliability / Resource Behaviour, Performance / Resource Budget,
  Reliability / Build Discipline, Privacy / Security, Privacy, Quality / Evaluation Gates,
  Accessibility, Localisation, Compliance.
- Primary sources of truth: the owner-approved proposal (source mandate);
  `specs/conversational-nepali-replies/constitution.md` (feature supplement: Feature Purpose &
  Scope; Nepali Conversation Style-Spec Contract; Runtime Contract — chat decode, grammar guard,
  cloud-first chat routing toggle, persona seams and Gemini chat temperature; Model & Training
  Contract — single-decode integrity and catalog swap, mixture and gate harness, data provenance,
  prompt/seed discipline; Safety & Compliance Delta; Success Criteria & Completion Gate;
  Integration Surfaces; Open Decisions 1–5);
  `specs/conversational-nepali-replies/workflow.yaml` (scope comment, security focus areas,
  phasing); project `constitution.md` (inherited Architecture Constraints 1–6, Standards, release
  gates, Agent Principles); `specs/conversational-nepali-replies/init-report.md`.
- Completion gate: **DV-1 … DV-6** on the reference device Anzaan, recorded at final sign-off —
  local chat quality; cloud-first consent/indicator/toggle-off fallback; offline honest
  degradation; emergency phrasing recall on device; command determinism; elderly listening-panel
  A/B verdict (FR-CNR-025) — plus the release gate `ios/tools/check-release-log-safety.sh`
  exiting 0 over the new chat/routing/guard paths (FR-CNR-012, NFR-CNR-006).

## Contents

- [define-requirements/index.md](define-requirements/index.md) — top-level index of this set
- [define-requirements/FR/index.md](define-requirements/FR/index.md) — functional requirements
  (29 files, `FR-CNR-001` … `FR-CNR-029`)
- [define-requirements/NFR/index.md](define-requirements/NFR/index.md) — non-functional
  requirements (11 files, `NFR-CNR-001` … `NFR-CNR-011`)
- [define-requirements.lock.yaml](define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `define-requirements/FR/` and `define-requirements/NFR/` folders accumulate across
features. They still contain the earlier features' files (call-dialer-primary-secondary
`*-CDP-*`, family-contacts-unify `*-FCU-*`, live-camera-translation `*-LCT-*`,
multi-turn-conversation `*-MTC-*`, profile-interview `*-PI-*`, spotify-music-integration
`*-SP-*`), left in place untouched; neither this document nor the lock covers them.

---

## Functional requirements

### FR-CNR-001: Nepali conversation style spec — one source of truth for the conversational register

**Area:** Style Spec / Single Source · **Priority:** MUST
**Source:** Owner-approved proposal §2 "The Nepali conversation pattern spec (the centerpiece)" (approved 2026-10-14: "please implement this as ai-sdd feature spec"); feature constitution "Nepali Conversation Style-Spec Contract" binding properties 1–8 and Feature Purpose & Scope ("a **Nepali conversation style spec** (one source of truth)"); workflow `define-requirements` scope comment ("persona upgrade … from a single Nepali conversation style spec (register/honorifics, particles budget, small-talk repertoire, code-switched health/tech nouns, forbidden AI-isms)"). Surfaces: `tools/train-intent/seeds/` (new artifact `nepali-chat-style-spec`), consumed by `LlamaCommandInterpreter.chatSystemPrompt` (:552-563), `GeminiCommandInterpreter.replyPersona` (:35-44), the data-generation/teacher prompts, the eval rubric and the grammar guard.

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

### FR-CNR-002: Persona upgrade in both seams — same style contract, local and cloud

**Area:** Persona / Local + Cloud Seams · **Priority:** MUST
**Source:** Proposal §5.4 ("Persona upgrade: bake the style spec's concrete rules (particles budget, code-switch nouns, forbidden AI-isms) into `chatSystemPrompt` … and `replyPersona` — kept short for the token budget") and §2 ("Style is declared, never demonstrated": the persona says the register but the model has no data showing it); feature constitution "Persona seams and Gemini chat temperature" properties 1–3; workflow `define-requirements` scope comment. Surfaces: `LlamaCommandInterpreter.chatSystemPrompt` (:552-563); `GeminiCommandInterpreter.replyPersona` (:35-44); `IntentPrompt.buildChat` (:197-211) for the local template.

Both chat personas **must** be rewritten so their concrete rules are the style spec's rules (FR-CNR-001) — particles budget, code-switch nouns, forbidden AI-isms, register, sentence shape — and the two **must** carry the same contract so the local and cloud paths cannot drift apart. Binding properties:

- The persona text implements the spec's *concrete* rules; it does not describe the goal in the abstract ("warm grandchild" alone is exactly the failure this feature fixes).
- The persona stays **short** for the token budget (it shares the 1,024-token on-device ceiling, NFR-CNR-004) — the style is carried by the training data, not by prompt tokens.
- The personas are **declarative only**: no few-shot exemplar turns in the device prompt (style travels via data, not prompt tokens — a feature non-goal).
- The pinned intent prompt (`IntentPrompt.build` text, byte-mirrored by `seeds/prompt_template.txt` and pinned by `IntentPromptTests`) stays **byte-identical**; the chat template (`IntentPrompt.buildChat`) follows the seed-mirror rule of FR-CNR-023.
- A rule change reaches the personas via the spec (FR-CNR-001) — never by editing one persona in isolation.

```gherkin
Feature: Both chat personas implement the style spec and cannot drift

  Scenario: The local and cloud personas carry the same style contract
    Given the shipped feature
    When chatSystemPrompt and replyPersona are compared against the style spec
    Then each states the register, particles budget, code-switch and forbidden-AI-ism rules
    And no rule is present in one persona and absent from the other

  Scenario: The persona is declarative, not demonstrative
    Given the on-device chat prompt built by IntentPrompt.buildChat
    When it is inspected
    Then it contains no few-shot exemplar turns
    And the style rules are carried by the persona text plus the training corpus

  Scenario: The locked intent prompt is untouched
    Given the pinned intent prompt and its seed mirror
    When the feature's change set is inspected
    Then both are byte-identical to their pre-change content
    And IntentPromptTests' pin on the intent prompt still passes

  Scenario: A one-sided persona edit (failure)
    Given an edit that changes the style contract in one persona only
    When the change is reviewed
    Then it is rejected as drift between the local and cloud paths
    And the rule is corrected in the style spec first
```

### FR-CNR-003: Chat-turn sampling — fixed seed with temperature ~0.3, chat turns only

**Area:** Decode / Chat Sampling · **Priority:** MUST
**Source:** Proposal §5.1 ("keep temp 0 + fixed seed for commands (invariant), but for **chat turns** use fixed-seed temp ~0.3 — still fully reproducible (the gibberish bug was *random* seed), yet it escapes greedy's most-cliché tokens"); proposal §1 root cause 2 (greedy decoding picks the most cliché, assistant-like phrasing); feature constitution Runtime Contract "Chat decode (P0)" properties 2–4 and OD-1 (exact value + plumbing is design-l1's). Surfaces: `LlamaCommandInterpreter.OnDeviceSampling` (:404-417), handle creation (:1391-1398), `respondToChat` (:709), GBNF `chatJSONSchema` (:350).

Chat turns **must** be decoded with a fixed seed and temperature ~0.3 (exact value and the per-turn-override vs. shape-specific-handle plumbing is design-l1's, feature OD-1), while command turns keep the existing temp-0 invariants (FR-CNR-004). Binding properties:

- **Reproducible by construction**: same transcript and same assistant state → same reply. The gibberish defect was a *random* seed; a fixed seed at ~0.3 keeps the NO-GIBBERISH class closed.
- **Chat turns only**: the change is scoped to the chat decode path (`respondToChat` and the chat-capability route); no command, emergency or ladder decode is affected.
- **The GBNF `chatJSONSchema` constraint continues to apply** to the chat decode — one JSON object (`intent`/`reply`/`confidence`); a decode that cannot produce a readable object ABSTAINS (nil) rather than speaking malformed output (FR-CNR-013).
- **Feasibility honesty**: if fixed-seed temp ~0.3 does not hold reproducibly on any device tier (GBNF interplay, Metal backends), the limitation is recorded explicitly for the owner (FR-CNR-024) — never silently dropped, and the chat path never reverts to an unreproducible configuration.

```gherkin
Feature: Reproducible chat-turn decoding at a fixed seed and temperature ~0.3

  Scenario: A chat turn is reproducible
    Given the same transcript and the same assistant state
    When the same chat turn is decoded twice on the same device tier
    Then the two replies are identical

  Scenario: The chat change does not reach the command path
    Given a session that handles a chat turn and a command turn
    When the chat sampler is active
    Then the command turn is decoded under the unchanged temp-0 + fixed-seed + GBNF configuration

  Scenario: The chat decode still emits one readable JSON object
    Given a chat turn decoded at the chat sampling setting
    When the model output is parsed
    Then it is a single JSON object carrying intent, reply and confidence
    And an unreadable output abstains instead of being spoken

  Scenario: The setting does not reproduce on a device tier (failure)
    Given a device tier where fixed-seed temperature ~0.3 does not reproduce
    When the configuration is evaluated
    Then the limitation is recorded explicitly for the owner
    And no unreproducible chat sampling setting ships silently
```

### FR-CNR-004: Command-turn decode determinism preserved — temp-0 + fixed seed + GBNF untouched

**Area:** Decode / Determinism Invariant · **Priority:** MUST
**Source:** Feature constitution Runtime Contract "Chat decode (P0)" property 1 ("Commands keep the NO-GIBBERISH invariants, byte-for-byte … `OnDeviceSampling` and the handle creation are not moved by this feature. Command determinism is regression-visible as DV-5") and "Out of scope (must not change)" ("Command-turn decode determinism: temp-0 + fixed seed + GBNF `commandJSONSchema` are the NO-GIBBERISH invariants and stay untouched"); proposal §5.1 and §7 risks ("mitigated by keeping the temp-0/seed/GBNF discipline"). Surfaces: `LlamaCommandInterpreter.swift:404-417` (`OnDeviceSampling`, `fixedSeed` = 20_260_907), `:1391-1398` (handle creation), `commandJSONSchema`.

The command path's decode determinism **must** remain byte-for-byte as shipped: temperature 0 (`OnDeviceSampling`), the fixed seed (20_260_907), and the GBNF `commandJSONSchema` constraint. `OnDeviceSampling` and the LLM handle creation are not moved, reparameterised or bypassed by this feature, and the chat sampling change (FR-CNR-003) **must** not leak into any command, ladder, emergency or reminder turn. This is a safety-relevant invariant: a non-deterministic command turn is a heard-by-the-user defect on a path the elderly user depends on, and it is the regression the NO-GIBBERISH fix closed.

```gherkin
Feature: Command turns stay byte-for-byte deterministic

  Scenario: A command turn is unchanged across the feature
    Given the pre-change baseline behaviour of a command turn (e.g. a reminder or alarm request)
    When the feature's build handles the same turn
    Then the decoded result and its determinism properties are unchanged
    And repeated runs produce the identical result

  Scenario: A chat turn cannot alter command decoding
    Given a session in which a chat turn was decoded at the chat sampling setting
    When a command turn follows
    Then it is decoded under temp-0 + fixed seed + commandJSONSchema
    And no chat sampling parameter is observable on that path

  Scenario: A command turn differs from the baseline (failure)
    Given a build in which a command turn's decode configuration or output changed
    When the regression is detected
    Then the change is rejected as a NO-GIBBERISH invariant violation
    And the chat feature does not ship in that state
```

### FR-CNR-005: Deterministic Nepali grammar guard at the polisher seam — verify, never rewrite

**Area:** Grammar Guard / Verification · **Priority:** MUST
**Source:** Proposal §5.2 ("a deterministic Nepali checker (तिमी/तपाईं–verb agreement, Devanagari purity, dangling particles). The polisher doc says grammar stays the models' job — so this *verifies*, never rewrites"); feature constitution "Grammar guard (P0)" properties 1–2, 5 and Safety & Compliance Delta 3 ("A guard that 'fixes' grammar would be an unverified rewrite spoken to a vulnerable user — forbidden"); workflow scope comment. Surface: `SpokenReplyPolisher.swift` doctrine (:21-26).

A deterministic Nepali grammar guard **must** sit at the `SpokenReplyPolisher` seam and inherit its doctrine — deterministic, context-free, idempotent checks only, because "grammar stays the models' job". Binding properties:

- **Verify, never rewrite.** The guard never edits, patches, or regenerates the model's words; it produces a verdict, never text.
- **Checks (deterministic at minimum):** तिमी/तपाईं–verb agreement; Devanagari purity; dangling particles. The checks are implementations of the style spec (FR-CNR-001), not local heuristics with their own authority.
- **Every model reply passes it — local and cloud alike** (the polisher's existing contract); escalation output is verified by the same checks.
- **Reproducible verdict:** the same input produces the same verdict, run to run; running the guard twice over the same reply changes nothing (idempotent).
- **No rewrite path exists**: there is no code path in which guard output substitutes model words. On a flag the turn follows FR-CNR-006 (escalate or safe template).

```gherkin
Feature: The grammar guard verifies and never rewrites

  Scenario: A conforming reply passes untouched
    Given a reply with तपाईं + honorific agreement, Devanagari text and no dangling particle
    When the guard runs
    Then the verdict is pass
    And the reply is spoken byte-identical to the model's output

  Scenario: A violating reply is flagged, not edited
    Given a reply with a तिमी/तपाईं–verb agreement violation, a Devanagari-purity violation or a dangling particle
    When the guard runs
    Then the verdict is flag
    And the model's words are unchanged by the guard

  Scenario: The verdict is reproducible and idempotent
    Given the same reply and the same guard configuration
    When the guard runs repeatedly
    Then it returns the same verdict every time
    And re-running it over an already-checked reply changes nothing

  Scenario: The guard is asked to produce corrected text (failure)
    Given any flagged reply
    When the turn is completed
    Then the spoken text is either the model's original or an escalation/safe-template reply
    And no guard-invented "corrected" reply is ever spoken
```

### FR-CNR-006: Guard flag outcome — escalate to the cloud persona or a safe template; honest degradation

**Area:** Grammar Guard / Degradation · **Priority:** MUST
**Source:** Proposal §5.2 ("on a flag, escalate that turn to the Gemini persona (already grammatical) or a safe template, and emit a `reply_grammar_flag` telemetry event"); feature constitution "Grammar guard (P0)" properties 3 and 6 ("the user never hears a reply the guard proved wrong, and never hears a 'fixed' one the guard invented"; "a guard that fails to run degrades honestly … it never blocks speech with an error and never reports a success it did not verify") and Safety & Compliance Delta 3; workflow scope comment.

On a flag the turn **must** resolve through one of exactly two honest outcomes, in this order:

1. **Escalate** to the cloud persona when it is available and consented — a flag-triggered cloud call obeys the same consent/disclosure/indicator rules as the routing toggle (FR-CNR-009); it is a second, smaller egress surface, not an unconsented path.
2. **Speak a safe template** otherwise (offline, cloud unavailable, consent declined or revoked) — a short, grammatical, register-correct fallback reply that keeps the conversation going.

Binding properties:
- The user never hears a reply the guard proved wrong, and never hears a "fixed" one the guard invented (no guard-authored substitution of the model's content — FR-CNR-005).
- The guard **never blocks speech with an error**: a guard that fails to run degrades honestly — the turn proceeds under today's behaviour, or it escalates — and it never reports a success it did not verify.
- Chat is never lost by a flag: the turn is always answered.

```gherkin
Feature: A flagged turn is answered honestly

  Scenario: Flag with the cloud persona available and consented
    Given a flagged local reply
    And the cloud chat path is available and consented
    When the turn is completed
    Then the turn is answered by the cloud persona
    And the flagged local reply is not spoken

  Scenario: Flag with no cloud available
    Given a flagged local reply
    And the cloud chat path is unavailable, not consented, or revoked
    When the turn is completed
    Then a safe template reply is spoken
    And the turn is still answered (chat is not lost)

  Scenario: The guard fails to run (failure)
    Given a guard that cannot execute
    When a reply reaches the polisher seam
    Then the turn proceeds under today's behaviour or escalates
    And no error blocks speech
    And no unverified "verified" success is reported
```

### FR-CNR-007: `reply_grammar_flag` telemetry — observability without user content

**Area:** Grammar Guard / Telemetry · **Priority:** MUST
**Source:** Proposal §5.2 ("emit a `reply_grammar_flag` telemetry event"); feature constitution "Grammar guard (P0)" property 4 ("a `reply_grammar_flag` event carrying NO user content (no transcript, no reply text) — observability-bus policy (PII-free), log discipline per B2/T-050"); workflow `security-design-review` focus ("the `reply_grammar_flag` telemetry event carries NO user content"); project constitution Standards (logs must not contain PII; log sanitiser required) and OD-12 credential-handling precedent.

When the guard flags a reply, the system **must** emit a `reply_grammar_flag` event so the rate and causes are observable, and that event **must** carry no user content:

- **Permitted fields (classification only):** event kind, the failed check class (तिमी/तपाईं–verb agreement / Devanagari purity / dangling particle), the path that produced the reply (on-device or cloud), and the outcome taken (escalated / safe template / degraded).
- **Forbidden fields:** transcript text, the reply text, the user's identity, health values, contacts, profile content, or any key material. Zero content fields, on every path including error paths.
- The event is emitted for local and cloud replies alike, and for the guard-failure degradation case (FR-CNR-006) with a distinct outcome value so a guard that is not running is visible rather than silently absent.
- The event schema is fixed and reviewed at security design; adding a content-bearing field is a defect, not a configuration change (NFR-CNR-007).

```gherkin
Feature: reply_grammar_flag carries classification only

  Scenario: A flagged turn emits the event with classification fields
    Given a reply that the guard flags
    When the turn completes
    Then a reply_grammar_flag event is emitted
    And it names the failed check class, the producing path and the outcome taken
    And it contains no transcript text and no reply text

  Scenario: A guard that is not running is visible
    Given a guard that fails to run and the turn degrades
    When the turn completes
    Then an event with the degraded outcome is emitted
    And the absence of verification is not silent

  Scenario: A content-bearing payload is rejected (failure)
    Given an emitted reply_grammar_flag payload under inspection
    When it contains transcript text, reply text, user identity or key material
    Then the payload is reported as a defect
    And the offending field is removed before ship
```

### FR-CNR-008: Cloud-first chat routing toggle — online routes to Gemini, local brain is the floor

**Area:** Cloud Chat Routing · **Priority:** MUST
**Source:** Proposal §5.3 ("**Cloud-first chat routing toggle**: when online, route chat to Gemini with the upgraded persona — instant grammar + conversationality for online users, local brain as fallback"); feature constitution "Cloud-first chat routing toggle (P0)" properties 1 and 7 ("The toggle never blocks chat — an unavailable, declined, or revoked cloud degrades to the on-device brain. The command ladder and emergency gate are NOT altered by chat routing"; "Reuse, don't fork … extends the existing cloud plumbing (`GeminiClient`, the router's cloud readiness inputs) — it does not add a parallel cloud path"); workflow scope comment. Surfaces: `IntentRouter.interpretLocalLadder` (:259-291) / `runLocalLadder` (:308-395), `LocalBrainChain.respondToChat` (:268-294), `GeminiClient`.

Chat turns **must** route to the cloud (Gemini, with the upgraded persona from FR-CNR-002) when the device is online and consented; otherwise the on-device brain answers. Binding properties:

- **Routing applies to chat turns only.** The command ladder, the emergency gate and the chat pre-check semantics beyond wiring the toggle are unchanged (FR-CNR-014).
- **The toggle never blocks chat.** An unavailable cloud (offline, error, timeout, rate cap), declined consent, or revocation degrades to the on-device brain; the turn is still answered. No silent failure, no dropped turn, no user-visible error where a reply is expected.
- **Honest degradation is visible to the developer path, not a false success:** a cloud-routed turn that degrades records the fallback (classification only, no content — NFR-CNR-007) rather than reporting a cloud success.
- **Reuse, not fork.** The toggle extends the existing cloud plumbing (`GeminiClient`, the router's cloud-readiness inputs); it does not add a parallel cloud path or a second provider integration.
- The on-device engine remains a first-class peer (project rule: the cloud engine is one option, never the only path).

```gherkin
Feature: Cloud-first chat routing with a never-failing local floor

  Scenario: Online and consented chat routes to the cloud persona
    Given the device is online and cloud chat is consented
    When the user speaks a chat turn
    Then the turn is answered through the cloud chat path using the upgraded persona

  Scenario: Offline chat is answered by the on-device brain
    Given the device is offline
    When the user speaks a chat turn
    Then the on-device brain answers
    And the reply is spoken without crash, delay beyond the envelope, or loss of the turn

  Scenario: A cloud error mid-turn degrades to the local brain
    Given cloud chat is consented and online
    When the cloud request fails or times out
    Then the turn degrades to the on-device brain
    And the degradation is recorded as a classification
    And the user still receives a reply

  Scenario: Consent is declined or revoked (failure)
    Given cloud chat consent is declined or has been revoked
    When the user speaks a chat turn
    Then no chat content leaves the device
    And the on-device brain answers the turn
```

### FR-CNR-009: Cloud chat consent, plain-language disclosure, visible indicator and revocation (the OD-12 shape)

**Area:** Cloud Chat Consent & Disclosure · **Priority:** MUST
**Source:** Proposal §5.3 ("explicit consent + plain-language disclosure + visible indicator, revocable, never blocks chat — the OD-12 shape"); feature constitution "Cloud-first chat routing toggle (P0)" properties 2, 5 and 6, and Safety & Compliance Delta 2 ("NEW cloud egress surface: chat conversation content … recorded in the OD-12 shape as an explicit exception/amendment — not a silent divergence from Architecture Constraint 1"); project constitution Architecture Constraint 1 recorded exceptions, Open Decisions 12 and 13 (the consent/disclosure pattern), and Standards Privacy ("each of which requires explicit user consent and plain-language disclosure"). Surface: the router's cloud-readiness/consent state, the existing consent UX seams.

The cloud chat path is a **consent-gated exception** to Architecture Constraint 1 and **must** carry the Open Decision 12 treatment, exactly:

- **Explicit consent at first cloud chat use**, with **plain-language disclosure** of what leaves the device (the chat conversation content), to whom, and what stays local. Consent is the user's (the elderly person's) explicit act; no default-on egress before consent, no consent buried in a general terms screen.
- **A visible indicator while conversation content is going to the cloud** — perceivable in the user's configured language, present for the whole time the cloud path is active, not a one-time toast.
- **Revocable at any time**; revoking returns subsequent turns to the on-device brain **without losing assistant functionality** — chat keeps working, no feature is held hostage to consent.
- **The grammar-guard escalation obeys the same rules** (FR-CNR-006): it is a second, smaller cloud egress surface and is consent-gated exactly like routing — a flag never silently opens an unconsented egress.
- **Conversation content is going to the cloud only when the exception is active**: consent state gates the route, and a declined/revoked state is enforced at the routing decision, not merely in the UI (NFR-CNR-011 evidence).
- **Consent/disclosure copy and the indicator UX are reviewed before the first App Store submission**, consistent with the Open Decision 12/13 review clause; the feature-level exception is recorded so the root constitution's recorded-exceptions list can be amended at final sign-off.

```gherkin
Feature: Cloud chat egress is consented, disclosed, indicated and revocable

  Scenario: First cloud chat use requires explicit consent
    Given a device that has never used cloud chat
    When a chat turn would route to the cloud
    Then plain-language disclosure is shown before any chat content is sent
    And no chat content leaves the device until the user consents

  Scenario: A visible indicator is present while cloud chat is active
    Given cloud chat consent has been granted and the cloud path is active
    When chat turns are handled
    Then a visible indicator is shown while conversation content is going to the cloud
    And it is rendered in the user's configured language

  Scenario: Revocation returns to the on-device brain without losing chat
    Given cloud chat consent is revoked
    When the user speaks a chat turn
    Then the turn is answered on-device
    And the assistant loses no chat functionality

  Scenario: The grammar-guard escalation is consent-gated too (failure)
    Given consent has been declined or revoked
    When the grammar guard flags a local reply and would escalate
    Then no chat content is sent to the cloud
    And the turn resolves through the safe-template path
```

### FR-CNR-010: Cloud chat egress scope — the chat turn's user content and nothing else

**Area:** Cloud Chat Egress Scope · **Priority:** MUST
**Source:** Feature constitution "Cloud-first chat routing toggle (P0)" property 3 ("Scope of egress: the chat turn's user content only. No health data, contacts, or profile content beyond what the user's own utterance contains. Emergency and command content flows through the existing (unchanged) paths, not this toggle") and Safety & Compliance Delta 2; project constitution Architecture Constraint 1 and Standards Privacy; project rule that no new data collection is introduced by this feature.

The only content that may leave the device through this feature **must** be the chat turn's user content — the spoken utterance and the conversational context needed to answer that turn — and nothing else. Binding properties:

- **No adjacent payload.** Health data (HealthKit values, medication state), contacts, family data, profile content, device identifiers and voice recordings are not added to a cloud chat request beyond what the user's own utterance contains.
- **Emergency and command content are out of this path.** Emergency phrasing and command turns flow through the existing (unchanged) routing and emergency paths; the chat toggle never carries them and never re-routes them (FR-CNR-014).
- **The escalation path has the same scope** as the routing path — a guard-triggered escalation sends the chat turn's content, not a broader context (FR-CNR-006).
- **No new data collection.** The feature introduces no telemetry, analytics or storage collection beyond the classification-only events this set defines (FR-CNR-007) and the recorded cloud-chat egress itself.

```gherkin
Feature: Cloud chat egress is bounded to the chat turn

  Scenario: A cloud chat request contains the chat content only
    Given cloud chat is consented and online
    When a chat turn is sent to the cloud
    Then the request carries the turn's user content and the contextual turns needed to answer it
    And it carries no health data, contacts, or profile payload beyond the utterance

  Scenario: Emergency and command turns never travel this path
    Given a device with cloud chat enabled
    When an emergency utterance or a command turn is spoken
    Then it is handled through the existing (unchanged) path
    And the chat routing toggle does not carry or re-route it

  Scenario: An adjacent payload is attached (failure)
    Given a cloud chat request under inspection
    When it contains health values, contact data or profile content beyond the utterance
    Then the request is reported as an Architecture Constraint 1 violation
    And the feature does not ship in that state
```

### FR-CNR-011: Explicit Gemini chat temperature — a stated, reviewed value instead of a provider default

**Area:** Cloud Chat Sampling Config · **Priority:** MUST
**Source:** Proposal §5.3 ("Gemini's `GenerationConfig` currently sends no sampling params (`GeminiClient.swift:658-680`); set an explicit temperature for chat there"); feature constitution "Persona seams and Gemini chat temperature" property 3 ("`GeminiRequest.GenerationConfig` (`GeminiClient.swift:659-661`) gains an EXPLICIT chat temperature — today it sends no sampling params, so the value is a provider default; it becomes a stated, reviewed value. (Exact value: Open Decision 5.)"); feature constitution OD-5. Surface: `Services/Gemini/GeminiClient.swift` `GenerationConfig`.

The cloud chat request **must** carry an explicit chat temperature in `GenerationConfig` — today the request sends no sampling parameters, so the effective value is a provider default nobody chose. The exact value is design-l1's to propose with a rationale (feature OD-5) and is reviewed like the on-device value (temperature ~0.3, FR-CNR-003). Binding properties:

- The explicit value is **visible in the code and in the design record** — a stated, reviewed decision, not an inherited provider default.
- The change is **chat-scoped**: other Gemini call sites (voice transcription, the translation tier, teacher tooling) keep today's behaviour; no sampling parameter is silently added to them by this feature.
- The cloud and on-device chat behaviour are described by the same style contract (FR-CNR-002), so an explicit cloud temperature is part of keeping the two paths from drifting in perceived register.

```gherkin
Feature: The cloud chat request carries an explicit temperature

  Scenario: A cloud chat request states its sampling value
    Given cloud chat is consented and online
    When the chat request is built
    Then its GenerationConfig carries an explicit temperature
    And the value matches the reviewed design decision

  Scenario: Other Gemini call sites are unchanged
    Given the pre-change behaviour of the transcription and translation call sites
    When the feature's change set is inspected
    Then those call sites send the same request shape as before
    And the chat temperature is not applied to them

  Scenario: The value is a provider default again (failure)
    Given a build in which the chat request omits its sampling value
    When the request is inspected
    Then the omission is reported as a regression against this requirement
    And the documented value is restored
```

### FR-CNR-012: Cloud chat credential and content hygiene — header-only key, content off the logs

**Area:** Cloud Chat Hygiene · **Priority:** MUST
**Source:** Feature constitution "Cloud-first chat routing toggle (P0)" property 4 ("the provider key travels in a header only — never in a URL, never in logs; conversation content must not reach logs beyond the existing transcript policy; the release-build log-surface gate (`ios/tools/check-release-log-safety.sh`) must cover the new routing/guard paths"); project constitution Open Decision 12 credential handling and the B2/T-050 binding precedent; project constitution Release gates (release-build log-surface gate; pre-release device check); workflow `security-design-review` / `security-test` focus.

The new cloud chat and grammar-guard paths **must** carry the same credential and content discipline the B2/T-050 remediation established (the binding precedent, not a new standard):

- **The provider key travels in a header only** — never in a URL, never in a query string, never in a log line, never in an error body.
- **Conversation content must not reach logs** beyond the existing transcript policy: the chat turn's text, the reply text, and the escalation's content are not logged by the new routing, consent or guard code. Errors on the cloud path record a reason classification, never the request payload or the response body.
- **The release-build log-surface gate covers the new paths**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of every test scope) exits 0 with the new chat/routing/guard source paths inside its coverage, and the pre-release device console/sysdiagnose check exercises those same paths.
- **Existing disciplines are not weakened** across the touched files (`GeminiClient`, `GeminiCommandInterpreter`, `LlamaCommandInterpreter`, `SpokenReplyPolisher`, `IntentRouter`, the new guard).

```gherkin
Feature: Credential and content hygiene on the new cloud chat paths

  Scenario: The provider key travels in a header
    Given a cloud chat request built by the feature
    When the request is inspected
    Then the key is present in a header only
    And no URL or query string contains it

  Scenario: A Release exercise of the new paths logs no content
    Given a Release build
    When a cloud chat turn, a guard flag and an escalation are exercised
    Then no conversation content, reply text or key material appears in the console or logs
    And only classification-level records are emitted

  Scenario: The log-safety gate covers the new paths and exits 0
    Given the feature's routing, consent, guard and escalation source paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And its rule coverage includes the new source paths

  Scenario: An error path leaks the payload (failure)
    Given a cloud chat failure or a guard escalation failure
    When the error is recorded
    Then only a reason classification is written
    And no request payload, response body, conversation text or key material reaches the log
```

### FR-CNR-013: Single-decode schema unchanged — one JSON, and an unreadable object abstains

**Area:** Single-Decode Integrity · **Priority:** MUST
**Source:** Proposal §1 ("The single-decode architecture (one JSON: `intent` + `response` + `confidence`) stays untouched — the router and its emergency gate must not regress") and §4 ("Same single-decode shape (schema unchanged) → no chain/router surgery, catalog swap only"); feature constitution "Out of scope (must not change)" ("The single-decode schema — one JSON (`intent` + response/reply + `confidence`). No chain/router surgery; the v17 variant is a catalog swap") and Runtime Contract "Chat decode (P0)" property 3 and "Model & Training Contract" property 1. Surfaces: `IntentPrompt.buildChat`, `chatJSONSchema` (GBNF), `LocalBrainChain.respondToChat` (:268-294), `IntentRouter.interpretLocalLadder` (:259-291).

The feature **must not** change the single-decode architecture. Chat continues to be produced as **one JSON object** carrying intent, response/reply and confidence, constrained by the existing GBNF chat schema, and chat keeps flowing through the existing capability rule (`LocalBrainChain.respondToChat`) and the existing chat pre-check (`IntentRouter.interpretLocalLadder`). Binding properties:

- **No chain or router surgery.** No new decode stage, no second model call to compose the reply, no post-hoc JSON repair layer that changes the contract. The P1 model arrives as a catalog swap (FR-CNR-022), not as a new pipeline.
- **The GBNF `chatJSONSchema` constraint continues to apply** (FR-CNR-003).
- **A model that cannot produce a readable object ABSTAINS (nil)** — it never speaks malformed output, never emits a partially parsed reply, and never falls back to speaking raw model text.
- The abstention path retains the existing abstain/honesty discipline that the abstention gate (≥0.90) and the claw-back data keep trained in (FR-CNR-017).

```gherkin
Feature: The single-decode shape is unchanged by this feature

  Scenario: A chat turn still produces one JSON object
    Given a chat turn on the shipped feature build
    When the model output is decoded
    Then it is one JSON object carrying intent, reply and confidence
    And it was produced without an added decode stage

  Scenario: The chat route and pre-check semantics are unchanged
    Given the same inputs as the pre-change build
    When a chat turn is routed
    Then it travels the same capability rule and chat pre-check decision points
    And no chain/router structure was added or re-ordered by this feature

  Scenario: An unreadable output abstains (failure)
    Given a chat decode whose output cannot be parsed as a readable JSON object
    When the turn is handled
    Then the system abstains
    And no malformed or partially parsed text is spoken
```

### FR-CNR-014: Router ladder and the emergency path unchanged — emergency recall 1.00 is a gate, not a metric

**Area:** Preserved Behaviours / Safety Path · **Priority:** MUST
**Source:** Feature constitution "Out of scope (must not change)" ("The router ladder and emergency gate behavior; the chat pre-check semantics beyond wiring the routing toggle") and "Cloud-first chat routing toggle (P0)" property 1; Safety & Compliance Delta 1 ("The v17 chat variant is a catalog swap of the SAME single-decode model that answers commands and the emergency path — a chat-data regression is a safety regression. Therefore all existing gates (emergency recall 1.00 above all) are non-negotiable regressions"); proposal §1 and §6 ("**emergency recall 1.00**"); project constitution Safety-critical constraints (emergency calling logic isolated in a hardened module; not blocked by the on-device LLM being busy or unavailable); workflow scope comment. Surfaces: `IntentRouter` ladder (:259-291, :308-395), `LocalBrainChain`, the emergency path, `AppCoordinator.defaultBrainModelID`.

The router ladder, the emergency gate and the safety routing behaviour **must** keep their pre-change semantics exactly, while the chat changes land around them:

- **The chat toggle never alters ladder ordering, ladder triggers, or the emergency gate.** Chat routing is wired into the chat path; it does not intercept, delay, re-order or re-classify emergency or command turns (FR-CNR-010).
- **The emergency path is not blocked by chat.** A chat turn in flight — local or cloud — never blocks, delays past its confined budget, or suppresses an emergency trigger; the emergency module's isolation from on-device LLM availability is preserved.
- **Emergency recall 1.00 remains a gate.** Because the v17 chat variant is the *same* single-decode model answering the intent and emergency paths, the emergency gate is a ship condition, never a monitored metric that may drift (FR-CNR-021). Emergency phrasing behaviour is re-verified on device (DV-4, FR-CNR-025).
- **Existing behaviour is preserved, not "improved":** no chat-driven change to emergency phrasing handling, threshold logic, or the trigger confirmation seam.

```gherkin
Feature: The ladder and emergency path are untouched by chat work

  Scenario: The ladder behaves exactly as before
    Given a set of turns used as the pre-change reference (commands, chat, ambiguous and emergency phrasing)
    When the feature build routes them
    Then every routing decision and trigger point matches the pre-change behaviour
    And only the chat path reflects the new routing toggle

  Scenario: A chat turn never blocks or delays an emergency trigger
    Given a chat turn in flight (local decode or cloud request)
    When an emergency utterance is spoken
    Then the emergency path triggers as it does without the chat feature
    And no chat state (routing, consent, guard) gates it

  Scenario: Emergency recall drops below 1.00 (failure)
    Given the post-change model evaluated on the emergency suite
    When recall is measured
    Then a result below 1.00 is a failed gate
    And the catalog swap does not ship in that state
```

### FR-CNR-015: STT pipeline, device permissions and data collection unchanged

**Area:** Preserved Behaviours / Privacy & Permissions · **Priority:** MUST
**Source:** Feature constitution "Out of scope (must not change)" ("STT behavior — the speech pipeline is not part of this feature (the STT-engine invariant stands)"; "Any new device permission; any new data collection beyond the recorded cloud-chat egress") and Safety & Compliance Delta 6 ("Unchanged: STT behavior; emergency-call logic; medication flow; device permissions; the intent prompt bytes; the router/emergency gates"); owner-declared STT-engine invariant ("functioning STT is the invariant of any change; transcript regressions cascade into intent and everything downstream"); workflow `define-requirements` non-goals.

The feature **must not** touch the speech pipeline, add device permissions, or add data collection:

- **STT untouched.** No change to transcription models, decoding, the transcript path, noise handling or the engine stack selection. The only interaction is that chat turns *consume* transcripts exactly as today; the reply-side changes (persona, decode, guard, routing) begin after the transcript exists.
- **Transcript-regression visibility.** Any observed change in transcript behaviour during this feature is a stop-and-investigate event, not an acceptable side effect — the STT-engine invariant is owner-declared and cascades into intent and every downstream path.
- **No new device permission.** No new `Info.plist` usage key, no new capability prompt; the cloud chat path reuses the existing network access and the existing cloud plumbing (FR-CNR-008).
- **No new data collection** beyond the recorded cloud-chat egress (FR-CNR-010) and the classification-only telemetry this set defines (FR-CNR-007).
- **Medication flow and emergency-call logic unchanged** (also FR-CNR-014 for the routing side).

```gherkin
Feature: The speech pipeline and permissions are unchanged

  Scenario: The speech pipeline is byte-identical
    Given the pre-change STT path, its configuration and its engine-stack selection
    When the feature's change set is inspected
    Then no STT source file, model selection or decode setting is modified
    And the transcript behaviour for a given audio input is unchanged

  Scenario: No new permission or data collection appears
    Given the shipped feature build
    When the app's permission set and data flows are inspected
    Then no usage-description key was added
    And the only new egress is the consented cloud-chat path
    And no new collection exists beyond the classification-only events this set defines

  Scenario: A transcript regression appears during the work (failure)
    Given a build in which transcription output differs from the pre-change baseline for the same audio
    When the difference is observed
    Then the work stops and the divergence is reported against the STT-engine invariant
    And it is not accepted as an acceptable side effect of this feature
```

### FR-CNR-016: v17 — a chat-aware QLoRA variant of the existing training suite (same model family)

**Area:** Training / v17 Suite Extension · **Priority:** MUST
**Source:** Proposal §4 ("Extend `tools/train-intent` with a `chat` variant (v17) rather than a new pipeline") with its base, recipe and mixture bullets; feature constitution "Mixture and gate harness" property 1 ("Mixture: 70% conversation / 30% claw-back … Target ~30–60k clean turns post-filter. Recipe: the proven QLoRA config (r=16, α=32, lr ~1e-4, 2–3 epochs, 1024 seq, Q4_K_M export). Assistant turns are teacher-GEC'd before training") and "Single-decode integrity and catalog swap" properties 1–4; workflow scope comment. Surfaces: `tools/train-intent/` (`config.yaml` teacher `gemini-2.5-flash-lite`, `stt_noise.py` at the existing 60% rate), training box anjan-ubuntu (4090).

The P1 deliverable **must** be a **chat-aware variant (v17) of the existing `tools/train-intent` suite** — not a new pipeline — producing the same single-decode model family with a conversation-capable chat behaviour. Binding properties:

- **Same single-decode shape, catalog-swap delivery.** The variant keeps the schema (intent + reply + confidence) and is delivered as a new `ModelCatalog` entry (FR-CNR-022); no chain/router changes accompany it (FR-CNR-013).
- **Mixture: 70% conversation / 30% claw-back** (Layer 4 sources per FR-CNR-017). The claw-back is the intent-regression mitigation and is not optional.
- **Recipe: the proven QLoRA configuration** — r=16, α=32, learning rate ~1e-4, 2–3 epochs, 1024 sequence length, Q4_K_M export.
- **Target corpus size: ~30–60k clean conversational turns post-filter**, with every assistant turn teacher-GEC'd before training (grammar comes from the data, per FR-CNR-001/FR-CNR-017).
- **Base model: Qwen3-1.7B as the device default**, with the Nepali extended-tokenizer base preferred (`qwen4BNepali`, `ModelCatalog.swift:237`) because fewer tokens per Nepali sentence leaves budget inside the 1,024-token ceiling; the 4B variant is a P2 tier served only via the per-device resolver (FR-CNR-028).
- **Training runs on the training box** (anjan-ubuntu, 4090); corpus and GGUF are build artifacts, not app changes.
- **The run is reproducible from the recorded recipe and provenance manifest** (FR-CNR-018): the same data mix, filters and hyperparameters are recorded with the run.

```gherkin
Feature: A chat-aware v17 variant of the existing training suite

  Scenario: The run produces a chat-capable single-decode variant
    Given the v17 training run completed on the training box
    When the produced model is evaluated
    Then it answers chat turns conversationally under the single-decode schema
    And it was produced by a chat variant of tools/train-intent, not a new pipeline

  Scenario: The mixture and recipe are as specified
    Given the recorded training run
    When its configuration and data mix are inspected
    Then the conversation:claw-back ratio is 70:30
    And the QLoRA configuration is r=16, α=32, lr ~1e-4, 2–3 epochs, 1024 seq, Q4_K_M export
    And the corpus is within the ~30–60k clean turns target after filtering
    And every assistant turn in the corpus is teacher-GEC'd

  Scenario: The run is reproducible from its record
    Given the recorded recipe, filter set and provenance manifest
    When the run is repeated against the same data mix
    Then it reproduces the recorded configuration and gate results

  Scenario: A run without the claw-back mixture (failure)
    Given a candidate whose mixture omits the 30% claw-back
    When the gate harness is run
    Then the candidate is not eligible for a catalog swap
    And the deviation is recorded rather than shipped
```

### FR-CNR-017: Four-layer conversation corpus construction shaped by the style spec

**Area:** Training Data / Corpus Construction · **Priority:** MUST
**Source:** Proposal §3 "Data plan — publicly available conversation samples" (Layers 1–4 with the pipeline, filters and target size) and §4 ("Grammar comes from the data: every assistant turn in the corpus is teacher-GEC'd before training"); feature constitution "Mixture and gate harness" property 1 (layer mapping, STT-noise rate, teacher-GEC) and "Data provenance — binding" property 3; workflow scope comment. Surfaces: `tools/train-intent/` (`config.yaml` teacher, `stt_noise.py`), `eval/golden_corpus.jsonl`, `eval/emergency_nearmiss.jsonl`.

The v17 corpus **must** be built from the proposal's four layers, each shaped by the style spec (FR-CNR-001) and each filtered before it is admitted:

- **Layer 1 — native Nepali conversation (style anchors, grammar ground truth).** IndicDialogue Nepali (9,688 dialogues), the Nepali call-center corpus (audio; transcribed through the existing Whisper pipeline on the training box, a ~100–300 h sample — the only public source of *spoken* Nepali register), kshitizgajurel/Devanagari-Ecommerce (4,930 rows) for task-oriented politeness, and optionally the nepali-sft sets, teacher-cleaned and light-weight. **Layer 1's research-gated and CC BY-NC members are dev-mix only** (FR-CNR-018).
- **Layer 2 — translated + post-edited English dialogue (volume + topical diversity).** Research-only sources (DailyDialog, PersonaChat/ConvAI2, EmpatheticDialogues) and commercial-safe sources (Taskmaster-1/2/3, SODA, ProsocialDialog, OASST1); the pipeline is en→ne with the project's own Qwen-1.7B translation tier off-device, then teacher post-edit with the existing teacher (`gemini-2.5-flash-lite`) given the style spec plus few-shot real exemplars from Layer 1, then automatic filters (honorific-agreement checker, AI-ism blacklist, length) and a human spot-check.
- **Layer 3 — synthetic elderly-care dialogues (domain match, unlimited, commercial-safe).** Teacher-generated, persona-grounded conversations across the repertoire (meds reminders, health talk, family, food, weather, memories, loneliness), grounded in Layer-1 style anchors, ~10–20k turns.
- **Layer 4 — retention claw-back (~30% of the mix).** Existing `eval/golden_corpus.jsonl` (8k rows), `eval/emergency_nearmiss.jsonl`, abstain/honesty examples (the abstention ≥0.90 gate and the "abstain honesty 0.0" lesson must stay trained in), light instruction data, and STT-noised user turns at the same 60% rate the suite already uses (`stt_noise.py`) so the model understands *spoken* Nepali input.
- **Grammar comes from the data**: every assistant turn admitted to the corpus is teacher-GEC'd first.
- **The filters are recorded** with the run (the automatic filters, the human spot-check step, and the resulting turn counts per layer) so the ~30–60k clean-turn target is auditable (FR-CNR-018).

```gherkin
Feature: The v17 corpus is built from the four layers and filtered

  Scenario: Every layer is represented and the mixture is intact
    Given the recorded v17 corpus
    When its composition is inspected
    Then Layers 1–4 are each represented
    And Layer 4 accounts for ~30% of the mix with the 60% STT-noise rate applied to user turns

  Scenario: Assistant turns are grammatical by construction
    Given a sample of assistant turns from any layer
    When they are inspected
    Then each was teacher-GEC'd before admission

  Scenario: Automatic filters reject substandard turns
    Given a Layer-2 turn with honorific disagreement, an AI-ism, or out-of-bounds length
    When the filter stage runs
    Then the turn is rejected and the rejection is counted
    And the surviving corpus is within the ~30–60k clean-turn target

  Scenario: An unfiltered layer reaches training (failure)
    Given a candidate corpus containing turns that failed the filters, GEC, or the style-spec conformance check
    When the corpus is inspected
    Then those turns are removed before training
    And the deviation is recorded rather than shipped
```

### FR-CNR-018: Ship-mix provenance manifest — no CC BY-NC contamination of a shipped artifact

**Area:** Training Data / Provenance & Licensing · **Priority:** MUST
**Source:** Proposal §3 (license posture: "DailyDialog/PersonaChat/EmpatheticDialogues/IndicDialogue are **CC BY-NC** — research-only; use them for the dev mix, keep the ship mix clean") and §7 risks ("licensing → ship mix uses only CC-BY/Apache/MIT + synthetic + own data, research layers stay in the dev mix"); feature constitution "Data provenance — binding" properties 1–4 and Safety & Compliance Delta 5 ("CC BY-NC contamination of a shipped artifact is a compliance event (App Store distribution); the provenance manifest is the evidence"); workflow `security-design-review` / `security-test` focus.

The training run **must** be accompanied by a **provenance manifest** that proves the shipped mix's license posture, and the shipped mix **must** contain only ship-safe sources. Binding properties:

- **Ship mix = CC-BY / Apache / MIT + synthetic + own data only.** Concretely: kshitizgajurel/Devanagari-Ecommerce (Apache-2.0), Taskmaster-1/2/3, SODA, ProsocialDialog (CC-BY-4.0), OASST1 (Apache-2.0), synthetic Layer 3, and the project's own data.
- **CC BY-NC sources never contaminate a shipped artifact**: IndicDialogue Nepali, DailyDialog, PersonaChat, and EmpatheticDialogues are dev/research-only. Any artifact (corpus, GGUF, catalog entry) whose mix contains them does not ship.
- **The Nepali call-center corpus is research-gated**: anything trained on it ships only after the enterprise license is obtained; until then it is dev-mix only, and its transcripts are labelled accordingly in the manifest.
- **The manifest is the evidence**: it lists every source with its license, layer, ship/dev classification, the row/turn counts used, and the derived artifacts produced (FR-CNR-016). It is produced as part of the run and travels with the run into security design/test.
- **Tooling inherits the rule**: the en→ne translation tier's inputs and the teacher are tooling, not shipped artifacts, but the ship/dev classification of their inputs is still recorded.
- Contaminating a shipped artifact is treated as a **compliance event**, not a training-error class.

```gherkin
Feature: Provenance manifest proves the ship mix is clean

  Scenario: The manifest accounts for every source in the shipped mix
    Given the v17 training run and its served artifacts
    When the provenance manifest is inspected
    Then every source is listed with its license, layer and ship/dev classification
    And the ship-mix entries are exclusively CC-BY, Apache, MIT, synthetic or own data

  Scenario: A research-only source is confirmed absent from the shipped artifacts
    Given the manifest's list of CC BY-NC and research-gated sources
    When the shipped corpus and GGUF are checked
    Then none of those sources contributed turns to them
    And the manifest states the exclusion explicitly

  Scenario: A CC BY-NC source reaches the ship mix (failure)
    Given a candidate artifact whose mix includes IndicDialogue, DailyDialog, PersonaChat, EmpatheticDialogues, or unlicensed call-center transcripts
    When the artifact is reviewed
    Then it is rejected as a compliance event
    And it does not ship or enter the catalog (FR-CNR-022)
```

### FR-CNR-019: `eval/chat_golden.jsonl` — a held-out chat evaluation set

**Area:** Evaluation / Held-out Set · **Priority:** MUST
**Source:** Proposal §6 ("**New**: `eval/chat_golden.jsonl` (~500 held-out Nepali chat turns, teacher-authored + human-reviewed)"); feature constitution "Mixture and gate harness" property 2 ("New chat gates over `eval/chat_golden.jsonl`"); workflow scope comment ("new `eval/chat_golden.jsonl` held-out set + new gates"); profile of the existing eval fixtures. Surface: `tools/train-intent/eval/` (new fixture alongside `golden_corpus.jsonl`, `emergency_nearmiss.jsonl`).

The feature **must** ship a new evaluation fixture, `tools/train-intent/eval/chat_golden.jsonl`, of approximately **500 held-out Nepali chat turns**, teacher-authored and human-reviewed, held out of training:

- **Held out strictly**: no turn (or near-duplicate) from this set is present in the training corpus; the manifest (FR-CNR-018) records the exclusion.
- **Coverage is deliberate**: the set exercises the style spec's classes — register/honorific agreement, particles within budget, small-talk repertoire, code-switched health/tech nouns, and the forbidden AI-ism classes — plus the hard cases (offline-style short turns, code-switched input, reminiscence prompts).
- **Reviewable**: every turn carries its expected qualities so a reviewer can adjudicate the gates without re-deriving intent; the set is human-reviewed before use as a gate fixture.
- **The fixture is versioned with the run**: a gate result is only meaningful against the fixture version recorded in the run's evidence.

```gherkin
Feature: A held-out chat golden set exists and is trustworthy

  Scenario: The fixture exists at the specified scale and shape
    Given the shipped feature
    When tools/train-intent/eval/chat_golden.jsonl is inspected
    Then it contains approximately 500 Nepali chat turns with their expected qualities
    And each turn is teacher-authored and human-reviewed

  Scenario: The set covers the style spec's classes
    Given the fixture's turn inventory
    When its coverage is reviewed against the style spec
    Then register/honorific, particle-budget, small-talk, code-switch and AI-ism classes are each represented

  Scenario: A golden turn leaks into training (failure)
    Given the training corpus and the chat golden set
    When they are compared
    Then no golden turn or near-duplicate is present in the corpus
    And a detected overlap invalidates the gate run until the corpus is corrected
```

### FR-CNR-020: The new chat gates — honorific agreement, no AI-isms, LLM-judge quality

**Area:** Evaluation / Chat Gates · **Priority:** MUST
**Source:** Proposal §6 ("New gates: honorific-agreement pass ≥0.98, no-AI-ism ≥0.98, LLM-judge (reuse the `stt_judge_eval` judge pattern or Gemini) mean ≥4/5 on naturalness/grammar/warmth/brevity"); feature constitution "Mixture and gate harness" property 2 and "Nepali Conversation Style-Spec Contract" property 8 ("The honorific-agreement and no-AI-ism eval gates and the grammar guard's checks are implementations of this spec; a gate failure is a spec violation"); workflow scope comment. Surface: `tools/train-intent/eval/` (the harness), `eval/chat_golden.jsonl` (FR-CNR-019).

Three new chat gates **must** be implemented over `eval/chat_golden.jsonl` and **must** meet their thresholds for the catalog swap to be eligible:

| Gate | Threshold | Measures |
|---|---|---|
| Honorific agreement | pass rate **≥0.98** | तपाईं + honorific verb agreement, no तिमी toward the elder |
| No AI-isms | pass rate **≥0.98** | no lists/markdown, no "म एक AI हुँ", no canned service phrases, no translation-ese, no over-politeness |
| LLM-judge quality | mean **≥4/5** | naturalness, grammar, warmth, brevity (reusing the existing `stt_judge_eval` judge pattern or Gemini) |

Binding properties:
- **The gates implement the style spec** (FR-CNR-001): a gate failure is a spec violation, and the spec — not a gate-local heuristic — is the authority. A gate's rubric is derived from the spec, not authored beside it.
- **Thresholds are ship conditions, not targets**: a result below threshold is a failed gate (FR-CNR-021), never rounded, re-scoped or waived without the owner.
- **Judge reproducibility**: the LLM-judge configuration, judge model/version and prompt are recorded with the result so a gate verdict can be re-derived.
- **The gate run's result is recorded as release evidence** together with the fixture version (FR-CNR-019) and the model artifact identity.

```gherkin
Feature: The new chat gates gate the swap

  Scenario: All three gates are evaluated over the held-out set
    Given the candidate v17 model and eval/chat_golden.jsonl
    When the chat gate harness runs
    Then it reports honorific-agreement pass rate, no-AI-ism pass rate, and the LLM-judge mean over naturalness/grammar/warmth/brevity
    And each result is recorded with the fixture version and judge configuration

  Scenario: Thresholds are met and the candidate is eligible
    Given the gate run results
    When honorific agreement is ≥0.98, no-AI-ism is ≥0.98 and the judge mean is ≥4/5
    Then the chat gates are green
    And the candidate proceeds to the full harness (FR-CNR-021)

  Scenario: A gate fails (failure)
    Given a candidate with any chat gate below its threshold
    When the swap is considered
    Then the swap is blocked
    And the shortfall is reported to the owner rather than absorbed by loosening the gate
```

### FR-CNR-021: The full gate harness is the ship gate — existing regressions are non-negotiable

**Area:** Evaluation / Regression Gates & Ship Gate · **Priority:** MUST
**Source:** Proposal §6 ("**Non-negotiable regressions** (same model, so the full suite must stay green): closed-intent ≥0.95, **emergency recall 1.00**, abstention precision ≥0.90, calibration ±0.10, latency p50 ≤1.0 s") and §7 risks ("intent regression → 30% claw-back + full gate suite"); feature constitution "Mixture and gate harness" properties 2–3 ("The catalog swap ships only with ALL gates green; harness output is release evidence"; "A red gate is a stop, not a threshold to move") and Safety & Compliance Delta 1; workflow scope comment.

The v17 catalog swap **must** ship only when the **entire** gate suite is green — the new chat gates (FR-CNR-020) **and** every existing regression gate, because the chat variant is the same single-decode model that serves the safety-critical intent path:

| Existing gate (non-negotiable regression) | Threshold |
|---|---|
| Emergency recall | **1.00** (a gate, not a metric — FR-CNR-014) |
| Abstention precision | **≥0.90** |
| Closed-intent accuracy | **≥0.95** |
| Calibration | **±0.10** |
| Latency p50 | **≤1.0 s** |

Binding properties:
- **A red gate is a stop.** The swap does not ship; the response is to fix the data or the run, never to move the threshold. Any threshold change is an owner decision recorded explicitly.
- **Harness output is release evidence**, stored with the run: per-gate results, the fixture versions used, the judge configuration, and the model artifact identity.
- **The claw-back mixture (30%, FR-CNR-016/017) is the named mitigation** for intent regression and is part of what makes the "all gates green" claim meaningful.
- **No partial ship**: there is no path where the chat variant ships for chat quality while an existing gate is red — the swap is one model serving both paths.

```gherkin
Feature: All gates green before the swap

  Scenario: The full suite runs against the candidate
    Given the candidate v17 artifact
    When the gate harness runs
    Then it reports emergency recall, abstention precision, closed-intent accuracy, calibration, latency p50, and the three chat gates
    And the results are stored as release evidence with fixture versions and artifact identity

  Scenario: The candidate ships only when every gate is green
    Given a candidate whose gates are all at or above their thresholds
    When the swap is approved
    Then the catalog entry is updated to the candidate (FR-CNR-022)

  Scenario: One existing gate is red (failure)
    Given a candidate with emergency recall below 1.00, or any other existing gate below its threshold
    When the swap is considered
    Then the swap does not ship
    And the threshold is not moved to accommodate the candidate
    And the shortfall is reported to the owner
```

### FR-CNR-022: v17 catalog entry — versioned, reversible, gated, with per-device tier selection

**Area:** Model Delivery / Catalog Swap · **Priority:** MUST
**Source:** Proposal §4 ("Same single-decode shape (schema unchanged) → no chain/router surgery, catalog swap only"), §5 and §7 ("latency → 1.7B target, 4B only via the per-device resolver"); feature constitution "Single-decode integrity and catalog swap" properties 2–4 ("v17 is the SAME single-decode model family behind a NEW `ModelCatalog` entry — a versioned, reversible swap with a rollback path"; "Device tiers: Qwen3-1.7B is the device default; 4B only via the per-device resolver; prefer the `qwen4BNepali` extended-tokenizer base"; "Training runs on the training box … the app change is the catalog entry plus the swap discipline"); workflow scope comment. Surface: `Services/ModelStore/ModelCatalog.swift` (new chat-variant entry; `qwen4BNepali` :237), `AppCoordinator.defaultBrainModelID`.

The v17 model **must** reach devices as a **new `ModelCatalog` entry** — a versioned, reversible swap — and never as an in-place replacement of the shipped entry:

- **New entry, same family**: the chat variant is the same single-decode model family behind a new catalog identifier, so the swap is a catalog change with no chain/router surgery (FR-CNR-013).
- **Versioned and reversible**: the previous entry stays addressable for rollback, and rolling back is a catalog-level operation that does not require a code change or a re-run of the gates. The DV protocol (FR-CNR-025) exercises the swap and the rollback path.
- **Gated**: the entry becomes the default only after the full harness is green (FR-CNR-021) with the provenance manifest attached (FR-CNR-018). A gated entry may exist in the catalog without being the default.
- **Tier selection**: Qwen3-1.7B is the device default; the 4B variant is admitted only through the per-device resolver (P2, FR-CNR-028), and the Nepali extended-tokenizer base is preferred because fewer tokens per Nepali sentence leave budget inside the 1,024-token ceiling.
- **A/B on the reference device** rides the catalog pick (FR-CNR-025), so the shipped default is decided by device evidence, not by intent alone.

```gherkin
Feature: The v17 model ships as a gated, reversible catalog swap

  Scenario: v17 is reachable as its own catalog entry
    Given the shipped feature build
    When the catalog is inspected
    Then a distinct entry for the v17 chat variant exists alongside the previous entry
    And selecting it changes the served model without any chain or router change

  Scenario: The swap is reversible
    Given a device running the v17 entry
    When the catalog pick is rolled back to the previous entry
    Then the device serves the previous model again
    And no code change or gate re-run is required to complete the rollback

  Scenario: The default is set only after the gates are green
    Given a v17 artifact with the full harness green and the provenance manifest attached
    When the catalog default is updated
    Then the change is recorded with the gate evidence
    And an artifact without green gates never becomes the default

  Scenario: A failing artifact is promoted (failure)
    Given a v17 artifact with any red gate or an incomplete provenance manifest
    When the catalog is inspected
    Then the artifact is not the default
    And its promotion is reported as a release-gate violation
```

### FR-CNR-023: Chat prompt/template discipline — seed byte-mirror, intent prompt untouched, no few-shot exemplars

**Area:** Prompt Discipline / Seed Mirror · **Priority:** MUST
**Source:** Proposal §4 ("**Style via data, not prompt tokens**: no few-shot exemplars in the device prompt (they eat the 1,024 budget) … Add `seeds/chat_prompt_template.txt` byte-mirrored to `IntentPrompt.buildChat`, same discipline as the intent prompt"); feature constitution "Prompt/seed discipline" 1–3 and "Persona seams and Gemini chat temperature" property 2, "Out of scope (must not change)" ("Few-shot exemplars in the on-device prompt — style travels via data, not prompt tokens"); workflow `security-design-review` / `security-test` focus ("seeds/chat_prompt_template.txt byte-mirrors IntentPrompt.buildChat"). Surfaces: `tools/train-intent/seeds/` (`prompt_template.txt` existing, `chat_prompt_template.txt` new), `IntentPrompt.buildChat` (:197-211), `IntentPromptTests` (1,024-token ceiling and the intent-prompt pin).

The chat prompt template **must** be governed by the same seed-mirror discipline the intent prompt uses:

- **Byte-mirror, same change.** `tools/train-intent/seeds/chat_prompt_template.txt` byte-mirrors the text produced by `IntentPrompt.buildChat`; any `buildChat` edit lands together with its seed update in the same change. Never a mirror "to be refreshed later".
- **The pinned intent prompt stays byte-identical.** `IntentPrompt.build`'s text, its `seeds/prompt_template.txt` mirror and the `IntentPromptTests` pin are untouched by this feature; the chat template is a separate artifact.
- **Within the pinned token budget.** The chat template (persona + template + turn) stays within the 1,024-token on-device ceiling enforced by `IntentPromptTests`; the persona upgrade (FR-CNR-002) is kept short precisely to respect this.
- **No few-shot exemplars in the device prompt.** The conversational register is demonstrated by the training corpus, not by prompt tokens — adding exemplar turns to the prompt is a defect against this requirement (and against the token budget).
- **The template change is verifiable**: the mirror check is mechanical (byte comparison), so a drift between code and seed is detectable in the test suite rather than by review.

```gherkin
Feature: The chat template and its seed mirror stay in lockstep

  Scenario: The seed mirrors the code
    Given the shipped feature build
    When tools/train-intent/seeds/chat_prompt_template.txt is compared with the text IntentPrompt.buildChat produces
    Then they are byte-identical

  Scenario: A buildChat edit carries its seed update in the same change
    Given a change that edits IntentPrompt.buildChat
    When the change set is reviewed
    Then chat_prompt_template.txt is updated in the same commit
    And the template remains within the pinned 1,024-token budget

  Scenario: The intent prompt and its pin are untouched
    Given the pre-change intent prompt, its seed mirror and the IntentPromptTests pin
    When the feature's change set is inspected
    Then all three are byte-identical to their pre-change content

  Scenario: Exemplars are injected into the device prompt (failure)
    Given a chat prompt containing few-shot exemplar turns
    When the prompt is inspected
    Then the injection is reported as a defect
    And it is removed before ship (style travels via data, not prompt tokens)
```

### FR-CNR-024: Feasibility honesty — every leg reported explicitly, no silent drop

**Area:** Delivery / Feasibility Reporting · **Priority:** MUST
**Source:** Feature constitution Runtime Contract "Chat decode (P0)" property 4 ("**Feasibility honesty.** If fixed-seed temp ~0.3 does not hold reproducibly on any device tier (GBNF interplay, Metal backends), the design records it explicitly for the owner — no silent drop (workflow, design-l1)"); feature constitution OD-1 (the same clause repeated for the design decision) and Open Decisions preamble; workflow design-l1 task comment ("if any leg is not feasible … the design records it explicitly for the owner — no silent drop"); project constitution Agent Principles ("No silent stubs — deferred work throws explicit errors, never silently returns success"); the owner's standing request to be told when something is not feasible.

If any leg of this feature proves infeasible or only partially feasible, the deliverable **must** state it explicitly for the owner — the affected leg, the evidence, the narrower behaviour that ships instead, and what the user experience loses — rather than silently narrowing, deferring or dropping it. Named legs that must be reported honestly if they do not hold:

- **Chat sampling feasibility**: fixed-seed temperature ~0.3 reproducible on every supported device tier, including any GBNF interplay and Metal-backend effects (FR-CNR-003).
- **Grammar-guard coverage**: whether the deterministic checks catch the violations the spec names, and where they cannot (the guard verifies; where it cannot verify, that gap is reported).
- **Cloud chat routing**: whether consent + indicator + revocation work as specified on device, including the escalation path (FR-CNR-009).
- **Training outcome**: whether the corpus and gates reach their thresholds, and if not, what the measured shortfall is (FR-CNR-020/021).
- **4B tier admission**: whether a device tier can serve the larger variant within the latency/memory envelope (FR-CNR-028).
- **Any P0→P1→P2 sequencing deviation**: the owner's directive puts the full scope in this run, P0 first; a deviation from that ordering is reported, not assumed (feature OD-3).

The report is part of the final sign-off package, and a "not feasible" statement is an acceptable outcome — a silent drop is not.

```gherkin
Feature: Infeasibility is reported, never absorbed

  Scenario: A leg is feasible and ships as specified
    Given a leg that meets its requirement on the reference device
    When the sign-off package is assembled
    Then the leg is reported as delivered with its evidence

  Scenario: A leg is only partially feasible
    Given a leg that cannot hold as specified (e.g. temperature ~0.3 does not reproduce on a tier)
    When the deliverable is reported
    Then the limitation is stated explicitly for the owner
    And the narrower behaviour that ships is described along with what the user loses
    And no requirement is silently narrowed

  Scenario: A leg is dropped without a statement (failure)
    Given a shipped build in which a specified leg is absent, narrowed or deferred
    When the sign-off package is reviewed
    Then the absence is reported as a defect against this requirement
    And the owner statement is produced before sign-off completes
```

### FR-CNR-025: DV-1 … DV-6 device validation on Anzaan — the recorded completion gate

**Area:** Validation / Completion Gate · **Priority:** MUST
**Source:** Proposal §6 ("**Device**: A/B on Anzaan behind the catalog pick; listening panel with actual elderly users (they are the judges of 'human-like'); DV-style protocol with honorific-mismatch telemetry"); feature constitution "Success Criteria & Completion Gate" (the DV-1..DV-6 list and the release gate) and Safety & Compliance Delta 7; workflow `final-sign-off` task comment (the DV list is repeated there and `final-sign-off` is T2 + HIL). Reference device: Anzaan.

The feature is **not complete** until the DV protocol has been executed on the reference device (Anzaan) and its results are recorded with the feature spec at final sign-off. Each item **must** be recorded with its outcome, and a failed item blocks completion:

- **DV-1 — local chat quality**: warm, grammatical replies from the shipped tier (honorific agreement, particles within budget, no AI-isms) — the elderly-user-facing quality claim measured on device.
- **DV-2 — cloud-first chat**: consent + plain-language disclosure + visible indicator work; toggling off (revocation) returns to the on-device brain without losing chat.
- **DV-3 — offline/honest degradation**: with no cloud available, chat degrades honestly to the local brain — no crash, no false success, no dropped turn.
- **DV-4 — emergency phrasing recall on device**: emergency phrasing still triggers exactly; recall is untouched by the chat work (the gate form is 1.00, FR-CNR-014/021).
- **DV-5 — command determinism unchanged**: temp-0 behaviours (e.g. reminders/alarms) are unchanged on device (FR-CNR-004).
- **DV-6 — elderly listening panel A/B verdict recorded**: real elderly listeners judge the A/B behind the catalog pick; their verdict is the "human-like" authority and is recorded, whatever it says.
- **Release gate**: `ios/tools/check-release-log-safety.sh` exits 0 covering the new chat/routing/guard paths (NFR-CNR-006), and the pre-release device console check covers the same paths.
- **Honorific-mismatch telemetry** is captured during the DV session (classification only) so on-device performance is observable after ship.

```gherkin
Feature: DV-1..DV-6 executed on the reference device and recorded

  Scenario: Each DV item is executed and recorded
    Given the feature build installed on Anzaan
    When the DV protocol is run
    Then each of DV-1..DV-6 is executed against its stated criterion
    And each result is recorded with the feature spec at final sign-off

  Scenario: The listening panel's verdict is recorded
    Given an A/B comparison behind the catalog pick
    When the elderly listening panel gives its verdict
    Then the verdict is recorded verbatim
    And it is not summarised into a claim the panel did not make

  Scenario: A DV item fails or is skipped (failure)
    Given a DV item that failed or was not executed
    When final sign-off is prepared
    Then completion is withheld
    And the failure or omission is stated explicitly for the owner (FR-CNR-024)
```

### FR-CNR-026: P2 polish — DPO on judge preferences

**Area:** P2 Polish / Preference Tuning · **Priority:** SHOULD
**Source:** Proposal §7 phasing table ("**P2** — polish | DPO on judge preferences, romanized-Nepali chat, 4B tier, consent-based real transcripts | after P1") and §6 (the LLM-judge rubric over naturalness/grammar/warmth/brevity); feature constitution "In scope" P2 bullet; workflow scope comment P2 bullet.

After P1 lands (corpus, v17 run, gates green, catalog swap — FR-CNR-016 … FR-CNR-022), the feature **should** add a **DPO (direct preference optimisation) stage on judge preferences** to push the reply style further toward what the judge rubric rewards. Binding properties:

- **Preference data comes from the existing judge**: pairs are constructed from judged responses (naturalness, grammar, warmth, brevity) so the optimisation target is the same rubric the gates measure — no new, unmeasured aesthetic.
- **P1 remains the floor**: the DPO variant is a *new catalog candidate*, not an in-place mutation of the P1 artifact — versioned and reversible exactly as FR-CNR-022 requires, and gated by the same full harness.
- **All gates still bind**, including emergency recall 1.00 (FR-CNR-021): a preference-tuned model that regresses any safety gate does not ship.
- **Sequencing**: P2 work starts only after P1's swap is live and the DV protocol has run; it does not delay P0 or P1, and if P1's quality already satisfies the owner, this stage may be descoped by the owner explicitly (never silently).

```gherkin
Feature: A preference-tuned candidate, gated like P1

  Scenario: Preference pairs derive from the judge rubric
    Given the P2 DPO stage
    When its preference data is inspected
    Then the pairs are built from judged responses scored on naturalness, grammar, warmth and brevity
    And no unmeasured aesthetic objective is introduced

  Scenario: The preference-tuned candidate is gated as a new artifact
    Given a DPO candidate produced after P1
    When it is considered for the catalog
    Then it enters as a versioned, reversible candidate (FR-CNR-022)
    And the full harness (FR-CNR-021) is run before it can become the default

  Scenario: DPO regresses a safety gate (failure)
    Given a DPO candidate whose emergency recall, abstention, closed-intent, calibration or latency gate is red
    When the swap is considered
    Then it does not ship
    And the candidate is recorded as rejected with the failing gate
```

### FR-CNR-027: P2 polish — romanized-Nepali chat

**Area:** P2 Polish / Romanized Input · **Priority:** COULD
**Source:** Proposal §7 phasing table ("**P2** — polish | DPO on judge preferences, romanized-Nepali chat, 4B tier, consent-based real transcripts | after P1"); feature constitution "In scope" P2 bullet; workflow scope comment P2 bullet. Related project context: the STT transcript is predominantly Devanagari, and romanized forms appear in real Nepali usage (the family-contacts-unify precedent is explicit that romanized and Devanagari spellings are distinct unless both are stored).

After P1, the feature **may** extend conversational handling to **romanized-Nepali chat** — user turns written or transcribed in Latin script (e.g. "khana khayau?") — so those turns receive a warm, grammatical reply in the same register rather than an abstention or an off-register answer. Binding properties:

- **Additive, never a regression to Devanagari**: the existing Devanagari behaviour, all style rules and all gates are unchanged; romanized handling ships only if the full harness stays green (FR-CNR-021).
- **No script bridging in the reply contract**: the reply's script follows the spec and the user's register; this requirement does not introduce automatic transliteration semantics into other surfaces (matching/dialling rules elsewhere are unaffected — this feature does not re-open them).
- **Scope honesty**: if romanized chat proves infeasible or unreliable within the envelope, it is reported as not delivered rather than shipped half-working (FR-CNR-024).
- **Sequencing**: after P1 (and independent of FR-CNR-026/FR-CNR-028); it may be descoped by the owner explicitly.

```gherkin
Feature: Romanized-Nepali chat turns are handled

  Scenario: A romanized chat turn receives an in-register reply
    Given a P2 build with romanized chat enabled
    When a romanized-Nepali chat turn is spoken
    Then the turn is answered (not abstained) in the style spec's register
    And the reply respects the honorific, particle-budget and no-AI-ism rules

  Scenario: Devanagari behaviour is unchanged
    Given the pre-change behaviour on Devanagari chat turns
    When the P2 build handles the same turns
    Then their behaviour and gate results are unchanged

  Scenario: Romanized handling cannot be delivered reliably (failure)
    Given an evaluation in which romanized turns are answered incorrectly or off-register
    When the P2 deliverable is reported
    Then the shortfall is stated explicitly for the owner
    And the partial capability is not shipped as if complete
```

### FR-CNR-028: P2 polish — the 4B chat tier, admitted only through the per-device resolver

**Area:** P2 Polish / Device Tiers · **Priority:** COULD
**Source:** Proposal §4 ("Base: Qwen3-1.7B (device default, 5–8 s/turn) and Qwen3-4B for newer devices; prefer the Nepali extended-tokenizer base (`qwen4BNepali` …) — fewer tokens per Nepali sentence leaves budget inside the 1,024-token ceiling") and §7 phasing table ("P2 — polish | … 4B tier …") and risks ("latency → 1.7B target, 4B only via the per-device resolver"); feature constitution "Single-decode integrity and catalog swap" property 3 and Success Criteria ("The v17 catalog swap is live behind the per-device resolver, versioned and reversible"); workflow scope comment.

After P1 ships the 1.7B chat variant as the device default, the feature **may** admit a **4B chat variant** for newer device tiers — but only through the **per-device resolver**, never as a global default. Binding properties:

- **The 1.7B tier stays the default**; the 4B variant is opted into by the resolver based on the device's measured capability, exactly as the existing brain selection works.
- **Residency is single-model**: the resolver serves exactly one tier at a time on a device (no both-models-resident configuration), preserving the memory/jetsam requirement (NFR-CNR-003).
- **The envelope binds**: a tier is admitted only if it stays within the listening-turn latency envelope (NFR-CNR-002) and the memory/jetsam requirement on that tier; a tier that misses the envelope is not admitted, even if newer devices *can* load it.
- **Gated like every other artifact**: the 4B variant is a versioned, reversible catalog candidate behind the full harness (FR-CNR-021, FR-CNR-022) with its own gate evidence; the extended-tokenizer base is preferred (FR-CNR-022).
- **If a tier cannot be admitted, that is reported** (FR-CNR-024), not silently shipped with worse behaviour.

```gherkin
Feature: The 4B tier is resolver-gated, never a global default

  Scenario: A capable device receives the 4B tier through the resolver
    Given a device tier the resolver classes as capable of the 4B variant
    When the brain model is resolved
    Then the 4B chat variant is served on that device
    And it stays within the latency and memory envelope

  Scenario: The default tier remains the 1.7B variant
    Given a device that the resolver does not class as 4B-capable
    When the brain model is resolved
    Then the 1.7B chat variant is served
    And no device is forced onto the larger variant

  Scenario: A tier misses its envelope (failure)
    Given a device tier on which the 4B variant exceeds the latency or memory requirement
    When admission is considered
    Then the tier is not admitted
    And the shortfall is reported rather than shipped with degraded behaviour
```

### FR-CNR-029: P2 polish — consent-based real conversation transcripts as the gold source

**Area:** P2 Polish / Own-Data Corpus · **Priority:** COULD
**Source:** Proposal §3 ("**Bonus gold source**: consent-based transcripts of real Anzaan conversations (not public, but the exact target register) — the long-term ideal once you have opt-in"); feature constitution "Data provenance — binding" (own data is a ship-safe source class) and "In scope" P2 bullet; workflow scope comment P2 bullet; project constitution Standards Privacy (no personal data leaves the device; consent requirements) and Open Decision 12 (the consent/disclosure pattern for user content).

After P1, the feature **may** use **consent-based transcripts of real user conversations** as the highest-value training source — the exact target register — under a strict consent regime. Binding properties:

- **Explicit, informed, revocable consent** from the person whose conversation it is (the elderly user), and from the family/caregiver side where the project's practice requires it (UAT/test-device sessions at first). Consent is obtained before collection, states the purpose (model training), and can be withdrawn — withdrawal removes that person's transcripts from future mixes.
- **Collection never happens silently**: transcripts are not harvested from the shipped product merely because they exist on the device; the default remains "collected only under the recorded egress/consent surfaces".
- **Provenance and privacy discipline**: transcripts used for training are classified as own data in the manifest (FR-CNR-018); PII is handled per the project's log/PII discipline (NFR-CNR-006) and no transcript content reaches logs or telemetry (FR-CNR-007, NFR-CNR-007).
- **Gated like every other data change**: a model trained with real transcripts is a new catalog candidate behind the full harness (FR-CNR-021) and a new provenance manifest entry; the clause "own data" is recorded explicitly for the compliance evidence.
- **If consent cannot be obtained, that is the outcome** — the source is simply not used (FR-CNR-024), never a partially consented mix.

```gherkin
Feature: Real transcripts enter the corpus only with consent

  Scenario: Consented transcripts are used as a corpus source
    Given a participant who gave explicit, informed consent to the training use of their conversation transcripts
    When a corpus mix including those transcripts is built
    Then the source is recorded as own data in the provenance manifest
    And the consent record accompanies the run

  Scenario: Withdrawal removes the source going forward
    Given a participant who withdraws consent
    When subsequent corpus mixes are built
    Then that participant's transcripts are excluded from them
    And the exclusion is recorded in the manifest

  Scenario: Transcripts are used without consent (failure)
    Given a corpus mix containing transcripts for which consent is absent, expired or withdrawn
    When the mix is reviewed
    Then it is rejected as a compliance event
    And no artifact trained on it ships (FR-CNR-018)
```

---

## Non-functional requirements

### NFR-CNR-001: Chat reply reproducibility — fixed seed, same input, same reply

**Category:** Reliability / Determinism · **Priority:** MUST
**Source:** Feature constitution Runtime Contract "Chat decode (P0)" property 2 ("Deterministic and reproducible: same transcript and state → same reply. The gibberish bug was a RANDOM seed; a fixed seed at 0.3 stays fully reproducible") and Safety & Compliance Delta 4 ("Determinism invariants preserved … the NO-GIBBERISH class stays closed"); proposal §5.1 and §7 risks; workflow `security-test` focus ("chat turns are reproducible at fixed-seed temp ~0.3").

Chat decoding **must** be reproducible at the fixed seed. Measurable properties:

- **Repeat-run identity**: for the same transcript and the same assistant state on the same device tier and build, repeated chat decodes produce **byte-identical** replies — 100% of trials (no sampling variance run to run).
- **Seed is fixed and recorded**: the chat decode uses a fixed seed (the project's `OnDeviceSampling.fixedSeed` value, 20_260_907, or a documented fixed value chosen at design time); a random or time-derived seed is a defect.
- **Guard verdicts are reproducible** over the same reply (100% identical verdicts across repeats) — FR-CNR-005's idempotence in measurable form.
- **Cross-session stability**: the same turn in a fresh session with the same state yields the same reply; reproducibility is not an artefact of an in-process cache.
- **The cloud path is deterministic in configuration**: the cloud chat request carries its fixed, recorded sampling configuration (FR-CNR-011) so a repeat request is issued under identical parameters.

```gherkin
Feature: Reproducible chat replies

  Scenario: Repeated local chat decodes are byte-identical
    Given a fixed transcript and assistant state
    When the same chat turn is decoded 20 times on the same device tier and build
    Then every resulting reply is byte-identical
    And no run differs from another

  Scenario: Reproducibility holds across sessions
    Given the same transcript and state in a fresh app session
    When the chat turn is decoded
    Then the reply matches the earlier session's reply

  Scenario: A non-fixed seed is introduced (failure)
    Given a chat decode configuration whose seed is random, time-derived or unrecorded
    When the configuration is inspected
    Then it is reported as a NO-GIBBERISH-class defect
    And the chat path does not ship in that state
```

### NFR-CNR-002: Listening-turn latency envelope — chat replies stay within the spoken-conversation budget

**Category:** Performance · **Priority:** MUST
**Source:** Proposal §4 ("Base: Qwen3-1.7B (device default, **5–8 s/turn**)") and §6 ("**Non-negotiable regressions** … latency p50 ≤1.0 s") and §7 risks ("latency → 1.7B target, 4B only via the per-device resolver"); feature constitution "Mixture and gate harness" property 2 (the latency gate is part of the non-negotiable regression set); workflow scope comment. Measurement surface: the existing latency evaluation in the gate harness plus the DV session on the reference device.

Chat replies **must** arrive inside a spoken-conversation envelope, and the existing latency gate **must** stay green. Measurable properties:

- **On-device chat turn**: for the 1.7B device default, the interval from end of the user's utterance to the start of the spoken reply has **p50 within 5–8 s** on the reference device tier (the proposal's measured envelope for this tier), measured over the DV session (FR-CNR-025).
- **Existing latency gate unchanged**: the suite's latency gate **p50 ≤1.0 s** (the intent/command path measurement) remains at or below its threshold after the change (FR-CNR-021).
- **Cloud path does not add a worse tail**: when the cloud chat path is used, a degraded-to-local fallback (FR-CNR-008) does not push the turn beyond the local envelope by more than the cloud attempt's own timeout budget; the fallback decision is bounded, so a chat turn is never left waiting indefinitely.
- **No envelope exploitation by tier**: a larger tier (4B, FR-CNR-028) is admitted only if it holds the same envelope on that device.

```gherkin
Feature: Chat latency stays inside the spoken-conversation envelope

  Scenario: Local chat turns meet the 1.7B envelope
    Given the 1.7B chat variant on the reference device tier
    When chat turns are exercised during the DV session
    Then the end-of-utterance to start-of-reply interval has p50 within 5–8 s
    And the result is recorded with the DV evidence

  Scenario: The existing latency gate remains green
    Given the post-change gate run
    When the latency gate is evaluated
    Then its p50 is ≤1.0 s
    And it is not traded against the chat work

  Scenario: A cloud attempt stalls the turn (failure)
    Given a cloud chat attempt that fails or times out
    When the turn degrades to the local brain
    Then the turn completes with the reply started within the local envelope plus the bounded attempt budget
    And no chat turn is left waiting without a reply
```

### NFR-CNR-003: Memory and jetsam behaviour — one brain resident, zero feature-attributable terminations

**Category:** Reliability / Resource Behaviour · **Priority:** MUST
**Source:** Proposal §4 (the 1.7B default and the 4B-for-newer-devices tiering; "fewer tokens per Nepali sentence leaves budget inside the 1,024-token ceiling") and §7 risks (latency/memory mitigation: 1.7B target, 4B only via the resolver); feature constitution "Single-decode integrity and catalog swap" property 3 (device tiers) and "Prompt/seed discipline" property 2 (the pinned 1,024-token on-device budget); project constitution Architecture Constraint 4 (24/7 safety service — the assistant must remain reliably available) and Safety-critical constraints (the emergency path must not be blocked by the LLM being busy or unavailable). Reference device: Anzaan.

The feature **must not** increase model residency or provoke system terminations on any supported device tier. The requirements are counted, not estimated:

- **Exactly one brain model resident at a time** on a device — the chat variant replaces the served model in the swap (FR-CNR-022); the feature introduces **no second resident model**, no additional model instance for chat, and no dual-tier configuration.
- **Zero feature-attributable jetsam terminations**: during the DV session (FR-CNR-025), which exercises local chat, cloud chat, degradation, emergency phrasing and commands, the app records **0** terminations in which the feature's chat path is the memory driver.
- **No growth in the decode working set**: the chat path's context stays within the existing pinned budget (NFR-CNR-004) and adds no additional KV/context allocation beyond what the existing single-decode chat turn already uses.
- **Tier admission is memory-gated**: the larger tier (FR-CNR-028) is admitted only on a device class where the resident footprint holds without reaching the jetsam threshold; a tier that cannot hold it is not admitted.
- **Degradation under pressure is honest**: if memory pressure does occur, the chat path degrades (local or safe template) rather than terminating the app or a safety-critical flow (the emergency path is never blocked — FR-CNR-014).

```gherkin
Feature: Memory residency and jetsam behaviour are counted and clean

  Scenario: One brain model is resident during a chat session
    Given a device running the shipped chat variant
    When a chat session is exercised
    Then exactly one brain model instance is resident
    And no second chat model is loaded

  Scenario: The DV session records no feature-attributable termination
    Given the DV session on the reference device (local chat, cloud chat, degradation, emergency phrasing, commands)
    When the session is reviewed
    Then the app recorded 0 terminations attributable to the chat path's memory use

  Scenario: A tier exceeds the memory envelope (failure)
    Given a device class where the candidate tier's resident footprint reaches the terminations threshold
    When tier admission is considered
    Then the tier is not admitted
    And the limitation is recorded (FR-CNR-024)
```

### NFR-CNR-004: Chat prompt token budget — the 1,024-token ceiling holds

**Category:** Performance / Resource Budget · **Priority:** MUST
**Source:** Proposal §4 ("no few-shot exemplars in the device prompt (they eat the **1,024 budget**)"); feature constitution "Prompt/seed discipline" property 2 ("The chat template stays within the pinned 1,024-token on-device budget (`IntentPromptTests`' ceiling)") and "Model & Training Contract" property 3 (extended-tokenizer base leaves "budget inside the 1,024-token ceiling"); workflow `security-design-review` focus ("chat templates stay within the 1,024-token budget").

The on-device chat prompt **must** stay within the pinned 1,024-token budget enforced by `IntentPromptTests`. Measurable properties:

- **Ceiling**: the fully assembled chat prompt (system persona + template + the turn being answered) tokenises to **≤1,024 tokens**; the existing ceiling test remains green and now covers the upgraded chat template.
- **No exemplar inflation**: **0** few-shot exemplar turns are present in the device chat prompt (style travels via data — FR-CNR-023); the persona upgrade is kept short enough that the rules fit without pushing the assembly over the ceiling.
- **Headroom is not silently consumed**: the persona/rule additions (FR-CNR-002) are within budget, and any requirement to exceed the ceiling is reported as a design-level conflict rather than satisfied by truncating user context (a truncated turn degrades intent quality on the safety-critical model).
- **Cloud prompt does not substitute**: exceeding the local ceiling is not "solved" by routing more turns to the cloud — the local path must be able to answer within budget offline (FR-CNR-008, DV-3).

```gherkin
Feature: The chat prompt stays inside the 1,024-token ceiling

  Scenario: The assembled chat prompt fits the ceiling
    Given the upgraded chat persona, the chat template and a representative turn
    When the prompt is tokenised by the suite's budget test
    Then the total is ≤1,024 tokens
    And the test stays green

  Scenario: No exemplar turns inflate the prompt
    Given the shipped device chat prompt
    When it is inspected
    Then it contains 0 few-shot exemplar turns

  Scenario: The budget is exceeded (failure)
    Given a build whose assembled chat prompt exceeds 1,024 tokens
    When the budget test runs
    Then the build fails the gate
    And the conflict is resolved in the persona/rules or reported as a design issue
    And user context is not silently truncated to make the fit
```

### NFR-CNR-005: Prompt-template byte-mirror discipline — seed and code cannot drift

**Category:** Reliability / Build Discipline · **Priority:** MUST
**Source:** Proposal §4 ("Add `seeds/chat_prompt_template.txt` byte-mirrored to `IntentPrompt.buildChat`, same discipline as the intent prompt"); feature constitution "Prompt/seed discipline" property 1 ("the mirror lands in the SAME change as any `buildChat` edit") and "Nepali Conversation Style-Spec Contract" property 1 (the style spec follows "the byte-pinned `seeds/prompt_template.txt` discipline"); workflow `security-design-review` / `security-test` focus ("the seed mirror is byte-identical"); project precedent: the pinned, byte-mirrored intent prompt guarded by `IntentPromptTests`.

The prompt artifacts **must** be mechanically locked so no drift can ship. Measurable properties:

- **Byte-identical mirror**: `tools/train-intent/seeds/chat_prompt_template.txt` is **byte-identical** (sha256 equal) to the chat template text produced by `IntentPrompt.buildChat` at every revision that ships.
- **Same-change rule**: a revision that edits `IntentPrompt.buildChat` without updating the mirror in the same change fails the check — a mismatch count of **0** is required, verified mechanically rather than by review.
- **The intent prompt is untouched**: `IntentPrompt.build`'s text and its `seeds/prompt_template.txt` mirror are byte-identical to their pre-change content (sha256 equal), and the existing pin test remains green.
- **The style spec's discipline is equivalent**: the new `seeds/nepali-chat-style-spec` (FR-CNR-001) is a single-source artifact with the same no-fork property — its consumers derive from it rather than holding copies (verifiable as "no consumer contains an independently authored rule text").

```gherkin
Feature: Prompt artifacts are byte-locked to their sources

  Scenario: The chat seed mirrors the code byte-for-byte
    Given a shipped revision
    When tools/train-intent/seeds/chat_prompt_template.txt is hashed and compared with the text IntentPrompt.buildChat produces
    Then the two hashes are equal

  Scenario: The locked intent prompt is unchanged
    Given the pre-change intent prompt text and its seed mirror
    When the post-change artifacts are hashed
    Then both hashes equal their pre-change values
    And the intent-prompt pin test stays green

  Scenario: A template edit ships without its seed update (failure)
    Given a revision that edits IntentPrompt.buildChat and leaves the seed mirror stale
    When the check runs
    Then the revision fails with an explicit mismatch
    And the change cannot land in that state
```

### NFR-CNR-006: Log safety — no conversation content, transcript or key material in any log

**Category:** Privacy / Security · **Priority:** MUST
**Source:** Feature constitution "Cloud-first chat routing toggle (P0)" property 4 and Safety & Compliance Delta 5; project constitution Standards ("Logs must not contain PII (names, health values, contacts). Log sanitiser required") and Release gates ("**Release-build log-surface gate.** `ios/tools/check-release-log-safety.sh` must pass … It is a build-blocking gate, not a report"; "**Pre-release device check.** … confirm that no transcript content, key material, or raw upstream body appears in the device console or in a sysdiagnose capture"); B2/T-050 precedent; feature constitution "Success Criteria & Completion Gate" (release gate); workflow `security-test` focus.

No conversation content **must** reach any log surface beyond the existing transcript policy. Measurable properties:

- **Zero occurrences**: in a Release build exercising the new paths — local chat decode, the grammar guard (pass and flag), the escalation attempt, cloud chat routing (success, failure, timeout), consent/revocation handling, and the offline fallback — the console/log output contains **0** occurrences of conversation content: user utterance text, reply text, transcript text, system-persona diagnostics, prompt dumps, request/response bodies, or provider key material.
- **Classification-only observability**: the new paths may emit event kinds, outcomes, reason codes, counters, the failed-check class (FR-CNR-007) and routing decisions — never content. Error paths record a reason code, never the payload or upstream body.
- **Build-blocking release gate**: `ios/tools/check-release-log-safety.sh` **exits 0** and its rule coverage/RED-baseline includes the new chat/routing/guard source paths; because it is wired into `ios/build.sh` ahead of every test scope, no gate runs with a re-introduced raw print.
- **Device console check**: the pre-release check on a real device confirms the same for the new paths (console and sysdiagnose capture).
- **No regression** of the existing B1/B2 disciplines in any touched file.

```gherkin
Feature: Log safety across the chat, guard and routing paths

  Scenario: A Release exercise of the new paths logs no content
    Given a Release build
    When local chat, a guard flag, an escalation, a cloud chat success and failure, and an offline fallback are exercised
    Then no utterance text, reply text, transcript text, request/response body or key material appears in the console or logs
    And only classification-level records are emitted

  Scenario: The release log-surface gate covers the new paths and exits 0
    Given the feature's chat/routing/guard source paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And its coverage includes those paths

  Scenario: An error path leaks the payload (failure)
    Given a cloud chat failure, a guard failure or a router fallback
    When the error is recorded
    Then only a reason classification is written
    And no conversation content, transcript text or key material reaches any log
```

### NFR-CNR-007: Telemetry content hygiene — every new event carries classification only

**Category:** Privacy · **Priority:** MUST
**Source:** Feature constitution "Grammar guard (P0)" property 4 ("a `reply_grammar_flag` event carrying NO user content (no transcript, no reply text) — observability-bus policy (PII-free), log discipline per B2/T-050"); project constitution Standards Privacy ("No personal data (voice, health, contacts, conversations) transmitted to cloud for AI processing, except under the recorded exceptions"); project constitution Open Decision 12 (visible indicator, revocable, no content beyond scope); workflow `security-design-review` focus (the flag event carries no user content).

Every telemetry/observability event introduced by this feature **must** carry classification fields only. Measurable properties:

- **Content field count = 0** for each new event: `reply_grammar_flag` (FR-CNR-007), the cloud-chat routing/consent decisions (granted, declined, revoked, active indicator state), the degradation/fallback outcome, and any DPO/training-run event. Forbidden: utterance text, reply text, transcript text, user identity, health values, contacts, profile content, provider key material.
- **Permitted fields only**: event kind, path (on-device/cloud), failed-check class, outcome enum, counters, reason codes, timestamps, model/catalog identifiers.
- **Egress discipline**: events travel on the existing observability channel and are not a new egress surface for user content; nothing in the telemetry payload can reconstruct the conversation.
- **Reviewable schema**: the event schemas are fixed at security design; adding a content-bearing field is a defect (a schema change, not a configuration change) and is caught by the same review that covers NFR-CNR-006.
- **Consistency with the consent exception**: the telemetry does not widen the consent grant — the consent covers cloud chat content, not content in telemetry.

```gherkin
Feature: New telemetry events are content-free

  Scenario: Each new event schema is classification-only
    Given the event schemas introduced by this feature
    When each is inspected field by field
    Then every field is a classification, counter, identifier or reason code
    And no field can carry utterance text, reply text, transcript text or identity

  Scenario: Events emitted during a Release exercise contain no content
    Given a Release build exercising chat, guard flags, consent changes and fallbacks
    When the emitted events are inspected
    Then none contains conversation content or key material
    And the payloads cannot reconstruct a conversation

  Scenario: A content-bearing field is added (failure)
    Given a telemetry schema change that adds a content field
    When the change is reviewed
    Then it is rejected as a defect against this requirement
    And the field is removed before ship
```

### NFR-CNR-008: Gate thresholds — the measurable ship conditions for the v17 swap

**Category:** Quality / Evaluation Gates · **Priority:** MUST
**Source:** Proposal §6 ("New gates: honorific-agreement pass ≥0.98, no-AI-ism ≥0.98, LLM-judge … mean ≥4/5 … **Non-negotiable regressions**: closed-intent ≥0.95, **emergency recall 1.00**, abstention precision ≥0.90, calibration ±0.10, latency p50 ≤1.0 s"); feature constitution "Mixture and gate harness" property 2 (the gate list and "harness output is release evidence") and property 3 ("A red gate is a stop, not a threshold to move"); workflow `define-requirements` scope comment. Surface: `tools/train-intent/eval/` harness + `eval/chat_golden.jsonl` (FR-CNR-019).

The v17 swap is governed by fixed numeric thresholds. All thresholds are **ship conditions**; each result is recorded with its fixture version, judge configuration and artifact identity:

| Gate | Metric | Threshold | Scope |
|---|---|---|---|
| Honorific agreement | pass rate over `chat_golden.jsonl` | **≥0.98** | new (chat) |
| No AI-isms | pass rate over `chat_golden.jsonl` | **≥0.98** | new (chat) |
| LLM-judge quality | mean over naturalness / grammar / warmth / brevity | **≥4/5** | new (chat) |
| Emergency recall | recall on the emergency suite | **1.00** | regression (non-negotiable) |
| Abstention precision | precision on the abstention set | **≥0.90** | regression |
| Closed-intent accuracy | accuracy on the closed-intent set | **≥0.95** | regression |
| Calibration | expected-vs-observed error | **±0.10** | regression |
| Latency | p50 | **≤1.0 s** | regression |

Measurable properties: every threshold is reported as a number with its denominator and fixture version; a result exactly at the threshold passes, below it fails; the metrics are computed by the existing harness extended with the three chat gates (no parallel scoring implementation); a threshold is changed only by an explicit, recorded owner decision.

```gherkin
Feature: The gate thresholds are fixed, measured and reported

  Scenario: The harness reports every gate with its threshold
    Given a candidate v17 artifact and the fixture set
    When the gate harness runs
    Then it reports all eight metrics with their denominators and the fixture versions used
    And each is compared against the threshold in this requirement

  Scenario: A candidate meets every threshold
    Given the reported results
    When all values are at or above their thresholds
    Then the candidate is gate-green
    And the evidence bundle is stored with the run

  Scenario: A threshold is missed (failure)
    Given any metric below its threshold
    When the swap is considered
    Then the candidate is blocked
    And the threshold is not adjusted to fit the candidate
```

### NFR-CNR-009: Accessibility — voice-first, house touch standards, and no routing reasoning asked of the elderly user

**Category:** Accessibility · **Priority:** MUST
**Source:** Project constitution Standards Accessibility ("Voice-first UI — every function accessible by voice command without requiring any touch"; "Touch UI … must use large tap targets (minimum 44x44 pt iOS …), high-contrast text, and minimum 18pt font size for body text"; "At minimum, support the primary user's configured language for all TTS output") and Compliance constraints ("Permissions must be requested at the point of use with clear plain-language explanation visible to elderly users"); feature constitution "Cloud-first chat routing toggle (P0)" property 2 (plain-language disclosure) and Success Criteria; proposal §6 (the elderly listening panel are the judges of "human-like"). Surfaces: the consent/disclosure surface, the cloud-activity indicator, the toggle/revocation control.

The new user-facing surfaces **must** meet the house accessibility standards, and the elderly user **must** never be asked to reason about routing internals. Measurable properties:

- **Voice-first**: every function on the new surfaces — consenting, revoking, learning whether the cloud is active — is reachable by voice command without requiring touch; no new behaviour is touch-only.
- **House touch standards** on each new/edited screen: tap targets at least **44x44 pt**, body text at least **18 pt**, high-contrast text; the consent/disclosure surface and the indicator obey them.
- **Indicator legibility**: while cloud chat is active, the indicator is rendered in the user's configured language at body size, and it is present for **100%** of cloud-active chat turns in the DV-2 session (FR-CNR-025) — not a one-time toast.
- **No internals asked of the user**: the disclosure and controls speak in plain language about *what happens* (their words go to a service to be answered), never in engineering terms (routing, model tiers, fallback ladders). No screen requires the user to understand the toggle to use chat.
- **Spoken feedback**: TTS output in the user's configured language covers the consent acknowledgement and any state change, so a user who cannot read the screen still knows the cloud path is on or off.
- **Non-punitive revocation**: revoking is a single clear action, and the UI states plainly that chat keeps working — the elderly user is never led to believe turning the cloud off disables the assistant.

```gherkin
Feature: The new surfaces are accessible and free of internals

  Scenario: The consent and revocation path is voice-reachable
    Given a user with no touch interaction
    When they give or revoke cloud chat consent by voice
    Then the state changes and is confirmed by spoken feedback in their configured language
    And no step requires touch

  Scenario: New surfaces meet the house touch standards
    Given the consent/disclosure screen and the cloud-activity indicator
    When their layout is measured
    Then every tap target is at least 44x44 pt
    And body text is at least 18 pt with high contrast

  Scenario: The indicator is present for every cloud-active turn
    Given cloud chat active during the DV-2 session
    When chat turns are exercised
    Then the indicator is shown for 100% of turns in which content goes to the cloud

  Scenario: The UI asks the user to reason about routing (failure)
    Given consent/disclosure copy or controls that describe routing, model tiers or fallback mechanics
    When the copy is reviewed
    Then it is rejected and rewritten in plain language
    And the user is never required to understand the mechanism to keep using chat
```

### NFR-CNR-010: Localisation — every new user-visible string exists in Nepali and English

**Category:** Localisation · **Priority:** MUST
**Source:** Project constitution Standards Accessibility ("Localisation: all UI strings must be externalised for translation. At minimum, support the primary user's configured language for all TTS (text-to-speech) output") and Compliance constraints (plain-language explanation visible to elderly users); feature constitution "Cloud-first chat routing toggle (P0)" property 2 (plain-language disclosure) and Success Criteria ("Online users get grammatical conversational replies via cloud-first chat; consent + visible indicator work"); workflow scope comment.

Every new user-visible string introduced by this feature **must** exist in both Nepali (`ne`) and English (`en`) in the app's string catalogue, and every spoken output **must** be produced in the user's configured language. Measurable properties:

- **String coverage = 100%** for the new surfaces: cloud chat consent request, plain-language disclosure, the cloud-activity indicator and its spoken form, the revocation control and its confirmation, the safe-template fallback replies (FR-CNR-006), and any offline/degradation notice.
- **No hardcoded user-visible string** is added; the existing catalogue-coverage test covers the new keys.
- **Spoken language correctness**: the safe template and any system-spoken notice are spoken in the configured language; a Nepali-configured device never speaks an English-only fallback (and vice versa).
- **The conversational register lives in the model, not in UI strings**: the localised strings here are the system/UX surfaces; the chat reply language is governed by the style spec and data (FR-CNR-001).
- **Copy review**: consistent with the Open Decision 12/13 review clause, the consent/disclosure copy is reviewed before the first App Store submission (NFR-CNR-011 evidence).

```gherkin
Feature: New strings exist in ne and en and are spoken correctly

  Scenario: Every new user-visible string is localised in both languages
    Given the feature's user-visible surfaces (consent, disclosure, indicator, revocation, safe template, degradation notice)
    When the string catalogue is inspected
    Then each string has both a ne and an en value
    And the catalogue-coverage test reports no missing key

  Scenario: Spoken output follows the configured language
    Given a device configured for Nepali
    When a safe template reply or a consent confirmation is spoken
    Then the output is spoken in Nepali
    And no English-only fallback string is spoken

  Scenario: A string ships hardcoded or untranslated (failure)
    Given a build containing a user-visible string that is hardcoded or lacks one of the two languages
    When the coverage check runs
    Then the build is reported as failing this requirement
    And the string is externalised and translated before ship
```

### NFR-CNR-011: Compliance and release gates — workflow gates, the log gate, and honest baseline reporting

**Category:** Compliance · **Priority:** MUST
**Source:** Project constitution Quality ("Confidence threshold for implementation tasks: 0.85 … All paired review enabled"), Release gates (recorded 2026-09-13: release-build log-surface gate; pre-release device check; post-deploy monitoring) and Standards (App Store health/data policies; injection detection at `quarantine`; STRIDE threat model); feature constitution Safety & Compliance Delta 7 ("`security-design-review` (STRIDE required; SECURITY-GO exit), `security-test` (SECURITY-GO exit), paired review + confidence 0.85 on implement, `final-sign-off` at T2 + HIL; release gate `ios/tools/check-release-log-safety.sh` exits 0") and "Success Criteria & Completion Gate"; feature workflow exit conditions.

The feature **must** satisfy the project's workflow and release gates, and its evidence **must** be reported honestly. Measurable properties:

- **Security gates**: `security-design-review` produces a STRIDE threat model covering the new cloud egress, the guard, and the shared safety-critical model, and exits **SECURITY-GO**; `security-test` exits **SECURITY-GO**. A non-GO blocks the feature.
- **Paired review + confidence**: implementation output carries paired agentic review (challenger ≠ driver) and meets the **0.85** confidence threshold; max rework iterations 5.
- **Quality gates**: `review-l2` and `review-implementation` each return **GO**.
- **Release gate**: `ios/tools/check-release-log-safety.sh` **exits 0** (build-blocking, wired into `ios/build.sh`) with the new chat/routing/guard paths in coverage; the pre-release device console/sysdiagnose check covers the same paths and its result is recorded in the release checklist.
- **Completion gate**: `final-sign-off` at **T2 + HIL** records the DV-1..DV-6 results (FR-CNR-025) and the feasibility-honesty statement (FR-CNR-024).
- **Baseline honesty**: the project's known pre-existing test failures are the baseline where the full bundle is run; the feature's own and touched suites (chat sampling, guard, routing/consent, template pin/budget, catalogue coverage) **must pass**, with baseline failures recorded rather than silently included or excluded.
- **Post-deploy monitoring** (project clause, owner: Anjan Poudel) remains defined and owned before first App Store submission; this feature's new telemetry (NFR-CNR-007) is compatible with it.

```gherkin
Feature: Workflow and release gates are satisfied with recorded evidence

  Scenario: The security gates return GO
    Given the design and implementation as proposed
    When security-design-review and security-test run
    Then each returns SECURITY-GO with its evidence
    And a non-GO blocks progression

  Scenario: The release log gate and device check pass
    Given a Release build containing the feature
    When ios/tools/check-release-log-safety.sh runs and the pre-release device check is performed
    Then the gate exits 0 with the new paths in coverage
    And no transcript content, conversation content or key material is observed in the console or a sysdiagnose capture

  Scenario: Scoped suites pass and the baseline is reported honestly
    Given the feature's own and touched test suites and the known baseline failures
    When the scoped run completes
    Then every scoped suite passes
    And any baseline failure is reported as a pre-existing, recorded item rather than blended into or excluded from the result

  Scenario: A gate is skipped or a baseline is hidden (failure)
    Given a feature shipped with a missing GO, an unrun release gate, or an unreported baseline failure
    When final-sign-off evidence is reviewed
    Then completion is withheld
    And the omission is stated explicitly for the owner (FR-CNR-024)
```

---

## Assumptions recorded during this requirements pass

- The integration surfaces exist as named in the feature constitution and the scaffold report; the
  cited file/line anchors were verified as present in the worktree at scaffold time (2026-10-14,
  base master `91deddca`) — `IntentPrompt.buildChat` (:197-211), `LlamaCommandInterpreter`
  `OnDeviceSampling` (:404-417) / handle creation (:1391-1398) / `chatSystemPrompt` (:552-563) /
  `chatJSONSchema` (:350) / `respondToChat` (:709), `GeminiCommandInterpreter.replyPersona`
  (:35-44), `GeminiClient.GenerationConfig` (:659-661), `SpokenReplyPolisher` doctrine (:21-26),
  `LocalBrainChain.respondToChat` (:268-294), `IntentRouter.interpretLocalLadder` (:259-291) /
  `runLocalLadder` (:308-395), `ModelCatalog.qwen4BNepali` (:237), `tools/train-intent/seeds/`
  (`prompt_template.txt` present) and `tools/train-intent/eval/` (`golden_corpus.jsonl`,
  `emergency_nearmiss.jsonl` present), `ios/tools/check-release-log-safety.sh` present and
  executable. Line numbers are orientation, not contracts.
- Design-level choices are deliberately left open and are NOT requirements: the chat temperature
  value and its sampling plumbing (per-turn override vs. a shape-specific handle; feature OD-1);
  the style-spec artifact format and how the four consumers resolve against it (OD-2); the
  particles-budget enforcement mechanics (OD-4); the Gemini chat temperature value (OD-5); the
  exact `ModelCatalog` entry naming/versioning scheme and the resolver's tier criteria (FR-CNR-022,
  FR-CNR-028); the grammar guard's internal check implementation and its thresholds within the
  three named classes (FR-CNR-005); the consent/indicator UX shapes (FR-CNR-009, bounded by
  NFR-CNR-009).
- The 5–8 s/turn figure used as the chat latency envelope (NFR-CNR-002) is the proposal's measured
  value for the Qwen3-1.7B device default; it is recorded as the target band for the reference
  device tier rather than invented. The existing suite gate (latency p50 ≤1.0 s) remains a separate
  non-negotiable regression.
- The memory/jetsam requirement (NFR-CNR-003) is expressed as counted properties (one resident
  brain model; zero feature-attributable terminations in the DV session) because the source
  documents state no byte-level memory threshold; no numeric threshold was invented.
- Exact user-facing copy (consent disclosure, indicator labels, safe-template replies, degradation
  notices) is design-dependent and localisation-bound; the `ne`/`en` keys must exist per
  NFR-CNR-010, and the copy is reviewed under the Open Decision 12/13 review clause.
- Where the source documents describe sub-artifacts (e.g. an enterprise licence for the Nepali
  call-center corpus, the optional NepaliGPT CPT phase, the future Nepali GEC corrector), the
  requirement set encodes the binding property and its condition, not the sub-artifact's internal
  design.
- The project's known pre-existing full-bundle test failures remain the baseline for NFR-CNR-011;
  the feature's own and touched suites must pass, with baseline failures recorded rather than
  silently included or excluded.

## Open decisions

**No owner-level decision is open.** Five design-level Open Decisions carried by the feature
constitution are deliberately left to `design-l1`/`design-l2` — they are choices *inside* the
contracts this set fixes, not scope questions:

| # | Decision | Bounded by |
|---|---|---|
| OD-1 | Chat temperature value + sampling plumbing (the LLM handle is created once; per-turn override vs. a shape-specific handle) and the GBNF interplay | FR-CNR-003, FR-CNR-004, NFR-CNR-001; feasibility honesty in FR-CNR-024 |
| OD-2 | Style-spec artifact format (prose vs. machine-readable) and how the four consumers resolve against one file without duplication | FR-CNR-001 (single source, no forks), NFR-CNR-005 |
| OD-3 | P0 landing path — full P0→P1→P2 in this run (owner directive) vs. P0 as a normal PR first; only ordering changes | FR-CNR-024 (a sequencing deviation is reported) |
| OD-4 | Particles-budget enforcement mechanics (which particle set counts; guard check vs. eval rubric vs. both; interaction with the ≤2-sentence ceiling and code-switched sentences) | FR-CNR-001 (the ≤1 budget is fixed), FR-CNR-005, FR-CNR-020 |
| OD-5 | The Gemini chat temperature value (on-device is ~0.3; the cloud value is proposed at design with a rationale) | FR-CNR-011 (explicit + reviewed), FR-CNR-002 (no drift with the local contract) |

One owner-facing question is recorded rather than resolved: **OD-3** (P0 PR-first ordering), which
the approved proposal explicitly permits ("The P0 items are individually small and could land as a
normal PR first") and the workflow records as an owner question. It changes sequencing only, never
scope or contracts — recorded here for the audit trail rather than decided unilaterally.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)", the workflow scope
comment's non-goals, and the proposal's boundaries) — recorded so nothing is silently half-built:

- **The single-decode schema** — one JSON (`intent` + response/reply + `confidence`). No
  chain/router surgery; the v17 variant is a catalog swap (FR-CNR-013, FR-CNR-022).
- **The router ladder and emergency gate behaviour** — unchanged; the chat pre-check semantics
  beyond wiring the routing toggle are untouched (FR-CNR-014).
- **STT behaviour** — the speech pipeline is not part of this feature; the STT-engine invariant
  stands (FR-CNR-015).
- **Command-turn decode determinism** — temp-0 + fixed seed + GBNF `commandJSONSchema` are the
  NO-GIBBERISH invariants and stay untouched (FR-CNR-004).
- **Any new device permission; any new data collection** beyond the recorded cloud-chat egress and
  the classification-only telemetry this set defines (FR-CNR-015, FR-CNR-010, NFR-CNR-007).
- **Few-shot exemplars in the on-device prompt** — style travels via data, not prompt tokens
  (FR-CNR-023, NFR-CNR-004).
- **The intent prompt bytes** — `IntentPrompt.build`, `seeds/prompt_template.txt` and the
  `IntentPromptTests` pin stay byte-identical (FR-CNR-023).
- **Emergency-call logic, medication flow, health monitoring, and the encrypted remote-config
  channel** — unchanged by this feature.
- **Non-chat content on the cloud chat path** — commands, emergency phrasing and any other
  non-chat content do not travel through the new toggle (FR-CNR-010).
- **CC BY-NC and research-gated data in shipped artifacts** — IndicDialogue, DailyDialog,
  PersonaChat, EmpatheticDialogues and the unlicensed Nepali call-center corpus remain dev-mix only
  (FR-CNR-018).
- **A new training pipeline** — v17 extends `tools/train-intent`; no parallel pipeline is created
  (FR-CNR-016).
- **The Nepali GEC corrector on the device** — the literature's QLoRA grammar-corrector (~3.5 GB
  quantized) is out of scope for the device tiers at this stage; the grammar guard verifies instead
  of correcting, and the server-side corpus-cleaning use is tooling, not a shipped feature
  (FR-CNR-005).
- **Android** — no platform scope beyond the existing iOS app.

## Gate traceability

| Gate (feature workflow) | What it consumes from this set |
|---|---|
| `design-l1` / `design-l2` | Resolve OD-1 … OD-5 inside the contracts: the style-spec artifact and its four consumer seams (FR-CNR-001/002/005/017/020); the chat decode seam with reproducibility tests (FR-CNR-003, NFR-CNR-001) without moving the command invariants (FR-CNR-004); the guard contract (FR-CNR-005 … FR-CNR-007); the cloud toggle shape + consent/disclosure/indicator/fallback + the OD-12-shape amendment (FR-CNR-008 … FR-CNR-012); the Gemini temperature seam (FR-CNR-011); the v17 suite extension, provenance manifest, gate harness and catalog/rollback plan (FR-CNR-016 … FR-CNR-022); the DV protocol (FR-CNR-025). Feasibility honesty starts here (FR-CNR-024). |
| `review-l2` | `review.decision == GO` against the component design and this set. |
| `security-design-review` | STRIDE over: the shared safety-critical model + catalog-swap discipline (FR-CNR-014/021/022, NFR-CNR-008); the new cloud chat egress and the guard escalation (FR-CNR-006/008/009/010); credential + content hygiene (FR-CNR-012, NFR-CNR-006/007); guard integrity — verify-never-rewrite, honest degradation (FR-CNR-005/006); ship-mix provenance (FR-CNR-017/018); prompt discipline (FR-CNR-023, NFR-CNR-004/005). `SECURITY-GO` required. |
| `plan-tasks` / `implement` | Units trace back to `FR-CNR-*` / `NFR-CNR-*` ids; P0 lands before P1 per the owner directive (FR-CNR-024 records any deviation); paired review + 0.85 confidence; focused tests per unit. |
| `review-implementation` | `review.decision == GO` over the implementation against this set. |
| `security-test` | Evidence: emergency recall stays 1.00 and command decode stays deterministic (FR-CNR-004/014/021); chat turns reproducible at the fixed seed (NFR-CNR-001); the guard never rewrites and degrades honestly (FR-CNR-005/006); consent + indicator enforced and the key/conversation content never reach logs, with `check-release-log-safety.sh` covering the new paths (FR-CNR-009/012, NFR-CNR-006/007); the ship-mix manifest proves no CC BY-NC source (FR-CNR-018); templates stay within 1,024 tokens and the seed mirror is byte-identical (FR-CNR-023, NFR-CNR-004/005). `SECURITY-GO` required. |
| `final-sign-off` | T2 + HIL; the DV-1 … DV-6 record (FR-CNR-025); the release gate `ios/tools/check-release-log-safety.sh` exits 0 (NFR-CNR-006/011); the feasibility-honesty statement for every leg (FR-CNR-024). |

## Related

- Structured set: [`define-requirements/index.md`](define-requirements/index.md) ·
  [`define-requirements/FR/index.md`](define-requirements/FR/index.md) ·
  [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md)
- Locked snapshot: [`define-requirements.lock.yaml`](define-requirements.lock.yaml)
- Feature constitution: [`specs/conversational-nepali-replies/constitution.md`](conversational-nepali-replies/constitution.md)
- Feature workflow (scope comment): [`specs/conversational-nepali-replies/workflow.yaml`](conversational-nepali-replies/workflow.yaml)
- Scaffold report: [`specs/conversational-nepali-replies/init-report.md`](conversational-nepali-replies/init-report.md)
- Owner-approved proposal (source mandate): [`docs/features/2026-10-14-conversational-nepali-replies-proposal.md`](docs/features/2026-10-14-conversational-nepali-replies-proposal.md)
