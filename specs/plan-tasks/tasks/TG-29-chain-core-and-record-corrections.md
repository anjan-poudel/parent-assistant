# TG-29 — Chain Core and Design-Record Corrections

> **Jira Epic:** Chain Core and Design-Record Corrections

## Description
Foundation group. First applies the review-l2 findings (F-1..F-7) and the security-design-review conditions (M-1, M-2, V-1..V-6) to the frozen design records, then lands the new pure-static channel chain (component C1), the AppCoordinator resolution seams with the secondary settings storage (component C2), and the MethodResolver global-default injection (component C3, resolver half). Every later group consumes these units; nothing here speaks to the user.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| T-144 | Design-record corrections (M-1a, M-2, V-1..V-5) | S | — | HIGH |
| T-145 | CallChannelChain core and the never-dead-ends matrix | L | T-144 | CRITICAL |
| T-146 | Resolution seams and secondary settings storage | L | T-145 | HIGH |
| T-147 | MethodResolver global-default closure | S | T-144 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): ~5 days
- Realistic (2 devs): ~5 days

## Group-wide gates and conventions
- Scoped-suite gate: the honest per-unit gate is a scoped run such as `ios/build.sh test:unit CallChannelResolutionTests`, which also executes the source privacy guard before the tests. The full suite carries a known pre-existing red baseline (about 21 failures across 11 suites, unrelated to this feature) and is not the per-unit gate.
- Fresh-worktree note: a new worktree needs the whisper medium ne model and the kws assets symlinked from the main checkout before a link can succeed; see the house build notes.
- Dependency values are plain unit ids in both the table above and each section's Metadata. The coordinator file is the feature's serialization resource: every unit that names it as owned is ordered by file overlap (T-146 and T-147 here; T-148 through T-153 in later groups).
- Requirement links climb two levels to the requirements folder, for example [FR-CDP-007](../../define-requirements/FR/FR-CDP-007-chain-preferred-secondary-phone.md).
- Input discipline: the inputs of a unit are exactly the landed units named in its dependency line plus the design records; nothing is read across group boundaries without a declared edge.

## T-144: Design-record corrections (M-1a, M-2, V-1..V-5)

## Metadata
- **Group:** TG-29 — Chain Core and Design-Record Corrections
- **Component:** design records (design-l1.md, design-l2.md)
- **Agent:** dev
- **Effort:** S
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** T-145, T-147, T-150
- **Requirements:** — (process correction binding review-l2 and security-design-review; releases T-150)

## Description
Surgical, line-anchored corrections to the two frozen design records so the implementation units build against a truthful specification. Covers security-design-review must-fix M-1(a) and M-2, verify-and-record items V-1..V-5, and records the V-6 rename decision. No frozen owner decision is reopened; every edit is a factual repair or a recorded disposition.

## Acceptance criteria

```gherkin
Feature: Design-record corrections

  Scenario: The MAJOR finding (openWhatsAppChat) is corrected and dispositioned
    Given the corrected design-l2.md
    When the launch-failure classification row for the performCallAction whatsappChat branch is read
    Then it states the Boolean signature and the false-only-when-no-dialable-digits condition
    And its recovery attribution names the shipped call-chat opener only, not the chat opener
    And the M-1 disposition (i) is recorded: on a false result the branch speaks the shipped call.announce.noPhoneNumber line and records no success, no learning and no activity

  Scenario: Attempt-order wording uses the containment form
    Given the corrected design-l1.md and design-l2.md
    When the attempt-order wording at design-l1.md:147, the design-l2.md section 6 comment and section 19 step 3 are read
    Then each states that .phone is always IN the order and the route never dead-ends
    And the retired phrasing that the order "always ends .phone" no longer appears in those locations

  Scenario: A stale or partial correction is detected
    Given the delivered correction diff
    When the six M and V items are re-checked line by line against the review text
    Then every item's exact anchor shows the corrected sentence
    And any remaining occurrence of the retired .facebook case name or the ambiguous "five shipped" wording fails the check
```

## Implementation notes
- Owned files: `specs/design-l1.md` `specs/design-l2.md`.
- M-1(a), same as review-l2 F-1 (MAJOR): correct design-l2.md:799 so the whatsappChat row states the real opener signature (returns Bool; false only when the chat URL is nil because no dialable digits remain — verified at the call-links source `CallLinks.swift:283-287` and `CallLinks.swift:366-370`) and correct design-l2.md:609 so the native-compose / copied-number recovery chain is attributed to the call-chat opener only (`CallLinks.swift:457-470`). Record the explicit M-1 disposition (i), the recommended one: the voice branch speaks the shipped call.announce.noPhoneNumber line when the Boolean is false and records no success, no learning and no activity — matching the new phone-floor guard implemented in T-150. Silence is not acceptable; the record must name the disposition.
- M-2: correct design-l1.md:147 and the attempt-order comment plus the route documentation in design-l2.md section 6 (and the step-3 wording in section 19) from the "always ends .phone" form to the containment form: .phone is always IN the order, the route never dead-ends. State in the record that the order test asserts containment + isFeasible(routed) + preferred-first and never last-element, and that the attempt order is not reordered. The renamed test (V-6) is executed in T-145 as `testOrderContainsPhonePreferredFirst` (36 characters; the prior name is retired).
- V-1: design-l2.md:903 — replace the non-existent .facebook enum case with .faceTime.
- V-2: design-l2.md:1106 — state "the four shipped labelled constructions" (or "five-argument constructions"), matching the four verified call-action construction sites (`AppCoordinator.swift:7624`, `AppCoordinator.swift:7670`, `IntentLogStoreTests.swift:206`, `IntentLogStoreTests.swift:224`).
- V-3: design-l2.md:497-500 — reword the replacing() comment: the flywheel pair carries over; fellBackFrom deliberately resets to the empty list so a hop never re-speaks the disclosure.
- V-4 (record half): design-l2.md:975 must name the non-visual selected signal commitment (a selected accessibility trait or value on the selected row of both picker sections, plus a heading trait or softened claim for the section titles) and the picker-suite list at design-l2.md:1174 gains the accessibility assertion names. The implementation half is T-154.
- V-5: design-l2.md section 25 reader/writer list — add isAwaitingCallConfirmation as a reader (`AppCoordinator.swift:7553`, consumer `AppCoordinator.swift:10717-10723`), list recordConfirmationTimeout as a reader (`AppCoordinator.swift:10561-10569`), and note that the call block reads and nils the slot (`AppCoordinator.swift:10611-10612`). This matters because removing the confirmation early return changes when the slot can be live.
- Do not touch anything else; keep the two records' change surface as close to byte-identical elsewhere as possible. The corrections are exactly the ones enumerated above.

## Definition of done
- [ ] All nine corrections applied at the exact anchors (M-1 two lines plus disposition, M-2 three locations, V-1..V-5 record halves)
- [ ] Re-read each corrected location; the retired wordings no longer appear there
- [ ] V-6 rename recorded with the exact new name carried into T-145
- [ ] No frozen owner decision reopened; diff shows only the enumerated anchors
- [ ] No test scope applies (documents only); verification is by diff review

## T-145: CallChannelChain core and the never-dead-ends matrix

## Metadata
- **Group:** TG-29 — Chain Core and Design-Record Corrections
- **Component:** C1 — chain resolver (design-l2.md section 6)
- **Agent:** dev
- **Effort:** L
- **Risk:** CRITICAL
- **Depends on:** T-144
- **Blocks:** T-146
- **Requirements:** [FR-CDP-006](../../define-requirements/FR/FR-CDP-006-facetime-and-phone-always-feasible.md), [FR-CDP-007](../../define-requirements/FR/FR-CDP-007-chain-preferred-secondary-phone.md), [FR-CDP-008](../../define-requirements/FR/FR-CDP-008-fellbackfrom-attempt-order.md), [NFR-CDP-001](../../define-requirements/NFR/NFR-CDP-001-chain-never-dead-ends.md), [NFR-CDP-008](../../define-requirements/NFR/NFR-CDP-008-deterministic-testability.md)

## Description
Create the pure-static chain resolver in a new file, with the frozen shapes: Feasibility, Result carrying the routed channel plus fellBackFrom in attempt order, route(preferred:secondary:feasibility:), attemptOrder (deduped, .phone always IN the order), the hop-candidate statics, the installed-app probe helper, the channel-name keys and the CallChannelVocabulary. Add the exhaustive matrix tests to the resolution suite, including the renamed order test from V-6. This unit carries security evidence obligations SA-1, SA-2 (chain half) and the core of SA-3.

## Acceptance criteria

```gherkin
Feature: Chain resolution never dead-ends

  Scenario: Every configuration resolves to an attemptable channel
    Given the chain resolver and the vocabulary
    When all sixty-four ordered (primary, secondary) pairs across the feasibility combinations are routed
    Then every result channel is feasible under the supplied Feasibility
    And .phone is contained in the attempt order for every pair
    And no attempt order contains a duplicate channel

  Scenario: Preferred wins and equal picks dedupe
    Given a preferred channel that is feasible
    When the same channel is also the secondary
    Then the resolver returns the preferred channel with an empty fellBackFrom

  Scenario: A stubbed-absent WhatsApp still routes
    Given a primary of whatsApp with the installed probe stubbed false and a phone secondary
    When the route is resolved
    Then the result channel is the secondary, fellBackFrom carries the skipped whatsApp, and the order is still attemptable

  Scenario: The order test never asserts last-element
    Given the renamed order test
    When attempt order is asserted
    Then it asserts containment of .phone, isFeasible of the routed channel and preferred-first
    And it does not assert that .phone is the last element

  Scenario: Vocabulary substitution cannot dead-end the route
    Given a vocabulary whose routed channel is not permitted for the call type
    When the route is normalised
    Then the result is switched to the vocabulary terminal (or phone for any-channel) and remains feasible
```

## Implementation notes
- New file: `ios/ElderlyAssistant/Services/` `Calls/CallChannelChain.swift`. Reproduce the frozen shapes from design-l2.md section 6 verbatim (route, attemptOrder with the corrected containment comment from T-144, hopCandidates with the suffix-filter-then-append-terminal semantics, nextLaunchFailCandidate, the whatsAppProbeURL constant, whatsAppInstalled(canOpen:), channel-name keys, the resolver vocabulary). No new store, no new egress, no logging in this file; the probe is a closure parameter (NFR-CDP-002).
- Attempt-order rules to test (M-2/SA-1): containment of .phone, preferred-first, dedupe, no duplicates, isFeasible(routed) for all sixty-four cells, vocabulary legality of every returned channel, empty fellBackFrom when the preferred is routed. The renamed test is `testOrderContainsPhonePreferredFirst`; the retired name from the design record is not used (V-6).
- Hop statics tests (SA-2): candidates shrink strictly per step; suffix filtering drops null-handle messenger and stubbed-absent whatsApp; a substituted channel produces empty candidates; depth is structurally at most two; the same channel is never re-routed (at-most-once).
- Extend the resolution suite at `ios/ElderlyAssistantTests/Services/` `Voice/CallChannelResolutionTests.swift` with the pure-static matrix and hop cases (the seam-level cases belong to T-146 in the same file; keep the file's helpers compiling by coordinating with the T-146 signature change — same-file serialization is intentional, T-146 lands after this unit).
- Test-gate note: scoped run is the gate; a fresh worktree needs the whisper model and kws symlinks before the link step. The suite runs against the pre-existing baseline noted in the group preamble.
- Keep file tokens used elsewhere consistent: this unit owns exactly the two files named above.

## Definition of done
- [ ] The chain file compiles with the frozen shapes and no extra API surface
- [ ] Full matrix test green: sixty-four cells, containment, preferred-first, dedupe, feasibility, vocabulary legality
- [ ] Renamed order test present and asserting containment only (never last-element)
- [ ] Hop statics tests green including the substituted-channel empty-candidates case
- [ ] Scoped run green: `ios/build.sh test:unit CallChannelResolutionTests`
- [ ] Code reviewed and merged

## T-146: Resolution seams and secondary settings storage

## Metadata
- **Group:** TG-29 — Chain Core and Design-Record Corrections
- **Component:** C2 — coordinator seams (design-l2.md section 7) plus the settings storage half of C6 (section 11)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** T-145
- **Blocks:** T-148, T-151, T-154
- **Requirements:** [FR-CDP-003](../../define-requirements/FR/FR-CDP-003-secondary-call-app-persistence.md), [FR-CDP-004](../../define-requirements/FR/FR-CDP-004-messenger-feasibility-handle-on-file.md), [FR-CDP-005](../../define-requirements/FR/FR-CDP-005-whatsapp-feasibility-installed-probe.md), [FR-CDP-009](../../define-requirements/FR/FR-CDP-009-explicit-pick-wins-as-preferred.md), [NFR-CDP-002](../../define-requirements/NFR/NFR-CDP-002-local-probes-no-new-egress.md), [NFR-CDP-005](../../define-requirements/NFR/NFR-CDP-005-persistence-round-trip.md)

## Description
Wire the chain into the coordinator: the installed-app probe backed by the shipped local scheme check, the messenger handle predicate, the six-argument resolvedCallChannel and five-argument resolvedMissedCallChannel seam statics returning the chain Result, and the shared resolveChannel helper with vocabulary normalisation and terminal substitution. Also lands the secondary settings storage — the published property with its key and restore shape — so every seam consumer (this unit, the confirmation flow, the rows, the tiles, the dial-back) has its backing store. Extend the same resolution suite with the seam-level cells. SA-2 and SA-9 (dedupe) evidence lands here at seam level.

## Acceptance criteria

```gherkin
Feature: Coordinator resolution seams and settings storage

  Scenario: An explicit per-contact pick wins as the preferred
    Given an explicit pick of messenger with a handle and a conflicting global default
    When the resolution seam is called
    Then the routed channel is messenger and the provenance is empty

  Scenario: The probe is stubbed false and routing falls to the secondary
    Given an installed-app probe stubbed false and a whatsApp-friendly preference
    When the seam resolves the channel
    Then the result names the secondary (or the terminal) and the provenance carries the skipped channel

  Scenario: A messenger preference without a handle drops to the floor
    Given a preferred messenger channel but no handle on file
    When the seam resolves the channel
    Then the routed channel is the phone floor or the permitted secondary
    And no channel outside the attempt order is ever returned

  Scenario: An out-of-vocabulary routed channel is substituted
    Given a vocabulary that excludes the routed channel for the call type
    When the seam normalises the result
    Then the substituted channel is the vocabulary terminal (phone for any-channel) and remains feasible

  Scenario: The secondary setting starts at the phone floor
    Given a store without the secondary key or with an unknown stored value
    When the coordinator initialises
    Then the secondary property reads phone and the stored value remains writable by the settings screen
```

## Implementation notes
- Owned file: `ios/ElderlyAssistant/App/` `AppCoordinator.swift` (the feature's serialization resource; every unit naming it is ordered by file overlap). This unit covers design-l2.md section 7: the installed-probe helper (reusing the shipped local scheme check at `AppCoordinator.swift:7312-7315`; no plist or permission change), the handle predicate, resolvedCallChannel (six arguments) and resolvedMissedCallChannel (five arguments) returning the chain Result plus provenance, and the resolveChannel helper performing vocabulary normalisation and terminal substitution.
- Secondary settings storage: the published secondary property with key "secondaryCallApp" and the restore shape mirroring the primary (region `AppCoordinator.swift:2851-2853`), default phone. Recorded placement refinement: design-l2.md section 11 lists these two edits under C6; this plan places them in the seams unit so every consumer has its backing store, and the C6 view unit (T-154) then owns the screen, the section semantics and the picker plus persistence tests.
- Production call sites of resolvedCallChannel after this change: exactly two, plus the test helper — the LeafViews row site at `LeafViews.swift:1612-1615` (updated in T-151) and the coordinator site at `AppCoordinator.swift:8387` (updated here). Preference: update the coordinator site only and let T-151 flip the row site; if the shared signature forces the row site to change in this unit to keep the target compiling, do it and record the deviation in the unit report.
- Extend the resolution suite at `ios/ElderlyAssistantTests/Services/` `Voice/CallChannelResolutionTests.swift`: upgrade the assertResolved helper to the six-argument seam and Result with provenance, and add the seam-level cells (probe-stubbed routing, handle predicate, explicit-pick-wins, substitution). Same-file serialization with T-145 is intentional.
- SA-9 (dedupe at seam level): equal primary and secondary picks resolve to a single attempt with no duplicate work.
- Do not touch the override block or any emergency path in this unit.

## Definition of done
- [ ] Seams return the chain Result with provenance; replace-not-widen discipline kept in the call sites touched
- [ ] Probe helper reuses the shipped local check; no new plist entry, permission or network symbol
- [ ] Secondary property persists with key, restore shape and phone default (storage half of FR-CDP-003 and NFR-CDP-005; full round-trip acceptance in T-154)
- [ ] Resolution suite extended and green: `ios/build.sh test:unit CallChannelResolutionTests`
- [ ] Dedupe, explicit-pick-wins and substitution cases covered
- [ ] Code reviewed and merged

## T-147: MethodResolver global-default closure

## Metadata
- **Group:** TG-29 — Chain Core and Design-Record Corrections
- **Component:** C3 — MethodResolver injection (design-l2.md section 8, resolver half)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** T-144
- **Blocks:** T-149
- **Requirements:** [FR-CDP-012](../../define-requirements/FR/FR-CDP-012-voice-global-default-settings-primary.md)

## Description
Add the third initialiser parameter to MethodResolver — a global-default closure mapping call type to the settings primary — with a default of phone so existing constructions behave identically, and update the coordinator construction site to map the settings primary by call type. Steps one to three of the resolver stay unchanged.

## Acceptance criteria

```gherkin
Feature: MethodResolver global default becomes the settings primary

  Scenario: The closure maps the call type to the settings primary
    Given a resolver built with a stub storage and a closure returning faceTime for a video call
    When a bare call command is resolved
    Then the step-four default channel is faceTime and the method mapping is unchanged for voice calls

  Scenario: Default construction still resolves to the phone floor
    Given a resolver built with the default initialiser
    When a bare call command is resolved
    Then the resolved channel is phone
    And no stored preference or settings value changes behaviour for existing call sites
```

## Implementation notes
- Edit `ios/ElderlyAssistant/Services/` `Intents/MethodResolver.swift`: init gains the third parameter `globalDefault` with a default value mapping every call type to phone; the resolution steps one to three are untouched; step four consults the closure (design-l2.md section 8).
- Coordinator construction at `AppCoordinator.swift:1925-1926` passes the settings primary mapped by call type (the resolver's call-type sense: video-word versus plain call). This is a one-line region far from the T-146 seam edits; the owned-file token `AppCoordinator.swift` is still declared below so the engine orders coordinator edits strictly.
- Extend `ios/ElderlyAssistantTests/Services/` `Intents/MethodResolverTests.swift` with the closure-driven cases over the existing stub-storage helper: `testGlobalDefaultClosureMapsCallType`, `testDefaultConstructionStillPhone`, and a closed-map case proving the closure receives the call-type flag.
- Owned files: `ios/ElderlyAssistant/Services/` `Intents/MethodResolver.swift`, `ios/ElderlyAssistantTests/Services/` `Intents/MethodResolverTests.swift`, `ios/ElderlyAssistant/App/` `AppCoordinator.swift`.
- Gate: scoped run `ios/build.sh test:unit MethodResolverTests`; keep the suite's existing assertions untouched so step-one-to-three regressions surface.

## Definition of done
- [ ] Resolver init extended with the defaulted closure; existing constructions compile unchanged
- [ ] Coordinator construction site maps the settings primary by call type
- [ ] New and existing resolver tests green: `ios/build.sh test:unit MethodResolverTests`
- [ ] Scoped run reports the privacy guard executed and passed
- [ ] Code reviewed and merged
