import XCTest
@testable import ElderlyAssistant

/// Edge-triggered live-call detection (call-history task, 2026-09-06):
/// `onChange` fires ONLY on a real transition of `hasActiveCall` — never
/// for an unchanged state, and never for the initial snapshot (a call
/// already active at construction reports via `hasActiveCall`, not a
/// callback). All tests drive a fake `CallStateProviding` — CallKit never
/// enters the picture.
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
}

/// Fake `CallStateProviding` — a mutable flag plus the registered
/// listener, driven manually by the test.
private final class FakeCallStateProvider: CallStateProviding {
    var hasActiveCall = false
    private var listener: (() -> Void)?

    func addChangeListener(_ listener: @escaping () -> Void) {
        self.listener = listener
    }

    /// The system reported a call-state change — run the listener exactly
    /// as `CXCallStateProvider` would.
    func simulateChange() {
        listener?()
    }
}
