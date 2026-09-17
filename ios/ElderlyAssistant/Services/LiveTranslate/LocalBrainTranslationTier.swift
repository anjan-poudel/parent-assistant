import Foundation
#if canImport(LLM)
import LLM
#endif

// Tier 1 — the on-device brain as a translation tier (FR-LCT-008 as amended
// 2026-09-17, FR-LCT-020, NFR-LCT-010). The owner's complaint being fixed:
// with only a ~120-label dictionary and a consent-gated cloud in the cascade,
// any sign the dictionary misses degrades to "can't translate" the moment the
// elder is offline or has declined the cloud. The device already has a Nepali
// fine-tune on it; this is the tier that asks it.
//
// It sits **between** the curated dictionary (tier 0) and the cloud (tier 2),
// and it exists to make three things true:
//
//   1. **One batched call, not one call per region.** Everything a cycle could
//      not resolve on the device goes into ONE generation: the latency is
//      seconds, the cycle's pending state already covers the wait, and N
//      regions of a scene share the 1,024-token context that one call costs —
//      which is also why the batch is bounded by `brainTranslationMaxStrings`
//      and `brainTranslationMaxCharacters`. The surplus is left unresolved for
//      the next tier, never dropped.
//
//   2. **No consent, no network, no cost (OD-13 untouched).** Nothing about
//      this tier leaves the device, so there is nothing to consent to and no
//      budget to spend. The pipeline runs it BEFORE the gate, which is what
//      makes the prompt appear at the point of first *cloud* need
//      (FR-LCT-011/FR-LCT-020) rather than over a scene the device could
//      answer by itself.
//
//   3. **A failure is honest, bounded and ordinary.** The model may not be
//      installed, the runtime may not be linked, the load may fail, the
//      generation may fail or outlive `brainTranslationTimeoutSeconds` — every
//      one of those is a closed-vocabulary reason on
//      `brain_translation_unavailable`, and every one of them hands the
//      strings back to the caller unresolved so the cloud tier answers as
//      before. There is no stub, no empty translation passed off as an answer,
//      and no path that holds the cycle open: the bound is a real bound
//      (`LLM.stop()` interrupts the generation).
//
//   4. **Only a translation may settle a region (2026-09-17).** An answer that
//      is empty, over the size bound, the source again in comparison form, or
//      not written in the target language's script is **unresolved** — it
//      cannot end a string's journey, and the cloud is asked for it. This is
//      the tier's half of the owner's report ("it no longer falls back to
//      gemini; only the simplest words translate"): a tier that settles
//      whatever it produced, however unusable, is a tier that removes the
//      cloud from the cascade without anyone deciding to. Because the two
//      failure modes are opposite — answering nothing, and answering something
//      that is not an answer — this is a separate rule from (3) rather than a
//      special case of it.
//
//   5. **The device pays for the work only when it can (2026-09-17).** A batch
//      is not attempted when a brain is live for another owner, or when the
//      app's own headroom is below the brain's declared non-pageable
//      footprint; either way the strings go to the cloud and the deferral is
//      recorded. The tier reads the residency ledger and the memory probe, and
//      writes to neither.
//
// The **direction** is a parameter, not an assumption: every string this tier
// is handed is translated *into* `targetLanguage`, the same language tier 0
// answers in and tier 2 is asked for. The prompt shipped saying "Nepali sign
// text into English" — the reverse of the design's own direction (OD6, "the
// phrase card direction") and of the runtime that feeds it, which reads
// English and has no Devanagari recognition language at all — and the tier
// then settled that English literature as a translation. See `prompt(for:)`.
//
// What it deliberately does NOT do:
//
//   - **It does not write the translation cache.** `LabelTranslationCache`
//     attributes a persisted entry to the cloud tier, and a brain translation
//     is not a cloud translation; borrowing that provenance would misattribute
//     a local answer exactly the way attributing one to `.dictionary` would.
//     The pipeline's own settled set is what carries an answer across a region
//     re-identification inside a session.
//   - **It does not sanitise its input for egress.** C07's quarantine exists
//     to stop content leaving the device; nothing here leaves it. The batch
//     bounds and the prompt budget guard are what keep the context safe.
//   - **It does not take a residency slot.** `ModelLifecycleManager` has one
//     entry per slot and both llama slots (`.brain`, `.intentBrain`) belong to
//     the voice interpreters: registering one from here would replace their
//     release closure, so an eviction would free the wrong handle and this
//     tier's resident would go on being invisible to the budget — worse, not
//     better. Its mitigation is that this tier holds nothing between uses: the
//     handle is loaded lazily on the first attempt and released
//     `brainTranslationIdleUnloadSeconds` after the last one, so the ledger's
//     total is never silently crossed by a handle this tier parked. The only
//     thing it asks the ledger is whether someone else's brain is live
//     (`isResident`, a lock-guarded read safe from any queue); it never
//     registers, evicts or pins.

// MARK: - The seam the pipeline drives

/// What the pipeline needs from tier 1: one batched attempt, and nothing else.
///
/// `translate` never throws and never reports a failure through its result:
/// "could not translate" is an empty outcome, and the tier has already
/// recorded *why* on the feature's own event vocabulary. The caller's whole
/// job is to settle what came back and send the rest to the next tier.
protocol LocalBrainTranslating: Sendable {
    /// One attempt for the strings a cycle could not resolve on the device.
    ///
    /// Returns a translation for every string it could answer, keyed by the
    /// string exactly as it was handed in. A string the attempt did not
    /// resolve is absent — never an empty string, never the source itself.
    func translate(_ strings: [String]) async -> LocalBrainTranslationOutcome

    /// Releases any resident inference handle. Called when the session closes,
    /// so a closed session leaves no model parked in memory. A no-op for a
    /// brain that holds nothing.
    func release() async
}

extension LocalBrainTranslating {
    func release() async {}
}

/// The outcome of one batched attempt.
struct LocalBrainTranslationOutcome: Equatable {
    /// Source string → translation, for the strings this attempt answered.
    let translations: [String: String]
    /// How long the attempt took, for the event. 0 when nothing ran.
    let durationMs: Int
    /// Why the tier declined to attempt this batch at all, when it did.
    ///
    /// **Evidence, not a branch.** A deferral and an attempt that answered
    /// nothing mean the same thing to the caller — the strings go to the next
    /// tier untouched — so this field changes no decision. It is here because
    /// "the brain was never asked" and "the brain was asked and could not" are
    /// different facts about a session, and only one of them is worth acting
    /// on later (a device that defers every batch is a device whose memory
    /// floor is mis-set, not one whose model is bad).
    ///
    /// A `var` with a default rather than a `let`, so the shape that shipped
    /// (`translations:durationMs:`) is still the whole initializer and the
    /// tier's own tests keep constructing outcomes without one.
    var deferral: LocalBrainDeferral? = nil

    static let none = LocalBrainTranslationOutcome(translations: [:], durationMs: 0)
}

/// Why tier 1 did not attempt a batch. Not a failure: nothing was asked for,
/// nothing was answered, and every string is still the next tier's to answer.
enum LocalBrainDeferral: Equatable {
    /// A brain is already live for another owner — the voice pipeline's
    /// `.brain` or `.intentBrain` slot. Two 4B workloads at once on a 5.5 GB
    /// device is the fastest way to get the app killed, and the voice brain is
    /// the one the household is actively talking to.
    ///
    /// Read from the ledger, never written to it: this tier takes no residency
    /// slot (see the file header), so the only safe thing it can do with the
    /// ledger is ask.
    case residentBrain
    /// The app's own headroom under its jetsam ceiling is below the brain's
    /// declared non-pageable footprint, so a load would be the thing that
    /// crosses it.
    ///
    /// The numbers travel with the reason: they are the whole of the decision,
    /// and a log line that said only "insufficient memory" would not let
    /// anyone tell a mis-set floor from a genuinely pressured device.
    case insufficientHeadroom(requiredBytes: UInt64, availableBytes: UInt64)
}

/// The generation half, behind a seam so the tier's own tests drive a
/// deterministic fake: bounding, parsing, the event vocabulary and the
/// timeout-to-fallback contract are all exercised without a model on disk, and
/// the llama.cpp call is the only thing a fake replaces.
protocol BrainTextGenerating: Sendable {
    /// One grammar-constrained generation. Throws `BrainGenerationFailure` on
    /// every failure this tier reports, and must not outlive `timeout`.
    func generate(prompt: String,
                  jsonSchema: String,
                  modelURL: URL,
                  timeout: TimeInterval) async throws -> String

    /// Drops the resident handle, if one is held.
    func release() async

    /// Whether an inference handle is resident right now.
    ///
    /// It is the memory gate's one input it cannot derive: the gate exists to
    /// refuse a *load*, and a batch whose handle is already in memory costs no
    /// load at all — refusing it would send a string to the cloud while the
    /// 2.5 GB it was refused for sits in RAM. A generator that holds nothing
    /// answers `false`, which is the shape that makes the gate apply (a load
    /// would happen), so the default is the conservative half for a fake and
    /// the honest one for a runtime that has not been asked.
    func isHoldingHandle() async -> Bool
}

extension BrainTextGenerating {
    func release() async {}
    func isHoldingHandle() async -> Bool { false }
}

/// Why a generation did not produce an answer. Mapped 1:1 onto
/// `LiveTranslateBrainUnavailableReason`, so the reason an elder's screen
/// shows the original text for is the reason this tier actually hit.
enum BrainGenerationFailure: Error, Equatable {
    case loadFailed
    /// The prompt would leave no room to generate inside the shared context —
    /// deterministic, so it is reported rather than discovered as a truncated
    /// answer.
    case promptOverflow
    case timedOut
    case generationFailed
}

// MARK: - The tier

/// The on-device translation tier (tier 1). An actor for one reason: inference
/// serializes. Two cycles' batches can never decode at the same time on one
/// handle, and the whole attempt runs off the pipeline's actor, so the camera
/// cadence never waits on it — the pipeline awaits this value from inside its
/// own session-scoped task, not from its tick.
actor LocalBrainTranslationTier: LocalBrainTranslating {

    private let config: LiveTranslateConfig
    /// The store that answers "is the brain installed". Optional because the
    /// only construction that can fail is the process's own store; a tier
    /// without one reports itself unavailable, honestly, rather than
    /// pretending a model might be there.
    private let modelStore: ModelStore?
    private let events: LiveTranslateEvents
    private let generator: any BrainTextGenerating
    /// The language the translations must be written in.
    ///
    /// Taken from the session rather than assumed, because the direction is
    /// the one thing a generation cannot check for itself and the tier is the
    /// only place it can be *stated* to the model (`prompt(for:)`) and
    /// *checked* against its answer (`parse`). It is the same value tier 0 and
    /// tier 2 are keyed by, so the three cannot disagree about what "the
    /// translation" is a translation *into*.
    private let targetLanguage: AppLanguage
    /// The app's headroom reading (`MemoryProbe` in production). Injected so
    /// the memory gate is arithmetic a test can drive rather than a fact about
    /// the host machine.
    private let memory: MemoryProbing
    /// The residency ledger, read-only. This tier takes no slot in it (see the
    /// file header); it asks whether a brain is live for another owner and, if
    /// one is, defers — which is the one question the ledger can answer
    /// without this tier claiming anything.
    private let ledger: ModelLifecycleManager

    init(config: LiveTranslateConfig = .default,
         modelStore: ModelStore?,
         events: LiveTranslateEvents,
         generator: (any BrainTextGenerating)? = nil,
         targetLanguage: AppLanguage = LiveTranslationPipeline.defaultTargetLanguage,
         memory: MemoryProbing = SystemMemoryProbe(),
         ledger: ModelLifecycleManager = .shared) {
        self.config = config
        self.modelStore = modelStore
        self.events = events
        self.generator = generator ?? LlamaBrainTextGenerator(config: config)
        self.targetLanguage = targetLanguage
        self.memory = memory
        self.ledger = ledger
    }

    // MARK: Availability

    /// The catalogue entry that will run: the first of
    /// `config.brainTranslationModelIDs` that is installed *and complete*
    /// (`ModelStore.isAvailable` — the file, and every dependency the catalog
    /// declares for it). Nil means tier 1 cannot run on this device.
    ///
    /// There is no separate "tokenizer ready" check to make: a GGUF carries
    /// its own vocabulary, so an installed file is a runnable one, which is
    /// the same check the app's other on-device brains make
    /// (`LocalIntentInterpreter.isAvailable`).
    func installedModel() -> ModelID? {
        guard let modelStore else { return nil }
        return config.brainTranslationModelIDs.first { modelStore.isAvailable($0) }
    }

    // MARK: The attempt

    func translate(_ strings: [String]) async -> LocalBrainTranslationOutcome {
        guard !strings.isEmpty else { return .none }

        #if canImport(LLM)
        guard let modelStore, let modelID = installedModel(),
              let modelURL = modelStore.path(for: modelID) else {
            // No store, no catalogue entry, or no installed artifact: the tier
            // is skipped and says so. The strings fall through untouched.
            events.brainTranslationUnavailable(modelStore == nil ? .runtimeMissing : .modelNotInstalled)
            return .none
        }

        // The resource gate (2026-09-17). It runs here rather than at the top
        // of the method because it is a gate on a *load*: there is nothing to
        // refuse until a model has been found to load, and a device whose
        // brain is missing has a more honest reason to report than its memory.
        if let deferral = await deferralForLoad(of: modelID) {
            // The batch event, not the unavailable event: nothing was
            // unavailable. The model is on disk and the runtime is linked —
            // this batch is simply not the one to spend 2.5 GB on, and the
            // strings are untouched for the tier behind this one.
            events.brainTranslationBatch(resolvedCount: 0,
                                         unresolvedCount: strings.count,
                                         durationMs: 0)
            return LocalBrainTranslationOutcome(translations: [:],
                                                durationMs: 0,
                                                deferral: deferral)
        }

        let batch = boundedBatch(strings)
        guard !batch.isEmpty else {
            // Every string is over the batch bound on its own — nothing was
            // attempted, and none of it is dropped: the whole input is left to
            // the next tier.
            events.brainTranslationBatch(resolvedCount: 0,
                                         unresolvedCount: strings.count,
                                         durationMs: 0)
            return .none
        }

        let started = Date()
        do {
            let output = try await generator.generate(prompt: Self.prompt(for: batch,
                                                                          targetLanguage: targetLanguage),
                                                      jsonSchema: Self.jsonSchema,
                                                      modelURL: modelURL,
                                                      timeout: config.brainTranslationTimeoutSeconds)
            let translations = Self.parse(output,
                                          sources: batch,
                                          targetLanguage: targetLanguage,
                                          config: config)
            let durationMs = Self.milliseconds(since: started)
            // The counts are about the BATCH THE CALLER HANDED OVER, not about
            // the part that fitted: a bounded batch reports its surplus as
            // unresolved, which is what the caller then sends onward.
            events.brainTranslationBatch(resolvedCount: translations.count,
                                         unresolvedCount: strings.count - translations.count,
                                         durationMs: durationMs)
            return LocalBrainTranslationOutcome(translations: translations,
                                                durationMs: durationMs)
        } catch let failure as BrainGenerationFailure {
            events.brainTranslationUnavailable(Self.reason(for: failure))
            return .none
        } catch {
            // A llama.cpp error this tier does not classify is still a failure
            // it reports, with the token that says "the generation failed".
            events.brainTranslationUnavailable(.inferenceFailed)
            return .none
        }
        #else
        _ = strings
        // Built without the llama.cpp runtime: no model can be run, whatever is
        // on disk. Recorded once per sighting by the caller's claim, not once
        // per frame.
        events.brainTranslationUnavailable(.runtimeMissing)
        return .none
        #endif
    }

    func release() async {
        await generator.release()
    }

    // MARK: The resource gate

    /// Why the brain may not be loaded for this batch, if it may not.
    ///
    /// Two rules, in order, and both are about the device rather than about
    /// the translation:
    ///
    ///  1. **Another owner's brain is live.** The voice pipeline holds `.brain`
    ///     or `.intentBrain` while the household is talking to it; a second 4B
    ///     decode alongside it is the shape that gets the app killed, and the
    ///     translation is the workload that can afford to wait — the elder is
    ///     reading a sign, not waiting on an answer. Asked of the ledger and
    ///     never told to it: this tier takes no slot, so it may not evict,
    ///     register or claim.
    ///
    ///  2. **There is not enough headroom for the load.** The comparison is
    ///     `ModelFootprint.hardBytes` against the app's own reading of its
    ///     ceiling — the ledger's own rule, and the reason the pageable
    ///     weights are not charged twice: what must fit is the KV and runtime
    ///     cost, because the weights page in and out under the kernel.
    ///
    /// Neither rule applies when a handle is already resident: the bytes are
    /// already spent, and deferring then would buy nothing.
    private func deferralForLoad(of modelID: ModelID) async -> LocalBrainDeferral? {
        if config.brainTranslationDefersToResidentBrain,
           ledger.isResident(.brain) || ledger.isResident(.intentBrain) {
            return .residentBrain
        }
        if await generator.isHoldingHandle() { return nil }

        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: modelID)
        let required = UInt64(Double(footprint.hardBytes) * config.brainTranslationHeadroomFactor)
        let available = memory.availableProcessMemoryBytes
        guard available < required else { return nil }
        return .insufficientHeadroom(requiredBytes: required, availableBytes: available)
    }

    // MARK: Bounding

    /// The prefix of `strings` that fits one request: at most
    /// `brainTranslationMaxStrings` strings and `brainTranslationMaxCharacters`
    /// characters. A string that does not fit ends the prefix (the rule is
    /// "the first N that fit", so the same scene always produces the same
    /// batch), and everything past it is left to the next tier.
    private func boundedBatch(_ strings: [String]) -> [String] {
        var batch: [String] = []
        var characters = 0
        for text in strings {
            guard batch.count < config.brainTranslationMaxStrings,
                  characters + text.count <= config.brainTranslationMaxCharacters
            else { break }
            batch.append(text)
            characters += text.count
        }
        return batch
    }

    // MARK: The request

    /// One line per source string, numbered, so the model's answer can be
    /// matched back positionally and a short answer is detectable instead of
    /// silently shifting every later translation onto the wrong sign.
    ///
    /// **The direction is the session's, and it is stated in words** because a
    /// generation has no other way to know it. This prompt shipped saying the
    /// opposite — "translate Nepali sign text into English" — which is the
    /// reverse of the direction every other tier translates in: the curated
    /// dictionary is keyed by the English label and answers with Nepali, the
    /// cloud is asked for `targetLanguage`, and the vision runtime that feeds
    /// this feature reads English text (it has no Devanagari recognition
    /// language at all). The instruction the model was given was therefore
    /// already satisfied by its input, and the literature it produced — English
    /// words for English signs — was settled as a translation, which is what
    /// stopped the remaining signs from ever reaching the cloud. The reversal
    /// is also the one the design excludes by name (OD6, the "phrase card"
    /// direction).
    ///
    /// Raw prompt, no chat template: the same convention the app's other brain
    /// paths use for these fine-tunes (see `LocalIntentInterpreter`'s raw
    /// prompt), and the schema travels beside the prompt as a parameter, never
    /// inside it — appending it is what truncated the intent brain's
    /// generations inside the shared 1,024-token context.
    static func prompt(for texts: [String], targetLanguage: AppLanguage) -> String {
        let language = languageName(targetLanguage)
        let source = languageName(sourceLanguage(for: targetLanguage))
        var lines = [
            "You translate \(source) text into \(language).",
            "Answer with JSON only, exactly one \(language) translation per source, in the same order.",
            "Use \"\" for a source you cannot translate. Keep each translation short.",
            "",
            "Source texts:"
        ]
        for (offset, text) in texts.enumerated() {
            lines.append("\(offset + 1). \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// The language the scene text is in, for the other half of the
    /// instruction: the app's own language set is a pair, so naming the target
    /// names the source. Stated rather than assumed, because the instruction
    /// the model is given is the one thing a generation cannot infer — and the
    /// prompt that shipped here named the wrong direction, which a generation
    /// obeyed by answering its input back.
    static func sourceLanguage(for targetLanguage: AppLanguage) -> AppLanguage {
        switch targetLanguage {
        case .nepali: return .english
        case .english: return .nepali
        }
    }

    /// The target language's name, from the app's own language set — an
    /// exhaustive switch with no `default`, so a new language is a compile
    /// error rather than a silently unnamed target (the shape
    /// `TranslationPrompt.languageName` uses for the cloud's instruction).
    static func languageName(_ language: AppLanguage) -> String {
        switch language {
        case .nepali: return "Nepali"
        case .english: return "English"
        }
    }

    /// The grammar the decode is constrained to. An array of strings is the
    /// whole answer, so a malformed response is structurally impossible — the
    /// parser below is still defensive, because "impossible" is a property of
    /// the sampler and this file should not depend on it.
    static let jsonSchema = """
    {
      "type": "object",
      "properties": {
        "translations": {"type": "array", "items": {"type": "string"}}
      },
      "required": ["translations"]
    }
    """

    // MARK: Reading the answer

    /// Maps a positional answer back onto the sources it was asked about.
    ///
    /// A position the answer did not reach, a non-string, and anything
    /// `accepts` refuses are each *unresolved*: the region keeps its original
    /// text and the string goes on to the next tier, which is the same rule
    /// `TranslationResponseParser` applies to a cloud response.
    ///
    /// **Unresolved, never terminal.** This is the difference the owner's
    /// device report turned on. The tier's answers used to settle a region by
    /// default — anything non-empty, unlike the source, and short enough was
    /// published as the translation — so a model that answered English with
    /// English ended the cascade for that sign and the cloud was never asked.
    /// "Only the simplest words translate" is exactly what that produces: the
    /// curated hits are correct, and everything after them settles on an
    /// answer that is not a translation. A tier can only *end* a string's
    /// journey by producing something the elder can use; anything else is a
    /// statement that the next tier should try.
    static func parse(_ raw: String,
                      sources: [String],
                      targetLanguage: AppLanguage,
                      config: LiveTranslateConfig) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["translations"] as? [Any] else { return [:] }

        var translations: [String: String] = [:]
        for (position, source) in sources.enumerated() {
            guard position < list.count, let value = list[position] as? String else { continue }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let accepted = accepts(text,
                                         for: source,
                                         targetLanguage: targetLanguage,
                                         config: config)
            else { continue }
            translations[source] = accepted
        }
        return translations
    }

    /// Whether an answer counts as a translation of `source`, and the answer
    /// itself when it does. `nil` is the tier's contract for every rejection:
    /// the string stays unresolved and the next tier is asked.
    ///
    /// Four rules, each one a shape a 4B model on a phone actually produces:
    ///
    ///  1. **Empty.** Nothing was said. The prompt asks for `""` when a source
    ///     cannot be translated, so this is the model's own "I cannot".
    ///  2. **Over the shipped size bound.** The same bound the cloud's parser
    ///     applies (`TranslationResponseParser.maxLength(forSource:config:)`),
    ///     so two tiers cannot disagree about what a plausible translation is.
    ///  3. **The source again — in comparison form.** Case folded, punctuation
    ///     and whitespace dropped, because byte-equality (what shipped) is the
    ///     one form of echo a model avoids for free: `OPEN` answered with
    ///     `Open` is the same words, and it settled the region as translated
    ///     while the elder saw no translation at all.
    ///  4. **Not written in the target's script.** A Nepali translation
    ///     contains Devanagari, and English text does not. This is the check
    ///     that catches the wrong-direction generation directly — it is what
    ///     "the answer did not change language" looks like — and it is skipped
    ///     when the source has no letters, so a numerals-only sign is not
    ///     refused for having no Devanagari to translate into.
    ///
    /// Rules 3 and 4 are deliberately independent: an echo in the source's own
    /// script fails 3, a non-echo that is still in the wrong language fails 4,
    /// and an answer that fails neither is the only thing that may settle a
    /// region on the device.
    static func accepts(_ text: String,
                        for source: String,
                        targetLanguage: AppLanguage,
                        config: LiveTranslateConfig) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.count <= TranslationResponseParser.maxLength(forSource: source,
                                                               config: config) else { return nil }
        guard comparisonForm(text) != comparisonForm(source) else { return nil }
        if containsLetters(source), !usesTheTargetScript(text, targetLanguage: targetLanguage) {
            return nil
        }
        return text
    }

    /// A string's comparison form: case folded, with whitespace, punctuation
    /// and symbols dropped.
    ///
    /// It answers one question — "did the model change the words at all?" —
    /// for which typography is noise. Letters and digits survive in every
    /// script. Devanagari's vowel signs are neither punctuation nor symbols,
    /// so they survive too, which is what keeps two Devanagari strings
    /// comparable rather than collapsing them onto their consonants.
    static func comparisonForm(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars
        where !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.punctuationCharacters.contains(scalar)
            && !CharacterSet.symbols.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Whether the text has any letters at all — the guard on the script rule,
    /// so that a source made of digits and symbols is not refused for having
    /// no script to be translated into.
    static func containsLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Whether the text is written in the target language's own script.
    ///
    /// Script is the honest proxy available on device: a translation into
    /// Nepali is *in Devanagari*, and no amount of word-level cleverness is
    /// needed to know that an answer which contains none of it is not a Nepali
    /// translation. Both directions are covered, so the rule is about the
    /// target and not about Nepali specifically.
    static func usesTheTargetScript(_ text: String, targetLanguage: AppLanguage) -> Bool {
        switch targetLanguage {
        case .nepali:
            // Devanagari, including the extended block (the Vedic and
            // extended-sign ranges a transliteration or a name may carry).
            return text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value)
                                                    || (0xA8E0...0xA8FF).contains($0.value) }
        case .english:
            // ASCII letters. The English target is not the shipped one, so
            // this is the conservative reading: an answer with no Latin letter
            // in it at all is certainly not English.
            return text.unicodeScalars.contains { (0x41...0x5A).contains($0.value)
                                                    || (0x61...0x7A).contains($0.value) }
        }
    }

    private static func reason(for failure: BrainGenerationFailure) -> LiveTranslateBrainUnavailableReason {
        switch failure {
        case .loadFailed: return .modelLoadFailed
        case .promptOverflow, .generationFailed: return .inferenceFailed
        case .timedOut: return .inferenceTimeout
        }
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }
}

// MARK: - The production generator

/// The app's own llama.cpp runtime (`LLM.swift`), used the way the rest of the
/// app uses it: one handle per owner, created lazily, sampled deterministically
/// (`OnDeviceSampling`, shared with the voice interpreters so the same prompt
/// cannot sample differently on every run), and constrained at decode time by
/// a JSON Schema.
///
/// Two things this generator does that `LocalIntentInterpreter` does not:
///
///  - **It releases the handle when it goes idle**
///    (`brainTranslationIdleUnloadSeconds`). The camera feature has no turn
///    boundary to release at, and a 4B resident parked between scenes is
///    exactly the invisible-resident shape the residency ledger exists to
///    prevent. The tier takes no ledger slot (see the file header), so this is
///    its own honest answer to the same problem.
///  - **It interrupts on the deadline.** `LLM.stop()` breaks the decode loop,
///    so a generation that outlives `timeout` costs the deadline and not the
///    session, and the next batch is not queued behind a runaway decode.
actor LlamaBrainTextGenerator: BrainTextGenerating {

    private let config: LiveTranslateConfig
    /// Held as `Any?` so this file compiles when the LLM package is absent,
    /// exactly like the app's other guarded interpreters.
    private var handle: Any?
    private var handleModelURL: URL?
    private var lastUse: Date?
    /// The armed idle release, if one is. Cancelled and re-armed by every use,
    /// so the handle's lifetime is measured from the last batch and not from
    /// the first.
    private var idleRelease: Task<Void, Never>?

    init(config: LiveTranslateConfig = .default) {
        self.config = config
    }

    func generate(prompt: String,
                  jsonSchema: String,
                  modelURL: URL,
                  timeout: TimeInterval) async throws -> String {
        #if canImport(LLM)
        let llm = try loadHandle(modelURL: modelURL)
        defer {
            lastUse = Date()
            scheduleIdleRelease()
        }
        return try await Self.run(llm,
                                  prompt: prompt,
                                  jsonSchema: jsonSchema,
                                  timeout: timeout)
        #else
        _ = (prompt, jsonSchema, modelURL, timeout)
        throw BrainGenerationFailure.loadFailed
        #endif
    }

    func isHoldingHandle() async -> Bool { handle != nil }

    func release() async {
        idleRelease?.cancel()
        idleRelease = nil
        dropHandle()
    }

    /// Arms the idle release: `brainTranslationIdleUnloadSeconds` after the
    /// last use, the handle is dropped and its memory returned.
    ///
    /// **Scheduled, not checked.** This rule used to live inside `loadHandle`
    /// — the timer was only ever consulted on the way in to the *next*
    /// generation — so a session that stopped asking never reached it, and the
    /// 4B stayed resident for the rest of the session even though the tier's
    /// whole memory argument rests on it going away. Nothing about a camera
    /// session's shape guarantees another batch (the elder may have walked
    /// away), which is exactly why the release cannot be a side effect of
    /// using the handle again.
    private func scheduleIdleRelease() {
        idleRelease?.cancel()
        idleRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.config.brainTranslationIdleUnloadSeconds ?? 0))
            guard !Task.isCancelled else { return }
            await self?.releaseIfIdle()
        }
    }

    /// Drops the handle if nothing has used it since the timer was armed. The
    /// `lastUse` comparison is what makes a batch that landed while the timer
    /// was sleeping keep its handle: that batch re-armed the timer, so this
    /// call is a no-op and the new one decides.
    private func releaseIfIdle() {
        guard let lastUse,
              Date().timeIntervalSince(lastUse) >= config.brainTranslationIdleUnloadSeconds
        else { return }
        dropHandle()
    }

    private func dropHandle() {
        handle = nil
        handleModelURL = nil
        lastUse = nil
    }


    #if canImport(LLM)

    /// The resident handle for `modelURL`, loading it if there is none.
    ///
    /// The idle rule is not re-checked here: it is a timer
    /// (`scheduleIdleRelease`), so a handle that reaches this line is one the
    /// timer has not dropped, which means it is inside the idle window. One
    /// rule, one mechanism — the check this method used to carry was the only
    /// place the rule was ever consulted, and a session that stopped asking
    /// never got there.
    private func loadHandle(modelURL: URL) throws -> LLM {
        if let existing = handle as? LLM, handleModelURL == modelURL { return existing }

        // Passthrough template: generation calls `generateWithConstraints`
        // with the raw prompt, and the template's chat framing is only used by
        // `respond(to:)`, which this generator never calls.
        let template = Template(system: ("", ""), user: ("", ""), bot: ("", ""),
                                stopSequence: nil, systemPrompt: "")
        guard let created = LLM(from: modelURL,
                                template: template,
                                seed: OnDeviceSampling.fixedSeed,
                                topK: OnDeviceSampling.topK,
                                topP: OnDeviceSampling.topP,
                                temp: OnDeviceSampling.temperature,
                                repeatPenalty: OnDeviceSampling.repeatPenalty,
                                repetitionLookback: OnDeviceSampling.repetitionLookback,
                                maxTokenCount: Int32(LocalIntentInterpreter.contextTokenBudget)) else {
            throw BrainGenerationFailure.loadFailed
        }
        handle = created
        handleModelURL = modelURL
        return created
    }

    /// One generation, raced against its deadline.
    ///
    /// The budget guard runs first and fails fast: prompt and output share the
    /// 1,024-token context, so a prompt that leaves less than the output
    /// headroom does not produce a shorter answer, it produces a truncated
    /// one — and under temp 0 with a fixed seed that truncation is
    /// deterministic, not transient. A timeout is the one failure worth
    /// interrupting rather than reporting: `stop()` breaks the decode loop so
    /// the handle is usable again immediately.
    private static func run(_ llm: LLM,
                            prompt: String,
                            jsonSchema: String,
                            timeout: TimeInterval) async throws -> String {
        let promptTokens = await llm.encode(prompt).count
        guard promptTokens <= LocalIntentInterpreter.contextTokenBudget
                - LocalIntentInterpreter.outputHeadroomTokens else {
            throw BrainGenerationFailure.promptOverflow
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await llm.core.generateWithConstraints(from: prompt, jsonSchema: jsonSchema)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                llm.stop()
                throw BrainGenerationFailure.timedOut
            }
            // First result wins; on the deadline the sleep throws, the group
            // cancels, and the interrupted generation ends inside the runtime.
            let first = try await group.next() ?? {
                throw BrainGenerationFailure.generationFailed
            }()
            group.cancelAll()
            return first
        }
    }

    #endif
}
