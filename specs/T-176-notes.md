# T-176 — Consent prompt and plain-language disclosure at first cloud chat need (implement notes)

**Status: implemented, scoped suite green.** Worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`, HEAD `95354ef7` + working tree).
No commits, no pushes, no ai-sdd state-mutating commands. Declared files exactly; no other edit
by this unit. Final evidence: `./build.sh test:unit CloudChatConsentPromptTests
CloudChatConsentGateTests` → **61 executed, 0 failures, 0 skipped — TEST SUCCEEDED** (24 prompt
tests of this unit + 37 gate cross-check), exit 0, house guards green.

## What was built

| File (declared) | Lines | Contents |
|---|---|---|
| `ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatConsentPrompt.swift` | 302 | `CloudChatConsentPrompt` — `@MainActor final class … ObservableObject`, `import Foundation` only. The one entry point `consentNeedDetected(answerPendingTurnLocally:)`, presentation state `@Published private(set) var isPromptPresented`, `sheetSurface`/`updateLocale`, `reofferSpokenAnswer`, `refreshAfterDecisionChange`, the answers `grant()`/`decline()`/`submitSpokenAnswer(_:)`, and the outcome types (`Outcome` with `allowsEgress`, `SpokenAnswer`, `AnswerOutcome`). |
| `ios/ElderlyAssistant/Services/Intents/CloudChat/Views/CloudChatConsentSheet.swift` | 160 | `CloudChatConsentAction` (exactly two fields: `kind`, `title`; plus the derived `accessibilityIdentifier`), `CloudChatConsentSheetSurface` (the four catalogue keys resolved per locale; deliberately no failure line — see Decisions), `CloudChatConsentSheet` (one `actionButton` builder for both answers, `.interactiveDismissDisabled(true)`). |
| `ios/ElderlyAssistantTests/Services/Intents/CloudChat/CloudChatConsentPromptTests.swift` | 838 | 24 tests (list below), incl. two test-only doubles: the seam counters `PromptSeams` and `CloudChatPromptGarbageWriteStorage`. |

Nothing else was modified by this unit. `ios/seniOS.xcodeproj/project.pbxproj` shows a diff
because `build.sh` regenerates it via XcodeGen — expected, left in place (it now carries this
unit's two new production files under `Views/` and the new test file).

## The entry point and the injected seam (the call contract T-175/T-177 consume)

`consentNeedDetected(answerPendingTurnLocally: () -> Void) -> Outcome` is the ONE place the
question can appear. It reads `gate.currentDecision()` fresh and:

| Gate decision at the call | Returned `Outcome` | Local seam | Question |
|---|---|---|---|
| `.granted` | `.cloudAllowed` | **not run** (the turn may egress; serving it twice would be the bug) | not shown |
| `.notRecorded` | `.awaitingDecision` | run once | shown (first time) + spoken capture offered once |
| `.denied` | `.localOnly(.denied)` | run once | closed, never re-shown this session |
| `.unreadable` | `.localOnly(.unreadable)` | run once | never shown (fail closed; a broken record is not a question for the elder) |

Presence/liveness: the guard `isPromptPresented` makes repeated turns answer their own turns
without re-asking. `updateLocale(_:)` re-resolves every string; `reofferSpokenAnswer()` re-arms
the capture only while the question is live; `refreshAfterDecisionChange()` closes the question
when the gate has a decision; both answer paths (`grant()`, `decline()`, and `submitSpokenAnswer`
which delegates to them) reach `gate.record(granted:)` exactly once and return
`AnswerOutcome.recorded | .writeFailed(error) | .questionNotLive`.

## Decisions made during implementation

1. **No observability events of this unit's own.** T-172's `EventCatalogue` is the frozen,
   test-pinned schema (its suite asserts the event set); the design declares no prompt-shown
   event for cloud chat, and the gate's `consent_recorded` / `consent_denied` /
   `consent_write_failed` are the classification-only evidence that a decision happened.
   Presentation is verified in tests through `isPromptPresented` and the seam spies, not through
   invented telemetry. No content can travel: the prompt has no text parameter at all (pinned
   by source scan: no `String`, no `print(`, no transport/model tokens in the controller).
2. **No failure line inside the sheet — and a proposed key for the owner.** The 18-key consent
   family (T-171) has no "could not be saved" string (`livetranslate.consent.failed` and
   `pointask.consent.failed` exist for those features only), and the catalogue is not a
   declared file of this unit, so no string was invented in code. Failure is surfaced honestly
   without it: `AnswerOutcome.writeFailed` to the wiring, the gate's `consent_write_failed`
   event, and a failed **grant** leaving the question on screen (the elder's retry is one tap
   away; the routing decision keeps refusing). **Proposal for the coordinator / T-171's file**
   if the owner wants the elder told on-screen: add `cloud.chat.consent.failed`, en
   `"That could not be saved. Please try again."` / ne
   `"यो सुरक्षित हुन सकेन। कृपया फेरि प्रयास गर्नुहोस्।"` (zero slots, like the rest of the
   family), and a `failureMessage` slot on `CloudChatConsentSheetSurface`. Not done: not my
   declared file.
3. **The spoken capture is offered once, at presentation; re-arming is explicit.** `startSpokenCapture()`
   fires exactly once when the question appears (the elder is never required to touch). The
   capture window has its own lifetime; if it lapses unanswered while the question is still up,
   T-177 calls `reofferSpokenAnswer()` (a no-op when no question is live). The question is never
   re-asked per turn.
4. **A spoken yes/no outside the live question is not an answer.** `submitSpokenAnswer` when
   `isPromptPresented == false` returns `.questionNotLive` and writes nothing — a late voice
   "yes" after a recorded "no" cannot flip the session's decline, and a voice "yes" a year later
   cannot grant without the disclosure having been on screen. Explicit, declared, tested.
5. **A failed decline closes the question; a failed grant keeps it up.** The gate mirrors the
   deny before it writes, so the elder's "no" stands for the session even when the write fails
   (`.writeFailed` is still returned — the record may not survive a restart). A failed grant
   means the answer did not take effect, so the question stays exactly where it was.
6. **`.cloudAllowed` does not run the local seam.** The race is real (the elder answers the
   previous turn's question while the current turn is being decided); the outcome makes
   double-serving structurally impossible instead of leaving it to the wiring's discipline.
7. **Decline is final for the session; re-ask only after explicit revocation/re-enable or
   relaunch.** Revoked and denied both read `.denied` in-process (the gate's deny mirror);
   revocation tested end-to-end, including the explicit re-enable path
   (`gate.record(granted: true)` clears the mirror, the next turn is `.cloudAllowed` with no
   question and no local fallback).

## Open item 1 — the disclosure-version stamp (T-172's seam): proposed change, NOT applied

The gate (line 128) ships
`var disclosureVersion: String = "cloudchat.disclosure.draft.14oct2026.r1"`, and its doc
comment says the `draft.` marker is deliberate because "the disclosure copy and its review are
T-176's … and the stamp says so until that review lands". Finalising it requires editing
`ios/ElderlyAssistant/Services/Intents/CloudChat/CloudChatConsentGate.swift` — **not a declared
file of this unit, so it was not edited.** Exact proposed change for whoever owns that file next
(T-172's owner; coordinator to dispatch):

```swift
// CloudChatConsentGate.swift, line 128 (Config)
- var disclosureVersion: String = "cloudchat.disclosure.draft.14oct2026.r1"
+ var disclosureVersion: String = "cloudchat.disclosure.14oct2026.r1"
```

plus the comment paragraph above it (lines 120-122) updated from "the stamp says so until that
review lands" to state that the OD-12/13 copy review landed and to keep the sanitizer rationale
(the `14oct2026` shape must stay — `2026-10-14` is scrubbed by `LogSanitiser`).

Rationale: (a) the marker's stated precondition is an **owner** copy review (OD-12/13), not a
unit self-review — it would be dishonest for this unit to declare that review complete; (b) the
shipped precedent stamp `pointask.disclosure.19sep2026.r1` carries no `draft.` segment, so the
final form is known; (c) flipping the stamp invalidates every grant recorded under the draft
stamp (stale grant → `.notRecorded` → the disclosure is shown again under the new copy), which
is the gate's designed version-bump behaviour and loses nothing on a pre-release build.
Readiness note: this unit's test asserts `metadata["disclosureVersion"] == Config.default.disclosureVersion`
(follows the constant, not the literal), so the change will not break this suite.

## Open item 2 — T-171's softener-"न" template question: ACCEPTED, no change proposed

T-171 recorded (its Decision 4) that the safe templates use the softener "न"
("फेरि भन्नुहोस् न"), which is not one of the style spec's six particle units, and deferred the
question to this unit's owner copy review. Disposition: **accept as correct.**

- The style spec's particle lexicon (`tools/train-intent/seeds/nepali-chat-style-spec`:
  `{"budget":1,"units":["हुन्छ नि","होला नि","हो नि","छ नि","अनि","है","नि","ला","ल"]}`) does not
  contain bare "न", so T-169's guard counts zero reply particles in the templates — the
  one-particle budget cannot be violated by them **by construction**. There is no guard defect
  to fix and no copy defect to correct.
- Grammatically the bare "न" here is the respectful-imperative softener
  ("फेरि भन्नुहोस् न" — "do say it again"), which is idiomatic spoken Nepali; the spec's "नि" is
  a confirmation-seeking question tag and would read as wrong/pushy in a request.
- No catalogue edit is needed, and none is possible from this unit (the catalogue is T-171's
  file). Recorded here so the owner copy review sees the acceptance with its rationale rather
  than a silent assertion.

## Spec/artifact tensions and deviations (honesty record)

1. **The brief's required reading `specs/T-172-notes.md` does not exist** (verified: not in the
   worktree; T-172 landed in Wave 0 without a notes file, and `specs/T-175-notes.md` is absent
   too, T-175 still in flight). The authoritative T-172 interface was read instead: the shipped
   `CloudChatConsentGate.swift` in full and its 918-line `CloudChatConsentGateTests.swift` (whose
   pinned invariants — single consent-key literal, the event catalogue, the cloud-chat source
   sweep that now includes this unit's `Views/` file — this unit's files satisfy; the full
   combined run is green).
2. **Pre-existing flake observed in T-172's suite (not this unit's file, not fixed here):**
   `CloudChatConsentGateTests.testConcurrentGrantAndRevokeNeverLeaveATornOrMixedRecord` failed
   once on the first combined run (`XCTAssertTrue failed … never a mixture: notRecorded`) and
   passed on the final run. Cause, from the gate source: the grant path's read-back
   (`let confirmation = withLock { readStoredDecision() }`, line 373) and the deny-mirror clear
   (`withLock { deniesInMemory = false }`, line 377) are two separate lock acquisitions, so a
   concurrent revoke (deny-mirror set at line 422, delete at line 428) can delete the record
   between them; the grant then clears the mirror after the delete and the final state is
   mirror=false + record absent = `.notRecorded`. That state is semantically consistent (the
   revoke won; next launch re-asks, which is the designed re-ask rule after revocation), and the
   assertion's own message text says "(or cleanly absent)" — but the code rejects
   `.notRecorded`. Recommendation for T-172's owner: widen the assertion to accept
   `.notRecorded` (or make read-back+clear one critical section). Left untouched: the file is
   not declared for this unit.
3. **Build contention history (evidence trail, all per the wait-and-retry protocol; DerivedData
   never deleted, no clean):** run at 22:07 failed with `unable to attach DB … build.db:
   database is locked` (a sibling build on the same `build/DerivedDataTests`); run at 22:11
   failed compiling this unit's test file (`Published.wrappedValue` is unavailable in this SDK —
   fixed by reading the public property instead); run at 22:13 failed on the sibling T-174
   agent's mid-edit `ReplyGrammarFlagResolutionTests.swift` (`Immutable value 'self.escalation'
   may only be initialized once`); waited for the sibling file's mtime to be stable for 6+
   minutes, then the 22:24 run was green.
4. **Test-technique note:** `@Published` properties reflect as `_name` through `Mirror`, and
   `.wrappedValue` on a reflected `Published` is unavailable on this SDK — the state test pins
   the reflected field set (underscore-stripped) and reads the public `isPromptPresented`
   instead.
5. **What the render test does and does not prove:** the ImageRenderer measurement reads the
   pixels of both drawn answers (two accent runs, each ≥ 44 pt × scale − 4 px) plus the
   source-level equal-weight bans; it does not synthesise taps. The button action closures are
   exercised through the controller API (`grant()`/`decline()`, which is what the wiring's
   closures call), and the two-answers-one-builder structure is pinned by scan.

## Gherkin / DoD → test mapping (24 tests, all in `CloudChatConsentPromptTests`)

| Scenario / DoD item | Tests |
|---|---|
| First cloud chat need presents the disclosure; nothing sent while pending | `testTheFirstCloudNeedPresentsTheQuestionAnswersTheTurnLocallyAndSendsNothing`, `testThePendingDecisionKeepsTheRoutingDecisionRefusingEgress` (via the real `CloudChatRouting.decide`, all other inputs yes) |
| Talkative turn never blocked | same two + `testTheQuestionIsAskedOnceAndStaysNoMatterHowManyTurnsArrive` (26 turns, capture offered once) |
| Race: consent landed before the need | `testAGrantThatLandedBeforeTheNeedAllowsEgressAndSendsNothingLocal` |
| Voice answers work (gate's one writer) | `testTheSpokenYesIsRecordedThroughTheGatesOneWriterAsGranted` (event metadata = disclosureVersion only), `testTheSpokenNoIsRecordedAsDeniedAndClosesTheQuestion`, `testTheTouchAnswerAndTheSpokenAnswerTakeTheSamePath` (identical record bytes), `testASpokenAnswerWhenNoQuestionIsLiveIsNotAnAnswer` |
| Decline final for the session | `testADeclineIsDeniedForTheSessionAndTheQuestionIsNeverReAsked`, `testAPendingTurnThatArrivesAfterADeclineIsStillAnsweredLocally` |
| Relaunch without an answer | `testARelaunchWithoutAnAnswerIsStillNotRecordedAndEgressIsStillRefused` |
| Write failure surfaced | `testAGrantWhoseWriteFailsIsSurfacedAndTheQuestionStaysUp`, `testAGrantThatLandsAsGarbageIsReportedAsUnreadableAndNeverAsSuccess` (unreadable read-back is never a grant), `testADeclineWhoseWriteFailsStillDeniesAndClosesTheQuestion` |
| Unreadable record never asks | `testAnUnreadableRecordNeverPresentsTheQuestion` |
| Revocation surfaces cooperate | `testARevocationFromTheOtherSurfacesClosesTheQuestion` (incl. explicit re-enable) |
| Capture re-offer | `testTheCaptureIsReOfferedOnlyWhileTheQuestionIsUp` |
| Copy from the catalogue, both languages, zero slots | `testEveryStringOnTheSheetComesFromTheCatalogueInBothLanguages`, `testTheSheetCarriesNoComposedOrHardcodedCopy` |
| No timeout / no auto-dismiss / no implicit grant (test-pinned) | `testNoTimeoutNoAutoDismissAndNoImplicitGrantPathExists` (banned-token scan + `interactiveDismissDisabled(true)` required + one `gate.record(` site), `testTheQuestionHasExactlyOnePresentationEntryAndNoOtherHook` |
| No content / no transport anywhere | `testThePromptHoldsNoTransportNoModelAndNoContentParameter`, `testThePromptStateIsTheGateAndTheQuestionOnly` |
| Accessibility (large type, 44 pt, plain language, no technical terms) | `testTheSheetRendersTwoFullTapTargetAnswersAndFollowsTheHouseTypography` (ImageRenderer pixel measurement), plus T-171's term-ban suite over the copy |

## Test results (exact commands and counts)

Command form (from `ios/`):

```
./build.sh test:unit CloudChatConsentPromptTests CloudChatConsentGateTests
```

1. **Run 1, 22:01 — 61 executed, 8 failures.** First compile-and-run of this unit's tests; all 8
   failures were triaged to two sources: (a) this unit's test harness created two gate instances
   in four tests (the prompt used its own gate while the assertions read a second one) and two
   wrong scan expectations (the `@Published` mirror label; `minHeight` count 2-vs-1 — the sheet
   has exactly one button construction); (b) the pre-existing gate concurrency flake above.
   xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_22-01-06-+1100.xcresult`.
2. **Runs 2-4, 22:07-22:13 — no test evidence** (build-db lock, then this unit's
   `wrappedValue` compile error, then the sibling agent's mid-edit file; see Deviations 3).
3. **Run 5, 22:24 — 61 executed, 0 failures, 0 skipped; `** TEST SUCCEEDED **`; exit 0;
   wrapper `=== Scoped unit run passed (baseline not advanced) ===`.** Per-suite (from
   `xcrun xcresulttool get test-results tests`): `CloudChatConsentPromptTests` 24 passed;
   `CloudChatConsentGateTests` 37 passed. House guards green in the same run
   (`check-release-log-safety.sh`, `check-prompt-mirror.sh` — both exit 0). xcresult:
   `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_22-24-00-+1100.xcresult`.
   Device: iPhone 17 Pro simulator, iOS 26.5 (x86_64).

**Coverage statement (honest bound):** the scoped scheme's result bundle carries no coverage
data (same as recorded for T-173), so no measured percentage is claimed. By construction every
executable path of the three new files is exercised: all three `consentNeedDetected` branches
and the presented/not-presented sub-branch, both `refreshAfterDecisionChange` outcomes, both
`reofferSpokenAnswer` outcomes, all `answer(granted:)` paths (liveness guard, success, grant
failure, decline failure), `updateLocale`, `sheetSurface`, and the view's `body`/`actionButton`
builder for both actions via the render test. The only not-executed code is the SwiftUI button
action closure bodies as such (no synthetic taps in a unit host) — their targets are covered
directly. No test was claimed that was not run; the failing intermediate runs are itemized above.

## Wiring recipe for T-175/T-177 (handoff)

- One `CloudChatConsentGate` per session (T-172, the coordinator's lifecycle), passed into
  `CloudChatConsentPrompt(gate:locale:startSpokenCapture:)`. `startSpokenCapture` arms the
  shipped spoken-confirmation capture for a yes/no.
- At the call site where a chat turn's routing decision (T-173) returns
  `.local(reason: .consentNotRecorded)`: call
  `prompt.consentNeedDetected(answerPendingTurnLocally: { answerLocally(turn) })` **instead of
  answering locally separately** — the seam call runs the local answer exactly once. On
  `.awaitingDecision`/`.localOnly` the turn is already answered (nothing more to do); on
  `.cloudAllowed` the seam did NOT run (the grant landed concurrently) — the caller then either
  re-reads the routing decision (it now says `.cloud`) or answers locally, its choice per lane.
- Spoken answers: map the capture's confirmation to `prompt.submitSpokenAnswer(.yes/.no)`.
  `.questionNotLive` means the capture answered something else — ignore. `.writeFailed` is the
  surface's cue (T-177's indicator/voice feedback); a failed grant leaves the question up.
- Revocation/re-enable surfaces write through the gate (`revoke()` / `record(granted: true)`)
  and then call `prompt.refreshAfterDecisionChange()`.
- The sheet is rendered when `prompt.isPromptPresented` (if presented via `.sheet`, use a
  custom `Binding(get:set:)` whose setter is a no-op — the only exits are the two answer
  closures). On app language change call `prompt.updateLocale(_:)`.
- Do not prompt at launch, in Settings navigation, or from an utterance alone: the only trigger
  is a chat-classified turn whose routing decision needed the consent answer (FR-CNR-009; the
  recorded Gemini-stack transcription exception stands per the design).

## Open items handed to the coordinator

- Open item 1: the disclosure-version stamp edit (proposed change above; gate file, not declared
  for this unit).
- Open item 2: the "न" softener — accepted, recorded for the OD-12/13 owner copy review (no
  change requested).
- The `cloud.chat.consent.failed` key proposal (Decision 2), if the owner wants an on-screen
  write-failure line.
- The T-172 gate concurrency assertion (Deviation 2) for T-172's owner.
- DV items (spoken prompt heard in the elder's language, VoiceOver reading of the sheet, the
  question not being swipe-dismissable on device) are T-186/device work, not assertable in a
  unit process.
