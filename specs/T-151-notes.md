# T-151 — FamilyContactIndex: implementation notes

Unit: `TG-30/T-151-family-contact-index`
Feature: `family-contacts-unify` · Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`)
Commit: the T-151 unit commit on `feat/family-contacts-unify` carrying this notes file plus the new source file, the new test suite and the regenerated `seniOS.xcodeproj/project.pbxproj` (not pushed).
Date: 2026-10-12 · **Speed mode** (parent directive): implement + whole-module typecheck + commit only — the scoped suite run and per-unit review are deferred to the phase-end gate.

## What was built

### 1. `ios/ElderlyAssistant/Services/Contacts/FamilyContactIndex.swift` (new, pure value type)

Exactly the design interface (design-l1 §5.4, design-l2 §1.2/§8.2):
`struct FamilyContactIndex: Equatable` with `Entry { id, normalizedName, normalizedNicknames, rawNicknames }`,
`private(set) var entries`, `private(set) var idsByNickname: [String: [UUID]]`,
`init(family: [FamilyContact])`, `static let empty`, `nicknameEntries(for:)`,
`exactNicknameHolders(_:)`, `entry(for:)`.

Recorded implementation decisions (all internal, none widens the published surface):

1. **`entry(for:)` is backed by a private `entriesByID: [UUID: Entry]` map** — the design calls it the resolver hot path (design-l2 §1.2) and the unit's whole point is the perf ceilings (NFR-FCU-001); a dictionary hit keeps it O(1) instead of a scan that would degrade as the roster grows. The map is exactly derivable from `entries`, built in `init`, never mutated; the two published stored properties are exactly the design's.
2. **Empty normalized keys are never indexed.** A spelling that normalizes to `""` (punctuation-only, e.g. `।।`) would otherwise make an empty query "match" its holders; today's search treats an empty query as no query (`familyMatches` guards it), so the index never creates that key. The spelling itself is still stored verbatim in `rawNicknames` (containment parity).
3. **One id at most once per key.** Duplicates across contacts are preserved in roster order (`idsByNickname` is multi-valued — no silent overwrite, the T-152/T-153 ambiguity is representable); a *single* contact listing the same spelling twice does not duplicate its own id in the holders list (downstream reads "holders", not "mentions").
4. **`FamilyContact.normalizedNicknames` is re-applied at build time** (idempotent for stored data — decoder and editor already trim). Belt-and-braces against a directly-constructed model smuggling an untrimmed spelling into a key containment could never match.
5. **Normalization is `NepaliTextNormalizer.normalize` only** — no new grapheme/transliteration logic (NFR-FCU-007 pin; OD-2 "store as entered" keeps `सानु` ≠ `sanu`).
6. **No logging at all** in the type — the "no PII in logs" requirement is satisfied vacuously (there is no log call site).

### 2. `ios/ElderlyAssistantTests/Services/Contacts/FamilyContactIndexTests.swift` (new, 17 tests)

| Task Gherkin / requirement | Test |
|---|---|
| Nickname lookup resolves O(1) via `idsByNickname` | `testExactNicknameLookupIsTheMapHitAndNotAScan` (map and method answer identically; stored spelling kept verbatim) |
| (caller contract the per-keystroke design rests on, design-l2 §6.1) | `testExactLookupTakesThePreNormalizedKeyNotTheRawQuery` (query normalized ONCE at the call site; a raw query is a miss, deliberately) |
| Perf ceilings at 12 contacts × 8 nicknames — build | `testMaxRosterBuildStaysUnderTheTwentyMillisecondCeiling` (worst of 5 builds ≤ 20 ms; 96 distinct keys; roster order asserted) |
| Perf ceilings — lookup ≤ 20 ms per query | `testNicknameLookupStaysUnderTheTwentyMillisecondCeilingPerQuery` (97 individually-timed queries: 96 hits + one 256-char miss) |
| Long-string worst case (F5, 256 chars) | `testLongStringWorstCaseEntryStaysWithinTheCeilings` (256-Character nickname AND 256-Character name; build worst-of-5 and query worst-of-20 both ≤ 20 ms; fixture guards assert 256 exactly) |
| Devanagari positive pin | `testDevanagariExactMatchIsThePositivePin` (`आमा`; `ज्यू` = ONE Character from four scalars — never split) |
| Devanagari negative pin (NFR-FCU-007, deliberate) | `testDevanagariPartialWordSubstringDoesNotMatchTheNegativePin` (`छोर` does not match `छोरी` in the precomputed strings, with the same `range(of:options:)` call the containment tier uses; full word matches — positive control; partial word is not a map key) |
| (NFC rationale — STT composition variance) | `testCanonicallyEquivalentSpellingsOfOneWordShareTheKey` (U+0958 vs `क`+nukta: canonically equivalent, NFC deliberately does NOT compose, one key) |
| Duplicate nickname on two contacts (failure path 1) | `testDuplicateNicknameOnTwoContactsKeepsBothIDsInRosterOrder` (both ids; reversed roster answers reversed — roster order is the contract) |
| Duplicates preserved (assignment) | `testRepeatedSpellingOnOneContactKeepsOneIDAndAllSpellings` |
| Rebuild after store change (failure path 2) | `testRebuildAfterStoreChangeDropsStaleIDsWithNoTornReads` (stale ids absent; the pre-rebuild value still answers its own snapshot — no torn reads) |
| Empty-index parity with today's behaviour | `testEmptyIndexReproducesTodaysNameOnlyAnchor`, `testRosterWithoutNicknamesDegeneratesToNameOnlyIndex` (no synthetic keys; names live on entries for the `.exactName` tier) |
| Roster order + raw spellings + value semantics | `testEntriesPreserveRosterOrderAndStoredSpellings` |
| Blank/punctuation-only spellings | `testBlankAndPunctuationOnlySpellingsNeverBecomeKeys` |
| Legacy `nickname` field feeds the index (FR-FCU-011/012 seam) | `testIndexBuiltFromALegacyNicknameFieldResolvesTheMigratedValue` (raw legacy JSON → production decoder → index → lookup hit) |
| Unknown ids / keys | `testLookupsForUnknownIDsAreEmpty` |

Perf assertions are worst-case (every measured iteration asserted, plus the max printed to the test output — durations only, never fixture text), per the task's F5 note and design-l2 §6.1 ("measured values are logged into the test output").

### 3. Deliberately NOT done (other units own these)

- No wiring into `AppCoordinator` (`@Published familyIndex`, rebuild on roster mutation) — T-156.
- No changes to `UnifiedContactSearch` tiers (`familyMatches(query:family:index:)`, `.nickname` tier, substring pass) — T-152.
- No `ContactResolver` provider/bands — T-153.

## Gate results

- **Whole-module typecheck**: `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant -destination "platform=iOS Simulator,id=14AE2228-…" -derivedDataPath build/DerivedDataTests` (Debug, simulator) — **TEST BUILD SUCCEEDED, 0 errors**; this compiles the app module AND the test bundle, so the new suite provably compiles with the rest of the target.
- `seniOS.xcodeproj` was regenerated (`xcodegen generate`) so both new files are in their targets; the generated diff also carries the concurrently-added `ContactsAccessTests.swift` reference (another agent's unit in this shared worktree — generated content, committed as-is so the project file stays consistent for everyone).
- **Scoped suite DEFERRED** per the speed-mode directive — the tests exist and compile; `./build.sh test:unit FamilyContactIndexTests` is a phase-end gate item.
- Coverage measured: not applicable in this mode; the 17 tests exercise every branch of `init` (empty roster, no nicknames, punctuation-only key skip, repeated spelling, duplicate holders, multi-nickname alignment) and all three lookups including their miss paths.

## Decisions made during implementation (log)

1. Private `entriesByID` added (see §1.1) — the only deviation from the design's literal two-stored-property shape; not part of the published surface, deterministic, and it makes the "hot path" claim true at any roster size.
2. Empty-key skip and per-contact holder dedupe (see §1.2/§1.3) — both chosen so an empty/duplicate input cannot produce a downstream lie (everyone-matches / same-contact-twice); neither is observable for well-formed stored data, both are pinned by tests.
3. The negative Devanagari pin is asserted over the index's *precomputed strings* (the index itself has no substring API by design); the test uses the exact `range(of:options:)` call the containment tier runs today, so the pin sits at the level T-151 owns without testing T-152's unwritten code.
4. Legacy-migration seam test decodes the raw legacy JSON directly through `FamilyContact`'s production decoder (the store's read IS this decode) — avoids duplicating `FamilyContactStoreTests`' storage scaffolding in a Contacts-suite.

## Handoff / open items

1. **T-152** consumes: `.exactName` compares `entry.normalizedName` (no per-call normalization); `.nickname` exact = one `exactNicknameHolders(NepaliTextNormalizer.normalize(query))`; `.nickname` substring = `range(of:options:[.caseInsensitive, .diacriticInsensitive])` over `entry.normalizedNicknames` (raw spellings for the containment tier are in `entry.rawNicknames`).
2. **T-153** consumes `entry(for:)` (O(1) per contact) and `nicknameEntries(for:)` for the near-miss walk.
3. **T-156** must republish `familyIndex` wholesale inside every roster mutation path (launch batch load included) — because the rebuild derives only from the roster snapshot, drift is impossible by construction.
4. Phase-end gate items: run `FamilyContactIndexTests` (scoped) and record the printed ms values; per-unit review.

## Files changed

```
ios/ElderlyAssistant/Services/Contacts/FamilyContactIndex.swift         (NEW, 145 lines)
ios/ElderlyAssistantTests/Services/Contacts/FamilyContactIndexTests.swift (NEW, 449 lines)
ios/seniOS.xcodeproj/project.pbxproj                                    (regenerated — +8 lines: both new files in their targets)
specs/T-151-notes.md                                                    (this file)
```
