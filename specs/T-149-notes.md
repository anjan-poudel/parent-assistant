# T-149 — Launch-fail hop machinery and opener threading — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary`
(branch `feat/call-dialer-primary-secondary`, base `9165174b` = wave 5, T-148). Unit: TG-30,
wave 6, risk HIGH, effort L, component C5 (design-l2 §10). Depends on T-148 (landed); blocks
T-150/T-152/T-153. Requirements: FR-CDP-015, FR-CDP-016, NFR-CDP-004. Design references:
design-l2 §10.1 failure classification table (`:794-…`), §10.2 listings, §10.3 termination proof,
§10.4 vocabulary case table, the voice-path region (`:592-609`), §13 edit rows 12/14/15, §14
interface summary, §15 steps 5-8, §21 (LaunchHop = internal nested type), §22-24 (taxonomy +
hop event), §28 (suite/seam rows). Task spec:
`specs/plan-tasks/tasks/TG-30-voice-confirmation-and-launch-fail-hop.md` T-149 section
(`:86-142`).

## Status

**Done — scoped gate green (32/32), nothing committed, nothing pushed.** Two owned files
touched and nothing else; no new catalogue key (the hop line `call.announce.launchFailedFallback`
pre-exists), no new console write (speech + the one event), no new dependency, no ai-sdd
command, no commit, no push, no `git clean`/`restore`.

## Files changed

| File | numstat (+/-) |
|------|---------------|
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 160 / 4 |
| `ios/ElderlyAssistantTests/Services/Voice/CallChannelResolutionTests.swift` | 685 / 0 |

`git diff -U0` shows the ONLY four removed lines are the four opener signatures (rewritten with
the additive `hop` parameter) — `performSystemContactCall(name:phone:)`,
`performFaceTimeCall(name:phone:video:)`, `performSystemContactWhatsApp(name:phone:)`,
`performSystemContactMessenger(name:handle:)`. Every other hunk is a pure insertion, and every
success/recovery branch of the four openers is byte-untouched. The test file has **zero
deletions**: all 26 pre-existing tests are byte-intact, including the T-145 chain-level
termination test `testHopConsumesCandidatesNeverLoops` (`:315`).

## What was built

### 1. `LaunchHop` + `launchFailHopStep` — the ONE spoken site (`:7969`, `:7984`)

```swift
    struct LaunchHop: Equatable {
        let candidates: [CallApp]
        let handle: String?
    }

    func launchFailHopStep(after failed: CallApp, candidates: [CallApp],
                           handle: String?, name: String,
                           locale: Locale) -> (next: CallApp, remaining: [CallApp])? {
        guard let next = CallChannelChain.nextLaunchFailCandidate(
                after: failed,
                attemptOrder: candidates,
                messengerHandleAvailable: hasUsableMessengerHandle(handle)) else {
            return nil
        }
        noteLaunchFailHop(after: failed, next: next)
        speak(text: L10n.fmt("call.announce.launchFailedFallback", locale: locale,
                             CallChannelChain.label(failed, locale: locale),
                             name,
                             CallChannelChain.label(next, locale: locale)))
        let remaining = Array(candidates.drop(while: { $0 != next }).dropFirst())
        return (next, remaining)
    }
```

Design-l2 §10.2 listing verbatim (the only added doc paragraph records the access relaxation —
deviation 1). The catalogue key pre-exists (T-155: en `%1$@ didn't open for %2$@ — trying %3$@.`,
ne `%2$@ को %1$@ खुलेन — %3$@ मार्फत प्रयास गर्दैछु।`); the argument order binds the failed
label, the contact name and the next label — exactly the listing's slots.

### 2. `noteLaunchFailHop` — the hop event (`:8036`)

```swift
    private func noteLaunchFailHop(after failed: CallApp, next: CallApp) {
        observabilityBus.emit(ObservabilityEvent(
            component: "call_launch_fallback",
            eventType: "hop",
            durationMs: nil,
            outcome: "\(failed.rawValue):\(next.rawValue)",
            errorCode: nil,
            metadata: [:]
        ))
    }
```

SA-6: closed tokens only — component, event type, and the `failed:next` channel raw values;
`metadata: [:]`. Never a name, never a number, never a handle. No console write is introduced —
the event rides the existing `ConsoleObservabilityBus`/`LogSanitiser` seam.

### 3. `performLaunchFailHop` — the tap path (`:8009`)

```swift
    @discardableResult
    private func performLaunchFailHop(after failed: CallApp,
                                      candidates: [CallApp],
                                      name: String, phone: String, handle: String?,
                                      isVideo: Bool, locale: Locale) -> Bool {
        guard let step = launchFailHopStep(after: failed, candidates: candidates,
                                           handle: handle, name: name,
                                           locale: locale) else { return false }
        switch step.next {
        case .phone:
            performSystemContactCall(name: name, phone: phone)   // floor: its own honest line
        case .faceTime:
            performFaceTimeCall(name: name, phone: phone, video: isVideo)
        case .whatsApp:
            performSystemContactWhatsApp(name: name, phone: phone,
                                         hop: LaunchHop(candidates: step.remaining, handle: handle))
        case .messenger:
            guard let handle, !handle.isEmpty else { return true }  // filtered above; defensive
            performSystemContactMessenger(name: name, handle: handle,
                                          hop: LaunchHop(candidates: step.remaining, handle: handle))
        }
        return true
    }
```

Design listing verbatim. Its callers land in T-151/T-153 (tap surfaces); this unit exercises it
through the shipped openers' own failure branches (`testHopOpenerWiringEndToEnd`).

### 4. `hopFromCallAction` — the voice path (`:8052`) and its wiring

```swift
    private func hopFromCallAction(after failed: CallApp, action: PendingCallAction,
                                   isVideo: Bool, locale: Locale) {
        guard let step = launchFailHopStep(after: failed,
                                           candidates: action.hopCandidates,
                                           handle: action.contact.messengerHandle,
                                           name: action.contact.name,
                                           locale: locale) else { return }
        performCallAction(action.replacing(
            method: CallChannelChain.method(for: step.next, isVideo: isVideo),
            hopCandidates: step.remaining))
    }
```

Wired in `performCallAction` AFTER each shipped failure line has spoken — the FaceTime arm
(`:7895-7899`):

```swift
                speak(text: L10n.str("router.call.facetimeUnavailable", locale: locale))
                // FR-CDP-015 (L2 §10.1): the shipped honest line just
                // spoke; a remaining candidate hops — announced by the
                // shared step, then re-entered through THIS executor.
                hopFromCallAction(after: .faceTime, action: action,
                                  isVideo: isVideo, locale: locale)
```

and the Messenger arm (`:7946-7950`):

```swift
                speak(text: L10n.fmt("router.call.messengerNoHandle", locale: locale, action.contact.name))
                // Same rule as the FaceTime arm (L2 §10.1): the honest
                // line has spoken, then a remaining candidate hops.
                hopFromCallAction(after: .messenger, action: action,
                                  isVideo: action.method == .messengerVideo, locale: locale)
```

The `.phone` case, the `.whatsappChat` case and **every success branch** are untouched. Records
nothing on failure stays exactly as shipped (no learning, no activity, no history from a failed
open — the hop only decides, says and re-attempts).

### 5. Opener threading — additive `hop: LaunchHop? = nil`, failure branches only

- `performFaceTimeCall(name:phone:video:hop:)` (`:8215`) — in `.unavailable, .invalidHandle`
  after the shipped honest line:
  `performLaunchFailHop(after: .faceTime, candidates: hop?.candidates ?? [], name: name, phone: phone, handle: hop?.handle, isVideo: video, locale: locale)`.
- `performSystemContactMessenger(name:handle:hop:)` (`:8343`) — in `.invalidHandle` after the
  shipped line and the shipped tap event:
  `performLaunchFailHop(after: .messenger, candidates: hop?.candidates ?? [], name: name, phone: "", handle: hop?.handle, isVideo: false, locale: locale)`.
- `performSystemContactWhatsApp(name:phone:hop:)` (`:8253`) — parameter accepted, **never
  consulted**: every outcome is TERMINAL (`.invalidPhone`) or a RECOVERY
  (`.needsNativeCompose`, `.copiedNumber`) per §10.1; only a failure-with-hop row may hop
  (RES-10). The call-chat opener's recovery chain stays non-hopping, as the task spec requires.
- `performSystemContactCall(name:phone:hop:)` (`:8189`) — parameter accepted for call-site
  uniformity per the task spec, deliberately never consulted: the GSM floor is TERMINAL
  (design-l2 §10.1, "the floor is the last resort"). See deviation 2.

## Termination proof statement (for the unit report)

> The hop walks strictly shrinking candidates: each step selects the first remaining candidate
> that is not the failed channel and, for Messenger, has a usable handle on file
> (`CallChannelChain.nextLaunchFailCandidate`), then consumes the list through
> `drop(while: != next).dropFirst()` — a suffix consumption that removes `next` and everything
> before it, so the next step sees a strictly smaller list. `|hopCandidates| ≤ 2` by construction
> (`hopCandidates` is the attempt-order suffix after the routed channel, and the vocabulary
> terminal is appended only when that suffix is empty), so the depth is at most two and no
> channel is ever attempted twice; a vocabulary-substituted routed channel yields no candidates
> at all; the floor never re-hops; and exhaustion returns `nil` while speaking nothing beyond
> the caller's already-spoken failure line. No hop step re-enters the confirmation flow — the
> voice path re-enters `performCallAction` (the executor a fresh confirmation reaches) with
> `action.replacing(...)`, so there is no re-pending and no re-prompt. Synchronous throughout
> (NFR-CDP-004): no `await`, no timer, no queue, no detached task anywhere in the chain.

Pinned by `testHopStepConsumesCandidatesNeverRepeats` (behavioural: the §10.4 worked example
plus the 64-cell matrix through the real step, `XCTAssertEqual(cells, 64)`) and
`testHopNeverReEntersConfirmationOrAwaits` (source: the re-entry site, the absence of
confirmation symbols, the absence of await/schedule/loop statements).

## Tests added (6, all in `CallChannelResolutionTests.swift`)

| Test (`:line`) | Scenario | What it pins |
|------|----------|--------------|
| `testHopStepConsumesCandidatesNeverRepeats` (`:870`) | "Candidates never loop (failure)" | The voice worked example (`[.whatsApp, .phone]` after a failed `.messenger`, attempted `[.messenger, .whatsApp, .phone]`, sizes `[2, 1, 0]`, 2 steps); the same walk over the whole 64-cell matrix through the REAL step (each step returns a member of its own list, never a repeat, strictly shrinking; depth ≤ 2; the exhaustion residual is only a handle-less messenger; cells counted at 64; `hopEventLines == sweepSteps`); exhaustion (empty list, messenger-only-without-handle, and the vocabulary-substituted `[]` case) returns nil and emits nothing. |
| `testLaunchFailedFallbackSpokenOnce` (`:987`) | "A failed launch hops to the next candidate once" | The hop step speaks exactly once per hop: one captured event whose payload is pinned byte-exactly (from `[call_launch_fallback]`: `hop outcome=faceTime:phone metadata=[:]` — closed tokens, no name, no digits); a second call over the consumed list exhausts with no further line; source-pinned single key site (1 literal in the whole coordinator), exactly one `speak(text:` in the step region, the collapsed spoken listing matching the step verbatim (catalogue slot order); the key resolves in both en and ne. |
| `testMessengerWithoutHandleSkippedInHop` (`:1051`) | "A messenger candidate without a handle is skipped inside the hop" | Handle-less messenger is dropped and the floor proceeds; the control leg (same list, `maya.gurung`) selects messenger — a feasibility filter, not a ban; suffix consumption `[.phone]`; the two hop lines in order; the component occurs exactly twice (the dropped candidate is never announced); a messenger-only list without a handle is exhaustion. |
| `testAdditiveFieldsKeepOldCallSites` (`:1104`) | "The additive fields keep the shipped call sites compiling" | The override's amended construction (whitespace-collapsed, token-exact) names none of the three new fields; the TWO `IntentLogStoreTests` constructions (read via source scan — the file is outside this unit's ownership) name the five shipped labels and none of the new fields; the voice step names `fellBackFrom`/`hopCandidates` (the T-148 edit, by design) and not the clock; `replacing` names `requestedAt`/`hopCandidates` and not `fellBackFrom`; plus runtime defaults (empty provenance/hop list) and `replacing` semantics (clock preserved, provenance reset, flywheel slot follows the hopped method). |
| `testHopNeverReEntersConfirmationOrAwaits` (`:1207`) | "Candidates never loop" (second half) | `hopFromCallAction` re-enters `performCallAction(action.replacing(` exactly once and touches no confirmation symbol (`pendingCallAction`, `requestCallConfirmation`, `confirmationPrompt`, override/response handlers, `isAwaitingCallConfirmation`); the machinery holds no await/async/Task/DispatchQueue/Timer/sleep/schedule and no loop statement at all; the floor dispatch is dispatched once through the shipped floor opener, and the tap helper never re-enters the voice executor. |
| `testHopOpenerWiringEndToEnd` (`:1256`) | Integration leg (FR-CDP-015) | Hermetic end-to-end through the SHIPPED openers: Arm 0 — the floor opener with a hop on board produces no hop event and its own honest line (terminal); Arm A — `performSystemContactMessenger(handle: "")` (fails without building any URL, so nothing is probed or opened) speaks its shipped tap event FIRST, then one hop line `messenger:phone`, then the floor's `call.announce.noPhoneNumber`; Arm B — the same failure hopping to WhatsApp ends on `.invalidPhone` (TERMINAL per §10.1) with exactly one hop line and the `whatsapp:invalidPhone` tap event; `activityLog` count unchanged across all arms (a failed open records nothing). |

The suite now executes **32 tests** (26 pre-existing + 6 new).

## Gate

Command (from the worktree root): `ios/build.sh test:unit CallChannelResolutionTests`

- Exit code: **0** — `** TEST SUCCEEDED **`.
- `Selected tests` / xctest bundle: **Executed 32 tests, with 0 failures (0 unexpected)** in
  0.475 s.
- xcresult (authoritative pass list):
  `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.12_06-23-18-+1100.xcresult`
- Retained log: `ios/build/t149-gate.log` (same command, `tee`d). A pre-test compile-only log
  from the checkpoint run is retained at `ios/build/t149-precheck.log` (26/26 at that point).
- In-build guards, both green **before** the tests: the source-privacy guard (all rules with
  their positive/negative fixtures behaved — including `feature-console-write` and
  `feature-unlisted-metadata-key`, so the hop event adds no console write and no unlisted
  metadata key) and the intent-prompt mirror guard (seed mirrors `IntentPrompt.build`
  byte-for-byte, 2717 bytes, 4 placeholders; all 7 drift self-tests rejected).
- No build-database lock contention occurred on either run; no retry needed.
- Honest note: the FIRST gate run (after the test additions, 06:21) failed 2/32 — both were
  self-inflicted assertion bugs in the NEW tests, fixed before the green run: (a) one source
  pin collapsed only the needle while matching against the raw region (fixed: collapse both
  sides); (b) the collapsed equality carried a trailing space from the region boundary (fixed:
  trim both sides). The production code was green on the first run (26/26) before any test was
  added. The two pins failing-first is also evidence they are load-bearing, not tautologies.

## Deviations from the design / task spec (with reason)

1. **`launchFailHopStep` access: `private` → internal.** The §28 seam for the hop behaviour
   suite is the step driven with the real catalogue; a `private` member is unreachable across
   files. The relaxation mirrors T-148's `confirmationPrompt` precedent exactly, is recorded in
   the function's doc comment, and changes no signature or body line (the design listing does
   not pin the modifier). `performLaunchFailHop`, `noteLaunchFailHop` and `hopFromCallAction`
   stay `private` as listed. The alternative — driving every assertion through the real openers
   — is not fully available in the unit bundle: a FaceTime or `tel:` open would place a real
   call on a device, and the WhatsApp opener's happy paths leave the hermetic envelope. The
   one hermetic integration leg (messenger `.invalidHandle`) IS driven through the shipped
   action-level call sites (`testHopOpenerWiringEndToEnd`).
2. **The system phone opener gained a `hop` parameter it never consults — task spec says four
   openers, design §14 says three search-shaped openers.** The task spec
   ("Implementation notes") names four openers that gain the additive parameter, including the
   system phone opener; the design's §10.1 table classifies the floor as TERMINAL and the §14
   interface summary lists the hop parameter only on the three hopping openers. Implemented as
   the UNION, conservatively: the parameter exists on all four (call-site uniformity — T-151/
   T-153 call sites can pass a hop uniformly), and `performSystemContactCall` never reads it —
   the floor is terminal per §10.1 and a caller-side error can never silently introduce a hop
   the failure table forbids. Doc comment records the reconciliation. **For the reviewer to
   adjudicate** whether the design should be amended to four or the parameter dropped from the
   floor opener (dropping it would make the four call sites asymmetric in the same wave).
3. **`performLaunchFailHop`'s `.faceTime` leg does not thread the hop onward — design listing
   verbatim.** Consequence: a mid-list `.faceTime` candidate (reachable when the vocabulary
   falls back to FaceTime, e.g. routed `.messenger` with candidates `[.faceTime, .phone]`)
   drops its remaining suffix if FaceTime itself fails to open. This is conservative (never a
   loop — the depth bound holds), and the listing is followed verbatim rather than "improved";
   flagged for the challenger to probe against §10.1 rows 11-12 and the §10.3 proof.
4. **Unused `hop` parameter on `performSystemContactWhatsApp`** (design §14 signature, task spec
   verbatim): documented as accepted-for-uniformity, never consulted — all its rows are
   terminal or recovery. Pinned behaviourally in Arm B (the hopped WhatsApp leg does not
   re-hop).
5. **The messenger opener's hop carries no phone number** (design §14 gives it
   `name:handle:` only): a hopped `.phone` leg therefore lands on the shipped
   `call.announce.noPhoneNumber` line (pinned in Arm A) instead of dialing. Honest and terminal;
   recorded in the opener's doc comment. The call-site surfaces that DO hold the number keep it
   on their own floor path (T-151/T-153's job).
6. **Test-name collision resolved by the distinct name (dispatch option b).**
   `testHopConsumesCandidatesNeverLoops` already existed at `:315` (T-145's chain-level SA-2
   statics walk + 64-cell sweep) and is byte-frozen — the test file diff is +685/-0. Editing it
   would have destroyed T-145's frozen evidence, so the coordinator/hop-step-level termination
   proof lands under the distinct name `testHopStepConsumesCandidatesNeverRepeats`. The task
   spec's "extend the resolution suite: testHopConsumesCandidatesNeverLoops, …" is satisfied in
   substance: the suite's termination coverage now spans the chain statics (existing tests 26)
   AND the real hop step (new test), and the four named capabilities all exist by name.
7. **"Speaks exactly once" is evidenced behaviourally plus at the source, not by audio.** A unit
   test drives the coordinator before `start()`, where `speak` is a documented no-op (no queue,
   no `noteAssistantSpoke`). The single spoken-line SITE (1 key literal, 1 `speak(text:` in the
   step, the collapsed listing equality, both catalogues resolving) plus the one-hop-one-event
   count is the honest unit-level evidence; the audio itself stays DV-2 territory — the same
   scoping T-148 recorded.

## Notes for the paired challenger

1. **Probe deviation 3 first**: drive `performLaunchFailHop` with `after: .messenger, candidates:
   [.faceTime, .phone]` (routed `.messenger` under `.anyChannel`) and confirm the intended
   reading of §10.1 — the listing's `.faceTime` leg omits the hop, so the `.phone` suffix is
   abandoned. If the design intends the hop to continue, it is a one-line listing fix ({hop:
   LaunchHop(candidates: step.remaining, handle: handle)}) — decide and record.
2. **Probe the floor's terminality directly**: `performSystemContactCall(name:phone:"",hop:)`
   with any candidate list must produce no hop event (Arm 0) — confirm the parameter can never
   be consulted by a future edit without failing that test (it would need someone to *delete*
   the pin, which is the point).
3. **Check the hermeticity claim**: `CallLinks.openMessengerThread(handle: "")` returns
   `.invalidHandle` BEFORE building any URL (no `canOpenURL`, no `open`), and
   `CallLinks.openWhatsAppCallChat("")` returns `.invalidPhone` before its probe; the floor leg
   uses `phone: ""` so `PhoneDialer.url` is nil. If any of those guards ever reorders, the
   integration test could start probing the platform — worth a source pin in a later wave
   (outside this unit's ownership: `CallLinks.swift`, `RedesignComponents.swift`).
4. **The event-shape pin** excludes only the timestamp (slices from `[call_launch_fallback]`);
   confirm no sanitiser path could add metadata keys (`LogSanitiser` passes component/eventType/
   outcome through and filters metadata — an added key would fail the exact-equality pin).
5. **The collapse/trim helpers are duplicated across suites** (`CallConfirmationWordingTests`,
   `DialogueCoordinatorWiringTests`, now here) — a house extraction is possible but was not done
   (outside this unit's owned files). The two new-file failures in the first gate run came from
   exactly this fragility; the pins are now collapse-both-sides + trim.

## Definition of done

- [x] Hop walks strictly shrinking candidates, depth at most two, single spoken line site
      (behavioural 64-cell walk + source pins; termination statement above)
- [x] Hop event shape pinned: closed tokens, empty metadata, no numbers or handles anywhere
      (exact-payload equality + no-name/no-digit assertions)
- [x] Openers take the additive hop parameter; the shipped constructions pin green
      (two coordinator sites + two log-store sites pinned; floor/whatsApp parameters documented
      as never-consulted)
- [x] Scoped run green: `ios/build.sh test:unit CallChannelResolutionTests` (32/32, exit 0)
- [x] No new console writes beyond the single hop event; privacy guard green
- [ ] Code reviewed and merged — coordinator's paired review + integration commit
