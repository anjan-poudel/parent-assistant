import Foundation

/// [T-037-a] Compile-time feature gate for the intent-encoder local brain.
///
/// The encoder is an INTERNAL-TESTING path in this phase, not a shipped
/// brain: its artifact is the T-036 v0 export — a baseline whose E4 harness
/// gates failed (closed-intent accuracy ~0.53, emergency recall ~0.9375,
/// publication withheld), now with the Swift XLM-R tokenizer
/// ([ENCODER-RUNTIME-READY]) and the artifact's companion meta.json wired
/// behind this gate. It must therefore be impossible for the encoder to
/// become the local brain in a release build by accident.
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

    /// The coordinator's gate decision, extracted so the SHIPPED call site
    /// — not a copy of it — is what the tests exercise (`AppCoordinator`
    /// calls this function directly).
    ///
    /// `resolve` is the caller's lazy factory and is invoked ONLY when the
    /// compilation condition is present: a non-gated build must never even
    /// construct the interpreter, which is the invariant documented at the
    /// lazy var's declaration.
    static func gatedEncoder(isEnabled: Bool = IntentEncoderFeature.isEnabled,
                             resolve: () -> IntentEncoderInterpreter?)
    -> IntentEncoderInterpreter? {
        guard isEnabled else { return nil }
        return resolve()
    }

    /// Metadata for the `encoder_selected_as_local_brain` event when the
    /// OFFERED encoder is the instance that actually took the `preferred`
    /// slot; nil otherwise (gate off, or offered but unavailable). The
    /// values are the instance's own manifest identity — fixed vocabulary,
    /// never user content.
    static func selectionEventMetadata(preferred: CommandInterpreter?,
                                       encoder: IntentEncoderInterpreter?)
    -> [String: String]? {
        guard let encoder, preferred === encoder else { return nil }
        return ["model_id": encoder.manifestIdentity.id,
                "model_version": encoder.manifestIdentity.version]
    }

    /// [ENCODER-RUNTIME-READY] The local-brain preference for the
    /// INTERNAL-TESTING path, as a deferred pair.
    ///
    /// `preferredLocalBrain` above answers "can the encoder serve RIGHT
    /// NOW?" — correct for the boot decision, but it pins the answer for
    /// the life of the process: `LocalBrainChain` holds the object it was
    /// given. That is exactly wrong for the install trigger, which lands
    /// the artifact asynchronously AFTER boot: the tester would have to
    /// relaunch before the encoder could ever be selected.
    ///
    /// This wraps the decision in a `LocalBrainChain` so availability is
    /// re-read on every turn (the chain's own rule), while the fallback
    /// object is EXACTLY the one the boot decision would have installed
    /// (the fine-tuned model when it can serve, else the stand-in). Once
    /// the install completes, the very next turn goes to the encoder; until
    /// then nothing about the chain's behaviour changes.
    ///
    /// The selection EVENT keeps its meaning because the caller emits it
    /// from `selectionEventMetadata(preferred:encoder:)` fed by
    /// `preferredLocalBrain` — the encoder-available-now decision — not by
    /// this wrapper.
    static func deferredEncoderPreference(encoder: IntentEncoderInterpreter?,
                                          fallback: CommandInterpreter)
    -> CommandInterpreter {
        guard let encoder else { return fallback }
        return LocalBrainChain(preferred: encoder, standIn: fallback)
    }
}
