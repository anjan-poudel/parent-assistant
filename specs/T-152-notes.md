# T-152 — Family tiles: audio/video routing and hop branches — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary`
(branch `feat/call-dialer-primary-secondary`, base `54574bb3`). Unit: TG-31, risk HIGH.
Assigned requirements (task file): FR-CDP-009 (explicit pick wins as preferred), FR-CDP-010
(tap buttons route the chain), FR-CDP-018 (preserved behaviours), NFR-CDP-009 (no regression on
shipped call paths). Design references: design-l2 §9.2 family tiles (`design-l2.md:694-750`),
§10.1 failure classification (which arms hop, which are terminal), §10.2 `LaunchHop`/step/helper,
L2-D3 (the defaulted-memberwise lesson), L2-D5, L2-D10 (one snapshot: routed channel + provenance
+ candidates), ADR-CDP-07 (announce at resolution, BEFORE the open), RES-10 (the floor is
terminal; a failed open records nothing). Task spec:
`specs/plan-tasks/tasks/TG-31-tap-paths-dial-back-and-settings.md` T-152 section (`:78-126`).
Carried fixes (W6 review, `specs/implement-review-w6-t149.md`), adjudicated jointly into
T-151/T-152: **N-1** (the hop helper's `.faceTime` leg abandons its remaining candidates) and
**N-4** (`LaunchHop` carries no phone, so a hopped floor leg from the messenger-family openers
cannot dial the surface's real number — disposition in `specs/implement-notes.md` W7 point 4).
The row-side (T-151) rendering of the same two carries, the shared production hunks, and the
joint negative-control plan are recorded in `specs/T-151-notes.md`; this file covers the tile
surface and cross-references.

## Status

**Implemented — production and tests delivered; delivered bytes COMPILE (see Gate). The scoped
unit run (DoD line `ios/build.sh test:unit ContactCallButtonsTests CallChannelResolutionTests`)
and the negative control are DEFERRED to the consolidated end-of-feature sweep, per a mid-task
orchestration process change (message from the `sdd-run` session: skip the negative-control run,
do not start new gate runs — reviews and test gates consolidate to a single sweep at feature
end). No test in this unit has been executed against a run yet — the tests are
unaudited-against-run. Disclosure: the one gate run that WAS started (the sibling T-151 command
`test:unit CallChannelResolutionTests`) failed at BUILD with a compile error located in THIS
unit's test file — `ContactCallButtonsTests.swift:583:27` — fixed before the compile check (Gate
item 1). Nothing committed, nothing pushed, no ai-sdd command run, no `git clean`/`restore`.
No new catalogue key; the announcement reuses the shipped lane (`call.announce.fallbackRouted`)
and the shipped channel labels.

## Files changed

| File | numstat (+/-) | Hunks |
|------|---------------|-------|
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 91 / 22 | shared with T-151 (5); the tile hunks are within `performContactCall` + the two carried-fix lines |
| `ios/ElderlyAssistantTests/Services/Intents/ContactCallButtonsTests.swift` | 569 / 0 | 2 (pure additive) |

The test file is PURE ADDITIVE — `git diff --numstat` shows 0 removed lines; the 16 pre-existing
tests (`:13-186`) are byte-frozen, helpers included (they are extended, not edited: the new
section's helpers twin the shipped patterns with new names — `tileEventLines`, `hopEventLines`, a
dedicated `captureConsole` sink path — and the shipped `RecordingCallLinkOpener` at file scope
`:762` is reused as-is). Suite total after this unit: 16 pre-existing + 9 new = **25 tests**
(`grep -c "func test"` = 25; none yet run — see Gate).

The FIVE removed non-comment lines in `AppCoordinator.swift` (the whole diff, both units):

```
-            performFaceTimeCall(name: name, phone: phone, video: isVideo)   ← N-1 carry: gains the hop thread
-        let app = kind == .video ? contact.resolvedVideoApp : contact.resolvedAudioApp   ← renamed to `preferred` (unchanged expression)
-            outcome: "\(kind == .video ? "video" : "audio"):\(app.rawValue)",            ← extended emit (same prefix, provenance token appended)
-        switch app {                                                                    ← switch route.channel {
-                                 name: name, phone: "", handle: hop?.handle,            ← N-4 carry: phone: hop?.phone ?? ""
```

Three of the five are THIS unit's tile head (lines 2-4); lines 1 and 5 are the carried fixes
(shared with T-151). Every other coordinator line in the diff is a pure insertion; the `.phone`
arm's statements are untouched (verified by the source pin's verbatim sub-region equality).

## What was built

### 1. `performContactCall` — the design §9.2 listing, `AppCoordinator.swift:8125-8245`

Head (preferred, vocabulary, the six-argument seam, the extended emit, the announce, the
candidates — all from ONE snapshot, L2-D10):

```swift
    func performContactCall(_ contact: FamilyContact, kind: ContactCallKind) {
        let locale = activeLocale
        let preferred = kind == .video ? contact.resolvedVideoApp : contact.resolvedAudioApp
        let vocabulary: CallChannelVocabulary = kind == .video ? .video : .audio
        let route = Self.resolvedCallChannel(
            explicit: preferred,
            defaultApp: defaultCallApp,
            secondaryApp: secondaryCallApp,
            messengerHandleAvailable: hasUsableMessengerHandle(contact.messengerHandle),
            whatsAppInstalled: whatsAppInstalledNow,
            vocabulary: vocabulary)
        observabilityBus.emit(ObservabilityEvent(
            component: "contact_call_buttons",
            eventType: "tap",
            durationMs: nil,
            outcome: "\(kind == .video ? "video" : "audio"):\(route.channel.rawValue):"
                + (route.fellBackFrom.isEmpty ? "direct" : "fellBack"),
            errorCode: nil,
            metadata: [:]  // no contact identifiers — C9 policy
        ))
        if let skipped = route.fellBackFrom.first {
            // ADR-CDP-07: at resolution, BEFORE the open. Nothing is
            // spoken when nothing fell back (FR-CDP-016 scenario 3).
            speak(text: L10n.fmt("call.announce.fallbackRouted", locale: locale,
                                 CallChannelChain.label(skipped, locale: locale),
                                 contact.name,
                                 CallChannelChain.label(route.channel, locale: locale)))
        }
        let candidates = CallChannelChain.hopCandidates(preferred: preferred,
                                                        secondary: secondaryCallApp,
                                                        routed: route.channel,
                                                        vocabulary: vocabulary)
        switch route.channel {
        …
```

Key properties, each pinned by `testTileChainHeadSourcePins`:

- **The tapped button decides both inputs.** `preferred` from `resolvedVideoApp`/`resolvedAudioApp`
  (non-nil by construction — the pin asserts `explicit: nil` NEVER appears in the region);
  `vocabulary` `.video`/`.audio`. The silent input substitution semantics of the seam (a raw
  preference the vocabulary forbids is normalized at the seam's INPUT — no fabricated provenance)
  is exactly the shipped guard's silence; pinned behaviourally in
  `testAudioTileVocabularyExcludesFaceTime + AndKeepsSilentSubstitution`.
- **Emit → announce → switch**, in that order (ADR-CDP-07); exactly ONE
  `call.announce.fallbackRouted` site in the region.
- **The emit extends additively**: the shipped `video:<channel>`/`audio:<channel>` prefix is
  byte-identical (same expression, `app` renamed `route.channel`), `metadata` stays `[:]`
  (C9 policy), and the provenance token `:direct`/`:fellBack` is appended. See Deviation 1 for
  the DoD-reading note.
- **Candidates from the SAME snapshot and vocabulary** (L2-D10) — the list handed to every hop
  helper call is `candidates`, built once.

The four arms (each byte-verified against the removed lines):

- `.faceTime` (`:8158-8182`) — `callLinks.openFaceTime(handle: contact.phone, video: true)`;
  `.opened` keeps the shipped statements verbatim; `.unavailable`/`.invalidHandle` speaks the
  shipped `router.call.facetimeUnavailable` line then calls
  `performLaunchFailHop(after: .faceTime, candidates: candidates, name: contact.name,
  phone: contact.phone, handle: contact.messengerHandle, isVideo: kind == .video, locale: locale)`
  — ONE hop arm (source-pinned region + count).
- `.phone` (`:8183-8193`) — the shipped guard `guard callLinks.openPhone(contact.phone) else {
  announceNoUsableNumber(contact: contact, locale: locale); return }` and the shipped success
  statements, verbatim; `performLaunchFailHop` count in the region == 0 — the floor is terminal
  (RES-10).
- `.messenger` (`:8194-8218`) — `openMessengerChat`; `.openedApp`/`.openedWebChat` keep the
  shipped statements; `.invalidHandle` speaks the shipped line then hops once
  (`performLaunchFailHop(after: .messenger, …)` — the second and last hop arm).
- `.whatsApp` (`:8219-8243`) — every arm is the shipped terminal or recovery, byte-identical
  (`openedChat`, `needsNativeCompose` → `presentMessageDraft` + the SMS-fallback line,
  `copiedNumber` → the copy outcome + line, `invalidPhone` → `announceNoUsableNumber`); the
  region contains ZERO `performLaunchFailHop(` calls and does not even reference `candidates`
  (source-pinned). The Gherkin "a terminal invalid-phone result hops nowhere" is pinned
  behaviourally by `testWhatsAppLaneNeverHopsEvenHandedCandidates`.

### 2. Carried fix N-1 — the hop helper's `.faceTime` leg threads its candidates

`AppCoordinator.swift:8041-8047` (inside `performLaunchFailHop`, `:8031-8057`):

```swift
        case .faceTime:
            // W6-review N-1 carry (T-151/T-152): …
            performFaceTimeCall(name: name, phone: phone, video: isVideo,
                                hop: LaunchHop(candidates: step.remaining, handle: handle))
```

The tile's `.faceTime` failure arm now hands a hop that survives the next hop
(`step.remaining` — the candidate list minus everything up to and including the attempted
channel), so a video tile that falls through FaceTime can still reach its remaining candidates.
Pins: source-form equality + the two-step `launchFailHopStep` walk + the end-to-end two-hop
sequence — all three in `testFaceTimeLegThreadsTheRemaining + Candidates` (T-151's test file;
see T-151 notes items 6 and the Gate section for the expected-red plan). The tile-side symptom
of the old bug (a hop onto FaceTime silently ending the chain) is covered by the same pins; a
tile BEHAVIOURAL arm for it does not exist because no tile hop can currently land on `.faceTime`
(the video vocabulary's FaceTime is the terminal — routed FaceTime has no candidates — and the
audio vocabulary never permits FaceTime); disclosed in Deviation 3.

### 3. Carried fix N-4 — the hop carries the row's/tile's phone

`LaunchHop` gains `var phone: String? = nil` (`AppCoordinator.swift:7992`); the tile's
`.messenger` arm threads `handle: contact.messengerHandle` and the helper's hopped floor leg
consumes it in `performSystemContactMessenger`'s `.invalidHandle` branch
(`AppCoordinator.swift:8457-8459`):

```swift
            performLaunchFailHop(after: .messenger, candidates: hop?.candidates ?? [],
                                 name: name, phone: hop?.phone ?? "", handle: hop?.handle,
                                 isVideo: false, locale: locale)
```

`?? ""` keeps hop-less callers byte-identical (pinned behaviourally by
`testHoppedFloorLegWithoutAPhone + KeepsTheShippedLine`); the tile-side hop construction itself
(which sets `phone:`) is T-151's row/`dialChannel` — nothing in the tile head needed changing for
N-4 beyond the consume line, because the tile's hop helper call already passes
`phone: contact.phone` (source-pinned inside the `.faceTime`/`.messenger` arm pins). The
positive direction (a real number reaching the hopped floor) cannot run inert — the shipped GSM
opener hands any dialable number to `UIApplication.shared.open(tel:)` — so source pins are the
ceiling there (T-151 notes item 7 carries the full rationale).

### 4. Settings-pair consumption

The tile reads the settings pair at the seam call: `defaultApp: defaultCallApp`,
`secondaryApp: secondaryCallApp`, plus the real probe `whatsAppInstalledNow` (the T-146 seam's
inputs, unchanged names) — pinned by the six-argument seam needle in
`testTileChainHeadSourcePins`; "the settings pair is consumed by the tile at the seam call"
(task file) holds by construction.

## Tests added (9 — new section `ContactCallButtonsTests.swift:189-605`)

Hermeticity: every behavioural arm drives the REAL `performContactCall` through an in-memory
coordinator, and every fixture uses an EMPTY phone and/or EMPTY handle so the shipped openers
fail before any `canOpenURL`/`open` — nothing opens, nothing is dialed, nothing is recorded. All
tile arms route on values where the real `whatsAppInstalledNow` probe cannot change the outcome
(see Deviation 2 for the WhatsApp lane).

| Test (`:line`) | Scenario | What it pins |
|------|----------|--------------|
| `testVideoTileVocabularyExcludes + ThePhoneCandidateUntilTheFloor` (`:221`) | Gherkin "video tile routes video-capable channels"; FR-CDP-004/007 + SA-3 | `video` vocabulary forbids `.phone`; FaceTime-routed → zero candidates (already the surface floor); handle-less Messenger preference + phone secondary → `[.faceTime]`, never `.phone`; the seam's substitution for a forbidden raw route lands on the FaceTime terminal with REAL provenance (`[.messenger]`, not fabricated) and zero candidates. |
| `testAudioTileVocabularyExcludes + FaceTimeAndKeepsSilentSubstitution` (`:269`) | Gherkin "audio tile never routes faceTime"; the shipped guard's silence | `audio` forbids `.faceTime`; a raw FaceTime audio preference is substituted SILENTLY at the seam input (`fellBackFrom` EMPTY — nothing to announce, exactly the shipped `guard supportsAudio` behaviour); a handle-less Messenger line's candidates carry `[.phone]` (never FaceTime) even when FaceTime is the secondary; the floor routes with real provenance `[.messenger]` and zero candidates. |
| `testVideoTileDirectEmits + TheShippedDirectOutcome` (`:313`) | FR-CDP-016 + ADR-CDP-07 (behavioural) | Contact with defaults → `outcome=video:faceTime:direct metadata=[:]` verbatim in the console; one tap event; ZERO hop events (the video floor has no candidates); the shipped honest `facetimeUnavailable` line; a failed open records nothing (RES-10). |
| `testAudioTileDirectKeeps + TheShippedDirectOutcome` (`:341`) | behavioural twin | `outcome=audio:phone:direct metadata=[:]`; no hop; the shipped floor guard line for the empty number; nothing recorded. |
| `testAudioTileFallbackReaches + TheFloorWithProvenance` (`:369`) | DoD "floor reachable with everything else infeasible" | Handle-less Messenger audio preference → `outcome=audio:phone:fellBack`; ZERO hops (routed ON the floor, nothing remains); the shipped no-number line; nothing recorded. |
| `testVideoTileSubstitution + NeverHopsAndStaysOnFaceTime` (`:397`) | SA-3 (behavioural) | Handle-less Messenger video preference → substituted FaceTime terminal with real provenance: `outcome=video:faceTime:fellBack`; the FaceTime branch fails on the empty number and hops NOWHERE (the substituted terminal is the floor). |
| `testMessengerTileInvalidHandle + HopsThroughTheChain` (`:425`) | FR-CDP-015 (behavioural, tile arm) | Handle-less open path: on-file handle `"maya.gurung"` routes `outcome=audio:messenger:direct`; the `.invalidHandle` failure then hops EXACTLY once — `outcome=messenger:phone metadata=[:]` — landing on the GSM floor's shipped no-number line; failed opens record nothing, the hop included. |
| `testWhatsAppLaneNeverHops + EvenHandedCandidates` (`:458`) | Gherkin "terminal invalid-phone result hops nowhere"; RES-10 | `performSystemContactWhatsApp` handed `LaunchHop(candidates: [.phone], handle: nil)` with an empty phone: the `.invalidPhone` arm speaks its one shipped line, emits ZERO hop events, records nothing — the lane consults no candidates even when given some. |
| `testTileChainHeadSourcePins` (`:484`) | design-l2 §9.2 (comment-stripped source) | Preferred + vocabulary lines verbatim; `explicit: nil` NEVER; the six-argument seam needle; emit < announce < switch ordering; ONE `call.announce.fallbackRouted`; the emit expression byte-pin (prefix expression + provenance concatenation, `\\("` escapes) ; the announce block shape (skipped label, name, routed label); the candidates construction with `vocabulary:`; `performLaunchFailHop(` count == 2 in the region; per-arm pins — FaceTime arm hops once with the shipped argument shape, `.phone` arm has ZERO hop calls + the shipped guard and shipped success statements verbatim, `.messenger` arm hops once with the shipped shape, and the `.whatsApp` tail (everything from `case .whatsApp:` on) has ZERO hop calls, NO `candidates` reference, and the shipped terminal/recovery arms verbatim. |

Helpers (new section tail, twins of the sibling suites' patterns): setUp/tearDown back up and
restore `appLanguage`/`defaultCallApp`/`secondaryCallApp` (`:618-638`); `makeCoordinator`
(`:644-650`) seeds english + `.phone`/`.phone` BEFORE construction so the init restores through
the real persisted seams; `drainMainQueue` (`:654-657`; `setOutcome` assigns on main async —
the sentinel enqueued last runs after everything); `captureConsole` (`:663`, dup2 stdout to a
`contact-call-buttons-sink-` temp file); `tileEventLines` (`:689`, filters
`[contact_call_buttons] tap `); `hopEventLines` (`:696`, filters `[call_launch_fallback] hop`);
`coordinatorSource` (`:701`, the house `FeatureSourceScan` walk-up); `region`/`collapsed`/
`occurrences` (`:709`/`:720`/`:724`); the nested `InMemoryProfilePayloadStorage` twin (`:733`);
the file-scope `RecordingCallLinkOpener` (`:762`) reused unchanged.

## Gate

Command (as briefed, from the worktree root): `ios/build.sh test:unit ContactCallButtonsTests
CallChannelResolutionTests`.

1. **Not started — DEFERRED** to the consolidated end sweep (mid-task orchestration process
   change; no new gate runs). No green gate claim is made. However, the sibling gate-1 command
   that WAS attempted (`test:unit CallChannelResolutionTests`, T-151) **failed at build with the
   compile error in THIS unit's file**: `ContactCallButtonsTests.swift:583:27: error: no exact
   matches in call to initializer` — `String(try XCTUnwrap(…).lowerBound...)` passed the RANGE,
   not the subscripted text, to `String.init` (no such initializer for
   `PartialRangeFrom<String.Index>`). Fixed to the house subscript form
   (`String(text[start.lowerBound...])`) in both new test sections; no test semantics changed.
   Full evidence in `specs/T-151-notes.md` Gate item 1 (log `ios/build/t151-gate.log`, failed
   bundle `Test-ElderlyAssistant-2026.10.12_07-15-41-+1100.xcresult`, build failure before any
   test ran).
2. **Compile-only check — GREEN (the evidence on the delivered bytes).** `xcodebuild
   build-for-testing` (same project/scheme/destination/DerivedData as the gate command; log
   `ios/build/t151-compilecheck.log`): `** TEST BUILD SUCCEEDED **`, exit 0, zero `error:` lines;
   the log shows `ContactCallButtonsTests.swift` recompiled on the delivered bytes (SwiftCompile
   at log lines 825-833). No test was executed by this check.
3. **Scoped unit run (DoD) — DEFERRED** to the consolidated end sweep. The tests are
   unaudited-against-run.
4. **Negative control (briefed) — DEFERRED** to the same sweep. Recorded plan (identical to
   T-151's; the two reverted lines are shared production): revert `AppCoordinator.swift:8041-8046`
   to `performFaceTimeCall(name: name, phone: phone, video: isVideo)` and `:8458` back to
   `phone: "", handle: hop?.handle`; expected reds are the two T-151 pins
   (`testFaceTimeLegThreadsTheRemaining + Candidates`, `testLaunchHopCarriesThePhone + Additively`).
   **Honest note for the sweep operator: NO test in THIS (T-152) suite is expected to redden
   from those two reverts** — no tile behavioural arm hops onto `.faceTime` (the video vocabulary
   makes routed FaceTime the terminal with zero candidates), and every tile fixture's phone is
   empty, so `hop?.phone ?? ""` equals the reverted `""` in every arm this suite runs. The
   N-1/N-4 red evidence therefore lives entirely in the sibling suite; a T-152-only negative
   control would show green-on-broken and must not be mistaken for coverage. Restore and verify
   `AppCoordinator.swift` md5 `0e633131325a4d05a74e2ec1adb58704` (delivered-bytes hash; the
   file was NOT touched after the compile check; `LeafViews.swift`
   `7878d0c9ec475e4b7c2b46e8e1d55b0f`).

In-build guards were green in the attempted sibling gate run before the compile stopped it
(release log-safety 12 rules / 24 fixtures; intent-prompt mirror 2717 bytes / 4 placeholders);
the compile check does not re-run them (they live in `run_tests`).

## Deviations from the design / task spec (with reason)

1. **The direct-outcome full string necessarily gains the provenance suffix.** The task file's
   DoD says "the shipped direct outcome strings stay byte-identical"; design-l2 §9.2 (the
   normative listing for this unit, mandated verbatim by the brief) ALWAYS appends
   `:direct`/`:fellBack`. Resolution: the shipped `video:<channel>`/`audio:<channel>` prefix
   expression, the `metadata: [:]` policy and every shipped branch statement stay byte-identical
   (source + behavioural pins); the append itself is the design's additive extension. A strict
   full-string reading is unsatisfiable alongside §9.2; flagged for the challenger/reviewer to
   arbitrate, not silently chosen.
2. **The WhatsApp lane has no behavioural arm through `performContactCall`.** The real
   `whatsAppInstalledNow` probe is `false` in the simulator and cannot be stubbed for the
   coordinator path (the probe lives behind `UIApplication.shared.canOpenURL`), so a
   WhatsApp-routed tile arm is unreachable in unit tests. The lane is pinned behaviourally
   through the shipped opener (handed candidates, `:458`) and structurally (the §9.2 arm pins,
   `:587-604`). Disclosed rather than faked with a probe hook.
3. **No tile behavioural arm hops ONTO FaceTime.** By construction no tile hop can currently
   land on `.faceTime` (video candidates exclude the phone and FaceTime-routed has none; audio
   never permits FaceTime), so the N-1 tile-side symptom is covered by the shared pins in the
   sibling suite plus the arm pins here; a behavioural tile arm would be a no-op that cannot
   fail on the N-1 revert (and a real-numbered hop onto FaceTime would dial for real — not
   hermetic).
4. **New tests use crash-safe option access (`.first?`/`dropFirst().first?` with `?? false`).**
   An indexed access after a count assert crashes the runner on regression instead of failing
   the case; the safe form fails cleanly — which the deferred negative control needs (a failing
   test record, not a crashed bundle). Pre-existing tests' indexed lines are untouched.
5. **Disclosure: the first gate attempt failed at build in this file.** Recorded in full in
   Gate item 1; the compile check is the honest delivered-bytes evidence until the sweep runs
   the suites.
6. **Doc-comment variance (comment-only):** the new section's header comment cites the
   cross-cutting chain requirements exercised (FR-CDP-003/004/010/015/016, NFR-CDP-002, SA-3)
   while the task file assigns FR-CDP-009/010/018, NFR-CDP-009 to this unit; both are accurate
   at their level (the unit's assignment vs. the behaviours the arms exercise) and no pin
   depends on the comment. Left as delivered rather than edited post-compile-check.

## Notes for the paired challenger

1. **Probe Deviation 1 first** — read design-l2 §9.2's emit expression and the task-file DoD side
   by side; arbitrate whether the suffix append is acceptable as the DoD's "direct strings stay
   byte-identical" or needs an escalation. Everything else is pinned either way.
2. **Probe the hop-arm inventory**: `performLaunchFailHop(` must appear exactly twice inside
   `performContactCall` (FaceTime arm, Messenger arm), zero times in `.phone`, zero from
   `case .whatsApp:` to the region end, and `candidates` must not appear in the WhatsApp tail.
   A whole-file grep will also hit the hop helper's own definitions and T-149 call sites — the
   pins scan the single `performContactCall` region (`func performContactCall(` → 
   `func performSystemContactCall(`).
3. **Probe hermeticity**: every behavioural arm's fixture has an empty phone and/or empty
   handle; the shipped openers fail before any `canOpenURL`/`open` (`openPhone` nil URL;
   FaceTime/Messenger/WhatsApp openers reject `invalid*` before probing). Anything that could
   reach `UIApplication.shared.open` from these arms is a hermeticity bug.
4. **Probe the console assertions against the bus format**: `[HH:mm:ss.SSS][component]
   eventType outcome=<verbatim> metadata=[:]`; the filters `[contact_call_buttons] tap ` and
   `[call_launch_fallback] hop` are substring-anchored on that format; `LogSanitiser` passes
   `outcome` verbatim (no escaping of `:`).
5. **Probe the settings-pair seeding**: `makeCoordinator` seeds UserDefaults BEFORE construction
   (the init restores through the persisted seams); `tearDown` restores prior values so the
   suite is order-independent. A challenger running the suite in isolation and then in the full
   bundle should see identical outcomes.

## Definition of done (task file, `:121-126`)

- [x] Video and audio vocabularies enforced at the tiles; floor reachable with everything else
      infeasible (`:221`, `:269` routing arms; `:369` floor arm; `:397` substituted-terminal arm)
- [x] Per-contact preferred always non-nil, pinned (`explicit: nil` absent, `:509-510`;
      preferred/vocabulary lines `:491-498`); shipped direct outcome strings — see Deviation 1
      (shipped prefix + statements byte-identical; suffix appended per design-l2 §9.2)
- [x] Invalid-phone terminal speaks once and never hops (`:458` behavioural — one line, zero
      hops; `:587-604` structural — zero hop calls, no `candidates` reference)
- [x] Announce at resolution, BEFORE the open, only on fallback (ordering pin `:512-519`;
      behavioural provenance arms `:369`, `:397`)
- [x] Hop branches thread `LaunchHop` into the family openers; exactly the two failure arms hop
      (`:546-585`); the `.phone` floor byte-identical and terminal (RES-10)
- [x] Carried fixes N-1/N-4 implemented and pinned (shared hunks; see T-151 notes items 6-7 and
      the negative-control plan; tile-side consume line pinned there)
- [x] Delivered bytes COMPILE (`ios/build/t151-compilecheck.log`, `TEST BUILD SUCCEEDED`, exit 0;
      this file recompiled in-log)
- [ ] Scoped run green `ios/build.sh test:unit ContactCallButtonsTests CallChannelResolutionTests`
      — **deferred to the consolidated end sweep** (not yet run; tests unaudited-against-run)
- [ ] Negative control (briefed) — **deferred to the same sweep** (plan recorded; expected reds
      live in the sibling suite — see Gate item 4)
- [ ] Code reviewed and merged — the paired challenger's review + integration commit (not this
      unit's call)
