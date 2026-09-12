# T-044: Doc-as-Contract Verification Suite

## Metadata
- **Group:** [TG-09 — Plugin Recognition & Contract](../index.md)
- **Component:** ElderlyAssistantTests (Services/Plugins, Services/Voice, Services/Intents), docs/plugin-architecture.md
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-041](T-041-brain-independent-plugin-routing.md), [T-042](T-042-transcript-contract-and-doc-truth.md), [T-043](T-043-plugin-confirmation-governance.md)
- **Blocks:** —
- **Requirements:** FR-008, FR-009, NFR-013, NFR-016, NFR-023

## Description

Make every load-bearing claim in `docs/plugin-architecture.md` executable. The suite extends the existing test files — `PluginRegistryTests`, `CommandRouterTests`, `LlamaCommandInterpreterTests`, `ApplianceHelperPluginTests`, `GuidePluginDispatchTests` — rather than creating a parallel harness, and it pins both directions: the behaviours the guide promises (collision event, double gating, per-brain recognition, transcript propagation, honest failures, safety exclusion, zero-core-edit plugin addition) and the corrections T-042 lands (ApplianceHelperPlugin is not a skeleton, the `notReady` key is gone, registration is the lazy factory). A guide claim with no test is a defect in this suite.

## Acceptance criteria

```gherkin
Feature: Plugin architecture claims are executable tests

  Scenario: Duplicate action names are rejected loudly, including the event
    Given two plugins claiming the same action name and a recording observability bus
    When both are registered
    Then the second registration is dropped and the first claimant still resolves
    And an event with component "plugin_registry", eventType "plugin_action_collision", outcome "failure" and the collision payload is asserted — the existing test asserts only the drop (PluginRegistryTests.swift:44-52), so the loud half of the contract gains its assertion here
    And the registry never crashes or traps on the collision

  Scenario: Geography gating is asserted on both halves
    Given a plugin applicable only to Nepali and an English-locale fixture
    When the cloud prompt is composed and dispatch is attempted
    Then the plugin's fragment is absent from the composed prompt (GeminiCommandInterpreter.swift:72-75)
    And registry.plugin(handling:locale:) resolves nil for that locale and dispatch speaks the honest unavailable message (PluginRegistry.swift:47-56; CommandRouter.swift:2293-2299)

  Scenario: Every supported brain either emits or explicitly rejects .plugin
    Given the T-039/T-040 decision
    When the per-brain matrix test runs
    Then for the cloud brain a fixture proves emission and dispatch
    And for each on-device brain the test asserts the decided behaviour — recognition via the chosen path, or an explicit rejection pinned by the generation schema/grammar (LlamaCommandInterpreter.swift:189-193, 219-221; LocalIntentInterpreter.swift:303-312)
    And the matrix test fails if a brain's behaviour changes without the decision record being updated

  Scenario: Transcript semantics are enforced on both dispatch paths
    Given the T-042 outcome
    When a fixture plugin records the PluginCommand it receives
    Then the normal .plugin path and the guide-deferral path carry the same field semantics
    And the recorded transcript is sanitised when the code-fix option was chosen (NFR-013), and absent when the contract-fix option was chosen
    And the appliance extraction fallback is exercised on the normal path (ApplianceHelperPlugin.swift:88-95)

  Scenario: Failure paths are honest and observable
    Given fixtures for: an unconfigured Gemini client, a plugin returning .failed(spokenApology:), an action name matching no plugin, and a plugin dropped by the collision rule
    When each is dispatched
    Then the user hears the corresponding honest localized message, never silence and never a fabricated success
    And the corresponding observability event is asserted for each path

  Scenario: Plugin actions cannot reach safety-critical paths
    Given adversarial fixtures that pair plugin vocabulary with emergency phrases, medication acknowledgements, and keyword-net forms
    When they are routed
    Then the emergency path, the medication acknowledgement path and the keyword stages are reached unchanged
    And no plugin handle is invoked for those utterances
    And the test fails if a future routing change lets a plugin pre-empt them

  Scenario: Adding a fixture plugin needs no core edit
    Given a new fixture plugin registered in the test's registry factory
    When the end-to-end routing test runs
    Then the plugin is reachable with no edit to InterpretedCommand.Action, IntentPrompt's core section, or CommandRouter.dispatchInterpreted's switch
    And a source-scan assertion over those three files fails if a plugin action name (for example "nepali_calendar.query", "routine.set", "youtube.play", "appliance.identify") appears in them
    And the scan's expected exceptions — the two documented core lookups decided in T-040 (CommandRouter.swift:2341; AppCoordinator.swift:5349) — are listed explicitly, so any new exception fails the test

  Scenario: Corrected guide claims cannot silently regress
    Given docs/plugin-architecture.md after T-042
    When the doc-contract assertions run
    Then the guide states the lazy first-use factory (not AppCoordinator.init), names all four registered plugins, and describes ApplianceHelperPlugin's live camera flow
    And assertions fail if the "not ready" skeleton wording or an init-registration claim reappears
    And plugin.applianceHelper.notReady is asserted absent from Localizable.xcstrings, and no Swift source references it

  Scenario: Observability across every suite path is PII-free
    Given the events emitted by all scenarios above
    When they are inspected
    Then no event carries transcript text, entity values, contact data or user words — only fixed vocabulary, action names and outcomes (NFR-016)

  Scenario: The suite runs where the app's tests run
    Given the repository's canonical iOS test command
    When the suite executes
    Then it runs inside the existing ElderlyAssistantTests target (no parallel harness, no new target)
    And a failing assertion fails the run that gates the plugin changes
```

## Implementation notes

- Reuse the existing doubles rather than inventing new ones: `FakePlugin` (`PluginRegistryTests.swift:58-86`), `FakeGeminiTransport` + `GeminiInMemoryStorage` (`CommandRouterTests.swift:229-285`), `StubCommandInterpreter`/`FakeCommandInterpreter`, `MockSpeaker`, `RecordingObservabilityBus`/`MockObservabilityBus` (`GuidePluginDispatchTests.swift:30-57`).
- The source-scan and doc-lint assertions are plain test code reading repository files (resolve paths from `#filePath`); they must be deterministic and must fail with the offending file and line in the message. If the repo already runs such scans (scripts/ or CI), extend that mechanism instead — decide by inspecting the repo at implementation time and record the choice.
- The per-brain matrix test is the guard that keeps T-039's decision and the code aligned; when TG-08's encoder ship changes the local brain (T-037), this test is the place the new brain's behaviour gets declared.
- Keep `CommandRouterTests`' async pattern for plugin dispatch (`wait` after `speak()` tasks land) — do not introduce sleeps longer than the existing convention.
- Do not change production behaviour in this task; a failing assertion is fixed either by a follow-up implementation commit or by an updated decision record, never by weakening the assertion.
- The suite is iOS-only because the plugin runtime is iOS-only (documented invariant); if Android gains a plugin runtime later, this is the reference contract for its port.

## Definition of done
- [ ] Collision event asserted, not just the drop
- [ ] Double gating (prompt composition + dispatch) asserted with an inapplicable-locale fixture
- [ ] Per-brain emit-or-reject matrix test exists and is tied to the T-039/T-040 decision
- [ ] Transcript semantics asserted on both dispatch paths; appliance fallback regression pinned
- [ ] All honest-failure paths asserted with their events
- [ ] Safety-exclusion adversarial fixtures pass
- [ ] Fixture-plugin-no-core-edits test plus the source-scan assertion with explicit exceptions
- [ ] Doc-contract assertions pin the corrected guide claims and the dead key's absence
- [ ] PII-free assertion across emitted events
- [ ] Suite runs in the existing test target under the repository's canonical command
