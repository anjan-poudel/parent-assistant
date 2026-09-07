import Foundation

/// One producer of proactive speech in the voice-OS shell
/// (docs/superpowers/specs/2026-09-07-voice-os-shell-v1-design.md §4.2,
/// implementation plan §Pinned contracts).
///
/// Sources are registered at compile time beside `PluginRegistry`; the
/// kernel (`SpeakQueue`) never knows a source by name. A source answers two
/// questions for the shell:
///   - "do you apply to this locale?" — locale gating, the same pattern as
///     `AssistantPlugin.isApplicable`, and
///   - "do you have something to say now?" — the pull channel,
///     `nextAnnouncement()`.
///
/// Push-driven sources (e.g. `NotificationReader`, which enqueues at
/// `willPresent` time) still conform so the registry can gate/order them
/// uniformly; their `nextAnnouncement()` honestly returns nil because
/// nothing is ever staged for the pull channel.
///
/// Hard rule (spec §3): safety-critical speech never goes through this
/// source contract. Medication read-aloud enters the queue on the `.safety`
/// lane via its own lane-aware enqueue inside `NotificationReader` — the
/// lane is an announcement property, not a registry property.
protocol SpeechSource: AnyObject {
    /// Stable identifier for this source, e.g. "notification_reader".
    /// Never shown to the user; used as the `sourceID` of every
    /// `Announcement` the source produces and as the registry's uniqueness
    /// key. Duplicate registration is dropped with an observability event
    /// (mirrors `PluginRegistry` collision handling — never a crash).
    var sourceID: String { get }

    /// The lane this source's announcements enter when no explicit
    /// per-announcement priority is given. Reader announcements carry their
    /// own priority (`.safety` for medication), so this is the nominal
    /// default for the pull channel.
    var defaultPriority: AnnouncementPriority { get }

    /// Locale gate. v1 sources speak text that is already localized at the
    /// producer (notification content) or resolved by the announcement
    /// template, so gate returns true for every locale until per-locale
    /// templates exist.
    func isApplicable(locale: Locale) -> Bool

    /// The next announcement this source has to say, or nil when it has
    /// nothing right now — callers must treat nil as "nothing", never as an
    /// error (spec §4.2).
    func nextAnnouncement() async -> Announcement?
}

/// Owns the set of registered speech sources. Registration is compile-time,
/// by a fixed list in `AppCoordinator` — mirroring `PluginRegistry` (design
/// doc §4.2: "Compile-time registration beside PluginRegistry").
///
/// Answers the one question the shell asks: "which sources apply to this
/// locale, in registration order?"
final class SpeechSourceRegistry {

    private(set) var sources: [SpeechSource] = []
    private let observabilityBus: ObservabilityBus?

    init(observabilityBus: ObservabilityBus? = nil) {
        self.observabilityBus = observabilityBus
    }

    /// Registers `source`. A second source claiming an already-registered
    /// `sourceID` is dropped with an observability event — two sources
    /// claiming the same identity must not silently shadow each other
    /// (same policy as `PluginRegistry` action-name collisions). Deliberately
    /// NOT an assertionFailure: a misregistration must never crash the app,
    /// least of all on an elderly user's device at boot; the event is the
    /// loud failure and the first claimant keeps the identity.
    func register(_ source: SpeechSource) {
        let isDuplicate = sources.contains { $0.sourceID == source.sourceID }
        if isDuplicate {
            observabilityBus?.emit(ObservabilityEvent(
                component: "speech_source_registry",
                eventType: "speech_source_collision",
                durationMs: nil,
                outcome: "failure",
                errorCode: source.sourceID,
                metadata: ["state": source.sourceID]
            ))
            return
        }
        sources.append(source)
    }

    /// Sources whose `isApplicable` gate passes for `locale`, in
    /// registration order (deterministic composition for the shell).
    func applicableSources(locale: Locale) -> [SpeechSource] {
        sources.filter { $0.isApplicable(locale: locale) }
    }
}
