import Foundation
import Network

/// [RELIABILITY-ROUTER] "Is there a network path right now?" — the one question
/// the router needs answered before it will put the cloud in FRONT of the
/// on-device tier.
///
/// The feature has never had to ask before. Offline has been handled
/// reactively: a cloud request fails, `URLError` classifies as `.offline`, the
/// region degrades with `no_network` and the tier behind it answers. That is
/// the right shape for a tier that is only ever tried second, and the wrong
/// one for a tier the router wants to LEAD with — leading with the cloud means
/// paying the request, the retry and the degraded state before the device is
/// ever asked, on every sentence, on a phone that is simply offline.
///
/// A protocol rather than a direct `NWPathMonitor` reference, for the reason
/// the pipeline's other collaborators are protocols: the routing decision has
/// to be testable where no network state can be controlled or waited on.
///
/// **What it is not.** This is a PATH question, not a permission question. It
/// says nothing about the household's cloud switch, consent, or the budget —
/// those stay in the gate, which is consulted after this and before any
/// request. A `true` here does not mean a request will be made; a `false` here
/// only ever costs the router the cloud-first ORDER, because the cloud is
/// still asked later in the same tick for whatever the device misses.
protocol NetworkReachability: Sendable {
    /// True while a network path is available. Implementations are
    /// **conservative**: one that has not seen its first update yet answers
    /// false, so the worst this can do is leave the cascade in the order it
    /// shipped with.
    var isReachable: Bool { get }
}

/// The device's real answer, from `NWPathMonitor`.
///
/// The monitor delivers on its own queue, so the flag it writes is guarded and
/// the read is synchronous: the pipeline asks this question from actor code
/// that has no business awaiting a path update mid-dispatch.
final class PathMonitorReachability: NetworkReachability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "live-translate.reachability")
    private let lock = NSLock()
    /// False until the first update arrives: "not known to be reachable" and
    /// "not reachable" both mean "do not lead with the cloud", which is the
    /// order that needs no network at all.
    private var reachable = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.reachable = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    deinit { monitor.cancel() }
}

/// The answer for a caller that has no opinion — every construction site that
/// predates the router, and every test that is not about it.
///
/// It reports "no path", which keeps the cascade in the order it shipped with:
/// the device leads and the cloud is asked for whatever the device misses.
/// That direction is chosen so a missing wiring degrades to today's behaviour
/// rather than to a cloud-first cascade nobody asked for.
struct UnavailableReachability: NetworkReachability {
    var isReachable: Bool { false }
}
