import Foundation
import os

// MARK: - Startup instrumentation (startup review P0, 2026-09-10)
//
// SEVEN separate OSSignposter intervals — one per startup metric the
// review asks for. They are deliberately NOT collapsed into a single
// "startup complete" duration: a slow boot has to be attributable to a
// phase (bootstrap init vs. data restoration vs. voice start vs. KWS
// construction vs. the optional engine warm) or the trace tells us
// nothing actionable.
//
//  1. bootstrap-init            — AppCoordinator.init() (composition root).
//  2. first-meaningful-frame    — App struct init → first committed frame.
//  3. safety-data-restored      — boot start → safety-critical data live.
//  4. voice-pipeline-start-requested
//                               — voice-prep phase → start request issued.
//  5. kws-session-ready         — KWS model resolution + session build.
//  6. voice-pipeline-callback-completed
//                               — start request → completion callback.
//  7. warm-engines-completed    — warm phase → warm settled (or watchdog).
//
// Intervals 4 and 6 are adjacent, not overlapping: 4 measures how long
// the boot took to ASK the voice stack to start, 6 measures how long the
// pipeline itself took to answer. Both are honest, separate numbers.
//
// Signposts carry machine strings only (stage/outcome names, booleans,
// integer counters) — never transcripts, names or other PII, matching
// the LogSanitiser contract the ObservabilityBus enforces elsewhere.

/// One named startup interval. `name` is the signpost name that shows up
/// in Instruments; keep them stable — traces are compared across builds.
enum StartupInterval: String, CaseIterable {
    case bootstrapInit = "bootstrap-init"
    case firstMeaningfulFrame = "first-meaningful-frame"
    case safetyDataRestored = "safety-data-restored"
    case voicePipelineStartRequested = "voice-pipeline-start-requested"
    case kwsSessionReady = "kws-session-ready"
    case voicePipelineCallbackCompleted = "voice-pipeline-callback-completed"
    case warmEnginesCompleted = "warm-engines-completed"

    /// `beginInterval`/`endInterval` take a `StaticString`; the raw value
    /// is a `String`, so the signpost names are spelled once here.
    var signpostName: StaticString {
        switch self {
        case .bootstrapInit: return "bootstrap-init"
        case .firstMeaningfulFrame: return "first-meaningful-frame"
        case .safetyDataRestored: return "safety-data-restored"
        case .voicePipelineStartRequested:
            return "voice-pipeline-start-requested"
        case .kwsSessionReady: return "kws-session-ready"
        case .voicePipelineCallbackCompleted:
            return "voice-pipeline-callback-completed"
        case .warmEnginesCompleted: return "warm-engines-completed"
        }
    }
}

/// Thread-safe holder for the in-flight interval states. Startup spans
/// several queues (boot queue, main, the voice stack's callback thread),
/// so begin and end are NOT guaranteed to run on the same thread — the
/// state is stored under a lock and each interval is finished exactly
/// once.
///
/// Bookkeeping (`openNames`) is independent of whether signposts are
/// ENABLED for the current process (`OSSignposter.isEnabled` — false in
/// an untraced unit-test run). The pairing contract — "a repeated begin
/// is a no-op, an unmatched end is a no-op" — is a property of the call
/// sites, so it holds either way; only the `os_signpost` calls themselves
/// are gated on the runtime flag.
final class StartupSignpostTracker {
    static let shared = StartupSignpostTracker()

    static let subsystem = "com.elderlyassistant.app"
    static let category = "startup"

    let signposter = OSSignposter(subsystem: subsystem, category: category)

    private let lock = NSLock()
    private var active: [String: OSSignpostIntervalState] = [:]
    /// Names begun and not yet ended — the enabled-independent half of
    /// the bookkeeping (see the class comment).
    private var openNames: Set<String> = []

    /// Begins `interval`. A repeated begin (duplicate call site, restart)
    /// is a no-op — an interval is never double-opened, so the pair in
    /// the trace stays balanced.
    func begin(_ interval: StartupInterval) {
        lock.lock()
        let alreadyOpen = !openNames.insert(interval.rawValue).inserted
        lock.unlock()
        guard !alreadyOpen, signposter.isEnabled else { return }
        let state = signposter.beginInterval(interval.signpostName)
        lock.lock()
        active[interval.rawValue] = state
        lock.unlock()
    }

    /// Ends `interval` with an optional machine-string note. Ending an
    /// interval that was never begun is a no-op (e.g. an early-return
    /// path, or a trace recorded before the begin site ran).
    func end(_ interval: StartupInterval, note: String? = nil) {
        lock.lock()
        let wasOpen = openNames.remove(interval.rawValue) != nil
        let state = active.removeValue(forKey: interval.rawValue)
        lock.unlock()
        guard wasOpen, signposter.isEnabled, let state else { return }
        if let note {
            signposter.endInterval(interval.signpostName, state,
                                   "\(note, privacy: .public)")
        } else {
            signposter.endInterval(interval.signpostName, state)
        }
    }

    /// A discrete point of interest inside a running interval (e.g. the
    /// exact moment the voice start request was issued). Not an interval
    /// — it carries no duration and never gates anything.
    func event(_ interval: StartupInterval, _ note: String) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent(interval.signpostName,
                             "\(note, privacy: .public)")
    }

    /// True while `interval` is open — test + diagnostics seam.
    func isActive(_ interval: StartupInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openNames.contains(interval.rawValue)
    }

    /// Drops every open interval without ending it. Tests only.
    func reset() {
        lock.lock()
        active.removeAll()
        openNames.removeAll()
        lock.unlock()
    }
}

/// Static facade — the call sites read as prose (`StartupSignposts.end(
/// .bootstrapInit)`).
enum StartupSignposts {
    static func begin(_ interval: StartupInterval) {
        StartupSignpostTracker.shared.begin(interval)
    }

    static func end(_ interval: StartupInterval, note: String? = nil) {
        StartupSignpostTracker.shared.end(interval, note: note)
    }

    static func event(_ interval: StartupInterval, _ note: String) {
        StartupSignpostTracker.shared.event(interval, note)
    }

    /// The metric names a physical-device trace must show separately —
    /// pinned by `StartupSignpostsTests` so a future edit cannot quietly
    /// merge two metrics into one.
    static let metricNames: [String] = StartupInterval.allCases.map(\.rawValue)
}
