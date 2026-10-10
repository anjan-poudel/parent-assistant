# T-132 — Candidate assembly for did-you-mean probes — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`; W1 at 76b28b9, base 0cbe4e6). Unit:
C-MTC-03, TG-25.

## Status

Done and green. The did-you-mean candidate assembly is implemented as a pure,
stateless enum of static functions; focused suite green (29/29 tests, locked
scoped run 2026-10-10, `** TEST SUCCEEDED **`, `rc=0`, `xcresult`
`Test-ElderlyAssistant-2026.10.10_16-10-58-+1100`). No wiring into callers —
T-134 owns the degenerate-trigger integration.

## Files created

- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Services/Voice/DialogueCandidateBuilder.swift`
  (sha256 `08241c4d2c4aafc23dbefc3979a9d19bc4a6ee5629553cd7f5a64b21ecd120fd`)
- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/DialogueCandidateBuilderTests.swift`
- NEW `specs/T-132-notes.md` (this file)

No other file was touched. No git commands; no ai-sdd CLI; no sibling unit's
files (`DialogueAnswerPath.swift`, T-131, was in flight in the same worktree
and was never opened for edit — the reference reader was never needed, see
"Open items"). `project.yml` needed no edit — the Swift files ride the
existing source glob and `build.sh` regenerates the project each run.

## What was built

`DialogueCandidateBuilder.swift` (design-l2 §10, C-MTC-03; L1 ADR-MTC-07):

- **`build(for:excludingDomain:rephraseHypothesis:maxCandidates:)`** — the
  did-you-mean assembly:
  1. iterates `KeywordIntentRule.nearMatches(transcript:)` (the bounded
     near-match readings, one per domain in rule order) and maps each reading
     to its domain's compose form — at most one candidate per domain, rule
     order preserved;
  2. appends the denied rephrase hypothesis LAST, and only when at least one
     near-match candidate exists (never offered alone);
  3. caps at `max(0, maxCandidates)` — near-match candidates keep priority.
  Returns `[]` when nothing is eligible (FR-MTC-004 scenario 3: no frame is
  armed, the caller keeps its existing honest dead-end line).
- **Compose forms (design-l2 §10 mapping table, T-129 keys verbatim):**
  news → `dialogue.candidate.news` (query nil) | youtube →
  `dialogue.candidate.youtube` (query = `YouTubeRoute.extractQuery`; the
  reading is OMITTED when no quotable query exists — never invented) | music
  → `dialogue.candidate.music` (query = `KeywordIntentRule.musicQuery`) |
  appLaunch → `dialogue.candidate.appLaunch` (`appID` = reading's catalog
  id). `matchKeys` carries the reading's own matched rule tokens; the
  youtube/music queries are the utterance's own extracted words.
- **Hypothesis mapping (design-l2 §10):** `.music` → `.music`
  (query = `command.message`); `.suggestVideo` → `.youtube`
  (query = `command.topic`); any other action omitted silently;
  `matchKeys: []` (index-word pickable only).
- **`slotFillCandidates(from:catalog:)`** — the slot-fill side: at most
  `DialogueConfig.maxSlotOptions` options in file order, re-resolved from the
  catalog by group id (fail closed: a group the catalog does not carry yields
  `[]`), ids/label keys/queries/aliases taken verbatim from catalog data.
- **Consumes, never re-declares** the DialogueManager vocabulary
  (`DialogueCandidate`, `DialogueSlot`, `DialogueConfig`, `DialogueError`,
  frame types — T-125) and the rule vocabulary (`KeywordIntentRule.Domain`,
  `NearMatch`, `YouTubeRoute.extractQuery`, `InterpretedCommand`). No new
  type is declared that already exists in `DialogueManager.swift`.
- **Purity and fences:** statics only, no state, no frame mutation (T-134
  arms), no catalog load, no speech, no network. No console output and no
  observability metadata — log safety by construction (one of the four T-138
  FEATURE_ROOTS files). Never touches
  `VoiceSessionStateMachine.Config.confirmationTimeoutSeconds` (file-wide
  grep: zero matches). No fabricated content anywhere: every label resolves
  from a shipped `dialogue.*` key plus either the rule's matched tokens or
  the utterance's/command's own words.

## Tests

`ios/ElderlyAssistantTests/Services/Voice/DialogueCandidateBuilderTests.swift`
(29 tests, inline-JSON 2-group catalog for the slot-fill side, exact Nepali
probe-string assertions; deterministic — no clock, no session machine, no
router, no network):

Exact command (locked, per the dispatch protocol; worktree `ios/`):

```
cd /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios && ./build.sh test:unit DialogueCandidateBuilderTests
```

Result: **29 executed, 0 failures (0 unexpected)**, `** TEST SUCCEEDED **`,
`rc=0`. Per-test results re-read from the `xcresult` bundle: 29/29 Passed,
0 failed, 0 skipped (iPhone 17 Pro simulator, iOS 26.5 / 23F77). Gates in the
same invocation green: source privacy guard + log-safety fixtures (24 cases
over 12 rules) + intent-prompt mirror (2717 bytes, 4 placeholders, all drift
classes rejected). Zero compiler warnings. Log-safety grep of both new files
for `print(` / `os_log` / `Logger` / `NSLog` / `debugPrint` / `URLSession` /
`confirmationTimeoutSeconds`: no matches. No full-suite run (per protocol).

Test list (all Passed):

1. `testNewsNearMatchMapsToTheNewsComposeForm` — "समाचार" → [news, keys `["समाचार"]`, query nil].
2. `testYoutubeNearMatchMapsTheExtractedQueryAndRuleTokens` — "युट्युबमा गीत" → [youtube, query "गीत", keys `["युट्युब"]`].
3. `testVideoNearMatchWithoutAQuotableQueryContributesNoCandidate` — "युट्युब" alone: the appLaunch candidate carries the probe, the youtube reading contributes nothing.
4. `testVideoOnlyReadingYieldsAnEmptyList` — youtube is the only near-match and has no query → `[]` even with a hypothesis supplied.
5. `testMusicNearMatchMapsTheExtractedQueryAndRuleTokens` — "दशैं दुर्गा भजन" → [music, query "दशैं दुर्गा", keys `["भजन"]`].
6. `testAppLaunchNearMatchCarriesTheCatalogAppID` — "क्यामेरा" → [appLaunch, appID "camera"].
7. `testMultipleDomainsMapOneCandidateEachInRuleOrder` — "युट्युब समाचार" → ids `[near.news, near.youtube, near.appLaunch]`, queries `[nil, "समाचार", nil]`, appIDs `[nil, nil, "youtube"]`.
8. `testADomainContributesAtMostOneCandidateAcrossPartialVariants`.
9. `testExcludingDomainSkipsThatDomainsNearMatch` — and only the near-match side is subject to the exclusion.
10. `testHypothesisIsAppendedLastAlongsideNearMatches`.
11. `testSuggestVideoHypothesisMapsToTheVideoComposeForm`.
12. `testNonMappedHypothesisActionIsOmittedSilently`.
13. `testHypothesisWithoutItsOwnWordsIsOmitted` — nil/blank `message`/`topic` → hypothesis omitted.
14. `testHypothesisIsNeverOfferedAlone`.
15. `testZeroNearMatchesBuildAnEmptyList`.
16. `testMedicationAndCallShapesBuildNoCandidates` — the ADR-SP-06 exclusions stay excluded ("फेरि भन्छु", "होइन" — zero readings).
17. `testZeroCandidatesCannotArmAFrame` — integration: `DialogueManager.arm` on an empty candidateChoice frame throws `.noResolution`; nothing is armed, so the honest line is preserved.
18. `testCapKeepsNearMatchesAheadOfTheHypothesis`.
19. `testTheCapIsAParameterOfTheBuilder` — maxCandidates 0/1/2/5 each obey.
20. `testCandidateCountNeverExceedsTheMaximum`.
21. `testSlotFillCandidatesMapTheCatalogGroupAndCapTheOptions` — 5-option group → 4; aliases ride `matchKeys`.
22. `testSlotFillCandidatesServeSmallerGroupsWhole`.
23. `testSlotFillCandidatesReadTheCatalogAsTheSourceOfTruth` — mutations of the passed catalog are what is served.
24. `testSlotFillCandidatesForANonCatalogGroupAreEmpty` — fail closed.
25. `testBuiltMusicCandidateRendersIntoTheDidYouMeanProbe` — byte-exact: `"मैले बुझिन। के तपाईंको मतलब दशैं दुर्गा बजाउने हो? हो?"`
26. `testBuiltAppLaunchCandidateRendersThePrimaryMatchKey` — byte-exact: `"मैले बुझिन। के तपाईंको मतलब युट्युब खोल्ने हो? हो?"`
27. `testEveryComposeFormKeyResolvesInBothLanguages` — en-US + ne-NP, non-empty, non-identical, Devanagari for ne.
28. `testTheComposeFormKeysAreTheShippedDialogueKeys` — the four strings are exactly the T-129 inventory entries.
29. `testBuildIsDeterministicAcrossCalls` — same input, same list, id-for-id.

### Gherkin coverage

| Scenario | Tests |
|---|---|
| Near-match readings map to did-you-mean candidates in rule order | 1, 2, 5, 6, 7, 8 |
| A video near-match without a quotable query contributes no candidate | 3, 4 |
| The hypothesis is re-offered last, never alone | 4, 10, 11, 12, 13, 14 |
| Zero eligible candidates build an empty list (never fabricate) | 15, 16, 17 |
| The candidate maximum is the frame config's, passed in | 18, 19, 20 |
| Slot-fill candidates come from the catalog with capped options | 21, 22, 23, 24 |
| Candidate labels compose from the shipped `dialogue.*` keys | 25, 26, 27, 28 |

Beyond the Gherkin: determinism (29) and probe-string render integration
(25, 26 — the composer is T-125's, consumed unmodified).

## DoD checklist

- [ ] **Code reviewed and merged** — workflow action, not this unit's (no git
  commands permitted here; the session integrates and the wave gate reviews).
- [x] **All Gherkin scenarios covered by automated tests
  (`DialogueCandidateBuilderTests`)** — 29/29 green scoped; scenario mapping
  above.
- [x] **Zero-candidate behaviour pinned** — a zero-candidate list arms no
  frame (integration test 17: `DialogueManager` throws `.noResolution`); the
  honest dead-end line staying in place is T-134's per design-l2 §12 edits
  5/6, out of this unit's file scope.
- [x] **One candidate per near-matched domain, rule order** — tests 7, 8.
- [x] **Video near-match without a quotable query contributes no candidate** —
  tests 3, 4.
- [x] **Hypothesis generic-only, appended last, only with ≥1 near-match, never
  alone** — tests 10–14; no domain query is ever invented for it (13).
- [x] **Cap is the frame config's `maxCandidates`, a parameter never a
  literal** — signature default `DialogueConfig.maxCandidates`; tests 18–20
  prove it is the operative knob.
- [x] **Labels verbatim from the T-129 keys + rule vocabulary** — Key enum +
  matched-token queries; tests 25–28 pin the shipped strings byte-for-byte.
- [x] **Focused suite green: `DialogueCandidateBuilderTests` (29/29); no new
  full-suite failures** — no full-suite run per protocol; the ~21
  pre-existing master failures (recorded in the queue) are untouched by two
  new files.
- [x] **No console output / observability metadata (log safety by
  construction), no network** — grep-verified (zero matches in both files).
- [x] **Never touches `Config.confirmationTimeoutSeconds`** — grep-verified
  (zero matches).

## Decisions / deviations

1. **`maxCandidates` parameter default.** The builder takes
   `maxCandidates: Int = DialogueConfig.maxCandidates` — the caller (T-134)
   passes the live config value; the default keeps single-source at
   `DialogueManager.DialogueConfig` and keeps the builder testable with
   explicit caps. No 3 literal appears in the file.
2. **Hypothesis omitted when its mapped field is nil/blank.** design-l2 §10
   pins query = `command.message` (music) / `command.topic` (video). When that
   field is absent or whitespace-only the composer would render an empty
   `%@` (broken spoken copy) and inventing a substitute would violate
   FR-MTC-004; the builder therefore omits the hypothesis exactly like an
   unmapped action. Pinned by test 13.
3. **"Only alongside ≥1 near-match" = ≥1 near-match CANDIDATE** (design-l1
   line 156 / R2: never alone; when it is the only possible candidate no
   candidate frame opens). The V13 exact-shape case — youtube-only reading
   with no quotable query — yields `[]` even with a hypothesis (test 4). The
   probe still fires through the appLaunch candidate in the shipped V13
   transcript shape (test 3).
4. **`excludingDomain` applies to the near-match readings only** — the
   hypothesis is the explicitly-supplied re-offer and is not subject to the
   exclusion. Both live trigger sites (design-l2 §12) pass nil; the parameter
   exists for the degenerate-trigger caller.
5. **`slotFillCandidates` re-resolves the group from the catalog by id**
   (fail closed, `[]` when absent) — this gives the pinned `catalog` parameter
   a load-bearing purpose: the shipped catalog stays the single source of
   option data, and a stale group copy cannot offer options the catalog does
   not own. `domain` is `.music` (Phase 1's only slot, `DialogueSlot.musicQuery`).
6. **Deterministic local ids** — `near.<domain>` / `hypothesis.<domain>`,
   never logged with content; makes the list comparable across calls (test 29).
7. **Cap clamp `max(0, maxCandidates)`** — `Array.prefix` traps on a negative
   count; a non-positive maximum can only mean "offer nothing".
8. **Defensive total switch branches** in `candidate(for:)` and
   `hypothesisCandidate(from:)` — unreachable today (`nearMatches` is
   restricted to the four framable domains), present so a future domain
   addition fails into omission, not into a fabricated candidate.

## Open items

1. **T-134 wiring** — the builder is not called anywhere yet (by scope
   design). The two call sites are design-l2 §12 (degenerate trigger and
   rephrase "no" path); both pass the ORIGINAL utterance, which is why the
   `utterance` parameter is the reading source, not the "no".
2. **T-138 gate roots** — `DialogueCandidateBuilder.swift` is cited in this
   file's header as one of the four FEATURE_ROOTS files the release log gate
   will cover; registering it in the gate's root list is T-138's file, not
   this unit's (design-l2 §20).
3. **Sibling T-131** (`DialogueAnswerPath.swift`) was in flight in the same
   worktree during this unit's window; it never affected the scoped build
   (first locked run was green — the retry-not-fix protocol was never
   triggered), and no sibling file was read or edited.
4. **Probe-string pins depend on T-129 copy** — tests 25/26 assert the
   composed probe byte-for-byte; a deliberate copy review of the
   `dialogue.*` values will move those anchors (T-129 pinned the same values
   verbatim, so the pair moves together).
