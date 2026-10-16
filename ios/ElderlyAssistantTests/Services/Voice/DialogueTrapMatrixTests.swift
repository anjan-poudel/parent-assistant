import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// T-139 (TG-27) — the E3 trap matrix: one named test per trap row —
/// cancel, escape, barge-in, timeout, expiry, Talk mid-window, watchdog
/// mid-window and pipeline events mid-window. Every row runs against a
/// LIVE frame and must end it: a terminal resolution with no live frame
/// left behind, no half-open window once the hourglass has passed
/// (renewal refused, late hourglass landings dropped), and a second
/// resolve of the same outcome is a no-op on both event surfaces.
///
/// Pins carried by this suite: the pipeline-events row is the M-1 pin
/// (the mapper's guard covers `.awaitingSlotAnswer`), the Talk and
/// watchdog rows are the M-2 pins (window-state refusal + the
/// session-exit observer's supersession), and the corpus rows ride the
/// production funnel and the production-shaped seam (M-3).
///
/// Composition: the sanctioned closest-real wiring —
/// `AppCoordinator(profileStorage:)` + `CommandRouter(coordinator:)`
/// (`start()` cannot run in the unit host) — for every row that needs the
/// real funnel, observer, mapper or Talk entry; the expiry row uses a
/// mock coordinator over a REAL `DialogueManager` whose clock and window
/// are both injected (half-open boundary exercised exactly, no sleeps).
/// The timeout row fires the production-installed
/// `voiceSession.onSlotAnswerTimeout` callback (the exact function the
/// machine's hourglass invokes; the real coordinator's machine is a
/// non-injectable 45 s `let`, AppCoordinator.swift:211) and separately
/// injects the T-135 test clock into a bare machine to prove the
/// hourglass itself closes with nothing half-open — no sleeps anywhere.
@MainActor
final class DialogueTrapMatrixTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Fixtures

    private func slotFillDraft(defaultQuery: String = "भजन") throws -> DialogueFrame {
        let catalog = try DialogueOptionCatalog.load()
        let group = try XCTUnwrap(catalog.groupForMusicQuery(defaultQuery),
                                  "the shipped catalog must claim the pending query")
        return DialogueFrame.slotFill(
            candidates: DialogueCandidateBuilder.slotFillCandidates(from: group,
                                                                     catalog: catalog),
            defaultQuery: defaultQuery,
            domain: .music,
            activeCommand: nil,
            sourceTranscript: "भजन बजाऊ")
    }

    // MARK: - Worlds

    /// The real-composition world: the shipped coordinator + router with
    /// this file's doubles on the seams a trap row observes.
    private final class TrapRealWorld {
        let coordinator: AppCoordinator
        let bus: MockObservabilityBus
        let speaker: TrapRecordingSpeaker
        let opener: TrapLinkOpener
        let interpreter: TrapCountingInterpreter
        let router: CommandRouter

        init() {
            let bus = MockObservabilityBus()
            let speaker = TrapRecordingSpeaker()
            let opener = TrapLinkOpener()
            let interpreter = TrapCountingInterpreter()
            let coordinator = AppCoordinator(profileStorage: InMemoryProfileStorage())
            let router = CommandRouter(coordinator: coordinator,
                                       observabilityBus: bus,
                                       speaker: speaker,
                                       interpreter: interpreter,
                                       localToolLogStore: LocalToolLogStore(storage: GeminiInMemoryStorage()),
                                       youtubeLinkOpener: opener)
            self.coordinator = coordinator
            self.bus = bus
            self.speaker = speaker
            self.opener = opener
            self.interpreter = interpreter
            self.router = router
        }

        func events(named name: String) -> [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType == name }
        }
    }

    private func makeTrapWorld() -> TrapRealWorld {
        TrapRealWorld()
    }

    /// The expiry row's world: a mock coordinator over a REAL
    /// `DialogueManager` whose window AND clock are injected — the
    /// half-open deadline is exercised exactly, with no wall-clock waits.
    private final class TrapClockWorld {
        let coordinator: TrapMockCoordinator
        let bus: MockObservabilityBus
        let interpreter: TrapCountingInterpreter
        let opener: TrapLinkOpener
        let router: CommandRouter

        init(clock: TrapClock, window: TimeInterval = 4) {
            let bus = MockObservabilityBus()
            let coordinator = TrapMockCoordinator(
                manager: DialogueManager(answerWindowSeconds: window,
                                         now: { clock.now }))
            let interpreter = TrapCountingInterpreter()
            let opener = TrapLinkOpener()
            let router = CommandRouter(coordinator: coordinator,
                                       observabilityBus: bus,
                                       speaker: TrapRecordingSpeaker(),
                                       interpreter: interpreter,
                                       localToolLogStore: LocalToolLogStore(storage: GeminiInMemoryStorage()),
                                       youtubeLinkOpener: opener)
            self.coordinator = coordinator
            self.bus = bus
            self.interpreter = interpreter
            self.opener = opener
            self.router = router
        }
    }

    /// An injectable clock — the `DialogueManager(now:)` seam (L1 §20).
    private final class TrapClock {
        var now: Date
        init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
            self.now = now
        }
    }

    // MARK: - Shared E3 assertions

    /// The terminal triple after a row has ended the frame: no live frame,
    /// the window is closed and unrenewable (leaving the window cancels
    /// the slot timer), and the state is no longer a window state.
    private func assertNoHalfOpenWindow(_ coordinator: AppCoordinator,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertNil(coordinator.activeDialogueFrame,
                     "no live frame may be left behind", file: file, line: line)
        XCTAssertNotEqual(coordinator.voiceSession.state, .awaitingSlotAnswer,
                          "the window must be closed", file: file, line: line)
        XCTAssertFalse(coordinator.voiceSession.refreshSlotAnswerWindow(),
                       "leaving the window means the slot timer is cancelled and "
                       + "unrenewable — no half-open window", file: file, line: line)
    }

    /// Resolving twice is a no-op in every row: a second resolve of the
    /// same outcome must emit nothing, disturb nothing and crash nothing.
    private func assertResolveTwiceIsANoOp(_ world: TrapRealWorld,
                                           resolution: DialogueFrameResolution,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let console = captureConsole {
            world.coordinator.resolveDialogueFrame(resolution)
            drainMainQueue()
        }
        XCTAssertEqual(eventCount("dialogue_frame_resolved", in: console), 0,
                       "a second resolution of a cleared frame must be silent",
                       file: file, line: line)
        XCTAssertNil(world.coordinator.activeDialogueFrame, file: file, line: line)
        XCTAssertNotEqual(world.coordinator.voiceSession.state, .awaitingSlotAnswer,
                          file: file, line: line)
        XCTAssertFalse(world.coordinator.voiceSession.refreshSlotAnswerWindow(),
                       file: file, line: line)
    }

    /// A LATE hourglass landing after the window has already closed: the
    /// production-installed slot-timeout callback fires again and must be
    /// a no-op end to end (the machine's F6 still-open guard plus the
    /// funnel's no-frame guard) — nothing half-open survives the window.
    private func assertLateHourglassIsANoOp(_ world: TrapRealWorld,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let console = captureConsole {
            world.coordinator.voiceSession.onSlotAnswerTimeout?()
            drainMainQueue()
        }
        XCTAssertEqual(eventCount("dialogue_frame_resolved", in: console), 0,
                       "a late hourglass landing must not resolve anything",
                       file: file, line: line)
        XCTAssertNil(world.coordinator.activeDialogueFrame, file: file, line: line)
        XCTAssertNotEqual(world.coordinator.voiceSession.state, .awaitingSlotAnswer,
                          file: file, line: line)
    }

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "trap-matrix async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    // MARK: - Row 1: cancel

    /// E3 trap row "cancel": a cancel answer mid-window resolves the frame
    /// terminally (router-emitted, `cancelled`), closes the window, speaks
    /// one acknowledgement, and re-resolving is a no-op.
    func testE3TrapRowCancelEndsTheWindowTerminally() throws {
        let world = makeTrapWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let result = world.router.route(transcript: "रद्द")

        XCTAssertEqual(result, .unrecognised(transcript: "रद्द"))
        let resolved = world.events(named: "dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "cancelled")
        XCTAssertEqual(resolved.first?.component, "command_router")
        assertNoHalfOpenWindow(world.coordinator)
        XCTAssertEqual(world.interpreter.interpretCount, 0, "the ladder never ran")
        waitForDelivery()
        XCTAssertTrue(world.speaker.utterances.contains(L10n.str("dialogue.cancelled", locale: ne)))
        assertResolveTwiceIsANoOp(world, resolution: .cancelled)
        assertLateHourglassIsANoOp(world)
    }

    // MARK: - Row 2: escape

    /// E3 trap row "escape": the escape phrase resolves terminally
    /// (`escaped`) before any other reading, closes the window and is
    /// idempotent on re-resolve.
    func testE3TrapRowEscapeEndsTheWindowTerminally() throws {
        let world = makeTrapWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let result = world.router.route(transcript: "फेरि भन्छु")

        XCTAssertEqual(result, .unrecognised(transcript: "फेरि भन्छु"))
        let resolved = world.events(named: "dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "escaped")
        assertNoHalfOpenWindow(world.coordinator)
        XCTAssertEqual(world.interpreter.interpretCount, 0, "the ladder never ran")
        waitForDelivery()
        XCTAssertTrue(world.speaker.utterances.contains(L10n.str("dialogue.escape", locale: ne)))
        assertResolveTwiceIsANoOp(world, resolution: .escaped)
        assertLateHourglassIsANoOp(world)
    }

    // MARK: - Row 3: barge-in

    /// E3 trap row "barge-in": the strong command resolves the frame
    /// (`bargedIn`) and falls through to the UNALTERED ladder exactly once
    /// (B5's YouTube play request executes), leaving no half-open window.
    func testE3TrapRowBargeInEndsTheWindowTerminallyAndFallsThroughOnce() throws {
        let world = makeTrapWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let result = world.router.route(transcript: "युट्युबमा गीत चलाऊ")

        XCTAssertEqual(result, .unrecognised(transcript: "युट्युबमा गीत चलाऊ"))
        let resolved = world.events(named: "dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "bargedIn")
        assertNoHalfOpenWindow(world.coordinator)
        XCTAssertEqual(world.interpreter.interpretCount, 0)
        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "गीत")],
                       "the ladder executed the strong command exactly once")
        assertResolveTwiceIsANoOp(world, resolution: .bargedIn)
        assertLateHourglassIsANoOp(world)
    }

    // MARK: - Row 4: timeout

    /// E3 trap row "timeout": the answer window's hourglass (fired through
    /// the PRODUCTION-installed callback) resolves the frame `timedOut`
    /// through the coordinator funnel, silently (ADR-MTC-08), closing the
    /// window with nothing renewable. The machine-clock leg drives the
    /// T-135 test clock (1 s injected) to prove the hourglass itself
    /// closes to `.idle` with no half-open window — no sleeps.
    func testE3TrapRowTimeoutClosesTheWindowWithoutAHalfOpenHourglass() throws {
        let world = makeTrapWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))
        // Flush the bridge hops the window-open published (required no-ops
        // while the window is open) so the measured leg is the timeout's.
        drainMainQueue()

        let console = captureConsole {
            world.coordinator.voiceSession.onSlotAnswerTimeout?()
        }

        XCTAssertNil(world.coordinator.activeDialogueFrame,
                     "the timeout must resolve the frame as timed-out")
        XCTAssertEqual(world.coordinator.voiceSession.state, .idle,
                       "the window closes through the legal .idle edge")
        XCTAssertEqual(eventCount("dialogue_frame_resolved", in: console), 1)
        XCTAssertTrue(console.contains("[app_coordinator] dialogue_frame_resolved outcome=timedOut"),
                      "the coordinator owns the timedOut outcome (design-l2 §26)")
        XCTAssertFalse(world.coordinator.voiceSession.refreshSlotAnswerWindow(),
                       "no half-open window after the hourglass passes")
        // Silent by contract: the slot timeout speaks nothing.
        waitForDelivery()
        XCTAssertTrue(world.speaker.utterances.isEmpty)

        assertResolveTwiceIsANoOp(world, resolution: .timedOut)
        assertLateHourglassIsANoOp(world)

        // The hourglass itself on the injected test clock (the T-135 seam;
        // the wait pumps the runloop — no sleeps).
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        let fired = expectation(description: "slot hourglass on the injected test clock")
        machine.onSlotAnswerTimeout = { fired.fulfill() }
        machine.transition(to: .idle)
        XCTAssertTrue(machine.openSlotAnswerWindow())
        wait(for: [fired], timeout: 3.0)
        XCTAssertEqual(machine.state, .idle,
                       "the expired window returns to idle through a legal edge")
        XCTAssertFalse(machine.refreshSlotAnswerWindow(),
                       "no half-open window after the injected hourglass")
    }

    // MARK: - Row 5: expiry

    /// E3 trap row "expiry": the frame's own hourglass runs on the
    /// injected manager clock. The deadline is half-open
    /// (`[arm, deadline)`), the expired frame is dropped before it can
    /// claim anything, a LATE utterance runs the ladder fresh (the window
    /// claims nothing — the interpreter sees it), and resolving the
    /// expired frame is a no-op at the manager.
    func testE3TrapRowExpiryDropsTheFrameBeforeItCanClaimALateAnswer() throws {
        let clock = TrapClock()
        let world = TrapClockWorld(clock: clock)
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let live = try XCTUnwrap(world.coordinator.activeDialogueFrame,
                                 "the row must run against a live frame")
        // The half-open boundary, exactly: live strictly before the
        // deadline, expired AT it (`now >= deadline`).
        XCTAssertFalse(live.isExpired(at: live.deadline.addingTimeInterval(-0.001)))
        XCTAssertTrue(live.isExpired(at: live.deadline),
                      "the window is half-open [arm, deadline)")
        clock.now = live.deadline.addingTimeInterval(-0.5)
        XCTAssertNotNil(world.coordinator.activeDialogueFrame, "still inside the window")

        clock.now = live.deadline.addingTimeInterval(0.1)
        XCTAssertNil(world.coordinator.activeDialogueFrame,
                     "the expired frame is dropped on read")
        XCTAssertNil(world.coordinator.manager.frame)
        XCTAssertTrue(world.coordinator.resolutions.isEmpty,
                      "an expired frame resolves nothing — it is simply not live")

        // The late utterance is a FRESH command: no dialogue telemetry, no
        // resolution, and the ladder receives it (interpreter counted).
        let result = world.router.route(transcript: "zebra quokka")
        XCTAssertEqual(result, .unrecognised(transcript: "zebra quokka"))
        XCTAssertTrue(world.coordinator.resolutions.isEmpty)
        XCTAssertTrue(world.bus.emittedEvents.allSatisfy { !$0.eventType.hasPrefix("dialogue_") },
                      "no dialogue telemetry may ride the fresh-command path")
        XCTAssertEqual(world.interpreter.interpretCount, 1,
                       "the late utterance reached the ladder — the expired window claimed nothing")

        // Idempotent disposal: a resolution after the expiry is a no-op.
        XCTAssertNil(world.coordinator.manager.resolve(.timedOut))
        XCTAssertTrue(world.coordinator.resolutions.isEmpty)
        XCTAssertTrue(world.opener.opened.isEmpty)
    }

    // MARK: - Row 6: Talk mid-window (M-2)

    /// E3 trap row "Talk mid-window" — an M-2 pin: the window states
    /// refuse the Talk long-press reset (`supportsTalkReset == false`), so
    /// the real `resetVoiceActivation()` entry is a guarded no-op that
    /// leaves the probe answerable; the hourglass still ends the frame
    /// terminally and nothing is left half-open.
    func testE3TrapRowTalkMidWindowIsRefusedAndTheHourglassStillEndsTheFrame() throws {
        let world = makeTrapWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))
        XCTAssertFalse(world.coordinator.voiceSession.state.supportsTalkReset,
                       "M-2: the slot window refuses the Talk reset by design")

        world.coordinator.resetVoiceActivation()   // the real Talk entry; guarded no-op

        XCTAssertNotNil(world.coordinator.activeDialogueFrame,
                        "the frame must survive a Talk press mid-window")
        XCTAssertEqual(world.coordinator.voiceSession.state, .awaitingSlotAnswer)
        XCTAssertTrue(world.coordinator.voiceSession.refreshSlotAnswerWindow(),
                      "the window must still be open after the refused Talk press")

        let console = captureConsole {
            world.coordinator.voiceSession.onSlotAnswerTimeout?()
        }
        XCTAssertEqual(eventCount("dialogue_frame_resolved", in: console), 1)
        XCTAssertTrue(console.contains("outcome=timedOut"))
        assertNoHalfOpenWindow(world.coordinator)
        assertResolveTwiceIsANoOp(world, resolution: .timedOut)
    }

    // MARK: - Row 7: watchdog mid-window (M-2)

    /// E3 trap row "watchdog mid-window" — an M-2 pin: the watchdog's work
    /// item fires only from `.listening`, so mid-window its landing is a
    /// no-op and cannot half-close the window; and its destructive
    /// consequence — the recycle's own `.stopped` flip — still leaves no
    /// orphan frame behind, because the session-exit observer supersedes a
    /// live frame through the funnel.
    func testE3TrapRowWatchdogMidWindowCannotOrphanTheFrame() throws {
        let world = makeTrapWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        // The fire condition (`armVoiceWatchdog`'s work item guards on
        // `.listening`) is false mid-window: a landing fire is a no-op.
        XCTAssertNotEqual(world.coordinator.voiceSession.state, .listening)

        // The private 60 s work item cannot be waited out; drive its
        // terminal consequence directly — the recycle's own `.stopped`
        // flip — and let M-2's observer answer for the frame.
        let console = captureConsole {
            world.coordinator.voiceSession.transition(to: .stopped)
            drainMainQueue()
        }
        XCTAssertEqual(eventCount("dialogue_frame_resolved", in: console), 1,
                       "the session exit must resolve the live frame exactly once")
        XCTAssertTrue(console.contains("outcome=superseded"),
                      "the funnel owns the superseded outcome (M-2)")
        XCTAssertNil(world.coordinator.activeDialogueFrame)
        XCTAssertEqual(world.coordinator.voiceSession.state, .stopped)
        XCTAssertFalse(world.coordinator.voiceSession.refreshSlotAnswerWindow(),
                       "no half-open window survives the watchdog's teardown")
        assertResolveTwiceIsANoOp(world, resolution: .superseded)
    }

    // MARK: - Row 8: pipeline events mid-window (M-1)

    /// E3 trap row "pipeline events mid-window" — the M-1 pin: every
    /// pipeline stage (the listen/idle stages included) bounces off the
    /// mapper's guard while `.awaitingSlotAnswer` owns the session, the
    /// frame stays answerable, the hourglass still ends it terminally, and
    /// the mapper keeps working outside the window (the guard is a window
    /// policy, not a mute).
    func testE3TrapRowPipelineEventsMidWindowAreDroppedAndTheHourglassEndsTheFrame() throws {
        let world = makeTrapWorld()
        let draft = try slotFillDraft()
        XCTAssertTrue(world.coordinator.startDialogueFrame(draft))

        let stages: [VoicePipeline.State] = [
            .idle, .stopped, .capturingCommand, .processing, .routing, .error("boom")
        ]
        for stage in stages {
            world.coordinator.handlePipelineState(stage)
            XCTAssertEqual(world.coordinator.voiceSession.state, .awaitingSlotAnswer,
                           "M-1: pipeline stage \(stage) closed the slot window mid-frame")
            XCTAssertEqual(world.coordinator.activeDialogueFrame?.id, draft.id,
                           "pipeline stage \(stage) disturbed the live frame")
            XCTAssertTrue(world.coordinator.voiceSession.refreshSlotAnswerWindow(),
                          "the slot window must still be open after \(stage)")
        }
        drainMainQueue()
        XCTAssertEqual(world.coordinator.activeDialogueFrame?.id, draft.id,
                       "the exit observer must not resolve a frame the guard protected")
        XCTAssertEqual(world.coordinator.voiceSession.state, .awaitingSlotAnswer)

        // The hourglass still ends the frame terminally.
        let console = captureConsole {
            world.coordinator.voiceSession.onSlotAnswerTimeout?()
        }
        XCTAssertEqual(eventCount("dialogue_frame_resolved", in: console), 1)
        XCTAssertTrue(console.contains("outcome=timedOut"))
        assertNoHalfOpenWindow(world.coordinator)
        assertResolveTwiceIsANoOp(world, resolution: .timedOut)

        // Control leg: outside the window the same mapper still maps —
        // `.capturingCommand` → `.listening`, `.processing` →
        // `.transcribing` — so the guard is a window policy, not a mute.
        world.coordinator.handlePipelineState(.capturingCommand)
        XCTAssertEqual(world.coordinator.voiceSession.state, .listening)
        world.coordinator.handlePipelineState(.processing)
        XCTAssertEqual(world.coordinator.voiceSession.state, .transcribing)
    }
}

// MARK: - Helpers (file-private copies of the W4 idioms)

extension DialogueTrapMatrixTests {

    /// Runs `body` with process stdout redirected to a temp file and
    /// returns what the bus printed (the W4 captureConsole idiom).
    fileprivate func captureConsole(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/dialogue-trap-sink-\(UUID().uuidString).log"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, descriptor >= 0 else {
            if descriptor >= 0 { close(descriptor) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)

        body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }

    fileprivate func eventCount(_ name: String, in console: String) -> Int {
        console.components(separatedBy: name).count - 1
    }

    /// Waits out the main-queue hops (the observer, the off-main funnels).
    fileprivate func drainMainQueue() {
        let done = expectation(description: "main drain")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
}

// MARK: - Doubles (file-private)

/// In-memory profile storage — the coordinator's init requirement.
private final class InMemoryProfileStorage: ProfilePayloadStorage {
    var payloads: [String: Data] = [:]
    private let encoder = JSONEncoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard let data = try? encoder.encode(value) else {
            return .failure(.encryptedWriteFailed)
        }
        payloads[key] = data
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        .failure(.encryptedReadFailed)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        payloads[key] = nil
        return .success(())
    }

    func readRawData(key: String) -> Data? { payloads[key] }
    func hasPayload(key: String) -> Bool? { payloads[key] != nil }
}

private final class TrapRecordingSpeaker: Speaker {
    private(set) var utterances: [String] = []
    func speak(_ text: String, locale: Locale) async {
        utterances.append(text)
    }
    func cancel() {}
}

private final class TrapLinkOpener: CallLinkOpening {
    private(set) var opened: [URL] = []
    func canOpenURL(_ url: URL) -> Bool { true }
    func open(_ url: URL) { opened.append(url) }
}

/// Counts interpreter consultations — the fresh-command witness on the
/// expiry row and the never-reached witness everywhere else.
private final class TrapCountingInterpreter: CommandInterpreter {
    private(set) var interpretCount = 0
    var isAvailable: Bool { true }
    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpretCount += 1
        DispatchQueue.main.async { completion(nil) }
    }
    func unload() {}
}

/// The expiry row's coordinator double: the six dialogue members are thin
/// adapters over a REAL `DialogueManager` (its window and clock injected),
/// so the deadline behaviour under test is the shipped one.
private final class TrapMockCoordinator: VoiceCommandCoordinating {
    let manager: DialogueManager

    init(manager: DialogueManager) {
        self.manager = manager
    }

    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    private(set) var resolutions: [DialogueFrameResolution] = []

    // MARK: The six dialogue members (§12.1)

    var activeDialogueFrame: DialogueFrame? { manager.liveFrame }

    func startDialogueFrame(_ frame: DialogueFrame) -> Bool {
        do {
            try manager.arm(frame)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func noteDialogueAttempt() -> Int {
        manager.noteAttempt()
    }

    func resolveDialogueFrame(_ resolution: DialogueFrameResolution) {
        manager.resolve(resolution)
        resolutions.append(resolution)
    }

    func clearDialogueFrame(reason: DialogueFrameResolution) {
        manager.resolve(reason)
        resolutions.append(reason)
    }

    /// Production-shaped even on the double: the T-127 helper through the
    /// production seam composition, never a nil-seam pass-through (M-3).
    func prepareDialogueAnswerText(_ raw: String) -> String {
        IntentTranscriptPreparation.prepare(
            raw,
            seam: IntentEncoderWiring.localSlotInputSeam(traceRecorder: nil)).prepared
    }

    // MARK: The base members the router's route() touches

    var medicationVoiceEntries: [MedicationEntry] { [] }
    var pendingRephraseCommand: InterpretedCommand? { nil }

    func recordTranscript(_ text: String) {}
    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
    func handleConfirmationResponse(_ response: ConfirmationResponse) {}
    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}
    func noteAssistantSpoke(_ text: String) {}
    func noteGenericReply(_ text: String) {}
    func fireNewsReader() {}
    func requestAppLaunch(appID: String, confidence: Double?) -> String { "launch line" }
    func addVoiceReminder(title: String, time: DateComponents) {}

    func requestCallConfirmation(contactQuery: String?, callType: String?,
                                 requestedApp: String?, sourceTranscript: String?,
                                 sourceCommand: InterpretedCommand?) -> String? { nil }

    func startRephraseConfirmation(_ command: InterpretedCommand,
                                   sourceTranscript: String?) {}

    func takePendingRephraseCommand()
        -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }

    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }

    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }

    func presentPluginView(_ view: AnyView) {}

    func requestContactSearch(query: String?) {}
}
