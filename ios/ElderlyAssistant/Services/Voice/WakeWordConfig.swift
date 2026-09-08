import Foundation

/// Wake-word ("Hey Sahayak") configuration surface — open item #4
/// (docs/OPEN-ITEMS.md). The pieces below (persisted toggle, pure
/// engine-selection decision, honest status derivation, live audio gate)
/// are the testable logic behind `AppCoordinator.makeWakeWordEngine()`
/// and the Settings → "Voice activation" screen, and they are deliberately
/// FREE of engine types (no sherpa, no Porcupine): the real engine is
/// injected as the selection's `sherpaCandidate` closure, so the whole
/// decision table is unit-testable without the sherpa-onnx SPM package
/// linked.
///
/// Selection, 2026-09-08 (voice-personalisation P0, slice A + settings
/// cleanup): the Picovoice/Porcupine free tier ended 2026-06-30, so the
/// sherpa-onnx keyword spotter (`SherpaKWSWakeWordEngine.attempt()`) is
/// the ONLY real engine candidate — it needs neither an access key nor a
/// trained `.ppn`: a bundled model directory + runtime `keywords.txt`
/// carry the "HEY SAHAYAK" keyword (tools/fetch-kws-model.sh fetches
/// both). It is invoked once the toggle is ON; when it declines (no model
/// in this build, or the runtime not linked), the caller falls back to
/// `NullWakeWordEngine` — the honest default — and `WakeWordStatus` is
/// derived from that same reality, so no screen can claim "listening"
/// while the engine is Null.

// MARK: - Persisted "listen for Hey Sahayak" toggle

/// The persisted on/off switch behind Settings → "Voice activation".
/// A UI preference, not a secret — UserDefaults is the right home (same
/// treatment as `sttModelPreference` / `voiceEngineStack`).
///
/// Defaults to ON. 2026-09-08 rationale: with the sherpa model bundled,
/// ON means the wake word is genuinely listening from the next launch on
/// with no extra Settings visit — the whole point of the feature
/// ("always on mic — like Siri"). When the model is absent from the
/// build the engine is Null regardless, exactly like before. The
/// battery/always-listening trade-off is disclosed on the Settings screen
/// (wakeWord.batteryNote), and the family can switch listening off here.
final class WakeWordPreferences {
    static let enabledKey = "wakeWord.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True unless someone has explicitly switched listening off.
    var isEnabled: Bool {
        guard defaults.object(forKey: Self.enabledKey) != nil else { return true }
        return defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}

// MARK: - Pure engine-selection decision

/// Decides between the sherpa-onnx KWS engine and the Null fallback.
/// 2026-09-06: factored OUT of `AppCoordinator.makeWakeWordEngine()` — and
/// out of any compile guard — so the whole decision table is unit-testable
/// without the sherpa package linked. The real engine's construction
/// arrives as the `sherpaCandidate` closure, which defaults to the
/// sherpa-onnx `attempt()` (bundle-direct model resolution).
/// 2026-09-08 (P0 slice A + settings cleanup): the legacy Porcupine chain
/// (access key + bundled `.ppn` + guarded init) is gone — the Porcupine
/// free tier ended 2026-06-30 and sherpa needs none of those artifacts.
/// The decision is now: toggle ON + a live sherpa candidate ⇒ real engine;
/// anything else ⇒ nil, and the caller falls back to `NullWakeWordEngine`
/// (the honest default until a model is installed). `sherpaCandidate` is
/// NOT invoked when the toggle is off (model load is not free).
enum WakeWordEngineSelection {
    static func make(toggleEnabled: Bool,
                     sherpaCandidate: () -> WakeWordEngine? = { SherpaKWSWakeWordEngine.attempt() }) -> WakeWordEngine? {
        // Master switch first — the engine must honor it.
        guard toggleEnabled else { return nil }
        return sherpaCandidate()
    }
}

// MARK: - Honest status for Settings → "Voice activation"

/// What the Settings row/screen must truthfully report (2026-09-06). The
/// screen exists so a family member can see — in one place — whether the
/// wake word is really listening, and exactly what is missing if not. No
/// dead ends: every non-active state names the concrete next step on the
/// screen (toggle, model note, restart note). 2026-09-08: the states now
/// describe the sherpa reality — "provisioned" means the sherpa runtime
/// is linked and the KWS model directory is bundled.
enum WakeWordStatus: Equatable {
    /// A real engine is live (built at launch) and listening is ON.
    case active
    /// The Settings toggle is OFF — deliberately not listening. Copy on
    /// the screen says how to re-enable and that the Talk button is
    /// unaffected.
    case off
    /// Listening is ON but this build is missing something the real engine
    /// needs (the sherpa runtime, or the bundled KWS model directory) —
    /// the Null engine is in place, i.e. today's exact pre-wake-word
    /// behavior.
    case needsSetup
    /// Listening is ON and everything is in place, but the engine was
    /// built at launch while listening was OFF (or the artifacts arrived
    /// after launch) — one relaunch activates it. The engine is fixed per
    /// launch by design; the copy says so instead of pretending.
    case restartToActivate
}

enum WakeWordStatusResolver {
    /// Pure status derivation. `realEngineAtLaunch` is recorded once at
    /// construction (`AppCoordinator.makeWakeWordEngine()`), `enabled` and
    /// `isProvisioned` are the live configuration.
    static func status(enabled: Bool,
                       isProvisioned: Bool,
                       realEngineAtLaunch: Bool) -> WakeWordStatus {
        guard enabled else { return .off }
        guard isProvisioned else { return .needsSetup }
        return realEngineAtLaunch ? .active : .restartToActivate
    }
}

// MARK: - Live activity gate (self-hearing mitigation + off switch)

/// Thread-safe "may the wake-word path act right now?" flag, consulted by
/// `VoicePipeline` for every idle-state audio chunk and for inbound wake
/// detections.
///
/// Two writers close the gate:
///  - Self-hearing (2026-09-06): while the assistant's own TTS reply is
///    playing, the mic hears it — the audio session is `.playAndRecord`
///    with `.measurement` mode and NO acoustic echo cancellation
///    (AudioSessionManager), so a reply containing the phrase "Hey
///    Sahayak" could otherwise wake the assistant mid-speech. Suppressing
///    here is deliberately conservative: we do NOT switch the global audio
///    session mode (a `.voiceChat`/AEC mode change is a regression risk
///    for the always-on tap and the recognizers that share it).
///  - The Settings "listen for Hey Sahayak" toggle: turning listening OFF
///    must stop keyword detection immediately, not at the next launch.
///
/// Reads happen on the mic tap's processing queue (`VoicePipeline`), while
/// writes come from the main queue (`AppCoordinator.noteSpeakingStarted/
/// Ended`, the Settings binding) — hence the lock rather than a bare Bool.
final class WakeWordActivityGate {
    private let lock = NSLock()
    private var speaking = false
    private var enabled = true

    /// Defaults match `WakeWordPreferences` (enabled) and the coordinator
    /// (not speaking); the coordinator syncs the gate from the restored
    /// preference during its init.
    ///
    /// Consulted before idle-state audio is fed to the engine: audio is
    /// dropped while the assistant speaks OR listening is switched off.
    /// (With listening off the engine is never fed, so it can never fire.)
    var allowsWakeWordAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && !speaking
    }

    /// Consulted when a wake detection (or the Talk button's simulated
    /// wake) is about to start a capture. Only the SPEAKING half applies:
    /// a keyword event already in flight when the reply started must not
    /// open a capture over the assistant's own speech, but the enable half
    /// is deliberately excluded so the Talk button keeps working with
    /// listening switched off (that path is human intent, and the audio
    /// feed is already stopped, so the engine cannot fire while disabled).
    var allowsWakeDetection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !speaking
    }

    func setSpeaking(_ speaking: Bool) {
        lock.lock()
        self.speaking = speaking
        lock.unlock()
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }
}
