import Foundation

/// [T-037-a] Compile-time feature gate for the intent-encoder local brain.
///
/// The encoder is an INTERNAL-TESTING path in this phase, not a shipped
/// brain: its artifact is the T-033 bake-off spike (legacy dataset, no
/// schema-v2 slot coverage, unmeasured calibration) and the Swift-side
/// tokenizer does not exist yet. It must therefore be impossible for the
/// encoder to become the local brain in a release build by accident.
///
/// The gate is a Swift compilation condition, not a runtime toggle, so a
/// build WITHOUT `INTENT_ENCODER` cannot even construct the interpreter's
/// wiring — the app builds and behaves exactly as it does today.
///
/// Internal-testing enablement (Debug/internal builds only):
///
///   xcodebuild ... SWIFT_ACTIVE_COMPILATION_CONDITIONS="\$(inherited) INTENT_ENCODER"
///
/// or add `INTENT_ENCODER` to the target's Active Compilation Conditions
/// in the Xcode UI for the internal-testing scheme. With the condition
/// present AND the artifact installed in `ModelStore` AND a ready
/// tokenizer, `AppCoordinator` offers the encoder as
/// `LocalBrainChain.preferred`; otherwise the chain keeps today's brain
/// (`LocalIntentInterpreter`, LLaMA stand-in).
///
/// Even when enabled, the keyword safety net (emergency, explicit
/// med-ack) runs upstream of every interpreter in `CommandRouter`, so no
/// encoder output can intercept or suppress those paths (FR-009).
enum IntentEncoderFeature {

    /// True when the build defines `INTENT_ENCODER`. Compiled-out on a
    /// non-gated build, so no test can flip it at runtime.
    static var isEnabled: Bool {
        #if INTENT_ENCODER
        return true
        #else
        return false
        #endif
    }
}

/// The wiring decision for the local-brain chain's `preferred` slot,
/// extracted as a pure function so the "shipped default is unchanged"
/// guarantee is unit-testable without an `AppCoordinator` instance.
enum IntentEncoderWiring {

    /// Returns the encoder when the caller OFFERS it (feature gate passed)
    /// and it can actually serve; otherwise returns the fallback — today's
    /// `LocalIntentInterpreter`. Identity equality lets tests prove the
    /// fallback instance is installed untouched.
    ///
    /// NOTE: `IntentRouter`, `CommandRouter`, `LocalBrainChain`,
    /// `TranscriptSanityGuard`, `IntentCommandCache` and the confirmation
    /// flow are deliberately NOT modified — the encoder only ever occupies
    /// the existing `preferred` slot, and the stand-in (LLaMA) is
    /// unchanged.
    static func preferredLocalBrain(encoder: CommandInterpreter?,
                                    fallback: CommandInterpreter) -> CommandInterpreter {
        guard let encoder, encoder.isAvailable else { return fallback }
        return encoder
    }
}
