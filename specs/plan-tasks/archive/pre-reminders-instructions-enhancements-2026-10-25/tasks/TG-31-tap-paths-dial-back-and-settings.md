# TG-31 — Tap Paths, Dial-Back and Settings

> **Jira Epic:** Tap Paths, Dial-Back and Settings

## Description
The tap and dial-back surfaces of the feature plus the settings screen that feeds the chain: address-book rows announce-then-open through the chain, family audio and video tiles route with the vocabulary, missed-call dial-back announces and dispatches through the same hop machinery, and the calling settings screen gains the second picker with the non-visual selection signal (the storage property itself lands in T-146). Carries SA-3 (per-surface floors), SA-9 (settings persistence tests) and the V-4 implementation half.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| T-151 | Tap rows: row channel state, announce and hop | M | T-146 | HIGH |
| T-152 | Family tiles: audio/video routing and hop branches | M | T-146, T-149 | HIGH |
| T-153 | Missed-call dial-back routing and announcement | M | T-146, T-149 | HIGH |
| T-154 | Settings: secondary picker and accessibility | M | T-145, T-146 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): ~3 days
- Realistic (2 devs): ~4 days

## Group-wide gates and conventions
- The coordinator file is shared by T-152 and T-153 and is serialized by file overlap; T-151 owns the row view plus the resolution suite, and T-154 owns only the settings view and its suite, so both are file-disjoint from the coordinator chain.
- Every announcement in this group is speech only; nothing here writes to logs beyond the shipped lanes. The tap announcement names the channel that actually opens, and the dial-back announcement names the channel actually dispatched.
- Scoped-suite gate, baseline note and fresh-worktree symlink note hold as in TG-29.
- Input discipline: the inputs of a unit are exactly the landed units named in its dependency line plus the design records; nothing is read across group boundaries without a declared edge.

## T-151: Tap rows: row channel state, announce and hop

## Metadata
- **Group:** TG-31 — Tap Paths, Dial-Back and Settings
- **Component:** C4 — address-book rows (design-l2.md section 9)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** T-146
- **Blocks:** T-157
- **Requirements:** [FR-CDP-010](../../define-requirements/FR/FR-CDP-010-tap-buttons-route-the-chain.md), [FR-CDP-016](../../define-requirements/FR/FR-CDP-016-automatic-routing-with-announcement.md), [NFR-CDP-002](../../define-requirements/NFR/NFR-CDP-002-local-probes-no-new-egress.md)

## Description
Route address-book row taps through the chain: the row state derives from the five-argument row helper, the row probe delegates to the same shipped local check, and dialChannel announces the routed channel before opening, threading the hop for launch-failure recovery. The GSM floor is reachable from every row state, including the numberless honest dead row.

## Acceptance criteria

```gherkin
Feature: Address-book row taps route the chain

  Scenario: The tap announces the routed channel then opens it
    Given a row whose chain routes to the secondary channel
    When the row is tapped
    Then the announcement names that routed channel before the opener runs
    And the opener receives the pre-built hop for launch-failure recovery

  Scenario: The probe is stubbed false and the row still routes
    Given a row preferring whatsApp with the installed probe stubbed false
    When the row state is derived
    Then the routed channel is the permitted secondary or the floor, and the announcement names it

  Scenario: A numberless row keeps its honest dead-row behaviour
    Given a row without a dialable number
    When the row is tapped
    Then the shipped honest behaviour is unchanged and no chain attempt is made
```

## Implementation notes
- Owned files: `ios/ElderlyAssistant/App/LeafViews.swift`, `ios/ElderlyAssistantTests/Services/` `Voice/CallChannelResolutionTests.swift`.
- In LeafViews.swift: the row probe at `LeafViews.swift:1171-1174` delegates to the same shipped local check as the coordinator probe (no second probe implementation); the row state helper (region `LeafViews.swift:1605-1620`) takes the five arguments including the settings pair and returns the row channel state with the routed channel and provenance; dialChannel (region `LeafViews.swift:1564-1584`) announces the routed channel via the shipped speech lane then switches on the channel, passing the LaunchHop; the row-state value (region `LeafViews.swift:2249-2266`) carries the fields the row needs. The whatsApp open site at `LeafViews.swift:1546-1548` is routed through dialChannel.
- SA-3 address-book rows surface: the floor is reachable from every row state; the numberless honest dead row is preserved (pinned).
- Extend the resolution suite: row-state cases (probe-stubbed routing, secondary fall-through, floor reachability) plus source pins for the announce-before-open order and the single probe implementation. Row helpers that are static are asserted directly; the rest are source-pinned with the house scan helper.
- The announcement is speech only; the row adds no console writes and no new keys (labels reuse the channel name keys).
- The secondary property read here lands in T-146.

## Definition of done
- [ ] Row state derives from the five-argument helper; probe delegates to the shipped local check
- [ ] Announce-before-open pinned; hop threaded into every opener call from the row
- [ ] Numberless dead-row behaviour pinned unchanged
- [ ] Scoped run green: `ios/build.sh test:unit CallChannelResolutionTests`
- [ ] Code reviewed and merged

## T-152: Family tiles: audio/video routing and hop branches

## Metadata
- **Group:** TG-31 — Tap Paths, Dial-Back and Settings
- **Component:** C4 — family tiles (design-l2.md section 9)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** T-146, T-149
- **Blocks:** T-157
- **Requirements:** [FR-CDP-009](../../define-requirements/FR/FR-CDP-009-explicit-pick-wins-as-preferred.md), [FR-CDP-010](../../define-requirements/FR/FR-CDP-010-tap-buttons-route-the-chain.md), [FR-CDP-018](../../define-requirements/FR/FR-CDP-018-preserved-behaviours.md), [NFR-CDP-009](../../define-requirements/NFR/NFR-CDP-009-no-regression-shipped-call-paths.md)

## Description
Route the family contact tiles through the chain with the call-type vocabulary: the video tile allows faceTime and excludes phone from candidacy until the floor, the audio tile excludes faceTime, each tile always passes its per-contact preferred app (never nil), announces the routed channel and threads the hop. The tiles' shipped outcome strings are extended for the fallback cases without changing the shipped ones.

## Acceptance criteria

```gherkin
Feature: Family tile routing

  Scenario: The video tile routes video-capable channels
    Given a family video tile with a feasible preferred channel
    When the tile is tapped
    Then the routed channel respects the video vocabulary, the announcement names it, and the outcome string records the video lane

  Scenario: The audio tile never routes faceTime
    Given a family audio tile whose preferences include faceTime
    When the tile is tapped
    Then the routed channel is audio-capable (the terminal is the phone floor)

  Scenario: A terminal invalid-phone result hops nowhere
    Given a tile tap whose opener reports an invalid phone terminal
    When the branch completes
    Then the shipped line is spoken and no hop is attempted
```

## Implementation notes
- Owned files: `ios/ElderlyAssistant/App/` `AppCoordinator.swift`, `ios/ElderlyAssistantTests/Services/` `Intents/ContactCallButtonsTests.swift`.
- In AppCoordinator.swift: the family tile path (performContactCall, design-l2.md section 9) takes the vocabulary from the call type via the resolver vocabulary helper; the tile always passes a non-nil per-contact app as the preferred channel (R-4); the announcement names the routed channel at resolution; the hop branches thread the LaunchHop into the family openers; the outcome strings are extended additively (a fallback suffix on the video and audio lanes) while the shipped direct strings stay byte-identical.
- Terminal handling: an invalid-phone opener result on the whatsApp or chat lane is a terminal — speak the shipped line, no hop (pinned). The settings pair is consumed by the tile at the seam call (secondary plus probe).
- Extend ContactCallButtonsTests.swift: the preference-level cases already cover the opener semantics; add the tile routing cases (video vocabulary excludes the phone candidate until the floor, audio excludes faceTime, non-nil preferred always passed) and the invalid-phone terminal pin. Reachability: the family tile floor is one of the SA-3 surfaces — assert the floor with every other channel infeasible.
- No new keys; announcements reuse the shipped lane and the channel name keys.

## Definition of done
- [ ] Video and audio vocabularies enforced at the tiles; floor reachable with everything else infeasible
- [ ] Per-contact preferred always non-nil (pinned); shipped direct outcome strings byte-identical
- [ ] Invalid-phone terminal speaks once and never hops
- [ ] Scoped run green: `ios/build.sh test:unit ContactCallButtonsTests CallChannelResolutionTests`
- [ ] Code reviewed and merged

## T-153: Missed-call dial-back routing and announcement

## Metadata
- **Group:** TG-31 — Tap Paths, Dial-Back and Settings
- **Component:** C4 — dial-back (design-l2.md sections 7 and 9)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** T-146, T-149
- **Blocks:** T-157
- **Requirements:** [FR-CDP-011](../../define-requirements/FR/FR-CDP-011-missed-call-dial-back-routes-the-chain.md), [FR-CDP-018](../../define-requirements/FR/FR-CDP-018-preserved-behaviours.md), [NFR-CDP-009](../../define-requirements/NFR/NFR-CDP-009-no-regression-shipped-call-paths.md)

## Description
Route missed-call dial-back through the chain: the dial route value carries the action, the routed channel, the provenance and the hop candidates; the dial action guards its inputs as shipped and switches on the resolved action; dialBackMissedCall announces the routed channel at resolution then dispatches with the LaunchHop. No step of the chain awaits anything: escalation timing is untouched.

## Acceptance criteria

```gherkin
Feature: Missed-call dial-back routes the chain

  Scenario: Dial-back announces the routed channel then dispatches
    Given a missed call whose number matches a family contact preferring messenger with a handle
    When dial-back runs
    Then the announcement names messenger before the opener runs and the hop is threaded into the dispatch

  Scenario: An unmatched number keeps the shipped tel behaviour
    Given a missed call with no matching contact
    When dial-back runs
    Then the dial action is the shipped tel floor with an empty provenance

  Scenario: Nothing in the dial-back chain delays escalation (failure discipline)
    Given the dial-back source region
    When the hop and dispatch paths are inspected
    Then no await, sleep, retry loop or timer appears in the chain
    And the emergency escalation path is untouched
```

## Implementation notes
- Owned files: `ios/ElderlyAssistant/App/` `AppCoordinator.swift`, `ios/ElderlyAssistantTests/App/` `MissedCallDialBackTests.swift`.
- In AppCoordinator.swift: add the dial-route value (action, routed channel, provenance, hop candidates) returned by the missed-call dial action, with the shipped guards and switch semantics preserved (design-l2.md section 7); dialBackMissedCall composes the announcement from the routed channel plus provenance at resolution time, then dispatches through the shared hop machinery (section 9). The dial-back runs the ordinary chain only — it never touches emergency frames or lifts any guard.
- SA-4(d) evidence: the unit report states the no-await inspection result for the dial-back chain region; the final unit re-checks it.
- Extend MissedCallDialBackTests.swift: the existing resolution cases upgrade to the route value with provenance; add announce-before-dispatch pin, hop threading, empty-provenance tel floor, and floor reachability with every other channel infeasible.
- Speech only; no new console writes; no new keys.

## Definition of done
- [ ] Route value returned with routed channel, provenance and candidates; shipped guards intact
- [ ] Announcement precedes dispatch and names the routed channel (pinned)
- [ ] Emergency and escalation paths untouched; no-await inspection recorded
- [ ] Scoped run green: `ios/build.sh test:unit MissedCallDialBackTests`
- [ ] Code reviewed and merged

## T-154: Settings: secondary picker and accessibility

## Metadata
- **Group:** TG-31 — Tap Paths, Dial-Back and Settings
- **Component:** C6 — settings pickers (design-l2.md section 11, view half; storage half landed in T-146)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** T-145, T-146
- **Blocks:** —
- **Requirements:** [FR-CDP-001](../../define-requirements/FR/FR-CDP-001-primary-dialer-setting.md), [FR-CDP-002](../../define-requirements/FR/FR-CDP-002-fallback-dialer-setting.md), [FR-CDP-003](../../define-requirements/FR/FR-CDP-003-secondary-call-app-persistence.md), [NFR-CDP-005](../../define-requirements/NFR/NFR-CDP-005-persistence-round-trip.md), [NFR-CDP-006](../../define-requirements/NFR/NFR-CDP-006-picker-accessibility.md)

## Description
The calling settings screen gains its second labelled section bound to the secondary storage property: two pickers with distinct titles, the shared row pattern, the non-visual selected signal on both sections (V-4 implementation half), heading semantics on the section titles, and the new settings suite that exercises persistence end to end (round-trip, absent and garbage fallback, equal picks). The storage property and restore shape themselves land in T-146; this unit owns the screen, the section semantics and the tests. No sixth user-visible string appears.

## Acceptance criteria

```gherkin
Feature: Secondary dialer picker and persistence

  Scenario: An absent or garbage stored value restores the phone floor
    Given fresh storage with no secondary key (or an unknown raw value)
    When the coordinator initialises
    Then the secondary picker shows phone as selected

  Scenario: The pick round-trips across coordinator instances
    Given a secondary pick of messenger
    When a new coordinator initialises over the same storage
    Then the picker shows messenger as selected

  Scenario: Both sections persist independently
    Given distinct primary and secondary picks
    When each row is tapped in turn
    Then each section reflects only its own pick and the two values persist separately

  Scenario: Selection is announced non-visually (failure of the visual-only check)
    Given the shipped row pattern that conveyed selection by checkmark and stroke only
    When the updated rows are inspected
    Then each selected row carries a selected signal readable without sight (trait or value)
    And the section titles carry heading semantics
```

## Implementation notes
- Owned files: `ios/ElderlyAssistant/App/` `CallingSettingsView.swift`, `ios/ElderlyAssistantTests/App/` `CallingSettingsSurfaceTests.swift` (new suite).
- View in CallingSettingsView.swift: two sections built by the shipped row pattern (region `CallingSettingsView.swift:40-64`); section titles use the two new keys (settings.calling.primaryTitle, settings.calling.secondaryTitle — catalog entries land in T-155); the channel name key mapping delegates to the chain helper so labels stay single-sourced; V-4 implementation: the selected row of each section carries a selected accessibility trait or value and the section titles carry a heading trait — traits and semantics only, no sixth user-visible string.
- Storage consumed, not implemented here: the published secondary property with key "secondaryCallApp", restore shape and phone default landed in T-146 (the seams unit; region `AppCoordinator.swift:2851-2853`). Equality of the two picks is legal and deduped later by the chain (SA-9).
- New suite CallingSettingsSurfaceTests.swift (App tests folder, real-store seam pattern of its siblings; instantiate the coordinator with the in-memory profile storage helper): testSecondaryAbsentRestoresPhone, testSecondaryRoundTrip, testPickerTwoSectionsPersist, plus the accessibility pins (selected-signal presence on both sections, heading semantics on both titles). Value-level assertions where the model is reachable, source pins with the house scan helper for the view structure; rendered-tree limits are recorded as device-validation items, not simulated here.
- Gate: scoped run `ios/build.sh test:unit CallingSettingsSurfaceTests`.

## Definition of done
- [ ] Both sections render with distinct titles; only their own pick selects; no sixth user-visible string
- [ ] Round-trip, absent and garbage fallback green (exercising the T-146 storage): `ios/build.sh test:unit CallingSettingsSurfaceTests`
- [ ] Non-visual selected signal on both sections; heading semantics on both titles
- [ ] Name-key mapping delegates to the chain helper (single source)
- [ ] Code reviewed and merged
