# T-153 — ContactResolver nickname bands: implementation notes

Unit: `TG-30/T-153-contact-resolver-bands`
Feature: `family-contacts-unify` · Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`)
Commit: the T-153 unit commit on `feat/family-contacts-unify` carrying this notes file plus the resolver change and the extended test suite (not pushed).
Date: 2026-10-12 · **Speed mode** (parent directive): implement + whole-module typecheck + commit only — the scoped suite run and per-unit review are deferred to the phase-end gate.

## What was built

### 1. `ios/ElderlyAssistant/Services/Intents/ContactResolver.swift` (extended)

Exactly the design interface (design-l1 §8.3, design-l2 §1.7, §8.2):

- **init**: `init(contactsProvider:indexProvider:)` with `indexProvider: (() -> FamilyContactIndex)? = nil`.
  `nil` ⇒ one `FamilyContactIndex(family: contactsProvider())` build per call — the test-parity path
  (identical strings by construction: it runs exactly the projection the real index runs). Source-compatible:
  the existing trailing-closure call site in `AppCoordinator` (`ContactResolver { [weak self] in … }`)
  compiles unchanged (verified by the whole-module build).
- **Band ladder** in `score(_:against:forms:)`, strongest first — exact name 1.00 (index `normalizedName`),
  relationship 0.90 (unchanged), exact nickname 0.85 (any index `normalizedNicknames` exact), name
  containment 0.80 (unchanged), nickname containment 0.75 (either direction — the name band's shape,
  applied per stored spelling), token overlap 0.60 (unchanged, name tokens). Accept 0.60 / margin 0.15
  remain the private constants; the strict `<` rival rule and the tie ⇒ ambiguity rule are unchanged.
- **`nearMiss(_:)`**: candidate set = name OR any nickname within edit budget 2; the exactly-one rule is
  preserved and now counts CONTACTS, not spellings (a contact whose name and nickname are both in budget
  is one candidate; one name-near-miss plus one nickname-near-miss on different contacts abstains).
- **`.none` stays the honest failure**; no new error type, no logging (no PII surface — there is no log
  call in the type).
- The **linked system twin is never a candidate** (family roster only; FR-FCU-004) — unchanged, now
  documented in the class comment and pinned by a test.

### 2. `ios/ElderlyAssistantTests/Services/Intents/ContactResolverTests.swift` (extended: 13 → 37 tests)

New sections: nickname bands, the F2 consequence table, grapheme/linked pins, the near-miss extension,
and the perf ceiling.

| Task Gherkin / requirement | Test |
|---|---|
| Unambiguous nickname resolves in one step (FR-FCU-013) | `testUnambiguousNicknameResolvesInOneStep`, `testEveryStoredNicknameSpellingResolves` |
| Nickname containment band, both directions | `testNicknameContainmentMatchesEitherDirection` |
| Band never fabricates a match; blank spelling safe | `testNicknameBandNeverFabricatesAMatch`, `testBlankNicknameSpellingCannotMatchEveryQuery` |
| Consequence table F2 — pins + IEEE-754 gap | `testConsequenceTablePinsTheBandingConstants` (asserts accept 0.6 / margin 0.15 through `bandingPins`, and `1.00-0.85 == 0.90-0.75 == 0.75-0.60 == 0.15000000000000002`, which is NOT `< margin`) |
| Row 1.00 vs 0.85 (documented: name-exact resolves; exact-name beats nickname) | `testConsequenceRowNameExactBeatsNicknameExactAtMargin` (both roster orders) |
| Row 0.90 vs 0.75 (exactly at margin ⇒ decisive) | `testConsequenceRowRelationshipBeatsNicknameContainmentAtMargin` |
| Row 0.75 vs 0.60 (exactly at margin ⇒ decisive) | `testConsequenceRowNicknameContainmentBeatsTokenOverlapAtMargin` |
| Accept floor inclusive / below-accept honest miss | `testConsequenceRowCandidateAtTheAcceptFloorResolves`, `testConsequenceRowBelowAcceptIsAnHonestMiss` |
| Ambiguous nickname asks instead of guessing (FR-FCU-014) | `testConsequenceRowSharedNicknameIsAmbiguous` (tie; both ids; `.one` explicitly ruled out), `testConsequenceRowNicknameExactAgainstRelationshipIsAmbiguous`, `testConsequenceRowNicknameExactAgainstNameContainmentIsAmbiguous`, `testConsequenceRowNicknameExactAgainstNicknameContainmentIsAmbiguous` |
| Ties ⇒ ambiguity, never order (determinism) | `testDecisionsDoNotDependOnRosterOrder` |
| Index provider path ≡ nil-provider path | `testIndexProviderPathAnswersIdenticallyToTheBuiltInPath` (10 query shapes × resolve + nearMiss), `testRosterWithoutNicknamesReproducesTodaysAnswers` (parity anchor) |
| NFR-FCU-007 grapheme negative pin (+ positive control) | `testGraphemeSplitTruncationDoesNotResolveTheFullName` (name AND nickname band; `सुनित` ≠ `सुनिता`) |
| Linked twin never a candidate (FR-FCU-004 scenario 2) | `testLinkedSystemTwinIsNeverASeparateCandidate` |
| Near-miss extension (name OR nickname ≈ budget 2) | `testNearMissProposesThroughANickname`, `testNearMissCountsOneContactOnceWhenNameAndNicknameAreBothInBudget`, `testNearMissAbstainsWhenNameAndNicknameLandOnDifferentContacts` |
| Resolution performance ≤ 20 ms at 12×8 (NFR-FCU-001) | `testVoiceResolutionStaysWithinTheTwentyMillisecondCeilingAtMaxRoster` (96 queries × both provider shapes, every iteration asserted; durations only printed) |
| Pre-existing regressions (name/relationship/containment/ambiguity + 4 near-miss) | carried unchanged |

## Gate results

- **Whole-module typecheck**: `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant -destination "platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2" -derivedDataPath build/DerivedDataTests "-skip-testing:ElderlyAssistantUITests"` (Debug, simulator) — **TEST BUILD SUCCEEDED, 0 errors**; app module AND test bundle compiled (both changed files recompiled per the log), no warning in either file. Log: `ios/build/t153-typecheck.log` (ignored by git).
- **Scoped suite DEFERRED** per the speed-mode directive — `./build.sh test:unit ContactResolverTests` is a phase-end gate item.
- **Pre-commit band verification (extra, since the suite run is deferred)**: the resolver's pure parts were extracted verbatim from the repo files into a standalone harness (`/tmp/t153check`, scratch, not committed) and every consequence-table fixture was checked band-by-band through the real `score` ladder: 1.00/0.85, 0.90/0.75 and 0.75/0.60 all resolve to the documented decisive row (each gap `0.15000000000000002`), the four sub-margin rows are ambiguous with both ids, the floor/`below-accept`/grapheme/near-miss/legacy-regression cases all pass, and the indexed path answers identically to the built-in path. Worst measured per-call wall time at 12×8: **published index ≈ 1.7 ms, built index ≈ 2.4 ms, near-miss ≈ 0.2 ms** — inside the 20 ms ceiling with two orders of magnitude of headroom (measured values are printed by the XCTest perf test at the phase-end run).
- Coverage: not measured in this mode; the new ladder branches (0.85/0.75 bands, empty-spelling guards, index-fallback path, nickname near-miss forms) each have at least one direct test.

## Decisions made during implementation (log)

1. **`bandingPins` read-only accessor** (`static var bandingPins: (accept: Double, margin: Double)`): the
   unit spec requires the F2 table to share the banding constants with the runtime ("single-sourced … no
   duplicated literals"), while design-l2 §1.7 says the constants stay private at :61-62 (pre-change line
   numbers). Both are satisfied by keeping the two literals private and publishing read-only values —
   there is no setter and no second definition, and an accept/margin edit fails
   `testConsequenceTablePinsTheBandingConstants`.
2. **Index publish-lag fallback** (`normalizedForms(of:in:)`): a contact the published index has not seen
   yet is normalized on the fly with exactly the calls `FamilyContactIndex.init` makes. Not in the design's
   prose, but the design does say the index is republished wholesale (T-156) and the resolver reads the
   roster for the returned VALUES: without the fallback, a lagging index would silently drop a contact from
   consideration. With it, lag can only cost time, never flip a decision — and the two provider paths are
   pinned as identical.
3. **Near-miss empty-spelling filter**: a spelling that normalizes to `""` (punctuation-only nickname) is
   dropped from the near-miss walk — an empty form is within the edit budget of any ≤2-scalar query and
   would be a fabricated rival. Same rule the name band already had (`guard !name.isEmpty`), now applied
   uniformly to nicknames. `score` needs no equivalent guard: the query is non-empty by the time it runs.
4. **Nickname containment is both-direction** per design-l2 §1.7 (the §1.6 one-direction rule is the SEARCH
   tier over raw spellings, a different surface); "contains" is plain `String.contains` on normalized
   strings — the same Character-cluster semantics as the name band, no new grapheme logic (NFR-FCU-007).
5. No coordinator wiring: `AppCoordinator` still constructs the resolver through the defaulted-init
   trailing closure and keeps working; handing it the published index is T-156's roster-republish work.

## Deliberately NOT done (other units own these)

- `AppCoordinator` index wiring / `@Published familyIndex` — T-156.
- `UnifiedContactSearch` nickname tier and link-aware dedupe — T-152.
- `MethodResolver` — untouched (design R4: resolution upstream chooses the person, the method chain
  downstream chooses the channel).
- No changes to `seniOS.xcodeproj` (no new files in this unit); the concurrent pbxproj edits in the
  worktree belong to other in-flight units and were not staged.

## Handoff / open items

1. **T-156** should pass `indexProvider: { [weak self] in self?.familyIndex ?? .empty }` at the
   `AppCoordinator.contactResolver` construction site once the index is published with the roster.
2. Phase-end gate items: run `ContactResolverTests` (scoped) + the caller suites (`CommandRouterTests`,
   `DirectionsRouteTests`, `DeterministicCallRoute` tests) and record the printed ms values; per-unit review.
3. DV item: the Anzaan smoke test should include one unambiguous nickname dial and one shared-nickname
   request (expects the disambiguation prompt, never a silent call).

## Files changed

```
ios/ElderlyAssistant/Services/Intents/ContactResolver.swift        (extended, 308 lines)
ios/ElderlyAssistantTests/Services/Intents/ContactResolverTests.swift (extended, 445 lines, 37 tests)
specs/T-153-notes.md                                              (this file)
```
