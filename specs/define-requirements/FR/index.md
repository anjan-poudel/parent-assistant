# Functional Requirements — Reminders Instructions Enhancements

25 functional requirements. IDs are namespaced `FR-RIE-NNN` to avoid colliding with the
project-level `FR-NNN` set in the root stakeholder brief (`requirements.md`) — the same convention
the earlier features used (`FR-MSR-NNN`, `FR-CNR-NNN`, `FR-CDP-NNN`, `FR-FCU-NNN`, `FR-LCT-NNN`,
`FR-MTC-NNN`, `FR-PI-NNN`, `FR-SP-NNN`). This page covers the
`reminders-instructions-enhancements` set (`FR-RIE-*`) only; the earlier feature files remain in
this folder and are not part of this feature's requirements or lock.

The feature constitution (`specs/reminders-instructions-enhancements/constitution.md`) is the
normative source; OD-1 … OD-8 were RESOLVED by the owner on 2026-10-25. All 25 requirements are
MUST — the scope is a fixed v1 contract, not a polish tier.

| ID | Title | Area | Priority |
|----|-------|------|----------|
| [FR-RIE-001](FR-RIE-001-instruction-model-three-kinds.md) | Instruction model — one instruction of a single kind on routines and free-form events | Instruction Model | MUST |
| [FR-RIE-002](FR-RIE-002-text-instruction.md) | Text instruction — written steps stored as text and readable at fire time | Text Instruction | MUST |
| [FR-RIE-003](FR-RIE-003-image-instruction.md) | Image instruction — photo or diagram shown through the existing photo-aid path | Image Instruction | MUST |
| [FR-RIE-004](FR-RIE-004-library-video-pick.md) | Pick an existing video from the library — first-class, permission-free source | Video Capture | MUST |
| [FR-RIE-005](FR-RIE-005-in-app-video-recording.md) | Record a video in the app — system camera UI, ships in v1 | Video Capture | MUST |
| [FR-RIE-006](FR-RIE-006-video-acceptance-limits.md) | Video acceptance limits — 3 minutes, ~200 MB, as provided, unsupported codecs rejected at pick time | Video Constraints | MUST |
| [FR-RIE-007](FR-RIE-007-optional-caption.md) | Optional caption for image and video — shown with the instruction, blank reserves no space | Captions | MUST |
| [FR-RIE-008](FR-RIE-008-instruction-lifetime-and-edits.md) | One instruction belongs to the entry — every firing, edits apply without re-creation | Instruction Lifetime | MUST |
| [FR-RIE-009](FR-RIE-009-existing-caregiver-edit-surfaces.md) | Instruction management stays in the existing caregiver surfaces — no standalone media screen | Caregiver Editing | MUST |
| [FR-RIE-010](FR-RIE-010-plain-feedback-and-safe-failure.md) | Plain visible feedback — choose, record, save, replace, remove; cancellation and failure never silent | Caregiver Editing | MUST |
| [FR-RIE-011](FR-RIE-011-video-storage-layout-and-protection.md) | Video store — dedicated Application Support roots, bare filenames, complete file protection | Storage | MUST |
| [FR-RIE-012](FR-RIE-012-filename-hygiene-traversal-guard.md) | Filename hygiene — plain names only; a hand-edited payload cannot escape the store root | Storage Hardening | MUST |
| [FR-RIE-013](FR-RIE-013-transactional-replace.md) | Transactional replace — write the new video before the index points at it | Storage Lifecycle | MUST |
| [FR-RIE-014](FR-RIE-014-delete-with-owner.md) | Delete with the owner — routine deletion, event deletion and reconcile leave no orphan video | Storage Lifecycle | MUST |
| [FR-RIE-015](FR-RIE-015-reminder-always-fires.md) | The reminder always fires — instruction media never blocks, delays or mutes it | Fire-Time Reliability | MUST |
| [FR-RIE-016](FR-RIE-016-presentation-handlers-always-false.md) | Presentation handlers always return false — notification outcomes unchanged | Notification Discipline | MUST |
| [FR-RIE-017](FR-RIE-017-fire-time-composition.md) | Fired screen composition — reminder content plus instruction content per kind | Fire-Time Presentation | MUST |
| [FR-RIE-018](FR-RIE-018-playback-ux-no-autoplay.md) | Playback UX — explicit large Play opens full-screen AVKit; no sound before a user action | Playback UX | MUST |
| [FR-RIE-019](FR-RIE-019-tap-open-path-foreground-honest.md) | Tap/Open path in v1 — reach the instruction after unlock; no background video claim | Fire-Time Access | MUST |
| [FR-RIE-020](FR-RIE-020-playback-failure-plain-fallback.md) | Playback failure — plain localized message, reminder stays, always dismissible, PII-free log | Failure Handling | MUST |
| [FR-RIE-021](FR-RIE-021-notification-taxonomy-preserved.md) | Notification taxonomy preserved — full-REPLACE builder, scoped cancels only | Notification Discipline | MUST |
| [FR-RIE-022](FR-RIE-022-video-not-in-notification-attachments.md) | Instruction video never enters the notification attachment store | Notification Discipline | MUST |
| [FR-RIE-023](FR-RIE-023-no-new-ack-escalation-machinery.md) | No new acknowledgement, escalation, re-fire or missed-event machinery | Preserved Behaviour | MUST |
| [FR-RIE-024](FR-RIE-024-honest-capability-surface.md) | Honest capability surface — YouTube link not shipped, no fake control, room left for a later link kind | Honesty / Capability Surface | MUST |
| [FR-RIE-025](FR-RIE-025-camera-microphone-permissions.md) | Camera and microphone at point of use — plain disclosure, denial non-blocking | Capture Permissions | MUST |

## Traceability to the source mandate

| Source | Requirements |
|--------|--------------|
| Feature purpose and in-scope items 1–5 (instructions on routines and free-form events; local video primary; three kinds; playback at fire time) | FR-RIE-001 … FR-RIE-025 |
| OD-1 media amendment (text, image, video; one instruction; 3 min / ~200 MB; no transcode; codec rejection) | FR-RIE-001, FR-RIE-002, FR-RIE-003, FR-RIE-006 |
| OD-2 in-app recording ships, system camera UI, non-blocking denial | FR-RIE-005, FR-RIE-025 |
| OD-3 YouTube links not shipped; room for a later link kind; no fake control | FR-RIE-024 (+ FR-RIE-001 model) |
| OD-4 fire-time composition, no autoplay, photos plus video | FR-RIE-017, FR-RIE-018, FR-RIE-007 |
| OD-5 storage roots, bare filenames, complete file protection, receive-as-is | FR-RIE-011, FR-RIE-006 |
| OD-6 foreground-only honest; routine tap/Open in v1; no extra "Watch video" action | FR-RIE-018, FR-RIE-019, FR-RIE-024 |
| OD-7 injectable playback seam; simulator failure paths; one device smoke | FR-RIE-020, NFR-RIE-009 |
| OD-8 success criterion (caregiver attaches; elder follows unaided) | FR-RIE-009, FR-RIE-010, FR-RIE-017 … FR-RIE-020 |
| Instruction Model & Storage Contract properties 1–7 | FR-RIE-001, FR-RIE-008, FR-RIE-011 … FR-RIE-014, FR-RIE-022, NFR-RIE-005 … NFR-RIE-007 |
| Capture & Permissions Contract properties 1–6 | FR-RIE-004, FR-RIE-005, FR-RIE-007, FR-RIE-009, FR-RIE-010, FR-RIE-025, NFR-RIE-002 |
| Fire-Time Playback, Accessibility & Failure Contract properties 1–7 | FR-RIE-015 … FR-RIE-023, NFR-RIE-001, NFR-RIE-008 |
| Safety & Compliance Delta (fail-safe degradation; on-device only; privacy of home video; permissions; no silent stubs) | FR-RIE-015, FR-RIE-020, FR-RIE-024, NFR-RIE-003, NFR-RIE-004 |
| Root brief FR-024 / FR-025 (general reminders; schedules persist) and supplement FR-D26–D29 (routine guidance context) | FR-RIE-001, FR-RIE-008, FR-RIE-023 (context, never renumbered) |
