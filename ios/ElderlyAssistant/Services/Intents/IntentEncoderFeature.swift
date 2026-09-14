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
/// The gate is a Swift compilation condition, so a build WITHOUT
/// `INTENT_ENCODER` cannot even construct the interpreter's wiring — the
/// app builds and behaves exactly as it does today.
///
/// [ENCODER-RUNTIME-TOGGLE] Compiling the condition in is necessary but
/// no longer sufficient: the tester ALSO has to switch the encoder on in
/// Settings → AI मोडेल (hidden; long-press the Settings title) →
/// "on-device intent encoder". The toggle is the persisted
/// `IntentEncoderPreferences` value (`intentEncoder.enabled`, default
/// OFF), so a flagged build still ships the incumbent brain until someone
/// opts in, and a flagged device can A/B the encoder against the picker
/// brain from the same install by flipping one switch.
///
/// [ENCODER-RUNTIME-CASCADE] A second, independent switch
/// (`intentEncoder.cascade`, same card, default OFF) widens the A/B to a
/// third leg: ON, the encoder answers first and the picker brain answers
/// the SAME turn whenever the encoder abstains or lands below the
/// router's ACCEPT band; OFF, the encoder answers alone (the
/// [ENCODER-RUNTIME-TOGGLE] behaviour). It is ignored while the enable
/// switch is off — see `IntentEncoderWiring.servingMode`.
///
/// Internal-testing enablement (Debug/internal builds only):
///
///   xcodebuild ... SWIFT_ACTIVE_COMPILATION_CONDITIONS="\$(inherited) INTENT_ENCODER"
///
/// or add `INTENT_ENCODER` to the target's Active Compilation Conditions
/// in the Xcode UI for the internal-testing scheme. With the condition
/// present AND the runtime toggle ON AND the artifact installed in
/// `ModelStore` AND a ready tokenizer, `AppCoordinator` offers the
/// encoder as `LocalBrainChain.preferred`; otherwise the chain keeps
/// today's brain (`LocalIntentInterpreter`, LLaMA stand-in) and no error
/// is surfaced — a missing artifact or a flipped-off switch is a normal,
/// silent fall-through, never a failure the user has to read.
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

/// [ENCODER-RUNTIME-TOGGLE] The persisted on/off switch behind Settings →
/// AI मोडेल (the hidden internal screen) → "on-device intent encoder".
///
/// A UI preference, not a secret — UserDefaults is the right home (same
/// treatment as `WakeWordPreferences.enabledKey` /
/// `sttModelPreference` / `voiceEngineStack`).
///
/// Defaults to OFF, unlike `WakeWordPreferences`: the encoder is an
/// internal-testing artifact whose published run does not meet every
/// harness gate (publication withheld), so SERVING it must be an explicit
/// tester decision. The compilation condition alone is not consent. An
/// absent key reads as false, so a device that never opened the screen
/// serves the picker brain.
///
/// The key is deliberately namespaced away from the shipped preferences:
/// `intentEncoder.enabled` can be set (or cleared) from a debugger or a
/// UITest launch argument without touching any user-facing setting.
final class IntentEncoderPreferences {
    static let enabledKey = "intentEncoder.enabled"
    /// [ENCODER-RUNTIME-CASCADE] The cascade switch, same treatment and
    /// same default.
    static let cascadeKey = "intentEncoder.cascade"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True only when someone has explicitly switched the encoder on.
    var isEnabled: Bool {
        guard defaults.object(forKey: Self.enabledKey) != nil else { return false }
        return defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    /// [ENCODER-RUNTIME-CASCADE] True only when someone has explicitly
    /// switched the cascade on. Absent key reads as false, so an
    /// enable-only device gets the standalone encoder, and the cascade is
    /// never in play on a build whose enable switch was never touched.
    var isCascadeEnabled: Bool {
        guard defaults.object(forKey: Self.cascadeKey) != nil else { return false }
        return defaults.bool(forKey: Self.cascadeKey)
    }

    func setCascadeEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.cascadeKey)
    }
}

/// The wiring decision for the local-brain chain's `preferred` slot,
/// extracted as a pure function so the "shipped default is unchanged"
/// guarantee is unit-testable without an `AppCoordinator` instance.
enum IntentEncoderWiring {

    /// [ENCODER-RUNTIME-TOGGLE] The serving decision: the compile-time
    /// gate AND the tester's persisted toggle. Both must be true before
    /// the encoder may occupy the local-brain slot.
    ///
    /// The toggle can only ever SUBTRACT from what the compilation
    /// condition allows: with `INTENT_ENCODER` absent the result is false
    /// whatever the stored preference says, so a release build cannot be
    /// talked into the encoder path by a stale UserDefaults value.
    static func isServingEnabled(isCompiledIn: Bool = IntentEncoderFeature.isEnabled,
                                 isToggleOn: Bool) -> Bool {
        isCompiledIn && isToggleOn
    }

    /// [ENCODER-RUNTIME-CASCADE] How the local-brain slot is served, from
    /// the two persisted switches. `isEnabled` is the compose gate above
    /// (compilation condition AND enable toggle), so the cascade can only
    /// ever choose between the two encoder modes — never opt a build into
    /// the encoder path, and never past the enable switch.
    ///
    ///  - `.pickerBrain` — the encoder is not in play: the picker brain
    ///    holds the local slot exactly as on a non-gated build.
    ///  - `.standaloneEncoder` — the encoder holds the slot ALONE, so an
    ///    abstention falls through to the router's own policy (band →
    ///    cloud escalation → re-prompt), unchanged.
    ///  - `.encoderFirstEscalate` — the encoder answers first; on an
    ///    abstention or a sub-band answer the picker brain answers the
    ///    SAME turn (one turn, one answer, no second prompt).
    enum ServingMode: Equatable {
        case pickerBrain
        case standaloneEncoder
        case encoderFirstEscalate
    }

    static func servingMode(isEnabled: Bool,
                            isCascadeOn: Bool) -> ServingMode {
        guard isEnabled else { return .pickerBrain }
        return isCascadeOn ? .encoderFirstEscalate : .standaloneEncoder
    }

    /// [ENCODER-RUNTIME-CASCADE] The cascade's serve-or-escalate line:
    /// the router's OWN ACCEPT band, so "the encoder serves" means exactly
    /// what it means in `IntentRouter.bandChecked` — one number, not two.
    static let cascadeAcceptThreshold = IntentRouter.Config.default.acceptThreshold

    /// [ENCODER-RUNTIME-CASCADE] Builds the local-brain slot for a serving
    /// mode. `.pickerBrain` and `.standaloneEncoder` produce the SAME
    /// chain shape as before this switch existed (the deferred encoder
    /// pair in the `preferred` slot, the picker brain as the stand-in);
    /// only `.encoderFirstEscalate` attaches a cascade, and the cascade
    /// then escalates to that SAME picker brain — one turn, one answer.
    ///
    /// `onEscalated` is consulted only in the cascade mode; the default
    /// no-op keeps the non-cascading call sites honest (nothing to report).
    static func localBrainSlot(mode: ServingMode,
                               encoder: IntentEncoderInterpreter?,
                               encoderFallback: CommandInterpreter,
                               pickerBrain: CommandInterpreter,
                               onEscalated: @escaping (LocalBrainChain.EscalationReason) -> Void = { _ in })
    -> CommandInterpreter {
        let preferredLocal = deferredEncoderPreference(encoder: encoder,
                                                       fallback: encoderFallback)
        let cascade: LocalBrainChain.Cascade? = mode == .encoderFirstEscalate
            ? LocalBrainChain.Cascade(acceptThreshold: cascadeAcceptThreshold,
                                      onEscalated: onEscalated)
            : nil
        return LocalBrainChain(preferred: preferredLocal,
                               standIn: pickerBrain,
                               cascade: cascade)
    }

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
