# T-121 notes — Release log-safety gate FEATURE_ROOTS extension

**Feature:** spotify-music-integration · **Worktree:**
`/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration`
(branch `feat/spotify-music-integration`, HEAD `1dce327`) · **Date:** 2026-10-07
**Task:** `specs/plan-tasks/tasks/TG-23-release-gates-security-evidence-and-device-validation/T-121-release-log-safety-gate.md`
**Requirement:** NFR-SP-002 (log safety) / NFR-SP-011 (release gates)

## 1. What changed

`ios/tools/check-release-log-safety.py`, `FEATURE_ROOTS` gains **two entries and a
per-feature comment** (15 entries before, 17 after). Exact diff (`git diff`):

```diff
@@ -164,6 +164,15 @@ FEATURE_ROOTS = [
     "App/ProfileSettingsModel.swift",
     "App/OnboardingDrafts.swift",
     "App/ProfileInterviewSteps.swift",
+    # [SPOTIFY-MUSIC-INTEGRATION T-121 / §20] The music feature's own roots:
+    # the whole Services/Spotify group (tool, transport, credential store,
+    # auth flow, session) and the plugin. Household music queries are user
+    # content: a Release console write or a content-derived event field
+    # anywhere in these files fails the gate — no exemptions for the new
+    # surfaces (design §20's `Services/Voice/SpotifyTool.swift` entry is a
+    # stale path; the tool lives in the Services/Spotify group below).
+    "Services/Spotify",
+    "Services/Plugins/SpotifyPlugin.swift",
 ]
```

- No new rule. No fixture added. No exemption-list additions —
  `LogSanitiser.allowedKeys` is untouched. `check-release-log-safety.sh` and
  `log-safety-fixtures/` are unchanged (not needed).
- Only this one file is modified in the worktree:
  `git status --porcelain` → ` M ios/tools/check-release-log-safety.py`.

### §20 path correction (deviation from the design's edit list — driver to annotate)

Design §20 (`specs/design-l2.md:358`) lists three entries. Verified against the
worktree:

- `Services/Voice/SpotifyTool.swift` — **stale path, dropped.** `Services/Voice/`
  contains `YouTubeTool.swift`, not `SpotifyTool.swift`. `SpotifyTool.swift` lives in
  the `Services/Spotify` group (`ios/ElderlyAssistant/Services/Spotify/`, alongside
  `SpotifyTransport`, `SpotifyCredentialStore`, `SpotifyAuthFlow`,
  `SpotifyAccountSession`, `SpotifyAuthError`, `ASWebSpotifyAuthSession`). The group
  entry covers it.
- `Services/Spotify/` — added as `"Services/Spotify"`, **no trailing slash** (the list
  convention: every existing entry is slash-free). The scan-loop match is
  `path == root or path.startswith(root + os.sep)`; a trailing slash would make both
  halves fail for every file in the group, so the prose `Services/Spotify/` must not be
  copied literally when §20 is annotated.
- `Services/Plugins/SpotifyPlugin.swift` — added as listed (exists at
  `ios/ElderlyAssistant/Services/Plugins/SpotifyPlugin.swift`).

Same three-entry (stale) list also appears at `plan.md:24-25`; both are driver-owned
annotations. The design was **not** edited here.

## 2. Clean-tree runs of the gate (Gherkin scenario 1)

**Invocation the build uses:** `ios/build.sh:431` runs
`"${PROJECT_DIR}/tools/check-release-log-safety.sh"` (`PROJECT_DIR` = `ios/`,
build.sh:63) before *every* test gate and exits 1 on failure. The `.sh` runs the rule
engine `check-release-log-safety.py` over the real tree, then the fixture suite
`check-release-log-safety-fixtures.py`. Verified in this worktree's build log (below).

| Command | Exit | Result |
|---|---|---|
| `bash ios/tools/check-release-log-safety.sh` (pre-change baseline) | 0 | gate ✓, `log-safety fixtures: 24 case(s) over 12 rule(s)`, all ✓ |
| `bash ios/tools/check-release-log-safety.sh` (post-change, clean tree) | 0 | gate ✓, 24/12 fixtures ✓ (log: `/tmp/t121-clean-gate-final.log`) |
| `python3 ios/tools/check-release-log-safety-fixtures.py` (direct) | 0 | 24 cases over 12 rules, every case ✓ ("every rule has a positive and a negative fixture, and every fixture behaves") |
| `python3 ios/tools/check-release-log-safety-fixtures.py --falsify` (bonus, not a build path) | 0 | every one of the 12 rules is load-bearing (its positive fixture stops failing when the rule is disabled) |

The fixture count/rule set is unchanged by design (24/12 before the change in
`/tmp/w4-gate-final.log:21`, 24/12 after): the harness is per-rule, not per-root.

**Scenario 1's "it inspects the new Spotify tool, store, session and plugin paths".**
The gate reports no per-file list, so coverage is evidenced by (a) the clean-tree exit 0
above, (b) the planted-violation classification proof in §3 (scanner-observed: a file in
`Services/Spotify` was judged in the `feature` role), and (c) an expression-level role
check that imports the shipped module and replays the scan loop's role expression
(`path == root or path.startswith(root + os.sep)`) over the shipped `FEATURE_ROOTS` —
labelled as replication, not scanner output:

```
feature  exists=True  Services/Spotify/SpotifyTool.swift
feature  exists=True  Services/Spotify/SpotifyTransport.swift
feature  exists=True  Services/Spotify/SpotifyCredentialStore.swift
feature  exists=True  Services/Spotify/SpotifyAuthFlow.swift
feature  exists=True  Services/Spotify/SpotifyAccountSession.swift
feature  exists=True  Services/Spotify/SpotifyAuthError.swift
feature  exists=True  Services/Spotify/ASWebSpotifyAuthSession.swift
feature  exists=True  Services/Plugins/SpotifyPlugin.swift
other    exists=True  Services/Voice/CommandRouter.swift
other    exists=True  Services/Voice/KeywordIntentRule.swift
other    exists=True  Services/Voice/LocalToolLogStore.swift
other    exists=True  Services/Voice/YouTubeTool.swift
FEATURE_ROOTS entries: 17
stale path exists: False
```

## 3. Planted-violation demonstration (Gherkin scenario 2; security evidence for T-123 obligation 6)

Temporary file — **not a fixture** (design §20: no new fixture required; per instructions
the scenario is demonstrated honestly, then removed). Planted at
`ios/ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift`:

```swift
// TEMPORARY — T-121 planted-violation demonstration (security evidence for
// T-123 obligation 6). Not part of the product. Removed immediately after the
// gate run it exists for; the recorded transcript lives in specs/T-121-notes.md.
import Foundation

enum SpotifyPlantedViolationDemo {
    static func consoleWrite(query: String) {
        print("spotify search: \(query)")       // rule 3 only
    }

    static func contentWrite(queryText: String) {
        print("search term: \(queryText)")      // rules 3 + 4
    }

    static func transcriptWrite(transcript: String) {
        print("heard: \(transcript)")           // rules 1 + 3 + 4
    }

    static func rawErrorWrite(error: Error) {
        print("failed: \(error)")               // rule 3 only: rule 2 is engine-scoped
    }
}
```

Run 1 — rule engine direct: `python3 ios/tools/check-release-log-safety.py` →
**exit 1**, full output:

```
ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift:16: [transcript-print] transcript content in a print outside #if DEBUG
    print("heard: \(transcript)")           // rules 1 + 3 + 4
ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift:8: [feature-console-write] console write in the feature's sources (route the signal through the sanitising observability bus)
ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift:12: [feature-console-write] console write in the feature's sources (route the signal through the sanitising observability bus)
ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift:12: [feature-content-print] recognized or translated text in a console write
ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift:16: [feature-console-write] console write in the feature's sources (route the signal through the sanitising observability bus)
ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift:16: [feature-content-print] recognized or translated text in a console write
ElderlyAssistant/Services/Spotify/SpotifyPlantedViolationDemo.swift:20: [feature-console-write] console write in the feature's sources (route the signal through the sanitising observability bus)
  ✗ 7 Release-log privacy violation(s) (B1/T-049, AM-5).
    A transcript, a recognized or translated string, or a raw error object
    must not be rendered by a print that compiles into Release: wrap it in
    #if DEBUG, delete it, or route a content-free signal (count/duration/
    domain+code) through the sanitised observability bus — never the raw
    content. The feature's sources carry no console write at all, in any
    configuration, and their event fields are counts, closed tokens or the
    disclosure version — never a text value.
```

Run 2 — the build's own entry point, `bash ios/tools/check-release-log-safety.sh` →
**exit 1** (same named output on the first lines; the wrapper exits 1 and does not
proceed to the fixture step, exactly as `build.sh:431` requires).

What each violation line demonstrates:

- **line 8** (content-free `print("spotify search: \(query)")`) →
  `[feature-console-write]` only: rule 3 fires on *any* console write in the new root.
- **line 12** (`queryText`) → `[feature-console-write]` + `[feature-content-print]`:
  rule 4 (content-worded console write; camelCase `…Text` tail caught).
- **line 16** (`transcript`) → `[transcript-print]` + `[feature-console-write]` +
  `[feature-content-print]`: rule 1 remains global and also applies inside the new
  root.
- **line 20** (`print("failed: \(error)")`) → `[feature-console-write]` only: the
  rule-2 raw-error family (`string-describing` / `error-description` /
  `error-interpolation` / `error-argument`) did **not** fire in the feature root —
  engine-file scoping observed directly. (The same shape *is* caught when the file
  bears an `ENGINE_FILES` name: the `error-interpolation/positive` fixture.)

Cleanup: file removed; `git status --porcelain -- ios/ElderlyAssistant/Services/Spotify/`
empty; full status back to only ` M ios/tools/check-release-log-safety.py`.

## 4. Rule scoping on the new roots (Gherkin scenario 3) — verified vs. reasoned

| Rule family | Scope implemented | Evidence |
|---|---|---|
| 1 — `transcript-print`, `transcript-taint` | every file | Code read: the transcript checks in `judge_console` are unconditional (the `engine` flag gates only the error rules). Fixture: `transcript-print/positive` plants in `Services/Voice/ExampleEngine.swift` — an `other`-role path (not an `ENGINE_FILES` name, not a feature root); the harness requires exit 1 **and** the rule named, and it passes. Planted run: rule 1 named inside `Services/Spotify`. |
| 2 — `string-describing`, `error-description`, `error-interpolation`, `error-argument` | engine files only (`ENGINE_FILES`) | Code read: `judge_console`'s `error_object_offence` only runs when `role == "engine"`. Fixtures: the four error-* positives plant in files named `WhisperSpeechRecognizer.swift` / `WhisperKitSpeechRecognizer.swift` (engine role) and name their rule. Planted run: the same `print("failed: \(error)")` shape in a feature root names only `feature-console-write`. |
| 3–6 — console write, content-worded write, unlisted metadata key, content-derived event field | only inside `FEATURE_ROOTS` | Planted run: rules 3/4 fired in the new root and nowhere else in the run. Fixture precedent: `feature-console-write/positive` pins `App/ProfileInterviewSteps.swift` via its `expect` file — "the planted violation in a newly added scan root is the one reported". Scenario 3's "fixtures demonstrate both pass and fail" = the 24-case suite (§2). |

Reasoned, not separately demonstrated: the in-place files (`CommandRouter.swift`,
`KeywordIntentRule.swift`, `LocalToolLogStore.swift`, `VoiceContactSearchRoute.swift`,
`ToolLogReviewView.swift`, `SettingsView.swift`, `SettingsTabs.swift`,
`AppCoordinator`) stay in the `other` role — the role-expression check above shows
`other` for the three reachable by path, and no entry added matches their paths
(reasoning from the shipped match expression; planting violations in them is outside
this task's file ownership). Their coverage under rules 1–2 is the project's
established position (§20).

## 5. C-2 record (documentation-only condition)

`plan.md:141-143` (worktree): *"Documentation-only correction of the §20 rule-scope
sentence (rule 1 all files, rule 2 engine files, rules 3–6 feature roots). No task
exists for it because no code changes; T-121 implements the correct scoping and notes
this."* The task's Gherkin scenario 3 states the same model.

- The shipped engine already implements exactly that model — verified in §4 (rule 1
  global; rule 2 family engine-gated; rules 3–6 feature-roots-gated). This change adds
  roots only; it does not alter scoping.
- The design's only rule-scope sentence is `design-l2.md:356` (§20 "Verified
  mechanics"): *"Rules 1–2 (transcript taint, raw-error rendering) apply to every
  file; rules 3–6 … apply only inside `FEATURE_ROOTS`."* That is exact for rule 1 and
  loose for rule 2 if read standalone (the raw-error family is engine-gated, per the
  engine's own docstring and the error-* fixtures). Design §14 (C-SP-07,
  `KeywordIntentRule`) carries no scope statement.
- **C-2 satisfied for this task by this record:** no code action (the scoping this
  task ships is the correct one), no design edit by me — the §20 prose correction is
  the wave-closure annotation the driver owns (along with the stale path in §20 and
  plan.md:24-25).

## 6. Build-path proof (gate runs inside every build scope)

```
bash /tmp/spotify-lockrun.sh /Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration \
    ./build.sh test:unit SpotifyPluginTests
```

→ **exit 0**, log `/tmp/t121-build-gate.log`. Run under the cross-agent lock, after
the planted file was removed. Inside the log:

```
17  Checking source privacy guards...
18    ✓ no transcript content or raw error object can be printed in a non-Debug
19      configuration, and the live-camera-translation sources carry no console
20      write or content-bearing event field
21    log-safety fixtures: 24 case(s) over 12 rule(s)
```

followed by the scoped unit run: `Executed 19 tests, with 0 failures`,
`** TEST SUCCEEDED **`, `✓ unit tests passed`, `=== Scoped unit run passed (baseline
not advanced) ===`. xcresult:
`ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.07_01-55-09-+1100.xcresult`.

## 7. Deviations and open items

1. **§20 stale entry dropped** (3 listed → 2 real entries), per the verified path
   correction; the group entry covers `SpotifyTool.swift`. Driver to annotate §20 and
   `plan.md:24-25` at wave closure (design left untouched here).
2. **No new fixture** — the harness is per-rule and fixture-complete (24/12); design
   §20 says none is required, and the scenario-2 requirement is met by the temporary
   planted run recorded above (transcript retained for T-123 obligation 6).
3. **No merge/commit/push** (per instructions). The worktree's only change is the one
   intended file plus this note. The parallel agent's files were not present in the
   worktree during these runs (`git status` showed only ` M
   ios/tools/check-release-log-safety.py`), so the green results cover exactly this
   change; re-run the gate at wave closure after both agents' files land.
4. The trailing-slash nuance (§1) is recorded so the §20 annotation does not introduce
   a broken group entry.
