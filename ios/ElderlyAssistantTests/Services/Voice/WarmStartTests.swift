import XCTest
@testable import ElderlyAssistant

/// Pure warm-plan gating + runner execution tests (warm-start task,
/// 2026-09-09): the planner's decision table (settings, stack,
/// availability, selected voice, simulator) and the runner's per-engine
/// `warm_start` observability against fake seams — no WhisperKit, no
/// sherpa-onnx, no models. Mirror of the placeholder-driven style: the
/// heavy runtimes never run here, only the decisions around them.
final class WarmStartTests: XCTestCase {

    // MARK: - Fakes

    final class FakeSTTWarming: STTModelWarming {
        var isAvailable = true
        var result: WarmStartEngineResult = .ready
        private(set) var warmCalls = 0

        func warm(completion: ((WarmStartEngineResult) -> Void)?) {
            warmCalls += 1
            completion?(result)
        }
    }

    final class FakeTTSWarming: TTSVoiceWarming {
        var results: [ModelID: WarmStartEngineResult] = [:]
        private(set) var warmCalls: [ModelID] = []

        func warm(voiceID: ModelID, completion: (WarmStartEngineResult) -> Void) {
            warmCalls.append(voiceID)
            completion(results[voiceID] ?? .ready)
        }
    }

    /// [LAT-M1] The llama warm seam fake — same shape as the other two.
    final class FakeLLMWarming: LLMInterpreterWarming {
        var isAvailable = true
        var result: WarmStartEngineResult = .ready
        private(set) var warmCalls = 0

        func warm(completion: @escaping (WarmStartEngineResult) -> Void) {
            warmCalls += 1
            completion(result)
        }
    }

    // MARK: - Config helpers

    /// The shipped defaults: enabled, on-device stack, WhisperKit
    /// available, llama available, both TTS voices installed, no voice
    /// selection, wake word on, not a simulator.
    private func defaultConfig() -> WarmStartConfig {
        WarmStartConfig(
            enabled: true,
            stack: .onDevice,
            whisperKitAvailable: true,
            whisperCppAvailable: true,
            availableTTSVoices: [ModelCatalog.piperNepali,
                                 ModelCatalog.piperEnglishUS],
            selectedNepaliVoiceID: ModelCatalog.piperNepali,
            wakeWordEnabled: true,
            isSimulator: false,
            llamaAvailable: true
        )
    }

    // MARK: - Planner gates

    func testDisabledPreferenceProducesEmptyPlan() {
        var config = defaultConfig()
        config.enabled = false
        XCTAssertEqual(WarmStartPlanner.plan(for: config), [],
                       "warm-start OFF must warm nothing")
    }

    func testGeminiStackSkipsWhisperAndStillWarmsTTS() {
        var config = defaultConfig()
        config.stack = .gemini
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertEqual(plan.first,
                       WarmStartStep(engine: .whisperKit,
                                     action: .skip(reason: "gemini_stack")),
                       "the Gemini STT stack must never warm an on-device whisper runtime")
        // [LAT-M1] The .gemini stack is LOCAL-FIRST hybrid ("the local
        // brain answers what it can, Gemini takes the rest"), so the
        // llama warm applies there too — the first conversation's
        // interpret still runs on the local brain.
        XCTAssertTrue(plan.contains(WarmStartStep(engine: .llamaInterpreter,
                                                  action: .warm,
                                                  phase: .boot)),
                      "the llama brain warms on the gemini stack — the local-first hybrid still runs it")
        XCTAssertTrue(plan.contains(WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepali),
                                                  action: .warm,
                                                  phase: .boot)),
                      "TTS warm is stack-independent — the reply voice is always on-device Piper, and the primary warms in the boot slot")
        XCTAssertTrue(plan.contains(WarmStartStep(engine: .ttsVoice(ModelCatalog.piperEnglishUS),
                                                  action: .warm,
                                                  phase: .postBoot)),
                      "the secondary English voice still warms — deferred past boot, not skipped")
    }

    func testLlamaMissingModelSkipsHonestly() {
        var config = defaultConfig()
        config.llamaAvailable = false
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertTrue(plan.contains(WarmStartStep(engine: .llamaInterpreter,
                                                  action: .skip(reason: "model_missing"))),
                      "a brain model that cannot load is an honest skip — the first interpret pays the load, today's behavior")
    }

    func testLlamaWarmIsSettingsGatedLikeEveryOtherWarm() {
        var config = defaultConfig()
        config.enabled = false
        XCTAssertEqual(WarmStartPlanner.plan(for: config), [],
                       "warm-start OFF warms nothing — llama included")
    }

    func testDefaultConfigBootSlotWarmsWhisperKitLlamaAndPrimaryVoiceOnly() {
        let plan = WarmStartPlanner.plan(for: defaultConfig())
        // [BOOT-LATENCY] The boot slot carries the whisper model, the
        // llama brain ([LAT-M1] — weights + context, no inference) and
        // ONLY the primary reply voice (whisper first — the biggest
        // load). The secondary English voice defers to the post-boot
        // slot so it can never delay `.ready`.
        XCTAssertEqual(plan, [
            WarmStartStep(engine: .whisperKit, action: .warm, phase: .boot),
            WarmStartStep(engine: .llamaInterpreter, action: .warm, phase: .boot),
            WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepali), action: .warm, phase: .boot),
            WarmStartStep(engine: .ttsVoice(ModelCatalog.piperEnglishUS), action: .warm, phase: .postBoot)
        ], "defaults → boot: whisper + llama + primary voice; post-boot: secondary voice")
    }

    func testSecondaryVoiceIsDeferredNotSkipped() {
        let plan = WarmStartPlanner.plan(for: defaultConfig())
        let bootEngines = plan.filter { $0.phase == .boot }.map(\.engine)
        XCTAssertEqual(bootEngines,
                       [.whisperKit, .llamaInterpreter,
                        .ttsVoice(ModelCatalog.piperNepali)],
                       "the boot slot warms ONLY whisper + llama + the primary reply voice")
        let deferred = plan.filter { $0.phase == .postBoot }
        XCTAssertEqual(deferred, [WarmStartStep(engine: .ttsVoice(ModelCatalog.piperEnglishUS),
                                                action: .warm,
                                                phase: .postBoot)],
                       "the secondary voice is DEFERRED, not dropped — same settings gates, only the slot moved")
    }

    func testWhisperCppOnlyIsSkippedWithPerAttemptReason() {
        var config = defaultConfig()
        config.whisperKitAvailable = false
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertEqual(plan.first,
                       WarmStartStep(engine: .whisperCpp,
                                     action: .skip(reason: "per_attempt_contexts")),
                       "whisper.cpp loads a FRESH context per attempt by design — a warmed context could never be reused, so warming it would only waste ~1.5 GB of idle RAM")
        XCTAssertFalse(plan.contains { $0.engine == .whisperKit },
                       "only ONE whisper runtime appears in the plan")
    }

    func testNoWhisperRuntimeSkipsModelMissing() {
        var config = defaultConfig()
        config.whisperKitAvailable = false
        config.whisperCppAvailable = false
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertEqual(plan.first,
                       WarmStartStep(engine: .whisperKit,
                                     action: .skip(reason: "model_missing")))
    }

    func testSelectedNepaliVoiceIsTheOneWarmed() {
        var config = defaultConfig()
        config.availableTTSVoices.insert(ModelCatalog.piperNepaliChitwan)
        config.selectedNepaliVoiceID = ModelCatalog.piperNepaliChitwan
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertTrue(plan.contains(WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepaliChitwan),
                                                  action: .warm)),
                      "warm must target the voice the first Nepali reply will ACTUALLY use")
        XCTAssertFalse(plan.contains { $0.engine == .ttsVoice(ModelCatalog.piperNepali) },
                       "the default voice is not warmed when a different voice is selected")
    }

    func testSelectedVoiceMissingSkipsEvenWhenDefaultAvailable() {
        var config = defaultConfig()
        config.selectedNepaliVoiceID = ModelCatalog.piperNepaliChitwan
        // chitwan NOT in availableTTSVoices; piperNepali IS.
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertTrue(plan.contains(WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepaliChitwan),
                                                  action: .skip(reason: "voice_missing"))),
                      "a missing selected voice falls back at speak time — warming the default would preload a voice the reply won't use")
    }

    func testMissingEnglishVoiceSkipsHonestly() {
        var config = defaultConfig()
        config.availableTTSVoices.remove(ModelCatalog.piperEnglishUS)
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertTrue(plan.contains(WarmStartStep(engine: .ttsVoice(ModelCatalog.piperEnglishUS),
                                                  action: .skip(reason: "voice_missing"),
                                                  phase: .postBoot)),
                      "a missing secondary voice is skipped in its own slot — the deferral never papers over an honest skip")
    }

    func testSimulatorSkipsWhisperAndSkipsEveryTTSWarm() {
        var config = defaultConfig()
        config.isSimulator = true
        let plan = WarmStartPlanner.plan(for: config)

        XCTAssertEqual(plan.first,
                       WarmStartStep(engine: .whisperKit,
                                     action: .skip(reason: "simulator")),
                       "WhisperKit is CPU-only on the simulator — the warm could outlive boot without ever helping")
        // [LAT-M1] The llama warm skips on the simulator too: llama.cpp
        // is CPU-only there (no Metal), the load is minutes-scale and
        // never helps a sim conversation — the whisper doctrine.
        XCTAssertTrue(plan.contains(WarmStartStep(engine: .llamaInterpreter,
                                                  action: .skip(reason: "simulator"))),
                      "the llama brain warm is SKIPPED on the simulator, never loaded")
        // [VAD-REGRESSION] On the simulator TTS warms are SKIPPED, not
        // deferred: the measured sherpa engine constructions cost up to
        // ~9 s there, hold the serial TTS engine queue (delaying the
        // morning briefing's first synthesis), and the off-main session
        // creation is the onnxruntime segfault class that crashed
        // launches (7 crash reports 2026-09-10). The sim's first
        // conversation pays the load — the pre-warm behavior.
        XCTAssertTrue(plan.contains(WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepali),
                                                  action: .skip(reason: "simulator"),
                                                  phase: .postBoot)),
                      "the primary TTS warm is SKIPPED on the simulator, never constructed")
        XCTAssertTrue(plan.contains(WarmStartStep(engine: .ttsVoice(ModelCatalog.piperEnglishUS),
                                                  action: .skip(reason: "simulator"),
                                                  phase: .postBoot)))
        XCTAssertTrue(plan.allSatisfy { $0.phase != .boot || $0.action != WarmStartAction.warm },
                      "no warm step may occupy the boot slot on the simulator — the boot warm slice is empty")
    }

    func testSelectedEnglishVoiceIsWarmedOnceAsPrimary() {
        // When the persisted reply voice IS the English voice, it is the
        // primary (boot slot, device) — never warmed twice.
        var config = defaultConfig()
        config.selectedNepaliVoiceID = ModelCatalog.piperEnglishUS
        let plan = WarmStartPlanner.plan(for: config)

        let englishSteps = plan.filter { $0.engine == .ttsVoice(ModelCatalog.piperEnglishUS) }
        XCTAssertEqual(englishSteps, [
            WarmStartStep(engine: .ttsVoice(ModelCatalog.piperEnglishUS),
                          action: .warm,
                          phase: .boot)
        ], "one warm for the English voice when it IS the primary — no duplicate post-boot step")
    }

    func testBootWarmBudgetIsShort() {
        // [BOOT-LATENCY] The boot-warm contribution is capped at a short
        // budget (the coordinator's watchdog consumes this constant): a
        // primary warm that outlives it finishes detached and boot
        // advances — the spinner must never wait on a multi-second
        // engine construction.
        XCTAssertEqual(WarmStartPlanner.bootWarmBudgetSeconds, 4.0,
                       "the boot warm budget pins at 4 s — the spinner's target ceiling")
        XCTAssertLessThanOrEqual(WarmStartPlanner.bootWarmBudgetSeconds, 5,
                                 "boot must reach .ready inside the latency target")
    }

    func testWakeWordPreferenceDoesNotGateWarming() {
        var config = defaultConfig()
        config.wakeWordEnabled = false
        XCTAssertEqual(WarmStartPlanner.plan(for: config),
                       WarmStartPlanner.plan(for: defaultConfig()),
                       "the wake-word engine is fully loaded in the boot's preparingVoice phase, and the Talk button uses the same STT/TTS engines — the preference must not gate warming")
    }

    func testNoWakeWordEngineStepEverAppears() {
        // The KWS engine needs no warm (loaded at boot phase 2 on main —
        // the sherpa ONNX runtime segfaults off-main on the x86_64
        // simulator). The plan must never carry a wake-word step.
        for stack in [VoiceEngineStack.onDevice, .gemini] {
            var config = defaultConfig()
            config.stack = stack
            let plan = WarmStartPlanner.plan(for: config)
            for step in plan {
                switch step.engine {
                case .whisperKit, .whisperCpp, .ttsVoice, .llamaInterpreter:
                    break // the only engine kinds the warm plan may carry
                }
            }
        }
    }

    // MARK: - Runner execution + observability

    private func run(_ plan: [WarmStartStep],
                     stt: STTModelWarming? = nil,
                     tts: TTSVoiceWarming? = nil,
                     llm: LLMInterpreterWarming? = nil,
                     bus: MockObservabilityBus = MockObservabilityBus())
        -> ([WarmStartRunner.WarmStartStepOutcome], MockObservabilityBus) {
        let runner = WarmStartRunner(stt: stt, tts: tts, llm: llm,
                                     observabilityBus: bus)
        let done = expectation(description: "warm plan settles")
        var outcomes: [WarmStartRunner.WarmStartStepOutcome] = []
        runner.run(plan: plan) { results in
            outcomes = results
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return (outcomes, bus)
    }

    func testRunnerEmitsStartedReadyAndSkippedPerEngine() {
        let stt = FakeSTTWarming()
        let tts = FakeTTSWarming()
        let plan = [
            WarmStartStep(engine: .whisperKit, action: .warm),
            WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepali), action: .warm),
            WarmStartStep(engine: .whisperCpp, action: .skip(reason: "per_attempt_contexts"))
        ]
        let (outcomes, bus) = run(plan, stt: stt, tts: tts)

        let events = bus.emittedEvents
        XCTAssertEqual(events.map(\.component), Array(repeating: "warm_start", count: events.count))
        XCTAssertEqual(events.map(\.eventType), Array(repeating: "engine", count: events.count))

        let started = events.filter { $0.outcome == "started" }
        XCTAssertEqual(started.map { $0.metadata["engine"] },
                       ["whisper_kit", "tts_voice"])

        let ready = events.filter { $0.outcome == "ready" }
        XCTAssertEqual(ready.count, 2)
        XCTAssertNotNil(ready[0].durationMs)

        let skipped = events.filter { $0.outcome == "skipped" }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped[0].metadata["engine"], "whisper_cpp")
        XCTAssertEqual(skipped[0].metadata["reason"], "per_attempt_contexts")

        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(outcomes[0].result, .ready)
        XCTAssertEqual(outcomes[1].result, .ready)
        XCTAssertNil(outcomes[2].result, "a skipped step never ran")
        XCTAssertEqual(stt.warmCalls, 1)
        XCTAssertEqual(tts.warmCalls, [ModelCatalog.piperNepali])
    }

    func testRunnerReportsFailedWithReasonAndDuration() {
        let stt = FakeSTTWarming()
        stt.result = .failed(reason: "load_failed")
        let plan = [WarmStartStep(engine: .whisperKit, action: .warm)]
        let (outcomes, bus) = run(plan, stt: stt)

        let failed = bus.emittedEvents.filter { $0.outcome == "failed" }
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed[0].errorCode, "load_failed")
        XCTAssertEqual(failed[0].metadata["reason"], "load_failed")
        XCTAssertEqual(outcomes, [WarmStartRunner.WarmStartStepOutcome(
            step: plan[0], result: .failed(reason: "load_failed"), durationMs: failed[0].durationMs)])
    }

    func testRunnerMissingSeamsFailHonestly() {
        let plan = [
            WarmStartStep(engine: .whisperKit, action: .warm),
            WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepali), action: .warm)
        ]
        let (outcomes, bus) = run(plan, stt: nil, tts: nil)

        XCTAssertEqual(outcomes.map(\.result),
                       [.failed(reason: "seam_unavailable"),
                        .failed(reason: "seam_unavailable")])
        XCTAssertEqual(bus.emittedEvents.filter { $0.outcome == "failed" }.count, 2)
    }

    func testRunnerEmptyPlanCompletesImmediatelyWithoutEvents() {
        let (outcomes, bus) = run([], stt: FakeSTTWarming(), tts: FakeTTSWarming())
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(bus.emittedEvents.isEmpty)
    }

    func testRunnerTTSVoiceEventsCarryVoiceID() {
        let plan = [WarmStartStep(engine: .ttsVoice(ModelCatalog.piperNepaliChitwan),
                                  action: .warm)]
        let (_, bus) = run(plan, stt: nil, tts: FakeTTSWarming())

        let ready = bus.emittedEvents.first { $0.outcome == "ready" }
        XCTAssertEqual(ready?.metadata["voice"], ModelCatalog.piperNepaliChitwan.rawValue)
    }

    // MARK: - Llama warm ([LAT-M1])

    func testRunnerWarmsLlamaThroughTheSeam() {
        let llm = FakeLLMWarming()
        let plan = [WarmStartStep(engine: .llamaInterpreter, action: .warm)]
        let (outcomes, bus) = run(plan, llm: llm)

        XCTAssertEqual(outcomes.map(\.result), [.ready])
        XCTAssertEqual(llm.warmCalls, 1)
        let ready = bus.emittedEvents.first { $0.outcome == "ready" }
        XCTAssertEqual(ready?.metadata["engine"], "llama_interpreter")
        XCTAssertNotNil(ready?.durationMs)
    }

    func testRunnerReportsLlamaFailureHonestly() {
        let llm = FakeLLMWarming()
        llm.result = .failed(reason: "model_load_failed")
        let plan = [WarmStartStep(engine: .llamaInterpreter, action: .warm)]
        let (outcomes, bus) = run(plan, llm: llm)

        let failed = bus.emittedEvents.filter { $0.outcome == "failed" }
        XCTAssertEqual(failed.first?.metadata["engine"], "llama_interpreter")
        XCTAssertEqual(failed.first?.errorCode, "model_load_failed")
        XCTAssertEqual(outcomes.map(\.result),
                       [.failed(reason: "model_load_failed")])
    }

    func testRunnerMissingLlamaSeamFailsHonestly() {
        let plan = [WarmStartStep(engine: .llamaInterpreter, action: .warm)]
        let (outcomes, _) = run(plan, llm: nil)
        XCTAssertEqual(outcomes.map(\.result),
                       [.failed(reason: "seam_unavailable")])
    }

    // MARK: - Settings copy (catalog binding, both shipped languages)

    func testWarmStartSettingsCopyResolvesInBothLanguages() {
        // The Voice personalization card's honesty copy — memory/battery
        // disclosure included — must resolve in both shipped languages
        // (same catalog-binding discipline as StartupBootTests).
        let ne = Locale(identifier: "ne-NP")
        let en = Locale(identifier: "en-US")

        XCTAssertEqual(L10n.str("voiceSettings.warmStart.title", locale: en),
                       "Faster first conversation")
        XCTAssertEqual(L10n.str("voiceSettings.warmStart.title", locale: ne),
                       "पहिलो कुराकानी छिटो")
        XCTAssertFalse(L10n.str("voiceSettings.warmStart.caption", locale: en)
            .hasPrefix("voiceSettings."))
        XCTAssertFalse(L10n.str("voiceSettings.warmStart.caption", locale: ne)
            .hasPrefix("voiceSettings."))
        XCTAssertTrue(L10n.str("voiceSettings.warmStart.caption", locale: en)
            .contains("memory"),
                      "the caption must disclose the memory/battery trade-off")
    }
}
