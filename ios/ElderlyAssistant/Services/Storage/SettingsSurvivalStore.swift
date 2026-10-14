import Foundation

// [SETTINGS-SURVIVAL] (2026-10-14, owner invariant: "settings should be
// invariants of all updates — even if you uninstall, still keep the
// settings") The UserDefaults survival mirror.
//
// The iOS reality: the Keychain is the ONE store the OS keeps after an
// app uninstall; UserDefaults and the app container are wiped. The
// provider credentials, the Spotify session and — since the placement
// flip — the user profile already live in the Keychain
// (`StoragePlacementPolicy.keychainResidentKeys`). This store closes the
// last gap: every USER-SET scalar preference is snapshotted into one
// Keychain-resident blob (`settings.survival`) and restored on a fresh
// launch whose defaults are empty.
//
// SNAPSHOT POLICY: on scene background (the moment that precedes both an
// update and an uninstall) and after the onboarding interview, which is
// the write-heavy user moment. The snapshot is a small JSON dictionary
// (`[key: value]`) — values are the UserDefaults plist-compatible types
// the app already persists (strings, bools, numbers), never secrets the
// credential stores already own.
//
// RESTORE POLICY: for each key in the snapshot, write it ONLY when the
// live defaults carry no value for it — a real value always wins over
// the mirror, so a stale snapshot can never resurrect a preference the
// user changed after the snapshot. Every restore is observable
// (`settings_survival_restored`, count-only metadata).

final class SettingsSurvivalStore {

    /// The Keychain-resident blob key (see `StoragePlacementPolicy`).
    static let storageKey = "settings.survival"

    /// The user-set preferences that must survive an uninstall. Each key
    /// is a UserDefaults key already persisted elsewhere in the app —
    /// this list is the ONE place that decides which of them survive.
    /// Pinned by tests: a new user preference must be added here
    /// deliberately, not discovered after a wipe.
    static let survivalDefaultsKeys: [String] = [
        // Stack and models
        "voiceEngineStack",
        "brainModelPreferenceByLanguage",
        "sttModelPreferenceByLanguage",
        "ttsVoicePreferenceByLanguage",
        // Language and appearance
        "appLanguage",
        "appLocale",
        // Voice behavior
        "wakeWord.enabled",
        "noiseFilterEnabled",
        "dialectBiasEnabled",
        "dialectLabel",
        "voice.outputVolumePercent",
        "warmStartEngines",
        // Pre-intent layers (the correction chain's pins)
        "sttCorrection.mode",
        "sttCorrection.threshold",
        "intentEncoder.corrector",
        "intentEncoder.canonicalizer",
        "canonicalizer.enabled",
    ]

    private let storage: any EncryptedLocalStorage
    private let defaults: UserDefaults
    private let observabilityBus: ObservabilityBus?

    init(storage: any EncryptedLocalStorage = MigratingEncryptedStorage(),
         defaults: UserDefaults = .standard,
         observabilityBus: ObservabilityBus? = nil) {
        self.storage = storage
        self.defaults = defaults
        self.observabilityBus = observabilityBus
    }

    // MARK: - Snapshot

    /// Writes the current values of every survival key into the
    /// Keychain-resident blob. Silent success; failures are reported to
    /// the bus (`settings_survival_snapshot`, outcome).
    @discardableResult
    func snapshot() -> Bool {
        var payload: [String: PlistValue] = [:]
        for key in Self.survivalDefaultsKeys {
            guard let value = defaults.object(forKey: key),
                  let typed = PlistValue(any: value) else { continue }
            payload[key] = typed
        }
        let outcome: String
        switch storage.write(key: Self.storageKey, value: payload) {
        case .success:
            outcome = "success"
        case .failure:
            outcome = "failure"
        }
        observabilityBus?.emit(ObservabilityEvent(
            component: "settings_survival",
            eventType: "settings_survival_snapshot",
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: ["keys": String(payload.count)]))
        return outcome == "success"
    }

    // MARK: - Restore

    /// Writes the snapshot's values into the defaults for every key the
    /// live defaults do NOT already carry (a real value always wins).
    /// Returns the number of keys restored — a caller can use zero to
    /// prove the device was not a fresh install.
    @discardableResult
    func restore() -> Int {
        guard case .success(let payload) = storage.read(
            key: Self.storageKey, type: [String: PlistValue].self) else { return 0 }
        var restored = 0
        for key in Self.survivalDefaultsKeys {
            guard defaults.object(forKey: key) == nil,
                  let value = payload[key] else { continue }
            defaults.set(value.any, forKey: key)
            restored += 1
        }
        observabilityBus?.emit(ObservabilityEvent(
            component: "settings_survival",
            eventType: "settings_survival_restored",
            durationMs: nil,
            outcome: restored > 0 ? "restored" : "noop",
            errorCode: nil,
            metadata: ["keys": String(restored)]))
        return restored
    }
}

/// The type-erased UserDefaults value: strings, bools and numbers are
/// the only shapes the survival keys persist (the app's own writes are
/// the same three shapes). Codable so the snapshot travels as one
/// Keychain-resident JSON blob.
enum PlistValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)

    init?(any: Any) {
        if let value = any as? String { self = .string(value) }
        else if let value = any as? Bool { self = .bool(value) }
        else if let value = any as? NSNumber { self = .number(value.doubleValue) }
        else { return nil }
    }

    var any: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .number(let value): return value
        }
    }
}
