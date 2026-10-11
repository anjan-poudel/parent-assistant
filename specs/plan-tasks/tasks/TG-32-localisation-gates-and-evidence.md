# TG-32 — Localisation, Log-Safety Gate and Release Evidence

> **Jira Epic:** Localisation, Log-Safety Gate and Release Evidence

## Description
Closes the feature: the five ne/en catalogue keys with the family coverage tests, the release privacy gate extended to the new calls root, and the final integration unit that audits preservation surfaces, sweeps the scoped suites and assembles the evidence pack for security-test and final sign-off. The final unit is the plan's barrier and carries the final marker.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| T-155 | Localisation: five ne/en keys and coverage | S | — | LOW |
| T-156 | Log-safety gate: Services/Calls feature root | S | T-145 | MEDIUM |
| T-157 | Final integration and release-evidence sweep | S | T-144, T-145, T-146, T-147, T-148, T-149, T-150, T-151, T-152, T-153, T-154, T-155, T-156 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~1.5 days
- Realistic (2 devs): ~1.5 days

## Group-wide gates and conventions
- The five-key bound is exact: exactly the five named keys, no sixth user-visible string anywhere in the feature surface (SA-8). Every other label reuses shipped keys.
- The privacy gate runs inside every scoped build step; its exit-0 result is part of each unit's evidence and is re-run formally in the final unit.
- The final unit owns no source files; it audits, re-runs and records. It must be planned last in its wave (final marker).

## T-155: Localisation: five ne/en keys and coverage

## Metadata
- **Group:** TG-32 — Localisation, Log-Safety Gate and Release Evidence
- **Component:** C7 — catalogue (design-l2.md section 12)
- **Agent:** dev
- **Effort:** S
- **Risk:** LOW
- **Depends on:** —
- **Blocks:** T-157
- **Requirements:** [FR-CDP-017](../../define-requirements/FR/FR-CDP-017-localisation-new-strings.md), [NFR-CDP-007](../../define-requirements/NFR/NFR-CDP-007-localisation-completeness.md)

## Description
Add exactly five user-visible strings in both languages with the frozen binding parameter contracts, and extend the catalogue coverage suite with the calling family so parity, placeholder counts and the no-literal rule are enforced by test.

## Acceptance criteria

```gherkin
Feature: Calling feature localisation

  Scenario: All five keys resolve in both languages
    Given the updated catalogue
    When the calling family is checked
    Then each of the five keys resolves in ne and en and none carries the English copy in the ne entry

  Scenario: The parity check names a missing value
    Given an intentionally missing ne value for one calling key
    When the coverage check runs
    Then it fails and the failure message names the missing key (suite convention)

  Scenario: The key bound is exact
    Given the feature surface
    When the catalogue is diffed against the design table
    Then exactly the five named keys are added and no sixth user-visible string appears
```

## Implementation notes
- Owned files: `ios/ElderlyAssistant/Resources/` `Localizable.xcstrings`, `ios/ElderlyAssistantTests/App/` `L10nCatalogCoverageTests.swift`.
- Exactly five keys with the frozen contracts: settings.calling.primaryTitle, settings.calling.secondaryTitle, router.call.fallbackDisclosure (binds the skipped-channel label), call.announce.fallbackRouted (binds the routed-channel label), call.announce.launchFailedFallback (binds the failed and next labels). Values in Nepali and English, placeholder counts equal across languages, entries placed alphabetically and contiguously as the file convention requires (the suite asserts this for existing families; extend the same discipline).
- Extend L10nCatalogCoverageTests.swift in the house family pattern: a calling-family resolution test, a placeholder-parity test, and keep the existing families untouched so their baselines stay green. The suite already automates the ne/en parity sweep; the new keys must be covered by it and by an explicit named assertion.
- No user-visible literal may appear in the feature's views or coordinator — labels route through the catalogue keys only.

## Definition of done
- [ ] Exactly five keys added; ne and en values complete; placeholder counts equal
- [ ] Coverage suite extended and green: `ios/build.sh test:unit L10nCatalogCoverageTests`
- [ ] No sixth user-visible string; no literal copy in views or coordinator
- [ ] Code reviewed and merged

## T-156: Log-safety gate: Services/Calls feature root

## Metadata
- **Group:** TG-32 — Localisation, Log-Safety Gate and Release Evidence
- **Component:** release gate (design-l2.md section 13, row 27)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** T-145
- **Blocks:** T-157
- **Requirements:** [NFR-CDP-003](../../define-requirements/NFR/NFR-CDP-003-log-safety.md), [NFR-CDP-010](../../define-requirements/NFR/NFR-CDP-010-compliance-and-release-gates.md)

## Description
Extend the release privacy guard's feature roots with the calls service root so the new chain file is graded inside the gate, following the shipped per-feature comment pattern, and confirm the guard exits zero with the new file present. Numbers, handles and announcement content stay out of logs under the existing policy.

## Acceptance criteria

```gherkin
Feature: Release privacy guard covers the calls root

  Scenario: The guard exits zero with the calls root listed
    Given the chain file present under the calls service root
    When the privacy guard runs
    Then it lists the calls root among the graded feature roots and exits zero

  Scenario: The new chain file is graded as a feature file
    Given the calls root registered
    When the role match runs
    Then the chain file matches the feature-role rule and its emissions are graded under the strict rules

  Scenario: A file outside every root is still flagged (failure discipline)
    Given a scratch file outside the registered roots
    When the guard runs
    Then the unregistered file is reported and the guard fails
```

## Implementation notes
- Owned file: `ios/tools/check-release-log-safety.py`. Adds the calls service root (the services subtree plus the calls directory) to the feature-root list at `check-release-log-safety.py:141` and following, written in the shipped per-feature comment pattern naming the feature and the design section, exactly as the previous feature entries do.
- Confirm, without changing: the role-match rules around `check-release-log-safety.py:821-834` grade the chain file as a feature file; LogSanitiser.allowedKeys stays unchanged; the guard step in the build script (the source privacy check that runs before test scopes) stays intact.
- Verification commands: any scoped unit run executes the guard; run it directly as well and record the exit code and the summary line in the unit report. No interpreter invocation detail is needed beyond the shipped script entry point.
- The hop event metadata and all new emissions stay inside the closed token rule; this unit is the gate-side half of SA-6 (the coordinator-side halves landed in T-149 and T-150).

## Definition of done
- [ ] Calls root registered in the shipped comment pattern; no other gate change
- [ ] Guard exits zero with the new file present; role match grades it feature-role
- [ ] Unregistered-file failure discipline still demonstrated by the guard's own tests or a scratch check
- [ ] Exit-0 evidence recorded in the unit report
- [ ] Code reviewed and merged

## T-157: Final integration and release-evidence sweep

## Metadata
- **Group:** TG-32 — Localisation, Log-Safety Gate and Release Evidence
- **Component:** integration (all components)
- **Agent:** dev
- **Effort:** S
- **Risk:** HIGH
- **Depends on:** T-144, T-145, T-146, T-147, T-148, T-149, T-150, T-151, T-152, T-153, T-154, T-155, T-156
- **Blocks:** —
- **Requirements:** [FR-CDP-018](../../define-requirements/FR/FR-CDP-018-preserved-behaviours.md), [FR-CDP-019](../../define-requirements/FR/FR-CDP-019-device-validation-completion-gate.md), [NFR-CDP-008](../../define-requirements/NFR/NFR-CDP-008-deterministic-testability.md), [NFR-CDP-009](../../define-requirements/NFR/NFR-CDP-009-no-regression-shipped-call-paths.md), [NFR-CDP-010](../../define-requirements/NFR/NFR-CDP-010-compliance-and-release-gates.md)

Final: true
<!-- wave: final -->

## Description
The plan's final barrier. Audits the preservation surfaces end to end, sweeps every scoped suite for the feature, re-runs the privacy gate formally, and assembles the evidence pack that security-test and final sign-off consume, including the device-validation checklist hand-off.

## Acceptance criteria

```gherkin
Feature: Final integration evidence

  Scenario: The whole feature sweeps green on the scoped suites
    Given all feature units merged
    When the scoped family run completes
    Then every named suite passes and the privacy guard prints exit zero

  Scenario: Preservation surfaces are byte-unchanged (failure if any drift)
    Given the change set
    When the emergency components file region, the override block and gate, and the plist are diffed against the baseline
    Then the emergency region is byte-unchanged, the override gate is diff-clean, no emergency identifiers were added anywhere, and the plist byte-diff is empty

  Scenario: Only one new store key exists and no per-contact storage appears
    Given the settings and storage diffs
    When the store keys are enumerated
    Then the secondary key is the only new store key and no per-contact primary or secondary storage exists

  Scenario: The evidence pack is complete for sign-off
    Given the merged feature branch
    When the pack is assembled
    Then it maps every SA item to its unit and test evidence, lists the five keys with parity proof, records the gate exit codes, and carries the device-validation checklist for the seven device items
```

## Implementation notes
- Final unit — must be planned in its own final wave. Owns no source files; delivers audit evidence in its unit report.
- Preservation audit (SA-4): confirm no emergency component file is in the change set and the emergency components region (`RedesignComponents.swift:229-237`) is byte-unchanged; the override block (`AppCoordinator.swift:7656-7686`) with its gate (`AppCoordinator.swift:7665-7669`) is diff-clean and the amended action (`AppCoordinator.swift:7670-7674`) still constructs with provenance dropped; zero additions of emergency notify identifiers, notify-channel types or preferred-emergency-contact storage anywhere; no escalation-delaying await in the dial-back chain (re-verify T-153's inspection); the confirmation timeout constant (`VoiceSessionStateMachine.swift:135`) untouched.
- New-surface audit (SA-7): plist byte-diff empty; no new network symbol anywhere in the diff; the secondary settings key is the only new store key; no per-contact primary or secondary storage. Traceability statement of record: no router service exists and no per-contact storage was added (FR-CDP-018).
- Sweep (NFR-CDP-009, NFR-CDP-008): scoped family run — `ios/build.sh test:unit CallChannelResolutionTests MethodResolverTests MissedCallDialBackTests ContactCallButtonsTests CallingSettingsSurfaceTests CallConfirmationWordingTests L10nCatalogCoverageTests` — plus the privacy gate exit-0 re-run and the announcement end-to-end checks (prompt names routed channel; one hop line per hop; M-1 variant exercised; floor speaks the shipped line).
- Evidence pack contents: SA-1..SA-9 landing map with unit and test references; the five-key parity proof (SA-8); gate exit codes (SA-6); the no-egress statement (probes local-only); the device checklist for the seven device-validation items with their pass criteria, prepared for execution on the reference device (the device pass itself is the downstream sign-off gate, not simulated here).
- Baseline honesty: record that scoped suites are the gate and that the full-bundle pre-existing failures are unrelated; note the fresh-worktree model symlink requirement if the sweep runs in a new worktree.

## Definition of done
- [ ] Preservation audit recorded with the exact anchors above; any drift fails the unit
- [ ] Plist byte-diff empty; single new store key; no per-contact storage; no new network symbol
- [ ] Scoped family sweep green and privacy gate exit zero recorded
- [ ] Evidence pack assembled (SA map, key parity, exit codes, device checklist)
- [ ] Final-wave placement honoured (planned after T-144..T-156)
- [ ] Code reviewed and merged
