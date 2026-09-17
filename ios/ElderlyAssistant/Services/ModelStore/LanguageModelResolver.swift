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
    ///   - the new language's REMEMBERED pick (`remembered`, see below)
    ///     when the current model is tagged for other languages only and
    ///     that memory still names a live, compatible, same-kind entry;
    ///   - the per-kind default for the new language
    ///     (`ModelCatalog.defaultEntry(kind:language:)`) otherwise;
    ///   - `current` unchanged when the catalog has no entry for that kind
    ///     at all — the resolver never clears a preference.
    ///
    /// `remembered` is the per-language record of the household's OWN picks
    /// (`ModelPreferenceMemory.rememberedSTT/Brain()`, keyed by ISO 639-1
    /// code) and mirrors the voice resolver's remembered step exactly: when
    /// the new language has a remembered model that still resolves to a
    /// usable catalog entry of the SAME KIND, it wins over the default map —
    /// so an en→ne→en round trip restores the household's chosen engine
    /// instead of flattening it to the ne default. A remembered entry that
    /// no longer fits (retired id, another kind's model, wrong language) is
    /// ignored — the default map answers — but is never deleted from storage.
    ///
    /// `catalog` is the list `current` (and the remembered pick) is looked
    /// up in (injectable for tests); the default itself always comes from
    /// the CURATED lists, so a hidden/superseded entry can never be
    /// auto-selected. A remembered pick is the user's own, so — like the
    /// voice memory — it only has to be a live entry of the right kind, not
    /// a curated one: decluttering a list must never cost a household the
    /// engine it is already running.
    ///
    /// Deliberate scope note: a `nil` preference means "Automatic", which
    /// resolves through the recognizer/interpreter's own cached-model
    /// logic — the resolver does not invent a pick the user never made.
    /// What Automatic itself resolves TO is
    /// `resolvedAutomaticPick(kind:language:policy:…)` below: a separate
    /// question (which model *should* an automatic device run) with its own
    /// answer, and deliberately not a rewrite of a stored preference. The
    /// policy gate lives there and ONLY there — this function stays the
    /// explicit-preference path, so a household's own over-budget pick is
    /// never second-guessed here.
    static func resolvedPreference(current: ModelID?,
                                   language: String,
                                   remembered: [String: ModelID] = [:],
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
        if let preferred = remembered[language.lowercased()],
           let preferredEntry = catalog.first(where: { $0.id == preferred }),
           preferredEntry.kind == entry.kind,
           isLanguageCompatible(preferredEntry, language: language) {
            return preferred
        }
        return ModelCatalog.defaultEntry(kind: entry.kind, language: language)?.id ?? current
    }

    // MARK: - [MODEL-WARDEN] The policy-aware AUTOMATIC pick (2026-09-18)
    //
    // `ModelBudgetPolicy` proved which models a device class can hold beside
    // the STT a voice turn needs warm, and `ModelLifecycleManager` shows that
    // verdict on every Settings row. What it did NOT do is answer the one
    // question the automatic path asks: on THIS class, what should
    // "Automatic" resolve to? The catalog's language default
    // (`ModelCatalog.defaultEntry` — the curated per-language pick) is a
    // statement about language, not about memory, so a 6 GB Nepali phone
    // still resolved to the 4B, which the policy refuses with
    // `overClassBudget` — and the ledger then admitted it through
    // `soloOverBudget` and evicted the warm ANE STT on every turn, which is
    // the D1 hole the policy exists to name.
    //
    // The fix is a resolution ORDER, not a second policy: this function asks
    // the policy the same question the Settings rows ask, through the same
    // `availability(of:physicalMemoryBytes:warmSTTLiveBytes:)` call the
    // ledger's `availability(of:)` delegates to, and it steps down the
    // ladder until it finds a model the class can actually hold:
    //
    //   1. **The language default, when the class can hold it.** The
    //      overwhelming case, and the one that must not move: every
    //      device that can run the curated pick still gets it.
    //   2. **The largest CURATED artifact that fits beside the warm STT.**
    //      The ladder order, in the units the catalog and the user both
    //      think in (file size). Curated only — a hidden or superseded
    //      entry must never be auto-selected — and language-compatible
    //      only, so a step-down can never land an English household on a
    //      Devanagari fine-tune.
    //   3. **The smallest brain, with its consequence stated.** On the
    //      compact class no shipped brain fits beside an STT at all (a
    //      finding `ModelBudgetPolicyTests` pins), so there is no honest
    //      "fits" to resolve to. The pick degrades to the lightest
    //      language-compatible brain and carries its own reason, so the
    //      class's cost is visible in the choice rather than arriving as a
    //      cold-STT mystery. No loop, no crash, no silent admit.
    //
    // ### What this deliberately does not do
    //
    // An EXPLICIT pick is not overridden. This function takes no `current`
    // preference and is not called from `resolvedPreference`: a household
    // that stored the 4B keeps the 4B, served through the ledger's
    // `soloOverBudget` escape hatch, which is the path that exists so a
    // resident is never unloadable. The policy gates the automatic path
    // only. `resolvedPreference(current: nil, …)` likewise still returns
    // nil — Automatic is not converted into a stored pick — and the
    // recognizer/interpreter read the resolution below when they need a
    // concrete model.
    //
    // ### Purity and the record
    //
    // Everything here is a pure function of (catalog, policy, probe bytes,
    // warm-STT bytes): no clock, no singleton, no side effect, so the whole
    // matrix is unit-tested without a ledger or a coordinator. The choice
    // is recorded honestly by the CALLER: `AutomaticPick.recordedReason` is
    // the one closed-vocabulary token that explains it (an
    // `over_class_budget` / `requires_evicting_warm_stt` value — no
    // filename, no size, no model id), and it rides the existing `reason`
    // metadata key. The Settings sentence for it already ships in both
    // languages (`ModelUnavailabilityReason.localizationKey`), so this
    // resolution needs no new copy.
    //
    // Wired 2026-09-18: the load path calls this through
    // `AppCoordinator.resolveBrainModelID(storedPreference:language:ledger:)`
    // (the ledger supplies the inputs) and the coordinator emits the record
    // once per launch as `automatic_brain_pick` — only when the choice
    // moved, so a device the policy left alone says nothing at all.

    /// What "Automatic" resolves to, and the policy facts behind it.
    struct AutomaticPick: Equatable {

        /// The model Automatic resolves to. Always a live, curated,
        /// language-compatible catalog entry — never nil-by-substitution
        /// and never a hidden one.
        let entry: ModelCatalogEntry

        /// The policy's verdict on `entry`. `.available` for every pick the
        /// class can hold beside its warm STT, and the reason when even the
        /// pick it landed on cannot (the compact class, where the ladder
        /// bottoms out — see the header).
        let availability: ModelAvailability

        /// Why the class refused the catalogue's LANGUAGE default, when it
        /// did. nil when the default was taken (step 1) — which is the
        /// class-independent case — and non-nil on exactly the classes
        /// where Automatic had to move.
        ///
        /// It can very occasionally name the pick itself: on the compact
        /// class the lightest brain IS the `en` default, so the reason the
        /// class refused the default and the reason the pick is over-budget
        /// are the same sentence, said once.
        let declinedDefaultReason: ModelUnavailabilityReason?

        /// The single honest token for this resolution, or nil when the
        /// language default was taken and fits (nothing to report, nothing
        /// to explain).
        ///
        /// The pick's own reason wins when it has one: on the compact class
        /// the fact worth stating is the cost of the model that was chosen,
        /// not the cost of the one that was refused. Everything else
        /// reports why the default could not be taken — a 6 GB phone says
        /// `over_class_budget`, which is the sentence that explains why
        /// Automatic did not pick the model the language asked for.
        var recordedReason: ModelUnavailabilityReason? {
            availability.reason ?? declinedDefaultReason
        }

        /// Two picks are the same pick when they name the same artifact and
        /// the same policy facts. Compared by `entry.id` rather than by the
        /// whole entry because a catalog entry is identified by its id (its
        /// URLs and sizes are properties of the artifact, not of the
        /// choice), which also keeps `AutomaticPick` free of a conformance
        /// `ModelCatalogEntry` does not carry.
        static func == (lhs: AutomaticPick, rhs: AutomaticPick) -> Bool {
            lhs.entry.id == rhs.entry.id
                && lhs.availability == rhs.availability
                && lhs.declinedDefaultReason == rhs.declinedDefaultReason
        }
    }

    /// What "Automatic" resolves to for `kind` in `language` on a device.
    ///
    /// `policy` is the class's policy and `physicalMemoryBytes` the probe's
    /// reading — the same pair `ModelLifecycleManager.availability(of:)`
    /// composes, so a row and this pick can never disagree about a model.
    /// `warmSTTLiveBytes` is the footprint of the STT the class keeps warm,
    /// resolved through `ModelBudgetPolicy.warmSTTLiveBytes(forSTTModelID:)`
    /// from the ledger's registered `.speechToText` model; nil falls back to
    /// the policy's own reserve, which is the right answer for a caller
    /// with no selection to hand. It is a parameter rather than a lookup
    /// because the ANE graph and the whisper.cpp context differ by 0.1 GB —
    /// enough to change which brain a 6 GB class can hold.
    ///
    /// Nil only when the kind ships no curated entry at all. See the header
    /// for the resolution order and for why an explicit pick is untouched.
    static func resolvedAutomaticPick(kind: ModelKind,
                                      language: String,
                                      policy: ModelBudgetPolicy,
                                      physicalMemoryBytes: UInt64,
                                      warmSTTLiveBytes: UInt64? = nil) -> AutomaticPick? {
        guard let languageDefault = ModelCatalog.defaultEntry(kind: kind,
                                                              language: language) else {
            // The kind ships nothing (an empty curated list): there is no
            // pick to make, and inventing one is how a caller ends up
            // loading a model the catalog does not have.
            return nil
        }

        func verdict(_ entry: ModelCatalogEntry) -> ModelAvailability {
            policy.availability(of: entry,
                                physicalMemoryBytes: physicalMemoryBytes,
                                warmSTTLiveBytes: warmSTTLiveBytes)
        }

        let defaultVerdict = verdict(languageDefault)
        if defaultVerdict.isAvailable {
            // Step 1 — the default, untouched. This branch is what keeps
            // the change from being a behaviour change on every device that
            // was already fine.
            return AutomaticPick(entry: languageDefault,
                                 availability: defaultVerdict,
                                 declinedDefaultReason: nil)
        }

        // The candidates, in the catalog's own preference order — the order
        // the size ties below are broken by, so the result is a pure
        // function of the curated list. Only language-compatible entries
        // compete: an automatic pick that cannot serve the household's
        // language is not a pick at all.
        let candidates: [(entry: ModelCatalogEntry, verdict: ModelAvailability)] =
            ModelCatalog.curatedEntries(kind: kind)
                .filter { isLanguageCompatible($0, language: language) }
                .map { (entry: $0, verdict: verdict($0)) }

        // Step 2 — the ladder: the largest artifact that still fits beside
        // the warm STT. `max(by:)` keeps the first of equal sizes, and the
        // candidate order is the curated order, so a tie is resolved by the
        // picker's own preference and never by dictionary or hash order.
        if let best = candidates.filter({ $0.verdict.isAvailable })
            .max(by: { $0.entry.sizeBytes < $1.entry.sizeBytes }) {
            return AutomaticPick(entry: best.entry,
                                 availability: best.verdict,
                                 declinedDefaultReason: defaultVerdict.reason)
        }

        // Step 3 — nothing fits beside the warm STT, so the honest answer is
        // the LIGHTEST language-compatible brain: it is the one that costs
        // the class least when the STT has to be re-loaded for it, and the
        // reason it carries is that consequence. Never a crash, never a
        // loop, never a silent admit of the default the policy refused.
        guard let lightest = candidates.min(by: { $0.entry.sizeBytes < $1.entry.sizeBytes }) else {
            // Nothing serves this language either (a catalog that ships
            // one language's brains and nothing neutral). The language
            // default is the catalog's own best answer, unavailability and
            // all — this function does not invent a worse one.
            return AutomaticPick(entry: languageDefault,
                                 availability: defaultVerdict,
                                 declinedDefaultReason: nil)
        }
        return AutomaticPick(entry: lightest.entry,
                             availability: lightest.verdict,
                             declinedDefaultReason: defaultVerdict.reason)
    }

    /// The reply-voice preference (`ResponseVoiceSelection`) after the app
    /// language became `language`. The TTS preference is a
    /// `ResponseVoice` (voice id + speaker id), so it needs its own shape
    /// of the same decision: an incompatible voice switches to the
    /// new language's remembered pick or default voice; a compatible voice
    /// keeps its chosen speaker. `nil` (no choice stored — the locale
    /// default rules) and unknown voice ids are never touched.
    ///
    /// `remembered` is the per-language record of the user's OWN picks
    /// (`ResponseVoiceSelection.rememberedVoices()`, keyed by ISO 639-1
    /// code): when the new language has a remembered voice that still
    /// resolves to a usable catalog voice, it wins over the default map —
    /// an en→ne→en round trip restores the household's chitwan choice
    /// instead of flattening it to the ne default. A remembered entry that
    /// no longer fits (retired id, out-of-range speaker, wrong language)
    /// is ignored — the default map answers instead — but is never
    /// deleted from storage.
    static func resolvedVoicePreference(current: ResponseVoice?,
                                        language: String,
                                        remembered: [String: ResponseVoice] = [:],
                                        catalog: [ModelCatalogEntry] = ModelCatalog.all) -> ResponseVoice? {
        guard let current,
              let entry = catalog.first(where: { $0.id == current.voiceID }) else {
            return current
        }
        guard !isLanguageCompatible(entry, language: language) else {
            return current
        }
        if let preferred = remembered[language.lowercased()],
           let preferredEntry = catalog.first(where: { $0.id == preferred.voiceID }),
           preferredEntry.kind == .tts,
           isLanguageCompatible(preferredEntry, language: language),
           ResponseVoice.speakerIDs(for: preferred.voiceID).contains(preferred.speakerID) {
            return preferred
        }
        guard let fallback = ModelCatalog.defaultEntry(kind: .tts, language: language) else {
            return current
        }
        return ResponseVoice(voiceID: fallback.id, speakerID: 0)
    }
}
