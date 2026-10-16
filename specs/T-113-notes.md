# T-113 — VoiceContactSearchRoute music veto (C-SP-08) — implementation notes

Status: COMPLETE (worktree `elderly-ai-assistant-spotify-music-integration`, branch
`feat/spotify-music-integration`, uncommitted per instructions).
Date: 2026-10-07. Depends on T-112 (W1, committed at a198830) — `KeywordIntentRule`
was called exactly as frozen, never modified.

## What was built

### 1. The veto block (production change, one insertion)

`ios/ElderlyAssistant/Services/Voice/VoiceContactSearchRoute.swift`:

```swift
if isYouTubeUtterance(text) { return .notSearch }          // existing (baseline)

// [SPOTIFY] (2026-10-06) Music-marked utterances belong to the
// music stage, which runs LATER in the ladder — position parity ...
if KeywordIntentRule.mentionsMusic(text) { return .notSearch }   // NEW

guard isSearchMarkerHit(text) else { return .notSearch }   // existing (baseline)
```

- Exactly one block; no other code in the file changed.
- Calls the FROZEN `KeywordIntentRule.mentionsMusic(_:)` (T-112) and nothing else;
  the veto reuses the rule's own `musicMarkers` family, so veto and rule can never
  disagree about "a music utterance".
- No logs added; utterance text never enters logs (NFR-SP-002 held).

### 2. Insertion-position resolution (discrepancy closed)

- T-113 task file says: "after the direct-call veto and before the YouTube veto".
- design-l2.md §15 (the reviewed contract) says: "Immediately after the existing
  YouTube veto ... before the search-marker check".
- Resolution: **followed design-l2 §15** (after `isYouTubeUtterance`, before
  `isSearchMarkerHit`), as instructed. The two orderings decide identically: both
  vetoes return `.notSearch`, so any double-matching utterance (e.g.
  "युट्युबमा गीत खोज") is route-identical under either ordering. The position is
  pinned by `testYoutubeVetoStillHoldsWithTheMusicVeto`, and the code comment
  records that §15 is the shipped ordering.

### 3. F-6 residual — recorded at the documenting fixture

F-6 is recorded (task file wording, verbatim in spirit) at
`VoiceContactSearchRouteTests.testFusedMarkerNamesAreTheKnownF6OverBlock`
(ios/ElderlyAssistantTests/Services/Voice/VoiceContactSearchRouteTests.swift):
a contact whose name literally contains a full music marker ("गीतमाया" ⊃ "गीत",
"भजनलाई" ⊃ "भजन") is no longer reachable through a search-marker utterance
carrying that name — the veto fires and the search cannot run. The same test
asserts the near-miss protection that makes the trade-off narrow: "गीता" and
"गीतांजलि" do NOT contain "गीत" (the final त carries the vowel sign), so their
searches route exactly as before (`.openPhone(...)`).

### 4. Tests added / extended

`ios/ElderlyAssistantTests/Services/Voice/VoiceContactSearchRouteTests.swift`
(5 new tests, all existing tests untouched):

| Gherkin scenario | Test |
|---|---|
| 1: A music utterance is vetoed before contact search — veto fires, contact search does not, proceeds toward the music path | `testMusicShapedUtterancesAreNotContactSearches` (design §15 fixtures: "गीत चलाऊ", "भजन बजाऊ", "play a song", "संगीत सुनाऊ" → `.notSearch` + `mentionsMusic` true + `KeywordIntentRule.match == .music`) — and `testSearchMarkerUtteranceWithMusicMarkerIsVetoed` ("भजन खोज र सुनाऊ": an actual search-marker utterance, pinned as the only fixture where the insertion is load-bearing — extraction would have prefilled "भजन सुनाऊ") |
| 1 (F-6 documenting fixture) | `testFusedMarkerNamesAreTheKnownF6OverBlock` |
| 2: Existing vetoes and matching semantics unchanged | existing `testPhoneNumberDialPhraseIsVetoed`, `testCallVerbPhrasesAreVetoed`, `testEnglishCallPhrasesAreVetoed`, `testYouTubeShapedUtterancesAreNotContactSearches`, `testNonYouTubeSearchStillRoutes` — unchanged and passing; plus new `testMusicVetoDoesNotOverBlockContactRequests` ("आरवलाई फोन गर", "call ram", "मेरो छोरालाई फोन लगाऊ" → `mentionsMusic` false, baseline `.notSearch`), `testYoutubeVetoStillHoldsWithTheMusicVeto` |

`ios/ElderlyAssistantTests/Services/Voice/KeywordIntentRuleTests.swift`
(W1-review F-1 additions only; the W1-corrected doc comment was NOT reverted):
`testExcludedFormsNeverFireTheMusicRule` gained the fused-marker fixtures
"भजनलाई फोन गर" and "गीतमाया" — both keep the music rule nil (no music verb),
demonstrating the marker-fusion class explicitly.

### Deviation / addition (flagged)

One fixture goes beyond the brief's enumerated list:
`testSearchMarkerUtteranceWithMusicMarkerIsVetoed` ("भजन खोज र सुनाऊ"). The four
design §15 positive fixtures carry a music marker but no search marker, so they
pass identically with and without the insertion; the Gherkin's "Given a
search-marker utterance that also carries a music marker" needed at least one
fixture where the veto is the deciding factor, and this is it. It is an addition,
not a change to any specified fixture.

## Gate

Command (lock-serialized, run from the worktree):

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration ./build.sh test:unit VoiceContactSearchRouteTests KeywordIntentRuleTests
```

Result: **TEST SUCCEEDED** — `Executed 74 tests, with 0 failures (0 unexpected)`,
`VoiceContactSearchRouteTests`: 26 tests / 0 failures (21 baseline + 5 new);
`KeywordIntentRuleTests`: 48 tests / 0 failures (count unchanged; fixtures
extended). The F-6 test is confirmed present and passed in the parsed xcresult.
No other stop-ship gates are owned by this task.

## Files changed (only the three owned; pbxproj untouched — existing files only)

- `ios/ElderlyAssistant/Services/Voice/VoiceContactSearchRoute.swift` (one veto block)
- `ios/ElderlyAssistantTests/Services/Voice/VoiceContactSearchRouteTests.swift` (+5 tests)
- `ios/ElderlyAssistantTests/Services/Voice/KeywordIntentRuleTests.swift` (F-1 fixtures)

Not committed / not staged / not pushed, per instructions.

## Open items for downstream tasks

- T-116 (router music path) consumes this veto's outcome (`.notSearch` leaves the
  utterance to the music stage).
- CommandRouter still reaches `VoiceContactSearchRoute` exactly as before; the
  music stage ordering assumption (contact-search stage runs BEFORE the music
  stage) is T-116's to preserve.
