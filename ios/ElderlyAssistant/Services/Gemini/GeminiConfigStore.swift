import Foundation

/// Holds the Gemini API key (v2 pivot — see
/// docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md). Stored via
/// the same `EncryptedLocalStorage` (Keychain, Data Protection Complete)
/// used for family contacts and other sensitive local state — never in
/// `UserDefaults`, never hardcoded.
///
/// The key is expected to be entered by a family member during setup (or
/// via Settings later), not typed by the elderly primary user — same
/// "family configures remotely" framing as the rest of the app's sensitive
/// configuration.
final class GeminiConfigStore: ObservableObject {
    private static let storageKey = "gemini.apiKey"
    private static let modelStorageKey = "gemini.model"
    static let defaultModel = "gemini-2.5-flash-lite"

    private let storage: EncryptedLocalStorage

    @Published private(set) var apiKey: String?
    /// Which Gemini model `GeminiClient` targets — user-selectable
    /// (Settings → Gemini AI) so the household can try different
    /// options (cost/quality/latency tradeoffs). Not a secret, but kept
    /// alongside the key for one storage path; defaults to the cheapest
    /// tier if nothing has been chosen yet.
    @Published private(set) var model: String

    var isConfigured: Bool { apiKey != nil }

    /// [BOOT-M1M2] Guards the one-shot deferred load
    /// (`loadPersistedValues` — main-confined, like every mutation here).
    private var loadScheduled = false
    /// Set by `save`/`clear` (main-confined). A deferred load that lands
    /// AFTER a user write must never clobber it — the user's explicit
    /// action always wins over a boot-time restore.
    private var apiKeyWritten = false
    /// Same rule for `saveModel`.
    private var modelWritten = false

    /// [BOOT-M1M2] ZERO storage IO in init (constant-time startup): the
    /// key/model start at their no-value defaults and the persisted
    /// values are restored by `loadPersistedValues(on:)`, which
    /// `AppCoordinator.start()` calls once after first paint. No caller
    /// observes a difference: `GeminiClient` reads `apiKey`/`model`
    /// point-of-use (request time), and the deferred restore lands
    /// within milliseconds of launch — the same values, a paint earlier.
    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.apiKey = nil
        self.model = Self.defaultModel
    }

    /// [BOOT-M1M2] Deferred keychain restore. Call ONCE, on MAIN, after
    /// first paint (`AppCoordinator.start()` — force-on-main-first
    /// discipline: the kick runs on main because the published values
    /// are main-confined; the LOADS run on the supplied queue, normally
    /// the coordinator's boot queue, and the published assignments plus
    /// `completion` hop back to main).
    func loadPersistedValues(on queue: DispatchQueue,
                             completion: (() -> Void)? = nil) {
        assert(Thread.isMainThread,
               "GeminiConfigStore.loadPersistedValues must be kicked on main")
        guard !loadScheduled else { return }
        loadScheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            let key = Self.load(storage: self.storage)
            let storedModel = Self.loadModel(storage: self.storage)
            DispatchQueue.main.async {
                if !self.apiKeyWritten { self.apiKey = key }
                if !self.modelWritten { self.model = storedModel }
                completion?()
            }
        }
    }

    func saveModel(_ newModel: String) {
        let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = storage.write(key: Self.modelStorageKey, value: trimmed)
        modelWritten = true
        model = trimmed
    }

    private static func loadModel(storage: EncryptedLocalStorage) -> String {
        guard case .success(let value) = storage.read(key: modelStorageKey, type: String.self),
              !value.isEmpty else { return defaultModel }
        return value
    }

    func save(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        _ = storage.write(key: Self.storageKey, value: trimmed)
        apiKeyWritten = true
        apiKey = trimmed
    }

    func clear() {
        _ = storage.delete(key: Self.storageKey)
        apiKeyWritten = true
        apiKey = nil
    }

    private static func load(storage: EncryptedLocalStorage) -> String? {
        guard case .success(let value) = storage.read(key: storageKey, type: String.self),
              !value.isEmpty else { return nil }
        return value
    }
}

/// Curated model choices offered in Settings — NOT the full live
/// `ListModels` response. That list also contains image-generation,
/// TTS-only, robotics, and preview/experimental entries unsuited to a
/// text+audio conversational picker; this is deliberately the stable
/// Flash/Pro family plus the "latest" rolling aliases. Verified against
/// the real `v1beta/models` endpoint for this API key on 2026-09-04 —
/// re-check if Google renames/retires any of these.
enum GeminiModelCatalog {
    struct Entry: Identifiable {
        let id: String
        let labelKey: String
        let descriptionKey: String
    }

    static let entries: [Entry] = [
        Entry(id: "gemini-2.5-flash-lite",
              labelKey: "settings.gemini.model.flashLite",
              descriptionKey: "settings.gemini.model.flashLite.desc"),
        Entry(id: "gemini-2.5-flash",
              labelKey: "settings.gemini.model.flash",
              descriptionKey: "settings.gemini.model.flash.desc"),
        Entry(id: "gemini-2.5-pro",
              labelKey: "settings.gemini.model.pro",
              descriptionKey: "settings.gemini.model.pro.desc"),
        Entry(id: "gemini-flash-lite-latest",
              labelKey: "settings.gemini.model.flashLiteLatest",
              descriptionKey: "settings.gemini.model.flashLiteLatest.desc"),
        Entry(id: "gemini-flash-latest",
              labelKey: "settings.gemini.model.flashLatest",
              descriptionKey: "settings.gemini.model.flashLatest.desc")
    ]
}
