# T-075: DialectCanonicalizer Implementation & Pipeline Composition

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** `DialectCanonicalizer` (the deterministic rule engine), `VariantTableSet` (the loader and `issues()` validator), the offset-mapping and abstain machinery, and the composition seam inside `IntentEncoderInterpreter`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-072](T-072-canonicalizer-rules-schema-design.md), [T-074](T-074-variant-table-authoring.md)
- **Blocks:** [T-077](T-077-canonicalization-losslessness-safety-verification.md), [T-079](T-079-tg10-loop-binding.md)
- **Requirements:** FR-005, FR-007, FR-008, NFR-013
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §4.1, §4.2, §4.5, §4.6; the shipped resource-loading pattern at `DialectBiasComposer.swift:113-170`

## Description

This task writes the layer. It is a pure, synchronous, non-throwing table lookup with mandatory provenance, plus four composition seams that must be exactly as the design specifies.

**1. `VariantTableSet` — the loader, adopting the shipped pattern.** `DialectLexicon.bundled(in:)` / `entry(for:)` / `issues()` (`DialectBiasComposer.swift:113-170`) is the template: decode from the bundle, validate structurally, and **fail closed** — `DialectBiasComposer.swift:111-112` states the principle for the lexicon (*"a structurally corrupt lexicon must not bias at all"*) and design D-4 transfers it verbatim. A table set with any issue returns a result with `degraded: true`, `applications: []` and `canonical == original`, byte-identical. Not a best-effort load of the valid entries, and not a partial application — the whole set passes through untouched. That property is testable and is T-077's first fixture.

**2. `DialectCanonicalizer.canonicalize` — the engine.** Five ordered stages (orthographic → misSegmentation → lexicalVariant → clippedForm → re-collapse), deterministic, with no I/O, no async boundary and no error path: the function never throws and every failure is a value. Each firing appends a `CanonicalVariantApplication` with `ruleID`, `tableID`, `dialect`, `kind`, both ranges and both surfaces. `applications` is empty iff `canonical == original` (design §4.5), so an unattributed rewrite is a bug and must be impossible by construction rather than by assertion where it can be avoided.

**3. Offset translation and the abstain rule.** Ranges are half-open UTF-16, matching the encoder's contract (`annotation_rules.yaml:96-104`). Each stage's applications are appended in canonical-offset order and translated forward through later stages, so a stage-1 application stays addressable after stage-3 rewrites shift its position. The map from a decoded span back to the original follows design §4.5's four cases — identity, exact containment, conservative widening, deletion union — and the **abstain rule** is the load-bearing one: a required span (`contact` for `call`/`send_message`, `time` for `set_reminder`) that maps with widening causes the interpreter to abstain, exactly as the encoder's F-4 abstains on an invalid span. This is the "calls the wrong person" hazard, and the rule is what makes the difference between a quality bug and a safety bug.

**4. The composition seams — four, and each is a place the implementation can go wrong quietly.**
- **After the sanitiser.** `InputSanitiser.sanitise(_:level: .quarantine)` runs first and the canonicalizer runs on its output. Canonicalizing before the clamp would let a table rewrite resurrect text the 200-character clamp had removed and would put a table lookup upstream of the injection defence.
- **Never through `NepaliTextNormalizer`.** Its punctuation and danda stripping is correct for a cache key and destructive for a model input — it would eat the word-boundary information O-6 needs.
- **The cache key is unchanged.** `IntentCommandCache` keeps `NepaliTextNormalizer.normalize`; re-keying would orphan every recorded entry and undo the write-after-confirmation discipline silently.
- **The stand-in gets the original.** On escalation the picker brain receives the original sanitised transcript, never the canonical one. Design §4.6 gives three reasons and the third is the operational one: it keeps the escalation path identical to today's, so T-071/T-078/T-078's comparison is a comparison of one change rather than two.

**5. The kill switch and the conservative arm.** `Policy.enabled` (default true) and `Policy.orthographicOnly` (default false). `orthographicOnly` exists so per-dialect tables can ship behind review without the layer being all-or-nothing, and T-077's A/B uses `enabled: false` as its control arm.

**6. `degraded` is surfaced, not swallowed.** A missing dialect table, an absent table set and a corrupt one are all non-fatal, all pass the transcript through, and all set `degraded` so the state is observable. The design's invariant 7 applies: there is no path where a canonicalizer defect produces *no* answer.

**What is not in this task.** No table content (T-074), no flip (T-076), no `IntentRouter` or `CommandRouter` edit, no new intent label or BIO tag, no change to the band constants, no learned component.

## Acceptance criteria

```gherkin
Feature: The canonicalizer is a deterministic, fail-closed, provenance-carrying table lookup

  Scenario: A structurally corrupt table set canonicalizes nothing
    Given a VariantTableSet whose issues() reports any Issue case
    When canonicalize is called
    Then canonical is byte-identical to the input
    And applications is empty
    And degraded is true
    And no partial application of the valid entries occurs

  Scenario: Every rewrite is attributed
    Given a transcript containing an attested variant
    When canonicalize fires a rule
    Then applications names the ruleID, tableID, kind and both ranges
    And applications is empty if and only if canonical equals the original
    And the firing order is orthographic, misSegmentation, lexicalVariant, clippedForm, re-collapse

  Scenario: The tables are selected without substitution across regions
    Given DialectLabel is eastern | doteli | default while T-062 may validate a wider inventory
    When the dialect is default, has no table, or the centroid table is degraded
    Then only the orthographic and pan-regional tables apply
    And another region's table is never substituted
    And the selection reason and any low-confidence marking are recorded in the result

  Scenario: Span mapping preserves the original and required spans abstain when widened
    Given a decoded encoder span satisfying canonical[start:end] == spanText
    When the span lies in an untouched region, is contained in one application, straddles boundaries, or overlaps a deletion
    Then it maps by identity, exact originalRange, conservative widening, or union of affected applications respectively
    And when a contact span for call/send_message or a time span for set_reminder maps with widening, the interpreter abstains rather than resolving

  Scenario: The four composition seams hold
    Given the interpreter's existing order: sanitise(.quarantine) then tokenize
    When the canonicalizer is composed in
    Then the sanitiser runs first and the canonicalizer runs on its output
    And the output is not routed through NepaliTextNormalizer
    And the IntentCommandCache key is unchanged
    And the stand-in on escalation receives the original sanitised transcript, not the canonical one

  Scenario: The kill switch and the conservative arm work per device
    Given Policy.enabled and Policy.orthographicOnly
    When enabled is false
    Then canonical equals the original with empty applications, and the recognizer behaves exactly as it did before the layer existed
    And when orthographicOnly is true only orthographic rules run, with the restriction visible in the result

  Scenario: Degraded states are observable and never fatal
    Given an absent table set, a dialect with no table, or a corrupt table
    When a turn is processed
    Then the transcript passes through unchanged and the turn still produces an answer
    And degraded is set and the reason is emitted as metadata only
    And no event, log line or manifest field contains an original or canonical surface form
```

## Implementation notes

- Read first: design §4.1 (the pipeline diagram and its three properties), §4.2 (the contract), §4.5 (the span invariant — the load-bearing section), §4.6 (the seams); `DialectBiasComposer.swift:101-170`; `InputSanitiser.swift:22`, `:42-44`; `NepaliTextNormalizer.swift` in full; `IntentEncoderInterpreter.swift` around the sanitiser call site; `annotation_rules.yaml:96-104`.
- The encoder's F-4 (`span_invalid`, `transcript[start:end] == text`) is the contract the abstain rule extends. Read the encoder design §7.2 and §12 before implementing the mapper: the clitic-trim precedent (*"The trimmed value is still a substring of the transcript, so it is still a span, not a resolution"*) is the reasoning to follow.
- Prefer implementation shapes that make the invariant impossible to violate: build the application list alongside the rewritten string rather than diffing afterwards, and derive `canonicalRange` from the string builder's own offsets rather than recomputing them.
- An empty `applications` with `canonical != original` must be unreachable. If the implementation cannot make it structurally impossible, assert it — but prefer the structural version.
- `degraded` must be a single value describing the table set's state for the turn, not a per-rule flag; per-rule detail belongs in the applications.
- Test the shape, not only the outcomes: a property test that `canonical == original` whenever the input contains no variant scalars catches a whole class of accidental rewrites that fixture tests miss.
- Unit tests live in the iOS test target. Per the project's iOS quirk, verify with `xcodebuild test` rather than `build` (the swift-syntax shims), and use `./build.sh` as the canonical entry point.
- No PII and no surface forms in any logged field. The rule id, the table id, the kind and the counts are the entire permitted vocabulary (design §6.6, NFR-016).
- If the tables are still `SEED-CANONICAL`-thin when this lands, ship with `orthographicOnly` as the default policy and say so — that is the honest state, and it is what makes T-077's A/B meaningful.

## Definition of done
- [ ] `VariantTableSet` loads from the bundle, validates via `issues()`, and fails closed on any issue
- [ ] `DialectCanonicalizer.canonicalize` implements the five ordered stages deterministically, with no I/O, no async boundary and no throwing path
- [ ] Every rewrite emits a `CanonicalVariantApplication`; `applications` is empty iff `canonical == original`
- [ ] Offset translation through later stages implemented, and the four-case span map returns to the original
- [ ] The required-span abstain rule implemented for `contact` (call/send_message) and `time` (set_reminder)
- [ ] Dialect selection falls back to orthographic + pan-regional and never substitutes another region's table
- [ ] The four seams verified: post-sanitiser, no `NepaliTextNormalizer` call, unchanged cache key, original transcript to the stand-in
- [ ] `Policy.enabled` and `Policy.orthographicOnly` implemented and per-device settable
- [ ] Degraded states pass the transcript through, still answer the turn, and emit reason metadata with no surface forms
- [ ] Tests pass under `xcodebuild test`; no `IntentRouter`, `CommandRouter` or band-constant change
