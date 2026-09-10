import Foundation

// MARK: - On-device STT engine selection (startup-r2 task, 2026-09-10)
//
// Pure decision table behind `AppCoordinator.applyVoiceEngineStack()`'s
// on-device branch — which whisper engine the on-device stack speaks
// with, and the honest reason when a cheaper path is forced.
//
// The SIMULATOR is the deliberate exception (mirroring the warm plan's
// `skip(reason: "simulator")` in WarmStart.swift): WhisperKit is
// CPU-only there and its medium-class CoreML prepare is a minutes-scale
// load that outlives the boot watchdog without ever helping a real
// conversation, while whisper.cpp's per-attempt contexts cost NOTHING at
// startup (the load moves into the first utterance — its pre-existing
// "per_attempt_contexts" contract). So on the simulator, when the
// bundled whisper.cpp model is available, it wins over an installed
// WhisperKit artifact, with reason "simulator". Devices keep the
// ANE-first order: WhisperKit whenever its artifact is installed.

enum OnDeviceSTTSelection {

    /// What the on-device stack should speak with.
    enum Choice: Equatable {
        /// WhisperKit (ANE on real hardware). The caller absorbs the
        /// load off the critical path via `prepare()` — DEVICE ONLY.
        case whisperKit
        /// whisper.cpp (CPU, per-attempt contexts). The reason records
        /// why the ANE path lost — event copy, never user-facing.
        case whisperCpp(reason: String)
        /// The SFSpeechRecognizer fallback — no whisper model usable.
        case fallback(reason: String)
    }

    /// Pure table. Order-independent of the caller's side effects.
    static func choose(whisperKitAvailable: Bool,
                       whisperCppAvailable: Bool,
                       isSimulator: Bool) -> Choice {
        switch (whisperKitAvailable, whisperCppAvailable, isSimulator) {
        case (true, _, false):
            // Device: ANE WhisperKit first — the medium-class models are
            // conversational on ANE (vs ~128 s CPU per clip).
            return .whisperKit
        case (true, true, true):
            // Simulator with both: force the cheaper startup path — the
            // CPU-only WhisperKit prepare never helps a sim conversation.
            return .whisperCpp(reason: "simulator")
        case (false, true, _):
            return .whisperCpp(reason: "whisperkit_unavailable")
        case (true, false, true):
            // Simulator with ONLY WhisperKit: still better than nothing.
            // The caller skips `prepare()` on the simulator either way,
            // so this path adds no startup load — the first utterance
            // pays it, exactly the pre-warm behavior.
            return .whisperKit
        case (false, false, _):
            return .fallback(reason: "no_whisper_model")
        }
    }

    /// Whether the caller should absorb the WhisperKit load now
    /// (`prepare()`). Device only — on the simulator the prepare is a
    /// CPU-only multi-minute load that can outlive the boot watchdog
    /// without ever helping a real conversation (the same honest reason
    /// the warm plan skips it there).
    static func shouldPrepareWhisperKit(isSimulator: Bool) -> Bool {
        !isSimulator
    }
}
