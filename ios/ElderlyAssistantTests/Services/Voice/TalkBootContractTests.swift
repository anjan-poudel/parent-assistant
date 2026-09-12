import XCTest
@testable import ElderlyAssistant

/// [LAT-M1] Unit tests for background engine readiness telemetry
/// (`TalkBootContractState`). This contract measures warm/KWS settlement and
/// never gates manual Talk; `ManualTalkReadinessState` is published
/// independently. The state doctrine pinned here:
///
///  - every tracked feature settles as ready, skipped, or failed,
///  - a SKIP preserves the planner's honest reason and is not cold,
///  - a FAILED warm records an honest cold-feature classification,
///  - budget expiry alone does not settle an in-flight feature,
///  - the watchdog fails pending warm features but skips pending KWS,
///  - retry and late real outcomes can upgrade watchdog/failure states.
final class TalkBootBackgroundReadinessTests: XCTestCase {

    // MARK: - Helpers

    private func plan(_ steps: [WarmStartStep]) -> [WarmStartStep] { steps }

    private func step(_ engine: WarmStartEngine,
                      action: WarmStartAction = .warm,
                      phase: WarmStartPhase = .boot) -> WarmStartStep {
        WarmStartStep(engine: engine, action: action, phase: phase)
    }

    private func settleAllWarm(_ contract: inout TalkBootContractState) {
        contract.noteWarmOutcome(feature: .whisper, result: .ready)
        contract.noteWarmOutcome(feature: .primaryTTS, result: .ready)
        contract.noteWarmOutcome(feature: .llama, result: .ready)
    }

    // MARK: - Initial state

    func testInitialContractIsIncompleteWithEverythingPending() {
        let contract = TalkBootContractState()
        XCTAssertFalse(contract.isComplete)
        XCTAssertEqual(contract.pendingFeatures,
                       [.whisper, .primaryTTS, .llama, .kws])
        XCTAssertTrue(contract.coldFeatures.isEmpty)
    }

    // MARK: - Plan-time skips settle (simulator / stack / model policy)

    func testSkipActionsSettleTheirFeatures() {
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit, action: .skip(reason: "simulator")),
            step(.llamaInterpreter, action: .skip(reason: "simulator")),
            step(.ttsVoice(ModelCatalog.piperNepali),
                 action: .skip(reason: "simulator"), phase: .postBoot),
        ]) {
            contract.noteWarmPlanStep(step)
        }
        XCTAssertEqual(contract.statuses[.whisper], .skipped(reason: "simulator"))
        XCTAssertEqual(contract.statuses[.primaryTTS], .skipped(reason: "simulator"))
        XCTAssertEqual(contract.statuses[.llama], .skipped(reason: "simulator"))
        // KWS is still pending — the contract is NOT complete.
        XCTAssertFalse(contract.isComplete)
        XCTAssertEqual(contract.pendingFeatures, [.kws])
    }

    func testPreferenceOffSettlesWarmFeaturesWithoutBlocking() {
        var contract = TalkBootContractState()
        contract.settleUnplannedWarmFeatures()
        XCTAssertEqual(contract.statuses[.whisper],
                       .skipped(reason: TalkBootContractState.preferenceOffReason))
        XCTAssertEqual(contract.statuses[.primaryTTS],
                       .skipped(reason: TalkBootContractState.preferenceOffReason))
        XCTAssertEqual(contract.statuses[.llama],
                       .skipped(reason: TalkBootContractState.preferenceOffReason))
        // KWS remains independently pending in the telemetry.
        XCTAssertEqual(contract.pendingFeatures, [.kws])
    }

    // MARK: - Settlement completeness

    func testSettlementCompletesOnlyAfterEveryFeature() {
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit), step(.llamaInterpreter),
            step(.ttsVoice(ModelCatalog.piperNepali)),
        ]) {
            contract.noteWarmPlanStep(step)
        }
        contract.noteWarmOutcome(feature: .whisper, result: .ready)
        XCTAssertFalse(contract.isComplete)
        contract.noteWarmOutcome(feature: .primaryTTS, result: .ready)
        XCTAssertFalse(contract.isComplete)
        contract.noteWarmOutcome(feature: .llama, result: .ready)
        XCTAssertFalse(contract.isComplete, "KWS telemetry is still pending")
        contract.noteKWSApplied(isReal: true)
        XCTAssertEqual(contract.statuses[.whisper], .ready)
        XCTAssertEqual(contract.statuses[.primaryTTS], .ready)
        XCTAssertEqual(contract.statuses[.llama], .ready)
        XCTAssertEqual(contract.statuses[.kws], .ready)
        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.isSatisfied)
        XCTAssertTrue(contract.coldFeatures.isEmpty)
    }

    // MARK: - Honest cold-engine classification

    func testWarmFailureSettlesWithColdFeatureClassification() {
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit), step(.llamaInterpreter),
            step(.ttsVoice(ModelCatalog.piperNepali)),
        ]) {
            contract.noteWarmPlanStep(step)
        }
        contract.noteWarmOutcome(feature: .whisper,
                                 result: .failed(reason: "load_failed"))
        contract.noteWarmOutcome(feature: .primaryTTS, result: .ready)
        contract.noteWarmOutcome(feature: .llama, result: .ready)
        contract.noteKWSApplied(isReal: true)

        XCTAssertTrue(contract.isComplete)
        XCTAssertFalse(contract.isSatisfied)
        XCTAssertEqual(contract.statuses[.whisper],
                       .failed(reason: "load_failed"))
        XCTAssertEqual(contract.coldFeatures, [.whisper])
    }

    func testBudgetExpiryAloneDoesNotSettlePendingWarmWork() {
        // No budget transition exists in this pure state machine: without a
        // warm outcome or watchdog event, the feature remains pending.
        var contract = TalkBootContractState()
        for step in plan([step(.whisperKit)]) {
            contract.noteWarmPlanStep(step)
        }
        contract.noteKWSApplied(isReal: true)
        XCTAssertFalse(contract.isComplete)
        XCTAssertEqual(contract.pendingFeatures,
                       [.whisper, .primaryTTS, .llama])
        XCTAssertTrue(contract.coldFeatures.isEmpty)
    }

    func testTalkWatchdogFailsPendingWarmFeaturesButOnlySkipsKWS() {
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit), step(.llamaInterpreter),
            step(.ttsVoice(ModelCatalog.piperNepali)),
        ]) {
            contract.noteWarmPlanStep(step)
        }
        // The whisper warm hangs; KWS never built (pipeline stayed busy).
        contract.noteWarmOutcome(feature: .primaryTTS, result: .ready)
        contract.noteWarmOutcome(feature: .llama, result: .ready)
        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.isComplete)
        XCTAssertEqual(contract.statuses[.whisper],
                       .failed(reason: TalkBootContractState.watchdogReason))
        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.watchdogReason),
                       "pending KWS falls back to a non-failure Null classification")
        XCTAssertFalse(contract.isSatisfied)
        XCTAssertEqual(contract.coldFeatures, [.whisper])
    }

    func testNullKWSSettlesSatisfiedWithoutColdFeatures() {
        var contract = TalkBootContractState()
        settleAllWarm(&contract)
        contract.noteKWSApplied(isReal: false)

        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.isSatisfied,
                      "a Null wake-word engine is a settled non-failure skip")
        XCTAssertTrue(contract.coldFeatures.isEmpty)
        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.nullEngineReason))
    }

    // MARK: - Recovery upgrades

    func testRetryWarmOutcomeUpgradesAFailedFeature() {
        var contract = TalkBootContractState()
        contract.noteWarmOutcome(feature: .whisper, result: .ready)
        contract.noteWarmOutcome(feature: .primaryTTS, result: .ready)
        contract.noteWarmOutcome(feature: .llama,
                                 result: .failed(reason: "model_load_failed"))
        contract.noteKWSApplied(isReal: true)
        XCTAssertTrue(contract.isComplete)
        XCTAssertEqual(contract.coldFeatures, [.llama])

        // A retry re-runs the failed warm; success clears the cold-feature
        // classification honestly rather than via a timer.
        contract.noteWarmOutcome(feature: .llama, result: .ready)
        XCTAssertTrue(contract.isSatisfied)
        XCTAssertTrue(contract.coldFeatures.isEmpty)
    }

    func testLateRealSettleUpgradesWatchdogSkip() {
        var contract = TalkBootContractState()
        // Two warms settle normally; the whisper warm hangs past the
        // watchdog; the KWS build never landed.
        contract.noteWarmOutcome(feature: .primaryTTS, result: .ready)
        contract.noteWarmOutcome(feature: .llama, result: .ready)
        contract.noteTalkWatchdogExpired()
        XCTAssertEqual(contract.statuses[.whisper],
                       .failed(reason: TalkBootContractState.watchdogReason))
        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.watchdogReason))

        // The whisper warm landed late — the feature is genuinely warm now.
        contract.noteWarmOutcome(feature: .whisper, result: .ready)
        XCTAssertEqual(contract.statuses[.whisper], .ready)
        // KWS applies for real late too.
        contract.noteKWSApplied(isReal: true)
        XCTAssertEqual(contract.statuses[.kws], .ready)
        XCTAssertTrue(contract.isSatisfied)
    }

    func testSettledReadyIsStickyAcrossRePlans() {
        var contract = TalkBootContractState()
        settleAllWarm(&contract)
        contract.noteKWSApplied(isReal: true)
        XCTAssertTrue(contract.isSatisfied)

        // A retry re-plan re-asserts skip steps and re-feeds warm steps —
        // a satisfied feature must never downgrade.
        for step in plan([
            step(.whisperKit, action: .skip(reason: "simulator")),
            step(.llamaInterpreter, action: .skip(reason: "model_missing")),
        ]) {
            contract.noteWarmPlanStep(step)
        }
        contract.noteWarmOutcome(feature: .whisper,
                                 result: .failed(reason: "late_failure"))
        XCTAssertTrue(contract.isSatisfied,
                      "a ready feature sticks: re-plans and late outcomes cannot downgrade it")
    }

    func testSkipNeverDowngradesAReadyFeature() {
        var contract = TalkBootContractState()
        contract.noteWarmOutcome(feature: .whisper, result: .ready)
        contract.noteWarmPlanStep(
            step(.whisperKit, action: .skip(reason: "simulator")))
        XCTAssertEqual(contract.statuses[.whisper], .ready)
    }

    // MARK: - Feature mapping

    func testEngineFeatureMapping() {
        XCTAssertEqual(TalkBootContractState.feature(for: .whisperKit), .whisper)
        XCTAssertEqual(TalkBootContractState.feature(for: .whisperCpp), .whisper)
        XCTAssertEqual(TalkBootContractState.feature(
            for: .ttsVoice(ModelCatalog.piperEnglishUS)), .primaryTTS)
        XCTAssertEqual(TalkBootContractState.feature(for: .llamaInterpreter), .llama)
    }

    func testPostBootWarmDefensivelySkipsInsteadOfRemainingPending() {
        // The planner does not put primary TTS in the post-boot slot today;
        // pin the defensive settlement for hand-built or future plans.
        var contract = TalkBootContractState()
        contract.noteWarmPlanStep(step(
            .ttsVoice(ModelCatalog.piperNepali), phase: .postBoot))
        XCTAssertEqual(contract.statuses[.primaryTTS],
                       .skipped(reason: TalkBootContractState.postBootSlotReason))
    }


    // MARK: - Watchdog settlement

    func testTalkWatchdogBoundsTheWait() {
        // The watchdog remains a bounded telemetry settlement backstop and
        // outlives the normal boot warm budget.
        XCTAssertLessThanOrEqual(TalkBootContractState.talkWatchdogSeconds, 45,
                                 "background readiness must not remain pending for minutes")
        XCTAssertGreaterThan(TalkBootContractState.talkWatchdogSeconds,
                             WarmStartPlanner.bootWarmBudgetSeconds,
                             "the watchdog must outlive the boot warm budget")
    }

    // MARK: - Never-stuck guarantees ([CONTRACT-FIX])

    func testAllSilentPublishersSettleColdFeaturesAtWatchdog() {
        // No warm outcome or KWS settle arrives. The watchdog is the only
        // input and must settle every telemetry field.
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit), step(.llamaInterpreter),
            step(.ttsVoice(ModelCatalog.piperNepali)),
        ]) {
            contract.noteWarmPlanStep(step)
        }
        XCTAssertEqual(contract.pendingFeatures,
                       [.whisper, .primaryTTS, .llama, .kws])

        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.isComplete)
        XCTAssertEqual(contract.statuses[.whisper],
                       .failed(reason: TalkBootContractState.watchdogReason))
        XCTAssertEqual(contract.statuses[.primaryTTS],
                       .failed(reason: TalkBootContractState.watchdogReason))
        XCTAssertEqual(contract.statuses[.llama],
                       .failed(reason: TalkBootContractState.watchdogReason))
        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.watchdogReason),
                       "silent KWS falls back to a non-failure Null classification")
        XCTAssertFalse(contract.isSatisfied)
        XCTAssertEqual(contract.coldFeatures,
                       [.whisper, .primaryTTS, .llama])
    }

    func testKWSNoSignalAloneFallsBackToNullSkipNotFailure() {
        // The warms settle cleanly while KWS never emits. The watchdog records
        // KWS as a satisfied skip rather than a cold engine.
        var contract = TalkBootContractState()
        settleAllWarm(&contract)
        XCTAssertEqual(contract.pendingFeatures, [.kws])

        contract.noteTalkWatchdogExpired()

        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.watchdogReason))
        XCTAssertTrue(contract.isSatisfied,
                      "pending KWS settles to the Null classification")
        XCTAssertTrue(contract.coldFeatures.isEmpty)
    }

    func testNoInputsAtAllStillSettleAtWatchdog() {
        // Even when no plan was fed, the watchdog settles every tracked field.
        var contract = TalkBootContractState()
        XCTAssertEqual(contract.pendingFeatures,
                       [.whisper, .primaryTTS, .llama, .kws])

        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.pendingFeatures.isEmpty)
        XCTAssertEqual(contract.coldFeatures,
                       [.whisper, .primaryTTS, .llama])
    }

    func testPreferenceOffFullFlowSettlesSatisfiedOnceKWSApplies() {
        // Warm-start OFF classifies whisper/primaryTTS/llama as intentional
        // skips; the KWS outcome completes the telemetry cleanly.
        var contract = TalkBootContractState()
        contract.settleUnplannedWarmFeatures()
        XCTAssertEqual(contract.statuses[.whisper],
                       .skipped(reason: TalkBootContractState.preferenceOffReason))
        XCTAssertEqual(contract.statuses[.primaryTTS],
                       .skipped(reason: TalkBootContractState.preferenceOffReason))
        XCTAssertEqual(contract.statuses[.llama],
                       .skipped(reason: TalkBootContractState.preferenceOffReason))
        XCTAssertEqual(contract.pendingFeatures, [.kws])

        contract.noteKWSApplied(isReal: true)

        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.isSatisfied)
        XCTAssertTrue(contract.coldFeatures.isEmpty)
    }

    func testPreferenceOffWithSilentKWSStillSettlesAtWatchdog() {
        // Preference off plus a silent deferred KWS build settles the final
        // field as a watchdog skip.
        var contract = TalkBootContractState()
        contract.settleUnplannedWarmFeatures()

        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.isSatisfied,
                      "preference-off warms and silent KWS are settled skips")
        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.watchdogReason))
    }

    func testWatchdogDeadlineLeavesNothingPending() {
        // After the injected watchdog deadline, no publisher silence, warm
        // hang, or KWS wedge can leave telemetry pending.
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit), step(.llamaInterpreter),
            step(.ttsVoice(ModelCatalog.piperNepali)),
        ]) {
            contract.noteWarmPlanStep(step)
        }

        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.pendingFeatures.isEmpty,
                      "the deadline settles every tracked feature")
        XCTAssertTrue(contract.isComplete)
        var stillOpen = TalkBootContractState()
        for step in plan([step(.whisperKit)]) {
            stillOpen.noteWarmPlanStep(step)
        }
        XCTAssertFalse(stillOpen.isComplete,
                       "before the watchdog event, pending telemetry stays open")
    }

}

// MARK: - The watchdog seam ([CONTRACT-FIX])

/// The scheduler half of the settlement guarantee: the watchdog fires on its
/// own scheduler while the warm queue is occupied, retains the first deadline,
/// and can be cancelled.
final class TalkBootWatchdogTests: XCTestCase {

    /// A seam that NEVER reports — its warm occupies the serial warm
    /// queue's settle chain forever (the exact wedge the watchdog must
    /// survive).
    private final class NeverReportingSTTWarming: STTModelWarming {
        var isAvailable = true
        func warm(completion: ((WarmStartEngineResult) -> Void)?) {
            // Deliberately never calls back.
        }
    }

    func testWatchdogFiresOnItsOwnSchedulerWhileWarmQueueOccupied() {
        // The warm queue is occupied by a hung seam and runner timeout is off.
        // Only the watchdog's independent scheduler can settle the state.
        let warmQueue = DispatchQueue(label: "contractfix.test.warm")
        let watchdogQueue = DispatchQueue(label: "contractfix.test.watchdog")
        let runner = WarmStartRunner(
            stt: NeverReportingSTTWarming(), tts: nil, llm: nil,
            observabilityBus: MockObservabilityBus(),
            queue: warmQueue,
            stepTimeoutSeconds: 0)  // runner timeout OFF — isolates the watchdog
        let plan = [WarmStartStep(engine: .whisperKit, action: .warm)]
        var runnerCompletionDelivered = false
        runner.run(plan: plan) { _ in
            runnerCompletionDelivered = true
        }

        var contract = TalkBootContractState()
        for step in plan {
            contract.noteWarmPlanStep(step)
        }
        contract.settleUnplannedWarmFeatures()

        let watchdog = TalkBootWatchdog(scheduler: watchdogQueue)
        let fired = expectation(description:
            "watchdog fires while the warm queue stays occupied")
        watchdog.arm(after: 0.1) {
            contract.noteTalkWatchdogExpired()
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)

        XCTAssertEqual(contract.statuses[.whisper],
                       .failed(reason: TalkBootContractState.watchdogReason))
        XCTAssertEqual(contract.coldFeatures, [.whisper])
        XCTAssertTrue(contract.isComplete,
                      "the independent watchdog settles state while warm work is hung")
        // The warm queue is STILL occupied (the seam never returned), so
        // the runner's completion can never have been delivered — the
        // settle came ONLY from the independent watchdog.
        XCTAssertFalse(runnerCompletionDelivered,
                       "the warm queue's block never returned — settlement is the watchdog's, not the runner's")
        XCTAssertFalse(watchdog.isArmed, "a fired watchdog disarms")
    }

    func testArmIsIdempotentFirstDeadlineWins() {
        // Progress notes and retry re-plans call arm again — the
        // deadline must NOT extend past the first arm (otherwise a
        // chatty publisher could delay settlement forever).
        let queue = DispatchQueue(label: "contractfix.test.arm")
        let watchdog = TalkBootWatchdog(scheduler: queue)
        let lock = NSLock()
        var fireCount = 0
        let count = { () -> Int in
            lock.lock(); defer { lock.unlock() }
            return fireCount
        }
        let fire = {
            lock.lock(); fireCount += 1; lock.unlock()
        }

        XCTAssertTrue(watchdog.arm(after: 0.05, fire: fire))
        XCTAssertTrue(watchdog.isArmed)
        XCTAssertFalse(watchdog.arm(after: 0.3, fire: fire),
                       "a second arm must keep the ORIGINAL deadline")

        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertEqual(count(), 1,
                       "fires exactly once at the original deadline — the later arm never fires")
        XCTAssertFalse(watchdog.isArmed)
        watchdog.cancel()
    }

    func testCancelDisarms() {
        let watchdog = TalkBootWatchdog(scheduler: DispatchQueue(
            label: "contractfix.test.cancel"))
        let fired = expectation(description: "cancelled watchdog must not fire")
        fired.isInverted = true
        watchdog.arm(after: 0.05) {
            fired.fulfill()
        }
        watchdog.cancel()
        XCTAssertFalse(watchdog.isArmed)
        wait(for: [fired], timeout: 0.3)
    }
}
