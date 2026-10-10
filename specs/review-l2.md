# Review — L2 Component Design (Multi-Turn Conversation)

**Task.** `review-l2` — the design-chain gate for the `multi-turn-conversation`
workflow. Workflow exit condition: `review.decision == GO`.

**Artifacts under review**

| Artifact | Contract | Size | Status |
|---|---|---|---|
| `specs/design-l1.md` | `architecture_l1` | 680 lines | gate-cleared at `design-l1` |
| `specs/design-l2.md` | `component_design_l2` | 1005 lines | this review |

`design-l2.md` sha256 verified at review time (chunked here for readability):
`9c164658 5b137833 0129c007 8cc4ae0f 3a32ab3e 818e3a86 ac87fe8c 069c6f51`.

**Feature / worktree.** `multi-turn-conversation` @
`/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`,
branch `feat/multi-turn-conversation`.

**Inputs consulted.** Feature supplement
`specs/multi-turn-conversation/constitution.md`; root `constitution.md`
(Archive / Standards / Agent Principles bind this review); the requirement
set `specs/define-requirements.md` plus `FR/` (FR-MTC-001..020) and `NFR/`
(NFR-MTC-001..012); the workflow `.ai-sdd/workflows/multi-turn-conversation.yaml`.

**Verification method.** Read-only review; no artifact, workflow file or git
state was modified. Every load-bearing code claim below was re-checked
against the shipped source in this worktree rather than trusted from the
documents: the interception insertion point, the music ladder arms, the
interpreted-music dispatch, `routeKeywordRemainder`, the session state
machine, the coordinator confirmation/timer wiring, `LocalBrainChain.turnInput`,
`KeywordIntentRule.musicQuery`, `IntentPrompt.build`, the release-log gate
and the test layout. Central measurements were reproduced independently
(see Reproduced below).

## Summary

**Decision: GO** — 0 BLOCKER, 1 MAJOR, 3 MINOR, 3 NOTE.

- Checklist: **7 / 7 items pass** (item 3 passes with the F-1 caveat).
- No finding blocks GO; all findings are mechanically resolvable with
  in-repo patterns and are compile- or test-tripwired at first build.
- The design is internally consistent with L1, resolves the L1 §31 items
  R1-R5/R10-R12 against verified real call sites, traces all 32
  requirements, and keeps scope discipline.

### Reproduced measurements (independent)

- Rendered `IntentPrompt.build` baseline = **exactly 2,506 Swift Characters**
  (recompiled the literal verbatim via swiftc with the same interpolation
  substitutions); matches `IntentPromptTests.swift:495` and
  `PinnedSurfaceGuardTests.swift:66`. Worst case with the address clause =
  2,586 (+80) and the ceiling 3,000 match pins at `:498-507` and `:67-69`.
- `VoiceSessionStateMachine.Config.confirmationTimeoutSeconds` = **45**
  (`UInt64` instance `var`, `App/VoiceSessionStateMachine.swift:95`); only
  usages are `:185` and the test injections.
- All pre-existing test files the L2 §18 table references exist, including
  `CommandRouterMusicTests.swift` with its four doubles (`:75-87`) and
  `PinnedSurfaceGuardTests.swift` with the digests it names.
- No new-symbol name collides: `DialogueManager`, `DialogueFrame`,
  `DialogueAnswerPath`, `DialogueOptionCatalog`, `DialogueProbeComposer`,
  `MusicQueryExtraction`, `nearMatches`, `awaitingSlotAnswer` are all absent
  from the worktree today.
- `Localizable.xcstrings` has 1,364 keys and **zero** `dialogue.*` keys
  pre-existing; `router.reprompt`, `router.rephrase.discard`,
  `router.confirmationTimeout` and `router.sensitiveBlocked` all exist.

## Checklist

### 1. Explicit error return types — PASS

§8 defines `DialogueError` as a closed case vocabulary; the mutating entry
points are `throws` (`DialogueManager.arm`), `DialogueOptionCatalog.load(bundle:)`
throws, and no interface returns an erased error type. `InterpretedCommand
.merging(message:)` (§9) is total: a memberwise-init copy of the 14 stored
fields, verified 1:1 against the shipped `InterpretedCommand` at
`LlamaCommandInterpreter.swift:122-229` — including the defaulted
initialiser at `:209-213`.

### 2. Async / external failure modes and recovery — PASS

- Session timer: the F6 guard (`guard self.state == .awaitingConfirmation
  else { return }`, `:198`) is the verified model for the mirrored
  `armSlotAnswerTimer`; an arm that fails resolves via the §15 edit-4
  failure line and the frame stays resolvable.
- Catalog load failure: §11's failure row opens the `dialogue.probe.musicAny`
  free-text path — no frame is lost.
- Degraded brain: Phase 1's core guarantee is the deterministic merge; the
  shipped `turnInput` (`LocalBrainChain.swift:275-285`) shows the nil-seam
  passthrough the design preserves, and the production seam is non-nil
  (wired at `AppCoordinator.swift:1824`).
- Main-queue confinement mirrors the existing `openConfirmationWindow()`
  hop (`AppCoordinator.swift:7019-7027`); the 60 s watchdog region
  (`:4823-4883`) is untouched.

### 3. Timeouts and retry limits as configurable parameters — PASS (with F-1 caveat)

All four knobs are parameters, not literals: `answerWindowSeconds` injected
into `DialogueManager.init`, the attempts cap and `maxCandidates` as frame
config (§27), the catalog location as a bundle resource. §14 edit 4 keeps
the 45 s value owned by the state machine's `Config`. The caveat is F-1
only — the default-argument *expression* §8/§15/§27 pin cannot compile as
written; the parameter-by-injection design itself meets the standard.

### 4. Traceability — PASS

The table maps every requirement: 20 FR-MTC rows and 12 NFR-MTC rows
(verified all present, including FR-MTC-007 and the NFR-MTC-006 row at
`:970`). FR-MTC-012 lands on the §6 B1-B7 predicate table; NFR-MTC-012's
parity claim is structural via L2-D13 (both paths converge on
`fireMusicRequest`, verified `:2667`).

### 5. User/operator-visible behaviour — PASS

§16 inventories every spoken line (17 keys; count prose issue = F-4), all
ne+en mandatory; §25 gives the events with a closed outcome vocabulary; the
45 s expiry drops the frame silently and re-arms (§14), preserving the
shipped timer semantics; the honest dead-end lines in
`routeKeywordRemainder` (`:1968-2030`) are upgraded in place with their
anchors preserved (`router.reprompt` at `:2021`, `router.sensitiveBlocked`
block `:1973-1980`).

### 6. Design-chain consistency (L1 ↔ L2) — PASS

- R1: the B1-B7 predicate call sites are all real — B1
  `isExplicitMedicationAcknowledgement` `:1913`, B2 `sensitiveCallPhrases`
  `:1869`, B3/B4 `VoiceContactSearchRoute` (`Decision` is the two-case enum
  at `:52-58`, so L2's "returns `.openPhone`" is exactly L1's "!= .notSearch"
  — reconciled, not contradictory), B5 `YouTubeRoute.decide` `:56`, B6
  `KeywordIntentRule.match` `:164`.
- R3 (the carried question): **confirmed**. FR-MTC-007's "execute with
  defaults" presupposes a pending command to execute; FR-MTC-004 ("never
  fabricate candidates") and FR-MTC-010 forbid executing an unasked
  candidate. The honest `dialogue.exhausted` close is the admissible
  reading; risk 11 can be closed by this review.
- R2 resolved with the bounded reading (L2-D9): only a candidate's own
  domain extractor can claim free text; no claim stays invalid. R4's
  ordered algorithm (§22 S1-S6 with vectors) and R5's escape drop are
  internally consistent with the constitution's capture contract.
- R10-R12 consumed (L2-D13/D14/D15); L2-D12's drop of L1 §28's optional
  catalog protocol member is a documented refinement with rationale — no
  ADR contradiction; the cache-bypass constraint and emergency precedence
  are preserved structurally (emergency block `:779-783` remains ahead of
  the interception block at `:886-897`).

### 7. Scope discipline — PASS

"Not in this design" excludes chat, transcript history in prompts,
model-generated probe text, cloud, persistence and Phase 3 — matching the
constitution's out-of-scope list exactly; no out-of-scope element was
found. OD-M1..M4 remain owner-facing with defaults recorded in §27 (2
probes; curated catalog; Phase 1 first; Phase 3 separate) — owner-ratified
as open-with-defaults; noted, not a finding.

## Findings

**F-1 (MAJOR) — the pinned default-argument expression cannot compile as
written.** §4 (`:54`), §8 (`:207`), §15 edit 1 (`:687`) and §27 (`:917`)
all pin `TimeInterval(VoiceSessionStateMachine.Config.confirmationTimeoutSeconds)`,
while §14 edit 4 (`:672`) rows `Config (:93-96)` as "unchanged". Shipped:
the property is an instance `var` (`:95`), reached only via an instance
(`:185`); no static accessor exists anywhere. A type-level access is a
compile error, and a same-named `static` would collide with the instance
property — so "Config unchanged" and the pinned expression cannot both
hold. Mechanical; the intent (no new literal; 45 s stays single-source) is
unambiguous. Blocks GO: No. Fix: C-1.

**F-2 (MINOR) — the news-arm parity anchor points at comment text.** The
header anchor list and §12.5 cite the relaxed news arm at `:1194-1198`;
those lines are a comment block. The real sites are the relaxed `.news` arm
`:1210-1217` (emit `:1211`, ack `:1214`, reader `:1215`, emit `:1216`,
return `:1217`) and the strict stage `:1131-1138`. The structural claim
(the new arm mirrors the news hand-off) is still correct against the real
site. Blocks GO: No. Fix: C-2.

**F-3 (MINOR) — §12.2 calls a three-argument `emit` that does not exist.**
§12.2 pins `emit(eventType:outcome:metadata:)` for the
`dialogue_answer`/`invalid` event; the only helper is the two-argument
`emit(eventType:outcome:)` at `:3982` with `metadata: [:]` hardcoded, and
§12.4's edit list adds no overload. Metadata-carrying events elsewhere
construct `ObservabilityEvent` directly and call `observabilityBus.emit`
(pattern at `:1406-1413`). Compile-enforced one-liner; the real risk is the
`reason` metadata being silently dropped. Blocks GO: No. Fix: C-3.

**F-4 (MINOR) — key-count prose is off by one against its own table.**
§16 (`:719`) says "16 new `dialogue.*` keys" and the NFR-MTC-006 row
(`:970`) repeats "(16 keys)", but the table lists 17 concrete keys
(`:723-739`) plus the deliberately-absent `dialogue.timeout` row (`:740`).
Verified zero `dialogue.*` keys pre-exist, so all 17 are new. The key
inventory itself is complete; only the counts are wrong. Blocks GO: No.
Fix: C-4.

### Notes

- **N-1.** Micro anchor drift: `emergencyPhrases` cited `:1854` vs actual
  `:1855`; `containsPhrase` semantics cited `:1824` vs func `:1826`; the
  header's `YouTubeRoute` "Decision `:41-56`" is loose for the real
  `:41-46` enum. No semantic impact.
- **N-2.** `Prepared.sanitised = raw` on a nil seam matches the shipped
  `turnInput` nil-seam path (`:275-285`); production wires the seam non-nil
  (`AppCoordinator.swift:1824`), so the sanitiser discipline holds. Worth a
  comment in the new helper.
- **N-3.** The rephrase-discard site currently drops the command it takes
  (`_ = coordinator?.takePendingRephraseCommand()`, `CommandRouter.swift:806`);
  R2's composition needs that value bound — already implied by edit 5, but
  pin it in the tests.

## Decision

decision: GO

**Rationale.** All seven checklist items pass and no BLOCKER exists. The
single MAJOR and all three MINOR findings are mechanical, are tripwired by
the compiler or the pinned tests at first build, and none alters the
architecture, the safety properties (emergency precedence ahead of the
interception; frame-trap resistance; transcript-cache skip during capture;
deterministic merge under a degraded brain; unchanged log-safety gate) or
the user-visible contract. The design chain is internally consistent, the
L1 §31 items are resolved against verified real call sites, all 32
requirements trace, scope is clean, and the central measurements reproduce
exactly (2,506 / 2,586 / 3,000; 45 s).

**Conditions (apply during implementation; none requires design rework).**

- **C-1 (F-1).** Source the answer-window default without a type-level
  access — an accessor on the session machine or a value passed at
  construction; keep `:95` the owner of 45, never a new literal.
- **C-2 (F-2).** Use `:1210-1217` (relaxed) / `:1131-1138` (strict) as the
  news-parity anchors when implementing §12.5.
- **C-3 (F-3).** Carry the invalid-answer `reason` via the direct
  `ObservabilityEvent` construction pattern (`:1406-1413`) or add the
  overload; never drop the metadata.
- **C-4 (F-4).** Correct the counts to 17 in §16 and the NFR-MTC-006 row;
  keep `dialogue.timeout` absent.
- **C-5 (N-2, N-3).** Bind the taken rephrase command at `:806` for R2
  composition; comment the nil-seam raw-passthrough parity in the new
  helper.

**Carry-forwards to `security-design-review`.** The workflow's six focus
areas — emergency precedence mid-dialogue; free-text answer injection;
frame-trap resistance; log sanitisation; no new egress; degraded-brain
path — map 1:1 onto §28, the hostile-corpus suite (§18), the log-gate
edits (§17) and the deterministic-merge tests. Risk 11 (R3 wording) is
confirmed by this review and can be closed.
