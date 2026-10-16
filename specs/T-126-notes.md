# T-126 — Curated option catalog and bundled resource — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`). Unit: C-MTC-04, TG-24.

## Status

Done. Loader + bundled resource + `project.yml` wiring + focused suite green
(10/10 tests, 2026-10-10 15:49 AEDT). One transient cross-unit compile blocker
was handled by retrying the locked gate, per protocol — details under "Open
items / deviations".

## Files created / modified

- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Services/Voice/DialogueOptionCatalog.swift`
- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Resources/DialogueOptionCatalog.json`
- MODIFIED `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/project.yml`
  (single-file app-target resource entry, same pattern as `DialectLexicon.json`)
- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/DialogueOptionCatalogTests.swift`
- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/specs/T-126-notes.md` (this file)

No other file was touched (no git commands; no ai-sdd CLI; no sibling unit's
files; no `specs/` or `.ai-sdd/` edits beyond this notes file).

## What was built

`DialogueOptionCatalog.swift` (design-l2 §11, C-MTC-04): `DialogueOption`,
`DialogueOptionGroup`, `DialogueOptionCatalog` with the pinned interface —
`init(data:) throws`, `load(bundle:resource:) throws`, `group(_:)`,
`groupForMusicQuery(_:)`, `option(matchingWholeValue:in:)`.

- **Schema v1 + fail-closed validation.** Decode runs through private
  `Payload`/`GroupPayload`/`OptionPayload` shapes; then: `version == 1`,
  non-empty `groups`; per group non-empty `id`/`questionKey`/`matchKeys`/
  `options`; per option non-empty `id`/`labelKey`/`query`/`aliases`
  (whitespace-only strings rejected). Any parse or schema failure throws the
  closed `DialogueError.catalogUnavailable` (T-125's error vocabulary — no
  local error type, per design §7/§8). All-or-nothing: the throwing init can
  never return a partially parsed subset.
- **Fail-safe load.** `load(bundle:resource:)` throws `.catalogUnavailable`
  for a missing resource or malformed data; the caller (T-134) stores nil and
  degrades to the free-text-only probe + default (§22 E3). The resource name is
  `bundledResourceName`; `supportedVersion` is 1.
- **Ordered groups (L2-D12).** `groups` is the JSON array order;
  `groupForMusicQuery` returns the first group (file order) whose `matchKeys`
  hit the canonicalized query; nil when nothing claims it.
- **Script-split matching idiom** (shared semantics with `KeywordIntentRule`'s
  vocabulary keys): canonicalization (lowercase + whitespace collapse) first;
  Devanagari keys and multi-word keys match by grapheme-aware
  `String.contains` (postposition fusion: "भजनहरू" ⊃ "भजन"); single Latin
  words match by whole-token equality ("bhajans" never matches "bhajan",
  "shivaji" never matches "shiva"). The pinned near-pair holds by cluster
  discipline: "गीत" is [गी][त] and "गीता" is [गी][ता] — different trailing
  clusters, so the shared script prefix never matches (Swift
  `"गीता".contains("गीत") == false`).
- **Data is the artifact.** `DialogueOptionCatalog.json` ships the design §11
  v1 JSON verbatim: the `bhajan.deity` group (`questionKey`
  `dialogue.probe.bhajanKind`, `matchKeys` ["भजन","bhajan"]) with shiva/durga/
  bishnu/devi — label keys, canonical queries ("`<deity>` bhajan") and
  ne/Latin alias lists. Alias lists are extendable without code (§6 gap 3).
  The "just play anything" default is deliberately NOT a catalog entry.
- **project.yml.** Explicit `buildPhase: resources` entry added beside
  `DialectLexicon.json`; the Swift file rides the existing source glob. The
  regenerated project was verified before/independently of the test run (see
  Evidence).
- **NFR-MTC-003 by construction.** Imports: `Foundation` only (tests:
  `XCTest` + `@testable import`). No URL session/client, no network symbol,
  no telemetry, no `print`, no observability metadata. The only file read is
  the bundle copy via the URL `Bundle` hands out.

## Tests

`ios/ElderlyAssistantTests/Services/Voice/DialogueOptionCatalogTests.swift`
(10 tests):

1. `testBundledCatalogParsesAndPreservesGroupOrder`
2. `testGroupForMusicQueryMatchesBoundedAliases`
3. `testGitaDoesNotMatchGeet`
4. `testGroupForMusicQueryFileOrder`
5. `testCanonicalQueriesResolveThroughTheCatalog`
6. `testDefaultOptionIsNotACatalogEntry`
7. `testMalformedDataThrowsCatalogUnavailable`
8. `testNoPartiallyParsedGroupsAreReturned`
9. `testLoadMissingResourceThrowsCatalogUnavailable`
10. `testResourceShipsInTheBundle`

### Gherkin coverage

| Scenario | Tests |
|---|---|
| The bundled catalog parses and preserves group order | 1 (version, array order, group present, label keys/queries/alias lists intact) |
| Lookup is whole-value or whole-token and script-exact | 2 (bounded aliases, whole-token Latin), 3 (गीता/गीत near-pair, both lookup paths) |
| Malformed catalog data fails closed | 7 (12 malformed payload shapes), 8 (valid + malformed = no partial load), 9 (missing resource) |
| Canonical queries resolve through the catalog | 5 (11 alias→query vectors incl. marker-dropped variants; unmatched text stays nil) |
| The resource ships in the app bundle | 10 (present, exactly-once enumeration, parses through the real load path) |

## Results — GREEN (2026-10-10 15:49 AEDT)

Command (locked, per the protocol; worktree `ios/`):

```
./build.sh test:unit DialogueOptionCatalogTests
```

- `DialogueOptionCatalogTests`: **10 executed, 0 failures**; `** TEST SUCCEEDED **`;
  `rc=0`; `=== Scoped unit run passed (baseline not advanced) ===`
  (`xcresult` `Test-ElderlyAssistant-2026.10.10_15-49-44-+1100.xcresult`).
- The run's pre-scope gates passed (source privacy guard; prompt-mirror gate),
  and `xcodegen generate` regenerated `seniOS.xcodeproj` inside the same run.
- No full-suite run (per the dispatch protocol: focused suites only).

### Evidence — project manifest and bundle presence

- Regenerated `seniOS.xcodeproj/project.pbxproj`: `DialogueOptionCatalog.json in
  Resources` appears exactly once, in the single app-target Resources build
  phase beside `DialectLexicon.json`; `DialogueOptionCatalog.swift` and
  `DialogueOptionCatalogTests.swift` sit in their targets' Sources phases.
- Built app product (the unit-test host):
  `ElderlyAssistant.app/DialogueOptionCatalog.json` present exactly once,
  byte-identical to the source resource (`shasum` SHA-1
  `e51de88ef5c4dc078618b96ca01705dd52dead57`), parses as version 1 with
  `groups == ["bhajan.deity"]`.
- `testResourceShipsInTheBundle` re-asserts presence + exactly-once
  enumeration + real-load parse at runtime through `Bundle.main`.

### Secondary host evidence

Before the app module could compile (see deviation 1), the same source file was
compiled and exercised on host Swift (macOS, real Foundation) against a
same-shaped `DialogueError` stub: 48/48 assertions pass, including the
गीता/गीत pin and every malformed-payload case. Kept as auxiliary evidence only —
the simulator suite above is the gate result.

## DoD checklist

- [ ] Code reviewed and merged — not in this unit (no git actions permitted here; the session integrates).
- [x] All Gherkin scenarios covered by automated tests (`DialogueOptionCatalogTests`) — 10/10 green.
- [x] `ios/project.yml` resource entry added and `xcodegen generate` re-run; bundle-presence test green — pbxproj + built-bundle evidence above; `testResourceShipsInTheBundle` passed.
- [x] No network client, URL session or telemetry code in the new files (NFR-MTC-003) — Foundation-only imports; grep-verified; no print/observability metadata.
- [x] Focused suite green: `DialogueOptionCatalogTests` (10/10). Scoped runs never advance the impact baseline and no other suite was run or touched; the "no new full-suite failures" comparison (baseline ~21 pre-existing master failures, unrelated suites) remains for the session's end-of-feature full gate.

## Open items / deviations

1. **Transient focused-run blocker (cross-unit, resolved).** The first locked
   attempt (14:30) failed compiling `DialogueManager.swift` (T-125, concurrent
   unit): `case answered(DialogueMerge)` with `DialogueMerge` not yet declared
   ("Cannot find type 'DialogueMerge' in scope" + the `Equatable` cascade). No
   error referenced this unit's files. Per protocol the gate was retried under
   the shared lock, never fixed here; T-125 landed the type (with `CaptureForm`
   and `MergeSource`) in `DialogueManager.swift` at 15:26 and the retried run
   at 15:49 went green. Integration note for the session: T-131 must NOT
   re-declare `CaptureForm`/`MergeSource`/`DialogueMerge` (a redeclaration is a
   compile error; the sibling T-127 notes carry the same note).
2. Nothing else outstanding in this unit.
