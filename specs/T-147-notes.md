# T-147 — MethodResolver global-default closure — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary`
(branch `feat/call-dialer-primary-secondary`, base eafa4bcc = wave 3). Unit: TG-29, wave 4,
risk MEDIUM, effort S. Depends on T-144; blocks T-149. Requirement: FR-CDP-012. Design
references: design-l2 §8 (`:447-472`), §14 row C3 (`:1052`), §15 step 3 (`:1063`), §19 test
list (`:1178`). Task spec: `specs/plan-tasks/tasks/TG-29-chain-core-and-record-corrections.md`
T-147 section (`:213-257`).

## Status

**Done — scoped gate green, nothing committed (coordinator records after paired review).**
Exactly the three owned files changed, one region each. No commit, no push, no ai-sdd
command, no new dependency, no network symbol. The wave-3 artifacts (CallChannelChain,
six-argument seams, `secondaryCallApp`) are consumed unchanged; T-154's parallel files
(`CallingSettingsView.swift`, the new `CallingSettingsSurfaceTests.swift`) were not opened.

## Files changed

| File | numstat (+/-) |
|------|---------------|
| `ios/ElderlyAssistant/Services/Intents/MethodResolver.swift` | 22 / 5 |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 9 / 2 |
| `ios/ElderlyAssistantTests/Services/Intents/MethodResolverTests.swift` | 70 / 2 |

The pbxproj delta visible in the worktree (`ios/seniOS.xcodeproj/project.pbxproj`, 4 added
lines) is T-154's mechanical xcodegen registration of `CallingSettingsSurfaceTests.swift`
only — this unit added no files, so no regeneration was triggered here.

## What was built

### 1. Resolver initialiser (design-l2 §8, verbatim shape)

```swift
init(preferenceStore: CallMethodPreferenceStore,
     historyStore: ConfirmedMethodHistoryStore,
     globalDefault: @escaping (_ isVideo: Bool) -> CallMethod = { _ in .phone }) {
```

Stored as `private let globalDefault: (Bool) -> CallMethod`. The defaulted closure maps
every call type to `.phone`, so both existing construction sites (the coordinator's lazy
property and the test helper) compile and behave identically.

### 2. Step 4 consults the closure

Steps one to three of `resolve` and the `explicitMethod` static are byte-for-byte
untouched (diff confirms no hunk inside either). Step 4 replaces the hardcoded `.phone`
with `globalDefault(isVideo)`, keeping `source: .globalDefault`:

```swift
let isVideo = callType.map {
    $0.lowercased().contains("video") || $0.contains("भिडियो")
} ?? false
return ResolvedMethod(method: globalDefault(isVideo),
                      unsupportedRequestedApp: nil,
                      source: .globalDefault)
```

The call-type sense is the same video-word test step 1 uses (duplicated deliberately:
extracting it would have edited step 1's helper, which the unit forbids).

### 3. Coordinator construction site (one region, `AppCoordinator.swift:1942`)

```swift
private lazy var methodResolver = MethodResolver(
    preferenceStore: callMethodPreferences,
    historyStore: confirmedMethodHistory,
    // FR-CDP-012: the settings primary, mapped by call type — a
    // video-word call versus a plain call (design-l2 §8). Read per
    // resolution, so a settings change applies from the next call.
    globalDefault: { [weak self] isVideo in
        CallChannelChain.method(for: self?.defaultCallApp ?? .phone, isVideo: isVideo)
    })
```

The closure body is design-l2 §8's snippet verbatim. It reads `defaultCallApp` at call
time (not at construction), so a settings change applies from the next resolution; the
`weak self` avoids a coordinator → resolver → closure retain cycle; `?? .phone` keeps the
shipped floor if the coordinator is gone.

### 4. Tests (`MethodResolverTests.swift`)

All 14 pre-existing tests and their assertions are untouched. The stub-storage helper
gained an optional third parameter (`globalDefault: ((Bool) -> CallMethod)? = nil`); when
nil it still constructs via the shipped two-argument initialiser, so every pre-existing
test exercises the unchanged call shape. Three tests added:

| Test | Scenario |
|------|----------|
| `testGlobalDefaultClosureMapsCallType` | Coordinator-shaped closure with settings primary `.faceTime`: closure returns `.facetimeVideo` for a video call; a bare call resolves at step four to `.facetimeAudio` (the unchanged voice mapping) with channel `.faceTime` and source `.globalDefault` |
| `testDefaultConstructionStillPhone` | Two-argument initialiser with absent stores: bare call → method `.phone`, channel `.phone`, source `.globalDefault`, nil unsupported-app |
| `testGlobalDefaultClosureReceivesCallTypeFlag` | Closed map: the closure records the flag `resolve` passes (`[false]` after a bare call) and returns per it; a bare video word returns at step 1 as `.explicit` `.facetimeVideo` without consulting the closure (steps 1–3 intact) |

## Gate

Command (from the worktree root): `ios/build.sh test:unit MethodResolverTests`

- Exit code: 0 — `=== Scoped unit run passed (baseline not advanced) ===`
- `Executed 17 tests, with 0 failures (0 unexpected)` (14 pre-existing + 3 new)
- Source privacy guard: green (24 fixtures over 12 rules, all positive/negative cases
  behaved)
- Intent-prompt mirror guard: green (seed mirrors `IntentPrompt.build` byte-for-byte,
  2717 bytes, 4 placeholders; all 7 drift self-tests rejected)
- No build-database lock contention encountered.

## Decisions and notes for the reviewer

1. **Design followed, not improvised.** The initialiser signature matches design-l2 §8
   (`:452-458`) and §14 row C3 (`:1052`) exactly; the coordinator shape matches §8's
   snippet (`:464-469`) exactly. No signature discrepancy was found between design and
   shipped code.
2. **Reachability observation (flag for review, disclosed in code and tests).** Through
   `resolve` with steps 1–3 unchanged, step 4 is only reachable when `requestedApp` is
   nil/empty and the call-type sense is false: a bare video word already returns at step 1
   as an explicit FaceTime choice (`explicitMethod`'s own comment: "asking for video IS a
   method choice"). So the closure's video arm is unreachable through this entry point
   today; the closure is wired exactly as the design freezes it, and
   `testGlobalDefaultClosureReceivesCallTypeFlag` proves what actually arrives is
   observable (`[false]`), rather than asserting a green that would depend on step 1
   coincidentally producing FaceTime. The video arm's mapping is pinned by the closure
   construction assertion in `testGlobalDefaultClosureMapsCallType`. A comment in step 4
   records the same fact for future readers.
3. **Behaviour-identity for existing call sites.** The default closure ignores both stores
   and all settings, so no stored preference or settings value changes behaviour for a
   two-argument construction beyond the shipped steps 2–3.
4. **Integration coverage.** The coordinator edit is compile-verified by the gate (app
   target builds and links) and its closure shape is exercised at the resolver seam by
   `testGlobalDefaultClosureMapsCallType`; end-to-end voice-path coverage (settings
   primary → confirmation → execution) belongs to T-149 per the plan and is not claimed
   here.

## Definition of done

- [x] Resolver init extended with the defaulted closure; existing constructions compile
      unchanged
- [x] Coordinator construction site maps the settings primary by call type
- [x] New and existing resolver tests green: `ios/build.sh test:unit MethodResolverTests`
- [x] Scoped run reports the privacy guard executed and passed (and the prompt-mirror
      guard, which runs in the same gate)
- [ ] Code reviewed and merged — coordinator's paired review + integration commit
