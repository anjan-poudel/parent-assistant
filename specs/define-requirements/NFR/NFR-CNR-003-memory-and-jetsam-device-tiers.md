# NFR-CNR-003: Memory and jetsam behaviour — one brain resident, zero feature-attributable terminations

## Metadata
- **Category:** Reliability / Resource Behaviour
- **Priority:** MUST
- **Source:** Proposal §4 (the 1.7B default and the 4B-for-newer-devices tiering; "fewer tokens per Nepali sentence leaves budget inside the 1,024-token ceiling") and §7 risks (latency/memory mitigation: 1.7B target, 4B only via the resolver); feature constitution "Single-decode integrity and catalog swap" property 3 (device tiers) and "Prompt/seed discipline" property 2 (the pinned 1,024-token on-device budget); project constitution Architecture Constraint 4 (24/7 safety service — the assistant must remain reliably available) and Safety-critical constraints (the emergency path must not be blocked by the LLM being busy or unavailable). Reference device: Anzaan.

## Description
The feature **must not** increase model residency or provoke system terminations on any supported device tier. The requirements are counted, not estimated:

- **Exactly one brain model resident at a time** on a device — the chat variant replaces the served model in the swap (FR-CNR-022); the feature introduces **no second resident model**, no additional model instance for chat, and no dual-tier configuration.
- **Zero feature-attributable jetsam terminations**: during the DV session (FR-CNR-025), which exercises local chat, cloud chat, degradation, emergency phrasing and commands, the app records **0** terminations in which the feature's chat path is the memory driver.
- **No growth in the decode working set**: the chat path's context stays within the existing pinned budget (NFR-CNR-004) and adds no additional KV/context allocation beyond what the existing single-decode chat turn already uses.
- **Tier admission is memory-gated**: the larger tier (FR-CNR-028) is admitted only on a device class where the resident footprint holds without reaching the jetsam threshold; a tier that cannot hold it is not admitted.
- **Degradation under pressure is honest**: if memory pressure does occur, the chat path degrades (local or safe template) rather than terminating the app or a safety-critical flow (the emergency path is never blocked — FR-CNR-014).

## Acceptance criteria

```gherkin
Feature: Memory residency and jetsam behaviour are counted and clean

  Scenario: One brain model is resident during a chat session
    Given a device running the shipped chat variant
    When a chat session is exercised
    Then exactly one brain model instance is resident
    And no second chat model is loaded

  Scenario: The DV session records no feature-attributable termination
    Given the DV session on the reference device (local chat, cloud chat, degradation, emergency phrasing, commands)
    When the session is reviewed
    Then the app recorded 0 terminations attributable to the chat path's memory use

  Scenario: A tier exceeds the memory envelope (failure)
    Given a device class where the candidate tier's resident footprint reaches the terminations threshold
    When tier admission is considered
    Then the tier is not admitted
    And the limitation is recorded (FR-CNR-024)
```

## Related
- FR: FR-CNR-008 (degradation), FR-CNR-014 (safety path never blocked), FR-CNR-022 (residency via the swap), FR-CNR-025 (DV evidence), FR-CNR-028 (tier admission)
- NFR: NFR-CNR-002 (latency), NFR-CNR-004 (context budget)
