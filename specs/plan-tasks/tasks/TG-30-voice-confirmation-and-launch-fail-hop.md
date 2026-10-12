# TG-30 — Voice Confirmation and Launch-Fail Hop

> **Jira Epic:** Voice Confirmation and Launch-Fail Hop

## Description
The voice path of the feature: the settings primary becomes the resolver default (landed in T-147), the chain resolves before the spoken confirmation, the prompt discloses the routed channel, and a launch failure hops to the next candidate with exactly one spoken recovery line. Also closes the M-1 disposition (i) in code. Carries security evidence obligations SA-5, SA-6 (new event shape) and SA-2 (hop termination) with the M-1 must-fix precondition: T-144 strictly precedes T-150.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| T-148 | Voice confirmation: chain-before-prompt and the disclosure clause | M | T-146 | HIGH |
| T-149 | Launch-fail hop machinery and opener threading | L | T-148 | HIGH |
| T-150 | Failure-honesty guards: phone floor and whatsappChat disposition | M | T-149 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~3.5 days
- Realistic (2 devs): ~4 days

## Group-wide gates and conventions
- All three units own the coordinator file and are serialized by file overlap; the resolution suite is shared between T-149 and T-150 and is serialized by the same mechanism.
- Scoped-suite gate and the pre-existing baseline note hold here as in TG-29. Fresh worktrees need the whisper model and kws symlinks before linking.
- Announcement text composes from one source: fellBackFrom plus the routed channel. An empty provenance keeps the shipped prompt byte-identical; this is pinned by test, not by convention.

## T-148: Voice confirmation: chain-before-prompt and the disclosure clause

## Metadata
- **Group:** TG-30 — Voice Confirmation and Launch-Fail Hop
- **Component:** C3 — voice confirmation flow (design-l2.md section 8)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** T-146
- **Blocks:** T-149
- **Requirements:** [FR-CDP-013](../../define-requirements/FR/FR-CDP-013-fallback-before-spoken-confirmation.md), [FR-CDP-014](../../define-requirements/FR/FR-CDP-014-override-protocol-preserved.md), [FR-CDP-016](../../define-requirements/FR/FR-CDP-016-automatic-routing-with-announcement.md), [NFR-CDP-009](../../define-requirements/NFR/NFR-CDP-009-no-regression-shipped-call-paths.md)

## Description
Resolve the chain before the spoken confirmation and surface the outcome in the prompt. Removes the messenger-no-handle early return from requestCallConfirmation, adds the additive pending-action fields and the hop-preserving replacing() helper, and appends the disclosure clause that names the skipped channel. The override protocol and the shipped prompt text (when nothing was skipped) stay untouched; SA-5 prompt guarantees and SA-4(b) preservation pins land here.

## Acceptance criteria

```gherkin
Feature: Fallback resolves before the spoken confirmation

  Scenario: The prompt discloses the skipped channel and names the routed one
    Given a call action whose chain skipped an infeasible preferred channel
    When the confirmation prompt is composed
    Then it contains the fallback disclosure clause naming the skipped channel label
    And the question sentence still names the routed channel

  Scenario: No fallback keeps the shipped prompt byte-identical
    Given an action with empty fellBackFrom
    When the confirmation prompt is composed
    Then the composed parts equal the shipped prompt parts exactly (pinned test)

  Scenario: A messenger preference without a handle no longer early-returns
    Given a voice call to a contact whose messenger handle is absent
    When the confirmation flow runs
    Then the flow proceeds through the chain to the floor instead of returning early
    And the pending-action slot holds the resolved action

  Scenario: The override protocol still wins pre-confirmation
    Given a live confirmation with a pending action
    When the user says the override phrase
    Then the amended action is constructed exactly as shipped, dropping provenance
    And the override gate source is diff-clean against the baseline
```

## Implementation notes
- Owned files: `ios/ElderlyAssistant/App/` `AppCoordinator.swift`, `ios/ElderlyAssistantTests/App/` `CallConfirmationWordingTests.swift` (new suite; the confirmation-wording home allowed by design-l2.md section 28).
- The secondary property consumed by the chain here landed in T-146 (the seams unit); this unit only reads it.
- Flow edits in AppCoordinator.swift: PendingCallAction gains `requestedAt` (default now), `fellBackFrom` (default empty) and `hopCandidates` (default empty); replacing(method:hopCandidates:) forwards source transcript, source command and requestedAt only — fellBackFrom deliberately resets to the empty list (the V-3 corrected comment from T-144 must be matched); requestCallConfirmation resolves the chain before the pending action is created and the messenger-without-handle early return (`AppCoordinator.swift:7620-7623`) is removed; the prompt part order is near-miss, repeat, unsupported, disclosure, method, question; confirmationPrompt (region `AppCoordinator.swift:7688-7709`) gains the disclosure block bound to the skipped-channel label plus the routed channel — the single source the announcement also reads.
- Preserved, verify-only: the override block (`AppCoordinator.swift:7656-7686`), its gate (`AppCoordinator.swift:7665-7669`, diff-clean) and the amended-action construction (`AppCoordinator.swift:7670-7674`, provenance dropped). Do not reorder or weaken; add the pinned regression test rather than new behaviour.
- New suite `CallConfirmationWordingTests.swift` (in the App tests folder): testDisclosureNamesSkippedAndRouted, testNoFallbackKeepsPromptByteIdentical (composed parts pinned against the shipped baseline), testOverrideGateUntouchedPin (source-pin over the override region using the house source-scan helper). The suite is MainActor-scoped like its neighbours.
- The four shipped labelled constructions of PendingCallAction stay compile-compatible via the added defaulted fields (their additive-fields pin lives in T-149).
- Announcement honesty: speech only, never logged; no new console writes in this unit.

## Definition of done
- [ ] Chain resolves before the pending action; the early return is removed only at the named site
- [ ] Prompt disclosure names the skipped and routed channels; empty provenance is byte-identical (pinned)
- [ ] Override block, gate and amended-action construction diff-clean; pinned test green
- [ ] Scoped run green: `ios/build.sh test:unit CallConfirmationWordingTests CallChannelResolutionTests`
- [ ] No PII in logs; no new console writes
- [ ] Code reviewed and merged

## T-149: Launch-fail hop machinery and opener threading

## Metadata
- **Group:** TG-30 — Voice Confirmation and Launch-Fail Hop
- **Component:** C5 — hop machinery (design-l2.md section 10)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** T-148
- **Blocks:** T-150, T-152, T-153
- **Requirements:** [FR-CDP-015](../../define-requirements/FR/FR-CDP-015-launch-fail-fallback-announced.md), [FR-CDP-016](../../define-requirements/FR/FR-CDP-016-automatic-routing-with-announcement.md), [NFR-CDP-004](../../define-requirements/NFR/NFR-CDP-004-fallback-resolution-latency.md)

## Description
Add the launch-fail hop: the LaunchHop value, the hop step that walks the remaining candidates, the single spoken recovery line site, the structured hop event, and the `hop` parameter threaded through the shipped openers and their call sites at the action level. Depth is structurally bounded at two and candidates shrink strictly; SA-2 termination and SA-6 event shape land here.

## Acceptance criteria

```gherkin
Feature: Launch-fail hop with one spoken line

  Scenario: A failed launch hops to the next candidate once
    Given a routed action whose opener reports a launch failure and a non-empty candidate list
    When the hop step runs
    Then the next candidate is attempted and the fallback-routed line is spoken exactly once
    And the hop event carries the outcome as failed-channel then next-channel with empty metadata

  Scenario: Candidates never loop (failure)
    Given a failing opener and a candidate chain of two steps
    When the hop runs to exhaustion
    Then at most two hop steps occur, no candidate repeats, and the flow ends on the shipped line
    And no hop step re-enters the confirmation flow

  Scenario: A messenger candidate without a handle is skipped inside the hop
    Given hop candidates containing messenger with no handle on file
    When the hop filters its candidates
    Then messenger is dropped from the walk and the next feasible candidate proceeds

  Scenario: The additive fields keep the shipped call sites compiling
    Given the four shipped labelled constructions of the pending action
    When the target compiles
    Then all four construct without naming the new fields (pinned)
```

## Implementation notes
- Owned files: `ios/ElderlyAssistant/App/` `AppCoordinator.swift`, `ios/ElderlyAssistantTests/Services/` `Voice/CallChannelResolutionTests.swift`.
- Machinery in AppCoordinator.swift (design-l2.md section 10): the LaunchHop value; launchFailHopStep as the only site that speaks the fallback-routed line; performLaunchFailHop; noteLaunchFailHop emitting component `call_launch_fallback`, event type `hop`, outcome as failed-channel then next-channel, metadata empty (SA-6: closed tokens only, nothing beyond channel raw values); hopFromCallAction builds the LaunchHop from the action's hopCandidates. Openers gain the additive `hop` parameter with a default of nil: performFaceTimeCall, the system phone opener, performSystemContactWhatsApp, performSystemContactMessenger; the action-level call sites pass the hop. No await, timer or queue is introduced anywhere (latency budget NFR-CDP-004 stays user-paced).
- Termination proof to document in the unit report: candidates strictly shrink per step (suffix consumption plus feasibility filter), the substituted-channel case yields no candidates, and the terminal channel never re-hops — depth at most two, never re-pending.
- Extend the resolution suite: testHopConsumesCandidatesNeverLoops, testLaunchFailedFallbackSpokenOnce, testMessengerWithoutHandleSkippedInHop, testAdditiveFieldsKeepOldCallSites (the four shipped constructions at the two coordinator sites and the two log-store test sites, pinned).
- The shipped failure vocabulary is reused as-is (no new error type); the recoveries of the call-chat opener stay non-hopping.

## Definition of done
- [ ] Hop walks strictly shrinking candidates, depth at most two, single spoken line site
- [ ] Hop event shape pinned: closed tokens, empty metadata, no numbers or handles anywhere
- [ ] Openers take the additive hop parameter; the four shipped constructions pin green
- [ ] Scoped run green: `ios/build.sh test:unit CallChannelResolutionTests`
- [ ] No new console writes beyond the single hop event; privacy guard green
- [ ] Code reviewed and merged

## T-150: Failure-honesty guards: phone floor and whatsappChat disposition

## Metadata
- **Group:** TG-30 — Voice Confirmation and Launch-Fail Hop
- **Component:** C3 launch outcome + C5 failure classification (design-l2.md sections 8 and 10)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** T-149
- **Blocks:** T-157
- **Requirements:** [FR-CDP-018](../../define-requirements/FR/FR-CDP-018-preserved-behaviours.md), [NFR-CDP-003](../../define-requirements/NFR/NFR-CDP-003-log-safety.md)

## Description
Implement the M-1 disposition (i) recorded in T-144 and the phone-floor guard: when the routed phone opener reports a false result, speak the shipped no-usable-number line and stop (no hop, nothing recorded); when the voice whatsappChat opener returns false, speak the same shipped line and record no success, no learning and no activity. This closes the shipped silent-false site (review-l2 F-1, R-5). M-1 precondition: T-144 lands before this unit — do not start otherwise.

## Acceptance criteria

```gherkin
Feature: Failure honesty at the terminals

  Scenario: The phone floor reports a false result honestly
    Given a routed phone action whose opener returns false
    When the guard runs
    Then the shipped no-usable-number line is spoken once
    And no hop is attempted and no success, learning or activity is recorded

  Scenario: The whatsappChat false result follows the recorded disposition
    Given a routed whatsappChat action whose opener returns false (no dialable digits)
    When the branch runs
    Then the shipped no-usable-number line is spoken once
    And no success, no learning and no activity is recorded, and no hop follows (precondition T-144 applied)

  Scenario: Any other outcome of the call-chat opener keeps its shipped recovery
    Given a routable whatsappChat action whose opener takes a native-compose or copied-number recovery
    When the branch completes
    Then the shipped recovery behaviour is unchanged and the false-case guard does not fire
```

## Implementation notes
- Owned file: `ios/ElderlyAssistant/App/` `AppCoordinator.swift`; announcement honesty pin extends the resolution suite at `ios/ElderlyAssistantTests/Services/` `Voice/CallChannelResolutionTests.swift` (source-pin pair testWhatsAppChatFalseSpeaksTheLine, testPhoneFalseSpeaksTheLineNoHop).
- Guard placement: performCallAction's phone case gains the false-result guard (speak the shipped line, no hop, nothing recorded); the whatsappChat branch (`AppCoordinator.swift:7755-7765` region) stops discarding the opener Boolean — the false result follows disposition (i) exactly as recorded in T-144. The call-chat opener's own recovery chain stays untouched (its non-false outcomes are non-hopping recoveries).
- The shipped no-usable-number line key is reused; no new key is introduced by this unit (the five-key bound stays T-155's). Records-nothing means: no success log, no learning write, no activity write — verified by the pinned assertions plus the privacy guard run.
- Ordering note: this unit must not start until T-144's disposition line is present in the record; the dependency chain enforces this, and the unit report cites the T-144 anchor.
- Do not touch the override gate or any emergency path.

## Definition of done
- [ ] Phone false-case guard speaks the shipped line once and records nothing
- [ ] The whatsappChat branch honours disposition (i); the silent-false site is closed
- [ ] Recovery outcomes of the call-chat opener unchanged (pinned)
- [ ] Scoped run green: `ios/build.sh test:unit CallChannelResolutionTests`
- [ ] Unit report cites the T-144 disposition anchor (M-1 precondition evidence)
- [ ] Code reviewed and merged
