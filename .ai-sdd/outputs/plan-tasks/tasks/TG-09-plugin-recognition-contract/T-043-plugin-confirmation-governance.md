# T-043: Plugin Confirmation Governance (core-enforced)

## Metadata
- **Group:** [TG-09 — Plugin Recognition & Contract](../index.md)
- **Component:** Services/Plugins (action declaration), Services/Voice (CommandRouter dispatch), Services/Intents (ConfirmationTier/confirmation flow)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-040](T-040-plugin-contract-v2-design.md)
- **Blocks:** [T-044](T-044-plugin-doc-contract-verification.md)
- **Requirements:** FR-009, FR-012, NFR-016, NFR-023

## Description

Close the governance hole: plugin dispatch is currently `ConfirmationTier.free` with the comment that each plugin owns its confirmation policy (`ConfirmationTier.swift:25-32`), while the live `RoutinePlugin` executes its side effect — `scheduler.addEntry` — before speaking a post-hoc confirmation (`RoutinePlugin.swift:125-149`), and `YouTubePlugin` likewise confirms after opening the external app (`YouTubePlugin.swift:10-16`). Under the pre-change contract a newly added plugin can perform a side-effecting action with no core confirm-before-execute gate, while the core app treats consequential actions (call, message, reminder) as confirm-first. Implement T-040's design: an action-level declaration that core enforces before `handle` runs.

## Acceptance criteria

```gherkin
Feature: Core-enforced confirmation for side-effecting plugin actions

  Scenario: A side-effecting plugin action is confirmed before it executes
    Given a plugin whose registered action is classified side-effecting by the T-040 contract
    When the user speaks the matching utterance
    Then the existing dual-channel confirmation question is spoken before handle is invoked
    And only after an affirmative answer does the plugin's side effect execute exactly once
    And the confirmation reuses the existing flow (voice हो/होइन plus chips, 45-second timeout) with no new UI

  Scenario: Declining or timing out cancels the side effect
    Given the same side-effecting action mid-confirmation
    When the user answers no, or the confirmation times out
    Then handle is never invoked
    And no reminder, entry, external app or other side effect occurs
    And the user hears an honest, externalised message that nothing was done

  Scenario: Read-only plugin actions remain ungated
    Given a read-only action such as the Nepali calendar query (NepaliCalendarPlugin.swift:47-94)
    When it is dispatched
    Then it answers without a confirmation question
    And its existing latency and spoken behaviour are unchanged

  Scenario: A plugin cannot weaken core's classification
    Given a plugin that declares one of its actions read-only while core's rule classifies it side-effecting
    When the plugin is registered or the action is dispatched
    Then core's classification wins and the action is confirmed, or the non-conforming declaration is rejected with an observability event
    And a plugin cannot declare any of its actions as never-gated, authenticated-exempt, or eligible for the emergency/medication namespaces
    And this is enforced in core, not in a code review convention

  Scenario: Existing plugins' behaviour is explicitly re-classified, not silently changed
    Given RoutinePlugin's routine.set (side effect: adds a reminder entry) and routine.query (read-only), YouTubePlugin's youtube.play (opens an external app), and the appliance and calendar plugins
    When the governance lands
    Then each registered action has a recorded classification and the user-visible change, if any, is stated in the guide
    And routine.set is confirmed before its entry is persisted unless T-040 records a reasoned exception in the design
    And no plugin can trigger the emergency path, a medication acknowledgement, or the keyword safety net

  Scenario: Enforcement lives in dispatch, with no per-plugin switch case
    Given the enforcement point named in T-040
    When it is implemented
    Then one check applies to every plugin action uniformly — core never gains a case per plugin name
    And the single InterpretedCommand.Action.plugin case and the single CommandRouter dispatch case remain the only core plugin vocabulary

  Scenario: Governance events are PII-free
    Given a confirmation, a decline and a timeout on a plugin action
    When observability events are emitted
    Then they carry the action name from the fixed registry vocabulary and the outcome only — never transcript text, entity values, or user words (NFR-016)

  Scenario: Deviation from the designed enforcement is not permitted silently
    Given an implementation constraint that makes part of T-040's enforcement impractical
    When the implementer deviates
    Then the design note is updated and re-approved by the lead engineer before the deviating code lands
    And the deviation and its safety reasoning are recorded
```

## Implementation notes

- Model the declaration on the existing registry contract (`PluginIntentContribution.actionNames`, `AssistantPlugin.swift:51-60`) — e.g. a per-action classification carried alongside the name; core reads it through the registry, never through a plugin-name switch.
- Reuse `ConfirmationTier` semantics as the vocabulary but do not let a plugin return `.neverGated` for its own action; the tier a plugin action can receive is derived by core.
- The confirmation question must be localised through `Localizable.xcstrings` in both supported languages (NFR-023).
- `handle` must stay the only execution point: enforcement gates the call to `plugin.handle`, so no plugin can execute before it — this keeps the plugin's own internals untouched by core.
- Do not gate the router's post-hoc spoken outcomes (they are speech, not side effects); the gate is confirm-before-execute, matching core's `call`/`send_message` policy.
- Coordinate with T-042's guide truth-up: the new classification table belongs in the guide, in the same commit series.
- The plugin hard boundary is unchanged: emergency, medication ack/reminders and the deterministic keyword layer remain core (constitution; design doc §5) — the governance work must not create a path where a plugin can be asked to perform those.

## Definition of done
- [ ] Action-level classification implemented and enforced in core before handle
- [ ] Side-effecting plugin actions confirmed through the existing dual-channel flow; decline/timeout leaves no side effect
- [ ] Read-only actions ungated; classification of every existing plugin action recorded (routine.set/query, youtube.play, appliance actions, nepali_calendar.query)
- [ ] Plugin self-declared never-gated/exempt declarations rejected in core with an observability event
- [ ] Uniform enforcement, no per-plugin switch case; single core plugin vocabulary preserved
- [ ] Observability events PII-free (NFR-016); confirmation messages externalised (NFR-023)
- [ ] Guide classification table landed with the code; any deviation re-approved in design
