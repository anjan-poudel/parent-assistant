# Requirements — Reminders Instructions Enhancements

Feature: `reminders-instructions-enhancements` (branch `feat/reminders-instructions-enhancements`,
worktree `elderly-ai-assistant-reminders-instructions-enhancements`; scaffold base master
`821f19c5`).
Task: `define-requirements`, agent `ba`, contracts `requirements_doc` + `requirements_lock`.
Date: 2026-10-25.
Source mandate: the owner's scaffold brief and the normative feature supplement
[`../reminders-instructions-enhancements/constitution.md`](../reminders-instructions-enhancements/constitution.md),
whose "Decisions" section records **OD-1 … OD-8 as RESOLVED by the owner on 2026-10-25**. The
locked snapshot in `define-requirements.lock.yaml` is the drift-detection baseline for downstream
tasks.

## Summary

- Functional requirements: **25** (`FR-RIE-001` … `FR-RIE-025`), all MUST.
- Non-functional requirements: **10** (`NFR-RIE-001` … `NFR-RIE-010`), all MUST.
- Gherkin acceptance scenarios: **107** (80 in the FR set, 27 in the NFR set).
- Areas covered: Instruction Model; Text Instruction; Image Instruction; Video Capture; Video
  Constraints; Captions; Instruction Lifetime; Caregiver Editing; Storage; Storage Hardening;
  Storage Lifecycle; Fire-Time Reliability; Fire-Time Presentation; Playback UX; Fire-Time Access;
  Failure Handling; Notification Discipline; Preserved Behaviour; Honesty / Capability Surface;
  Capture Permissions; Accessibility; Localisation; Privacy; Security; Reliability /
  Compatibility; Performance; Quality / Compliance.
- Scope: instruction media (text, image, video) attached to **daily-routine reminders** and
  **app-created free-form events**, captured locally (library pick and in-app recording), stored in
  the app's Application Support tree with complete file protection, and presented at fire time with
  a large explicit Play control. Video is the flagship path; text and image are first-class kinds.

## Contents

- [FR/index.md](FR/index.md) — functional requirements (25 files, `FR-RIE-001` … `FR-RIE-025`)
- [NFR/index.md](NFR/index.md) — non-functional requirements (10 files, `NFR-RIE-001` … `NFR-RIE-010`)
- [../define-requirements.md](../define-requirements.md) — consolidated, human-readable copy of this
  set (the `requirements_doc` contract artifact)
- [../define-requirements.lock.yaml](../define-requirements.lock.yaml) — locked snapshot with
  per-requirement content hashes (the `requirements_lock` contract artifact)

Note: the `FR/` and `NFR/` folders also contain the earlier features' requirement files
(medication-schedules-reminders `FR-MSR-*`/`NFR-MSR-*`, call-dialer-primary-secondary
`FR-CDP-*`/`NFR-CDP-*`, conversational-nepali-replies `FR-CNR-*`/`NFR-CNR-*`, family-contacts-unify
`FR-FCU-*`/`NFR-FCU-*`, live-camera-translation `FR-LCT-*`/`NFR-LCT-*`, multi-turn-conversation
`FR-MTC-*`/`NFR-MTC-*`, profile-interview `FR-PI-*`/`NFR-PI-*`, spotify-music-integration
`FR-SP-*`/`NFR-SP-*`), left in place untouched; the indexes on this page and the lock cover the
`reminders-instructions-enhancements` set only.

## Resolved decisions carried as requirements

All decisions were resolved by the owner on 2026-10-25 ("go with your suggestions" on the proposed
defaults, plus the media amendment). No owner-level decision is open.

| # | Resolution | Carried by |
|---|---|---|
| OD-1 | Instructions cover **text, image and video**; one instruction per reminder/event of any single kind; video caps 3 minutes / ~200 MB stored as provided (no transcode); unsupported codec rejected at pick time with a plain message; audio-only out | FR-RIE-001, FR-RIE-002, FR-RIE-003, FR-RIE-006 |
| OD-2 | In-app recording ships in v1 using the system camera UI; point-of-use camera + microphone prompts; `Info.plist` amended; denial leaves library pick and the reminder fully working | FR-RIE-005, FR-RIE-025 |
| OD-3 | YouTube links not shipped in v1; the model leaves room for a later `link` kind (URL stored, not bytes); no fake control | FR-RIE-024 (+ FR-RIE-001 model) |
| OD-4 | Fired screen shows reminder content plus instruction content per kind; large Play opens full-screen AVKit; no sound before an explicit action; photos plus video coexist; order is design-level | FR-RIE-017, FR-RIE-018, FR-RIE-007 |
| OD-5 | Dedicated `Application Support/InstructionVideos/<entryId>/` for routines and a separate event root; bare filenames in encrypted payloads; `.completeFileProtection`; receive-as-is format | FR-RIE-011, FR-RIE-006, NFR-RIE-005 |
| OD-6 | v1 keeps foreground presentation; the routine tap/Open path IS in v1; no background video claim; no extra "Watch video" action button | FR-RIE-018, FR-RIE-019, FR-RIE-024 |
| OD-7 | Thin injectable playback seam in the `CameraCapturePresenting` style; simulator covers every failure path; one real-device smoke check; no UI test required | FR-RIE-020, NFR-RIE-009 |
| OD-8 | Success = a caregiver can attach an instruction (text, image or video) to a routine reminder or free-form event, and when it fires the elderly user can follow it unaided | FR-RIE-009, FR-RIE-010, FR-RIE-017 … FR-RIE-020 |

## Open decisions

**None at owner level.** OD-1 … OD-8 are RESOLVED in the feature constitution (2026-10-25) and are
carried by this set as settled requirements. Design-level choices inside those contracts —
exact layout/ordering of photos versus the video affordance, the exact event instruction root name,
the concrete system-camera component, and the fired-screen visual composition — belong to
`design-l1` / `design-l2`. They are bounded by FR-RIE-011 (separate roots), FR-RIE-017 (composition
per kind), FR-RIE-018 (explicit Play, no autoplay) and FR-RIE-005 (system camera UI).

## Out of scope

- **Medication reminders** — no instruction surface is added there, and no medication code path is
  altered (FR-RIE-023, NFR-RIE-010).
- **Imported / Google / other-calendar events** — only app-created free-form events tracked by
  `EventExtrasStore` are in scope.
- **Any new acknowledgement, escalation, re-fire or missed-event machinery** — routines and
  free-form events remain explicitly non-safety-critical (FR-RIE-023).
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
- **A new standalone media-library screen or top-level tab** — instructions are managed in the
  existing caregiver surfaces (FR-RIE-009).
- **Background or killed-at-fire video playback claims** — foreground is the honest baseline; the
  tap/Open path is the v1 route (FR-RIE-019, FR-RIE-024).
- **A UI test requirement** — none is required (OD-7, NFR-RIE-009).
- **Any new safety-critical surface, alert, delivery guarantee, or biometric/PIN gate** — the
  safety delta is none.
- **Changes to the existing photo-aid behaviour, notification taxonomy, read-aloud, caregiver
  alerts, or the medication path** — preserved (FR-RIE-016, FR-RIE-021, NFR-RIE-010).

## Assumptions and ambiguity resolution

Recorded in full in [`../define-requirements.md`](../define-requirements.md) §Assumptions recorded
during this requirements pass. The load-bearing ones: "~200 MB" is encoded as a hard 200 MiB bound;
"one instruction of any single kind" means one designated instruction, with existing photo aids
allowed to coexist with a video instruction (OD-4); the exact event instruction root name is
design-level; playback latency targets are BA-set acceptance bounds for the device smoke check.
