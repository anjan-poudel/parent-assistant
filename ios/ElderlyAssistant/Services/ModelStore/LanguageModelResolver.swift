import Foundation

// MARK: - Language-aware model selection (2026-09-13)
//
// Every catalog entry carries a language tag (`ModelCatalogEntry.languages`
// — `[]` = multilingual / any language). This resolver answers the one
// question the coordinator asks when `appLanguage` changes: is the model
// the user currently has selected still usable in the new language, and if
// not, which per-kind default does it switch to?
//
// Why this exists: a `["ne"]` Whisper fine-tune transcribes English as
// noise, and a Nepali intent fine-tune is not the brain an English
// household should be talking to. The app language is the household's one
// statement about which language the device is used in, so the models
// follow it — the STT engine, the assistant brain and the reply voice.
//
// Pure + static (the `OnDeviceSTTSelection` / `FeedLanguageSorter` house
// seam): the whole matrix is unit-tested without an AppCoordinator
// (`LanguageModelResolverTests`), and the coordinator keeps only the
// persistence + hot-swap side effects.

enum LanguageModelResolver {

    /// The single compatibility rule: an entry is usable in `language`
    /// when it is language-neutral (`languages == []`) or explicitly
    /// tagged with that language. `language` is an ISO 639-1 code
    /// (`AppLanguage.rawValue` — "ne" / "en"); matching is
    /// case-insensitive so a stored "NE" can never strand a preference.
    static func isLanguageCompatible(_ entry: ModelCatalogEntry,
                                     language: String) -> Bool {
        guard !entry.languages.isEmpty else { return true }
        return entry.languages.contains(language.lowercased())
    }

    /// The preference a `ModelID`-backed kind (STT, brain) should hold
    /// after the app language became `language`.
    ///
    /// Returns, in order:
    ///   - `current` unchanged when it is language-compatible — INCLUDING
    ///     `[]`-tagged (multilingual) models and a `nil` (automatic)
    ///     preference, which is never touched;
    ///   - the per-kind default for the new language
    ///     (`ModelCatalog.defaultEntry(kind:language:)`) when the current
    ///     model is tagged for other languages only;
    ///   - `current` unchanged when the catalog has no entry for that kind
    ///     at all — the resolver never clears a preference.
    ///
    /// `catalog` is the list `current` is looked up in (injectable for
    /// tests); the default itself always comes from the CURATED lists, so
    /// a hidden/superseded entry can never be auto-selected.
    ///
    /// Deliberate scope note: a `nil` preference means "Automatic", which
    /// resolves through the recognizer/interpreter's own cached-model
    /// logic — the resolver does not invent a pick the user never made.
    /// (Reconciling what AUTOMATIC resolves to per language is a separate,
    /// larger change; see the task report.)
    static func resolvedPreference(current: ModelID?,
                                   language: String,
                                   catalog: [ModelCatalogEntry] = ModelCatalog.all) -> ModelID? {
        guard let current,
              let entry = catalog.first(where: { $0.id == current }) else {
            // No preference, or an id no longer in the catalog (a stale
            // stored value): nothing to judge — leave it exactly as it is.
            return current
        }
        guard !isLanguageCompatible(entry, language: language) else {
            return current
        }
        return ModelCatalog.defaultEntry(kind: entry.kind, language: language)?.id ?? current
    }

    /// The reply-voice preference (`ResponseVoiceSelection`) after the app
    /// language became `language`. The TTS preference is a
    /// `ResponseVoice` (voice id + speaker id), so it needs its own shape
    /// of the same decision: an incompatible voice switches to the
    /// new language's default voice at speaker 0; a compatible voice keeps
    /// its chosen speaker. `nil` (no choice stored — the locale default
    /// rules) and unknown voice ids are never touched.
    static func resolvedVoicePreference(current: ResponseVoice?,
                                        language: String,
                                        catalog: [ModelCatalogEntry] = ModelCatalog.all) -> ResponseVoice? {
        guard let current,
              let entry = catalog.first(where: { $0.id == current.voiceID }) else {
            return current
        }
        guard !isLanguageCompatible(entry, language: language) else {
            return current
        }
        guard let fallback = ModelCatalog.defaultEntry(kind: .tts, language: language) else {
            return current
        }
        return ResponseVoice(voiceID: fallback.id, speakerID: 0)
    }
}
