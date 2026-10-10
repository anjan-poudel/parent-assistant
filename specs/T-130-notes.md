# T-130 — Keyword-rule provenance, near-matches and markers (implementation notes)

Feature: multi-turn-conversation · Worktree: `elderly-ai-assistant-multi-turn-conversation` (branch `feat/multi-turn-conversation`) · Date: 2026-10-10

## Files

| File | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/KeywordIntentRule.swift` | Modified — extractor provenance, wrapper, accessors, near-matches |
| `ios/ElderlyAssistantTests/Services/Voice/KeywordIntentRuleTests.swift` | Modified — 6 tests appended (one per Gherkin scenario); all 48 shipped tests untouched |
| `ios/ElderlyAssistantTests/Services/Voice/KeywordIntentRuleProvenanceTests.swift` | Created — 23-test provenance/near-match suite |

No other unit's files were touched. `KeywordIntentRule.swift` was byte-identical to master when the unit started, and no other agent modified it during the unit (a conflicting in-flight T-128 edit was not observed; mtimes verified).

## What was built

All in `KeywordIntentRule.swift` (C-MTC-06), per design-l2 §10/§13 and FR-MTC-002.

1. **Extractor provenance** — `MusicQueryExtraction` (Equatable) with the closed vocabulary `Provenance` = {`.content`, `.markerFallback`, `.transcriptFallback`} and `isDegenerate` (`provenance != .content || query == nil`; design-l2 §23, FR-MTC-002).
2. **`musicQueryOutcome(from:maxLength:)`** — the shipped extractor's never-empty fallback ladder laid bare: tokens surviving the drop sets ⇒ `.content`; else the first music-marker token ⇒ `.markerFallback` ("भजन बजाऊ" → "भजन"); else the raw transcript's tokens ⇒ `.transcriptFallback` ("चलाऊ" → "चलाऊ", design L2-D10 step 3). A canonical-empty input is `.transcriptFallback` with `query == nil`. Tokenization, drop sets, containment drops and `NepaliTextNormalizer` handling are byte-for-byte the shipped mechanics.
3. **`musicQuery(from:maxLength:)`** — thin wrapper: `musicQueryOutcome(from:maxLength:).query`. Byte-identical returns by construction; every shipped call site keeps its source unchanged and its values unchanged.
4. **Marker/scaffold accessors** — `isMusicMarkerToken` widened private → internal (same `musicMarkers` table, same semantics; design-l2 §13c consumers T-131/T-132/T-134 reference it, never copy the vocabulary). New `isMusicScaffoldToken` = drop token AND NOT marker: markers are never scaffold, so the free-text fallback keeps them and the marker-dropped variant (V3) removes them through the marker accessor. Both accessors read the same tables the extractor reads.
5. **`NearMatch` + `nearMatches(transcript:)`** — bounded did-you-mean readings: only the four framable domains {news, youtube, music, appLaunch}; at most one entry per domain (first partial variant in table order wins); rule-level `excluded` groups apply exactly as in `match` (ADR-SP-06 — a YouTube marker disqualifies the music near-match too); medication rules can never appear (no medication vocabulary is consulted, by construction). `matchedKeys` are the rule's own alternative keys — never user text — in declared order; `appID` follows `Match.appID`'s discipline (only `.appLaunch`, else nil). Pure: no egress, no file reads.

## Test results

Exact command (serialized under the shared build lock `/tmp/mtc-w1-build.lock`, per the worktree protocol):

```
cd /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios \
  && ./build.sh test:unit KeywordIntentRuleTests KeywordIntentRuleProvenanceTests
```

- `KeywordIntentRuleTests` — **PASS**, executed 54 tests, 0 failures (0 unexpected) — 48 shipped (unmodified) + 6 new
- `KeywordIntentRuleProvenanceTests` — **PASS**, executed 23 tests, 0 failures (the xcresult selection total is 77/77 passed, 0 failed, 0 skipped; run exit 0, `** TEST SUCCEEDED **`; all 14 `V1`–`V14` vector nodes and all fallback-step nodes present in the result tree)

The build's pre-test gates ran green in the same invocation: source privacy guard (24 log-safety fixtures over 12 rules), intent-prompt mirror gate (2717 bytes, 4 placeholders, all drift classes rejected).

### Gherkin scenario → test mapping (KeywordIntentRuleTests, the 6 new tests)

| Gherkin scenario | Test |
|---|---|
| A marker-only request is flagged degenerate with no query | `testMarkerOnlyRequestIsFlaggedDegenerateWithNoContentQuery` |
| A specific request keeps the content provenance | `testSpecificRequestKeepsTheContentProvenance` |
| A canonical empty result falls back to the transcript without a query | `testCanonicalEmptyResultFallsBackToTheTranscriptWithoutAQuery` |
| The compatibility wrapper is byte-identical | `testMusicQueryWrapperMatchesOutcome` |
| Near-match readings are bounded and deduplicated | `testNearMatchReadingsAreBoundedAndDeduplicated` |
| Scaffold and marker accessors split framing words from content | `testScaffoldAndMarkerAccessorsSplitFramingWordsFromContent` |

### KeywordIntentRuleProvenanceTests (new suite, 23 tests)

- One provenance test per fallback step: `testProvenanceStepContent`, `testProvenanceStepMarkerFallback`, `testProvenanceStepTranscriptFallback`, `testProvenanceStepCanonicalEmpty`; plus `testDegenerateFlagTruthTable` (the `isDegenerate ⇔ provenance != .content || query == nil` equivalence).
- One named provenance test per capture vector V1–V14 pinning this unit's contribution to each vector (the classifier-level vector outcomes are T-131's `DialogueAnswerPathTests`): `testVectorV1IndexWordProducesNoKeywordReading` … `testVectorV14OverLongInputStaysCappedAndDeterministic`.
- Near-match boundary rows: `testNearMatchExclusionAppliesExactlyAsInMatch`, `testNearMatchesFollowTheRulesNotTheUtteranceClaim`, `testBareVerbIsNotANearMatch`, `testNonFramableDomainsAndEmptyInputsYieldNoNearMatch` (medication, festival, empty inputs yield nothing).

Wrapper parity (`testMusicQueryWrapperMatchesOutcome`) runs the full shipped fixture corpus — the extraction fixtures, provider drops, fallbacks, whitespace, empty/danda-only inputs — asserting wrapper == outcome for every fixture, equality to the historical literal values for 17 fixtures, and the `maxLength` forwarding legs.

## Definition of done — line by line

- [ ] **Code reviewed and merged** — not an action of this unit: the worktree merges through the feature's PR flow (project rule); this unit leaves the worktree with the focused suites green.
- [x] **All Gherkin scenarios covered by automated tests (`KeywordIntentRuleTests` extended)** — the 6 scenarios map to the 6 named tests above; the provenance suite adds the fallback-step, vector and boundary coverage.
- [x] **Wrapper-parity test over the full fixture corpus is green (byte-identical returns)** — `testMusicQueryWrapperMatchesOutcome`; the wrapper is one expression over `musicQueryOutcome`.
- [x] **No existing caller behaviour change: full existing keyword-rule suite passes unmodified** — all 48 shipped tests untouched and green; `musicQuery` keeps its signature and returns.
- [x] **Focused suite green: `KeywordIntentRuleTests`; no new full-suite failures** — the final locked run passed: 77/77 selected tests, 0 failures (KeywordIntentRuleTests 54 + KeywordIntentRuleProvenanceTests 23), exit 0, `** TEST SUCCEEDED **`. The ~21 pre-existing master failures are in unrelated suites; this unit adds no test to any other suite and does not touch the full-suite baseline.

## Decisions and deviations

1. **"the query is absent" (Gherkin scenarios 1 and 3) — deviation in wording, implemented per design + FR.** The scenarios say the marker-only and framing-only outcomes have "the query ... absent". design-l2 §13, FR-MTC-002 ("भजन बजाऊ" → query "भजन", the degenerate marker fallback), and the shipped byte-parity values all pin a NON-nil query for those two shapes (`"भजन बजाऊ"` → `"भजन"`, `"चलाऊ"` → `"चलाऊ"`); `nil` is reserved for the canonical-empty input, which the third scenario names ("canonical empty"). A nil query for marker-only input would contradict the wrapper's shipped values and break FR-MTC-002's probe trigger. Implemented the design/FR reading: the tests assert `provenance != .content`, `isDegenerate == true` and the pinned query byte value. The wrapper-parity test is the proof nothing shipped changed.
2. **Near-match group counting — prefix, not independent subsets.** A variant counts when the transcript matches a non-empty PREFIX of the variant's declared groups (specific word first, action verb last), stopping at the first absent group. Rationale: safety and mirroring `match` — a bare verb ("अलार्म बजाऊ", "टाइमर लगाऊ") partial-matches nothing, exactly as it fires nothing, so no nonsense music candidate can be framed from alarm/timer vocabulary. The considered alternative (any proper subset of groups) was rejected for exactly that failure mode; it is recorded here so the choice is a decision, not an accident. `testBareVerbIsNotANearMatch` pins it.
3. **V1–V14 ownership.** The named classifier vector tests are T-131's DoD (`DialogueAnswerPathTests`). This unit satisfies its completion bar with one named provenance test per vector pinning what THIS unit contributes to each vector (extractor reading, markers, near-match), without touching T-131's files. The vector doc comments state which part is the classifier's.
4. **`isMusicMarkerToken` visibility private → internal** — required so T-131/T-132/T-134 can reference the one marker table (design-l2 §13c; single-source vocabulary, NFR-MTC-012). Semantics unchanged; the shipped extractor call path is identical.
5. **Compatibility discipline** — no existing signature changed; `musicQuery` gained no new required parameter (defaulted `maxLength` kept). Every existing call site compiles source-unchanged.

## Security / NFR notes

- **V-1 (gibberish guard ordering)**: untouched. This unit adds no router call sites and changes no ordering; the extractor and near-match reading consume the same canonicalized transcript the shipped code did.
- **V-2 (no console writes in touched legacy files)**: `KeywordIntentRule.swift` gains no print/os_log/interpolation into events; the build's privacy gate (log-safety fixtures + engine/FEATURE scanners) is green in the same invocation as the tests.
- **NFR-MTC-012**: provenance is a closed internal vocabulary; near-match keys are static rule alternatives (never user text); no egress, no file reads, no new metadata. Single vocabulary source kept — no phrase list is copied anywhere.
- No new call sites are wired in this unit; T-131/T-134 consume these surfaces.

## Open items / notes for the integrator

- The near-match reading can report a partial variant that is unreachable on the live did-you-mean path (e.g. `"आजको समाचार सुनाइदिनुस् न"` yields `.news ["समाचार"]` through the news rule's second variant while the first variant fully matches). It is pinned in tests deliberately — the builder (T-132) decides what becomes a candidate; the reading itself must not drift.
- During implementation the shared worktree's app target transiently failed to compile because `DialogueManager.swift` (T-125, in flight) referenced the not-yet-defined `DialogueMerge` type, so five locked `./build.sh test:unit` attempts failed with exactly those two cross-unit diagnostics (`Cannot find type 'DialogueMerge' in scope` / `Type 'DialogueFrameResolution' does not conform to protocol 'Equatable'`) and never reached the test target — no T-130 file was involved in any failure. The type landed (in `DialogueManager.swift`) at 15:26; the next locked run passed on its first attempt at 15:30 (`rc=0`). This is recorded because any window of the interim logs may show those retries.
