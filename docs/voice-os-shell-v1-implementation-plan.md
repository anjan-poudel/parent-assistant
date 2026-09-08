# Voice-OS Shell v1 — Implementation Plan

Date: 2026-09-07 · Spec: `docs/superpowers/specs/2026-09-07-voice-os-shell-v1-design.md`
Branch: `worktree-voice-os-shell-v1`

## Execution model

Parallel subagents with **disjoint file ownership**, all inside the worktree
`voice-os-shell-v1`. Agents A–C write **new files only** and code against the pinned
contracts in §Contracts (the contracts live in this plan, not in each other's code).
Agent D (wiring) runs **after** A–C and is the only writer of existing files.
No agent builds or commits. Integration + verification happen in the main checkout
(`./build.sh test`), then commit and merge.

## File ownership

| Agent | Files (all new unless noted) | Parallel? |
|---|---|---|
| A — SpeakQueue | `Services/Voice/Announcement.swift`, `Services/Voice/SpeakQueue.swift`, `ElderlyAssistantTests/Services/Voice/SpeakQueueTests.swift` | yes |
| B — SpeechSource + NotificationReader | `Services/Plugins/SpeechSource.swift`, `Services/Notifications/NotificationFacade.swift`, `Services/Plugins/NotificationReader.swift`, `ElderlyAssistantTests/.../SpeechSourceRegistryTests.swift`, `.../NotificationReaderTests.swift`, `.../NotificationFacadeTests.swift` | yes |
| C — MorningBriefing | `Services/Plugins/MorningBriefing.swift`, `ElderlyAssistantTests/.../MorningBriefingTests.swift` | yes |
| D — Wiring (serial, after A–C) | EDITS: `App/AppCoordinator.swift`, `Services/Voice/CommandRouter.swift`, `Resources/Localizable.xcstrings`, card views | no |

## Pinned contracts

```swift
// Services/Voice/Announcement.swift
enum AnnouncementPriority: Int, Comparable, CaseIterable {
    case interactive = 0, notification = 1, briefing = 2, safety = 3, emergency = 4
}
struct AnnouncementCard: Equatable { let title: String; let body: String; let symbolName: String }
struct Announcement: Identifiable, Equatable {
    let id: UUID
    let text: String                    // already localized
    let priority: AnnouncementPriority
    let sourceID: String
    let card: AnnouncementCard?         // nil = speech only
}

// Services/Voice/SpeakQueue.swift — owns the single shared Speaker instance
protocol SpeakQueueProtocol: AnyObject {
    func enqueue(_ announcement: Announcement)
    var isSpeaking: Bool { get }
    var currentCard: AnnouncementCard? { get }
}
final class SpeakQueue: SpeakQueueProtocol, ObservableObject {
    @Published private(set) var currentCard: AnnouncementCard?
    init(speaker: Speaker, observability: ObservabilityBus)  // Speaker protocol: Services/Voice/Speaker.swift
}
// Behavior (from spec §3, §6): lane preemption (higher cancels lower mid-utterance;
// lower waits); coalescing — .notification announcements within 60s merge into one
// summary; depth caps — drop-oldest for .notification only, never drop .safety/.emergency;
// TTS failure fallback: Piper -> system voice (en); Nepali without Piper -> card-only +
// sanitised log event, never fake speech. All internal events PII-free.

// Services/Plugins/SpeechSource.swift
protocol SpeechSource: AnyObject {
    var sourceID: String { get }
    var defaultPriority: AnnouncementPriority { get }
    func isApplicable(locale: Locale) -> Bool
    func nextAnnouncement() async -> Announcement?   // nil = nothing to say now
}
final class SpeechSourceRegistry {
    func register(_ source: SpeechSource)   // duplicate sourceID -> observability event, drop second (never crash)
    func applicableSources(locale: Locale) -> [SpeechSource]
}

// Services/Notifications/NotificationFacade.swift — the SINGLE UNUserNotificationCenterDelegate
protocol NotificationEventHandling: AnyObject {
    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool  // true = spoken, caller enqueues
    func didReceive(_ response: UNNotificationResponse) async   // v1: sanitised event only; action categories are later work
}
final class NotificationFacade: NSObject, UNUserNotificationCenterDelegate {
    init(handlers: [NotificationEventHandling], observability: ObservabilityBus)
    // willPresent ALWAYS calls completionHandler with .banner + .list + .sound to
    // preserve current delivery behavior, then notifies handlers.
}

// Services/Plugins/NotificationReader.swift
final class NotificationReader: SpeechSource, NotificationEventHandling {
    init(queue: SpeakQueueProtocol, observability: ObservabilityBus)
    // Category allowlist: read ACTUAL category identifiers from
    // Services/MedicationScheduler/PlatformAlarmScheduler.swift (medication), plus family
    // and calendar categories as found. Non-allowlisted categories are never spoken.
    // Medication -> .safety lane; everything else allowlisted -> .notification lane.
}

// Services/Plugins/MorningBriefing.swift
final class MorningBriefing: SpeechSource {
    init(queue: SpeakQueueProtocol, observability: ObservabilityBus /* + existing
         RoutineScheduler / calendar / weather services read from current code */)
    var wakeWindowStart: Int  // hour, default 5
    var wakeWindowEnd: Int    // hour, default 10
    func shouldFireOnActivation(now: Date, calendar: Calendar) -> Bool  // once per window per calendar day
    func fire() async          // compose deterministically + enqueue(.briefing) once
}
```

## Localization keys (pinned — Agent D adds values en+ne; Agents B/C reference only)

```
notification.read.medication        ("Medicine time: %@")
notification.read.summary           ("You have %d new notifications")
briefing.greeting                   ("Good morning")
briefing.date                       ("Today is %@")
briefing.routines                   ("Your routines today: %@")
briefing.medications                ("Your medications today: %@")
briefing.calendar                   ("Your events today: %@")
briefing.weather                    ("The weather today: %@")
briefing.weather.unavailable        ("Weather is not available in this mode")
briefing.nothing                    ("You have nothing scheduled today")
briefing.empty.<source>             (one per empty source, honest wording)
```

## Agent D wiring checklist (serial, after A–C)

1. `AppCoordinator`: construct `SpeakQueue` with the existing `Speaker`; construct
   `SpeechSourceRegistry`; register `NotificationReader` + `MorningBriefing`; set
   `UNUserNotificationCenter.current().delegate` to a `NotificationFacade`; app-activation
   hook → `morningBriefing.shouldFireOnActivation` → `fire()`. No new coordinator-owned
   state beyond composition (capability rule).
2. `CommandRouter`: spoken "read me my briefing" via existing pre-answer layer →
   `morningBriefing.fire()`; migrate coordinator-level speak() sites to
   `SpeakQueue` `.interactive` lane (thin shims; zero behavior change for existing
   flows). Medication announcement speech routes through `.safety`.
3. `Localizable.xcstrings`: add the pinned keys with en + ne values.
4. Outcome cards: `currentCard` presentation beside existing result-card pattern.
5. Run existing test suites mentally for signature drift; fix compile fallout during
   main-checkout integration.

## Integration & verification (in main checkout)

1. Union-copy A–C new files + D's edits into the main checkout.
2. **CommandRouter contention:** main checkout holds another session's uncommitted
   weather-routing edits (`CommandRouter.swift`, `TopicPreAnswer.swift`,
   `WeatherTool.swift`, tests, `Localizable.xcstrings`). Apply D's `CommandRouter` diff
   ON TOP of that working file (patch, never wholesale replace); merge the xcstrings key
   sets.
3. `./build.sh test` (canonical; runs xcodegen) — fix compile fallout.
4. Golden-corpus + full suite; confirm no behavior change for existing command flows.
5. Commit from the worktree, `--no-ff` merge to master, cleanup.

## Out of scope (per spec §10)

Barge-in, background delivery, dialog manager, app control, LLM narration, wake-word
changes, TTS pause API.
