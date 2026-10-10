# Requirements — Multi-Turn Conversation (feature)

**Project:** Elderly AI Assistant · **Feature:** `multi-turn-conversation` (v1) ·
**Branch:** `feat/multi-turn-conversation` (worktree `elderly-ai-assistant-multi-turn-conversation`)
**Task:** `define-requirements` (agent `ba`; contracts `requirements_doc` + `requirements_lock`)
**Date:** 2026-10-10 · **Status:** submitted for owner HIL approval (risk tier T1, per the feature
workflow's `define-requirements` task); no owner amendment recorded at lock time — the locked
snapshot in `define-requirements.lock.yaml` is the drift-detection baseline.

This is the consolidated, human-readable copy of the feature requirements. The structured source
of the same set is the folder [`define-requirements/`](define-requirements/index.md): one file per
requirement, with index files at each level. Both are generated from the same content; the
per-requirement files are the unit of change, this document plus the lock file are the snapshot
downstream tasks (`design-l1`, `design-l2`, `review-l2`, `security-design-review`, `plan-tasks`,
`implement`, `review-implementation`, `security-test`, `final-sign-off`) consume.

**ID convention.** Requirement IDs are namespaced `FR-MTC-NNN` / `NFR-MTC-NNN`. The project-level
stakeholder brief (`requirements.md`) already uses the bare `FR-NNN` / `NFR-NNN` series, so a
feature-scoped namespace avoids collisions in downstream traceability — the same convention
live-camera-translation used (`FR-LCT-NNN`), profile-interview used (`FR-PI-NNN`) and
spotify-music-integration used (`FR-SP-NNN`). One file per requirement; every requirement carries
at least one Gherkin scenario, and every safety-relevant requirement carries a failure scenario.

**Phase structure (preserved from the study §7 and the workflow "PHASE STRUCTURE").** Feature
Phase 0 = PR #156 voice-OOM hardening merged (`437631e`, 2026-10-10) with its Anzaan device smoke
outstanding — the prerequisite gate (bound by FR-MTC-020). Phase 1 = the deterministic MVP,
shippable alone (FR-MTC-001 … FR-MTC-017, all MUST) — the owner's bhajan example must work
end-to-end with no training run. Phase 2 = the follow-up NLU fine-tune v17 with the frame clause,
shipping ONLY with the training iteration (FR-MTC-018, SHOULD pending OD-M3). Phase 3 =
reminder/calendar rollover (FR-MTC-019, SHOULD pending OD-M4) plus the DV-* device-validation
closure (FR-MTC-020, MUST).

**Relationship to the stakeholder brief (`requirements.md`).** No supersession of the brief is
needed: the brief does not address multi-turn dialogue. Its FR-008 "conversational response
generation" clause is **not** delivered or superseded by this feature — open-ended chat stays
explicitly out of scope per the owner's 2026-10-10 study and the feature constitution. The brief's
§4 Post-MVP "Music and bhajan playback" entry (~lines 675–676) was already superseded by the
shipped spotify-music-integration feature; this feature extends that shipped music path with
dialogue mechanics rather than re-opening the placement.

## Summary

- **Functional requirements: 20** (`FR-MTC-001` … `FR-MTC-020`)
- **Non-functional requirements: 12** (`NFR-MTC-001` … `NFR-MTC-012`)
- **Areas covered:** Dialogue Frame / Core, Music Path / Probe Trigger, Probes (slot-fill,
  did-you-mean), Answer Capture (forms, escape), Answer Merge / Execution, Probe Policy,
  Interception / Routing (pre-ladder, cancel, barge-in), Safety / Emergency, Timeout / Recovery,
  Session State, Option Catalog, Probe Generation / Localisation, Cache Discipline, NLU Training
  (Phase 2), Rollout (Phase 3), Validation / Completion Gate. NFR categories: Performance,
  Reliability, Privacy, Security, Localisation, Accessibility, Compliance.
- **v1 scope:** give the single-turn voice pipeline a one-deep dialogue frame (`DialogueManager` +
  `DialogueFrame`, FR-MTC-001) with two first-class probe kinds — `.slotFill` for a missing slot
  such as the bhajan deity (FR-MTC-002/003) and `.candidateChoice`/didYouMean for a not-understood
  utterance (FR-MTC-004) — voice answer capture by name, index word, repetition or free-form
  (FR-MTC-005), the deterministic merge that executes through the normal music path (FR-MTC-006),
  the bounded probe budget with default execution (FR-MTC-007), the say-it-again escape
  (FR-MTC-008), pre-ladder interception (FR-MTC-009) with cancel, emergency, barge-in and 45 s
  timeout rules (FR-MTC-010 … FR-MTC-013), the `awaitingSlotAnswer` state (FR-MTC-014), the
  curated on-device catalog (FR-MTC-015), template-only probes (FR-MTC-016), the transcript-cache
  bypass (FR-MTC-017), and the Phase 2/3 follow-ups (FR-MTC-018/019) closing with the DV-* gate
  (FR-MTC-020).
- **Primary sources of truth:** `specs/multi-turn-conversation/constitution.md` (feature
  constitution — Purpose & Scope, Probe Kinds & Answer-Capture Contract, Safety-Relevant
  Constraints 1–4, Feature Constraints 1–10, Integration Surfaces, Success Criteria, DV-*
  completion gate, Open Decisions OD-M1..M4); `specs/multi-turn-conversation/workflow.yaml` (the
  `define-requirements` scope comment and phase structure); `docs/multi-turn-conversation-
  feasibility.md` (the owner's study — §5 measured constraints, §6 recommended design, §7 phasing,
  §8 risks, §9 open decisions); project `constitution.md` (inherited constraints, release gates).
- **Read-only stakeholder brief:** `requirements.md` (see the relationship note above).

## Contents

- [`define-requirements/index.md`](define-requirements/index.md) — top-level feature index
- [`define-requirements/FR/index.md`](define-requirements/FR/index.md) — functional requirement
  list (20 files: `define-requirements/FR/FR-MTC-NNN-*.md`)
- [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md) — non-functional
  requirement list (12 files: `define-requirements/NFR/NFR-MTC-NNN-*.md`)
- [`define-requirements.lock.yaml`](define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (contract `requirements_lock`)
- Sections below: [Functional requirements](#functional-requirements) ·
  [Non-functional requirements](#non-functional-requirements) ·
  [Open decisions](#open-decisions) · [Out of scope](#out-of-scope) ·
  [How this set is verified downstream](#how-this-set-is-verified-downstream)

The `define-requirements/FR/` and `define-requirements/NFR/` folders also still contain the
previously shipped live-camera-translation (`FR-LCT-*`, `NFR-LCT-*`), profile-interview
(`FR-PI-*`, `NFR-PI-*`) and spotify-music-integration (`FR-SP-*`, `NFR-SP-*`) requirement files,
left in place untouched; the indexes, this document and the lock cover the
`multi-turn-conversation` set only.

### Requirement index

| ID | Title | Area / Category | Priority | File |
|----|-------|-----------------|----------|------|
| [FR-MTC-001](define-requirements/FR/FR-MTC-001-dialogue-frame-lifecycle.md) | Dialogue frame lifecycle and one-deep state | Dialogue Frame / Core | MUST | `FR-MTC-001-dialogue-frame-lifecycle.md` |
| [FR-MTC-002](define-requirements/FR/FR-MTC-002-degenerate-music-query-detection.md) | Degenerate music-query detection before playback | Music Path / Probe Trigger | MUST | `FR-MTC-002-degenerate-music-query-detection.md` |
| [FR-MTC-003](define-requirements/FR/FR-MTC-003-slot-fill-probe.md) | `.slotFill` probe — a short kind-of-request question with options and a default | Probes / Slot-Fill | MUST | `FR-MTC-003-slot-fill-probe.md` |
| [FR-MTC-004](define-requirements/FR/FR-MTC-004-candidate-choice-did-you-mean-probe.md) | `.candidateChoice` (didYouMean) probe — honest not-understood line plus narrowing candidates | Probes / Did-You-Mean | MUST | `FR-MTC-004-candidate-choice-did-you-mean-probe.md` |
| [FR-MTC-005](define-requirements/FR/FR-MTC-005-voice-answer-capture.md) | Voice answer capture — name, index word, repetition, free-form | Answer Capture | MUST | `FR-MTC-005-voice-answer-capture.md` |
| [FR-MTC-006](define-requirements/FR/FR-MTC-006-deterministic-frame-merge-and-execution.md) | Deterministic frame merge and execution | Answer Merge / Execution | MUST | `FR-MTC-006-deterministic-frame-merge-and-execution.md` |
| [FR-MTC-007](define-requirements/FR/FR-MTC-007-probe-budget-two-then-defaults.md) | Probe budget — bounded probes, then execute with defaults | Probe Policy | MUST | `FR-MTC-007-probe-budget-two-then-defaults.md` |
| [FR-MTC-008](define-requirements/FR/FR-MTC-008-say-it-again-escape.md) | "No — let me say it again" escape re-arms a fresh capture | Answer Capture / Escape | MUST | `FR-MTC-008-say-it-again-escape.md` |
| [FR-MTC-009](define-requirements/FR/FR-MTC-009-pre-ladder-answer-interception.md) | Pre-ladder answer interception | Interception / Routing | MUST | `FR-MTC-009-pre-ladder-answer-interception.md` |
| [FR-MTC-010](define-requirements/FR/FR-MTC-010-cancel-drops-the-frame.md) | Cancel words drop the frame with an honest line | Interception / Cancel | MUST | `FR-MTC-010-cancel-drops-the-frame.md` |
| [FR-MTC-011](define-requirements/FR/FR-MTC-011-emergency-precedence-mid-frame.md) | Emergency precedence is absolute mid-frame | Safety / Emergency | MUST | `FR-MTC-011-emergency-precedence-mid-frame.md` |
| [FR-MTC-012](define-requirements/FR/FR-MTC-012-barge-in-strong-new-command.md) | Barge-in — a strong new command drops the frame | Interception / Barge-in | MUST | `FR-MTC-012-barge-in-strong-new-command.md` |
| [FR-MTC-013](define-requirements/FR/FR-MTC-013-timeout-silent-rearm.md) | 45 s timeout — silent drop and re-arm | Timeout / Recovery | MUST | `FR-MTC-013-timeout-silent-rearm.md` |
| [FR-MTC-014](define-requirements/FR/FR-MTC-014-awaiting-slot-answer-state.md) | `awaitingSlotAnswer` session state with the 45 s timer reuse | Session State | MUST | `FR-MTC-014-awaiting-slot-answer-state.md` |
| [FR-MTC-015](define-requirements/FR/FR-MTC-015-curated-on-device-catalog.md) | Curated on-device option catalog | Option Catalog | MUST | `FR-MTC-015-curated-on-device-catalog.md` |
| [FR-MTC-016](define-requirements/FR/FR-MTC-016-template-generated-probes.md) | Template-generated probes, localized ne/en — never model-generated | Probe Generation / Localisation | MUST | `FR-MTC-016-template-generated-probes.md` |
| [FR-MTC-017](define-requirements/FR/FR-MTC-017-transcript-cache-bypass.md) | Transcript-cache bypass during answer capture | Cache Discipline | MUST | `FR-MTC-017-transcript-cache-bypass.md` |
| [FR-MTC-018](define-requirements/FR/FR-MTC-018-follow-up-nlu-fine-tune-v17.md) | Phase 2 — follow-up NLU fine-tune v17 with the frame clause | NLU Training (Phase 2) | SHOULD | `FR-MTC-018-follow-up-nlu-fine-tune-v17.md` |
| [FR-MTC-019](define-requirements/FR/FR-MTC-019-reminder-calendar-frame-rollover.md) | Phase 3 — reminder/calendar missing-slot re-prompts on the frame path | Rollout (Phase 3) | SHOULD | `FR-MTC-019-reminder-calendar-frame-rollover.md` |
| [FR-MTC-020](define-requirements/FR/FR-MTC-020-device-validation-completion-gate.md) | DV-* device validation recorded and passed (completion gate) | Validation / Completion Gate | MUST | `FR-MTC-020-device-validation-completion-gate.md` |
| [NFR-MTC-001](define-requirements/NFR/NFR-MTC-001-probe-turn-latency.md) | Probe and answer turns stay within the existing turn envelope | Performance | MUST | `NFR-MTC-001-probe-turn-latency.md` |
| [NFR-MTC-002](define-requirements/NFR/NFR-MTC-002-prompt-budget-and-token-ceiling.md) | 1024-token ceiling and the pinned prompt budget are preserved | Reliability / Maintainability | MUST | `NFR-MTC-002-prompt-budget-and-token-ceiling.md` |
| [NFR-MTC-003](define-requirements/NFR/NFR-MTC-003-no-new-network-egress.md) | No new network egress — probes and answers stay on-device | Privacy | MUST | `NFR-MTC-003-no-new-network-egress.md` |
| [NFR-MTC-004](define-requirements/NFR/NFR-MTC-004-log-safety.md) | Log safety — probe and answer text never reach logs | Privacy / Security | MUST | `NFR-MTC-004-log-safety.md` |
| [NFR-MTC-005](define-requirements/NFR/NFR-MTC-005-degraded-brain-deterministic-path.md) | The frame survives a degraded or absent brain — deterministic path | Reliability | MUST | `NFR-MTC-005-degraded-brain-deterministic-path.md` |
| [NFR-MTC-006](define-requirements/NFR/NFR-MTC-006-localisation.md) | Localisation of every dialogue string (ne/en) | Localisation | MUST | `NFR-MTC-006-localisation.md` |
| [NFR-MTC-007](define-requirements/NFR/NFR-MTC-007-sustained-multi-turn-stability.md) | Sustained multi-turn stability on 6 GB devices — no jetsam | Reliability / Performance | MUST | `NFR-MTC-007-sustained-multi-turn-stability.md` |
| [NFR-MTC-008](define-requirements/NFR/NFR-MTC-008-answer-sanitisation-and-injection-safety.md) | Answer-path sanitisation and injection safety | Security | MUST | `NFR-MTC-008-answer-sanitisation-and-injection-safety.md` |
| [NFR-MTC-009](define-requirements/NFR/NFR-MTC-009-voice-only-accessibility.md) | Voice-only accessibility of probes and answer capture | Accessibility | MUST | `NFR-MTC-009-voice-only-accessibility.md` |
| [NFR-MTC-010](define-requirements/NFR/NFR-MTC-010-frame-trap-resistance.md) | Frame-trap resistance — zero stuck states | Reliability / Safety | MUST | `NFR-MTC-010-frame-trap-resistance.md` |
| [NFR-MTC-011](define-requirements/NFR/NFR-MTC-011-kv-prefix-stability.md) | KV-prefix stability — the frame clause never mutates the template prefix | Performance / Reliability | MUST | `NFR-MTC-011-kv-prefix-stability.md` |
| [NFR-MTC-012](define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md) | Compliance, no-regression and release gates | Compliance | MUST | `NFR-MTC-012-compliance-and-release-gates.md` |

## Functional requirements

### FR-MTC-001: Dialogue frame lifecycle and one-deep state

#### Metadata
- **Area:** Dialogue Frame / Core
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Frame shape (in-memory, held by `DialogueManager`, owned by the coordinator — the same one-deep pattern as today's pending-command state, but structured)" and "In scope" (Phase 1: `DialogueManager` + `DialogueFrame`); feasibility study §6.1 (the frame object and its fields); workflow `define-requirements` scope comment ("one-deep dialogue frames (`DialogueManager` + `DialogueFrame`)").

#### Description
While a probe awaits an answer, the system **must** hold exactly one in-memory dialogue frame — structured, not a bare pending command. The frame carries: `activeCommand` (the pending resolved command), `missingSlot` (what the probe asked for), `probeKind` (`.slotFill` or `.candidateChoice`), `candidates` (candidate interpretations for the active probe), `attempts` (probe count, capped per FR-MTC-007) and `deadline` (45 s per FR-MTC-013). The binding properties:

- **Held by `DialogueManager`, owned by the coordinator** — the existing one-deep ownership pattern (the coordinator owns the pending-command state today, read through `CommandRouter` via coordinator hooks such as `isAwaitingConfirmation` at `AppCoordinator.swift:10535`), not scattered per-call state.
- **One-deep**: at most one frame exists at a time; a new probe cannot start while a frame is active — the active frame is resolved first (answer, cancel, barge-in or timeout).
- **In-memory only**: no persistence across sessions; after a cold start no frame exists and the next utterance is a fresh command (feature constitution "Out of scope ... Persistent dialogue state across sessions").
- **No transcript history in the frame**: dialogue state lives in the app, never as utterance history for prompts (feature constitution Feature Constraint 1).
- **Cleared on resolution**: every terminal outcome (execute, cancel, barge-in, timeout, escape) clears the frame; no residue affects the next turn.

#### Acceptance criteria

```gherkin
Feature: One-deep dialogue frame

  Scenario: A probe trigger creates exactly one frame with the dialogue fields
    Given a music command resolves with a degenerate query (FR-MTC-002)
    When the system decides to ask the slot-fill probe
    Then one dialogue frame is held with the pending command, the missing slot, probeKind .slotFill, the candidate options and a 45 s deadline
    And the frame is owned by the coordinator

  Scenario: A second probe trigger never creates a second frame
    Given a frame is active
    When any further probe trigger occurs (another degenerate command, or a not-understood utterance)
    Then no second frame is created
    And the active frame is resolved first (answer, cancel, barge-in or timeout)

  Scenario: No frame survives a cold start
    Given the app is relaunched
    When the voice session starts
    Then no dialogue frame exists
    And the next utterance is treated as a fresh command
```

#### Related
- FR: FR-MTC-014 (the session state that opens the answer window), FR-MTC-013 (the deadline), FR-MTC-007 (the attempt cap)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-002 (no transcript history in prompts)

### FR-MTC-002: Degenerate music-query detection before playback

#### Metadata
- **Area:** Music Path / Probe Trigger
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "In scope" (Phase 1: "degenerate-query detection in the music path"); feasibility study §2 ("the query is whatever survives token-stripping — or the marker itself"; `musicQuery(from:)` marker fallback, `KeywordIntentRule.swift:752-779`) and §6.2 (the probe trigger); worktree source verified: the never-empty marker fallback at `KeywordIntentRule.swift:765-775`, the ladder music arm at `CommandRouter.swift:1223-1234`, the interpreted `.music` path at `CommandRouter.swift:3336-3355`.

#### Description
When a music command resolves and its search query is **degenerate**, the system **must not** execute the literal top-hit search blindly (today: `fireMusicRequest` → `runMusicTurn` → `SpotifyTool.fetchTopTrack` with whatever survives extraction). A degenerate query is: a bare music-marker word produced by the never-empty marker fallback (e.g. "play bhajans" → query `"bhajans"`, "भजन बजाऊ" → query `"भजन"`), or an extraction that canonicalizes to nothing (the raw-transcript fallback). Detection **must** run on both intake routes:

- the deterministic keyword-ladder music arm (`CommandRouter.swift:1223-1234`), and
- the interpreted `.music` action (`CommandRouter.swift:3336-3355`, the `interpretedQuery ?? musicQuery ?? raw` order).

A non-degenerate query (a specific artist/track/genre phrase present in the utterance) must keep today's behaviour exactly — no probe (NFR-MTC-012). Detection is deterministic and model-free (zero prompt tokens).

#### Acceptance criteria

```gherkin
Feature: Degenerate music-query detection

  Scenario: A bare Nepali bhajan request is detected as degenerate and probes instead of searching
    Given the keyword ladder resolves the utterance "भजन बजाऊ" to the music domain
    And the extracted query is only the bare marker "भजन"
    When the music path evaluates the query
    Then no Spotify search is fired for the bare marker
    And the slot-fill probe is triggered (FR-MTC-003)

  Scenario: A specific music request passes straight through, unchanged
    Given the user says "दशैं दुर्गा भजन बजाऊ"
    When the music path extracts a specific query
    Then the query is not treated as degenerate
    And playback proceeds exactly as today with no probe

  Scenario: An empty extraction triggers the probe rather than searching the raw transcript
    Given a music command whose query canonicalizes to nothing
    When the music path evaluates the query
    Then no search is fired with the raw transcript as the query
    And the slot-fill probe is triggered
```

#### Related
- FR: FR-MTC-003 (the slot-fill probe it triggers), FR-MTC-012 (barge-in interplay), FR-MTC-019 (the same mechanism later covers reminder/calendar slots)
- NFR: NFR-MTC-012 (no regression for specific queries), NFR-MTC-005 (detection is deterministic, brain-free)

### FR-MTC-003: `.slotFill` probe — a short kind-of-request question with options and a default

#### Metadata
- **Area:** Probes / Slot-Fill
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Probe Kinds table (`.slotFill`: "a short template probe (e.g. 'कस्तो भजन? शिव, दुर्गा, विष्णु, देवी … वा आफैँ भन्नुहोस्'), ≤3–4 named options, one default always offered ('just play anything')") and the owner's example ("'play bhajans' makes Pip ask 'WHAT KIND OF BHAJANS? shiva, durga, bishnu, devi...'"); feasibility study §6.2 (the probe text) and §6.5 (spoken like any reply; appears in chat history; no new UI). OD-M1 (probe policy — OPEN) and OD-M2 (option source — OPEN) affect the exact wording and option sourcing; the requirements bind the shape below.

#### Description
For a degenerate music query (FR-MTC-002), the system **must** speak a short, template-generated probe asking what kind of music the user wants, and enter the answer-capture window. Binding properties:

- **Template text, ne/en** — static localized strings, never model-generated (FR-MTC-016). The owner's example probe: 'कस्तो भजन? शिव, दुर्गा, विष्णु, देवी … वा आफैँ भन्नुहोस्' / "What kind of bhajan? shiva, durga, bishnu, devi … or say it yourself."
- **≤3–4 named options**, spoken by name, sourced from the curated on-device catalog (FR-MTC-015).
- **One default option is always offered** on the probe ("just play anything" — the OD-M1 default-play wording, e.g. 'जे पनि बजाऊ'). The default is a valid answer that executes the pending command with the default query (FR-MTC-007).
- **Free text always accepted** — the user may answer with anything, not only the named options (FR-MTC-005).
- **`probeKind` is `.slotFill`** on the frame (FR-MTC-001), and the frame records the missing slot the probe asked for.
- Spoken through the existing reply lane (`speak` → `ReplySpeakLane`), appears in the chat history like any reply — **no new UI** (study §6.5).
- The probe does not execute anything; it only asks and opens the 45 s window (FR-MTC-014).

#### Acceptance criteria

```gherkin
Feature: The slot-fill probe

  Scenario: The owner's example — "play bhajans" hears the kind-of-bhajan probe
    Given the user says "play bhajans"
    And the resolved music query is degenerate
    When the probe is triggered
    Then Pip asks what kind of bhajans, naming the catalog options and inviting a free-spoken answer
    And a default option ("just play anything") is offered
    And the probe appears in the chat history like any reply

  Scenario: The probe is bounded — at most four named options plus the default
    Given any slot-fill probe is constructed
    When its spoken option list is inspected
    Then at most 3–4 named options are named
    And exactly one default option is always offered
    And the free-spoken path is always offered

  Scenario: The English utterance receives the English probe
    Given the active language is English
    When the slot-fill probe is spoken
    Then every part of the probe (question, options, default, free-text invitation) is the English template
```

#### Related
- FR: FR-MTC-002 (the trigger), FR-MTC-015 (option source), FR-MTC-005 (answer capture), FR-MTC-016 (template generation), FR-MTC-007 (default execution)
- NFR: NFR-MTC-006 (localisation), NFR-MTC-009 (voice-only accessibility)

### FR-MTC-004: `.candidateChoice` (didYouMean) probe — honest not-understood line plus narrowing candidates

#### Metadata
- **Area:** Probes / Did-You-Mean
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Probe Kinds table (`.candidateChoice`: "the utterance was not understood ... an honest 'did not understand' line **plus** a narrowing probe with ≤2–3 candidate options the user picks by voice") and "The owner requirement (2026-10-10): two probe kinds ... this is a first-class requirement, not an optional extra"; feasibility study §6.2 ("No-understanding probe (owner requirement, 2026-10-10)") — candidates from the rephrase band (confidence 0.4–0.7), relaxed keyword near-matches (`KeywordIntentRule.match`, called at `CommandRouter.swift:1207-1234`), and the active frame; upgrades the honest-but-dead-end `routeKeywordRemainder` lines (`CommandRouter.swift:1968-2030`).

#### Description
When Pip does not understand an utterance, it **must** (1) honestly say that it did not understand, and (2) offer a narrowing probe with candidate interpretations the user picks by voice — instead of today's honest-but-dead-end re-prompt. Binding properties:

- **Both parts are required**: honesty first ("I didn't understand"), then the narrowing candidates. Neither alone satisfies this requirement.
- **`probeKind` is `.candidateChoice`** on the frame (FR-MTC-001).
- **≤2–3 candidate options**, spoken by name; the user picks by option name, index word, repetition, or free-form correction (FR-MTC-005).
- **Candidate sources** (deterministic first): the rephrase band's low-confidence hypothesis (confidence < 0.7 tier-`.free`; `CommandRouter.swift:1493-1519`, music is tier `.free` per `ConfirmationTier`), relaxed keyword near-matches, and the active dialogue frame when one exists.
- **Never fabricate candidates**: when the pipeline has no candidate to offer, the honest not-understood line stands alone (today's behaviour, no invented options).
- **Same constraints as `.slotFill`**: template text ne/en (never model-generated), 45 s deadline, free text always accepted, the "no — let me say it again" escape (FR-MTC-008), the same pre-ladder interception (FR-MTC-009) and frame-merge execution path (FR-MTC-006).
- This upgrades the `routeKeywordRemainder` honest-failure lines (`CommandRouter.swift:1968-2030`) into a narrowing dialogue; the honest no-brain states (download/setup) keep their truthful lines (NFR-MTC-012).

#### Acceptance criteria

```gherkin
Feature: The did-you-mean candidate probe

  Scenario: A not-understood utterance hears honesty plus narrowing candidates
    Given the user says something the pipeline cannot resolve
    When the fallback path is reached
    Then Pip first says it did not understand, in the active language
    And Pip offers at most 2–3 candidate interpretations by voice
    And the user can pick one by voice

  Scenario: Picking a candidate executes the interpretation
    Given the did-you-mean probe is outstanding with candidates
    When the user picks a candidate by name (or index word)
    Then the chosen interpretation is executed exactly as if it had been understood as that command

  Scenario: No candidates available — honest line, nothing invented
    Given no deterministic candidate interpretation exists for the utterance
    When the fallback path is reached
    Then the honest not-understood line is spoken
    And no candidate option is fabricated and no frame is opened
```

#### Related
- FR: FR-MTC-008 (the say-it-again escape), FR-MTC-009 (interception), FR-MTC-005 (picking), FR-MTC-016 (template text)
- NFR: NFR-MTC-006 (localisation), NFR-MTC-012 (no regression for the no-brain honest lines)

### FR-MTC-005: Voice answer capture — name, index word, repetition, free-form

#### Metadata
- **Area:** Answer Capture
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Answer capture — the user picks by: the option's **name**, its **index word** ('पहिलो' / 'first'), **repetition** of the candidate, or a **free-form correction** (always accepted)"; feasibility study §6.2 ("the user picks by voice — the option's name, its index ('पहिलो' / 'first'), or repeating the candidate — or answers free-form"); the no-with-amendment precedent (`CommandRouter.swift:811-821`) as the answer-with-content proof.

#### Description
While a probe is outstanding (either `probeKind`), the system **must** accept the user's spoken answer in all of these forms, and at least these forms:

1. **Option name** — the user says a named candidate ("दुर्गा", "shiva").
2. **Index word** — the user says the option's position ("पहिलो" / "first", and the second/third equivalents in the active language).
3. **Repetition of the candidate** — the user repeats the candidate phrase, optionally with the original command's verb ("दुर्गा भजन बजाऊ") — repetition is an answer, not a new command (FR-MTC-012).
4. **Free-form correction** — anything else is accepted as the user's intended value, even when it matches no option ("दशैं दुर्गा भजन", per the owner's example); free text is **always** accepted and never rejected for not being on the list.

The captured answer is then merged deterministically (FR-MTC-006). Single-word answers must work (elderly usability — NFR-MTC-009). An utterance that matches none of the forms and resolves to nothing is not a valid answer — it re-probes under the attempt cap (FR-MTC-007).

#### Acceptance criteria

```gherkin
Feature: Voice answer capture

  Scenario: Answer by option name
    Given the slot-fill probe is outstanding with option "दुर्गा" among the candidates
    When the user says "दुर्गा"
    Then the answer is captured as the दुर्गा option
    And the merge proceeds (FR-MTC-006)

  Scenario: Answer by index word
    Given the probe is outstanding with an ordered option list
    When the user says "पहिलो" ("first")
    Then the answer is captured as the first option in the list

  Scenario: Answer by repeating the candidate with the original verb
    Given the music probe is outstanding
    When the user says "दुर्गा भजन बजाऊ"
    Then the repetition is captured as the answer to the probe
    And it is not executed as a fresh independent command

  Scenario: A free-form answer matching no option is still accepted
    Given the music probe is outstanding
    When the user says "दशैं दुर्गा भजन" (not a catalog option)
    Then the free-form text is captured as the answer value
    And no option-list membership is required
```

#### Related
- FR: FR-MTC-006 (merge), FR-MTC-007 (re-probe on invalid answers), FR-MTC-012 (repetition is not barge-in), FR-MTC-015 (catalog canonicalisation)
- NFR: NFR-MTC-009 (single-word, voice-only usability)

### FR-MTC-006: Deterministic frame merge and execution

#### Metadata
- **Area:** Answer Merge / Execution
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Deterministic frame merge — sanitise the answer through the existing input seam (STT-error corrector + dialect canonicalizer), strip answer scaffolding, canonicalise via the catalog when it matches (else keep the free text), merge into `activeCommand`, dispatch through the normal executor (`runMusicTurn`)" and Feature Constraint 4 ("Deterministic merge works with the brain absent or degraded"); feasibility study §6.3.3 (steps) and §7 Phase 1 ("covers the owner's bhajan example end-to-end without any training run"); worktree surfaces verified: input seam (`Services/Intents/LocalBrainChain.swift` `turnInput`, `InputSanitiser.sanitise(_:level:.quarantine)`), dispatch entry `runMusicTurn` (`CommandRouter.swift:2684`).

#### Description
On a captured answer, the system **must** merge it into the pending command and execute — deterministically, with no model involvement in Phase 1:

1. **Sanitise through the existing input seam** — the captured transcript passes through the same `InputSanitiser`-led seam (STT-error corrector + dialect canonicalizer) every turn uses, before any use.
2. **Strip answer scaffolding** — verb/probe words added to the answer are removed ("दशैं दुर्गा भजन" → query value `"dasain durga bhajan"`; a bare index-word answer resolves to the option it names).
3. **Canonicalise via the curated catalog when it matches** — e.g. दुर्गा → the canonical search query "durga bhajan" (FR-MTC-015); when the answer matches no catalog entry, the free text itself is kept as the value. Never reject, never invent.
4. **Merge into `activeCommand`** — the answer fills the missing slot (music: the query) on the pending command; the command's other properties are unchanged.
5. **Dispatch through the normal executor** — the merged command runs through the existing path (`fireMusicRequest` → `runMusicTurn`), so pre-ack, the Spotify/YouTube outcome matrix, and honest outcomes behave exactly as for a directly-spoken command (NFR-MTC-012).

The owner's acceptance anchor: "play bhajans" → probe → "dasain durga bhajans" → correct playback of dasain durga bhajans — end-to-end, with no training run. The merge must work with the brain absent or degraded (NFR-MTC-005); the optional brain-assisted resolution is Phase 2 (FR-MTC-018) and never a Phase 1 dependency.

#### Acceptance criteria

```gherkin
Feature: Deterministic frame merge

  Scenario: The owner's bhajan example works end-to-end with no training run
    Given the user said "play bhajans" and heard the kind-of-bhajan probe
    When the user answers "dasain durga bhajans"
    Then the answer is sanitised, scaffolding-stripped and merged into the pending music command as the query
    And playback of dasain durga bhajans starts through the normal music path
    And no model or training artifact was required

  Scenario: A catalog-matching answer canonicalises to the canonical query
    Given the probe asked for the kind of bhajan
    When the user answers "दुर्गा"
    Then the merged query is the catalog's canonical form ("durga bhajan")
    And execution proceeds through the normal music path

  Scenario: A free-form answer merges as spoken, without catalog membership
    Given the probe asked for the kind of bhajan
    When the user answers "दशैं दुर्गा भजन"
    Then the merged query preserves the sanitised free text
    And execution proceeds through the normal music path

  Scenario: The merge survives with the brain absent
    Given the brain is not loaded (or was pressure-evicted)
    When the user answers the probe
    Then the deterministic merge produces the same merged command
    And execution proceeds through the normal music path
```

#### Related
- FR: FR-MTC-005 (capture forms), FR-MTC-015 (catalog), FR-MTC-018 (Phase 2 brain-assisted merge, optional)
- NFR: NFR-MTC-005 (degraded-brain path), NFR-MTC-008 (sanitisation discipline), NFR-MTC-012 (execution paths unchanged)

### FR-MTC-007: Probe budget — bounded probes, then execute with defaults

#### Metadata
- **Area:** Probe Policy
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 3 ("Probe budget. Max 2 probes then execute with defaults; ≤3–4 spoken options with a default always offered (slotFill), ≤2–3 for candidateChoice; free-text answers always accepted") and the answer-capture contract ("Unrecognized answers re-probe until the attempt cap: **max 2 probes, then execute with defaults**"); feasibility study §8 ("Probe fatigue / option overload — Max 2 probes then execute with defaults"); OD-M1 (OPEN — 1 probe vs up-to-2, and the default-play wording; the study recommends 2 probes max, default offered on the first probe). OD-M1's resolution sets the exact cap; the requirement binds a bounded budget and default execution.

#### Description
The system **must** bound every probe dialogue so it always terminates in an executed outcome, never in an endless question loop:

- **Bounded budget**: a frame issues at most the configured probe cap (currently **2** probes per the constitution's contract — the default; OD-M1 may resolve to 1). The cap counts probe attempts on the frame (`attempts` field, FR-MTC-001).
- **Default always offered**: every slot-fill probe offers a default answer ("just play anything"; exact wording — OD-M1) from the first probe, so the user can always end the dialogue in one word.
- **On exhaustion, execute with defaults**: after the cap is reached with no valid answer, the system executes the pending command with its default behaviour (e.g. play the default/plain query) rather than asking again or dead-ending. The user must hear the normal execution outcome (no silence — NFR-MTC-012's honesty discipline carries into this path).
- **Valid answers always win**: a valid answer at any point (name, index word, repetition, free-form) resolves the frame immediately and executes (FR-MTC-005/006) — the cap never delays a good answer.
- **Free text is always accepted**: an answer that is not on the option list is still a valid answer (FR-MTC-005); only genuinely unresolvable utterances consume probe attempts.

#### Acceptance criteria

```gherkin
Feature: Bounded probe budget with default execution

  Scenario: The default answer executes immediately when picked on the first probe
    Given the slot-fill probe is outstanding and offers a default ("just play anything")
    When the user says the default phrase
    Then the pending command executes with the default query
    And no further probe is asked

  Scenario: A second unrecognised answer does not produce a third probe
    Given the probe cap is configured (default 2) and two probe attempts were spent
    When the user's answer resolves to nothing
    Then no further probe is asked
    And the pending command executes with its default behaviour
    And the user hears the normal execution outcome

  Scenario: A valid answer resolves immediately regardless of remaining attempts
    Given the frame has attempt count below the cap
    When the user gives a valid answer
    Then the frame resolves and executes immediately
    And the remaining probe budget is never spent
```

#### Related
- FR: FR-MTC-001 (the attempts field), FR-MTC-003 (the default offer), FR-MTC-005 (free text always accepted), FR-MTC-013 (the timeout as the other termination)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-009 (no probe fatigue for the elderly user)

### FR-MTC-008: "No — let me say it again" escape re-arms a fresh capture

#### Metadata
- **Area:** Answer Capture / Escape
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Both kinds share ... the same constraints (template text, 45 s deadline, free-text always accepted, the 'no — let me say it again' escape re-arming a fresh capture)" and the `.candidateChoice` row ("a 'no — let me say it again' re-capture escape"); feasibility study §6.2 ("a 'no — let me say it again' escape that re-arms a fresh capture").

#### Description
Both probe kinds **must** offer an escape: when the user says the "no — let me say it again" phrase (localized ne/en), the system **must** drop the current probe's framing, speak a brief acknowledgement, and re-arm a fresh capture so the user can say what they meant in their own words. Binding properties:

- **Recognised in both probe kinds** (`.slotFill` and `.candidateChoice`) and in the active language of the probe.
- **Executes nothing**: the escape itself resolves nothing and must never execute the pending command, a candidate, or any other action.
- **Fresh capture re-armed**: the user is immediately back in listening for a fresh utterance; their next utterance is their new attempt at the request, handled by the normal turn path (a fresh command, or an answer if it resolves against the still-pending probe context — the composition is design's to fix; the requirement is that the user is never stuck and nothing executes unasked).
- **No dead end**: the escape always produces the acknowledgement and the re-armed capture — never silence, never a repeated probe line only.
- **Never countable as a hostile input**: the escape cannot be used to bypass the emergency precedence or the frame's safety rules (FR-MTC-011; NFR-MTC-008).

#### Acceptance criteria

```gherkin
Feature: The say-it-again escape

  Scenario: The escape re-arms a fresh capture in a slot-fill probe
    Given the slot-fill probe is outstanding
    When the user says the localized "no — let me say it again" phrase
    Then Pip briefly acknowledges and re-arms listening for a fresh utterance
    And the user is not stuck in a repeated question

  Scenario: The escape never executes anything by itself
    Given any probe is outstanding
    When the escape phrase is spoken
    Then neither the pending command nor any candidate is executed
    And no probe line is repeated as the only response

  Scenario: The escape works in a did-you-mean probe too
    Given the did-you-mean probe is outstanding
    When the user says the escape phrase in the active language
    Then the same acknowledgement and fresh capture follow
```

#### Related
- FR: FR-MTC-003/FR-MTC-004 (the two probe kinds it serves), FR-MTC-005 (capture), FR-MTC-011 (safety precedence)
- NFR: NFR-MTC-010 (no stuck states), NFR-MTC-006 (localisation)

### FR-MTC-009: Pre-ladder answer interception

#### Metadata
- **Area:** Interception / Routing
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "The answer turn (interception runs **before** the routing ladder, generalizing the confirmation hook at `CommandRouter.swift:785-886`)"; feasibility study §6.3 ("the interception in `CommandRouter.route` (the confirmation hook at 789-886, generalized) runs **before** the routing ladder") and §8 (the structural mitigation for out-of-distribution follow-ups); worktree surface verified: the existing confirmation hook at `CommandRouter.swift:785-886` sits above the safety net/keyword ladder.

#### Description
While a frame is awaiting an answer, the next transcript **must** be consumed by the answer path — the same structural position as today's confirmation hook — so that a follow-up utterance can never fall through to general routing and be misclassified as a fresh command. Binding properties:

- **Interception runs before the routing ladder** for the whole answer window: the next STT turn while `awaitingSlotAnswer` is handled by the answer path (cancel → emergency → merge/execute; FR-MTC-010/011/006), not by keyword matching, the interpreter, or the LLM as a fresh command.
- **This is what makes follow-ups work**: a bare "dasain durga bhajans" is out-of-distribution for the single-turn fine-tunes; interception is the structural guarantee that it is treated as an answer (study §5.2, §8).
- **The interception is armed exactly while a frame is awaiting an answer** and disarmed on every resolution (execute, cancel, barge-in, timeout, escape) — no stale interception can swallow a later legitimate command.
- **Exceptions pass through by rule, not by accident**: emergency keywords always win (FR-MTC-011); a strong new-command barge-in drops the frame and executes the new command (FR-MTC-012); everything ambiguous is treated as an answer.
- **No new routing surface**: the interception generalizes the existing confirmation-hook seam — it does not add a parallel router or alter ladder behaviour outside the answer window (NFR-MTC-008, NFR-MTC-012).

#### Acceptance criteria

```gherkin
Feature: Pre-ladder answer interception

  Scenario: A bare follow-up answer never reaches general routing
    Given the frame is awaiting a slot answer ("dasain durga bhajans" would be misrouted as a fresh command today)
    When the user says "dasain durga bhajans"
    Then the utterance is handled as an answer to the frame
    And it is not routed through the keyword ladder or the interpreter as a fresh command

  Scenario: After resolution the next utterance is routed normally again
    Given the frame resolved (executed, cancelled or timed out) on the previous turn
    When the user speaks a new command
    Then the utterance is routed as a fresh command exactly as today
    And no stale interception consumes it

  Scenario: The interception runs at the confirmation hook's position, before the ladder
    Given a frame is awaiting an answer
    When the answer turn is processed
    Then the answer path is evaluated before the keyword ladder and before the interpreter
    And the frame's rules decide the outcome
```

#### Related
- FR: FR-MTC-010 (cancel), FR-MTC-011 (emergency), FR-MTC-012 (barge-in), FR-MTC-006 (merge), FR-MTC-013 (timeout as the disarming edge)
- NFR: NFR-MTC-008 (no new injection surface), NFR-MTC-012 (ladder behaviour unchanged outside the window)

### FR-MTC-010: Cancel words drop the frame with an honest line

#### Metadata
- **Area:** Interception / Cancel
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 2 ("Frames must never trap the user. Cancel words drop the frame with an honest line") and the answer-turn contract step 1 ("Cancel detection — cancel words ('होइन', 'रद्द', 'never mind') drop the frame with an honest line"); feasibility study §6.3.1.

#### Description
While a probe is awaiting an answer, cancel words in the active language ('होइन', 'रद्द', 'never mind' — the localized set) **must** drop the frame immediately:

- **Drops the frame**: pending command, candidates and attempts are cleared; nothing executes; the 45 s deadline disarms; the next utterance is a fresh command.
- **Honest line**: an explicit, localized acknowledgement is spoken (e.g. "ठीक छ" — exact copy is design/localisation; the requirement is an explicit spoken outcome, never silence, never a pretence that something played). No new UI.
- **Never a trap**: the cancel path resolves even at the attempt cap, mid-probe, in both probe kinds.
- **Interaction with a correction carried along** ("होइन, दुर्गा भजन"): the existing no-with-amendment precedent (`CommandRouter.swift:811-821`, where "होइन, फोन नै गर" amends a slot rather than rejecting) is the design input for composing negative words that carry content; the design must ensure a bare cancel drops the frame and a negative-plus-correction is not silently discarded. The requirement binds: cancel never dead-ends and never executes unasked.
- **Safety unaffected**: emergency precedence still outranks everything (FR-MTC-011); cancel handling cannot be used to bypass safety checks (NFR-MTC-008).

#### Acceptance criteria

```gherkin
Feature: Cancel words drop the frame

  Scenario: A bare cancel mid-probe drops the frame with an honest line
    Given the slot-fill probe is outstanding
    When the user says "होइन" (or "रद्द" / "never mind")
    Then the frame is dropped immediately
    And an explicit localized acknowledgement is spoken
    And nothing (playback or any other action) is executed

  Scenario: Cancel still resolves cleanly at the attempt cap
    Given the frame has spent its probe attempts
    When the user cancels
    Then the frame is dropped with the honest line
    And the default execution of FR-MTC-007 does not fire

  Scenario: After a cancel the next utterance is a fresh command
    Given the user just cancelled
    When the user says "मेरो छोरालाई फोन गर" ("call my son")
    Then the new command is routed normally
    And no residue of the dropped frame affects it
```

#### Related
- FR: FR-MTC-009 (interception), FR-MTC-011 (emergency precedence), FR-MTC-013 (the other drop path), FR-MTC-006 (the merge path it forbids)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-006 (localisation)

### FR-MTC-011: Emergency precedence is absolute mid-frame

#### Metadata
- **Area:** Safety / Emergency
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 1 ("Emergency precedence is absolute. Emergency keywords must always win mid-dialogue — the override is checked before any frame merge. Emergency dispatch and medication re-fire are frame-independent ... A hostile or corrupted answer cannot bypass the emergency precedence rule"); feasibility study §6.3.2; project constitution safety-critical constraints (emergency logic must not be blocked by anything); worktree precedent verified: emergency runs before the confirmation hook today (`CommandRouter.swift:779-783`, "Emergency outranks even an outstanding confirmation").

#### Description
During any active dialogue frame, emergency keywords **must** always win — the mid-dialogue generalization of the existing rule that emergency outranks an outstanding confirmation (`CommandRouter.swift:779-783`). Binding properties:

- **Checked before any frame merge**: the emergency override is evaluated on every answer turn before cancel handling, before answer capture, before the merge and before any dispatch of the pending command.
- **The frame never blocks emergency**: an emergency keyword mid-probe (e.g. "मद्दत" during the bhajan question) triggers the normal emergency path and drops the frame; it is never parsed as an answer, candidate, index word or cancel.
- **Frame-independent safety behaviour**: emergency dispatch and medication re-fire behave exactly as today regardless of any active frame — the frame machinery adds zero conditions to those paths (NFR-MTC-012).
- **Hostile answers cannot bypass it**: a crafted or corrupted answer that contains an emergency keyword — or that tries to hide one — must not be merged or executed ahead of the emergency check; no answer path may precede or skip the emergency precedence rule (NFR-MTC-008; workflow `security-design-review` focus area).
- This is a safety-critical requirement: it carries a failure scenario in addition to the happy paths below.

#### Acceptance criteria

```gherkin
Feature: Emergency precedence mid-frame

  Scenario: An emergency keyword mid-probe triggers emergency handling and drops the frame
    Given the frame is awaiting an answer to a probe
    When the user says an emergency keyword ("मद्दत" / "help me")
    Then the emergency path is triggered exactly as with no frame active
    And the frame is dropped
    And the utterance is not treated as an answer, candidate or cancel

  Scenario: An active frame changes nothing about emergency or medication behaviour
    Given a frame is active
    When the emergency dispatch path or the medication re-fire path is exercised
    Then its behaviour is identical to the no-frame case
    And the frame machinery contributes no gating, delay or condition to those paths

  Scenario: A hostile answer cannot precede the emergency check (failure scenario)
    Given the frame is awaiting an answer
    When a crafted or corrupted answer contains an emergency keyword or attempts to hide one behind answer content
    Then the emergency override still wins, checked before any frame merge
    And no pending command is executed ahead of the emergency check
    And no answer content can bypass, skip or weaken the rule
```

#### Related
- FR: FR-MTC-009 (interception order), FR-MTC-010 (cancel), FR-MTC-012 (barge-in), FR-MTC-006 (merge it outranks)
- NFR: NFR-MTC-008 (injection safety of the answer path), NFR-MTC-005 (degraded-brain path must not weaken safety gates), NFR-MTC-010 (trap resistance), NFR-MTC-012 (no regression)

### FR-MTC-012: Barge-in — a strong new command drops the frame

#### Metadata
- **Area:** Interception / Barge-in
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Barge-in rule: an utterance that looks like a *different* command mid-frame (strong deterministic match, e.g. 'call my son') drops the frame and executes the new command; ambiguous utterances are treated as answers. This is the behaviour elderly users expect and it prevents the frame from trapping them"; Safety-Relevant Constraint 2; feasibility study §6.3 (barge-in paragraph).

#### Description
While a probe is awaiting an answer, an utterance that is a **strong deterministic match for a different command** must take priority:

- **Strong new command → barge-in**: the frame is dropped (pending command, candidates and attempts cleared; deadline disarmed) and the new command executes through the normal routing path exactly as today (e.g. "मेरो छोरालाई फोन गर" / "call my son" mid-probe places the call — subject to the normal confirmation tiers for sensitive actions, which are unchanged).
- **Ambiguous utterances are answers**: anything that is not a strong deterministic match for a different command is treated as an answer to the probe (capture per FR-MTC-005, re-probe under the cap per FR-MTC-007) — the frame is never dropped on a guess and never executes the pending command from an ambiguous utterance.
- **Repetition is not barge-in**: repeating a candidate (optionally with the pending command's own verb, "दुर्गा भजन बजाऊ") is an answer (FR-MTC-005), not a new command — the check is for a *different* command with a strong match.
- **This is the anti-trap rule**: users who change their mind mid-dialogue must be able to redirect the assistant immediately; the frame must never hold the user hostage to the question it asked (NFR-MTC-010).

#### Acceptance criteria

```gherkin
Feature: Barge-in on a strong new command

  Scenario: A strong new command mid-probe executes and drops the frame
    Given the music probe is outstanding
    When the user says "मेरो छोरालाई फोन गर" ("call my son") — a strong deterministic match for a different command
    Then the frame is dropped
    And the call command executes through the normal routing path (with its normal confirmation tiers)

  Scenario: An ambiguous utterance is treated as an answer, not a barge-in
    Given the probe is outstanding
    When the user says something that is not a strong match for any different command
    Then it is treated as an answer attempt to the probe
    And the frame is not dropped and no different command is executed from the ambiguity

  Scenario: Repetition of the candidate with the pending verb is an answer, not a barge-in
    Given the music probe is outstanding
    When the user says "दुर्गा भजन बजाऊ"
    Then it is captured as the answer (FR-MTC-005)
    And it is not executed as a fresh independent command
```

#### Related
- FR: FR-MTC-005 (repetition as answer), FR-MTC-009 (interception), FR-MTC-011 (emergency outranks barge-in too), FR-MTC-013 (the other drop path)
- NFR: NFR-MTC-010 (frame-trap resistance), NFR-MTC-012 (command routing unchanged for the barged-in command)

### FR-MTC-013: 45 s timeout — silent drop and re-arm

#### Metadata
- **Area:** Timeout / Recovery
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Timeout / abandonment — 45 s expiry drops the frame silently and re-arms; the user's next utterance is a fresh command. No stuck state, no persistence." and Safety-Relevant Constraint 2 ("a 45 s timeout silently drops and re-arms"); feasibility study §6.3.5 and §8 ("Elderly user walks away mid-dialogue — 45 s expiry, silent drop, re-arm; no persistence, no stuck state"); worktree precedent verified: the confirmation timer is 45 s (`VoiceSessionStateMachine.swift:93-96`, `confirmationTimeoutSeconds = 45`).

#### Description
Every frame **must** expire at its deadline (45 s — the reused confirmation timer, FR-MTC-014) and recover silently:

- **Silent drop**: on expiry the frame is dropped without a scolding or a "time's up" line (this differs deliberately from the confirmation timeout's spoken notice); nothing is executed, nothing is spoken.
- **Re-arm**: the session returns to idle listening exactly as after any completed turn; the pipeline's normal re-arm applies; the user's next utterance is a fresh command handled by normal routing (FR-MTC-009's interception is disarmed).
- **No stuck state, no persistence**: after expiry there is no frame, no timer, no residue; a later utterance can never be interpreted as an answer to the expired probe.
- **Boundary correctness**: an utterance arriving while the window is open is an answer (including just before expiry); once expired, the same utterance is a fresh command. There is no half-open window.
- This is a safety-relevant recovery path: it carries a failure (anti-trap) scenario in addition to the happy path.

#### Acceptance criteria

```gherkin
Feature: 45 s timeout recovery

  Scenario: Expiry drops the frame silently without executing anything
    Given the probe is outstanding and the user has not answered
    When 45 s elapse
    Then the frame is dropped with no spoken scolding and nothing executed
    And the session is listening normally again

  Scenario: The next utterance after expiry is a fresh command (failure/anti-trap scenario)
    Given the frame just expired
    When the user says "गीत चलाऊ" ("play a song")
    Then the utterance is routed as a fresh command
    And it is never interpreted as an answer to the expired probe

  Scenario: An answer inside the window is still an answer, even at the last moment
    Given the probe is outstanding and the deadline has not yet passed
    When the user answers
    Then the answer is captured and merged (FR-MTC-005/006)
    And the expiry does not race the merge into a contradictory outcome
```

#### Related
- FR: FR-MTC-014 (the timer), FR-MTC-009 (interception disarming), FR-MTC-007 (the other termination), FR-MTC-001 (frame cleared on resolution)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-001 (timeout envelope vs the 60 s watchdog)

### FR-MTC-014: `awaitingSlotAnswer` session state with the 45 s timer reuse

#### Metadata
- **Area:** Session State
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Integration Surfaces ("`VoiceSessionStateMachine.swift` — New `awaitingSlotAnswer` state alongside `awaitingConfirmation` (states at 15–16; the 45 s timer at 91–127 is reused)") and the answer-turn contract step 5; feasibility study §4 (the `awaitingConfirmation` state + 45 s timeout as "the dialogue state slot to extend") and §6.2 ("Enter `awaitingSlotAnswer` ... same 45 s timer"); worktree surfaces verified: the state list and transition table (`VoiceSessionStateMachine.swift:9-79`), the timer config and arming (`:93-96`, `:183-203`).

#### Description
The voice session state machine **must** gain an `awaitingSlotAnswer` state beside `awaitingConfirmation`, with the same machinery guarantees:

- **Entered when a probe is spoken** — the slot-fill or did-you-mean probe opens the state; the answer window exists from the moment the question is asked (the same "the window must EXIST, not merely be attempted" discipline the app-launcher fix established via `openConfirmationWindow()`, `VoiceSessionStateMachine.swift:153-181`).
- **45 s timer reused** — the deadline is the existing confirmation timer value (45 s, `confirmationTimeoutSeconds`); entering the state arms it, every resolution cancels it; the timer expiry drives FR-MTC-013 (silent drop and re-arm).
- **Legal transitions only** — the transition table is extended so every entry and exit edge used by the frame path is legal (no debug assertion, no release-mode silent no-op that would strand the window); the busy→`awaitingSlotAnswer` entry mirrors the confirmation window's entry rules, and every resolution (execute, cancel, barge-in, timeout, escape) returns the session to idle legally.
- **Coexistence** — the new state never breaks the confirmation state: the two windows never exist at once; the confirmation flow behaves exactly as today (NFR-MTC-012).
- **Backstops intact** — the 60 s voice watchdog and the manual Talk-button recovery keep working; the state adds no new stuck path (NFR-MTC-010).

#### Acceptance criteria

```gherkin
Feature: The awaitingSlotAnswer session state

  Scenario: Speaking a probe enters the state and arms the 45 s window
    Given a probe is triggered (slot-fill or did-you-mean)
    When the probe is spoken
    Then the session enters awaitingSlotAnswer
    And the 45 s timer is armed

  Scenario: Every resolution exits the state legally and cancels the timer
    Given the session is in awaitingSlotAnswer
    When the frame resolves via answer-merged, cancel, barge-in, escape or timeout
    Then the session exits to idle through a legal transition
    And the timer is cancelled
    And no debug illegal-transition assertion fires

  Scenario: The confirmation window is unaffected
    Given a confirmation (yes/no) challenge is outstanding
    When it resolves
    Then its behaviour is byte-for-byte today's
    And awaitingSlotAnswer machinery is not involved
```

#### Related
- FR: FR-MTC-013 (timer expiry behaviour), FR-MTC-001 (frame), FR-MTC-009 (interception active window)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-012 (confirmation flow unchanged)

### FR-MTC-015: Curated on-device option catalog

#### Metadata
- **Area:** Option Catalog
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Integration Surfaces ("**NEW** curated on-device music option catalog — Bhajan deity → canonical search query; zero latency; consistent with the on-device stance (study §5.4)") and the Probe Kinds table ("Candidate source: the curated on-device catalog (bhajan deity → canonical search query)"); feasibility study §5.4 (option 1, recommended MVP) and §6.2 ("Options come from the curated catalog (5.4), never the model"); OD-M2 (OPEN — curated catalog vs live Spotify playlist search; the study recommends the curated on-device catalog for the MVP).

#### Description
The probe options and the canonicalisation input **must** come from a curated, on-device catalog:

- **Structure**: a small local mapping (bhajan deity → canonical search query, e.g. दुर्गा → "durga bhajan") covering the launch option list(s); the exact contents are data, not code, and are refined at design time (OD-M2 may extend the sourcing later — the Phase 1 binding is the on-device curated catalog).
- **On-device stance**: zero network, zero latency, works offline; no new egress (NFR-MTC-003); consistent with Architecture Constraint 1 and the Spotify feature's privacy disclosure (music-query egress remains only the existing search path).
- **Localizable ne/en**: option names and their spoken forms exist in both languages (NFR-MTC-006); the canonical query values are the deterministic strings the music search consumes.
- **Informational, not restrictive**: the catalog shapes the probe's options and canonicalises matching answers (FR-MTC-006); it never limits what the user may say — free-form answers always flow (FR-MTC-005).
- **Deterministic**: catalog lookup is a pure, model-free function of the answer text (NFR-MTC-005).

#### Acceptance criteria

```gherkin
Feature: Curated on-device option catalog

  Scenario: The bhajan probe's options come from the catalog in the active language
    Given the slot-fill probe is triggered for a bhajan request
    When the probe is spoken
    Then the named options are the catalog entries rendered in the user's active language
    And a catalog default option is available

  Scenario: A catalog-matching answer canonicalises to the canonical query
    Given the user answers "दुर्गा"
    When the deterministic merge runs
    Then the merged search query is the catalog's canonical value for that entry ("durga bhajan")

  Scenario: The catalog works with no network
    Given the device is offline
    When the probe is spoken and answered with a catalog option
    Then the probe and the canonicalisation both work with zero network access
```

#### Related
- FR: FR-MTC-003 (the probe that uses it), FR-MTC-005 (free text overrides any list), FR-MTC-006 (canonicalisation in the merge)
- NFR: NFR-MTC-003 (no new egress), NFR-MTC-006 (localisation), NFR-MTC-005 (deterministic), NFR-MTC-001 (zero added latency)

### FR-MTC-016: Template-generated probes, localized ne/en — never model-generated

#### Metadata
- **Area:** Probe Generation / Localisation
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 2 ("Template-generated probes only (localized ne/en). Never model-generated. The model never writes probe text.") and "Probe Kinds & Answer-Capture Contract" ("both are template-driven"); feasibility study §5.2 ("**Probes must therefore be template-generated, never model-generated. The model's job in multi-turn is narrow: classify the *answer* utterance against the active frame*") and §6.2; project constitution Standards (localisation; voice-first accessibility).

#### Description
Every spoken element of the dialogue mechanics **must** be a static, localized template — never model-generated:

- **Covered text**: the probe questions (both kinds), the option lists and their spoken forms, the default offer, the honest not-understood line, the cancel acknowledgement, the escape acknowledgement, and the index words — all static strings with ne/en entries (FR-MTC-015 supplies option *data*; this requirement binds its spoken rendering).
- **Never model-generated**: no probe line may be produced by the brain or any generative model, in any phase. The model's only multi-turn job is classifying the answer against the active frame (Phase 2, FR-MTC-018) — never writing what the user hears.
- **Deterministic with a degraded or absent brain**: with the brain absent, downloading, or pressure-evicted, the spoken probe text is byte-identical to the template (NFR-MTC-005); no dialogue element degrades to silence or improvisation.
- **Elderly-appropriate and short**: probes are short spoken lines; option counts stay within the bounds (≤3–4 slot-fill, ≤2–3 did-you-mean) so the spoken list is memorable (NFR-MTC-009).
- **Localized at the string catalog**: new keys exist in both ne and en (NFR-MTC-006), following the project's externalised-string discipline (`spotify.*`-style key families).

#### Acceptance criteria

```gherkin
Feature: Template-generated probes

  Scenario: The probe text is byte-identical to the template regardless of brain state
    Given the probe is triggered while the brain is absent (or evicted)
    When the probe is spoken
    Then the spoken text equals the localized template string for that probe
    And no model call produced any part of it

  Scenario: Each language hears its own templates
    Given the active language is Nepali
    When any probe, honest line, default offer or acknowledgement is spoken
    Then it is the Nepali template
    And with English active, it is the English template

  Scenario: No generative call is made to produce dialogue text
    Given any probe or dialogue line is about to be spoken
    When the turn is traced
    Then no interpreter/model invocation exists on the path that produces that text
```

#### Related
- FR: FR-MTC-003/FR-MTC-004 (the probes), FR-MTC-008 (escape line), FR-MTC-010 (cancel line), FR-MTC-018 (the model's Phase 2 role: answer classification only)
- NFR: NFR-MTC-006 (localisation), NFR-MTC-005 (degraded-brain determinism), NFR-MTC-009 (voice-only accessibility)

### FR-MTC-017: Transcript-cache bypass during answer capture

#### Metadata
- **Area:** Cache Discipline
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 7 ("During `awaitingSlotAnswer`, the transcript cache (`IntentCommandCache`) is bypassed — answers are never cacheable inputs; only confirmed *merged* commands are recorded"); feasibility study §8 ("`IntentCommandCache` short-circuits the frame — during `awaitingSlotAnswer`, bypass the transcript cache (answers are never cacheable inputs); only confirmed *merged* commands are recorded"); worktree surface verified: `Services/Intents/IntentCommandCache.swift` (normalized-transcript → command cache sitting "in `IntentRouter` BEFORE any model", header invariants `:1-27`).

#### Description
While a frame is awaiting an answer, the normalized-transcript → command cache (`IntentCommandCache`) **must** be bypassed on both directions of its interface:

- **No cache reads for answers**: the answer transcript is never resolved from the cache — an answer is frame-relative (e.g. a bare "दुर्गा" is only meaningful against the outstanding probe) and must never be executed as a standalone cached command. The interception (FR-MTC-009) and the deterministic merge (FR-MTC-006) own the answer turn.
- **No cache writes for answers**: answer utterances are never recorded as cacheable transcripts; the cache's "freshest **confirmed** interpretation wins" discipline only ever sees confirmed command executions.
- **Only confirmed merged commands may be recorded**: after a merged command actually executes (with the normal confirmation discipline for its tier), the existing caching rules apply to that confirmed execution — and `IntentCommandCache.isCacheable` semantics stay unchanged (music remains cacheable for real commands; answers, which never execute standalone, are not candidates).
- **After resolution, normal caching resumes**: once the frame resolves, the next real command uses the cache exactly as today (its first-hit speed and its confirmation invariants unchanged; NFR-MTC-012).
- **Answer text stays out of any cross-session store**: no answer transcript is interned into the encrypted cache store or any other persistence (FR-MTC-001's no-persistence rule).

#### Acceptance criteria

```gherkin
Feature: Transcript-cache bypass during answer capture

  Scenario: An answer that exactly matches a cached transcript is not served from the cache
    Given the transcript "दुर्गा" exists in the command cache from some earlier confirmed command
    And the frame is awaiting an answer
    When the user says "दुर्गा" as the answer
    Then the cache does not resolve it
    And the answer is handled by the frame's capture and merge path

  Scenario: An answer is never interned into the cache
    Given the user answers a probe (valid, invalid, or cancelled)
    When the turns complete
    Then no answer transcript is recorded as a cacheable entry

  Scenario: A confirmed merged command is recorded and behaves like any confirmed execution
    Given the probe answered with "दुर्गा भजन" and the merged command executed and completed its normal confirmation discipline
    When the user next says a real command that is cacheable
    Then the cache behaves exactly as today for that command
    And nothing about the bypass changed the cache's normal semantics
```

#### Related
- FR: FR-MTC-009 (interception owns the answer turn), FR-MTC-006 (merge), FR-MTC-001 (no persistence)
- NFR: NFR-MTC-012 (cache semantics unchanged outside the window), NFR-MTC-008 (no new injection surface via cached answers)

### FR-MTC-018: Phase 2 — follow-up NLU fine-tune v17 with the frame clause

#### Metadata
- **Area:** NLU Training (Phase 2)
- **Priority:** SHOULD (Phase 2 — ships only with the training iteration; escalates to MUST if OD-M3 sequences it into the release)
- **Phase:** Phase 2 (later phase — follow-up NLU fine-tune v17; data authoring may proceed in parallel per OD-M3, but the clause ships ONLY with the training iteration)
- **Source:** Feature constitution "In scope" Phase 2 ("follow-up-turn training data (golden corpus + synthetic follow-ups), `prompt_template` mirror update, LoRA on the existing training pipeline, query-slot gates, brain-assisted frame merge"), Feature Constraint 5 ("The Phase 2 frame clause ships only together with the v17 training iteration ... mirrored byte-identically in `tools/train-intent/seeds/prompt_template.txt` in the same change, and must not alter the `.raw` framing") and the answer-turn contract step 4 ("Optional brain resolution (Phase 2 only)"); feasibility study §6.3.4 (the frame clause), §6.4 (constraints), §7 Phase 2; OD-M3 (OPEN — sequencing).

#### Description
Phase 2 turns the same dialogue mechanism from curated to general via the follow-up NLU iteration. Binding properties:

- **Follow-up-turn training data**: golden-corpus additions plus synthetic follow-ups (e.g. a bare "दशैं दुर्गा भजन" against frame-marked contexts), covering the answer forms of FR-MTC-005 and both probe kinds.
- **Frame clause ships ONLY with the training iteration**: the optional brain-resolution clause (a compact "answer to the earlier question about music; missing detail: kind of bhajan" addition inside the ~300-token headroom) is injected into the runtime prompt **only** in the same change that ships the retrained model (v17) and its training data — injecting it without training data is the named prompt-identity-drift hazard (NFR-MTC-002, NFR-MTC-011).
- **Prompt mirror byte-identical**: `tools/train-intent/seeds/prompt_template.txt` is updated in the same change and stays byte-identical to the runtime prompt template; the `.raw` framing (no system turn) is not altered.
- **Query-slot gates**: new query-slot accuracy gates run alongside the existing contact/time slot gates (the slot-canon precedent: gates fail → retrain, don't ship).
- **Brain-assisted frame merge (optional resolution)**: when the deterministic merge cannot extract a value (e.g. "the one from yesterday"), the answer turn may ask the brain once with the compact frame clause; if the brain is unavailable, the system asks one more probe (within the cap) and then executes with defaults (FR-MTC-007) — Phase 1's deterministic path remains the floor at all times (NFR-MTC-005).

#### Acceptance criteria

```gherkin
Feature: Phase 2 follow-up NLU (v17)

  Scenario: The frame clause is never injected without its training iteration
    Given a release built without the v17 follow-up training artifacts
    When answer turns are processed
    Then the frame clause is not present in any prompt
    And the deterministic merge path is used

  Scenario: The training mirror is byte-identical in the same change
    Given the frame clause is added to the runtime prompt template
    When the change is inspected
    Then tools/train-intent/seeds/prompt_template.txt is updated in the same change
    And the mirror is byte-identical to the runtime template
    And the .raw framing is unaltered

  Scenario: Brain-assisted resolution merges an otherwise-unmergeable answer
    Given the deterministic merge cannot extract a value from the answer ("the one from yesterday")
    And the v17 brain is available
    When the answer turn runs
    Then the brain resolves the answer against the compact frame clause
    And the merged command executes through the normal path

  Scenario: A brain-unavailable answer still terminates cleanly
    Given the deterministic merge cannot extract a value
    And the brain is unavailable
    When the answer turn runs
    Then the system asks one more probe (within the cap)
    And then executes with defaults if the answer remains unresolved
```

#### Related
- FR: FR-MTC-006 (the deterministic floor), FR-MTC-007 (probe cap), FR-MTC-016 (the model never writes probe text)
- NFR: NFR-MTC-002 (prompt budget), NFR-MTC-011 (KV-prefix stability), NFR-MTC-005 (degraded-brain floor)

### FR-MTC-019: Phase 3 — reminder/calendar missing-slot re-prompts on the frame path

#### Metadata
- **Area:** Rollout (Phase 3)
- **Priority:** SHOULD (Phase 3 — rides the release only if the owner resolves OD-M4 to include it)
- **Phase:** Phase 3 (later phase — after the frame mechanics are proven on music; Phase 1 leaves reminder/calendar turns unchanged)
- **Source:** Feature constitution "In scope" Phase 3 ("roll the same frame path over the existing stateless reminder/calendar missing-slot re-prompts; `RepetitionGuard` interplay; DV-* device validation") and "Out of scope (must not change)" ("Reminder/calendar turns are unchanged in Phase 1 (Phase 3 is where they move onto the frame path)"); feasibility study §4 (missing-slot ask-lines as today's stateless re-prompts), §6.2 (the same mechanism upgrades them) and §7 Phase 3; OD-M4 (OPEN — scope).

#### Description
Phase 3 extends the same dialogue-frame mechanism to the existing **stateless** missing-slot re-prompts in the reminder and calendar paths — reminder without a time and calendar event without a title/time currently speak a missing-slot question, but the follow-up utterance is routed as a fresh command (no frame). The Phase 3 behaviour:

- **Same frame mechanics**: the missing-slot question becomes a `.slotFill` frame on the same `DialogueManager`/`DialogueFrame` path, with the same interception (FR-MTC-009), capture (FR-MTC-005), deterministic merge (FR-MTC-006), cancel/barge-in/timeout rules (FR-MTC-010/012/013) and probe budget (FR-MTC-007).
- **The follow-up fills the slot**: e.g. the reminder "what time?" answer ("बेलुका आठ बजे") merges into the pending reminder command instead of being misrouted as a fresh command.
- **`RepetitionGuard` interplay**: the existing cross-turn memory of recent confirmed actions (dementia-loop protection) must keep working with the frame path — repetition protection is not weakened by dialogue frames.
- **Phase-gated**: this requirement is not built or shipped in Phase 1 — reminder/calendar behaviour stays exactly as today until the owner resolves OD-M4 (and the phase sequencing per OD-M3); NFR-MTC-012 binds the Phase 1 no-change.
- **Same safety rules**: the reminder/calendar answer path inherits every safety constraint (emergency precedence absolute, log safety, sanitisation).

#### Acceptance criteria

```gherkin
Feature: Phase 3 reminder/calendar frame rollover

  Scenario: (Phase 3) A reminder missing its time becomes an answer-capture frame
    Given Phase 3 is shipped
    When the user asks for a reminder without a time and the missing-slot question is asked
    Then the session enters the frame path (awaitingSlotAnswer)
    And the user's next answer ("बेलुका आठ बजे") merges into the pending reminder
    And the reminder is created with the spoken time confirmation as usual

  Scenario: (Phase 3) RepetitionGuard still protects against loops on the frame path
    Given Phase 3 is shipped and the user repeats the same confirmed action in a loop
    When the frame path is involved
    Then RepetitionGuard's existing protection behaves exactly as today

  Scenario: (Phase 1 guard) Reminder/calendar turns are unchanged until Phase 3 ships
    Given a Phase 1 build (this feature's deterministic MVP)
    When a reminder lacks a time or a calendar event lacks a title
    Then today's stateless re-prompt behaviour is byte-for-byte unchanged
    And no awaitingSlotAnswer frame is opened by those paths
```

#### Related
- FR: FR-MTC-006 (the merge it reuses), FR-MTC-020 (device validation), FR-MTC-002 (the music-path precedent)
- NFR: NFR-MTC-012 (Phase 1 no-change), NFR-MTC-010 (trap resistance for the reminder flow)

### FR-MTC-020: DV-* device validation recorded and passed (completion gate)

#### Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Phase:** Completion gate (device validation on Anzaan; per the study §7 the DV checklist closes the feature — run before final sign-off)
- **Source:** Feature constitution "Completion gate — DV-* device validation on Anzaan (the DV pattern of prior shipped features, recorded with the feature spec)" (DV-1 … DV-5) and "Phase 0 prerequisite: the outstanding PR #156 device smoke — conversation → no jetsam → pull JetsamEvent logs — must be run as the Phase 0 gate"; feasibility study §7 (Phase 0/Phase 3); workflow `final-sign-off` comment ("DV-* device validation on Anzaan is part of the completion gate"); precedent: `SP-device-validation-protocol.md` / `LCT-device-validation-protocol.md`.

#### Description
The feature **must not** be considered done until the DV-* checklist is executed on the reference device (Anzaan) and recorded with the feature spec, in the same shape as the prior shipped features' device-validation records:

- **DV-1 — probe → answer → correct playback** (the owner's bhajan example): "play bhajans" → probe → "dasain durga bhajans" → dasain durga bhajan playback.
- **DV-2 — timeout**: 45 s expiry drops the frame silently and re-arms; the next utterance is a fresh command.
- **DV-3 — barge-in**: a strong new command mid-frame executes and drops the frame.
- **DV-4 — mid-dialogue degraded-brain turn**: the deterministic merge carries the dialogue when the brain is degraded/absent.
- **DV-5 — sustained multi-turn without jetsam**: post-conversation JetsamEvent log pull shows no voice-stack kills (NFR-MTC-007).
- **Phase 0 prerequisite first**: the outstanding PR #156 device smoke (conversation → no jetsam → pull JetsamEvent logs) is run and recorded **before** the DV-* work begins (feature constitution Phase 0; scope comment "Phase 0 prerequisite: PR #156 ... its Anzaan device smoke is still outstanding").
- **Recorded results**: each DV item is recorded as passed/failed with the evidence (log pulls, session notes) attached to the feature spec; a failure blocks final sign-off until fixed and re-run — no silent waiver.

#### Acceptance criteria

```gherkin
Feature: Device-validation completion gate

  Scenario: Every DV item is executed on Anzaan and recorded
    Given the Phase 0 prerequisite smoke is complete
    When final validation runs
    Then DV-1 through DV-5 are each executed on the reference device
    And each result (pass/fail with evidence) is recorded with the feature spec

  Scenario: The Phase 0 prerequisite is satisfied before DV work
    Given PR #156's device smoke has not yet been run
    When device validation is about to start
    Then the smoke (conversation → no jetsam → JetsamEvent pull) is run and recorded first
    And its result is attached to the feature record

  Scenario: A failed DV blocks completion (failure scenario)
    Given any DV item fails (e.g. DV-5 shows a voice-stack jetsam kill)
    When completion is assessed
    Then the feature does not pass final sign-off
    And the failure is fixed and the item re-run before sign-off proceeds
```

#### Related
- FR: FR-MTC-013 (DV-2), FR-MTC-012 (DV-3), FR-MTC-006 (DV-4), FR-MTC-003/006 (DV-1)
- NFR: NFR-MTC-007 (DV-5 stability), NFR-MTC-012 (release gates)

## Non-functional requirements

### NFR-MTC-001: Probe and answer turns stay within the existing turn envelope

#### Metadata
- **Category:** Performance
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feasibility study §6.5 ("Latency budget: one probe adds exactly one full turn's latency (seconds), within the existing 22 s capture / 45 s hold / 60 s watchdog envelope"); worktree surfaces verified: `VoicePipeline.captureTimeoutSeconds = 22` (`VoicePipeline.swift:130`), `turnPendingSafetySeconds = 45` (`:275`), `voiceWatchdogSeconds = 60` (`AppCoordinator.swift` ~`:4867`).

#### Description
A probe dialogue **must** fit the existing voice-turn time budgets; it adds no new waiting mechanism:

- **One extra turn, no extra round trip**: the probe adds exactly one full turn's latency (the question turn); the probe itself is decided and spoken within that turn — it waits on no model and no network (template text, on-device catalog). The answer turn then behaves like a normal turn.
- **Existing envelope preserved**: the coupled timers are not changed or exceeded — 22 s capture (`captureTimeoutSeconds`), 45 s pending-turn hold (`turnPendingSafetySeconds`), 60 s voice watchdog (`voiceWatchdogSeconds = 60` = 47 s worst legitimate turn + margin). The frame deadline (45 s, FR-MTC-013) sits inside the envelope; a dialogue timeout must never be able to trip the 60 s watchdog.
- **Measurable target**: with no network and no models loaded, probe speech begins on the same turn as the probe decision (no cross-turn hop added beyond today's reply lane); the full probe→answer→execute sequence completes within the watchdog envelope with margin.

#### Acceptance criteria

```gherkin
Feature: Probe latency envelope

  Scenario: The probe is spoken without any model or network wait
    Given a degenerate music request triggers the probe
    When the probe turn runs with no network and no brain loaded
    Then the probe line is spoken on that same turn
    And no additional round trip beyond the normal reply lane occurs

  Scenario: The dialogue fits inside the existing time budget
    Given a probe is outstanding
    When the user answers before the 45 s deadline
    Then the merged execution starts on the answer turn exactly like a normally spoken command
    And the 60 s voice watchdog is never reached by the dialogue

  Scenario: The timeout couplings stay unchanged
    Given the feature is built
    When the capture / pending-hold / watchdog values are inspected
    Then they remain 22 s / 45 s / 60 s respectively
    And the frame deadline uses the existing 45 s confirmation timer value
```

#### Related
- FR: FR-MTC-013 (the 45 s deadline), FR-MTC-014 (timer reuse), FR-MTC-003 (template probe)
- NFR: NFR-MTC-011 (prefix reuse keeps later turns cheap)

### NFR-MTC-002: 1024-token ceiling and the pinned prompt budget are preserved

#### Metadata
- **Category:** Reliability / Maintainability
- **Priority:** MUST
- **Phase:** Phase 1 binding for state placement; the frame clause itself is Phase 2 (ships only with the v17 iteration)
- **Source:** Feature constitution Feature Constraint 1 ("1024-token ceiling. The brain context is a measured memory ceiling (2048 crashed 6 GB devices — study §5.1). Dialogue state lives in the app, never as transcript history in prompts. Any prompt clause must fit the ~300-token headroom inside the pinned `IntentPromptTests` budget") and Feature Constraint 5 (clause inside the pinned budget, mirror discipline); feasibility study §5.1 (measured: composed prompt ~696 qwen3 tokens, ~300 left for utterance + output, ~128 reserved; two shipped overflow bugs) and §6.4; worktree surfaces verified: `maxTokenCount: 1024` (`LlamaCommandInterpreter.swift:1199`, 2048-crash comment `:1159-1163`), the `IntentPromptTests` 3,000-character regression pin (measured 2,506 characters for the fixture, 2026-10-05) and the 696 qwen3-token measurement note (`IntentPromptTests.swift:105-131`).

#### Description
The feature **must** respect the measured 1024-token brain context and the pinned prompt budget:

- **Dialogue state lives in the app, never in the prompt**: no transcript history, no turn array, no conversation log is ever added to the intent prompt (Phase 1 adds **0** prompt tokens; the frame is app state — FR-MTC-001).
- **Frame clause within the headroom (Phase 2)**: any frame clause must fit the ~300-token remaining budget (1024 context = ~696-token measured template + ~128-token output reserve + utterance); the study's sizing guidance is ~30–60 tokens. The clause ships only with the v17 training iteration (FR-MTC-018).
- **The pin must not be raised**: `IntentPromptTests`' regression tripwire (build() ≤ 3,000 characters for the pinned fixture; the pre-fix 2,361-token overflow is the named failure) stays in force and is not relaxed by this feature; with the clause present the test still passes.
- **`.raw` framing unchanged**: no system turn, no wrapper change (Feature Constraint 5); the prompt prefix stays byte-stable (NFR-MTC-011).

#### Acceptance criteria

```gherkin
Feature: Prompt budget preservation

  Scenario: Phase 1 adds zero prompt tokens for dialogue state
    Given a dialogue frame is active
    When a command turn builds its intent prompt
    Then the prompt is identical to the no-frame prompt for the same utterance (no frame, history or state text added)

  Scenario: The Phase 2 clause stays inside the pinned budget
    Given the v17 iteration ships with the frame clause
    When IntentPromptTests runs
    Then build() stays within the 3,000-character pin and the 1024-token context
    And the pin value has not been raised

  Scenario: No transcript history accumulates across dialogue turns
    Given N consecutive dialogue turns have completed
    When an equivalent utterance builds its prompt
    Then its prompt size and prefix are identical to the first turn's
    And no utterance history is present
```

#### Related
- FR: FR-MTC-018 (the clause and its shipping condition), FR-MTC-001 (state in the app)
- NFR: NFR-MTC-011 (prefix stability), NFR-MTC-005 (brain-free floor)

### NFR-MTC-003: No new network egress — probes and answers stay on-device

#### Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 3 ("No new network egress; no new compliance regime; the on-device stance and existing encrypted stores are unchanged") and "Out of scope (must not change)" ("No new network egress"); workflow `security-design-review` focus ("No new egress: probes and answers stay on-device; the feature adds no provider calls (music-search egress is Spotify-feature owned)"); project constitution Architecture Constraint 1; feasibility study §5.4 (catalog recommendation: "consistent with the on-device stance").

#### Description
The feature **must** add zero network egress:

- **Probes**: template text + curated on-device catalog → no request of any kind to produce a probe; works offline.
- **Answer capture and merge**: sanitisation, scaffolding strip, catalog canonicalisation and frame merge are all local (FR-MTC-006); no provider or cloud call.
- **Model path**: nothing in this feature sends dialogue content to any cloud/BYO-LLM service; any brain use stays the on-device brain (and the Phase 2 clause changes the local prompt only).
- **Music search unchanged**: the only network in a music dialogue remains the existing Spotify-feature search/play path (already covered by that feature's privacy disclosure and egress rules) — this feature adds no host, no endpoint, no widening.
- **Measurable**: an air-gapped run of probe → answer → merge completes with 0 outbound requests up to the point of the (already-permitted) music search itself; a code-surface audit of the feature's new files shows no URL/transport construction (NFR-MTC-012 evidence).

#### Acceptance criteria

```gherkin
Feature: No new egress from the dialogue path

  Scenario: The full dialogue works with no network up to the permitted search
    Given the device is offline
    When the user says "भजन बजाऊ", hears the probe and answers "दुर्गा"
    Then the probe is spoken and the answer is merged with zero network requests
    And only the music-search step itself (already permitted) may attempt network

  Scenario: No new endpoint or transport exists in the feature's paths
    Given the feature's new and touched code paths
    When the egress surface is audited
    Then no new host, endpoint or transport construction is present
    And the on-device stance of Architecture Constraint 1 is unchanged
```

#### Related
- FR: FR-MTC-015 (on-device catalog), FR-MTC-016 (template probes), FR-MTC-006 (local merge)
- NFR: NFR-MTC-012 (compliance gates), NFR-MTC-005 (no model dependency)

### NFR-MTC-004: Log safety — probe and answer text never reach logs

#### Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 3 ("no raw transcripts may reach logs — the B2/T-050 precedent is binding and the release-build log gate (`ios/tools/check-release-log-safety.sh`) must keep passing"); workflow `security-design-review` focus ("Log sanitisation: probe texts and captured answers must not reach logs beyond the existing transcript policy (B2/T-050 precedent)"); project constitution Release gates (release-build log-surface gate; pre-release device console check).

#### Description
No probe text, captured answer, candidate content or transcript content **must** reach any log, telemetry event or diagnostic surface beyond the existing transcript policy. Measurable properties:

- **Zero occurrences**: in a Release build exercising a full dialogue (probe → answer → merge → execute), a cancel, a timeout, the escape, the re-probe cap and the did-you-mean path, the console/log output contains **0** raw transcripts, answer strings, probe-text dumps or candidate content.
- **Classification-only observability**: dialogue events carry non-content classifications (event name, probe kind, attempt count, outcome) — never the utterance, answer or option text.
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of every test scope) covers the new dialogue paths and **exits 0**; the pre-release device console check covers the same paths.
- **No regression**: the existing B1/B2 disciplines (no raw transcript prints, no raw error bodies) remain intact across the touched router/state-machine files.

#### Acceptance criteria

```gherkin
Feature: Log safety for the dialogue paths

  Scenario: A full dialogue produces no content in logs
    Given a Release build
    When a probe, an answer, a cancel and a timeout are exercised
    Then no transcript, answer, probe or candidate text appears in the console or logs
    And only non-content classifications are emitted

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's dialogue paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new probe/answer/interception paths

  Scenario: A hostile or malformed answer is never logged raw
    Given an answer containing hostile or malformed content
    When it is rejected or re-probed
    Then only the outcome classification is recorded
    And no raw answer content reaches the log
```

#### Related
- FR: FR-MTC-009 (interception), FR-MTC-006 (merge), FR-MTC-011 (emergency path logs)
- NFR: NFR-MTC-012 (compliance and release gates), NFR-MTC-008 (answer-path security)

### NFR-MTC-005: The frame survives a degraded or absent brain — deterministic path

#### Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 4 ("Deterministic merge works with the brain absent or degraded. This is Phase 1's core guarantee: the frame survives a degraded or skipped brain turn and executes via the deterministic merge. The PR #156 hardening must stay intact (per-turn STT release, pressure-tiered brain pick); brain-assisted merge is Phase 2 only") and "Success Criteria" ("Brain-degraded turns fall back to the deterministic merge or one more probe"); feasibility study §5.3 (degradation ladder) and §6.3.3; workflow `security-design-review` focus ("Degraded-brain path: the deterministic merge must not weaken the emergency/safety gates when the brain is absent or evicted"); worktree surfaces verified: `PressureBrainPick` (4B→1.7B→1B→lightweight, `Services/Voice/PressureBrainPick.swift`), degraded-mode pill (PR #156, `437631e`).

#### Description
The dialogue frame **must** function with the brain absent, skipped, unavailable (downloading/setup) or pressure-evicted:

- **Zero model dependency in Phase 1**: probe trigger, probe text, answer capture, catalog canonicalisation and the merge/execution path require **no model call and no prompt tokens** — the owner's bhajan example works end-to-end with the brain entirely absent.
- **Frame survives mid-dialogue degradation**: if the brain pick degrades between the probe and the answer (4B → 1.7B → 1B → lightweight → brainless), the frame is unaffected — deterministic merge carries the dialogue (DV-4).
- **PR #156 hardening intact**: the per-turn STT release policy and the pressure-tiered brain pick remain in force and are not weakened or bypassed by the frame path (no new resident model, no new warm-up, no extra turn peak-memory work); no jetsam regression (NFR-MTC-007).
- **Safety gates unchanged under degradation**: with the brain absent, emergency precedence, cancel and timeout rules behave identically (FR-MTC-011); the deterministic path never skips a safety check because a model is missing.
- **Unresolvable answers terminate cleanly**: when even the deterministic merge cannot extract a value and (Phase 2) the brain is unavailable, the system asks one more probe within the cap and then executes with defaults — never a stuck state (FR-MTC-007).

#### Acceptance criteria

```gherkin
Feature: Degraded-brain dialogue survival

  Scenario: The full dialogue completes with the brain absent
    Given no brain model is loaded
    When the user triggers the bhajan probe and answers "दुर्गा भजन"
    Then the probe is spoken and the answer merges deterministically
    And the merged command executes with zero model calls

  Scenario: A mid-dialogue brain eviction does not break the frame
    Given a probe was asked while a 4B brain was resident
    When the brain is pressure-evicted before the answer turn
    Then the answer is still captured and merged on the deterministic path
    And the dialogue completes without error

  Scenario: PR #156 memory policy remains in force
    Given the feature is built
    When a multi-turn dialogue runs on the 6 GB device
    Then the per-turn STT release policy and pressure-tiered brain pick behave as shipped in PR #156
    And the frame path adds no new resident model or warm-up work
```

#### Related
- FR: FR-MTC-006 (deterministic merge), FR-MTC-007 (cap), FR-MTC-011 (safety under degradation), FR-MTC-018 (the Phase 2 brain assist this floor outranks)
- NFR: NFR-MTC-007 (stability), NFR-MTC-001 (latency with no model wait)

### NFR-MTC-006: Localisation of every dialogue string (ne/en)

#### Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Probe Kinds & Answer-Capture Contract ("Probes are template-generated, localized ne/en") and Feature Constraint 2; project constitution Standards ("all UI strings must be externalised for translation. At minimum, support the primary user's configured language for all TTS output"); feasibility study §6.2 (probe example in Nepali; escape/index words in ne/en).

#### Description
Every user-facing string this feature adds **must** exist in Nepali and English and be spoken in the user's active language:

- **Coverage (100%)**: probe questions (both kinds), option names and their spoken forms, the default offer ("just play anything" family, wording per OD-M1), the honest not-understood line, the cancel acknowledgement, the escape acknowledgement, the re-probe line and the index words ("पहिलो"/"first" and the second/third equivalents) — each with an entry in the string catalog for **ne** and **en**.
- **No hardcoded user-facing text**: dialogue text is externalised (keyed) so future languages can be added without code changes, following the existing string-catalog discipline.
- **Active-language binding**: the probe/honest/acknowledgement lines are spoken (TTS) in the user's configured language, matching the original request's language where the interaction already resolved it (Nepali-first product).
- **Consistent voice with the shipped product**: the Nepali lines follow the existing elder-facing register; exact copy is design/OD-M1-dependent (illustrative in this set).

#### Acceptance criteria

```gherkin
Feature: Dialogue localisation

  Scenario: Every new dialogue string has ne and en entries
    Given the feature's string keys
    When the catalog is audited
    Then 100% of probe, option, default, honest-line, cancel, escape, re-probe and index-word strings exist in both ne and en
    And no dialogue string is hardcoded in code

  Scenario: The active language drives the spoken output
    Given the active language is Nepali
    When a probe, cancel acknowledgement or escape acknowledgement is spoken
    Then each is the Nepali entry
    And the English configuration speaks the English entries

  Scenario: The default offer and the escape exist in both languages
    Given any probe in either language
    When its option list is inspected
    Then the default offer and the say-it-again escape are present in that language
```

#### Related
- FR: FR-MTC-003/FR-MTC-004 (probes), FR-MTC-008 (escape), FR-MTC-010 (cancel), FR-MTC-016 (template generation)
- NFR: NFR-MTC-009 (voice-only accessibility)

### NFR-MTC-007: Sustained multi-turn stability on 6 GB devices — no jetsam

#### Metadata
- **Category:** Reliability / Performance
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone; validated by DV-5)
- **Source:** Feature constitution "Success Criteria" ("No jetsam kills across sustained multi-turn use on Anzaan") and DV-5 ("sustained multi-turn without jetsam (post-conversation jetsam log pull)"); feasibility study §5.1/§5.3 (1024-token ceiling is a memory limit; multi-turn multiplies the turn-count risk; PR #156 landed the OOM hardening) and §8 (OOM mitigation row); project constitution safety service stance.

#### Description
Sustained multi-turn dialogue **must not** introduce memory-pressure failures on the reference 6 GB-class device:

- **Measurable**: a sustained dialogue session (the DV scripted sequence, ≥ 10 consecutive dialogue turns including probe→answer pairs and one degraded-brain turn) on Anzaan produces **0 jetsam kills attributable to the voice stack**; a post-conversation JetsamEvent log pull is the evidence.
- **Inherits PR #156 policy**: per-turn STT release (`WhisperPostTurnPolicy.ReleaseReason.brainOverBudget` behaviour) and the pressure-tiered brain pick stay in force; the frame machinery adds no keeper of large allocations, no second resident model, no new warm-up.
- **Bounded turn cost**: each dialogue turn's memory profile is no worse than today's equivalent single turn (probe text and catalog are small static data; the frame is a tiny app object); the feature must not turn N turns into N times the worst-case resident set.
- **Regression signal**: if a jetsam occurs, the JetsamEvent log pull is recorded with the feature and the feature fails its completion gate (FR-MTC-020).

#### Acceptance criteria

```gherkin
Feature: Sustained multi-turn stability

  Scenario: A sustained multi-turn session produces no voice-stack jetsam
    Given a 6 GB-class reference device in Release configuration
    When a sustained multi-turn session (probe/answer turns plus a degraded-brain turn) runs
    Then the post-conversation JetsamEvent pull shows 0 voice-stack kill events
    And the session completes without a crash

  Scenario: Per-turn memory is bounded like today's turns
    Given the dialogue feature is built
    When a dialogue turn's resident set is compared to a comparable single turn
    Then no new large allocation or resident model is added by the frame machinery
    And PR #156's release/pick policies remain in effect
```

#### Related
- FR: FR-MTC-020 (DV-5 records this), FR-MTC-014 (session state), FR-MTC-018 (Phase 2 must not add resident cost)
- NFR: NFR-MTC-005 (degraded-brain path), NFR-MTC-001 (turn envelope)

### NFR-MTC-008: Answer-path sanitisation and injection safety

#### Metadata
- **Category:** Security
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 4 ("Security-review focus — the answer-capture path. That path accepts arbitrary spoken free text mid-dialogue. The feature's security-design-review (STRIDE) must treat it as a focus area and ensure there is no new injection surface into routing, no log-safety regressions, and that a hostile or corrupted answer cannot bypass the emergency precedence rule. The design must apply the project's existing sanitisation discipline before the answer enters any routing or prompt context.") and Constraint 3 (free-text answers sanitised through the `InputSanitiser` discipline); workflow `security-design-review`/`security-test` focus ("free-text answer injection surface"); project constitution Standards (injection detection at `quarantine` level); worktree surfaces verified: the input seam runs `InputSanitiser.sanitise(transcript, level: .quarantine)` before any brain use (`Services/Intents/LocalBrainChain.swift` `turnInput`), `InputSanitiser.containsInjectionMarker`.

#### Description
The answer-capture path accepts arbitrary spoken free text mid-dialogue; it **must** be the security-review focus area and satisfy:

- **Sanitisation before any use**: every captured answer passes the project's existing sanitisation discipline (`InputSanitiser.sanitise(_:level:.quarantine)` plus the input seam's STT-error corrector and dialect canonicalizer) **before** it enters routing, the frame merge, an executor, or (Phase 2) any prompt context. No path may consume a raw answer.
- **No new injection surface into routing**: a hostile answer must not be able to inject commands, JSON, control characters or prompt text that changes the router's behaviour outside the frame's own rules; the answer is data for the merge, never a routing input beyond the frame.
- **Emergency precedence unbypassable**: no hostile or corrupted answer can skip, reorder or weaken the emergency keyword check (FR-MTC-011); the check precedes all answer handling.
- **No sensitive-action bypass**: an answer can never itself trigger a sensitive action without the action's normal confirmation tiers (`ConfirmationTier` unchanged; calls/messages/reminders stay `.confirm` or gated as today).
- **STRIDE evidence**: the security-design-review produces a threat model with this path as a named focus; `security-test` verifies with crafted hostile answers (SECURITY-GO required; NFR-MTC-012).

#### Acceptance criteria

```gherkin
Feature: Answer-path security discipline

  Scenario: A hostile answer is sanitised before any use
    Given the probe is outstanding
    When the user answers with content containing injection markers or control text
    Then the quarantine-level sanitisation runs before the answer is used
    And no raw hostile content reaches routing, an executor or a prompt

  Scenario: A hostile answer cannot inject a command into routing
    Given the probe is outstanding
    When the answer contains command-like content for a different action
    Then no action outside the frame's rules is executed from the injected content
    And the frame path treats it under its normal capture rules only

  Scenario: A hostile answer cannot bypass emergency precedence
    Given the probe is outstanding
    When the answer attempts to hide an emergency keyword behind answer content
    Then the emergency override still wins before any frame merge
    And no answer handling can precede the emergency check
```

#### Related
- FR: FR-MTC-011 (emergency precedence), FR-MTC-009 (interception), FR-MTC-006 (merge), FR-MTC-017 (cache bypass)
- NFR: NFR-MTC-004 (log safety), NFR-MTC-012 (security gates)

### NFR-MTC-009: Voice-only accessibility of probes and answer capture

#### Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Project constitution Standards ("Voice-first UI — every function accessible by voice command without requiring any touch"; TTS in the configured language) and Target Users (60+, cognitive/motor challenges); feature constitution "Primary user: the elderly parent (60+, Nepali-first, voice-only)"; feasibility study §6.2 ("the user picks by voice") and §6.5; FR-MTC-005's single-word requirement.

#### Description
The entire dialogue — hearing the probe and answering it — **must** be completable by voice alone, with no touch interaction of any kind:

- **Answerable by every capture form, hands-free**: option name, index word, repetition or free-form; single-word answers must work (e.g. "दुर्गा" alone; "पहिलो" alone); the default ("just play anything") one phrase.
- **Spoken in the user's configured language** at the existing elder-facing TTS register; probe lines are short and the option count bounded (≤3–4 slot-fill, ≤2–3 did-you-mean; FR-MTC-003/004) so the spoken list stays memorable for elderly users.
- **No new gesture or tap requirement**: the probe appears in the existing spoken/visible surfaces (chat history like any reply); nothing in the flow requires the user to touch the screen (parity with the product's voice-first standard).
- **Verifiable end-to-end**: the bhajan dialogue (trigger → probe → answer → playback) can be completed in a hands-free test with no UI interaction.

#### Acceptance criteria

```gherkin
Feature: Voice-only dialogue accessibility

  Scenario: The whole dialogue completes hands-free
    Given the user never touches the device
    When the bhajan flow runs: "भजन बजाऊ" → probe → "दुर्गा"
    Then the dialogue completes and playback starts
    And no touch interaction was required at any point

  Scenario: Single-word answers work
    Given the probe is outstanding
    When the user answers with one word ("दुर्गा", "पहिलो", or the default phrase)
    Then the answer is captured and the frame resolves

  Scenario: Option lists stay within the elderly-friendly bounds
    Given any probe of either kind
    When the spoken option list is inspected
    Then slot-fill probes name at most 3–4 options plus the default
    And did-you-mean probes name at most 2–3 candidates
```

#### Related
- FR: FR-MTC-005 (capture forms), FR-MTC-003/FR-MTC-004 (probe bounds), FR-MTC-007 (no probe fatigue)
- NFR: NFR-MTC-006 (localisation of the spoken lines)

### NFR-MTC-010: Frame-trap resistance — zero stuck states

#### Metadata
- **Category:** Reliability / Safety
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 2 ("Frames must never trap the user. Cancel words drop the frame with an honest line; a strong new-command barge-in drops the frame and executes the new command; ambiguous utterances are treated as answers; a 45 s timeout silently drops and re-arms. Zero stuck states; no persistence across sessions."); workflow `security-design-review` focus ("Frame-trap resistance: cancel words, barge-in on a strong new command, and the 45 s timeout must always recover; a frame must never strand the user"); feasibility study §8 ("Elderly user walks away mid-dialogue — no stuck state").

#### Description
Every possible frame state **must** reach a terminal resolution, under a measurable recovery bound:

- **Total resolution**: from any frame state, one of — answer-merged execution, cancel, barge-in, probe-cap default execution, or 45 s timeout — resolves the frame; there is no state from which the frame can persist indefinitely.
- **Recovery bound**: inactivity resolution is ≤ 45 s (the deadline, FR-MTC-013); an interrupting user (cancel, barge-in, escape) resolves within that turn. A frame may never block a fresh command beyond the current turn (barge-in) or the deadline (timeout).
- **Trap-scenario matrix (verification)**: the test suite covers every trap candidate — bare cancel, cancel at the attempt cap, timeout, barge-in, escape, repeated unrecognised answers up to the cap, degraded-brain mid-dialogue, hostile answer — and **all** leave the session at idle with no active frame; 0 stuck states after the matrix.
- **Persistence is not a recovery route**: no frame survives a relaunch (FR-MTC-001); the machine's existing backstops (60 s voice watchdog, Talk reset) remain able to recycle a wedged cycle (FR-MTC-014).
- **The elderly-user test**: the assistant must never keep re-asking after the user has walked away or changed their mind.

#### Acceptance criteria

```gherkin
Feature: Frame-trap resistance

  Scenario: The trap-scenario matrix fully resolves with zero stuck states
    Given the full trap matrix (cancel, cap-exhaustion, timeout, barge-in, escape, repeated unrecognised answers, degraded brain, hostile answer)
    When each scenario is run
    Then every scenario reaches a terminal resolution (executed, dropped or re-armed)
    And no scenario leaves an active frame or a session stranded outside idle

  Scenario: A frame cannot outlive its deadline
    Given a frame is active and the user is silent
    When the 45 s deadline passes
    Then the frame is dropped and the session is listening for fresh commands

  Scenario: The user can always cut through the dialogue
    Given a frame is active
    When the user barges in with a strong new command or cancels
    Then the frame resolves on that turn
    And the user's intent is served without having to finish the dialogue
```

#### Related
- FR: FR-MTC-013 (timeout), FR-MTC-012 (barge-in), FR-MTC-010 (cancel), FR-MTC-007 (cap), FR-MTC-014 (session state)
- NFR: NFR-MTC-005 (degraded-brain recovery), NFR-MTC-008 (hostile-answer handling)

### NFR-MTC-011: KV-prefix stability — the frame clause never mutates the template prefix

#### Metadata
- **Category:** Performance / Reliability
- **Priority:** MUST
- **Phase:** Phase 2 (the clause itself ships only with the v17 iteration; the constraint is binding on any prompt-affecting change of this feature)
- **Source:** Feature constitution Feature Constraint 6 ("KV-prefix stability. The frame clause must not mutate the byte-stable template prefix (the vendored LLM prefix-reuse path depends on it — study §5.3)"); feasibility study §5.3 ("The reuse depends on the template prefix being byte-stable between turns, which is one more reason the frame clause must not mutate the template") and §6.4; worktree surface: the vendored `LLM.swift` prompt-prefix KV reuse (`prepareContext(for:)` diffs the new prompt against the previous context and decodes only the divergent tail).

#### Description
The vendored LLM path re-uses the KV cache for the byte-stable prompt prefix between turns; the frame clause (and anything else this feature adds to a prompt) **must** preserve that property:

- **Byte-stable prefix**: for consecutive turns in a dialogue, the template prefix bytes are identical whether or not a frame is active — the clause is appended inside the utterance/user segment (per the study's placement, "append to the user turn"), never inside or ahead of the stable prefix.
- **Reuse preserved**: between dialogue turns, only the utterance tail is re-decoded (tens of tokens), not the ~700-token template — the study's measured benefit that makes multi-turn turns cheaper than the pre-#156 churn.
- **Verifiable**: a test compares prompt prefix bytes across frame/no-frame turns and asserts identity; a second check asserts the divergent tail is the only re-decoded region (the reuse path engages).
- **No prompt change at all in Phase 1**: this NFR binds vacuously in Phase 1 (no clause exists) and becomes load-bearing with FR-MTC-018.

#### Acceptance criteria

```gherkin
Feature: KV-prefix stability

  Scenario: Prefix bytes are identical with and without an active frame
    Given the v17 frame clause is present in a build
    When the prompt is built for the same utterance with a frame active and inactive
    Then the template prefix bytes are identical between the two prompts
    And only the utterance segment differs

  Scenario: Prefix reuse engages between dialogue turns
    Given consecutive dialogue turns run with a resident brain
    When the second turn decodes
    Then only the divergent utterance tail is decoded
    And the ~700-token template prefix is not re-decoded

  Scenario: Phase 1 changes no prompt bytes at all
    Given a Phase 1 build (no clause)
    When prompts are compared with the pre-feature build
    Then they are byte-identical
```

#### Related
- FR: FR-MTC-018 (the clause this binds), FR-MTC-001 (state lives in the app)
- NFR: NFR-MTC-002 (prompt budget), NFR-MTC-001 (per-turn latency)

### NFR-MTC-012: Compliance, no-regression and release gates

#### Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone; gates apply to every phase)
- **Source:** Feature constitution "Delivery gates" (Feature Constraint 8: "Focused tests + typecheck per unit; full suite once at the end. Device validation is the DV-* checklist") and "Out of scope (must not change)" ("Reminder/calendar turns are unchanged in Phase 1 ... No new network egress; ... No new compliance regime"); project constitution Standards/Quality (safety-critical paths test discipline; paired review; 0.85 confidence) and Release gates (release-build log-surface gate; pre-release device check); workflow `repo conventions` (focused tests + typecheck per unit, full suite once at the end).

#### Description
The feature **must** meet the project's delivery and release discipline with no regressions to existing behaviour:

- **Tests**: new focused suites mirror the confirmation-protocol suite pattern (probe trigger, capture, interception, cancel/barge-in/timeout, cache bypass, catalog canonicalisation, degraded-brain merge); focused tests + typecheck run per unit during implementation and the full suite once at the end; the feature's suites pass, and any pre-existing baseline failures are recorded rather than silently included or excluded.
- **No regression (Phase 1 scope guard)**: the confirmation protocol, emergency and medication paths, the music path for non-degenerate queries, the honest no-brain lines, reminder/calendar re-prompts and the transcript cache's normal semantics all behave exactly as today outside the answer window (FR-MTC-019 guards the reminder/calendar Phase 1 no-change).
- **Release gates**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) exits 0 covering the new paths; the pre-release device console check covers the dialogue paths; final sign-off is T2 + HIL with the DV-* results recorded (FR-MTC-020).
- **Security gates**: STRIDE security-design-review with the answer-capture path as a focus area, `SECURITY-GO` required; security-test `SECURITY-GO` with the workflow's evidence list (emergency precedence mid-frame, log coverage, cancel/timeout/barge-in recovery, degraded-brain fallback, didYouMean cannot bypass the ladder).
- **No new compliance regime**: no new permission, no new data store, no new egress, no widened data handling — the existing privacy/consent disclosures are untouched (NFR-MTC-003).

#### Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: The release log-safety gate and test discipline pass
    Given the feature is built
    When ios/tools/check-release-log-safety.sh runs and the focused suites run
    Then the gate exits 0
    And the feature's focused suites and the end-of-feature full suite are green against the recorded baseline

  Scenario: Existing behaviour outside the dialogue window is unchanged
    Given a build with the feature
    When confirmation, emergency, medication, non-degenerate music, reminder/calendar and no-brain paths are exercised
    Then each behaves exactly as before the feature
    And no new permission, store or egress exists

  Scenario: The security gates carry the answer-capture focus
    Given the workflow's security-design-review and security-test
    When their decisions are recorded
    Then the answer-capture path is a named STRIDE focus
    And both decisions are SECURITY-GO with the evidence list covered
```

#### Related
- FR: FR-MTC-020 (DV gate), FR-MTC-011 (safety evidence), FR-MTC-017 (cache semantics), FR-MTC-019 (Phase 1 scope guard)
- NFR: NFR-MTC-004 (log safety), NFR-MTC-008 (security), NFR-MTC-003 (no new egress)

## Open decisions

Carried from the feature constitution "Open Decisions" (feasibility study §9); **not resolved
here**. None blocks the requirement set; each has an owner-visible resolution point.

**OD-M1 — Probe policy (OPEN — owner).** *Substance:*

> 1 probe vs up-to-2 before executing with defaults, and the default-play wording ('जे पनि बजाऊ').
> Recommend: 2 probes max, default offered on the first probe.

Status in this requirement set: open. The requirements bind a **bounded** probe budget, the
always-present default and execution-with-defaults on exhaustion — FR-MTC-007 (bounded budget,
default execution), FR-MTC-003 (the default offer on the probe). The exact cap (1 vs 2) and the
exact default copy stay open. Resolve at: owner; recorded in design-l1.

**OD-M2 — Probe option source (OPEN — owner).** *Substance:*

> Curated on-device catalog (recommended for MVP: zero latency, on-device stance) vs live Spotify
> playlist search (richer, needs a `SpotifyTool` extension + network per probe).

Status in this requirement set: open. The requirements bind the curated on-device catalog for
Phase 1 — FR-MTC-015 (on-device catalog: zero latency, localisable, canonicalisation) — and no
new egress — NFR-MTC-003; a later live-search enrichment resolves here. Resolve at: owner +
design-l1.

**OD-M3 — Sequencing (OPEN — owner).** *Substance:*

> Ship Phase 1 deterministic-only first vs run Phase 2 + v17 in parallel. Recommend: Phase 1
> first (it covers the bhajan example), v17 data authoring in parallel.

Status in this requirement set: open. The requirements mark Phase 2 (FR-MTC-018) as SHOULD pending
this resolution; Phase 1 (FR-MTC-001 … FR-MTC-017) is complete and shippable alone. Resolve at:
owner.

**OD-M4 — Scope (OPEN — owner).** *Substance:*

> Whether Phase 3's reminder/calendar answer-capture (fixing today's stateless re-prompts) rides
> the same release as the music probe.

Status in this requirement set: open. The requirements keep reminder/calendar unchanged in
Phase 1 (FR-MTC-019's Phase 1 guard; NFR-MTC-012) and carry the Phase 3 target as SHOULD
(FR-MTC-019). Resolve at: owner.

### Assumptions recorded during this requirements pass

Recorded so nothing is silently assumed; all are design-input notes, not scope changes. The full
list is in the lock file (`assumptions`).

- The integration surfaces exist as named in the feature constitution; the cited anchors were
  spot-verified against the worktree source at requirements time (`CommandRouter.route` at 740,
  the confirmation hook at 785-886, the keyword-ladder music arm at 1223-1234,
  `routeKeywordRemainder` at 1968-2030, `selectMusicOutcome`/`fireMusicRequest`/`runMusicTurn` at
  2614/2667/2684, the interpreted `.music` path at 3336-3355, `musicQuery` at 752-779,
  `VoiceSessionStateMachine` states/timer at 9-17/93-96/183-203, the 60 s voice watchdog, the
  `IntentPromptTests` 3,000-character pin, `maxTokenCount: 1024`). Remaining study §10 line
  references not cited above are study-derived.
- Exact user-facing copy (probe wording, default-play phrase, cancel/escape lines, honest lines)
  is OD-M1/OD-M2/design-dependent; the Nepali/English examples in this set are illustrative and
  localization-bound (the keys must exist in both languages — NFR-MTC-006).
- The curated catalog's exact contents (e.g. the bhajan deity list) are data refined at design
  time; the requirement binds the catalog's existence, on-device sourcing, localisability and
  canonicalisation behaviour (FR-MTC-015).
- "v16"/"v17" are the study's and constitution's iteration labels for the existing slot-canonical
  fine-tune and the Phase 2 follow-up fine-tune; the actual artifacts land via the Phase 2 training
  iteration (FR-MTC-018) — nothing in Phase 1 depends on a training run.
- The project's known pre-existing test failures (unrelated to this feature) remain the baseline
  for NFR-MTC-012; the feature's own suites and touched suites must pass, with baseline failures
  recorded rather than silently included or excluded.
- The 45 s deadline is the existing confirmation timer value
  (`VoiceSessionStateMachine.confirmationTimeoutSeconds = 45`); reuse mechanics are design's to
  fix, the value is binding.
- `DialogueManager`/`DialogueFrame`/`awaitingSlotAnswer`/the curated catalog were confirmed absent
  from the worktree source at requirements time — they are genuinely new surfaces.

## Out of scope

Explicitly not in scope (feature constitution "Out of scope (must not change)" plus the workflow
scope comment's explicit non-goals) — recorded so nothing is silently half-built:

| Non-goal | Why it is stated |
|---|---|
| Open-ended conversation/chat | The fine-tunes have no conversational mode; stage-3 chat was never done and shipped-brain chat is a known problem. Probes are the only new dialogue (constitution Out of scope; study §5.2). |
| Raw transcript history in prompts | The 1024-token ceiling is a measured memory limit; dialogue state lives in the app (NFR-MTC-002; study §5.1). |
| Model-generated probe text | Probes are template-generated, localized ne/en; the model's only multi-turn job is classifying the answer (FR-MTC-016; constitution Feature Constraint 2). |
| Cloud / BYO-LLM anything | No new network egress; the on-device stance is unchanged (NFR-MTC-003). |
| Persistent dialogue state across sessions | Frames are in-memory only; a cold start has no frame (FR-MTC-001). |
| Reminder/calendar changes in Phase 1 | Those turns are unchanged until Phase 3 and the OD-M4 resolution (FR-MTC-019 Phase 1 guard). |
| Android | No platform scope beyond the existing iOS app (constitution Feature Constraint 10). |
| Emergency/medication behaviour changes | No change of any kind; emergency precedence is preserved absolutely (FR-MTC-011). |
| Any new compliance regime, permission, data store or egress host | None added; existing disclosures and gates unchanged (NFR-MTC-012). |

## How this set is verified downstream

| Gate | What it checks against this set |
|---|---|
| `design-l1` / `design-l2` | Resolve/design with OD-M1..M4 (address the open decisions; the study's recommendations are inputs): `DialogueFrame` shape + `probeKind` enum; the interception seam in `CommandRouter.route` (generalize the confirmation hook ~785-886) and its ordering vs emergency keywords; `awaitingSlotAnswer` + 45 s timer reuse; degenerate-query detection in the music path (`KeywordIntentRule.musicQuery`); the curated catalog format (localizable ne/en); how the frame survives the degradation ladder (PR #156 pressure-tiered picks); the Phase 2 frame-clause budget within the pinned prompt and the v17 training-mirror requirement. |
| `review-l2` | `review.decision == GO` against the component design and this set. |
| `security-design-review` | STRIDE with the answer-capture path as a named focus: emergency precedence mid-dialogue (FR-MTC-011, NFR-MTC-010); free-text answer injection (NFR-MTC-008, FR-MTC-009, FR-MTC-017); frame-trap resistance (FR-MTC-010/012/013); log sanitisation of probe/answer text (NFR-MTC-004); no new egress (NFR-MTC-003); degraded-brain deterministic path must not weaken safety gates (NFR-MTC-005, FR-MTC-011); `SECURITY-GO` required. |
| `plan-tasks` / `implement` | Units trace back to `FR-MTC-*` / `NFR-MTC-*` ids; paired review and the 0.85 confidence threshold on implementation output; rework bound 5; unit-based dependency waves. |
| `security-test` | Evidence: emergency precedence verified mid-frame (FR-MTC-011); probe/answer text never reaches logs and `check-release-log-safety.sh` covers the new paths (NFR-MTC-004, NFR-MTC-012); cancel/timeout/barge-in recovery (FR-MTC-010/012/013, NFR-MTC-010); degraded-brain fallback honored (NFR-MTC-005); the didYouMean candidate list cannot be induced to bypass the ladder (FR-MTC-004, NFR-MTC-008); `SECURITY-GO` required. |
| `final-sign-off` | T2 + HIL; release gate `ios/tools/check-release-log-safety.sh` exits 0 (NFR-MTC-004, NFR-MTC-012); the DV-* checklist is recorded and passed on the reference device incl. the Phase 0 PR #156 smoke (FR-MTC-020, NFR-MTC-007). |
