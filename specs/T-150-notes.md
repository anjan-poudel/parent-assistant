# T-150 — Failure-honesty guards: phone floor and whatsappChat disposition — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary`
(branch `feat/call-dialer-primary-secondary`, base `0e145701`). Unit: TG-30, risk HIGH, effort M,
components C3 (launch outcome) + C5 (failure classification); depends on T-149 (landed); blocks
T-157. Requirements: FR-CDP-018, NFR-CDP-003. Design references: design-l2 §10.1 table rows for
`.phone` (`design-l2.md:800`) and `.whatsappChat` (`design-l2.md:803`), the M-1 disposition (i)
paragraph (`design-l2.md:817`), the phone-floor listing (`design-l2.md:568-577`), the
`.whatsappChat` prose (`design-l2.md:613`). Task spec:
`specs/plan-tasks/tasks/TG-30-voice-confirmation-and-launch-fail-hop.md` T-150 section
(`:144-196`).

## Status

**Done — scoped gate green (34/34), nothing committed, nothing pushed.** Two owned files touched
and nothing else: no new catalogue key (the shipped `call.announce.noPhoneNumber` line is reused
through the shipped helper `announceNoUsableNumber` — the five-key bound stays T-155's), no new
console write, no new dependency, no ai-sdd command, no commit, no push, no `git clean`/`restore`.
`CallLinks.swift` is untouched — `git status --short` lists exactly the two owned files (plus the
pre-existing untracked `.ai-sdd/workflows/workflow.yaml` engine state, outside the artifact
surface).

## Files changed

| File | numstat (+/-) | Hunks |
|------|---------------|-------|
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 14 / 2 | 2 |
| `ios/ElderlyAssistantTests/Services/Voice/CallChannelResolutionTests.swift` | 253 / 2 | 3 |

The coordinator's ONLY two removed lines are the two discarded-result open calls
(`callLinks.openPhone(action.contact.phone)`, `callLinks.openWhatsAppChat(action.contact.phone)`);
every other production line is a pure insertion, and every shipped success/recovery statement of
both cases is byte-untouched. The test file's ONLY two removed lines are exactly the two lines of
the itemised carried edit (item 3 below) — `git diff -U0` proves it:

```
-                                   and: "private func hopFromCallAction(", in: source)
-        XCTAssertFalse(machinery.contains("performCallAction("),
```

Everything else in the test file is additive; the file grows 1510 → 1761 lines.

## What was built

### 1. `.phone` — the false-result guard (design listing verbatim), `AppCoordinator.swift:7864-7879`

```swift
        case .phone:
            guard callLinks.openPhone(action.contact.phone) else {
                // RES-8/RES-10: the floor is terminal but its open can
                // still fail (an undialable number) — the shipped honest
                // line, no hop exists from the floor.
                announceNoUsableNumber(contact: action.contact, locale: locale)
                return
            }
            contactNumberUsed(action.contact.phone)
            setOutcome(icon: "phone.fill",
                       text: L10n.fmt("home.outcome.callPlaced", locale: locale, action.contact.name))
            speak(text: L10n.fmt("router.call.calling", locale: locale, action.contact.name))
            noteConfirmedCallExecution(action)
            recordActivity(kind: .call, channel: .phone,
                           contactName: action.contact.name,
                           phone: action.contact.phone)
```

The guard block (comment included) is the design-l2 `:568-577` listing verbatim; the open call
MOVED into the guard — it is called once and its `Bool` is consumed, never twice. The five
statements below it are byte-identical to the shipped success path. On the `false` path: the
shared helper `announceNoUsableNumber` speaks the shipped `call.announce.noPhoneNumber` line (its
own card + speech, unchanged — `AppCoordinator.swift:8811-8815` at the base, `:8823-8827` after
this edit's net +12 lines), and nothing
else runs — no `contactNumberUsed`, no success `setOutcome`, no
`noteConfirmedCallExecution`, no `recordActivity`, and no hop (the floor is terminal, RES-10).
`openPhone` is `@discardableResult func openPhone(_ rawPhone: String) -> Bool`
(`CallLinks.swift:340`), false only when the phone URL is nil.

### 2. `.whatsappChat` — the M-1 disposition (i) guard, `AppCoordinator.swift:7907-7923`

```swift
        case .whatsappChat:
            guard callLinks.openWhatsAppChat(action.contact.phone) else {
                // M-1 disposition (i) (T-144, design-l2 §10.1): false means
                // no dialable digits remain — the shipped honest line, no
                // success, no learning, no activity, no hop (RES-10).
                announceNoUsableNumber(contact: action.contact, locale: locale)
                return
            }
            setOutcome(icon: "message.fill",
                       text: L10n.fmt("home.outcome.whatsappOpened", locale: locale, action.contact.name))
            speak(text: L10n.fmt("router.call.whatsappOpened", locale: locale, action.contact.name))
            noteConfirmedCallExecution(action)
            // The wa.me chat opened — a genuine MESSAGE surface (the only
            // one WhatsApp exposes to a deep link; see Channel.whatsapp).
            recordActivity(kind: .message, channel: .whatsapp,
                           contactName: action.contact.name,
                           phone: action.contact.phone)
```

The shipped silent drop (`AppCoordinator.swift:7755-7765` at the design-time anchor — the
counterexample the disposition row exists to close) is gone: the opener's `Bool` is consumed as
the guard's condition and `false` follows disposition (i) EXACTLY like the phone floor —
`announceNoUsableNumber` (no new key), record no success, no learning and no activity, no hop
(RES-10), then return. `openWhatsAppChat` is
`@discardableResult func openWhatsAppChat(_ rawPhone: String) -> Bool` (`CallLinks.swift:366`),
false only when `whatsAppChatURL` is nil because no dialable digits remain. On `true` the four
shipped success statements are byte-identical (including the shipped `contactNumberUsed`-free
success set — that helper is not part of this branch's shipped shape).

The call-chat opener's recovery chain is NOT consulted anywhere in this branch: `needsNativeCompose`
/ `copiedNumber` belong to `openWhatsAppCallChat` only (`CallLinks.swift:457-470`, design-l2
`:613`), whose own non-false recoveries stay non-hopping and byte-untouched (the unit diff never
opens `CallLinks.swift`; pinned read-only by the new tests).

### 3. Carried test edit — W6 review note N-8(a) (adjudicated into this wave)

In `testHopNeverReEnters + ConfirmationOrAwaits` (the T-149 source test,
`CallChannelResolutionTests.swift:1207`), the machinery source-scan region is WIDENED to include
`hopFromCallAction`:

- before: `struct LaunchHop: Equatable {` → `private func hopFromCallAction(` (exclusive) —
  80 comment-stripped lines;
- after: `struct LaunchHop: Equatable {` → `private func noteConfirmedCallExecution(` —
  97 comment-stripped lines, so the synchronous-machinery scan (no `await`/`async`/`Task`/
  `DispatchQueue`/`Timer`/sleep/schedule, no loop statement) now covers the voice hop's re-entry
  body too.

Re-derived counts inside the widened region (before → after):
`case .phone:` 1 → 1; `performSystemContactCall(name: name, phone: phone)` present → present;
`performCallAction(` **0 → 1** (the only re-entry is `hopFromCallAction`'s, as designed); every
forbidden sync token and the loop regex still absent in both widths. The one assertion that had
to be re-derived is the old negative `XCTAssertFalse(machinery.contains("performCallAction("))`:
it becomes a count pin on the widened region (exactly ONE re-entry) PLUS a new negative pin on
the tap helper's own narrowed region
(`private func performLaunchFailHop(` → `private func noteLaunchFailHop(`), so the original
semantic — "the tap helper never re-enters the voice executor" — stays exact rather than being
weakened. This is the only edit to a pre-existing test; the other 25 pre-existing tests and the
other five T-149 tests are byte-frozen.

## Tests added (2 — the source-pin pair the task names)

Both live in a new `// MARK: - Failure-honesty guards (T-150)` section
(`CallChannelResolutionTests.swift:1345-1582`), following the house pattern: comment-stripped
source scans (`FeatureSourceScan`), `region`/`collapsed`/`occurrences` helpers, exact token and
occurrence assertions. The executor is `private` and the pending slot is `private(set)`, so no
unit seam reaches the guard (this unit adds no access relaxation — T-149's §28 relaxation covers
`launchFailHopStep` only, and `performCallAction` stays private as listed); the source pin is
therefore the honest ceiling here, and the SHARED helper's behaviour is exercised end to end in
`testHopOpenerWiringEndToEnd` Arm 0 (the shipped tap floor speaks the same
`call.announce.noPhoneNumber` line and records nothing).

| Test (`:line`) | Scenario | What it pins |
|------|----------|--------------|
| `testPhoneFalseSpeaksTheLineNoHop` (`:1376`) | "The phone floor reports a false result honestly" | Region = the `.phone` case inside `performCallAction`. The open exists ONCE and the case STARTS with the guard (`guard callLinks.openPhone(action.contact.phone) else {`); the collapsed guard block — `guard … else { announceNoUsableNumber(…locale: locale) return }` — is present verbatim, so the `false` body holds exactly the honest line and the return and nothing else (any success/learning/activity statement entering the `else` body breaks the match); every shipped success token (`contactNumberUsed`, `home.outcome.callPlaced`, `router.call.calling`, `noteConfirmedCallExecution`, `recordActivity(kind: .call, channel: .phone,`) sits AFTER the guard's return and occurs exactly once; no hop symbol (`hopFromCallAction`, `launchFailHopStep`, `performLaunchFailHop`, `LaunchHop`, `hopCandidates`) and no hop line (`call.announce.launchFailedFallback`) appears in the case; the reused helper binds `call.announce.noPhoneNumber` exactly twice (card + speech) and reports the failure icon, and the key resolves in both en and ne. |
| `testWhatsAppChatFalseSpeaksTheLine` (`:1468`) | "The whatsappChat false result follows the recorded disposition" + "Any other outcome of the call-chat opener keeps its shipped recovery" | Region = the `.whatsappChat` case inside `performCallAction`. The Boolean is CONSUMED: one `callLinks.openWhatsAppChat(` occurrence, as the guard's condition, and the case STARTS with the guard (the shipped bare discarding statement can no longer be reached); the collapsed guard block is present verbatim (honest line + return only); `contactNumberUsed(` occurs ZERO times; `home.outcome.whatsappOpened`, `router.call.whatsappOpened`, `noteConfirmedCallExecution(`, `recordActivity(` each occur exactly once and all AFTER the guard's return; the shipped success block is byte-identical (whitespace-collapsed, shipped order); no hop symbol, no hop line, and none of `needsNativeCompose` / `copiedNumber` / `openWhatsAppCallChat` appears in the case; read-only scans of `CallLinks.swift` pin the other end — the chat opener's body carries no recovery machinery (`needsNativeCompose`, `copiedNumber`, `canSendText`, `copyText` all absent between `func openWhatsAppChat(` and `func openWhatsAppText(`) and the call-chat opener's shipped recovery chain is present byte-for-byte (collapsed) in `openWhatsAppCallChat`. |

Load-bearing, not tautological: both tests FAIL against the pre-edit shape. A negative-control
gate run on a temporarily reverted coordinator (only the two guards reverted; the test file
untouched) produced 34 executed / 4 failures — 2 assertion failures in each new test
("the guard is the FIRST statement of the case" + "the guard … is absent") and 32 passes — then
the coordinator was restored and verified byte-identical (md5
`58bc45bb0946592a8351b103e671c617` before and after the revert). The base-source simulation of
the same scan logic fails 15 of the same assertions.

Suite total: 26 pre-existing + 6 T-149 + 2 new = **34 tests**.

## Gate

Command (from the worktree root): `ios/build.sh test:unit CallChannelResolutionTests`

Three runs, in this order (the retained log is the last one):

1. **First run — green.** 34/34, exit 0. Bundle
   `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.12_06-46-59-+1100.xcresult`
   (34 passed / 0 failed). No self-inflicted failure on this run; nothing needed fixing.
2. **Negative control — expected red.** Same command against the temporarily reverted coordinator;
   log retained at `ios/build/t150-negative-control.log`; bundle
   `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.12_06-48-56-+1100.xcresult`
   — 32 passed / 2 failed (exactly the two new tests).
3. **Final run on the delivered bytes — green (authoritative).** Bundle
   `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.12_06-51-15-+1100.xcresult`
   — `result: Passed`, 34 passed / 0 failed / 0 skipped; the bundle's per-case list contains all
   34 cases as `Passed`, both new tests included. Retained log: `ios/build/t150-gate.log`
   (`** TEST SUCCEEDED **` at line 103).

- In-build guards, both green **before** the tests (log order proves it): the source-privacy
  guard at lines 17-46 (all 12 rules × positive/negative fixtures behave, including
  `feature-console-write` and `feature-unlisted-metadata-key` — the new guards add no console
  write and no event) and the intent-prompt mirror at lines 48-58 (seed mirrors
  `IntentPrompt.build` byte-for-byte, 2717 bytes / 4 placeholders; all 7 drift self-tests
  rejected). The scoped `only-testing` line follows at line 59.
- No build-database lock contention; no retry needed.
- The gate ran on iPhone 17 Pro (iOS 26.5) simulator, macOS 26.6.2, x86_64.

## M-1 precondition evidence (T-144 disposition anchor)

The disposition this unit implements is recorded in the corrected design record, not invented
here:

- `specs/design-l2.md:817` — the M-1 disposition (i) paragraph, headed "the `.whatsappChat` false
  case (recorded; implemented in T-150)": a `false` result is a data failure handled exactly like
  the `.phone` floor's `openPhone == false`; the branch speaks the shipped
  `call.announce.noPhoneNumber` line and records no success, no learning and no activity; "Silence
  is not an acceptable disposition; the pre-existing silent drop (`AppCoordinator.swift:7755-7765`)
  is the counterexample this row exists to close"; the chat opener's recovery chain is not
  consulted. The §10.1 table row (`design-l2.md:803`) states the same as
  "failed, data (M-1 disposition (i)) … NO hop (RES-10)".
- `specs/plan-tasks/tasks/TG-29-chain-core-and-record-corrections.md:52` — the T-144 Gherkin line
  recording the disposition: "And the M-1 disposition (i) is recorded: on a false result the
  branch speaks the shipped call.announce.noPhoneNumber line and records no success, no learning
  and no activity" (scenario "The MAJOR finding (openWhatsAppChat) is corrected and dispositioned",
  `:47-52`).

T-144 (TG-29, wave 1) is landed in this branch's history before this unit's base, so the
ordering precondition ("do not start otherwise") holds.

## F-6 — recorded slot-liveness input, no action taken

`specs/implement-review-w1.md:44-46` (finding F-6, informational) records that an expired call
window leaves the call slot pended — source-verified, no nil write on the timeout path, so
`isAwaitingCallConfirmation` stays true after an expiry until a response or another write — and
asks T-150's slot-liveness reasoning to treat that as a recorded input, especially around the
routing-busy check and the early-return removal. **Read and acknowledged; no action taken beyond
the guard placement itself**, exactly as the task directs. This unit touches neither the pending
slot, the confirmation window, the routing-busy check nor any early return: its production diff
is confined to the two cases of `performCallAction`, which runs only after
`handleConfirmationResponse` has already nil'ed the slot (`AppCoordinator.swift:10929-10930`), so
the F-6 condition cannot reach the new guards.

## Deviations from the design / task spec (with reason)

1. **The `.whatsappChat` guard carries a 3-line explanatory comment inside its `else` body,
   which the task's snippet does not show.** The task gives the phone guard as the design listing
   verbatim (comments included) and the whatsappChat guard as a bare code snippet. Implemented as
   the snippet's code lines EXACTLY, plus a comment in the phone guard's own style (RES-8/RES-10
   there; the disposition + RES-10 here) citing the T-144 anchor. Comment-only; the
   comment-stripped pins cannot see it, and no code line differs from the prescribed snippet.
2. **The carried test edit's one re-derived assertion (N-8(a)) is expressed as a count pin plus a
   new narrowed-region negative pin, not as a single edited negative.** Widening the region makes
   `performCallAction(` legitimately present (0 → 1: the voice hop's re-entry), so the old
   `XCTAssertFalse` could not survive unchanged. Chosen form: `occurrences(...) == 1` on the
   widened region AND `XCTAssertFalse(tapHelper.contains("performCallAction("))` on the tap
   helper's own region — the original semantic is preserved exactly, nothing is weakened, and the
   region declaration gained a comment recording the widening. Before/after counts are disclosed
   above (item 3).
3. **No runtime leg for the two new guards.** `performCallAction` is private and the pending slot
   is `private(set)`; driving it would require a new test-only seam the task does not authorise
   (and this unit's spec names exactly the two source-pin tests). The behavioural half is covered
   by the shipped sibling: `testHopOpenerWiringEndToEnd` Arm 0 drives the identical tap-floor
   guard through the real opener and asserts the shipped honest line + nothing recorded. No
   compile-forced divergence exists: the production code compiled with no change beyond the two
   hunks.

## Notes for the paired challenger

1. **Probe the negative control first** (`ios/build/t150-negative-control.log`, bundle
   `Test-ElderlyAssistant-2026.10.12_06-48-56-+1100.xcresult`): it is the cheapest proof that both
   new tests are load-bearing rather than tautological. Re-derive that the restored
   `AppCoordinator.swift` is byte-identical (md5 `58bc45bb0946592a8351b103e671c617`) and that the
   authoritative green bundle `06-51-15` was produced from those exact bytes.
2. **Independently re-derive the region endpoints**: `performCallAction` is bracketed by
   `private func performCallAction(` → `struct LaunchHop: Equatable {` (the MARK comment between
   them is stripped), and the two case regions stop at the next `case` label — an added success
   statement inside either `else` body breaks the collapsed guard-block equality, and an added
   second open breaks the occurrence pins.
3. **Probe the `hasPrefix` pins**: they assert the case STARTS with the guard, so nothing
   (no success card, no learning write) can execute before the open's result is known. If a
   future wave legitimately needs code before the guard, the pin should move with the design.
4. **Probe the absence pins against the right surface**: `needsNativeCompose` / `copiedNumber`
   still exist in `CallLinks.swift` (inside `openWhatsAppText` `:386`, `openWhatsAppCallChat`
   `:466-469`, and the `WhatsAppCallOutcome` cases `:184-187`); the pins here are scoped to the
   `.whatsappChat` case region and to the chat opener's own body, so a whole-file grep
   "proving" they exist does not touch them.
5. **`contactNumberUsed` is deliberately pinned at ZERO in the `.whatsappChat` case**: that is the
   shipped shape of the branch (it never recorded a used number), not an omission of this unit —
   the byte-identical success-block pin is what keeps it honest.
6. **No catalogue or console surface moved**: the privacy guard (12 rules, 24 fixtures) and the
   prompt-mirror guard are green in the same log; no new key, no new event. If a challenger
   suspects a new key, the check is `git diff` — the only literals added by this unit are none.

## Definition of done

- [x] Phone false-case guard speaks the shipped line once and records nothing
      (`testPhoneFalseSpeaksTheLineNoHop`; helper reused; nothing on the false path)
- [x] The whatsappChat branch honours disposition (i); the silent-false site is closed
      (`testWhatsAppChatFalseSpeaksTheLine`; Boolean consumed; zero `contactNumberUsed`)
- [x] Recovery outcomes of the call-chat opener unchanged (pinned) (chat-opener body scan +
      byte-identical `openWhatsAppCallChat` recovery chain; `CallLinks.swift` untouched by the
      diff)
- [x] Scoped run green: `ios/build.sh test:unit CallChannelResolutionTests`
      (34/34, bundle `…06-51-15…`, guards green first; retained log `ios/build/t150-gate.log`)
- [x] Unit report cites the T-144 disposition anchor (M-1 precondition evidence)
      (`design-l2.md:817`; TG-29 `:52`)
- [ ] Code reviewed and merged — the paired challenger's review + integration commit
      (carried; not this unit's call)
