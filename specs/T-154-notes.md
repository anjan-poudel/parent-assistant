# T-154 — SystemContactPhotoWriter: implementation notes

Unit: `TG-31/T-154-system-contact-photo-writer`
Feature: `family-contacts-unify` · Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`)
Commit: the T-154 unit commit on `feat/family-contacts-unify` carrying this notes file plus the new source file, the new test suite and the regenerated `seniOS.xcodeproj/project.pbxproj` (not pushed).
Date: 2026-10-12 · **Speed mode** (parent directive): implement + whole-module typecheck + commit only — the scoped suite run and per-unit review are deferred to the phase-end gate.

## What was built

### 1. `ios/ElderlyAssistant/Services/Contacts/SystemContactPhotoWriter.swift` (new, 481 lines)

Exactly the design's shape (design-l1 §9.2, design-l2 §1.4/§1.5/§5.2/§6.2; FR-FCU-008, FR-FCU-010, NFR-FCU-002):

- `enum SystemContactWriteAccess: Equatable { notDetermined, denied, limited, full }` with
  `static func from(_ access: ContactsAccess)` — the SINGLE-GATE mapping (`.allowed → .full`,
  `.limited → .limited`); no second availability gate anywhere in the file (the module-wide
  single-`#available(iOS 18` pin in `ContactsAccessTests` stays the one gate). Additive
  `allowsWriting` (`full`/`limited`) and `logToken` (`not_determined`/`denied`/`limited`/`full`).
- `enum SystemContactWriteFailure: String, Equatable` — raw values ARE the log reason codes
  (`fetch_failed`, `not_in_granted_selection`, `save_rejected`, `read_back_mismatch`).
- `enum SystemContactPhotoWriteOutcome: Equatable` — the six outcomes plus `logToken`,
  `failureReasonCode` (the raw value only on `.failed`) and `metadata` (the `state` token only
  for `.skippedNoAuthorization`) — the §5.2 row's three columns as values.
- `enum PhotoWriteField: Hashable { case photo }`; `struct PhotoWriteIntent: Equatable
  { identifier, numberKey, fields, imageBytesHash }` with `isPhotoConfined`; `enum PhotoReadBack
  { bytes(Data?), unverifiable }`.
- `protocol SystemContactPhotoWriting: AnyObject { writeAccess(), writePhoto(_:to:), clearPhoto(from:) }`.
- `actor SystemContactPhotoWriter: SystemContactPhotoWriting` —
  `init(store: CNContactStore = CNContactStore(), observabilityBus: ObservabilityBus? = nil)`.
  `writeAccess()` reads `CNContactStore.authorizationStatus` through the one mapping and NEVER
  prompts. `writePhoto`/`clearPhoto` both enter one shared `perform(assigning: Data?, to:)`
  (a clear is the same §1.4 sequence with `nil`), which implements the exact attempt order:
  access gate → fetch by identifier with keys `[identifier, phoneNumbers, imageData,
  imageDataAvailable]` (throw + `.limited` → `notInGrantedSelection`; throw otherwise →
  `fetch_failed`; empty + `.limited` → `notInGrantedSelection`; empty otherwise → `recordGone`)
  → fingerprint re-check AT ATTEMPT TIME (`MissedCallContactResolver.matches`; mismatch returns
  BEFORE any request exists) → `PhotoWriteIntent` + `assert(isPhotoConfined)` → checked
  `contact.mutableCopy() as? CNMutableContact` (failure → `saveRejected`) → `mutable.imageData =
  jpeg` (the ONLY assignment on the mutable contact) → `CNSaveRequest()` + `request.update(mutable)`
  + `try store.execute(request)` in do/catch (failure → `saveRejected`) → read-back re-fetch of
  `CNContactImageDataKey` with byte equality (anything else → `readBackMismatch`) → `written`.
  One `ObservabilityBus` event per exit (`contacts_photo`/`write`, `outcome` = log token,
  `error_code` = raw failure code, `state` metadata on skipped-no-authorization, `duration_ms`).
  No console writes, no `try!`, no force casts, no retries/backoff/timeouts.
- `enum FamilyPhotoEditorState: Equatable { updatedInSystem, keptOnPhone,
  keptOnPhoneAccessDenied, systemPhotoRemains }` with `static func from(_:) -> Self?` — an
  exhaustive switch with NO `default` over both the outcome and the failure enum (a new case
  breaks the build). The §1.5 rows, row for row; `.skippedNoLink → nil` is the only silent case.

Recorded implementation decisions (all internal — no pinned interface changed):

1. **`SystemContactWriteDecision` — a pure decision seam inside the file.** The no-attempt gate,
   the fetch-throw/empty classification, the fingerprint rule, the intent construction and the
   read-back equality are `static func`s the actor calls and nothing else. Rationale: the real
   store write cannot be driven from tests (`CNContactStore` not fakeable; security review
   §5/F1), so the behaviours the Gherkin scenarios name must live in code a test can actually
   exercise — the same "thin glue over pure seams" layering `AddressBookDirectory.swift` states.
   No API surface is added outside the file.
2. **`PhotoReadBack.unverifiable`** distinguishes "read back and it is nil" (a successful clear)
   from "the re-fetch failed / found no record". Without it, a failed re-fetch after a clear
   would read as `nil == nil` → a FALSE `.written`. `.unverifiable` is never success
   (`readBackVerified` returns false), which is what "never a false success" requires.
3. **`preAttemptOutcome(hasVerifiedLink:access:)` takes the link's presence explicitly.** The
   actor always passes `true` (its protocol requires a link); the parameter exists so
   `.skippedNoLink` — missing from the §1.5 outcome table's producer list, and produced by the
   caller in the design's prose — has one testable production decision site. T-158's
   `syncSystemPhoto` ("nil = no such contact; `.skippedNoLink` = no verified link") is the other
   consumer of the same function.
4. **`.failed(.fetchFailed) → .keptOnPhone`** is enumerated explicitly in `from(_:)`. The §1.5
   table lists the other three failure rows but not this one; the task's totality criterion
   ("each `SystemContactWriteFailure` raw value") requires a row, and the table's own rule fixes
   its value (the write did not land → the photo stays on the phone). Both the `from` switch and
   `readBackVerified`/`preAttemptOutcome` stay default-free.
5. **`imageBytesHash` is `""` for a clear.** design-l1 §9.4 declares the field on the recorded
   intent; a clear assigns `nil`, so there is no payload to hash — the empty string states that
   rather than hashing nothing into a real-looking digest.
6. **`.systemPhotoRemains` is documented as caller-owned.** `from(_:)` never returns it (a write
   outcome alone cannot distinguish a write from a clear); design-l2 §2.6 sets it in the REMOVE
   path after a clear returns `.written` and the display precedence still finds a system photo.
   A test pins that `from` never claims it.

### 2. `ios/ElderlyAssistantTests/Services/Contacts/SystemContactPhotoWriterTests.swift` (new, 37 tests)

| Task Gherkin / requirement | Test(s) |
|---|---|
| Access mapping is the single gate (no second iOS-18 check) | `testWriteAccessMappingIsExhaustive`, `testAllowsWritingIsFullAndLimitedOnly`, `testAccessLogTokensAreTheClosedStateVocabulary` |
| No-attempt matrix (§1.4 gate; unlinked / denied) | `testNoVerifiedLinkSkipsForEveryAccess` (×4 accesses), `testDeniedAndNotDeterminedSkipWithTheirOwnAccessPayload`, `testFullAndLimitedAccessProceedToTheAttempt`, `testThePreAttemptGateAgreesWithAllowsWriting` |
| Fetch classification (throw/empty × limited/full) | `testFetchFailureClassification`, `testEmptyFetchClassification` |
| Fingerprint precondition — no write on mismatch | `testFingerprintPreconditionUsesTheSharedTrailingDigitRule` (reformatted same number holds; different/empty/unusable do not), `testFingerprintNeverHoldsForAnEmptyNumberKey`, plus the source-order pin in `testTheAttemptSequenceIsFetchFingerprintIntentSaveReadBackWrite` (mismatch returns before the mutable copy and before `CNSaveRequest()`) |
| Read-back byte-equality pinned (never a false success) | `testReadBackVerificationMatrix`, `testUnverifiableReadBackIsNeverSuccess`, and `testTheSaveBlockCatchesExecuteFailuresAndTheSuccessIsGatedOnReadBack` |
| Intent confinement `[.photo]` | `testIntentIsPhotoFieldOnly`, `testClearIntentIsPhotoFieldOnlyWithNoPayloadHash`, `testImageBytesHashIsAStableSha256Prefix`, `testPhotoWriteIntentCarriesNoBytes` (Mirror: no `Data` member), plus the every-record assertion in the fake tests |
| Total outcome→state mapping (no default) | `testFromMapsEveryOutcomeRowOfTheTable`, `testEveryFailureRawValueMapsToAKeptState`, `testSystemPhotoRemainsIsNotProducedByTheOutcomeMapping` |
| §5.2 closed vocabulary, reason codes, metadata | `testOutcomeLogTokensAreTheClosedVocabulary`, `testFailureReasonCodesAreTheRawValuesAndOnlyOnFailed`, `testMetadataIsStateOnlyForSkippedNoAuthorization`, `testTheWriterEmitsTheClosedContactsPhotoWriteEvent` (source pin of the one emit site) |
| Fake double (design-l1 §9.4) | `testFakeReportsScriptedAccessAndCountsRequests`, `testFakeRecordsNoIntentForNoAttemptOutcomes`, `testFakeRecordsNoIntentBeforeTheRequestIsBuilt`, `testFakeRecordsPhotoOnlyIntentForAttemptedOutcomes`, `testFakeClearRecordsTheClearedLinkWithAnEmptyHash`, `testFakeRequestIsBuiltClassification` |
| **F1** source-level single-property assertion | `testOnlyImageDataIsAssignedOnTheMutableContact` (binding derived from the `mutableCopy() as? CNMutableContact` guard; every assignment on it must be `imageData`; exactly one assignment site — write and clear share the parameterised path; no `as!`/`try!`) |
| **F1** update-only request | `testTheSaveRequestIsUpdateOnly` (one `CNSaveRequest()`, the only call on it is `update(_:)`, no `add`/`delete`/`addMember`/`removeMember`) |
| §1.4 attempt order + do/catch containment | `testTheAttemptSequenceIsFetchFingerprintIntentSaveReadBackWrite` (ten ordered source markers), `testTheSaveBlockCatchesExecuteFailuresAndTheSuccessIsGatedOnReadBack` |
| §5.2 no console writes (T-155 re-checks from outside) | `testTheWriterSourceCarriesNoConsoleWriteOrForceUnwrap` |
| **Confinement scan** (§6.2 layer 1 / §6.4) | `testCNSaveRequestAndCNMutableContactLiveOnlyInTheWriterFile` (module-wide `FeatureSourceScan` sweep: exactly one file; non-vacuous — both tokens present in the writer), `testCNContactStoreConstructionsStayInTheAllowedFiles` (writer + `AddressBookDirectory.swift` only) |

`FakeSystemContactPhotoWriter` (top-level in the suite file, per design-l1 §9.4) is the shared
scripted double: scripted `access`/`outcome`, recorded `intents` (one per outcome that happens
AFTER the request was built — `requestIsBuilt(for:)` is an exhaustive, default-free switch),
recorded `writes`/`clearedLinks` and an access-request counter. The coordinator suites (T-158)
inject it through `SystemContactPhotoWriting`.

### 3. Deliberately NOT done (other units own these)

- No coordinator wiring — `syncSystemPhoto`, `setFamilyContactLink`, `refreshVerifiedLinks`
  are T-156/T-158.
- No `FEATURE_ROOTS` registration of this file in the release log-safety gate — T-155 (the file
  is already console-write-free and the confinement pin it consumes lives here).
- No UI rendering of `FamilyPhotoEditorState` / the `family.photo.*` labels — T-159/T-160.

## Gate results

- **Whole-module typecheck**: `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme
  ElderlyAssistant -destination "platform=iOS Simulator,id=0D2CED77-002C-4081-A4C7-6A0A97E60F18"
  -derivedDataPath build/DerivedDataTests` (Debug, simulator, warm DerivedData) —
  **`** TEST BUILD SUCCEEDED **`, 0 errors; this unit's files compile warning-free.** The build
  log replays pre-existing Swift-6 migration / try-no-throw warnings from unrelated test suites
  (`TranslateTestModelTests`, `HomeWidgetTestSupport`, `LocalBrainTranslationTierTests`,
  `SpotifyAccountSessionTests`, `CommandRouterCorrectionRerouteTests`) whose object files were
  not rebuilt in the run — none mention this unit's files. Verified non-vacuous after the fact:
  both object files were produced in this run (08:02/08:03, re-verified 08:09 after the
  final test edit), both `SwiftFileList`s carry the new files, and the app's
  `ElderlyAssistant.debug.dylib` contains the new symbols and the new string
  literals (`contacts_photo`, `not_in_granted_selection`, `read_back_mismatch`).
- `seniOS.xcodeproj` was regenerated (`xcodegen generate`) so both new files are in their
  targets. The committed pbxproj carries 16 added lines: the 8 for this unit's two files plus
  the 8 for the concurrently-added `SystemContactLinkService.swift` /
  `SystemContactLinkServiceTests.swift` references (another agent's in-flight unit in this
  shared worktree). As with T-151's notes, the GENERATED file is committed in its consistent
  current state so the project stays buildable for everyone — those 8 lines are project-file
  references only, no part of this unit's source.
- **Scoped suite DEFERRED** per the speed-mode directive — the tests exist and compile;
  `./build.sh test:unit SystemContactPhotoWriterTests` is a phase-end gate item. The F1/F2
  scan logic was additionally dry-run outside the suite against the production source (mirroring
  the test's exact patterns over comment-stripped text): assignment sites on the mutable contact
  = `["imageData"]` (exactly one), request calls = `["update"]` only, all ten §1.4 order markers
  found in order, mismatch return precedes both the mutable copy and the request, and the save
  block contains update + execute + catch + `save_rejected`.
- Coverage: not measured in this mode; the suite exercises every branch of the pure decision
  core (both gate arms × 4 accesses, both fetch arms × 4 accesses, the fingerprint matrix, the
  read-back matrix incl. `unverifiable`, the intent for write and clear, the full §1.5 table)
  plus the source-level pins above.

## Handoff / open items

1. **T-155** registers `Services/Contacts/SystemContactPhotoWriter.swift` in the release gate's
   `FEATURE_ROOTS`; the source-level confinement evidence it consumes is
   `testCNSaveRequestAndCNMutableContactLiveOnlyInTheWriterFile` + the F1 assertions in this
   suite (both use `FeatureSourceScan`).
2. **T-158** injects `FakeSystemContactPhotoWriter` (defined here) and uses
   `SystemContactWriteDecision.preAttemptOutcome(hasVerifiedLink:access:)` for the
   `syncSystemPhoto` pre-flight; it must invalidate the photo cache on `.written` and refresh
   links on `.recordGone`/`.identityMismatch` (design-l2 §4.4).
3. **T-160** renders `FamilyPhotoEditorState` labels and owns the `.systemPhotoRemains` remove
   path (design-l2 §2.6); F4's design-doc comment alignment is T-165.
4. Phase-end gate items: run `SystemContactPhotoWriterTests` (scoped) and per-unit review; F7
   re-verified here (reason codes are fixed strings — no PII can reach the event fields).

## Files changed

```
ios/ElderlyAssistant/Services/Contacts/SystemContactPhotoWriter.swift                (NEW, 481 lines)
ios/ElderlyAssistantTests/Services/Contacts/SystemContactPhotoWriterTests.swift      (NEW, 819 lines, 37 tests)
ios/seniOS.xcodeproj/project.pbxproj                                                (regenerated — +16 lines: this unit's 2 files + the concurrently added T-149 file refs)
specs/T-154-notes.md                                                                 (this file)
```
