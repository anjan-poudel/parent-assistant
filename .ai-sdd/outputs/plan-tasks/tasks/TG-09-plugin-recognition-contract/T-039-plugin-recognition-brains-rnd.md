# T-039: Plugin Recognition Across Brains — R&D Decision (GO/NO-GO)

## Metadata
- **Group:** [TG-09 — Plugin Recognition & Contract](../index.md)
- **Component:** Services/Plugins, Services/Voice (CommandRouter, interpreters), IntentRouter
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-040](T-040-plugin-contract-v2-design.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002

## Description

Produce the measured decision for how a plugin utterance can be recognised on **every** brain this project supports, because today it can be recognised on exactly one. The R&D establishes, per brain — cloud Gemini, on-device `LlamaCommandInterpreter`, the fine-tuned `LocalIntentInterpreter`, the TG-08 encoder (conditional on the T-033 GO), and the deterministic keyword layer — whether `.plugin` can be emitted at all, evaluates the routing options, and closes with an explicit GO/NO-GO that names one option and the per-brain behaviour it produces. The on-device gap is real **today** and is not conditional on TG-08; only the encoder row of the matrix waits on the [T-033](../TG-08-nepali-intent-encoder/T-033-encoder-bake-off-export-feasibility.md) GO/NO-GO.

## Acceptance criteria

```gherkin
Feature: Plugin recognition decision across every supported brain

  Scenario: Per-brain capability matrix is measured, not asserted
    Given the five recognition paths — GeminiCommandInterpreter, LlamaCommandInterpreter, LocalIntentInterpreter, the TG-08 encoder (if the T-033 decision is GO), and the deterministic keyword layer
    When the R&D findings are written
    Then each path is recorded as EMITS_PLUGIN or CANNOT_EMIT_PLUGIN with the exact file and line evidence
    And the matrix records that GeminiCommandInterpreter composes plugin fragments (GeminiCommandInterpreter.swift:72-75) while LlamaCommandInterpreter deliberately does not (LlamaCommandInterpreter.swift:319-327, 449-453)
    And the matrix records that the on-device generation grammars exclude the value "plugin" entirely: LlamaCommandInterpreter's GBNF intent alternation (LlamaCommandInterpreter.swift:189-193) and JSON-schema enum (LlamaCommandInterpreter.swift:219-221), and LocalIntentInterpreter's intent schema (LocalIntentInterpreter.swift:303-312)
    And the matrix records that no on-device interpreter is constructed with the plugin registry (AppCoordinator.swift:1062-1092) and that IntentPrompt.build defaults activePlugins to empty (IntentPrompt.swift:69-71)

  Scenario: The cloud-only reality is reproduced by an executable fixture
    Given a CommandRouter on the on-device stack (no Gemini key configured) and a registered plugin
    When the R&D fixture routes a plugin-shaped utterance through the LlamaCommandInterpreter path
    Then the fixture demonstrates that no InterpretedCommand(action: .plugin) can be produced on that path
    And the finding is recorded as a live defect of the current architecture, not as a documentation nit

  Scenario: Options are evaluated against fixed criteria before a recommendation
    Given the option set — (a) encoder emits a plugin gate class resolved by a deterministic registry action-name matcher in core, (b) the deterministic matcher serves every local brain without an encoder change, (c) plugin-eligible utterances are pinned to the cloud brain, (d) keep the current cloud-only behaviour and document it honestly
    When the options are evaluated
    Then each option records: recognizer affected, latency impact against NFR-002, offline behaviour, whether FR-007 holds on the on-device stack, whether plugin recognition can ever gate or pre-empt FR-009 safety paths, and the core-edit cost per new plugin
    And option (c) is recorded as conflicting with FR-007 for the on-device stack unless the cloud fallback is an explicit user-consented configuration
    And the recommendation names exactly one option

  Scenario: Kill criteria are pre-registered before measurement
    Given the spike plan
    When the spike starts
    Then the kill criteria are written down first: no option may add more than one core switch case per plugin, no option may delay or pre-empt the keyword safety net, and no option may require a plugin name to appear in InterpretedCommand.Action
    And the criteria are not adjusted after results are known

  Scenario: GO decision fixes per-brain behaviour for every existing brain
    Given at least one option passes every pre-registered criterion
    When the GO decision is recorded
    Then it names the chosen option and states, for each of the four existing brains (cloud Gemini, LlamaCommandInterpreter, LocalIntentInterpreter, keyword layer), what a plugin utterance does: recognised, explicitly rejected with an honest user-facing message, or handled by the deterministic matcher
    And it names what happens on the TG-08 encoder brain conditionally on the T-033 GO/NO-GO
    And the decision is signed off by the lead engineer before T-040 starts

  Scenario: NO-GO or keep-as-is leaves code untouched and the docs corrected
    Given no option passes the pre-registered criteria
    When the spike closes
    Then the decision records a NO-GO per option with the failing criterion
    And no production code is changed by this task
    And T-040 still proceeds with the transcript-contract and governance work, because those defects are independent of the recognition decision
    And docs/plugin-architecture.md's implication that recognition is brain-independent is listed as a required correction for T-042

  Scenario: Safety paths are provably out of scope of every option
    Given each candidate option
    When its routing point is placed against the router ladder
    Then no option can consume, delay or reinterpret an emergency phrase, a medication acknowledgement, or a keyword-net utterance, because the matcher sits after those stages or cannot match their action names
    And the decision states that no plugin action name may ever be registered under the emergency or medication namespaces

  Scenario: Encoder interaction is recorded against the TG-08 tasks, not silently diverged
    Given the T-033 decision outcome
    When the R&D report is finalised
    Then if T-033 is GO and option (a) is chosen, the required taxonomy change (a plugin gate class in the encoder output) is filed as an explicit change request against T-035 and T-036, with the exact field the encoder must emit
    And if T-033 is NO-GO or any other option is chosen, the report states that the encoder taxonomy carries no plugin class and that T-035's design is not contradicted
    And the report never assumes an encoder exists without the T-033 GO
```

## Implementation notes

- Evidence to verify and cite (already verified during planning, re-verify at implementation time):
  - Cloud path only composes fragments: `GeminiCommandInterpreter.swift:72-75`; the cloud path requires a configured Gemini key.
  - Llama path: registry retained unused (`LlamaCommandInterpreter.swift:319-327`), fragments deliberately not composed (`LlamaCommandInterpreter.swift:449-453`), GBNF grammar and JSON schema exclude "plugin" (`189-193`, `219-221`).
  - Fine-tuned local brain: `LocalIntentInterpreter` builds the prompt without plugins (`LocalIntentInterpreter.swift:106`) and its constrained-decoding schema excludes "plugin" (`LocalIntentInterpreter.swift:303-312`); it is not constructed with a `PluginRegistry` (`AppCoordinator.swift:1076-1092`).
  - `IntentPrompt.build` defaults `activePlugins` to empty and its doc states only the cloud path composes them (`IntentPrompt.swift:63-71`).
  - Dispatch itself needs a non-nil `GeminiClient` (`CommandRouter.swift:2293-2296`); plugins with network work fail honestly without a key (`NepaliCalendarPlugin.swift:88-93`, `ApplianceHelperPlugin.swift:70-74`).
- The matcher option must not reintroduce the problem the plugin system exists to solve: core must never learn a plugin's action names statically. `CommandRouter.dispatchInterpreted`'s `.plugin` case (`CommandRouter.swift:2106`, `2147`) is the only core case and stays that way.
- The deterministic keyword layer is not a candidate recognizer for plugin actions in this spike: `KeywordIntentRule.Domain` is deliberately limited to `news` and `youtube` (`KeywordIntentRule.swift:33-39`, `124-138`) and its comment enumerates what is never relaxed. Record it as an existing, narrow path, not as extensible.
- This task produces a decision record and fixtures only; it ships no production behaviour change. Where the decision requires a prototype to measure an option (e.g. matcher false-positive rate over the golden corpus utterances), the prototype is throwaway and lives with the report.
- No PII anywhere in fixtures or reports; fixtures use synthetic plugin names and the existing golden corpus only (NFR-016).
- Suggested landing zone: a decision note under `docs/superpowers/specs/` appended to the plugin architecture why-doc, plus fixtures in the existing iOS test target. Paths are the task's choice but must be committed.

## Definition of done
- [ ] Per-brain capability matrix with file:line evidence for every path
- [ ] Cloud-only defect reproduced by an executable fixture (not text alone)
- [ ] Four options evaluated against the fixed criteria, including FR-007 and FR-009 impact
- [ ] Kill criteria recorded before measurement, unmodified after
- [ ] GO/NO-GO recorded and signed off by the lead engineer; GO names one option and per-brain behaviour
- [ ] TG-08 interaction recorded as a change request to T-035/T-036 when applicable, with the exact encoder field
- [ ] No production code changed; no PII in fixtures or report
