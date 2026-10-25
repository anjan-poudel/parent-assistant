# review-l2 — reminders-instructions-enhancements — iteration 3

| Field | Value |
|---|---|
| Task | review-l2 |
| Workflow | reminders-instructions-enhancements |
| Iteration | 3 (final review after two bounded reworks) |
| Artifact under review | `specs/design-l2.md` (2,208 lines) |
| Worktree | `elderly-ai-assistant-reminders-instructions-enhancements` |
| Requirements lock | `specs/define-requirements.lock.yaml`: 35 RIE requirements (25 FR + 10 NFR), zero per-file SHA-256 mismatches; snapshot `a02b9d4ee24a305ae396cf762304f1a13816f7bc1e81242e9f2adbaf0111bfb9` matches `specs/define-requirements.md`; counts 25 / 10 / 107 |
| Prior reviews | `review-l2` iteration 1 (NO_GO), iteration 2 (NO_GO) |
| Review mode | Read-only. Design text and source anchors were read; no build, test run, or workflow execution was performed. |
| Decision | NO_GO |

## Summary

The iteration-2 correction pass is real. N-2 through N-10 are closed in the body with anchors and named tests; B-1, B-2, M-1, M-2, m-1 and m-2 remain intact; m-3 is accepted and m-4 is verified. N-1's original blocker — a shipped `Info.plist` that was never amended — is now designed: exact English camera and microphone text, both `InfoPlist.strings` files, their `project.yml` registration and `L10nCatalogCoverageTests` pins are present, and the existing disclosures are retained.

The full L1-fidelity and safety re-check found three new issues that the prior reviews did not catch:

1. **B-3 (blocker).** The design copies the picked video with `copyItem` and sets complete protection only afterwards. L1 D18 and the resolved review-l1 finding m-5 explicitly require the destination file to exist with complete protection **before any bytes**, and reject exactly this copy-then-set window. The design's claims that protection is "created" and that "creation is the guarantee" are false for the staged file. A crash, kill or lock between the copy and the attribute set can leave a weaker-class instruction video in Application Support; the fail-closed verification has not run at that point, and a missing protection attribute is tolerated.
2. **M-3 (major).** The new "bundle-level" assertion cannot detect a missing `project.yml` `InfoPlist.strings` registration. The base plist already contains both amended keys, and the tests are app-hosted, so `Bundle.main.object(forInfoDictionaryKey:)` returns the non-empty English plist value even when neither strings file shipped. The source-file parses pass because the files exist on disk. The design's claim that a missing registration fails is false, so the localisation half of N-1 is not actually evidenced.
3. **M-4 (major).** `RoutineScheduler.entriesIfReadable() -> [RoutineEntry]?` has no implementable backing. `RoutineStore.loadEntries()` returns `[]` on every read failure, `RoutineStore.storage` is private, and `RoutineStore.swift` is not in C11's file list. `RoutineScheduler` cannot tell an unreadable store from an empty one, so the nil-means-unknown orphan-sweep safety — the mitigation for the design's own "worst failure" — cannot be built as written, and the §11.3 K unreadable-store test has no seam.

These are correction-pass issues, not an architecture problem: B-3 is a write-path correction, M-3 is a test-evidence correction, and M-4 is a small store seam. The component set, scope boundary and user-visible design remain sound. No scope creep was found. All 35 locked requirements are named in §11.2; the only traceability statuses that are not clean are the two tied to B-3 and M-3.

## Findings

### Iteration-1 and iteration-2 findings — resolution status

| Finding | Status | Evidence / residual |
|---|---|---|
| B-1 optional-entry tap and deleted-owner notice | Resolved | `onInstructionTap(entryId:entry:firedAt:)` is in §2.14.3 and IF-31/IF-32; a nil entry maps to `FiredRoutineVisualAids.Content.unavailable` (§2.15.3–4, §4.11); `.unavailable` renders the shared screen with `aids: []`, title `instruction.reminderUnavailable`, an `EmptyView` footer and Close, with no title or time claimed (§2.15.4, §10.3); copy row 35, test B.3 and smoke step 7 are present. Photo-only and pre-upgrade no-ops remain (P-13). |
| B-2 persisted `"text"` kind and visible labels | Resolved | `InstructionKind.text` with raw value `"text"` is used in §3.4, §4.1, F-3, `reportable`, observability and `instruction.kind.text`; §10.1 now reads `Text / Photo / Video`, matching §10.5 rows 5–7 and §1.7. No `case note`, `kind.note` or raw `"note"` remains. |
| M-1 camera-before-microphone order | Resolved | §2.4.3 and §2.5.3 specify camera first, microphone second when both are undetermined, short-circuit on denial, and the recorder only after both grants; §11.3 R records the order, both denial short-circuits, the already-denied/restricted no-re-prompt rule and camera-unavailable without a microphone request; `InstructionPermissionTests` is named. |
| M-2 FR-RIE-024 / 021 / 022 evidence | Resolved | FR-RIE-024 is credited to `InstructionDisplayStateTests`, `InstructionImageLoadingTests` and the `InstructionSurfaceTests` source scan, with `instruction.foregroundNote` rows 35–36. FR-RIE-021 is credited to `NotificationCategoriesTests`, `RoutineSchedulerTests` (scoped cancel) and `RoutineNotificationSchedulerTests`. FR-RIE-022 is credited to `RoutineNotificationSchedulerTests` with schedule, re-arm and event-path attachment assertions. Each claim is falsifiable by a named suite. |
| m-1 single service read | Resolved | `FreeFormEventService.event(withId:)` (`FreeFormEventService.swift:318`) is the only service read; the coordinator wrapper delegates. §2.13, §3.6, §4.8 and §5.9 name it. |
| m-2 labelled store Bool exception | Resolved | `EventExtrasStore.setInstruction -> Bool` is labelled in IF-26 and OI-1 as the deliberate store exception, translated to `InstructionWriteError.persistenceFailed` at the service seam; no view sees the Bool. |
| m-3 copy-family renames | Accepted | The renames are not behaviour-bearing; the two behaviour-bearing keys `instruction.reminderUnavailable` and `instruction.foregroundNote` are restored as rows 35–36 with en and ne values. |
| m-4 load-bearing source anchors | Verified | `EventExtrasStore.setPhotoFilename` is at `:110–113`; `RoutineScheduler(` is at `AppCoordinator.swift:3571`; the routine overlay is at `ContentView.swift:65–72` (the design cites 65–73, a harmless range); userInfo is at `RoutineAlarmScheduler.swift:75–79`; the existing print is at `:103` inside `:101–105`; `LocaleFormatters.shortTime(locale:)` is at `ViewCaches.swift:51`; the service read is at `FreeFormEventService.swift:318`; `VisualAidStore.isPlainFilename` is at `:243–249`; the store's protected write is at `:123`. |
| N-1 FR-RIE-025 plist amendment and disclosure | Partially resolved | The original blocker is closed by design: §10.6 contains the exact amended English camera and microphone text (retaining every existing disclosure and adding the video and on-device clauses), §2.0 C05 lists the shipped plist, both `InfoPlist.strings` files and the two `project.yml` resource entries, and §11.2/§11.3 N name `L10nCatalogCoverageTests`. The residual is the false built-bundle registration assertion; see M-3. |
| N-2 "Note" residue | Resolved | §10.1 reads `Kind picker (Text / Photo / Video)`; §10.5 rows 5–7 agree; no "Note" label survives. |
| N-3 invalid `InstructionPayload` enum | Resolved | §3.4 declares `struct InstructionPayload: Equatable` with stored `let` fields, a memberwise init and the computed `instruction`; no `enum InstructionPayload` remains. §4.2's payload table and §11.2's model tests match the struct. |
| N-4 incomplete filename guard | Resolved | §3.4 and §3.5 define `isPlain` as non-empty, not single-dot, not double-dot, and free of both separators. The guard runs before any name-derived URL in `availability`, `fileURL`, `delete`, both image loaders and as a commit invariant (§3.5, §4.7 F-11). F-11, §11.3 D and the two named suites cover empty, single-dot and double-dot refusal. |
| N-5 dropped fire-time line | Resolved | §4.10 is the authoritative D6 statement: `timeText` is non-nil only when `instruction?.isPresent == true || expectsInstruction`; `.unavailable` carries no `firedAt`; a photo-only foreground firing passes `nil`, renders the `.none` card and an `EmptyView` footer (§2.15.4, §4.11, §10.3, §11.3 B/M). |
| N-6 phantom suite citation | Resolved | §8.3 cites `RoutineNotificationSchedulerTests`; `RoutineNotificationContentTests` is gone. The §2.0 naming note correctly records that `RoutineAlarmSchedulerTests` is also a phantom and that the real alarm suite is `AlarmSchedulerTests`. |
| N-7 missing files in C01/C05/C08/P-14 | Resolved | C01 lists `Services/Instructions/InstructionImageLoading.swift` and its three types; C05 lists the plist, both `InfoPlist.strings` files and the `project.yml` entries; C08 names the loader it reads; P-14 is reworded to "no new file beyond those tabled in §2.0". |
| N-8 unrecorded L1 shape changes | Resolved | R-8 through R-13 record the six differences (display state, permission protocol, importer discard, event-handler composite read, playback close/pause, C17 extraction) and argue mechanical equivalence. The protection deviation is not among them; that is B-3. |
| N-9 FR-RIE-015 / NFR-RIE-009 evidence | Resolved | `RoutineVisualAidFireHandlerTests` and `RoutineNotificationSchedulerTests` name FR-RIE-015; `InstructionPlaybackControllerTests` adds the `finished` outcome; §11.3 I pins Close as pause-then-release and the `.closed` event. |
| N-10 duplicate fake and tooLong copy | Resolved | One `FakeInstructionVideoRecorder` row remains (§11.4); the `instruction.video.tooLong` copy says "3 minutes or shorter" in English and "३ मिनेटसम्मको" in Nepali, matching the inclusive 180-second cap; §5.2 step 3 and §6.7 agree. |

**Earlier fixes intact:** B-1, B-2, M-1, M-2, m-1, m-2 are all present and were re-checked against the body; no regression was found. m-3 is accepted; m-4's anchors were re-read in the source.

### New findings

#### B-3 — Blocker: the staged video is copied before it is protected, reversing L1 D18 and review-l1 m-5

**Anchor.** `specs/design-l2.md` §5.2 steps 5–6 (`:1443–1444`), the step-order paragraph (`:1447`), §5.3 "Creation" bullet (`:1453`), P-10 (`:31`) and R-4 (`:2172`). L1 D18 (`specs/design-l1.md:84`), L1's storage rule (`specs/design-l1.md:338–346`) and review-l1 m-5 (`specs/review-l1.md:73`).

**Problem.** L2's staging order is: create `_pending/<draftId>/` with complete protection, `copyItem` the picker's source into `payload.<ext>`, then `setAttributes([.protectionKey: .complete])` on the copy and verify. The design itself explains that `copyItem` inherits the source's class and that picker temp files are often `.completeUntilFirstUserAuthentication` (`:1447`). Yet §5.3 calls this "creation" and says "creation is the guarantee", P-10 says protection "is created" with `.completeFileProtection`, and R-4 says it is "requested at creation and re-asserted after the copy". Those statements are false for the staged file: the file is created by the copy at the source's class, and the complete class is set only afterwards. L1 D18 and m-5 are explicit: the destination file is created with complete protection **before any bytes**, filled by a bounded chunked stream, and there is no copy-then-set window. L1's rationale names this exact failure mode: "no staging window with a weaker Data Protection class, unlike a post-copy attribute set."

**Why this blocks.** A process kill, crash, power loss or device lock between steps 5 and 6 leaves an instruction video in Application Support at a weaker class. The store's fail-closed verification has not run, and §5.3 deliberately tolerates a missing protection attribute, so this state is invisible to the detector. The pending-draft sweep removes such files only at the next launch and only after the grace window. That violates NFR-RIE-005 and FR-RIE-011 on the feature's most sensitive artifact, reverses a locked L1 decision and a resolved review-l1 finding, and is not recorded in §1.3 (R-8 through R-13 do not include it). The current test plan cannot catch it: §11.3 E's source pin only finds the protection string in the region, and the `InstructionFileManagerSpy` only exercises the weaker-reported-class branch after the set. OI-5 also defers the chunked copy; that is a performance question, but the current `copyItem` default cannot satisfy D18's creation-before-bytes rule regardless of chunking.

**Required fix.** Restore D18: create the destination file with the complete-protection attribute before writing any bytes (for example, create the file with the protection attribute, then fill it by a bounded chunked stream or file-handle writes), and delete the partial file on any creation, write or verify failure. If a different mechanism is genuinely unavoidable, record an explicit L1 amendment and obtain review-l1/owner ratification; it cannot be absorbed silently into L2. Correct P-10, §5.2's step-order paragraph, §5.3's "Creation" bullet and R-4 so they describe the actual guarantee. Add a named ordering test (a FileManager spy asserts the protection attribute is set before the first byte, and no copy-then-set path exists) plus the kill-window case; update the NFR-RIE-005 and FR-RIE-011 traceability rows. OI-5 may remain a performance question, but its fix must be compatible with the restored creation-before-bytes rule.

#### M-3 — Major: the built-bundle assertion cannot detect a missing `InfoPlist.strings` registration

**Anchor.** `specs/design-l2.md` §11.3 N (`:2088`), §10.6's "Text pin" (`:1988`), N-1's resolution row (`:102`) and C05 (`:129`). `ios/project.yml:372` (`TEST_HOST` points the unit tests at the built app), and `ios/ElderlyAssistant/Info.plist:113–114`, `:121–122` (the two base keys, both amended and non-empty). The `InfoPlist.strings` files do not yet exist on disk; they are designed as new resources.

**Problem.** The design says a bundle-level assertion reads both keys from the built test host with `Bundle.main.object(forInfoDictionaryKey:)` and confirms they are non-empty, "so a missing `project.yml` registration fails even when the source files are correct." That inference is invalid. The base plist already carries both amended English values. In an app-hosted test, `Bundle.main` is the host app; if neither `en.lproj/InfoPlist.strings` nor `ne.lproj/InfoPlist.strings` is registered in `project.yml`, the same call returns the non-empty base English value and the assertion passes. It checks the current system-localised value, not the presence of either file, and it cannot detect a missing Nepali file at all. The source parses in the same test pass because the files exist in the source tree; they do not prove they enter the app bundle. So the localisation half of N-1 remains unevidenced, and the claimed test failure mode is false.

**Required fix.** Test the built bundle, not only `object(forInfoDictionaryKey:)`. In `L10nCatalogCoverageTests` (or a small `InfoPlistLocalisationTests` extension of the same suite), locate the host app bundle via `Bundle.main.bundleURL`, assert that `en.lproj/InfoPlist.strings` and `ne.lproj/InfoPlist.strings` exist inside it, parse each from the bundle, and assert both keys and their exact values (the English equality and the Nepali strings). Alternatively use `Bundle(path:)` or `path(forResource:ofType:inDirectory:forLocalization:)` for each locale and assert the localized values. Keep the source plist and source strings pins. Correct §10.6's "Text pin" and the N-1 resolution wording so the registration claim matches the test. This is a test-evidence correction; the table of `project.yml` entries itself is correct and remains.

#### M-4 — Major: `entriesIfReadable()` has no strict-read seam, so the orphan-sweep safety is not implementable

**Anchor.** `specs/design-l2.md` §2.11.6 (`:284`), §3.6 IF-23 (`:409`) and the extension (`:1041`), §4.9 (`:1348–1363`), §7.6 (`:1734–1744`), §11.3 K (`:2080`) and C11 (`:135`). `ios/ElderlyAssistant/Services/Reminders/RoutineStore.swift:17` (private storage) and `:25–30` (`loadEntries()` returns `[]` on a read failure); `ios/ElderlyAssistant/Services/Reminders/RoutineScheduler.swift:18` (private store); `ios/ElderlyAssistant/Services/MedicationScheduler/DependencyProtocols.swift:17` (the `EncryptedLocalStorage` protocol's `read` returns a `Result`).

**Problem.** The design's mitigation for its "worst failure" is the chain `entriesIfReadable()` / `snapshot()` → `LiveInstructionOwners` → a no-op for an unreadable root. The event half works: `EventExtrasStore.snapshot()` is added in C12 and returns nil on failure. The routine half does not. `RoutineScheduler.entriesIfReadable()` is declared, but `RoutineScheduler` holds a private concrete `RoutineStore`; `RoutineStore.loadEntries()` collapses every failure to `[]`, and `RoutineStore.storage` is private. There is no method on `RoutineStore` that can return a failure, and `RoutineStore.swift` is not in C11's file list; C11's "Types owned" row also omits `entriesIfReadable`. An implementer cannot distinguish "no routines" from "the encrypted store could not be read" without editing an untabled shared file. The §11.3 K test "make the routine store unreadable" has no seam to inject or observe, and a naive implementation would build an empty live set on a transient failure and let the sweep delete every routine instruction video. That is the exact failure R-1 claims to remove.

**Required fix.** Add a strict read to `RoutineStore` — for example, `func loadEntriesIfReadable() -> [RoutineEntry]?` that returns nil on any `storage.read` failure (or a `Result` variant with an explicit error), implemented against the `EncryptedLocalStorage` protocol. Add `Services/Reminders/RoutineStore.swift` to C11's files and type list, add an interface-register row for the strict read, and make `RoutineScheduler.entriesIfReadable()` delegate to it. Add a test with a failing `EncryptedLocalStorage` double that asserts `entriesIfReadable()` is nil and the sweep is a no-op, plus the mirror readable-but-empty collection test after the grace window. Update P-14/N-7 to table this shared file; this is a tabled shared-file edit, not scope creep. If a different seam is chosen, it must expose the same explicit nil/error distinction and be named in the component map.

### Review notes (not findings)

No other blocking or major issue was found. Three observations were deliberately not raised as findings because none changes behaviour or introduces a failure path: the permission copy says "never uploaded or shared" while D9 includes normal iOS backup (L1 accepted this as not app egress; the requirement's phrase is "stays on the device"); `InstructionObservability` accepts `kind: String` but restricts it through `InstructionKind.reportable`; and not every suite rename is restated in §1.3. None affects the decision.

## Ratification

| Item | Disposition | Basis and conditions |
|---|---|---|
| OI-1 | **Ratified** | The principal seams declare explicit error types. `EventExtrasStore.setInstruction -> Bool` is a narrow, labelled exception (IF-26) that follows the store's existing Bool convention and is translated to `.persistenceFailed` at the service boundary. Condition: keep the IF-26 label and the translation test. |
| OI-3 | **Ratified** | `InstructionCommit` and `InstructionPendingMedia` are necessary because an event has no id before it is created, so a picked photo or recorded video cannot have a store filename at handoff. The kind-match rule prevents a text write from smuggling media. |
| OI-7 | **Ratified** | NFR-RIE-008's 1 s bound is a failure-detection budget; the preflight and `AVPlayerItem.status` resolve the named failures within it. The 10 s ready watchdog is a platform-stall ceiling with Close available, not the failure budget. Condition: keep that distinction explicit and keep 10 s a backstop. |
| OI-8 | **Ratified** | Event notifications carry no `had_instruction`; the event tap already opens the detail, where absence renders `.none`, so there is no dead end. Revisit only if a future flow presents instruction content from the background. |
| OI-2 | Correctly classified, non-blocking | The synchronous AVFoundation accessors are deprecated but not removed; warnings-as-errors is off. The async replacement cannot run inside the system callback; the fallback is stated and triggered by SDK removal. |
| OI-4 | Correctly classified, non-blocking | The shared image store is pinned by L1 D3; one instruction image per owner is unambiguous. A per-instruction layout is a future product+engineering decision. |
| OI-5 | Non-blocking as a performance item, but coupled to B-3 | Chunking remains a measurement-driven performance fix inside the same callback, but the current "keep `copyItem`" default cannot satisfy D18's creation-before-bytes rule. The B-3 fix must choose a write path that creates the protected destination first; if that is a chunked write, OI-5 is resolved by construction. Do not ratify a `copyItem`-then-set path against D18. |
| OI-6 | Correctly classified, non-blocking | L1 specifies plain text only; a Settings deep-link is a new interaction and a product decision. The plain text is the shipped default. |
| R-1 through R-3, R-5 through R-14 | **Accepted** | R-1's nil-means-unknown mitigation is accepted in intent but is not implementable until M-4 is fixed; R-2/R-10's copy cost and R-3's deprecated probe are accepted with the stated OI fallbacks; R-5 is an honest conditional protection test; R-6 preserves `EventExtras` construction; R-7's log-gate limits are stated; R-8 through R-13 are the recorded mechanical L1 differences; R-9 is the system-language limit; R-11 is the `EventExtras` rebuild-hazard mitigation; R-12 records the 1 s/10 s distinction; R-13 is the duplicate-presentation dedupe; R-14 is the pre-existing event-image condition. |
| R-4 | **Not accepted as written** | It says protection is requested at creation and re-asserted after the copy, but the staged file is created by the copy at the source's class. This is the B-3 defect and must be corrected or the L1 decision formally amended. |

## Requirement traceability

The lock contains 25 functional and 10 non-functional RIE requirements, all re-derived from the locked files. Every requirement is named in §11.2; the status column records the two caveats that affect the decision.

| Requirement | Design sections | Named evidence | Status |
|---|---|---|---|
| FR-RIE-001 instruction model | §2.1, §3.4, §4.1–4.3 | `InstructionModelTests`; `RoutineSettingsInstructionTests`; `FreeFormEventServiceTests` | Covered |
| FR-RIE-002 text instruction | §2.1, §2.8, §4.1 | `InstructionModelTests`; `RoutineSettingsInstructionTests`; `EventExtrasStoreTests`; `RoutineStoreTests` | Covered |
| FR-RIE-003 image instruction | §2.1, §2.8, §5.8 | `InstructionModelTests`; `InstructionImageLoadingTests`; `RoutineSettingsInstructionTests`; `VisualAidStoreTests` | Covered |
| FR-RIE-004 library pick | §2.4, §3.5, §7.4 | `InstructionCaptureTests`; `InstructionVideoImportTests` | Covered |
| FR-RIE-005 recording | §2.4, §3.5, §7.4 | `InstructionCaptureTests`; `InstructionVideoImportTests` | Covered |
| FR-RIE-006 limits | §3.4, §5.2, §9.1 | `InstructionModelTests` (duration); `InstructionVideoImportTests` (limits) | Covered |
| FR-RIE-007 caption | §2.1, §3.4, §4.10 | `InstructionModelTests`; `InstructionVideoImportTests`; `InstructionCaptureTests` | Covered |
| FR-RIE-008 lifetime and edits | §4.2, §5.6 | `RoutineSettingsInstructionTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-009 existing surfaces | §2.8–2.10 | `RoutineSettingsInstructionTests`; `InstructionVideoImportTests`; `InstructionCaptureTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-010 plain feedback | §3.3, §6.2, §6.7, §10.7 | `InstructionVideoImportTests`; `InstructionCaptureTests`; `FreeFormEventServiceTests`; `FreeFormEventFormTests` | Covered |
| FR-RIE-011 storage layout and protection | §4.3, §5.1–5.4 | `InstructionVideoStoreTests`; `NoIOInInitTests` | **Covered except protection-at-creation (B-3)** |
| FR-RIE-012 filename hygiene | §3.4, §4.3, §4.7 F-11, §8.3 | `InstructionVideoStoreTests`; `InstructionImageLoadingTests`; `EventExtrasStoreTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-013 transactional replace | §5.6 | `InstructionVideoStoreTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-014 delete with owner | §2.11, §2.13.4, §5.5–5.6 | `InstructionVideoStoreTests`; `FreeFormEventServiceTests`; `RoutineSchedulerTests` | Covered |
| FR-RIE-015 always fires | §2.14, §2.17, §6.2 | `RoutineVisualAidFireHandlerTests`; `RoutineNotificationSchedulerTests`; unchanged facade and medication suites | Covered |
| FR-RIE-016 handlers return false | §2.14 | `RoutineVisualAidFireHandlerTests`; `FreeFormEventFireHandlerTests` | Covered |
| FR-RIE-017 composition | §2.15 | `InstructionDisplayStateTests`; `InstructionImageLoadingTests`; `InstructionSurfaceTests`; `FreeFormEventFireHandlerTests`; `AppCoordinatorInstructionTests` | Covered |
| FR-RIE-018 playback UX | §2.6–2.7, §10.1–10.3 | `InstructionPlaybackControllerTests`; `InstructionPlaybackAdapterTests`; `InstructionSurfaceTests`; `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-019 tap and Open | §2.14.2–3, §2.15.3–4, §4.11 | `RoutineVisualAidFireHandlerTests` (three taps); `AppCoordinatorInstructionTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-020 failure fallback | §4.10, §6.2 | `InstructionDisplayStateTests`; `InstructionPlaybackControllerTests`; `InstructionImageLoadingTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-021 notification taxonomy | §2.14, §2.17, §6.4 | `NotificationCategoriesTests`; `RoutineSchedulerTests`; `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-022 no notification attachment | §2.17, §5.6, §11.3 T | `RoutineNotificationSchedulerTests` | Covered |
| FR-RIE-023 no new machinery | §1.4, §2.15, §6.4 | `RoutineSchedulerTests`; `AppCoordinatorInstructionTests` | Covered |
| FR-RIE-024 honest capability surface | §2.8.6, §4.10, §10.5 row 36 | `InstructionDisplayStateTests`; `InstructionImageLoadingTests`; `InstructionSurfaceTests` | Covered |
| FR-RIE-025 permissions and disclosure | §2.4.3, §2.5.3, §3.5, §10.6 | `InstructionCaptureTests`; `InstructionPermissionTests`; `L10nCatalogCoverageTests` | **Designed; registration evidence gap (M-3)** |
| NFR-RIE-001 accessibility | §10.1–10.4 | `InstructionSurfaceTests`; `DesignTokensTests` | Covered |
| NFR-RIE-002 localisation | §10.5–10.7 | `L10nCatalogCoverageTests`; `InstructionSurfaceTests` | Covered |
| NFR-RIE-003 privacy and no egress | §8.3–8.4 | `InstructionSourceHygieneTests` | Covered |
| NFR-RIE-004 PII-free logs | §6.4–6.6 | `InstructionObservabilityTests`; `RoutineNotificationSchedulerTests` | Covered |
| NFR-RIE-005 at-rest protection | §5.3 | `InstructionVideoStoreTests`; `InstructionSourceHygieneTests` | **Not satisfied as written (B-3)** |
| NFR-RIE-006 migration and tolerance | §4.4–4.7 | `InstructionModelTests`; `InstructionDisplayStateTests`; `RoutineEntryTests`; `RoutineStoreTests`; `EventExtrasStoreTests` | Covered |
| NFR-RIE-007 footprint and orphans | §5.5–5.6 | `InstructionVideoStoreTests`; `RoutineSchedulerTests` | Covered |
| NFR-RIE-008 responsiveness | §8.1–8.2, §9.1 | `InstructionPlaybackControllerTests`; `AppCoordinatorInstructionTests`; recorded smoke | Covered; OI-7 ratified |
| NFR-RIE-009 testability and gate | §3.5, §11.2 | `InstructionVideoImportTests`; `InstructionCaptureTests`; `InstructionPlaybackControllerTests`; `InstructionPlaybackAdapterTests`; recorded smoke | Covered |
| NFR-RIE-010 preserved baseline | §4.10, §11.3 M, §11.2 unchanged suites | `InstructionSurfaceTests`; `RoutineVisualAidFireHandlerTests`; `RoutineNotificationSchedulerTests`; `NotificationCategoriesTests`; medication suites | Covered |

## Scope statement

No scope creep was found. The design keeps `url` decode-only and inert and ships no link, YouTube or URL control; no transcode, compression, trimming, cloud upload or thumbnails; no instruction notification category, action or attachment (`had_instruction` is a Boolean in `userInfo`); no medication-path change; no multi-instruction; no photo-library read (the picker is out of process and the recorder uses camera and microphone only); no Settings deep-link (OI-6 default); no audio transcription or captioning; and no `SpokenTime`. §1.4 and the source-hygiene tests (§11.3 P and Q) enforce that boundary. The two `InfoPlist.strings` resources are localisation files required by L1 D10, not new scope. The component set is L1's C01–C17; the only file-list correction needed is the RoutineStore shared-file table for M-4. The permission copy's existing cloud disclosures describe current app behavior; no new egress is introduced. The design adds no new permission key.

## Decision

Decision: NO_GO

**Justification.** The iteration-2 findings are substantially closed: B-1, B-2, M-1, M-2, m-1 and m-2 remain intact, m-3 is accepted, m-4 is verified, and N-2 through N-10 are resolved in the body with anchors and named tests. N-1's original blocker is closed by the designed plist text, strings files and registration, but its localisation evidence is not yet real (M-3). Three new issues prevent a GO: B-3 reverses L1 D18 and review-l1 m-5 by copying before protecting the staged video, with a false "creation is the guarantee" claim and a real weaker-class crash window; M-3's built-bundle assertion cannot detect a missing `InfoPlist.strings` registration; and M-4 leaves `entriesIfReadable()` without a strict-read seam, so the nil-means-unknown sweep safety cannot be implemented or tested. These are correction-pass issues, not a redesign.

**Blocking IDs:** B-3 (locked storage/privacy decision), M-3 (N-1 evidence), M-4 (sweep safety and implementability).

**Conditions for a GO at iteration 4.**

1. Close B-3 by restoring creation-before-bytes with complete protection and correcting P-10, §5.2, §5.3 and R-4; add the ordering and kill-window tests; or obtain an explicit L1 amendment ratified at review-l1/owner. Do not absorb the deviation silently.
2. Close M-3 by asserting the built app bundle's `en.lproj` and `ne.lproj` `InfoPlist.strings` resources and their values, and correct the §10.6/N-1 evidence claim.
3. Close M-4 by adding the strict `RoutineStore` read, tabling `RoutineStore.swift` in C11, adding the interface row, and pinning the unreadable-store and readable-but-empty sweep tests.
4. Keep every N-2 through N-10 resolution and every B/M/m fix intact; introduce no new contradiction; leave the scope boundary unchanged; and ensure no new open item lacks a shipped default.

This report is the only file written by this review. The preserved iteration-2 review copy was not edited. No build, test run, commit or workflow execution was performed.
