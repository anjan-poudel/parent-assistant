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

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.apiKey = Self.load(storage: storage)
        self.model = Self.loadModel(storage: storage)
    }

    func saveModel(_ newModel: String) {
        let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = storage.write(key: Self.modelStorageKey, value: trimmed)
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
        apiKey = trimmed
    }

    func clear() {
        _ = storage.delete(key: Self.storageKey)
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
