# FR-MTC-006: Deterministic frame merge and execution

## Metadata
- **Area:** Answer Merge / Execution
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Deterministic frame merge — sanitise the answer through the existing input seam (STT-error corrector + dialect canonicalizer), strip answer scaffolding, canonicalise via the catalog when it matches (else keep the free text), merge into `activeCommand`, dispatch through the normal executor (`runMusicTurn`)" and Feature Constraint 4 ("Deterministic merge works with the brain absent or degraded"); feasibility study §6.3.3 (steps) and §7 Phase 1 ("covers the owner's bhajan example end-to-end without any training run"); worktree surfaces verified: input seam (`Services/Intents/LocalBrainChain.swift` `turnInput`, `InputSanitiser.sanitise(_:level:.quarantine)`), dispatch entry `runMusicTurn` (`CommandRouter.swift:2684`).

## Description
On a captured answer, the system **must** merge it into the pending command and execute — deterministically, with no model involvement in Phase 1:

1. **Sanitise through the existing input seam** — the captured transcript passes through the same `InputSanitiser`-led seam (STT-error corrector + dialect canonicalizer) every turn uses, before any use.
2. **Strip answer scaffolding** — verb/probe words added to the answer are removed ("दशैं दुर्गा भजन" → query value `"dasain durga bhajan"`; a bare index-word answer resolves to the option it names).
3. **Canonicalise via the curated catalog when it matches** — e.g. दुर्गा → the canonical search query "durga bhajan" (FR-MTC-015); when the answer matches no catalog entry, the free text itself is kept as the value. Never reject, never invent.
4. **Merge into `activeCommand`** — the answer fills the missing slot (music: the query) on the pending command; the command's other properties are unchanged.
5. **Dispatch through the normal executor** — the merged command runs through the existing path (`fireMusicRequest` → `runMusicTurn`), so pre-ack, the Spotify/YouTube outcome matrix, and honest outcomes behave exactly as for a directly-spoken command (NFR-MTC-012).

The owner's acceptance anchor: "play bhajans" → probe → "dasain durga bhajans" → correct playback of dasain durga bhajans — end-to-end, with no training run. The merge must work with the brain absent or degraded (NFR-MTC-005); the optional brain-assisted resolution is Phase 2 (FR-MTC-018) and never a Phase 1 dependency.

## Acceptance criteria

```gherkin
Feature: Deterministic frame merge

  Scenario: The owner's bhajan example works end-to-end with no training run
    Given the user said "play bhajans" and heard the kind-of-bhajan probe
    When the user answers "dasain durga bhajans"
    Then the answer is sanitised, scaffolding-stripped and merged into the pending music command as the query
    And playback of dasain durga bhajans starts through the normal music path
    And no model or training artifact was required

  Scenario: A catalog-matching answer canonicalises to the canonical query
    Given the probe asked for the kind of bhajan
    When the user answers "दुर्गा"
    Then the merged query is the catalog's canonical form ("durga bhajan")
    And execution proceeds through the normal music path

  Scenario: A free-form answer merges as spoken, without catalog membership
    Given the probe asked for the kind of bhajan
    When the user answers "दशैं दुर्गा भजन"
    Then the merged query preserves the sanitised free text
    And execution proceeds through the normal music path

  Scenario: The merge survives with the brain absent
    Given the brain is not loaded (or was pressure-evicted)
    When the user answers the probe
    Then the deterministic merge produces the same merged command
    And execution proceeds through the normal music path
```

## Related
- FR: FR-MTC-005 (capture forms), FR-MTC-015 (catalog), FR-MTC-018 (Phase 2 brain-assisted merge, optional)
- NFR: NFR-MTC-005 (degraded-brain path), NFR-MTC-008 (sanitisation discipline), NFR-MTC-012 (execution paths unchanged)
