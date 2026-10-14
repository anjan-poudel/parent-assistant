# Design L1+L2 — Conversational Nepali Replies

| | |
|---|---|
| Task | `design-l1` (agent: `system-architect`), contract `architecture_l1` |
| Feature | `conversational-nepali-replies`, branch `feat/conversational-nepali-replies` |
| Worktree | `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies` |
| Base | `22de9864` (scaffold base master `91deddca`; all anchors verified in the feature worktree) |
| Date | 2026-10-14 |
| Scope | Combined L1+L2 design of record — `design-l2` is folded into this task (and the `review-l2` gate dropped) per the owner directive 2026-10-14; the review chain is the lean chain recorded in §21 |
| Inputs | project `constitution.md`; `specs/conversational-nepali-replies/constitution.md` (feature supplement: style-spec contract, runtime contract, model & training contract, OD-1..OD-5); `specs/define-requirements.md` + `specs/define-requirements/` (29 FR-CNR, 11 NFR-CNR, locked; `define-requirements.lock.yaml`); owner-approved proposal `docs/features/2026-10-14-conversational-nepali-replies-proposal.md`; workflow `specs/conversational-nepali-replies/workflow.yaml` (canonical; its `.ai-sdd/workflows/` mirror is kept byte-identical per the workflow header) |
| OD status | OD-1, OD-2, OD-4, OD-5 resolved in this document (§5, §6, §7.2, §9). OD-3 is an owner question, recorded not decided (§19.2; feasibility statement §20). Decision register: §3 |

Line numbers cited below are orientation anchors into base `22de9864`, not contracts; symbol
names are the contracts. This document designs; it does not implement (no production code, no
migrations, no seed-file content are written here). Every interface below specifies its error
paths (agent principle: explicit error return types), its isolation (agent principle:
concurrency explicit), and treats timeouts as configuration (§13) — no timeout literal is
introduced. Scope is enforced by the requirements: every component named here traces to an
FR-CNR/NFR-CNR in the Traceability mapping, and nothing else is added.

---

## Overview

### 1. Scope and method

This document — the combined L1+L2 design of record — fixes the architecture for the owner's complaint — replies are "too robotic and AI like
and sometimes incorrect grammatically" — as bound by the feature constitution's four contracts
(Style Spec / Single Source, Runtime, Model & Training, Safety & Compliance Delta) and the 29+11
locked requirements. It translates the generic architect template to this codebase's idioms:

- **"REST API surface" → the in-process seam surface**: the small set of Swift types other
  modules may call (`ChatResponding`, the routing decision, the consent gate, the grammar
  guard's verdict, the sampling override), each with an explicit outcome/verdict type; plus the
  file-level artifact seams on the training box (style spec, seed mirrors, corpus, gate
  harness). The only cross-process surface this feature touches is the existing Gemini HTTPS
  client (consent-gated; §8).
- **"OpenAPI" → the fixed schemas of those seams**: the single-decode JSON contract is
  UNCHANGED (FR-CNR-013) and is therefore not redesigned here; the new contract documents are
  the grammar-guard verdict/event schema (§7.5), the consent record (§8.3), and the
  training-run provenance manifest (§11.5) — each defined as a named, versioned shape.
- **"Data model" → persisted schemas + run artifacts**: the new persisted datum is the
  cloud-chat consent record (encrypted at rest, §12); everything else the feature adds is a
  repo/run artifact (style spec, seed mirrors, corpus, `chat_golden.jsonl`, GGUF, catalog
  entry), versioned per §6.1/§11.
- **"Infrastructure topology" → the process/thread topology**: one on-device app process
  (main-thread-confined coordinator state, the serial `inferenceQueue` decode lane, the
  `LLMCore` actor, the speech path), the training box (anjan-ubuntu, 4090) as the P1 compute
  surface, and the Gemini endpoint as the single external service. There is no server of ours,
  no container, no Docker anywhere in this design.
- **"Auth strategy" → the trust & consent model**: there are no accounts and no auth tokens to
  invent. The relevant authorization surface is (a) the existing stack-level cloud consent
  (`voiceEngineStack` / `cloudEnabled`) and (b) the NEW explicit cloud-chat consent in the
  Open Decision 12 shape (§8.3), plus header-only provider-key handling (FR-CNR-012). The
  on-device brain is the floor under every path.

### 2. Design summary and invariant ledger

Three legs, per the approved proposal: **P0 runtime** (persona upgrade both seams; chat-only
fixed-seed temp 0.3; deterministic grammar guard at the polisher seam; cloud-first chat routing
toggle with OD-12-shape consent; explicit Gemini chat temperature), **P1** (four-layer corpus,
chat-aware v17 QLoRA variant of the existing suite, chat gates, catalog swap), **P2** (DPO,
romanized chat, 4B tier, consent-based transcripts). The design keeps every leg inside the
existing seams; the load-bearing invariants that must not move are:

| Invariant | Contract | Enforcement in this design |
|---|---|---|
| Command decode determinism (NO-GIBBERISH) | temp 0 + fixed seed 20_260_907 + GBNF `commandJSONSchema`, byte-for-byte | §5.2: per-turn re-assertion of temp 0 for command decodes; `OnDeviceSampling` members and handle creation untouched; test-visible decode-parameter record |
| Single-decode schema | one JSON (`intent` + response/reply + `confidence`); unreadable output abstains | Unchanged (FR-CNR-013); chat lane answers reuse the `.chat` `InterpretedCommand` shape; no new decode stage, no JSON repair |
| Router ladder + emergency gate | semantics exactly as shipped; emergency recall 1.00 is a gate | §8.2: chat lane diverts only `ChatIntentClassifier == .chat` turns ahead of the selector; no ladder/cascade edits; DV-4 |
| STT pipeline | untouched; transcript regression = stop-and-investigate | Not in the change surface; the chat lane and guard act on post-transcript text only (§8.2 note) |
| Intent prompt bytes | `IntentPrompt.build` text + `seeds/prompt_template.txt` + `IntentPromptTests` pin byte-identical | §10: command decode's assembled prompt (incl. its system slot) stays byte-identical; only the chat shape's system slot changes |
| One brain resident | no second model instance; zero feature-attributable jetsam | §5.2 rejects a shape-specific handle; §11.6 v17 is a swap of the same resident |
| Log/telemetry content discipline | no conversation content, transcript, or key material in logs; classification-only events | §7.5, §16: new events carry enums/counts only; release gate covers the new paths |

### 3. Decision register

| OD | Question | Decision (this document) | Section |
|---|---|---|---|
| OD-1 | Chat temperature value, sampling plumbing, GBNF interplay | Chat temperature exactly 0.3 (`ChatSampling.chatTemperature`), applied as a per-turn, awaited, actor-ordered override on the single resident handle; command turns re-assert temp 0; a shape-specific second handle is rejected (NFR-CNR-003) | 5 |
| OD-2 | Style-spec artifact format and four-consumer wiring | One artifact `tools/train-intent/seeds/nepali-chat-style-spec` (prose rules + machine YAML blocks); personas and guard hold drift-checked byte-mirrors; the Python consumers load it directly | 6 |
| OD-3 | P0 landing path (owner question — NOT decided here) | Recorded verbatim, pending owner answer (Slack `q-ask-2f6a8883-804e-4ac5-9a58-c0762f257074`, 2026-10-14); the P0 slice stays independently landable | 19.2 |
| OD-4 | Particles-budget enforcement mechanics | Particle set = the spec lexicon with longest-match-first tokenization; budget fixed at 1; enforced in the runtime guard AND the eval rubric over the post-polisher text | 7.2 |
| OD-5 | Gemini chat temperature value | Exactly 0.3 (parity with the on-device value); chat-scoped optional `GenerationConfig.temperature`; search grounding off for chat | 9 |

Items left to implementation/plan-tasks are listed in Deferred work (after the design body).

## Architecture

### 4. Runtime topology and chat data flow

```
                            ┌──────────────────────────────────────────────────────────┐
                            │ IntentRouter.interpret (unchanged layers above chat)     │
                            │  cache → cloud preparse → [NEW] chat lane → selector/    │
                            │  legacy ladders (commands only, byte-identical)          │
                            └───────────────┬──────────────────────────┬───────────────┘
                                            │ classifier == .chat      │ otherwise
                                            ▼                          ▼ (commands, untouched)
                          ┌────────────────────────────────┐   ┌──────────────────────────┐
                          │ CloudChatRouting.decide(...)   │   │ InterpreterSelector /    │
                          │  consent × online × key × cost │   │ legacy ladder / cascade  │
                          └───────┬─────────────────┬──────┘   └──────────────────────────┘
                     .cloud (granted)          .local (or fallback)
                                  │                 │
                 ┌────────────────▼───┐   ┌─────────▼─────────────────────────────┐
                 │ GeminiCommand-     │   │ interpretLocalLadder chat pre-check   │
                 │ Interpreter        │   │ (existing): ChatIntentClassifier →    │
                 │ respondToChat      │   │ LocalBrainChain.respondToChat →       │
                 │ (ChatResponding)   │   │ LlamaCommandInterpreter.runTurn(.chat)│
                 │ buildChat +        │   │  ┌────────────────────────────────┐   │
                 │  chat replyPersona │   │  │ ResponseShape .chat:           │   │
                 │  + GenerationConfig│   │  │  schema chatJSONSchema,        │   │
                 │  temp (OD-5)       │   │  │  persona system slot,          │   │
                 └────────┬───────────┘   │  │  temp ChatSampling.chatTemperature │
                          │               │  │  via awaited core.setParameters│   │
                          │               │  └────────────┬───────────────────┘   │
                          │               │   one resident LLM handle (actor)      │
                          │               └──────────────┬─────────────────────────┘
                          │                              ▼
                          │              CommandRouter.dispatchInterpreted  case .chat
                          │              (chatConfidenceFloor guard, unchanged)
                          └──────────────┬───────────────┘
                                         ▼
                    ┌───────────────────────────────────────────────┐
                    │ [NEW] NepaliGrammarGuard.verdict(spokenText)  │  pure, total, no IO
                    │  pass → speak (byte-identical to polished)    │
                    │  flag → escalate (cloud chat, consented) or   │
                    │         safe template (localized)             │
                    │  unavailable → today's behaviour (honest)     │
                    └──────────────────┬────────────────────────────┘
                                       ▼
                       ReplySanityGate → SpokenReplyPolisher.polish → speak
                       (+ observability: reply_grammar_flag, cloud_chat_*)

     Training box (P1):  Layer builders → filters (spec-driven) → teacher-GEC → 70/30 mix
                         → QLoRA (existing recipe) → chat gates + full regression harness
                         → provenance manifest → GGUF → NEW ModelCatalog entry (gated swap)

     Consent/UI:  CloudChatConsentGate (encrypted record) + ConsentPrompt (first cloud need)
                  + status-slot cloud indicator + Settings/voice revocation (§8, §18)
```

Data flow for a chat turn (online, consented): transcript (existing STT path, untouched) →
`IntentRouter.interpret` → cache/preparse miss → chat lane → `CloudChatRouting.decide` →
`.cloud` → `GeminiCommandInterpreter.respondToChat` (buildChat + chat persona + explicit
temperature) → `InterpretedCommand(.chat)` → `CommandRouter` dispatch (floor check) →
grammar guard on the final spoken text → speak. Any cloud failure/timeout degrades to the
local chat pre-check in the same turn (§8.8). Offline/declined/revoked: the local chat path
directly, with cloud escalation for that turn disabled (§8.2). Command and emergency turns
never enter this lane.

Data flow for a chat turn (local): unchanged pre-check path (`interpretLocalLadder` :259-291)
except the decode shape now carries the persona system slot and the chat temperature (§5, §10).
The reply flows through the same dispatch → guard → polisher → speak seam.

### 5. OD-1 — Chat decode sampling (resolved)

**Decision: chat temperature = exactly `0.3`** (a new named constant
`ChatSampling.chatTemperature: Float = 0.3`; NOT a mutation of `OnDeviceSampling`), applied as
a **per-turn, actor-ordered override on the single resident handle** — not a shape-specific
second handle.

#### 5.1 Value and constants

- `0.3` is the reviewed value (requirement says "~0.3"; a constant satisfies "~" by fixing
  it). Changing it later is a reviewed change to a recorded constant, not a tunable.
- New constant lives in a new small type (`ChatSampling`) so `OnDeviceSampling`
  (LlamaCommandInterpreter.swift:404-417: `fixedSeed = 20_260_907`, `temperature = 0`,
  topK 40, topP 0.95, repeatPenalty 1.2, lookback 64) is not moved, reparameterised or
  bypassed (FR-CNR-004). Seed stays `OnDeviceSampling.fixedSeed` — one fixed seed for both
  shapes.
- The handle creation call (`LLM(from:...seed: OnDeviceSampling.fixedSeed ... temp:
  OnDeviceSampling.temperature ...)`, :1391-1398) is untouched.

#### 5.2 Plumbing (why per-turn override; handles, sampling order)

- `ResponseShape` (:870-901) gains `var temperature: Float { .command →
  OnDeviceSampling.temperature; .chat → ChatSampling.chatTemperature }` and `runInference`
  receives the shape (it already receives the shape's schema, :1416-1417).
- Inside the generation task, immediately before the existing
  `llm.core.generateWithConstraints(from:jsonSchema:)` call (:1508-1510):
  `try? await llm.core.setParameters(temp: shape.temperature)`.
- **Determinism argument (why this is safe):** `LLMCore` is an actor (LLM.swift:34);
  `makeConstrainedSampler` (:711-720) builds the per-call chain
  `penalties → grammar → top_k → top_p → temp → dist(seed)` from the CURRENT handle fields at
  generation time; the awaited `setParameters` (:114-125) and the generation run on the same
  actor with no suspension between them inside the actor's serialized execution, and the whole
  turn is additionally serialized on `inferenceQueue` (label `llama.command`, :969). No other
  code path can interleave a field change mid-decode. The wrapper's fire-and-forget
  `LLM.temp` setter is NOT used (ordering with `generateWithConstraints` would not be
  guaranteed).
- **Every turn asserts its shape's temperature before decoding** — the handle persists across
  turns, so the command shape re-asserts temp 0 rather than assuming `OnDeviceSampling`'s
  initial value survives a preceding chat turn. With temp 0 the draw is deterministic
  (argmax under `dist`), the seed is unchanged, and the assembled command prompt is
  byte-identical (§10), so command outputs stay byte-identical to today (FR-CNR-004).
- **Rejected: a shape-specific second handle.** A second `LLM` instance doubles resident
  weights (two Q4_K_M copies) and duplicate decode state: it violates NFR-CNR-003's "exactly
  one brain model resident" and the recorded [VOICE-OOM] bug class ("a second 3.4 GB load is
  the bug class"). Rejected also: per-turn handle re-creation (model load per turn — latency
  and memory churn).
- **Test seam:** `runInference`'s override seam stays; a read-only
  `lastDecodeParameters: (temperature: Float, seed: UInt32, schema: String)` record is set on
  every path (override included via an added `generateOverride(prompt, schema, temperature)`
  variant, default compatible) so tests can assert "chat decode requested 0.3" and "command
  decode requested 0" without inspecting llama.cpp.

#### 5.3 GBNF interplay (honest)

Grammar masking happens in the sampler chain BEFORE top_k/top_p/temp → dist: the masked
distribution contains only grammar-valid tokens, so at temp 0.3 the output is still one JSON
object (`intent` = "chat" only — `LlamaGrammar.chatJSONSchema` :350-360 pins the enum —
`reply`, `confidence`); structural validity is preserved, only token CHOICE varies. An output
that still fails to parse abstains (nil) exactly as today (FR-CNR-003/013). There is no
configuration where temp > 0 with GBNF produces malformed JSON by construction; the honest
residual is content-quality variance, not structure.

#### 5.4 Reproducibility contract (NFR-CNR-001)

- Same transcript + same state + same device tier + same build → byte-identical reply, 100% of
  trials (the fixed seed makes the `dist` draw sequence identical for identical distributions;
  cross-session holds because nothing seed- or state-relevant is cached per session).
- **Explicit non-claim (see §20):** byte-identity across DIFFERENT device tiers or different
  builds is not claimed (Metal backend float differences can shift the last bits of logits).
  NFR-CNR-001 measures per tier and build; the requirement is met as written.
- A random/time-derived seed remains a defect: the seed is `OnDeviceSampling.fixedSeed`; the
  only per-shape variability is the reviewed temperature constant.
- Cloud path determinism (NFR-CNR-001 last bullet) is "identical configuration": the chat
  request is issued with the recorded `GenerationConfig` (fixed temperature, fixed
  responseMimeType) — the provider remains a nondeterministic service and the requirement is
  met by fixing the request parameters (§9).

#### 5.5 Error paths and isolation

| Failure | Outcome | Consumer |
|---|---|---|
| `setParameters` fails (cannot throw in practice — `try?` guards authoring drift) | decode proceeds with current handle fields; `lastDecodeParameters` records the requested value, and the mismatch is detectable in tests | turn still decoded; classification-only event `chat_sampling_override_failed` |
| Timeout (existing `config.timeoutSeconds`, :1517) | unchanged: `llm.stop()`, `inference_empty_output`/`inference_timeout`, completion(nil) | router fallback as today |
| Empty/failed decode | unchanged: abstain (nil) | `chat_abstained` path as today |

Isolation: one actor (`LLMCore`) + one serial queue (`inferenceQueue`) serialize all decodes;
no concurrent access to sampler fields is possible (§14).

### 6. OD-2 — The style spec and its four consumers (resolved)

**Decision: one extensionless artifact `tools/train-intent/seeds/nepali-chat-style-spec` in a
hybrid format — prose rule text (human authority) PLUS a machine-readable YAML block
(executable authority) — with four consumers that either load it directly (Python) or hold a
mechanically drift-checked byte-mirror of its named blocks (Swift). No consumer re-authors a
rule; the drift checker fails the build on any divergence.**

#### 6.1 Artifact and format

- Path is exactly `tools/train-intent/seeds/nepali-chat-style-spec` (as FR-CNR-001 fixes it;
  no extension added). Content: a YAML document (parseable by `PyYAML`, already a training-suite
  dependency) whose sections carry both `description` (prose, human) and machine fields. No
  seed CONTENT is authored in this design document; the sections and their consumers are the
  contract here.
- Sections (contractual names): `register` (rules; `honorific_pairs`: familiar→honorific verb
  forms, e.g. भन्यो→भन्नुभयो; `forbidden_address_forms`: तिमी family), `particles` (lexicon
  with longest-match units — है, नि, ल, ला, अनि, हुन्छ नि + morphological variants;
  `budget: 1`), `sentence_shape` (`max_sentences: 2`, SOV, one idea per sentence),
  `small_talk` (repertoire topics), `code_switch` (health/tech noun renderings),
  `ai_isms` (blacklist: list/markdown patterns, "म एक AI हुँ", canned service phrases,
  translation-ese stems, over-politeness stacking), `persona_clause` (the canonical SHORT
  rule clause to be embedded byte-identically by both personas), `guard_checks` (the executable
  inputs for §7: the lexicons/patterns the guard and the eval checkers share).
- Versioned: the spec carries a `version` field; the sha256 of the file is recorded in the
  training-run evidence and in the mirror-check output.

#### 6.2 The four consumers, exactly

| Consumer | Mechanism | Where |
|---|---|---|
| Personas (`chatSystemPrompt` chat-side system slot; cloud `replyPersona`) | Both embed the spec's `persona_clause` byte-identically (each with its own minimal transport wrapper). `check-prompt-mirror.py` extracts both literals and fails if the clause bytes differ from the spec | §10; FR-CNR-002 |
| Data-generation / teacher prompts (all four layers) | `src/style_spec.py` loads the spec at generation time and renders rules into every layer-builder and teacher-post-edit prompt. No prompt text is authored beside the spec | §11.1; FR-CNR-017 |
| Eval rubric (chat gates) | `eval_chat_gates.py` executes the spec's machine blocks: the honorific-agreement checker and the no-AI-ism checker ARE lexicon/pattern runs over the spec; the LLM-judge prompt's rubric criteria are rendered from the spec's rule text | §11.4; FR-CNR-020 |
| Grammar guard (on-device) | Swift holds `NepaliGrammarGuard`'s lexicons/patterns as compiled constants that mirror the spec's `guard_checks` block; `check-prompt-mirror.py` (extended) verifies byte-equality of each named block; a mismatch fails the check | §7; FR-CNR-005 |

#### 6.3 No-fork enforcement (NFR-CNR-005's verifiable property)

- `check-prompt-mirror.py` gains three checks: (a) `chat_prompt_template.txt` ↔
  `IntentPrompt.buildChat` (existing 4-placeholder mechanism, 3 placeholders here:
  `{language_hint}`, `{address_as_clause}`, `{transcript}`); (b) persona clause ↔ spec
  `persona_clause` (both personas); (c) guard lexicon blocks ↔ spec `guard_checks`. Each
  check exits non-zero on drift and runs in the same gate surface as the existing intent-prompt
  check. The Python side (`src/style_spec.py`) loads the spec directly, so Python consumers
  cannot hold copies.
- "The style spec's discipline is equivalent to the seed mirror" is thus mechanically
  verified, not reviewed by eye: a consumer block that stops matching the spec is a build
  failure, in the same change (FR-CNR-001 property 1; NFR-CNR-005 last bullet).

### 7. Grammar guard contract (FR-CNR-005/006/007, OD-4 included)

#### 7.1 Verdict type and seam position

New file `Services/Voice/NepaliGrammarGuard.swift`; a pure, total, context-free type (the
`SpokenReplyPolisher` doctrine, `SpokenReplyPolisher.swift:21-26`, is inherited: deterministic,
idempotent, **grammar stays the models' job** — the guard verifies, never rewrites):

```swift
enum GrammarCheckClass: String, CaseIterable {   // FR-CNR-007 permitted field
    case honorificAgreement, devanagariPurity, danglingParticle
}
enum GrammarGuardVerdict: Equatable {
    case pass
    case flag(classes: [GrammarCheckClass])   // sorted, classification only
    case unavailable(reason: String)          // reason code; see 7.4
}
static func verdict(spokenText: String, locale: String) -> GrammarGuardVerdict
```

- The guard returns a verdict, never text. There is NO code path in which guard output
  substitutes model words (FR-CNR-005 "no rewrite path exists").
- **Where it runs:** `CommandRouter.dispatchInterpreted`'s `.chat` case (:4490-4531) — after
  the `chatConfidenceFloor` check (unchanged), AFTER `SpokenReplyPolisher.polish` for the
  candidate text is computed but BEFORE `speak`; i.e. the verdict is computed over the exact
  text that would be spoken. A `.pass` speaks that text byte-identically (the guard changes
  nothing). Both local and cloud chat replies arrive at this single dispatch case, so "every
  model reply passes it — local and cloud alike" holds structurally (FR-CNR-005 property 3).
  The one call-site location of `polish` (:4557) is not duplicated; the guard wraps the
  `deliverModelReply` sequence from the dispatch level where the transcript is still in scope
  (needed for escalation, §7.3).
- **Idempotent/reproducible:** pure function of (text, locale, compiled lexicons) — same input,
  same verdict, run to run; re-running changes nothing (FR-CNR-005 property 4).

#### 7.2 Checks (deterministic; the machine inputs are the spec's `guard_checks`)

| Class | Rule (executable) | Bound |
|---|---|---|
| `honorificAgreement` | Flag if the reply contains any `forbidden_address_forms` token (तिमी family) as a word; flag if it contains any `non_honorific_verb_forms` standalone token whose honorific pair exists in `honorific_pairs` (the familiar finite forms a reply to the elder must not use) | Lexicon-bounded: forms outside the curated pairs are NOT caught (honest limit, §20) |
| `devanagariPurity` | For a Nepali session: flag if the reply contains Latin-letter runs other than tokens in the spec's (empty-by-default) latin allowlist; flag mixed-script tokens. Code-switched health/tech nouns are Devanagari renderings (प्रेसर, डाक्टर, …) and pass | Script classification only; not a spell checker |
| `danglingParticle` | Tokenize on whitespace/punctuation; longest-match the particle lexicon first ("हुन्छ नि" counts once). Flag if count > budget (1) — the OD-4 decision below — or if a particle token is dangling: the first token of the reply, or immediately preceded only by a sentence terminator/punctuation (no clause to attach to) | Budget ceiling is fixed at 1 (FR-CNR-001); dangling = the positional definition above |

**OD-4 decision (particle-budget enforcement):** the particle SET is the spec's lexicon
(है, नि, ल, ला, अनि, हुन्छ नि + variants) with longest-match-first tokenization so multi-word
units count once and the contained particle is not double-counted. Enforcement is **both**:
(a) the grammar guard flags >1 occurrences (and dangling particles) at runtime — the reply is
not spoken (§7.3); and (b) the eval rubric enforces it: the deterministic eval checker runs
the SAME lexicon over `chat_golden.jsonl` outputs, and the LLM-judge rubric includes "particles
within budget" as a scored criterion derived from the spec. One rule, two execution sites.
Interaction with the ≤2-sentence ceiling: the guard verdict is computed over the FINAL
(post-polisher) text — brevity trimming happens first, so a trimmed-away second sentence
cannot flag and a surviving one does; two sentences with one particle each = 2 > 1 → flag.
Code-switched sentences: English/Latin tokens are never particles; a particle following an
English noun ("प्रेसर छ, नि?") still counts by token rule (no noun-class exception — simpler and
testable; if this proves too strict in device testing it is a spec change, not a code
exception). The polisher's brevity profile remains the downstream backstop (unchanged).

#### 7.3 Flag outcome — honest degradation (FR-CNR-006)

On `.flag`, the flagged text is never spoken. Resolution order, exactly two outcomes:

1. **Escalate**: if the flagged reply came from the LOCAL shape AND `CloudChatRouting.decide`
   yields `.cloud` for this turn (consent granted, online, key, cost — §8.1), issue the cloud
   chat call for the SAME turn's transcript (`respondToChat`), whose reply is itself run
   through the guard before speaking (FR-CNR-005 property 3). If that reply passes, speak it.
   If the cloud call fails/timeouts or its reply also flags, go to (2). This is a second,
   smaller cloud egress surface and obeys the identical consent/disclosure rules (FR-CNR-009
   property 5).
2. **Safe template**: speak a short, grammatical, register-correct localized fallback
   (safe-template set, en+ne, authored to the spec, deterministic selection keyed by check
   class; exact copy authored at implementation — see Deferred work). Chat is never lost — the turn is always answered.

A flagged CLOUD reply takes only outcome (2) (escalating a cloud reply back to the same cloud
would repeat the failure; documented asymmetry, consistent with FR-CNR-006's "flagged local
reply" scenarios).

#### 7.4 Guard-failure honesty (FR-CNR-006 property "a guard that fails to run")

The guard is pure and total, so a runtime failure is structurally unreachable; the
`.unavailable(reason)` verdict exists as the contract's third state (e.g. a future
lexicon-loading change). On `.unavailable`: the turn proceeds under today's behaviour (the
polished text is spoken), and a `reply_grammar_flag` event with outcome `degraded` is emitted
so "a guard that is not running is visible rather than silently absent" (FR-CNR-007). It never
blocks speech with an error and never reports a success it did not verify.

#### 7.5 Telemetry (FR-CNR-007; NFR-CNR-007)

Event `reply_grammar_flag` on the existing observability bus. Permitted fields ONLY: event
kind; `path` (on-device/cloud); `check` (space-joined `GrammarCheckClass` raw values; empty for
degraded); `outcome` (`escalated` / `safeTemplate` / `degraded` / `notApplicable` — the last
for `.pass`, or omitted entirely for pass per the schema frozen before implement);
counters; timestamps. Forbidden: transcript, reply text, identity, health values, contacts,
profile, key material. Emitted for local, cloud and degraded cases. Schema frozen before
implement; adding a content-bearing field is a defect (NFR-CNR-007 property 4); the advisory
security pass reviews it.

### 8. Cloud-first chat routing toggle (the OD-12-shape amendment)

#### 8.1 The routing decision (single chokepoint)

New pure type `CloudChatRouting`:

```swift
enum ChatRoute: Equatable {
    case cloud                                   // egress allowed this turn
    case local(reason: LocalReason)              // fail-closed; no egress
    enum LocalReason: String { case consentNotRecorded, consentDenied, consentRevoked,
                                    consentUnreadable, offline, keyMissing, costBlocked }
}
static func decide(consent: CloudChatConsentGate.Decision,
                   online: Bool,
                   keyConfigured: Bool,
                   costAllows: Bool) -> ChatRoute
```

- The ONLY yes is `consent == .granted` AND online AND key AND cost → `.cloud`. Everything
  else is `.local(reason)` — fail-closed, one function, exhaustively unit-tested (16 cells).
- This is "enforced at the routing decision, not merely in the UI" (FR-CNR-009): the gate's
  decision is read per turn at this single point (wired as closures like `geminiKeyConfigured`
  :107-108; nil closure reads as not-granted — every pre-feature construction site and test
  keeps compiling and selects local, honestly).
- `online` uses the existing reachability discipline (LiveTranslate's `NetworkReachability`
  pattern; provided as a closure so tests inject it).

#### 8.2 Insertion point and the no-ladder-change proof (FR-CNR-008, FR-CNR-014)

In `IntentRouter.interpret` (:167-223), AFTER the cache layer and the cloud-preparse layer and
BEFORE the `cloudFirstEnabled && cloudEnabled` selector block (:197):

```
if ChatIntentClassifier.classify(transcript) == .chat {
    switch CloudChatRouting.decide(...) {
    case .cloud:  interpretCloudChat(...)      // new: cloud ChatResponding
    case .local:  interpretLocalLadder(..., chatEgressDisabled: true)
    }
    return
}
```

- **Only `.chat`-classified turns are diverted.** `ChatIntentClassifier` is the existing
  conservative exact-table classifier (any content cue → `.command`); every command, ladder,
  cascade and emergency utterance takes the identical code path as before (FR-CNR-014). The
  classifier table is NOT widened by this feature.
- **Why a `.chat` turn never reaches the command ladder's cloud escalation**: for a
  chat-classified turn the turn must resolve through chat surfaces only — cloud chat, else
  local chat, else the existing local ladder with cloud escalation disabled FOR THAT TURN.
  Otherwise the FR-CNR-009 failure scenario ("consent declined/revoked → no chat content
  leaves the device") could be violated by a chat turn's abstention escalating to the cloud
  command path. The cost is confined to utterances byte-equal to the closed small-talk table
  (genuinely small talk by construction); a false `.command` costs nothing and a false `.chat`
  can only divert an exact table hit — the classifier's own documented trade-off, preserved.
  `chatEgressDisabled` is a parameter of the LOCAL lane for chat-classified turns only; the
  lane's ladder body is otherwise untouched.
- **Emergency isolation:** the chat lane performs no model-independent delay and no new
  blocking call; the emergency gate's precedence is untouched (FR-CNR-014); DV-4 re-verifies
  recall on device. A cloud chat attempt cannot block the emergency path: it runs on the
  router/existing async seams, and the emergency module's isolation from LLM availability is
  preserved.
- **Cloud preparse note:** the preparse layer above the chat lane is produced by the Gemini
  speech stack's collapsed transcription call (GeminiSpeechRecognizer): on a Gemini-stack
  device the transcript already travels to the provider for transcription under the
  STACK-level consent (the recorded OD-12 transcription exception). This feature neither
  widens that path nor claims to remove it; the chat consent gate governs the REPLY surfaces
  (routing + escalation). Recorded explicitly in §20 — a silent drop it is not. On the
  on-device speech stack, no chat content leaves at all without chat consent.

#### 8.3 Consent gate (OD-12 shape — binding)

`CloudChatConsentGate`, mirroring `LiveTranslateConsentGate`'s shape as the implementation
precedent (fail-closed decision, one writer, revoke-verify, disclosure version):

- `enum Decision: Equatable { granted, notRecorded, denied, unreadable }` with
  `var allowsEgress: Bool` (only `.granted`). `.unreadable` is fail-closed.
- `struct ConsentRecord: Codable, Equatable { granted: Bool, recordedAt: Date,
  disclosureVersion: String }` stored via the existing encrypted-at-rest consent pattern
  (Keychain-backed storage; the store seam reuses the mechanism the LiveTranslate consent record uses — reuse, not a fork; see Deferred work).
- One writer (`grant()`, `revoke()` guarded by an NSLock); revoke clears in-memory state
  BEFORE storage; a write that did not take effect is surfaced as a failure, never as success.
- A record whose `disclosureVersion` differs from the current constant is treated as
  `.notRecorded` (re-disclosure after a copy change — the LiveTranslate pattern).
- Consent is the ELDER's act: the prompt (§8.4) is presented at the first cloud chat need and
  answerable by voice (yes/no via the existing spoken-confirmation capture) or touch.

#### 8.4 Disclosure (plain language; final copy at implementation — Deferred work)

At the first moment a chat turn WOULD route to the cloud: a blocking prompt (no timeout, no
auto-dismiss — mirroring `ConsentPromptController`'s doctrine that auto-dismissal is implicit
consent): "conversation goes to an internet service to be answered; everything else stays on
this phone; you can stop it anytime". Until answered, the turn is answered locally (never
content sent, never a dropped turn — chat is never blocked). Declined → recorded `denied`;
no re-prompt within the session. Copy + indicator UX are reviewed before the first App Store
submission (FR-CNR-009; OD-12/13 review clause), and the feature-level exception is recorded
so the root constitution's exceptions list can be amended at final sign-off.

#### 8.5 Visible indicator

- While cloud chat is active the status slot shows a persistent badge (existing status-slot
  surface; no new screen): presented from the routing decision of a cloud turn until its reply
  is spoken, and it also reflects the enabled state in Settings. "Present for the whole time
  conversation content is going to the cloud — not a one-time toast" (FR-CNR-009/ NFR-CNR-009:
  100% of cloud-active chat turns, DV-2).
- Spoken form: a one-per-session short spoken notice at the first cloud-active turn in the
  user's language (final copy at implementation — Deferred work; NFR-CNR-010); the badge remains visible regardless.

#### 8.6 Revocation (voice-first, NFR-CNR-009)

- Settings row (family/caregiver paths) toggles cloud chat off; wired through the gate's one
  writer.
- Elder voice path: one small deterministic keyword-rule family added to the existing keyword
  safety net (KeywordIntentRule — no model involvement, no NLU change): (a) revoke cloud chat,
  (b) spoken state query ("is the cloud on?"). Exact phrases: implementation (Deferred work). This is what
  makes "consenting, revoking, learning whether the cloud is active" voice-reachable — no
  new behaviour is touch-only (NFR-CNR-009 property 1).
- Revocation takes effect at the NEXT turn's routing decision (read per turn — no cached
  route), returns chat to the on-device brain, and loses no chat functionality.

#### 8.7 Egress scope (FR-CNR-010)

Exactly one payload shape: the chat request carries the sanitised transcript (the user's own
utterance) and the chat template/context needed to answer that turn. No health data, contacts,
family data, profile content, device identifiers, or recordings are attached (the
`GeminiClient` builder is the chokepoint; a test asserts the request body contains only the
composed prompt text). Emergency and command content never travel this lane (§8.2). The
escalation path has the identical scope (§7.3).

#### 8.8 Degradation (FR-CNR-008)

Cloud-chat attempt failure/timeout (existing `GeminiClient` timeout config), offline,
rate/cost block: fall back IN THE SAME TURN to the local chat path (`interpretLocalLadder`
chat pre-check), emit `cloud_chat_fallback` (classification + reason only), and answer —
no user-visible error where a reply is expected, no dropped turn. The fallback decision is
bounded by the cloud attempt's own budget (NFR-CNR-002): worst case = local envelope + the
bounded attempt, never an indefinite wait. The on-device engine remains a first-class peer:
with cloud chat off the assistant is fully functional.

#### 8.9 Reuse, don't fork

The lane uses the existing `GeminiClient`, the existing router readiness inputs
(`geminiKeyConfigured`, `geminiCostAllows`), the existing `GeminiCommandInterpreter` object
(it gains a `ChatResponding` conformance), and the existing dispatch/speech seam. No parallel
cloud client, no second provider integration.

### 9. OD-5 — Explicit Gemini chat temperature (resolved)

**Decision: cloud chat temperature = `0.3`** — parity with the on-device value, one reviewed
number for the same style contract.

- `GeminiRequest.GenerationConfig` (GeminiClient.swift:659-661) gains an optional
  `temperature: Double?`; `generateJSON` (:168-180) passes it through. ONLY the new chat call
  site sets it (`GeminiChatConfig.temperature: Double = 0.3`, a new named constant). Every
  other call site (voice transcription, translation tier, teacher tooling, the command
  `interpret` path) sends today's shape with no sampling parameter — chat-scoped (FR-CNR-011).
- Rationale: 0.3 is the same escape from greedy cliché as the on-device side; identical values
  keep the two paths from drifting in perceived register (FR-CNR-002); a provider default is
  replaced by a stated, reviewed value visible in code and in this record.
- The chat request additionally sets search grounding OFF for the chat call (design decision,
  rationale: chat answers come from the persona, not web retrieval; keeps the request
  minimal and the latency tail tighter; flagged for confirmation in the advisory security pass (final-sign-off) —
  it changes no egress scope of user content, which remains the transcript only). The command
  `interpret` call's grounding behavior is untouched.
- Cloud determinism is "identical configuration" (NFR-CNR-001): fixed temperature + fixed
  responseMimeType are recorded; the service itself is nondeterministic by nature and the
  requirement is met as written.

### 10. Personas and prompt discipline (FR-CNR-002, FR-CNR-023)

- The local persona is applied ONLY to the chat shape: `ResponseShape` gains a per-shape
  system slot — `.command` keeps the CURRENT `chatSystemPrompt` bytes untouched (the
  command decode's assembled prompt, system included, stays byte-identical → command outputs
  stay byte-identical at temp 0), `.chat` uses a NEW short system text built from the spec's
  `persona_clause` (concrete rules — register/तपाईं+honorific, particles ≤1, code-switch
  nouns, forbidden AI-isms, ≤2 sentences — not abstractions like "warm grandchild").
- The cloud persona `replyPersona` (:35-44) is rewritten from the SAME `persona_clause`
  (byte-identical clause inside its wrapper) so the two paths cannot drift (FR-CNR-002); both
  remain declarative and short.
- Budget: the fully assembled chat prompt (chat system text + `buildChat` template + turn)
  tokenises ≤1,024; enforced by the extended `IntentPromptTests` ceiling; no few-shot
  exemplars anywhere in the device prompt (FR-CNR-023; NFR-CNR-004 — headroom shortfalls are
  reported, never solved by truncating the turn or by making the cloud the offline answer).
- Seed mirrors: `tools/train-intent/seeds/chat_prompt_template.txt` byte-mirrors
  `IntentPrompt.buildChat` and lands in the SAME change as any `buildChat` edit; in P0 the
  mirror is created against the CURRENT `buildChat` text (no text change required for P0),
  and the extended `check-prompt-mirror.py` enforces it from then on. `IntentPrompt.build` +
  `seeds/prompt_template.txt` + the pin remain byte-identical (sha256-verified by the existing
  check plus a new equality assertion in the mirror report).

### 11. Training-suite extension — v17 (P1)

#### 11.1 Corpus (FR-CNR-016, FR-CNR-017)

- `src/build_chat_corpus.py` builds the four layers per the proposal, each shaped by
  `style_spec.py`-rendered prompt text:
  L1 native Nepali (IndicDialogue, call-center transcription sample via the existing Whisper
  pipeline, Devanagari-Ecommerce Apache-2.0; optional nepali-sft sets teacher-cleaned),
  L2 translated+post-edited English dialogue (research-only set and commercial-safe set),
  L3 teacher-generated synthetic elderly-care dialogues (~10–20k turns),
  L4 claw-back (golden_corpus.jsonl, emergency_nearmiss.jsonl, abstain/honesty examples,
  light instruction data, STT-noised turns at the suite's existing 60% rate via `stt_noise.py`).
- Every assistant turn is teacher-GEC'd (existing teacher config, `gemini-2.5-flash-lite`)
  before admission — grammar comes from the data.
- Target ~30–60k clean turns post-filter; mixture 70% conversation / 30% claw-back (the
  intent-regression mitigation, not optional).

#### 11.2 Filters (admission gates on data, source = spec)

Honorific-agreement checker and AI-ism blacklist (the same spec machine blocks the guard/eval
execute — one rule), length filter, and a held-out dedupe/near-duplicate check against
`chat_golden.jsonl` BEFORE admission (a golden leak invalidates the run — FR-CNR-019).
Human spot-check of L1/L2 post-edit outputs.

#### 11.3 Config and recipe (FR-CNR-016)

`config.yaml` gains an additive `chat:` variant section (enable flag, mixture ratios, layer
paths, filters); with the flag absent, the existing pipeline runs byte-identically (v14/v16
runs reproducible). Recipe unchanged: QLoRA r=16, α=32, lr ~1e-4, 2–3 epochs, 1024 seq,
Q4_K_M export; base Qwen3-1.7B device default (extended-tokenizer base preferred); 4B only
via the per-device resolver (P2).

#### 11.4 Gate-harness extension (FR-CNR-020, FR-CNR-021; NFR-CNR-008)

`eval_chat_gates.py` runs over `chat_golden.jsonl`: deterministic honorific-agreement pass
rate and no-AI-ism pass rate (spec lexicons), plus an LLM-judge mean (naturalness/grammar/
warmth/brevity) using the recorded judge (Gemini, temperature 0, model version + prompt +
rubric recorded with the result — the `stt_judge_eval` judge discipline applied). Thresholds:
≥0.98, ≥0.98, ≥4/5. The existing `eval_golden.py` regression harness (emergency recall 1.00,
abstention ≥0.90, closed-intent ≥0.95, calibration ±0.10, near-miss ≥0.98, side-effect
precision ≥0.97, latency p50 ≤1.0 s) re-runs unchanged over the SAME candidate. Red gate =
stop; the swap does not ship; the shortfall is reported to the owner (never absorbed by
loosening).

#### 11.5 Provenance manifest (FR-CNR-018)

The run emits `build/<run-id>/provenance-manifest.json`: every source with license, layer,
ship/dev classification, counts used, derived artifacts, and the `chat_golden.jsonl` exclusion.
Ship mix = CC-BY/Apache/MIT + synthetic + own data only; CC BY-NC (IndicDialogue, DailyDialog,
PersonaChat, EmpatheticDialogues) and the research-gated call-center transcripts are dev-mix
only and can never reach a shipped artifact; tooling inputs are classified too. The manifest
travels with the run into final-sign-off (advisory security pass) as compliance evidence, and its
sha256 is recorded with the gate results.

#### 11.6 Model delivery, tiers, rollback (FR-CNR-022, FR-CNR-028)

- NEW versioned `ModelCatalogEntry` (id marked `v17`/chat variant, real sha256, sizeBytes,
  `minDeviceRAMBytes`, languages ne/en) placed BESIDE `intentQwenS43`; `availableBrainEntries`
  lists both. Selecting the entry changes the served model with zero chain/router changes.
- Default promotion only with ALL gates green + manifest attached; recorded with the gate
  evidence. The promotion is expressed through the catalog default resolution seam
  (`resolvedBrainModelID`/`LanguageModelResolver.resolvedAutomaticPick` — the per-language
  remembered-pick + default map is reference DATA), so a rollback to the previous entry is a
  catalog-level operation with no code change and no gate re-run (the previous entry already
  carries green evidence) — FR-CNR-022's reversibility, exercised in DV.
- Tiers: 1.7B default; 4B only through the resolver and only if it holds the latency envelope
  and memory behavior on that tier (NFR-CNR-002/003); §20 records the reference-tier verdict.
- A/B on Anzaan rides the catalog pick (listening panel; DV-6).

#### 11.7 P2 hooks (FR-CNR-026/027/028/029)

- DPO: preference pairs from the SAME judge rubric; result is a NEW catalog candidate behind
  the full harness (never an in-place mutation); starts only after P1's swap is live and DV
  has run; descopable only by the owner explicitly (FR-CNR-026).
- Romanized chat: additive; Devanagari behavior and all gates unchanged; if unreliable, it is
  reported not-delivered (FR-CNR-024 honesty) — FR-CNR-027.
- 4B tier: per §11.6, memory/latency-gated (FR-CNR-028).
- Real transcripts: explicit informed revocable consent before collection (UAT/test-device
  sessions first), withdrawal removes future mixes, classified as own data in the manifest,
  no silent harvest, gated as a new candidate (FR-CNR-029).

### 12. Data model and persisted state

- **`CloudChatConsentGate.ConsentRecord`** (NEW persisted datum; §8.3) — encrypted at rest via
  the existing consent-storage pattern (Keychain-backed; Data Protection household standard).
  Fields: `granted`, `recordedAt`, `disclosureVersion`. Corrupt/unreadable payload ⇒
  `.unreadable` ⇒ fail-closed (local route), never a crash and never a silent grant.
- **Preferences** — none required beyond the consent record; the Settings toggle writes
  through the gate (revocation is a record state, not a separate flag), so there is exactly
  one source of truth for "may chat egress".
- **No new device schema otherwise**: the feature adds no store fields, no new permission
  keys, no `Info.plist` change (FR-CNR-015). The v17 catalog entry is catalog reference data;
  its download/install uses the existing ModelStore lifecycle (existing outcomes, §15).
- **Repo/run artifacts** (not device state): style spec (+version +sha256), both seed mirrors,
  corpus + provenance manifest, `chat_golden.jsonl` (versioned with the run), GGUF, catalog
  entry. Their formats are the contracts named in §22 (Components); content is authored at implementation,
  not here.

### 13. Timeouts and configurable parameters (agent principle: timeouts are configuration)

| Parameter | Value | Status |
|---|---|---|
| `ChatSampling.chatTemperature` | 0.3 | NEW named constant (reviewed; §5) |
| `GeminiChatConfig.temperature` | 0.3 | NEW named constant (reviewed; §9) |
| `OnDeviceSampling.*` (seed/topK/topP/temp/penalties) | unchanged | untouched (FR-CNR-004) |
| Local decode timeout | existing `LlamaCommandInterpreter.Config.timeoutSeconds` | unchanged, still config |
| Cloud attempt budget | existing `GeminiClient` timeout config (+ its existing retry policy) | unchanged, still config; fallback bound = local envelope + this budget (NFR-CNR-002) |
| Preparse freshness | existing `IntentRouter.Config.preparseFreshnessSeconds` | unchanged |
| Consent prompt dismissal | NONE (blocking decision; a timeout value would be wrong — the ConsentPromptController doctrine) | no timer |
| Indicator | event-driven (decision → spoken reply); no timer | none |
| Particle budget | 1 | spec data constant (FR-CNR-001), not a timeout |
| Guard | pure function | no timeout possible |

No new timeout literals are introduced anywhere; the only new numbers are the two reviewed
temperatures and the spec's budget.

### 14. Concurrency and isolation (explicit)

| Component | Isolation | Concurrent access |
|---|---|---|
| `IntentRouter` chat lane + readiness closures | router state mutated on its owning thread (as today); the lane adds no shared mutable state beyond reading the injected closures per turn | closure reads are per-turn; the consent gate is internally locked |
| `CloudChatConsentGate` | NSLock; single writer; revoke clears memory before storage | decision reads and grant/revoke writes may interleave safely; no partial states observable |
| `NepaliGrammarGuard` | pure static (no state, no IO) | callable from the speech path thread; trivially thread-safe |
| `LLMCore` sampling override | actor (LLM.swift:34); `setParameters` then `generateWithConstraints` are actor-ordered; the turn is additionally serialized on `inferenceQueue` (label `llama.command`) | no interleaving possible mid-decode (§5.2) |
| `CommandRouter` speech/dispatch | main-thread-confined (existing) | unchanged |
| `GeminiClient` calls | URLSession-based, per-call objects; no shared mutable request state | chat and command calls are independent; cost governor gate before network (existing) |
| Audit/lifecycle (`ModelLifecycleManager`) | existing actor/seam; the v17 swap uses the existing lifecycle | no new keeper of large allocations; one resident model (§11.6) |

Single-flight rules: the consent prompt presents at most once per session (a state machine on
main, mirroring ConsentPromptController); guard escalation issues at most ONE cloud attempt
per flagged turn (no retry loop — a failed escalation goes straight to the safe template);
cloud chat has the client's existing bounded retry only.

### 15. Error-path catalogue

| Interface | Failure | Returned outcome | Consumer behavior |
|---|---|---|---|
| `ChatSampling` override (`setParameters`) | authoring drift / call fails | requested value recorded; `try?` | decode proceeds; test-detectable; `chat_sampling_override_failed` event |
| Local chat decode | empty output / timeout | nil (existing `inference_empty_output` / `inference_timeout`) | `chat_abstained` → local ladder (escalation disabled for chat turns) |
| `CloudChatRouting.decide` | any non-granted input state | `.local(reason)` — total function, never throws | reasons map: `consentNotRecorded` → present disclosure + local answer; `consentDenied/Revoked` → local, no re-prompt; `offline/keyMissing/costBlocked` → local; each emits classification event |
| `CloudChatConsentGate` | unreadable/corrupt record; write failure on grant/revoke | `.unreadable` (routes local) / grant-revoke returns failure surfaced to UI | never a silent grant; never a crash |
| Cloud chat call | timeout / non-200 / malformed JSON / empty reply | nil → `cloud_chat_fallback(reason)` | same-turn local chat path (NFR-CNR-002 bound) |
| `respondToChat` (cloud) parse | reply JSON invalid/missing fields | nil | treated as cloud failure → fallback |
| `NepaliGrammarGuard.verdict` | (structurally unreachable) unavailable | `.unavailable(reason)` | turn proceeds under today's behaviour + `reply_grammar_flag` outcome `degraded` |
| Guard flag resolution | escalation unconsented/offline/failed; escalation reply also flags; flagged cloud reply | safe template | localized safe reply spoken; event outcome `safeTemplate` |
| `ModelCatalogEntry` install (v17) | download/hash/space failures | existing ModelStore outcomes (unchanged) | resolver keeps serving the previous entry (rollback = previous entry still addressable) |
| Mirror/drift checks (`check-prompt-mirror.py`) | consumer block ≠ spec; seed ≠ buildChat | exit non-zero | build/test fails; never a silent drift |

### 16. Privacy, log safety, egress discipline, release gate wiring

- **Zero content in logs** (NFR-CNR-006, FR-CNR-012): the new chat/routing/guard/consent code
  logs/emits classification only — event kinds, outcomes, reason codes, check classes,
  counters, model/catalog ids. No utterance, reply, transcript, prompt dump, request/response
  body, or key material — error paths record a reason code, never the payload.
- **Key handling**: unchanged — provider key in the `x-goog-api-key` header only (never URL,
  never log); the new chat path reuses the same request builder.
- **Telemetry schemas** (§7.5, §8.1/§8.8 events) are frozen before implement; a
  content-bearing field is a defect; the advisory security pass reviews them. Events ride the existing observability channel — not a
  new egress surface.
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of
  every test scope) must exit 0 with the new chat/routing/guard/consent source paths inside
  its coverage (feature role); its fixture suite stays green; the pre-release device
  console/sysdiagnose check covers the new paths.
- **Egress inventory (this feature)**: exactly two provider surfaces — the cloud chat reply
  call and the guard escalation — both consent-gated by `CloudChatConsentGate`, both carrying
  only the chat turn's content (§8.7); plus the unchanged existing surfaces (transcription
  under stack consent; the command interpret path for non-chat turns). No new hosts/endpoints.

### 17. Accessibility, localisation, consent/indicator surfaces

- All new user-visible strings exist in `ne` and `en` via the string catalogue (L10n keys;
  final wording at implementation — Deferred work): `cloud.chat.consent.title/.body/.allow/.notNow`;
  `cloud.chat.indicator` + `cloud.chat.indicatorSpoken`; `cloud.chat.revoke.title/.body/.done`;
  `cloud.chat.state.spoken.*` (voice state query answer); `settings.cloudChat.*`;
  `chat.safeTemplate.<class>` (+ generic); optionally `chat.cloudFallback.notice` (config-only,
  not spoken, unless implementation decides otherwise — Deferred work). `L10nCatalogCoverageTests` extended (both languages,
  values differ, placeholder counts).
- Safe templates and the spoken indicator/state lines are spoken in the configured language —
  a Nepali device never speaks an English-only fallback (NFR-CNR-010).
- Accessibility: consent sheet, indicator, Settings row ≥44 pt controls, ≥18 pt text, plain
  language (no "routing", "model", "fallback" terms — NFR-CNR-009); the elder is never asked
  to reason about routing internals; every new function is voice-reachable (§8.6).
- No new permission and no `Info.plist` change (FR-CNR-015).

### 18. DV protocol on Anzaan (FR-CNR-025 — the completion gate)

Each item recorded with outcome at final-sign-off; a failed/skipped item withholds completion.

| DV | Script | Evidence |
|---|---|---|
| DV-1 local chat | force local (consent declined or offline); chat turns: warm, grammatical, honorific agreement, particles ≤1, no AI-isms; safe template engages on a seeded guard flag | session notes + `reply_grammar_flag`/`command_llm_chat` events (classification only) |
| DV-2 cloud-first chat | first-use disclosure appears before any send; consent granted; indicator visible for cloud-active turns; revoke (voice + Settings) returns to on-device without losing chat | consent record state + indicator presence count (100% of cloud-active turns) |
| DV-3 offline degradation | airplane mode: chat answers locally; forced cloud failure mid-turn degrades without crash/false success/dropped turn; latency ≤ local envelope + bounded attempt | session notes + fallback events |
| DV-4 emergency phrasing | emergency utterances still trigger exactly (recall untouched on device) | existing emergency check script |
| DV-5 command determinism | reminders/alarms answer identically to pre-feature behavior (temp-0 path unchanged); two repeat commands byte-identical | side-by-side with the previous build |
| DV-6 listening panel | A/B behind the catalog pick (v17 vs previous, or P0-build vs previous for a P0-only landing); elderly listeners' verdict recorded VERBATIM | recorded verdict; A/B pick flip + rollback exercised here |
| Honorific-mismatch telemetry | captured during the DV session (classification only) | event counts |
| Release gate | `check-release-log-safety.sh` exits 0 with new paths covered; pre-release console/sysdiagnose check on the same paths | gate output + device capture |

### 19. Sequencing and the OD-3 record

#### 19.1 The P0 slice is independently landable (design guarantee)

Every P0 item works against the CURRENT shipped model (`intentQwenS43`, 1.7B default) with
ZERO dependency on P1 artifacts: the persona/spec/guard/consent/routing/Gemini-temperature
changes touch only runtime seams and repo artifacts that exist at base; `chat_golden.jsonl`,
the corpus, the GGUF, and the v17 catalog entry are not referenced by any P0 path; the
catalog default stays `intentQwenS43` until P1's gates are green. A P0-only PR therefore
ships with no rework: P1 later adds data/artifact files + one catalog entry + the default
resolution change.

#### 19.2 OD-3 — recorded exactly as the owner question it is (NOT decided here)

> **OD-3 (owner question):** owner directive = full P0→P1→P2 in this run, P0 first; the
> P0-PR-first option preserved by design; re-surfaced to the owner via Slack question id
> `q-ask-2f6a8883-804e-4ac5-9a58-c0762f257074` (2026-10-14); pending owner answer; any
> sequencing deviation is reported per FR-CNR-024.
>
> (The design preserves the second option literally: §19.1's P0 slice is independently
> landable with no rework.)

### 20. Feasibility honesty statement (FR-CNR-024; locked constraint C13)

No silent drops. Verdicts for every named leg:

| Leg | Verdict | Statement for the owner |
|---|---|---|
| Chat sampling (temp 0.3, fixed seed, GBNF) | FEASIBLE as specified | Reproducibility holds per device tier + build (byte-identical repeats, NFR-CNR-001's own scope). GBNF validity is preserved at temp 0.3 (grammar masks before sampling). NOT claimed: byte-identity across different tiers/builds (Metal float differences can shift distribution tails) — the requirement does not demand it. The per-turn override re-asserts temp 0 for commands, so command determinism is untouched |
| Grammar-guard coverage | PARTIALLY feasible — bounded, stated | The deterministic checks catch: forbidden तिमी-family forms, the curated familiar↔honorific verb pairs, Latin-script runs in Nepali replies, particle count >1, positionally dangling particles. They do NOT catch: agreement forms outside the curated pairs, case/postposition errors, complex agreement, word-order errors. The guard is a floor (never a false "verified"), not a grammar proof; the gates + P1 corpus carry the rest. A `flag` never invents text; false negatives are the honest residual |
| Cloud chat routing (consent/disclosure/indicator/revocation) | FEASIBLE as specified, with one recorded scope note | The consent gate governs the reply surfaces (routing + escalation) and is enforced at the routing decision. On a Gemini SPEECH stack device, the utterance transcript already travels for transcription under the existing stack-level consent (recorded OD-12 transcription exception) before the chat decision exists; this feature does not widen that path and cannot retroactively gate it — "no chat content leaves the device" is guaranteed at the chat reply/escalation surfaces, and fully (including transcription) on the on-device speech stack. Recorded, not dropped |
| Training thresholds (P1) | FEASIBILITY MEASURED AT THE RUN | If the corpus/gates do not reach ≥0.98/≥0.98/≥4/5 with all regressions green, the swap does NOT ship; the measured shortfall is reported to the owner. P0 is unaffected either way |
| 4B tier admission | LIKELY NOT ADMISSIBLE on the reference 6 GB tier | The 4B latency failure is documented at default; admission requires the latency envelope AND memory behavior on that tier. Until a tier holds both, the 4B variant exists only as a gated, non-default catalog candidate (P2, COULD). Recorded |
| Romanized chat (P2) | UNPROVEN | Ships only if the full harness stays green; otherwise reported as not delivered (FR-CNR-027) |
| Chat-classified surface scope | STATED BOUND | The P0 decode/persona/cloud-chat improvements act on turns `ChatIntentClassifier` routes as chat (the conservative closed small-talk table); content-bearing conversational turns keep the command decode by design (FR-CNR-004), improving via the P1 model's register. The table is not widened |

### 21. Test plan and gates

Scoped XCTest suites (house rule: focused tests + typecheck per unit; scoped runs at gates;
full suite once at the end with pre-existing baseline failures recorded, never masked):

- NEW `ChatSamplingTests`: shape→temperature mapping; command decode requests temp 0 on every
  turn (including after a chat turn); chat decode requests 0.3; repeat-decode byte-identity
  probe via `lastDecodeParameters`; schema passthrough unchanged.
- NEW `NepaliGrammarGuardTests`: each check positive/negative; particle lexicon longest-match
  (`हुन्छ नि` = 1); budget boundary (1 passes, 2 flags); dangling-position cases; code-switch
  nouns pass; Latin-run flag; Latin-free Nepali passes; idempotence (same verdict over
  repeats); totality (no throws); Devanagari edge cases pinned, not "fixed".
- NEW `StyleSpecMirrorTests` (or extensions in the python `tests/`): spec loads/validates;
  persona clause byte-equality (both personas); guard lexicons byte-equality; chat template
  mirror; intent prompt + seed untouched (sha256 equality).
- NEW `CloudChatRoutingTests`: the decision matrix (consent × online × key × cost = 16 cells);
  decline/revoke ⇒ local AND zero cloud call recorded (fake chat brain spy); failure ⇒
  fallback + classification event; chat turns never enter the command ladder/cascade; command
  turns byte-identical behavior.
- NEW `CloudChatConsentGateTests`: fail-closed `.unreadable`; one writer; revoke-verify;
  disclosureVersion mismatch ⇒ notRecorded; round-trip through encrypted storage.
- NEW `CloudChatEgressTests` (fake client): request body = composed chat prompt only; header-only
  key; timeout from config; no content in any log path (fixture-level).
- NEW `ReplyGrammarFlagEventTests`: event carries only permitted fields (the frozen schema);
  degraded case distinct; emitted for local/cloud.
- CHANGED suites: `IntentPromptTests` (build pin unchanged; chat assembly ceiling extended to
  include the persona), `L10nCatalogCoverageTests` (new keys), router suites (chat lane
  insertion leaves command paths pinned), log-safety fixtures.
- Python: `tests/test_style_spec.py` (loader/validation), gate-harness fixture tests for
  `eval_chat_gates.py` (fixture-backed, no network), corpus-filter unit tests (a golden leak
  is detected).
- Gates (lean chain per the owner directive 2026-10-14): design (this document — the combined
  L1+L2 design of record; review-l2 and review-implementation dropped) → plan-tasks →
  implement (unit-based; confidence 0.85; no paired review) → final-sign-off T2 + HIL with the
  DV record and the feasibility statement (§20), carrying ONE advisory, non-blocking security
  pass (STRIDE + security-test scope; findings recorded with the sign-off). The hard safety
  gates — emergency recall 1.00, abstention ≥0.90, closed-intent ≥0.95 — remain enforced by
  the training eval gates (§11.4) and implementation tests; they are not review gates. Release
  gate `check-release-log-safety.sh` exits 0.

## Components

### 22. Module boundaries and responsibilities

| File / artifact | Status | Responsibility | Requirements |
|---|---|---|---|
| `tools/train-intent/seeds/nepali-chat-style-spec` | NEW (single source) | THE conversational register: prose rules + machine blocks (register/particles/ai-isms/code-switch/persona clause); consumable by Python tooling and drift-checkable against Swift mirrors (§6) | FR-CNR-001, FR-CNR-002, FR-CNR-005, FR-CNR-017, FR-CNR-020; NFR-CNR-005 |
| `tools/train-intent/seeds/chat_prompt_template.txt` | NEW | Byte-mirror of `IntentPrompt.buildChat`'s text (3 placeholders), same-change rule enforced by `check-prompt-mirror.py` (§10) | FR-CNR-023; NFR-CNR-005 |
| `ios/tools/check-prompt-mirror.py` | CHANGED | Extended: chat template mirror check + persona-clause check + guard-lexicon check (the no-fork verifier) | FR-CNR-001, FR-CNR-023; NFR-CNR-005 |
| `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift` | CHANGED | `ResponseShape` gains per-shape system slot + `temperature`; `runInference` awaits `core.setParameters(temp:)` before `generateWithConstraints`; test-visible decode-parameter record; `chatSystemPrompt` (command system slot) untouched; chat persona system text NEW | FR-CNR-002, FR-CNR-003, FR-CNR-004, FR-CNR-013; NFR-CNR-001, NFR-CNR-004 |
| `ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift` | CHANGED (only if a chat-template edit is needed) | `buildChat` gains no exemplars; text changes only together with the seed mirror; `build` byte-identical | FR-CNR-002, FR-CNR-023; NFR-CNR-004 |
| `ios/ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift` | NEW (pure, total) | Deterministic verdict over the final spoken text: honorific agreement, Devanagari purity, dangling particles/particle budget; never returns text | FR-CNR-005, FR-CNR-006; NFR-CNR-001 |
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` | CHANGED | `.chat` dispatch branch: guard call site (post-polish text), flag outcome wiring (escalate/safe template), `reply_grammar_flag` emission; `speak` path unchanged for a pass | FR-CNR-005, FR-CNR-006, FR-CNR-007 |
| `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatConsentGate.swift` | NEW | OD-12-shape consent: fail-closed `Decision`, `ConsentRecord` (granted/recordedAt/disclosureVersion), one writer, revoke in-memory-first; encrypted at rest | FR-CNR-009; NFR-CNR-006, NFR-CNR-011 |
| `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatRouting.swift` | NEW (pure) | Single routing decision for chat turns: `.cloud`, `.local` (with reason) — the only place egress is decided | FR-CNR-008, FR-CNR-009, FR-CNR-010 |
| `ios/ElderlyAssistant/Services/Intents/IntentRouter.swift` | CHANGED | Chat lane inserted after cache/preparse, before the `cloudFirstEnabled` selector branch; cloud-chat readiness closures (consent/online) wired like `geminiKeyConfigured`; local-chat fallback for chat-classified turns with cloud escalation disabled for the turn | FR-CNR-008, FR-CNR-009, FR-CNR-014 |
| `ios/ElderlyAssistant/Services/Voice/GeminiCommandInterpreter.swift` | CHANGED | New `ChatResponding` conformance (`respondToChat`): sanitise → `IntentPrompt.buildChat` → upgraded chat `replyPersona` → `generateJSON` with the chat `GenerationConfig` (temp OD-5, search grounding off for chat — §9); `interpret()` unchanged | FR-CNR-002, FR-CNR-008, FR-CNR-010, FR-CNR-011, FR-CNR-012 |
| `ios/ElderlyAssistant/Services/Gemini/GeminiClient.swift` | CHANGED (small) | `GenerationConfig` gains optional `temperature`; only the chat call site sets it; timeout/cost-governor/header-key discipline unchanged | FR-CNR-011, FR-CNR-012; NFR-CNR-002 |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | CHANGED | Consent gate lifecycle + wiring (`cloudChatConsent`, `cloudChatOnline` closures), indicator published state, Settings row model, revocation action, catalog-per-language default resolution for the P1 swap | FR-CNR-008, FR-CNR-009, FR-CNR-022; NFR-CNR-009 |
| `Resources/Localizable.xcstrings`, `App/L10n.swift`, `L10nCatalogCoverageTests` | CHANGED | All new strings en+ne (consent, disclosure, indicator + spoken form, revocation, safe templates, Settings row) | NFR-CNR-009, NFR-CNR-010 |
| `ios/tools/check-release-log-safety.sh(.py)` + fixtures | CHANGED (coverage) | New chat/routing/guard/consent source paths in the stricter feature role; fixtures unchanged | FR-CNR-012; NFR-CNR-006 |
| `tools/train-intent/src/style_spec.py` | NEW | Loads/validates the spec; renders rule text into layer-builder prompts; executes machine blocks for filters | FR-CNR-001, FR-CNR-017 |
| `tools/train-intent/src/build_chat_corpus.py` | NEW | Layer 1–4 builders, filters (honorific/AI-ism/length/dedupe), teacher-GEC stage, 70/30 mixture assembly, manifest emission | FR-CNR-016, FR-CNR-017, FR-CNR-018 |
| `tools/train-intent/eval/chat_golden.jsonl` | NEW | ~500 held-out, teacher-authored, human-reviewed turns with expected qualities; held out strictly | FR-CNR-019 |
| `tools/train-intent/src/eval_chat_gates.py` | NEW | The three chat gates over `chat_golden.jsonl`; judge config recorded; exit non-zero on any red gate | FR-CNR-020; NFR-CNR-008 |
| `tools/train-intent/src/eval_golden.py` + `config.yaml` | CHANGED (additive) | Chat variant keys under `chat:`; the regression harness re-runs as-is; existing keys/defaults untouched | FR-CNR-016, FR-CNR-021 |
| `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` | CHANGED | NEW versioned v17 entry (real sha256, tier fields) beside `intentQwenS43`; previous entry stays addressable for rollback | FR-CNR-022, FR-CNR-028; NFR-CNR-003 |

## Traceability

| Requirement | Design sections |
|---|---|
| FR-CNR-001 style spec, single source, four consumers | 6 (all), 22, 21 |
| FR-CNR-002 persona upgrade both seams, same contract | 10, 6.2, 9 |
| FR-CNR-003 chat sampling fixed seed temp 0.3, chat only, GBNF, feasibility | 5 (all), 20 |
| FR-CNR-004 command determinism preserved | 5.1, 5.2, 10, 2, 18 (DV-5) |
| FR-CNR-005 grammar guard verify-never-rewrite | 7.1, 7.2, 7.4 |
| FR-CNR-006 flag outcome, honest degradation | 7.3, 7.4, 15 |
| FR-CNR-007 reply_grammar_flag no content | 7.5, 16 |
| FR-CNR-008 cloud-first chat toggle, local floor, degradation | 8.1, 8.2, 8.8, 15 |
| FR-CNR-009 consent/disclosure/indicator/revocation, OD-12 shape | 8.3, 8.4, 8.5, 8.6, 17 |
| FR-CNR-010 egress scope | 8.7, 7.3, 16 |
| FR-CNR-011 explicit Gemini chat temperature | 9 |
| FR-CNR-012 credential + content hygiene | 9, 16, 22 (gate row) |
| FR-CNR-013 single-decode unchanged, abstain | 2, 5.3, 8.2 |
| FR-CNR-014 ladder/emergency unchanged | 8.2, 2, 18 (DV-4) |
| FR-CNR-015 STT/permissions/collection unchanged | 8.2 (note), 12, 17, 2 |
| FR-CNR-016 v17 chat-aware QLoRA variant | 11.1, 11.2, 11.3 |
| FR-CNR-017 four-layer corpus | 11.1, 11.2 |
| FR-CNR-018 ship-mix provenance manifest | 11.5 |
| FR-CNR-019 chat_golden held-out set | 11.4 (held-out rule), 21, 22 (artifact row) |
| FR-CNR-020 new chat gates + thresholds | 11.4, 21 |
| FR-CNR-021 full harness before swap | 11.4, 11.6, 20 |
| FR-CNR-022 catalog entry, versioned/reversible/gated/tiers | 11.6, 15, 18 |
| FR-CNR-023 chat template discipline / intent prompt frozen | 10, 6.3 |
| FR-CNR-024 feasibility honesty | 20, 19.2 |
| FR-CNR-025 DV-1..DV-6 + release gate | 18, 16 |
| FR-CNR-026 P2 DPO | 11.7 |
| FR-CNR-027 P2 romanized chat | 11.7, 20 |
| FR-CNR-028 P2 4B tier via resolver | 11.6, 11.7, 20 |
| FR-CNR-029 P2 consent-based transcripts | 11.7 |
| NFR-CNR-001 chat reproducibility | 5.4, 5.2, 8.9 |
| NFR-CNR-002 latency envelope | 13, 8.8, 11.6, 18 |
| NFR-CNR-003 memory/jetsam, one resident | 5.2 (rejected handle), 11.6, 14 |
| NFR-CNR-004 1,024-token budget | 10, 21 |
| NFR-CNR-005 byte-mirror discipline | 6.3, 10 |
| NFR-CNR-006 log safety | 16, 7.5, 21 |
| NFR-CNR-007 telemetry hygiene | 7.5, 8.1, 16 |
| NFR-CNR-008 gate thresholds | 11.4, 21 |
| NFR-CNR-009 accessibility, voice-first, indicator, no internals | 17, 8.5, 8.6 |
| NFR-CNR-010 localisation ne/en | 17, 7.3 (safe templates) |
| NFR-CNR-011 compliance/release gates | 21, 16, 19.1 |

Every locked requirement is bound by the design above. No requirement is left unbound.

## Deferred work (plan-tasks / implementation)

`design-l2` is folded into this document (owner directive 2026-10-14): this is the combined
L1+L2 design of record, and the `review-l2` gate is dropped. The former design-l2 items are
resolved here where the contracts already determine them, and honestly deferred otherwise —
never silently dropped. Nothing below weakens a binding above.

| Item | Disposition |
|---|---|
| File placement for `CloudChatRouting` / `CloudChatConsentGate` / `NepaliGrammarGuard` | FOLDED — paths fixed in §22 (Components); unit decomposition belongs to plan-tasks |
| Guard internals — tokenization and lexicon representation | FOLDED — tokenization and longest-match rules fixed in §7.2; lexicons are compiled Swift constants that byte-mirror the spec's `guard_checks` blocks (drift-checked, §6.3); no runtime resource loading, so no load-failure mode |
| Consent store seam | FOLDED — reuse the encrypted, Keychain-backed store mechanism the LiveTranslate consent record uses (reuse, not a fork; §8.3, §12) |
| `ResponseShape` / `runInference` refactor detail (parameter passing, extended override-seam signature, `lastDecodeParameters` accessor shape) | FOLDED — the shape→temperature property, the awaited `core.setParameters` placement, and the test-visible decode-parameter record are fixed in §5.2; parameter/member names are implementation |
| Judge prompt/model version pinning; `eval_chat_gates.py` output schema | FOLDED — the judge runs at temperature 0 and model id + prompt sha256 + rubric are recorded with the results; the results file carries `{gate, threshold, observed, pass}` per gate plus the judge config, and the harness exits non-zero on any red gate (§11.4) |
| Catalog entry id / default-resolution data shape | DEFERRED to implementation — the entry is new and versioned beside `intentQwenS43` (§11.6); the literal id is set when the artifact exists (real sha256), recorded in the entry and the run manifest |
| Spec field-level schemas (e.g. `honorific_pairs` internals) | DEFERRED to implementation, binding intact — section names and required content are fixed in §6.1; field names may be finalized at implementation because the drift checks bind the BYTES of the named blocks (§6.3), and any change is a spec-version bump recorded in the run manifest |
| Final en/ne copy — consent, disclosure, indicator + spoken forms, revocation/state, safe templates, Settings row, `chat.cloudFallback.notice` | DEFERRED to implementation — the key set and semantics are fixed in §17/§8; literal strings are authored at implementation and verified by `L10nCatalogCoverageTests` (both languages) and DV-2/DV-3, with copy review before the first App Store submission (§8.4) |
| Voice revocation/state keyword phrases | DEFERRED to implementation — the deterministic keyword-rule family is fixed in §8.6; phrases are authored with the router safety-net test pins |
| Wave decomposition and unit boundaries | DEFERRED to plan-tasks (the plan owns unit decomposition) |

## Assumptions

- A1: The `ChatIntentClassifier` table and its conservative semantics stay as shipped; the
  chat lane routes exactly its `.chat` set.
- A2: `LLMCore.setParameters` + `generateWithConstraints` actor-ordering holds as read at base
  22de9864 (verified in the vendored source); any future runtime change re-verifies §5.2 by
  test before the feature's invariants are claimed.
- A3: The Gemini speech stack's transcription egress remains under the existing stack consent
  (recorded OD-12); the feature records the boundary (§20) rather than altering it.
- A4: Training-box execution (anjan-ubuntu/4090) per the suite's README; corpus/GGUF are build
  artifacts, not app changes.
- A5: The reference device (Anzaan) runs an iOS 26-class build; DV results are recorded there.
- A6: The workflow's canonical file `specs/conversational-nepali-replies/workflow.yaml` is the
  authority for gate mechanics; its `.ai-sdd/workflows/` mirror is kept byte-identical.
