# T-094: Prompt Clause + Seed Mirror + Build Gate (C06, C08)

## Metadata
- **Group:** [TG-15 — Personalization Paths: Prompt Clause, Seed Mirror, Wake Ack](index.md)
- **Component:** C06 — `InterpreterContext.addressAs`, `IntentPrompt.addressAsClause`; C08 — seed, renderer, mirror gate
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-091](../TG-14-profile-foundations/T-091-profile-prompt-guard-and-personalization.md), [T-092](../TG-14-profile-foundations/T-092-coordinator-profile-seams.md)
- **Blocks:** —
- **Requirements:** FR-PI-009, FR-PI-010 · NFR-PI-005 · Feature Constraint 2 · AM-1 · SD-1 · evidence obligations 1, 2, 3 (clause half)

## Description

Lands the seed, the Swift template and the mirror gate as one indivisible unit: the `" Address them as \"\(term)\" where it fits, never every sentence."` clause at its three exact anchors (`build`, `buildChat`, `buildUnderstanding`), the seed's `{address_as_clause}` placeholder at the matching position, the renderer's defaulted parameter, and the new build-blocking `ios/tools/check-prompt-mirror.sh` + `.py` invoked from `ios/build.sh` before every test scope. The gate's first run fixes the recorded one-byte trailing-newline drift (seed 2,699 ends `request.\n\n` vs template 2,698) — net 2,716 bytes after the fix. The explicit `InterpreterContext` initializer keeps `addressAs` immutable with a defaulted parameter, so every existing call site compiles unchanged.

## Acceptance criteria

```gherkin
Feature: Prompt clause, seed mirror and gate

  Scenario: No-term composition is byte-identical to today
    Given a context whose guarded term is nil, and one whose term is empty
    When build, buildChat and buildUnderstanding compose
    Then the clause is the empty string in all three
    And the composed build output matches the pinned digest of the pre-feature baseline

  Scenario: The clause appears once at its exact anchor in each builder
    Given a context with a benign term
    When each builder composes
    Then the clause is appended directly after the pinning sentence at the anchor settled in the design (one per builder, no other insertion point)

  Scenario: Worst-case composition stays inside the pinned ceiling
    Given a 24-grapheme term at the composition bound
    When build composes
    Then the result is 2,586 Characters or fewer, within the 3,000 ceiling
    And the fixture comment states the measured base of 2,506 so the next trim starts from truth

  Scenario: In-table marker terms compose the un-personalized baseline
    Given a term that trips the shared marker table
    When the turn's context is built through the read seam
    Then the composed prompt is byte-identical to the digest baseline (AM-1, obligation 1)

  Scenario: Out-of-table instruction-shaped terms stay quoted data with unchanged routing
    Given the requirement's own example payload and a Nepali instruction-shaped term
    When a fixed utterance is routed with the hostile term present versus absent
    Then the routing decision is unchanged between the two runs, no action triggers, and no profile write is reachable through prompt output (AM-1, SD-1, obligation 2)
    And the composed prompt differs from the baseline only by the clause carrying the bounded term

  Scenario: The mirror gate fails loudly on any drift
    Given a byte flipped in the seed, a removed placeholder, or an altered template literal
    When the gate runs
    Then it exits non-zero with a diff excerpt or a named failure, never a silent pass
    Given a missing or duplicated interpolation anchor in the Swift template
    Then extraction or anchor validation fails the gate loudly as well
```

## Implementation notes

- One unit: the template edit, the seed edit, the renderer default (`render_prompt(..., address_as_clause: String = "")`), and the gate land together — a partial landing breaks byte equality by construction.
- Gate shape mirrors `tools/check-release-log-safety.sh`: a `.sh` wrapper calling `.py`, wired into `ios/build.sh` beside the existing log-safety call, before every test scope. Extraction follows Swift multiline-literal semantics: dedent by the closing delimiter's indentation and drop exactly one trailing newline; the four interpolation sources map to `{language_hint}`, `{medications}`, `{transcript}`, `{address_as_clause}`.
- The digest pin and the ceiling test extend `IntentPromptTests`; both construction sites (the router and the coordinator's collapse provider) pass `addressAs: profilePersonalization?.addressAsForPrompt` — the only edits outside `IntentPrompt.swift`, and no downstream call site changes.
- AM-1 rests here for the routing half: the A/B assertion for the split fixtures is a clause test (same fixed utterance, term absent versus hostile present, routing decision compared). Reference the containment statement in the guard's documentation (T-091) rather than restating policy.
- The renderer's default keeps the no-term training corpus bytes identical to the pre-feature render — assert this directly in the renderer's test, not only through the gate.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (extended `IntentPromptTests`; initial `check-prompt-mirror` test invocation)
- [ ] The gate's negative path is exercised in CI (a deliberately drifted fixture run proves the non-zero exit)
- [ ] Evidence (obligation 1, clause half): un-personalized digest equality recorded for the marker fixture
- [ ] Evidence (obligation 2, clause half): A/B routing assertion recorded for both out-of-table fixtures
- [ ] Evidence (obligation 3, clause half): the 24-grapheme worst case measured inside the pinned ceiling
- [ ] AM-1 statement present (guard doc referenced, split fixtures named); the one-byte drift fix and the net 2,716-byte seed recorded in the PR
- [ ] `ios/build.sh` passes with the new gate active
