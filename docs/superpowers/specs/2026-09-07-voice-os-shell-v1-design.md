# Voice-OS Shell v1 — Design Spec

Date: 2026-09-07 · Status: pending user review
Parent: `docs/superpowers/specs/2026-09-07-voice-os-pivot-proposal.md` (§7)

## 1. Purpose

First implementation slice of the voice-driven personal OS: a **kernel speak-queue** with
priority lanes, **notification read-aloud**, and a **morning briefing**. This slice
establishes the kernel/userland boundary every later slice builds on.

## 2. Confirmed decisions

- **Scope:** `SpeakQueue` + `NotificationReader` + `MorningBriefing`. App control, dialog
  manager, and barge-in are later slices.
- **Read-aloud mode:** active-app only — foreground, or lock-screen while the process
  lives via the existing `audio` session. Honest about iOS limits; true background
  delivery is Track 1 work.
- **Delegate composition:** `NotificationReader` subscribes behind the single
  `UNUserNotificationCenterDelegate` facade that later hosts notification action
  categories (medication ack, refusal, emergency countdown cancel). The reader never owns
  the delegate.
- **Briefing narration:** deterministic localized templates. No LLM, no cloud cost, no
  Gemini quota impact.

## 3. Architecture

**Kernel:** `SpeakQueue` owns the single `Speaker` instance (today the speaker is private
inside coordinators — `AppCoordinator.swift` ~195 KB must not grow new speech behavior).
The queue is a capability composed by `AppCoordinator`, which stays a composition root.

Priority lanes:

| Lane | Use | Interrupt policy |
|---|---|---|
| `.emergency` | future emergency module | non-cancellable, preempts all |
| `.safety` | medication announcements, escalation voice | preempts everything below it |
| `.briefing` | proactive compositions | waits for `.interactive` to finish |
| `.notification` | read-aloud | coalesces; never interrupts speech |
| `.interactive` | command replies (existing paths) | current utterance finishes |

**Userland:** `SpeechSource` protocol — sources that *push speech into the system*. v1
contract: `sourceID`, `announcementPriority`, `isApplicable(locale:)`,
`nextAnnouncement() async -> Announcement?` where `Announcement` = localized text +
priority + card hint. Compile-time registration beside `PluginRegistry`.

**Hard rule:** safety-critical sources never go through `SpeechSource`. Medication
announcements stay kernel/scheduler-driven with the `.safety` lane. The plugin contract
stays userland, per the existing plugin-architecture rule.

## 4. Components

**4.1 `SpeakQueue`** (Services/Voice/) — priority arbitration, coalescing (multiple
`.notification` announcements within 60 s → one summary announcement, e.g. "You have 3
new notifications"), per-lane depth caps (drop-oldest for `.notification` only; `.safety`
and `.emergency` are never dropped), TTS fallback chain (Piper → system voice for
English; Piper-missing Nepali → card-only + sanitised log, never fake speech — today's
Nepali system fallback is literal silence).

**4.2 `SpeechSource` + registry** (Services/Plugins/) — compile-time registration, locale
gating (same pattern as `AssistantPlugin.isApplicable`), explicit outcomes (spoken /
card-only / failed — no silent stubs).

**4.3 `NotificationReader`** (source plugin #1) — hooks the facade delegate's
`willPresent` → category allowlist gate (medication, family, calendar only; everything
else stays silent) → localized template render → enqueue (`.notification`, or `.safety`
for medication). PII-free logging: announcement templates logged by event name only, no
medication names, transcripts, or health values.

**4.4 `MorningBriefing`** (source plugin #2) — triggers: (a) first app activation inside
a configurable wake window (default 05:00–10:00, local setting for v1; caregiver
configurable once the caregiver app exists) — fires once per wake window per calendar
day, (b) spoken command ("read me my briefing")
routed through the existing pre-answer layer. Deterministic composition: Bikram Sambat
date (existing Nepali calendar services) → today's routines → today's medications → today's
calendar events → weather via the existing `TopicPreAnswer` path (stack-dependent — on the
on-device stack, an honest "weather isn't available in this mode" line). Localized ne/en
templates with the existing veto/honesty rules — never fabricate.

**4.5 `CommandRouter` migration** — all coordinator-level speech migrates to the queue's
`.interactive` lane; existing direct-speak sites become thin shims so the migration lands
in one place and current tests keep passing.

**4.6 Outcome cards** — briefings and read-aloud reuse the existing
`PluginResult.spokenAndPresented` card pattern.

## 5. Data flow

**Notification:** notification arrives → facade delegate → category allowlist → template
render → enqueue → queue speaks (or coalesces). While the user is mid-command,
`.notification` waits; `.safety` preempts.

**Briefing:** trigger fires → compose from deterministic sources → each source reports
`available` / `empty` / `unavailable` explicitly → template render (ne/en) → enqueue
`.briefing` → speak + outcome card. Unavailable sources are skipped with an honest line,
never invented.

## 6. Error handling

- Every announcement path returns an explicit outcome (spoken / card-only / failed) — no
  silent success, matching the plugin architecture's hard rule.
- TTS failure: Piper missing → system voice for English; Nepali without Piper voice →
  card-only + sanitised log.
- Notification storm: coalescing (60 s window) + depth caps, drop-oldest for
  `.notification` only.
- Interruptions: higher lane cancels lower mid-utterance; lower never interrupts higher.
- PII policy: no medication names, transcripts, or health values in logs or announcements
  metadata.

## 7. Testing

**Unit:** `SpeakQueueTests` — lane preemption matrix, coalescing, depth caps, fallback
chain per language; `NotificationReaderTests` — category gating, template rendering
ne/en, willPresent behavior against a fake notification center;
`MorningBriefingTests` — composition with fakes (FakeRoutineScheduler, fake calendar,
fake weather), Nepali date correctness, empty-source honesty paths, wake-window trigger
logic.

**Integration:** facade delegate shared with the future action-category coordinator (fake
notification center); briefing triggered via the `CommandRouter` pre-answer path.

**Regression:** existing `CommandRouterTests` keep passing through the migrated
`.interactive` lane; golden corpus untouched.

## 8. Acceptance gates

- Emergency/safety lane can never be blocked or dropped by queue depth.
- Read-aloud and briefing fully functional with Gemini disabled and no network.
- Both languages verified by test for every spoken template.
- No new coordinator-owned state — queue and sources are self-contained capabilities.
- No UI behavior change for existing command flows.

## 9. Preconditions

- Merge/commit the in-flight weather-routing work in the main checkout
  (`CommandRouter`, `TopicPreAnswer`, `WeatherTool` + tests) — the briefing composes the
  `TopicPreAnswer` weather path.
- Groundwork (constitution cleanup, worktree pruning, ai-sdd reconciliation) can land in
  parallel; not blocking.

## 10. Out of scope (v1)

Barge-in, background delivery, dialog manager, app control, LLM-narrated briefings,
wake-word changes, family-message sources, TTS pause API (prerequisite for barge-in, to
be added with it).

## 11. Implementation process

Per standing rule: implementation runs via subagent in worktree branch
`worktree-voice-os-shell-v1`; no builds inside the worktree — integrate into the main
checkout and verify with `./build.sh test` (see ios-build-environment-quirks), then commit
and merge sequentially to avoid overlap contention on `AppCoordinator.swift` and
`Localizable.xcstrings`.

## 12. Open items (non-blocking)

- Coalescing summary wording and wake-window local setting UI are template/UI details
  resolved during implementation.
- `.emergency` lane exists from day one but has no producer until the emergency module
  lands (Track 1).
