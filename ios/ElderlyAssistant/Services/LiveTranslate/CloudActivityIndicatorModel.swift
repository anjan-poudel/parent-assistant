import Foundation

// C10 — `CloudActivityIndicatorModel` (T-016, FR-LCT-011).
//
// The indicator's whole job is to be a **true statement about cloud
// activity**: the elder is told, while it is shown, that text from their
// screen is being sent to the assistant's cloud service. A statement like
// that is either true or it is a lie, so this type is built to have exactly
// one input.
//
// What this file exists to make true:
//
//  - **One input, and it is the request counter.** `isActive` is `private(set)`
//    and changes only in `requestBegan()` / `requestEnded()` — the tier's
//    in-flight registry. Nothing else in the app can turn the indicator on:
//    not the settings layer, not the overlay layer, not the dictionary-only
//    path, and not the "always show original text" toggle (which changes the
//    overlay's form and nothing else — FR-LCT-011 scenario 3). The view
//    cannot suppress it while a request is in flight, because the view has no
//    input that could.
//  - **On at 0→1, off at 1→0.** The count is the number of in-flight
//    requests, so an indicator that disagreed with reality would have to be
//    a second source of truth. There is none.
//  - **No minimum-dwell timer.** A lingering indicator after the request
//    resolved is a false statement about cloud activity, which is exactly
//    what FR-LCT-011 forbids. A very fast response flickering is the honest
//    display of a very fast response.
//  - **No latch.** Failure, timeout and cancellation all return through the
//    same release path (`withRequestInFlight(_:)`'s `defer`, or the tier's
//    own paired `requestEnded()`), so a failed request cannot leave the
//    indicator on any more than a successful one can.
//  - **Content-free transitions.** The two events carry no metadata at all —
//    there is no parameter here through which text, a prompt or an
//    identifier could travel (NFR-LCT-006).
//
// `@MainActor` because it is bound to a view and because serialising the
// counter on the main actor is what makes "no two updates interleave"
// structural rather than hoped for.

@MainActor
final class CloudActivityIndicatorModel: ObservableObject {

    /// Whether a cloud request is in flight **right now**. The only writer is
    /// this class; the only readers are the view and the tests.
    @Published private(set) var isActive = false

    // MARK: Dependencies

    private let events: LiveTranslateEvents

    // MARK: State (main-actor-isolated)

    /// The number of in-flight cloud requests. `isActive` is exactly
    /// `inFlightCount > 0`, maintained on every transition.
    private var inFlightCount = 0
    /// Tokens for the scoped `withRequestInFlight(_:)` path. A token is
    /// removed by its own release, so a double release cannot decrement the
    /// count twice — the registry, not the caller's discipline, is what
    /// keeps the indicator honest.
    private var scopedTokens: Set<UUID> = []

    // MARK: Init

    init(observabilityBus: ObservabilityBus, config: LiveTranslateConfig = .default) {
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
    }

    // MARK: The tier's registry (the only input)

    /// The tier reports that a cloud request has begun. The indicator appears
    /// on the 0→1 transition and records it once.
    func requestBegan() {
        begin()
    }

    /// The tier reports that a cloud request has ended — resolved, failed,
    /// timed out or cancelled, all the same way. The indicator disappears on
    /// the 1→0 transition.
    ///
    /// An unpaired call is ignored rather than counted: a count that could go
    /// negative would let a later request fail to show the indicator, and
    /// silently *not* showing it is the one error this type must not make.
    func requestEnded() {
        end()
    }

    /// Runs `body` with a cloud request in flight, releasing the registration
    /// when it returns **or throws** — the tier's `defer`-released registry,
    /// expressed as a scoped API so a call site cannot forget the release.
    ///
    /// This is a convenience over the paired calls, not a second input: it
    /// moves the same counter.
    func withRequestInFlight<T>(_ body: () async throws -> T) async rethrows -> T {
        let token = beginScoped()
        defer { endScoped(token) }
        return try await body()
    }

    /// How many requests the model believes are in flight. Evidence for the
    /// tier's tests and for `security-test`; there is no setter.
    var inFlightRequestCount: Int { inFlightCount }

    // MARK: Transitions

    private func begin() {
        inFlightCount += 1
        guard inFlightCount == 1 else { return }
        isActive = true
        events.cloudIndicatorShown()
    }

    private func end() {
        guard inFlightCount > 0 else { return }
        inFlightCount -= 1
        guard inFlightCount == 0 else { return }
        isActive = false
        events.cloudIndicatorHidden()
    }

    // MARK: Scoped registration

    private func beginScoped() -> UUID {
        let token = UUID()
        scopedTokens.insert(token)
        begin()
        return token
    }

    private func endScoped(_ token: UUID) {
        // A release that does not correspond to a live registration is
        // ignored: idempotence matters more than the count, because the count
        // is derived from registrations.
        guard scopedTokens.remove(token) != nil else { return }
        end()
    }
}
