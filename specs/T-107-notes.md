# T-107 — Deep-link grammar, hostile corpus and open probe (C-SP-01 deep-link half) — implementation notes

Status: COMPLETE — gate green (uncommitted; the orchestrator commits per wave).
Worktree `elderly-ai-assistant-spotify-music-integration`, branch
`feat/spotify-music-integration`; W1 committed at `a198830`. Date: 2026-10-07.
Depends on T-106 — the W1 search half was extended additively only (zero
changes to existing functions; diff is appended code plus one header-comment
paragraph).

## What was built

### 1. Production — `ios/ElderlyAssistant/Services/Spotify/SpotifyTool.swift`

The deep-link half of the §24 exact interface, all inside the existing
caseless `enum SpotifyTool`:

- `enum OpenOutcome { case opened, notOpened }` — two cases, no third, no
  case that reports success on a failed probe.
- `static func trackURI(id: String) -> URL?` — accepted iff
  `isSpotifyIdentifier(id)` (exactly 22 scalars, `[A-Za-z0-9]`); assembles
  `spotify:track:<id>`, re-parses and requires scheme `spotify`; nil on any
  failure, never a partial URI. No title parameter exists on any path.
- `static func searchURI(query: String) -> URL?` — accepted iff the trimmed
  query is non-empty and its `Character` count ≤ `maxSearchQueryLength`
  (100); percent-encoded with `CharacterSet.urlQueryAllowed` minus
  `+&=?/%#` (the §24 removal set, spelled verbatim); assembles
  `spotify:search:<encoded>`, re-parses and requires scheme `spotify`; nil
  otherwise (matrix row 8 hand-off link).
- `static func open(_ url: URL, opener: CallLinkOpening) -> OpenOutcome` —
  V-4: `canOpenURL` is consulted exactly once and is the only input to the
  outcome; probe true → `opener.open(url)` + `.opened`; probe false →
  `.notOpened` with no open call, no fallback, no inference, no retry.
- Privates: `deepLinkScheme`, `trackURIPrefix`, `searchURIPrefix`,
  `searchURIAllowedCharacters`, `validatedDeepLink(_:)` (the construction
  allowlist boundary).

`SpotifyTransport.swift` was deliberately NOT modified: the deep-link half
has no transport concern (no network, no headers), and the task allowed but
did not require extending it.

### 2. Tests

- `ios/ElderlyAssistantTests/SpotifyToolTests.swift` — extended, +9 tests
  (30 → 39): exact track-URI shape/no-title pin, representative rejections,
  probe-open pin, app-absent pin, both-probe-answers pin (DoD: no
  probe-failure-as-success path), search-URI shape/encoding, exact
  delimiter encodings, empty/over-cap/multibyte-cap bounds, scheme-allowlist
  walk over accepted constructions.
- `ios/ElderlyAssistantTests/Services/Spotify/SpotifyDeepLinkTests.swift` —
  NEW class (20 tests): 13 named category rejection tests, the whole-corpus
  walk (zero URIs, zero opener contact), corpus completeness pin, the
  exactly-22-Character class-rejection pin, the search hand-off fixtures,
  and the no-log-surface scan + its falsifiability check.
- `ios/ElderlyAssistantTests/Services/Spotify/SpotifyHostileCorpus.swift` —
  NEW fixture file (data only, no assertions).
- `ios/ElderlyAssistantTests/Services/Spotify/RecordingSpotifyLinkOpener.swift`
  — NEW `CallLinkOpening` double recording probe/open order.

## Hostile corpus

**88 identifier fixtures** across the 13 §24 clauses below (one NAMED test
per clause; one named rejection assertion per entry — the fixture name rides
in the assertion message) plus **14 query fixtures** (5 refused on the §24
bounds, 9 accepted-and-encoded). 43 fixtures sit at exactly the valid 22
`Character`s, so rejection is proven on the scalar class, not the length.

| §24 clause | Category | Fixtures |
|---|---|---|
| wrong scheme | `wrongScheme` | 6 |
| script-style scheme | `scriptStyleScheme` | 6 |
| control characters | `controlCharacters` | 5 |
| lengths 0/21/23/100 | `offLengthIdentifier` | 4 |
| `/ : ? # % . - _` + whitespace (+ extra punctuation) | `delimiter` | 17 |
| scheme text | `schemeText` | 5 |
| `//` | `doubleSlash` | 5 |
| quotes (double/single/backtick) | `quote` | 6 |
| path traversal (raw + encoded + backslash) | `pathTraversal` | 6 |
| non-base62 Unicode (accent, Devanagari, emoji, format chars, combining) | `nonBase62Unicode` | 8 |
| case variants (fullwidth, Cyrillic homoglyphs) | `caseVariant` | 5 |
| whitespace variants (tab/NL/CR/NBSP/ideographic) | `whitespaceVariant` | 6 |
| percent-encoding tricks (encoded delimiters, double encoding, malformed) | `percentEncodingTrick` | 9 |

The corpus total is pinned in the suite (`expectedIdentifierFixtureCount`),
fixture names are asserted unique, and every category is asserted non-empty —
a silently emptied group fails loudly.

## Gherkin scenario → test mapping

| Gherkin scenario | Tests |
|---|---|
| A validated track id opens the Spotify app | `SpotifyToolTests.testTrackURIUsesTheExactSpotifyTrackShapeAndCarriesNoTitleOrQueryText`; `SpotifyToolTests.testValidatedTrackIDOpensThroughTheProbeWithTheProbeResultAsTheOutcome` (probe true → `.opened`, exact probe-then-open order) |
| Hostile input never opens a link | `SpotifyDeepLinkTests`: the 13 `…IdentifiersAreRejected` category tests; `testWholeHostileCorpusIsRejectedWithoutReachingTheOpener` (zero constructions, zero opener events); `testHostileCorpusIsCompleteNamedAndCategoryCovered`; `testHostileGlyphsAtTheValidLengthAreRejectedOnTheScalarClass`; `testTheDeepLinkSourcesHaveNoLogOrEventSurface` + `testTheLogSurfaceScanFiresOnASourceThatDoesLog` (the "never a log" half); `testSearchHandoffRejectsEveryEmptyOrOverCapFixture`; `testSearchHandoffEncodesHostileQueriesInsideTheSpotifyScheme` |
| Spotify app absent degrades honestly | `SpotifyToolTests.testProbeReportingTheAppAbsentIsNotOpenedWithNoOpenCall`; `SpotifyToolTests.testOpenOutcomeHasNoPathThatTreatsProbeFailureAsSuccess` |
| Search hand-off follows the same grammar/encoding (§24) | `SpotifyToolTests.testSearchURIUsesTheSpotifySearchShapeAndPercentEncodesTheQuery`, `testSearchURIEncodesEveryDelimiterInTheGrammarSet`, `testSearchURIRejectsEmptyTrimmedAndOverCapQueries`, `testEveryDeepLinkConstructionStaysInsideTheSpotifyScheme` |

## Gate

Command (serialized through the shared worktree lock):

```
bash /tmp/spotify-lockrun.sh \
  /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
  ./build.sh test:unit SpotifyToolTests SpotifyDeepLinkTests
```

Observed (final run, 2026-10-07 00:33): `Test Suite 'SpotifyToolTests' passed
… Executed 39 tests, with 0 failures`; `Test Suite
'ElderlyAssistantTests.xctest' passed … Executed 59 tests, with 0 failures (0
unexpected)`; `** TEST SUCCEEDED **`; exit 0. 39 (SpotifyToolTests) + 20
(SpotifyDeepLinkTests) = 59 selected tests. A solo rerun of the new suite
(same lock wrapper, `./build.sh test:unit SpotifyDeepLinkTests`, 00:36) shows
its explicit summary: `Test Suite 'SpotifyDeepLinkTests' passed … Executed 20
tests, with 0 failures (0 unexpected)`; `** TEST SUCCEEDED **`; exit 0. The
build.sh log-safety gate and the intent-prompt mirror gate ran first inside
both scopes and passed.

Two intermediate runs (00:23, 00:28) failed to compile **in files owned by
the parallel T-110 agent**, not in this change set (`SpotifyAccountSession.swift:178`
main-actor isolation error; then `SpotifyAccountSessionTests.swift` argument/context
errors and an autoclosure-concurrency error while that agent was mid-refactor).
The parallel agent's fix landed at ~00:30 and the final run is green.

## Definition of done

- [x] Gherkin scenarios mapped above; the full hostile corpus has one named
      rejection assertion per fixture.
- [x] No PII in logs — this half has no log or event surface at all
      (pinned by the source scan); rejected and accepted material alike has
      no sink to reach (NFR-SP-002).
- [x] `OpenOutcome` has no path that treats probe failure as success.
- [x] `ios/build.sh` scoped unit gate green (above).
- [ ] Code reviewed and merged — orchestrator's per-wave commit.

## Deviations and decisions (surface, do not silently diverge)

1. **`open` re-validates nothing** (no scheme guard inside `open`). §24's
   "Scheme allowlist" sentence makes construction the enforcement point
   ("the tool constructs only `spotify:` URIs"), and V-4 pins the outcome to
   the probe alone — a guard returning a non-probe-derived outcome would
   violate that. The allowlist is enforced at construction
   (`validatedDeepLink`), pinned by tests, and the corpus proves no hostile
   input reaches the opener. No conflict with §24 found.
2. **Corpus committed as a Swift fixture file**, not a JSON/resource file:
   xcodegen auto-globs test sources, while a resource would need a
   `project.yml` edit (not owned by this task). The fixture file contains
   data plus the category vocabulary only — no assertions, no logic.
3. **Hygiene scan reuses `FeatureSourceScan`** (the existing LiveTranslate
   test helper, read-only; that file was not modified).
4. **`%` and `#` in the removal set** are already outside
   `CharacterSet.urlQueryAllowed`; the code spells §24's exact
   `+&=?/%#` subtraction so the constant matches the reviewed grammar
   verbatim and any drift is a visible edit.
5. **Extra corpus entries beyond the named list** (e.g. `@ ; ,` delimiters,
   Cyrillic/fullwidth homoglyphs, `\u{007F}`) are additive coverage of the
   same rejection rule, not a grammar change.
6. **`searchURI` keeps the §24 set exactly**, so `:`, `;`, `'` and other
   `urlQueryAllowed` characters stay unencoded inside the opaque
   `spotify:search:` payload (no test asserts otherwise). If a future review
   wants a narrower query alphabet, that is a grammar change to §24, not an
   implementation fix.
