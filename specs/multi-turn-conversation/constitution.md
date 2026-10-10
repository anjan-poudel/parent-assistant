# Constitution — multi-turn-conversation (feature supplement)

Applies to the `multi-turn-conversation` workflow only (`specs/multi-turn-conversation/workflow.yaml`, mirrored at `.ai-sdd/workflows/multi-turn-conversation.yaml`). The project constitution (`/constitution.md`) is inherited unchanged — Architecture Constraints 1–6, Standards, release gates, and Agent Principles all bind this feature. This supplement does not restate project-level rules; it records only what the feature adds, what it must not change, and the decisions left open. See `specs/multi-turn-conversation/init-report.md` for the scaffold probe.

## Feature Purpose & Scope

Purpose: give Pip a one-deep dialogue frame. Today the voice pipeline is strictly single-turn — one transcript produces one `RoutingResult` with no context across utterances — so a request that needs a missing detail either guesses (the music path takes the literal top search hit) or dead-ends with an honest but stateless line. This feature asks a short spoken clarifying probe, captures the user's spoken answer, merges the answer into the pending command, and executes it. It is grounded in the owner's feasibility study `docs/multi-turn-conversation-feasibility.md` (2026-10-10), which contains the full recommended design, measured constraints, phasing, risks, and open decisions OD-M1..M4.

Primary user: the elderly parent (60+, Nepali-first, voice-only). The owner's example: 'play bhajans' makes Pip ask 'WHAT KIND OF BHAJANS? shiva, durga, bishnu, devi...', and 'dasain durga bhajans' then plays the right thing. The same user is affected whenever any utterance is not understood: Pip must honestly say so **and** offer a narrowing probe, instead of today's dead-end line. No new caregiver-facing surface.

In scope:

- **Phase 1 — deterministic MVP, shippable alone** (covers the owner's example with no training run): `DialogueManager` + `DialogueFrame`; the `awaitingSlotAnswer` session state (reusing the 45 s confirmation timer); pre-ladder answer interception (cancel detection, emergency override, barge-in rule); template-generated probes (ne/en) + a curated on-device option catalog; degenerate-query detection in the music path; deterministic answer merge (input-seam sanitisation, scaffold stripping, catalog canonicalisation, merge into `activeCommand`, dispatch via `runMusicTurn`); timeout/abandonment with silent re-arm; focused tests (pattern: the confirmation-protocol suites).
- **The owner requirement (2026-10-10): two probe kinds — `probeKind` `.slotFill` (a slot the pending command needs, e.g. which bhajan deity) and `.candidateChoice` / didYouMean (when Pip did not understand the utterance at all).** When Pip does not understand an utterance it must (1) honestly say it did not understand and (2) offer a narrowing probe with candidate interpretations the user picks by voice. Candidate probes upgrade today's honest-but-dead-end `routeKeywordRemainder` lines (`CommandRouter.swift:1968-2030`) into a narrowing dialogue. This is a first-class requirement, not an optional extra.
- **Phase 2 — follow-up NLU fine-tune v17**: follow-up-turn training data (golden corpus + synthetic follow-ups), `prompt_template` mirror update, LoRA on the existing training pipeline, query-slot gates, brain-assisted frame merge.
- **Phase 3**: roll the same frame path over the existing stateless reminder/calendar missing-slot re-prompts; RepetitionGuard interplay; DV-* device validation.

Out of scope (must not change):

- Open-ended conversation/chat (the fine-tunes have no conversational mode; stage-3 chat was never done and shipped-brain chat is a known problem).
- Raw transcript history in prompts (the 1024-token ceiling — study §5.1).
- Model-generated probe text.
- Cloud / BYO-LLM anything.
- Persistent dialogue state across sessions.
- Reminder/calendar turns are unchanged in Phase 1 (Phase 3 is where they move onto the frame path).
- No new network egress; the on-device stance and existing encrypted stores are unchanged. No new compliance regime.

## Probe Kinds & Answer-Capture Contract

`DialogueFrame.probeKind` is an enum with two cases; both are in scope and both are template-driven:

| Probe kind | Trigger | Candidate source | What the user hears |
|---|---|---|---|
| `.slotFill` | a resolved command still needs a slot (degenerate/missing music query — e.g. bare 'play bhajans') | the curated on-device catalog (bhajan deity → canonical search query) | a short template probe (e.g. 'कस्तो भजन? शिव, दुर्गा, विष्णु, देवी … वा आफैँ भन्नुहोस्'), ≤3–4 named options, one default always offered ('just play anything') |
| `.candidateChoice` (didYouMean) | the utterance was not understood | the existing rephrase band (confidence 0.4–0.7), relaxed keyword near-matches, and the active dialogue frame | an honest 'did not understand' line **plus** a narrowing probe with ≤2–3 candidate options the user picks by voice |

Both kinds share the same pre-ladder interception, the same voice-pick protocol, the same constraints (template text, 45 s deadline, free-text always accepted, the 'no — let me say it again' escape re-arming a fresh capture), and the same frame-merge execution path.

Answer capture — the user picks by:

- the option's **name**,
- its **index word** ('पहिलो' / 'first'),
- **repetition** of the candidate,
- or a **free-form correction** (always accepted).

Unrecognized answers re-probe until the attempt cap: **max 2 probes, then execute with defaults**. Probes are template-generated, localized ne/en — never model-generated; the model's only multi-turn job is classifying the answer against the active frame.

The answer turn (interception runs **before** the routing ladder, generalizing the confirmation hook at `CommandRouter.swift:785-886`):

1. **Cancel detection** — cancel words ('होइन', 'रद्द', 'never mind') drop the frame with an honest line.
2. **Emergency override** — emergency keywords always win, checked before any frame merge.
3. **Deterministic frame merge** — sanitise the answer through the existing input seam (STT-error corrector + dialect canonicalizer), strip answer scaffolding, canonicalise via the catalog when it matches (else keep the free text), merge into `activeCommand`, dispatch through the normal executor (`runMusicTurn`).
4. **Optional brain resolution (Phase 2 only)** — a compact frame clause within the pinned prompt budget; brain unavailable → one more probe, then execute with defaults.
5. **Timeout / abandonment** — 45 s expiry drops the frame silently and re-arms; the user's next utterance is a fresh command. No stuck state, no persistence.

**Barge-in rule:** an utterance that looks like a *different* command mid-frame (strong deterministic match, e.g. 'call my son') drops the frame and executes the new command; ambiguous utterances are treated as answers. This is the behaviour elderly users expect and it prevents the frame from trapping them.

Frame shape (in-memory, held by `DialogueManager`, owned by the coordinator — the same one-deep pattern as today's pending-command state, but structured): `activeCommand`, `missingSlot`, `probeKind`, `candidates`, `attempts` (capped), `deadline` (45 s).

## Safety-Relevant Constraints (binding)

No new safety class beyond the project baseline, but this feature edits the voice-turn interception path that front-runs emergency and medication handling, so it is treated as safety-relevant. The following rules are binding:

1. **Emergency precedence is absolute.** Emergency keywords must always win mid-dialogue — the override is checked before any frame merge. Emergency dispatch and medication re-fire are frame-independent: their behaviour is exactly as today regardless of any active frame. A hostile or corrupted answer cannot bypass the emergency precedence rule.
2. **Frames must never trap the user.** Cancel words drop the frame with an honest line; a strong new-command barge-in drops the frame and executes the new command; ambiguous utterances are treated as answers; a 45 s timeout silently drops and re-arms. Zero stuck states; no persistence across sessions.
3. **Privacy & log-safety stance unchanged.** No new network egress; no new compliance regime; the on-device stance and existing encrypted stores are unchanged. Free-text answers are sanitised through the existing input seam (the `InputSanitiser` discipline) before any use, and no raw transcripts may reach logs — the B2/T-050 precedent is binding and the release-build log gate (`ios/tools/check-release-log-safety.sh`) must keep passing.
4. **Security-review focus — the answer-capture path.** That path accepts arbitrary spoken free text mid-dialogue. The feature's security-design-review (STRIDE) must treat it as a focus area and ensure there is no new injection surface into routing, no log-safety regressions, and that a hostile or corrupted answer cannot bypass the emergency precedence rule. The design must apply the project's existing sanitisation discipline before the answer enters any routing or prompt context.

## Feature Constraints

1. **1024-token ceiling.** The brain context is a measured memory ceiling (2048 crashed 6 GB devices — study §5.1). Dialogue state lives in the app, never as transcript history in prompts. Any prompt clause must fit the ~300-token headroom inside the pinned `IntentPromptTests` budget.
2. **Template-generated probes only** (localized ne/en). Never model-generated. The model never writes probe text.
3. **Probe budget.** Max 2 probes then execute with defaults; ≤3–4 spoken options with a default always offered (slotFill), ≤2–3 for candidateChoice; free-text answers always accepted.
4. **Deterministic merge works with the brain absent or degraded.** This is Phase 1's core guarantee: the frame survives a degraded or skipped brain turn and executes via the deterministic merge. The PR #156 hardening must stay intact (per-turn STT release, pressure-tiered brain pick); brain-assisted merge is Phase 2 only.
5. **The Phase 2 frame clause ships only together with the v17 training iteration.** The clause must stay inside the pinned prompt budget, must be mirrored byte-identically in `tools/train-intent/seeds/prompt_template.txt` in the same change, and must not alter the `.raw` framing. Prompt-identity drift is the named hazard; no clause without training data.
6. **KV-prefix stability.** The frame clause must not mutate the byte-stable template prefix (the vendored LLM prefix-reuse path depends on it — study §5.3).
7. **Cache bypass.** During `awaitingSlotAnswer`, the transcript cache (`IntentCommandCache`) is bypassed — answers are never cacheable inputs; only confirmed *merged* commands are recorded.
8. **Delivery gates.** Focused tests + typecheck per unit; full suite once at the end. Device validation is the DV-* checklist below on Anzaan.
9. **Phase 0 prerequisite.** PR #156 voice-OOM hardening is merged (`437631e`, 2026-10-10); its device smoke (conversation → no jetsam → pull JetsamEvent logs) is outstanding — that outstanding smoke is the Phase 0 prerequisite for this feature.
10. **iOS only.** No platform scope beyond the existing iOS app.

## Integration Surfaces (mapped by the scaffold brief)

| Surface | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` | `route()` and the confirmation interception hook (~785–886) generalized to the answer interception; keyword ladder (1207–1234); `routeKeywordRemainder` honest-failure lines (1968–2030) upgraded into the didYouMean probe; music path (2614–3136 — `selectMusicOutcome` 2614, `fireMusicRequest` 2667, `runMusicTurn` 2684). |
| `ios/ElderlyAssistant/Services/Voice/KeywordIntentRule.swift` | `musicQuery(from:)` (752–779) degenerate-query detection; relaxed near-match candidates for candidateChoice probes. |
| `ios/ElderlyAssistant/App/VoiceSessionStateMachine.swift` | New `awaitingSlotAnswer` state alongside `awaitingConfirmation` (states at 15–16; the 45 s timer at 91–127 is reused). |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | `DialogueManager` ownership, timers, watchdog. |
| **NEW** `ios/ElderlyAssistant/Services/Voice/DialogueManager.swift` | `DialogueFrame` with `probeKind` (`.slotFill` / `.candidateChoice`), candidates, attempts cap, deadline. |
| **NEW** curated on-device music option catalog | Bhajan deity → canonical search query; zero latency; consistent with the on-device stance (study §5.4). |
| Phase 2: `Services/Voice/IntentPrompt.swift`, `Services/Voice/LlamaCommandInterpreter.swift` | Frame clause within the pinned prompt budget; `.raw` framing unchanged. |
| Phase 2: `tools/train-intent/seeds/prompt_template.txt` + the training pipeline | v17 follow-up-turn data; prompt mirror updated in the same change. |
| Phase 3: `ios/ElderlyAssistant/Services/Intents/RepetitionGuard.swift` | Interplay with the frame manager (existing cross-turn memory of recent confirmed actions). |
| Tests | Mirror the confirmation-protocol suites. |

The feasibility study section 10 lists the exact file references the brief is derived from.

## Success Criteria & Completion Gate

Success (acceptance seed for the requirements phase):

- The owner's bhajan example works end-to-end in Phase 1 with no training run (probe → answer → correct playback).
- Every probe is template-generated and localized ne/en; at most 2 probes then execution with defaults.
- Answers are captured by option name, index word, repetition, or free-form correction.
- An unrecognized utterance gets an honest 'didn't understand' line plus a didYouMean probe with voice-pickable candidates and a 'no — let me say it again' re-capture escape.
- Cancel words drop the frame with an honest line; emergency keywords win mid-frame; strong new-command barge-in drops the frame and executes the new command; 45 s timeout silently re-arms — zero stuck states.
- Brain-degraded turns fall back to the deterministic merge or one more probe; reminder/calendar turns are unchanged in Phase 1.
- No jetsam kills across sustained multi-turn use on Anzaan.

Completion gate — DV-* device validation on Anzaan (the DV pattern of prior shipped features, recorded with the feature spec):

- DV-1 — probe → answer → correct playback (the bhajan example).
- DV-2 — timeout: 45 s expiry drops the frame silently and re-arms.
- DV-3 — barge-in: a strong new command mid-frame executes and drops the frame.
- DV-4 — mid-dialogue degraded-brain turn: the deterministic merge carries the dialogue.
- DV-5 — sustained multi-turn without jetsam (post-conversation jetsam log pull).

Phase 0 prerequisite: the outstanding PR #156 device smoke — conversation → no jetsam → pull JetsamEvent logs — must be run as the Phase 0 gate.

## Open Decisions

Q1–Q6 for this scaffold were answered non-interactively from the owner's feasibility study plus a repo probe; if any derived answer conflicts with the owner's intent, correct it before `/sdd-run`. The four decisions below are owner-facing and stay **OPEN** into requirements/design (feasibility study section 9).

### OD-M1 — Probe policy (OPEN — owner)

1 probe vs up-to-2 before executing with defaults, and the default-play wording ('जे पनि बजाऊ'). Recommend: 2 probes max, default offered on the first probe.

### OD-M2 — Probe option source (OPEN — owner)

Curated on-device catalog (recommended for MVP: zero latency, on-device stance) vs live Spotify playlist search (richer, needs a `SpotifyTool` extension + network per probe).

### OD-M3 — Sequencing (OPEN — owner)

Ship Phase 1 deterministic-only first vs run Phase 2 + v17 in parallel. Recommend: Phase 1 first (it covers the bhajan example), v17 data authoring in parallel.

### OD-M4 — Scope (OPEN — owner)

Whether Phase 3's reminder/calendar answer-capture (fixing today's stateless re-prompts) rides the same release as the music probe.
