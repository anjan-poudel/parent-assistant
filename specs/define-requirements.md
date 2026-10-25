# Requirements — Reminders Instructions Enhancements (feature)

Feature: `reminders-instructions-enhancements` (branch `feat/reminders-instructions-enhancements`,
worktree `elderly-ai-assistant-reminders-instructions-enhancements`; scaffold base master
`821f19c5`).
Task: `define-requirements`, agent `ba`, contracts `requirements_doc` + `requirements_lock`.
Date: 2026-10-25.
Source mandate: the owner's scaffold brief and the normative feature supplement
[`specs/reminders-instructions-enhancements/constitution.md`](reminders-instructions-enhancements/constitution.md),
whose "Decisions" section records **OD-1 … OD-8 as RESOLVED by the owner on 2026-10-25**. The
root stakeholder brief is [`requirements.md`](../requirements.md) (read-only); the dementia
supplement §1.9 (`FR-D26`–`FR-D29`, caregiver-configured routine guidance) is context, never
renumbered. The locked snapshot is
[`define-requirements.lock.yaml`](define-requirements.lock.yaml).

This document is the flat, human-readable copy of the structured set under
[`define-requirements/`](define-requirements/index.md). The per-requirement files are the source
of truth; the lock hashes them.

## Summary

- Functional requirements: **25** (`FR-RIE-001` … `FR-RIE-025`), all MUST.
- Non-functional requirements: **10** (`NFR-RIE-001` … `NFR-RIE-010`), all MUST.
- Gherkin acceptance scenarios: **107** (80 FR, 27 NFR).
- Feature purpose: a caregiver can attach an instruction — written text, an image, or a video — to
  a daily-routine reminder or an app-created free-form event, and when it fires the elderly user
  can follow the instruction in the app unaided (OD-8 success criterion).
- Scope boundary: routines and app-created free-form events only. Medication reminders, imported
  calendar events, Android, cloud processing, voice/TTS narration, audio-only instructions and
  YouTube links are out of scope.
- Safety delta: **none**. Routines and free-form events carry no acknowledgement, escalation or
  re-fire machinery; medication paths are untouched.

## Contents

- [define-requirements/index.md](define-requirements/index.md) — structured index (this feature's
  set only)
- [define-requirements/FR/index.md](define-requirements/FR/index.md) — 25 functional requirements
- [define-requirements/NFR/index.md](define-requirements/NFR/index.md) — 10 non-functional
  requirements
- [define-requirements.lock.yaml](define-requirements.lock.yaml) — locked snapshot with
  per-requirement sha256 hashes
- The `FR/` and `NFR/` folders also hold earlier features' files, left untouched; this set and the
  lock cover only `FR-RIE-*` / `NFR-RIE-*`.

## Functional requirements

### FR-RIE-001: Instruction model — one instruction of a single kind on routines and free-form events

**Area:** Instruction Model · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-001-instruction-model-three-kinds.md](define-requirements/FR/FR-RIE-001-instruction-model-three-kinds.md)

Both `RoutineEntry` and `EventExtras` can carry one optional instruction whose kind is text, image
or video. The model stores only a kind and a bare file name/identifier — never bytes, never a path.
Text lives in the encrypted payload, images use the existing photo-aid path, video uses the new
app-managed store. A media-only owner is as valid as a photo-only one. Existing photo aids remain
and can coexist with a video instruction (OD-4). Scenarios cover a routine video instruction, an
event text instruction, and a media-only routine that is still valid.

### FR-RIE-002: Text instruction — written steps stored as text and readable at fire time

**Area:** Text Instruction · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-002-text-instruction.md](define-requirements/FR/FR-RIE-002-text-instruction.md)

A caregiver can attach the written steps to a routine reminder or event. The text is stored in the
encrypted payload, never as a file, and renders at fire time at the user's reading size and
direction. A text instruction has no separate caption. Whitespace-only text is not an instruction
and must not create an empty instruction block. Scenarios cover routine text, event text, and the
whitespace edge.

### FR-RIE-003: Image instruction — photo or diagram shown through the existing photo-aid path

**Area:** Image Instruction · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-003-image-instruction.md](define-requirements/FR/FR-RIE-003-image-instruction.md)

An image instruction follows the existing photo-aid pattern: a bare filename in the encrypted
payload and bytes in the existing app-managed photo store; no parallel image store. At fire time it
renders like today's photo aids with its optional caption. Existing photo-aid limits and paging
remain; a video instruction can coexist. Scenarios cover routine and event image instructions.

### FR-RIE-004: Pick an existing video from the library — first-class, permission-free source

**Area:** Video Capture · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-004-library-video-pick.md](define-requirements/FR/FR-RIE-004-library-video-pick.md)

The caregiver can choose a library video through the out-of-process photo picker, which needs no
photo-library permission. The chosen video is imported into the app-managed instruction store as
app data; it is never referenced in place, re-saved to Photos, or listed as an app asset. Library
pick remains fully functional when the camera or microphone is denied. Scenarios cover import plus
payload hygiene, and the camera-denied edge.

### FR-RIE-005: Record a video in the app — system camera UI, ships in v1

**Area:** Video Capture · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-005-in-app-video-recording.md](define-requirements/FR/FR-RIE-005-in-app-video-recording.md)

In-app recording ships in v1 (OD-2) using the system camera UI. The recording is app data: stored
locally, never uploaded, transcribed, or saved to Photos. Camera and microphone are requested at
the point of use with plain disclosure (FR-RIE-025). Cancelling the camera changes nothing and is
not an error. Scenarios cover record-and-save and cancel.

### FR-RIE-006: Video acceptance limits — 3 minutes, ~200 MB, as provided, unsupported codecs rejected at pick time

**Area:** Video Constraints · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-006-video-acceptance-limits.md](define-requirements/FR/FR-RIE-006-video-acceptance-limits.md)

Accepted video is at most 3 minutes (180 s) and at most ~200 MB (encoded for verification as a
hard 200 MiB bound), stored as provided with no transcode or conversion. An unsupported codec or
container is rejected at pick time with a short plain-language message, never a raw error or
codec name, and the previous instruction stays intact. Scenarios cover accepted unchanged,
over-duration, over-size, and unsupported-codec rejection.

### FR-RIE-007: Optional caption for image and video — shown with the instruction, blank reserves no space

**Area:** Captions · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-007-optional-caption.md](define-requirements/FR/FR-RIE-007-optional-caption.md)

Image and video instructions can carry an optional caregiver caption shown at the user's reading
size and direction. A blank or whitespace-only caption reserves no space (the
`VisualAidDisplayState.currentCaption` rule). A text instruction has no separate caption. Scenarios
cover a shown caption, the whitespace edge, and the no-caption-field rule for text.

### FR-RIE-008: One instruction belongs to the entry — every firing, edits apply without re-creation

**Area:** Instruction Lifetime · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-008-instruction-lifetime-and-edits.md](define-requirements/FR/FR-RIE-008-instruction-lifetime-and-edits.md)

The instruction belongs to the entry/event, not an occurrence. The same instruction is offered at
every firing; editing it takes effect for future firings without re-creating the owner or changing
its schedule. Routine edits follow the existing `setVisualAids` → `persistAndReschedule` path. A
video-only owner is valid. Scenarios cover edit-without-re-creation, same-instruction-every-firing,
and the video-only owner.

### FR-RIE-009: Instruction management stays in the existing caregiver surfaces — no standalone media screen

**Area:** Caregiver Editing · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-009-existing-caregiver-edit-surfaces.md](define-requirements/FR/FR-RIE-009-existing-caregiver-edit-surfaces.md)

Routine instructions are managed from the routine's existing manage sheet in `RoutineSettingsView`;
event instructions from the existing free-form event form/detail in `EventsView`. No new standalone
media-library screen or tab is introduced. Scenarios cover both surfaces and the absence of a
separate gallery.

### FR-RIE-010: Plain visible feedback — choose, record, save, replace, remove; cancellation and failure never silent

**Area:** Caregiver Editing · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-010-plain-feedback-and-safe-failure.md](define-requirements/FR/FR-RIE-010-plain-feedback-and-safe-failure.md)

Every instruction action produces a clear plain-language state. Cancellation is an outcome, not an
error, and changes nothing. A failed save keeps the draft or previous instruction and says plainly
that it did not save — never a silent no-op, silent success or raw error. Scenarios cover success,
cancellation, save failure and removal.

### FR-RIE-011: Video store — dedicated Application Support roots, bare filenames, complete file protection

**Area:** Storage · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-011-video-storage-layout-and-protection.md](define-requirements/FR/FR-RIE-011-video-storage-layout-and-protection.md)

Routine video lives under `Application Support/InstructionVideos/<entryId>/`; free-form event video
under a separate event root (exact name design-level). The two roots are not mixed with
`VisualAids`/`EventPhotos`. Encrypted payloads store bare filenames only. Every file is written with
`.completeFileProtection`, is never saved to Photos, never appears in the picker, and is never
shared. Format is stored as provided. Scenarios cover routine layout, event layout and protection
plus non-exposure.

### FR-RIE-012: Filename hygiene — plain names only; a hand-edited payload cannot escape the store root

**Area:** Storage Hardening · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-012-filename-hygiene-traversal-guard.md](define-requirements/FR/FR-RIE-012-filename-hygiene-traversal-guard.md)

Only plain, traversal-free filenames are accepted, persisted and resolved, matching the
`VisualAidStore.isPlainFilename` discipline. A payload with `../`, a path separator or an absolute
path fails safe: no read outside the store root, the instruction is treated as missing, the plain
fallback shows, and the rejection is logged PII-free. Scenarios cover traversal, a normal filename,
and an absolute path.

### FR-RIE-013: Transactional replace — write the new video before the index points at it

**Area:** Storage Lifecycle · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-013-transactional-replace.md](define-requirements/FR/FR-RIE-013-transactional-replace.md)

Replacement writes the new file before the encrypted index points at it and deletes the old file
only after the index update succeeds (the `FreeFormEventService.setPhoto` precedent). A failed
write or index update leaves the previous instruction intact and reports plainly, with no partially
written file referenced or orphaned. Scenarios cover success and both failure directions.

### FR-RIE-014: Delete with the owner — routine deletion, event deletion and reconcile leave no orphan video

**Area:** Storage Lifecycle · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-014-delete-with-owner.md](define-requirements/FR/FR-RIE-014-delete-with-owner.md)

Deleting a routine deletes its whole instruction folder; deleting an event or dropping a vanished
event in reconcile deletes its video file with the extras row; removing only the instruction keeps
the owner, schedule and other media. No orphan video remains in any case. Scenarios cover routine
delete, event delete, reconcile, and instruction-only removal.

### FR-RIE-015: The reminder always fires — instruction media never blocks, delays or mutes it

**Area:** Fire-Time Reliability · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-015-reminder-always-fires.md](define-requirements/FR/FR-RIE-015-reminder-always-fires.md)

The reminder/event fires at its scheduled time with or without an instruction. A missing, corrupt,
unsupported, still-loading, deleted or unreadable instruction never blocks, delays or mutes
delivery; presentation is a side effect and degrades to the reminder plus a plain fallback.
Scenarios cover missing, corrupt, still-loading and text/image load failures.

### FR-RIE-016: Presentation handlers always return false — notification outcomes unchanged

**Area:** Notification Discipline · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-016-presentation-handlers-always-false.md](define-requirements/FR/FR-RIE-016-presentation-handlers-always-false.md)

Any instruction presentation handler always returns `false` from `willPresent` and does not change
banner/list/sound, read-aloud, caregiver handlers or the medication path. `NotificationFacade`
keeps completing `[.banner, .list, .sound]` and consulting handlers as today. `didReceive` routes
the tap path without claiming presentation. Scenarios cover routine, event, and the untouched
medication path.

### FR-RIE-017: Fired screen composition — reminder content plus instruction content per kind

**Area:** Fire-Time Presentation · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-017-fire-time-composition.md](define-requirements/FR/FR-RIE-017-fire-time-composition.md)

With an instruction, the fired screen shows the reminder/event content plus the instruction for its
kind: readable text, the existing photo-aid rendering, or a large Play affordance for video. A
media-only owner presents and is not suppressed by the photo-only gate. Photos and video coexist
(order design-level). No instruction keeps today's behaviour exactly. Scenarios cover video plus
photos, video-only, text-only and no-instruction.

### FR-RIE-018: Playback UX — explicit large Play opens full-screen AVKit; no sound before a user action

**Area:** Playback UX · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-018-playback-ux-no-autoplay.md](define-requirements/FR/FR-RIE-018-playback-ux-no-autoplay.md)

A large Play control opens full-screen AVKit `VideoPlayer`. Sound never starts because a reminder
appeared: no autoplay, audio only after the explicit Play tap; pause/close stops audio. No "Watch
video" notification action is added (OD-6). Scenarios cover no-sound-before-action, Play opens
playback, no extra notification action, and close/pause.

### FR-RIE-019: Tap/Open path in v1 — reach the instruction after unlock; no background video claim

**Area:** Fire-Time Access · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-019-tap-open-path-foreground-honest.md](define-requirements/FR/FR-RIE-019-tap-open-path-foreground-honest.md)

v1 implements the routine tap/Open path so a banner tap or Open action opens the reminder with the
instruction playable after unlock; the existing event tap/Open path does the same for the event
detail. Foreground remains the honest baseline: no background or killed-at-fire video claim, and
the limitation is stated honestly. If content cannot resolve, the plain fallback shows. Scenarios
cover routine banner, routine Open, event tap/Open, and the no-background-claim edge.

### FR-RIE-020: Playback failure — plain localized message, reminder stays, always dismissible, PII-free log

**Area:** Failure Handling · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-020-playback-failure-plain-fallback.md](define-requirements/FR/FR-RIE-020-playback-failure-plain-fallback.md)

A missing, corrupt, unsupported, deleted or unplayable video shows a short localized plain message
while the reminder/event title and time remain; the screen is always dismissible. Never a blank
screen, endless spinner, raw error or error code. The failure log carries event type and outcome
only. Scenarios cover missing at Play, corrupt, PII-free logging, and no-endless-spinner.

### FR-RIE-021: Notification taxonomy preserved — full-REPLACE builder, scoped cancels only

**Area:** Notification Discipline · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-021-notification-taxonomy-preserved.md](define-requirements/FR/FR-RIE-021-notification-taxonomy-preserved.md)

`NotificationCategories` remains the single full-REPLACE builder; any addition goes through it
without dropping existing categories/actions. Routine/event cancels remain scoped by identifier;
`removeAllPendingNotificationRequests` is never used. No instruction-specific category or action is
added. Scenarios cover full-set preservation, scoped cancel, and no new instruction action.

### FR-RIE-022: Instruction video never enters the notification attachment store

**Area:** Notification Discipline · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-022-video-not-in-notification-attachments.md](define-requirements/FR/FR-RIE-022-video-not-in-notification-attachments.md)

Video bytes are never handed to `UNNotificationAttachment` or copied per occurrence/re-arm. The
notification remains today's text banner plus the existing first-photo attachment; the throwaway
photo-copy path is not applied to video. Scenarios cover scheduling, re-arm and the event edge.

### FR-RIE-023: No new acknowledgement, escalation, re-fire or missed-event machinery

**Area:** Preserved Behaviour · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-023-no-new-ack-escalation-machinery.md](define-requirements/FR/FR-RIE-023-no-new-ack-escalation-machinery.md)

Routines and free-form events remain non-safety-critical (`RoutineEntry.swift:77–80`). An
instruction-bearing item fires once, as today; ignoring it does not re-fire, alert a caregiver or
produce a missed-event verdict. Medication machinery stays separate and untouched. Scenarios cover
routine, event, and the medication edge.

### FR-RIE-024: Honest capability surface — YouTube link not shipped, no fake control, room left for a later link kind

**Area:** Honesty / Capability Surface · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-024-honest-capability-surface.md](define-requirements/FR/FR-RIE-024-honest-capability-surface.md)

YouTube links are not shipped in v1: no link control, URL field or fake affordance. The model
leaves room for a later `link` kind (URL as a string, not bytes) without foreclosing it, and an
unknown/future kind decodes tolerantly with no fake control. Background/cold-launch video playback
is not claimed. Scenarios cover no link control, honest unknown-kind degradation, and no background
claim.

### FR-RIE-025: Camera and microphone at point of use — plain disclosure, denial non-blocking

**Area:** Capture Permissions · **Priority:** MUST ·
**File:** [define-requirements/FR/FR-RIE-025-camera-microphone-permissions.md](define-requirements/FR/FR-RIE-025-camera-microphone-permissions.md)

Camera and microphone are requested at the first record attempt with plain-language purpose,
including that video recordings stay on the device. `NSCameraUsageDescription` and
`NSMicrophoneUsageDescription` are amended while retaining existing disclosures. Denial of either
is non-blocking: recording is unavailable with a plain explanation, library pick and the reminder
keep working, and there is no crash or prompt loop. Scenarios cover first record, camera denial,
microphone denial, and the plist disclosure.

## Non-functional requirements

### NFR-RIE-001: Accessibility — 44pt targets, 18pt body, VoiceOver, dynamic type, no fine-motor or swipe-only controls

**Category:** Accessibility · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-001-accessibility-elderly-fit.md](define-requirements/NFR/NFR-RIE-001-accessibility-elderly-fit.md)

New controls are ≥44×44 pt; body text is ≥18 pt; captions/titles support Dynamic Type through the
accessibility sizes without clipping Play/Close; every video, caption and transport action has a
VoiceOver label; no fine-motor or swipe-only interaction is added; Play and Close are reachable
one-handed; high contrast binds. Measurable: 100% of new controls ≥44×44 and labelled, 0
gesture-only actions. Scenarios cover largest text size, VoiceOver, and motor accessibility.

### NFR-RIE-002: Localisation — every new string in English and Nepali; no hardcoded user-visible text

**Category:** Localisation · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-002-localisation-en-ne.md](define-requirements/NFR/NFR-RIE-002-localisation-en-ne.md)

All new strings live in `Localizable.xcstrings` with en and ne; 100% key parity, 0 missing or
English fallbacks in Nepali, 0 hardcoded user-visible literals in new code, and spoken times only
via `SpokenTime`. Scenarios cover language switching and a static parity audit.

### NFR-RIE-003: No new network egress — instruction media never leaves the device

**Category:** Privacy · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-003-no-new-egress.md](define-requirements/NFR/NFR-RIE-003-no-new-egress.md)

Instruction media is never uploaded, transcribed or AI-processed; capture, storage, replace/delete
and playback use local APIs only. Measurable: 0 outbound requests attributable to instruction paths
under instrumentation; 0 upload/transcription call sites under static scan. Scenarios cover
instrumented play/save and the static scan.

### NFR-RIE-004: PII-free observability — event type + outcome only; release log gate green

**Category:** Privacy / Security · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-004-pii-free-logging-and-release-gate.md](define-requirements/NFR/NFR-RIE-004-pii-free-logging-and-release-gate.md)

New logs carry event type and outcome only — no titles, captions, filenames, paths, entry IDs in
clear, video content, or raw errors. `ios/tools/check-release-log-safety.sh` exits 0 and covers the
new paths. Measurable: 0 content-bearing log statements; gate exit 0. Scenarios cover the failure
log and the release gate.

### NFR-RIE-005: At-rest protection — complete file protection on every instruction video; no Photos/share exposure

**Category:** Security · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-005-at-rest-file-protection.md](define-requirements/NFR/NFR-RIE-005-at-rest-file-protection.md)

Every video file uses `.completeFileProtection`, lives in Application Support instruction roots
(not Documents, Photos or a shared container), is absent from Photos and share surfaces, and is
removed on deletion. Measurable: 100% protected files, 0 Photos/shared copies, 0 files after
delete. Scenarios cover attributes, non-exposure and deletion.

### NFR-RIE-006: Migration compatibility — pre-feature payloads load; unknown kinds degrade honestly

**Category:** Reliability / Compatibility · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-006-migration-compatibility.md](define-requirements/NFR/NFR-RIE-006-migration-compatibility.md)

New fields are optional with custom-decoder defaults. 100% of pre-feature `RoutineEntry` and
`EventExtras` fixtures decode unchanged; 0 reminder-list or event-index losses; an unknown future
kind decodes without throwing and shows no fake control; no forced rewrites. Scenarios cover both
payload types and the unknown-kind edge.

### NFR-RIE-007: Storage footprint — one video per owner, ≤200 MiB, zero orphans after replace/delete

**Category:** Storage / Reliability · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-007-storage-footprint-and-orphans.md](define-requirements/NFR/NFR-RIE-007-storage-footprint-and-orphans.md)

At most one video file per owner, each within the 200 MiB cap; replace/delete/reconcile leave zero
orphans; re-arm or unrelated edits create no per-occurrence copy. Measurable: exactly 1 file after
N replacements; 0 files after delete; unchanged count after re-arm. Scenarios cover all three.

### NFR-RIE-008: Playback responsiveness — player within 500 ms, first frame within 2 s, fallback within 1 s

**Category:** Performance · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-008-playback-responsiveness.md](define-requirements/NFR/NFR-RIE-008-playback-responsiveness.md)

On the reference device, Play presents the full-screen player within 500 ms and starts playback
within 2 s for a compliant local video; any failure resolves to the plain fallback within 1 s with
no unbounded spinner. These are BA-set acceptance bounds for the device smoke and simulator
failure tests. Scenarios cover the compliant path and the failure path.

### NFR-RIE-009: Testability and gate — injectable playback seam, scripted failure paths, one device smoke

**Category:** Quality / Reliability · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-009-playback-seam-and-test-gates.md](define-requirements/NFR/NFR-RIE-009-playback-seam-and-test-gates.md)

Playback sits behind a thin injectable seam in the `CameraCapturePresenting` style so unit tests
script play, pause, failure and missing-file outcomes without a real player. Simulator tests cover
every failure path; one real-device smoke check verifies rendering and audio; no UI test required.
The named existing suites are extended, focused suites green, typecheck/build clean, full-suite
baseline unchanged. Measurable: 100% suites pass, ≥4 scripted outcomes, ≥1 recorded smoke, 0 new
baseline failures. Scenarios cover the seam, the device smoke, and simulator failure coverage.

### NFR-RIE-010: Preserved baseline and release gates — medication paths, notification outcomes and no-instruction UI unchanged

**Category:** Compliance / Reliability · **Priority:** MUST ·
**File:** [define-requirements/NFR/NFR-RIE-010-preserved-baseline-and-release-gates.md](define-requirements/NFR/NFR-RIE-010-preserved-baseline-and-release-gates.md)

No change to medication paths, notification banner/list/sound, read-aloud or caregiver alerts; a
no-instruction item is byte-for-byte today's behaviour; the full-REPLACE category set is
regression-tested; release gates (log script, build/typecheck, localisation, accessibility) pass and
the safety delta remains none. Measurable: 0 no-instruction snapshot diffs, 100% categories/actions
preserved, medication suite green with 0 medication source changes, log gate exit 0. Scenarios
cover the snapshot, taxonomy, medication suite and log gate.

## Resolved decisions carried as requirements

| # | Resolution (owner, 2026-10-25) | Requirements |
|---|---|---|
| OD-1 | Text, image and video are all in scope; one instruction per reminder/event of any single kind; video caps 3 minutes / ~200 MB, stored as provided (no transcode); unsupported codec rejected at pick time with a plain message; audio-only out | FR-RIE-001, FR-RIE-002, FR-RIE-003, FR-RIE-006 |
| OD-2 | In-app recording ships in v1 using the system camera UI; point-of-use camera + microphone prompts; `Info.plist` amended; denial leaves library pick and the reminder fully working | FR-RIE-005, FR-RIE-025 |
| OD-3 | YouTube links not shipped in v1; model leaves room for a later `link` kind (URL stored, not bytes); no fake control | FR-RIE-024 (+ FR-RIE-001 model) |
| OD-4 | Fired screen shows reminder text plus instruction content per kind; large Play opens full-screen AVKit; no sound before an explicit action; photos plus video coexist; order TBD by design | FR-RIE-017, FR-RIE-018, FR-RIE-007 |
| OD-5 | Dedicated `Application Support/InstructionVideos/<entryId>/` for routines and a separate event root; bare filenames in encrypted payloads; `.completeFileProtection`; receive-as-is | FR-RIE-011, FR-RIE-006, NFR-RIE-005 |
| OD-6 | v1 keeps foreground presentation; the routine tap/Open path is in v1 scope; no background video claim; no extra "Watch video" action button | FR-RIE-018, FR-RIE-019, FR-RIE-024 |
| OD-7 | Thin injectable playback seam; simulator covers every failure path; one real-device smoke check; no UI test required | FR-RIE-020, NFR-RIE-009 |
| OD-8 | Success = caregiver attaches an instruction (text, image or video) to a routine reminder or free-form event, and the elderly user can follow it unaided when it fires | FR-RIE-009, FR-RIE-010, FR-RIE-017 … FR-RIE-020 |

## Traceability summary

| Constitution contract / success criterion | Requirements |
|---|---|
| Feature purpose: instructions on daily-routine reminders and app-created free-form events | FR-RIE-001, FR-RIE-002, FR-RIE-003, FR-RIE-009 |
| Local video as the primary path; library pick and in-app recording both first-class | FR-RIE-004, FR-RIE-005, FR-RIE-025 |
| Instruction Model & Storage Contract properties 1–7 | FR-RIE-001, FR-RIE-008, FR-RIE-011, FR-RIE-012, FR-RIE-013, FR-RIE-014, FR-RIE-022, NFR-RIE-005, NFR-RIE-006, NFR-RIE-007 |
| Capture & Permissions Contract properties 1–6 | FR-RIE-004, FR-RIE-005, FR-RIE-007, FR-RIE-009, FR-RIE-010, FR-RIE-025, NFR-RIE-002 |
| Fire-Time Playback, Accessibility & Failure Contract properties 1–7 | FR-RIE-015, FR-RIE-016, FR-RIE-017, FR-RIE-018, FR-RIE-019, FR-RIE-020, FR-RIE-021, NFR-RIE-001, NFR-RIE-008 |
| Success criterion 1 — caregiver can attach, replace and remove; media-only presents | FR-RIE-001, FR-RIE-008, FR-RIE-009, FR-RIE-010, FR-RIE-013, FR-RIE-014, FR-RIE-017 |
| Success criterion 2 — elder follows unaided; large controls; user-initiated audio | FR-RIE-017, FR-RIE-018, FR-RIE-019, NFR-RIE-001 |
| Success criterion 3 — missing/corrupt/unplayable fallback; PII-free log | FR-RIE-015, FR-RIE-020, NFR-RIE-004 |
| Success criterion 4 — storage/privacy: file protection, absent from Photos, deleted with owner, never in logs | FR-RIE-011, FR-RIE-012, FR-RIE-014, FR-RIE-022, NFR-RIE-003, NFR-RIE-004, NFR-RIE-005 |
| Success criterion 5 — no change to medication, notification outcomes, read-aloud, caregiver alerts | FR-RIE-016, FR-RIE-021, FR-RIE-023, NFR-RIE-010 |
| Success criterion 6 — migration: pre-feature payloads load unchanged | NFR-RIE-006 |
| Success criterion 7 — scoped suites green, typecheck/build clean, real-device playback smoke | NFR-RIE-008, NFR-RIE-009, NFR-RIE-010 |
| Safety & Compliance Delta — fail-safe degradation, on-device only, privacy of home video, permissions, no silent stubs | FR-RIE-015, FR-RIE-020, FR-RIE-024, FR-RIE-025, NFR-RIE-003, NFR-RIE-004, NFR-RIE-005 |
| Root brief FR-024 / FR-025 (general reminders; schedules persist) — context, never renumbered | FR-RIE-001, FR-RIE-008, FR-RIE-023 |
| Dementia supplement §1.9 FR-D26–D29 (caregiver-configured routine guidance) — broader context this feature begins to serve | FR-RIE-001, FR-RIE-002, FR-RIE-003, FR-RIE-009 (context only; no renumbering) |

## Out of scope

- **Medication reminders** — no instruction surface is added and no medication code path is altered
  (FR-RIE-023, NFR-RIE-010).
- **Imported / Google / other-calendar events** — only app-created free-form events tracked by
  `EventExtrasStore` are in scope.
- **Any new acknowledgement, escalation, re-fire or missed-event machinery** — routines and
  free-form events stay explicitly non-safety-critical (FR-RIE-023).
- **Voice/TTS narration, transcript generation, and voice authoring of instructions** — not in the
  brief.
- **Audio-only instructions** — not required and not a supported kind.
- **Android (v2), cloud upload, transcoding, or AI processing of instruction video** — excluded
  (NFR-RIE-003).
- **YouTube links as a shipped v1 path** — not shipped; only a forward-compatible model slot is
  reserved, with no UI control (FR-RIE-024).
- **Multiple instructions per reminder/event, or mixed designated instruction kinds** — v1 supports
  one designated instruction of a single kind; existing photo aids remain and can coexist with a
  video instruction (OD-4).
- **A new standalone media-library screen or top-level tab** — instructions live in the existing
  caregiver surfaces (FR-RIE-009).
- **Background or killed-at-fire video playback claims** — foreground is the honest baseline; the
  tap/Open path is the v1 route (FR-RIE-019, FR-RIE-024).
- **A UI test requirement** — none is required (OD-7, NFR-RIE-009).
- **Any new safety-critical surface, alert, delivery guarantee, or biometric/PIN gate** — safety
  delta none.
- **Changes to existing photo-aid behaviour, notification taxonomy, read-aloud, caregiver alerts,
  or the medication path** — preserved (FR-RIE-016, FR-RIE-021, NFR-RIE-010).
- **Ordering/layout of the fired screen and the exact event instruction root name** — design-level
  (design-l1/l2), bounded by FR-RIE-011/FR-RIE-017/FR-RIE-018.

## Open decisions and design-level boundaries

**No owner-level decision is open.** OD-1 … OD-8 are RESOLVED in the feature constitution
(2026-10-25) and are carried as settled requirements above. The following are design-chain choices
inside the contracts this set fixes — not scope questions:

| Design item | Bounded by |
|---|---|
| Exact event instruction root name and directory layout | FR-RIE-011 (separate root, not mixed), NFR-RIE-005/007 |
| Concrete system-camera component (`UIImagePickerController` vs AVFoundation flow) | FR-RIE-005 (system camera UI), FR-RIE-025 (point-of-use prompts) |
| Fired-screen ordering/layout of photos versus the video Play affordance | FR-RIE-017 (composition per kind), FR-RIE-018 (explicit Play), OD-4 (order TBD) |
| Caption typography and maximum length | FR-RIE-007 (optional, shown, blank reserves no space), NFR-RIE-001 (dynamic type) |
| Playback seam protocol shape | NFR-RIE-009 (scriptable outcomes, `CameraCapturePresenting` style), OD-7 |
| Whether any instruction-kind discriminator is an enum or a string-backed value | FR-RIE-001, FR-RIE-024 and NFR-RIE-006 (unknown kinds must decode tolerantly) |

## Gate traceability

| Gate | What this set requires |
|---|---|
| `define-requirements` | This document and the structured set under `define-requirements/`; locked by `define-requirements.lock.yaml` (25 FR, 10 NFR, 107 scenarios). |
| `design-l1` / `review-l1` | Design must satisfy every FR/NFR here without reopening OD-1 … OD-8; design-level items are listed above and bounded. |
| `design-l2` / `review-l2` | Interfaces for the store, the instruction model, the playback seam and the edit surfaces must make the failure/edge scenarios testable (NFR-RIE-009). |
| `plan-tasks` | Task breakdown must cover both surfaces, all three kinds, capture/recording, storage/lifecycle, migration, fire-time presentation and playback, notifications, permissions, localisation, accessibility and the test gates. |
| `implement` | Work in the dedicated worktree only; no medication-path changes; no new egress; no silent stubs. |
| `review-implementation` | Verify the failure paths (missing/corrupt/unsupported/traversal/replace failure), the PII-free log gate, and the preserved no-instruction baseline. |
| `final-sign-off` | Real-device playback smoke check (rendering + audio after an explicit Play tap; one check per NFR-RIE-009/OD-7); `ios/tools/check-release-log-safety.sh` exits 0; `./build.sh` canonical and `xcodebuild test` for scoped suites; focused suites green and full-suite baseline unchanged; OD-8 success criterion demonstrated. No UI test required. |

## Assumptions recorded during this requirements pass

- The feature constitution's verified ground truth and Integration Surfaces are taken as given for
  this pass (verified against master `821f19c5`, 2026-10-25); file/line anchors are orientation, not
  contracts, and no capability claim in this set goes beyond the verified statements or the
  read-only source documents.
- **"~200 MB"** (owner language, OD-1) is encoded as a hard verification bound of **200 MiB =
  209,715,200 bytes**. The 3-minute cap is 180 seconds. No transcode is permitted.
- **"One instruction per reminder/event in v1, of any single kind"** is interpreted as one
  *designated* instruction with exactly one kind (text, image or video). Existing photo aids are not
  removed or capped by this feature, and OD-4 explicitly allows photos plus a video to coexist;
  multiple designated instructions or mixed designated kinds are out of scope. How the fired screen
  orders photos against the video affordance is design-level.
- The **exact event instruction root name** is design-level. The requirement binds only that it is a
  separate root from `InstructionVideos`, `VisualAids` and `EventPhotos`.
- **"Unsupported codec"** means a file AVKit/AVFoundation cannot play on the supported iOS
  deployment target; rejection happens at pick time before the file is copied into the store.
- **Playback latency targets** (500 ms player presentation, 2 s first frame, 1 s failure fallback)
  are BA-set acceptance bounds created by this pass for the real-device smoke check and simulator
  failure tests. They are not pre-existing project numbers and add no project-wide performance
  claim. The reference device is the project's "Anzaan" device used by earlier feature validation.
- **Foreground-only honesty**: v1 implements the notification tap/Open path to the reminder/event
  with the instruction playable after unlock, and claims no background or killed-at-fire video
  playback. Any cold-launch nuance beyond that tap path is bounded by OD-6 and FR-RIE-019.
- **The model's future `link` kind** is not shipped. The requirement is only that adding it later is
  not foreclosed (URL stored as a string, not bytes) and that an unknown kind today decodes
  tolerantly without a fake control.
- **Existing full-suite test baseline**: the project's known pre-existing full-bundle failures remain
  the recorded baseline; this feature's own and touched suites are the honest gate (NFR-RIE-009,
  NFR-RIE-010).
- **Artifact ownership**: this pass overwrites the shared `specs/define-requirements/index.md`,
  `specs/define-requirements.md` and `specs/define-requirements.lock.yaml` with the
  `reminders-instructions-enhancements` set, following the established per-feature convention.
  Earlier features' requirement files under `FR/` and `NFR/` are untouched and are not part of this
  lock.
- **Approval basis**: the feature constitution records OD-1 … OD-8 as resolved by the owner on
  2026-10-25. No separate HIL gate identifier is fabricated in this document; the coordinator owns
  task state and gates.

## Related

- Structured set: [`define-requirements/index.md`](define-requirements/index.md) ·
  [`define-requirements/FR/index.md`](define-requirements/FR/index.md) ·
  [`define-requirements/NFR/index.md`](define-requirements/NFR/index.md)
- Locked snapshot: [`define-requirements.lock.yaml`](define-requirements.lock.yaml)
- Feature constitution (source mandate):
  [`specs/reminders-instructions-enhancements/constitution.md`](reminders-instructions-enhancements/constitution.md)
- Project constitution: [`constitution.md`](../constitution.md)
- Read-only inputs: [`requirements.md`](../requirements.md) (`FR-024`, `FR-025`),
  [`requirements-dementia-supplement.md`](../requirements-dementia-supplement.md) (`FR-D26`–`FR-D29`),
  [`feature-requests.md`](../feature-requests.md)
- Existing code surfaces named by the constitution: `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift`,
  `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift`,
  `ios/ElderlyAssistant/Services/Reminders/VisualAidDisplayState.swift`,
  `ios/ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift`,
  `ios/ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift`,
  `ios/ElderlyAssistant/Services/Reminders/RoutineScheduler.swift`,
  `ios/ElderlyAssistant/App/RoutineSettingsView.swift`,
  `ios/ElderlyAssistant/App/VisualAidViews.swift`,
  `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift`,
  `ios/ElderlyAssistant/Services/Notifications/FreeFormEventFireHandler.swift`,
  `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift`,
  `ios/ElderlyAssistant/App/EventsView.swift`
