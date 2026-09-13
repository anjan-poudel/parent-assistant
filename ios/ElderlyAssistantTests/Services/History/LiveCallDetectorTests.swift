import XCTest
@testable import ElderlyAssistant

/// Edge-triggered live-call detection (call-history task, 2026-09-06):
/// `onChange` fires ONLY on a real transition of `hasActiveCall` — never
/// for an unchanged state, and never for the initial snapshot (a call
/// already active at construction reports via `hasActiveCall`, not a
/// callback). Unanswered-call events (missed-calls task, 2026-09-07)
/// pass through `onUnanswered` as a straight forward of the provider's
/// once-per-call events. All tests drive a fake `CallStateProviding` —
/// CallKit never enters the picture.
final class LiveCallDetectorTests: XCTestCase {

    // MARK: - Initial snapshot semantics

    /// A call already connected when the detector is created: no initial
    /// onChange, but `hasActiveCall` reads true immediately (the
    /// coordinator's banner needs that).
    func testNoInitialCallbackWhenAlreadyActive() {
        let provider = FakeCallStateProvider()
        provider.hasActiveCall = true
        var events: [Bool] = []
        let detector = LiveCallDetector(provider: provider) { events.append($0) }

        XCTAssertTrue(detector.hasActiveCall)
        XCTAssertTrue(events.isEmpty,
                      "an already-active call must not fire a phantom initial callback")
    }

    /// Idle at construction → no callback either, flag false.
    func testNoInitialCallbackWhenIdle() {
        let provider = FakeCallStateProvider()
        var events: [Bool] = []
        let detector = LiveCallDetector(provider: provider) { events.append($0) }

        XCTAssertFalse(detector.hasActiveCall)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Transitions

    func testFiresOnTransitionToActive() {
        let provider = FakeCallStateProvider()
        var events: [Bool] = []
        let detector = LiveCallDetector(provider: provider) { events.append($0) }
        XCTAssertFalse(detector.hasActiveCall)

        provider.hasActiveCall = true
        provider.simulateChange()

        XCTAssertTrue(detector.hasActiveCall)
        XCTAssertEqual(events, [true])
    }

    func testFiresOnTransitionToInactive() {
        let provider = FakeCallStateProvider()
        provider.hasActiveCall = true
        var events: [Bool] = []
        let detector = LiveCallDetector(provider: provider) { events.append($0) }
        XCTAssertTrue(detector.hasActiveCall)

        provider.hasActiveCall = false
        provider.simulateChange()

        XCTAssertFalse(detector.hasActiveCall)
        XCTAssertEqual(events, [false])
    }

    // MARK: - Edge-triggering (no duplicates)

    /// A stream of system callChanged events that do NOT change the
    /// active state (e.g. a second call joins an active one) must not
    /// re-fire onChange.
    func testRepeatedSameStateDoesNotFire() {
        let provider = FakeCallStateProvider()
        var events: [Bool] = []
        let detector = LiveCallDetector(provider: provider) { events.append($0) }

        // False → true (fires once) …
        provider.hasActiveCall = true
        provider.simulateChange()
        // … then "still true" updates — no repeats.
        provider.hasActiveCall = true
        provider.simulateChange()
        provider.simulateChange()
        // True → false (fires once) …
        provider.hasActiveCall = false
        provider.simulateChange()
        // … then "still false" updates — no repeats.
        provider.simulateChange()
        provider.hasActiveCall = false
        provider.simulateChange()

        XCTAssertEqual(events, [true, false])
    }

    // MARK: - Long-lived detector

    /// A detector that saw a full call cycle reports the pair and ends
    /// idle — the coordinator's lifecycle.
    func testFullCycleActiveThenInactive() {
        let provider = FakeCallStateProvider()
        var events: [Bool] = []
        let detector = LiveCallDetector(provider: provider) { events.append($0) }

        provider.hasActiveCall = true
        provider.simulateChange()
        provider.hasActiveCall = false
        provider.simulateChange()

        XCTAssertEqual(events, [true, false])
        XCTAssertFalse(detector.hasActiveCall)
    }

    // MARK: - Unanswered-call propagation (missed-calls task, 2026-09-07)

    /// Every provider unanswered event reaches `onUnanswered` with its
    /// end-observation moment intact — the coordinator records one
    /// anonymous row per delivered event.
    func testPropagatesUnansweredEndsWithTimestamps() {
        let provider = FakeCallStateProvider()
        var events: [Date] = []
        let detector = LiveCallDetector(provider: provider,
                                        onUnanswered: { events.append($0) })
        let firstEnd = Date(timeIntervalSince1970: 1000)
        let secondEnd = Date(timeIntervalSince1970: 2000)

        provider.simulateUnansweredEnd(at: firstEnd)
        provider.simulateUnansweredEnd(at: secondEnd)

        XCTAssertEqual(events, [firstEnd, secondEnd])
    }

    /// The unanswered channel stays inert when no handler is registered —
    /// the coordinator's existing callers (no onUnanswered) keep working.
    func testUnansweredWithoutHandlerDoesNothing() {
        let provider = FakeCallStateProvider()
        var events: [Bool] = []
        let detector = LiveCallDetector(provider: provider) { events.append($0) }

        provider.simulateUnansweredEnd(at: Date(timeIntervalSince1970: 42))

        XCTAssertEqual(events, [])
        XCTAssertFalse(detector.hasActiveCall)
    }

    /// Unanswered events and active-state transitions are independent
    /// channels: a call that ends unanswered never toggles the active
    /// flag, and an answered call's transitions never emit an unanswered
    /// event (the provider decides what each callChanged means).
    func testUnansweredDoesNotDisturbActiveStateTracking() {
        let provider = FakeCallStateProvider()
        var activeEvents: [Bool] = []
        var unansweredEvents: [Date] = []
        let detector = LiveCallDetector(provider: provider,
                                        onChange: { activeEvents.append($0) },
                                        onUnanswered: { unansweredEvents.append($0) })

        // A call rings, connects, and later ends — active only.
        provider.hasActiveCall = true
        provider.simulateChange()
        provider.hasActiveCall = false
        provider.simulateChange()
        // A separate call ends unanswered — unanswered only.
        provider.simulateUnansweredEnd(at: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(activeEvents, [true, false])
        XCTAssertEqual(unansweredEvents, [Date(timeIntervalSince1970: 5)])
    }
}

/// The once-per-call unanswered gate behind `CXCallStateProvider`
/// (missed-calls task, 2026-09-07). CallKit cannot be driven by unit
/// tests — CXCall has no public initializer — so the provider's only
/// stateful decision lives in `UnansweredCallTracker` and is exercised
/// here directly: a call reports exactly when its FIRST ended-without-
/// ever-connected observation arrives, once per call, never for a call
/// that connected, never for a merely-ringing update.
final class UnansweredCallTrackerTests: XCTestCase {

    /// Ended-without-connected fires once per call: the first terminal
    /// observation reports; the same call re-delivered is the same
    /// event, and a DIFFERENT call reports again.
    func testFiresOncePerEndedWithoutConnectedCall() {
        let tracker = UnansweredCallTracker()
        let firstCall = UUID()
        let secondCall = UUID()

        XCTAssertTrue(tracker.isNewUnanswered(uuid: firstCall,
                                              hasEnded: true, hasConnected: false))
        XCTAssertFalse(tracker.isNewUnanswered(uuid: firstCall,
                                               hasEnded: true, hasConnected: false),
                       "re-delivering the same call's terminal state must not double-fire")
        XCTAssertTrue(tracker.isNewUnanswered(uuid: secondCall,
                                              hasEnded: true, hasConnected: false),
                      "a second unanswered call is a second event")
    }

    /// Connected-then-ended does NOT fire: `hasConnected` is sticky, so
    /// an answered call's end arrives with the flag still true — the
    /// one state shape that must never report.
    func testConnectedThenEndedNeverReports() {
        let tracker = UnansweredCallTracker()

        XCTAssertFalse(tracker.isNewUnanswered(uuid: UUID(),
                                               hasEnded: true, hasConnected: true))
    }

    /// A merely-ringing update (not yet ended) never reports — the
    /// event is terminal-state only.
    func testRingingUpdateNeverReports() {
        let tracker = UnansweredCallTracker()

        XCTAssertFalse(tracker.isNewUnanswered(uuid: UUID(),
                                               hasEnded: false, hasConnected: false))
        XCTAssertFalse(tracker.isNewUnanswered(uuid: UUID(),
                                               hasEnded: false, hasConnected: true))
    }

    /// Repeated same-state deliveries of the SAME call never double-fire,
    /// however many times the system re-reports the end.
    func testRepeatedSameStateDoesNotDoubleFire() {
        let tracker = UnansweredCallTracker()
        let uuid = UUID()

        XCTAssertTrue(tracker.isNewUnanswered(uuid: uuid,
                                              hasEnded: true, hasConnected: false))
        for _ in 0..<5 {
            XCTAssertFalse(tracker.isNewUnanswered(uuid: uuid,
                                                   hasEnded: true, hasConnected: false))
        }
    }
}

/// The app-initiated-call attribution gate (call-tracking task,
/// 2026-09-13). Same reason to be pure and testable as
/// `UnansweredCallTracker`: the coordinator's init boots the voice stack,
/// so the decision — may this anonymous unanswered event carry the
/// contact the app just dialed? — is driven here directly.
final class OpenedCallAttributorTests: XCTestCase {

    private let dialedAt = Date(timeIntervalSince1970: 10_000)

    private func attributorWithPendingCall() -> OpenedCallAttributor {
        let attributor = OpenedCallAttributor()
        attributor.recordOpenedCall(name: "बुबा", phone: "9812345678", at: dialedAt)
        return attributor
    }

    /// The one case the app can prove: it opened a call to a contact, and
    /// a call ended without ever connecting inside the window — the row
    /// gets the contact the app itself dialed.
    func testAttributesAnUnansweredEndInsideTheWindow() {
        let attributor = attributorWithPendingCall()

        let opened = attributor.attributedMissedCall(endedAt: dialedAt.addingTimeInterval(45))
        XCTAssertEqual(opened?.name, "बुबा")
        XCTAssertEqual(opened?.phone, "9812345678")
    }

    /// The window is narrow on purpose: an unanswered event later than
    /// `window` after the dial is not that dial's outcome, so it stays
    /// anonymous rather than naming the wrong caller. The horizon itself
    /// is inclusive — an event landing exactly at it is still the call
    /// just placed.
    func testAttributesAtTheHorizonAndRefusesBeyondIt() {
        let atHorizon = attributorWithPendingCall()
        XCTAssertNotNil(atHorizon.attributedMissedCall(
            endedAt: dialedAt.addingTimeInterval(OpenedCallAttributor.window)))

        let beyond = attributorWithPendingCall()
        XCTAssertNil(beyond.attributedMissedCall(
            endedAt: dialedAt.addingTimeInterval(OpenedCallAttributor.window + 1)))
    }

    /// Nothing opened → nothing to attribute, whatever the timing.
    func testRefusesWithNothingPending() {
        let attributor = OpenedCallAttributor()

        XCTAssertNil(attributor.attributedMissedCall(endedAt: dialedAt))
    }

    /// An end that precedes the open (clock skew, or an event delivered
    /// out of order) is never attributed.
    func testRefusesAnEndBeforeTheOpen() {
        let attributor = attributorWithPendingCall()

        XCTAssertNil(attributor.attributedMissedCall(endedAt: dialedAt.addingTimeInterval(-1)))
    }

    /// A connected call clears the candidate: something was answered, so a
    /// later unanswered event cannot honestly be pinned on the dial.
    func testConnectedCallClearsTheCandidate() {
        let attributor = attributorWithPendingCall()
        attributor.noteCallConnected()

        XCTAssertNil(attributor.attributedMissedCall(endedAt: dialedAt.addingTimeInterval(30)))
    }

    /// An unanswered end consumes the candidate — the same event can never
    /// be attributed twice, and a later unrelated end is not credited to
    /// the same dial.
    func testAttributionIsConsumedOnce() {
        let attributor = attributorWithPendingCall()

        XCTAssertNotNil(attributor.attributedMissedCall(endedAt: dialedAt.addingTimeInterval(30)))
        XCTAssertNil(attributor.attributedMissedCall(endedAt: dialedAt.addingTimeInterval(40)))
    }

    /// One candidate at a time: a newer open replaces an older one, so the
    /// row names the call the user most recently placed.
    func testNewestOpenWins() {
        let attributor = attributorWithPendingCall()
        let secondDialAt = dialedAt.addingTimeInterval(60)
        attributor.recordOpenedCall(name: "सीता", phone: "9800000000", at: secondDialAt)

        let opened = attributor.attributedMissedCall(endedAt: secondDialAt.addingTimeInterval(20))
        XCTAssertEqual(opened?.name, "सीता")
    }

    /// An open with no number can never be matched, so it records no
    /// candidate — the next end stays anonymous.
    func testOpenWithoutANumberNeverBecomesACandidate() {
        let attributor = OpenedCallAttributor()
        attributor.recordOpenedCall(name: "बुबा", phone: "", at: dialedAt)

        XCTAssertNil(attributor.attributedMissedCall(endedAt: dialedAt.addingTimeInterval(10)))
    }
}

/// Fake `CallStateProviding` — a mutable flag plus the registered
/// listeners, driven manually by the test.
private final class FakeCallStateProvider: CallStateProviding {
    var hasActiveCall = false
    private var listener: (() -> Void)?
    private var unansweredListener: ((Date) -> Void)?

    func addChangeListener(_ listener: @escaping () -> Void) {
        self.listener = listener
    }

    func addUnansweredListener(_ listener: @escaping (Date) -> Void) {
        self.unansweredListener = listener
    }

    /// The system reported a call-state change — run the listener exactly
    /// as `CXCallStateProvider` would.
    func simulateChange() {
        listener?()
    }

    /// The system reported a call that ended without ever connecting —
    /// run the unanswered listeners exactly as `CXCallStateProvider`
    /// does after its tracker accepts the event.
    func simulateUnansweredEnd(at date: Date = Date()) {
        unansweredListener?(date)
    }
}
