# TG-05 — Consent gate, prompt, revocation and the cloud-activity indicator: implementation notes

Tasks: **T-014 `LiveTranslateConsentGate`** (C09), **T-015 consent prompt and revocation** (C09 surfaces),
**T-016 `CloudActivityIndicatorModel`** (C10).
Worktree: `.claude/worktrees/live-camera-translation`. Uncommitted, per the workflow (no commits were made).
Requirements: FR-LCT-010, FR-LCT-011, FR-LCT-012, FR-LCT-013, FR-LCT-015 · NFR-LCT-004, NFR-LCT-007,
NFR-LCT-012 · Amendments **AM-1, AM-4, AM-7** (and AM-10 where it binds) · Security design review
**SD-1**, **E-6** · **CL-2** (`specs/review-l2.md`).

## What was built

### T-014 — `LiveTranslateConsentGate` (C09)

`ios/ElderlyAssistant/Services/LiveTranslate/LiveTranslateConsentGate.swift` (485 lines).

- **Four decisions, one of which allows anything.** `Decision { granted, notRecorded, denied, unreadable }`
  with `allowsEgress` true only for `granted`. Every non-granted state denies: no record, a record that
  says no, a corrupt record, a record that cannot be read at all, and a record granted for a *different*
  disclosure version (which reads as `notRecorded`, so the prompt re-appears under the new copy — OD3's hook).
- **The record**: `ConsentRecord { granted, recordedAt, disclosureVersion }` under
  `plugin.live_translate.consent.v1` through the shipped `EncryptedLocalStorage` (`StoragePlacementPolicy`
  puts this key on the encrypted file channel — one key, one whole-payload write, no sidecar).
- **One writer.** `record(granted:)` is the only API that writes the record. Both it and `revoke()`'s
  tombstone go through one private `persistDecision(granted:)`, which goes through one private `write(_:)`,
  which holds the file's single `storage.write(` call site. A source scan pins the only two call sites of
  `record(granted:` to `ConsentPromptController.swift` — the prompt and the revocation control.
- **AM-4, in four parts** — see the dedicated table below.
- **AM-7 proof.** `Grant { disclosureVersion }` with a `fileprivate init`: `authorize()` is its only
  producer, so a request builder that takes a `Grant` cannot be reached without the gate. `fileprivate`
  rather than `private` because `private` on a nested type's member scopes to that type alone and would
  make `authorize()` itself uncompilable; the claim ("no file outside the gate can mint one") is identical,
  and the test pins the initialiser's access level.
- **AM-1 cancellation seam.** `registerInFlight(cancel:) -> InFlightRegistration`; `revoke()` cancels every
  registration before it touches storage, and the registration's release is idempotent and `deinit`-released.
- **No operational literals**: every value (key, version, event names, error codes, timestamps) comes from
  `LiveTranslateConfig`, `LiveTranslateEvents` or the declared storage key. `LiveTranslateSourceHygieneTests`
  scans for redeclared defaults and passes.

### T-015 — the prompt, the revocation control, and their two surfaces

- `ios/ElderlyAssistant/Services/LiveTranslate/ConsentPromptController.swift` (236 lines). `cloudNeedDetected()`
  is the only entry point: `granted` → `authorize()` → `.proceed(Grant)`; `notRecorded` → present the prompt
  once → `.awaitingDecision`; `denied` → `.unavailable(.consentDenied)`; `unreadable` →
  `.unavailable(.consentRecordUnreadable)`. No request is in flight while the prompt is up, and there is no
  timeout, timer or auto-dismiss anywhere in the file. `grant()`, `decline()` and `revoke()` are the only
  things that write; each returns the gate's own `Result`, and a failure keeps the surface truthful rather
  than optimistically flipping it.
- `ios/ElderlyAssistant/Services/LiveTranslate/Views/ConsentView.swift` (244 lines). `ConsentPromptSurface`
  (title, message, two `ConsentAction`s, optional failure line, locale) and `ConsentControlSurface`
  (`.decision`, `.granted`, `.revocationIncomplete`) built from catalog keys in the active language. Both
  choices are built by **one** `actionButton(_:)` helper called exactly twice, both take
  `DesignTokens.minTapTargetSize`, and neither carries a style, role, shortcut or default that could mark
  one as the expected answer.
- `ios/ElderlyAssistant/Services/LiveTranslate/Views/LiveTranslateConsentSettingsView.swift` (43 lines) —
  the Settings leaf, driving the app's one controller so a decision made there is the decision in force
  over the session view.
- `AppCoordinator` builds **one** `LiveTranslateConsentGate` in `init` and hands out **one**
  `ConsentPromptController`; `SettingsView` gained a `liveTranslate` row that presents the leaf.

### T-016 — `CloudActivityIndicatorModel` (C10)

- `ios/ElderlyAssistant/Services/LiveTranslate/CloudActivityIndicatorModel.swift` (136 lines). A
  `@MainActor` observable whose only input is the in-flight counter: on at 0→1, off at 1→0, no dwell
  timer, no debounce, no configuration parameter, no settings/overlay/dictionary input, and
  `withRequestInFlight { }` releases on every exit path (success, throw, timeout, cancellation).
- `ios/ElderlyAssistant/Services/LiveTranslate/Views/CloudActivityIndicatorView.swift` (71 lines). A
  symbol plus a catalog-backed label in the active language; `if surface.isActive` is the only thing that
  decides whether it is drawn, and no input exists that could hide it while a request is in flight.
- Transitions emit `cloud_indicator_shown` / `cloud_indicator_hidden` with no metadata at all.

### Tests (all new, under `ios/ElderlyAssistantTests/Services/LiveTranslate/`)

| File | Lines | Tests |
|---|---|---|
| `LiveTranslateConsentGateTests.swift` | 613 | 29 |
| `ConsentPromptAndRevocationTests.swift` | 587 | 22 |
| `CloudActivityIndicatorTests.swift` | 351 | 15 |

## Shipped-file edits, with the reason each is additive (NFR-LCT-012)

Files already committed at `HEAD`:

1. **`ios/ElderlyAssistant/App/AppCoordinator.swift`** — two new properties (`liveTranslateConsentGate`,
   `consentController?`), built in `init` beside the storage they write through (construction is a lock
   and a closure — no I/O, nothing read until a decision is asked for), and two new read-only accessors
   (`liveTranslateConsentController()`, `liveTranslateConsentDecision`). The only deletions are three
   lines hoisted into a local `storage` (same object, same order). No shipped line changes behaviour.
2. **`ios/ElderlyAssistant/App/SettingsView.swift`** — one new `SettingsSection` case plus its `id`, one
   new `sectionRow` (after Alarms, before Privacy), one new destination case. The single deletion is the
   enum declaration line, extended in place: the shipped rows keep their order and their behaviour.
3. **`ios/ElderlyAssistant/Resources/Localizable.xcstrings`** — 6 new keys (`livetranslate.consent.failed`,
   `.grantedTitle`, `.grantedNote`, `.revokeFailedTitle`, `.revokeFailedNote`, `settings.livetranslate.title`),
   each with `en` + `ne`; the 959 keys present at `HEAD` are unchanged (verified by parsing both revisions
   and diffing the key sets: 25 added since `HEAD`, 19 of them TG-01–TG-04's, 6 mine).
4. **`ios/seniOS.xcodeproj/project.pbxproj`** — regenerated by `./build.sh generate` (XcodeGen), never
   hand-edited. It is generated output; §Environment findings explains why regenerating is mandatory.

Files created by this feature's earlier groups, so not yet shipped (these edits are additive too):

5. **`Services/LiveTranslate/LiveTranslateEvents.swift`** — one catalogue entry
   (`"consent_write_failed": outcomes ["failure"], metadataKeys []`), one parameterless emitter
   `consentWriteFailed()`, and a second `code(_:)` overload for the gate's `ConsentError`. No existing
   entry, emitter or overload changed.
6. **`ElderlyAssistantTests/.../LiveTranslateEventsTests.swift`** — one line in `driveEveryEmitter()`
   (the catalogue pin requires every emitter to be driven).
7. **`ElderlyAssistantTests/.../LiveTranslateCopyTests.swift`** — the 5 new feature keys added to
   `featureKeys`.
8. **`ElderlyAssistantTests/.../LabelTranslationCacheTestStorage.swift`** — `failsDeletes` and
   `keepsBytesAfterDelete`, plus the guards in `delete(key:)`. Both default to `false`, so every existing
   user of the double behaves exactly as before. Extending the shipped double was deliberate: a second
   storage seam would be a second thing to keep honest, and the double already models `failsReads` /
   `failsWrites` in this shape.

`ios/ElderlyAssistant/Info.plist`, `LogSanitiser.swift`, `InputSanitiser.swift`, the `Appliance/*` files
and `specs/design-component.md` show as modified in this worktree but were changed by **TG-01–TG-04**,
not by this task.

## Gherkin coverage — scenario to test

### T-014 `LiveTranslateConsentGate`

| Scenario | Tests |
|---|---|
| A grant for the current disclosure version allows the send | `testAGrantedRecordForTheCurrentDisclosureVersionAllowsEgress` |
| Every absence form denies, each with its own decision | `testAnAbsentRecordDeniesAsNotRecorded`, `testARecordThatSaysNoDeniesAsDenied`, `testACorruptRecordDeniesAsUnreadableAndNeverAsGranted` (`"not a record"`, `"{}"`, `{"granted":"yes"}`, `{"granted":true}`), `testAStoreThatCannotAnswerAtAllDeniesAsUnreadable`, `testTheFourDecisionsAreDistinguishableAndOnlyAGrantAllowsEgress` |
| A stale-version grant does not inherit | `testAGrantForADifferentDisclosureVersionDoesNotCarryOver`, `testGrantingUnderANewDisclosureVersionRecordsThatVersion` |
| No configuration or context implies consent | `testNoConfigurationValueReachesTheConsentDecision` (source scan: the gate reads exactly one config member, `disclosureVersion`), `testTheConfigTypeCarriesNoConsentSetting` |
| Withdrawal takes effect immediately, including between attempts | `testAWithdrawalBetweenTwoAttemptsDeniesTheRetry`, `testRevocationCancelsEveryRegisteredInFlightRequest`, `testRegistrationIsReleasedOnEveryExitAndCannotBeCancelledTwice` |
| A revocation whose write fails still denies | `testAWithdrawalThatCannotBeMadeToTakeEffectIsNeverSilent` (`.failure(.writeFailed)`, one `consent_write_failed` event, this session denies — and the test states plainly that a relaunch reads the surviving grant), `testARevocationWhoseDeleteLiesAndCannotBeReadIsReportedAsAFailure`, `testADeleteThatReportsSuccessAndKeepsTheRecordIsCaughtByTheReadBack`, `testARevocationWhoseDeleteFailsStillStopsTheNextAttempt`, `testARevocationDeniesInMemoryEvenWhenStorageCannotBeRead`, `testARelaunchCannotReadBackAGrantThatWasWithdrawn` |
| Recording a decision is explicit and minimal | `testTheStoredRecordCarriesExactlyThreeFieldsAndNoMore` (`Mirror` on the decoded record: `{granted, recordedAt, disclosureVersion}`; no text, no identifier), `testTheRecordIsWrittenUnderTheDeclaredKeyAndNowhereElse` |
| Every decision point is evidenced without content | `testEveryDecisionPointIsEvidencedWithContentFreeEvents` (every emitted type is in `LiveTranslateEventCatalogue`, metadata exactly `["disclosureVersion"]`, no `print(`), `testAWriteFailureIsEvidencedAsAFailureWithAStableCode`, `testACorruptRecordDeniesAsUnreadableAndNeverAsGranted` |
| DoD: the builder cannot be reached without the proof (AM-7) | `testAGrantCanOnlyBeMintedByTheGate` (one `Grant(disclosureVersion:` call site, inside the gate; the initialiser is `fileprivate`), `testTheGateIsTheOnlyThingThatCanAuthorizeOrDeny` (one `func authorize()`) |
| DoD: one writer, two sanctioned controls | `testTheConsentKeyIsDeclaredOnceAndOnlyTheGateWritesIt`, `testTheRecordIsWrittenOnlyByThePromptAndTheRevocationControl` |
| DoD: a model crash or hang cannot grant consent or bypass the gate | `testACrashOrHangOfTheTranslationModelCannotGrantConsentOrBypassTheGate` (no model/engine/encoder/session token in the gate's source; its whole state is store + events + clock + lock + a **deny-only** mirror; the decision is re-derived on every read; 100 refusals never drift towards a grant) |
| DoD: integration on the stubbed store, failure modes included | the six revocation/failure tests above, plus `testTheRecordSurvivesOnTheRealEncryptedChannelAndRevocationRemovesIt` (the real `EncryptedFileStorage` over a temp directory, three gate generations) |

### T-015 consent prompt and revocation

| Scenario | Tests |
|---|---|
| The prompt appears at the first cloud need, not at session open | `testADictionaryOnlySceneShowsNoPromptAndMakesNoRequest` (zero requests, no prompt, indicator off), `testThePromptAppearsAtTheFirstCloudNeedAndNoRequestStartsWhileItIsUp`, `testThePromptIsNeverPresentedWhenNothingHasAskedForTheCloud` (no session-open hook exists) |
| The prompt is a blocking decision with no timeout | `testThePromptStaysUntilTheElderChoosesNoMatterHowManyCloudNeedsArrive` (25 cloud needs, still presented, exactly one `consent_prompt_shown`), `testNoTimeoutParameterOrTimerExistsForThePrompt` (no timer/`asyncAfter`/`Task.sleep`/`deadline` in the prompt sources) |
| Granting records a decision and lets the send proceed | `testGrantingRecordsTheDecisionAndThePendingSendProceedsWithoutASecondPrompt` |
| Declining keeps the dictionary path intact | `testADeclineStopsEveryLaterSendUntilTheElderChangesTheDecision`, `testTheDictionaryAndTheCacheKeepAnsweringAfterADecline`, `testADeclinedRegionGetsTheHonestUnavailableIndication` (Nepali copy, no specific cause named) |
| The decline choice is presented with equal weight | `testGrantAndDeclineAreEquallyWeightedChoices` (`Mirror` children == 2 per action; one `actionButton(` builder called twice; two `minHeight: DesignTokens.minTapTargetSize`; no `borderedProminent`/`keyboardShortcut`/`buttonRole`/`destructive`/`isDefault`/`preferred`; no `.onAppear`/`.task`), `testBothChoicesRenderAtTheFullTapTargetHeight` (off-screen `ImageRenderer` + a scan of the accent `#BB1E4D` rows: exactly two full-height bands), `testNeitherChoiceCarriesGuiltOrPressureWording` (banned-word list in `en` and `ne`), `testTheExplanationIsAboutRecognizedTextAndNeverImages` |
| Revocation is reachable and immediate from both surfaces | `testARevocationDeletesTheRecordFlipsTheMirrorAndDeniesTheNextAttempt`, `testARevocationCancelsAnInFlightRequest`, `testTheFeatureContinuesWithTheDictionaryAndTheCacheAfterARevocation`, `testTheSettingsLeafDrivesTheAppsOneConsentController` |
| A decline or revocation is not re-asked in a loop | `testADeclineIsNotReAskedAutomaticallyInThatSession`, `testTheControlStillOffersTheDecisionSoTheElderCanChangeItDeliberately` |
| DoD: a failed grant/decline/revocation stays honest | `testAGrantThatCouldNotBeSavedKeepsThePromptAndSaysSo`, `testADeclineThatCouldNotBeSavedStillStopsTheSendAndSaysSo`, `testARevocationThatCouldNotBeSavedKeepsTheRetryWithinReach` |

### T-016 cloud-activity indicator

| Scenario | Tests |
|---|---|
| The indicator follows the in-flight counter exactly | `testTheIndicatorAppearsWhenTheFirstRequestBegins`, `testItStaysOnUntilTheLastRequestEnds` (shown once on 0→1, hidden once on 1→0) |
| Nothing else can turn the indicator on | `testTheStateIsNotSettableFromAnywhere` (`@Published private(set) var isActive`; exactly three assignments), `testNoSettingsOverlayOrDictionaryInputExists`, `testTheViewHasNoWayToSuppressItWhileActive` (no `hidden`/`isHidden`/`shouldShow`/`isEnabled`/`alwaysShowOriginal`; `if surface.isActive` is the only gate), `testTheIndicatorStaysOffWhenTheGateDeniesAndWhenTheCacheServes` |
| A very fast response flickers honestly | `testAFastResponseIsShownForExactlyItsOwnDurationAndNoLonger` (no `Timer`/`asyncAfter`/`Task.sleep`/`withTimeout`/`dwell` anywhere in the model or view) |
| Failures and cancellations still return it to off | `testAThrowingScopedRequestStillLeavesItOff`, `testATimeoutAndACancelledAttemptReturnItToOffThroughTheSameRelease` (a `URLError(.timedOut)` and a task cancelled from outside, both released through the same `defer`), `testASuccessfulScopedRequestLeavesItOff`, `testNestedScopedRequestsReleaseIndependently`, `testAnUnpairedEndCanNeitherTurnItOnNorUnderflow` |
| The indicator renders as a symbol plus a label | `testItCarriesASymbolAndALabelInTheActiveLanguage` (catalog-backed, differs by locale, Devanagari asserted; a symbol alone is not a statement an elder can read), `testTheInactiveIndicatorDrawsNothing` |
| Transitions are recorded without content | `testTheTransitionsCarryNoContentAtAll` (empty metadata, outcome `success`, no error code, and both emitters are parameterless) |

## Decisions made during implementation

1. **AM-4's four parts, and the design's "safe direction" is not implemented.**

   | Part | Where it lives | Tests |
   |---|---|---|
   | 1. Deny in memory before storage | `persistDecision` sets the deny mirror before the write; `revoke()` sets it before the delete | `testARevocationDeniesInMemoryEvenWhenStorageCannotBeRead`, `testARevocationWhoseDeleteLiesAndCannotBeReadIsReportedAsAFailure` |
   | 2. Verify the delete by reading back | `revoke()` deletes, then re-reads through `grantEvidence()`; the raw channel separates "nothing there" from "bytes that will not decode" | `testADeleteThatReportsSuccessAndKeepsTheRecordIsCaughtByTheReadBack` (the lying delete is caught and the tombstone is written), `testAWithdrawalBetweenTwoAttemptsDeniesTheRetry` |
   | 3. Surface a failure as a failure | `.failure(...)` is returned and `consent_write_failed` is emitted; an unverified withdrawal is never reported as done | `testAWithdrawalThatCannotBeMadeToTakeEffectIsNeverSilent`, `testARevocationWhoseDeleteLiesAndCannotBeReadIsReportedAsAFailure` |
   | 4. A relaunch cannot silently re-grant | the tombstone goes through the one writer and is re-verified; a stale, absent or unverifiable record denies on every read | `testARelaunchCannotReadBackAGrantThatWasWithdrawn`, `testTheRecordSurvivesOnTheRealEncryptedChannelAndRevocationRemovesIt`, `testACorruptRecordDeniesAsUnreadableAndNeverAsGranted` |

   The design's failure matrix (`specs/design-component.md`, row 9) still says a failed revoke "leaves the
   record intact, which is the safe direction: the gate is still gated". That sentence is wrong — with the
   record intact the gate is **open** — and it is not what this task implements.
   `specs/security-design-review.md` SD-1 already records the finding and states the required semantics,
   which T-014's implementation notes restate; the design text was **not** edited, because neither task
   spec asks for a wording correction and SD-1 is the binding correction. Reported as an open item.

2. **An unverifiable record is a failure, and the raw channel is what makes that checkable.** Through
   `EncryptedLocalStorage`, "absent" and "unreadable" are the same `read` failure. The gate therefore asks
   the shipped `RawEncryptedStorage` channel (which the real file store and the test double both conform
   to — the same channel `readStoredDecision()` already uses for this distinction) whether bytes exist:
   bytes that are there but will not decode cannot be shown to be gone, and such a record could read back
   as a grant on a later launch (the file-protection state of a locked device is exactly that shape), so
   that case is reported as a failure and a tombstone is attempted. No second storage seam was invented.

3. **The prompt's contract lives in `ConsentPromptController.cloudNeedDetected()`.** The zero-request and
   "nothing in flight while the prompt is up" evidence runs through a small harness (`CloudRequestPath`)
   modelling dictionary → cache → gate → send, because the real tier is T-019's. The test documents it as
   the contract T-019 must preserve; when T-019 lands, the harness should be replaced by the real tier.

4. **No timeout is a structural fact, not a promise.** Nothing in the prompt sources mentions a timer, a
   deadline or a sleep, and a source scan fails if one appears.

5. **Equal weight is asserted structurally and by rendering.** SwiftUI's accessibility tree is not readable
   from a unit-test host, so "equally reachable, no pre-selected default" is asserted as: identical action
   type with identical field count, one builder called twice, the same minimum tap height on both, no
   emphasis modifier anywhere in the file — plus an off-screen `ImageRenderer` measurement of the two
   accent bands.

6. **A new catalogue event, added additively.** A failed consent write needed to be visible as a failure:
   `consent_revoked` is design-pinned to `success` and re-meaning it would have changed a shipped
   contract, so `consent_write_failed` (outcome `failure`, no metadata) was added to
   `LiveTranslateEventCatalogue`. It is additive (no existing entry changed) and `LiveTranslateEventsTests`
   drives it like every other emitter.

7. **A failed revocation keeps the retry within reach.** Rather than leaving the control in its "granted"
   state (a lie) or in the plain decision state (which would re-present the grant as if nothing had
   happened), `ConsentControlSurface` gained a third state, `.revocationIncomplete`: the copy says the
   change could not be saved and that nothing is being sent now, and the revoke control stays reachable so
   the elder can try again.

8. **The in-memory mirror is deny-only and outranks storage.** It is set before a decline or a revocation
   is written and cleared only by a grant confirmed by a read-back. That is what makes a "no" effective in
   the same session even when storage is broken, and it is why a declined or revoked state is not re-asked
   in that session while a restart (a new process) is free to ask again.

## Verification performed

Command (the flags `ios/build.sh test:unit` uses, scoped to this task's suites and to the neighbouring
suites this task touched additively):

```
cd ios
./build.sh generate                       # XcodeGen — mandatory before testing new files
xcodebuild test \
  -project seniOS.xcodeproj -scheme ElderlyAssistant \
  -destination "platform=iOS Simulator,id=990E1710-4805-46E2-8FED-BD1DE12D1BE8" \
  -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests \
  -only-testing:ElderlyAssistantTests/LiveTranslateConsentGateTests \
  -only-testing:ElderlyAssistantTests/ConsentPromptAndRevocationTests \
  -only-testing:ElderlyAssistantTests/CloudActivityIndicatorTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateEventsTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateCopyTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateSourceHygieneTests \
  -only-testing:ElderlyAssistantTests/LabelTranslationCacheTests \
  -only-testing:ElderlyAssistantTests/LiveTranslateAllowListTests \
  -resultBundlePath build/TG05-gate.xcresult
```

Result: **`** TEST SUCCEEDED **`, exit code 0**, and
`xcrun xcresulttool get test-results summary --path build/TG05-gate.xcresult` →
`result: Passed · total: 144 · passed: 144 · failed: 0 · skipped: 0`, on iPhone 17 (iOS 26.5, x86_64),
`ElderlyAssistant · Built with macOS 26.6.2`.

Per-suite (from the same result bundle): `LiveTranslateConsentGateTests` **29/29**,
`ConsentPromptAndRevocationTests` **22/22**, `CloudActivityIndicatorTests` **15/15** — **66 new tests, all
passing** — plus the neighbouring suites this task extended: `LabelTranslationCacheTests` 21,
`LiveTranslateAllowListTests` 24, `LiveTranslateEventsTests` 17, `LiveTranslateCopyTests` 10,
`LiveTranslateSourceHygieneTests` 6.

`./build.sh build` (the DoD's build check, T-014 and T-016): **`** BUILD SUCCEEDED **`, exit code 0**, zero
compiler errors**. This was re-run after the last source change, so it reflects the delivered code.

The scoped gate was run four times while the failures below were found and fixed; the run reported here is
the final one, after the last source edit. Failures found and fixed during that loop, all of them real
defects rather than test noise:

- a `private init` on the nested `Grant` was not reachable from `authorize()` (Swift scopes `private` to
  the nested type) → `fileprivate`, which is the intended claim anyway;
- `code(.consentWriteFailed)` named a `ConsentError` case that does not exist (`writeFailed`) and could not
  be resolved against the two `code(_:)` overloads → the explicit type;
- `Result<Void, E>` is not `Equatable` (the shipped `ResultVoidAssertions` says so) → `isSuccess` /
  `failureError`;
- three tests scanned feature sources by a hard-coded path and missed the `Views/` subdirectory, and
  `FeatureSourceScan` fails loudly on an unreadable file → the helper now finds a file by name anywhere
  under the feature directory and fails if it matches nothing;
- the revocation's verification treated "the store cannot answer" as "no grant survived", which would
  report an unverifiable withdrawal as done → `grantEvidence()` now distinguishes absent from unreadable
  through the raw channel (decision 2 above), which is the change that makes AM-4 part 2 a real check.

## Environment findings

1. **XcodeGen must be re-run before testing new files — and a missing file fails silently.** This project
   is generated from `ios/project.yml`. A raw `xcodebuild test -only-testing:…/<NewSuite>` whose class is
   not in the generated project does not error: it **runs nothing and reports success**. The first scoped
   run of this task reported `** TEST SUCCEEDED **` with 78 tests while all 66 new tests had never
   executed, because the three new test files were absent from `seniOS.xcodeproj` (created after the last
   generation). `./build.sh generate` fixed it (each file now appears four times in the pbxproj). Any
   green run that names a class the project does not contain is worthless — check the per-suite counts in
   the result bundle, not just the exit code.
2. The unit baseline in this checkout is genuinely red (≈21 pre-existing failures in unrelated suites,
   e.g. the voice-turn timing suites), which is why verification is scoped rather than a full
   `./build.sh test:unit`.
3. The simulator must be pinned (`id=990E1710-4805-46E2-8FED-BD1DE12D1BE8`); the run above was on
   iPhone 17 / iOS 26.5 / x86_64 with Xcode 26.6 and XcodeGen 2.46.0.
4. `Result<Void, E>` is not `Equatable`; use the shipped `ResultVoidAssertions` (`isSuccess`,
   `failureError`).
5. `private` on a member of a *nested* type does not reach the enclosing type; `fileprivate` is the right
   access level for a proof type whose producer is the enclosing type.
6. SwiftUI's accessibility tree cannot be read from a unit-test host — `ImageRenderer` plus pixel
   measurement is the substitute used for the equal-weight claim.

## Open items (reported, not silently closed)

1. **T-018's call-site binding.** The `Grant` proof exists and can only be minted by `authorize()`, but
   nothing yet *requires* a `Grant` — the request builder that takes one is T-018's. Until it lands, AM-7's
   guarantee is "the proof cannot be forged or come from anywhere else", not yet "a request cannot be built
   without it". The test comment says so explicitly.
2. **The residual failed-write risk.** If every write path is broken, this session denies, the elder is
   told, and the failure is evidenced — but the surviving grant would still be read by a relaunch. That is
   stated in `testAWithdrawalThatCannotBeMadeToTakeEffectIsNeverSilent` rather than papered over. A
   stronger remedy (retrying or queueing the revocation until storage recovers) is out of this task's
   scope.
3. **`consent_write_failed` is a new event type.** It is additive and catalogue-pinned, but `security-test`
   (T-029) and the observation allow-list should confirm it is the intended evidence for this case.
4. **The copy is a draft.** The 6 new keys (`livetranslate.consent.failed`, `.grantedTitle`, `.grantedNote`,
   `.revokeFailedTitle`, `.revokeFailedNote`, `settings.livetranslate.title`), `en` + `ne`, ride the draft
   disclosure version (`LiveTranslateConfig.disclosureVersion` ends `.draft.16sep2026.r1`, pinned by
   `testTheDisclosureVersionIdentifiesThisCopyRevision`). No separate draft marker exists in the catalog
   for any key; the OD3 review at `final-sign-off` covers them.
5. **Equal-weight accessibility is asserted structurally and by rendering, not by VoiceOver.** A
   VoiceOver-level check (both buttons reachable, identical traits, no default) needs the UI-test target
   and is not done here.
6. **No session-view prompt presentation yet.** `ConsentPromptController` and the Settings leaf drive the
   app's single gate; the session view that presents the prompt over the camera is T-021's, and
   `AppCoordinator.liveTranslateConsentController()` is the seam it will use. Until then the prompt has no
   on-screen home in the app itself.
7. **The design's wrong sentence remains in `specs/design-component.md`** (failure matrix row 9, "the safe
   direction"). SD-1 supersedes it and this task implements SD-1's semantics; no design edit was made
   because neither task spec asks for one.
8. **The `CloudRequestPath` harness is a contract placeholder.** It must be replaced by T-019's real tier,
   at which point its tests should be re-pointed rather than kept as a parallel model.
