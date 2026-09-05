import Foundation

/// Which voice engine stack is active: the cloud Gemini pivot (default) or
/// the legacy on-device Whisper+LLaMA pipeline. A UI preference — not a
/// secret — so the household can A/B test both without rebuilding
/// (see `AppCoordinator.voiceEngineStack`, persisted the same way as
/// `sttModelPreference`).
enum VoiceEngineStack: String {
    case onDevice
    case gemini
}

/// Forwards `CommandInterpreter` calls to whichever concrete interpreter is
/// currently selected, so `CommandRouter` — which holds its `interpreter` as
/// a `private let` set once at construction — never has to change when the
/// user flips `AppCoordinator.voiceEngineStack` at runtime.
///
/// `AppCoordinator` constructs exactly ONE of these in `start()`, hands it to
/// `CommandRouter`, and updates `current` whenever the preference changes.
/// This class itself never chooses which interpreter to use — that decision
/// lives entirely in `AppCoordinator.applyVoiceEngineStack()`.
final class SwitchableCommandInterpreter: CommandInterpreter {
    var current: CommandInterpreter

    init(current: CommandInterpreter) {
        self.current = current
    }

    var isAvailable: Bool { current.isAvailable }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        current.interpret(transcript: transcript, context: context, completion: completion)
    }
}
