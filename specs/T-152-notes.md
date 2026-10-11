# T-152 — UnifiedContactSearch tiers and dedupe: implementation notes

Unit: `TG-30/T-152-unified-search-tiers-and-dedupe`
Feature: `family-contacts-unify` · Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`)
Commit: the T-152 unit commit on `feat/family-contacts-unify` carrying this notes file plus the two owned files, the extend-ed test suite and the three shared-file call-site fixes (not pushed).
Date: 2026-10-12 · **Speed mode** (parent directive): implement + whole-module typecheck + commit only — the scoped suite run and per-unit review are deferred to the phase-end gate.

## What was built

### 1. `ios/ElderlyAssistant/Services/Contacts/UnifiedContactSearch.swift`

Exactly design-l2 §1.6 / design-l1 §7.1–§8.1:

- **`FamilyMatchTier`** — `.nickname` INSERTED at raw value 2, `.containment` renumbered to 3, raw values now spelled explicitly (`exactName = 0`, `relationship = 1`, `nickname = 2`, `containment = 3`). The tier is transient (computed per search, never persisted — grepped: no persistence path, no exhaustive switch outside this file and the tests), so renumbering is safe; `<` keeps comparing raw values, so `rank` needed no change.
- **`Outcome`** — gained `linkedBookNames: [String: String]` with an explicit init defaulting to `[:]` (design-l2 §1.6 verbatim), so every existing `Outcome(entries:moreAvailable:)` construction still compiles.
- **`search(query:family:index:in:verifiedLinks:recency:limit:)`** — the `index:` parameter is REQUIRED (no convenience overload, per §1.6) and `verifiedLinks` defaults to `.empty`. Five passes, in order:
  - **Pass 1** `familyMatches(query:in:index:)` — tiers checked best-first. `.exactName` reads the index `normalizedName`; `.relationship` unchanged; `.nickname` = the exact map hit (`index.exactNicknameHolders`, resolved ONCE per call into a `Set`) OR a Character-safe substring of a precomputed normalized nickname via the SAME `range(of:options: [.caseInsensitive, .diacriticInsensitive])` call the name/containment tiers use — same direction (stored value contains the query), no new grapheme or transliteration logic (NFR-FCU-007); `.containment` unchanged.
  - **Pass 2** `addressBookMatches` — untouched.
  - **Pass 3** (new, private `linkMerge`) — for each matched book row whose non-empty `identifier` has a verified link: family contact matched in Pass 1 → DROP the row; otherwise SYNTHESIZE `(contact, tier: .containment)`, DROP the row, and record `linkedBookNames[Result.family(contact).id] = row.name` — suppressed when `NepaliTextNormalizer.normalize(row.name)` equals the index `normalizedName` (nothing to explain).
  - **Pass 4** — the existing `dedupe(matchedFamily:in:)` over the REMAINING book rows, fed exactly the Pass-1 matched family contacts ("unchanged" read literally, design-l1 §7.1).
  - **Pass 5** — `moreAvailable = matched + synthesized + remainingBook > limit`, recomputed BEFORE the limit slice.
- **Guards (no crash, no phantom drop, no wrong-person merge):** a row with an empty identifier is never a link target (kept); a verified link whose family contact is not in the roster being searched is kept (never dropped without a replacement row); a second matched row of the SAME record (one record, two numbers) synthesizes the family row only once — one row per person; a stale stored `systemContact` claim is never consulted (only the verified snapshot is); a punctuation-only query that normalizes to `""` never substring-matches nicknames (mirrors T-151's decision never to key the empty string).
- **`.empty` short-circuit** — `linkMerge` returns its inputs untouched when the snapshot has no links, so unlinked pairs traverse the same code they always did: the parity guarantee is structural, not incidental.
- **No logging** anywhere in the changed code (NFR-FCU-002: "No PII in logs" is satisfied by having no log call site — grepped for `print`/`Logger`/`os_log`/`NSLog`: none).

### 2. `ios/ElderlyAssistantTests/Services/Contacts/UnifiedContactSearchTests.swift` (extended)

All 22 pre-existing tests kept intact (their `index:` arguments threaded mechanically; two pre-existing unused-binding warnings carried over — they exist at HEAD, lines 434/450 of the old file, and were deliberately not touched to keep the diff faithful). New coverage, mapped to the unit spec and design §8.3:

| Gherkin / DoD item | Test |
|---|---|
| Tier order `.exactName < .relationship < .nickname < .containment` (raw-value pin) | `testTierRawValuesPinTheQualityOrder` |
| Nickname exact match (both scripts; the O(1) map hit) | `testNicknameExactMatchLandsInTheNicknameTier` |
| Nickname substring = name-tier semantics (`सान` → `सानु`, `SAA` → `saanu`; exact and substring are ONE tier) | `testNicknameSubstringMatchUsesTheSameCharacterSafeSemantics` |
| No transliteration bridging, both directions (OD-2) | `testNicknameQueriesDoNotCrossScripts` |
| Devanagari pins POSITIVE (`छोरी`) and NEGATIVE (`छोर` does not match) — NFR-FCU-007 | `testDevanagariNicknamePinsPositiveAndNegative` |
| Nickname ranks below relationship and above containment (matches + ranked outcome) | `testNicknameTierRanksBelowRelationshipAndAboveContainment` |
| Linked pair, one row for a digit query despite differing number spellings (Pass 3 drop; the unlinked control shows TWO rows) | `testLinkedPairYieldsOneRowForADigitQueryDespiteNumberSpellings` |
| Book-side-only match → SYNTHESIZE + drop + `linkedBookNames` under the ROW's id (Pass 3) | `testBookSideOnlyMatchSynthesizesTheFamilyRowWithItsBookName` |
| `linkedBookNames` suppression when the names already normalize equal | `testSynthesizedCaptionIsSuppressedWhenTheNamesAlreadyAgree` |
| A nickname-matched linked pair still yields ONE row (FR-FCU-012) | `testNicknameMatchedLinkedPairStillYieldsOneRow` |
| One record / two numbers → synthesized ONCE, first book name recorded | `testOneRecordTwoNumbersSynthesizesOnce` |
| Synthesized rows are `.containment` — they rank below a relationship match | `testSynthesizedRowRanksAtContainmentBelowARelationshipMatch` |
| Pass 5 recount turns `moreAvailable` false after a twin drop | `testRecountHappensAfterTheLinkMerge` |
| Pass 5 counts synthesized rows (limit 2 vs 3) | `testSynthesizedRowsCountTowardMoreAvailable` |
| Stale link (stored claim, absent from the snapshot) never merges; recount honest; verified control DOES merge | `testStaleStoredLinkNeverMergesRecords` |
| "Linked record disappears between passes" — gone family contact: no phantom drop; record row gone: no crash, honest rows | `testLinkWhoseFamilyContactIsGoneKeepsTheBookRow` |
| Row without a live record (empty identifier) is never a link target | `testRowWithoutALiveRecordIsNeverALinkTarget` |
| Ambiguous nickname: both claimants + the book claimant shown DISTINCTLY, deterministic, nothing collapsed (FR-FCU-014) | `testAmbiguousNicknameShowsBothClaimsNeverOneCollapsedRow` |
| Unlinked parity anchor: explicit `.empty` == defaulted, `linkedBookNames` empty on every query, hand-computed row/order anchors | `testEmptySnapshotIsTheUnlinkedParityAnchor` |
| Search ≤ 20 ms at 12 contacts × 8 nicknames (worst measured call asserted; duration printed, never fixture text) | `testNicknameSearchStaysUnderTheTwentyMillisecondCeiling` |
| Verified links with an empty roster leave the book half untouched | extended `testEmptyFamilySearchIsIdenticalToSystemContactSearch` |

### 3. Shared-file call-site fixes (compile-forced by `search(index:)`)

All three production call sites live in `ios/ElderlyAssistant/App/LeafViews.swift` (CallView). Each got the identical minimal mechanical fix: hoist `let index = FamilyContactIndex(family: coordinator.familyContacts)` and pass `index: index` — no other line touched. Sites: `resolveResultPhotos()` (:1153), `announceVoiceResultIfReady()` (:1532), `resultsArea` (:1696). The index is rebuilt inline per evaluation until T-156 republishes a coordinator-owned `familyIndex` (design-l2 §3.6); the cost is one `normalize` per name/nickname (≤ 108 calls, T-151's measured ceilings) — CallView UI work (link-aware rows, `linkedBookNames` rendering, `.limited` gates) deliberately NOT done here (T-161).

**Wizard call site — as-assigned item that does not exist in this tree:** the assignment said "the wizard has 1" call site. `FamilyContactWizardSheet`'s find step (SettingsView.swift:2170) still calls `SystemContactSearch.search(query:in:recency:)` DIRECTLY — not `UnifiedContactSearch.search` — so the signature change does not reach it and there is nothing to fix without doing T-159's work (converting the wizard search to the unified union is explicitly T-159's scope). Verified by grep: the only references to `UnifiedContactSearch.search/familyMatches` in the module are the three LeafViews sites, the definition, and the tests. Recorded here so the reviewer can confirm rather than hunt.

## Recorded implementation decisions (none widens the published surface)

1. **`linkMerge` is a private static helper**, not a new public seam. Design-l2 §1.6 names no helper for Pass 3 and every Gherkin scenario is observable through `search(...)`/`Outcome` (all the tests above go through the public entry points, including the failure paths). Keeping it private minimises the reviewed surface in a HIGH-risk unit; if a later unit needs the seam it is a one-word change.
2. **Pass 4 receives the Pass-1 matched family contacts only** (not the synthesized rows) — the literal reading of design-l2 §1.6 / design-l1 §7.1 ("unchanged"; the byte-for-byte paragraph assumes an unchanged input). Consequence: a *third* book record that merely shares the family phone is not additionally swept up in a linked triple — the linked row itself is already gone via Pass 3, and no shipped shape produces that triple.
3. **Name-comparison suppression is literal**: `normalize(row.name) != index.entry(for: familyID)?.normalizedName` — a nil entry (inconsistent index, a caller error) records the book name rather than guessing they are equal.
4. **The exact-nickname map is resolved once per `familyMatches` call** into a `Set<UUID>`, not once per contact — the O(1) claim holds with one dictionary hit per keystroke, matching T-151's contract.
5. **Empty normalized query never substring-matches nicknames** (mirrors the index's no-empty-key decision); the raw name/relationship and digit tiers keep exactly today's behaviour, so parity is preserved even for punctuation-only queries.
6. **`linkedBookNames` keys are built through `Result.family(contact).id`**, not string-interpolated by hand, so the map can never drift from the row id the UI looks up.

## Gate results

- **Whole-module typecheck: GREEN.** `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant -destination "platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2" -derivedDataPath build/DerivedDataTests "-skip-testing:ElderlyAssistantUITests"` → **TEST BUILD SUCCEEDED**, exit 0, 0 errors; the log confirms `UnifiedContactSearch.swift`, `LeafViews.swift` and `UnifiedContactSearchTests.swift` all recompiled. Log: `ios/build/t152-typecheck2.log` (ignored by git). (First run caught one argument-order error in a new test, fixed; the same log also shows exactly the two pre-existing unused-binding warnings carried over from HEAD.)
- **Scoped suite DEFERRED** per the speed-mode directive — the tests exist and compile; `UnifiedContactSearchTests` is a phase-end gate item. Because the run was deferred, the one genuinely uncertain Foundation behaviour the pins rest on was probed standalone instead of assumed: `"छोरी".range(of: "छोर", options: [.caseInsensitive, .diacriticInsensitive]) == nil` (negative pin holds) and `"सानु".range(of: "सान", …) != nil` (positive pin holds). No test expectation in this unit depends on an unprobed assumption.
- **Release log-safety gate**: not re-run here (T-155 owns it); the changed files add no logging, so the feature-root scan is unaffected by this unit.

## Deliberately NOT done (other units own these)

- **T-156** — coordinator-owned `familyIndex` publishing/republication, `verifiedLinks` state, `refreshVerifiedLinks()`. The LeafViews hoists are the interim shape.
- **T-159 / T-161** — wizard find-step conversion to the unified search (the wizard does not call `UnifiedContactSearch` yet) and CallView rendering of the synthesized row's caption (`call.search.linkedBookName`) + `.limited` gates.
- **T-153** — `ContactResolver` nickname bands (already landed; this unit does not touch the voice path).
- No changes to `SystemContactSearch`, `Result`, or the number-dedupe seam.

## Deviations

None from the assigned behaviour. Two items to note explicitly for the reviewer (details above): the wizard call site named in the assignment does not exist in this tree (SettingsView:2170 calls `SystemContactSearch` directly — T-159's scope), and `linkMerge` is private rather than a new public seam.
