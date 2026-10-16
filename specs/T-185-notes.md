# T-185 notes — Release log-surface gate coverage for the new chat paths

Unit: T-185 (TG-38), FR-CNR-012 / NFR-CNR-006 / NFR-CNR-011, design-l1 §16.
Worktree: `elderly-ai-assistant-conversational-nepali-replies` @ `feat/conversational-nepali-replies`
(branch tip at the time of this unit: `29ebf1a6`). No commits, no pushes, no ai-sdd mutating commands.

Declared files, both modified; nothing else in the repo was touched:

| File | Branch tip | After | Diff |
|---|---|---|---|
| `ios/tools/check-release-log-safety.py` | 897 lines | 1376 lines | +509 / −30 |
| `ios/tools/check-release-log-safety.sh` | 45 lines | 61 lines | +24 / −8 |

`git status --porcelain -- ios/tools/` shows exactly those two files modified. No fixture file,
no Swift source, no `ios/build.sh`, no other unit's tree (the parallel T-182 `tools/train-intent`
tree was never opened).

## 1. What was built

### 1.1 Roots — 8 added, 33 total

A `[CONVERSATIONAL-NEPALI-REPLIES T-185 / design-l1 §16, FR-CNR-012]` block appended to
`FEATURE_ROOTS` puts the feature's sources under the stricter role (rules 3–6 whole-file:
no Release-compiled console write at all; content forbidden in any configuration; event
fields inside the sanitizer's allow-list):

- `Services/Intents/CloudChat` (directory: `CloudChatRouting.swift`, `CloudChatConsentGate.swift`,
  `CloudChatConsentPrompt.swift`, `CloudChatActivityIndicator.swift`, `Views/CloudChatConsentSheet.swift`)
- `Services/Voice/ChatSampling.swift` (T-167 sampling seam)
- `Services/Voice/NepaliGrammarGuard.swift`
- `Services/Voice/KeywordIntentRule.swift`
- `Services/Voice/LlamaCommandInterpreter.swift`
- `Services/Gemini/GeminiClient.swift`
- `App/SettingsView.swift`
- `App/HomeSubviews.swift`

Every added root was verified to match ≥1 real file; the coverage self-test (`coverage-registry`
leg) now reports `33 root(s) and 7 event type(s) resolve under ElderlyAssistant/`, so a root can
never grade nothing silently.

### 1.2 Event-type registry — rules 5–6 applied by emission statement

New `FEATURE_EVENT_TYPES` (7 entries). The feature's emission sites in `CommandRouter.swift`,
`IntentRouter.swift` and `GeminiCommandInterpreter.swift` live in files that **cannot** join
`FEATURE_ROOTS` whole (section 5: each carries pre-existing console writes / unlisted keys of
its own, and rooting any of them would make the shipped-tree gate exit non-zero). Instead,
`judge_feature` was split (T-185) into:

- `judge_feature_payload(...)` — rules 5–6 (`feature-unlisted-metadata-key`,
  `feature-text-interpolated-into-event`), order preserved;
- `judge_feature(...)` — rules 3–4, then the payload judgment.

`scan()` now applies `judge_feature_payload` to two statement sets: every statement in a
feature-root file (unchanged), and every statement anywhere in the tree that names a registered
event type (`mentions_feature_event_type` whole-source cheap gate first). Rules 3–4 are
deliberately NOT applied by event type — a console write elsewhere in a shared file is never
this feature's offence.

Registry entries (4 specified by the task + 3 found in the audit, section 5.3):

- `reply_grammar_flag` (CommandRouter), `cloud_chat_fallback` / `cloud_chat_served` (IntentRouter),
  `cloud_chat_voice_control` (CommandRouter);
- `chat_respond_unusable` / `chat_respond_done` / `chat_respond_failed`
  (GeminiCommandInterpreter — the chat turn's provider seam; un-rootable file, so the
  statement pass is the only mechanism that can reach these sites).

### 1.3 Violations name the file AND the statement

`scan()` now fills `violation.source` with the offending source line for every violation family
(previously only the transcript console rules did). This is what the T-185 Gherkin requires
("fails, naming the file and the statement") and what lets the seeded legs assert the statement
text, not just the file.

### 1.4 Coverage self-test (`--self-test`) + wrapper step 3

Because the fixture harness is rule-shaped (a non-rule directory fails it) and fixture
directories are outside this unit's declared file set, the coverage proof rides on the existing
rule ids plus a self-test in the engine itself — the in-repo precedent is
`check-prompt-mirror.py --self-test` (T-170). `--self-test` builds temp trees
(`tempfile.TemporaryDirectory`), runs **the engine as a subprocess** (real exit codes) over
each, and inspects the verdict. 7 legs:

| leg | seed | expected |
|---|---|---|
| `coverage-registry` | none | every `FEATURE_ROOTS` entry resolves to ≥1 Swift file; every `FEATURE_EVENT_TYPES` entry is still emitted somewhere |
| `pristine-feature-paths` | clean templates | exit 0 |
| `seeded-raw-print-in-feature-path` | raw `print` in `Services/Intents/CloudChat/CloudChatRouting.swift` | RED, `feature-console-write`, file + statement |
| `seeded-content-write-in-feature-path` | Debug-guarded content print in `Services/Voice/NepaliGrammarGuard.swift` | RED, `feature-content-print` |
| `seeded-event-type-unlisted-key` | `cloud_chat_voice_control` emit with `metadata: ["transcript": …]` in `Services/Voice/CommandRouter.swift` | RED, `feature-unlisted-metadata-key` |
| `seeded-event-type-content-field` | `cloud_chat_fallback` emit with interpolated reply text in `Services/Intents/IntentRouter.swift` | RED, `feature-text-interpolated-into-event` |
| `off-root-control` | the same raw print at `Services/Voice/SelfTestOffRootControl.swift` | exit 0 (keeps the RED attributable to the root) |

`check-release-log-safety.sh` now runs three things in order: engine → fixture suite →
`--self-test`, each non-optional (a failure in any exits 1 with an actionable message; "never
delete the leg"). The docstring documents the contract, the event-type application anchoring,
and two new known limitations (section 6). Success output appends:
`33 feature root(s) grade no Release console write, no content-bearing field; / 7 feature event
type(s) are payload-graded at every emission site`.

## 2. Verification (amendment-4 cadence: no `./build.sh`, no xcodebuild, no test suite)

```
$ python3 -m py_compile tools/check-release-log-safety.py        # OK
$ ./tools/check-release-log-safety.sh                            # exit 0 (≈4.2 s wall)
  ✓ no transcript content or raw error object can be printed in a non-Debug
    configuration, and the live-camera-translation sources carry no console
    write or content-bearing event field
    33 feature root(s) grade no Release console write, no content-bearing field;
    7 feature event type(s) are payload-graded at every emission site
  log-safety fixtures: 24 case(s) over 12 rule(s)                # BASELINE: 24 / 12 — unchanged
  ✓ every rule has a positive and a negative fixture, and every fixture behaves
  log-safety coverage self-test: 7 leg(s)                        # all 7 ✓
  ✓ every root and feature event type resolves, every seeded violation is
    caught by name, and the off-root control stays quiet
$ python3 tools/check-release-log-safety-fixtures.py --falsify   # exit 0
  log-safety fixtures: 36 case(s) over 12 rule(s)                # 24 cases + 12 falsify variants
  ✓ every rule is load-bearing: disabling it makes its positive fixture pass
```

Fixtures before/after: 24 cases over 12 rules → 24 cases over 12 rules. No fixture was added,
edited or relaxed (the seeded-violation proof lives in the self-test, not the fixture layout).
The three transcript/error rule families, all 12 rules and `--falsify` behave exactly as before.

### 2.1 Seeded-violation demonstration (verbatim from the gate output)

```
    ✓ seeded-raw-print-in-feature-path
        caught by name:
        ElderlyAssistant/Services/Intents/CloudChat/CloudChatRouting.swift:7: [feature-console-write] console write in the feature's sources (route the signal through the sanitising observability bus)
        print("seeded release-compiled print")
    ✓ seeded-content-write-in-feature-path
        caught by name:
        ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift:9: [feature-content-print] recognized or translated text in a console write
        print("grammar guard: \(replyText)")
    ✓ seeded-event-type-unlisted-key
        caught by name:
        ElderlyAssistant/Services/Voice/CommandRouter.swift:12: [feature-unlisted-metadata-key] event metadata key 'transcript' is not in LogSanitiser.allowedKeys
        bus.emit(ObservabilityEvent(component: "command_router", eventType: "cloud_chat_voice_control", durationMs: nil, outcome: token, errorCode: nil, metadata: ["transcript": token]))
    ✓ seeded-event-type-content-field
        caught by name:
        ElderlyAssistant/Services/Intents/IntentRouter.swift:10: [feature-text-interpolated-into-event] recognized or translated text interpolated into an event field
        bus.emit(ObservabilityEvent(component: "intent_router", eventType: "cloud_chat_fallback", durationMs: nil, outcome: "info", errorCode: nil, metadata: ["reason": "\(reason) \(replyText)"]))
```

Each seed is deliberately placed in a file that is **not** a fixture and is the real shape a
later change would take (the raw print; the Debug-guarded content print that rule 4 must catch
in every configuration; the unlisted key; the interpolated text). The `off-root-control` leg
shows the same raw print outside every root is NOT rejected — the RED is attributable to root
coverage, not to the print shape alone.

### 2.2 Mechanism falsification (is the coverage load-bearing?)

In-process mutation cannot affect the legs (they run the engine as a subprocess by design), so a
mirror copy of the engine was made at `/tmp/t185-falsify/ios/tools/` with the real
`ElderlyAssistant` symlinked, mutated, and re-run:

| mutation | self-test verdict |
|---|---|
| A: `Services/Intents/CloudChat` removed from `FEATURE_ROOTS` | exit 1 — `seeded-raw-print-in-feature-path` fails |
| B: all 7 `FEATURE_EVENT_TYPES` entries removed | exit 1 — both `seeded-event-type-*` legs fail |
| C: `Services/Voice/NepaliGrammarGuard.swift` removed from `FEATURE_ROOTS` | exit 1 — `seeded-content-write-in-feature-path` fails |
| D: only `chat_respond_done` removed from the registry | exit 0 — **not** auto-caught (see section 6) |

## 3. Build wiring (confirmed by reading, not duplicated)

`ios/build.sh`, `run_tests()` (starts line 417): line **431** runs
`"${PROJECT_DIR}/tools/check-release-log-safety.sh"` with
`|| { echo "ERROR: Release-log privacy guard failed — see above." >&2; exit 1; }`, before the
per-scope `case` (~line 448) that dispatches every test scope. The gate's exit code therefore
gates the build ahead of every test scope; nothing was changed here.

## 4. Event emission-site validation (allowed-key set; no text in fields)

The event-type pass was instrumented (spy on `judge_feature_payload`) over the shipped tree:
the only non-root statements it inspects are the 7 CNR emission sites below — nothing wider,
nothing missed:

| site | event | payload | verdict |
|---|---|---|---|
| `CommandRouter.swift:2086` | `cloud_chat_voice_control` | `metadata: [:]`, `outcome: request.eventToken` (closed enum) | clean |
| `CommandRouter.swift:5013` | `reply_grammar_flag` | keys `origin` (=`path.rawValue`), `reason` (=`classes.map(\.rawValue).joined(separator: " ")` — enum raw values, a closed vocabulary, not caller text), `count` (=`String(attempts)`) | clean; all 3 keys allowed |
| `IntentRouter.swift:370` | `cloud_chat_served` | no payload | clean |
| `IntentRouter.swift:426` | `cloud_chat_fallback` | `metadata: ["reason": reason]` where `reason` is the closed `cloudChatFailureReason` token | clean; key allowed |
| `GeminiCommandInterpreter.swift:319` | `chat_respond_unusable` | `errorCode: "unusable_answer"` (literal) | clean |
| `GeminiCommandInterpreter.swift:324` | `chat_respond_done` | no payload | clean |
| `GeminiCommandInterpreter.swift:330` | `chat_respond_failed` | `errorCode: ErrorCodeMapper.code(for: error)` (content-free code) | clean |

Every metadata key is inside `LogSanitiser.allowedKeys` (the shipped authority, read from
source by the gate); no text value is interpolated into any field. The unit suites named in the
task (ReplyGrammarFlagResolutionTests, IntentRouterCloudChatLaneTests, CloudChatIndicatorAnd
RevocationTests) also scan these sites — that is a second, independent witness, not a substitute.

## 5. Coverage audit — no new content-rendering path left unscanned

### 5.1 Method

`git diff --name-status <merge-base(origin/master, HEAD)>..HEAD` → 162 changed paths, 29 Swift
files. Each was classified by the gate's own role logic (feature root / engine / event-typed /
other), and each "other" file was scanned for console-write and emission lines. Separately, the
CNR-added line ranges of the four shared files were extracted from `git diff -U0` and graded
under the feature role hunk by hunk.

### 5.2 Result, file by file

- **Joined a root (8 path entries, 12 files)** — all clean under the feature role (verified by
  the gate exiting 0): `Services/Intents/CloudChat/{CloudChatRouting,CloudChatConsentGate,
  CloudChatConsentPrompt,CloudChatActivityIndicator,Views/CloudChatConsentSheet}.swift`,
  `Services/Voice/{ChatSampling,NepaliGrammarGuard,KeywordIntentRule,
  LlamaCommandInterpreter}.swift`, `Services/Gemini/GeminiClient.swift`,
  `App/{SettingsView,HomeSubviews}.swift`. (`LlamaCommandInterpreter.swift` and
  `GeminiClient.swift` carry legitimate emission sites — catalogue passthroughs with allow-listed
  keys; the gate graded all of them clean before the roots were declared.)
- **Already covered before this unit, now additionally payload-graded:**
  `Services/Intents/IntentRouter.swift`, `Services/Voice/CommandRouter.swift` — rules 1–2
  (transcript/error) applied to them all along as part of the whole-tree scan; T-185 adds rules
  5–6 at their 4 registered emission sites (section 4). They stay "other"-role for rules 3–4.
- **Content-free by construction (audited, no root needed):** `App/L10n.swift` (strings only,
  0 console/emit sites); `Localizable.xcstrings` is not Swift; the test files under
  `ios/ElderlyAssistantTests/` are outside the gate's `--source-root` by design (three of them
  showed up in the raw scan only because they contain forbidden-token string arrays — they are
  the unit-level source scans, not writes); `SpokenReplyPolisher` was named by FR-CNR-012 but is
  not touched by the CNR diff. `ios/vendor/LLM.swift` is outside the source root by design; the
  CNR-side diff to it is T-167's access-level change only (`setParameters` made `public`, body
  unchanged) — no print was added there.
- **Per-hunk audit of CNR-added lines in shared files** (`CommandRouter`, `IntentRouter`,
  `AppCoordinator`, `GeminiCommandInterpreter`): 45 added hunk ranges, 7 console/emit lines in
  them, **0 feature-role offences** — every offence those files would produce if rooted is
  pre-existing (section 5.3). The feature's own hunks are clean.

### 5.3 Files that could NOT join the roots — pre-existing findings (REPORT ONLY, not edited)

Rooting any of these would make the shipped-tree gate exit non-zero; the findings are
**pre-existing** (0 of them fall in a CNR-added hunk) and the files are outside this unit's
declared set, so they were not edited. File + statement + key + recommendation:

| file | finding (pre-existing) | recommendation |
|---|---|---|
| `CommandRouter.swift` | unlisted keys: `:1895` `topic_pre_answer` key `topic`; `:2064` `intent_keyword_match` keys `domain`,`matched_keys`; `:4720` `chatLowConfidence` key `floor` | separate hygiene unit: add the keys to `LogSanitiser.allowedKeys` deliberately (or rename) — then the file could join the roots |
| `CommandRouter.swift` | `:5472` Debug-guarded content print rendering `\(text)`; `:5476` Debug-guarded print (flagged on the word `text`) | see DEBUG-guard finding below; the first is why rules 4 would red the file even under `#if DEBUG` |
| `IntentRouter.swift` | `:901` / `:921` `interpreter_selected` key `interpreter` | same follow-up: allow-list or rename |
| `AppCoordinator.swift` | 21 Release-compiled console writes (`:3702 :4304 :4428 :4498 :4558 :4682 :4700 :4739 :4873 :5012 :5398 :5430 :5471 :5497 :5534 :6530 :6533 :6610 :10191 :12997 :13812`) + unlisted key `cold_features` at `:4522`. Note `:13812` renders `clean.metadata` after sanitisation, and `:10191` is the `[cloud_cascade]` banner — all pre-date the CNR branch | large follow-up unit: these are the exact class the stricter role exists for; rooting `AppCoordinator` requires sweeping them first |
| `GeminiCommandInterpreter.swift` | `:141` Debug-guarded print rendering the raw + sanitized transcript | sweep with the `[gemini_interpreter][DEBUG]` family; the CNR-added `chat_respond_*` sites are now graded clean through the event registry |

No violation was surfaced in a CNR-added hunk of any file — the "report a real violation from
adding a root" case did not occur; these findings were known before rooting and are the stated
reason the four files are event-typed instead.

### 5.4 CommandRouter `[command_router][DEBUG] speak()` finding (requested either way)

All three console writes are Debug-guarded — `:5472` between `#if DEBUG` `:5471`/`:5473`,
`:5476` between `:5475`/`:5477`, `:5497` between `:5496`/`:5498`. They cannot be compiled into
Release. `:5472` is content-bearing (renders `text="\(text)"`), so it is exactly the print rule
4 (`feature-content-print`, judged in every configuration) would flag if the file were rooted —
recorded here as the reason the file stays "other"-role for rules 3–4.

## 6. Honest limitations (stated, not implied)

1. A single registry entry deleted outright is not caught automatically (falsification
   mutation D): the stale-entry check fires when an entry exists but its event is no longer
   emitted; removing the whole registry IS caught (mutation B, the seeded legs). No duplicated
   expectation list is kept — the source comment beside `FEATURE_EVENT_TYPES` now states
   exactly this, `ENGINE_FILES`-style.
2. Rules 3–4 are per file, so a content-bearing console write in a hunk added to a
   non-root shared file is not graded by them; for the CNR hunks the per-hunk audit (5.2) is
   the evidence and the feature's unit suites carry it forward. Recorded in the gate's docstring
   known-limitations block.
3. The AM-5 static-analysis limits (indirection, wrapper sinks, metadata-as-variable) are
   unchanged and remain stated in the docstring; a green gate means "no defect of these shapes",
   not "content cannot reach a sink".

## 7. DoD mapping

- [x] New feature paths inside the gate's coverage with the stricter role — 8 root entries
      added, 33 roots total, all resolving (self-test `coverage-registry`).
- [x] Gate exits zero over the shipped sources — exit 0, fixtures 24/24, self-test 7/7.
- [x] Runs ahead of the test scopes in the build — `ios/build.sh:431` (section 3, confirmed by
      reading; unchanged).
- [x] Seeded-violation demonstration recorded — 4 seeded legs, verbatim in 2.1; the mechanism
      itself falsified A–D in 2.2.
- [x] Event emission sites validated — 7 sites, 2.4/4: all keys allowed, no text interpolated.
- [x] Existing rule families and fixtures unchanged and passing — 24 cases / 12 rules before
      and after, `--falsify` green, no fixture file touched.
- [x] Coverage audit recorded — section 5, including the four report-only files and the
      per-hunk audit proving zero CNR-added offences.
