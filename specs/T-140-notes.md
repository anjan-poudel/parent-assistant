# T-140 — Cache-bypass, log-capture and egress suites (E4/E5/E6/E8) — Implementation Notes

**Unit:** T-140 (multi-turn-conversation, wave W5) — **Status: complete, focused gate green in one locked run (117/117)**
**Worktree:** /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation (branch `feat/multi-turn-conversation`, HEAD cc065b0)
**Date:** 2026-10-10

## What was built

Two new focused suites providing the runtime witness set for security obligations E4 (log capture),
E5 (closed vocabularies), E6 (egress) and E8 (cache/history boundary, FR-MTC-017), plus the V-3
re-verification. Both mirror the `CommandRouterDialogueTests` draws: real `CommandRouter`, real
`IntentRouter`/catalog/`AppCoordinator` where the row demands it, counting doubles at the seams,
deterministic (expectation-based delivery drains, no sleeps anywhere).

### Files created

1. `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/DialogueCacheBypassTests.swift` (603 lines, 4 tests)
2. `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Observability/DialogueLogAndEgressTests.swift` (956 lines, 5 tests)

No other file was touched. The worktree is **not committed** (per dispatch).

### E-row → witness map

**E8 / FR-MTC-017 — `DialogueCacheBypassTests`**

| Test | Witness |
|---|---|
| `testACachedAnswerThatWouldMatchIsNotServedOnTheAnswerTurn` | Seeds the real `IntentCommandCache` (via `IntentRouter.recordConfirmedExecution`) with an entry for the answer utterance ("शिव भजन"). The answer turn on an armed frame resolves `.answered(merge "shiva bhajan", .repetition, .catalog)` and executes — while `interpretCount == 0`, cache `reads == 0`, `writes == 0` and NO `cache_hit` event occur. Post-delivery, the *same* utterance re-routed with no frame DOES reach the interpreter and DOES hit the seeded entry (reads ≥ 1, `cache_hit` present) — the causal A/B proving the entry would have matched and the frame path bypassed it. The cache state after the turn is exactly the seeded entry (`recordedTranscripts == ["शिव भजन"]`). |
| `testTheAnswerTextIsNeverInternedIntoTheCache` | Cold cache: an executed answer turn writes nothing (`writes == 0`); the re-route afterwards misses (reads ≥ 1, no `cache_hit`, still `writes == 0`). |
| `testPendingTranscriptStaysNilOnFrameExecution` | `Mirror` reads the private carrier as nil mid-turn and after async delivery; both assignment-site counters are 0 (`interpretCount == 0`, `rephraseTakes == 0`); source pin: the six dialogue regions of `CommandRouter.swift` (raw-read) contain ZERO references to `pendingTranscript`, and the two legacy assignment sites occur exactly once each, outside every region. Positive control: a call turn on the same machinery delivers the raw transcript to `requestCallConfirmation` (`callConfirmationSourceTranscripts == ["छोरालाई फोन गर"]`) — the nil readings above are causal, not a blind spy. |
| `testConfirmedExecutionRecordingIsUnchanged` | Negative control: a confirmed cacheable call IS interned (`writes == 1`) and IS served on the next lookup with a `cache_hit`; a non-cacheable reminder stays out (`writes` still 1). The recording machinery was not touched by the bypass discipline. |

**E4 — capturing sink over the production pipeline.**
`DialogueLogAndEgressTests.testTheFullDialogueScenarioSetEmitsOnlyAllowListedKeysAndNoContent` drives the
production `ConsoleObservabilityBus(sanitiser: LogSanitiser())` (the same class `AppCoordinator:2561`
installs as its default bus) under `dup`/`dup2` capture across eight legs: probe, answer, merge
(candidate), cancel, timeout, escape, exhaustion + `defaultExecuted`, and did-you-mean. Seven
distinctive marker tokens (`zmtcanswerx`, `zmtcmerge`, `zmtccancelx`, `zmtctimeoutx`, `zmtcescapex`,
`zmtcexhx`, `zmtcdym`) are planted in the seeded transcripts / candidate label / merge values / rephrase
hypothesis and appear in the resolved merges and executed URLs — but in NO sink line. Every metadata key
seen in a `dialogue_*` line is a member of `LogSanitiser.allowedKeys`; every dialogue-line key is in the
runtime vocabulary `{intake, probe_kind, attempt, option_count, capture_form, merge_source, reason, outcome}`
(suite-level pin: the observed set EQUALS the documented set); per-scenario expected pairs are asserted by
substring (probe `slotFill`/`attempt 1`/`option_count 4`; answer `freeText`/`freeText`; merge `candidate`;
cancel/escape/timedOut `outcome` values; exhaustion `attempt 2`/`option_count 4`/`reason degenerateAnswer`/
`defaultQuery`; did-you-mean `candidateChoice`/`option_count 2`). R1: the sink-line scan matches only
lines in the bus's own `[HH:mm:ss.SSS][component] …` format, so the legacy `DebugConfiguration` print in
`CommandRouter.speak(text:)` sits outside the scanned set by construction; independently, the suite asserts
no marker token appears anywhere in the captured console text at all.

**E5 — closed vocabularies and the allow-list diff.**
`testTheClosedVocabularyRedactsOutOfVocabularyTokensAndDropsUnlistedKeys` (runtime, production bus):
an out-of-vocabulary `probe_kind` value is replaced by `[redacted]` (pair kept); an unlisted key is dropped
whole (neither key nor value appears); `reason` passes its value verbatim — the reused generic key is
deliberately not value-constrained at the bus. Allow-list diff row, verified at runtime rather than trusted:
six dialogue keys ⊆ `allowedKeys`, total **84** (78→84, exactly +6), `reason` present, and `reason` NOT in
the six-key dialogue set.
`testTheInvalidAnswerReasonStaysClosedAtTheProducer`: T-133's over-length fixture (guard `.pass`,
`raw.count > InputSanitiser.maxLength`) routes to exactly one `dialogue_answer … outcome=invalid` line whose
`reason` ∈ `{overLength, emptyAfterStrip, degenerateAnswer, noCandidateClaimed}` and equals `overLength` —
the producer-side closure of the reused key.

**E6 / NFR-MTC-003 — no egress.**
`testNoDialoguePathConstructsNetworkEgress` (source audit): forbidden set
`[URLSession, URLRequest, URLComponents, URL(string:, http://, https://, NWConnection, NWPathMonitor, CFNetwork, dataTask, fetchData(for:, LocalToolTransport]`
over (a) the four dialogue files, whole-file comment-stripped — zero hits; the catalog's one URL-shaped
construct `url(forResource:)` (local bundle read) pinned explicitly; (b) the six `CommandRouter.swift`
dialogue regions (raw slices; every anchor verified unique and in order) — zero hits; (c) the coordinator's
dialogue extension region — zero hits.
`testTheExecutedDialoguePathsReachNoTransportAndOnlyTheOfflinePlaybackHelper` (runtime): five legs (probe,
answer, merge, cancel, exhaustion+default) with 20 injected spy transports across the weather / search /
YouTube / Spotify seams — every spy's request list is empty; every executed open equals
`YouTubeTool.appSearchURL(query:)` for a recorded merge value (or the pending default query). Merged music
execution reaches the pre-existing offline playback helper ONLY.

**V-3 — re-verification record (observed, not assumed).**
Claims under re-verification: answer turns do not run the interpreter, do not touch the intent cache, never
intern the answer text, and never populate `pendingTranscript`. Observed in this build: `interpretCount == 0`
on the answer turn while a matching seeded entry demonstrably exists (it is hit by the control re-route);
`reads == 0 && writes == 0` during the answer turn and the cache afterwards contains exactly the seeded
entry; no `cache_hit` on the answer turn; `writes == 0` on a cold-cache answer turn and the follow-up route
misses; `pendingTranscript` nil mid-turn and post-delivery with both assignment sites' counters at 0 and a
positive control proving the carrier is observable when legitimately used; `recordConfirmedExecution` still
interns/serves (negative control) so the zero readings are not artifacts of a broken recording path. All six
`CommandRouter.swift` dialogue regions contain zero `pendingTranscript` references even including comments.

## Results — GREEN

Gate command (shared build lock `/tmp/mtc-w1-build.lock` held throughout; only the mandated scoped form):

```
cd /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios && ./build.sh test:unit DialogueCacheBypassTests DialogueLogAndEgressTests LogSanitiserTests CommandRouterDialogueTests DialogueAnswerPathTests DialogueCoordinatorWiringTests
```

**Red-run history (honest):** run 1 — log `/tmp/t140-gate.log`, xcresult
`…/ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_19-16-19-+1100.xcresult`
(audit copy: `/tmp/t140-gate-red.xcresult`), **GATE rc=65**. One failure, in this unit's file:
`DialogueCacheBypassTests.testPendingTranscriptStaysNilOnFrameExecution` — `XCTUnwrap failed: region anchor
missing: interception`. Root cause: the source pin loaded `CommandRouter.swift` through
`FeatureSourceScan.codeText(of:)`, which strips comments **by design**, while the six region anchors are
comment lines — the slice could never match. Fix (one edit, my file only): read the file raw
(`String(contentsOf:encoding:)`, the same idiom the already-passing E6 suite uses for the identical six
regions), with a comment recording the rationale. Predicates verified on the raw text before re-running:
each anchor occurs exactly once, in order (anchors at lines 1021/1130, 2953/3342, 878/944, 1475/1488,
2285/2297, 4019/4034); all six raw regions contain zero `pendingTranscript` mentions; each assignment
string (`pendingTranscript = taken.sourceTranscript`, `self.pendingTranscript = raw`) occurs exactly once.
No sibling file was touched.

**Green run (the unit gate, one locked run):** log `/tmp/t140-gate2.log`, xcresult
`…/ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_19-21-01-+1100.xcresult`
(audit copy: `/tmp/t140-gate2.xcresult`), **GATE rc=0**:

```
Test Suite 'ElderlyAssistantTests.xctest' passed
  Executed 117 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
  ✓ unit tests passed
=== Scoped unit run passed (baseline not advanced) ===
GATE rc=0
```

Per-suite counts (walked via `xcrun xcresulttool get test-results tests`):

| Suite | Result | Tests |
|---|---|---|
| DialogueCacheBypassTests (this unit) | green | 4/4 (0.61s / 0.0027s / 1s / 0.62s) |
| DialogueLogAndEgressTests (this unit) | green | 5/5 (0.14s / 0.0037s / 3s / 3s / 0.0082s) |
| LogSanitiserTests | green | 34/34 |
| CommandRouterDialogueTests | green | 21/21 |
| DialogueAnswerPathTests | green | 36/36 |
| DialogueCoordinatorWiringTests | green | 17/17 |
| **Total** | | **117/117** |

The release-log safety gate ran inside the same build (24 fixtures over 12 rules, all green); the
intent-prompt mirror gate and privacy guards also passed in both runs.

## Definition of done

- [x] Both suites exist at the exact mandated paths; mirror the `CommandRouterDialogueTests` draws
  (counting storage/interpreter doubles, real router, seeded cache, real catalog/`AppCoordinator` where
  required); deterministic; injected clock/doubles; **no sleeps** (bounded expectation delivery drains only).
- [x] E8/FR-MTC-017: confirmed-entry bypass with the causal A/B extended across the persistence boundary;
  answer text never interned; `pendingTranscript` nil on the frame path (Mirror + counters + source pin +
  positive control); confirmed-execution recording unchanged as the negative control.
- [x] E4: capturing log sink driven through the production pipeline (LogSanitiser + allow-list) over probe,
  answer, merge, cancel, timeout, escape, exhaustion and did-you-mean; marker tokens never in sink payloads;
  only allow-listed keys observed.
- [x] E5: allow-list diff verified at runtime (exactly six documented keys, 78→84, `reason` REUSED);
  out-of-vocabulary token rejected/redacted by production machinery; producer closure of `reason` pinned.
- [x] E6/NFR-MTC-003: source audit (four dialogue files + six router dialogue regions + coordinator region);
  runtime spy over probe/answer/merge/cancel/exhaustion/default — merged execution reaches the existing
  offline playback helper ONLY, zero transport requests.
- [x] V-3 re-verification recorded (observed vs assumed, above).
- [x] Focused gate green in one locked run — 117/117, rc=0; lock released after the green run.
- [x] No file outside the two suites touched; no commits made.

## Decisions and deviations (with rationale)

1. **One red run then a one-edit fix (the honest history above).** The failure was in this unit's own file
   (comment-stripping scanner vs comment anchors), fixed once, re-run as the full six-suite gate. The
   dispatch's retry-not-fix rule applies to sibling-file failures; none occurred.
2. **Raw-read for the router source pin.** `FeatureSourceScan.codeText` is the right tool for symbol scans
   (its doc comment says comments are removed by design) and the wrong one for comment-delimited slices;
   both suites now slice the raw file, which is also the tighter E8 claim (zero `pendingTranscript`
   references *including comments*).
3. **Interception region anchor is the `§12.2` heading (line 1021)** — the region whose end anchor is the
   deterministic safety net in `route()` — not the `§12.1` mentions elsewhere (lines 110, 559); the six
   anchors are each unique in the file (verified before and inside the test).
4. **File-private `LogInMemoryProfilePayloadStorage` in the E4 suite.** Every repo definition of that fake
   is file-scoped; the timeout leg needs a real `AppCoordinator`, so the suite mirrors the established fake
   shape from `DialogueCoordinatorWiringTests` (lines 790-813) rather than widening another file's symbol.
5. **Timeout leg drives the real coordinator's timeout seam** (`voiceSession.onSlotAnswerTimeout?()`), not a
   timer — deterministic event exercise with no sleeps; the `[app_coordinator] … outcome=timedOut` emitter
   is exercised for real and observed in the sink scan.
6. **The did-you-mean fixture pairs the rephrase hypothesis with a near-match transcript ("समाचार")** —
   `DialogueCandidateBuilder.build` appends the hypothesis only alongside non-empty near-matches (R2
   never-alone); the suite additionally asserts the marker is *inside* the armed frame's candidates and in
   the spoken text, so the marker-absence claim is non-vacuous.
7. **E5 allow-list row re-verified at runtime** (count 84; contains `reason`; `reason` absent from the
   six-key dialogue vocabulary) instead of trusting T-137's notes — "verify, don't assume".

## Integration notes (for T-141 / T-142)

- The E-row → witness map above is the runtime evidence set for the security evidence index; the red-run
  xcresult (audit copy `/tmp/t140-gate-red.xcresult`) is preserved for provenance; worktree test bundles
  are pruned by later runs, hence the `/tmp` copies.
- Suite 1 extends `CommandRouterDialogueTests` test 1 across the persistence boundary (same utterance,
  same seeded cache, same expected resolution value) — the three suites now cover intent-before-executor,
  executor, and cache/history-after-executor for the answer path.
- Suite 2's runtime E6 net covers the four currently injected transport seams; a future wave that adds a
  new dialogue execution seam must extend the explicit `EgressSpyTransport` set.
- The runtime dialogue key vocabulary is pinned at suite level to exactly
  `{intake, probe_kind, attempt, option_count, capture_form, merge_source, reason, outcome}`; extend the pin
  only alongside a legitimate new key (which also reopens the T-137 allow-list row).
- The E4 suite's console-capture idiom is scoped to timestamped bus lines; if the bus format ever changes,
  update the anchored regex there (it fails loudly, never silently passes).

## Open items

- None blocking. Feature-level full-suite sweep and device validation (T-143 protocol) happen at the
  feature gate, not in this unit.
