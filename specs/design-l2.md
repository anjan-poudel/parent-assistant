# Design L2 — Reminders: instructions (text / image / video)

> **Task** `design-l2` · **contract** `component_design_l2` · **feature** `reminders-instructions-enhancements` · **date** 2026-10-25
> **Inputs** `specs/design-l1.md` (approved; D1–D18, C01–C17), `specs/review-l1.md` (GO; minors N-1…N-5), `specs/reminders-instructions-enhancements/constitution.md` (OD-1…OD-8 resolved), `specs/define-requirements.md` + `.lock.yaml` (25 FR-RIE, 10 NFR-RIE), and the shipping sources under `ios/ElderlyAssistant/`.
> **Verification statement** Every file, symbol and line number below was read in this worktree at the commit of this task. Where L1's citation drifted (review-l1 N-4), the corrected anchor is used and the correction is listed in §1.3. Nothing here is inherited on trust.
> **Scope statement** This document specifies *how* C01–C17 are built. It adds **no component, no user-visible behaviour, no dependency and no permission** beyond L1 and the feature constitution. Where an L1 literal had to be made concrete (a typed value instead of a `Bool`, a value type carrying a signal L1 names but does not type), the change is listed in §1.3 and raised in §13 rather than absorbed silently.

---

## Overview

### 1.1 What L2 has to decide

L1 fixed the architecture: an optional `Instruction` on a routine entry and on a free-form event; three instruction kinds (`text`, `image`, `video`) — L1's vocabulary, restated here without renaming; one instruction per owner; receive-as-is video up to 3 minutes / 200 MiB; transactional replace; a footer seam on the fired screen; `had_instruction` in the notification payload; four-way playback availability. It left the *engineering* open: which type owns which decision, the exact Swift contracts (including error types), the on-disk algorithm and its protection/verification policy, the configuration values and where they live, the event names and fields, the copy, and the test that proves each requirement.

L2 is implementation-ready when an implementer can write each file without making a design decision. That is the bar this document is held to: every type below is given a full declaration (properties, initialisers, method signatures, error type), every async or external call is given a timeout name and default, and every behavioural claim names the suite that would fail if the claim became false.

### 1.2 The decisions of this document

| # | Decision | Resolves | Detailed in |
|---|---|---|---|
| P-1 | The **playback controller** owns both timers — `preflightTimeoutSeconds` (0.6 s) and `readyWatchdogSeconds` (10 s). The AVKit adapter owns neither and uses no timers. A new `InstructionPlaybackEvent.preflightPassed` makes the phase boundary observable and testable; a `deadline:` seam makes both timers deterministic in unit tests. | review-l1 N-3 (preflight ownership stated twice) | §3.5 IF-20, §8.2 |
| P-2 | `Result<Void, InstructionStorageError>` and the `.deleteFailed` case apply **only** to `InstructionVideoStore`. `VisualAidStore.delete/deleteAll` and `ContactPhotoStore.delete(named:)` keep their existing `Void` best-effort signatures, and no failure event is claimed for image deletes. | review-l1 N-1 | §3.5 IF-8/IF-9, §5.8, §6.4 |
| P-3 | All `instruction_*` events are emitted by a typed `InstructionObservability` value in `Services/Instructions` (a `FEATURE_ROOTS` directory). `entry_instruction_updated` stays where L1 puts it — inside the shared `RoutineScheduler.persistAndReschedule` — and is graded by **event type**: it is registered in `FEATURE_EVENT_TYPES` (rules 5–6), never claimed to be graded from a file root. | review-l1 N-2 | §3.6, §6.5 |
| P-4 | `EventExtrasStore.setPhotoFilename` is fixed to **mutate the existing extras row**, preserving every other field including `instruction`. The wholesale `EventExtras(photoFilename:)` rebuild is removed; a test pins that an instruction survives a photo change. | review-l1 N-4, L1 C12 | §4.5 |
| P-5 | The capture protocols take the staging hook **inside** the system callback: `presentVideoPicker(makeStagedCopy:completion:)` and `presentRecorder(maximumDurationSeconds:quality:makeStagedCopy:completion:)`. `completion` is called exactly once on every path, on the main thread. This is structural, not stylistic — the callback URL is dead afterwards. | review-l1 N-4 (capture signatures) | §3.4 IF-16/IF-17, §7.4 |
| P-6 | The launch/housekeeping sweep is driven by `LiveInstructionOwners`, whose `nil` means **unreadable, therefore unknown** — an unreadable routine store or extras index disables sweeping for that root rather than deleting every video. Owner directories younger than `orphanGraceSeconds` (60 s) are never swept, and an in-memory in-flight commit set is consulted under a lock. | review-l1 N-4 (crash orphans) | §5.5, §7.6 |
| P-7 | `StagedInstructionVideo` and `AcceptedInstructionVideo` are `Equatable`; `InstructionPlaybackAvailability`, `InstructionImportError`, `InstructionStorageError`, `InstructionWriteError`, `InstructionPlaybackFailure` and `InstructionImageFailure` are `Equatable`. Tests compare values, not descriptions. | review-l1 N-4 | §3.2, §3.3 |
| P-8 | L1's drifted anchors are corrected: `EventExtrasStore.setPhotoFilename` is `:110–113`; `RoutineScheduler(` is `AppCoordinator.swift:3571`; the routine fired overlay is `ContentView.swift:65–73`; the notification payload is `RoutineAlarmScheduler.swift:75–79`; the formatter is `LocaleFormatters.shortTime(locale:)` (`App/ViewCaches.swift:51`). | review-l1 N-4 | §1.3 |
| P-9 | `App/InstructionCapture.swift` is added to `FEATURE_ROOTS` as an ordinary file root (the adapter file contains no log surface, but the root makes that a graded fact). A card in the `.none` state renders `EmptyView`, so the no-instruction fired screen is the **same rendered screen** as today. | review-l1 N-5 | §5.8, §6.5, §10.3 |
| P-10 | The staging destination file is **created with `.completeFileProtection` before any byte is written**, then filled by a bounded chunked stream from the source; the attribute is verified immediately after creation and again after the stream, and a reported weaker class deletes the file and fails the write. `copyItem` is never used in the staging path, so there is no copy-then-set window. A missing `protectionKey` attribute (a platform reporting limitation) is tolerated, because creation is the guarantee and verification is a detector. Tests assert the create-before-bytes order and the creation option by source pin **and** the attribute when the platform reports it, and exercise the fail-closed path through the store's staging seam double. | L1 D18, review-l1 m-5, constitution §Security | §5.2, §5.3 |
| P-11 | The two `setInstruction` seams return `Result<Void, InstructionWriteError>` instead of L1's `Bool`. Behaviour is identical (failure still means "nothing changed, previous instruction intact"); the change exists because the principal-engineer contract forbids a method whose only error channel is a `Bool`. Recorded as OI-1 for review-l2 ratification. `EventExtrasStore.setInstruction` keeps the store's existing `Bool` convention and is translated at the service seam. | L1 C11/C13 literal vs. constitution principle | §1.3, §3.5, §13 |
| P-12 | The fired-screen path carries the notification's `had_instruction` as a typed `RoutineInstructionFireContext` value (not a bare `Bool`), and `FiredRoutineVisualAids.Content.reminder` carries `instruction`, `expectsInstruction` and `firedAt`; `Content.unavailable` carries none of them. The time line renders the **fire time** (there is no trigger timestamp in userInfo and adding one is not needed). | L1 D13/D14, C14/C15 | §3.4, §4.11 |
| P-13 | Tapping a routine notification presents the instruction screen only when `had_instruction == true`; a photo-only or pre-upgrade notification (key absent ⇒ `false`) stays a **no-op on tap**, exactly as today. Three tap cases are specified: present, instruction-removed fallback, and entry-deleted `instruction.reminderUnavailable` notice with Close (L1 D14; review-l1 B-2) — a deleted owner is a notice, never a dead tap. | L1 tap branching (D14), review-l1 B-2, feature constitution | §2.14, §3.6, §4.11, §6.2, §10.3, §11.3 |
| P-14 | `InstructionRecordingQuality` and the three configuration structs live in `Services/Instructions/InstructionConfiguration.swift`; `InstructionPlaybackConfiguration` lives beside the controller in `InstructionPlayback.swift`. **No new file beyond those tabled in §2.0** (the M-4 strict read is an edit to the already-shipping `Services/Reminders/RoutineStore.swift`, tabled as a shared file), and no UIKit import in a service model file. | L1 file layout (left open) | §2, §8.1 |

### 1.3 Refinements to L1 literals

Each row is a place where L1 states a *shape* that cannot be implemented literally without leaving an error channel or a signal untyped. None changes user-visible behaviour, the component set, or the scope boundary.

| # | L1 literal | L2 refinement | Why | Ratification |
|---|---|---|---|---|
| R-1 | `setInstruction(_:entryId:) -> Bool` (C11/C13) | `Result<Void, InstructionWriteError>` (P-11) | The principal-engineer contract requires a declared error type on every interface method; a `Bool` cannot say *why*, and the copy differs between "owner gone" and "write failed". | OI-1 (review-l2) |
| R-2 | `RoutineVisualAidFireHandler(entryLookup:onFire:)` with `onFire(RoutineEntry)`; `FiredRoutineVisualAids(entryId:title:aids:)` | `onFire(RoutineEntry, RoutineInstructionFireContext)` plus the separate `onInstructionTap(UUID, RoutineEntry?, Date)` sink; `FiredRoutineVisualAids.Content` carries the reminder fields or `.unavailable` | D13/D14 require `had_instruction` at presentation time and an optional entry on the tap path; the existing callback has neither. A typed context beats a bare `Bool`, and the optional entry is what lets a deleted owner reach the notice (review-l1 B-2). | none — mechanical consequence of D13/D14 |
| R-3 | The notification scheduler's `scheduleRoutineReminder(...)` (L1 C17) | one new parameter, `hadInstruction: Bool`, no default | An explicit argument at the single production call site (`RoutineScheduler.regenerateWindow`) is the point; a default would let a future caller forget and silently degrade tap behaviour. | none |
| R-4 | L1 cites `setPhotoFilename` at `:108`, `RoutineScheduler(` at `:3583`, the overlay at `:61–69`/`:92–96` | corrected anchors per P-8 | The citations drifted as the file grew during L1 review. | none |
| R-5 | "the attribute is asserted on the staged and committed file" (C16) | source pin on the write option **plus** an attribute read that asserts only when the platform reports one | iOS does not guarantee `attributesOfItem` surfaces `protectionKey` on every simulator/runtime; an unconditional assertion would be flaky and would not strengthen the guarantee. The fail-closed detector is tested through a spy instead (P-10). | none — an honest test, not a weaker one |
| R-6 | `EventExtras` memberwise init `EventExtras(photoFilename:)` | new property `instruction: Instruction? = nil`; the memberwise init keeps its existing call sites | A defaulted property preserves every existing construction; the *store* methods are where wholesale construction is forbidden (P-4). | none |
| R-7 | `InstructionDraft.resolvedWrite` is the editor→host handoff (C01/C09) | the draft exposes **both** `resolvedWrite` (L1's value, unchanged and truth-table-tested) and `resolvedCommit` (`InstructionWrite` + optional `InstructionPendingMedia`); the host seams take the commit | A picked photo or recorded video has no store filename until the owner's save transaction writes it — an event id does not exist before the event is created. Carrying the pending bytes beside the write is the same shape the shipping event form already uses for `pickedPhoto`; committing at pick time would strand orphan bytes for a cancelled form. The payload itself (`struct InstructionPayload`, §3.4) keeps L1's `kind`/`text`/`caption` and replaces its `existingFilename`/`pendingImage`/`pendingVideo` fields with one `filename`; the pending bytes live once, on `InstructionCommit`. Same information, typed once. | OI-3 |
| R-8 | `struct InstructionDisplayState { instruction; expectsInstruction; presentation }` + `enum InstructionPresentation { .none, .missingInstruction, .text, .media(kind:filename:), .unsupportedKind }` (L1 §C01) | one `enum InstructionDisplayState { .none, .text, .image, .video, .unsupported, .removed }` plus the pure `InstructionPresentation.state(for:isExpected:)` constructor | The six logical states are identical: `.missingInstruction` becomes `.removed`, `.media(kind: .image)`/`.media(kind: .video)` become separate cases, `.unsupportedKind` becomes `.unsupported`. Collapsing the two types makes the view switch exhaustive and keeps the state free of IO; the derivation is the same total function. No behaviour change. | none — mechanical equivalence |
| R-9 | `@MainActor protocol InstructionPermissionRequesting { func status(...) -> Status; func request(...) async -> Status }` and a four-case status (L1 §C05) | `protocol InstructionPermissionRequesting: Sendable` with both methods `async`; the five-case status adds `.restricted` | The production adapter still calls `AVCaptureDevice` on the main actor where the API requires it; the coordinator already awaits `request`, and awaiting `status` makes the seam uniformly `Sendable` without adding a hop to any caller. `.restricted` is surfaced separately from `.denied` but maps to the same plain denial note and the same no-re-prompt rule, so no user-visible behaviour changes. | none — mechanical equivalence |
| R-10 | `InstructionVideoImporting { validate(...) async; discard(_:) }` (L1 §C03) | `validate` alone; on any validation failure it discards the staged bytes before returning; explicit discard is the store's `discard(_:)` (IF-7), called by the capture coordinator on cancel/leave | Every discard that used to go through the importer now goes through the one type that owns the bytes, and the failure path still discards before returning. No staged directory outlives the same set of events; no behaviour change. | none — mechanical equivalence |
| R-11 | `FreeFormEventFireHandler(instructionPresent: (String) -> Bool)` as a second lookup (L1 §C14, m-1) | the handler reads `event.instruction?.isPresent == true` from the single `FreeFormEvent` it already resolves through `FreeFormEventService.event(withId:)` | One read instead of two, so the gate can never disagree with the event it presents; the value is identical (the service populates the composite from the same index row). No new dependency and no behaviour change. | none — mechanical equivalence |
| R-12 | `InstructionPlaybackEvent { ready, failed, finished, dismissed }`; controller `close()` "pauses and releases"; a seven-case playback failure including the three resolution failures (L1 §Playback) | `{ preflightPassed, ready, failed, finished, closed }`; the adapter's `dismiss()` pauses before releasing and the controller emits `.closed`; `InstructionPlaybackFailure` keeps only the four playback-time failures because the three resolution failures live in `InstructionPlaybackAvailability` (D16) | Pause is one step inside `dismiss()`, not a separately observed event; the close path is still observed once (`.closed`, after a player existed). A file that cannot resolve never reaches playback (D16), so its failure cannot arise there. No behaviour change. | none — mechanical equivalence |
| R-13 | C17 is a bounded change inside `RoutineAlarmScheduler.swift` (L1 component map) | the pure builder is extracted to `Services/Notifications/RoutineNotificationContent.swift`; the scheduler delegates to it | The extraction exists so `had_instruction` and the payload are testable without a notification centre; the call path, the argument, the userInfo keys, the banner/list/sound outcome and the scoped cancels are unchanged. C17 is the same component, one file split out. No behaviour change. | none — mechanical equivalence |

Rows R-8…R-13 are documentation fidelity only, as review-l2 N-8 says: none changes user-visible behaviour, the component set or the scope boundary, and none is a new decision. Renames that ride along (`InstructionPermission` → `InstructionMediaPermission`, `InstructionResolutionOutcome` → `InstructionAvailabilityOutcome`, `InstructionCaptureCoordinatorTests` → `InstructionCaptureTests`) are mechanical too; the typed values they name are unchanged.

### 1.4 Scope boundary and deliberate non-changes

In scope is exactly C01–C17. Out of scope, and not to be added by an implementer reading this document:

- **Links / YouTube / URL playback.** `Instruction.url` exists in the encoded model for tolerant decode only; v1 never authors it, never renders it, and has no UI that acts on it.
- **Transcode, compression, trimming, cloud upload, thumbnails.** Video is stored byte-for-byte as received (receive-as-is, constitution OD-2).
- **Notification categories, actions, attachments for instructions.** The routine reminder keeps no category, no action, and at most the existing first-photo attachment. `had_instruction` is a userInfo key only.
- **Medication paths.** `MedicationVisualAidFireHandler`, the medication scheduler, the slot model and the dose screen are untouched. Medication entries are a separate id space and cannot be instruction owners.
- **More than one instruction per owner**, per-instruction ordering, and multi-video.
- **Photos-library access.** The video *picker* is `PHPickerViewController` (out of process, no permission). The *recorder* is `UIImagePickerController` (camera + microphone). We never read or write the user's photo library.
- **Deep-linking the user to Settings** from a denied permission state. The state is plain text (L1 C05/C09); an "Open Settings" affordance is OI-6, not a silent addition.
- **Transcribing or captioning a video's audio.** Captions are typed by the family or absent.
- **`SpokenTime`.** No new time is spoken; the only new time is visual. (Any future spoken time must go through `SpokenTime` — constitution rule.)

### 1.5 How to read this document

§2 maps components to files and types. §3 is the contract register: every type and method an implementer writes, grouped by owner, with its error channel and isolation. §4 pins the encoded shapes and the migration fixtures. §5 is the on-disk algorithm. §6 is failure mapping and the exact event catalogue. §7 states who may touch what, and under which isolation. §8 gives the performance budgets and the threat model. §9 is the configuration register (defaults and timeout names). §10 is accessibility and copy. §11 maps every suite to the requirement it evidences. §12 is risk; §13 is open items.

### 1.6 What "done" means at L2

A reader can answer, for any line of code they are about to write: which component owns it, which type it belongs to, what it returns on every failure path, which queue/actor it runs on, which timeout bounds it, which event records it, which copy the user sees, and which test fails if it is wrong. If any of those is missing below, that is a defect in this document, not an implementation choice.

### 1.7 Review-l2 resolution (rework iteration 1)

This revision answers `specs/review-l2.md` (NO_GO, 2026-10-25). The architecture and the engineering core are unchanged; the table maps every finding to its correction.

| Finding | Resolution | Sections changed |
|---|---|---|
| B-1 | The routine tap sink carries the optional entry (`onInstructionTap(entryId:entry:firedAt:)`); the coordinator maps `entry == nil` to `FiredRoutineVisualAids.Content.unavailable`, rendered by the shared fired screen with `aids: []`, title `instruction.reminderUnavailable`, an `EmptyView` footer and Close — no title or time claimed. The copy key, VoiceOver row, failure-matrix row and test case are restored. P-13's attribution is corrected and the photo-only/pre-upgrade no-ops remain. | P-12, P-13, §2.14, §2.15, §3.2 IF-31/IF-32, §3.6, §4.10, §4.11, §6.2, §6.7, §10.3, §10.5, §11.3 B, §11.5, R-2, R-13 |
| B-2 | The persisted kind is `text` everywhere: `InstructionKind.text`, raw value `"text"`, payloads, fixtures, `reportable`, observability and the copy key `instruction.kind.text` (label "Text"). The overview attributes text/image/video to L1. `"link"` and `"audio"` remain independently unknown values in the tolerance tests. No OI is recorded: this is a correction to a locked requirement, not a refinement. | title, §1.1, §2.1, §3.4, §3.4.1, §4.1, §4.2, §4.6, §4.7 F-3/F-6a/F-6b, §4.10, §5.6 C, §6.4, §10.1, §10.3, §10.5, §11.2, §11.3 C/G, §11.5 |
| M-1 | C04/C05 specify camera first, microphone second when both are undetermined, short-circuiting on denial, then presenting the recorder; `InstructionPermissionTests` records and asserts the request sequence, including both denial short-circuits. | §2.4, §2.5, §3.5, §11.2, §11.3 R |
| M-2 | FR-RIE-024 is credited to `InstructionDisplayStateTests` (unknown kind, no fake control) plus a new `InstructionSurfaceTests` source scan (no link/URL/YouTube control, no background-playback claim) and the restored `instruction.foregroundNote` in the editor. FR-RIE-021 moves to `NotificationCategoriesTests` + a scoped-cancel case in `RoutineSchedulerTests`. FR-RIE-022 moves to `RoutineNotificationSchedulerTests` with explicit attachment assertions on schedule, re-arm and the event path. §11.2 is corrected so each suite can fail what it claims. | §2.8, §6.7, §10.3, §10.5, §11.2, §11.3 C/N/Q/R/S/T, §11.4 |
| m-1 | Every service read is named `FreeFormEventService.event(withId:)` (`FreeFormEventService.swift:318`); the existing coordinator wrapper `AppCoordinator.freeFormEvent(id:)` merely calls it, so there is no second read path. | §2.13, §3.6, §4.8, §5.9 |
| m-2 | `EventExtrasStore.setInstruction -> Bool` is labelled in the interface register as a deliberate, recorded exception (OI-1), translated to `InstructionWriteError.persistenceFailed` at the service seam. | §3.1, §3.2 IF-26, §3.5, §13 OI-1 |

The review's m-3 (copy-family renames) and m-4 (P-8 anchors verified) need no change; the two behaviour-bearing keys are restored above.

### 1.8 Review-l2 resolution (rework iteration 2)

This revision answers `specs/review-l2.md` (NO_GO, iteration 2, 2026-10-25). The architecture, component set, scope boundary and ratified decisions (OI-1, OI-3, OI-7, OI-8; R-1…R-7) are unchanged. The iteration-1 fixes are intact and were re-checked while editing: the entry-deleted `instruction.reminderUnavailable` notice and the optional-entry tap sink (B-1), the locked `"text"` kind everywhere (B-2), camera-before-microphone ordering (M-1), the FR-RIE-024/021/022 evidence mappings and `instruction.foregroundNote` (M-2), `event(withId:)` as the single read path (m-1), and the labelled store `Bool` exception (m-2).

| Finding | Resolution | Sections changed |
|---|---|---|
| N-1 | The shipped `Info.plist` is now designed and tested: `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` are amended in English with exact text that retains every existing disclosure and adds video recording plus on-device storage; `Info.plist` is a shared C05 file, both `InfoPlist.strings` resources and their `project.yml` registration are tabled, and `L10nCatalogCoverageTests` gains FR-RIE-025 pins over the source plist, both source `InfoPlist.strings`, and the built app bundle's `en.lproj`/`ne.lproj` `InfoPlist.strings` resources (presence and parsed values). D10's English-plist fallback and the honest R-9 limit are kept. | §2.0 C05, §10.6, §11.2, §11.3 N, §11.5 step 13, §12 R-9 |
| N-2 | The §10.1 kind-picker row now reads Text / Photo / Video, matching §10.5 rows 5–7 and the persisted `text` kind. | §10.1 |
| N-3 | §3.4 declares `struct InstructionPayload` with stored `let` fields and an explicit memberwise init, matching L1's struct shape; the dependent declarations, the §4.2 truth/payload tables and the fixtures were re-checked; R-7 records the payload's media fields moving to `InstructionCommit`. | §3.4, §4.2, R-7 |
| N-4 | `InstructionFilename.isPlain` now requires a non-empty component **and** excludes `.`, `..` and both separators; the guard is applied before any name-derived URL is built (store `availability`/`fileURL`/`delete` and both image loaders); empty, single-dot and double-dot refusal cases join F-11, §11.3 D, `InstructionVideoStoreTests` and the new `InstructionImageLoadingTests`. | §3.3, §3.4, §3.5, §4.3, §4.7 F-11, §5.4, §8.3, §11.2, §11.3 D |
| N-5 | §4.10 states the D6 gate authoritatively and §2.15.4 applies it at the composition seam: `timeText` is non-nil only when the instruction is present or `expectsInstruction` is true; `.unavailable` carries no time; the photo-only foreground firing is pinned in §11.3 M as `timeText == nil` with the `.none` card and footer both `EmptyView`, matching `VisualAidViews.swift:283–289`. §4.11, §10.3 and §11.3 B.2 were re-checked against the same rule. | §2.15.3–4, §4.10, §4.11, §10.3, §11.2, §11.3 B/M |
| N-6 | §8.3 now cites the real suite, `RoutineNotificationSchedulerTests`; the phantom `RoutineNotificationContentTests` is gone. | §8.3 |
| N-7 | §2.0 C01 gains `Services/Instructions/InstructionImageLoading.swift` and its three types; C05 gains `Info.plist`, both `InfoPlist.strings` resources and the `project.yml` resource registration; C08 names the loader file it reads; P-14 is reworded to "no new file beyond those tabled in §2.0". | P-14, §2.0 C01/C05/C08 |
| N-8 | §1.3 gains R-8…R-13 recording the six L1 shape differences (display state, permission protocol, importer discard, event-handler composite read, playback close/pause, C17 extraction) and states their mechanical equivalence. None changes behaviour. | §1.3 |
| N-9 | `RoutineVisualAidFireHandlerTests` and `RoutineNotificationSchedulerTests` now name FR-RIE-015; `InstructionPlaybackControllerTests` adds the `finished` outcome; §11.3 I states that Close exercises the adapter's pause-then-release path. | §11.2, §11.3 I |
| N-10 | The duplicate `FakeInstructionVideoRecorder` row is merged into one; the `instruction.video.tooLong` copy now says "3 minutes or shorter" in both languages, matching the exactly-180-second inclusive cap, and the §6.7 example agrees; §5.2 step 3 states the boundary. | §5.2, §6.7, §10.5, §11.3 A, §11.4 |

No finding required an architectural change. Where a fix touched an already-approved row (for example R-7), the change is a recording of the same behaviour, not a new decision.

### 1.9 Review-l2 resolution (rework iteration 3)

This revision answers `specs/review-l2.md` (NO_GO, iteration 3, 2026-10-25). It fixes exactly the three new findings — B-3, M-3 and M-4 — and changes nothing else. The component set C01–C17, decisions P-1…P-14, refinements R-1…R-13, the ratified items OI-1/OI-3/OI-7/OI-8, the scope boundary, the requirement lock and every earlier fix (B-1, B-2, M-1, M-2, m-1, m-2, N-1…N-10) are unchanged.

| Finding | Resolution | Sections changed |
|---|---|---|
| B-3 | The staging destination is now **created with `.completeFileProtection` before any byte is written**, then filled by a bounded chunked stream (1 MiB default) with the 200 MiB cap enforced cumulatively and the step-2 byte count checked exactly; any creation, read, write or verify failure deletes the partial file and the draft directory. `copyItem` is removed from the staging path, so there is no copy-then-set window. The attribute is re-verified after the stream, and the committed-file verification stays. P-10, the §5.2 steps and step-order paragraph, §5.3 and R-4 now state the real guarantee; the small `InstructionStagingFileOps` seam lives inside `InstructionVideoStore.swift` (no new file) and is tabled in C02; OI-5 is now the chunk-size measurement with a shipped 1 MiB default. | P-10, §2.2–2.3, §2.16, §3.3, §3.5, §5.2–5.3, §5.10, §6.3, §8.1–8.3, §9.1–9.2, §11.2–11.4, R-2, R-3, R-4, OI-2, OI-5 |
| M-3 | Registration evidence now reads the **built app bundle**: the unit tests are app-hosted (`TEST_HOST`, `ios/project.yml:371–372`), so the suite resolves the host app from `Bundle.main.bundleURL`, asserts `en.lproj/InfoPlist.strings` and `ne.lproj/InfoPlist.strings` exist inside it, parses each as a property list and asserts both keys and their exact values (en = the source plist English; ne = the exact §10.6 Nepali strings, containing Devanagari). A missing `project.yml` registration fails because the resource is absent from the bundle. The source-plist and source-strings pins stay; `object(forInfoDictionaryKey:)` is no longer claimed as registration evidence. | §1.8 N-1, §10.6, §11.2, §11.3 N |
| M-4 | `RoutineStore` gains `loadEntriesIfReadable() -> [RoutineEntry]?` (nil on any `storage.read` failure, including a first-run absent key); `RoutineScheduler.entriesIfReadable()` delegates to it, and the legacy `loadEntries()` keeps `[]` for every existing caller. The shared file is tabled in C11, IF-33 records the contract, and the unreadable-store survival, readable-but-empty collection and legacy-`[]` tests are named. | P-14, §2.0 C11, §2.11, §2.16, §3.6, §4.9, §5.9, §7.1, §7.6, §11.2–11.4, R-1 |

---

## Components

### 2.0 Component map

The component set is L1's C01–C17, unchanged. This table adds only *files and type ownership*, which L1 left open. A file marked **(shared)** already exists and is edited in place; a file marked **(new)** is created by this feature. The `FEATURE_ROOTS` mark means the file or directory is registered in the Release-log gate (§6.5).

| L1 | Component | Files | Types owned | Suites |
|---|---|---|---|---|
| C01 | Model and display state | `Services/Instructions/Instruction.swift` (new) · `InstructionDisplayState.swift` (new) · `InstructionConfiguration.swift` (new) · `InstructionFilename.swift` (new) · `InstructionImageLoading.swift` (new) · `InstructionObservability.swift` (new) — directory in `FEATURE_ROOTS` | `InstructionKind`, `Instruction`, `InstructionPayload`, `InstructionWrite`, `InstructionDraft`, `InstructionOwner`, `InstructionRoot`, `InstructionVideoDuration`, `InstructionDisplayState`, `InstructionPresentation`, `InstructionMessageKey`, `InstructionVideoLimits`, `InstructionVideoConfiguration`, `InstructionCaptureConfiguration`, `InstructionRecordingQuality`, `InstructionImageLoading`, `VisualAidInstructionImageLoader`, `EventPhotoInstructionImageLoader`, `InstructionObservability` | `InstructionModelTests` (new), `InstructionDisplayStateTests` (new), `InstructionImageLoadingTests` (new), `InstructionObservabilityTests` (new) |
| C02 | Video store | `Services/Instructions/InstructionVideoStore.swift` (new) — in root | `InstructionVideoStore`, `InstructionStagingFileOps`, `SystemInstructionStagingFileOps`, `InstructionPlaybackAvailability`, `InstructionStorageError`, `StagedInstructionVideo`, `AcceptedInstructionVideo` | `InstructionVideoStoreTests` (new) |
| C03 | Probe and importer | `Services/Instructions/InstructionVideoInspecting.swift` (new) · `InstructionVideoImporter.swift` (new) — in root | `InstructionVideoMetadata`, `InstructionVideoProbing`, `InstructionVideoInspecting`, `AVInstructionVideoProber`, `AVInstructionVideoInspector`, `InstructionVideoImporting`, `InstructionVideoImporter`, `InstructionImportError` | `InstructionVideoImportTests` (new) |
| C04 | Capture adapters and coordinator | `Services/Instructions/InstructionVideoCaptureCoordinator.swift` (new) · `App/InstructionCapture.swift` (new, `FEATURE_ROOTS` file) | `InstructionVideoPicking`, `InstructionVideoRecording`, `PHPickerInstructionVideoPicker`, `UIImagePickerInstructionVideoRecorder`, `InstructionVideoCaptureCoordinator` | `InstructionCaptureTests` (new) |
| C05 | Permissions and usage disclosure | `Services/Instructions/InstructionPermissions.swift` (new) — in root · `ios/ElderlyAssistant/Info.plist` **(shared)** · `ios/ElderlyAssistant/Resources/en.lproj/InfoPlist.strings` (new) · `ios/ElderlyAssistant/Resources/ne.lproj/InfoPlist.strings` (new) · `ios/project.yml` **(shared; two resource entries)** | `InstructionMediaPermission`, `InstructionPermissionStatus`, `InstructionPermissionProblem`, `InstructionPermissionRequesting`, `AVFoundationInstructionPermissions` | `InstructionPermissionTests` (new), `L10nCatalogCoverageTests` (ext; FR-RIE-025 text pins) |
| C06 | Playback seam and controller | `Services/Instructions/InstructionPlayback.swift` (new) — in root | `InstructionVideoPlaying`, `InstructionPlaybackEvent`, `InstructionPlaybackFailure`, `InstructionPlaybackConfiguration`, `InstructionPlaybackController` | `InstructionPlaybackControllerTests` (new) |
| C07 | AVKit adapter | `Services/Instructions/AVKitInstructionVideoPlayer.swift` (new) — in root | `AVKitInstructionVideoPlayer` | `InstructionPlaybackAdapterTests` (new, source pins) |
| C08 | Card, cover and editor views | `App/InstructionViews.swift` (new, `FEATURE_ROOTS` file) · reads `Services/Instructions/InstructionImageLoading.swift` (C01) | `InstructionCardView`, `InstructionCardDependencies`, `InstructionPlaybackCover`, `InstructionEditorView`, `InstructionEditorDependencies` | `InstructionSurfaceTests` (new) |
| C09 | Routine editor integration | `App/RoutineSettingsView.swift` **(shared)** | the instruction section and its draft plumbing | `RoutineSettingsInstructionTests` (new) |
| C10 | Event editor and detail | `App/EventsView.swift` **(shared)** · `Services/Events/FreeFormEventDraft.swift` **(shared)** | form section, detail card, draft field | `FreeFormEventFormTests` (extended) |
| C11 | Routine scheduler | `Services/Reminders/RoutineScheduler.swift` **(shared)** · `Services/Reminders/RoutineStore.swift` **(shared)** | `setInstruction`, `entriesIfReadable`, `entry(deleting:)` media teardown, `loadEntriesIfReadable` (the strict read on `RoutineStore`) | `RoutineSchedulerTests` (extended), `RoutineStoreTests` (extended) |
| C12 | Extras store | `Services/Storage/EventExtrasStore.swift` **(shared)** | `EventExtras.instruction`, `setInstruction`, `snapshot()`, the `setPhotoFilename` fix | `EventExtrasStoreTests` (extended) |
| C13 | Free-form event service | `Services/Events/FreeFormEventService.swift` **(shared)** | `FreeFormEvent.instruction`, `setInstruction`, `FreeFormEventSaveOutcome`, media teardown, `LiveInstructionOwners` inputs | `FreeFormEventServiceTests` (extended) |
| C14 | Notification handlers | `Services/Notifications/RoutineVisualAidFireHandler.swift` **(shared)** · `FreeFormEventFireHandler.swift` **(shared)** | `RoutineInstructionFireContext`, tap branching, event-presentation gate | `RoutineVisualAidFireHandlerTests`, `FreeFormEventFireHandlerTests` (extended) |
| C15 | Composition | `App/AppCoordinator.swift` **(shared)** · `App/ContentView.swift` **(shared)** | store/loader/factory properties, fired-screen composition, housekeeping enqueue | `AppCoordinatorInstructionTests` (new), `InstructionSurfaceTests` |
| C16 | Tests and gates | `ios/ElderlyAssistantTests/**`, `ios/tools/check-release-log-safety.py` | fakes, fixtures, registry entries | every suite in §11 |
| C17 | Notification content builder | `Services/Notifications/RoutineNotificationContent.swift` (new) | `RoutineNotificationContent` | `RoutineNotificationSchedulerTests` (new; also `NotificationCategoriesTests` untouched) |

Two naming notes, so an implementer does not "fix" them:

- The scheduler suite is **`RoutineNotificationSchedulerTests`**. There is no `RoutineAlarmSchedulerTests` in this repository (the alarm suite is `AlarmSchedulerTests`, a different subsystem). L1's reference to a `RoutineAlarmSchedulerTests` is a phantom; C17's suite is created here.
- `Services/Instructions` is a new directory, not a new component. Every file in it belongs to C01–C07 as tabled.

### 2.1 C01 — Model and display state

**Responsibility.** The value model, its tolerant decode, the write algebra, the display-state derivation, the copy-key mapping, and the typed observability emitter. Pure Swift: no file IO, no AVFoundation, no UIKit (the display state intentionally carries no image).

**Behavioural contract.**

1. `Instruction` decodes from any JSON object without throwing on any *field*; an instruction value that is not an object is discarded by the *parent* (`try? decodeIfPresent(...) ?? nil`), so one corrupt instruction never costs the routine entry or the extras row (§4.6).
2. `kind` is stored as the raw `String`. Known kinds are `text`, `image`, `video` (L1's enum, unchanged); anything else round-trips unchanged (NFR-RIE-006) and is displayable only as `.unsupported`.
3. `isPresent` is the single definition of "this instruction renders something" (§3.2 IF-1). The card, the notification arming path and the fired-screen gate all use it; no second definition may exist.
4. `InstructionPayload` authors known kinds only, trims `text`/`caption`, and nulls fields that do not belong to the chosen kind. A write therefore cannot produce a text instruction with a filename or an image with stray text.
5. `InstructionDraft.resolvedWrite` is `nil` unless `loadState == .loaded && hasChanges && write != nil`. The truth table is a test (§11.3).
6. `InstructionPresentation.state(for:isExpected:)` is the only place a nil/present/expected combination becomes a display state (§3.2 IF-3). Views switch on the result and do no reasoning themselves.
7. `InstructionMessageKey` maps every error, failure and permission problem to exactly one catalogue key. Services never hold copy; views never hold error-to-copy logic.
8. `InstructionObservability` is the only writer of `instruction_*` events, with typed outcomes and no free-text parameter of any kind (§3.6).

**Ownership notes.** `InstructionOwner` (including the SHA-256 event-directory name) is here because both the store and the services key on it; it imports `CryptoKit` and nothing else. `InstructionVideoLimits` et al. are here (P-14) because the store, importer and coordinator all need them and none of them may own the number.

### 2.2 C02 — Video store

**Responsibility.** The only code that touches instruction video bytes. It owns the two roots, the `_pending` staging area, the pre-staging size stat, the protected create-then-stream staging write, the same-volume rename, availability classification, deletion, and the two sweeps.

**Behavioural contract.**

1. `init` resolves paths only. It performs no `FileManager` call (§5.1, pinned by a source scan and by a base-directory-exists check).
2. `stageSynchronously` runs the checks in a fixed order — readable file, size, probe, directory, destination created with complete protection, chunked fill, protection re-verify — and removes everything it created on any failure (§5.2).
3. Nothing outside `_pending` is written until `commit`; `commit` is a single `moveItem` on the same volume and is the only operation that makes bytes visible to the index.
4. `availability` never throws; its four classes are the contract. Only `.available` hands out a URL, and that URL is valid only for the call that received it (§7.4).
5. `delete`/`deleteAll` return `Result<Void, InstructionStorageError>`; `.deleteFailed` is reachable and tested. Absent paths are `.success` (idempotent teardown).
6. `purgePendingDrafts` and `purgeOrphanedOwners(in:live:graceSeconds:)` implement P-6 exactly: `live == nil` means "unknown, do not sweep".
7. No method logs. Failures return typed errors to the caller, which maps them to events.

### 2.3 C03 — Probe and importer

**Responsibility.** The two metadata paths — synchronous (before staging) and asynchronous (after it) — and the async validator with its timeout.

**Behavioural contract.**

1. `AVInstructionVideoProber` uses the synchronous AVFoundation accessors (`isPlayable`, `duration`, `tracks(withMediaType:)`). They emit deprecation warnings on the current SDK; the project sets no warnings-as-errors flag (`ios/project.yml`, `ios/build.sh`), so the build is green. This is the only reason the synchronous pre-staging probe is possible at all, and it is recorded as OI-2.
2. Neither prober decodes a frame, writes a thumbnail, or reads audio. They answer three questions: playable, duration, video track exists.
3. `InstructionVideoImporter.validate` bounds itself with `validationTimeoutSeconds`, cancels the losing branch, and discards the staged file on any failure including timeout. It never mutates the index; the caller owns the transaction.
4. Every error is an `InstructionImportError` case; no `NSError`, no `localizedDescription`, no raw AVFoundation error escapes the file.

### 2.4 C04 — Capture coordinator and adapters

**Responsibility.** The one state machine that turns "the family taps Add video / Record video" into an `AcceptedInstructionVideo` (or a plain failure), and the two system-UI adapters that feed it.

**Behavioural contract.**

1. Single-flight: `pick()` and `record()` are refused while `isBusy`; the state machine is the lock (§7.3).
2. The staging hook is invoked **inside** the system callback, before it returns; this is the callback-scoped URL rule made structural (P-5, §7.4).
3. Permissions are checked before the recorder is presented, in a fixed order (FR-RIE-025): **camera first, microphone second** when both are undetermined. A denial short-circuits the sequence — the later permission is not requested and the recorder is not presented — and becomes a `permissionProblem`, not an `.failed` state, with no error copy beyond the plain permission line. An already-denied or restricted permission is read, never re-prompted. The pick path consults no permission, so library pick still works after either denial.
4. User cancellation is `.cancelled`: no event, no copy, state `.idle`.
5. `consumeAccepted()` transfers ownership of the staged bytes to the editor without discarding; `discardAccepted()` and `cancel()` discard them. Leaving the editor without consuming must discard (`.onDisappear`).
6. The adapters never stage, never validate and never decide; they present, call the hook, call `completion` exactly once, and dismiss.

### 2.5 C05 — Permissions

**Responsibility.** One seam over `AVCaptureDevice` and `AVAudioSession` so the coordinator's decisions are testable without hardware.

**Behavioural contract.**

1. `status(for:)` maps the OS answer to the five-case status; `unavailable` is returned when no camera exists.
2. `request(_:)` returns the post-request status; it never throws and never traps on a denied state. It requests exactly the permission it is given, so the coordinator owns the sequence.
3. The coordinator's recording sequence is the locked order (FR-RIE-025): read camera status; if undetermined, request camera; if that is not granted, stop with `cameraDenied`/`cameraUnavailable` and do not request microphone; otherwise read/request microphone; if that is not granted, stop with `microphoneDenied`; otherwise present the recorder. The order is a tested contract (§11.3 R), not an implementation detail.
4. The seam is `Sendable`; implementations hop to the main actor only where the OS API requires it.

### 2.6 C06 — Playback seam and controller

**Responsibility.** The UI state machine between a tapped video and a playing (or plainly failed) player. It owns both timers and the fallback decision; it owns no AVKit view.

**Behavioural contract.**

1. `start()` is idempotent. It calls `present(url:onEvent:)` once and arms the 0.6 s preflight watchdog.
2. `.preflightPassed` cancels the preflight watchdog and arms the 10 s ready watchdog. `.ready` cancels it and moves to `.playing`. `.failed` or a watchdog expiry moves to `.failed(...)`, dismisses the adapter, and leaves the cover showing the inline fallback.
3. Any event after `.failed` or after `close()` is ignored (a late callback cannot resurrect a dismissed cover).
4. `close()` cancels both timers, dismisses the adapter, and emits `.closed` (only when a player had been presented) with `duration_ms`.
5. The controller never reads the file itself; it trusts the store's `.available` URL and the adapter's preflight. A TOCTOU deletion between the two lands in `.failed(.playerFailed)` and the fallback — the correct user outcome.

### 2.7 C07 — AVKit adapter

**Responsibility.** The only file that constructs `AVPlayer`/`AVPlayerItem` for instructions, and the only reader of playback-time AVFoundation state.

**Behavioural contract.**

1. `present` performs the synchronous `isPlayable` check, constructs the player and item, sets `renderablePlayer`, and emits `.preflightPassed` — all before returning. A false check emits `.failed(.unsupported)` and constructs nothing.
2. `AVPlayerItem.status` is observed with KVO (`.readyToPlay` → `.ready`; `.failed` → `.failed(.playerFailed)`), `AVPlayerItemDidPlayToEndTime` → `.finished`, and `AVAudioSession.interruptionNotification` (`.began`) → `.failed(.interrupted)`. No polling, no `timeControlStatus` loop.
3. `dismiss()` removes every observer, pauses, clears the item and releases the player.
4. The adapter owns no timers, no copy, and no availability logic (P-1).

### 2.8 C08 — Card, cover and editor views

**Responsibility.** The three user-facing surfaces: the instruction card (read-only, used on the fired screens, details and editors), the playback cover, and the editor sheet.

**Behavioural contract.**

1. `InstructionCardView` renders exactly the state `InstructionPresentation` hands it. `.none` renders `EmptyView` — not an empty container, not a spacer (P-9).
2. The card loads its image and its video availability in `.task(id: instruction)`; it never touches the filesystem in `body`.
3. The play affordance is a real button with a 44 pt target; the cover is presented with `.fullScreenCover(item:)` from the card, and the controller is constructed by the cover from `playbackFactory` (no player exists before the tap).
4. The editor is the only surface that mutates a draft; it reports a resolved write to its host and never saves by itself.
5. Every control meets the 44 pt / 18 pt floors and carries an explicit VoiceOver label in every state (§10).
6. The editor's video section renders `instruction.foregroundNote` beneath the Choose/Record controls in both languages: the foreground-only limitation is stated where the family chooses a video (L1 §Playback item 7, FR-RIE-024). The card and the cover make no background-playback claim of their own.

### 2.9 C09 — Routine editor integration

**Responsibility.** Hosts the instruction section inside the existing routine editor sheet and folds the resolved write into the routine save.

**Behavioural contract.**

1. The section shows the current state (`.none` ⇒ an "Add instruction" row; otherwise the card plus "Change"/"Remove").
2. The instruction editor opens as a nested sheet; on its Save the draft's write is held in the routine editor's state until the routine editor saves.
3. The routine editor's Save calls `coordinator.saveRoutineInstruction(_:entryId:)`; a failure keeps the sheet open with the plain copy and does not clear the draft (§11.3).
4. Nothing about the existing title/time/weekday/photo controls changes; the photo section and the instruction section are independent and both survive each other's edits.

### 2.10 C10 — Event editor and detail

**Responsibility.** The instruction section in the free-form event *form*, the read-only card on the event *detail*, and the card on the event's fired screen.

**Behavioural contract.**

1. The form owns an `InstructionDraft` and the view holds an optional `AcceptedInstructionVideo` beside it (not inside the form's persisted draft). The section uses the same `InstructionEditorView` as routines.
2. `save` returns `FreeFormEventSaveOutcome?`. `nil` means the event itself was not saved: the form stays open, the draft is intact, and the routine-level copy applies. A non-nil outcome always closes the form — even when `instructionSaved == false` — because the event exists and re-entering the form would risk a duplicate.
3. A partial outcome (`instructionSaved == false`) surfaces `instruction.savePartial` once on the detail screen, with the existing edit path as the retry. It is not a modal and not an error dialog.
4. The detail renders the card under the photo and above the info card. It uses the same `InstructionCardView`; the detail never shows `.removed` (it reads the current instruction, and absence is `.none`).
5. The fired event screen adds the card below the title. `.none` renders `EmptyView`, so an event with no instruction fires exactly as today.

### 2.11 C11 — Routine scheduler

**Responsibility.** The routine owner's write seam, its media teardown, and the strict read accessor the sweep needs.

**Behavioural contract.**

1. `setInstruction(_:entryId:) -> Result<Void, InstructionWriteError>` performs the ordered transaction of §5.6 and then calls the existing `persistAndReschedule()` once. No new timer, no new scheduling path.
2. `persistAndReschedule` emits `entry_instruction_updated` (P-3) **only when the write succeeded and the instruction actually changed**, with `entry_id_hash`, `kind`, `count` — no text, no filename, no caption.
3. `regenerateWindow` passes `hadInstruction: entry.instruction?.isPresent == true` to the notification scheduler for every occurrence it arms, so a re-arm refreshes the payload.
4. `removeEntry` deletes the routine's video owner directory in addition to the existing photo deletion; a delete failure is reported as an event and left to the sweep (§5.5).
5. A failed write leaves the entry, its previous instruction, its previous media and its scheduled notifications exactly as they were.
6. `entriesIfReadable() -> [RoutineEntry]?` is the read accessor the sweep needs; it delegates to `RoutineStore.loadEntriesIfReadable()` (IF-33), which returns nil on any `storage.read` failure — including the first-run absent key. The existing `loadEntries()` (which returns `[]` on failure) is untouched and must **not** be used to build a live set.

### 2.12 C12 — Extras store

**Responsibility.** The encrypted side index gains one optional field and loses one wholesale-rebuild bug.

**Behavioural contract.**

1. `EventExtras` gains `var instruction: Instruction? = nil`; existing construction sites compile unchanged (R-6).
2. `setInstruction(_:forEventId:) -> Bool` upserts the row and preserves `photoFilename`. `setPhotoFilename` preserves `instruction` (P-4, the pinned fix).
3. `snapshot() -> [String: EventExtras]?` returns `nil` when the payload cannot be decoded — the *only* read accessor that distinguishes "empty" from "unreadable". `all` and `eventIds` keep their existing tolerant behaviour and are not used for sweep decisions.
4. Decode stays tolerant: a malformed `instruction` value is dropped, not propagated (§4.6).
5. Membership is unchanged: a row exists iff the event is ours, whether or not it has a photo or an instruction.

### 2.13 C13 — Free-form event service

**Responsibility.** The event owner's read/write seam, the save outcome, and the event-side media teardown.

**Behavioural contract.**

1. `event(withId:)` — the shipping service read at `FreeFormEventService.swift:318` — populates the composite's `instruction` from the index; a nil row and a row without an instruction both yield `nil` on the returned event. The coordinator's existing `freeFormEvent(id:)` wrapper calls it, so there is no second read path.
2. `setInstruction(_:forEventId:) -> Result<Void, InstructionWriteError>` performs the same ordered transaction as C11 and emits `event_instruction_updated` on a real change.
3. `save(_:editing:) -> FreeFormEventSaveOutcome?` keeps today's contract for the event itself and adds: when the draft carries a resolved instruction write, it commits the media and stores the instruction **after** the event row exists; a failure there yields `instructionSaved == false` and leaves the event saved. A failed *event* save stops before any instruction work.
4. `delete(eventId:)` removes the extras row, the photo and the video owner directory. The `upcoming` vanish branch does the same after a successful `extras.remove`; a failed index removal leaves both index and media in place (today's retry behaviour).
5. No copy, no formatting, no notification work here.

### 2.14 C14 — Notification handlers

**Responsibility.** The two `NotificationEventHandling` conformers learn about instructions without changing their always-false contract or the facade's first-claim behaviour.

**Behavioural contract.**

1. Neither handler gains a dependency: each reads the instruction off the value it already looks up (`RoutineEntry.instruction`, `FreeFormEvent.instruction`). No handler holds a store, and there is no second read path to disagree with the first.
2. **Routine `willPresent`:** type gate `routine_reminder` → entry lookup → present iff `!entry.visualAids.isEmpty || entry.instruction?.isPresent == true || context.hadInstruction`. The foreground sink receives `(entry, RoutineInstructionFireContext(hadInstruction:firedAt:))`. Returns `false`.
3. **Routine `didReceive`:** only the default action (`UNNotificationDefaultActionIdentifier`), and only when `had_instruction == true` (P-13). The entry id comes from `userInfo["entry_id"]` and `firedAt` from `response.notification.date`; the entry itself is resolved once, and may be nil. Entry exists and instruction present ⇒ present; entry exists and instruction gone ⇒ present with `.removed`; **entry gone ⇒ present the `.unavailable` notice** (`instruction.reminderUnavailable`, Close, no title/time) through the tap sink `onInstructionTap(entryId:entry:firedAt:)` — an owner deleted after arming is a notice, never a dead tap (FR-RIE-019, L1 D14, review-l1 B-2). A missing key (pre-upgrade) reads as `false`. Returns `false` — the system must still handle the tap.
4. **Event `willPresent`:** the photo gate becomes `event.photoFilename != nil || event.instruction?.isPresent == true`. No `had_instruction` is added to event payloads: the event's tap already opens the detail, where absence renders `.none`, so there is no dead end to defend against.
5. **Event `didReceive`:** unchanged (opens the detail for the default action and `OPEN_EVENT`). Returns `false`.
6. Neither handler presents from a background thread: the sink hop remains `DispatchQueue.main.async`.

### 2.15 C15 — Composition

**Responsibility.** Wire the new seams into `AppCoordinator`, compose the fired routine screen, and enqueue the launch sweep. No behaviour lives here beyond wiring; every decision is delegated.

**Behavioural contract.**

1. New coordinator properties (all `let`, all constructed in `init` without file IO): `instructionVideoStore`, `instructionVideoProber`, `instructionVideoInspector`, `instructionVideoImporter`, `instructionVideoPermissions`, `instructionCaptureConfiguration`, `instructionPlaybackConfiguration`, `instructionEvents`, `routineInstructionImageLoader`, `eventInstructionImageLoader`. Factories (lazy, host-view-dependent): `makeInstructionVideoPicker()`, `makeInstructionVideoRecorder()`, `makeInstructionPlayback(url:title:)`.
2. `saveRoutineInstruction(_:entryId:) -> Result<Void, InstructionWriteError>`, `saveFreeFormEvent(_:editing:) -> FreeFormEventSaveOutcome?`, `presentRoutineVisualAids(for:context:)`, `presentRoutineInstructionTap(entryId:entry:firedAt:)` and `dismissFiredRoutineVisualAids()` keep one entry point each; reads go through the model values the views already hold, and views never reach a store.
3. `presentRoutineVisualAids(for:context:)` builds `FiredRoutineVisualAids.Content.reminder` (entry id, localized title, aids, `instruction`, `expectsInstruction`, `firedAt`). `presentRoutineInstructionTap(entryId:entry:firedAt:)` builds `.reminder` when the entry resolves and `.unavailable` when it does not; a presentation already showing the same entry is not replaced (L1's dedupe rule), and `.unavailable` carries no title or time.
4. `ContentView` keeps the overlay shape at `:65–73`. `RoutineVisualAidOverlay` switches on `FiredRoutineVisualAids.Content`: `.reminder` renders the existing `ReminderVisualAidScreen` with its title, aids, the instruction card, and a footer whose time line is present **only when the D6 gate holds** — `instruction?.isPresent == true || expectsInstruction` (§4.10); otherwise it passes `timeText == nil` and today's screen is unchanged (NFR-RIE-010). `.unavailable` renders the same screen with `aids: []`, `title: L10n.str("instruction.reminderUnavailable", locale:)`, an `EmptyView` footer and Close, and carries no time. Nothing else moves.
5. The launch sweep is enqueued on the existing `modelHousekeepingQueue` (§5.5): the live set is composed on the main actor first, then the file work runs off-main; the results are one event each.
6. `AppCoordinator` gains no timer, no notification registration and no new permission request at launch.

### 2.16 C16 — Tests and gates

**Responsibility.** The suites, fakes and registrations that make every claim above falsifiable. The mapping is §11; the gate registration is §6.5. Two structural rules:

1. New fakes live beside the suites that use them and are `private` where only one suite needs them (`InstructionPlaybackSpy`, `InstructionCaptureSpy`, `InstructionFileManagerSpy`, `InstructionStagingFileOpsSpy`).
2. No test writes outside its own temporary directory; the store's `fileManager`/`baseDirectory`/`fileOps` parameters are the only injection points (`InstructionVideoStore(fileManager:baseDirectory:now:fileOps:)`), and every test passes a base directory.

### 2.17 C17 — Notification content builder

**Responsibility.** One pure builder for a routine reminder's content, extracted from `UNRoutineNotificationScheduler.scheduleRoutineReminder` so the payload — including `had_instruction` — is testable without a notification centre.

**Behavioural contract.**

1. `RoutineNotificationContent.make(...) -> UNMutableNotificationContent` sets: localized title, body = entry title, default sound, `userInfo` with `occurrence_id`, `entry_id`, `type`, and `had_instruction: Bool`, and at most the existing first-photo attachment (via an injected attachment factory).
2. **No instruction content** enters the payload: no text, no caption, no filename, no URL, no attachment. `had_instruction` is a boolean and nothing more (constitution: PII-free).
3. No category, no action, no interruption level change.
4. The scheduler delegates to it; the existing `notificationIdentifier(for:)` and scoped cancels are untouched.

### 2.18 Wiring at a glance

| Seam | Constructed in | Construction IO | Held by |
|---|---|---|---|
| `InstructionVideoStore` | `AppCoordinator.init` | none (path resolution only) | coordinator; injected into importer, capture coordinator, services |
| `AVInstructionVideoProber` / `Inspector` | `AppCoordinator.init` | none | importer; capture coordinator (prober closure) |
| `InstructionVideoImporter` | `AppCoordinator.init` | none | capture coordinator; event form path |
| `AVFoundationInstructionPermissions` | `AppCoordinator.init` | none | capture coordinator |
| `InstructionObservability` | `AppCoordinator.init` | none | every seam above |
| `InstructionVideoCaptureCoordinator` | lazily per editor presentation | none | the editor sheet's `@StateObject` |
| `PHPickerInstructionVideoPicker` / `UIImagePickerInstructionVideoRecorder` | lazily, per presentation | none | the sheet's host resolver |
| `AVKitInstructionVideoPlayer` | per playback | none | `InstructionPlaybackCover`'s controller |
| `InstructionPlaybackController` | per playback, from `makeInstructionPlayback` | none | the cover's `@StateObject` |

---

## Interfaces

### 3.1 Conventions

1. **No signature has an untyped error channel.** Every method that can fail returns `Result<T, ConcreteError>`, or returns a sum type whose cases *are* the failures (`InstructionPlaybackAvailability`), or drives a published `State` whose `.failed` case carries the failure (`InstructionPlaybackController`, `InstructionVideoCaptureCoordinator`). No new API returns `any Error`, `NSError`, or a `Bool` where "why" matters. **One deliberate, recorded exception (OI-1):** `EventExtrasStore.setInstruction -> Bool` (IF-26) keeps the shipping store's `Bool` convention; the service seam translates `false` to `.persistenceFailed` before any caller sees it, so the explicit-error-type rule is satisfied at the boundary that matters (m-2).
2. **`Void` returns are teardown only**, and only where a failure cannot change the user's outcome: `InstructionVideoPlaying.dismiss()`, `InstructionVideoCaptureCoordinator.cancel()`, the two image-store deletes that already ship (`VisualAidStore.delete/deleteAll`, `ContactPhotoStore.delete(named:)`), and `InstructionVideoStore.purge…` is *not* in this list (it returns a count or an error). A `Void` teardown may still be observed, never reported as success.
3. **Optional returns are "nothing", never "failed".** `InstructionPayload.filename == nil` means "media not yet committed" (transient, draft only). `[RoutineEntry]?` and `[String: EventExtras]?` mean "unreadable" — deliberately distinct from `[]` (P-6). No other new API uses `T?` to signal failure.
4. **Isolation is declared on the type, not inferred at the call site.** Main-actor types are annotated; everything crossing a queue boundary is `Sendable`. `InstructionVideoStore` is `@unchecked Sendable` for one stated reason (§7.1).
5. **Timeouts are injected, never read from the clock inside a body.** Each one is a parameter with a default from its configuration struct (§9). A test can replace it; production never passes one.
6. **Equatable everywhere a test compares or a view diffs**: all model values, all error types, all state enums.
7. **No copy in services.** Every user-visible string is `InstructionMessageKey` output resolved by a view through `L10n`/`.locale`. Two view-layer exceptions exist because no view resolves them: the notification title, resolved by the scheduler through `L10n.str` because a notification has no view, and the fired-screen notice title `instruction.reminderUnavailable`, resolved by `RoutineVisualAidOverlay` through `L10n.str` (the overlay is a view; §4.11).
8. **No free text in events.** Emitters take typed errors and closed-vocabulary outcomes; `kind` is `InstructionKind.reportable(_:)`, so an unknown decoded kind logs as `"unknown"` and never as arbitrary bytes.

### 3.2 Interface register

| ID | Declaration (abbreviated) | Error channel | Isolation | Bound | Owner |
|---|---|---|---|---|---|
| IF-1 | `Instruction.isPresent: Bool` | none (pure) | nonisolated | — | C01 |
| IF-2 | `InstructionDraft.resolvedWrite` / `.resolvedCommit` | none (pure) | nonisolated | — | C01 |
| IF-3 | `InstructionPresentation.state(for:isExpected:)` | none (pure) | nonisolated | — | C01 |
| IF-4 | `InstructionMessageKey.for…` | none (pure) | nonisolated | — | C01 |
| IF-5 | `InstructionVideoStore.stageSynchronously(…)` | `InstructionImportError` | nonisolated, **main-thread only** by contract | none (callback-scoped) | C02 |
| IF-6 | `InstructionVideoStore.commit(…)` | `InstructionStorageError` | nonisolated | — | C02 |
| IF-7 | `InstructionVideoStore.discard(…)` | `InstructionStorageError` | nonisolated | — | C02 |
| IF-8 | `InstructionVideoStore.delete(…)` | `InstructionStorageError` | nonisolated | — | C02 |
| IF-9 | `InstructionVideoStore.deleteAll(for:)` | `InstructionStorageError` | nonisolated | — | C02 |
| IF-10 | `InstructionVideoStore.availability(…)` | value-encoded (`rejected/missing/unreadable`) | nonisolated | — | C02 |
| IF-11 | `InstructionVideoStore.purgePendingDrafts()` | `InstructionStorageError` | nonisolated, off-main | — | C02 |
| IF-12 | `InstructionVideoStore.purgeOrphanedOwners(in:live:graceSeconds:)` | `InstructionStorageError` | nonisolated, off-main | `orphanGraceSeconds` 60 s | C02 |
| IF-13 | `InstructionVideoProbing.probe(url:)` | `InstructionImportError` | nonisolated | — | C03 |
| IF-14 | `InstructionVideoInspecting.inspect(url:)` | `InstructionImportError` | `async`, nonisolated | — | C03 |
| IF-15 | `InstructionVideoImporting.validate(_:limits:)` | `InstructionImportError` | `async`, nonisolated | `validationTimeoutSeconds` 20 s | C03 |
| IF-16 | `InstructionVideoPicking.presentVideoPicker(makeStagedCopy:completion:)` | `InstructionImportError` via both closures | `@MainActor` | none (user-paced) | C04 |
| IF-17 | `InstructionVideoRecording.presentRecorder(maximumDurationSeconds:quality:makeStagedCopy:completion:)` | `InstructionImportError` via both closures | `@MainActor` | recording capped at 180 s; picker cap is user-paced | C04 |
| IF-18 | `InstructionPermissionRequesting.status/request` | value-encoded status | `Sendable` | — | C05 |
| IF-19 | `InstructionVideoPlaying.present(url:onEvent:)/dismiss()` | events (`.failed(InstructionPlaybackFailure)`) | `@MainActor` | adapter own none | C06/C07 |
| IF-20 | `InstructionPlaybackController.start()/close()` | `State.failed(InstructionPlaybackFailure)` | `@MainActor` | `preflightTimeoutSeconds` 0.6 s, `readyWatchdogSeconds` 10 s | C06 |
| IF-21 | `InstructionImageLoading.loadImage(filename:)` | `InstructionImageFailure` | `@MainActor` | — | C01/C08 |
| IF-22 | `RoutineScheduler.setInstruction(_:entryId:)` | `InstructionWriteError` | main actor (as today) | — | C11 |
| IF-23 | `RoutineScheduler.entriesIfReadable()` (delegates to IF-33) | `nil` = unreadable | main actor | — | C11 |
| IF-24 | `FreeFormEventService.setInstruction(_:forEventId:)` | `InstructionWriteError` | nonisolated (as today) | — | C13 |
| IF-25 | `FreeFormEventService.save(_:editing:)` | `nil` = event not saved; `instructionSaved` = partial | nonisolated (as today) | — | C13 |
| IF-26 | `EventExtrasStore.setInstruction(_:forEventId:)` | `Bool` — **deliberate recorded exception (OI-1, m-2)**: the shipping store convention; translated to `InstructionWriteError.persistenceFailed` at the service seam | nonisolated | — | C12 |
| IF-27 | `EventExtrasStore.snapshot()` | `nil` = unreadable | nonisolated | — | C12 |
| IF-28 | `InstructionVideoCaptureCoordinator.pick()/record()/cancel()/consumeAccepted()/discardAccepted()` | `State.failed`, `permissionProblem` | `@MainActor` | as IF-15/17 | C04 |
| IF-29 | `InstructionObservability.*` | none (fire-and-forget) | `Sendable` | — | C01 |
| IF-30 | `RoutineNotificationContent.make(…)` | none (pure builder; attachment factory may return nil) | nonisolated | — | C17 |
| IF-31 | `RoutineVisualAidFireHandler.init(entryLookup:onFire:onInstructionTap:)`, `FreeFormEventFireHandler` | none (`Bool` always false, by contract) | nonisolated sink hop | — | C14 |
| IF-32 | Coordinator seams: `saveRoutineInstruction`, `saveFreeFormEvent`, `presentRoutineVisualAids`, `presentRoutineInstructionTap`, `dismissFiredRoutineVisualAids`, factories | `Result` / `Outcome?` as above | `@MainActor` | — | C15 |
| IF-33 | `RoutineStore.loadEntriesIfReadable()` | `nil` = unreadable (any `storage.read` failure, including a missing key) | main actor (callers) | — | C11 |

### 3.3 Error taxonomy

Six concrete error types, one per failure domain. Nothing else is thrown or returned as an error by this feature.

```swift
/// C03 — everything that can go wrong between "the family chose a file"
/// and "the bytes are validated and staged". `Equatable` so tests compare.
enum InstructionImportError: Error, Equatable {
    case unreadableSource          // not a file URL, absent, or unreadable
    case unsupportedFormat         // not playable, or no video track
    case tooLong                   // rounded duration > maxDurationSeconds
    case tooLarge                  // byte size > maxBytes
    case validationTimedOut        // the async inspector exceeded its bound
    case writeFailed(InstructionStorageError)   // staging/commit failure
    case cancelled                 // the person dismissed the picker/recorder
}

/// C02 — the store's failures. `.deleteFailed` is reachable (N-1) and
/// applies to VIDEO only; the image stores keep their Void best-effort API.
enum InstructionStorageError: Error, Equatable {
    case invalidOwner              // owner directory name is not a plain component
    case stagingFailed             // _pending or the destination file could not be created, or the streamed fill failed
    case protectionFailed          // a weaker-than-.complete class was reported; bytes deleted
    case commitFailed              // the same-volume rename failed; _pending left for the sweep
    case deleteFailed              // an existing path could not be removed, or a name was refused before a path was built
    case purgeFailed               // a sweep stopped early; the count is partial
}

/// C11/C13 — the write seam's failures. Behaviour on every case is
/// "nothing changed": the previous instruction and its media are intact.
enum InstructionWriteError: Error, Equatable {
    case ownerNotFound             // the routine entry or extras row no longer exists
    case unresolvedPayload         // a media payload with no pending media and no filename
    case mediaWriteFailed(InstructionStorageError)
    case persistenceFailed         // the store/index refused the new payload
}

/// C06 — playback's failures. All of them render one plain line.
enum InstructionPlaybackFailure: Error, Equatable {
    case unsupported               // preflight said not playable
    case playerFailed              // AVPlayerItem failed
    case interrupted               // the system stopped playback (audio session/call)
    case timedOut                  // the ready watchdog expired
}

/// C01/C08 — image decoding's failures.
enum InstructionImageFailure: Error, Equatable {
    case rejectedFilename          // the bare-name guard refused
    case missingFile
    case unreadableFile
}
```

Mapping table (the only permitted user copy and the only permitted `error_code` tokens):

| Error | User copy key | `error_code` token(s) |
|---|---|---|
| `.unreadableSource` | `instruction.video.unreadable` | `unreadable_source` |
| `.unsupportedFormat` | `instruction.video.unreadable` | `unsupported_format` |
| `.tooLong` | `instruction.video.tooLong` | `too_long` |
| `.tooLarge` | `instruction.video.tooLarge` | `too_large` |
| `.validationTimedOut` | `instruction.video.unreadable` | `validation_timeout` |
| `.writeFailed` | `instruction.video.saveFailed` | `write_failed` |
| `.cancelled` | **none** (silent) | `cancelled` (event only, never copy) |
| `.invalidOwner` | `instruction.saveFailed` | `invalid_owner` |
| `.stagingFailed` | `instruction.video.saveFailed` | `staging_failed` |
| `.protectionFailed` | `instruction.video.saveFailed` | `protection_failed` |
| `.commitFailed` | `instruction.video.saveFailed` | `commit_failed` |
| `.deleteFailed` | none (logged only; the next sweep retries) | `delete_failed` |
| `.purgeFailed` | none (logged only) | `purge_failed` |
| `.ownerNotFound` | `instruction.removed` | `owner_not_found` |
| `.unresolvedPayload` | `instruction.saveFailed` | `unresolved_payload` |
| `.mediaWriteFailed` | inner storage mapping | `media_write_failed` |
| `.persistenceFailed` | `instruction.saveFailed` | `persistence_failed` |
| `.unsupported` | `instruction.video.unavailable` | `unsupported` |
| `.playerFailed` | `instruction.video.unavailable` | `player_failed` |
| `.interrupted` | `instruction.video.unavailable` | `interrupted` |
| `.timedOut` | `instruction.video.unavailable` | `timed_out` |
| `.rejectedFilename` | `instruction.image.unavailable` | — (image events are outcome-only) |
| `.missingFile` | `instruction.image.unavailable` | — |
| `.unreadableFile` | `instruction.image.unavailable` | — |

Every token is lowercase snake_case, identifier-shaped, ≤ 19 characters, no unbroken run over 32 — inside `LogSanitiser`'s error-code shape bound. No OS error domain, code or description is ever logged.

### 3.4 C01 declarations — model, draft, presentation, copy, configuration

```swift
// Services/Instructions/Instruction.swift

enum InstructionKind: String, CaseIterable, Codable, Equatable {
    case text, image, video        // L1's locked raw values; "text" is the persisted kind
    /// The ONLY way a raw kind reaches an event field: known raw values
    /// pass, anything else becomes "unknown" (closed vocabulary).
    static func reportable(_ raw: String) -> String
}

struct Instruction: Codable, Equatable {
    var kind: String                 // raw; unknown values round-trip (NFR-RIE-006)
    var text: String?
    var caption: String?
    var filename: String?            // bare name inside the owner's store
    var url: String?                 // decoded/encoded only; v1 never authors it

    init(kind: String, text: String? = nil, caption: String? = nil,
         filename: String? = nil, url: String? = nil)
    init(from decoder: Decoder) throws      // no field ever throws (§4.6)
    func encode(to encoder: Encoder) throws // nil fields omitted

    var knownKind: InstructionKind? { get }
    var isPresent: Bool { get }             // IF-1, rules in §3.4.1
    var trimmedText: String? { get }        // nil when blank
    var trimmedCaption: String? { get }
}

struct InstructionPayload: Equatable {
    let kind: InstructionKind               // known kinds only
    let text: String?
    let caption: String?
    let filename: String?                   // nil = media pending commit
    init(kind: InstructionKind, text: String? = nil,
         caption: String? = nil, filename: String? = nil)
    var instruction: Instruction { get }    // url nil; irrelevant fields nil
}
```

`InstructionPayload` is L1's **struct** shape (a value with named fields, not an enum): the kind tag decides which fields are meaningful, and `instruction` nulls the rest (§4.2). L1's `existingFilename`/`pendingImage`/`pendingVideo` are not fields here; the one `filename` plus `InstructionPendingMedia` on `InstructionCommit` carry the same information without letting a payload smuggle bytes (R-7).

```swift
enum InstructionWrite: Equatable {          // L1's type, unchanged
    case set(InstructionPayload)
    case remove
}

enum InstructionPendingMedia: Equatable {
    case image(UIImage)
    case video(AcceptedInstructionVideo)
}

struct InstructionCommit: Equatable {       // R-7: the host handoff
    let write: InstructionWrite
    let pendingMedia: InstructionPendingMedia?
}

struct InstructionDraft: Equatable {
    enum LoadState: Equatable { case loading, loaded, failed }
    private(set) var loadState: LoadState
    private(set) var hasChanges: Bool
    private(set) var write: InstructionWrite?
    private(set) var pendingMedia: InstructionPendingMedia?
    private(set) var payload: InstructionPayload?   // editable values
    private(set) var original: Instruction?

    static func loading() -> InstructionDraft
    static func loaded(instruction: Instruction?) -> InstructionDraft
    static func failed() -> InstructionDraft

    var resolvedWrite: InstructionWrite? { get }    // IF-2, truth table §11.3
    var resolvedCommit: InstructionCommit? { get }

    mutating func chooseKind(_ kind: InstructionKind)   // clears fields the kind cannot carry
    mutating func setText(_ text: String)
    mutating func setCaption(_ caption: String)
    mutating func setExistingMedia(filename: String, caption: String?)
    mutating func setPendingImage(_ image: UIImage, caption: String?)
    mutating func setPendingVideo(_ video: AcceptedInstructionVideo, caption: String?)
    mutating func removeInstruction()                   // write = .remove, pendingMedia = nil
    mutating func revert()                              // back to `original`, hasChanges = false
}

enum InstructionRoot: String, CaseIterable, Equatable {
    case routines = "InstructionVideos"
    case events   = "EventInstructionVideos"
}

enum InstructionOwner: Hashable, Equatable {
    case routine(UUID)
    case event(String)                       // EventKit identifier
    var root: InstructionRoot { get }
    var directoryName: String { get }        // uuidString / "ev-" + first 32 hex of SHA-256(utf8 id)
    static func eventDirectoryName(for eventId: String) -> String
}

enum InstructionFilename {
    static func isPlain(_ name: String) -> Bool           // non-empty, no "/" or "\\", and not "." or ".."
    static func sanitizedExtension(_ ext: String) -> String  // [a-z0-9]{1,8} else "mov"
}

enum InstructionVideoDuration {
    static func roundedSeconds(_ seconds: Double) -> Int  // .toNearestOrAwayFromZero; 180.2 → 180
    static func exceedsLimit(_ seconds: Double, limit: TimeInterval) -> Bool
}
```

**3.4.1 `isPresent` rules** (IF-1; the single definition):

| Stored shape | `isPresent` |
|---|---|
| `kind == "text"` | trimmed `text` non-empty |
| `kind == "image"` / `"video"` | `filename` non-empty |
| unknown `kind` | **any** of trimmed `text`, trimmed `caption`, `filename`, `url` non-empty |
| anything else (e.g. blank kind, all fields empty) | `false` |

The unknown-kind rule is forward tolerance, not generosity: a future link-only instruction renders the plain `.unsupported` note rather than vanishing silently. An image/video with no filename is malformed and renders nothing — the store is the security boundary and never sees it.

```swift
// Services/Instructions/InstructionDisplayState.swift

enum InstructionDisplayState: Equatable {
    case none                                   // render EmptyView
    case text(text: String)
    case image(filename: String, caption: String?)
    case video(filename: String, caption: String?)
    case unsupported(text: String?)             // unknown kind + the plain note
    case removed                                // expected at fire time, now absent
}

enum InstructionPresentation {
    static func state(for instruction: Instruction?, isExpected: Bool) -> InstructionDisplayState
}
```

`state(for:isExpected:)` rules: `nil` or `!isPresent` ⇒ `.removed` when `isExpected`, else `.none`; known text/image/video map to their case; unknown ⇒ `.unsupported`. No other input combination is legal, and the function is total.

```swift
// Services/Instructions/InstructionDisplayState.swift (continued)

enum InstructionMessageKey {
    static func forImport(_ error: InstructionImportError) -> String?     // nil only for .cancelled
    static func forPlayback(_ failure: InstructionPlaybackFailure) -> String
    static func forImage(_ failure: InstructionImageFailure) -> String
    static func forWrite(_ error: InstructionWriteError) -> String
    static func forPermission(_ problem: InstructionPermissionProblem) -> String
}
```

```swift
// Services/Instructions/InstructionConfiguration.swift   (P-14)

struct InstructionVideoLimits: Equatable {
    let maxDurationSeconds: TimeInterval        // 180
    let maxBytes: Int64                         // 209_715_200 (200 MiB)
    static let standard: InstructionVideoLimits
}

struct InstructionVideoConfiguration: Equatable {
    let limits: InstructionVideoLimits
    let validationTimeoutSeconds: TimeInterval  // 20
    let orphanGraceSeconds: TimeInterval        // 60
    let stagingChunkBytes: Int                  // 1_048_576 (1 MiB); D18 chunked stream
    static let standard: InstructionVideoConfiguration
}

enum InstructionRecordingQuality: String, Equatable { case high, medium }

struct InstructionCaptureConfiguration: Equatable {
    let video: InstructionVideoConfiguration
    let recordingQuality: InstructionRecordingQuality   // .high
    static let standard: InstructionCaptureConfiguration
}
```

### 3.5 C02–C07 declarations — bytes, metadata, capture, permissions, playback, images

```swift
// Services/Instructions/InstructionVideoStore.swift

enum InstructionPlaybackAvailability: Equatable {
    case available(URL)          // exists, is a regular file, is readable
    case rejectedFilename        // bare-name guard refused
    case missingFile             // absent
    case unreadableFile          // exists but attributes/readability say no
}

struct StagedInstructionVideo: Equatable {
    let draftId: UUID
    let root: InstructionRoot
    let stagedURL: URL           // <root>/_pending/<draftId>/payload.<ext>
    let byteCount: Int64         // the step-2 source size; the stream must deliver exactly this
    let metadata: InstructionVideoMetadata
    let sourceExtension: String  // sanitized
    let stagedAt: Date
}

struct AcceptedInstructionVideo: Equatable {
    let staged: StagedInstructionVideo
    let validatedAt: Date
}

/// C02 — the store's only staging file-operation seam (declared in
/// `InstructionVideoStore.swift`; no new source file). Production is
/// `SystemInstructionStagingFileOps`: `createFile(contents: nil,
/// attributes: [.protectionKey: .complete])`, an attribute read, and a
/// 1 MiB `FileHandle` read/write loop that closes both handles on every
/// path. A test double records one ordered call log, reports a weaker
/// protection class at creation or after the stream, and fails the n-th
/// read or write — which is what makes the create-before-bytes order and
/// the fail-closed cleanup real (§11.3 E).
protocol InstructionStagingFileOps: Sendable {
    /// Creates the destination with NO bytes and the complete-protection attribute.
    func createProtectedFile(at url: URL) -> Bool
    /// The reported class, or nil when the platform reports none (R-5).
    func protectionClass(at url: URL) -> FileProtectionType?
    /// Streams the source into the existing file in bounded chunks.
    /// `.tooLarge` when the cumulative count exceeds `maxBytes`;
    /// `.unreadableSource` on a read failure; `.writeFailed(.stagingFailed)`
    /// on a write failure. Returns the bytes delivered.
    func copyChunks(from source: URL, to destination: URL,
                    maxBytes: Int64, chunkBytes: Int) -> Result<Int64, InstructionImportError>
}

struct SystemInstructionStagingFileOps: InstructionStagingFileOps { init() }

final class InstructionVideoStore: @unchecked Sendable {
    /// Resolves both roots and nothing else — zero FileManager calls (§5.1).
    /// `fileOps` is the staging seam (create-before-bytes, chunked fill,
    /// attribute read); the production default is the system implementation.
    init(fileManager: FileManager = .default,
         baseDirectory: URL? = nil,
         now: @escaping () -> Date = Date.init,
         fileOps: InstructionStagingFileOps = SystemInstructionStagingFileOps())

    /// IF-5. MUST be called on the main thread from inside a system
    /// callback, before the callback returns (the callback-scoped URL rule).
    /// `probe` is the synchronous pre-staging inspector supplied by C03.
    /// The destination is created with `.completeFileProtection` before any
    /// byte, filled by a bounded chunked stream of `chunkBytes`, and its
    /// attribute is re-verified after the stream; any failure deletes the
    /// partial file and the draft directory (§5.2–5.3).
    func stageSynchronously(
        from sourceURL: URL,
        into root: InstructionRoot,
        limits: InstructionVideoLimits,
        chunkBytes: Int = InstructionVideoConfiguration.standard.stagingChunkBytes,
        draftId: UUID = UUID(),
        probe: (URL) -> Result<InstructionVideoMetadata, InstructionImportError>
    ) -> Result<StagedInstructionVideo, InstructionImportError>

    /// IF-6. Same-volume rename; returns the stored BARE filename.
    func commit(_ staged: StagedInstructionVideo,
                for owner: InstructionOwner) -> Result<String, InstructionStorageError>

    /// IF-7. Removes the draft directory. Absent ⇒ .success.
    func discard(_ staged: StagedInstructionVideo) -> Result<Void, InstructionStorageError>

    /// IF-8. Removes one stored file. Absent ⇒ .success.
    func delete(_ filename: String,
                for owner: InstructionOwner) -> Result<Void, InstructionStorageError>

    /// IF-9. Removes the owner's whole directory. Absent ⇒ .success.
    func deleteAll(for owner: InstructionOwner) -> Result<Void, InstructionStorageError>

    /// IF-10. Never throws; the four cases are the contract.
    func availability(filename: String,
                      owner: InstructionOwner) -> InstructionPlaybackAvailability

    /// IF-11/IF-12. Off-main. `live == nil` ⇒ unreadable owner list ⇒
    /// return .success(0) without deleting anything (P-6).
    func purgePendingDrafts() -> Result<Int, InstructionStorageError>
    /// One root per call: the coordinator passes that root's live set, so
    /// "unknown" is expressible per root (P-6).
    func purgeOrphanedOwners(in root: InstructionRoot,
                             live: Set<InstructionOwner>?,
                             graceSeconds: TimeInterval) -> Result<Int, InstructionStorageError>

    /// Existence-checked URL for a playback handoff; nil when unsafe/absent.
    func fileURL(filename: String, owner: InstructionOwner) -> URL?
}
```

**Filename guard (N-4).** `InstructionFilename.isPlain(_:)` is exactly `!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")`. It runs **before any URL is built from a payload-supplied name**: `availability` returns `.rejectedFilename`, `fileURL` returns `nil`, `delete` returns `.deleteFailed` without touching the disk (one event, no copy), and both image loaders return `.rejectedFilename`. The write path never consumes a name (it mints `instruction-<draftId>.<ext>`), so no payload name can reach it; `commit` still runs the same guard over the name it is about to use as a cheap invariant, and the store suite pins that the minted shape always passes. The non-empty clause is the safety-critical one: `URL.appendingPathComponent("")` resolves to the owner directory, so a guard without it would let `delete(_:for:)` remove the directory and every live byte inside it. The store is the security boundary; the model deliberately does not sanitise (§4.1 rule 2).

Failure and recovery, per method: `stageSynchronously` returns `.tooLarge`/`.tooLong`/`.unsupportedFormat`/`.unreadableSource` before creating anything, and `.tooLarge` (a cumulative cap breach while streaming), `.unreadableSource` (a read failure or a delivered count that differs from the step-2 size) or `.writeFailed(.stagingFailed|.protectionFailed)` after deleting the partial file and the draft directory it created — the caller shows one plain line and leaves the previous instruction untouched. `commit` failure leaves the staged bytes for the sweep and the index unchanged. `discard`/`delete`/`deleteAll` failures are logged as events and retried by the launch sweep; no user action is required because the owner no longer references the bytes (or still does, in which case the delete was for a *replaced* old file and the new one is live). `availability` never fails. `purge…` failures are logged; the next launch retries.

```swift
// Services/Instructions/InstructionVideoInspecting.swift

struct InstructionVideoMetadata: Equatable {
    let durationSeconds: Double
    let hasVideoTrack: Bool
    let isPlayable: Bool
}

protocol InstructionVideoProbing: Sendable {
    func probe(url: URL) -> Result<InstructionVideoMetadata, InstructionImportError>   // IF-13
}

protocol InstructionVideoInspecting: Sendable {
    func inspect(url: URL) async -> Result<InstructionVideoMetadata, InstructionImportError>  // IF-14
}

struct AVInstructionVideoProber: InstructionVideoProbing { init() }
struct AVInstructionVideoInspector: InstructionVideoInspecting { init() }
```

Both map **every** AVFoundation failure to `.unreadableSource` or `.unsupportedFormat`; neither returns or logs an `NSError`.

```swift
// Services/Instructions/InstructionVideoImporter.swift

protocol InstructionVideoImporting: Sendable {
    /// IF-15. Validates a staged file. On any failure the staged bytes are
    /// discarded before returning; the caller never has to.
    func validate(_ staged: StagedInstructionVideo,
                  limits: InstructionVideoLimits) async -> Result<AcceptedInstructionVideo, InstructionImportError>
}

final class InstructionVideoImporter: InstructionVideoImporting {
    init(store: InstructionVideoStore,
         inspector: InstructionVideoInspecting,
         configuration: InstructionVideoConfiguration,
         deadline: @escaping @Sendable (TimeInterval) async -> Void = InstructionVideoImporter.sleep,
         now: @escaping () -> Date = Date.init)
}
```

`validate` runs the inspector and the deadline as two racing tasks; the first result wins and the other is cancelled. Timeout ⇒ `.validationTimedOut` **and** `store.discard(staged)`. Inspector failure ⇒ its own case **and** discard.

```swift
// Services/Instructions/InstructionPermissions.swift

enum InstructionMediaPermission: Equatable { case camera, microphone }

enum InstructionPermissionStatus: Equatable {
    case granted, denied, restricted, undetermined
    case unavailable            // no camera hardware / cannot present
}

enum InstructionPermissionProblem: Equatable {
    case cameraDenied, microphoneDenied, cameraUnavailable
}

protocol InstructionPermissionRequesting: Sendable {
    func status(for permission: InstructionMediaPermission) async -> InstructionPermissionStatus   // IF-18
    func request(_ permission: InstructionMediaPermission) async -> InstructionPermissionStatus
}

struct AVFoundationInstructionPermissions: InstructionPermissionRequesting {
    init()      // no stored state; the OS is the source of truth
}
```

`status`/`request` never throw and never trap; a denied answer is a value. `request` is a no-op returning the current status when it is already `.denied`/`.restricted` (the OS will not re-prompt).

```swift
// Services/Instructions/InstructionVideoCaptureCoordinator.swift

@MainActor
protocol InstructionVideoPicking: AnyObject {
    /// IF-16. Presents the out-of-process picker. `makeStagedCopy` is
    /// invoked on the main thread INSIDE the system callback, before it
    /// returns; `completion` is invoked exactly once on every path
    /// (picked, cancelled, failed, adapter dismissed).
    func presentVideoPicker(
        makeStagedCopy: @escaping @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>,
        completion: @escaping @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void)
    func dismiss()
}

@MainActor
protocol InstructionVideoRecording: AnyObject {
    /// IF-17. Same contract; the recorder caps its own capture at
    /// `maximumDurationSeconds` and reports the file through its callback.
    func presentRecorder(
        maximumDurationSeconds: TimeInterval,
        quality: InstructionRecordingQuality,
        makeStagedCopy: @escaping @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>,
        completion: @escaping @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void)
    func dismiss()
}

@MainActor
final class InstructionVideoCaptureCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case picking
        case recording
        case validating
        case ready(AcceptedInstructionVideo)
        case failed(InstructionImportError)
    }

    @Published private(set) var state: State
    /// A denial is not an error state: it is a plain note beside an idle
    /// sheet. Cleared by the next attempt or by dismissal.
    @Published private(set) var permissionProblem: InstructionPermissionProblem?

    var isBusy: Bool { get }                         // picking/recording/validating
    var accepted: AcceptedInstructionVideo? { get }  // .ready payload, else nil

    init(store: InstructionVideoStore,
         importer: InstructionVideoImporting,
         permissions: InstructionPermissionRequesting,
         makePicker: @escaping () -> InstructionVideoPicking,
         makeRecorder: @escaping () -> InstructionVideoRecording,
         configuration: InstructionCaptureConfiguration,
         events: InstructionObservability,
         probe: @escaping (URL) -> Result<InstructionVideoMetadata, InstructionImportError>,
         now: @escaping () -> Date = Date.init)

    func pick()                                   // IF-28
    func record()
    func cancel()
    func consumeAccepted() -> AcceptedInstructionVideo?   // ownership transfer
    func discardAccepted()
}
```

`pick()`/`record()` are main-actor and non-async: they set the state, present the adapter, and run validation in a `Task`. `cancel()` dismisses whatever is presented, discards staged bytes it can name, and returns to `.idle` with **no event**. `consumeAccepted()` returns the value and clears the state without discarding; the host now owns the bytes. `discardAccepted()` discards and clears. `pick`/`record` while `isBusy` are ignored (single-flight, §7.3).

```swift
// Services/Instructions/InstructionPlayback.swift

enum InstructionPlaybackEvent: Equatable {
    case preflightPassed        // adapter only: player constructed, file is playable
    case ready                  // adapter: AVPlayerItem .readyToPlay
    case failed(InstructionPlaybackFailure)
    case finished               // played to the end
    case closed                 // controller only
}

enum InstructionPlaybackFailure: Error, Equatable { /* §3.3 */ }

struct InstructionPlaybackConfiguration: Equatable {
    let preflightTimeoutSeconds: TimeInterval   // 0.6
    let readyWatchdogSeconds: TimeInterval      // 10
    static let standard: InstructionPlaybackConfiguration
}

@MainActor
protocol InstructionVideoPlaying: AnyObject {
    var renderablePlayer: AVPlayer? { get }     // nil until .preflightPassed
    func present(url: URL, onEvent: @escaping @MainActor (InstructionPlaybackEvent) -> Void)  // IF-19
    func dismiss()
}

@MainActor
final class InstructionPlaybackController: ObservableObject {
    enum State: Equatable {
        case preparing
        case playing
        case failed(InstructionPlaybackFailure)
    }

    let title: String?
    @Published private(set) var state: State
    @Published private(set) var player: AVPlayer?

    init(url: URL,
         title: String?,
         player: InstructionVideoPlaying,
         configuration: InstructionPlaybackConfiguration,
         events: InstructionObservability,
         deadline: @escaping @MainActor (TimeInterval) async -> Void = InstructionPlaybackController.sleep,
         now: @escaping () -> Date = Date.init)

    func start()      // IF-20; idempotent
    func close()
}
```

Timer contract (P-1): `start()` arms the preflight watchdog. `.preflightPassed` cancels it and arms the ready watchdog. `.ready` cancels it. Either expiry, or `.failed`, sets `.failed(...)`, calls `player.dismiss()`, and emits one `instruction_playback` event. `.finished` leaves the player on its last frame with the Close button available. Any event after `.failed`/`close()` is ignored.

```swift
// Services/Instructions/AVKitInstructionVideoPlayer.swift

@MainActor
final class AVKitInstructionVideoPlayer: NSObject, InstructionVideoPlaying {
    init()                                   // constructs nothing
    var renderablePlayer: AVPlayer? { get }
    func present(url: URL, onEvent: @escaping @MainActor (InstructionPlaybackEvent) -> Void)
    func dismiss()
}
```

```swift
// Services/Instructions/InstructionImageLoading.swift   (C01, used by C08)

@MainActor
protocol InstructionImageLoading {
    func loadImage(filename: String) -> Result<UIImage, InstructionImageFailure>   // IF-21
}

/// Routines: the instruction image lives in the entry's VisualAidStore
/// directory (the photo store this app already has — D3).
struct VisualAidInstructionImageLoader: InstructionImageLoading {
    init(store: VisualAidStore, entryId: UUID)
}

/// Events: the instruction image lives in the same flat EventPhotos store
/// as the event's own photo.
struct EventPhotoInstructionImageLoader: InstructionImageLoading {
    init(store: ContactPhotoStore)
}
```

Both loaders apply `InstructionFilename.isPlain` before the store read — non-empty, no separators, not `.` or `..` — and map a refused name to `.rejectedFilename`, an absent file to `.missingFile`, and a decode failure to `.unreadableFile`. They never log; the card emits one outcome event.

### 3.6 C08–C17 declarations — views, services, observability, notifications, handlers

```swift
// App/InstructionViews.swift

@MainActor
struct InstructionCardDependencies {
    let loadImage: (String) -> Result<UIImage, InstructionImageFailure>
    let videoAvailability: (String) -> InstructionPlaybackAvailability
    let makePlayback: (URL, String?) -> InstructionPlaybackController
    let locale: Locale
}

struct InstructionCardView: View {
    /// Read-only by design: the host owns every editing affordance, so the
    /// same card is safe on the fired screen, the detail and the editor
    /// preview. The only control inside it is the video Play button.
    init(instruction: Instruction?,
         isExpected: Bool,
         timeText: String?,                  // nil ⇒ no time line
         dependencies: InstructionCardDependencies)
}

@MainActor
struct InstructionEditorDependencies {
    let imageLoader: InstructionImageLoading            // previews an existing image
    let makeCaptureCoordinator: () -> InstructionVideoCaptureCoordinator
    let makePlayback: (URL, String?) -> InstructionPlaybackController
    let locale: Locale
}

struct InstructionEditorView: View {
    init(dependencies: InstructionEditorDependencies,
         draft: Binding<InstructionDraft>,
         onCancel: @escaping () -> Void,
         onDone: @escaping () -> Void)
}

struct InstructionPlaybackCover: View {
    init(controller: InstructionPlaybackController, locale: Locale, onClose: @escaping () -> Void)
}
```

Section order, state→view mapping and accessibility are §10. `InstructionEditorView` is the only surface that mutates the binding; `onDone` is enabled always (a no-op draft simply reports `nil`), and the host decides what `nil` means for its own save.

```swift
// Services/Reminders/RoutineStore.swift   (added, same file as the class)

extension RoutineStore {
    /// IF-33. The strict read the sweep needs: `nil` on ANY `storage.read`
    /// failure — the encrypted store reports a missing key as a read
    /// failure, so a first-run/absent key also yields nil. The legacy
    /// `loadEntries()` keeps returning `[]` on failure for every existing
    /// caller and is never used to build a live set.
    func loadEntriesIfReadable() -> [RoutineEntry]?
}

// Services/Reminders/RoutineScheduler.swift   (added)

extension RoutineScheduler {
    /// IF-22. Ordered transaction §5.6; `persistAndReschedule()` exactly
    /// once on success; emits `entry_instruction_updated` only on a real
    /// change; never leaves a half-applied instruction.
    @discardableResult
    func setInstruction(_ commit: InstructionCommit,
                        entryId: UUID) -> Result<Void, InstructionWriteError>

    /// IF-23. Delegates to `RoutineStore.loadEntriesIfReadable()` (IF-33).
    /// `nil` = the store could not be read (NOT an empty list).
    func entriesIfReadable() -> [RoutineEntry]?
}
```

```swift
// Services/Storage/EventExtrasStore.swift   (added / fixed)

extension EventExtrasStore {
    /// IF-26. Upserts the row, sets only `instruction`, preserves
    /// `photoFilename`. `Bool` is this store's existing convention and a
    /// deliberate, recorded exception to the explicit-error-type rule
    /// (OI-1, m-2): the service seam translates `false` to
    /// `InstructionWriteError.persistenceFailed`.
    @discardableResult
    func setInstruction(_ instruction: Instruction?, forEventId eventId: String) -> Bool

    /// IF-27. `nil` = the payload could not be decoded. The only read
    /// accessor that distinguishes unreadable from empty (P-6).
    func snapshot() -> [String: EventExtras]?
}
```

```swift
// Services/Events/FreeFormEventService.swift   (added)

struct FreeFormEventSaveOutcome: Equatable {
    let eventId: String
    let instructionSaved: Bool      // false ⇒ event saved, instruction not
}

extension FreeFormEventService {
    /// IF-24. Same ordered transaction as C11, for the event owner.
    @discardableResult
    func setInstruction(_ commit: InstructionCommit,
                        forEventId eventId: String) -> Result<Void, InstructionWriteError>

    /// IF-25. Event-first; instruction work only after `resolvedId`
    /// exists; a failed instruction yields `instructionSaved == false`.
    @discardableResult
    func save(_ form: FreeFormEventForm,
              editing eventId: String? = nil) -> FreeFormEventSaveOutcome?
}
```

`FreeFormEvent` (the composite the service already returns) gains `var instruction: Instruction? = nil`; `event(withId:)` populates it from the index. `FreeFormEventForm` gains `var instructionDraft: InstructionDraft = .loaded(instruction: nil)`; `save` reads `form.instructionDraft.resolvedCommit`.

```swift
// Services/Instructions/InstructionObservability.swift

enum InstructionImportOutcome: String, Equatable { case accepted, failed }
enum InstructionDeleteOutcome: String, Equatable { case deleted, absent, failed }
enum InstructionAvailabilityOutcome: String, Equatable { case rejected, missing, unreadable }
enum InstructionPlaybackOutcome: String, Equatable { case ready, failed, closed }
enum InstructionImageOutcome: String, Equatable { case loaded, missing, unreadable }
enum InstructionPurgeOutcome: String, Equatable { case completed, failed }

struct InstructionObservability: Sendable {
    init(bus: ObservabilityBus)

    // IF-29. Every method builds its metadata from typed values only.
    func mediaImport(outcome: InstructionImportOutcome, kind: String,
                     durationMs: Int, error: InstructionImportError?)
    func mediaDelete(outcome: InstructionDeleteOutcome, count: Int,
                     error: InstructionStorageError?)
    func mediaAvailability(outcome: InstructionAvailabilityOutcome, kind: String)
    func playback(outcome: InstructionPlaybackOutcome, durationMs: Int,
                  error: InstructionPlaybackFailure?)
    func imageLoad(outcome: InstructionImageOutcome, durationMs: Int)
    func permission(_ state: InstructionPermissionStatus,
                    permission: InstructionMediaPermission)
    func orphanPurge(outcome: InstructionPurgeOutcome, count: Int,
                     error: InstructionStorageError?)
}
```

```swift
// Services/Notifications/RoutineNotificationContent.swift

enum RoutineNotificationContent {
    /// IF-30. Pure builder: no centre, no clock, no file IO of its own.
    static func make(occurrenceId: UUID,
                     entryId: UUID,
                     entryTitle: String,
                     reminderTitle: String,
                     visualAidURL: URL?,
                     hadInstruction: Bool,
                     attachmentFactory: (URL, UUID) -> UNNotificationAttachment? = Self.standardAttachment)
        -> UNMutableNotificationContent
}
```

`userInfo` is exactly `occurrence_id: String`, `entry_id: String`, `type: "routine_reminder"`, `had_instruction: Bool`. No instruction text, caption, filename or URL is ever placed in content, and no category or action is set.

```swift
// Services/Notifications/RoutineVisualAidFireHandler.swift   (changed)

struct RoutineInstructionFireContext: Equatable {
    let hadInstruction: Bool     // userInfo["had_instruction"] ?? false
    let firedAt: Date
}

final class RoutineVisualAidFireHandler: NotificationEventHandling {
    /// `onFire` is the foreground delivery sink; `onInstructionTap` is the
    /// tap/Open sink and carries the entry as OPTIONAL so an owner deleted
    /// after arming can still reach presentation (L1 D14, review-l1 B-2).
    init(entryLookup: @escaping (UUID) -> RoutineEntry?,
         onFire: @escaping (RoutineEntry, RoutineInstructionFireContext) -> Void,
         onInstructionTap: @escaping (UUID, RoutineEntry?, Date) -> Void)
    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool
    func didReceive(_ response: UNNotificationResponse) async
}
```

```swift
// App/AppCoordinator.swift   (added)

@MainActor
extension AppCoordinator {
    func saveRoutineInstruction(_ commit: InstructionCommit,
                                entryId: UUID) -> Result<Void, InstructionWriteError>   // IF-32
    func saveFreeFormEvent(_ form: FreeFormEventForm,
                           editing eventId: String?) -> FreeFormEventSaveOutcome?
    func presentRoutineVisualAids(for entry: RoutineEntry,
                                  context: RoutineInstructionFireContext)
    /// The tap path. `entry == nil` (owner deleted after arming) maps to
    /// `FiredRoutineVisualAids.Content.unavailable` — never a no-op.
    func presentRoutineInstructionTap(entryId: UUID,
                                      entry: RoutineEntry?,
                                      firedAt: Date)
    func dismissFiredRoutineVisualAids()
}
```

`FiredRoutineVisualAids` gains a `Content` enum (§4.11): `.reminder(title:aids:instruction:expectsInstruction:firedAt:)` or `.unavailable`. The coordinator keeps every decision out of the view: the view renders, the coordinator saves and presents.

---

## Data Models

There is no database in this feature. Persistence is three existing shapes plus file bytes: the routine entries' `EncryptedLocalStorage` payload, the free-form events' encrypted single-key side index, and the two file stores. The "schema" work is therefore (a) two encoded deltas, (b) tolerant decode rules, (c) the migration fixtures that prove old payloads still load, and (d) the value shapes the UI and services exchange.

### 4.1 `Instruction` on the wire

One JSON object per instruction, nested under a single key on its owner. Nil fields are omitted on encode.

| Field | Type | Authored by v1 | Meaning |
|---|---|---|---|
| `kind` | `String` | yes | `"text"`, `"image"`, `"video"` (L1's locked vocabulary); unknown values preserved verbatim |
| `text` | `String?` | text only | The instruction's words. Trimmed on write; blank ⇒ not present |
| `caption` | `String?` | image/video | Optional one-line caption under the media |
| `filename` | `String?` | image/video | Bare filename inside the owner's store. Never a path |
| `url` | `String?` | **no** | Decoded/encoded for forward tolerance only. No UI acts on it |

Rules:

1. `kind` is the discriminator and the only field that decides which other fields matter. A text instruction carrying a filename, or an image carrying text, is *legal to decode* and is normalised away on the next write (`InstructionPayload.instruction` nulls it). The reader must not "fix" such a row in place; the model is read-only outside a save.
2. `filename` is bare by contract, but the *decoder does not sanitise* — the model is not a security boundary. `InstructionVideoStore` and the image loaders apply `InstructionFilename.isPlain` and refuse. A traversal-shaped filename therefore never resolves, and a test proves the refusal rather than a decode rejection (fixture F-11).
3. `url` never affects `isPresent` for known kinds and never reaches a log or an event.

### 4.2 The write algebra

```
InstructionDraft
  ├─ loadState   .loading | .loaded | .failed
  ├─ hasChanges  set by the first mutating edit; cleared by revert()
  ├─ write       .set(InstructionPayload) | .remove | nil
  ├─ pendingMedia .image(UIImage) | .video(AcceptedInstructionVideo) | nil
  └─ original    the instruction the draft loaded (nil for a new owner)
```

`resolvedWrite` truth table (IF-2, pinned by `InstructionModelTests`):

| `loadState` | `hasChanges` | `write` | `resolvedWrite` |
|---|---|---|---|
| `.loading` | any | any | `nil` |
| `.failed` | any | any | `nil` |
| `.loaded` | `false` | any | `nil` (a mutation that was reverted is not a change) |
| `.loaded` | `true` | `nil` | `nil` (nothing authored) |
| `.loaded` | `true` | `.set(payload)` | that write |
| `.loaded` | `true` | `.remove` | `.remove` |

`resolvedCommit` is `nil` when `resolvedWrite` is nil; otherwise it is `InstructionCommit(write: resolvedWrite, pendingMedia: pendingMedia)` — with the rule that `pendingMedia` is dropped unless the write is `.set` **and** the payload's kind matches the pending media's kind. A text write can therefore never smuggle an image.

Payload construction (`InstructionPayload.instruction`):

| Payload kind | `text` | `caption` | `filename` | `url` |
|---|---|---|---|---|
| `.text` | trimmed text | `nil` | `nil` | `nil` |
| `.image` | `nil` | trimmed caption | filename (nil until commit) | `nil` |
| `.video` | `nil` | trimmed caption | filename (nil until commit) | `nil` |

Editing an existing instruction seeds the payload from `original` with its filename, so a caption-only edit writes **no** media (`pendingMedia == nil`, filename present) and the transaction (§5.6) has no copy to do.

### 4.3 Owners, roots and filenames

| `InstructionOwner` | Root directory | Owner directory | Media directory layout |
|---|---|---|---|
| `.routine(uuid)` | `Application Support/InstructionVideos/` | `<uuid>` (uppercase UUID string, as `VisualAidStore` does) | `<owner>/instruction-<draftId>.<ext>` |
| `.event(eventId)` | `Application Support/EventInstructionVideos/` | `ev-` + first 32 lowercase hex chars of `SHA-256(utf8: eventId)` | `<owner>/instruction-<draftId>.<ext>` |

Why a digest for events: an EventKit identifier is an opaque string that can contain characters that are not safe in a path component and is long enough to be awkward; the digest is stable, filename-safe, and one-way (the event id never lands on disk as a name). Why the first 32 hex characters: 128 bits of collision resistance for a per-device event count is far beyond need, and it keeps the directory name short enough to read in a log-free diagnostic. `eventDirectoryName(for:)` is the single implementation; a test pins `^ev-[0-9a-f]{32}$` and pins that two distinct ids differ.

`.invalidOwner` is returned by the store when a directory name is empty, `.`, `..`, or contains `/` or `\\`. It cannot happen from `UUID` or the digest; the guard exists so a future id source cannot escape the root and take the whole store with it on `deleteAll`.

Stored filenames are `instruction-<draftId>.<ext>`: `draftId` is the UUID minted at staging, so a replace never overwrites the file the index still points at; `<ext>` is `InstructionFilename.sanitizedExtension(sourceExtension)` — 1–8 lowercase alphanumerics, else `mov`. Every name that arrives from a payload is validated by `InstructionFilename.isPlain` before it becomes a URL; the non-empty clause is what stops an empty component from resolving to the owner directory (§3.5).

### 4.4 `RoutineEntry` delta

```swift
struct RoutineEntry: Codable, Equatable {
    // existing: id, category, titleOverride, scheduleTimes, frequency,
    // weekdays, isEnabled, visualAids
    var instruction: Instruction? = nil        // NEW
}
```

- `CodingKeys` gains `case instruction`.
- `init(from:)` gains `instruction = (try? container.decodeIfPresent(Instruction.self, forKey: .instruction)) ?? nil`. The double optional is deliberate: a malformed `instruction` value (an array, a string, a number) must cost the *instruction*, never the routine entry (fixture F-7).
- `encode(to:)` uses `encodeIfPresent`; a nil instruction adds no key (fixture F-1 asserts a legacy-shaped payload round-trips byte-identically).
- If `RoutineEntry` has an explicit initialiser, the new parameter is appended with `= nil`; if it relies on the memberwise initialiser, the default preserves every existing call site. Either way no existing construction changes.
- The model does not consult the store: `instruction` may name a file that is gone. `isPresent` answers "is there something to render", not "are the bytes there"; availability is the store's answer, at display time.

### 4.5 `EventExtras` delta and the `setPhotoFilename` fix

```swift
struct EventExtras: Codable, Equatable {
    var photoFilename: String? = nil
    var instruction: Instruction? = nil        // NEW
}
```

- Tolerant decode for both fields; a malformed `instruction` is dropped (fixture F-7).
- `track(eventId:)` preserves both fields; `remove(eventId:)` returns the dropped row (so the caller can delete both files).

**The pinned fix (P-4, N-4).** The shipping `setPhotoFilename` at `EventExtrasStore.swift:110–113` builds `EventExtras(photoFilename:)` wholesale and writes it back. With a second field that rebuild would erase every `instruction`. The required shape is: read the existing row (or an empty one), set only `photoFilename`, write the row back. The same rule applies to the new `setInstruction`: read the existing row, set only `instruction`, write back. Neither method may construct a fresh `EventExtras` with only its own field. `EventExtrasStoreTests` gains the regression pair:

1. track → setInstruction → `setPhotoFilename` ⇒ instruction survives, photo set.
2. track → setPhotoFilename → setInstruction ⇒ photo survives, instruction set.

### 4.6 Tolerant-decode rules (the whole contract)

| Situation | Required outcome | Fixture |
|---|---|---|
| No `instruction` key | owner loads, `instruction == nil` | F-1, F-2 |
| `instruction: null` | owner loads, `instruction == nil` | F-10 |
| `instruction` is an object with unknown fields | loads; unknown fields ignored on encode | F-8 |
| `instruction.kind` unknown (e.g. `"link"` or `"audio"`) | loads; kind preserved verbatim; `knownKind == nil`; displays `.unsupported` | F-6a, F-6b |
| A known field has the wrong type (`"text": 7`) | that field becomes `nil`; the instruction still loads with its other fields | F-4b |
| `instruction` is not an object (`"instruction": "oops"`) | **the instruction is dropped; the owner loads** | F-7 |
| Payload is `{}` (extras) | empty index, not an error | F-9 |
| Payload is corrupt JSON | existing behaviour: the store's tolerant read returns empty (unchanged) | not new |
| Filename is traversal-shaped | decodes; store refuses; card shows the image fallback | F-11 |

One rule governs all of it: **no decode path added by this feature may throw past its own field.** The only tolerated loss is the instruction itself.

### 4.7 Migration fixtures

Fixtures are Swift string literals in the suites, not files on disk (the house style — `EventExtrasStoreTests` plants bytes through `MockEncryptedLocalStorage`). Each fixture is named, and each names the test that consumes it.

| ID | Payload | Asserted by |
|---|---|---|
| F-1 | Legacy routine entry JSON with `visualAids: []` and **no** `instruction` key | `RoutineEntryTests` — loads; `encode → decode` adds no `instruction` key |
| F-2 | Legacy extras `{"photoFilename":"a.jpg"}` | `EventExtrasStoreTests` — loads; photo intact; instruction nil |
| F-3 | Entry with `"instruction":{"kind":"text","text":"Take the blue pill"}` | `RoutineEntryTests` — text round-trips trimmed; the raw kind is asserted as `"text"` |
| F-4 | Entry with a full image instruction (`caption`, `filename`) | `RoutineEntryTests` — all fields; `isPresent == true` |
| F-4b | Entry with `"instruction":{"kind":"image","text":7,"filename":"x.jpg"}` | `RoutineEntryTests` — `text == nil`, filename intact |
| F-5 | Entry with a video instruction | `RoutineEntryTests`, `InstructionDisplayStateTests` |
| F-6a | Entry with `"instruction":{"kind":"link","url":"stored-url"}` — FR-RIE-024's future kind | `RoutineEntryTests` — loads, kind and url verbatim; `InstructionDisplayStateTests` — `.unsupported`, no Play/photo/link control |
| F-6b | Entry with `"kind":"audio"` + text — an independently unknown value | `RoutineEntryTests` — verbatim round-trip; `InstructionDisplayStateTests` — `.unsupported` |
| F-7 | Entry with `"instruction":"oops"`; extras with the same | `RoutineEntryTests`, `EventExtrasStoreTests` — the owner survives, instruction nil |
| F-8 | Instruction with `"future_field": 42` | `RoutineEntryTests` — loads; re-encode drops it |
| F-9 | Extras `"{}"` | `EventExtrasStoreTests` — empty index, not an error |
| F-10 | `"instruction": null` in both owners | `RoutineEntryTests`, `EventExtrasStoreTests` |
| F-11 | Filenames the guard must refuse: one parent-directory segment (`"filename":"../x.jpg"`), a backslash-separator variant, an absolute path, the empty string, the single-dot component and the double-dot component — one parent segment is enough to trip the guard | `InstructionVideoStoreTests`, `InstructionImageLoadingTests`, `InstructionSurfaceTests` — store and loaders refuse before any URL is built; card shows the fallback |
| F-12 | A video instruction whose file is absent | `InstructionDisplayStateTests` — `.video` state; store says `.missingFile`; playback never starts |

### 4.8 `FreeFormEvent`, `FreeFormEventForm` and the save outcome

```swift
struct FreeFormEvent: Equatable {
    // existing: id, title, start, end, notes, address, photoFilename, …
    var instruction: Instruction? = nil        // NEW, populated by event(withId:)
}

struct FreeFormEventForm: Equatable {
    // existing: title, start, end, notes, address, pickedPhoto, removedPhoto
    var instructionDraft: InstructionDraft = .loaded(instruction: nil)   // NEW
}

struct FreeFormEventSaveOutcome: Equatable {
    let eventId: String
    let instructionSaved: Bool
}
```

`save` semantics, case by case:

| Situation | Return | Side effects |
|---|---|---|
| Form invalid, or gateway create/update refused | `nil` | Nothing changes anywhere |
| Event saved, no instruction write | `Outcome(id, true)` | Event (+ its photo) as today |
| Event saved, instruction write succeeded | `Outcome(id, true)` | Event, media committed, index updated |
| Event saved, instruction write failed | `Outcome(id, false)` | Event and photo as today; **no** instruction change; committed media removed; the detail shows the partial line |
| Instruction `.remove` succeeded | `Outcome(id, true)` | Index cleared, media deleted, old file may be swept |

A partial outcome is never `nil`: `nil` means "the event itself did not save", and collapsing the two would make the form lie about what happened.

### 4.9 `LiveInstructionOwners` — the sweep's input

```swift
struct LiveInstructionOwners: Equatable {
    /// nil = the routine store could not be read. The sweep must NOT run
    /// for the routines root in that case (P-6).
    let routines: Set<InstructionOwner>?
    /// nil = the extras index could not be read.
    let events: Set<InstructionOwner>?

    static func compose(routineEntries: [RoutineEntry]?,
                        extras: [String: EventExtras]?) -> LiveInstructionOwners
}
```

Rules: for each readable source, the live set is every owner whose current `instruction.knownKind == .video` — regardless of whether its file resolves. Erring toward "live" means the sweep can never delete bytes the index might still point at; a missing file simply means there is nothing to delete. `compose` performs no IO; the coordinator supplies the two reads (`routineScheduler.entriesIfReadable()` — which delegates to `RoutineStore.loadEntriesIfReadable()` — and `extras.snapshot()`), which is what makes the nil-means-unknown distinction possible at all.

### 4.10 Display state → surface

| `InstructionDisplayState` | Card renders | Keys | VoiceOver label |
|---|---|---|---|
| `.none` | `EmptyView` (nothing, not a container) | — | — |
| `.text(text)` | Body text, full width | — | the text itself, static text (§10.3) |
| `.image(filename, caption)` | Photo (max width, aspect fit), caption beneath; fallback line on load failure | `instruction.image.unavailable` | `instruction.image.accessibility` = "Instruction photo"; caption appended as its own text |
| `.video(filename, caption)` | Play button (44 pt) + caption; fallback line when not `.available` | `instruction.video.play`, `instruction.video.unavailable` | `instruction.video.accessibility` = "Instruction video. Play" |
| `.unsupported(text?)` | `text` if any, plus the plain note | `instruction.unsupported` | note text |
| `.removed` | The plain removed line | `instruction.removed` | same text |

`.unavailable` is not an `InstructionDisplayState`: it is a `FiredRoutineVisualAids.Content` case for a deleted owner, rendered by the overlay with its own title and an `EmptyView` footer (§4.11, §10.3).

**The fire-time gate (D6), stated once.** `RoutineVisualAidOverlay` resolves `firedAt` through `LocaleFormatters.shortTime(locale:)` and passes the result as the card's `timeText` **only when `instruction?.isPresent == true || expectsInstruction`**; otherwise it passes `nil`. `.unavailable` carries no `firedAt` at all, so it can never render a time. The card renders `Text(timeText)` (when non-nil) plus the accessibility compositions in §10; the time line is *not* part of the card's state, because the card is also used where there is no fire time (editors, details). Two consequences are pinned: a removed instruction (`expectsInstruction == true`, `instruction == nil`) keeps the title and the time and shows `.removed`; a photo-only foreground firing (`instruction == nil`, `expectsInstruction == false`) passes `timeText == nil`, the card is `.none` (`EmptyView`) and the footer is `EmptyView` — the rendered screen is exactly today's (`VisualAidViews.swift:283–289`, §11.3 M). §2.15.4 applies the same rule at the composition seam; this paragraph is the authoritative statement.

### 4.11 `FiredRoutineVisualAids` delta

```swift
struct FiredRoutineVisualAids: Equatable, Identifiable {
    enum Content: Equatable {
        /// A routine firing: title and delivery date, plus the instruction.
        /// The time line renders only when the D6 gate holds (§4.10);
        /// `instruction == nil && expectsInstruction == true` renders the
        /// `instruction.removed` fallback and keeps the time.
        case reminder(title: String,
                      aids: [VisualAid],
                      instruction: Instruction?,
                      expectsInstruction: Bool,
                      firedAt: Date)
        /// The owner was deleted between arming and the tap (FR-RIE-019,
        /// L1 D14, review-l1 B-2): the shared screen renders title
        /// `instruction.reminderUnavailable`, `aids: []`, an `EmptyView`
        /// footer and a Close control. No title or time is claimed,
        /// because none can be resolved.
        case unavailable
    }
    let entryId: UUID
    let content: Content
    var id: UUID { entryId }
}
```

`expectsInstruction` is what makes the removed-instruction fallback honest: without it, "no instruction now" and "never had one" are the same value, and the tap would be a dead end. `.unavailable` is the separate, equally explicit value for "the owner is gone": `RoutineVisualAidOverlay` maps it to the same `ReminderVisualAidScreen` with `aids: []`, `title: L10n.str("instruction.reminderUnavailable", locale:)`, an `EmptyView` footer and Close (the overlay is a view, so it resolves the key itself; no service holds copy), so a deleted owner cannot fall through to a blank screen or a no-op.

---

## Storage

### 5.1 Roots, base resolution and the no-IO init

```
Application Support/
├── InstructionVideos/                 (InstructionRoot.routines)
│   ├── _pending/<draftId>/payload.<ext>
│   └── <routineUuid>/instruction-<draftId>.<ext>
└── EventInstructionVideos/            (InstructionRoot.events)
    ├── _pending/<draftId>/payload.<ext>
    └── ev-<32 hex>/instruction-<draftId>.<ext>
```

`InstructionVideoStore.init(fileManager:baseDirectory:now:)` resolves, and only resolves:

1. `baseDirectory` if supplied (tests always do);
2. else `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)` — `create: false` is a pure path lookup, exactly as `VisualAidStore.init` (`VisualAidStore.swift:82–104`);
3. else — a broken sandbox only — `FileManager.temporaryDirectory`, the same degradation `VisualAidStore` takes.

It stores two computed root URLs and performs **no** `createDirectory`, `contentsOfDirectory`, `fileExists`, `attributesOfItem` or `data(` call. Two proofs, both required: a source scan over the `init` region (`FeatureSourceScan.codeText` + region slice, the `MedicationEditorSurfaceTests` idiom) and a behavioural check that constructing the store over a nonexistent base leaves that base nonexistent. Directories are created by the first write (`createDirectory(withIntermediateDirectories: true)`), which is also `VisualAidStore`'s rule.

### 5.2 `stageSynchronously` — ordered algorithm

Called on the main thread, inside a system callback, before the callback returns (IF-5, §7.4). Each step's failure returns immediately; every step after the first directory creation removes what it created.

| # | Step | Failure | Cleanup |
|---|---|---|---|
| 1 | `sourceURL.isFileURL`, exists, not a directory, `isReadableFile` | `.unreadableSource` | none |
| 2 | `attributesOfItem[.size]` as `Int64` — the expected byte count the stream must deliver; `size > limits.maxBytes` (strictly greater) | `.unreadableSource` / `.tooLarge` | none |
| 3 | `probe(sourceURL)`; either `!isPlayable` or `!hasVideoTrack` ⇒ `.unsupportedFormat`; non-finite duration ⇒ `.unreadableSource`; `InstructionVideoDuration.exceedsLimit(duration, limit:)` (strictly greater: exactly 180 s is allowed, 180.5 s rounds to 181 and is refused) | the probed case / `.tooLong` | none |
| 4 | create `<root>/_pending/<draftId>/` with `withIntermediateDirectories` and attributes `[.protectionKey: .complete]` | `.writeFailed(.stagingFailed)` | none (nothing created) |
| 5 | create the destination `<draft>/payload.<sanitizedExtension>` with **no bytes** and `[.protectionKey: .complete]` (`FileManager.createFile(atPath:contents:nil,attributes:)` through `InstructionStagingFileOps`); false ⇒ `.writeFailed(.stagingFailed)`. Immediately read the attribute: a reported weaker class deletes the file and fails `.writeFailed(.protectionFailed)`; an unreported attribute proceeds (R-5) | `.writeFailed(.stagingFailed)` / `.writeFailed(.protectionFailed)` | remove the file and the draft dir |
| 6 | fill the created file from the source with a bounded chunked stream (`stagingChunkBytes`, 1 MiB; a `FileHandle` read/write loop that closes both handles on every path). The 200 MiB cap is enforced **cumulatively while streaming**, not only from the step-2 metadata. Read failure ⇒ `.unreadableSource`; write failure ⇒ `.writeFailed(.stagingFailed)`; cumulative overflow ⇒ `.tooLarge`; a delivered count other than the step-2 size (truncated or changed source) ⇒ `.unreadableSource` | the mapped case | delete the partial file and the draft dir |
| 7 | re-read `attributesOfItem[.protectionKey]` after the stream; a reported weaker class deletes the file and fails | `.writeFailed(.protectionFailed)` | remove the file and the draft dir |
| 8 | return `StagedInstructionVideo` (draftId, root, URL, step-2 size, metadata, extension, `now()`) | — | — |

Steps 5–7 run through the store's single staging seam, `InstructionStagingFileOps` (production: `SystemInstructionStagingFileOps`; both live in `InstructionVideoStore.swift`, no new file). The seam is what makes the create-before-write order, the weaker-class report and a mid-stream failure observable in tests (§11.3 E).

Step order is a design decision, not an implementation detail: the size check is cheap and runs before AVFoundation opens a 2 GB file; the probe runs before staging any byte; and the destination file is created with the complete-protection attribute **before the first byte is written**, because a copy would inherit the *source's* class — a picker's temp file is often `.completeUntilFirstUserAuthentication` — and a copy-then-set path would leave a weaker-class window (L1 D18, review-l1 m-5). The fill is a bounded chunked stream: no whole-file buffering and no second copy of the bytes, and `copyItem` is never used in the staging path.

The staging write has **no timeout**. It cannot: the source URL dies when the callback returns, so the bytes cannot be deferred or raced. The chunked stream holds at most one chunk in memory (`stagingChunkBytes`, 1 MiB) and the wall-clock cost is bounded by the 200 MiB cap; it is measured in the device smoke (§8.1, NFR-RIE-009). OI-5 is now only the chunk-size measurement — the chunked path itself is mandated by D18, not an option to defer.

### 5.3 Protection: creation is the guarantee, verification is the detector

- **Creation.** Every video file and every directory this store creates carries `.completeFileProtection` at creation: the `_pending` directory by `createDirectory` attributes; the payload file by `createFile(contents: nil, attributes: [.protectionKey: .complete])` **before any byte is written**, then filled by the chunked stream; the owner directory by `createDirectory` attributes; and the committed file by the move preserving the class (re-verified). There is no `copyItem` and therefore no copy-then-set window.
- **Verification.** Immediately after creation, and again after the stream, `attributesOfItem[.protectionKey]` is read. If it reports a class and that class is not `.complete`, the file is deleted (with the draft directory) and staging fails `.protectionFailed`; `commit` uses the same rule and fails `.commitFailed` after removing the destination, because nothing is indexed yet. If the platform reports **no** protection attribute, the store proceeds: creation asked for `.complete`, and treating "the OS did not tell me" as a failure would make the feature untestable and unusable on current simulators without strengthening anything.
- **Why this is fail-closed where it matters.** A weaker class is the only observable failure mode; it is refused at creation and again after the stream, and the bytes are deleted before any index can name them. The tests assert the creation call and its option by source pin (`MedicationEvidenceStoreTests:396` and `LabelTranslationCacheTests:548` establish the idiom), assert the create-then-write order and the attribute *when reported* through `InstructionStagingFileOpsSpy`, and assert that a source scan finds no `copyItem` in the store. **Kill window:** a crash, kill or lock after creation leaves at most an empty or partial file whose class was requested `.complete` at creation — never a weaker-class file — and the pending purge removes it after the grace window (§5.5). R-5 records why the runtime assertion is conditional.
- **Image files** keep `VisualAidStore`'s and `ContactPhotoStore`'s existing `.completeFileProtection` write options, unchanged (`VisualAidStore.swift:123`). We do not add verification to the image stores: that would be a change to two shipping components outside this feature's scope, for no new risk.

### 5.4 Staging and the same-volume rename

`commit` (IF-6):

1. Owner name is a plain component, else `.invalidOwner`.
2. `staged.root == owner.root`, else `.commitFailed` (a programming error; no move).
3. Create `<root>/<ownerDir>/` with `.complete` protection; failure ⇒ `.commitFailed`.
4. Destination = `<ownerDir>/instruction-<draftId>.<ext>`. If it already exists with the staged size, a retried commit is a **success** returning that name (no move); this is what makes a retry after an ambiguous failure safe.
5. `moveItem(stagedURL, destination)` — same volume by construction, because the staging directory and the owner directory are both under the same `InstructionRoot`. Failure ⇒ `.commitFailed`; the staged file is left for the sweep.
6. Verify the destination's protection (move preserves attributes); a weaker class ⇒ remove the destination and `.commitFailed` — nothing is indexed yet, so deleting is the safe direction.
7. Remove the now-empty draft directory best-effort; return the bare filename.

Why same volume is load-bearing: `moveItem` across volumes is a copy+delete, which is not atomic, doubles the peak space, and can leave a truncated file under the final name. Keeping `_pending` inside each root makes the rename a metadata operation on the same filesystem — the file either appears complete or does not appear.

`discard` removes `<root>/_pending/<draftId>/`; absent ⇒ `.success`; a failure ⇒ `.deleteFailed` (the bytes are already unreachable, only the sweep will notice). `delete`/`deleteAll` follow the same existence-first pattern: absence is success (idempotent teardown), a real failure is `.deleteFailed`.

### 5.5 Purges: pending drafts and crash orphans

**Pending purge (IF-11).** For each root, enumerate `_pending`; remove every child whose modification date is at least `graceSeconds` (60) old; a file directly under `_pending` is removed on the same rule. Returns the count. A partial failure returns `.purgeFailed` with the count of what was removed (the caller logs the count).

**Orphan sweep (IF-12, P-6).** Called once per root with that root's live set. If `live == nil`, return success without touching the root — an unreadable index means the live set is *unknown*, and a naive sweep against an empty set would delete every video the household owns. Otherwise, for each child directory of the root:

1. skip `_pending`;
2. skip non-directories;
3. skip a name whose owner cannot be parsed (conservative: an unparseable name is not ours to delete);
4. skip if the directory's modification date is younger than `graceSeconds`;
5. skip if the directory name is in the store's in-flight commit set (read under the lock);
6. skip if `live.contains(owner)`;
7. otherwise `removeItem` and count it.

The grace window exists because a commit is a two-step operation (owner directory created, then file moved in) and because the index write follows the commit by a moment; nothing that is genuinely live is younger than 60 s *and* absent from the index, except during that window, which the grace covers. The in-flight set closes the remaining race for a sweep that runs while the app is interactive.

**Launch wiring.** `AppCoordinator` composes `LiveInstructionOwners` on the main actor (`routineScheduler.entriesIfReadable()`, `extras.snapshot()`), captures the grace value, then enqueues the file work on the existing `modelHousekeepingQueue` (`AppCoordinator.swift:571`). The enqueued block calls `purgePendingDrafts()` once and `purgeOrphanedOwners(in:live:graceSeconds:)` once per root with that root's live set, emitting one `instruction_orphan_purge` event per call. No purge runs on the main thread, and no purge result can block launch.

### 5.6 Transactional replace — the one ordering rule

> **Bytes are durable before the index names them; the index moves before old bytes are deleted.**

Four cases for `setInstruction(commit:owner:)`; the owner and current instruction are resolved first, and a missing owner is `.ownerNotFound` before anything is touched.

**A. Add or replace media (image/video), with pending bytes.**
1. Write/commit the new bytes → new filename. Failure ⇒ `.mediaWriteFailed(...)`; the old instruction and old bytes are untouched; the staged draft is discarded for videos.
2. Persist the payload with the new filename. Failure ⇒ delete the new bytes; return `.persistenceFailed`.
3. Delete the previous bytes if the previous instruction had a filename and it differs. A delete failure is emitted (`instruction_media_delete`) and **not** returned: the instruction is already correct, and the orphan is sweepable.
4. Emit the update event; reschedule (routines) or finish the save (events).

**B. Media unchanged, caption/text changed.** Persist only; step 3 is skipped because the filename is the same. No copy, no delete, no event for media.

**C. Kind change to text.** Persist the text instruction first; on success delete the previous media (step 3). On failure, nothing is deleted.

**D. Remove.** Persist `.remove` first. On failure ⇒ `.persistenceFailed`, bytes and index untouched. On success delete the media; a delete failure is emitted, and the owner leaves the live set, so the next sweep collects the directory.

The failure consequence is asymmetric on purpose: an index naming absent bytes is a user-visible broken screen; unreferenced bytes are a disk cost that the sweep reclaims. Every partial state therefore errs toward "bytes exist, index doesn't point at them".

For the event path, step 1 runs only after the event's `resolvedId` exists (§4.8), so a failed event create leaves no instruction bytes at all.

### 5.7 Backup, restore and the pending draft

Neither root is excluded from backup (D9). Both are backed up like the rest of `Application Support`, under `.completeFileProtection`; the restore's first unlock makes them readable and the first launch's sweep removes any draft that a backup caught mid-copy. No new `isExcludedFromBackup` attribute is written: one more attribute write is one more failure path, and a partial draft surviving a backup is harmless by construction.

### 5.8 Image storage and the N-1 boundary (image stores unchanged)

An instruction's photo reuses the app's existing photo storage (D3). No new image store, no new image API:

| Owner | Store | Write | Read | Delete | Return type |
|---|---|---|---|---|---|
| Routine instruction image | `VisualAidStore` | `save(_:for:caption:) -> VisualAid?` | `load(_:for:) -> UIImage?` | `delete(_:for:)` | `Void` (unchanged) |
| Event instruction image | `ContactPhotoStore` (`EventPhotos`) | `save(_:) -> String?` | `load(named:) -> UIImage?` | `delete(named:)` | `Void` (unchanged) |

**N-1, stated exactly.** `Result`/`.deleteFailed` are introduced *only* on `InstructionVideoStore`. `VisualAidStore.delete`, `VisualAidStore.deleteAll` and `ContactPhotoStore.delete(named:)` keep their `Void` best-effort signatures and their `try? removeItem` bodies; no failure event is claimed for an image delete, because there is no error value to observe and inventing one would mean changing two shipping components. A failed image delete therefore has exactly today's consequence (bytes linger) and, for routines, is covered by `removeEntry`'s existing `deleteAll(for:)`; for events, a flat-store orphan is an accepted, pre-existing condition (the shipping photo path has the same property). `instruction_media_delete` is emitted **only** by the video path, with `count` = files removed (0 or 1).

Image write failures are observable because the writes return optionals: routines map `VisualAidStore.save == nil` to `.mediaWriteFailed(.stagingFailed)`, events map `ContactPhotoStore.save == nil` the same way. No new error type is introduced for images.

### 5.9 Read paths and their failure modes

| Read | Failure mode | Caller's action |
|---|---|---|
| `availability(filename:owner:)` | `.rejectedFilename` / `.missingFile` / `.unreadableFile` | card shows the video fallback; emits one availability event (never for `.available`) |
| `fileURL(filename:owner:)` | nil (unsafe/absent) | treated exactly as `.missingFile` by the cover's caller |
| `VisualAidInstructionImageLoader.loadImage` | `.rejectedFilename` / `.missingFile` / `.unreadableFile` | card shows the image fallback; emits one image event |
| `RoutineStore.loadEntriesIfReadable()` (via `RoutineScheduler.entriesIfReadable()`) | nil (any read failure, including a first-run absent key) | sweep skips the routines root |
| `snapshot()` | nil | sweep skips the events root |
| `event(withId:).instruction` (through the existing `AppCoordinator.freeFormEvent(id:)` wrapper) | nil (row gone or no instruction) | `.none` (detail) — never `.removed` |
| `RoutineEntry.instruction` | nil | `.none` or `.removed` depending on `isExpected` |

No read path retries. A read that fails is a state to render, not a transient to poll; the next appearance re-reads.

### 5.10 Space and disk-full behaviour

- Worst case per owner is one video (≤ 209,715,200 bytes) plus one image (a few hundred KB, existing store) plus a transient staged file of the same video during a replace. The staged file is deleted on commit, discard, or the sweep, so the steady-state ceiling is one video per owner.
- A full disk fails the staging write (`.stagingFailed`) or the rename, never truncates a stored file: the destination name does not exist until the move completes. The previous instruction remains playable throughout.
- No quota, no eviction, no compression. The 200 MiB cap and one-video-per-owner rule are the whole space policy (constitution OD-2).

---

## Error Handling & Observability

### 6.1 Principles

1. **A media failure never blocks the thing it decorates.** A reminder fires, an event saves, a routine saves — with or without its instruction. The only blocking failures are the *instruction write itself*, and even then the previous instruction survives.
2. **One plain line, no codes, no dialogs.** No alert, no modal, no "try again" button, no error code in copy. The elder's recovery is the ordinary affordance that is already on screen (Add, Change, Save).
3. **Cancellation is not a failure.** Dismissing the picker or recorder produces no copy and no event.
4. **Every caught error is either mapped to copy, mapped to an event, or both.** Silent catches are permitted only where the comment says which of the two it is and why the other is unnecessary (an image-delete failure: neither, and N-1 says why).
5. **No retry loops.** An import is attempted when the family asks; a playback when the elder taps. Nothing polls a failing file, nothing re-requests a denied permission.
6. **Services hold no copy and views hold no error-to-copy logic.** `InstructionMessageKey` is the single mapping.
7. **No crash, no trap, no `fatalError`,** including for the "impossible" root mismatch and the malformed filename: both are typed failures.

### 6.2 Failure matrix, per surface

| Surface | Failure | The person sees | Event | Recovery |
|---|---|---|---|---|
| Video pick | Unreadable/unsupported/too long/too large/timeout | `instruction.video.unreadable` / `.tooLong` / `.tooLarge` — one line in the editor | `instruction_media_import` failed + `error_code` | Choose another file; the previous instruction is untouched |
| Video pick | Cancelled | nothing | none | — |
| Video record | Camera/microphone denied or camera unavailable | `instruction.camera.denied` / `instruction.microphone.denied` / `instruction.camera.unavailable` | `instruction_capture_permission` | Choose a file instead; (Settings affordance is OI-6) |
| Video record | Staging/validation failure | same as pick | `instruction_media_import` failed | as above |
| Routine save | `.ownerNotFound` | `instruction.removed` (the entry was deleted under the sheet) | none (no scheduler event exists to emit) | Close; the reminder is gone |
| Routine save | `.mediaWriteFailed` / `.persistenceFailed` / `.unresolvedPayload` | `instruction.saveFailed` or `instruction.video.saveFailed` | `entry_instruction_updated` **not** emitted; the inner store failure is emitted if it was a video | Press Save again; the draft is intact |
| Event save | Event refused | the form's existing failure line | existing `event_save` | existing |
| Event save | Instruction failed after the event saved | `instruction.savePartial` once on the detail | `event_instruction_updated` not emitted | Edit the event and add it again |
| Card | Photo missing/unreadable | `instruction.image.unavailable` | `instruction_image_load` | none needed; the reminder still renders |
| Card | Video missing/unreadable/rejected | `instruction.video.unavailable` | `instruction_media_availability` | none; the caption and text still render |
| Playback | Unsupported/player failure/interrupted/timeout | `instruction.video.unavailable` inside the cover, Close still available | `instruction_playback` failed + `error_code` + `duration_ms` | Close; reopen later |
| Fired screen | Instruction removed since arming | `instruction.removed` + the fire time | none | Close |
| Fired screen | Routine tap, owner deleted after arming (`had_instruction == true`) | `instruction.reminderUnavailable` with a Close control; no title or time is claimed | none (no owner left to attach an event to) | Close |
| Launch sweep | Purge failure | nothing | `instruction_orphan_purge` failed | Next launch retries |
| Any | Delete of replaced/removed bytes fails | nothing | `instruction_media_delete` failed | The sweep collects it (the owner is not live, or the file is unreferenced) |

### 6.3 Retry and recovery register

| Operation | Automatic retry? | Who retries | How |
|---|---|---|---|
| Staged write / commit | No | the person (Choose again) | A new draft id each attempt |
| Index persist | No | the person (Save again) | Draft intact; new bytes re-committed |
| Video delete | No | the launch sweep | Orphan sweep, `graceSeconds` after the owner leaves the live set |
| Pending purge | No | the next launch | Idempotent |
| Playback | No | the person (tap again) | Fresh controller each presentation |
| Permission request | No (OS won't re-prompt) | the person in Settings | — |
| Notification re-arm | Yes, by design | `persistAndReschedule` on every successful change | Same identifiers replace; idempotent |

There is no backoff, no jitter, no circuit breaker. Every one of them would be a mechanism with no failure it can heal.

### 6.4 Event catalogue (exact names and fields)

All `instruction_*` events are emitted by `InstructionObservability`. The `component` value is a code constant. Metadata uses **only** keys already in `LogSanitiser.allowedKeys` — this feature adds **no** allow-list entry (§6.6).

| `event_type` | `component` | Emitter | When | `outcome` | Other fields |
|---|---|---|---|---|---|
| `instruction_media_import` | `instruction_media` | capture coordinator | once per validation that resolved, after the importer returns | `accepted` \| `failed` | `duration_ms` (accepted only), `kind` = `"video"`, `error_code` (failed only) |
| `instruction_media_delete` | `instruction_media` | services, around video deletes | when the transaction deletes a *referenced* video filename | `deleted` \| `absent` \| `failed` | `count` (0 or 1), `error_code` (failed only) |
| `instruction_media_availability` | `instruction_media` | card | when availability resolves to anything but `.available` | `rejected` \| `missing` \| `unreadable` | `kind` = `"video"` |
| `instruction_playback` | `instruction_playback` | playback controller | `.ready`, `.failed`, and `close()` after a player existed | `ready` \| `failed` \| `closed` | `duration_ms`, `error_code` (failed only) |
| `instruction_image_load` | `instruction_media` | card | when an image load resolves | `loaded` \| `missing` \| `unreadable` | `duration_ms` |
| `instruction_capture_permission` | `instruction_media` | capture coordinator | when a permission check stops a recording attempt | `denied` \| `restricted` \| `unavailable` (in `state`) | `kind` = `"camera"` \| `"microphone"` |
| `instruction_orphan_purge` | `instruction_media` | launch sweep | once per purge call | `completed` \| `failed` | `count`, `error_code` (failed only) |
| `entry_instruction_updated` | `routine_scheduler` | `RoutineScheduler.persistAndReschedule` | a successful, real instruction change | `saved` | `entry_id_hash`, `kind`, `count` = 1 |
| `event_instruction_updated` | `free_form_events` | `FreeFormEventService.setInstruction` | a successful, real instruction change | `saved` | `kind`, `count` = 1 (no identifier: `entry_id_hash` would misname an event id) |

`state` for the permission event is a *value of the allowed `state` key*, not an `outcome`: a denial is a state, not a failed operation. `kind` for the permission event uses `"camera"`/`"microphone"`; every other `kind` value comes from `InstructionKind.reportable(_:)` — the locked raw values `"text"`/`"image"`/`"video"`, and `"unknown"` for anything else.

Never emitted, in any event: instruction text, caption, filename, URL, any path, byte sizes, the raw event identifier, the raw routine UUID (only the existing hashed form), OS error domains/codes/descriptions, device or app identifiers. `duration_ms` is `Int`, clamped to ≥ 0, computed from injected `now()` deltas.

### 6.5 Release-log gate registration (P-3, P-9)

Additions to `ios/tools/check-release-log-safety.py`:

```py
FEATURE_ROOTS += [
    # [REMINDERS-INSTRUCTIONS] The instruction feature's own sources. The
    # words the family types, the captions and the media filenames are
    # household content: no console write anywhere in these files, in any
    # configuration, and no unlisted metadata key (rules 3-6 whole).
    "Services/Instructions",
    "App/InstructionViews.swift",
    "App/InstructionCapture.swift",
]

FEATURE_EVENT_TYPES |= {
    # [REMINDERS-INSTRUCTIONS] The two service emitters that live in shared
    # files no feature root can own: the routine scheduler's change
    # observation and the free-form event service's. Rules 5-6 are applied
    # by literal event name, so the payload stays graded if the emitter
    # moves.
    "entry_instruction_updated": "the routine scheduler's instruction change (RoutineScheduler)",
    "event_instruction_updated": "the event service's instruction change (FreeFormEventService)",
}
```

The honest limits, restated for this feature (the gate's own documentation makes them, and this design does not pretend otherwise):

- **Rules 3–4 are per file.** The hunks this feature adds to `RoutineScheduler.swift`, `EventExtrasStore.swift`, `FreeFormEventService.swift`, `RoutineVisualAidFireHandler.swift`, `FreeFormEventFireHandler.swift`, `EventsView.swift`, `RoutineSettingsView.swift`, `AppCoordinator.swift` and `ContentView.swift` are not graded by rules 3–4. The audit that accompanies this root addition says so file by file; the unit suites and review carry those hunks. No hunk in those files renders instruction content to a console — the only new statements are model mutation, typed emits and view composition.
- **The event-type grade covers rules 5–6 only** — the two registered emitters' metadata, wherever they live.
- **`RoutineNotificationContent.swift` is deliberately not a root.** It lives in a shared directory, writes no log, and its payload is two fixed producer keys plus a `Bool`; a file root would pass and claim nothing.
- **`--self-test` must be run.** Both new roots must resolve in the tree, and both new event types must still appear in an emission statement. A registered type that stops being emitted is a stale entry, fixed by a deliberate registry update — never by deleting the check.

### 6.6 Sanitisation: what is logged, and the proof that it is safe

- **No allow-list change is required.** Every key above is already declared: `outcome`, `state`, `duration_ms`, `error_code`, `count`, `kind`, `entry_id_hash` (`LogSanitiser.swift:56–66`, `:182–184`, `:402`). A feature that had needed a new key would be making an allow-list decision; this one does not, and that is a security property worth stating.
- **Values are closed by construction.** Outcome/state strings come from `String`-raw enums; `kind` from `reportable`; `error_code` from `InstructionErrorCode`; counts and durations are integers; the one hash uses the same helper the scheduler already uses for `entry_id_hash`.
- **The emitter takes no `String` for content.** There is no `metadata: [String: String]` parameter anywhere in `InstructionObservability`; a future contributor cannot pass a filename without changing the type and the review seeing it.
- **No console writes at all** in the three new roots, and none added in the shared files.

### 6.7 User-visible error copy

Every string in §6.2 resolves through `InstructionMessageKey`; the keys and their en/ne copy are §10.5. Two copy rules beyond the key table:

1. A media failure line names what failed and what to do next in one sentence ("That video is too long. Choose one 3 minutes or shorter."). It never says "error", never shows a code, never blames the person.
2. A removed instruction is stated, not hidden: "This instruction is no longer available." — the tap did something, and the person is told what. A deleted owner gets the same honesty with less content: "This reminder is no longer available." (`instruction.reminderUnavailable`) and a Close control, never a dead tap.

---

## Concurrency & Isolation

### 7.1 Isolation map

| Type | Isolation | Why |
|---|---|---|
| `InstructionVideoStore` | nonisolated, `@unchecked Sendable` | Its only mutable state is the in-flight commit-name set behind an `NSLock`; paths are immutable; `FileManager` is documented safe for concurrent use for these calls. The unchecked conformance is a reviewed claim, not a convenience — the class carries a comment stating exactly this. |
| `InstructionVideoImporter` | nonisolated `Sendable` | Runs the inspector and the deadline race in a `Task`; its state is its injected configuration |
| `InstructionVideoCaptureCoordinator` | `@MainActor` | Drives SwiftUI state and presents system view controllers |
| `PHPickerInstructionVideoPicker` / `UIImagePickerInstructionVideoRecorder` | `@MainActor` | UI presentation and delegate callbacks |
| `InstructionPlaybackController`, `AVKitInstructionVideoPlayer` | `@MainActor` | Published state, timers, AVKit |
| `VisualAidInstructionImageLoader` / `EventPhotoInstructionImageLoader` | `@MainActor` | Decode + `UIImage`, the shipping pattern |
| `InstructionObservability` | `Sendable` struct | Fire-and-forget bus writes; no mutable state |
| `Instruction`, `InstructionPayload`, `InstructionWrite`, `InstructionDraft`, `InstructionCommit`, `InstructionOwner`, errors | nonisolated value types | Pure |
| `RoutineScheduler` new methods, `RoutineStore.loadEntriesIfReadable` | the types' existing isolation (synchronous; called on the main actor) | No hop added; call sites are already on the main actor |
| `FreeFormEventService` new methods | the type's existing isolation (nonisolated, called from main) | No new hop |
| `EventExtrasStore` new methods | as today (nonisolated) | The encrypted storage's own serialisation is the mechanism |

### 7.2 Shared resources: who reads, who writes, how it is isolated

| Resource | Concurrent readers | Writer(s) | Isolation mechanism |
|---|---|---|---|
| `InstructionVideos/<owner>/<file>` | Playback (one cover at a time) via an open file descriptor; the card may stat it | `commit`, `delete`, `deleteAll`, sweep | Unique filename per commit (draft id) + same-volume rename; an in-flight player holds the descriptor, so a later unlink does not corrupt playback (POSIX semantics). No file is ever rewritten in place. |
| `InstructionVideos/_pending/<draftId>/` | Nobody | One save transaction at a time (main) | The draft id is unique per attempt; `discard`/`commit`/the sweep only ever touch their own id, and the sweep applies `graceSeconds` |
| The in-flight commit-name set | The sweep | `commit` | `NSLock`; the lock is held only around set insert/remove and the sweep's copy |
| Routine entries (`EncryptedLocalStorage`) | The settings list, the scheduler, the sweep | `RoutineScheduler` save path | The existing store serialisation; no new lock |
| Event extras index | The events list, the detail, the sweep | `FreeFormEventService` save path | The existing store serialisation; no new lock |
| The editor's `InstructionDraft` | The editor view (main) | The editor view (main) | Main actor; it is `@State`, not shared |
| Playback state | The cover (main) | The controller (main) | Main actor + an idempotent `start()` |
| Capture state | The editor sheet (main) | The coordinator (main) | Main actor + `isBusy` single-flight |
| Notification requests | The system | `UNRoutineNotificationScheduler` | Existing same-identifier replace + scoped cancels |
| `FiredRoutineVisualAids` / `firedRoutineVisualAids` | The root overlay (main) | The coordinator (main) | `@Published` on the main actor, as today |

### 7.3 Single-flight

- **Capture is globally single-flight.** One system picker/recorder at a time; `pick()`/`record()` are ignored while `isBusy`. Two editors cannot exist at once in this app (sheets are serial), and the coordinator's state machine is the lock either way.
- **Playback is per-controller.** Each `InstructionPlaybackController` has a `started` flag; a cover is `.fullScreenCover(item:)`, so at most one exists. There is no global playback lock because there is nothing to protect: a second controller would be a second player, which the presentation shape prevents.
- **Per-owner writes are serialised by the main actor.** The routine save path is main-actor; the event save path is reached from the form's Save on the main thread and the service performs no async hop. Two writes to the same owner therefore cannot interleave. The form disables Save while a save is in flight (the existing `isSaving` gate); the service is not re-entrant.
- **A sweep never races a commit that matters** — grace (60 s) + the in-flight set (§5.5). The grace also covers the window between `commit` and the index write.

### 7.4 The callback-scoped URL rule

> A URL a system framework hands to a callback is valid only until that callback returns. Anything that must survive is copied — synchronously — inside the callback.

Three call sites are affected, and each is pinned:

1. **PHPicker** — `loadFileRepresentation`'s completion delivers a temporary file URL. `PHPickerInstructionVideoPicker` calls `makeStagedCopy(url)` **inside** that completion, before returning, and passes the result to `completion`. It never stores the URL, never dispatches staging to another queue, and never calls `completion` later with a URL.
2. **UIImagePickerController** — `mediaURL` in `didFinishPickingMediaWithInfo` is temporary and deleted after the delegate returns. Same rule: stage inside the delegate call.
3. **Notification attachments** — `UNNotificationAttachment` *moves* the file it is given. This feature never builds an instruction attachment (constitution: no video in attachments), so the existing photo path's throwaway-copy rule is untouched and not reused.

The playback URL from `availability` is **not** callback-scoped: it is a stable path in `Application Support`. It is not immutable truth either — a delete between availability and playback is a TOCTOU the controller handles as `.failed` (§2.6.5).

### 7.5 Cancellation and teardown

| Event | Teardown |
|---|---|
| The editor sheet is dismissed while a pick/record is presenting | `cancel()`: dismiss the adapter, discard the staged bytes it knows, state `.idle`, no event |
| The editor is dismissed after `consumeAccepted()` but before save | The host owns the staged bytes; the host discards them in its own `onDisappear`/deinit path — pinned as a test that a consumed-but-unsaved video leaves no `_pending` directory after the next launch sweep |
| The editor is dismissed after a successful save | Nothing to discard: `commit` moved the bytes and removed the draft directory |
| The playback cover is dismissed | `close()`: cancel both timers, `dismiss()` the adapter (observers removed, player released), one `.closed` event if a player existed |
| The app backgrounds during playback | The adapter reports `.failed(.interrupted)` if AVFoundation stops the item; the cover shows the fallback and Close still works |
| The owner is deleted while an editor is open | The save returns `.ownerNotFound`; the copy is `instruction.removed` |
| The routine entry is deleted while its playback cover is open | Playback continues from the open descriptor until closed; the file is unlinked and the sweep sees a non-live owner |

No teardown path calls a throwing API without mapping it: `dismiss()` is `Void` and cannot fail in a way the user should see; `discard`/`delete` return `Result` and their failures are events.

### 7.6 Why the sweep is safe when a read fails

`RoutineStore.loadEntries()` returns `[]` on a read failure — indistinguishable from "no routines". `EventExtrasStore.all` is likewise tolerant. A sweep built on either would compute an empty live set during a transient read failure and delete **every** instruction video on the device. That is the worst failure this feature can have, and it is a silent one.

The design removes the possibility rather than mitigating it:

1. `RoutineStore.loadEntriesIfReadable()` (exposed to composition as `RoutineScheduler.entriesIfReadable()`, which delegates to it) and `EventExtrasStore.snapshot()` are the only reads the sweep uses, and both return `nil` on failure. The strict read returns nil on any `storage.read` failure; because `EncryptedLocalStorage` reports a missing key as a read failure, a first-run or absent key also yields nil. That is the safe direction: the sweep skips the routines root instead of deleting videos. The legacy `loadEntries()` keeps its `[]`-on-failure contract for every existing caller and is never used to build a live set.
2. `LiveInstructionOwners` carries `nil` per root, and `purgeOrphanedOwners(in:live: nil, …)` is a no-op for that root.
3. The sweep never constructs a live set of its own, and it is never handed `[]` as a stand-in for "unknown".
4. A test plants a video, injects a failing `EncryptedLocalStorage` double into `RoutineStore`/`RoutineScheduler`, and asserts `entriesIfReadable()` is nil and the sweep leaves the video; the mirror test injects a readable-but-empty double, asserts `entriesIfReadable()` is `[]` (not nil) and the file is collected after the grace window; a third asserts the legacy `loadEntries()` still returns `[]` on the failing double. `RoutineStoreTests` (extended) and `RoutineSchedulerTests` (extended) carry the three.

---

## Performance & Security Patterns

### 8.1 Performance budgets and how each is measured

| Metric | Bound | Measurement | Evidence |
|---|---|---|---|
| Tap Play → full-screen player visible | ≤ 500 ms (NFR-RIE-008) | Release-build device smoke, 60 fps screen recording; tap frame → the frame where the cover is fully drawn | Recorded smoke (§11.5) |
| Player visible → first frame playing | ≤ 2 s (NFR-RIE-008) | Same recording; cover frame → first motion frame | Recorded smoke |
| Detectable failure → plain fallback | ≤ 1 s (NFR-RIE-008) | Simulator: missing file, unplayable file, player failure, each resolving through synchronous preflight or `AVPlayerItem.status` | `InstructionPlaybackControllerTests` (simulator) + recorded smoke for the on-device path |
| Unresponsive player → fallback (not a failure detection) | ≤ 10 s (`readyWatchdogSeconds`) | Injected `deadline` in unit tests | `InstructionPlaybackControllerTests` |
| Picker/recorder → accepted | no requirement bound; recorded | Recorded smoke: a 60 s clip and a 200 MiB clip through the 1 MiB chunked staging write, wall clock from the callback to `.ready` | Recorded smoke; OI-5 (chunk size) if the 200 MiB staging write stalls visibly |
| Card appearance | no bound; mechanism only | Image decode + one `stat`, once per appearance, never in `body` | `InstructionSurfaceTests` source pins |
| Launch | no new measurable work | Store init zero IO; sweep enqueued off-main; no timers | `InstructionVideoStoreTests`, `NoIOInInitTests` (extended) |

The 1 s fallback bound and the 10 s watchdog are deliberately distinguished: the NFR bounds **detection of a failure**, which the shipped adapter reports synchronously (preflight) or within a frame or two (`AVPlayerItem.status`). The watchdog is the ceiling for a *platform stall with no signal at all*, a state that is not one of the acceptance scenarios; calling it the failure path would misstate both the design and the test.

No new instrumentation (signposts, counters) is added. Timings come from the screen recording, which is how the house has measured device smokes and which cannot leak content.

### 8.2 IO discipline

1. **No IO in `init` or `body`.** The store resolves paths; the card loads in `.task`; the editor loads via its host, not its drawing.
2. **The only main-thread IO is deliberate:** the callback-scoped staging copy (unavoidable, §7.4), the availability `stat`, and the image decode (the shipping photo pattern). Everything else — validation, purging, orphan sweeping — runs off-main.
3. **No full-file `Data`.** Staging is a bounded chunked stream (1 MiB chunks through `InstructionStagingFileOps`) into the already-protected destination; there is no `copyItem` and no whole-file buffer. The probe reads metadata only; no frame is decoded, so no video frame ever enters memory.
4. **No thumbnail.** The card shows a play affordance and the caption; generating a thumbnail would decode a frame, add a cache, and add a failure path for no requirement.
5. **No per-tick events.** One event per user-visible outcome; availability events only for non-`.available`; playability checks are not logged on the success path beyond the playback `.ready`.
6. **Bounded work per input.** The 200 MiB and 180 s limits are enforced before staging; one file per owner; no unbounded directory walk beyond the two roots' immediate children.

### 8.3 Security threat model

| Threat | Control | Evidence |
|---|---|---|
| A crafted payload smuggles a path (a parent-directory segment, backslashes, an absolute path, an empty component, or the `.`/`..` components) | Bare-name guard (`InstructionFilename.isPlain`: non-empty, no separators, not `.` or `..`) before any name-derived URL is built — store `availability`/`fileURL`/`delete` and both image loaders; owner-directory guard; the model deliberately does not sanitise, the store does | F-11; `InstructionVideoStoreTests` and `InstructionImageLoadingTests` refusal cases |
| The bytes are readable while the device is locked | `.completeFileProtection` set on the destination at creation, before any byte; filled by a chunked stream; re-verified after the stream and after the commit rename; a weaker reported class fails closed and deletes the bytes | §5.3 create-order test + `InstructionStagingFileOpsSpy`; source scan for `copyItem` |
| Another app or a backup destination reads the video | `Application Support` (not Documents, not a shared container, not Photos), no share surface, no `UIActivityViewController`, no `NSFileProvider`; backup is allowed under the same protection class (D9) | NFR-RIE-005 test + source scan |
| The video leaves the device | No network API in `Services/Instructions` (no `URLSession`, no upload, no transcription, no `AVAssetExportSession`); no third-party SDK | `InstructionSourceHygieneTests` static scan (NFR-RIE-003) |
| Household words reach a log or a notification payload | No console writes in the three roots; typed emitters with closed vocabularies; notification payload carries a `Bool` only | §6.4–6.6; gate exit 0 |
| A malformed/oversized video exhausts memory, disk or the parser | 200 MiB and 180 s caps **before** the copy; no transcode; no frame decode; AVFoundation parses the file exactly as it would in any player | `InstructionVideoImportTests` limits cases; residual parser risk accepted (platform) |
| An instruction is shown to the wrong person | One owner per instruction; owner directory keyed by the owner; the fired screen derives the owner from the notification's `entry_id` | `InstructionVideoStoreTests` owner isolation |
| A crash loses the previous instruction | Ordered transaction (§5.6): bytes before index; index before delete | `InstructionVideoStoreTests` + service tests |
| Notification content leaks on the lock screen | No instruction text, caption or filename in the payload; only `had_instruction` | `RoutineNotificationSchedulerTests` |
| Permission over-reach | Camera/microphone only at the moment of recording; no photo-library write/read permission at all (the picker is out-of-process); a denial is respected with plain copy | `InstructionPermissionTests`, `InstructionCaptureTests` |

### 8.4 Privacy posture

Instruction media is household data of the most direct kind (a family member's face, a home, a medicine box). The design is therefore deliberately boring: on-device only, no processing, no upload, no analytics, no OCR, no transcription, no thumbnails, no sharing. The only observable trace of an instruction anywhere is a boolean in a notification payload and a sanitised event with a closed vocabulary.

---

## Configuration

### 9.1 Configuration types and defaults

| Value | Type | Default | Where it lives | Why this number |
|---|---|---|---|---|
| `maxDurationSeconds` | `TimeInterval` | `180` | `InstructionVideoLimits.standard` | Constitution OD-2 (3 minutes) |
| `maxBytes` | `Int64` | `209_715_200` | `InstructionVideoLimits.standard` | Constitution OD-2 (200 MiB, defined as 200 × 1024 × 1024) |
| `validationTimeoutSeconds` | `TimeInterval` | `20` | `InstructionVideoConfiguration.standard` | Metadata load for a 200 MiB local file plus margin; beyond this the person is staring at a stuck sheet |
| `orphanGraceSeconds` | `TimeInterval` | `60` | `InstructionVideoConfiguration.standard` | Covers commit→index write and any slow save; nothing genuinely live is younger *and* unindexed |
| `recordingQuality` | `InstructionRecordingQuality` | `.high` | `InstructionCaptureConfiguration.standard` | The OS already caps at 3 minutes; high quality keeps a medicine label readable |
| `preflightTimeoutSeconds` | `TimeInterval` | `0.6` | `InstructionPlaybackConfiguration.standard` | The shipped adapter completes preflight synchronously; this bounds a future async adapter before the tap feels dead |
| `readyWatchdogSeconds` | `TimeInterval` | `10` | `InstructionPlaybackConfiguration.standard` | A last-resort ceiling for a platform stall, far above the 2 s NFR bound |
| `stagingChunkBytes` | `Int` | `1_048_576` (1 MiB) | `InstructionVideoConfiguration.standard`, injected through `stageSynchronously(chunkBytes:)` | Bounded memory for the D18 chunked stream: peak memory is one chunk, and a 200 MiB file is 200 chunk reads, not thousands |

Every one of them is a `let` on a value type, constructed once in `AppCoordinator.init` from `.standard`, and injected into the seam that needs it. **No value is user-configurable**, none is read from `UserDefaults`, a remote config or an environment variable, and none is read from the clock or the locale inside a method body. Tests construct their own configuration values; production never passes one.

### 9.2 Async and external call register

| Call | Declaration | Timeout parameter | Default | Bound by | Failure mode | Recovery |
|---|---|---|---|---|---|---|
| System video picker | `InstructionVideoPicking.presentVideoPicker` | none by design | — | The person | `completion(.failure(.cancelled))` or `.unreadableSource`; a picker that never calls completion is an adapter contract violation (P-5) | The sheet stays closed; the person can pick again |
| System recorder | `InstructionVideoRecording.presentRecorder` | `maximumDurationSeconds` (hard cap) | 180 | The OS (`videoMaximumDuration`) **and** the post-hoc probe | `.cancelled` / `.unreadableSource` / `.tooLong` (a rounded 181 s recording) | Record again |
| Staging write (chunked stream) | `InstructionVideoStore.stageSynchronously` | none | — | The callback window; cumulative 200 MiB cap; exactly the step-2 byte count | `.tooLarge` (cumulative cap), `.unreadableSource` (read failure or truncated source), `.writeFailed(.stagingFailed)` / `.writeFailed(.protectionFailed)` (creation, write or protection) | Choose again |
| Synchronous probe | `InstructionVideoProbing.probe` | none | — | Metadata read only | `.unreadableSource` / `.unsupportedFormat` | Choose another file |
| Asynchronous inspection | `InstructionVideoInspecting.inspect` | none inside; bounded by the importer | — | `validationTimeoutSeconds` | Thrown errors → `.unreadableSource` | Choose again |
| Validation race | `InstructionVideoImporting.validate` | `validationTimeoutSeconds` | 20 | `deadline` seam | `.validationTimedOut`; inspector failure | Staged bytes discarded; choose again |
| Playback preflight | `InstructionPlaybackController.start` | `preflightTimeoutSeconds` | 0.6 | `deadline` seam | `.failed(.unsupported)` on timeout or an explicit adapter failure | Fallback line; Close |
| Playback ready | `InstructionPlaybackController.start` | `readyWatchdogSeconds` | 10 | `deadline` seam | `.failed(.timedOut)` | Fallback line; Close |
| Player item load | `AVKitInstructionVideoPlayer.present` | none; observed | — | The two controller timers | `.failed(.playerFailed)` / `.interrupted` | Fallback line; Close |
| EventKit create/update | `FreeFormEventGateway` (existing) | none (existing) | — | Existing behaviour | `nil` from `save` | Existing form behaviour |
| Encrypted index write | `EventExtrasStore` | none (synchronous) | — | — | `false` → `.persistenceFailed` | Save again |
| Routine store write | `RoutineStore` (existing) | none (synchronous) | — | — | `false` → `.persistenceFailed` | Save again |
| Launch purges | `purgePendingDrafts` / `purgeOrphanedOwners` | `graceSeconds` (eligibility, not a timeout) | 60 | Directory size | `.purgeFailed` with partial count | Next launch |
| Notification re-arm | `UNRoutineNotificationScheduler` | none (existing `add` completion) | — | — | Logged by the existing code path (unchanged) | Re-armed on the next `scheduleAll` |

Two honest notes. First, the two "no timeout" rows are the *point* of the callback-scoped rule: the work must complete inside a callback the OS times, so there is nothing for us to bound. Second, the staging write and the probe are the only main-thread stalls this feature can cause; both are capped by 200 MiB and 180 s, and both are measured in the device smoke (§8.1).

### 9.3 Values that are fixed by design, not configuration

| Fixed choice | Value | Why not configurable |
|---|---|---|
| Instructions per owner | 1 | Constitution OD-1; the UI has no room and the model has no list |
| Videos per owner | 1 file | NFR-RIE-007; every replace deletes or sweeps the previous |
| Pending layout | `<root>/_pending/<draftId>/payload.<ext>` | The same-volume rename depends on it |
| Stored filename | `instruction-<draftId>.<ext>` | Uniqueness per attempt; never rewritten in place |
| Owner directory digest | first 32 lowercase hex of SHA-256 | Collision resistance far beyond need; short enough to read |
| Owner directory prefix | `ev-` | Distinguishes event owners from routine UUIDs at a glance |
| Extension length | 1–8 lowercase alphanumerics | Bounded name; anything else becomes `mov` |

### 9.4 What a reviewer should check about these numbers

1. Every number above is referenced by name in the code, never spelled twice. `180` appears in `InstructionVideoLimits.standard` and in the recorder call, and the recorder's value is *read from* the limits struct.
2. The 0.6 s / 10 s pair is owned by one type (P-1) and injected through one `deadline` seam, so a test can drive both without sleeping.
3. The 20 s validation bound is the only wait a person experiences without a visible progress state (the sheet shows its validating state); every other bound resolves to a line of copy.

---

## Accessibility & Localisation

### 10.1 Tokens and the per-control floor

| Control / text | Token or value | Floor | Notes |
|---|---|---|---|
| Play (card) | `DesignTokens.minTapTargetSize` (44) | 44×44 pt | Icon button with an explicit label; the whole card is not the only target |
| Close (playback cover) | `DesignTokens.minTapTargetSize` (44) | 44×44 pt | A labelled text button in the cover's bottom bar, reachable one-handed |
| Add / Change / Remove instruction rows | `DesignTokens.chipHeight` (60) and full width | ≥ 44 pt | Standard settings rows, like the existing photo row (`RoutineSettingsView.swift:107–116`) |
| Kind picker (Text / Photo / Video) | three 44 pt segmented buttons | 44×44 pt | Labels are the kind names, matching §10.5 rows 5–7; the selected state is also conveyed by a checkmark, not colour alone |
| Editor text and caption fields | `AppTypography.bodyPointSize` (21 scaled) | 18 pt | Caption uses the 18 pt caption size |
| Card text instruction | `AppTypography.bodyPointSize` | 18 pt | Wraps; no truncation |
| Card caption | `AppTypography.captionPointSize` (18) | 18 pt | One or two lines, wraps |
| Fire-time line | `AppTypography.captionPointSize` (18) | 18 pt | Rendered through `LocaleFormatters.shortTime(locale:)` |
| Player transport | system `VideoPlayer` controls | system | No custom transport; nothing to re-size |
| Validating / preparing state | body text | 18 pt | Text plus the system progress indicator; no spinner without a label |

### 10.2 Dynamic Type and the accessibility viewport

- The card and the fired footer use the `[AX-VIEWPORT]` pattern the routine fired screen already uses (`VisualAidViews.swift:170–174`): at accessibility sizes the content stack is wrapped in a `ScrollView` so nothing clips and Play/Close remain reachable.
- The playback cover's bottom bar uses scaled text and a fixed 44 pt target; at the largest sizes the label wraps rather than shrinking.
- The editor is hosted in a scrollable sheet; the keyboard never covers the caption field (the host's existing behaviour).
- No layout uses a fixed height for text. `lineLimit` is used only on the caption (2 lines) and the time (1 line), both of which are optional embellishments; the instruction text itself is never truncated.

### 10.3 VoiceOver

| Element | Label | Trait / hint |
|---|---|---|
| Card, text instruction | the text itself | static text |
| Card, image | `instruction.image.accessibility` ("Instruction photo") | image |
| Card, image fallback line | `instruction.image.unavailable` | static text |
| Card, video play button | `instruction.video.accessibility` ("Instruction video. Play") | button |
| Card, video fallback line | `instruction.video.unavailable` | static text |
| Card, unsupported | `instruction.unsupported` after any text | static text |
| Fired screen, removed | `instruction.removed` | static text |
| Fired screen, owner unavailable | `instruction.reminderUnavailable` | static text; the Close button follows |
| Editor, foreground-only note | `instruction.foregroundNote` | static text |
| Fire-time line | `instruction.atTimeFormat` ("At %@") resolved through `L10n.fmt` | static text |
| Cover, preparing | `instruction.video.preparing` | updates to the player when ready |
| Cover, Close | `common.close` | button |
| Editor, Add/Change/Remove | the row's own text | button |
| Editor, Use this video | `instruction.useVideo` | button |
| Editor, Done | `instruction.done` | button |
| Permission note | the denial key | static text |

VoiceOver order on a fired screen: title → fire time (only when the D6 gate holds, §4.10) → instruction card → Close; a photo-only firing has no time line. On the owner-unavailable screen: the notice → Close (there is no title or time). On the cover: the player (system) → Close. No element is reachable only by gesture; nothing is swipe-only.

### 10.4 Motion, contrast and reach

- **Reduce Motion:** no custom animation is added. The cover uses the system's `.fullScreenCover` transition, which honours the setting; the card's image simply appears.
- **Contrast:** the cover's bottom bar is white-on-black with the system's dynamic colours; nothing is conveyed by colour alone (the selected kind carries a checkmark; errors are text, not red-only).
- **Reach:** Play sits in the card, which is in the footer stack of the fired screen (bottom half); Close sits in the cover's bottom bar. Both are thumb-reachable on the reference device with one hand.
- **No fine motor:** no long-press, no drag, no swipe to dismiss as the only path; every action is a tap on a ≥ 44 pt target.

### 10.5 Localisation keys (en + ne)

New keys, all in `Localizable.xcstrings`, both languages, no English fallback in `ne`. Keys reused from the shipping catalogue are marked **reuse** and are not duplicated.

| # | Key | English | Nepali |
|---|---|---|---|
| 1 | `instruction.title` | Instruction | निर्देशन |
| 2 | `instruction.add` | Add instruction | निर्देशन थप्नुहोस् |
| 3 | `instruction.change` | Change instruction | निर्देशन बदल्नुहोस् |
| 4 | `instruction.remove` | Remove instruction | निर्देशन हटाउनुहोस् |
| 5 | `instruction.kind.text` | Text | पाठ |
| 6 | `instruction.kind.image` | Photo | फोटो |
| 7 | `instruction.kind.video` | Video | भिडियो |
| 8 | `instruction.textPlaceholder` | Write the instruction | निर्देशन लेख्नुहोस् |
| 9 | `instruction.image.change` | Change photo | फोटो बदल्नुहोस् |
| 10 | `instruction.image.unavailable` | This photo can't be shown. | यो फोटो देखाउन सकिएन। |
| 11 | `instruction.image.accessibility` | Instruction photo | निर्देशनको फोटो |
| 12 | `instruction.video.add` | Choose a video | भिडियो छान्नुहोस् |
| 13 | `instruction.video.record` | Record a video | भिडियो रेकर्ड गर्नुहोस् |
| 14 | `instruction.video.change` | Change video | भिडियो बदल्नुहोस् |
| 15 | `instruction.video.play` | Play | चलाउनुहोस् |
| 16 | `instruction.video.unavailable` | This video can't be played right now. | यो भिडियो अहिले चलाउन सकिएन। |
| 17 | `instruction.video.preparing` | Getting the video ready… | भिडियो तयार हुँदैछ… |
| 18 | `instruction.video.validating` | Checking the video… | भिडियो जाँच हुँदैछ… |
| 19 | `instruction.video.tooLong` | That video is too long. Choose one 3 minutes or shorter. | यो भिडियो धेरै लामो छ। ३ मिनेटसम्मको भिडियो छान्नुहोस्। |
| 20 | `instruction.video.tooLarge` | That video is too big for this phone. Choose a smaller one. | यो भिडियो यो फोनका लागि धेरै ठूलो छ। सानो भिडियो छान्नुहोस्। |
| 21 | `instruction.video.unreadable` | That video can't be played on this phone. Choose a different one. | यो भिडियो यो फोनमा चल्दैन। अर्को भिडियो छान्नुहोस्। |
| 22 | `instruction.video.saveFailed` | The video couldn't be saved. Try again. | भिडियो बचत हुन सकेन। फेरि प्रयास गर्नुहोस्। |
| 23 | `instruction.video.recordingLimit` | Recording stops by itself after 3 minutes. | रेकर्डिङ ३ मिनेटपछि आफै रोकिन्छ। |
| 24 | `instruction.camera.denied` | To record a video, allow the camera in Settings. | भिडियो रेकर्ड गर्न सेटिङमा क्यामेरा अनुमति दिनुहोस्। |
| 25 | `instruction.microphone.denied` | To record a video, allow the microphone in Settings. | भिडियो रेकर्ड गर्न सेटिङमा माइक्रोफोन अनुमति दिनुहोस्। |
| 26 | `instruction.camera.unavailable` | The camera isn't available right now. You can choose a video instead. | क्यामेरा अहिले उपलब्ध छैन। तपाईं भिडियो छान्न सक्नुहुन्छ। |
| 27 | `instruction.saveFailed` | Your changes weren't saved. Try again. | तपाईंका परिवर्तन बचत हुन सकेनन्। फेरि प्रयास गर्नुहोस्। |
| 28 | `instruction.savePartial` | The video couldn't be saved. Add it again from the event. | भिडियो बचत हुन सकेन। कार्यक्रमबाट फेरि थप्नुहोस्। |
| 29 | `instruction.removed` | This instruction is no longer available. | यो निर्देशन अब उपलब्ध छैन। |
| 30 | `instruction.unsupported` | This instruction may not show correctly. | यो निर्देशन राम्ररी देखिन नसक्ने हुन सक्छ। |
| 31 | `instruction.useVideo` | Use this video | यो भिडियो प्रयोग गर्नुहोस् |
| 32 | `instruction.done` | Done | भयो |
| 33 | `instruction.video.accessibility` | Instruction video. Play | निर्देशनको भिडियो। चलाउनुहोस् |
| 34 | `instruction.atTimeFormat` | At %@ | %@ बजे |
| 35 | `instruction.reminderUnavailable` | This reminder is no longer available. | यो सम्झना अब उपलब्ध छैन। |
| 36 | `instruction.foregroundNote` | This video plays only when the app is open. | यो भिडियो एप खोलेर मात्र हेर्न सकिन्छ। |
| — | `visualAid.add` | **reuse** — "Add photo" / "फोटो थप्नुहोस्" | — |
| — | `visualAid.captionPlaceholder` | **reuse** — "Caption (optional)" / "विवरण (वैकल्पिक)" | — |
| — | `common.cancel`, `common.close` | **reuse** | — |

`instruction.atTimeFormat` uses a positional argument through `L10n.fmt(_:locale:_:)` (`App/L10n.swift`), not string concatenation, because Nepali puts the time before "बजे" and English puts "At" first. That is the only formatting key in the feature.

The two restored keys are behaviour-bearing: `instruction.reminderUnavailable` is the B-1 owner-deleted notice and `instruction.foregroundNote` is the FR-RIE-024 foreground-only statement (editor helper text; the feature report repeats it). Rows 35–36 are appended, not renumbered, so earlier key numbers stay stable.

### 10.6 Usage descriptions — `Info.plist` (English) and `InfoPlist.strings` (D10)

FR-RIE-025's acceptance reads the **shipped `Info.plist`**, so the base English values are the contract and the fallback. L1 D10's split is kept exactly: the plist carries amended English; the `en` and `ne` `InfoPlist.strings` resources carry the localised copy. A strings-only change would leave the fallback stale on any system language other than English or Nepali and would fail the locked scenario.

**`ios/ElderlyAssistant/Info.plist` — amended values (exact).** Both descriptions retain every existing disclosure and add video recording and on-device storage. `NSCameraUsageDescription` (`:113–114`) becomes:

```text
The camera is used to verify medication intake, to photograph appliances, remotes, or screens when you ask for help using them, and to take an ordinary photo when you ask for one — that photo is then saved to your photo library. The camera is also used to read printed text aloud in your language with live translation. Appliance photos are sent to the assistant's cloud service so it can guide you. For live translation, only the text seen by the camera is sent — and only when the phone's own dictionary cannot translate it. Photos of that text are never sent. When you tap "what is this?", the small picture of the tapped thing — only that picture, and nothing else from your camera — is sent to the assistant's cloud service to work out what it is. The camera can also record a short instruction video for a reminder; that video stays on this phone and is never uploaded or shared.
```

`NSMicrophoneUsageDescription` (`:121–122`) becomes:

```text
The assistant needs microphone access to hear your voice commands. By default your speech goes to Gemini, a cloud service, to be turned into text — you can switch to a fully on-device engine in Settings → Voice Engine. The microphone is also used to record the sound in a short instruction video for a reminder; that recording stays on this phone and is never uploaded or shared.
```

The retained disclosures are explicit, not implied: camera — medication-intake verification, appliance/remote/screen photos and their cloud use, ordinary photos saved to the photo library, live translation and its text-only cloud exception, and the "what is this?" picture exception; microphone — voice commands, Gemini by default, and the in-app Voice Engine setting. The new clauses say "record a short instruction video" and "stays on this phone and is never uploaded or shared".

**New files, both languages.**

- `ios/ElderlyAssistant/Resources/en.lproj/InfoPlist.strings` — both keys; values **byte-identical to the plist English above**. A test pins the equality, so the two English copies cannot drift.
- `ios/ElderlyAssistant/Resources/ne.lproj/InfoPlist.strings` — both keys, full translations, not partial ones: a half-translated permission dialog is worse than an English one.

| Key | Nepali value (exact) |
|---|---|
| `NSCameraUsageDescription` | क्यामेरा औषधि सेवन पुष्टि गर्न, तपाईंले सहयोग माग्नुहुँदा उपकरण, रिमोट वा स्क्रिनको फोटो खिच्न, र तपाईंले भन्नुहुँदा साधारण फोटो खिच्न प्रयोग गरिन्छ — त्यो फोटो त्यसपछि तपाईंको फोटो लाइब्रेरीमा सुरक्षित गरिन्छ। क्यामेरा तपाईंको भाषामा छापिएको अक्षर लाइभ अनुवादसँगै ठूलो स्वरमा पढ्न पनि प्रयोग गरिन्छ। उपकरणका फोटो असिस्टेन्टको क्लाउड सेवामा पठाइन्छ ताकि यसले तपाईंलाई मार्गदर्शन गर्न सकोस्। लाइभ अनुवादका लागि क्यामेराले देखेको अक्षर मात्र पठाइन्छ — र त्यो पनि फोनको आफ्नै शब्दकोशले अनुवाद गर्न नसकेको अवस्थामा मात्र। ती अक्षरका तस्बिर कहिल्यै पठाइँदैनन्। तपाईंले "यो के हो?" ट्याप गर्नुहुँदा ट्याप गरिएको वस्तुको सानो तस्बिर — त्यो तस्बिर मात्र, क्यामेराको अरू केही होइन — असिस्टेन्टको क्लाउड सेवामा पठाइन्छ ताकि यो के हो भनेर पत्ता लगाउन सकियोस्। क्यामेरा सम्झनाका लागि छोटो निर्देशन भिडियो रेकर्ड गर्न पनि प्रयोग गरिन्छ; त्यो भिडियो यही फोनमा रहन्छ र कहिल्यै अपलोड वा साझा गरिँदैन। |
| `NSMicrophoneUsageDescription` | असिस्टेन्टलाई तपाईंका आवाज आदेश सुन्न माइक्रोफोनको अनुमति चाहिन्छ। पूर्वनिर्धारित रूपमा तपाईंको बोली जेमिनी, एउटा क्लाउड सेवामा पठाइन्छ, अक्षरमा बदल्न — तपाईं सेटिङ → भ्वाइस इन्जिनमा गएर पूर्ण रूपमा फोनभित्रै चल्ने इन्जिन रोज्न सक्नुहुन्छ। माइक्रोफोन सम्झनाका लागि छोटो निर्देशन भिडियोको आवाज रेकर्ड गर्न पनि प्रयोग गरिन्छ; त्यो रेकर्डिङ यही फोनमा रहन्छ र कहिल्यै अपलोड वा साझा गरिँदैन। |

**Build registration.** `Resources` is excluded from the XcodeGen source glob (`ios/project.yml:101–103`), so each strings file is declared explicitly in `ios/project.yml` with `buildPhase: resources` — the same single-file pattern as `Localizable.xcstrings` (`:108–109`). `knownRegions` already carries `en` and `ne` (`:22–25`), and the shipped plist's `CFBundleLocalizations` already lists both (`Info.plist:21–25`), so the OS can resolve either localisation. Without the two entries the files never enter the app bundle and every system language falls back to the plist English.

**The limit, stated plainly.** The OS permission dialog uses the *system* language, not the app's in-app language setting. A household running the app in Nepali on an English-system phone will see the amended English plist text. Adding these files makes the Nepali dialog correct on a Nepali-system phone; the surface that is *guaranteed* to be localised is the in-app plain-text explanation (`instruction.camera.denied` / `.microphone.denied`), which follows the app language. This is recorded in §12 as R-9 and is not something the app can fix.

**Text pin.** `L10nCatalogCoverageTests` reads the source plist and parses both source `InfoPlist.strings` files, and reads the **built app bundle's** `en.lproj/InfoPlist.strings` and `ne.lproj/InfoPlist.strings` resources (§11.2, §11.3 N). A dropped disclosure, a drifted English copy, a partial Nepali file, a new usage key or a missing `project.yml` registration fails the gate. The test does not use `Bundle.main.object(forInfoDictionaryKey:)`: the base plist already carries both amended English values, so that call returns non-empty English even when neither strings file shipped, and it cannot detect a missing Nepali resource.

No new usage-description key is needed: the picker is out of process and writes nothing to Photos, so the shipped `NSPhotoLibraryAddUsageDescription` (`:123–124`) stays exactly as it is and no photo-read key is added.

### 10.7 Copy voice

1. Second person, plain words, one sentence per idea. No jargon ("codec", "transcode", "MP4"), no error codes, no internal names.
2. A failure names the fix in the same sentence. "Choose a smaller one." "Try again."
3. No blame and no drama: "Your changes weren't saved", not "Failed".
4. No rhetorical questions and no numbered instructions — the instruction text is the family's, not ours.
5. Nepali mirrors the English meaning, not its word order; `instruction.atTimeFormat` is the worked example.
6. Nepali numerals in copy follow the shipping catalogue's convention (Devanagari digits inside Nepali sentences, e.g. "३ मिनेट").

---

## Test Plan

### 11.1 Gates

1. **Focused suites per unit** while building (house rule: no full suite per change).
2. **Typecheck / build**: `xcodebuild test` for the focused suites, `./build.sh` for the app (the canonical build; `xcodebuild build` alone is not the gate in this repo).
3. **Release-log gate**: `ios/tools/check-release-log-safety.sh --self-test` and the plain run via `ios/build.sh`.
4. **Localisation**: `L10nCatalogCoverageTests` (both languages, distinct values, no key-as-value).
5. **Full suite once at the end**, compared against the known baseline; zero new failures.
6. **One Release-build device smoke** (§11.5).
7. **No UI test** (NFR-RIE-009, OD-7).

### 11.2 Suite → requirement map

`ext` = existing suite extended; `new` = created by this feature. The constitution's gate list is a subset of this table; every suite it names is present.

| Suite | Status | Evidences |
|---|---|---|
| `InstructionModelTests` | new | FR-RIE-001 (raw kind `"text"`), 002, 003; NFR-RIE-006; resolvedWrite truth table; isPresent; payload nulling; duration rounding (180.0 / 180.2 / 180.5 / 181 / NaN) |
| `InstructionDisplayStateTests` | new | FR-RIE-017, 020, **024** (a future/unknown kind yields `.unsupported` and no fake Play/photo/link control); NFR-RIE-006; four availability classes; no-filename assertion |
| `InstructionObservabilityTests` | new | NFR-RIE-004; exact event names, components, outcomes, field names; only allowed keys; zero content; sanitised output |
| `InstructionVideoStoreTests` | new | FR-RIE-011, 012, 013, 014; NFR-RIE-005, 007; **pre-staging no-file test**; **create-before-bytes ordering, chunked-stream cleanup (mid-stream, truncation, cumulative cap, weaker class at creation and after the stream), and a source scan proving no `copyItem` in the staging path**; protection/delete failures; staging/commit/discard; four availability classes; owner isolation; pending purge; orphan sweep incl. nil-live safety; refusal of an empty name and of `.` / `..` (N-4) |
| `InstructionVideoImportTests` | new | FR-RIE-005, 006, 007, 009, 010; NFR-RIE-009 (≥ 4 scripted outcomes); limits; timeout + discard; cancel |
| `InstructionCaptureTests` | new | FR-RIE-004, 005, 007, 009, 010, 025; NFR-RIE-009; callback-scoped staging; single-flight; cancellation; permission denial; consume/discard |
| `InstructionPermissionTests` | new | FR-RIE-025; status mapping; **camera-then-microphone request order** with denial short-circuit; no re-prompt when denied; no `unavailable` trap |
| `InstructionPlaybackControllerTests` | new | FR-RIE-018 (the controller exists only after the Play tap; closing stops audio), 020 (the failed state renders the fallback); NFR-RIE-008 (failure detection paths), NFR-RIE-009 (seam + scripted outcomes: ready, failed, interrupted, timeout, close, **`finished`**; late events ignored) |
| `InstructionPlaybackAdapterTests` | new | NFR-RIE-009; source pins: no timers, KVO present, no transcode, no network |
| `InstructionImageLoadingTests` | new | FR-RIE-017, 020, **024**; both loaders (visual-aid and event-photo); filename guard (empty, `.`, `..`, `/`, `\`) before any store read; missing and unreadable files map to the plain fallback; no Photos/share surface |
| `InstructionSurfaceTests` | new | FR-RIE-017, 018, 019 (the `.unavailable` notice and Close), 020, **024** (no link/URL/YouTube control, no background-playback claim, `instruction.foregroundNote`); NFR-RIE-001 (44/18 floors, labels), NFR-RIE-002 (no hardcoded literals), NFR-RIE-010 (`none` renders `EmptyView`; D6 fire-time gate: `timeText` is non-nil only when an instruction is present or `expectsInstruction`, and a photo-only firing has no time line) |
| `RoutineSettingsInstructionTests` | new | FR-RIE-001, 002, 003, 008, 009 |
| `RoutineEntryTests` | ext | NFR-RIE-006 (F-1, F-3 … F-8, F-10, F-12) |
| `RoutineStoreTests` | ext | NFR-RIE-006 end-to-end through the encrypted store; **NFR-RIE-007 strict read: `loadEntriesIfReadable()` is nil on a failing `EncryptedLocalStorage` double (a missing-key read failure included) and `[]` on a readable-but-empty one; legacy `loadEntries()` still returns `[]` on failure** |
| `EventExtrasStoreTests` | ext | FR-RIE-002, 012; NFR-RIE-006; **`setPhotoFilename` / `setInstruction` preservation pair** |
| `FreeFormEventServiceTests` | ext | FR-RIE-001, 008, 009, 010, 012, 014; save outcome matrix; teardown |
| `FreeFormEventFormTests` | ext | FR-RIE-008, 009, 010; prefill; partial outcome |
| `RoutineSchedulerTests` | ext | FR-RIE-012, 013, 014, **021** (scoped cancel: one routine's identifiers only; source pin: never `removeAllPendingNotificationRequests`), 023; NFR-RIE-007 (one file after N replaces; re-arm creates no copy; **`entriesIfReadable()` delegates to the strict store read: nil ⇒ the routines-root sweep is a no-op, readable-but-empty ⇒ collection after the grace window**); NFR-RIE-010 |
| `RoutineVisualAidFireHandlerTests` | ext | FR-RIE-015, 016, 019; NFR-RIE-010; **three tap cases (including the deleted owner reaching the tap sink with a nil entry) + photo-only no-op + pre-upgrade missing key** |
| `FreeFormEventFireHandlerTests` | ext | FR-RIE-016, 017, 019; NFR-RIE-010 |
| `RoutineNotificationSchedulerTests` | new | FR-RIE-015 (content parity with the shipping scheduler at fire time), 018 (no video action), **021** (the content builder sets no category or action), **022** (attachment assertions on schedule, re-arm and the event path: no video attachment, the first-photo attachment unchanged, no per-occurrence copy); NFR-RIE-004 (payload carries a Bool only); NFR-RIE-010 (title/body/sound/identifier unchanged) |
| `AppCoordinatorInstructionTests` | new | FR-RIE-019 (tap resolution into `.reminder` / `.unavailable`), 023; NFR-RIE-010; composition; partial-outcome surfacing; no launch behaviour change |
| `InstructionSourceHygieneTests` | new | NFR-RIE-003 (no network/upload/transcode call sites), NFR-RIE-005 (no Photos/share APIs) |
| `L10nCatalogCoverageTests` | ext | NFR-RIE-002 (the 36 keys, en + ne, distinct); **FR-RIE-025** (text pins over the shipped `Info.plist`, both source `InfoPlist.strings`, and the built app bundle's `en.lproj`/`ne.lproj` resources, §11.3 N) |
| `NoIOInInitTests` | ext | The boot contract: `InstructionVideoStore.init` performs zero file IO (source pin + base-directory-absent check) |
| `DesignTokensTests` | unchanged | NFR-RIE-001 tokens |
| `NotificationCategoriesTests` | unchanged | **FR-RIE-021** (full-REPLACE set: exactly the medication and event categories, no instruction category or action, both languages); NFR-RIE-010 |
| `VisualAidStoreTests` | ext (one test) | NFR-RIE-010; an instruction image and a visual aid coexist; deleting one leaves the other |
| `VisualAidDisplayStateTests`, `MedicationVisualAidFireHandlerTests`, medication suites | unchanged | NFR-RIE-010 baseline |

### 11.3 Required cases, spelled out

**A. Pre-copy no-file test (store).**
`stageSynchronously` with (i) an absent URL, (ii) a directory URL, (iii) a source larger than `maxBytes`, (iv) a probe returning `.unsupportedFormat`, (v) a probe returning a duration that rounds to 181 — each returns the expected typed error **and** leaves no `_pending/<draftId>` directory behind. The size/duration/probe rejections must precede any staging: the spies assert zero `createDirectory`, zero destination creation and zero stream calls. A probe at exactly 180 s is accepted — the cap is inclusive — while 180.5 s rounds to 181 and is refused.

**B. The three tap cases (handler + composition).**
1. `had_instruction == true`, entry present, instruction present ⇒ `onInstructionTap` called once with `(entryId, entry, deliveryDate)`; `presentRoutineInstructionTap` builds `.reminder` and the card state is the instruction's own kind.
2. `had_instruction == true`, entry present, instruction absent ⇒ `onInstructionTap` called once; the card state is `.removed` (asserted through `InstructionPresentation`) while the title and fire time remain.
3. `had_instruction == true`, entry deleted ⇒ `onInstructionTap` called once with `(entryId, nil, deliveryDate)`; `presentRoutineInstructionTap` builds `.unavailable`; `RoutineVisualAidOverlay` renders the shared `ReminderVisualAidScreen` with `aids: []`, title `instruction.reminderUnavailable` and an `EmptyView` footer, and Close dismisses (`InstructionSurfaceTests` source-pins that branch and asserts the key in both languages; `AppCoordinatorInstructionTests` asserts the nil entry builds `.unavailable`); `FiredRoutineVisualAids.Content.unavailable` carries no title or time; `willPresent`/`didReceive` both return `false` on every path.
Plus the two negatives: photo-only (`had_instruction == false`/absent) tap does nothing (NFR-RIE-010); a pre-upgrade payload with no key reads `false` and a *foreground* delivery still presents when the entry now has an instruction.

**C. M-1 migration regressions (NFR-RIE-006; FR-RIE-024).** F-1, F-2, F-3 … F-10, F-12 across `RoutineEntryTests`, `EventExtrasStoreTests`, `RoutineStoreTests`; F-3 pins the raw kind `"text"`; F-6a/F-6b prove an independently unknown kind (`"link"`, `"audio"`) round-trips verbatim and displays no play/photo/link control; no forced rewrite (encode-then-decode of a legacy payload adds no key).

**D. Four availability classes and the no-filename assertion.**
`availability` returns `.available(url)` for a real file; `.rejectedFilename` for `"../x.mov"`, `"a/b.mov"`, `"..\\x"`, the empty string, `"."` and `".."`; `.missingFile` for an absent name; `.unreadableFile` for a file the spy reports unreadable. The empty and dot-only inputs matter because each would otherwise resolve to the owner directory itself rather than a file. Both image loaders run the same guard before touching the store, so an empty or dot-only name yields `.rejectedFilename` and no store call. `InstructionVideoStoreTests` carries the store rows and `InstructionImageLoadingTests` the two loader rows. `InstructionPresentation` maps an image/video instruction with `filename == nil` to `.none` (never a card with an empty control), and `.none` is pinned to `EmptyView` at source.

**E. Protection at creation, the create-before-bytes order and staging failures.** All cases run in `InstructionVideoStoreTests`, with an `InstructionFileManagerSpy` and an `InstructionStagingFileOpsSpy` sharing one ordered call log.

1. **Create-then-write order.** Staging a valid source asserts the log shows `createProtectedFile` (carrying `.completeFileProtection`) **before the first chunk write**; the ordering assertion is explicit, not inferred, and the destination did not exist with any class before the creation call. The create call is also asserted by source pin on `.completeFileProtection` in the `stageSynchronously` and owner-directory creation regions (the `MedicationEvidenceStoreTests:396` idiom).
2. **No `copyItem`.** A source scan over `InstructionVideoStore.swift` (the `FeatureSourceScan.codeText` region idiom, comments stripped) asserts zero `copyItem` calls: the only staging path is create-file-then-stream.
3. **Weaker class at creation.** The seam reports `.completeUntilFirstUserAuthentication` on the read immediately after creation ⇒ `.writeFailed(.protectionFailed)`, the file is gone and the draft directory is gone.
4. **Weaker class after the stream.** The same report only on the post-stream read ⇒ the same failure and the same cleanup; the committed-file verification in `commit` stays and is covered by its own case.
5. **Mid-stream failure.** The seam fails the n-th write (and, separately, the n-th read) after k bytes ⇒ `.writeFailed(.stagingFailed)` / `.unreadableSource`, with no file and no `_pending/<draftId>` directory left.
6. **Truncated source and cumulative cap.** A seam that delivers fewer bytes than the step-2 size ⇒ `.unreadableSource` and the partial file is deleted; a source whose metadata is under the cap but whose cumulative stream passes `maxBytes` ⇒ `.tooLarge` and the partial file is deleted.
7. **Kill-window invariant.** A test stops staging at each seam call (after creation, mid-stream) to simulate a kill: any surviving file reports (or was requested with) `.complete`, is empty or partial, and is removed by `purgePendingDrafts()` after the grace window — never a weaker-class file.
8. **Attribute when reported.** The attribute read is asserted when the platform reports one; R-5 records why it is conditional.
9. **Delete failures.** A spy whose `removeItem` throws ⇒ `.deleteFailed`; delete/deleteAll of an absent owner ⇒ `.success` and zero calls to `removeItem`.

**F. `setPhotoFilename` preservation.** The two-order pair in §4.5, plus a test that a photo change and an instruction change in sequence leave both fields intact and the row count at 1.

**G. Draft truth table.** All six rows of §4.2; `revert()` clears `hasChanges`; a `.failed` draft cannot resolve a write; a text write cannot carry `pendingMedia`; a media write with neither filename nor pending media fails the service with `.unresolvedPayload`.

**H. Notification payload.** `had_instruction` round-trips as a `Bool`; the key is absent only for pre-upgrade payloads and reads `false`; no instruction text/filename/URL key exists anywhere in `userInfo`; title, body, sound, identifier and the absence of a category are identical to today's content (a field-by-field comparison against a fixture built from the shipping shape).

**I. Playback timers and late events.** With an injected manual `deadline`: preflight expiry ⇒ `.failed(.unsupported)`; ready expiry ⇒ `.failed(.timedOut)`; `.preflightPassed` then `.ready` ⇒ `.playing` and the watchdog cancelled; `.failed` then `.ready` ⇒ still failed; `close()` then `.ready` ⇒ ignored; `start()` twice ⇒ one `present`; `.ready` then `.finished` ⇒ the finished state, watchdog cancelled, no failure surfaced and the Close control still available; `close()` (Close) after `.ready` drives the adapter's `dismiss()`, which pauses before releasing — the spy records `pause` before `dismiss` and the controller emits one `.closed`.

**J. Capture contract.** A fake picker that calls `makeStagedCopy` and then `completion` proves staging happens before completion returns; a fake that never calls completion leaves the sheet in `.picking` (documented contract violation, no hang in the coordinator because it is callback-driven, not `await`ed); `pick()` while `.validating` is a no-op; `cancel()` discards.

**K. Orphan safety (strict reads).** Plant a video, inject a failing `EncryptedLocalStorage` double into `RoutineStore`/`RoutineScheduler` ⇒ `entriesIfReadable()` is nil and the sweep leaves the planted video; inject a readable-but-empty double ⇒ `entriesIfReadable()` is `[]` (not nil) and the sweep collects the video after the grace window; assert the legacy `loadEntries()` still returns `[]` on the failing double. `RoutineStoreTests` (extended) carries the store-level triple and `RoutineSchedulerTests` (extended) the delegation plus sweep pair. A directory younger than grace is never collected; an unparseable directory name is never collected; an in-flight name is never collected; `deleteFailed` leaves the owner out of the live set so the next sweep retries.

**L. Single-file invariants.** After N replaces: exactly one file in the owner directory (previous deleted or swept, never two at steady state); after delete: zero; after re-arm/`scheduleAll`: unchanged count and no new `_pending` entry (NFR-RIE-007).

**M. Baseline preservation.** `NotificationCategoriesTests` green; medication suites green; `git diff --stat` over `Services/MedicationScheduler` and `MedicationVisualAidFireHandler.swift` empty; the fired screen for a photo-only entry renders the same view tree (source pin: same overlay, the `.none` card is `EmptyView`, the footer is `EmptyView`, and `timeText == nil` — the photo-only firing has no time line; `VisualAidViews.swift:283–289` is the anchor); banner/list/sound unchanged (H).

**N. Localisation and usage disclosure (FR-RIE-025).** The 36 keys resolve in en and ne to non-key, distinct values; a source sweep finds no user-visible string literal in the new view files outside `Localizable.xcstrings` lookups (the `L10nCatalogCoverageTests` sweep idiom).

The same suite reads the shipped source plist through its existing `sourceInfoPlist()` helper (`FeatureSourceScan.iosDirectory()/ElderlyAssistant/Info.plist`) and asserts: (i) `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` each contain every retained disclosure clause from §10.6 **and** the new video clauses ("record a short instruction video", "stays on this phone and is never uploaded or shared"); (ii) `CFBundleLocalizations` still lists en and ne; (iii) no new `NS*UsageDescription` key exists. It parses `Resources/en.lproj/InfoPlist.strings` and `Resources/ne.lproj/InfoPlist.strings` as property lists and asserts both keys are present and non-empty; the en values equal the plist English byte-for-byte, and the ne values equal the exact §10.6 Nepali strings and contain Devanagari. **Built-bundle registration evidence** — this is what a missing `project.yml` entry must fail. The unit tests are app-hosted (`TEST_HOST`, `ios/project.yml:371–372`), so the suite resolves the host app bundle from `Bundle.main.bundleURL` and asserts that `en.lproj/InfoPlist.strings` and `ne.lproj/InfoPlist.strings` each exist inside that built bundle. It parses each file from the bundle (`NSDictionary(contentsOf:)`) and asserts both keys and their exact values: the en values equal the source plist English, and the ne values equal the exact §10.6 Nepali strings and contain Devanagari. A missing registration fails because the resource is absent from the built bundle. The source-plist and source-strings pins above are kept and are complementary: they catch a drifted source file; the built-bundle assertions catch a file that never shipped.

**O. Accessibility source pins.** Each control in §10.1 carries the token or the explicit frame; each VoiceOver label exists; no gesture recogniser is the only path; the AX viewport branch exists in the card.

**P. Source hygiene (NFR-RIE-003 / 005).** `Services/Instructions` and `App/InstructionViews.swift`/`InstructionCapture.swift` contain no `URLSession`, `upload`, `transcribe`, `AVAssetExportSession`, `PHPhotoLibrary`, `UIActivityViewController`, `NSFileManager` writes to Documents, or `isExcludedFromBackup`.

**Q. Honest capability surface (FR-RIE-024).**
1. `InstructionDisplayStateTests`: F-6a (`"link"`) and F-6b (`"audio"`) load, preserve the owner, map to `.unsupported`, and expose no Play, photo or link control; the owner's other fields survive.
2. `InstructionSurfaceTests` source scan (the `FeatureSourceScan.codeText` idiom over the whole new UI files and the `[REMINDERS-INSTRUCTIONS]` regions of the shared views; comments are stripped): no `YouTube`, `youtube`, `http://`, `https://`, `Link(`, `openURL` or `UIApplication.shared.open`; no user-visible string literal that claims background or cold-launch playback.
3. `InstructionSurfaceTests` asserts the editor renders `instruction.foregroundNote` in both languages, and that the card and cover source contain no background-playback claim. The feature report repeats the foreground-only limitation as a completion-record line.

**R. Permission request order (FR-RIE-025).**
A `RecordingPermissionRequester` records every `status`/`request` call in order; the suite drives `InstructionVideoCaptureCoordinator.record()` with a recorder fake that records whether it was presented. First record with both undetermined: the sequence is `request(.camera)` then `request(.microphone)`, and the recorder is presented only after both resolve granted. Camera denied: `request(.microphone)` is never called, the recorder is never presented, `permissionProblem == .cameraDenied`, state `.idle`, and the library picker still opens. Microphone denied: both are requested in order, the recorder is never presented, `permissionProblem == .microphoneDenied`. Already denied or restricted: no request is issued (the OS will not re-prompt). Camera unavailable: `cameraUnavailable` and no microphone request.

**S. Notification taxonomy and scoped cancels (FR-RIE-021).**
`NotificationCategoriesTests` (unchanged) asserts `NotificationCategories.all` carries exactly the medication and event categories in both languages, so no instruction category or action exists and the full-REPLACE call cannot drop a pre-feature entry. `RoutineSchedulerTests` (extended) seeds two routine occurrences plus an unrelated occurrence standing in for the medication system's request, deletes one routine, and asserts the alarm seam was asked to cancel exactly that routine's identifiers while the other two remain scheduled; a source pin in the same suite asserts `UNRoutineNotificationScheduler` calls `removePendingNotificationRequests(withIdentifiers:)` and contains no `removeAllPendingNotificationRequests`.

**T. No video in notification attachments (FR-RIE-022).**
`RoutineNotificationSchedulerTests` builds content through `RoutineNotificationContent.make` with an injected `FakeAttachmentFactory`:
1. Schedule: an instruction-bearing routine with one photo aid produces exactly one attachment (`routine_visual_aid`, the shipping first-photo shape); the attachments array contains no video identifier, no `.mp4`/`.mov` URL and nothing derived from the instruction; the instruction video file is unchanged (present, same byte count) after scheduling.
2. Re-arm: scheduling the same occurrence again produces the same single first-photo attachment; no video or per-occurrence copy exists in the attachment directory (a `.mp4`/`.mov` count of zero) and the instruction store's file count is unchanged.
3. Event path: `UNExternalReminderScheduler` is source-pinned with no `attachments` assignment and no media parameter; an instruction-bearing free-form event schedules the same content shape as today.

### 11.4 Fakes

| Fake | Where | Purpose |
|---|---|---|
| `InstructionFileManagerSpy` | `InstructionVideoStoreTests` | Counts calls; can throw on `removeItem`; shares one ordered call log with the staging-seam double |
| `InstructionStagingFileOpsSpy` | `InstructionVideoStoreTests` | Records every staging call in one ordered log (create → stream → verify), reports `.completeUntilFirstUserAuthentication` at creation or after the stream, fails the n-th read or write, and can return a short byte count |
| `FakeInstructionVideoPicker` | `InstructionCaptureTests` | Scripts picked/cancelled/failed; asserts staging-inside-callback |
| `FakeInstructionVideoRecorder` | `InstructionCaptureTests`, `InstructionPermissionTests` | Scripts recorded/cancelled/failed, returns the recorded duration, and records whether it was presented |
| `InstructionPlaybackSpy` | `InstructionPlaybackControllerTests` | Scripts `.preflightPassed`/`.ready`/`.failed`/`.finished`/late events; counts and orders `present`/`pause`/`dismiss` |
| `MockInstructionProber` / `MockInstructionInspector` | `InstructionVideoImportTests` | Return canned metadata or errors |
| `RecordingPermissionRequester` | `InstructionPermissionTests` | Records the ordered `status`/`request` calls and scripts each permission's answer |
| `FakeAttachmentFactory` | `RoutineNotificationSchedulerTests` | Returns a real attachment built from a throwaway temp image (or nil) and records each URL it is handed |
| `ManualDeadline` | playback and import tests | Fires on demand; records the interval it was given |
| `MockObservabilityBus` | existing (`MedicationSchedulerTests:91`) | Records events for assertions |
| `MockEncryptedLocalStorage` | existing | Plants/reads payload bytes; can be scripted to fail `read` (the unreadable-store case) and to return a decoded empty list (the readable-but-empty case) |

No fake touches the network, the notification centre, photos, or a real AVPlayer.

### 11.5 Release-build device smoke (the one required run)

Build: `./build.sh` Release onto the reference device ("Anzaan"), clean install. Screen recording at 60 fps for the timing items. Record: build SHA, device, iOS version, app language, and the recording's file name.

1. **Routine, text.** Add a routine with a text instruction. Save. Confirm the row shows the card. Fire it (set the time a minute ahead) → the fired screen shows title, fire time, the text; Close returns.
2. **Routine, photo.** Attach a photo instruction; replace it once; confirm the new photo shows and the old file is gone after the next save.
3. **Routine, video (pick).** Choose a ~30 s clip; confirm "Checking the video…" then the card; save; fire; tap Play; record tap→player (≤ 500 ms) and player→first frame (≤ 2 s); audio plays; Close.
4. **Routine, video (record).** Record a 10 s clip; confirm it is accepted; confirm a 4-minute recording is stopped at 3 minutes and (if it lands at 181 s) rejected with `tooLong`.
5. **Limits.** Choose a > 200 MiB file → `tooLarge` line, previous instruction intact. Choose an unplayable/corrupt file → `unreadable` line, previous intact.
6. **Failure fallback.** Delete the video file from the container (devicectl), then tap Play from the card → the plain fallback within 1 s, Close works, no spinner remains.
7. **Removed instruction and deleted-owner taps.** Arm a routine with an instruction, remove the instruction, then tap the delivered notification → the fired screen shows `instruction.removed` and the fire time. Separately, arm a routine, let it be delivered, delete the routine, then tap the delivered notification → the shared screen shows `instruction.reminderUnavailable` and a working Close, with no title and no time.
8. **Photo-only unchanged.** A routine with only photos: the fired screen is today's; tapping the notification is a no-op (no instruction screen).
9. **Pre-upgrade payload.** Install over a build whose armed payloads lack `had_instruction`; tap → no-op; foreground delivery with a newly added instruction still presents.
10. **Event.** Create a free-form event with a video instruction; fire it; the event screen shows the card; tap → playback; edit the event and replace the video; confirm one file remains.
11. **Partial save.** Simulate a failed instruction write (fill the disk or stop the file write) → the event is saved and the detail shows the partial line once.
12. **Accessibility.** Largest accessibility text: no clipping, Play and Close reachable; VoiceOver: every label in §10.3 is read; one-handed: Play and Close reachable.
13. **Localisation.** Switch the app to Nepali: every new surface is Nepali; set the phone to Nepali and trigger a permission dialog: the Nepali usage strings appear. Then set the phone to English and trigger the dialog once: the amended English plist text appears — the D10 fallback — with the video-recording and on-device clauses present.
14. **Notification outcomes.** Banner/list/sound unchanged; read-aloud still reads the reminder; medication reminders unchanged; log gate green; device console has no instruction content (spot-check via Console while performing steps 1–10 under a Release build).

Pass = all fourteen, with the three timings inside NFR-RIE-008 and the recording attached to the task record. Any timing outside the bound is a failed smoke, not a note.

### 11.6 Not tested, and why

- **A real camera recording in CI**: no hardware in CI; the recorder is a thin adapter over `UIImagePickerController` and its contract is source-pinned. The device smoke covers the real path once.
- **OS notification delivery timing**: system-owned; the smoke covers the delivered banner and the handler unit tests cover the decision.
- **Real AVFoundation parsing of adversarial files**: out of scope and not a security boundary we can own; the caps bound the exposure, and the residual platform risk is R-6.
- **The permission dialog's language on a non-Nepali system**: not controllable (R-9); the in-app note is tested.
- **Snapshot tests of the no-instruction screen**: this repo has no snapshot harness; the source pins plus the smoke cover NFR-RIE-010's "byte-for-byte today's behaviour" claim honestly.

### 11.7 Definition of a green gate for this feature

Every suite in §11.2 green, typecheck/build clean, `check-release-log-safety.sh` exit 0 with `--self-test`, `L10nCatalogCoverageTests` green, full-suite baseline unchanged, the fourteen smoke steps recorded, and zero diffs under the medication paths.

---

## Risks

Likelihood (L) and impact (I) are H/M/L. "Residual" is the risk left *after* the named mitigation, not a hope.

| ID | Risk | L | I | Mitigation | Residual | Owner |
|---|---|---|---|---|---|---|
| R-1 | The orphan sweep deletes live videos because a store read collapsed to empty | L | H | The nil-means-unknown chain (`RoutineStore.loadEntriesIfReadable()` → `RoutineScheduler.entriesIfReadable()`/`EventExtrasStore.snapshot()` → `LiveInstructionOwners` → a no-op for that root), the 60 s grace, the in-flight set, and the survival/mirror/legacy test triple (§11.3 K) | A genuinely unreadable index delays collection; it never deletes | C02/C15 |
| R-2 | The synchronous 200 MiB staging write stalls the main thread enough to feel like a freeze | M | M | Size cap before staging; the bounded 1 MiB chunked stream keeps peak memory flat; measured in the smoke with a 200 MiB clip; `stagingChunkBytes` is the tuning knob (OI-5) | A visible wait on the worst case, bounded by the cap | C02/C04 |
| R-3 | The synchronous AVFoundation accessors are deprecated and may be removed in a future SDK | M (over years) | M | Warnings accepted today (no warnings-as-errors); fallback plan in OI-2: stage inside the callback, probe the staged file off-main | A future SDK forces a staging redesign | C03 |
| R-4 | A platform ignores or fails to report file protection | L | H | The destination is created with `.completeFileProtection` before any byte, filled by a chunked stream, and the attribute is re-verified after the stream and after the commit rename; a weaker reported class fails closed and deletes the bytes; source pins guarantee the creation call is present and that no `copyItem` exists in the staging path | An unreported but weaker class would be invisible — no evidence of one; a crash after creation leaves at most an empty/partial `.complete` file that the sweep removes | C02 |
| R-5 | The event owner's SHA-256 directory name collides or diverges | L | M | 128 bits kept; one implementation (`eventDirectoryName`); a test pins the shape and uniqueness | Negligible | C01 |
| R-6 | AVFoundation parses a malicious video and crashes or corrupts memory | L | H | Caps bound the input; the file is never transformed, uploaded or shared; the OS parses the same bytes in any player; no custom demuxer | Platform risk accepted | product + OS |
| R-7 | Instruction text/caption/filename reaches a log through a path the gate cannot see | L | H | No console writes in the three roots; typed emitters with closed vocabularies; no allow-list addition; the gate plus its self-test; the shared hunks reviewed file by file (the gate's own documented limitation) | A content-bearing print inside a shared-file hunk would not be caught by rules 3–4 | C01/C16 |
| R-8 | A partial event save confuses the family ("the event is there but the video isn't") | M | M | One plain line on the detail, the existing Edit path as the retry, the outcome type naming the partial state; the form never lies about what saved | A family may not notice the line | C10/C13 |
| R-9 | The OS permission dialog shows the system language, not the app language | H | L | The shipped plist carries the amended English text, pinned by `L10nCatalogCoverageTests`; `InfoPlist.strings` in en + ne covers Nepali-system phones; the in-app denial note is app-language localised | A Nepali in-app household on an English phone sees an English dialog — the amended fallback, not the old text | product |
| R-10 | The person cancels while the staging copy is running | L | L | The copy cannot be interrupted; it completes, then is discarded; bounded by 200 MiB/180 s | A short delay before the sheet returns to idle | C04 |
| R-11 | A future field is erased by a wholesale `EventExtras` rebuild (the `setPhotoFilename` bug class) | L | H | P-4's mutation rule, the two-order preservation test, and a comment on the struct | A future contributor repeating the pattern | C12 |
| R-12 | A reviewer reads NFR-RIE-008's 1 s fallback as covering an unresponsive player, making the 10 s watchdog a violation | M | L | §8.1 distinguishes failure detection from a platform stall; OI-7 offers the 1 s alternative if the review insists | A copy/design amendment, no user harm | review-l2 |
| R-13 | A foreground banner plus a tap presents the fired screen twice | L | L | `presentRoutineInstructionTap` does not replace a presentation already showing the same entry (L1's dedupe rule); a different entry replaces the published value (never stacks); the overlay is a single `fullScreenCover(item:)` | A visual re-presentation of the same screen | C15 |
| R-14 | Event instruction-image files accumulate when a flat-store delete fails | L | L | Pre-existing flat-store condition, stated in §5.8 (review-l1 N-1); no new mechanism invented for it | Slow disk growth in a rare path | product |

Two risk notes that do not fit a row:

- **The pre-existing `print` in `RoutineAlarmScheduler.swift:101–105`** maps only an `ErrorCodeMapper` code and is not content-bearing. It is untouched by this feature, is in a shared file (not a feature root), and is deliberately not "cleaned up" here: changing it would be an unrelated log-surface edit riding on a feature. Stated so a reviewer does not read its presence as an oversight.
- **The gate's per-file limitation is the largest residual in R-7**, and it is the gate's own documented limit, not a gap this design can close. The unit suites and the review carry shared-file hunks; that is what the audit paragraph in §6.5 is for.

---

## Open items

| ID | Item | Why it is open | Default if not decided | Who decides |
|---|---|---|---|---|
| OI-1 | `setInstruction` returns `Result<Void, InstructionWriteError>` instead of L1's `Bool` (R-1, P-11) | It is a literal L1 change, recorded rather than absorbed. `EventExtrasStore.setInstruction` keeps the shipping store's `Bool` and is translated at the service seam (labelled in IF-26, m-2) | Keep the `Result`: a `Bool` cannot declare an error type, which the principal-engineer contract forbids | review-l2 |
| OI-2 | Synchronous AVFoundation accessors in the pre-staging probe are deprecated | No warnings-as-errors today; the async replacement cannot run inside the system callback | Keep the synchronous probe; on SDK removal, stage inside the callback and probe the staged file off-main | engineering (trigger: SDK removal) |
| OI-3 | `InstructionCommit` (write + pending media) added beside L1's `InstructionWrite` (R-7) | An event has no id before it is created, so a picked photo/video cannot have a filename at handoff | Keep the commit type; it is the shipping `pickedPhoto` shape generalised | review-l2 |
| OI-4 | An instruction image shares the visual-aid / event-photo store with other images | L1 D3 pins reuse; a future multi-instruction or per-instruction-directory model would need a layout change | Keep the shared store; one instruction image per owner is unambiguous within the owner's directory | product + engineering |
| OI-5 | `stagingChunkBytes` (1 MiB) may need tuning if the 200 MiB staging write stalls visibly | A measurement, not a design question: the chunked stream is the mandated D18 path, and only the chunk size is tunable | Ship 1 MiB chunks; tune only if the smoke fails the budget; the write stays inside the same callback | engineering (after the smoke) |
| OI-6 | An "Open Settings" affordance beside a denied permission | L1 specifies plain text only; a settings deep-link is a new interaction | Ship the plain text; propose a follow-up task if the smoke shows people stuck | product |
| OI-7 | `readyWatchdogSeconds` (10 s) vs. a strict reading of NFR-RIE-008's 1 s fallback | L1 pins 10 s; the shipped failure paths resolve within 1 s | Keep 10 s as the stall ceiling; the 1 s bound is met by failure detection (§8.1) | review-l2 |
| OI-8 | Event notifications carry no `had_instruction` | The event tap already opens the detail, where absence renders `.none`; there is no dead end to defend | No key; revisit only if a future flow presents instruction content from the background | engineering |

No open item blocks implementation. OI-1, OI-3 and OI-7 are ratification questions with working defaults; OI-2 is a future SDK trigger and OI-5 a post-smoke measurement trigger; OI-6 and OI-8 are product calls with a shipped default.

---

*End of design-l2. Sections §1–§13 are complete against contract `component_design_l2`: components and their interfaces (with explicit error types), data models and their migration, storage and its failure ordering, error handling and observability, concurrency and isolation, performance and security patterns, configuration and timeouts, accessibility and localisation, the test plan that evidences every FR-RIE/NFR-RIE this feature touches, risks, and the open items above.*
