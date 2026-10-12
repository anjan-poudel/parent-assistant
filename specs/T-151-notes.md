# T-151 — Tap rows: row channel state, announce and hop — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary`
(branch `feat/call-dialer-primary-secondary`, base `54574bb3`). Unit: TG-31, risk HIGH.
Assigned requirements (task file): FR-CDP-010 (tap buttons route the chain), FR-CDP-016
(automatic routing with announcement), NFR-CDP-002 (local probes, no new egress); also touched,
cross-cutting: FR-CDP-004/005/007/015, NFR-CDP-004, SA-3 (the address-book row surface). Design references: design-l2 §9.1 row-tap listing (`design-l2.md:654-688`), the
row-state call form (`design-l2.md:623-651`), §10.2 `LaunchHop`/step/helper (`design-l2.md:824-900`),
L2-D3 (the defaulted-memberwise lesson), L2-D10 (the row state carries both provenance fields),
ADR-CDP-07 (announce at resolution, BEFORE the open), RES-10 (the floor is terminal).
Carried fixes (W6 review, `specs/implement-review-w6-t149.md`): **N-1** (the tap helper's `.faceTime`
leg omits the hop) and **N-4** (`LaunchHop` carries no phone; the messenger opener's hopped floor
leg cannot dial the row's real number — disposition recorded in `specs/implement-notes.md` W7
point 4). Task spec: `specs/plan-tasks/tasks/TG-31-tap-paths-dial-back-and-settings.md` T-151
section (`:26-76`).

## Status

**Implemented — production and tests delivered; a scoped gate run was ATTEMPTED and FAILED AT
BUILD (see Gate below), the fix landed, and a compile-only check is green on the delivered bytes.
The scoped unit runs and the required negative control are DEFERRED to the consolidated
end-of-feature sweep, per a mid-task orchestration process change (message from the `sdd-run`
session: skip the negative-control run, do not start new gate runs — reviews and test gates
consolidate to a single sweep at feature end). No test in this unit has been executed against a
run yet — the tests are unaudited-against-run; they have only been proven to COMPILE (which the
gate attempt itself proved for the T-151 file, and the full build-for-testing check proved for
both files after the fix).** Nothing committed, nothing pushed, no ai-sdd command run, no
`git clean`/`restore`. `CallChannelChain.swift` byte-frozen (read-only scan input). No new
catalogue key; no new console-write site beyond the shipped emit; no new dependency. `git status`
lists only the two production files + the two test files (plus the pre-existing untracked
`.ai-sdd/workflows/workflow.yaml` engine state, outside this unit's artifact surface).

## Files changed

| File | numstat (+/-) | Hunks |
|------|---------------|-------|
| `ios/ElderlyAssistant/App/LeafViews.swift` | 80 / 25 | 5 |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 91 / 22 | 5 (shared with T-152) |
| `ios/ElderlyAssistantTests/Services/Voice/CallChannelResolutionTests.swift` | 477 / 0 | 2 (pure additive) |

The test file is PURE ADDITIVE — `git diff --numstat` shows 0 removed lines; the pre-existing 34
tests (26 shipped + 6 T-149 + 2 T-150) are byte-frozen, including T-149's two indexed lines
(`lines[0]`/`lines[1]` at `:1078-1079`, untouched — the new tests use crash-safe
`.first`/`.dropFirst()` access instead). The production files' removed non-comment lines are
exactly the intended rewrites (`git diff -U0 | grep '^-'`, comment lines excluded):

```
-            performFaceTimeCall(name: name, phone: phone, video: isVideo)      ← N-1 fix replaces it
-        switch rowChannelState(for: result).resolvedChannel {                   ← §9.1 chain head
-            dial(result) / coordinator.performFaceTimeCall(…video: false) /     ← reformatted into the
-            whatsApp(result) / coordinator.performSystemContactMessenger(…)     ← §9.1 switch (calls kept)
-        guard let url = URL(string: "whatsapp://") else { return false }        ← probe delegated to
-        return UIApplication.shared.canOpenURL(url)                             ← the ONE chain probe
-    private func whatsApp(_ result: UnifiedContactSearch.Result) {              ← gains `hop:`
-        let resolvedChannel = AppCoordinator.resolvedCallChannel(…              ← five-argument form /
-            whatsAppInstalled: true).channel                                     ← real probe input
-                               resolvedChannel: resolvedChannel, storeKey: storeKey) ← both provenance fields
```

Every other line in `LeafViews.swift` is a pure insertion; every routed opener call keeps its
shipped argument shape and gains only the trailing `hop: hop`.

## What was built

### 1. The ONE probe — `LeafViews.swift:1175-1177`

```swift
    private var whatsAppInstalled: Bool {
        CallChannelChain.whatsAppInstalled(canOpen: { UIApplication.shared.canOpenURL($0) })
    }
```

The row's old local probe (its own `whatsapp://` literal + `canOpenURL`) is gone: one probe
implementation for the whole feature, owned by the frozen chain file
(`CallChannelChain.whatsAppInstalled(canOpen:)`, `CallChannelChain.swift:123-125`) over the
compile-time literal (`:116`). The row adds no coordinator dependency and no second probe URL —
pinned by `testRowProbeIsTheSingleChainProbe` (source counts below).

### 2. The WhatsApp helper gains the hop — `LeafViews.swift:1553-1557`

```swift
    private func whatsApp(_ result: UnifiedContactSearch.Result,
                          hop: AppCoordinator.LaunchHop? = nil) {
        coordinator.performSystemContactWhatsApp(name: result.name, phone: result.phone,
                                                 hop: hop)
    }
```

Defaulted `nil` keeps the pill's own tap hop-less (a chat surface, not a chain-routed dial);
the dial zone's `.whatsApp` route threads the row's pre-built hop through.

### 3. `dialChannel` — the design §9.1 listing, `LeafViews.swift:1583-1621`

```swift
    private func dialChannel(_ result: UnifiedContactSearch.Result) {
        let state = rowChannelState(for: result)
        let locale = coordinator.activeLocale
        if let skipped = state.fellBackFrom.first {
            // ADR-CDP-07: at resolution, BEFORE the open …
            coordinator.speak(text: L10n.fmt("call.announce.fallbackRouted",
                                             locale: locale,
                                             CallChannelChain.label(skipped, locale: locale),
                                             result.name,
                                             CallChannelChain.label(state.resolvedChannel,
                                                                    locale: locale)))
        }
        let hop = AppCoordinator.LaunchHop(candidates: state.hopCandidates,
                                           handle: resolvedMessengerHandle(for: result),
                                           phone: result.phone)
        switch state.resolvedChannel {
        case .phone:
            dial(result)                                   // floor: no hop (RES-10)
        case .faceTime:
            coordinator.performFaceTimeCall(name: result.name, phone: result.phone,
                                            video: false, hop: hop)
        case .whatsApp:
            whatsApp(result, hop: hop)
        case .messenger:
            guard let handle = resolvedMessengerHandle(for: result) else {
                // Stale state only — the shipped message; the shipped
                // inner `let locale` is kept byte-identical.
                let locale = coordinator.activeLocale
                coordinator.speak(text: L10n.fmt("router.call.messengerNoHandle",
                                                 locale: locale, result.name))
                return
            }
            coordinator.performSystemContactMessenger(name: result.name, handle: handle,
                                                      hop: hop)
        }
    }
```

The announce runs at RESOLUTION (before any opener — a successful open may background the app),
only when the chain skipped a channel (ADR-CDP-07/FR-CDP-016). The hop is built ONCE from the row
state (L2-D10) and threaded into every routed opener — FaceTime, WhatsApp, Messenger — and never
into the `.phone` floor. `dial(_:)` is the shipped body, byte-identical (GSM open + local recency
bump, `:1539-1545`); the numberless dead row keeps the shipped `call.announce.noPhoneNumber` line
via the unchanged `performSystemContactCall` guard, with no chain attempt.

### 4. `rowChannelState` — the five-argument call form, `LeafViews.swift:1648-1671`

```swift
        let preferred = storedPreference ?? coordinator.defaultCallApp
        let route = AppCoordinator.resolvedCallChannel(
            explicit: storedPreference,
            defaultApp: coordinator.defaultCallApp,
            secondaryApp: coordinator.secondaryCallApp,
            messengerHandleAvailable: hasHandle,
            whatsAppInstalled: coordinator.whatsAppInstalledNow)
        return RowChannelState(storedPreference: storedPreference,
                               resolvedChannel: route.channel,
                               hasHandle: hasHandle,
                               storeKey: storeKey,
                               fellBackFrom: route.fellBackFrom,
                               hopCandidates: CallChannelChain.hopCandidates(
                                   preferred: preferred,
                                   secondary: coordinator.secondaryCallApp,
                                   routed: route.channel))
```

The six-argument seam's `vocabulary` parameter takes the row surface's default (`.anyChannel`) —
the L1 integration #19 call form, no vocabulary argument at the row. The probe input is now the
REAL `whatsAppInstalledNow` (the previous T-146 compile bridge hardcoded `whatsAppInstalled: true`
— the design's five-argument form supersedes it, so a row now gates WhatsApp on the honest probe).
The routed channel, the provenance and the hop candidates come from the SAME snapshot.

### 5. `RowChannelState` gains both provenance fields, `LeafViews.swift:2323-2327`

```swift
    var fellBackFrom: [CallApp] = []
    var hopCandidates: [CallApp] = []
```

`var … = []` (L2-D3) so the synthesized memberwise initializer keeps defaulted parameters; the
single construction site above passes both explicitly.

### 6. Carried fix N-1 — the FaceTime leg threads the hop (shared with T-152)

`AppCoordinator.swift:8041-8047` (`performLaunchFailHop`'s `.faceTime` case):

```swift
        case .faceTime:
            // W6-review N-1 carry (T-151/T-152): …
            performFaceTimeCall(name: name, phone: phone, video: isVideo,
                                hop: LaunchHop(candidates: step.remaining, handle: handle))
```

The reviewer-prescribed one-line form, verbatim; the `.whatsApp`/`.messenger` legs already had it.
`testFaceTimeLegThreadsTheRemainingCandidates` pins (a) the source form by collapsed-region
equality, (b) the two-step consumption through the internal `launchFailHopStep` seam
(`[.faceTime, .phone]` → `.faceTime` remaining `[.phone]` → `.phone` remaining `[]`, two hop
events), and (c) the end-to-end consequence through the SHIPPED openers: an empty handle and an
empty number fail before any platform probe, so `performSystemContactMessenger(handle: "",
hop: LaunchHop(candidates: [.faceTime, .phone], handle: nil))` produces TWO hop lines
(`messenger:faceTime` then `faceTime:phone`, the second only with the N-1 thread) and ends on the
shipped no-number line with nothing recorded.

### 7. Carried fix N-4 — the hop carries the row's phone (shared with T-152)

`AppCoordinator.swift:7992` — `struct LaunchHop` gains `var phone: String? = nil` (`var` with a
default: the memberwise initializer keeps a DEFAULTED parameter, so every shipped
`LaunchHop(candidates:handle:)` call site compiles unchanged — the L2-D3 lesson). The row's hop
construction (`dialChannel`, item 3 above) passes `phone: result.phone`; the messenger opener's
failure branch (`AppCoordinator.swift:8457-8459`) consumes `phone: hop?.phone ?? ""`, so a hopped
floor leg dials the surface's REAL number instead of speaking the no-number line.

Pins: (a) the messenger opener's consumption is pinned by collapsed-region `contains` in
`testLaunchHopCarriesThePhoneAdditively`; (b) the row-side construction (`phone: result.phone` in
the hop) is pinned by the hop-needle in `testRowAnnouncesBeforeTheOpenAndThreadsTheHop`; (c) the
struct's additive shape is pinned at the runtime level (two-label form equals the three-label form
with explicit `nil`; the third parameter carries the number) and at source (`var`, not `let`).
**Honest ceiling, stated in the test doc comment:** the POSITIVE direction (a hop whose phone is
real) cannot run inert — `performSystemContactCall` hands any dialable number to
`UIApplication.shared.open(tel:)` (`PhoneDialer.url` builds a real URL for any digits; the
CallLinks/PhoneDialer seams do not intercept it), so a unit arm driving it would dial the
simulator for real. The source pins are the ceiling there; the DEFAULT arm (hop.phone nil → the
shipped line, hop-less callers byte-identical) runs behaviourally in
`testHoppedFloorLegWithoutAPhoneKeepsTheShippedLine`.

## Tests added (9 — new section `CallChannelResolutionTests.swift:1583-2053`)

House pattern: comment-stripped source scans (`FeatureSourceScan.codeText`) because the row
helpers are `private` inside the SwiftUI leaf, plus behavioural arms through the very seams the
row calls (`AppCoordinator.resolvedCallChannel`, `CallChannelChain.hopCandidates`,
`launchFailHopStep`) and the real shipped openers with empty inputs (nothing opens, nothing is
dialed, nothing is recorded — fully hermetic).

| Test (`:line`) | Scenario | What it pins |
|------|----------|--------------|
| `testRowProbeStubbedFalseRoutesTo + SecondaryOrFloor` (`:1612`) | probe stubbed false, row still routes | The row's exact argument shape: WhatsApp-preferred + probe false → permitted secondary (provenance `[.whatsApp]`, hop `[.phone]`); secondary also infeasible → the floor (provenance `[.whatsApp, .messenger]`, hop `[]` — the floor is the routed channel). |
| `testRowFloorReachableFrom + EveryRowState` (`:1644`) | SA-3 floor reachability | All 64 row cells (4 preferred × 4 secondary × 4 feasibility combos, counted): the floor is routed or is among the row's hop candidates — every row state ends at the GSM dialer on its own channel or through one hop. |
| `testRowAnnouncesBeforeThe + OpenAndThreadsTheHop` (`:1679`) | FR-CDP-016 / ADR-CDP-07; hop wiring | Collapsed-region pins: the ONE announce block (`call.announce.fallbackRouted` with skipped-label, name, routed-label) positioned BEFORE `switch state.resolvedChannel {`; the ONE hop construction with `phone: result.phone`; `hop: hop` exactly 3 times in the switch (and never in `.phone`); `.phone` case equals `case .phone: dial(result)` (comment-stripped); `.whatsApp` case equals `case .whatsApp: whatsApp(result, hop: hop)`; the shipped stale-state guard block unchanged; messenger opener carries `hop: hop`; the `whatsApp(_:hop:)` helper pinned whole (forward + defaulted nil). |
| `testRowProbeIsTheSingleChainProbe` (`:1783`) | NFR-CDP-002 / FR-CDP-005 | The leaf's `whatsAppInstalled` is the chain one-liner, exactly; `CallChannelChain.whatsAppInstalled(canOpen:` once; `canOpenURL` once; `whatsapp://` ZERO times in the leaf; the coordinator's `whatsAppInstalledNow` is the same chain check over its main-thread hop; the chain file itself calls no `canOpenURL` (closure injected) and owns the ONE `whatsapp://` literal plus the one-line implementation. |
| `testRowStateIsTheFiveArgumentCall + AndTheDeadRowStaysShipped` (`:1834`) | L1 integration #19 / L2-D10/D3 | The five-argument call form verbatim (no `vocabulary:` token anywhere in the region — `.anyChannel` is the row's surface); `preferred = storedPreference ?? coordinator.defaultCallApp`; ONE `RowChannelState(` construction passing BOTH provenance fields; the struct's two `var … = []` fields; `dial(_:)` byte-identical to the shipped body (open + recency bump, no chain, no hop). |
| `testNumberlessDeadRowKeepsThe + ShippedFloorLine` (`:1896`) | numberless dead row unchanged | Behavioural: `performSystemContactCall(phone: "")` emits no hop event, lands on the shipped no-number line, records nothing. |
| `testFaceTimeLegThreadsThe + RemainingCandidates` (`:1924`) | W6 N-1 (carried) | Source pin of the reviewer-prescribed `.faceTime` leg verbatim; the two-step `launchFailHopStep` walk (candidates consumed strictly, two events); the E2E arm through the shipped openers proving the second hop (`faceTime:phone`) exists only with the thread; nothing recorded. |
| `testLaunchHopCarriesThePhoneAdditively` (`:1987`) | W6 N-4 (carried) | `var phone: String? = nil` in the struct (one occurrence, `var` not `let`); runtime: two-label form == three-label-with-nil, third parameter carries the number; the messenger opener consumes `phone: hop?.phone ?? ""` (collapsed-region `contains`). |
| `testHoppedFloorLegWithoutAPhone + KeepsTheShippedLine` (`:2029`) | N-4 default arm | Behavioural: a hopped floor leg with `hop.phone == nil` still lands on the shipped no-number line after its one hop event — hop-less callers byte-identical. |

Suite total after this unit: 34 pre-existing + 9 new = **43 tests** (none yet run — see Gate).

## Gate

Command (as briefed, from the worktree root): `ios/build.sh test:unit CallChannelResolutionTests`.

1. **Attempted run — FAILED AT BUILD (exit 65).** Log retained at `ios/build/t151-gate.log`;
   bundle path referenced by the log: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.12_07-15-41-+1100.xcresult`
   (no per-test record — the build failed before any test ran: "Testing cancelled because the
   build failed"). Root cause: compile error in the SIBLING new test file
   `ContactCallButtonsTests.swift:583:27` — `error: no exact matches in call to initializer`
   (`String(try XCTUnwrap(…).lowerBound...)` — the range, not the subscripted text, was passed to
   `String.init`; re-derived with a standalone `swiftc -typecheck` repro). The same invalid
   construct existed in `CallChannelResolutionTests.swift` (the batch build surfaced only the
   first error). Both were fixed to the house subscript form
   (`String(text[start.lowerBound...])`); no test semantics changed. This failure is disclosed
   here rather than repaired silently.
2. **Compile-only check — GREEN (the evidence on the delivered bytes).** Command:
   `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant
   -destination "platform=iOS Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18"
   -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests`. Log:
   `ios/build/t151-compilecheck.log` — `** TEST BUILD SUCCEEDED **` (line 922),
   `COMPILECHECK_EXIT=0`, zero `error:` lines; the log shows BOTH edited test files recompiled on
   the delivered bytes (SwiftCompile for `ContactCallButtonsTests.swift` at lines 825-833 and
   `CallChannelResolutionTests.swift`). No test was executed by this check.
3. **Scoped unit run (DoD) — DEFERRED to the consolidated end sweep** (mid-task orchestration
   process change: reviews and test gates consolidate to a single end-of-feature sweep; no new
   gate runs). No green gate claim is made.
4. **Negative control (briefed: revert the two carried-fix production lines, expect the new pins
   red, restore, md5-verify, re-run) — DEFERRED to the same sweep.** Recorded plan for whoever
   runs it: revert `AppCoordinator.swift:8041-8046` to
   `performFaceTimeCall(name: name, phone: phone, video: isVideo)` and `:8458` back to
   `phone: "", handle: hop?.handle`; expected failures: `testFaceTimeLegThreadsThe +
   RemainingCandidates` (source-pin equality + E2E two-line count) and
   `testLaunchHopCarriesThePhoneAdditively` (messenger consume pin); the N-4 default arm and the
   step walk are expected to stay green (they do not depend on either reverted line — the
   decision-step walk deliberately isolates the step from the leg). Restore and verify
   `AppCoordinator.swift` md5 `0e633131325a4d05a74e2ec1adb58704` (the delivered-bytes hash,
   recorded before the attempted gate; `LeafViews.swift` `7878d0c9ec475e4b7c2b46e8e1d55b0f`).

In-build guards were green in the attempted gate run before the compile stopped it (log lines
17-58: release log-safety 12 rules / 24 fixtures, intent-prompt mirror 2717 bytes / 4
placeholders); the compile check does not re-run them (they live in `run_tests`).

## Deviations from the design / task spec (with reason)

1. **The row's probe input changed from the T-146 bridge's hardcoded `true` to the real
   `whatsAppInstalledNow`.** The design's five-argument call form and the task brief both mandate
   the real probe; a row preferring WhatsApp on a phone without WhatsApp now falls back (routed or
   announced) instead of opening a dead link. This is the designed T-151 behaviour change, not a
   drift — disclosed here because it changes shipped row routing.
2. **The announce pin checks ORDER (announce block before the switch) plus the block's exact
   shape, not a line number.** Region/order pins survive reformatting but cannot be fooled by a
   comment (comment-stripped source); chosen per the house rule "fail on a weakened gate, not on
   a reformat".
3. **New tests use crash-safe option access (`.first`/`.dropFirst()`) instead of the T-149 style
   index-after-count.** With count asserted first, an indexed access after a regression would
   crash the suite run instead of failing the case; the safe form fails cleanly (and is what the
   deferred negative control needs to record failing bundles rather than crashes).
4. **Disclosure: the first gate attempt failed at BUILD.** Recorded in full in
   Gate item 1 with the exact error, root cause, and fix; the compile check is the honest
   delivered-bytes evidence until the sweep runs the suites.

## Notes for the paired challenger

1. **Probe the fix first**: re-run the standalone repro
   (`xcrun swiftc -typecheck` on `String(r.lowerBound...)`) and confirm neither delivered test
   file contains the invalid construct (`grep "lowerBound\.\.\."` — every hit must be a subscript
   `text[…]`, never a `String(…)` argument). Then the compile log: SwiftCompile lines for both
   files + `TEST BUILD SUCCEEDED`.
2. **Probe the single-probe pin against the frozen file**: `CallChannelChain.swift` must remain
   byte-identical (`git diff --stat` shows no entry); the leaf must own zero `whatsapp://`
   literals and one `canOpenURL`; the coordinator must delegate through `whatsAppInstalledNow`.
   A whole-file grep of the leaf for `canOpenURL` will hit a doc comment line (`:1173`) and a
   doc-comment mention at `:2223` — the test scans comment-stripped source, so those do not
   count; verify the same way.
3. **Probe the hermeticity claims**: every behavioural arm uses an empty phone and/or empty
   handle, which `CallLinks` fails BEFORE any `canOpenURL`/`open` (`openPhone` nil URL;
   `openFaceTime`/`openMessengerThread`/`openMessengerChat`/`openWhatsAppCallChat` invalid* before
   the probe). If a challenger finds any arm that could reach `UIApplication.shared.open`, that
   is a hermeticity bug — the N-4 positive direction is deliberately NOT driven for exactly this
   reason (statement in the test doc comment + this note).
4. **Probe the floor invariant**: `testRowFloorReachableFromEveryRowState` asserts over 64 cells
   and counts them; the invariant is `routed == .phone || rowHop.contains(.phone)`. The proof
   sketch: for `.anyChannel` the routed channel always comes from the attempt order, `.phone` is
   always in the order, and when `.phone` is before a non-phone routed channel the route's
   remaining list is empty and the terminal rule refills `[.phone]` — a counterexample would be a
   routing change that returns a non-phone channel outside the order.
5. **Probe the announce hop list**: `hopCandidates(preferred:secondary:routed:)` without a
   vocabulary argument defaults `.anyChannel`; the row passes no vocabulary (pinned by
   `XCTAssertFalse(stateRegion.contains("vocabulary:"))`) — if a future wave threads a row
   vocabulary, that pin must move with the design, not be deleted.

## Definition of done

- [x] Row tap announces the routed channel at resolution, BEFORE the open, only on a fallback
      (`testRowAnnouncesBeforeTheOpenAnd + ThreadsTheHop`, order + shape pins)
- [x] Row state is the five-argument call over the six-argument seam; `RowChannelState` carries
      `fellBackFrom` + `hopCandidates` from one snapshot (L2-D10; both source-pinned)
- [x] ONE probe implementation (leaf and coordinator delegate to the chain static; no second
      literal; `testRowProbeIsTheSingleChainProbe`)
- [x] Provenance-aware hop threaded into every routed opener from the row switch and never into
      `.phone`; the floor reachable from every row state (64-cell invariant)
- [x] Numberless dead row unchanged (behavioural arm on the shipped floor line)
- [x] Carrier fixes N-1/N-4 implemented with source pins and (where hermetic) behavioural arms
- [x] Delivered bytes COMPILE (`ios/build/t151-compilecheck.log`, `TEST BUILD SUCCEEDED`, exit 0)
- [ ] Scoped run green `ios/build.sh test:unit CallChannelResolutionTests` — **deferred to the
      consolidated end sweep** (attempted run failed at build; fix landed; not re-run per the
      process change)
- [ ] Negative control (briefed) — **deferred to the same sweep** (plan recorded above)
- [ ] Code reviewed and merged — the paired challenger's review + integration commit (not this
      unit's call)
