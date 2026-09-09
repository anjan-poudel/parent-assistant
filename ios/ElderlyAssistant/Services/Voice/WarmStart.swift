import Foundation

// MARK: - Warm-start engines (warm-start task, 2026-09-09)
//
// Startup is instant (startup-perf task) but the FIRST conversation pays
// the cold-engine loads: the WhisperKit model (weights + one-time CoreML
// specialization) and the sherpa Piper TTS engine construction. Warm-start
// preloads them so the first Talk request skips the multi-second loads.
// The decision and the execution are separate so the decision table is
// pure and unit-testable:
//
//   WarmStartPlanner.plan(for:)  — which engines to warm/skip, why, and
//                                  WHICH lifecycle slot each step runs in
//                                  (from settings + stack + availability).
//   WarmStartRunner              — executes a plan against the two warm
//                                  seams and reports `warm_start` events
//                                  per engine (started/ready/skipped/
//                                  failed with reason) on the
//                                  ObservabilityBus.
//
// [BOOT-LATENCY] The boot warms ONLY the primary reply voice:
//  - `.boot` steps run during the boot's `.warmingEngines` stage and are
//    bounded by `WarmStartPlanner.bootWarmBudgetSeconds` (the
//    coordinator's watchdog — a tight budget so the warm contribution
//    can never dominate the spinner). A step still running when the
//    budget expires finishes DETACHED: boot advances, the warm
//    continues and still caches its engine for the first talk.
//  - `.postBoot` steps — the secondary English voice — run AFTER `.ready`
//    on the same serial warm queue, gated by the same settings. On the
//    simulator TTS warms are SKIPPED entirely (see `ttsSteps`): they
//    are deferred, never skipped because of the slot: only the timing
//    moved, so they can never delay boot.
//
// Honest limits (documented, not worked around):
//  - whisper.cpp (SwiftWhisper) is NEVER warmed: its design loads a FRESH
//    context per attempt and drops it after each transcript
//    (WhisperSpeechRecognizer.runInference), so a warmed context could
//    never be reused — it would only hold ~1.5 GB of RAM hostage during
//    idle while the LLM needs it. The planner pins this as
//    `.skip("per_attempt_contexts")`.
//  - Gemini (STT or LLM) is NEVER warmed: every Gemini API call is
//    billable and the client has no non-billing handshake, so a synthetic
//    warm request would cost tokens. On the Gemini STT stack the whisper
//    warm is skipped ("gemini_stack"); TTS warm still applies — the reply
//    voice is always on-device Piper.
//  - The wake-word engine needs no warm: it is fully loaded during the
//    boot's `.preparingVoice` phase (main thread — the sherpa ONNX
//    runtime segfaults off-main on the x86_64 simulator). The Talk button
//    uses the same STT/TTS engines with listening off, so the wake-word
//    preference does not gate warming.
//  - RAM honesty: warm holds the loaded weights until the first
//    transcript, when `recordTranscript` drops them exactly as before
//    (`releaseModel`) — warm changes WHEN the load happens, not the
//    post-transcript RAM contract. Memory/battery cost is disclosed in
//    the Settings copy (voiceSettings.warmStart.*).

// MARK: - Plan model (pure, no IO)

/// How one engine's warm attempt ended. The strings are event reasons,
/// never user copy.
enum WarmStartEngineResult: Equatable {
    case ready
    case failed(reason: String)
}

/// The engines the warm plan can touch.
enum WarmStartEngine: Equatable {
    case whisperKit
    case whisperCpp
    case ttsVoice(ModelID)
}

/// What the plan decided for one engine.
enum WarmStartAction: Equatable {
    case warm
    case skip(reason: String)
}

/// Which lifecycle slot a warm step runs in. The planner is pure — it
/// only DECIDES the slot; the coordinator splits the plan on this field
/// and runs each slice at its slot. The runner is phase-agnostic: it
/// executes any slice identically.
enum WarmStartPhase: Equatable {
    /// Runs during boot's `.warmingEngines` stage, bounded by
    /// `WarmStartPlanner.bootWarmBudgetSeconds`; a step that outlives
    /// the budget finishes detached (boot advances, warm continues).
    case boot
    /// Runs after boot completes (spinner dismissed), detached on the
    /// warm queue — never delays `.ready`.
    case postBoot
}

/// One engine's plan entry.
struct WarmStartStep: Equatable {
    var engine: WarmStartEngine
    var action: WarmStartAction
    /// Default `.boot` keeps hand-built runner plans unchanged; the
    /// runner ignores the slot — only the coordinator's phase split
    /// reads it.
    var phase: WarmStartPhase = .boot
}

/// Pure inputs to the warm decision. All values are resolved by the
/// coordinator at boot time so the planner itself performs no IO.
struct WarmStartConfig: Equatable {
    /// Settings → Voice personalization → warm start (default ON).
    var enabled: Bool
    /// The active voice-engine stack (Settings → AI मोडेल).
    var stack: VoiceEngineStack
    /// WhisperKit's own availability (installed catalog artifact or a
    /// bench override).
    var whisperKitAvailable: Bool
    /// whisper.cpp availability (a cached ggml model + runtime linked).
    var whisperCppAvailable: Bool
    /// TTS voice ids whose directories are installed OR bundled (the
    /// warm seam installs bundled voices idempotently, the same lazy
    /// install the speak path performs).
    var availableTTSVoices: Set<ModelID>
    /// The Nepali reply voice in effect: the persisted choice, else the
    /// locale default (piperNepali). Warm warms THIS voice — the voice
    /// the first Nepali reply will actually use — as the boot slot's
    /// only TTS step (deferred to the post-boot slot on the simulator).
    var selectedNepaliVoiceID: ModelID
    /// "Listen for Hey Sahayak" preference. Kept in the config so tests
    /// pin that it does NOT gate STT/TTS warming (see the header).
    var wakeWordEnabled: Bool
    /// Simulator builds skip the whisper warm: WhisperKit runs CPU-only
    /// there and the load can outlive the boot watchdog without ever
    /// helping a real conversation.
    var isSimulator: Bool
}

/// The pure decision table behind the boot's warm phase. Gating tests
/// live in WarmStartTests.
enum WarmStartPlanner {

    /// [BOOT-LATENCY] Seconds the boot's `.warmingEngines` stage may
    /// hold the boot before the coordinator's watchdog settles it:
    /// boot advances to `.finishingSetup` and the warm continues
    /// detached, still caching its engine for the first talk. Short on
    /// purpose — the boot-warm contribution must never dominate the
    /// spinner (measured sherpa TTS engine constructions run ~3.7–9 s
    /// on the simulator; a slow primary warm must not gate `.ready`
    /// past this budget).
    static let bootWarmBudgetSeconds: TimeInterval = 4.0

    static func plan(for config: WarmStartConfig) -> [WarmStartStep] {
        guard config.enabled else { return [] }
        var steps: [WarmStartStep] = [sttStep(for: config)]
        steps.append(contentsOf: ttsSteps(for: config))
        return steps
    }

    private static func sttStep(for config: WarmStartConfig) -> WarmStartStep {
        switch config.stack {
        case .gemini:
            // The Gemini stack transcribes in the cloud — warming an
            // on-device recognizer the first talk will never use would
            // be a wasted multi-hundred-MB load.
            return WarmStartStep(engine: .whisperKit,
                                 action: .skip(reason: "gemini_stack"))
        case .onDevice:
            if config.isSimulator {
                return WarmStartStep(engine: .whisperKit,
                                     action: .skip(reason: "simulator"))
            }
            if config.whisperKitAvailable {
                return WarmStartStep(engine: .whisperKit, action: .warm)
            }
            if config.whisperCppAvailable {
                return WarmStartStep(engine: .whisperCpp,
                                     action: .skip(reason: "per_attempt_contexts"))
            }
            return WarmStartStep(engine: .whisperKit,
                                 action: .skip(reason: "model_missing"))
        }
    }

    /// [BOOT-LATENCY] The boot warms ONLY the primary reply voice — the
    /// voice the next reply will actually use. The secondary English
    /// voice defers to the post-boot slot (same settings gates, same
    /// warm — only the timing moved so it can't delay `.ready`). On the
    /// simulator the TTS warms are SKIPPED outright (reason
    /// "simulator"): the measured sherpa engine constructions are
    /// sim-only costs (up to ~9 s) with no user value, and [VAD-
    /// REGRESSION] (2026-09-10) they were proven actively harmful
    /// there — every launch's warm held the serial TTS engine queue for
    /// ~9 s (delaying the morning briefing's first synthesis) and the
    /// off-main sherpa VITS session creation is the onnxruntime
    /// segfault class that killed launches (7 crash reports; see
    /// `SherpaTTSEngine.engine(for:)`). The simulator's first
    /// conversation happily pays the load — exactly the pre-warm
    /// behavior. When the selected voice IS the English voice, it is
    /// warmed once as the primary — never twice.
    private static func ttsSteps(for config: WarmStartConfig) -> [WarmStartStep] {
        let primary = config.selectedNepaliVoiceID
        let primaryPhase: WarmStartPhase = config.isSimulator ? .postBoot : .boot
        let simOverride: WarmStartAction? = config.isSimulator
            ? .skip(reason: "simulator") : nil
        var steps: [WarmStartStep] = [
            ttsStep(voiceID: primary,
                    available: config.availableTTSVoices,
                    phase: primaryPhase,
                    forcedAction: simOverride)
        ]
        let secondary = ModelCatalog.piperEnglishUS
        guard secondary != primary else { return steps }
        steps.append(ttsStep(voiceID: secondary,
                             available: config.availableTTSVoices,
                             phase: .postBoot,
                             forcedAction: simOverride))
        return steps
    }

    private static func ttsStep(voiceID: ModelID,
                                available: Set<ModelID>,
                                phase: WarmStartPhase,
                                forcedAction: WarmStartAction? = nil) -> WarmStartStep {
        let action: WarmStartAction
        if let forcedAction {
            action = forcedAction
        } else {
            action = available.contains(voiceID)
                ? .warm
                : .skip(reason: "voice_missing")
        }
        return WarmStartStep(engine: .ttsVoice(voiceID),
                             action: action,
                             phase: phase)
    }
}

// MARK: - Settings seam

/// Read/write seam for the warm-start preference (Settings → Voice
/// personalization). `AppCoordinator` conforms: its
/// `@Published warmStartEnabled` persists the UserDefaults key
/// ("warmStartEngines", default ON) and is the value the boot's warm
/// phase reads — one writer, same contract as
/// `NoiseFilterPreferenceControlling`.
protocol WarmStartPreferenceControlling: AnyObject {
    var warmStartEnabled: Bool { get set }
}

// MARK: - Warm seams (execution side)

/// Warm seam for the speech-recognition model: preloads the weights off
/// the critical path so the first utterance skips the load. `isAvailable`
/// tells the planner whether a warm is even possible; `completion` (when
/// given) reports the outcome on an arbitrary queue — never assumed main.
protocol STTModelWarming: AnyObject {
    var isAvailable: Bool { get }
    func warm(completion: ((WarmStartEngineResult) -> Void)?)
}

/// Warm seam for TTS: resolves one catalog voice's directory (installing
/// the bundled voice idempotently, exactly like the speak path) and
/// constructs the sherpa engine for it. Synchronous on the caller's
/// queue; completion is called inline.
protocol TTSVoiceWarming: AnyObject {
    func warm(voiceID: ModelID, completion: (WarmStartEngineResult) -> Void)
}

// MARK: - Runner (execution + observability)

/// Executes a warm plan against the two seams and reports per-engine
/// `warm_start` events on the ObservabilityBus. One attempt runs at a
/// time — the whisper load and the sherpa construction are both large
/// allocations; serializing them bounds the boot's memory spike. Skips
/// are reported, not executed. `completion` receives every step's
/// terminal outcome (in plan order) on the runner's queue.
final class WarmStartRunner {

    /// One step's terminal outcome. `result` is nil for skipped steps
    /// (nothing ran).
    struct WarmStartStepOutcome: Equatable {
        var step: WarmStartStep
        var result: WarmStartEngineResult?
        var durationMs: Int?
    }

    private let stt: STTModelWarming?
    private let tts: TTSVoiceWarming?
    private let bus: ObservabilityBus
    private let warmQueue: DispatchQueue

    init(stt: STTModelWarming?,
         tts: TTSVoiceWarming?,
         observabilityBus: ObservabilityBus,
         queue: DispatchQueue = DispatchQueue(label: "senios.startup.warm",
                                              qos: .userInitiated)) {
        self.stt = stt
        self.tts = tts
        self.bus = observabilityBus
        self.warmQueue = queue
    }

    /// Runs every step in plan order. `completion` is called exactly
    /// once, on `queue`, after the last step settles.
    func run(plan: [WarmStartStep],
             completion: @escaping ([WarmStartStepOutcome]) -> Void) {
        warmQueue.async {
            var outcomes: [WarmStartStepOutcome] = []
            var index = 0
            // Sequential settle chain — a nested function rather than
            // `inout` parameters (the warm seam's completion is escaping,
            // and escaping closures may not capture an inout).
            func settleNext() {
                guard index < plan.count else {
                    completion(outcomes)
                    return
                }
                let step = plan[index]
                index += 1
                switch step.action {
                case .skip(let reason):
                    self.emit(step, outcome: "skipped", reason: reason)
                    outcomes.append(WarmStartStepOutcome(step: step,
                                                         result: nil,
                                                         durationMs: nil))
                    settleNext()
                case .warm:
                    self.emit(step, outcome: "started")
                    let start = CFAbsoluteTimeGetCurrent()
                    self.runWarm(step) { result in
                        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                        switch result {
                        case .ready:
                            self.emit(step, outcome: "ready", durationMs: ms)
                        case .failed(let reason):
                            self.emit(step, outcome: "failed", reason: reason,
                                      durationMs: ms)
                        }
                        outcomes.append(WarmStartStepOutcome(step: step,
                                                             result: result,
                                                             durationMs: ms))
                        settleNext()
                    }
                }
            }
            settleNext()
        }
    }

    /// Fans a `.warm` step out to the matching seam. All completions are
    /// delivered on `warmQueue` so the settle chain stays single-threaded.
    private func runWarm(_ step: WarmStartStep,
                         completion: @escaping (WarmStartEngineResult) -> Void) {
        switch step.engine {
        case .whisperKit:
            guard let stt else {
                completion(.failed(reason: "seam_unavailable"))
                return
            }
            stt.warm { result in
                // The recognizer's completion lands on an arbitrary queue
                // (its load Task) — re-marshal so the settle chain stays
                // single-threaded.
                self.warmQueue.async {
                    completion(result)
                }
            }
        case .whisperCpp:
            // The planner never schedules a whisper.cpp warm — the
            // recognizer loads a fresh context per attempt by design, so
            // a warm context could never be reused (see the header).
            // Defensive honesty if a hand-built plan slips through.
            completion(.failed(reason: "per_attempt_contexts"))
        case .ttsVoice(let voiceID):
            guard let tts else {
                completion(.failed(reason: "seam_unavailable"))
                return
            }
            tts.warm(voiceID: voiceID, completion: completion)
        }
    }

    // MARK: Observability

    /// Per-engine event: component `warm_start`, eventType `engine`,
    /// outcome started/ready/skipped/failed, the engine id (+ voice id
    /// for TTS steps) and — for skips/failures — the honest reason.
    /// PII-free: catalog ids only, never audio or transcripts.
    private func emit(_ step: WarmStartStep,
                      outcome: String,
                      reason: String? = nil,
                      durationMs: Int? = nil) {
        var metadata = ["engine": engineName(step.engine)]
        if case .ttsVoice(let voiceID) = step.engine {
            metadata["voice"] = voiceID.rawValue
        }
        if let reason {
            metadata["reason"] = reason
        }
        bus.emit(ObservabilityEvent(
            component: "warm_start",
            eventType: "engine",
            durationMs: durationMs,
            outcome: outcome,
            errorCode: outcome == "failed" ? reason : nil,
            metadata: metadata
        ))
    }

    private func engineName(_ engine: WarmStartEngine) -> String {
        switch engine {
        case .whisperKit: return "whisper_kit"
        case .whisperCpp: return "whisper_cpp"
        case .ttsVoice: return "tts_voice"
        }
    }
}
