# T-042: PluginCommand.transcript Contract + plugin-architecture.md Truth-Up

## Metadata
- **Group:** [TG-09 — Plugin Recognition & Contract](../index.md)
- **Component:** Services/Voice (CommandRouter plugin dispatch), Services/Plugins, docs/plugin-architecture.md, Resources/Localizable.xcstrings
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-040](T-040-plugin-contract-v2-design.md)
- **Blocks:** [T-044](T-044-plugin-doc-contract-verification.md)
- **Requirements:** FR-008, NFR-013, NFR-016, NFR-023

## Description

Implement T-040's transcript decision and make the developer guide true. The live defect: `PluginCommand.transcript` is documented as the sanitised transcript (`AssistantPlugin.swift:65-66`), but normal plugin dispatch passes an empty string (`CommandRouter.swift:2302-2307`), only the guide-deferral path passes a transcript (`CommandRouter.swift:2345-2348`), and that one is the raw pending transcript — the router does not sanitise at all (sanitisation exists only inside the three interpreters). Separately, `docs/plugin-architecture.md` contains load-bearing falsehoods: the registration location, the plugin reference list, the ApplianceHelperPlugin description, and the dead `plugin.applianceHelper.notReady` key it implies. Code and the guide move in the same commit.

## Acceptance criteria

```gherkin
Feature: Transcript contract and accurate plugin guide

  Scenario: The transcript decision is implemented exactly as designed
    Given T-040's decision (fix the code by sanitising at the dispatch boundary, or fix the contract by removing the field)
    When the implementation lands
    Then every PluginCommand construction site in production code follows the decision
    And if the code is fixed: the transcript passed to handle is InputSanitiser.sanitise(_:level: .quarantine)-processed and non-empty only when the user actually spoke (NFR-013)
    And if the contract is fixed: the field and all its readers are removed, plugins that relied on it declare the data as entities, and no orphaned comment remains

  Scenario: Both dispatch paths carry the same contract
    Given the normal .plugin path and the guide-deferral path (CommandRouter.swift:2291-2368)
    When a plugin handles a command on either path
    Then the PluginCommand it receives is built by one shared helper with identical field semantics
    And a regression test asserts the transcript (or its replacement) is present on the normal path — today it is "" and the ApplianceHelperPlugin.extractQuestion fallback (ApplianceHelperPlugin.swift:88-95) can never fire there

  Scenario: The extraction fallback becomes reachable when the code is fixed
    Given an appliance utterance where the LLM emitted no "question" entity
    When it is dispatched through the normal path
    Then ApplianceHelperPlugin.extractQuestion returns the sanitised transcript instead of nil
    And a test pins this regression so the empty-string path cannot return silently

  Scenario: The developer guide matches the code it describes
    Given docs/plugin-architecture.md as it exists at implementation time
    When the guide is corrected
    Then the registration step says the registry is built by the lazy first-use factory (AppCoordinator.swift:1150-1156, factory at 1275-1285) and that it is deliberately not constructed in init ([BOOT-REVIEW P0-1]), replacing the current "Register it in AppCoordinator.init" claim
    And the reference list names all four registered plugins — NepaliCalendarPlugin, ApplianceHelperPlugin, RoutinePlugin, YouTubePlugin (AppCoordinator.swift:1275-1285)
    And the ApplianceHelperPlugin entry describes the live camera/vision flow it ships (ApplianceHelperPlugin.swift:69-106; tests at ApplianceHelperPluginTests.swift:73, 88) and no longer calls it a "not ready" skeleton; the only honest failure is the unconfigured client (ApplianceHelperPlugin.swift:70-74)
    And the claim that plugins are recognised regardless of brain is replaced by the per-brain behaviour decided in T-040/T-039
    And the "case .plugin — the ONLY core case" wording is corrected per T-040's disposition of the two hard-coded core lookups (CommandRouter.swift:2341, AppCoordinator.swift:5349)
    And the compile-time-only and iOS-only invariants are stated (PluginRegistry.swift:7-9; no dynamic loading; no plugin code in Android)

  Scenario: The dead localisation key is removed
    Given plugin.applianceHelper.notReady exists in Localizable.xcstrings:7687 and has no Swift usage
    When the guide drops the "not ready yet" claim
    Then the key is removed from the catalogue
    And no hard-coded replacement string is introduced (NFR-023)

  Scenario: Stale test documentation is corrected with the code it describes
    Given GuidePluginDispatchTests' header describes the plugin as a skeleton (.failed) (GuidePluginDispatchTests.swift:5-7)
    When the plugin's shipped behaviour is documented accurately
    Then that header comment matches the live behaviour without changing what the tests assert about the guide fallback path

  Scenario: No PII or sanitisation regression
    Given either transcript branch
    When events and logs are emitted
    Then no transcript or entity value appears in observability output (NFR-016)
```

## Implementation notes

- One commit per subject, doc + tests + code together (repository convention): (1) transcript contract; (2) guide truth-up + dead key; (3) stale test header.
- The guide's "Testing pattern" section still names the real files; keep it, extend it with the duplicate-collision event assertion only if T-044 adds it (T-044 owns test additions, this task owns the guide text).
- `docs/superpowers/specs/2026-09-05-plugin-architecture-design.md` is the why-doc edited by T-040; this task does not duplicate that content into the guide — the guide links to it.
- Do not touch `docs/plugin-architecture.md` claims about search grounding or storage — those are accurate (NepaliCalendarPlugin.swift:72, 110-134).
- If T-040 chose fix-the-contract, the guide must instead explain how plugins obtain what they need, and `ApplianceHelperPlugin`'s documentation comment about the transcript fallback is updated in the same commit.
- Android: the guide states the iOS-only invariant; it does not add an Android section.

## Definition of done
- [ ] Transcript decision implemented at every production construction site, with tests for both dispatch paths
- [ ] Regression test pins the extraction fallback (or its replacement) on the normal path
- [ ] Guide corrected: registration location, four-plugin reference list, ApplianceHelperPlugin behaviour, per-brain recognition, core-case wording, invariants
- [ ] Dead key `plugin.applianceHelper.notReady` removed; no hard-coded replacement
- [ ] Stale GuidePluginDispatchTests header corrected
- [ ] Doc and code landed in the same commits
- [ ] No PII in events; NFR-013 sanitisation preserved
