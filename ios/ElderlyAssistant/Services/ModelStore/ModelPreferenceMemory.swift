import Foundation

// MARK: - Per-language memory of the household's own STT/brain picks (2026-09-16)
//
// The STT and brain preferences are one stored `ModelID` each, and the
// app-language switch (`AppCoordinator.syncModelPreferencesToLanguage`)
// rewrites them whenever the current model cannot serve the new language.
// With no memory of what the household chose, an en→ne→en round trip
// therefore lands on the per-language DEFAULT both ways and silently
// flattens an explicit pick — the exact bug `ResponseVoiceSelection`'s
// `rememberedVoices()` fixed for the reply voice (2026-09-13, fix 2).
//
// This is that memory for the two `ModelID`-backed kinds: a
// `[language: ModelID]` map per kind, JSON in UserDefaults (a UI
// preference, not a secret — the house rule; the same store as
// `sttModelPreference` / `brainModelPreference`).
//
// Written ONLY by an explicit pick in the Settings pickers (`remember…`,
// called right next to the preference write). The automatic language switch
// must never call it: if the switch remembered, the switch-back would
// overwrite the very pick it exists to restore.
//
// `nil` ("Automatic") is never recorded — the resolver restores real
// catalog ids only, and a nil preference is deliberately left alone (see
// `LanguageModelResolver.resolvedPreference`). An explicit "Automatic" pick
// is therefore not a memory, and it does not erase one either.
//
// Values are returned RAW (decoded, never validated): a retired id must be
// IGNORED by the reader (`LanguageModelResolver`), never deleted — storage
// the user did not touch stays untouched.
enum ModelPreferenceMemory {

    private static let sttKey = "sttModelPreferenceByLanguage"
    private static let brainKey = "brainModelPreferenceByLanguage"

    // MARK: - Read

    /// The STT engines the household has EXPLICITLY picked, keyed by the
    /// app language they were picked in (ISO 639-1, lowercased).
    static func rememberedSTT(defaults: UserDefaults = .standard) -> [String: ModelID] {
        decode(key: sttKey, defaults: defaults)
    }

    /// The assistant brains the household has EXPLICITLY picked, keyed the
    /// same way.
    static func rememberedBrain(defaults: UserDefaults = .standard) -> [String: ModelID] {
        decode(key: brainKey, defaults: defaults)
    }

    // MARK: - Write (explicit user picks only)

    /// Records an explicit STT pick made while the app language was
    /// `language`. Refuses (returns false) an id that is not a live
    /// `.whisperBase` catalog entry: a non-catalog or wrong-kind pick must
    /// never enter the memory, so a corrupt store cannot put the app back
    /// on a voice-model id. (The reader validates too — this keeps storage
    /// honest at the source.)
    @discardableResult
    static func rememberSTT(_ id: ModelID,
                            for language: String,
                            defaults: UserDefaults = .standard) -> Bool {
        remember(id, kind: .whisperBase, key: sttKey,
                 language: language, defaults: defaults)
    }

    /// Records an explicit assistant-brain pick — the `rememberSTT`
    /// contract for `.llamaBase`.
    @discardableResult
    static func rememberBrain(_ id: ModelID,
                              for language: String,
                              defaults: UserDefaults = .standard) -> Bool {
        remember(id, kind: .llamaBase, key: brainKey,
                 language: language, defaults: defaults)
    }

    /// Test seam: drops BOTH memories (the live preferences are not
    /// touched — the picker keeps its selection).
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: sttKey)
        defaults.removeObject(forKey: brainKey)
    }

    // MARK: - Internals

    private static func remember(_ id: ModelID,
                                 kind: ModelKind,
                                 key: String,
                                 language: String,
                                 defaults: UserDefaults) -> Bool {
        guard ModelCatalog.entry(for: id)?.kind == kind else { return false }
        var map = decode(key: key, defaults: defaults)
        map[language.lowercased()] = id
        encode(map, key: key, defaults: defaults)
        return true
    }

    private static func decode(key: String, defaults: UserDefaults) -> [String: ModelID] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ModelID].self, from: data)) ?? [:]
    }

    private static func encode(_ value: [String: ModelID],
                               key: String,
                               defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
