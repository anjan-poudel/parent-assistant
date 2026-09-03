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

    private let storage: EncryptedLocalStorage

    @Published private(set) var apiKey: String?

    var isConfigured: Bool { apiKey != nil }

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.apiKey = Self.load(storage: storage)
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
