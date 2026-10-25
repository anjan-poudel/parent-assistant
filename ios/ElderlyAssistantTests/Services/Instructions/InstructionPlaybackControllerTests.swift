import AVFoundation
import XCTest
@testable import ElderlyAssistant

/// T-017 — the playback controller's policy (design L2 §2.6, §8.1, §9.1,
/// §11.3 I; FR-RIE-018, FR-RIE-020, FR-RIE-024, NFR-RIE-008, NFR-RIE-009).
///
/// Strategy. Every wait is an injected deadline: `ManualDeadlineScheduler`
/// records the interval and fires on demand, so no test sleeps, polls or
/// waits on a run loop. The adapter is a spy that scripts the seam events
/// (and can replay them after close through the callback it captured before
/// dismissal), while `ManualPlaybackClock` makes `duration_ms` an exact
/// injected-now delta. The emitter is the real `InstructionObservability`
/// over a recording bus, so the suite asserts the shipped event shape
/// rather than a mock of it.
///
/// The thirteen planned cases appear exactly once. Timer ownership is
/// pinned inside `testCloseCancelsBothDeadlines`: the AVKit adapter source
/// carries no timer token, and `InstructionPlayback.swift` is the only file
/// that arms the two deadlines (P-1).
@MainActor
final class InstructionPlaybackControllerTests: XCTestCase {

    private static let playbackURL = URL(
        fileURLWithPath: "/tmp/instruction-playback-controller-tests/video.mov"
    )

    // MARK: - Context and helpers

    /// One fresh, fully isolated controller world: a recording bus, a manual
    /// deadline factory, a manual clock and the adapter spy. Building a new
    /// context per test (rather than sharing stored state) keeps every case
    /// order-independent.
    private struct PlaybackContext {
        let bus: PlaybackRecordingBus
        let scheduler: ManualDeadlineScheduler
        let clock: ManualPlaybackClock
        let spy: InstructionPlaybackSpy
        let controller: InstructionPlaybackController

        var events: [ObservabilityEvent] { bus.events(named: "instruction_playback") }
    }

    private func makeContext(
        configuration: InstructionPlaybackConfiguration = .standard
    ) -> PlaybackContext {
        let bus = PlaybackRecordingBus()
        let scheduler = ManualDeadlineScheduler()
        let clock = ManualPlaybackClock()
        let spy = InstructionPlaybackSpy()
        let controller = InstructionPlaybackController(
            url: Self.playbackURL,
            title: "Instruction",
            player: spy,
            configuration: configuration,
            events: InstructionObservability(bus: bus),
            deadlineFactory: scheduler,
            now: { [clock] in clock.now }
        )
        return PlaybackContext(bus: bus, scheduler: scheduler, clock: clock,
                               spy: spy, controller: controller)
    }

    private var controllerSourceURL: URL {
        FeatureSourceScan.iosDirectory()
            .appendingPathComponent(
                "ElderlyAssistant/Services/Instructions/InstructionPlayback.swift"
            )
    }

    private var adapterSourceURL: URL {
        FeatureSourceScan.iosDirectory()
            .appendingPathComponent(
                "ElderlyAssistant/Services/Instructions/AVKitInstructionVideoPlayer.swift"
            )
    }

    /// The lines of one function body from comment-stripped source, so an
    /// ordering claim can assert statement order (the §11.3 E idiom).
    private func functionBody(named signature: String, in code: String) -> [String]? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            return nil
        }
        let end = lines[(start + 1)...].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("func ") || trimmed.hasPrefix("private func ")
                || trimmed.hasPrefix("deinit")
        } ?? lines.count
        return Array(lines[(start + 1)..<end])
    }

    /// Reads the controller's stored `url` through reflection. `URL` is a
    /// value type, so reflection is the only observation point that does not
    /// add a test-only accessor to the production type. An `Optional` mirror
    /// with no child is `nil`; with one child it is the retained URL.
    private func reflectedURL(of controller: InstructionPlaybackController) -> URL? {
        guard let child = Mirror(reflecting: controller).children
            .first(where: { $0.label == "url" }) else {
            XCTFail("InstructionPlaybackController must store the playback URL")
            return nil
        }
        let optional = Mirror(reflecting: child.value)
        if let value = optional.children.first?.value as? URL {
            return value
        }
        return nil
    }

    // MARK: - Planned cases (T-017 named-test list)

    /// Scenario "Playback starts only on an explicit start": creation does
    /// nothing observable; `start()` presents once; a passed preflight moves
    /// toward ready and arms the watchdog (FR-RIE-018).
    func testStartIsRequiredForPlayback() {
        let ctx = makeContext()

        // Creation: no preflight, no player, no deadline, no event.
        XCTAssertEqual(ctx.controller.state, .idle)
        XCTAssertNil(ctx.controller.player)
        XCTAssertEqual(ctx.spy.presentCount, 0, "no adapter call before the tap")
        XCTAssertEqual(ctx.spy.dismissCount, 0)
        XCTAssertNil(ctx.spy.capturedOnEvent)
        XCTAssertEqual(ctx.scheduler.intervals, [])
        XCTAssertTrue(ctx.events.isEmpty)

        ctx.controller.start()

        XCTAssertEqual(ctx.spy.presentCount, 1, "start presents exactly once")
        XCTAssertEqual(ctx.scheduler.intervals, [0.6], "the preflight bound is armed")
        XCTAssertEqual(ctx.controller.state, .preflighting)
        XCTAssertTrue(ctx.events.isEmpty, "preflighting emits no playback event")

        // start is idempotent (design §2.6.1).
        ctx.controller.start()
        XCTAssertEqual(ctx.spy.presentCount, 1, "a second start never re-presents")
        XCTAssertEqual(ctx.scheduler.intervals, [0.6], "a second start arms no timer")

        // A passed preflight cancels the bound and proceeds toward ready.
        ctx.spy.emit(.preflightPassed)
        XCTAssertEqual(ctx.controller.state, .preparing)
        XCTAssertEqual(ctx.scheduler.intervals, [0.6, 10],
                       "the ready watchdog is armed after preflight")
        XCTAssertEqual(ctx.scheduler.tokens[0].cancelCount, 1)

        ctx.spy.emit(.ready)
        XCTAssertEqual(ctx.controller.state, .ready)
        XCTAssertNotNil(ctx.controller.player)
        XCTAssertEqual(ctx.scheduler.liveCount, 0, "ready cancels the watchdog")
        XCTAssertEqual(ctx.events.map(\.outcome), ["ready"])
    }

    /// Scenario "A preflight that never answers is bounded": the 0.6 s bound
    /// fails with `.unsupported`, one fallback line and a safe close
    /// (design §9.1).
    func testPreflightTimeoutAt600Milliseconds() {
        XCTAssertEqual(InstructionPlaybackConfiguration.standard.preflightTimeoutSeconds, 0.6)

        let ctx = makeContext()
        ctx.controller.start()
        XCTAssertEqual(ctx.scheduler.intervals, [0.6])

        ctx.clock.advance(by: 0.6)
        ctx.scheduler.fire(0)

        XCTAssertEqual(ctx.controller.state, .failed(.unsupported))
        XCTAssertEqual(ctx.scheduler.liveCount, 0, "the expired deadline is gone")
        XCTAssertEqual(ctx.spy.dismissCount, 1, "failure dismisses the adapter")
        XCTAssertNil(ctx.controller.player)

        XCTAssertEqual(ctx.events.count, 1)
        let event = ctx.events.first
        XCTAssertEqual(event?.component, "instruction_playback")
        XCTAssertEqual(event?.eventType, "instruction_playback")
        XCTAssertEqual(event?.outcome, "failed")
        XCTAssertEqual(event?.errorCode, "unsupported")
        XCTAssertEqual(event?.durationMs, 600)
        XCTAssertEqual(event?.metadata, [:])

        // The surface's one fallback line is the key mapping; no player
        // existed, so close is safe and emits nothing further.
        XCTAssertEqual(InstructionMessageKey.forPlayback(.unsupported),
                       "instruction.video.unavailable")
        ctx.controller.close()
        XCTAssertEqual(ctx.controller.state, .closed)
        XCTAssertEqual(ctx.events.count, 1, "a close without a player emits nothing")
    }

    /// Scenario "A ready signal that never arrives is not the same as a
    /// failure": preflight passed, no ready, 10 s later `.timedOut` with
    /// exactly one event (design §8.1, §9.1).
    func testReadyWatchdogAt10Seconds() {
        XCTAssertEqual(InstructionPlaybackConfiguration.standard.readyWatchdogSeconds, 10)

        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        XCTAssertEqual(ctx.controller.state, .preparing)
        XCTAssertEqual(ctx.scheduler.intervals, [0.6, 10])

        ctx.clock.advance(by: 10)
        ctx.scheduler.fire(1)

        XCTAssertEqual(ctx.controller.state, .failed(.timedOut))
        XCTAssertEqual(ctx.scheduler.liveCount, 0)
        XCTAssertEqual(ctx.spy.dismissCount, 1)

        XCTAssertEqual(ctx.events.count, 1,
                       "exactly one instruction_playback event records the timeout")
        let event = ctx.events.first
        XCTAssertEqual(event?.outcome, "failed")
        XCTAssertEqual(event?.errorCode, "timed_out")
        XCTAssertEqual(event?.durationMs, 10_000)
    }

    /// The watchdog is a responsiveness ceiling, not failure detection: a
    /// slow ready inside the window is accepted and nothing was labelled
    /// failed before it expired (design §8.1).
    func testWatchdogIsNotEarlyFailureDetection() {
        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        XCTAssertEqual(ctx.controller.state, .preparing)
        XCTAssertEqual(ctx.scheduler.intervals, [0.6, 10],
                       "the ceiling is 10 s, not a shorter failure probe")

        // Time passing alone is not a failure.
        ctx.clock.advance(by: 9.5)
        XCTAssertEqual(ctx.controller.state, .preparing)
        XCTAssertTrue(ctx.events.isEmpty)

        // A ready at 9.5 s is a normal success.
        ctx.spy.emit(.ready)
        XCTAssertEqual(ctx.controller.state, .ready)
        XCTAssertEqual(ctx.events.map(\.outcome), ["ready"])
        XCTAssertNil(ctx.events.first?.errorCode)
        XCTAssertEqual(ctx.scheduler.liveCount, 0, "ready cancels the watchdog")

        // Even a cancelled watchdog firing late cannot fail a ready session.
        ctx.scheduler.fire(1)
        XCTAssertEqual(ctx.controller.state, .ready)
        XCTAssertEqual(ctx.events.count, 1)
    }

    /// Scenario "A late event after close is ignored": ready, finished or a
    /// second preflight after close changes nothing, emits nothing and
    /// leaves no timer (design §2.6.3).
    func testLateReadyAfterCloseIgnored() {
        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        ctx.spy.emit(.ready)
        XCTAssertEqual(ctx.controller.state, .ready)

        let late = ctx.spy.capturedOnEvent
        XCTAssertNotNil(late, "the spy must hand over the seam callback")
        let eventsBeforeClose = ctx.events.count

        ctx.controller.close()
        XCTAssertEqual(ctx.controller.state, .closed)
        XCTAssertEqual(ctx.events.count, eventsBeforeClose + 1,
                       "a close after a player existed emits one closed outcome")

        late?(.ready)
        late?(.preflightPassed)
        late?(.finished)
        late?(.closed)

        XCTAssertEqual(ctx.controller.state, .closed, "state does not change")
        XCTAssertEqual(ctx.events.count, eventsBeforeClose + 1, "no event is emitted")
        XCTAssertEqual(ctx.scheduler.liveCount, 0, "no timer remains scheduled")
        XCTAssertNil(ctx.controller.player)
    }

    /// A failure delivered after close is ignored exactly like a late ready.
    func testLateFailureAfterCloseIgnored() {
        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        XCTAssertEqual(ctx.controller.state, .preparing)

        let late = ctx.spy.capturedOnEvent
        XCTAssertNotNil(late)
        ctx.controller.close()
        XCTAssertEqual(ctx.controller.state, .closed)
        XCTAssertEqual(ctx.events.map(\.outcome), ["closed"])

        late?(.failed(.playerFailed))
        late?(.failed(.interrupted))
        late?(.failed(.timedOut))
        late?(.failed(.unsupported))

        XCTAssertEqual(ctx.controller.state, .closed, "state does not change")
        XCTAssertEqual(ctx.events.map(\.outcome), ["closed"], "no event is emitted")
        XCTAssertEqual(ctx.scheduler.liveCount, 0, "no timer remains scheduled")
        XCTAssertEqual(ctx.spy.dismissCount, 1, "no second dismiss from a late event")
    }

    /// Scenario "Finished closes cleanly and does not loop": one finished
    /// state, no restart, no extra event from the finished seam event, and
    /// close releases the adapter once (design §3.5 timer contract).
    func testFinishedEmitsOnceAndStops() {
        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        ctx.clock.advance(by: 1)
        ctx.spy.emit(.ready)
        XCTAssertEqual(ctx.events.map(\.outcome), ["ready"])

        ctx.spy.emit(.finished)
        XCTAssertEqual(ctx.controller.state, .finished)
        XCTAssertEqual(ctx.spy.presentCount, 1, "playback does not restart")
        XCTAssertEqual(ctx.events.count, 1,
                       "the closed outcome vocabulary has no finished token")
        XCTAssertNotNil(ctx.controller.player, "the last frame stays available")
        XCTAssertEqual(ctx.scheduler.liveCount, 0)
        XCTAssertEqual(ctx.spy.dismissCount, 0,
                       "finished keeps the frame; close owns the release")

        // Duplicate and late seam events cannot restart or re-emit.
        ctx.spy.emit(.finished)
        ctx.spy.emit(.ready)
        ctx.spy.emit(.failed(.playerFailed))
        ctx.controller.start()
        XCTAssertEqual(ctx.controller.state, .finished)
        XCTAssertEqual(ctx.events.count, 1)
        XCTAssertEqual(ctx.spy.presentCount, 1, "start after finished is a no-op")

        // Close releases the adapter once and reports the closed outcome once.
        ctx.controller.close()
        XCTAssertEqual(ctx.controller.state, .closed)
        XCTAssertEqual(ctx.spy.dismissCount, 1)
        XCTAssertNil(ctx.controller.player)
        XCTAssertEqual(ctx.events.map(\.outcome), ["ready", "closed"])

        ctx.controller.close()
        XCTAssertEqual(ctx.spy.dismissCount, 1, "close is idempotent")
        XCTAssertEqual(ctx.events.count, 2, "a no-op close emits nothing")
    }

    /// Scenario "Close pauses before release" and the P-1 timer ownership:
    /// close cancels the preflight bound and the ready watchdog, fires a
    /// cancelled deadline as a no-op, and the adapter source owns no timer.
    func testCloseCancelsBothDeadlines() {
        // Scenario A: close after the preflight passed. The bound was
        // cancelled at the phase boundary; close must cancel the watchdog.
        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        XCTAssertEqual(ctx.scheduler.intervals, [0.6, 10])
        XCTAssertEqual(ctx.scheduler.tokens[0].cancelCount, 1)
        XCTAssertEqual(ctx.scheduler.liveCount, 1)

        ctx.controller.close()
        XCTAssertEqual(ctx.scheduler.tokens[1].cancelCount, 1,
                       "close cancels the ready watchdog")
        XCTAssertEqual(ctx.scheduler.liveCount, 0, "no deadline remains scheduled")
        XCTAssertEqual(ctx.controller.state, .closed)

        // Firing a cancelled deadline cannot change state or emit.
        let eventsAfterClose = ctx.events.count
        ctx.scheduler.fire(0)
        ctx.scheduler.fire(1)
        XCTAssertEqual(ctx.controller.state, .closed)
        XCTAssertEqual(ctx.events.count, eventsAfterClose)

        // Idempotent close: no second dismiss, no second event, no timer.
        let dismissesAfterFirstClose = ctx.spy.dismissCount
        ctx.controller.close()
        XCTAssertEqual(ctx.spy.dismissCount, dismissesAfterFirstClose)
        XCTAssertEqual(ctx.events.count, eventsAfterClose)
        XCTAssertEqual(ctx.scheduler.liveCount, 0)

        // Scenario B: close while still preflighting cancels the preflight
        // bound; the ready watchdog is never armed.
        let second = makeContext()
        second.controller.start()
        XCTAssertEqual(second.scheduler.intervals, [0.6])
        second.controller.close()
        XCTAssertEqual(second.scheduler.tokens[0].cancelCount, 1)
        XCTAssertEqual(second.scheduler.intervals, [0.6],
                       "no watchdog exists before preflight passes")
        second.scheduler.fire(0)
        XCTAssertEqual(second.controller.state, .closed)
        XCTAssertTrue(second.events.isEmpty,
                      "a close without a player emits nothing")

        // Timer ownership (P-1, T-017 source scan): the adapter owns no
        // timer of any kind; this controller file arms exactly the two
        // deadlines and nothing else schedules one.
        let adapterCode = FeatureSourceScan.codeText(of: adapterSourceURL)
        for token in ["Timer(", "DispatchSourceTimer", "Task.sleep", "asyncAfter"] {
            XCTAssertFalse(adapterCode.contains(token),
                           "the adapter owns no timer; found '\(token)'")
        }
        let controllerCode = FeatureSourceScan.codeText(of: controllerSourceURL)
        XCTAssertFalse(controllerCode.isEmpty)
        XCTAssertEqual(
            controllerCode.components(separatedBy: "deadlineFactory.schedule(").count - 1,
            2,
            "the controller owns exactly the preflight bound and the ready watchdog"
        )
        XCTAssertFalse(adapterCode.contains("deadlineFactory.schedule("),
                       "the adapter never schedules a deadline")
    }

    /// Scenario "Close pauses before release": the adapter receives dismiss
    /// while the controller still holds the player; only then is the player
    /// released (design §2.7.3, §2.6.4).
    func testCloseDismissesAdapterBeforeRelease() {
        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        ctx.spy.emit(.ready)
        XCTAssertNotNil(ctx.controller.player)

        var playerHeldAtDismiss: Bool?
        ctx.spy.onDismiss = { [weak controller = ctx.controller] in
            playerHeldAtDismiss = controller?.player != nil
        }

        ctx.controller.close()

        XCTAssertEqual(ctx.spy.dismissCount, 1, "the adapter receives dismiss")
        XCTAssertEqual(playerHeldAtDismiss, true,
                       "dismiss runs before the controller releases the player")
        XCTAssertNil(ctx.controller.player)
        XCTAssertEqual(ctx.controller.state, .closed)
        XCTAssertEqual(ctx.events.map(\.outcome), ["ready", "closed"])

        // Source pin: inside close(), dismiss precedes the release.
        let code = FeatureSourceScan.codeText(of: controllerSourceURL)
        guard let body = functionBody(named: "func close()", in: code) else {
            XCTFail("could not locate close() in InstructionPlayback.swift")
            return
        }
        guard let dismissLine = body.firstIndex(where: { $0.contains("adapter.dismiss()") }),
              let releaseLine = body.firstIndex(where: { $0.contains("player = nil") }) else {
            XCTFail("close() must dismiss the adapter and release the player")
            return
        }
        XCTAssertLessThan(dismissLine, releaseLine)
    }

    /// One `instruction_playback` event per terminal outcome, with
    /// `duration_ms` from the injected clock and the closed outcome
    /// vocabulary (design §6.4).
    func testOnePlaybackEventPerTransition() {
        let ctx = makeContext()
        ctx.controller.start()

        ctx.clock.advance(by: 0.25)
        ctx.spy.emit(.preflightPassed)
        XCTAssertTrue(ctx.events.isEmpty, "the phase boundary is not an outcome")

        ctx.clock.advance(by: 0.25)
        ctx.spy.emit(.ready)
        XCTAssertEqual(ctx.events.count, 1)
        guard let ready = ctx.events.first else {
            XCTFail("no ready event")
            return
        }
        XCTAssertEqual(ready.component, "instruction_playback")
        XCTAssertEqual(ready.eventType, "instruction_playback")
        XCTAssertEqual(ready.outcome, "ready")
        XCTAssertEqual(ready.durationMs, 500,
                       "duration_ms is the injected-now delta from start")
        XCTAssertNil(ready.errorCode)
        XCTAssertEqual(ready.metadata, [:])

        // A duplicate ready is one transition, not two events.
        ctx.spy.emit(.ready)
        XCTAssertEqual(ctx.events.count, 1)

        ctx.clock.advance(by: 0.5)
        ctx.spy.emit(.finished)
        XCTAssertEqual(ctx.events.count, 1,
                       "finished has no token in the closed outcome vocabulary")

        ctx.controller.close()
        XCTAssertEqual(ctx.events.count, 2)
        guard let closed = ctx.events.last else {
            XCTFail("no closed event")
            return
        }
        XCTAssertEqual(closed.outcome, "closed")
        XCTAssertEqual(closed.durationMs, 1_000)
        XCTAssertNil(closed.errorCode)

        ctx.controller.close()
        XCTAssertEqual(ctx.events.count, 2, "a no-op close emits nothing")

        // The failure path is the same shape: one failed event, then one
        // closed outcome for the session that had a player.
        let failing = makeContext()
        failing.controller.start()
        failing.spy.emit(.preflightPassed)
        failing.clock.advance(by: 0.5)
        let repeated = failing.spy.capturedOnEvent
        failing.spy.emit(.failed(.playerFailed))
        XCTAssertEqual(failing.events.map(\.outcome), ["failed"])
        XCTAssertEqual(failing.events.first?.durationMs, 500)
        repeated?(.failed(.playerFailed))
        XCTAssertEqual(failing.events.count, 1,
                       "a repeated failure is not a second transition")
        failing.controller.close()
        XCTAssertEqual(failing.events.map(\.outcome), ["failed", "closed"])
    }

    /// No retry after a failure: `start()` is a no-op, no late event is
    /// accepted, and the adapter is presented once (design §6.3).
    func testNoRetryOnFailure() {
        let ctx = makeContext()
        ctx.controller.start()
        ctx.spy.emit(.preflightPassed)
        let late = ctx.spy.capturedOnEvent

        ctx.spy.emit(.failed(.playerFailed))
        XCTAssertEqual(ctx.controller.state, .failed(.playerFailed))
        XCTAssertEqual(ctx.events.map(\.outcome), ["failed"])
        XCTAssertEqual(ctx.spy.presentCount, 1)
        XCTAssertEqual(ctx.spy.dismissCount, 1, "a failure dismisses the adapter once")
        XCTAssertNil(ctx.controller.player)

        ctx.controller.start()
        late?(.ready)
        late?(.finished)
        late?(.failed(.unsupported))
        XCTAssertEqual(ctx.controller.state, .failed(.playerFailed))
        XCTAssertEqual(ctx.spy.presentCount, 1, "start after a failure never retries")
        XCTAssertEqual(ctx.events.count, 1)

        // Close stays safe; the failed session may report its closed
        // outcome because a player had been presented.
        ctx.controller.close()
        XCTAssertEqual(ctx.controller.state, .closed)
        XCTAssertEqual(ctx.events.map(\.outcome), ["failed", "closed"])
        XCTAssertEqual(ctx.spy.presentCount, 1, "closing never retries")
    }

    /// The URL is held only until close and never appears in the one emitted
    /// event family or in a log (design §7.4, §6.4).
    func testURLNotRetainedAfterClose() {
        let ctx = makeContext()
        XCTAssertEqual(reflectedURL(of: ctx.controller), Self.playbackURL,
                       "the controller holds the URL only for the playback handoff")

        ctx.controller.start()
        XCTAssertEqual(ctx.spy.presentedURLs, [Self.playbackURL])
        ctx.spy.emit(.preflightPassed)
        ctx.spy.emit(.ready)

        ctx.controller.close()
        XCTAssertNil(reflectedURL(of: ctx.controller),
                     "close drops the URL so it is not retained")

        let urlText = Self.playbackURL.absoluteString
        let filename = Self.playbackURL.lastPathComponent
        for event in ctx.bus.allEvents {
            XCTAssertFalse(event.component.contains(urlText))
            XCTAssertFalse(event.eventType.contains(urlText))
            XCTAssertFalse(event.outcome.contains(urlText))
            XCTAssertFalse(event.errorCode?.contains(urlText) ?? false)
            for (key, value) in event.metadata {
                XCTAssertFalse(key.contains(filename))
                XCTAssertFalse(value.contains(filename))
            }
        }

        // The drop is written in the close path, and the controller never
        // logs (Services/Instructions is a Release-log-gate root).
        let code = FeatureSourceScan.codeText(of: controllerSourceURL)
        XCTAssertTrue(code.contains("url = nil"), "close drops the stored URL")
        for token in ["print(", "NSLog", "os_log", "Logger("] {
            XCTAssertFalse(code.contains(token),
                           "the controller must not log; found '\(token)'")
        }
    }

    /// Every playback failure renders the same single plain line; the
    /// controller emits one failed outcome carrying the §3.3 token and holds
    /// no copy of its own (design §3.3, §6.2, §6.7).
    func testFailureLineIsSingle() {
        let failures: [InstructionPlaybackFailure] = [
            .unsupported, .playerFailed, .interrupted, .timedOut
        ]
        for failure in failures {
            XCTAssertEqual(InstructionMessageKey.forPlayback(failure),
                           "instruction.video.unavailable",
                           "every playback failure renders the same one line")
        }

        // Adapter-reported failures map immediately and emit one outcome.
        let adapterFailures: [(InstructionPlaybackFailure, String)] = [
            (.unsupported, "unsupported"),
            (.playerFailed, "player_failed"),
            (.interrupted, "interrupted")
        ]
        for (failure, token) in adapterFailures {
            let ctx = makeContext()
            ctx.controller.start()
            ctx.spy.emit(.failed(failure))
            XCTAssertEqual(ctx.controller.state, .failed(failure))
            XCTAssertEqual(ctx.events.count, 1)
            XCTAssertEqual(ctx.events.first?.outcome, "failed")
            XCTAssertEqual(ctx.events.first?.errorCode, token)
        }

        // The watchdog's failure is the same one line and one event.
        let watchdog = makeContext()
        watchdog.controller.start()
        watchdog.spy.emit(.preflightPassed)
        watchdog.scheduler.fire(1)
        XCTAssertEqual(watchdog.controller.state, .failed(.timedOut))
        XCTAssertEqual(watchdog.events.count, 1)
        XCTAssertEqual(watchdog.events.first?.errorCode, "timed_out")

        // The controller holds no copy: the one line lives in the view's
        // key mapping, so a second sentence or a code cannot be added here.
        let code = FeatureSourceScan.codeText(of: controllerSourceURL)
        XCTAssertFalse(code.contains("instruction."), "services hold no copy")
        XCTAssertEqual(
            code.components(separatedBy: "events.playback(outcome: .failed").count - 1,
            1,
            "one failed emission site serves all four failures"
        )
    }
}

// MARK: - Fakes (design §11.4)

/// The scripted playback seam. It records `present`/`dismiss` and the URLs
/// it was handed, holds the callback so a test can replay late events after
/// close, and models the adapter contract that `.preflightPassed` means a
/// player exists while a preflight failure constructs nothing.
@MainActor
private final class InstructionPlaybackSpy: InstructionVideoPlaying {

    private(set) var renderablePlayer: AVPlayer?
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var presentedURLs: [URL] = []
    private(set) var capturedOnEvent: (@MainActor (InstructionPlaybackEvent) -> Void)?

    /// Runs inside `dismiss`, before the spy clears its own state, so the
    /// suite can observe the controller's player still being held.
    var onDismiss: (@MainActor () -> Void)?

    func present(url: URL,
                 onEvent: @escaping @MainActor (InstructionPlaybackEvent) -> Void) {
        presentCount += 1
        presentedURLs.append(url)
        capturedOnEvent = onEvent
    }

    func dismiss() {
        dismissCount += 1
        onDismiss?()
        renderablePlayer = nil
        capturedOnEvent = nil
    }

    /// Emits one seam event. `.preflightPassed` constructs the player, as
    /// the shipped adapter does before reporting it.
    func emit(_ event: InstructionPlaybackEvent) {
        if event == .preflightPassed, renderablePlayer == nil {
            renderablePlayer = AVPlayer()
        }
        capturedOnEvent?(event)
    }
}

/// A deadline that fires only when a test says so; it records whether the
/// controller cancelled it (P-1: both timers are the controller's alone).
@MainActor
private final class ManualDeadline: InstructionPlaybackDeadline {

    private(set) var cancelCount = 0
    private(set) var isFired = false

    var isLive: Bool { cancelCount == 0 && !isFired }

    func cancel() {
        cancelCount += 1
    }

    func markFired() {
        isFired = true
    }
}

/// The manual deadline factory. Every armed interval is recorded; firing is
/// synchronous on the main actor, so the suite needs no expectation, sleep
/// or run-loop turn.
@MainActor
private final class ManualDeadlineScheduler: InstructionPlaybackDeadlineScheduling {

    private struct Entry {
        let seconds: TimeInterval
        let fire: @MainActor () -> Void
        let token: ManualDeadline
    }

    private var entries: [Entry] = []

    var intervals: [TimeInterval] { entries.map(\.seconds) }
    var tokens: [ManualDeadline] { entries.map(\.token) }
    var liveCount: Int { entries.filter { $0.token.isLive }.count }

    func schedule(after seconds: TimeInterval,
                  onExpire: @escaping @MainActor () -> Void) -> InstructionPlaybackDeadline {
        let token = ManualDeadline()
        entries.append(Entry(seconds: seconds, fire: onExpire, token: token))
        return token
    }

    /// Fires the n-th armed deadline even if it was cancelled; the
    /// controller's phase guards are what make that a no-op.
    func fire(_ index: Int) {
        guard entries.indices.contains(index) else {
            XCTFail("no deadline was armed at index \(index)")
            return
        }
        let entry = entries[index]
        entry.token.markFired()
        entry.fire()
    }
}

/// A deterministic injected clock. It starts at the reference date so
/// `Date` arithmetic with 0.25/0.5/0.6/10 is exactly representable and
/// `duration_ms` assertions are exact, never wall-clock dependent.
private final class ManualPlaybackClock {

    private(set) var now: Date

    init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// The recording observability sink; assertions read the shipped event
/// struct without a second test-only event type.
private final class PlaybackRecordingBus: ObservabilityBus {

    private(set) var allEvents: [ObservabilityEvent] = []

    func emit(_ event: ObservabilityEvent) {
        allEvents.append(event)
    }

    func events(named eventType: String) -> [ObservabilityEvent] {
        allEvents.filter { $0.eventType == eventType }
    }
}
