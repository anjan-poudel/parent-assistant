# T-074: Variant-Table Authoring & Native-Speaker Validation

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** The `Resources/VariantTables/*.json` content: the orthographic table, the pan-regional table, and one table per dialect in whichever inventory TG-11's `T-062` validates
- **Agent:** ml-engineer
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-072](T-072-canonicalizer-rules-schema-design.md), [T-062](../../TG-11-linguistic-robustness/T-062-dialect-inventory-review.md), [T-070](T-070-variant-coverage-measurement.md)
- **Blocks:** [T-075](T-075-canonicalizer-implementation.md), [T-079](T-079-tg10-loop-binding.md)
- **Requirements:** FR-005, FR-008, NFR-002
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §4.3, §4.3.1, §4.4 and §4.7; the shipped `Resources/DialectLexicon.json` seed content

## Description

T-070 measured which variants occur. T-072 fixed the schema. This task writes the rows, and it is where the evidence discipline either holds or evaporates.

**Authoring is downstream of measurement, never parallel to it.** Every entry in the orthographic table and every entry in the pan-regional table carries `evidence.source: "corpus"` with `occurrences ≥ 1` and the affected `rowIDs`, drawn from T-070's report. Every entry in a dialect table carries a source too: corpus rows if the corpus contains them, or `fixture`/`authored` with ≥ 2 cited examples that a native speaker has reviewed under TG-11's `T-062`. The validator (T-072's `issues()`) refuses the file otherwise, so the rule is not a convention — it is a precondition of the table loading at all.

**Where the rows come from.** The corpus rows are the evidence, but the *vocabulary* comes from: (a) the shipped `DialectLexicon.json` phrases, whose variant→canonical pairs the generation note already records (`गइछ`/`भइछ`/`खाइछ` → `गएछ`/`भएछ`/`खाएछ`; `भया` → `भयो`; `रह्याको` → `रहेको`; `भण्याको` → `भनेको`), and which are marked *"pending linguist review"* — this task is that review; (b) T-070's deviation scan, for the orthographic table; (c) the `elder_fragmented` register already in `annotation_rules.yaml:216`, for O-7 if T-072 admits it.

**The safety review is not a checklist item.** Before a table is committed, each candidate is tested against the frozen set of design §4.7: the 17 emergency phrases (`CommandRouter.swift:1468-1473`), the med-ack phrases and tokens (`:1519-1534`), the denial token list, and the negation class. A candidate that maps onto, or away from, any member of that set is **not** authored — and this is enforced twice over, at authoring time by `negationMarkerTouched` and at gate time by T-077. The canonical example is `नखाए` → `खाए`: it looks like a legacy-form repair and it converts a medication refusal into a medication acknowledgement.

**Prefer substitutions.** Design §4.5 makes a same-length substitution exact under span mapping and a length-changing rule a potential abstention. Authoring therefore prefers a substitution wherever one exists in the attested forms, and where only a length-changing rule is attested, the entry records it and T-070's collision measurement says how often it fires on rows carrying a `contact` or `time` span. That is the abstain cost, visible at authoring time.

**The negative result must be writable.** If T-070 finds that the dialect half of the surface is thin — a handful of attested phrases over 8 000 rows — then the dialect tables are thin, and the honest artifact is a small table plus a recorded coverage figure, not a table padded with plausible regional words. Design R-5 and D-8 exist for exactly this. A dialect with three attested entries gets three entries and a note.

**`DialectCentroids.json` and `DialectLexicon.json` are not edited.** Design §10 puts their content out of scope: they are consumed as-is, `SEED` status, empty prompts. Their phrases are a *source of candidates* for this task, not an object of it.

## Acceptance criteria

```gherkin
Feature: Variant tables are authored from measured evidence, not from plausible vocabulary

  Scenario: Every authored entry is sourced
    Given the pinned corpus at revision 7f71b8ae and T-070's per-variant measurements
    When a table is authored
    Then every corpus-sourced entry carries occurrences >= 1, a corpusRevision, and its rowIDs
    And every fixture- or authored-sourced entry carries at least two cited examples reviewed under T-062
    And the file fails validation and is not committed if any entry is unsourced

  Scenario: The frozen safety set is checked before commit
    Given the 17 emergency phrases, the med-ack phrases and tokens, the denial tokens, and the negation class
    When a candidate variant or its canonical target intersects that set
    Then the candidate is not authored and the reason is recorded
    And a deliberately unsafe candidate (नखाए -> खाए) is present in the task's own test set and is refused by negationMarkerTouched
    And no entry in any committed table rewrites a polarity or negation marker

  Scenario: Substitutions are preferred and length-changing rules carry their cost
    Given the span-mapping and abstain rules of design §4.5
    When an entry is authored
    Then a length-preserving substitution is preferred wherever the attested forms permit one
    And any length-changing entry records how often it fires on corpus rows carrying a contact or time span
    And the abstain cost is stated in the authoring notes rather than discovered at runtime

  Scenario: A thin dialect is authored thin
    Given T-070's coverage figures per dialect slice
    When a dialect has few attested variants
    Then its table contains only the attested entries
    And the coverage gap is recorded in the group's evidence pack with the slice named
    And no entry is added to make the table look more complete

  Scenario: Orthographic rules are authored only where attested
    Given the O-1..O-7 rule set of design §4.4
    When the orthographic table is authored
    Then O-1 (NFC) and O-5 (digit folding) are unconditional, matching the shipped normalizer's behaviour
    And O-2, O-3 and O-4 are table-driven pairs with evidence, not inferred rules
    And O-6's mis-segmentation pairs never join or split a token intersecting the frozen set
    And O-7 is authored only if T-072 admitted it, and is flagged rather than silent

  Scenario: The seed resources are consumed, not modified
    Given DialectLexicon.json and DialectCentroids.json at SEED status
    When the tables are authored
    Then neither file is modified
    And their phrases are cited as candidate sources with the pending-review status recorded
    And the new tables live under Resources/VariantTables/ with their own formatVersion and generation block
```

## Implementation notes

- Read first: design §4.3 (schema and fallback), §4.3.1 (the sourcing rule), §4.4 (O-1…O-7), §4.7 (the frozen set and the invariant); `Resources/DialectLexicon.json` (the variant→canonical pairs in its generation note); `annotation_rules.yaml:216` (register values); `T-062:16`, `:24` (the inventory hypothesis and the `clipped` question).
- The native-speaker review is TG-11's `T-062`'s review, not a second, parallel one. Do not commission a separate linguistic review; coordinate so one reviewer sees both the dialect inventory and these tables. Two reviews of the same language produce two vocabularies.
- Never author a rule whose justification is "this word looks dialectal". The test is: which corpus rows contain it, or which two attested examples support it. A rule that cannot answer either question is the thing this task exists to prevent.
- The `script` slices (devanagari 5 508 / latin 1 678 / code_switched 814) matter for authoring: a variant attested only in the `latin` slice is a romanized form, and romanization is explicitly refused (§5). Record such candidates as refused-by-scope rather than authoring a transliteration table.
- O-6 is the highest-risk rule. Read `CommandRouter.swift:607-620` (the WhisperKit join behaviour, pinned rev `ea872ffd`) before writing any mis-segmentation pair, and treat "never joins across a frozen negation marker" as a hard constraint, not a guideline.
- The tables are content. A reader must be able to open `canonical-eastern.json`, see `occurrences: 34` and the row ids, and check the claim — that is the whole point of D-2 and D-3. If an entry cannot survive that reading, it does not belong in the file.
- 8 000 rows is the whole evidence base. Do not claim coverage the corpus does not support, and do not treat the generated rows (line 190 onward) as evidence about Nepali speech — T-070's hand/generated split is the discriminator, and it is cited per entry.
- No real utterance or contact name appears in any table, test or note. The corpus is synthetic; the tables must be too (NFR-016).

## Definition of done
- [ ] `Resources/VariantTables/` populated: orthographic (pan-regional), pan-regional, and one table per dialect in T-062's validated inventory
- [ ] Every entry carries a validated `evidence` block; unsourced entries cannot load
- [ ] The frozen-safety-set check run over every candidate, with refusals recorded individually
- [ ] The deliberately unsafe `नखाए` → `खाए` candidate present in the task's test set and refused
- [ ] Length-changing entries annotated with the measured frequency of firing on `contact`/`time`-bearing rows
- [ ] Thin dialects authored thin, with the coverage gap recorded per slice
- [ ] Native-speaker review recorded against T-062's reviewer, not a parallel one
- [ ] `DialectLexicon.json` and `DialectCentroids.json` unmodified
- [ ] No PII, no real content, no transliteration table
