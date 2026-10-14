import Foundation
import Security

// MARK: - The durable settings seam ([SETTINGS-PERSIST], 2026-10-14)

/// The one place every household setting survives a reinstall.
///
/// The owning problem (owner report, 2026-10-14): "settings disappear
/// with new installs every now and then — I have to rekey API keys and
/// stuff". Two distinct causes were found:
///
///  1. EVERY owner-facing preference (theme, text size, model picks,
///     quick apps, call picks, voice toggles, calendar switches, the
///     lot) lived in `UserDefaults`, which iOS DELETES when the app is
///     uninstalled — by design. A reinstall is a fresh defaults domain.
///  2. The API keys were already Keychain-resident (see
///     `StoragePlacementPolicy.keychainResidentKeys` +
///     `KeychainEncryptedStorage`) — but Keychain items are bound to
///     the app's access group (signing team + bundle id). The macOS-era
///     rebrand (`com.elderlyassistant.app` →
///     `ai.voicebridge.senior.assistant`) and the signing-team flip
///     recorded in `project.yml` each change that group, orphaning the
///     old items — which is why the keys specifically needed re-keying.
///     That half is a signing/identity fact this file cannot fix in
///     code (documented as a risk in the task report); the settings
///     keychain service below at least gives the SETTINGS their own
///     durable home going forward.
///
/// ## Shape
///
/// `SettingsPersistence` is a `UserDefaults` subclass, so every store
/// in the house that already takes `defaults: UserDefaults = .standard`
/// accepts it with no signature changes and no new protocol — the seam
/// is injected by DEFAULT ARGUMENT (`= SettingsPersistence.shared` in
/// every owner-facing store) and by construction (`AppCoordinator`'s
/// own preference sites, `AppLanguage`). The subclass-override dispatch
/// was verified empirically before adoption (a swiftc probe intercepting
/// `string/bool/integer/double/data/stringArray/object(forKey:)`,
/// `set(_:Any?,forKey:)` and `removeObject(forKey:)`, including when
/// the instance travels through a `UserDefaults`-typed parameter —
/// which is exactly how the stores receive it).
///
/// ## Storage model
///
///  - **Keychain is the durable record.** Each key is one
///    `kSecClassGenericPassword` item: service
///    `ai.voicebridge.senior.assistant.settings` (the bundle-id
///    namespace), account = the UserDefaults key name (unchanged —
///    that is what lets a legacy install be backfilled 1:1), value =
///    a JSON `StoredValue`. Accessibility
///    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: survives app
///    deletion, never migrates to another device, never syncs via
///    iCloud Keychain (`kSecAttrSynchronizable` false). The settings
///    are needed on every launch — AfterFirstUnlock is the right class
///    for values the app may read before/without a foreground unlock,
///    and ThisDeviceOnly keeps a household's choices on the
///    household's phone.
///  - **UserDefaults stays the fallback.** Reads: keychain first, then
///    the fallback (an un-migrated legacy install, a keychain failure,
///    simulator quirks). Writes: keychain + a write-through mirror to
///    the fallback for non-secret keys, so every reader that has not
///    been migrated yet (and every existing test that asserts on
///    `UserDefaults.standard`) keeps seeing the value. Once the
///    keychain holds a key, the fallback copy is a cache — the
///    keychain wins.
///  - **Secrets are never mirrored.** The keys that
///    `StoragePlacementPolicy` already routes to the Keychain
///    (`gemini.apiKey`, `search.apiKey`, `search.engineId`,
///    `youtube.apiKey`, `spotify.session`) must never land in a
///    UserDefaults plist; the seam refuses to mirror them even if one
///    is written through it. (Those keys are also skipped by the
///    backfill — `MigratingEncryptedStorage` owns their migration.)
///
/// ## Migration / backfill
///
/// `backfillFromUserDefaults()` copies each `backfillKeys` entry that
/// exists in the fallback but not yet in the keychain — exactly once,
/// because the copy makes the keychain hold the key and later runs
/// skip it. It runs on the boot queue in `bootRestoreData()` (see
/// `AppCoordinator.start()`), AFTER the init-time restores, so a first
/// launch of the new build on an old install migrates silently. It
/// never deletes the fallback copies (they are the fallback) and never
/// clobbers a keychain value (keychain wins).
///
/// ## Tests
///
/// `SettingsPersistence.shared` DETECTS XCTest (the runner's
/// `XCTestConfigurationFilePath` / `XCTestBundlePath` environment, or
/// the `XCTestCase` class) and runs in PASSTHROUGH mode: no keychain
/// reads, no keychain writes, everything through the fallback
/// (`UserDefaults.standard`) — byte-identical to the pre-seam behavior.
/// That is what keeps the coordinator suites that construct the real
/// `AppCoordinator` over the real standard defaults hermetic without
/// touching their assertions, and keeps test junk out of the
/// production keychain service. The keychain machinery itself is
/// exercised by `SettingsPersistenceTests` through fully-scoped
/// instances (`SettingsPersistence.make(service:fallback:)`, unique
/// per test).
///
/// ## Threading
///
/// `SecItem*` and `UserDefaults` are both thread-safe, so the seam is
/// by construction. The in-memory read cache (the coordinator reads
/// ~20 settings during init, and Settings screens re-read on body
/// evaluation — a 60 Hz slider must not turn into 60 Keychain queries)
/// is guarded by its own lock. All writes go through this seam, so the
/// cache cannot go stale behind it.
final class SettingsPersistence: UserDefaults {

    /// The production keychain service — namespaced under the app's
    /// bundle id, distinct from the encrypted-storage service
    /// (`com.elderlyassistant.storage`) so the settings items and the
    /// secret items never share an audit surface.
    static let service = "ai.voicebridge.senior.assistant.settings"

    /// The single production instance. `AppLanguage`, `AppCoordinator`
    /// and every store whose `defaults:` parameter defaults to
    /// `SettingsPersistence.shared` go through here.
    static let shared: SettingsPersistence = {
        let store = SettingsPersistence()
        if store.isRunningUnderXCTest {
            // Passthrough: fallback-only semantics, no keychain I/O.
            // See the Tests section of the type doc — this is what
            // keeps every existing coordinator suite hermetic.
            store.keychainEnabled = false
        }
        return store
    }()

    /// A fully-scoped instance for tests: a unique `service` = keychain
    /// space that never touches the production items, and an explicit
    /// `fallback` suite.
    static func make(service: String,
                     fallback: UserDefaults,
                     keychainEnabled: Bool = true) -> SettingsPersistence {
        let store = SettingsPersistence()
        store.serviceName = service
        store.fallback = fallback
        store.keychainEnabled = keychainEnabled
        return store
    }

    // MARK: Configuration (defaults target production; `make` retargets)

    /// Whether the keychain half runs at all. False under XCTest
    /// (`.shared`) and settable by tests. With it false the seam is a
    /// pure UserDefaults pass-through.
    private var keychainEnabled = true

    private var serviceName = SettingsPersistence.service

    /// The UserDefaults half: the write-through mirror, and the read
    /// fallback when the keychain holds no value for a key.
    private var fallback: UserDefaults = .standard

    // MARK: The owner-facing key list (backfill input)

    /// Every owner-facing preference key this seam migrates and keeps
    /// durable. Deliberately an explicit reviewed list (the
    /// `StoragePlacementPolicy.keychainResidentKeys` pattern): a new
    /// owner-facing key added later must be consciously listed here to
    /// be backfilled, and `SettingsPersistenceTests` pins the list's
    /// shape in both directions. Keys NOT listed either belong to
    /// another channel already (the encrypted stores) or are
    /// deliberately volatile — the omissions are named in the suite.
    static let backfillKeys: Set<String> = [
        // App language + formatting locale (AppLanguage / AppLocale).
        "appLanguage",
        "appLocale",
        // Appearance (AppCoordinator).
        "appTheme",
        "appVisualStyle",
        "appTextSize",
        // Model picks, global + per-language memory.
        "sttModelPreference",
        "brainModelPreference",
        "sttModelPreferenceByLanguage",
        "brainModelPreferenceByLanguage",
        // Calling + navigation picks.
        "defaultCallApp",
        "secondaryCallApp",
        "navigationMapApp",
        // Voice stack + engines.
        "voiceEngineStack",
        "voiceProcessingEnabled",
        "noiseFilterEnabled",
        "warmStartEngines",
        "wakeWord.enabled",
        "dialectBiasEnabled",
        // Reply voice.
        "ttsResponseVoiceSelection",
        "ttsVoicePreferenceByLanguage",
        "voice.outputVolumePercent",
        // Cloud tiers.
        "cloudFallbackEnabled",
        "cloudProvider",
        "cloudCascade.threshold",
        "cloudCascade.enabled",
        // Home quick-access row.
        "quickAccessApps",
        // Medications / appointments.
        "appointmentsToCalendar",
        "appointmentSmsNoteDismissed.v1",
        // Calendar display + sync + sharing.
        "calendarDisplay.seeded.v1",
        "calendarDisplay.defaultCalendar.v1",
        "calendarDisplay.bsOverlay.v1",
        "calendarDisplay.tithiOverlay.v1",
        "calendarSync.enabled",
        "calendarSync.twoWayEnabled",
        "calendarShare.consentAccepted",
        "calendarShare.inboundSyncToken",
        "externalCalendar.enabled",
        "externalCalendar.leadMinutes",
        "festivalCalendar.advanceReminderDays",
        // Caregiver notifications.
        "caregiverNotify.medicationReminder",
        "caregiverNotify.routineReminder",
        "caregiverNotify.calendarEvent",
        // Live translate — the owner-facing switches only.
        // ("livetranslate.translationDebugLoggingEnabled" is a
        // developer diagnostic and is deliberately NOT backfilled;
        // a value the debugger sets still persists through the seam
        // once it is written with the new build.)
        "livetranslate.alwaysShowOriginal",
        "livetranslate.geminiCloudEnabled",
        "livetranslate.enabled"
    ]

    /// Keys that must NEVER be mirrored into UserDefaults and are never
    /// backfilled — the secrets `StoragePlacementPolicy` already routes
    /// to the Keychain (their own store, `MigratingEncryptedStorage`,
    /// owns their migration). Aliased rather than re-listed so the two
    /// policies cannot drift.
    static let neverMirroredKeys: Set<String> = StoragePlacementPolicy.keychainResidentKeys

    // MARK: One-time backfill

    /// Copies every `backfillKeys` value that exists in the fallback
    /// but not yet in the keychain. Idempotent by construction (a
    /// copied key makes the keychain hold it, so the next run skips
    /// it); safe to run on the boot queue. Never touches secrets, never
    /// deletes the fallback copy, never overwrites a keychain value.
    func backfillFromUserDefaults() {
        guard keychainEnabled else { return }
        for key in Self.backfillKeys where !Self.neverMirroredKeys.contains(key) {
            // Keychain wins — an existing item is the household's value.
            if readKeychain(key) != nil { continue }
            guard let raw = fallback.object(forKey: key),
                  let value = StoredValue.from(raw) else { continue }
            if writeKeychain(value, key: key) {
                cacheSet(key, .value(value))
            }
        }
    }

    /// Test-only wipe: deletes every item THIS service holds (the
    /// scratch service in tests — never the production one unless
    /// someone means it). The fallback is the caller's domain and is
    /// left alone.
    func removeAllStoredItems() {
        guard keychainEnabled else { return }
        SecItemDelete(baseQuery(account: nil) as CFDictionary)
        cacheRemoveAll()
    }

    // MARK: UserDefaults overrides — reads (keychain first, fallback second)

    override func object(forKey key: String) -> Any? {
        if let stored = keychainValue(forKey: key) { return stored.objectValue }
        return fallback.object(forKey: key)
    }

    override func string(forKey key: String) -> String? {
        if let stored = keychainValue(forKey: key) {
            guard case .string(let value) = stored else { return nil }
            return value
        }
        return fallback.string(forKey: key)
    }

    override func bool(forKey key: String) -> Bool {
        if let stored = keychainValue(forKey: key) {
            guard case .bool(let value) = stored else { return false }
            return value
        }
        return fallback.bool(forKey: key)
    }

    override func integer(forKey key: String) -> Int {
        if let stored = keychainValue(forKey: key) {
            switch stored {
            case .int(let value): return value
            case .double(let value): return Int(value)
            case .bool(let value): return value ? 1 : 0
            default: return 0
            }
        }
        return fallback.integer(forKey: key)
    }

    override func double(forKey key: String) -> Double {
        if let stored = keychainValue(forKey: key) {
            switch stored {
            case .double(let value): return value
            case .int(let value): return Double(value)
            case .bool(let value): return value ? 1 : 0
            default: return 0
            }
        }
        return fallback.double(forKey: key)
    }

    override func stringArray(forKey key: String) -> [String]? {
        if let stored = keychainValue(forKey: key) {
            guard case .stringArray(let value) = stored else { return nil }
            return value
        }
        return fallback.stringArray(forKey: key)
    }

    override func data(forKey key: String) -> Data? {
        if let stored = keychainValue(forKey: key) {
            guard case .data(let value) = stored else { return nil }
            return value
        }
        return fallback.data(forKey: key)
    }

    // MARK: UserDefaults overrides — writes (keychain truth + mirror)

    override func set(_ value: Any?, forKey key: String) {
        // `set(nil, forKey:)` is documented as `removeObject(forKey:)`.
        guard let value else {
            removeObject(forKey: key)
            return
        }
        guard let encoded = StoredValue.from(value) else {
            // A type this seam does not encode (none of the listed keys
            // uses one) — keep the old behavior exactly: fallback only,
            // no durability promise, no crash.
            fallback.set(value, forKey: key)
            return
        }
        if keychainEnabled {
            // Best-effort: a Keychain failure leaves the mirror as the
            // record for THIS install (exactly the pre-seam behavior),
            // and the next write retries.
            _ = writeKeychain(encoded, key: key)
            cacheSet(key, .value(encoded))
        }
        if !Self.neverMirroredKeys.contains(key) {
            fallback.set(value, forKey: key)
        }
    }

    override func removeObject(forKey key: String) {
        if keychainEnabled {
            SecItemDelete(baseQuery(account: key) as CFDictionary)
            cacheSet(key, .absent)
        }
        fallback.removeObject(forKey: key)
    }

    // MARK: Stored value (the keychain payload)

    /// The typed keychain payload: exactly the value types the listed
    /// keys use. Codable synthesis gives the JSON a self-describing
    /// shape, so a stored value can never be misread as another type.
    enum StoredValue: Codable, Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)
        case double(Double)
        case stringArray([String])
        case data(Data)

        /// The `Any?` form handed back to `object(forKey:)`.
        var objectValue: Any {
            switch self {
            case .string(let value): return value
            case .bool(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .stringArray(let value): return value
            case .data(let value): return value
            }
        }

        /// Type sniffing for the values that actually arrive from the
        /// house's stores (they call the Swift `set` conveniences with
        /// String / Bool / Int / Double / [String] / Data). Pure-Swift
        /// casts only: struct targets do not bridge, so an Int can
        /// never be misread as a Bool. NSNumber is still handled for
        /// safety (an ObjC caller), guarded by the CFBoolean type id.
        static func from(_ value: Any) -> StoredValue? {
            if let string = value as? String { return .string(string) }
            if let bool = value as? Bool { return .bool(bool) }
            if let int = value as? Int { return .int(int) }
            if let double = value as? Double { return .double(double) }
            if let float = value as? Float { return .double(Double(float)) }
            if let array = value as? [String] { return .stringArray(array) }
            if let data = value as? Data { return .data(data) }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return .bool(number.boolValue)
                }
                switch String(cString: number.objCType) {
                case "f", "d": return .double(number.doubleValue)
                default: return .int(number.intValue)
                }
            }
            return nil
        }
    }

    // MARK: Keychain layer (the `KeychainEncryptedStorage` pattern,
    //          its own service + accessibility)

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            // Bind to this device; never sync via iCloud Keychain —
            // a household's settings are this phone's settings.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private func readKeychain(_ key: String) -> StoredValue? {
        var query = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(StoredValue.self, from: data)
    }

    @discardableResult
    private func writeKeychain(_ value: StoredValue, key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let query = baseQuery(account: key)
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        default:
            return false
        }
    }

    // MARK: Read cache (launch reads + Settings re-renders)

    private enum CacheEntry {
        case absent
        case value(StoredValue)
    }

    private let cacheLock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    /// The keychain value for `key`: the cache when it knows, else one
    /// `SecItemCopyMatching` whose result — value OR absence — is
    /// cached. Absence is cached too (an un-migrated install must not
    /// pay a miss per read), and every write / remove through this
    /// seam updates the cache, so it cannot serve a stale record.
    private func keychainValue(forKey key: String) -> StoredValue? {
        guard keychainEnabled else { return nil }
        if let entry = cacheGet(key) {
            switch entry {
            case .value(let stored): return stored
            case .absent: return nil
            }
        }
        let stored = readKeychain(key)
        cacheSet(key, stored.map { CacheEntry.value($0) } ?? .absent)
        return stored
    }

    private func cacheGet(_ key: String) -> CacheEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func cacheSet(_ key: String, _ entry: CacheEntry) {
        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()
    }

    private func cacheRemoveAll() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: XCTest detection

    /// True inside the unit-test runner. `XCTestConfigurationFilePath`
    /// and `XCTestBundlePath` are set by the runner for every hosted
    /// test bundle; the class check covers runners that set neither.
    /// Detected once, in the `.shared` factory.
    private var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
