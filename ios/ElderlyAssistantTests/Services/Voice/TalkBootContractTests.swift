import XCTest
@testable import ElderlyAssistant

/// [LAT-M1] Unit tests for the invariance boot contract machine
/// (`TalkBootContractState`) and its published conjunction
/// (`TalkBootContract.combine`). The contract pinned here:
///
///  - speak-enabled ⇔ pipeline started ∧ whisper warm settled ∧ primary
///    TTS warm settled ∧ llama warm settled ∧ KWS settled,
///  - a SKIP settles its feature (the planner's honest reason — the
///    simulator skip, gemini_stack, model_missing, preference off) and
///    satisfies the contract,
///  - a FAILED warm settles DEGRADED: enabled with the honest cold-
///    feature payload — never silent, never blocked forever,
///  - the warm budget expiring does NOT enable the button — only real
///    settles (and the talk watchdog) move the contract,
///  - the talk watchdog fails still-pending warm features (cold) but
///    only SKIPS a pending KWS (wake word never degrades manual Talk),
///  - a retry warm outcome upgrades a failed feature honestly.
final class TalkBootContractTests: XCTestCase {

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
        // KWS remains — the button waits only on the KWS settle.
        XCTAssertEqual(contract.pendingFeatures, [.kws])
    }

    // MARK: - The speak-enabled conjunction

    func testSpeakEnabledRequiresEveryFeature() {
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit), step(.llamaInterpreter),
            step(.ttsVoice(ModelCatalog.piperNepali)),
        ]) {
            contract.noteWarmPlanStep(step)
        }
        // One feature at a time — the contract is never complete early.
        contract.noteWarmOutcome(feature: .whisper, result: .ready)
        XCTAssertFalse(contract.isComplete)
        contract.noteWarmOutcome(feature: .primaryTTS, result: .ready)
        XCTAssertFalse(contract.isComplete)
        contract.noteWarmOutcome(feature: .llama, result: .ready)
        XCTAssertFalse(contract.isComplete, "KWS still pending")
        contract.noteKWSApplied(isReal: true)
        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.isSatisfied)
        XCTAssertTrue(contract.coldFeatures.isEmpty)
    }

    func testCombineReadyRequiresContractSatisfied() {
        let pipeline: VoicePipelineReadiness = .ready
        // Contract still open → preparing, NOT enabled.
        var preparing = TalkBootContractState()
        preparing.noteKWSApplied(isReal: true)  // KWS done, warms pending
        XCTAssertEqual(TalkBootContract.combine(pipeline: pipeline,
                                                contract: preparing),
                       .loading(.preparingEngines(preparing.progress)))

        // Contract satisfied → ready.
        var satisfied = TalkBootContractState()
        settleAllWarm(&satisfied)
        satisfied.noteKWSApplied(isReal: true)
        XCTAssertEqual(TalkBootContract.combine(pipeline: pipeline,
                                                contract: satisfied),
                       .ready)
    }

    // MARK: - Honest degradation (never silent, never blocked forever)

    func testWarmFailureSettlesDegradedWithColdFeatures() {
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
        XCTAssertEqual(contract.coldFeatures, [.whisper])

        // The published value is DEGRADED — enabled with the banner
        // payload, not `.ready` and not `.loading`.
        let published = TalkBootContract.combine(pipeline: .ready,
                                                 contract: contract)
        XCTAssertEqual(published,
                       .degraded(TalkBootDegradation(coldFeatures: [.whisper])))
        XCTAssertTrue(published.isTalkEnabled,
                      "a degraded hero is ENABLED — the first conversation honestly pays the load")
    }

    func testBudgetExpiryAloneKeepsTheButtonDisabled() {
        // [LAT-M1] The 4 s warm budget may advance the SPINNER, but the
        // contract itself only moves on real settles (or the talk
        // watchdog). A budget expiry with warms still in flight = still
        // preparing = still disabled — no silent enable.
        var contract = TalkBootContractState()
        for step in plan([step(.whisperKit)]) {
            contract.noteWarmPlanStep(step)
        }
        contract.noteKWSApplied(isReal: true)
        XCTAssertFalse(contract.isComplete)
        let published = TalkBootContract.combine(pipeline: .ready,
                                                 contract: contract)
        XCTAssertTrue(published.isLoading,
                      "budget expiry never enables — the button stays disabled with honest progress")
        XCTAssertFalse(published.isTalkEnabled)
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
                       "a pending KWS falls back to Null behavior — wake word never degrades manual Talk")
        XCTAssertEqual(contract.coldFeatures, [.whisper])

        let published = TalkBootContract.combine(pipeline: .ready,
                                                 contract: contract)
        XCTAssertTrue(published.isTalkEnabled)
        XCTAssertEqual(published.degradation?.coldFeatures, [.whisper])
    }

    func testNullKWSSettlesSatisfiedWithoutDegradation() {
        var contract = TalkBootContractState()
        settleAllWarm(&contract)
        contract.noteKWSApplied(isReal: false)

        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.isSatisfied,
                      "a Null wake-word engine is a satisfied skip, never a Talk failure")
        XCTAssertTrue(contract.coldFeatures.isEmpty)

        let published = TalkBootContract.combine(pipeline: .ready,
                                                 contract: contract)
        XCTAssertEqual(published, .ready)
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

        // The degraded-state recovery re-runs the warm; success clears
        // the degradation honestly (never by a timer).
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

    func testPostBootWarmDefensivelySkipsInsteadOfGating() {
        // A hand-built plan can never put the PRIMARY TTS in the
        // post-boot slot through the planner (the simulator defers TTS
        // warms as SKIPS) — pin the defensive settle so a future planner
        // change can never gate the button on a post-boot load.
        var contract = TalkBootContractState()
        contract.noteWarmPlanStep(step(
            .ttsVoice(ModelCatalog.piperNepali), phase: .postBoot))
        XCTAssertEqual(contract.statuses[.primaryTTS],
                       .skipped(reason: TalkBootContractState.postBootSlotReason))
    }

    // MARK: - Published value passing-through

    func testCombinePassesThroughPipelineFailuresAndLoading() {
        var contract = TalkBootContractState()
        settleAllWarm(&contract)
        contract.noteKWSApplied(isReal: true)

        XCTAssertEqual(
            TalkBootContract.combine(
                pipeline: .failed(.pipelineStartFailed(reason: "mic")),
                contract: contract),
            .failed(.pipelineStartFailed(reason: "mic")),
            "a failed pipeline start is the published failure — the contract is irrelevant")
        XCTAssertEqual(
            TalkBootContract.combine(pipeline: .loading(.starting),
                                     contract: contract),
            .loading(.starting),
            "while the start callback is in flight the published stage is .starting")
    }

    func testTalkWatchdogBoundsTheWait() {
        // The contract watchdog must be short enough that a hung warm
        // degrades promptly, and the preparing hero must carry the
        // per-feature progress the caption renders.
        XCTAssertLessThanOrEqual(TalkBootContractState.talkWatchdogSeconds, 45,
                                 "the talk watchdog must never block the button for minutes")
        XCTAssertGreaterThan(TalkBootContractState.talkWatchdogSeconds,
                             WarmStartPlanner.bootWarmBudgetSeconds,
                             "the talk watchdog must outlive the boot warm budget — budget expiry alone never degrades")
    }

    // MARK: - Never-stuck guarantees ([CONTRACT-FIX])

    func testAllSilentPublishersSettleDegradedEnabledAtWatchdog() {
        // Every feature publisher is a no-op that never emits: the plan
        // was fed, but no warm outcome and no KWS settle ever arrives.
        // The watchdog is the ONLY input — and it must settle the
        // contract DEGRADED (enabled + banner), never leave the button
        // disabled.
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
                       "a silent KWS falls back to the Null behavior — wake word never degrades manual Talk")

        let published = TalkBootContract.combine(pipeline: .ready,
                                                 contract: contract)
        XCTAssertTrue(published.isTalkEnabled,
                      "the all-silent watchdog settle is ENABLED (degraded with the honest banner) — never stuck disabled")
        XCTAssertEqual(published.degradation?.coldFeatures,
                       [.whisper, .primaryTTS, .llama])
    }

    func testKWSNoSignalAloneFallsBackToNullSkipNotFailure() {
        // The warms settle clean; ONLY the KWS never emits (device build
        // wedged on the off-main queue). The watchdog's KWS fallback is a
        // satisfied skip — the published value is `.ready`, never a Talk
        // degradation.
        var contract = TalkBootContractState()
        settleAllWarm(&contract)
        XCTAssertEqual(contract.pendingFeatures, [.kws])

        contract.noteTalkWatchdogExpired()

        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.watchdogReason))
        XCTAssertTrue(contract.isSatisfied,
                      "a pending KWS degrades to the Null behavior — wake word never degrades manual Talk")
        XCTAssertTrue(contract.coldFeatures.isEmpty)
        XCTAssertEqual(TalkBootContract.combine(pipeline: .ready,
                                                contract: contract),
                       .ready)
    }

    func testNoInputsAtAllStillSettlesAtWatchdog() {
        // Not even a plan was fed (a boot path that never reached the
        // warm phase): the contract cannot wait forever on inputs that
        // can never arrive — the watchdog settles every feature.
        var contract = TalkBootContractState()
        XCTAssertEqual(contract.pendingFeatures,
                       [.whisper, .primaryTTS, .llama, .kws])

        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.pendingFeatures.isEmpty)
        let published = TalkBootContract.combine(pipeline: .ready,
                                                 contract: contract)
        XCTAssertTrue(published.isTalkEnabled,
                      "no-input contracts settle ENABLED at the deadline")
    }

    func testPreferenceOffFullFlowSettlesReadyOnceKWSApplies() {
        // Warm-start OFF: the empty plan settles whisper/primaryTTS/llama
        // as preference_off (including llama — the coordinator's planner
        // reasons must reach ALL warm features), and the KWS settle
        // completes the contract clean.
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
        XCTAssertEqual(TalkBootContract.combine(pipeline: .ready,
                                                contract: contract),
                       .ready)
    }

    func testPreferenceOffWithSilentKWSStillSettlesAtWatchdog() {
        // Preference off AND the deferred KWS build never reports: the
        // watchdog settles the last pending feature as the Null skip —
        // the button enables clean, never waits.
        var contract = TalkBootContractState()
        contract.settleUnplannedWarmFeatures()

        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.isComplete)
        XCTAssertTrue(contract.isSatisfied,
                      "preference-off warm features are settled skips; the silent KWS becomes the Null skip — never a failure")
        XCTAssertEqual(contract.statuses[.kws],
                       .skipped(reason: TalkBootContractState.watchdogReason))
        XCTAssertEqual(TalkBootContract.combine(pipeline: .ready,
                                                contract: contract),
                       .ready)
    }

    func testWatchdogDeadlineLeavesNothingPending() {
        // The hard upper bound: after the watchdog's deadline event (the
        // injected clock), NOTHING is pending — no publisher silence,
        // warm hang or KWS wedge can hold the contract past
        // `talkWatchdogSeconds`.
        var contract = TalkBootContractState()
        for step in plan([
            step(.whisperKit), step(.llamaInterpreter),
            step(.ttsVoice(ModelCatalog.piperNepali)),
        ]) {
            contract.noteWarmPlanStep(step)
        }

        contract.noteTalkWatchdogExpired()

        XCTAssertTrue(contract.pendingFeatures.isEmpty,
                      "at the deadline every feature is settled — the contract can never wait past the watchdog")
        XCTAssertTrue(contract.isComplete)
        // The settle happens AT the deadline — not before: until the
        // watchdog fires, the contract stays honestly open.
        var stillOpen = TalkBootContractState()
        for step in plan([step(.whisperKit)]) {
            stillOpen.noteWarmPlanStep(step)
        }
        XCTAssertFalse(stillOpen.isComplete,
                       "before the deadline the contract stays open — the button is disabled honestly, never silently enabled")
    }

    // MARK: - Copy (catalog binding, both shipped languages)

    func testPreparingAndDegradedCopyResolvesInBothLanguages() {
        // The new preparing/degraded strings must resolve in both shipped
        // languages (same catalog-binding discipline as
        // WarmStartTests' settings-copy test) — a key that falls back to
        // its own name would render as machine text on Home.
        let ne = Locale(identifier: "ne-NP")
        let en = Locale(identifier: "en-US")

        var preparing = TalkBootContractState()
        for step in plan([step(.whisperKit), step(.llamaInterpreter)]) {
            preparing.noteWarmPlanStep(step)
        }
        preparing.noteKWSApplied(isReal: true)

        let caption = TalkReadinessCopy.preparingEnginesCaption(
            preparing.progress, locale: en)
        XCTAssertFalse(caption.isEmpty)
        XCTAssertFalse(caption.hasPrefix("voice.readiness."))
        XCTAssertTrue(TalkReadinessCopy.preparingEnginesCaption(
            preparing.progress, locale: ne).contains("·"),
                      "the pending features join into the caption in Nepali too")

        let degradation = TalkBootDegradation(coldFeatures: [.llama, .whisper])
        let banner = TalkReadinessCopy.degradedCaption(degradation, locale: en)
        XCTAssertFalse(banner.isEmpty)
        XCTAssertFalse(banner.hasPrefix("voice.readiness."))
        let neBanner = TalkReadinessCopy.degradedCaption(degradation, locale: ne)
        XCTAssertFalse(neBanner.hasPrefix("voice.readiness."))
        XCTAssertTrue(neBanner.contains("दिमाग"),
                      "the Nepali banner names the cold brain feature")

        XCTAssertEqual(TalkReadinessCopy.loadingLabel(.preparingEngines(preparing.progress),
                                                      locale: en),
                       L10n.str("voice.readiness.loading.preparingEngines", locale: en))
        XCTAssertFalse(TalkReadinessCopy.loadingLabel(.preparingEngines(preparing.progress),
                                                      locale: ne).hasPrefix("voice.readiness."))
    }

    func testExtraLineOnlyAppearsWhilePreparingOrDegraded() {
        let ne = Locale(identifier: "ne-NP")
        XCTAssertNil(TalkReadinessCopy.extraLine(.ready, locale: ne))
        XCTAssertNil(TalkReadinessCopy.extraLine(.loading(.starting), locale: ne))
        XCTAssertNil(TalkReadinessCopy.extraLine(
            .failed(.pipelineStartFailed(reason: "x")), locale: ne))

        var preparing = TalkBootContractState()
        XCTAssertNotNil(TalkReadinessCopy.extraLine(
            .loading(.preparingEngines(preparing.progress)), locale: ne),
            "an open contract shows the preparing caption")
        XCTAssertNotNil(TalkReadinessCopy.extraLine(
            .degraded(TalkBootDegradation(coldFeatures: [.llama])), locale: ne),
            "a degraded settle shows the cold-feature banner")
    }
}

// MARK: - The watchdog seam ([CONTRACT-FIX])

/// The never-stuck guarantee's scheduler half: the watchdog must fire on
/// its OWN scheduler even when the warm queue is occupied by a hung warm
/// (the no-shared-queue-deadlock proof), the deadline must never extend
/// past the first arm, and a cancel must disarm.
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
        // The warm queue is OCCUPIED by the hung seam (its block never
        // returns) and the runner's per-step timeout is disabled — the
        // ONLY thing that can settle the contract is the watchdog on
        // its independent scheduler. If the watchdog shared the warm
        // queue it would never fire and the button would stay disabled
        // forever — this test pins the fix.
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

        let watchdog = TalkBootWatchdog(scheduler: watchdogQueue)
        let fired = expectation(description:
            "watchdog fires while the warm queue stays occupied")
        watchdog.arm(after: 0.1) {
            contract.noteTalkWatchdogExpired()
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)

        XCTAssertTrue(contract.isComplete)
        XCTAssertEqual(contract.statuses[.whisper],
                       .failed(reason: TalkBootContractState.watchdogReason))
        let published = TalkBootContract.combine(pipeline: .ready,
                                                 contract: contract)
        XCTAssertTrue(published.isTalkEnabled,
                      "the independent watchdog settles the contract even though the warm queue is still occupied by the hung warm")
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
