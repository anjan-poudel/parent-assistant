import Foundation

/// Speech lanes (spec §3). Higher lanes speak before lower lanes while
/// queued, and only the safety-critical lanes may interrupt an utterance
/// that is already being spoken (see `SpeakQueue.mayInterrupt`):
///
/// | Lane | Use |
/// |---|---|
/// | `.interactive` | command replies (existing paths) |
/// | `.notification` | read-aloud — coalesces, never interrupts speech |
/// | `.briefing` | proactive compositions — waits for the current utterance |
/// | `.safety` | medication announcements, escalation voice — preempts below |
/// | `.emergency` | future emergency module — preempts all, non-cancellable |
enum AnnouncementPriority: Int, Comparable, CaseIterable {
    case interactive = 0, notification = 1, briefing = 2, safety = 3, emergency = 4

    static func < (lhs: AnnouncementPriority, rhs: AnnouncementPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Visual accompaniment for a spoken announcement — reused by the existing
/// result-card presentation pattern (speech + card, spec §4.6). `nil` on an
/// `Announcement` means speech only.
struct AnnouncementCard: Equatable {
    let title: String
    let body: String
    let symbolName: String
}

/// One unit of push speech: text that is already localized by its source,
/// its lane, the producing `sourceID`, and an optional outcome card.
struct Announcement: Identifiable, Equatable {
    let id: UUID
    let text: String                    // already localized
    let priority: AnnouncementPriority
    let sourceID: String
    let card: AnnouncementCard?         // nil = speech only
}
