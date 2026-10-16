# T-129 notes — `dialogue.*` localisation inventory (17 keys)

- **Task:** `specs/plan-tasks/tasks/TG-24-dialogue-frame-foundations/T-129-dialogue-localisation-keys.md`
- **Worktree / branch:** `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`, `feat/multi-turn-conversation`
  (notes written without git access — the unit's constraints forbid git commands, so no HEAD is recorded)
- **Status:** complete — all three Gherkin scenarios covered; focused gate green (10/10, evidence below)
- **Date:** 2026-10-10

## Deliverables

| # | File | Kind |
|---|---|---|
| 1 | `ios/ElderlyAssistant/Resources/Localizable.xcstrings` | CHANGED — the 17 `dialogue.*` entries, ne+en |
| 2 | `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift` | CHANGED — dialogue-family coverage (7 new tests + fixture gate) |
| 3 | `specs/T-129-notes.md` | this file |

No production Swift changed, no other unit's file touched, no existing spec/plan/design
artifact edited. The catalog edit was scripted (verbatim copy extracted from design-l2 §16)
and validated: the file parses, the non-dialogue entries are byte-identical
(`old_other == new_other`), and every value is the §16 draft verbatim.

## Key inventory and counts

- **Before:** 1,364 keys, zero `dialogue.*` entries. Independently measured on the branch
  point (master checkout `Localizable.xcstrings`: 1,364, zero `dialogue.*`).
- **After:** 1,381 — delta **exactly 17**.
- The 17 entries sit as one contiguous alphabetical block between their neighbours
  `common.emergency` and `directions.cancelled`.
- `dialogue.timeout` is absent (C-4): the design lists it only to declare it missing, and
  the expiry path speaks nothing by construction.

## Scenarios → tests

**Scenario 1 — All dialogue keys exist in both languages (exactly 17).**

- `testTheDialogueFamilyPassesTheCoverageCheck` — the source half: the `dialogue.*` family
  equals the pinned 17-key inventory exactly (no stray, none missing), each entry `manual`
  with both string units `translated`; total pinned at 1,364 + 17; the alphabetical
  neighbours' copy is re-asserted so a clobbered insertion would move.
- `testEveryDialogueKeyResolvesInBothLanguages` — the behavioural half: every key resolves
  through `L10n.str` in `en-US` and `ne-NP` to non-empty, non-identical copy, and the Nepali
  resolution is Devanagari (NFR-MTC-009).
- `testTheDialogueCopyMatchesTheDesignDraftVerbatim` — the DoD pin: all 17 en+ne values are
  the design-l2 §16 draft copy byte-for-byte (so the owner copy review changes this table
  deliberately).
- `testTheDialoguePlaceholdersMatchBetweenLanguages` — `%@` counts agree between languages
  for the five formatted keys (and trivially for the rest).
- `testTheDialogueFamilySitsAlphabeticallyAndContiguouslyInTheFile` — the implementation
  note: the raw file's key lines carry the family as one contiguous sorted block between
  `common.emergency` and `directions.cancelled`.

**Scenario 2 — The silent timeout is not a string.**

- `testTheDialogueFamilyHasNoTimeoutEntry` — `dialogue.timeout` absent from the family and
  from the pinned inventory; no family key carries "timeout"; and a fixture that grows such
  an entry is rejected by the coverage check. (The timeout *path* staying silent is T-135's
  `testSlotAnswerTimeoutIsSilent`; this unit pins that no key exists for it.)

**Scenario 3 — A missing translation fails the gate.**

- `testTheCoverageCheckFailsNamingTheMissingDialogueValue` — five fixtures, each a mutated
  copy of the parsed catalog: (1) the `ne` localization removed → fails naming
  `dialogue.retry`; (2) whole entry removed → `dialogue.exhausted`; (3) blank `ne` value →
  `dialogue.escape`; (4) the en copy pasted into `ne` → `dialogue.cancelled`; (5) a stray
  `dialogue.*` key → `dialogue.stray`. The coverage check is a pure function over parsed
  catalog data, so these run without touching the shipped file.

## Evidence runs

**Locked focused run** (worktree `ios/`, serialized behind `/tmp/mtc-w1-build.lock`):

```
./build.sh test:unit L10nCatalogCoverageTests
```

Result: **`Executed 10 tests, with 0 failures (0 unexpected)` — `** TEST SUCCEEDED **`**
(the 7 new dialogue tests all pass, plus the 3 pre-existing interview tests — no
regression in the suite this unit extends).

**Blocked window (recorded, not a defect of this unit).** Retries 1–9 (14:31–15:26) failed
with `Cannot find type 'DialogueMerge' in scope` /
`Type 'DialogueFrameResolution' does not conform to protocol 'Equatable'` — the shared
worktree's app target carried T-125's forward reference to T-131's type (a W2 unit, not yet
landed). Per the unit protocol the break was retried, never fixed; attempt 10 (15:32) ran
green once the tree compiled. Nothing in this unit's diff can produce a Swift type error
(one JSON resource + one test file).

**Independent catalog check (substitute for the blocked window, kept as evidence).**
`xcrun xcstringstool compile` (Xcode's own String Catalog compiler) on the edited file for
`en` and `ne`: compiles clean; both compiled tables carry exactly the 17 keys; every
compiled value equals the design-l2 §16 draft; `dialogue.timeout` absent; no ASCII letters
in any `ne` value.

**Pre-flight.** Every assertion was also executed as a Python port against the real catalog
(zero failures, count 1,381) and against the six fixture mutations (each named the expected
key), and the test file's Swift idioms were type-checked in isolation.

## DoD checklist

- [x] **All Gherkin scenarios covered by automated tests (`L10nCatalogCoverageTests`
      extended).** 7 new tests; scenario mapping above.
- [x] **Exactly 17 new keys; every value draft-copied from design-l2 §16 in both
      languages.** Count pinned (1,364 + 17 = 1,381, family equality). Copy pinned verbatim;
      the values were extracted from the §16 table programmatically, not retyped.
- [x] **Focused suite green: `L10nCatalogCoverageTests`; no new full-suite failures.**
      Focused run: 10/10 green, `** TEST SUCCEEDED **`. No other suite's assertions are
      affected by a key insertion except the Spotify inventory's *stale* total-count pin —
      pre-existing, recorded below — which failed identically before this change.
- [ ] **Code reviewed and merged** — workflow action, not this unit's (no merges in the
      dev step; no git commands permitted in this worktree).

## Decisions, deviations and open items

1. **Notes file convention.** `specs/T-129-notes.md` is added per the repo's unit-notes
   convention (`specs/T-107-notes.md` … `specs/T-124-notes.md`). No design/plan/spec
   artifact was modified.
2. **The Spotify catalogue-total pin is stale at the branch point (pre-existing).**
   `SpotifyLocalizationTests.testTheCatalogParsesAndKeepsTheBaselineInstrumentation`
   asserts `catalog.count == 1341 + 20 = 1361`, but the branch-point catalog already had
   **1,364** keys (3 keys added by later features without updating that pin). It is
   therefore red on the branch before this change and stays red after (1,381) with the same
   assertion — the same failure, not a new one. Untouched here (out of this unit's scope);
   flagged for the wave that owns that suite.
3. **design-l2 §16 prose still says "16 new keys"** (and §7's component row, and the
   NFR-MTC-006 row). C-4 (review-l2) is the correction to 17 — the fix instruction targets
   the design document; this unit implements the corrected 17 and did not edit `specs/`.
4. **Copy review remains an owner action.** The §16 draft ships verbatim; the verbatim pin
   in the coverage suite makes any later wording change a deliberate edit.
5. **Index words are not in this inventory.** NFR-MTC-006 names the index words
   ("पहिलो"/"first" …); design-l2 §16 carries no catalog keys for them — they are answer
   vocabulary (`DialogueAnswerPath`, W2), recorded here so the omission is not silent.
6. **Parallel-proofing.** The catalog count pin assumes T-129 is the only unit adding
   `dialogue.*` keys (verified: no other task file in the plan touches
   `Localizable.xcstrings`). If another unit concurrently adds unrelated catalog keys, the
   total-pin test will fail loudly and needs a one-line baseline update — the pin is
   intentionally exact, matching the Spotify suite's precedent.
