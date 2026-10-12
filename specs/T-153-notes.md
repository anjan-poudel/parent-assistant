# T-153 — Missed-call dial-back routing and announcement — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-call-dialer-primary-secondary`
(branch `feat/call-dialer-primary-secondary`, HEAD `81bad0f7` = the W8 commit, base for this
unit). Unit: TG-31, risk HIGH. Assigned requirements (task file): FR-CDP-011 (missed-call
dial-back routes the chain), FR-CDP-018 (preserved behaviours; no router service, no per-contact
primary/secondary storage), NFR-CDP-009 (no regression on shipped call paths). Design references:
design-l2.md §7 `MissedCallDialRoute` + the pure dial-back decision (`:386-441`, L2-D9 at `:61`),
§9.3 `dialBackMissedCall` (`:753-786`), §10.1 failure classification / §10.2 the hop machinery
(`:796-924`, the `LaunchHop` carry), L2-D1 (the vocabulary-aware candidate list) and the §10.4
case table (`:904-915`), ADR-CDP-07 (announce at resolution, BEFORE the open), RES-10 (the floor
is terminal). Task spec: `specs/plan-tasks/tasks/TG-31-tap-paths-dial-back-and-settings.md`
T-153 section (`:128-178`). Carried findings implemented/discharged here: **W3-review N-2**
(`specs/implement-review-w3-t146.md:50-52` — the raw-vs-normalised handle derivation; pinned, not
"fixed") and the **W6-review N-4** phone carry as landed at W8 (`AppCoordinator.swift:7992`, the
additive defaulted `LaunchHop.phone`).

Process regime in force for this feature (owner directive): per-unit test gates and negative
controls are SUSPENDED — reviews and test runs happen in one consolidated sweep at the feature
end. One compile check (build-for-testing) was run and is the delivered-bytes evidence; no test
suite of any kind was executed by this unit. No commit, no push, no ai-sdd CLI command; the
untracked ` .ai-sdd/workflows/workflow.yaml` (engine state) was not touched, staged or committed.

## Status

**Implemented — production and tests delivered; the delivered bytes COMPILE (see Gate).** The
scoped unit run (`ios/build.sh test:unit MissedCallDialBackTests`, task-file DoD) and the
negative control are **DEFERRED** to the consolidated end sweep (owner directive). **No test in
this unit has been executed against a run** — the 22 tests are unaudited-against-run. Speech
only: the dial-back adds no console write, no catalogue key, no plist/pbxproj change; the
emergency/escalation path is untouched (evidence in Gate item 4).

## Files changed

| File | numstat (+/-) | Hunks | Notes |
|------|---------------|-------|-------|
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | 108 / 44 | 15 | Every hunk bounded to the two dial-back regions (old `:8808-8880` → new `:8808-8944`); nothing else in the file |
| `ios/ElderlyAssistantTests/App/MissedCallDialBackTests.swift` | 477 / 32 | 18 | The four `missedCallDialAction` call sites upgraded; the seam-resolution section (`:42-138`) and the identity/caption tests byte-frozen |

Delivered-bytes hashes (frozen at the compile check; recomputed after it, unchanged):

- `AppCoordinator.swift` md5 `7f50894d800b276dbf470c176a444d13` (mtime 07:34:38, before the run)
- `MissedCallDialBackTests.swift` md5 `ef6028c9b76d7fc65ca3b6a830aad7ad` (mtime 07:35:21, before the run)
- `CallChannelChain.swift` carries no diff entry (byte-frozen; task constraint honoured)

The test file's shipped tests: the eight `resolvedMissedCallChannel` seam cases and the three
row-identity/caption tests are byte-unchanged (the first content hunk after the header comment
edits is at old `:129`, the dial-action MARK line; the last shipped-test hunk boundary is old
`:185`, after which everything is additive). Suite total after this unit: 12 pre-existing + 10
new = **22 tests** (`grep -c "func test"` = 22; none yet run — see Gate).

## What was built

### 1. `MissedCallDialRoute` — `AppCoordinator.swift:8812-8821`

The design-l2.md `:393-402` listing verbatim (doc comments included), placed between the shipped
`MissedCallDialAction` enum and the decision, near the enum as briefed:

```swift
    struct MissedCallDialRoute: Equatable {
        let action: MissedCallDialAction
        /// The routed channel — nil for the two numberless actions,
        /// which return before the chain (nothing to route).
        let channel: CallApp?
        /// Skipped channels in attempt order (empty = no fallback).
        let fellBackFrom: [CallApp]
        /// The launch-fail candidates for `channel` ([] when nil).
        let hopCandidates: [CallApp]
    }
```

`Equatable` (synthesised) so the whole decision is comparable — the route-value tests assert
full-value equality where the brief asks for it.

### 2. `missedCallDialAction` — `AppCoordinator.swift:8835-8878` (design-l2.md `:404-438`, L2-D9)

The design listing in substance, with the shipped guards KEPT VERBATIM (their returns now wrap
the empty route; both return BEFORE the chain):

- `guard !phone.isEmpty else { return MissedCallDialRoute(action: .openPhoneApp, channel: nil, fellBackFrom: [], hopCandidates: []) }` (`:8842-8846`)
- `guard !ContactNumberKey.normalized(phone).isEmpty else { return MissedCallDialRoute(action: .unusableNumber(name: name), channel: nil, fellBackFrom: [], hopCandidates: []) }` (`:8847-8850`)
- `let preferred = familyContact?.resolvedAudioApp ?? defaultApp` (`:8862`)
- the seam call with `secondaryApp:` + `whatsAppInstalled:` and the **RAW shipped derivation**
  `messengerHandleAvailable: messengerHandle?.isEmpty == false` (`:8863-8868`) — **NOT**
  `hasUsableMessengerHandle` (L2-D9 + W3 N-2; see Test pin (f) and the coverage note below)
- the same switch mapping `route.channel` → action as today (`:8870-8877`)
- the final `return MissedCallDialRoute(action:channel:route.channel, fellBackFrom:route.fellBackFrom, hopCandidates: CallChannelChain.hopCandidates(preferred: preferred, secondary: secondaryApp, routed: route.channel, vocabulary: .audio))` (`:8873-8877`) — one snapshot; the dispatch re-derives no routing fact.

The T-146 bridge comment block was replaced by the in-body comment at `:8851-8861` citing
design-l2.md:404-438 and L2-D9 (design-l2.md `:8812-8821`-region + `:8835` doc block carry the
anchors in prose). The doc comment preserves the missed-calls-fix provenance (2026-09-18).

### 3. `dialBackMissedCall` — `AppCoordinator.swift:8899-8946` (design-l2.md `:753-786`)

- identity + family lookup unchanged (`:8900-8903`)
- `let route = Self.missedCallDialAction(phone: entry.phone, familyContact: family, defaultApp: defaultCallApp, secondaryApp: secondaryCallApp, messengerHandle: family?.messengerHandle, whatsAppInstalled: whatsAppInstalledNow, name: identity)` (`:8904-8911`)
- the announcement AT RESOLUTION, BEFORE the switch (`:8912-8921`):

  ```swift
  if let skipped = route.fellBackFrom.first, let channel = route.channel {
      // ADR-CDP-07 comment …
      speak(text: L10n.fmt("call.announce.fallbackRouted", locale: activeLocale,
                           CallChannelChain.label(skipped, locale: activeLocale),
                           identity,
                           CallChannelChain.label(channel, locale: activeLocale)))
  }
  ```

  Exactly one site; gated on provenance + non-nil channel; nothing spoken when nothing fell back.
- the hop (`:8922-8930`) with the N-4 carry, commented with the anchor chain (design-l2.md:772
  two-label form; the defaulted `phone` field at AppCoordinator.swift:7992):

  ```swift
  let hop = LaunchHop(candidates: route.hopCandidates,
                      handle: family?.messengerHandle,
                      phone: entry.phone)
  ```

- `switch route.action` (`:8931-8945`): `.openPhoneApp` → `PhoneAppOpener.openDialer()`
  (unchanged, `:8932-8933`); `.unusableNumber` → the shipped `speak(call.announce.noPhoneNumber,
  identity)` line unchanged (`:8934-8936`); `.call(let name, let phone)` → `performSystemContactCall(name:
  name, phone: phone)` with NO hop (`:8937-8938`, `// floor: no hop`); `.faceTime` →
  `performFaceTimeCall(name:phone:video: true, hop: hop)` (`:8939-8940`); `.whatsApp` →
  `performSystemContactWhatsApp(name:phone:hop: hop)` (`:8941-8942`); `.messenger` →
  `performSystemContactMessenger(name:handle:hop: hop)` (`:8943-8944`). All four openers accept
  `hop: LaunchHop? = nil` (verified at `:8265`, `:8291`, `:8329`, `:8421`).

The dial-back chain never touches emergency frames and lifts no guard: the diff's 15 production
hunks are all inside old `:8808-8880`; the emergency path is elsewhere and outside every hunk
(Gate item 4).

## Tests added / upgraded — `MissedCallDialBackTests.swift`

Houses: pure-static route cases + comment-stripped source scans of the private regions (the
`FeatureSourceScan` + `region`/`collapsed`/`occurrences` house pattern, helpers added at
`:671-698`). The file header (`:4-16`) and the T-146 bridge note (`:28-40`) were refreshed to
describe the delivered state (the seam itself is unchanged; the seam cases keep driving it).

| Test (`:line`) | Brief item | What it pins |
|---|---|---|
| `testNumberlessRowOpensPhoneApp` (`:145`) + `testUndialableNumberIsHonestDeadRow` (`:159`) | upgraded call sites | the shipped semantics kept, now reading the route: action + `channel == nil`, empty provenance/candidates |
| `testBothNumberlessGuardsCarryAnEmptyRoute` (`:174`) | **(a)** | both guards: FULL route equality (`.openPhoneApp` / `.unusableNumber(name:)` with `channel: nil`, `fellBackFrom: []`, `hopCandidates: []`) |
| `testUnmatchedNumberAlwaysDialsTel` (`:194`) + `testDirectTelFloorCarriesEmptyProvenance` (`:212`) | **(b)** | the tel floor under an unmatched number: `.call` route; direct floor → empty provenance; the FaceTime global default substitutes silently (empty provenance, no candidates) |
| `testMatchedFamilyContactDrivesTheAction` (`:226`) | upgraded call sites | the full matched-contact matrix with channel + provenance per leg |
| `testFloorReachableWithEveryOtherChannelInfeasible` (`:266`) | **(c)** | preferred messenger (no handle) + secondary whatsApp + probe false → FULL route: `.call`, `channel .phone`, `fellBackFrom [.messenger, .whatsApp]`, `hopCandidates []` (the audio terminal IS the routed channel) |
| `testFaceTimePreferenceStaysTheAudioFloorRoute` (`:287`) | **(d)** | audio-vocabulary semantics at the route level: matched FaceTime preference (via `resolvedAudioApp`) and unmatched FaceTime GLOBAL default both → full `.call` floor route, empty provenance, no candidates |
| `testDirectRouteCarriesNoProvenanceToAnnounce` (`:314`) | **(e)** | a direct route carries `fellBackFrom []` (the no-announce condition): WhatsApp preference with probe on, and the floor preferred |
| `testWhitespaceOnlyHandleKeepsTheRawDialBackDerivation` (`:344`) | **(f)** | the N-2 edge: `CallLinks.messengerHandle("   ")` is empty (the normalised predicate would say unusable) while the route resolves `.messenger` with `handle "   "` (raw derivation); both sides asserted — not weakened |
| `testRouteHopCandidatesAreTheChainsDerivedSuffix` (`:378`) | **(h)** | the hop candidates for the hop-eligible cells: expectation DERIVED from `CallChannelChain.hopCandidates(...)` directly and literal-pinned to the §10.4 documented `[.phone]`; floor-routed → `[]` |
| `testDialBackAnnouncesBeforeDispatchSourcePins` (`:430`) | **(g)** | comment-stripped scan of `dialBackMissedCall` (`func` → `var contactCallRecency`): exactly ONE `call.announce.fallbackRouted`; the announce block BEFORE `switch route.action`; the `fellBackFrom.first` + channel condition; skipped/identity/channel labels; the hop line with candidates + handle + `phone: entry.phone`; `hop: hop` exactly 3 in the switch (1 per faceTime/whatsApp/messenger arm) and ZERO before the switch and in the `.call` arm (which equals the shipped no-hop form); ZERO `observabilityBus`/`emit(` in the region; the SA-4(d) token scan (see below) |
| `testMissedCallDialRouteShapeSourcePins` (`:532`) | route value | the struct field-for-field (design-l2.md:393-402) |
| `testMissedCallDialActionSourcePins` (`:555`) | route value + **(f)** | the L2-D9 signature; both guards wrapped in the empty route; the `preferred` line; the RAW derivation needle; `hasUsableMessengerHandle` ABSENT; the single final return with `vocabulary: .audio` |

The source pins were additionally validated statically before the compile check with a one-off
Python emulation of `FeatureSourceScan.codeText` + the exact region/needle/count logic
(`/tmp/t153-static-check.py`, all checks pass). That is a static inspection, not a test run: the
XCTest assertions themselves remain unaudited-against-run.

## SA-4(d) evidence (item 5) — the no-await inspection

The dial-back chain is **synchronous**; nothing in it awaits, sleeps, retries or schedules.

- Token scan (raw lines, delivered file): the dial-back chain region `AppCoordinator.swift:8812-8949`
  (`MissedCallDialRoute` + `missedCallDialAction` + `dialBackMissedCall`) and the hop path
  `:8005-8057` (`launchFailHopStep` + `performLaunchFailHop`) each contain **0** occurrences of
  `await`, `sleep`, `Timer`, `retry`, `asyncAfter`, `DispatchQueue` and `Task`. Per-token counts
  were printed and are 0 for both regions.
- The same scan over the comment-stripped text (the exact region markers the test uses) is part
  of `testDialBackAnnouncesBeforeDispatchSourcePins` (`:513-525`), so a future edit that
  introduces a wait reddens the suite, not just this record.
- Dispatch targets: the four openers (`:8265` GSM, `:8291` FaceTime, `:8329` WhatsApp, `:8421`
  Messenger) are synchronous `func`s with zero `await`/`sleep`/`Timer`/`retry`/`Task` tokens in
  their bodies. Their only concurrency shape is the shipped, pre-existing one-way handoff in the
  GSM opener (`DispatchQueue.main.async { UIApplication.shared.open(url) }`, `:8273`; the same
  shipped pattern at `:7350`/`:7373`) — nothing awaits it and it predates this feature; the
  three hopping openers carry no dispatch at all.
- Emergency/escalation preservation (concrete checks run): `git diff | grep -in
  "emergency\|escalat"` finds exactly one hit — this unit's own test-file comment at
  `MissedCallDialBackTests.swift:644` (the SA-4(d) comment) — and **zero production hits**;
  `git status --porcelain` shows exactly the two owned files modified (plus the untracked engine
  `workflow.yaml`); the 15 production hunks are bounded to old `:8808-8880` (new `:8808-8944`).
  `CallChannelChain.swift`, the catalogue, Info.plist and the pbxproj carry no diff entry.

## Gate

1. **Scoped unit run (`ios/build.sh test:unit MissedCallDialBackTests`) — NOT RUN.** Deferred to
   the consolidated end sweep per the owner directive; no green suite claim is made anywhere in
   this record.
2. **Compile check — GREEN (the delivered-bytes evidence).** One `xcodebuild build-for-testing`
   (the W8 command, from `ios/`; `-project seniOS.xcodeproj -scheme ElderlyAssistant -destination
   "platform=iOS Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18" -derivedDataPath
   build/DerivedDataTests -skip-testing:ElderlyAssistantUITests`), log
   **`ios/build/t153-compilecheck.log`**: `** TEST BUILD SUCCEEDED **` (log line 1436),
   `COMPILECHECK_EXIT=0`, **zero `error:` lines**. Both edited files recompiled in-log
   (`AppCoordinator.swift` SwiftCompile at log :619-620; `MissedCallDialBackTests.swift` at
   :1052-1054). No test was executed by this check. The log's 31 warnings are all pre-existing
   (other files, or pre-existing AppCoordinator lines — :2272, :3903, :5446, :5470, :7548,
   :8731, :9354, :10546, :11248); none cite lines in the delivered regions (`:8812-8946`) or the
   test file.
3. **Negative control (briefed) — NOT RUN; plan recorded** (see below).
4. **Static pin verification — run (not a test suite).** `/tmp/t153-static-check.py` re-derived
   every region marker, needle and occurrence count of the source pins against the delivered
   bytes; all checks pass. Recorded because it is real verification that happened, and it is not
   a substitute for the deferred XCTest run.

## Deferred negative-control plan (for the end-stage sweep operator)

Restore target: `AppCoordinator.swift` md5 `7f50894d800b276dbf470c176a444d13`,
`MissedCallDialBackTests.swift` md5 `ef6028c9b76d7fc65ca3b6a830aad7ad`. Candidate reverts and
their expected reds (all reds are in THIS suite; each revert is a source-level edit of the
delivered hunks):

1. **Delete the announce block** (`:8912-8921`) → expected reds:
   `testDialBackAnnouncesBeforeDispatchSourcePins` (the `call.announce.fallbackRouted` count
   becomes 0; the announce-region `XCTUnwrap` throws). No other test in the suite should redden
   (the route values are unaffected).
2. **Revert the hop to the two-label form** (drop `phone: entry.phone,`, `:8930`) → expected red:
   `testDialBackAnnouncesBeforeDispatchSourcePins` (the hop needle). The N-4 phone's behavioural
   consequence is out of this suite's reach (no dial-back behavioural arm runs the openers) — the
   honest red lives in the source pin only.
3. **Drop `hop: hop` from one arm** (e.g. whatsApp `:8942`) → expected red: the `hop: hop`
   count 3→2 plus the arm needle.
4. **Swap the raw derivation for the normalised predicate** (`:8866` →
   `hasUsableMessengerHandle(...)`) → expected reds: `testMissedCallDialActionSourcePins` (raw
   needle absent, `hasUsableMessengerHandle` present) and
   `testWhitespaceOnlyHandleKeepsTheRawDialBackDerivation` (the whitespace-handle route becomes
   `.call` — full route equality fails).
5. **Swap `vocabulary: .audio` in the final return** (`:8877`) → expected red:
   `testMissedCallDialActionSourcePins` (the final-return needle). Note for the operator: the
   behaviour-level legs in this suite all use a `.phone` secondary, where `.audio` and
   `.anyChannel` agree; the vocabulary argument is source-pinned and the discriminating
   behaviour cell (a `.faceTime` secondary filtered per §10.4) is pinned at the chain level by
   the sibling suites, not here (coverage note below).

## Deviations and coverage notes

1. **No edit after the compile check.** The delivered bytes were frozen at the compile check;
   the coverage note below was deliberately NOT chased with a file edit, because that would have
   invalidated the single compile-check evidence (the T-152 deviation-6 precedent: recorded, not
   patched post-check).
2. **Coverage note (h): the audio-vocabulary argument is source-pinned, not behaviour-pinned for
   the `.faceTime`-secondary cell.** The delivered behavioural hop-candidate legs use the
   `.phone` secondary (per the brief's example); a hypothetical `.audio` → `.anyChannel` swap at
   the single final return would be caught by `testMissedCallDialActionSourcePins`' final-return
   needle but not by a behavioural arm of this suite. If the end-stage reviewer wants a
   behavioural discriminator, add the §10.4 `.audio` cell (messenger preferred + handle, FaceTime
   secondary → `[.phone]` with `.faceTime` filtered) as a new leg of
   `testRouteHopCandidatesAreTheChainsDerivedSuffix` in the sweep — flagged here rather than
   edited post-check.
3. **The N-2 divergence is pinned as shipped behaviour, not fixed** (as briefed): the raw
   `messengerHandle?.isEmpty == false` derivation routes `.messenger` for a whitespace-only
   handle where the normalised row/voice predicate would skip it. Pinned at both levels (route
   value + source needle). The private predicate itself cannot be called from the test; the
   divergence is asserted at the reachable `CallLinks.messengerHandle` level plus the route.
4. **Comment-only variance:** the new doc/in-body comments cite the design anchors
   (design-l2.md:404-438, :753-786, :772, L2-D9, ADR-CDP-07, the N-2/N-4 reviews); the comment-
   stripped pins are unaffected by them by construction.

## Notes for the end-stage reviewer

1. Probe the raw-derivation pin first: `AppCoordinator.swift:8866` must read
   `messengerHandleAvailable: messengerHandle?.isEmpty == false,` and `hasUsableMessengerHandle`
   must be ABSENT from the `missedCallDialAction` region — the divergence from the row/voice
   predicate is design-sanctioned (L2-D9) and pinned (W3 N-2), not a defect.
2. Probe the announce ordering: the announce block sits between the route resolution and the
   `switch route.action` (`:8912` < `:8931`), gated on `fellBackFrom.first` + non-nil channel;
   exactly one `call.announce.fallbackRouted` in the region; zero `observabilityBus`/`emit(`.
3. Probe the hop threading: `hop: hop` exactly 3 times (the three hopping arms), zero in the
   `.call` arm (`:8938` is the shipped no-hop statement verbatim) and zero before the switch;
   the hop carries `phone: entry.phone` (N-4).
4. Probe the guards: both numberless returns wrap the empty route BEFORE the chain; the
   non-empty switch mapping and the `?? ""` handle fallthrough are the shipped forms.
5. The tests are unaudited-against-run: run `test:unit MissedCallDialBackTests` in the sweep, and
   treat Gate item 2 (compile check) as the delivered-bytes evidence until then.

## Definition of done (task file, `:172-177`)

- [x] Route value returned with routed channel, provenance and candidates; shipped guards intact
      (production `:8812-8821`, `:8835-8878`; tests (a)-(f), route-shape + decision source pins)
- [x] Announcement precedes dispatch and names the routed channel (pinned; source pin (g);
      behavioural consequence pinned through the route's provenance values (b)/(c)/(e))
- [x] Emergency and escalation paths untouched; no-await inspection recorded (SA-4(d) section)
- [x] Delivered bytes COMPILE (`ios/build/t153-compilecheck.log`, `** TEST BUILD SUCCEEDED **`,
      exit 0, zero errors; both files recompiled in-log)
- [ ] Scoped run green `ios/build.sh test:unit MissedCallDialBackTests` — **DEFERRED** to the
      consolidated end sweep (not run; tests unaudited-against-run)
- [ ] Negative control (briefed) — **DEFERRED** to the same sweep (plan recorded above)
- [ ] Code reviewed and merged — the end-stage review + integration (not this unit's call)
