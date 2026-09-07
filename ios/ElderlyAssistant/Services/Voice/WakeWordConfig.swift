import Foundation

/// Wake-word ("Hey Sahayak") configuration surface — open item #4
/// (docs/OPEN-ITEMS.md). Everything here is deliberately FREE of Porcupine
/// types: the pieces below (persisted toggle, encrypted access-key store,
/// pure engine-selection decision, honest status derivation, live audio
/// gate) are the testable logic behind `AppCoordinator.makeWakeWordEngine()`
/// and the Settings → "Voice activation" screen. The only Porcupine-touching
/// code in the app stays behind `#if canImport(Porcupine)` in
/// `WakeWordEngine.swift` and `AppCoordinator` — nothing in this file may
/// reference it, so the whole decision table is unit-testable without the
/// SPM package linked.
///
/// Selection, 2026-09-08 (voice-personalisation P0, slice A): the Porcupine
/// free tier ended 2026-06-30, so the sherpa-onnx keyword spotter is now
/// the FIRST real engine candidate — `SherpaKWSWakeWordEngine.attempt()` is
/// invoked once the toggle is ON, and needs neither access key nor `.ppn`
/// (a bundled model directory + runtime `keywords.txt` carry the keyword;
/// tools/fetch-kws-model.sh fetches both). It wins whenever a model is
/// installed. Only when it declines (no model in this build) does the
/// Porcupine chain below decide as it always has — `WakeWordStatus` is
/// derived from that same reality, so nothing here changed for it. The
/// Porcupine flow itself is legacy: trained `.ppn` dropped into
/// ios/ElderlyAssistant/Resources/ + access key in Settings/Info.plist —
/// still supported, never preferred.

// MARK: - Persisted "listen for Hey Sahayak" toggle

/// The persisted on/off switch behind Settings → "Voice activation".
/// A UI preference, not a secret — UserDefaults is the right home (same
/// treatment as `sttModelPreference` / `voiceEngineStack`).
///
/// Defaults to ON. 2026-09-06 rationale: the toggle is inert until the
/// access key + trained `.ppn` exist, and NO shipped build has either
/// artifact — so ON today changes nothing (the engine is Null regardless,
/// and the mic tap itself is already always-on either way; VoicePipeline
/// installs it at startup). When the artifacts do land, ON means the wake
/// word activates at the next launch with no extra Settings visit, which
/// is the whole point of the feature ("always on mic — like Siri"). The
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

// MARK: - Encrypted access-key store (Settings paste-in field)

/// Holds the Picovoice access key that a family member pastes into
/// Settings → "Voice activation" — an exact mirror of `GeminiConfigStore`
/// (same `EncryptedLocalStorage` = Keychain, Data Protection Complete;
/// never UserDefaults, never hardcoded). `AppCoordinator.makeWakeWordEngine()`
/// reads it as the fallback when the build-time Info.plist
/// (`PicovoiceAccessKey`) is absent.
final class WakeWordAccessKeyStore: ObservableObject {
    static let storageKey = "wakeWord.picovoiceAccessKey"

    private let storage: EncryptedLocalStorage

    @Published private(set) var accessKey: String?

    var isConfigured: Bool { accessKey != nil }

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.accessKey = Self.load(storage: storage)
    }

    /// Where the access key can come from, in priority order. Exposed as a
    /// pure function so the precedence rule is unit-testable: a build-time
    /// Info.plist key (team builds) wins over the Settings paste-in value.
    static func resolvedAccessKey(plistKey: String?, storedKey: String?) -> String? {
        normalized(plistKey) ?? normalized(storedKey)
    }

    /// Trims and rejects blank strings (mirrors `GeminiConfigStore.save`).
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        _ = storage.write(key: Self.storageKey, value: trimmed)
        accessKey = trimmed
    }

    func clear() {
        _ = storage.delete(key: Self.storageKey)
        accessKey = nil
    }

    private static func load(storage: EncryptedLocalStorage) -> String? {
        guard case .success(let value) = storage.read(key: storageKey, type: String.self),
              !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Bundled keyword-file lookup

/// The trained "Hey Sahayak" keyword file expected in the app bundle
/// (ios/ElderlyAssistant/Resources/hey-sahayak_ios.ppn). Filename split so
/// `Bundle.path(forResource:ofType:)` gets its two halves.
enum WakeWordModelFile {
    static let baseName = "hey-sahayak_ios"
    static let fileExtension = "ppn"

    /// Absolute path of the bundled `.ppn`, or nil when this build has no
    /// keyword file (the normal state until a family member drops one in).
    static func bundledPath(in bundle: Bundle = .main) -> String? {
        bundle.path(forResource: baseName, ofType: fileExtension)
    }
}

// MARK: - Pure engine-selection decision

/// Decides between the sherpa-onnx KWS engine, the legacy Porcupine
/// engine, and the Null fallback.
/// 2026-09-06: factored OUT of `AppCoordinator.makeWakeWordEngine()` — and
/// out of the `#if canImport(Porcupine)` guard — so the whole decision
/// table is unit-testable without the Porcupine package linked. The real
/// engine's construction arrives as the `build` closure, which the app
/// target only supplies inside its existing compile guard.
/// 2026-09-08 (P0 slice A): sherpa-onnx KWS candidate added in FRONT of the
/// Porcupine chain (see file header). The `sherpaCandidate` closure is a
/// trailing default so every existing call site and test keeps compiling
/// unchanged — with no KWS model bundled the default attempt returns nil
/// and the Porcupine/Null chain below decides exactly as before.
enum WakeWordEngineSelection {
    /// Returns the real engine when EVERY precondition holds:
    ///  0. the persisted Settings toggle is ON — OFF means the Null engine
    ///     even when a key + .ppn or a sherpa model are present (master
    ///     switch);
    ///  1. a sherpa-onnx KWS model directory is installed — then the
    ///     sherpa engine is used: no access key, no `.ppn` (the keyword
    ///     lives in the model's runtime keywords.txt);
    ///  2. otherwise an access key exists (Porcupine);
    ///  3. otherwise the keyword `.ppn` exists in the bundle (Porcupine);
    ///  4. otherwise `build` succeeds (Porcupine init can throw on a bad
    ///     key).
    /// Any failure returns nil and the caller falls back to
    /// `NullWakeWordEngine` — the honest default until real artifacts
    /// exist. `build` is NOT invoked when the toggle is off, a sherpa
    /// model is live, or an artifact is missing (Porcupine init is not
    /// free; the sherpa spotter is loaded by its own attempt closure).
    static func make(toggleEnabled: Bool,
                     accessKey: String?,
                     keywordPath: String?,
                     build: (_ accessKey: String, _ keywordPath: String) -> WakeWordEngine?,
                     sherpaCandidate: () -> WakeWordEngine? = { SherpaKWSWakeWordEngine.attempt() }) -> WakeWordEngine? {
        // Master switch first — both engines must honor it.
        guard toggleEnabled else { return nil }
        // sherpa-first: present model ⇒ prefer it over legacy Porcupine.
        if let sherpaEngine = sherpaCandidate() {
            return sherpaEngine
        }
        // Legacy Porcupine chain, byte-for-byte as before.
        guard let accessKey = WakeWordAccessKeyStore.normalized(accessKey),
              let keywordPath = WakeWordAccessKeyStore.normalized(keywordPath) else {
            return nil
        }
        return build(accessKey, keywordPath)
    }
}

// MARK: - Honest status for Settings → "Voice activation"

/// What the Settings row/screen must truthfully report (2026-09-06). The
/// screen exists so a family member can see — in one place — whether the
/// wake word is really listening, and exactly what is missing if not. No
/// dead ends: every non-active state names the concrete next step on the
/// screen (toggle, setup checklist, restart note).
enum WakeWordStatus: Equatable {
    /// A real engine is live (built at launch) and listening is ON.
    case active
    /// The Settings toggle is OFF — deliberately not listening. Copy on
    /// the screen says how to re-enable and that the Talk button is
    /// unaffected.
    case off
    /// Listening is ON but this build is missing something the real engine
    /// needs (runtime link, access key, or the bundled keyword file) — the
    /// Null engine is in place, i.e. today's exact pre-wake-word behavior.
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
