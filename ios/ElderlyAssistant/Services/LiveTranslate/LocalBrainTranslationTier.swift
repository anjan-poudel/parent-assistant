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
//     handle is loaded lazily on the first attempt and released when it has
//     been idle for `brainTranslationIdleUnloadSeconds`, so the ledger's
//     total is never silently crossed by a handle this tier parked.

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

    static let none = LocalBrainTranslationOutcome(translations: [:], durationMs: 0)
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
}

extension BrainTextGenerating {
    func release() async {}
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

    init(config: LiveTranslateConfig = .default,
         modelStore: ModelStore?,
         events: LiveTranslateEvents,
         generator: (any BrainTextGenerating)? = nil) {
        self.config = config
        self.modelStore = modelStore
        self.events = events
        self.generator = generator ?? LlamaBrainTextGenerator(config: config)
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
            let output = try await generator.generate(prompt: Self.prompt(for: batch),
                                                      jsonSchema: Self.jsonSchema,
                                                      modelURL: modelURL,
                                                      timeout: config.brainTranslationTimeoutSeconds)
            let translations = Self.parse(output, sources: batch, config: config)
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
    /// Raw prompt, no chat template: the same convention the app's other brain
    /// paths use for these fine-tunes (see `LocalIntentInterpreter`'s raw
    /// prompt), and the schema travels beside the prompt as a parameter, never
    /// inside it — appending it is what truncated the intent brain's
    /// generations inside the shared 1,024-token context.
    static func prompt(for texts: [String]) -> String {
        var lines = [
            "You translate English text into Nepali.",
            "Answer with JSON only, exactly one Nepali translation per source, in the same order.",
            "Use \"\" for a source you cannot translate. Keep each translation short.",
            "",
            "Source texts:"
        ]
        for (offset, text) in texts.enumerated() {
            lines.append("\(offset + 1). \(text)")
        }
        return lines.joined(separator: "\n")
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
    /// A position the answer did not reach, a non-string, an empty string, an
    /// echo of the source, and a string over the shipped size-sanity bound are
    /// each *unresolved*: the region keeps its original text and the string
    /// goes on to the next tier, which is the same rule
    /// `TranslationResponseParser` applies to a cloud response (the bound is
    /// that parser's own, so the two tiers cannot disagree about what a
    /// plausible translation is).
    static func parse(_ raw: String,
                      sources: [String],
                      config: LiveTranslateConfig) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["translations"] as? [Any] else { return [:] }

        var translations: [String: String] = [:]
        for (position, source) in sources.enumerated() {
            guard position < list.count, let value = list[position] as? String else { continue }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard text != source.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            // The tier targets Nepali (v1): a translation with no Devanagari
            // is a wrong-language or echo artifact, never a usable answer —
            // unresolved, so the cloud tier carries it.
            guard Self.containsDevanagari(text) else { continue }
            guard text.count <= TranslationResponseParser.maxLength(forSource: source,
                                                                   config: config) else { continue }
            translations[source] = text
        }
        return translations
    }

    /// Devanagari block U+0900–U+097F — the same range the label localizer
    /// gates on, so the tier and the renderer agree about what Nepali is.
    static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
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

    init(config: LiveTranslateConfig = .default) {
        self.config = config
    }

    func generate(prompt: String,
                  jsonSchema: String,
                  modelURL: URL,
                  timeout: TimeInterval) async throws -> String {
        #if canImport(LLM)
        let llm = try loadHandle(modelURL: modelURL)
        defer { lastUse = Date() }
        return try await Self.run(llm,
                                  prompt: prompt,
                                  jsonSchema: jsonSchema,
                                  timeout: timeout)
        #else
        _ = (prompt, jsonSchema, modelURL, timeout)
        throw BrainGenerationFailure.loadFailed
        #endif
    }

    func release() async {
        handle = nil
        handleModelURL = nil
        lastUse = nil
    }

    #if canImport(LLM)

    /// The resident handle for `modelURL`, loading it if there is none — or if
    /// the one held has been idle past `brainTranslationIdleUnloadSeconds`, in
    /// which case its memory is given back before a new one is built.
    private func loadHandle(modelURL: URL) throws -> LLM {
        if let lastUse,
           Date().timeIntervalSince(lastUse) > config.brainTranslationIdleUnloadSeconds {
            handle = nil
            handleModelURL = nil
        }
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
