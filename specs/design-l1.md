# Design L1 — Reminders Instructions Enhancements

Feature: `reminders-instructions-enhancements`
Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-reminders-instructions-enhancements`
Branch: `feat/reminders-instructions-enhancements`
Scaffold base: master `821f19c5` (2026-10-25)
Task: `design-l1` (agent: `sdd-architect`), rework iteration 2
Rework authority: `specs/review-l1.md` — NO_GO review, preserved verbatim at
`.ai-sdd/runs/reminders-instructions-enhancements/reviews/review-l1-iteration-1-NO_GO.md`.
This revision resolves **B-1, B-2, M-1, M-2, m-1…m-8** in the design; the architecture,
seams and the five accepted risks are retained unchanged.
Inputs: `constitution.md`, `specs/reminders-instructions-enhancements/constitution.md`
(OD-1…OD-8 resolved 2026-10-25), `specs/define-requirements.md`,
`specs/define-requirements.lock.yaml` (35 requirements: 25 FR-RIE, 10 NFR-RIE).
Verified against the checkout at the scaffold base; the codebase is unchanged by this rework.
Line numbers are orientation, not contracts.

---

## Overview

### Purpose

A caregiver can attach **one instruction** — written text, an image, or a short video — to a
daily-routine reminder (`RoutineEntry`) or an app-created free-form event (`EventExtras`). When the
reminder or event fires, the elderly user sees the instruction in the app and can follow it
unaided: text as readable text, an image like today's photo aids, a video behind a large, explicit
Play control that opens full-screen AVKit playback. Nothing plays before that tap.

### Scope anchor (binding; not re-litigated here)

In scope: text, image and video instructions; video library pick and in-app recording using the
system camera UI; one instruction of a single kind per owner; 3 minutes / 200 MiB, stored as
provided (no transcode); optional caption for image/video; foreground-only presentation with the
routine tap/Open path; plain localized fallback on media failure. Out of scope: medication
reminders, imported events, YouTube/link instructions in v1 (a forward-compatible model slot only),
audio-only instructions, multiple instructions, cloud upload/transcoding/AI processing, new
acknowledgement/escalation machinery, a standalone media library, and any UI test requirement.

### Architecture at a glance

The feature is **local-only and layered on the existing photo-aid seams**:

- A pure, string-tolerant `Instruction` value is embedded in the two existing encrypted payloads.
- Video bytes live in dedicated Application Support roots; the encrypted payload holds a bare
  filename. **The 3-minute duration, ~200 MiB size and playability/video-track limits are enforced
  synchronously before any byte is copied into the instruction store** (FR-RIE-006, D17). The
  off-main importer re-checks as a second line; only then is the copy committed synchronously on
  the main actor in the data-safe order the shipped `setPhoto` path already uses. Staged files are
  protected at creation, never after the fact (D18).
- The fired screens are **extended, not replaced**. The routine fired screen gains the instruction
  through its existing generic `footer` seam, so neither the shared screen nor the medication path
  changes behaviour. Event instructions render in the existing `EventDetailView` card stack.
- Notification behaviour is **behaviourally untouched**: the same handlers keep returning `false`,
  the facade keeps completing `[.banner, .list, .sound]`, no category or action is added, and video
  never enters `UNNotificationAttachment`. The only notification-layer changes are two
  presentation gates, a bounded `had_instruction` `userInfo` flag written at arm time, and the
  routine `didReceive` tap path, which the requirements explicitly put in v1 (FR-RIE-019).
- Playback sits behind a thin injectable protocol in the `CameraCapturePresenting` style, so every
  outcome — play, failure, missing file, timeout, dismissal — is scriptable in unit tests without
  an `AVPlayer`.

### Key design decisions taken at this level

| # | Decision | Rationale / requirement |
|---|---|---|
| D1 | Event video root is `Application Support/EventInstructionVideos/` | FR-RIE-011 separates the event root from `InstructionVideos`; the name is design-level (OD-5) |
| D2 | Event owner directory is `ev-` + the first 32 hex chars of SHA-256(eventId) | EventKit ids are opaque, not filesystem-safe, and must not appear in a path; the clear id stays in the encrypted index only |
| D3 | Image instructions reuse the surface's existing photo store; no parallel image store | FR-RIE-003; routine = `VisualAidStore` (`VisualAid/fileURL`), event = `ContactPhotoStore(directoryName: "EventPhotos")` |
| D4 | Video is staged under `<root>/_pending/<draftUUID>/` and committed by a same-volume rename. The size, duration and playability/video-track checks happen **before** the staged copy; the off-main importer re-checks. **Revised (review B-1).** | PHPicker and `UIImagePickerController` URLs are valid only inside their callback; one protected copy, no 200 MB second copy, no orphan on cancel; FR-RIE-006's "before the file is copied" ordering |
| D5 | The routine fired screen shows the instruction through `ReminderVisualAidScreen`'s existing `footer` seam. The shared screen gains exactly one defaulted `timeText` parameter (`nil` at every other call site). **Revised (review m-4).** | FR-RIE-017 composition; medication and no-instruction call sites remain behaviourally identical to today (NFR-RIE-010's "byte-for-byte" is a behaviour claim, not a source-diff claim) |
| D6 | The fired reminder's time is shown only when an instruction is present or expected | FR-RIE-017/020 require title **and time**; NFR-RIE-010 requires photo-only/no-instruction firings to be behaviourally identical |
| D7 | In-app recording requires both camera and microphone; denial disables recording with a plain note | FR-RIE-025's own microphone scenario; library pick and the reminder stay fully usable |
| D8 | An unknown/future instruction kind shows the reminder content plus a plain "newer version" note, no control | FR-RIE-024 / NFR-RIE-006 honest unsupported state, never a fake control |
| D9 | Instruction video is included in the normal iOS device backup (no `isExcludedFromBackup`) | Parity with the shipped photo aids and encrypted payloads; no new app egress. Accepted risk, flagged for the owner report |
| D10 | Permission usage descriptions are localized through new `en`/`ne` `InfoPlist.strings` | FR-RIE-025 disclosure + NFR-RIE-002 en/ne parity; the project has no localized `InfoPlist.strings` today |
| D11 | Services receive an `InstructionWrite` value — `.set(payload)` or explicit `.remove` — never a half-built `Instruction`, and never "nil kind means remove". `nil` exists only at the form/save seam and means "leave the instruction untouched". **Revised (review M-1).** | The filename of a pending image/video is known only after the store writes it; the service owns the transactional ordering. A nil write can never silently erase an instruction |
| D12 | Free-form event save returns `FreeFormEventSaveOutcome(eventId:instructionSaved:)` | Honest partial-save reporting (FR-RIE-010/013): the event may save before the instruction write. `instructionSaved == true` also when no instruction change was requested (nothing failed) |
| D13 | The fired time comes from `UNNotification.date`, not from a scheduler change | **Partly superseded by D14 (review B-2):** the delivery-time choice stands and is accepted; the original "no edit to `RoutineAlarmScheduler`" rationale does not, because the routine notification now carries a bounded `had_instruction` flag |
| D14 | The routine notification `userInfo` carries `had_instruction` (Bool) written at arm time from `entry.instruction?.isPresent`, and the tap path uses it to tell an instruction-bearing firing from a photo-only one | FR-RIE-019's unresolved-owner/content branch without changing today's photo-only tap (NFR-RIE-010). Bounded `RoutineAlarmScheduler` change: one argument, one pure builder, one `userInfo` key. Text/body, banner/list/sound, the first-photo attachment and scoped cancels are untouched |
| D15 | `InstructionWrite?` semantics: `nil` = leave untouched; `.remove` = explicit removal; the form passes `InstructionDraft.resolvedWrite` (never a bare draft) and Save is disabled while the initial load is `.loading` | M-1: an unrelated edit on a form whose instruction load failed cannot erase the stored instruction. Regression-tested |
| D16 | The playback resolution seam returns `InstructionPlaybackAvailability` (`.available(URL)`, `.rejectedFilename`, `.missingFile`, `.unreadableFile`) and the card emits `instruction_resolution` from that same classification | M-2 / FR-RIE-012: the three PII-free outcomes are expressible and testable; a bare `URL?` could not distinguish them |
| D17 | The 3-minute duration (plus playability and video-track) limits are enforced synchronously inside the picker/recorder callback before the staged copy; the off-main importer is the second check | B-1 / FR-RIE-006's locked ordering. The source URL is valid only inside the callback; a metadata-only read is the only way to honour "before the file is copied" |
| D18 | Instruction video files are created with `.completeFileProtection` (directory and file attributes at creation) and filled by a bounded chunked stream copy; any failure deletes the partial file (fail-closed) | NFR-RIE-005 / FR-RIE-011: no staging window with a weaker Data Protection class, unlike a post-copy attribute set |

### Review-resolution map (rework iteration 2)

| ID | Resolution | Where |
|---|---|---|
| B-1 | Duration/playability/video-track enforced synchronously before the staged copy; `stageSynchronously` takes `InstructionVideoLimits` + `InstructionVideoProbing`; importer re-checks; store test proves an over-long/unplayable source creates no staged file | D4, D17; §Capture · Video; C02, C03, C04; tests |
| B-2 | Routine tap: `had_instruction` flag (D14); entry resolves → fired screen with title/time plus the plain fallback when the instruction was removed; entry deleted → plain localized unavailable notice; photo-only tap stays today's no-op. Three tap cases tested | D13, D14; §Fire-time; C01, C14, C15, C17; tests |
| M-1 | `InstructionWrite` is `.set`/`.remove`; `nil` only at the save seam = untouched; `InstructionDraft.resolvedWrite` gates on a terminal load; Save disabled while loading; unrelated-edit / explicit-remove / failed-load tests | D11, D15; §Data model; C10–C13; tests |
| M-2 | `availability(filename:for:) -> InstructionPlaybackAvailability`; card emits `instruction_resolution` from it; traversal/absent/unreadable tests and a no-filename assertion | D16; §Playback; C02, C08; tests |
| m-1 | Event handler gains an `instructionPresent: (String) -> Bool` dependency; specified in C14/C15 with its fake | C14, C15; tests |
| m-2 | `delete`/`deleteAll` return `Result<Void, InstructionStorageError>`; services emit the typed `instruction_media_delete` failure; `deleteFailed` is reachable | §Lifecycle, §Error taxonomy; C02, C11, C13 |
| m-3 | Phantom `RoutineAlarmSchedulerTests` removed; new `RoutineNotificationSchedulerTests` (clearly labelled new) plus retargeted, real-suite evidence for FR-RIE-021/022 | C16, C17; Traceability |
| m-4 | "Byte-identical" reworded to "behaviourally identical"; source-scan baseline allows and pins the defaulted `timeText` parameter and nil at no-instruction call sites | D5, D6; §Fire-time; C09; tests |
| m-5 | Protection applied at file creation (directory + file), fail-closed; staged and committed attribute tests | D18; §Storage; C02; tests |
| m-6 | `preflightTimeoutSeconds = 0.6` (sub-second default) with the 1 s bound as the outer acceptance target and an explicit measurement point | §Configuration, §Playback; C06; Risks |
| m-7 | Device smoke named as a **Release build** installed on the reference device, recorded with build/commit | C16; Traceability |
| m-8 | `InstructionImageLoading` returns `Result<UIImage, InstructionImageFailure>`; two adapters and a scripted fake specified | C01, C08; tests |

### What the reviewer should scrutinise first

1. **`EventExtrasStore.setPhotoFilename` erases a new `instruction` field** unless it is changed to
   mutate existing extras (`EventExtrasStore.swift:111–114`). This remains the single most likely
   silent-data-loss bug in the feature (see §Data model and C12).
2. **Pre-copy limit enforcement** (B-1/D17): the staged copy must be unreachable for an over-long,
   unplayable or video-less source, and the protection class must exist at file creation (m-5/D18).
3. **The routine tap/Open path** (B-2): it must open for instruction-bearing firings, show the
   fallback when the instruction was removed, show an honest notice when the entry is gone, and
   remain a no-op for photo-only firings.
4. **`InstructionWrite?` semantics** (M-1): nil means "leave untouched" everywhere; removal is an
   explicit `.remove`; a failed initial load cannot produce a write (C10).
5. **The resolution classification** (M-2): `.rejectedFilename` / `.missingFile` /
   `.unreadableFile` must be distinguishable and emitted PII-free (C02/C08).
6. **NFR-RIE-008's 1 s failure bound**: the cover appears synchronously on the Play tap; the
   preflight default is 0.6 s, leaving margin under the 1 s acceptance bound; the 10 s ready
   watchdog is only the no-endless-spinner backstop.
7. **Event image instructions inherit `ContactPhotoStore`'s 512 px thumbnail pipeline** — accepted
   because FR-RIE-003 binds event images to the existing event photo path. Flagged in §Risks.

---

## Architecture

### System context

```
┌──────────────────────────── Caregiver surfaces ────────────────────────────┐
│ RoutineSettingsView sheet                     EventFormView / EventDetail │
│  └ ReminderVisualAidEditorView                 └ InstructionCardView       │
│      └ RoutineInstructionSection                   (fire-time card)       │
│ EventInstructionSection ─────────┐                                          │
└──────────────────────────────────┼──────────────────────────────────────────┘
                                   │
             InstructionVideoCaptureCoordinator (UI state machine)
              ├ InstructionVideoPicking (PHPicker .videos, .current)
              ├ InstructionVideoRecording (UIImagePickerController, video)
              ├ InstructionPermissionRequesting (camera, microphone)
              └ InstructionVideoImporter ── InstructionVideoInspecting (AVFoundation, async 2nd check)
                                   │        └ staged copy is preceded by
                                   │          InstructionVideoProbing (sync, in-callback limits)
        ┌──────────────────────────┼──────────────────────────┐
        ▼                          ▼                          ▼
 InstructionVideoStore      VisualAidStore /           InstructionObservability
 (file ops, protection)     ContactPhotoStore          (typed, PII-free events)
        │                          │
        └──────────────┬───────────┘
                       ▼
        RoutineScheduler.setInstruction     FreeFormEventService.setInstruction
        (encrypted RoutineEntry)            (encrypted EventExtras + EventKit event)
                       │
                       ▼
        RoutineAlarmScheduler (only change: had_instruction userInfo flag)
                       │
                       ▼
        NotificationFacade ── handlers (always return false)
          ├ RoutineVisualAidFireHandler  → AppCoordinator → RoutineVisualAidOverlay
          │        willPresent: ReminderVisualAidScreen(footer: InstructionCardView)
          │        didReceive:  fired screen (removed instruction → fallback)
          │                     or plain localized unavailable notice
          └ FreeFormEventFireHandler      → EventDetailView → InstructionCardView
                       │
                       ▼
        InstructionCardView ── Play ── InstructionPlaybackController
                                     └ InstructionVideoPlaying (AVKit adapter)
```

### Layering and module boundaries

| Layer | Responsibility | New / changed files |
|---|---|---|
| Model (pure) | `Instruction`, `InstructionKind`, `InstructionWrite`, `InstructionPayload`, `InstructionDraft`, `InstructionOwner`, `InstructionFilename`, display state | **new** `Services/Instructions/Instruction.swift`, `Services/Instructions/InstructionDisplayState.swift` |
| Storage (file ops only) | pre-copy limit gate, protected staging, commit, bare-name guard, availability classification, per-owner lifecycle | **new** `Services/Instructions/InstructionVideoStore.swift` |
| Import / validation | synchronous probe before copy; size + duration + playability second check; plain error mapping; discard on failure | **new** `Services/Instructions/InstructionVideoImporter.swift`, `Services/Instructions/InstructionVideoInspecting.swift` |
| Playback seam | scriptable outcomes, bounded configurable timeouts, no autoplay | **new** `Services/Instructions/InstructionPlayback.swift`; production adapter `Services/Instructions/AVKitInstructionVideoPlayer.swift` |
| Permissions | point-of-use camera/mic, plain explanation, denial non-blocking | **new** `Services/Instructions/InstructionPermissions.swift` |
| Observability | one typed emitter, closed vocabulary, existing sanitiser keys | **new** `Services/Instructions/InstructionObservability.swift` |
| Service integration | transactional set/replace/remove, delete with owner, re-arm | changed `RoutineScheduler.swift`, `FreeFormEventService.swift`, `EventExtrasStore.swift`, `RoutineEntry.swift` |
| Notification scheduling | one additional `hasInstruction` argument and a pure `userInfo` builder; no text/banner/attachment/cancel change | changed `RoutineAlarmScheduler.swift` (bounded; C17) |
| Fire handlers | extend gates, implement routine `didReceive`, always `false` | changed `RoutineVisualAidFireHandler.swift`, `FreeFormEventFireHandler.swift` |
| UI | instruction card, editor sections, pickers/recorder/permission sheets, player cover | **new** `App/InstructionViews.swift`, `App/InstructionCapture.swift`; changed `VisualAidViews.swift` (overlay/composition + one defaulted `timeText` parameter), `RoutineSettingsView.swift`, `EventsView.swift` |
| Composition | stores, seams, presentation state, event accessors | changed `AppCoordinator.swift` |

**Non-goals at this layer:** no new network client, no new notification category/action, no new
audio-session code (the feed player at `FeedsView.swift:649–716` is the playback precedent), no
medication-file edits.

### Data model

#### `Instruction` — one optional value on each owner

```swift
enum InstructionKind: String, CaseIterable, Codable {
    case text, image, video          // no `link` case in v1 (OD-3)
}

struct Instruction: Codable, Equatable {
    let kind: String                 // RAW persisted kind; known values come from InstructionKind
    var text: String?                // kind == text
    var filename: String?            // kind == image|video: BARE file name, never a path/bytes
    var caption: String?             // image|video only; trimmed at write, blank -> nil
    var url: String?                 // RESERVED for the future link kind; v1 never sets/renders it

    var knownKind: InstructionKind? { InstructionKind(rawValue: kind) }
    var isPresent: Bool { /* text: non-blank; image/video: true even if bytes are missing;
                             unknown non-empty kind: true (shown as unsupported) */ }
}
```

Rules:

1. **One instruction per owner** is structural: `RoutineEntry.instruction: Instruction?` and
   `EventExtras.instruction: Instruction?` — no arrays, no per-occurrence copy.
2. **Never bytes, never a path.** Text lives in the encrypted payload; image/video store a bare
   filename only.
3. **Unknown kinds decode.** `kind` is a raw string, so `{"kind":"link"}` (or any future value)
   decodes without throwing. `url` round-trips the OD-3 slot even though v1 has no UI for it.
   Unknown extra fields are not preserved (honest limit; the OD-3 field is).
4. **Tolerant decode is fail-soft at the owner.** Both owners decode the instruction with
   `(try? container.decodeIfPresent(Instruction.self, forKey: .instruction)) ?? nil`, so one
   malformed instruction object can never cost the household its reminder list or event index.
   Every pre-existing key stays strict.
5. **Write normalization.** `Instruction.normalized()` trims `text` and `caption`; a blank text is
   not an instruction (`nil`), and a blank caption becomes `nil`. Services normalize before
   persisting; the defensive path means whitespace-only input behaves exactly like no instruction
   (FR-RIE-002).
6. **`url` is inert.** No control, no URL field, no parser, no playback path in v1 (FR-RIE-024).

#### Embedding and coding keys

- `RoutineEntry` (`Services/Reminders/RoutineEntry.swift:62–145`): add
  `var instruction: Instruction?` after `visualAids` (`:100`), add `.instruction` to the explicit
  `CodingKeys` (`:126–129`), initialize it to `nil` in the memberwise init, and decode it fail-soft
  in the hand-written `init(from:)` (`:135–145`) while leaving every other key strict. Synthesized
  `encode(to:)` omits nil optionals, so pre-feature payloads and instruction-free entries are
  payload-compatible.
- `EventExtras` (`Services/Storage/EventExtrasStore.swift:25–45`): add
  `var instruction: Instruction?`, include it in the memberwise init with a default of `nil`, and
  decode it fail-soft alongside `photoFilename` (`:41–45`). The struct stays `Codable, Equatable`.
- **Hazard — fix required:** `setPhotoFilename` (`EventExtrasStore.swift:111–114`) currently
  constructs a fresh `EventExtras(photoFilename:)`. Once the model has an `instruction`, saving an
  event photo would erase the instruction. It must mutate the existing extras
  (`extras(forEventId:) ?? EventExtras()`) and write the whole value back. `storeInstruction` must
  mutate symmetrically and preserve `photoFilename`. `track` (`:103`) already preserves existing
  extras and needs no change.

#### Payload examples

```json
{"kind":"text","text":"Lift your toes up and down ten times."}
{"kind":"image","filename":"A1B2C3D4-….jpg","caption":"The blue box"}
{"kind":"video","filename":"instruction-5E6F….mp4","caption":"Do it slowly"}
{"kind":"link","url":"https://…"}        // decodes; unknown kind; no control in v1
```

#### `InstructionWrite` — the service mutation, and `InstructionDraft` — the form state

```swift
/// The durable mutation the caregiver asked for. A value, never a half-built
/// `Instruction`: a pending medium's filename exists only after the store writes
/// it, so the service owns the transaction (D11).
enum InstructionWrite: Equatable {
    case set(InstructionPayload)
    case remove                              // explicit removal — never a nil kind
}

struct InstructionPayload: Equatable {
    var kind: InstructionKind                // exactly one kind
    var text: String?                        // kind == .text
    var caption: String?                     // image/video only
    var existingFilename: String?            // keep an already-saved image/video file
    var pendingImage: UIImage?               // saved at commit (surface photo store)
    var pendingVideo: StagedInstructionVideo? // committed at save (video store)
}

/// The caregiver's unsaved edit. `nil` write = no user change.
struct InstructionDraft: Equatable {
    enum LoadState: Equatable { case loading, loaded, failed }
    var write: InstructionWrite?
    var hasChanges: Bool
    var loadState: LoadState

    /// What the form may pass to a save. A loading or failed initial read can
    /// never produce a write, so an unrelated edit cannot remove the stored
    /// instruction (M-1). The section's controls are read-only unless `.loaded`.
    var resolvedWrite: InstructionWrite? {
        loadState == .loaded && hasChanges ? write : nil
    }
}
```

- **Semantics are pinned (M-1, D15):** at the save seam, `InstructionWrite? == nil` means "leave the
  instruction untouched". At the durable service seam, `InstructionWrite` is **non-optional** — the
  only way to remove is `.remove`, the only way to write is `.set(payload)`. There is no encoding
  in which "nil" or "nil kind" means removal.
- The editor owns the draft; the service owns the durable work. Pending media is always written
  **before** the index is updated; the old file is deleted **after** a successful index write
  (FR-RIE-013).
- The event form disables Save while `loadState == .loading`. On `.failed` the instruction section
  is read-only with a plain message and Retry; the form can still save the event's unrelated fields
  with `resolvedWrite == nil` (leave untouched) — it can never erase the stored instruction.

#### Filename predicate

```swift
enum InstructionFilename {
    /// non-empty, not "."/"..", no "/" and no "\" — the VisualAidStore discipline.
    static func isPlain(_ name: String) -> Bool
}
```

One table-driven predicate shared by the video store and both image loaders; `VisualAidStore`
itself is unchanged.

### Storage layout and protection

```
Application Support/
├── VisualAids/<routineUUID>/…jpg          existing; also holds a routine image instruction
├── EventPhotos/…jpg                       existing; also holds an event image instruction
├── InstructionVideos/
│   ├── _pending/<draftUUID>/instruction-<uuid>.<ext>
│   └── <routineUUID>/instruction-<uuid>.<ext>
└── EventInstructionVideos/
    ├── _pending/<draftUUID>/instruction-<uuid>.<ext>
    └── ev-<sha256(eventId) first 32 hex>/instruction-<uuid>.<ext>
```

- **Owner key:** routines use the entry UUID string (matching the existing `VisualAids/<entryId>/`
  layout); events use a deterministic digest because EventKit identifiers are opaque and not
  filesystem-safe (D2). The clear event id remains only in the encrypted `EventExtras` index.
- **Bare filenames only.** `InstructionVideoStore` uses `InstructionFilename.isPlain` (the
  `VisualAidStore.isPlainFilename` discipline, `VisualAidStore.swift:243–249`). A hand-edited
  `../EventPhotos/secret.jpg` or an absolute path resolves to no file, classifies as
  `.rejectedFilename`, is logged PII-free, and renders the plain fallback (FR-RIE-012).
- **Protection at creation (D18, m-5).** Directories are created with
  `[.protectionKey: FileProtectionType.complete]`. The staging destination file is **created with
  the complete-protection attribute before any bytes are written**, then filled by a bounded
  chunked stream copy (no whole-file buffering, no `copyItem`-then-set window). The attribute is
  verified after creation and again after the commit rename. Any failure at creation, copy or
  verify deletes the partial file and returns a write failure (fail-closed): a staged or committed
  instruction file never exists with a weaker class. `.completeFileProtection` is the shipped
  photo-aid class (`VisualAidStore.swift:123`). Enforcement is a device property; the simulator
  asserts the recorded attribute and the real-device smoke records the claim (NFR-RIE-005).
- **Backup.** No `isExcludedFromBackup` is set — parity with photo aids and the encrypted payloads
  (D9). No app network path is introduced.
- **Format.** Bytes are copied as provided; the sanitized source extension is preserved; no
  transcode, re-encode, or format conversion. `.current` picker representation mode prevents the
  system from transcoding a library asset on our behalf.
- **Staging cleanup.** `_pending` exists only for drafts. It is purged at launch on the existing
  utility housekeeping queue (`AppCoordinator.modelHousekeepingQueue`, `AppCoordinator.swift:571`)
  and every cancel/discard deletes its own draft directory. `_pending` is never a valid owner key.

#### Lifecycle matrix

| Operation | Ordering | Failure result |
|---|---|---|
| Add/replace text | persist `RoutineEntry`/`EventExtras` → delete nothing | previous instruction intact; plain failure |
| Add/replace image | save new image to the surface photo store → persist index → delete old image file (Result) | new image deleted; previous intact |
| Add/replace video | **pre-copy size/duration/playability gate** → protected staged write → commit rename → persist index → delete old video file (Result) | staged draft deleted; previous intact; no committed file on a failed index write |
| Remove instruction (`.remove`) | persist instruction `nil` → delete the old image/video file | index unchanged on a failed persist; previous intact. A media-delete refusal returns `.deleteFailed`, is logged, and leaves the index authoritative (orphan noted in §Risks) |
| Delete routine | `store.remove` → `visualAidStore.deleteAll` (photos + image instruction) → `instructionVideoStore.deleteAll(.routine(id))` → Result | index row gone; a `.deleteFailed` is logged PII-free, never silently swallowed |
| Delete event / vanished reconcile | `extras.remove` returns dropped extras → delete event photo → delete instruction image → delete event video directory (Result) | same |
| Re-arm / time edit | no media write; notification content unchanged (text/banner/photo attachment only); `had_instruction` refreshed from the entry | n/a |

### Capture, import and permissions

#### Text

Pure UI: a `TextEditor` (body size ≥ 18 pt) with Save. Save normalizes (trim); blank input is not
saveable ("Write the steps first."), so clearing the field can never silently remove an existing
instruction — removal is the explicit Remove control. No file, no permission.

#### Image

Reuses the existing out-of-process photo picker (`VisualAidPhotoPicker`, `VisualAidViews.swift:20`;
`PhotosPicker`, `EventsView.swift:295`) — permission-free. The picked `UIImage` is held in the
editor draft and saved only at commit:
- routine: `VisualAidStore.save(image, for: entryId)` → filename
- event: `ContactPhotoStore(directoryName: "EventPhotos").save(image)` → filename

Existing image limits apply (routine 1600 px / 0.8; event 512 px / 0.8). Event image instructions
therefore inherit the shipped event-photo resolution; FR-RIE-003 explicitly binds them to that path
(flagged in §Risks).

#### Video from the library

1. `PHPickerViewController` with `filter = .videos`, `selectionLimit = 1`,
   `preferredAssetRepresentationMode = .current` (no system transcode).
2. In `loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier)`, **inside the callback**
   (the URL is valid only there), in this exact order (FR-RIE-006, B-1/D17):
   a. stat the source; if `> maxBytes` reject `.tooLarge` **before any copy**;
   b. **synchronously probe** the source with `InstructionVideoProbing` (metadata only: duration,
      playability, video track). Reject `.tooLong` (duration rounded to the nearest second),
      `.unsupportedFormat` (not playable / no video track) or `.unreadableSource` **before any
      copy**;
   c. only then create the staged destination with complete protection and stream-copy into
      `<root>/_pending/<draftUUID>/instruction-<uuid>.<ext>`; verify the attribute; on any error
      delete the partial file;
   d. return `StagedInstructionVideo { url, filename, byteCount, probed }`.
3. The capture coordinator then runs `InstructionVideoImporter.validate(staged, limits:)`
   **off-main** as the second check: a full async inspection (duration, playability, video track)
   under `validationTimeoutSeconds`, plus a defensive byte-cap re-check. Failure discards the
   staged bytes and shows a plain message; the previous instruction is untouched.
4. Success hands `AcceptedInstructionVideo { staged, durationSeconds }` to the editor for preview
   and commit.
5. Cancellation (picker dismissed, no selection) discards nothing and shows no error.

The synchronous probe reads local metadata only — it does not decode frames, does not copy, and
runs once per pick. It is the only place the FR-RIE-006 ordering can be honoured, because the
source URL is invalid outside the callback. Its cost and the accepted trade-off are recorded in
§Risks (new item 13).

#### In-app recording

1. The caregiver taps Record. The permission flow runs at that point:
   - camera `authorized` → continue; `notDetermined` → plain pre-permission explanation → system
     request; `denied`/`restricted` → plain "camera is off" note, recording unavailable, library
     path intact;
   - microphone the same, because a recorded instruction includes sound; a denied microphone
     disables recording with a plain note (FR-RIE-025's own scenario);
   - no camera hardware (`isSourceTypeAvailable(.camera) == false`) → plain unavailable note.
   No prompt at launch, no prompt loop, no crash.
2. `UIImagePickerController` with `sourceType = .camera`, `mediaTypes = [UTType.movie.identifier]`,
   `cameraCaptureMode = .video`, `videoMaximumDuration` from configuration (180 s), quality mapped
   from the configuration enum.
3. In `didFinishPickingMediaWithInfo`, the `mediaURL` is valid only inside the callback: stat →
   synchronous probe → reject before copy → protected stage copy, by the same `stageSynchronously`
   call (same `limits` and `prober`) used by the library path.
4. The same importer second check, preview, commit and cancel semantics apply. Cancelling the
   system camera returns to the editor with no change and no error.
5. The system UI handles the recording itself; no custom capture UI is added.

#### Capture state machine (single-flight)

```
idle ──pick──▶ picking ──in-callback limits ok + staged──▶ validating ──✓──▶ ready
  │                │                                            │
  └──record────▶ recording ─────────────────────────────────────┘
                   │
                   └──cancel──▶ idle (previous instruction untouched)
  any failure (pre-copy or validation) ──▶ failed(InstructionImportError) ──retry/close──▶ idle
```

- One operation at a time; a second tap while `isBusy` is ignored (the `CameraCaptureFlow.isRunning`
  precedent, `CameraCapture.swift:109,153`).
- `.ready` survives until commit or discard; leaving the editor discards it.

### Fire-time presentation and playback

#### Handler changes (notification layer)

| Handler | `willPresent` gate | `didReceive` |
|---|---|---|
| `RoutineVisualAidFireHandler` | present when `!entry.visualAids.isEmpty \|\| entry.instruction?.isPresent == true` (was photos-only, `:55`); still always `false` (`:15–18`) | **new (B-2):** for the default action on a routine reminder whose `had_instruction == true`, resolve the entry and call the tap sink on the main queue: `onInstructionTap(entryId, entry?, notification.date)`. `had_instruction == false` (photo-only or no instruction at arm time) remains a no-op — today's behaviour. A missing `had_instruction` key (notification armed before this release) reads as `false` |
| `FreeFormEventFireHandler` | present when `event.photoFilename != nil \|\| instructionPresent(eventId)` (was photo-only, `:69`); still always `false` (`:21–24`) | unchanged: `.default`/`OPEN_EVENT` already opens the detail (`:87–96`), which now includes the instruction card. The event path never no-ops: a deleted event shows the detail's own honest "no longer in the calendar" message; a removed instruction leaves the event content showing. No event-scheduler change is needed |

- **Bounded scheduler change (D14, C17).** `RoutineAlarmScheduling.scheduleRoutineReminder` gains
  `hasInstruction: Bool`; `UNRoutineNotificationScheduler` writes it as `"had_instruction"` through
  the pure `RoutineNotificationContent.userInfo(occurrenceId:entryId:hasInstruction:)`. The
  notification title, body, sound, banner/list outcome, first-photo attachment and scoped-cancel
  identifiers are untouched. `RoutineScheduler.regenerateWindow` passes
  `entry.instruction?.isPresent == true` at its existing schedule call (`RoutineScheduler.swift:366–372`),
  so every re-arm (launch, edit, instruction set/remove) refreshes the flag.
- **Routine tap resolution (D14):**
  - `had_instruction == true`, entry resolves, instruction present → fired screen with title,
    delivery time and the playable instruction card.
  - `had_instruction == true`, entry resolves, instruction now absent (removed after arming) →
    fired screen with title and delivery time plus the plain fallback line
    (`instruction.removed`); no Play, no blank screen (FR-RIE-019/020).
  - `had_instruction == true`, entry gone (deleted after arming) → plain localized
    "This reminder is no longer available." surface (`instruction.reminderUnavailable`) with a Close
    control; no title/time is claimed because none can be resolved.
  - `had_instruction == false` → no-op, exactly today's photo-only behaviour (NFR-RIE-010).
  - Dedupe by entry id: if the fired screen for the same entry is already presented (foreground
    `willPresent` followed by a tap), `didReceive` does not reset it.
- `NotificationFacade` (`:81–91`, `:96–100`) is unchanged: it still completes
  `[.banner, .list, .sound]` and still stops at the first claim. Because every instruction handler
  returns `false`, delivery, read-aloud, and the caregiver handlers are untouched (FR-RIE-015/016).
- A routine notification has no category or custom action today (`RoutineAlarmScheduler.swift:75–79`
  comment: no category actions). "Open" on such a notification is the system default action and
  arrives as `.default`; the tap path therefore needs no taxonomy change.
- The handler gains two sinks: `onFire: (RoutineEntry, Date) -> Void` (foreground) and
  `onInstructionTap: (UUID, RoutineEntry?, Date) -> Void` (tap). `AppCoordinator` wires them to
  `presentRoutineVisualAids(for:at:)` and `presentRoutineInstructionTap(entryId:entry:at:)`. The
  time formats with `LocaleFormatters.shortTime(locale: activeLocale)` (the shipped
  `scheduleSummary` formatter, `RoutineSettingsView.swift:142`). Using `UNNotification.date` (D13)
  keeps the time honest without changing the scheduler's trigger logic.

#### Routine fired screen composition

`FiredRoutineVisualAids` (`VisualAidViews.swift:295–301`) becomes:

```swift
struct FiredRoutineVisualAids: Identifiable, Equatable {
    enum Content: Equatable {
        /// A routine firing: title and time from delivery, plus the instruction.
        /// `instruction == nil && expectsInstruction == true` renders the plain
        /// "instruction no longer available" fallback (instruction removed after
        /// arming) instead of nothing.
        case reminder(title: String, aids: [VisualAid],
                      instruction: Instruction?, expectsInstruction: Bool,
                      timeText: String?)
        /// The owner was deleted between arming and the tap: plain localized
        /// "no longer available" notice, no title/time, no Play.
        case unavailable
    }
    /// Entry id from the notification payload — the presentation identity.
    let entryId: UUID
    let content: Content
    var id: UUID { entryId }
}
```

`RoutineVisualAidOverlay` (`:306–329`) maps `.reminder` to the existing generic
`ReminderVisualAidScreen` **footer** slot and `.unavailable` to the same screen with
`aids: []`, `title: instruction.reminderUnavailable` and an `EmptyView` footer:

```
Close
[photo pager]            // today's pager, unchanged; absent for an instruction-only entry
Title
Time (instruction-bearing firings; nil otherwise)
Photo caption / "Photo 2 of 3"   // unchanged
footer: InstructionCardView
```

- **Shared-screen source change (m-4).** `ReminderVisualAidScreen` gains exactly one parameter,
  `timeText: String?` with a default of `nil`, and one conditional `Text` rendered only when it is
  non-nil. Medication call sites and every no-instruction routine call site pass `nil` and render
  the same view tree as today: **behaviourally identical**, which is what NFR-RIE-010's
  "byte-for-byte today's behaviour" means (a behaviour claim, not a source-diff claim). The
  source-scan baseline (`InstructionSurfaceTests`) records this addition as the only allowed edit
  to `VisualAidViews.swift` and pins that no-instruction call sites pass `nil`.
- An instruction-only entry passes `aids: []`: `showsImage` is false, the pager is absent, the
  title renders, and the footer carries the instruction. Nothing suppresses presentation any more.
- The time is rendered at caption size. Showing it only when an instruction exists or is expected
  is the requirement-driven compromise between FR-RIE-017/020 (title and time) and NFR-RIE-010
  (behavioural baseline for photo-only firings) (D6).

#### Event detail composition

`EventDetailView.detailCards` (`EventsView.swift:598–641`) gains an `InstructionCardView` after the
event-info card and before Navigate. Its `.task(id: version)` (`:580`) also loads the instruction and
instruction image through new coordinator accessors. The form's inset sheet and the fired
notification both reach the same screen, so the elder meets one event face, as today.

#### `InstructionCardView` (shared by both surfaces)

Render rules (pure display state + one card):

| State | Render | Missing media |
|---|---|---|
| text | card, body typography (≥ 18 pt), full-width, wrapping, no truncation | not reachable |
| image | image `scaledToFit`, optional caption below | plain "This picture is not available right now." |
| video | large full-width Play button (min height `DesignTokens.chipHeight`, ≥ 44 pt), optional caption below | plain "This video is not available right now."; no Play if availability is already known missing |
| removed instruction (`expectsInstruction == true`, `instruction == nil`) | plain "This instruction is no longer available." line; no control | n/a |
| unknown | reminder content plus a plain "made with a newer version" note, **no control** | n/a |
| none (`expectsInstruction == false`, no instruction) | nothing (no block, no space) | n/a |

- The pure state is:
  ```swift
  struct InstructionDisplayState: Equatable {
      let instruction: Instruction?
      let expectsInstruction: Bool
      var presentation: InstructionPresentation { get }   // no IO
      var caption: String? { get }
      var isPresent: Bool { get }
  }
  enum InstructionPresentation: Equatable {
      case none
      case missingInstruction        // expectsInstruction && instruction == nil
      case text(String)
      case media(kind: InstructionKind, filename: String?)
      case unsupportedKind(String)
  }
  ```
- The card resolves video availability in `.task` (no disk work in `body`, the house rule); image
  loading happens in `.task` like the existing pager (`VisualAidViews.swift:271–279`).
- Play is always the user's explicit action. No `AVPlayer` is constructed on appearance; no audio
  session is activated. The card is the only place a player is created (FR-RIE-018).
- Caption trimming is the `VisualAidDisplayState.currentCaption` rule
  (`VisualAidDisplayState.swift:61–65`): trimmed, blank → nil, and a nil caption reserves no space.
- VoiceOver: the Play button is labelled "Play the video instruction" (localized), the image is
  labelled "Instruction picture" with the caption as value/hint, the fallback text is read
  naturally, the unavailable notice is read as its text, and the Close control reuses
  `common.close`. No unlabelled new control.

#### Video resolution classification (M-2)

```swift
enum InstructionPlaybackAvailability: Equatable {
    case available(URL)
    case rejectedFilename
    case missingFile
    case unreadableFile
}

enum InstructionResolutionOutcome: String, Equatable {
    case rejectedName = "rejected_name"
    case missing
    case unreadable
}
```

`InstructionVideoStore.availability(filename:for:)` returns the classification:
non-plain name → `.rejectedFilename`; absent → `.missingFile`; present but not a readable regular
file (directory at the path, or `isReadableFile` false) → `.unreadableFile`; otherwise
`.available(url)`. The card maps `.rejectedFilename → rejected_name`, `.missingFile → missing`,
`.unreadableFile → unreadable`, emits one `instruction_resolution` event with `kind` and `outcome`
only, and renders the plain fallback. `.available` emits nothing. The event's typed API accepts
only those two fields, so a filename cannot reach it structurally; a test additionally asserts the
emitted metadata.

Images use `InstructionImageLoading` (m-8):

```swift
enum InstructionImageFailure: Equatable { case rejectedFilename, unavailable }

@MainActor protocol InstructionImageLoading {
    func loadImage(filename: String, for owner: InstructionOwner)
        -> Result<UIImage, InstructionImageFailure>
}
```

Two adapters: `RoutineInstructionImageLoader` over `VisualAidStore` + entryId
(`load(VisualAid(filename: filename), for:)`) and `EventInstructionImageLoader` over
`ContactPhotoStore` (`load(named:)`), each guarded first by `InstructionFilename.isPlain`. The image
stores collapse "absent" and "present but undecodable" into a nil read and this design deliberately
does not widen them, so images classify as `rejected_name` or `missing` (the umbrella outcome for an
unreadable image); `unreadable` is emitted only where the seam can distinguish it (video, above).
A `FakeInstructionImageLoader` with scripted results is the unit-test double.

#### Playback UX and the injectable seam

```swift
enum InstructionPlaybackFailure: Error, Equatable {
    case rejectedFilename, missingFile, unreadableFile,
         unsupportedFormat, playerFailed, interrupted, timedOut
}
enum InstructionPlaybackEvent: Equatable { case ready, failed(InstructionPlaybackFailure),
                                                  finished, dismissed }

@MainActor protocol InstructionVideoPlaying: AnyObject {
    var renderablePlayer: AVPlayer? { get }          // nil in fakes; the cover renders when non-nil
    func present(url: URL, title: String?,
                 completion: @escaping (InstructionPlaybackEvent) -> Void)
    func dismiss()
}

@MainActor final class InstructionPlaybackController: ObservableObject {
    enum State: Equatable { case preparing, playing, failed(InstructionPlaybackFailure) }
    init(player: InstructionVideoPlaying, url: URL, title: String?,
         configuration: InstructionPlaybackConfiguration)
    func start()
    func close()                                     // idempotent; pauses and releases
}
```

Play sequence:

1. Tap Play → the full-screen cover appears immediately (dismissible from its first frame) with a
   neutral preparing state; no audio. This synchronous presentation is what makes the 500 ms target
   credible.
2. Synchronous availability: the card already resolved plain-name/exists/readable in `.task`; a
   known-missing file renders the fallback instead of Play.
3. Asynchronous preflight: `AVURLAsset.load(.isPlayable)` (local file only) under
   `preflightTimeoutSeconds` (default **0.6 s**, configuration). Failure → inline plain fallback in
   the cover. **Measurement point (m-6):** failure latency is measured from the Play tap, with the
   cover presented synchronously in the same tap handler; 0.6 s preflight plus cover update leaves
   margin under NFR-RIE-008's 1 s outer acceptance bound (`:12`).
4. Ready → create the `AVPlayer`, attach it to the cover's SwiftUI `VideoPlayer`, start playback
   (the Play tap was the explicit action), and set `.playing`. The standard AVKit transport is
   available; a custom Close button (≥ 44 pt) sits outside the video area.
5. A ready watchdog (`playerReadyTimeoutSeconds`, default 10 s, configuration) converts a
   never-ready player into `.failed(.timedOut)` — the no-endless-spinner backstop.
6. Pause/close stops audio: `close()` calls `player.pause()`, detaches the item, and releases the
   player; `.onDisappear` calls `close()` too, so a dismissed fired screen cannot leave audio
   running. `.finished` and `.dismissed` also close.
7. No autoplay, no background playback, no notification "Watch video" action (OD-6). Copy states
   the foreground-only limitation honestly in the caregiver editor helper text; the elder-facing
   card claims nothing about background playback.

Production adapter `AVKitInstructionVideoPlayer`: AVFoundation preflight + `AVPlayer` +
`VideoPlayer` render source, with item-status observation mapped to the seam events. It adds no
network call, no audio-session change, and no custom transport.

#### Failure behaviour (plain, localized, non-blocking)

- Media failure never blocks the reminder: the notification is already delivered; the fired screen
  shows the reminder title/time plus the instruction fallback, and is always dismissible.
- No raw error, OSStatus, codec name, file name, or path reaches the caregiver or elder. Each
  error type maps to one localized plain message (see §Error taxonomy).
- Missing/unreadable/rejected file: immediate inline fallback.
- Corrupt/unsupported stored file: preflight failure within `preflightTimeoutSeconds`, or the
  ready watchdog as the last resort.
- Traversal/absolute filename: resolution returns `.rejectedFilename`, the instruction is treated
  as missing, and a PII-free `instruction_resolution` event records the refusal (FR-RIE-012).
- A tap whose instruction was removed or whose owner was deleted never shows a blank screen and
  never claims success (B-2, above).

### Notification integration (preserved contracts)

| Contract | Design |
|---|---|
| `NotificationCategories` is a full-REPLACE builder | **no new category or action**; the file is untouched, so the pre-feature set is registered by construction (FR-RIE-021) |
| Scoped cancels only | `UNRoutineNotificationScheduler`'s identifiers and scoped cancels are untouched; no `removeAllPendingNotificationRequests` (FR-RIE-021) |
| Handlers always return `false` | both instruction handlers keep that contract; the facade's handler loop and completion are untouched (FR-RIE-016) |
| No video in attachments | only the shipped first-photo attachment path exists; `RoutineAlarmScheduling` has no instruction/video URL parameter at all; no code path passes an instruction file to `UNNotificationAttachment`; re-arming copies nothing (FR-RIE-022) |
| Existing notification text | unchanged: routine body = entry title; event content unchanged; instruction media never enters content. The only `userInfo` addition is the producer constant `had_instruction` (D14) |
| Foreground presentation | `willPresent` is the only foreground trigger; `didReceive` is the tap/Open path after unlock, and it now resolves all three instruction tap cases honestly (B-2). No background/cold-launch playback claim (FR-RIE-019) |
| Medication path | no source change; the shared fired screen and facade are behaviourally untouched (NFR-RIE-010) |

### Concurrency, isolation and single-flight

- **UI and presentation state:** all new view models, coordinators and playback controllers are
  `@MainActor`. The fired presentation state dedupes by entry id; `dismiss` is idempotent.
- **Service writes:** `RoutineScheduler.setInstruction` and `FreeFormEventService.setInstruction`
  are synchronous and run on the main actor. There is no `await` between writing the new file and
  persisting the index, so no second write can interleave on the main actor (the `setPhoto`
  transactional shape). The only async steps are *before* commit (the off-main importer) and
  *after* commit (playback).
- **Store isolation:** `InstructionVideoStore` has only immutable stored properties (`FileManager`,
  resolved base URL) and performs `FileManager` operations; it holds no mutable state, so it is safe
  to call from the system picker/recorder callbacks and from the main actor. There is no shared
  cache to lock. The synchronous probe is a pure function of the source URL supplied by the caller;
  the store itself owns no AVFoundation state.
- **Single-flight capture:** one pick/record/validation at a time (`isBusy`); the editor disables
  kind controls while validating or saving.
- **Single playback:** one cover per card; Play is disabled while a cover is presented. Closing the
  cover releases the player.
- **Purge:** `_pending` cleanup runs on the utility housekeeping queue at launch; it removes only
  draft directories and never touches an owner directory.
- **No new locks, no background queues of our own:** the feature uses the existing coordinator
  housekeeping queue and the system callbacks only.

### Error taxonomy and failure behaviour

| Type | Cases | Raised by | User-facing result | Retry |
|---|---|---|---|---|
| `InstructionImportError` | `unreadableSource`, `tooLarge(byteCount)`, `tooLong(seconds)`, `unsupportedFormat`, `validationTimedOut`, `writeFailed`, `cancelled` | synchronous probe/stage (pre-copy cases), inspector, importer | one plain localized message; previous instruction unchanged; `.cancelled` is not an error | yes, pick again |
| `InstructionPlaybackFailure` | `rejectedFilename`, `missingFile`, `unreadableFile`, `unsupportedFormat`, `playerFailed`, `interrupted`, `timedOut` | card resolution, preflight, player, watchdog | plain "not available" text with title/time; cover dismissible | Play again after a transient interruption |
| `InstructionImageFailure` | `rejectedFilename`, `unavailable` | image loader | plain "picture not available" text with the reminder content | on the next fire/detail load |
| `InstructionStorageError` | `notPlainFilename`, `writeFailed`, `moveFailed`, `deleteFailed` | store, returned as `Result` (m-2) | service returns false → plain "didn't save"; previous instruction intact. `deleteFailed` is logged PII-free (cleanup, not the visible save) | yes |
| `InstructionPermissionStatus` | `granted`, `denied`, `undetermined`, `unavailable` | permission seam | plain explanation; recording unavailable; library/reminder unaffected | after changing system settings, on a later attempt |
| Unknown-kind state | — | display state | plain "newer version" note; **no control**; entry otherwise usable | not in v1 |
| Removed / unavailable tap state | — | tap resolution (B-2) | title/time + plain fallback, or plain "no longer available" notice; always dismissible | n/a |
| Blank text | — | normalization | behaves exactly like no instruction (no block) | n/a |

- No raw error text is ever surfaced. Every case has a localized key (§Localisation).
- Logged failures use only `outcome` and a closed `error_code`; no titles, captions, filenames,
  paths or ids.
- `InstructionStorageError.deleteFailed` is reachable because `delete`/`deleteAll` return
  `Result<Void, InstructionStorageError>` (m-2); the services catch it, emit
  `instruction_media_delete` with `outcome=failed`, and never swallow it.

### Configuration (no hardcoded timeouts)

```swift
struct InstructionVideoLimits: Equatable {
    let maxDurationSeconds: TimeInterval
    let maxBytes: Int64
}

struct InstructionVideoConfiguration: Equatable {
    var maxDurationSeconds: TimeInterval = 180
    var maxBytes: Int64 = 200 * 1024 * 1024        // 209,715,200
    var validationTimeoutSeconds: TimeInterval = 20
    var recordingQuality: InstructionRecordingQuality = .high
    var limits: InstructionVideoLimits {
        InstructionVideoLimits(maxDurationSeconds: maxDurationSeconds, maxBytes: maxBytes)
    }
    static let `default` = InstructionVideoConfiguration()
}

struct InstructionPlaybackConfiguration: Equatable {
    /// Sub-second by design: NFR-RIE-008's 1 s is the OUTER acceptance bound for
    /// the fallback, measured from the Play tap with the cover already presented.
    /// 0.6 s leaves margin for cover render/update (review m-6).
    var preflightTimeoutSeconds: TimeInterval = 0.6
    var playerReadyTimeoutSeconds: TimeInterval = 10  // no-endless-spinner backstop
    static let `default` = InstructionPlaybackConfiguration()
}
```

- Limits, timeouts and recording quality are injected at composition (`AppCoordinator`) and in
  tests; no call site spells a numeric timeout.
- Duration comparison rounds the asset duration to the nearest second before comparing to
  `maxDurationSeconds`, so a nominal 3:00 clip whose container timescale reports 180.2 s is not
  rejected as "4 minutes"; 181 s is. The same rounding rule applies to the synchronous probe and
  the importer's second check. Size comparison is exact against 209,715,200 bytes (FR-RIE-006).
- The recording maximum duration passed to the system UI is derived from the same configuration.

### Observability and the release log gate

All instruction events are emitted through one typed emitter in a listed source root; shared files
call typed methods and never build metadata themselves.

| Event type | When | Metadata (all already allowed by `LogSanitiser.allowedKeys`, `LogSanitiser.swift:56+`) |
|---|---|---|
| `instruction_saved` | after a successful/failed index write | `kind` ∈ text/image/video/none; `outcome` |
| `instruction_removed` | after a successful/failed removal | `kind`; `outcome` |
| `instruction_video_import` | pre-copy gate and importer outcome | `kind`=video; `outcome` ∈ accepted/rejected_too_long/rejected_too_large/rejected_unsupported/rejected_unreadable/timed_out/write_failed; top-level `durationMs` |
| `instruction_video_playback` | cover resolves | `kind`=video; `outcome` ∈ started/ready/failed/finished/dismissed; `error_code` ∈ missing/unsupported/timeout/player; top-level `durationMs` (time to ready) |
| `instruction_media_delete` | file cleanup, from the `Result` | `count`; `outcome` ∈ success/failed |
| `instruction_permission` | permission decision | `kind` ∈ camera/microphone; `outcome` ∈ granted/denied/unavailable |
| `instruction_resolution` | media resolution, from `InstructionPlaybackAvailability` / `InstructionImageFailure` | `kind` ∈ image/video; `outcome` ∈ rejected_name/missing/unreadable (images emit rejected_name/missing, §Playback) |

- **No new `LogSanitiser` keys** are required: `kind`, `count`, `outcome`, `state`, `error_code`
  and the event's own `durationMs`/`duration_ms` cover every field. No title, caption, filename,
  path, clear entry/event id, video content or raw OS error can reach an event. The typed emitter
  for resolution accepts only `kind` + `outcome`; a test asserts the emitted metadata for all three
  outcomes and that no filename appears (M-2).
- **Release gate:** add `Services/Instructions`, `App/InstructionViews.swift` and
  `App/InstructionCapture.swift` to `FEATURE_ROOTS` in `ios/tools/check-release-log-safety.py:184`.
  No `FEATURE_EVENT_TYPES` entry is needed because every emitter lives in a listed root; the
  coverage self-test's "listed root matches a Swift file / event type is emitted" legs stay green.
  The gate still runs from `ios/build.sh:431` before every scoped test run.
- No `print`/console writes in the new roots; the gate enforces it.

### Localisation and accessibility

#### Localisation

- Every new user-visible string is in `Localizable.xcstrings` with `en` and `ne`, referenced through
  `L10n` (views use `LocalizedStringKey`/`Text("instruction.…")`). Proposed new family:
  `instruction.title`, `.kind.text/.image/.video`, `.kind.choose`, `.text.placeholder`,
  `.text.blank`, `.image.choose`, `.image.unavailable`, `.video.choose`, `.video.record`,
  `.video.validating`, `.video.ready`, `.video.play`, `.video.playVoiceOver`, `.video.unavailable`,
  `.video.tooLong`, `.video.tooLarge`, `.video.unsupported`, `.video.unreadable`,
  `.video.saveFailed`, `.saveFailed`, `.savePartial`, `.remove`, `.replace`, `.empty`,
  `.caption`, `.saved`, `.unsupportedKind`, `.foregroundNote`, `.removed`,
  `.reminderUnavailable`, `.loadFailed`, `.retry`, `.permission.title`,
  `.permission.cameraWhy`, `.permission.microphoneWhy`, `.permission.cameraDenied`,
  `.permission.microphoneDenied`, `.permission.cameraUnavailable`, `.permission.continue`, plus
  `routine.manageAidsAndInstruction` for the routine manage row's accessibility label.
  Existing `common.close`, `common.cancel`, `common.save` and `visualAid.title` are reused.
- `InfoPlist.strings` for `en` and `ne` supplies the amended camera/microphone usage descriptions
  (D10). The `Info.plist` English text remains the fallback. Both descriptions disclose video
  recording **and** that the recording stays on the device, and retain the existing disclosures
  (medication/appliance photos, live translation, voice commands).
- Any spoken time on a new path goes through `SpokenTime`; this feature speaks no new times. The
  fired time is visual, formatted with the shipped `LocaleFormatters.shortTime`.
- Coverage: extend `L10nCatalogCoverageTests` (`ios/ElderlyAssistantTests/App/`) with the
  `instruction.*` family: every key resolves in en and ne to something other than the key, and the
  two resolutions differ. A companion test reads both `InfoPlist.strings` files and pins the two
  usage keys in both languages.

#### Accessibility

- **Targets:** every new interactive control (Play, Close, kind buttons, choose/record/save,
  replace/remove, Continue on the permission sheet) uses `DesignTokens.minTapTargetSize` (44,
  `DesignTokens.swift:127`) as its floor; the Play and kind buttons also use
  `DesignTokens.chipHeight` (60, `:156`). No drag, scrub, or swipe-only action is added.
- **Text:** body text uses `AppTypography.bodyPointSize` (scaled 21, floor 18,
  `AppTypography.swift:28,35–37`); captions use `captionPointSize` (18, `:29`). Instruction text
  wraps without truncation. The routine fired screen's existing accessibility-size ScrollView
  (`VisualAidViews.swift:170–174`) contains the instruction footer and the unavailable notice, so
  nothing clips at the largest text size. The event detail already scrolls.
- **VoiceOver:** the video Play control, the instruction image (caption as value), the caption text,
  the fallback text, the removed/unavailable notice and the player Close are labelled; no new
  control is unlabelled. The player's standard AVKit transport keeps its system labels.
- **Reduce Motion:** no instruction-specific animation is introduced; the system manages the cover
  transitions (which honour Reduce Motion). If a custom transition is added later, it must check
  `accessibilityReduceMotion`.
- **One-handed:** the Play button spans the card width; Close sits top-leading at 44 pt; neither
  requires a precise drag.
- **Coverage:** `InstructionSurfaceTests` uses the house source-scan idiom
  (`FeatureSourceScan.codeText` + region slicing, as `MedicationEditorSurfaceTests` does) to pin the
  token floor per new control, the presence of accessibility labels, and the allowed `timeText`
  baseline edit (m-4); pure draft/display rules are tested directly. Device accessibility is part of
  the recorded smoke check.

### Template sections not applicable

| Generic template section | Why it does not apply |
|---|---|
| **REST API surface / OpenAPI paths** | This is a single on-device iOS app. The feature's interfaces are in-process Swift protocols (`InstructionVideoProbing`, `InstructionVideoInspecting`, `InstructionVideoImporting`, `InstructionVideoPlaying`, `InstructionVideoPicking`, `InstructionVideoRecording`, `InstructionPermissionRequesting`, `InstructionImageLoading`) plus the service methods in C11–C13. Their error types are explicit and specified in §Error taxonomy (`InstructionImportError`, `InstructionStorageError`, `InstructionImageFailure`, `InstructionPlaybackFailure`). No HTTP endpoint, request/response schema, or OpenAPI document exists or is needed. |
| **Infrastructure topology / Docker services** | There is no service to deploy. The deliverable is the app binary plus its Application Support data; the only "topology" is the two on-device roots and the existing notification scheduler, diagrammed above. No container, database, queue, or cloud component is added (NFR-RIE-003). |
| **Auth strategy** | The feature adds no sensitive action, account, or remote surface. Access is already gated by the device passcode and iOS Data Protection: instruction media is `.completeFileProtection`, readable only while unlocked, and the app presents it only in the foreground after unlock. No new biometric/PIN gate, token, session, or permission beyond the point-of-use camera/microphone prompts is introduced. |

---

## Components

Each component lists its file, responsibility, interface, invariants and the tests that pin it.
"New" means a new file; "changed" means the smallest edit that satisfies the requirement.

### C01 — Instruction model, write semantics and display state (new)

**Files:** `Services/Instructions/Instruction.swift`, `Services/Instructions/InstructionDisplayState.swift`

**Responsibility:** the pure value model (`InstructionKind`, `Instruction`, `InstructionWrite`,
`InstructionPayload`, `InstructionDraft`, `InstructionOwner`, `InstructionRoot`, `StagedInstructionVideo`,
`AcceptedInstructionVideo`, `InstructionFilename`) and the pure mapping from an instruction (plus
"was one expected?") to what a fired card should render.

**Interface (in addition to §Data model):**
```swift
struct InstructionDisplayState: Equatable {
    let instruction: Instruction?
    let expectsInstruction: Bool            // true when the firing was armed with an instruction
    init(instruction: Instruction?, expectsInstruction: Bool = false)
    var presentation: InstructionPresentation { get }
    var caption: String? { get }            // trimmed; image/video only
    var isPresent: Bool { get }
}
enum InstructionPresentation: Equatable {
    case none
    case missingInstruction                // expectsInstruction && instruction == nil
    case text(String)
    case media(kind: InstructionKind, filename: String?)
    case unsupportedKind(String)
}
```
`InstructionOwner` is `.routine(UUID)` / `.event(String)`; `InstructionRoot` is `.routines` /
`.events`. `StagedInstructionVideo { url, filename, byteCount, probed: InstructionVideoMetadata }`;
`AcceptedInstructionVideo { staged, durationSeconds }`.

**Invariants:** no IO; `expectsInstruction == false` + nil → `.none`; `expectsInstruction == true` +
nil → `.missingInstruction` (the B-2 removed-instruction fallback); blank text → `.none`; unknown
kind → `.unsupportedKind(raw)`; image/video with nil filename → `.media` with nil (the card renders
the fallback); caption trimming is the `VisualAidDisplayState.currentCaption` rule.
`InstructionFilename.isPlain` is the single traversal predicate.

**Tests:** new `InstructionDisplayStateTests` — text/image/video/unknown/blank/removed-expected/none,
caption rules, and the availability→outcome mapping (`.available` nil, the three failures to
`rejected_name`/`missing`/`unreadable`); new `InstructionModelTests` (encode/decode, unknown kind,
reserved `url` round-trip, blank text, fail-soft malformed object, `InstructionDraft.resolvedWrite`
truth table: loading/loaded/failed × hasChanges).

### C02 — `InstructionVideoStore` (new)

**File:** `Services/Instructions/InstructionVideoStore.swift`

**Responsibility:** the only component that touches instruction video bytes.

**Interface:**
```swift
final class InstructionVideoStore {
    init(fileManager: FileManager = .default, baseDirectory: URL? = nil)  // path lookup only, no IO

    /// Stat + synchronous probe + reject BEFORE any copy; then a protected
    /// staged write. Fail-closed: a rejected or failed stage leaves no file.
    func stageSynchronously(from sourceURL: URL, in root: InstructionRoot,
                            limits: InstructionVideoLimits,
                            prober: InstructionVideoProbing)
        -> Result<StagedInstructionVideo, InstructionImportError>

    func commit(_ staged: StagedInstructionVideo,
                for owner: InstructionOwner) -> Result<String, InstructionStorageError>
    func discard(_ staged: StagedInstructionVideo)          // best-effort; purge is the backstop

    /// The M-2 classification — never a bare URL?.
    func availability(filename: String, for owner: InstructionOwner)
        -> InstructionPlaybackAvailability

    @discardableResult
    func delete(filename: String, for owner: InstructionOwner)
        -> Result<Void, InstructionStorageError>
    @discardableResult
    func deleteAll(for owner: InstructionOwner) -> Result<Void, InstructionStorageError>
    func purgePendingDrafts()
}
```

**Invariants:**
- `init` resolves `Application Support` with `create: false` and creates nothing (the
  `VisualAidStore` no-IO-init doctrine; `NoIOInInitTests` extended with a FileManager spy).
- `stageSynchronously` order is fixed (B-1/D17): (1) stat the source; reject `> maxBytes`; (2)
  `prober.probe(sourceURL)` synchronously — reject `.tooLong`, `.unsupportedFormat`,
  `.unreadableSource`; (3) only now create the draft directory and destination file **with
  complete protection**, stream-copy, verify; (4) return a staged handle whose filename is already
  plain. A rejection at (1) or (2) creates no directory and no file. A failure at (3) deletes the
  partial file and returns `.writeFailed`.
- `commit` validates the filename, creates the owner directory with complete protection, renames
  (same volume) the already-protected staged file, verifies protection, removes the now-empty draft
  directory, and returns the bare filename. Any failure deletes the committed copy and returns a
  typed error.
- `availability` classifies: non-plain → `.rejectedFilename`; absent → `.missingFile`; present but
  not a readable regular file (directory at the path or `isReadableFile` false) → `.unreadableFile`;
  else `.available(url)`. Never throws, never logs a filename.
- `delete`/`deleteAll` return `.success` when the item is absent after the call, `.deleteFailed`
  when `removeItem` refuses. `deleteAll` removes the owner directory with one `removeItem`;
  `purgePendingDrafts` removes both `_pending` roots and nothing else.
- No console output; no network API; no mutable state (safe from system callbacks); no AVFoundation
  dependency (the prober is the caller's seam).

**Tests:** new `InstructionVideoStoreTests` —
- **pre-copy limits (B-1):** a scripted prober returning a 4-minute duration, an unplayable asset or
  no video track → `.tooLong`/`.unsupportedFormat`; a FileManager spy records **zero copies** and a
  directory listing shows no `_pending` file. Over-size → `.tooLarge`, also no copy.
- size boundary (209,715,200 accepted / +1 rejected); duration boundary 179/180/181 s; protection
  attribute asserted on the **staged** file and on the committed file (m-5); fail-closed partial
  deletion when the copy fails.
- availability table: traversal (`../…`, absolute), absent, unreadable (directory at the expected
  path and a `chmod 000` file), available — the three failures distinct.
- commit rename + single file; replace leaves exactly one file; `delete`/`deleteAll` success and
  `.deleteFailed` through a FileManager spy that throws from `removeItem` (m-2); event-key digest
  stability and no clear id in the path; pending purge; no IO in init.

### C03 — Probe, import and validation (new)

**Files:** `Services/Instructions/InstructionVideoImporter.swift`,
`Services/Instructions/InstructionVideoInspecting.swift`

**Interface:**
```swift
/// Synchronous, local-file, metadata-only read — safe inside the system callback
/// and the mechanism that honours FR-RIE-006's pre-copy ordering (D17).
protocol InstructionVideoProbing {
    func probe(url: URL) -> Result<InstructionVideoMetadata, InstructionImportError>
}

/// Asynchronous second check, off-main, under validationTimeoutSeconds.
protocol InstructionVideoInspecting {
    func inspect(url: URL) async -> Result<InstructionVideoMetadata, InstructionImportError>
}
struct InstructionVideoMetadata: Equatable {
    let durationSeconds: Double
    let hasVideoTrack: Bool
    let isPlayable: Bool
}

protocol InstructionVideoImporting {
    func validate(_ staged: StagedInstructionVideo,
                  limits: InstructionVideoLimits) async
        -> Result<AcceptedInstructionVideo, InstructionImportError>
    func discard(_ staged: StagedInstructionVideo)
}
```

**Production adapters:** `AVInstructionVideoProber` (synchronous `AVURLAsset` metadata reads:
duration, video tracks, playability; local file only; no frame decode) and
`AVInstructionVideoInspector` (async `load(.isPlayable)`, `.duration`, video tracks). Neither makes
a network call and neither generates thumbnails.

**Importer invariants:**
- Second check only: a defensive byte-cap re-check, then the async inspector under
  `validationTimeoutSeconds` (task race; cancellation discards); reject `isPlayable == false`, no
  video track, non-finite duration, and duration over `limits.maxDurationSeconds`.
- Duration rounds to the nearest second before comparison (configuration rule above).
- On any failure the staged bytes are deleted by the importer; on success the caller owns the
  accepted handle and must commit or discard.
- Errors map to one plain localized message at the view layer; the importer never formats copy.

**Tests:** new `InstructionVideoImporterTests` with a scripted inspector — 179/180/181 s, 200 MiB
boundary, unsupported codec, audio-only, timeout, unreadable source, discard-on-failure, no
inspector call for an over-cap staged file, and the second-check cases where the synchronous probe
passed but the async inspection rejects (staged bytes deleted). The production prober is exercised
by the simulator's generated invalid-file case and the device smoke; its contract is scripted in
the store tests.

### C04 — Capture adapters (new)

**File:** `App/InstructionCapture.swift` (UIKit/PhotosUI adapters; UI-layer, not in the log-gate
logic roots)

**Components:**
- `InstructionVideoLibraryPicker: InstructionVideoPicking` — `PHPickerViewController`, `.videos`,
  `selectionLimit = 1`, `.current` representation mode; inside `loadFileRepresentation` it calls
  `stageSynchronously(from:in:limits:prober:)` **once** (which runs the pre-copy limit gate and the
  protected copy); maps no-movie-representation to `.unreadableSource`.
- `SystemInstructionVideoRecorder: InstructionVideoRecording` —
  `UIImagePickerController` camera/video with configured `videoMaximumDuration`/quality; the same
  single `stageSynchronously` call inside the delegate callback; cancel → `.cancelled`; no-camera
  probe.
- `InstructionVideoCaptureCoordinator` (`@MainActor ObservableObject`) — the state machine in
  §Capture; owns permission sequencing, picker/recorder presentation, the second-check validation,
  discard and single-flight. It emits `instruction_video_import` for both pre-copy rejections and
  importer outcomes through the typed emitter. It does **not** commit or persist.

**Invariants:** no copy outside the system callback; the limits/prober are passed to every staging
call (no adapter can bypass the pre-copy gate); no permission request at construction; no prompt
loop; cancellation is not an error; every accepted file is either committed by the surface or
discarded.

**Tests:** new `InstructionCaptureCoordinatorTests` with fake picker/recorder/permissions/prober —
library success, recording success, camera denied, microphone denied, unavailable hardware,
over-long/unplayable selection (plain message, nothing promoted to `.ready`), validation failure,
cancellation, single-flight, discard on leave, and the emitted import outcomes. The UIKit adapters
are exercised by the device smoke only (system UI cannot run in unit tests — the
`CameraCapturePresenting` precedent).

### C05 — Permissions (new)

**File:** `Services/Instructions/InstructionPermissions.swift`

```swift
enum InstructionPermission { case camera, microphone }
enum InstructionPermissionStatus { case granted, denied, undetermined, unavailable }
@MainActor protocol InstructionPermissionRequesting {
    func status(for: InstructionPermission) -> InstructionPermissionStatus
    func request(_ permission: InstructionPermission) async -> InstructionPermissionStatus
}
```

Production adapter uses `AVCaptureDevice.authorizationStatus(for:)` and async `requestAccess`
continuations, plus `.camera` source availability. The pre-permission explanation is a small
localized sheet presented by the capture coordinator **before** the system prompt (first attempt
only). Denial is non-blocking: the editor shows the plain note, library pick and the reminder stay
fully usable.

`Info.plist` (`:113–114`, `:121–122`) is amended in English; `en`/`ne` `InfoPlist.strings` carry the
localized copy (D10). The existing disclosures are retained.

**Tests:** pinned by `InstructionCaptureCoordinatorTests` through the fake seam; the `Info.plist`
and `InfoPlist.strings` text is pinned by `InstructionLocalisationTests`. Real prompts are device
smoke only.

### C06 — Playback seam and controller (new)

**File:** `Services/Instructions/InstructionPlayback.swift`

Implements the protocol/controller from §Playback. `InstructionPlaybackController` owns the
timeouts and the state machine; `InstructionVideoPlaying` owns AVKit. The cover never constructs a
player itself. `close()` is idempotent and pauses/releases.

**Tests:** new `InstructionPlaybackControllerTests` with a fake player — no `present` call before
`start` (no autoplay), `.ready` → `.playing`, `.failed` → fallback, watchdog → `.timedOut` (short
injected timeout), `.finished`/`.dismissed` → closed, `close()` idempotence, renderable player nil
in fakes, and a failure resolved within an injected sub-second preflight timeout (the default 0.6 s
is asserted by the configuration test, not a wall-clock test). Covers the NFR-RIE-009 required four
scripted outcomes (play, pause/close, failure, missing file — the last at the card/availability
seam).

### C07 — AVKit adapter (new)

**File:** `Services/Instructions/AVKitInstructionVideoPlayer.swift`

Production `InstructionVideoPlaying`: local-file preflight (`load(.isPlayable)` under
`preflightTimeoutSeconds`, default 0.6 s), `AVPlayer` creation, item-status observation, playback
start on ready, `pause` + release on dismiss. Exposes `renderablePlayer` for the cover's SwiftUI
`VideoPlayer` (the `FeedMediaPlayerSheet` precedent, `FeedsView.swift:686–695`). No network, no
audio-session changes, no custom transport. Device smoke covers rendering and audio; unit tests
never instantiate it.

### C08 — `InstructionCardView`, image loading and player cover (new)

**File:** `App/InstructionViews.swift`

`InstructionCardView` implements the render table in §Fire-time presentation and owns its
`InstructionPlaybackController` + full-screen cover. Inputs: `instruction`, `expectsInstruction`,
`owner`, `videoStore`, `imageLoader`, `events` (typed emitter), `playbackFactory`,
`playbackConfiguration`, `locale`.

- Video: resolves `videoStore.availability` in `.task`, renders the fallback or Play, emits one
  `instruction_resolution` from the classification (M-2).
- Image: `imageLoader.loadImage(...)` in `.task`; `.rejectedFilename` emits `rejected_name`,
  `.unavailable` emits `missing`; both render the plain picture fallback (m-8).
- `InstructionImageLoading` is the explicit success/failure protocol from §Playback; the two
  production adapters are `RoutineInstructionImageLoader` (over `VisualAidStore` + entryId) and
  `EventInstructionImageLoader` (over `ContactPhotoStore`). `FakeInstructionImageLoader` scripts
  results in tests.
- The cover (`InstructionPlaybackCover`) shows the preparing state, `VideoPlayer` when a renderable
  player exists, the inline plain fallback on failure, and a ≥44 pt Close. It presents from the card
  (nested presentation: card inside the fired `fullScreenCover` or the event `sheet`). The fallback
  plan if nested presentation misbehaves on an OS version is to hoist the cover to `ContentView`
  through coordinator state; the device smoke checks the nested path first.

**Tests:** `InstructionSurfaceTests` pins the source for Play/Close token floors, labels, the
fallback texts, the removed-instruction branch, the no-control unknown-kind branch, and the allowed
`VisualAidViews.swift` baseline (`timeText` default + conditional render; nil at no-instruction call
sites) (m-4). Card resolution/failure logic is tested with scripted store/loader/emitter doubles,
including the no-filename assertion for all three outcomes.

### C09 — Routine instruction editor (new + changed)

**Files:** `App/InstructionViews.swift` (new section), `App/RoutineSettingsView.swift` (changed),
`App/VisualAidViews.swift` (overlay composition + the defaulted `timeText` parameter)

- `RoutineSettingsView`'s existing manage-row sheet (`:71–89`) gains the instruction section. The
  row button (`:107–116`) keeps its photo icon but gains the new accessibility label
  `routine.manageAidsAndInstruction` ("Instructions and photos"); medication rows keep
  `visualAid.add`.
- `RoutineInstructionSection` shows the current instruction or an empty state, a three-way kind
  picker, the kind-specific editor, Replace/Remove, and the capture coordinator's states. On
  `.onAppear` it loads the existing instruction into an `InstructionDraft`; the controls are
  read-only until the load is `.loaded`; a `.failed` load shows a plain message and Retry. Its Save
  calls the coordinator only when `draft.resolvedWrite` is non-nil, and removal is the explicit
  Remove control producing `.remove`. The coordinator calls
  `routineScheduler.setInstruction(write, entryId:)` immediately (the photo-aid editing rhythm).
  A failure keeps the draft and shows the plain message; success clears it and shows the saved
  preview. There is no unrelated-edit path on this surface, so the M-1 hazard does not arise here,
  but the same load gating is used for consistency.
- `ReminderVisualAidEditorView` remains medication-neutral: the instruction section is opt-in
  (nil/default for medication call sites); the photo editor's existing behaviour is unchanged.
- `FiredRoutineVisualAids`/`RoutineVisualAidOverlay` gain the `Content` shape and pass
  `InstructionCardView` in the existing footer slot (D5); the shared `ReminderVisualAidScreen`
  gains only the defaulted `timeText` parameter (m-4).

**Tests:** `RoutineSchedulerTests` (set/replace/remove, re-arm, delete-with-owner, video-only entry,
failure keeps previous, media-delete Result logged), `RoutineVisualAidFireHandlerTests` (gates,
always false, the three tap cases), `InstructionSurfaceTests` (editor controls, labels, load-failure
read-only state).

### C10 — Free-form event editor and detail (changed + new)

**Files:** `App/EventsView.swift` (changed), `App/InstructionViews.swift` (new section)

- `EventFormView` gains `EventInstructionSection` between the photo card (`:284–327`) and the
  address card. The section binds an `InstructionDraft` in `@State`; on `.onAppear` it loads the
  existing instruction through the coordinator. **Form Save is disabled while
  `draft.loadState == .loading`.** On `.failed` the section is read-only with a plain message and
  Retry; unrelated event edits remain saveable with `resolvedWrite == nil` (M-1).
- The form's Save calls
  `coordinator.saveFreeFormEvent(form, instruction: draft.resolvedWrite, editing: event?.id)`:
  - `instruction == nil` → leave the stored instruction untouched (no service instruction call);
  - `.set(payload)` → write/replace after the event id exists;
  - `.remove` → explicit removal;
  - success → dismiss;
  - instruction failure → stay open with the plain partial-save message and adopt the returned
    event id so a retry edits the created event (D12).
- `EventDetailView.detailCards` (`:598–641`) adds the instruction card after the info card; `load()`
  reads the instruction and instruction image through new coordinator accessors.
- `FreeFormEventService` gains:
  ```swift
  func instruction(forEventId: String) -> Instruction?
  func instructionImage(forEventId: String) -> UIImage?
  @discardableResult
  func setInstruction(_ write: InstructionWrite, forEventId: String) -> Bool
  func save(_ form: FreeFormEventForm, instruction: InstructionWrite?,
            editing eventId: String? = nil) -> FreeFormEventSaveOutcome?
  ```
  `setInstruction` is **non-optional**: `.remove` is the only removal path; the save seam's `nil`
  means "leave untouched" and performs no instruction work. `save` applies `.set`/`.remove` **after**
  the event id exists, via the same transactional `setInstruction`; it returns
  `FreeFormEventSaveOutcome(eventId:instructionSaved:)` where `instructionSaved` is false only when
  a requested instruction write failed (`true` when nothing was requested).
- `AppCoordinator.saveFreeFormEvent` takes the resolved write, returns the outcome, and keeps its
  Google share notification for the saved event. Its callers (`EventFormView`) read the outcome.

**Tests:** `FreeFormEventServiceTests` (draft save, partial outcome, set/replace/remove, the
`nil`-write leave-untouched case, delete/reconcile cleanup, photo/instruction mutual preservation,
pre-feature payload), `FreeFormEventFormTests` (form validity untouched; draft semantics:
loading/loaded/failed × hasChanges; failed load passes `nil` and the instruction survives),
`FreeFormEventFireHandlerTests` (gate and tap), `InstructionSurfaceTests`.

### C11 — `RoutineScheduler` changes (changed)

**File:** `Services/Reminders/RoutineScheduler.swift`

- Add `instructionVideoStore: InstructionVideoStore? = nil` to the initializer (default nil keeps
  every existing test harness constructing unchanged).
- Add:
  ```swift
  @discardableResult
  func setInstruction(_ write: InstructionWrite, entryId: UUID) -> Bool
  ```
  It resolves the entry and switches on the write:
  - `.set(payload)`: apply pending image (via `visualAidStore.save`), then pending video (via
    `instructionVideoStore.commit`), build the final normalized `Instruction`, persist through
    `persistAndReschedule(entry, eventType: "entry_instruction_updated", metadata: ["kind": …,
    "count": …])` (the existing `setVisualAids` path, `:131–137` / `:202–213`), then delete the
    previous instruction's media if the new instruction no longer references it.
  - `.remove`: persist `instruction = nil` through the same `persistAndReschedule`, then delete the
    old media (`delete`/`deleteAll` `Result`; a `.deleteFailed` is logged, the index stays
    authoritative).
  On a persistence failure it deletes the pending writes and returns false, leaving the previous
  instruction intact.
- `removeEntry` (`:111–117`) additionally calls `instructionVideoStore?.deleteAll(for: .routine(id))`
  and logs a `.deleteFailed`; the existing `visualAidStore.deleteAll` already removes a routine
  image instruction.
- Scheduling passes `hasInstruction: entry.instruction?.isPresent == true` at its existing
  `scheduleRoutineReminder` call (`:366–372`); `visualAidURL` (`:391`) is unchanged — notifications
  still attach only the first photo. No video path is added to scheduling.

**Tests:** `RoutineSchedulerTests` extensions — set/replace/remove, explicit `.remove`, re-arm,
delete-with-owner, video-only entry, failure keeps previous, the fake alarm scheduler receives
`hasInstruction` matching the entry's instruction presence and only a photo URL, and scoped cancels
only (no remove-all). The protocol change means existing fake schedulers gain the parameter.

### C12 — `EventExtrasStore` changes (changed)

**File:** `Services/Storage/EventExtrasStore.swift`

- Add `instruction: Instruction?` to `EventExtras`, tolerant decode, default nil.
- Fix `setPhotoFilename` to mutate the existing extras (critical; see §Data model).
- Add:
  ```swift
  @discardableResult
  func storeInstruction(_ instruction: Instruction?, forEventId: String) -> Bool
  ```
  which mutates `extras(forEventId:) ?? EventExtras()`, preserving `photoFilename`, and writes the
  whole index back. The optional here is the **payload** (nil = no instruction stored), reached only
  after the service resolved an explicit `.remove`; it is not the `InstructionWrite?` save seam.
- `remove` (`:131–136`) already returns the dropped extras; the service now uses
  `dropped.instruction` for file cleanup.

**Tests:** `EventExtrasStoreTests` — pre-feature fixture, photo save preserves instruction,
instruction save preserves photo, `storeInstruction(nil)` clears only the instruction, remove
returns both, unknown kind decodes, malformed instruction object does not take the index down.

### C13 — `FreeFormEventService` lifecycle (changed)

**File:** `Services/Events/FreeFormEventService.swift`

- Inject `instructionVideoStore: InstructionVideoStore?` (default production instance for parity
  with `photoStore`; the coordinator passes its shared instance).
- `setInstruction(_ write: InstructionWrite, forEventId:)` mirrors C11 using `photoStore` for image
  instructions and the video store for video instructions. Ordering: pending writes → index → old-
  file deletion. A failed index write deletes the pending writes and returns false. A media-delete
  `.deleteFailed` is logged (never surfaced as a save failure of the index state).
- `save(form, instruction: InstructionWrite?, editing:)`: `nil` skips instruction work; a non-nil
  write is applied only after the event id exists; the outcome reports `instructionSaved`.
- `upcoming`'s vanish branch (`:293–315`) and `delete` (`:424–431`) delete the instruction image and
  the event video directory alongside the event photo (`deleteInstructionMedia(in:eventId:)`), via
  the `Result`-returning store methods and typed logging.
- Accessors `instruction(forEventId:)` and `instructionImage(forEventId:)`.

**Tests:** `FreeFormEventServiceTests` extensions (save outcome, partial save, nil-write leaves
instruction, explicit remove, replace/remove, delete/reconcile, photo preservation, no orphans after
replace/delete, delete-failure logging).

### C14 — Fire handlers (changed)

**Files:** `Services/Notifications/RoutineVisualAidFireHandler.swift`,
`Services/Notifications/FreeFormEventFireHandler.swift`

- **Routine:**
  ```swift
  init(entryLookup: @escaping (UUID) -> RoutineEntry?,
       onFire: @escaping (RoutineEntry, Date) -> Void,
       onInstructionTap: @escaping (UUID, RoutineEntry?, Date) -> Void)
  ```
  `willPresent` gate becomes `visualAids.isEmpty && !(entry.instruction?.isPresent ?? false)`, and
  the main-queue `onFire(entry, notification.date)` fires for instruction-bearing entries. New
  `didReceive`: only the default action; only when `userInfo["had_instruction"] as? Bool == true`;
  resolve the entry (may be nil), then main-queue `onInstructionTap(entryId, entry, notification.date)`.
  A missing key or `false` is a no-op (today's photo-only behaviour). Always returns `false`.
- **Event:** gate `photoFilename != nil` → `photoFilename != nil || instructionPresent(eventId)`
  (m-1). The new dependency is `instructionPresent: (String) -> Bool`; C15 wires it to
  `freeFormEventService.instruction(forEventId:)?.isPresent == true`. The test fake supplies a
  dictionary-backed predicate. `didReceive` unchanged (always opens the detail for a deleted event
  too, which shows its own honest message). Always returns `false`.
- No category, action, attachment, cancel-scope, or facade change.

**Tests:** both handler suites extended. `RoutineVisualAidFireHandlerTests` covers the **three
instruction tap cases** — (1) instruction present → `onInstructionTap(entryId, entry, date)`;
(2) instruction removed after arming (`had_instruction == true`, entry resolves, `instruction ==
nil`) → same callback, and `InstructionDisplayStateTests` proves the presentation is
`.missingInstruction`; (3) entry deleted (`had_instruction == true`, `entryLookup` nil) → callback
with `entry == nil`, which the coordinator maps to `.unavailable`. Plus the photo-only
(`had_instruction == false`) no-op baseline and always-`false` for every path.
`FreeFormEventFireHandlerTests` covers the new instruction-present gate and its fake.
`NotificationFacadeTests` and `NotificationCategoriesTests` run unchanged as the preserved-baseline
gate.

### C15 — Composition and presentation state (changed)

**File:** `App/AppCoordinator.swift`

- Owned properties (all no-IO init): `instructionVideoStore = InstructionVideoStore()`,
  `instructionVideoImporter`, `instructionVideoProber`, `instructionPermissions`,
  `instructionPlaybackConfiguration`, and the capture adapters/factory as needed by the views. Pass
  the shared stores into `RoutineScheduler` (wiring at `:3583`) and the lazy
  `freeFormEventService` (`:12862`).
- Fired routine state (`:13395`) uses the `FiredRoutineVisualAids.Content` shape;
  `presentRoutineVisualAids(for:at:)` (`:13441`) builds `.reminder` with
  `timeText = instructionPresent ? LocaleFormatters.shortTime(date, locale: activeLocale) : nil`
  (D6) and dedupes by entry id. New `presentRoutineInstructionTap(entryId:entry:at:)` builds
  `.reminder` (title/time, `expectsInstruction: true`, instruction possibly nil → fallback) or
  `.unavailable` when the entry is nil (B-2).
- Handler wiring (`:4591–4598`): the routine handler gains `onInstructionTap` in addition to the
  `(entry, date)` sink; the event handler is constructed with the `instructionPresent` lookup
  through the lazy service (`:4626–4633`).
- New accessors: `routineInstruction`/`saveRoutineInstruction`; `eventInstruction(forEventId:)` and
  `eventInstructionImage(forEventId:)`; the updated `saveFreeFormEvent(_:instruction:editing:)`
  signature (resolved write, `nil` = leave untouched).
- Launch: call `instructionVideoStore.purgePendingDrafts()` on the existing utility housekeeping
  queue (`:571`), not on `init` or the boot-critical path.
- `ContentView` (`:65–72`, `:107–110`) needs no new mount: instructions ride the existing routine
  overlay and event detail. The card's playback cover is nested inside those presentations.

**Tests:** covered through the service/handler/controller suites; `NoIOInInitTests` extended with
the store's FileManager-spy init; the handler wiring is pinned by the handler suites.

### C16 — Tests and gates (new/extended)

**New suites**

| Suite | Covers |
|---|---|
| `InstructionVideoStoreTests` | pre-copy limits (no staged file), size/duration boundaries, protection on staged + committed files, availability classification (traversal/absent/unreadable/available), commit/replace/delete Result, digest key, pending purge, no IO in init |
| `InstructionVideoImporterTests` | second-check duration/size/codec/timeout/discard, no transcode, boundaries |
| `InstructionDisplayStateTests` | text/image/video/unknown/blank/none, removed-instruction fallback, caption rules, availability→outcome mapping, draft truth table |
| `InstructionPlaybackControllerTests` | no autoplay, ready/failure/timeout/finish/dismiss/close, injected sub-second preflight |
| `InstructionCaptureCoordinatorTests` | library/record/permission denial/unavailable/over-long/validation/cancel/single-flight |
| `InstructionSurfaceTests` | source-pin editor/card controls (44 pt, tokens, VoiceOver labels, no link control, no unknown-kind control), removed-instruction branch, the allowed `VisualAidViews.swift` baseline (m-4) |
| `InstructionLocalisationTests` | `instruction.*` en/ne parity + `InfoPlist.strings` en/ne usage keys |
| `InstructionReleaseSafetyTests` | static scan of the new roots for network/upload/transcription APIs, forbidden content in log statements, and the FR-RIE-022 pin (no instruction/video reference or attachment path in `RoutineAlarmScheduler.swift`) |
| `RoutineNotificationSchedulerTests` | **new** (replaces the phantom `RoutineAlarmSchedulerTests`, m-3): the pure `RoutineNotificationContent.userInfo` keys (`had_instruction` Bool included), notification identifier namespace, scoped-cancel identifier mapping, and no instruction/video attachment input |

**Extended suites:** `RoutineEntryTests`, `RoutineStoreTests`, `RoutineSchedulerTests`,
`VisualAidStoreTests` (instruction image coexistence/deletion), `VisualAidDisplayStateTests`,
`RoutineVisualAidFireHandlerTests` (three tap cases + photo-only no-op), `EventExtrasStoreTests`,
`FreeFormEventServiceTests` (nil-write, explicit remove, failed-load safety), `FreeFormEventFormTests`
(draft semantics), `FreeFormEventFireHandlerTests` (instructionPresent gate),
`NotificationFacadeTests`, `NotificationCategoriesTests`, `NoIOInInitTests`,
`L10nCatalogCoverageTests`.

**Gates:** `./build.sh` is canonical (`ios/build.sh`; release log gate at `:431`, scoped
`-only-testing` runs at `:458`); `xcodebuild test`, not `build`, per the build-environment rule.
Focused suites green, typecheck/build clean, recorded full-suite baseline unchanged. **One recorded
real-device smoke check on a Release build** (m-7) installed on the reference device, recorded with
the build number and commit, covers: library pick, recording with permissions, a fired routine Play
with audio, event detail Play, close stops audio, the routine tap path for all three tap cases,
largest accessibility text size, VoiceOver labels, camera denial, microphone denial, and the
foreground-only copy. Simulator covers every failure path: missing file, corrupt file, unsupported
codec (fake inspector plus a generated invalid file), traversal filename, replace failure, playback
failure, timeout, and an over-long/unplayable source never reaching the staged copy. No UI test is
required (OD-7).

### C17 — Routine notification content (changed, bounded; review B-2)

**File:** `Services/Reminders/RoutineAlarmScheduler.swift`

**Responsibility:** carry one extra producer-constant fact — whether the firing was armed with an
instruction — so the routine tap path can distinguish an instruction-bearing firing from a
photo-only/no-instruction one without changing any shipped behaviour.

**Interface:**
```swift
// Pure, testable builder (no UNUserNotificationCenter at construction).
enum RoutineNotificationContent {
    static let hadInstructionKey = "had_instruction"
    static func userInfo(occurrenceId: UUID, entryId: UUID,
                         hasInstruction: Bool) -> [String: Any]
}

protocol RoutineAlarmScheduling {
    func scheduleRoutineReminder(
        occurrenceId: UUID, entryId: UUID, title: String,
        visualAidURL: URL?, hasInstruction: Bool, at scheduledTime: Date
    )
    // cancels unchanged
}
```

**Invariants:**
- `userInfo` is exactly today's three keys plus `had_instruction` (a Bool); no user data is added.
- Notification title/body/sound, banner/list outcome, the first-photo attachment and its throwaway
  copy, and the scoped-cancel identifiers are **unchanged**. No instruction/video URL is ever a
  parameter, so no video can reach `UNNotificationAttachment` (FR-RIE-022).
- A pending request armed before this release has no key; the handler treats that as `false` (the
  pre-feature no-op). Re-arming on launch/upgrade writes the key for future firings.
- `RoutineScheduler` passes `entry.instruction?.isPresent == true` at the existing call site.

**Tests:** new `RoutineNotificationSchedulerTests` (pure builder + identifiers); `RoutineSchedulerTests`
asserts the flag passed by the scheduler and the scoped-cancel contract; `InstructionReleaseSafetyTests`
pins the source for no instruction/video attachment path.

---

## Traceability

| Requirement | Design sections / components | Primary tests |
|---|---|---|
| FR-RIE-001 model, one kind, media-only valid | Data model; C01, C11, C12 | InstructionDisplayStateTests, RoutineEntryTests, EventExtrasStoreTests |
| FR-RIE-002 text | Capture · Text; C01, C08, C09/C10 | InstructionDisplayStateTests, InstructionSurfaceTests |
| FR-RIE-003 image via existing stores | Capture · Image; D3; C09/C10/C13 | VisualAidStoreTests, FreeFormEventServiceTests, InstructionSurfaceTests |
| FR-RIE-004 library pick | Capture · Library; C04 | InstructionCaptureCoordinatorTests; device smoke |
| FR-RIE-005 in-app recording | Capture · Recording; C04, C05 | InstructionCaptureCoordinatorTests; device smoke |
| FR-RIE-006 limits, as provided, codec reject | Configuration; D17; C02, C03, C04 | InstructionVideoStoreTests (pre-copy rejections, no staged file), InstructionVideoImporterTests (second check), InstructionCaptureCoordinatorTests |
| FR-RIE-007 optional caption, blank no space | Data model; C01, C08 | InstructionDisplayStateTests, InstructionSurfaceTests |
| FR-RIE-008 lifetime, edits re-arm | C11, C13; D14/D15 | RoutineSchedulerTests, FreeFormEventServiceTests |
| FR-RIE-009 existing edit surfaces | C09, C10 | InstructionSurfaceTests |
| FR-RIE-010 plain feedback, safe failure | Error taxonomy; C04, C09, C10 | InstructionCaptureCoordinatorTests, InstructionSurfaceTests, FreeFormEventServiceTests |
| FR-RIE-011 roots, bare names, protection | Storage; C02; D18 | InstructionVideoStoreTests (staged + committed protection, bare names) |
| FR-RIE-012 filename hygiene | Storage; C01, C02, C08; D16 (M-2) | InstructionVideoStoreTests (three distinct outcomes), InstructionDisplayStateTests (mapping), InstructionSurfaceTests (no filename in event) |
| FR-RIE-013 transactional replace | Storage lifecycle; C11, C13 | RoutineSchedulerTests, FreeFormEventServiceTests |
| FR-RIE-014 delete with owner | Storage lifecycle; C11, C13; m-2 | RoutineSchedulerTests, FreeFormEventServiceTests, InstructionVideoStoreTests (delete Result) |
| FR-RIE-015 always fires | Fire-time; C14 | RoutineVisualAidFireHandlerTests, FreeFormEventFireHandlerTests |
| FR-RIE-016 handlers always false | C14 | both handler suites, NotificationFacadeTests |
| FR-RIE-017 composition per kind | Fire-time; D5/D6; C08, C09, C10 | handler suites, InstructionSurfaceTests, InstructionDisplayStateTests |
| FR-RIE-018 explicit Play, no autoplay | Playback; C06, C07, C08 | InstructionPlaybackControllerTests, InstructionSurfaceTests |
| FR-RIE-019 tap/Open path, foreground-honest | Fire-time; D13/D14; C14, C15, C17 (B-2) | RoutineVisualAidFireHandlerTests (instruction present / removed / entry deleted / photo-only no-op), InstructionDisplayStateTests (.missingInstruction), InstructionSurfaceTests (.unavailable) |
| FR-RIE-020 plain fallback, PII-free | Error taxonomy; C06, C08, C14 | InstructionPlaybackControllerTests, InstructionSurfaceTests, RoutineVisualAidFireHandlerTests |
| FR-RIE-021 taxonomy preserved | Notification integration; C17 | NotificationCategoriesTests, RoutineSchedulerTests (scoped cancels), RoutineNotificationSchedulerTests (m-3) |
| FR-RIE-022 no video attachments/copies | Notification integration; C11, C17 | RoutineNotificationSchedulerTests (no video/instruction path), RoutineSchedulerTests (protocol has no instruction URL), InstructionReleaseSafetyTests (source pin) |
| FR-RIE-023 no new machinery | Notification integration; C14 | handler suites, facade tests |
| FR-RIE-024 honest capability surface | Data model (`url` inert), D8; C08 | InstructionDisplayStateTests, InstructionSurfaceTests |
| FR-RIE-025 permissions, denial non-blocking | Capture · Permissions; C05 | InstructionCaptureCoordinatorTests, InstructionLocalisationTests; device smoke |
| NFR-RIE-001 accessibility | Accessibility; C08, C09, C10 | InstructionSurfaceTests; device accessibility smoke |
| NFR-RIE-002 en/ne, no hardcoded copy | Localisation; C16 | InstructionLocalisationTests, L10nCatalogCoverageTests, source scan |
| NFR-RIE-003 no egress | Layering; C03, C06, C07 | InstructionReleaseSafetyTests |
| NFR-RIE-004 PII-free logs, release gate | Observability; C04, C08 | InstructionReleaseSafetyTests, InstructionSurfaceTests (no filename), build gate |
| NFR-RIE-005 at-rest protection | Storage; C02; D18 (m-5) | InstructionVideoStoreTests (staged + committed attribute); device smoke |
| NFR-RIE-006 migration | Data model; C01, C11, C12 | RoutineEntryTests, EventExtrasStoreTests (pre-feature fixtures) |
| NFR-RIE-007 footprint, zero orphans | Storage lifecycle; C02, C11, C13 | InstructionVideoStoreTests, service tests |
| NFR-RIE-008 playback responsiveness | Playback; Configuration; C06 | InstructionPlaybackControllerTests (injected sub-second preflight); simulator failure matrix; Release-build device smoke (timings) |
| NFR-RIE-009 playback seam + gates | Playback seam; C06, C16; m-7 | InstructionPlaybackControllerTests; recorded Release-build device smoke |
| NFR-RIE-010 preserved baseline | Notification integration; D5/D6/D14; C14, C17 | facade/category/medication suites, RoutineVisualAidFireHandlerTests (photo-only tap no-op), source-scan baseline (behaviourally identical) |

---

## Risks and open questions

### Owner-level open questions

**None.** OD-1 … OD-8 are resolved in the feature constitution (2026-10-25). The design-level
choices above (D1–D18) are recorded for `review-l1` ratification; none changes scope, storage
policy, playback UX, or safety posture.

### Risks and mitigations

1. **`EventExtrasStore.setPhotoFilename` erasure (critical).** Saving an event photo would clear the
   instruction unless the method mutates existing extras. Mitigated by C12 and a dedicated
   `EventExtrasStoreTests` case (save photo → instruction survives; save instruction → photo
   survives). This is the first thing the implementer must change.
2. **Nested presentation (medium; accepted iteration 1).** The playback cover presents from inside
   an already-presented routine `fullScreenCover` or event `sheet`. Supported on the deployment
   target, but SwiftUI presentation can regress at OS edges. Mitigation: check on the simulator and
   the device smoke; fallback plan is hoisting the cover to `ContentView` through coordinator state
   without changing the seam.
3. **Ephemeral system URLs (medium; accepted iteration 1).** PHPicker's `loadFileRepresentation`
   URL and `UIImagePickerController`'s `mediaURL` are valid only inside their callbacks. The
   synchronous pre-copy probe + stage copy are load-bearing (B-1/D4). Unit tests cannot run the
   system callbacks; the device smoke covers library pick and recording. Both callbacks use one
   store call so the rule is enforced in one place.
4. **`UIImagePickerController` video capture on the current OS (medium).** Permission ordering,
   silent-audio behaviour, and cancellation need device confirmation; the simulator cannot cover
   them. No custom capture UI is designed, which keeps the risk bounded.
5. **File-protection enforcement (low).** Protection is now applied at file creation, so there is no
   weaker-class staging window (D18/m-5); the simulator reports the attribute but does not enforce
   Data Protection. The device smoke records that a saved instruction plays and that the store
   reports complete protection on both the staged and committed file; enforcement is an iOS
   property, not app code.
6. **NFR-RIE-008 timing targets (medium).** 500 ms presentation / 2 s first frame / 1 s failure are
   device acceptance targets measured on a **Release build**. The cover is presented synchronously
   on the Play tap; the preflight default is 0.6 s (sub-second, leaving margin under the 1 s outer
   bound), and readiness is watched at a configurable 10 s. The recorded Release-build smoke is the
   only honest evidence for the first two.
7. **Event image resolution (low, accepted iteration 1).** `ContactPhotoStore` stores 512 px
   thumbnails; an event instruction diagram inherits that. FR-RIE-003 binds event images to the
   existing path and forbids a parallel image store, so this is a requirements consequence, not an
   implementation choice. Routine image instructions use the 1600 px `VisualAidStore` pipeline.
8. **Backup inclusion (low, accepted iteration 1).** Instruction video is included in the normal iOS
   backup (D9). This is not app egress and matches the shipped photo aids; if the owner wants
   backup-excluded media, that is a scope change to raise at review, not a design defect.
9. **Time shown only for instruction-bearing firings (low, accepted iteration 1).** D6 is the only
   way to satisfy both FR-RIE-017/020 and NFR-RIE-010's baseline. A photo-only firing is
   behaviourally identical to today; an instruction-bearing or instruction-expected firing shows
   the title and the delivery time.
10. **Delivery-time vs scheduled-time (low).** `UNNotification.date` is the delivery date. A
    system-delayed notification would display the later time; that is arguably the honest "when
    this fired". The scheduled-time alternative is a `scheduled_at` userInfo key (a further
    scheduler change), not chosen here.
11. **Source-scan tests are heuristic (low).** The hardcoded-copy and network-API scans pin tokens,
    not semantics. They are backed by the release gate and by reviewer inspection of the new roots;
    the design states the limit rather than overclaiming instrumentation.
12. **Unknown-kind note (low).** A future `link` instruction will show a plain "newer version" note
    rather than nothing. This is honest and contains no control; a future release replaces the note
    with the link renderer using the preserved `kind`/`url` fields.
13. **Synchronous metadata probe inside the system callback (medium; accepted for B-1).** Honouring
    FR-RIE-006's pre-copy ordering requires reading the local file's metadata on the callback's
    thread (the main thread for `UIImagePickerController`'s delegate). The probe is metadata-only
    (duration, playability, video track), does not decode frames, does not copy, and runs once per
    pick; the heavyweight inspection stays off-main. A pathological file can delay the picker's
    dismissal, never the reminder or its delivery. The alternative — keeping a post-copy check —
    violates a locked MUST; an owner amendment would be the only other route, and it is not
    proposed.
14. **Notifications armed before this release lack `had_instruction` (low).** The handler reads a
    missing key as `false`, so an old pending notification's tap is today's no-op; the next launch
    re-arms and writes the flag. No migration is needed, and no false claim is shown.
15. **Failed initial instruction load on the event form (low; mitigated).** Save is disabled while
    loading; a failed load makes the instruction section read-only with Retry and passes `nil`
    (leave untouched) to the save seam. The regression test proves an unrelated edit and a failed
    load cannot erase the stored instruction (M-1).
16. **Media-delete refusal after a successful index write (low).** `delete`/`deleteAll` return
    `.deleteFailed`, which is logged PII-free and never claimed as success (m-2). The index is
    authoritative, so the instruction no longer resolves; a protected orphan can remain on disk
    until a later successful cleanup. This is an OS-level refusal, not an app path; no user-facing
    copy claims the file was removed.

### Deliberate non-changes

- `NotificationFacade`, `NotificationCategories`, `VisualAidStore` (except reuse),
  `ContactPhotoStore` (except reuse), `LogSanitiser`, and every medication source file are
  unchanged.
- `RoutineAlarmScheduler` changes only by the bounded `hasInstruction` argument and the pure
  `RoutineNotificationContent.userInfo` builder (D14/C17): notification title/body, banner/list/
  sound, the first-photo attachment and its throwaway copy, and the scoped-cancel identifiers are
  untouched.
- `ReminderVisualAidScreen` gains exactly one defaulted `timeText` parameter and its conditional
  render; medication and no-instruction routine call sites pass `nil` and are **behaviourally
  identical** to today (the source-scan baseline pins this; m-4).
- No new notification category, action, attachment, audio session, network client, container,
  database, or auth mechanism.

---

## Deferred work

- **YouTube/link instructions (OD-3):** model slot preserved (`kind` raw string + `url`), no UI,
  no playback path. A later release adds the `.link` case, the renderer, the YouTube integration
  and its offline/failure handling.
- **Background or cold-launch video playback (OD-6):** v1 is foreground-only with the tap/Open
  path. Any future background playback needs an explicit product/safety decision; the current UI
  makes no such claim.
- **Multiple instructions or mixed kinds per owner:** v1 stores one optional instruction; the
  model would need a list and a composition decision.
- **Transcoding, cloud upload, transcription, AI processing of instruction media:** out of scope
  by NFR-RIE-003; nothing in the design forecloses it, but nothing implements it.
- **Android (v2):** not a surface in this repo.
- **A standalone media gallery or top-level tab:** explicitly out of scope; instructions live in
  the existing routine sheet and event form/detail.
- **A UI test:** not required (OD-7); the seam, simulator failure tests and one recorded Release-
  build device smoke are the agreed evidence.
