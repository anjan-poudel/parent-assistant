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
//      is empty, over the size bound, the source again in comparison form, not
//      written in the target language's script, or not *established as the
//      target language* where two languages share that script (2026-09-18,
//      `NepaliOutputGate`) is **unresolved** — it cannot end a string's
//      journey, and the cloud is asked for it. This is the tier's half of the
//      owner's report ("it no longer falls back to gemini; only the simplest
//      words translate"): a tier that settles whatever it produced, however
//      unusable, is a tier that removes the cloud from the cascade without
//      anyone deciding to. Because the two failure modes are opposite —
//      answering nothing, and answering something that is not an answer — this
//      is a separate rule from (3) rather than a special case of it.
//
//      The last of those is the evaluation rule, and it is why it is a rule at
//      all: Devanagari is the script of Hindi and Marathi as well as Nepali, so
//      "the answer is in Devanagari" is satisfied by a Hindi answer. Both
//      off-the-shelf Qwen rungs produced exactly that, and every guard above
//      passed it.
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
//   - **It takes its own residency slot, and only its own.** [MODEL-WARDEN]
//     Step 2 gives the tier `.translateBrain` — a pipeline position of its
//     own, distinct from the voice interpreters' `.brain` and
//     `.intentBrain`. Before that slot existed the tier could not register
//     at all: one entry per slot, and registering `.brain` from here would
//     have replaced the voice interpreter's release closure, so an eviction
//     would have freed the wrong handle while this tier's resident went on
//     being invisible to the budget. `.translateBrain` removes exactly that
//     obstacle, and Step 2's reservation kernel is what makes registering
//     safe: the handle is reserved on the way in, counted while it is
//     resident, and the ledger can *ask* for it back
//     (`TranslateBrainHandleSlot.releaseForWarden`) rather than only take
//     it. The idle rule is unchanged — the handle is loaded lazily on the
//     first attempt and released `brainTranslationIdleUnloadSeconds` after
//     the last one — so the slot is empty between sessions, and now the
//     ledger can see that it is.
//
//     What it still never does is touch another owner's position: the
//     ledger is read for `.brain` / `.intentBrain` residency (the deferral
//     rule) and written only for `.translateBrain`.

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

extension LocalBrainTranslationTier {
    /// [DYNAMIC-TIMEOUT] (owner directive: "a default floor and the rest
    /// driven by the source text's length.") The effective bound for one
    /// batch: the floor plus a per-character share of the source text,
    /// clamped to the kill-safe ceiling. Pure and static so the suites pin
    /// it without a model.
    static func effectiveTimeout(for strings: [String],
                                 config: LiveTranslateConfig) -> TimeInterval {
        let characters = strings.reduce(0) { $0 + $1.count }
        let dynamic = config.brainTranslationBaseTimeoutSeconds
            + Double(characters) * config.brainTranslationTimeoutPerCharacterSeconds
        return min(config.brainTranslationMaxTimeoutSeconds, dynamic)
    }
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
    ///
    /// Bytes, as `Double`: the two sources are byte counts and the comparison
    /// is a comparison, so the payload carries their value and not their
    /// integer width — bytes are far below the range where the two disagree,
    /// and a gate that must not trap on a device reading keeps no conversion
    /// that can (the hygiene scan also reads a `…64` type name as a
    /// re-declared default, which is a false positive this spelling avoids).
    case insufficientHeadroom(requiredBytes: Double, availableBytes: Double)
    /// [PRESSURE-SAFE LOAD] (2026-09-19) The kernel's own memory-pressure
    /// level is `.warning` or `.critical` right now.
    ///
    /// The rule the 2026-09-19 device death was missing. The headroom case
    /// above is arithmetic on `os_proc_available_memory()`, which is the
    /// app's ceiling under its own jetsam limit — and a phone whose *system* is
    /// out of free pages, with the kernel already killing daemons, can still
    /// read as roomy by that measure, because the app has not been charged for
    /// anything yet. The kernel's level is the second opinion, and it is the
    /// one that describes the device rather than the app's account on it.
    case memoryPressure(level: MemoryPressureLevel)
    /// [PRESSURE-SAFE LOAD] `.critical` fired inside
    /// `brainTranslationCriticalPressureWindowSeconds`, so a load is refused
    /// even though the level has since eased.
    ///
    /// A `.critical` is an instant, not a state: the kernel says nothing more
    /// until it says something, and the quiet minute after it is exactly when
    /// the "we were nearly killed" fact is still the most honest thing known
    /// about the device. The numbers travel with the reason, the same way the
    /// headroom case's do, so a capture can tell a window that is too wide
    /// from a device that is genuinely under water.
    case recentCriticalPressure(secondsSince: Double, windowSeconds: Double)
    /// [PRESSURE-SAFE LOAD] The load had already been admitted and declared in
    /// flight when a warden asked for this tier's position. The ask cannot be
    /// honoured — there is no handle to drop yet — so the load stands down
    /// instead of re-filling, microseconds later, the row the warden just
    /// cleared.
    ///
    /// Only ever produced by the load path and never by the pre-attempt gate:
    /// it is the *late* half of the same vocabulary, and the tier's own
    /// `deferralForLoad` cannot see it because before the load is declared in
    /// flight there is nothing for a warden to ask for.
    case releaseRequestedDuringLoad
}

extension LocalBrainDeferral {
    /// The closed token this deferral travels as on `brain_translation_batch`.
    ///
    /// One mapping, here, so the vocabulary a capture reads cannot drift from
    /// the vocabulary the tier decides in: every case has exactly one token
    /// and the switch has no `default`, which makes a new deferral a compile
    /// error until it is named.
    var eventReason: LiveTranslateBrainDeferralReason {
        switch self {
        case .residentBrain: return .residentBrain
        case .insufficientHeadroom: return .insufficientHeadroom
        case .memoryPressure: return .memoryPressure
        case .recentCriticalPressure: return .recentCriticalPressure
        case .releaseRequestedDuringLoad: return .releaseRequestedDuringLoad
        }
    }
}

/// The two moments the warden's hand-off owes the elder an explanation.
///
/// Owner directive, 2026-09-19: "keep the user in the loop so they don't
/// wonder about the silences." Both are moments where the camera feature is
/// doing something the elder did not ask for and cannot see: paying a model
/// load, or handing its model to the voice stack.
///
/// **This is the indicator path a surface renders.** The tier pushes these
/// through `LocalBrainTranslationTier.setWardenNoticeSink`; the sentence is
/// `copyKey`'s catalog entry, resolved in the active language — never a
/// literal at a call site, and never a value on the event vocabulary (see
/// `LiveTranslateEvents.brainTranslationLoadAnnounced` / `…Preempted`, which
/// record the same two moments as counts).
enum LocalBrainWardenNotice: String, Equatable, CaseIterable, Sendable {
    /// A handle has to page in before this batch can run. The elder is
    /// looking at untranslated text with nothing on screen to explain the
    /// wait, which is the whole reason this moment has copy.
    case loadingModel
    /// The warden took the translation model for the voice stack. The
    /// alternative to saying so is a session that silently stops
    /// translating, which reads as the feature being broken.
    ///
    /// The one caveat, stated because the copy is the owner's own words: the
    /// warden's hand-off does not say *who* asked for the bytes, so a load
    /// that is not a voice turn (a Settings picker picking a brain, say)
    /// produces the same sentence. In this app the only thing that takes a
    /// 2.6 GB handle mid-session is the voice stack, and the owner's
    /// directive names exactly that case.
    case offloadedForVoiceTurn

    /// The catalog entry this notice renders. Pinned by
    /// `LiveTranslateCopyTests`, which resolves every case in en and ne, so a
    /// notice cannot exist without a sentence an elder can read.
    var copyKey: String {
        switch self {
        case .loadingModel: return "livetranslate.warden.loading"
        case .offloadedForVoiceTurn: return "livetranslate.warden.offloaded"
        }
    }
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

    /// Told when the warden takes the resident handle away on a path the tier
    /// did not ask for — the preemption ask, or the registered release path
    /// when that ask was refused and overruled.
    ///
    /// Not `async` and deliberately not awaited: the warden calls it from its
    /// own reservation path, outside its lock, and nothing about admitting a
    /// voice turn's model may wait on a camera feature's bookkeeping. A
    /// generator that holds nothing (every fake) keeps the default no-op,
    /// which is why this is a requirement with a default rather than a new
    /// parameter on `generate`.
    func setWardenOffloadHandler(_ handler: (@Sendable () -> Void)?)
}

extension BrainTextGenerating {
    func release() async {}
    func isHoldingHandle() async -> Bool { false }
    func setWardenOffloadHandler(_ handler: (@Sendable () -> Void)?) {}
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
    /// The caller stopped waiting for this attempt, so the decode was stopped
    /// with it.
    ///
    /// Its own case rather than a second spelling of `timedOut` (added
    /// 2026-09-17, the device report): the two point at different halves of
    /// the attempt. `timedOut` means the tier's own bound was reached *during
    /// the decode* — the model and the batch are what is too slow. `cancelled`
    /// means the caller's own stage deadline expired first, which is only
    /// possible when everything before the decode (the handle load, or a
    /// previous attempt's decode still holding the runtime) ate the budget —
    /// a fact about the tier's *queue*, not about its model. Collapsing them
    /// is what made the device's console unreadable: every overrun reported
    /// `inference_failed`, the one token that describes neither.
    case cancelled
    case generationFailed
    /// [MODEL-WARDEN] Step 1 — the warden refused the allocation before a
    /// single byte was spent (`ModelLifecycleManager.reserve`). Distinct
    /// from `loadFailed`, which means the runtime tried and the artifact
    /// would not construct: this one means nobody tried, on purpose, and
    /// the `ReservationDenial` says why (budget, a competing load, the
    /// app's headroom). The tier answers both the same way — the strings
    /// fall through to the next tier — but the capture must not confuse
    /// "the device cannot hold this" with "this artifact is broken".
    case loadDenied(ReservationDenial)
    /// [PRESSURE-SAFE LOAD] (2026-09-19) The load was stood down *after* it
    /// had been admitted, before the runtime was asked to construct anything.
    ///
    /// The fourth thing that can happen to an admitted load, and the one the
    /// 2026-09-19 device death was made of. `loadDenied` is the warden saying
    /// no at the door; this is the device changing while the load walked
    /// through it — the reserve's own eviction sweep takes seconds (release
    /// closures run `llama_model_free`), and a `.critical` that lands inside
    /// that window is a refusal the caller never got to see. The load is a
    /// *future* spike, and this is the last instant at which declining to
    /// create it is still free.
    ///
    /// It carries the deferral it found, so the reason and the numbers are the
    /// tier's own vocabulary rather than a second one invented here.
    case loadAbandoned(LocalBrainDeferral)
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

    /// Where the two warden notices go, if anything is listening. A sink
    /// rather than a return value because both moments happen *during* an
    /// attempt — a load that is running, a handle that was just taken — and
    /// an outcome can only be read after it.
    ///
    /// Nil is the honest default: the events still record both moments, and
    /// a caller that has nothing to render loses nothing. Set at init or
    /// later via `setWardenNoticeSink`.
    private var noticeSink: (@Sendable (LocalBrainWardenNotice) -> Void)?

    /// How many strings are riding on the attempt in flight, so an offload
    /// that lands mid-decode can say what it cost. 0 between attempts — and a
    /// preemption that lands while the handle is idle is honestly a
    /// zero-cost hand-off.
    ///
    /// Actor-isolated and read from `noteWardenTookTheHandle`, which runs on
    /// this actor: the decode is an `await`, so the actor is free to answer
    /// while it is running.
    private var inFlightStrings = 0

    init(config: LiveTranslateConfig = .default,
         modelStore: ModelStore?,
         events: LiveTranslateEvents,
         generator: (any BrainTextGenerating)? = nil,
         targetLanguage: AppLanguage = LiveTranslationPipeline.defaultTargetLanguage,
         memory: MemoryProbing = SystemMemoryProbe(),
         ledger: ModelLifecycleManager = .shared,
         onWardenNotice: (@Sendable (LocalBrainWardenNotice) -> Void)? = nil) {
        self.config = config
        self.modelStore = modelStore
        self.events = events
        let generator = generator ?? LlamaBrainTextGenerator(config: config)
        self.generator = generator
        self.targetLanguage = targetLanguage
        self.memory = memory
        self.ledger = ledger
        self.noticeSink = onWardenNotice
        // The warden can take the handle at any moment, so the wiring is
        // done here rather than at the first load: an offload that beats the
        // first batch would otherwise be the one nobody hears about.
        generator.setWardenOffloadHandler { [weak self] in
            Task { await self?.noteWardenTookTheHandle() }
        }
    }

    /// Attaches (or detaches) the surface that renders the warden's two
    /// notices. A method rather than only an init parameter, because the
    /// surface is built after the session is: a camera that attaches late
    /// still gets every notice after it attaches, and nothing before it is
    /// owed to a surface that did not exist.
    func setWardenNoticeSink(_ sink: (@Sendable (LocalBrainWardenNotice) -> Void)?) {
        noticeSink = sink
    }

    /// A hand-off the tier did not ask for: the warden took the handle for
    /// another reservation. Called from the warden's thread via a `Task`, so
    /// it reads the in-flight count on this actor.
    private func noteWardenTookTheHandle() {
        events.brainTranslationPreempted(count: inFlightStrings)
        noticeSink?(.offloadedForVoiceTurn)
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

        // [DYNAMIC-TIMEOUT] (owner directive, 2026-09-20, re-landed on the
        // owner's 21:16/21:18 captures: the flat 25 s bound refused the
        // medical-page batches — one string of 110–180 characters, which
        // the model needs ~0.2 s/char for.) The effective bound is the
        // floor plus the source text's length, clamped to the kill-safe
        // ceiling. Computed once here, so the generation call below and
        // the tier's own deadline record agree.
        let timeout = Self.effectiveTimeout(for: strings, config: config)

        #if canImport(LLM)
        guard let modelStore, let modelID = installedModel(),
              let modelURL = modelStore.path(for: modelID) else {
            // No store, no catalogue entry, or no installed artifact: the tier
            // is skipped and says so. The strings fall through untouched.
            events.brainTranslationUnavailable(modelStore == nil ? .runtimeMissing : .modelNotInstalled,
                                               stage: .availability)
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
                                         durationMs: 0,
                                         deferral: deferral.eventReason)
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

        // [WARDEN-NOTICE] The "hold on a sec" moment (owner directive,
        // 2026-09-19). A batch that has to page in a 2.6 GB handle takes
        // seconds, and the elder is looking at text that has not changed with
        // nothing on screen to explain why. Asked of the generator rather
        // than assumed: a handle already resident costs no load, and
        // announcing one would be a wait the elder is not having.
        //
        // Announced when the load is *due*, not when it succeeds — a load
        // that then fails reports its own reason through
        // `brainTranslationUnavailable`, and the notice was still true.
        if await generator.isHoldingHandle() == false {
            events.brainTranslationLoadAnnounced(count: batch.count)
            noticeSink?(.loadingModel)
        }

        let started = Date()
        // The attempt in flight, for a warden preemption that lands during
        // it. Cleared on every exit — a hand-off between attempts is a
        // zero-cost one, and stale counts would say otherwise.
        inFlightStrings = batch.count
        defer { inFlightStrings = 0 }
        do {
            let output = try await generator.generate(prompt: Self.prompt(for: batch,
                                                                          targetLanguage: targetLanguage),
                                                      jsonSchema: Self.jsonSchema,
                                                      modelURL: modelURL,
                                                      timeout: timeout)
            let report = Self.report(output,
                                     sources: batch,
                                     targetLanguage: targetLanguage,
                                     config: config)
            // [EMPTY-DECODE] The generation's own self-portrait rides with the
            // counts: the raw length, the shape, and which rule refused what.
            // Without it a capture cannot tell a decode that emitted nothing
            // from one whose every answer a rule refused — the two fixes are
            // opposite, and the owner's answered-nothing batches were exactly
            // this ambiguity.
            let translations = report.translations
            // [DEBUG-LOG] (owner directive, 2026-09-20) The pairs and the
            // leg's time go to the sanitised debug lane rather than to the
            // console. `LiveTranslateDebugLane` hands them to the observability
            // bus and `LogSanitiser` redacts the strings at that choke point,
            // so a capture still shows that a pair happened, in the batch's own
            // order, with its timing — and the text never reaches a log surface
            // in any configuration (NFR-LCT-006). The feature's own sources
            // carry no console write at all.
            let durationMs = Self.milliseconds(since: started)
            #if DEBUG
            LiveTranslateDebugLane(bus: events.bus,
                                   enabled: config.translationDebugLoggingEnabled)
                .translationPairs(batch.compactMap { source -> (source: String, translation: String)? in
                    guard let translation = translations[source] else { return nil }
                    return (source: source, translation: translation)
                }, leg: .local, durationMs: durationMs)
            #endif

            // The counts are about the BATCH THE CALLER HANDED OVER, not about
            // the part that fitted: a bounded batch reports its surplus as
            // unresolved, which is what the caller then sends onward.
            events.brainTranslationBatch(resolvedCount: translations.count,
                                         unresolvedCount: strings.count - translations.count,
                                         durationMs: durationMs,
                                         generation: report.reading)
            return LocalBrainTranslationOutcome(translations: translations,
                                                durationMs: durationMs)
        } catch let failure as BrainGenerationFailure {
            events.brainTranslationUnavailable(Self.reason(for: failure),
                                               stage: Self.stage(for: failure))
            return .none
        } catch {
            // A llama.cpp error this tier does not classify is still a failure
            // it reports, with the token that says "the generation failed" —
            // and, now, the stage that says it came out of the decode.
            events.brainTranslationUnavailable(.inferenceFailed, stage: .decode)
            return .none
        }
        #else
        _ = strings
        // Built without the llama.cpp runtime: no model can be run, whatever is
        // on disk. Recorded once per sighting by the caller's claim, not once
        // per frame.
        events.brainTranslationUnavailable(.runtimeMissing, stage: .availability)
        return .none
        #endif
    }

    func release() async {
        await generator.release()
    }

    // MARK: The resource gate

    /// Why the brain may not be loaded for this batch, if it may not.
    ///
    /// Three rules, in order, and all of them are about the device rather than
    /// about the translation:
    ///
    ///  1. **Another owner's brain is live.** The voice pipeline holds `.brain`
    ///     or `.intentBrain` while the household is talking to it; a second 4B
    ///     decode alongside it is the shape that gets the app killed, and the
    ///     translation is the workload that can afford to wait — the elder is
    ///     reading a sign, not waiting on an answer. Asked of the ledger, and
    ///     asked about the *other* owners' positions: the tier owns
    ///     `.translateBrain` since Step 2, and this rule is why it never has
    ///     to look at its own row to decide — a live `.brain` or
    ///     `.intentBrain` means the voice pipeline is mid-conversation, and
    ///     that is a different question from whether this tier's own handle
    ///     is resident (which is the very next line).
    ///
    ///  2. **The kernel says the device is out of memory.** [PRESSURE-SAFE
    ///     LOAD] The rule the 2026-09-19 device death was missing, and it sits
    ///     here — after the resident-handle check and before the arithmetic —
    ///     for a reason that is itself part of the fix. It is a gate on a
    ///     *load*, so it is asked only where a load would happen; and it is
    ///     asked before the headroom comparison because it is the *stronger*
    ///     signal. `os_proc_available_memory()` describes the app's account
    ///     under its own ceiling, and a phone whose system is out of free
    ///     pages can still read as roomy by it: nothing has been charged to
    ///     this app yet, while the kernel is already killing other processes.
    ///     When the two disagree, the kernel is the one describing the device.
    ///
    ///     This is the half the testing bypass may **not** skip. See
    ///     `pressureDeferral(_:windowSeconds:)` and `loadHandle`.
    ///
    ///  3. **There is not enough headroom for the load.** The comparison is
    ///     `ModelFootprint.hardBytes` against the app's own reading of its
    ///     ceiling — the ledger's own rule, and the reason the pageable
    ///     weights are not charged twice: what must fit is the KV and runtime
    ///     cost, because the weights page in and out under the kernel.
    ///
    /// The first two rules apply only when a load would actually happen: the
    /// bytes of a resident handle are already spent, and deferring the batch
    /// that is reusing them would buy the device nothing at all. That is why
    /// the handle check comes first — and it is also why the pressure rule is
    /// not asked before it. A handle that survived a `.critical` (the warden's
    /// ask was refused mid-decode, or the slot was spared a force) means the
    /// load has already happened; refusing the *decode* then would cost an
    /// answer without returning a byte.
    private func deferralForLoad(of modelID: ModelID) async -> LocalBrainDeferral? {
        if config.brainTranslationDefersToResidentBrain,
           ledger.isResident(.brain) || ledger.isResident(.intentBrain) {
            return .residentBrain
        }
        if await generator.isHoldingHandle() { return nil }

        if let pressure = Self.pressureDeferral(
            ledger.memoryPressureReading(),
            windowSeconds: config.brainTranslationCriticalPressureWindowSeconds) {
            return pressure
        }

        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: modelID)
        let required = Double(footprint.hardBytes) * config.brainTranslationHeadroomFactor
        let available = Double(memory.availableProcessMemoryBytes)
        guard available < required else { return nil }
        return .insufficientHeadroom(requiredBytes: required, availableBytes: available)
    }

    /// [PRESSURE-SAFE LOAD] The kernel's half of the gate, as a pure function
    /// of the reading and the tier's window.
    ///
    /// **One rule, two callers, and this is the reason it is a static
    /// function.** The pre-attempt gate above and the load path's
    /// before-you-allocate check (`LlamaBrainTextGenerator.loadHandle`) ask the
    /// same question at two different moments, and they must not be able to
    /// disagree about the answer — a second copy of this comparison is exactly
    /// how a load ends up refused at the door and then taken anyway through a
    /// window the second copy forgot.
    ///
    /// A fresh `.warning` and a fresh `.critical` both refuse. A warning is the
    /// OS asking for memory back and the only honest answer to "may I spend
    /// another 1 GB" is no; a critical is it about to act, where a load begun
    /// now would still be allocating while the kernel reclaims. The window
    /// covers the third case the level cannot: a device that was critical
    /// seconds ago and has been quiet since.
    ///
    /// [PRESSURE-LATCH] (2026-09-19) **The two levels are not read the same
    /// way, and the asymmetry is the fix — until the device said otherwise.**
    /// A `.critical` was assumed paired: the dispatch source that sends it
    /// also sends `.normal` when the pressure eases, and that second event is
    /// what clears the level — so a level that still reads `.critical` was a
    /// device that is still critical, and refusing on it needed no age. The
    /// owner's 15:51 capture falsified the assumption: forty-two seconds of
    /// uniform `reason=memory_pressure durationMs=0` refusals while the
    /// warden was silent — no pressure events, no evictions — so a latched
    /// `.critical` is a real mode on this device, and it now ages out on the
    /// same window as the warning, with the caller's headroom arithmetic as
    /// the second line of defence. A `.warning` has a route with no counterpart:
    /// `UIApplication.didReceiveMemoryWarningNotification` arrives, the
    /// manager records `.warning`, and nothing on that path ever takes it
    /// back. On a device where only that route has fired — no dispatch source,
    /// or a warning between source updates — the level latches for the life of
    /// the process and this gate would refuse **every** subsequent load with a
    /// `durationMs=0` deferral, long after the pressure that caused it had
    /// passed. So a warning is only refused while it is *recent*: the same
    /// recency window the critical timestamp uses, on the warning timestamp
    /// (`MemoryPressureReading.secondsSinceWarning`), and past that the level
    /// is stale evidence and the only thing left worth checking is the
    /// critical age below.
    ///
    /// A reading that carries the level but no age at all (`nil`) is treated
    /// as fresh, deliberately: every caller that builds a reading by hand is a
    /// test, and "no timestamp" must not become a way to smuggle a refused
    /// warning past the gate.
    static func pressureDeferral(_ reading: MemoryPressureReading,
                                 windowSeconds: TimeInterval) -> LocalBrainDeferral? {
        switch reading.level {
        case .critical:
            // [PRESSURE-LATCH] (2026-09-19, owner's 15:51 device capture)
            // The critical level latches exactly the way the warning did:
            // forty-two seconds of uniform `reason=memory_pressure
            // durationMs=0` refusals while the warden was silent — no
            // pressure events, no evictions, nothing that would still be
            // firing if the device were still critical. A fresh critical is
            // the kernel about to act, and refuses as the level itself
            // (same token as before); a critical older than the window is
            // stale evidence and falls through to the caller's headroom
            // arithmetic, which re-checks the process's own account and
            // refuses a genuinely starved device there.
            if let age = reading.secondsSinceCritical, age >= windowSeconds {
                break // stale critical — the level latched, the pressure did not
            }
            return .memoryPressure(level: .critical)
        case .warning:
            if let age = reading.secondsSinceWarning, age >= windowSeconds {
                break // stale warning — the level latched, the pressure did not
            }
            return .memoryPressure(level: .warning)
        case .normal:
            break
        }
        if let age = reading.secondsSinceCritical, age < windowSeconds {
            return .recentCriticalPressure(secondsSince: age, windowSeconds: windowSeconds)
        }
        return nil
    }

    // MARK: Bounding

    /// The prefix of `strings` that fits one request: at most
    /// `brainTranslationMaxStrings` strings and `brainTranslationMaxCharacters`
    /// characters. A string that does not fit ends the prefix (the rule is
    /// "the first N that fit", so the same scene always produces the same
    /// batch), and everything past it is left to the next tier.
    private func boundedBatch(_ strings: [String]) -> [String] {
        Array(strings.prefix(Self.batchPrefixLength(of: strings, config: config)))
    }

    /// The prefix of `strings` that fits one request — the bound above, as a
    /// number, so that a *caller* can know what the tier will be asked about
    /// before it hands the batch over.
    ///
    /// The rule is the tier's own and stays in one place: this is the same walk
    /// `boundedBatch` performs. It is published because what is **not** asked
    /// must not be claimed: a plan that hands over more than the bound and
    /// records the whole batch as generation-paid claims a payment that was
    /// never made, and a plan that then fails the surplus records a failure on a
    /// tier the strings never reached (review of #100, finding 2). The caller
    /// reads this and defers the rest instead.
    static func batchPrefixLength(of strings: [String], config: LiveTranslateConfig) -> Int {
        var count = 0
        var characters = 0
        for text in strings {
            guard count < config.brainTranslationMaxStrings,
                  characters + text.count <= config.brainTranslationMaxCharacters
            else { break }
            count += 1
            characters += text.count
        }
        return count
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
            "Translate the MEANING into natural \(language) sentences — never write \(source) words "
                + "in \(language) letters, never transliterate. A translation of \"cough\" is the "
                + "\(language) word for coughing, not the sound \"cough\" spelled in \(language) script.",
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

    /// One generation, classified: what shape it came back in, which rule
    /// refused each answer, and the translations that survived.
    ///
    /// Maps a positional answer back onto the sources it was asked about — the
    /// shape the cloud's parser uses, one answer per source in order, so a
    /// short answer is detected instead of silently shifting every later
    /// translation onto the wrong sign. A position the answer did not reach, a
    /// non-string, and anything `accepts` refuses are each *unresolved*: the
    /// region keeps its original text and the string goes on to the next tier,
    /// which is the same rule `TranslationResponseParser` applies to a cloud
    /// response.
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
    ///
    /// [EMPTY-DECODE] (2026-09-19) `translations` is the half the caller uses;
    /// the rest of the type is what the owner's answered-nothing device report
    /// could not see. Three batches ran 7–20 seconds each and resolved zero
    /// strings; the counts said "the tier failed" and could not say whether the
    /// decode had emitted anything at all. The shape and the histogram are that
    /// missing half, and they are content-free: a closed token and counts keyed
    /// by a closed enum. No part of this type holds the answer, the source or
    /// any substring of either.
    ///
    /// The classification is the **same** code path that decides the
    /// translations (`rejection(of:for:targetLanguage:config:)`), so a capture
    /// cannot name a rule the tier does not actually apply.
    struct AnswerReport: Equatable {
        /// The raw answer's length in characters — never the characters.
        let length: Int
        let shape: BrainGenerationShape
        /// Rule → how many answers it refused. Empty when nothing was refused.
        let rejections: [BrainAnswerRejection: Int]
        let translations: [String: String]

        /// The content-free form the event carries.
        var reading: BrainGenerationReading {
            BrainGenerationReading(length: length, shape: shape, rejections: rejections)
        }
    }

    static func report(_ raw: String,
                       sources: [String],
                       targetLanguage: AppLanguage,
                       config: LiveTranslateConfig) -> AnswerReport {
        let length = raw.count
        // The structural half. `empty` is exactly "the decode returned no
        // characters"; anything non-empty that will not parse is `unparsable`,
        // which is the shape a wrapped or truncated answer takes.
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AnswerReport(length: length,
                                shape: raw.isEmpty ? .empty : .unparsable,
                                rejections: [:],
                                translations: [:])
        }
        guard let list = object["translations"] as? [Any] else {
            return AnswerReport(length: length, shape: .noArray, rejections: [:], translations: [:])
        }

        var translations: [String: String] = [:]
        var rejections: [BrainAnswerRejection: Int] = [:]
        for (position, source) in sources.enumerated() {
            // The positional rules first, because they are about the ANSWER
            // SLOT rather than about what the model said in it: a short array
            // is a decode that stopped, and a non-string is the grammar's
            // array holding something else.
            guard position < list.count else {
                rejections[.missing, default: 0] += 1
                continue
            }
            guard let value = list[position] as? String else {
                rejections[.nonString, default: 0] += 1
                continue
            }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let refusal = rejection(of: text,
                                       for: source,
                                       targetLanguage: targetLanguage,
                                       config: config) {
                rejections[refusal, default: 0] += 1
                continue
            }
            translations[source] = text
        }
        return AnswerReport(length: length, shape: .array,
                            rejections: rejections, translations: translations)
    }

    /// Why an answer is not a translation of `source`, in the tier's own
    /// closed vocabulary — or `nil` when it is one.
    ///
    /// **The one classification path.** `accepts` is this function's `nil`
    /// case and nothing else: a rule that decides an answer must be the rule
    /// that reports why it was refused, or a device capture ends up naming a
    /// rule the tier does not apply — which is exactly the confusion
    /// [EMPTY-DECODE] exists to end.
    static func rejection(of text: String,
                          for source: String,
                          targetLanguage: AppLanguage,
                          config: LiveTranslateConfig) -> BrainAnswerRejection? {
        guard !text.isEmpty else { return .empty }
        guard text.count <= TranslationResponseParser.maxLength(forSource: source,
                                                               config: config) else { return .tooLong }
        guard comparisonForm(text) != comparisonForm(source) else { return .echo }
        if containsLetters(source), !usesTheTargetScript(text, targetLanguage: targetLanguage) {
            return .wrongScript
        }
        // The gate is asked for its verdict rather than its boolean, so the
        // three reasons it already distinguishes reach the histogram as
        // themselves instead of collapsing into one token.
        switch NepaliOutputGate.verdict(for: text, targetLanguage: targetLanguage) {
        case .accept: return nil
        case .reject(.instructionEcho): return .instructionEcho
        case .reject(.hindiEvidence): return .hindiEvidence
        case .reject(.noNepaliEvidence): return .noNepaliEvidence
        }
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
    ///  5. **Not written in the target's language** (2026-09-18,
    ///     `NepaliOutputGate`). The script rule's blind spot: Devanagari is
    ///     Hindi's script too, so a Hindi answer passes rule 4 by
    ///     construction, and the evaluation produced one on both off-the-shelf
    ///     rungs — as it produced instruction echoes that were in Nepali but
    ///     were not translations at all. The gate scores the answer's Nepali
    ///     evidence against its Hindi evidence and accepts only what is
    ///     *established* as Nepali, which is the conservative half of the two
    ///     directions: a wrong rejection costs a cloud call, a wrong acceptance
    ///     shows an elder Hindi as their own language.
    ///
    /// Rules 3, 4 and 5 are deliberately independent: an echo in the source's
    /// own script fails 3, a non-echo that is still in the wrong language fails
    /// 4, a non-echo in Devanagari that is not Nepali fails 5, and an answer
    /// that fails none of them is the only thing that may settle a region on
    /// the device.
    ///
    /// The rules themselves live in `rejection(of:for:targetLanguage:config:)`
    /// — one path, so the tier cannot decide by one rule and report by another
    /// — and this is that path's `nil` case: the answer, or nothing.
    static func accepts(_ text: String,
                        for source: String,
                        targetLanguage: AppLanguage,
                        config: LiveTranslateConfig) -> String? {
        guard rejection(of: text, for: source,
                        targetLanguage: targetLanguage, config: config) == nil else { return nil }
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
        // A warden refusal rides with `loadFailed` here, and deliberately:
        // this token is four wide by design (it says what the CALLER must
        // do, which for both is "hand these strings to the next tier").
        // The precise cause — `budget_exhausted` vs `load_in_flight` vs
        // `insufficient_headroom`, with the slot and purpose — is on the
        // ledger's own `reservation_denied` event, which is emitted at the
        // moment of refusal and is the record a capture is read for.
        case .loadFailed, .loadDenied: return .modelLoadFailed
        // [PRESSURE-SAFE LOAD] An abandoned load reads as `model_load_failed`
        // for the same reason a warden refusal does: this token is four wide
        // by design and says what the CALLER must do, which for both is "hand
        // these strings to the next tier". The precise cause — the level, the
        // age of the last critical, the warden's ask — is on the stage token
        // and on `brain_translation_batch`'s `reason`, which is where a
        // capture reads it.
        case .loadAbandoned: return .modelLoadFailed
        case .promptOverflow, .generationFailed: return .inferenceFailed
        case .timedOut, .cancelled: return .inferenceTimeout
        }
    }

    /// Where the attempt stopped, for the `failureStage` metadata key.
    ///
    /// The second half of the same report `reason(for:)` serves, and the one
    /// that makes a device capture actionable: the reason tokens are four
    /// wide by design (what the caller must do), while the stage is seven
    /// wide (what the implementation did). Every case is named by the code
    /// path that throws it, so the two cannot drift.
    private static func stage(for failure: BrainGenerationFailure) -> BrainFailureStage {
        switch failure {
        // Same reasoning as `reason(for:)`: `load` is the stage that means
        // "no handle exists and none was decoded from", which is exactly
        // what a refusal produces. The ledger names the refusal precisely.
        case .loadFailed, .loadDenied: return .load
        // [PRESSURE-SAFE LOAD] Its own stage: nothing was constructed and
        // nothing failed — the device declined, and that is a different fact
        // from a corrupt artifact (see `BrainFailureStage.loadAbandoned`).
        case .loadAbandoned: return .loadAbandoned
        case .promptOverflow: return .promptBudget
        case .timedOut: return .deadline
        case .cancelled: return .cancelled
        case .generationFailed: return .decode
        }
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }
}

// MARK: - The production generator

/// The tier's handle, boxed so a warden can take it away from outside the
/// actor.
///
/// **Why a box and not three stored properties.** [MODEL-WARDEN] Step 2 makes
/// the tier's handle *preemptible*: the ledger registers `.translateBrain`
/// with a `resident:`, and the manager may call `releaseForWarden()` on the
/// caller's thread (never on this actor, and never holding its own lock). An
/// actor's isolated state cannot be reached that way, so the one thing both
/// sides must agree on — "is there a runtime here, and which URL is it" —
/// lives in this lock-guarded box instead, and the actor reads it through
/// `currentHandle` / `heldModelURL`.
///
/// **What it protects.** Three facts, always read together: the handle, the
/// URL it was loaded from (so a re-load for the same artifact is a no-op and a
/// load for a different one is a reload), and whether a decode is running.
///
/// **The lease.** While `beginDecode`/`endDecode` bracket is open the box
/// answers `.refused(.inUse)`. A refusal is not a veto — `.translateBrain`'s
/// release contract is `actorDeferredFree`, which `allowsForcedUnload`, so a
/// higher-priority reservation that cannot fit may invoke the registered
/// release path anyway. That is safe rather than merely convenient: the free
/// is deferred by ARC, and the running decode holds the runtime itself, so
/// forcing here drops the *ledger's* claim on bytes that come back the moment
/// the existing `stopDecode` ends the decode. The ledger's count is
/// momentarily low by that one handle for exactly as long as the decode it
/// already bounded takes to stop.
///
/// It conforms to `ModelResident` and **must not re-enter the manager**: the
/// manager's lock is non-recursive, and `releaseForWarden` runs outside it.
/// Nothing here calls back into `lifecycle` — the tier does that itself, from
/// its own path (`dropHandle`).
final class TranslateBrainHandleSlot: ModelResident, @unchecked Sendable {

    private let lock = NSLock()
    private var handle: Any?
    private var handleModelURL: URL?
    /// Depth, not a flag: `beginDecode`/`endDecode` are paired across a
    /// `defer`, and a depth that leaks upward would make the box refuse a
    /// preemption for the rest of the session.
    private var decodeDepth = 0
    /// [PRESSURE-SAFE LOAD] (2026-09-19) The same shape for a load: non-zero
    /// from just before the warden is asked to reserve, through the
    /// synchronous runtime construction, to the moment the handle is stored.
    ///
    /// **Why it spans more than the construction.** The interval that killed
    /// the owner's phone was the whole of this window, not just `LLM.init`.
    /// `lifecycle.reserve` evicts before it admits, and an eviction runs
    /// release closures (`llama_model_free` is not instant), so seconds can
    /// pass between the decision to load and the allocation — with the slot
    /// holding no handle and therefore answering `.notHolding` to every ask.
    private var loadDepth = 0
    /// [PRESSURE-SAFE LOAD] Set when an ask arrives while a load is in
    /// flight, and read by the load path at each of its checkpoints. This is
    /// the "abandon" half of the fix: the ask itself cannot free a handle that
    /// does not exist yet, so without it the warden would be told the bytes
    /// were back and the load would re-fill the row microseconds later.
    private var loadAbandonRequested = false

    /// The runtime, if one is resident. `Any?` because this type is compiled
    /// in builds that do not link the llama runtime at all — the cast to
    /// `LLM` belongs at the call site, inside `#if canImport(LLM)`.
    var currentHandle: Any? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    var heldModelURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return handleModelURL
    }

    var isHoldingHandle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    func store(_ handle: Any, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.handle = handle
        self.handleModelURL = url
    }

    /// Drops the reference without telling the ledger. Called by the tier's
    /// own idle/session release (which reports `didUnload` itself) and as the
    /// warden's registered force fallback (where the ledger has already
    /// marked the row non-resident and a callback would be a re-entry).
    func drop() {
        lock.lock()
        defer { lock.unlock() }
        handle = nil
        handleModelURL = nil
        // [PRESSURE-SAFE LOAD] A drop that lands while a load is in flight is
        // the warden taking the position, whether it asked first or came
        // through the registered closure directly. There is no handle here to
        // give back, so the only way the drop can mean anything is if the load
        // stands down — which is what the flag is for.
        if loadDepth > 0 { loadAbandonRequested = true }
    }

    /// Whether a load is in flight — no handle exists yet, but one is coming.
    ///
    /// Distinct from `isHoldingHandle`, which is `false` for the whole of this
    /// window: the difference between them is the difference between "there
    /// are no bytes here" and "there are no bytes here *yet*".
    var isLoading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadDepth > 0
    }

    /// Opens the in-flight window. Any abandon request left over from an
    /// earlier load is cleared here, so a stale one cannot stand a later load
    /// down for a warden that is no longer asking.
    func beginLoad() {
        lock.lock()
        defer { lock.unlock() }
        loadDepth += 1
        loadAbandonRequested = false
    }

    func endLoad() {
        lock.lock()
        defer { lock.unlock() }
        loadDepth = max(0, loadDepth - 1)
    }

    /// The abandon signal, taken. `true` exactly once per ask.
    ///
    /// Consumed rather than merely read because the load path asks at more
    /// than one checkpoint: a flag that stayed set would stand down the *next*
    /// load too, which is a warden's ask outliving the load it was about.
    func consumeLoadAbandonRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard loadAbandonRequested else { return false }
        loadAbandonRequested = false
        return true
    }

    func beginDecode() {
        lock.lock()
        defer { lock.unlock() }
        decodeDepth += 1
    }

    func endDecode() {
        lock.lock()
        defer { lock.unlock() }
        decodeDepth = max(0, decodeDepth - 1)
    }

    // MARK: ModelResident

    /// The warden's ask. Synchronous by contract, and called outside the
    /// manager's lock — so this takes only its own.
    ///
    /// A decode in flight is an honest refusal: the bytes would come back, but
    /// the *next* use pays a full reload, and the warden is the one that gets
    /// to decide whether that trade is worth it (`PreemptionOutcome.forced`).
    /// An idle handle is simply handed over.
    ///
    /// [PRESSURE-SAFE LOAD] (2026-09-19) A **load in flight** is a third
    /// answer, and it is the one this whole path was missing. It used to be
    /// reported as `.notHolding` — "nothing was there to drop" — which is
    /// literally true (the handle does not exist until `LLM.init` returns) and
    /// completely misleading: the warden was told the bytes were back, and the
    /// load it could not see went on to fill the row it had just cleared. The
    /// owner's phone died in exactly that gap. `.cannotReleaseNow` says what is
    /// actually true, and it is the token the released-ask's refusal grace is
    /// already built for. The flag it sets is what makes the load *stand down*
    /// rather than merely be described as un-droppable.
    func releaseForWarden() -> UnloadAck {
        lock.lock()
        defer { lock.unlock() }
        if loadDepth > 0 {
            loadAbandonRequested = true
            return .refused(.cannotReleaseNow)
        }
        guard handle != nil else { return .notHolding }
        guard decodeDepth == 0 else { return .refused(.inUse) }
        handle = nil
        handleModelURL = nil
        let notify = onOffloadedByWarden
        lock.unlock()
        // Outside the lock, and after the bytes are already given back: the
        // handler is a `Task` hop into the tier (see
        // `setWardenOffloadHandler`), so nothing here can wait on it.
        notify?()
        return .released
    }

    /// The warden's **registered release path** — what runs when the ask was
    /// refused and `ModelReleaseContract.actorDeferredFree` allowed the
    /// refusal to be overruled, and what a `.budget` eviction of this slot
    /// runs.
    ///
    /// `drop()` plus the notice, because the elder is owed the sentence: the
    /// tier did not ask for this, and from the camera's side the translation
    /// simply stopped. The handle reference goes first (the notice must not
    /// be able to outlive the drop it describes), and the handler is invoked
    /// with no lock held.
    func dropForWarden() {
        drop()
        lock.lock()
        let notify = onOffloadedByWarden
        lock.unlock()
        notify?()
    }

    /// Called by the generator when the warden takes the handle on a path the
    /// tier did not ask for. Invoked outside this box's lock, synchronously,
    /// on the warden's thread.
    private var onOffloadedByWarden: (@Sendable () -> Void)?

    /// Wired once, before the first load; read under the lock at the ask.
    func setOffloadHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        onOffloadedByWarden = handler
    }
}

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
///    prevent. The tier's `.translateBrain` row means the ledger sees the same
///    release (`dropHandle` → `didUnload`); this timer is what makes it
///    happen without a turn boundary, and it is unchanged by Step 2 — the
///    slot is preemptible *in addition to* the idle rule, never instead of it.
///  - **It interrupts on the deadline.** `LLM.stop()` breaks the decode loop,
///    so a generation that outlives `timeout` costs the deadline and not the
///    session, and the next batch is not queued behind a runaway decode.
actor LlamaBrainTextGenerator: BrainTextGenerating {

    private let config: LiveTranslateConfig
    /// The handle, and the ledger's view of it. Not an actor-stored property
    /// any more — see `TranslateBrainHandleSlot`.
    ///
    /// Internal rather than private for exactly one reader:
    /// `LocalBrainTranslationTierTests` drives the warden's ask against the
    /// in-flight window (`releaseForWarden` while `isLoading`). The ledger
    /// cannot produce that state itself — a slot with a load in flight holds
    /// nothing and is *not* resident, so no eviction path can reach it and the
    /// sweep that would ask skips it — and the ask is nevertheless the fact
    /// the fix is about.
    ///
    /// `nonisolated` because the warden does not go through this actor to
    /// reach it (`setWardenOffloadHandler` is `nonisolated` for the same
    /// reason: a reservation path may not have to await a decode). The box
    /// carries its own lock and is `@unchecked Sendable`, and the load window
    /// it describes is exactly the interval in which an `await` would be too
    /// late. It is the same object this actor would have asked; tests drive
    /// the real box without a model on disk or a llama runtime.
    nonisolated let slot = TranslateBrainHandleSlot()
    private var lastUse: Date?
    /// The armed idle release, if one is. Cancelled and re-armed by every use,
    /// so the handle's lifetime is measured from the last batch and not from
    /// the first.
    private var idleRelease: Task<Void, Never>?

    /// [MODEL-WARDEN] Step 1 — the warden this generator reserves its handle
    /// against. Before this, the tier's load was the clearest instance of
    /// finding H1: the 4B appeared in the ledger only at `didLoad`, i.e.
    /// after a 2.5 GB page-in had already landed, so a voice-turn brain load
    /// and this one were both admitted against the same budget.
    private let lifecycle: ModelLifecycleManager

    init(config: LiveTranslateConfig = .default,
         lifecycle: ModelLifecycleManager = .shared) {
        self.config = config
        self.lifecycle = lifecycle
    }

    func generate(prompt: String,
                  jsonSchema: String,
                  modelURL: URL,
                  timeout: TimeInterval) async throws -> String {
        #if canImport(LLM)
        defer {
            lastUse = Date()
            scheduleIdleRelease()
        }
        return try await run(modelURL: modelURL,
                             prompt: prompt,
                             jsonSchema: jsonSchema,
                             timeout: timeout)
        #else
        _ = (prompt, jsonSchema, modelURL, timeout)
        throw BrainGenerationFailure.loadFailed
        #endif
    }

    func isHoldingHandle() async -> Bool { slot.isHoldingHandle }

    /// `nonisolated` so it can satisfy `BrainTextGenerating`'s synchronous
    /// requirement: the warden asks from its own reservation path and must
    /// not have to await this actor (which may be mid-decode) to install a
    /// handler. The box guards its own copy of the reference.
    nonisolated func setWardenOffloadHandler(_ handler: (@Sendable () -> Void)?) {
        slot.setOffloadHandler(handler)
    }

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

    /// Drops the handle and tells the ledger its bytes are back.
    ///
    /// `didUnload` is owner-scoped on the slot's `TranslateBrainHandleSlot`,
    /// which is the object the registration was made with — so a
    /// re-registration by anyone else cannot make this call clear a
    /// residency it does not own (the same rule `.speechToText`'s two
    /// engines already live under).
    ///
    /// A handle the warden already took is not dropped twice: `didUnload` is
    /// a no-op on a slot that is not resident, and `slot.drop()` is a no-op
    /// with nothing in it.
    private func dropHandle() {
        slot.drop()
        lifecycle.didUnload(.translateBrain, owner: slot)
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
    /// **[PRESSURE-SAFE LOAD] (2026-09-19) — the container that decided whether
    /// this load may start, and how it stands down once it has.**
    ///
    /// The owner's phone died in this method. The sequence, from the forensic
    /// capture: the device was already starved, the tier's headroom gate passed
    /// anyway (it reads the app's own ceiling, not the system's free pages), a
    /// 1.03 GB Metal-offloaded load began, memory-pressure events fired, and
    /// the process was gone about five seconds later. Three properties of this
    /// method are what made that unrecoverable, and each one has a checkpoint
    /// below:
    ///
    ///  1. **The load is synchronous.** `LLM.init` cannot be interrupted once
    ///     it starts, and moving it off-thread is a change to the runtime's
    ///     contract rather than to this file. So the checks go *around* it:
    ///     one before the warden is asked, one after the reserve returns, and
    ///     one after the construction returns. The last is the one that closes
    ///     the hole the capture shows — the load cannot be stopped, but it can
    ///     be **declined the slot** it was going to fill.
    ///
    ///  2. **The reserve can take seconds.** It evicts before it admits, and
    ///     the evictions are real unloads (`llama_model_free` is not instant).
    ///     A `.critical` that lands inside that window is the device saying
    ///     "not now" *after* the warden said yes, and only a second check can
    ///     hear it.
    ///
    ///  3. **The slot had no way to say "a load is coming".** It held nothing,
    ///     so `releaseForWarden` answered `.notHolding` and the warden
    ///     believed the bytes were back. `slot.beginLoad()` is the fix: for
    ///     the whole of this method the slot answers `.refused(.cannotReleaseNow)`
    ///     and records the ask, which is what turns "silently acked" into
    ///     "abandoned".
    ///
    /// The window is opened *before* the registration and the reserve — not
    /// merely around the construction — because that is the interval a warden
    /// could previously mis-read. It is closed by a `defer`, so no exit leaks
    /// it.
    private func loadHandle(modelURL: URL) throws -> LLM {
        if let existing = slot.currentHandle as? LLM,
           slot.heldModelURL == modelURL { return existing }

        let modelID = Self.modelID(forURL: modelURL)

        slot.beginLoad()
        defer { slot.endLoad() }

        // Checkpoint 1 — before the warden is asked, and before anything it
        // might evict. The tier already asked this question a moment ago
        // (`deferralForLoad`); it is asked again because the answer is a fact
        // about the device, and a fact about a starving device goes stale in
        // milliseconds.
        if let abandoned = loadAbandonReason() {
            throw BrainGenerationFailure.loadAbandoned(abandoned)
        }

        // [LOAD-SERIALIZATION] (2026-09-19) Stand any in-flight STT load
        // down before this one starts allocating. The owner's 15:39 capture
        // shows the two colliding: the STT warm finished its 85-second load
        // in the same second this load was admitted, and two heavy page-ins
        // at once are the spike the device died from. The warm is
        // anticipatory and re-loads on demand; this load answers the
        // elder's live request. The recognizer detects the abandonment via
        // `isReservationHeld` when its load completes and stands down.
        lifecycle.abandonInFlight(slot: .speechToText, reason: .preempted)

        // [MODEL-WARDEN] Step 2 — declare the position before asking for the
        // bytes. `resident:` is what makes this handle *preemptible* rather
        // than merely evictable: the warden can ask the slot to stand down
        // (`releaseForWarden`) and the contract on the row — a brain's
        // `actorDeferredFree` — is what decides whether a refusal may be
        // overruled. The closure is the force fallback, and it is the same
        // body as the slot's own release: drop the reference, keep the
        // ledger's books straight later via `dropHandle`.
        lifecycle.register(slot: .translateBrain,
                           modelID: modelID,
                           owner: slot,
                           evictable: true,
                           priority: ReservationPurpose.liveTranslate.priority,
                           resident: slot) { [weak slot] in
            // `dropForWarden`, not `drop`: this closure is the warden's
            // forced half of the ask (and a budget eviction of this slot),
            // and both are moments the elder is owed the sentence for. The
            // tier's own releases go through `dropHandle`, which says
            // nothing — nobody needs telling about a release they made.
            slot?.dropForWarden()
        }

        // [MODEL-WARDEN] Step 1 — ask the warden BEFORE allocating.
        //
        // `replacesSlotContents: true`: this is the tier's OWN position now
        // (`ModelSlot.translateBrain`, § the file header). One handle per
        // pipeline position is the rule this expresses — the load is the
        // same position being refilled, so counting the slot's own prior
        // residency against it would double-book one position and evict an
        // innocent bystander.
        //
        // The bytes are still additive to everyone ELSE's, which is what
        // keeps a second 4B from slipping past a budget the voice brain
        // already spent — and `.translateBrain` does not
        // `admitSoloOverBudget`, so an over-budget ask is refused here
        // exactly as it was when this reserved as a peer on `.brain`.
        //
        // The refusal is thrown, not awaited: this generator has no queue to
        // wait in, and the tier's answer to "cannot load now" is already
        // the one it gives for a failed load — hand the strings to the next
        // tier. The load still runs inside the caller's deadline (see
        // `run`), so a granted reservation that takes too long is bounded
        // exactly as before.
        // [WARDEN-TESTING-BYPASS] (2026-09-19) The owner asked to test the
        // local model on device without the warden's arithmetic in the way:
        // while `wardenBypassForTesting` is on, the load skips the
        // reserve/admit gate entirely — no permit, no eviction, no denial.
        // Residency is still recorded (didLoad below), so the ledger stays
        // honest about what is in memory. Testing-only.
        //
        // [PRESSURE-SAFE LOAD] **The bypass skips the arithmetic. It does not
        // skip the device.** Every checkpoint in this method runs whatever
        // this flag says, because the arithmetic the flag turns off is the
        // part that is *wrong* on a starved phone — `os_proc_available_memory`
        // reads the app's own account, and a device the kernel is already
        // killing daemons on can still look roomy by it. The kernel's pressure
        // level is not arithmetic and is not optional: it is the reading that
        // would have refused the load the owner's phone died starting, and a
        // testing switch that could re-open that path would be a switch that
        // can kill the phone again.
        //
        // **The flip was one line, and the device pass made it**
        // (2026-09-19 directive: "the bypass stays until proven on device,
        // then flips off"; flipped 2026-09-20 in `LiveTranslateConfig`).
        // The gated path below is the one the round-2b work built, and the
        // four behaviours it rests on are the ones to watch for on the
        // device —
        //   1. the load is ADMITTED after evicting a background/warm
        //      resident, not refused (`over_budget_alone` in the console is
        //      the failure this task exists to remove);
        //   2. a voice turn takes the handle back (`brain_translation_preempted`
        //      on component `livetranslate`);
        //   3. the elder sees "hold on a sec" copy while a load runs;
        //   4. the elder sees "switched for your voice request" when it is
        //      taken, and translation resumes on the next batch.
        let reservation: ModelReservation?
        if config.wardenBypassForTesting {
            reservation = nil
        } else {
            switch lifecycle.reserve(ModelLoadRequest(
                slot: .translateBrain,
                modelID: modelID,
                owner: slot,
                purpose: .liveTranslate,
                replacesSlotContents: true)) {
            case .success(let granted):
                reservation = granted
            case .failure(let denial):
                throw BrainGenerationFailure.loadDenied(denial)
            }
        }
        // Every exit that is not a committed load hands the permit back —
        // a throw from the construction, and (though this method has no
        // suspension point today) anything the runtime adds later. The reason
        // is the abandon's own where there was one, because a permit handed
        // back under `memory_pressure` is a different fact in the ledger than
        // one handed back because the artifact would not construct.
        var committed = false
        var abandonReason: ReservationAbandonReason = .loadFailed
        defer {
            if let reservation, !committed {
                lifecycle.abandon(reservation, reason: abandonReason)
            }
        }

        // Checkpoint 2 — the one the reserve makes necessary. Between the ask
        // above and this line the warden may have evicted a voice brain, a
        // recognizer, or the encoder, and each of those is a real unload that
        // takes time. A `.critical` arriving anywhere in that interval is the
        // device withdrawing the permission the warden just granted, and the
        // ledger has already abandoned the reservation on its own account (see
        // `handleCriticalMemoryPressure`) — the point of asking here is that
        // this path must not go on to allocate anyway.
        if let abandoned = loadAbandonReason() {
            abandonReason = Self.abandonReason(for: abandoned)
            throw BrainGenerationFailure.loadAbandoned(abandoned)
        }

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

        // Checkpoint 3 — the only one that can speak for the seconds spent
        // *inside* `LLM.init`. The construction is synchronous and cannot be
        // interrupted, so a pressure event or a warden's ask that landed while
        // it ran has, until this line, had no way to stop it from filling the
        // slot. Here the handle is simply not stored: `created` is released on
        // the way out of this scope, the ledger is told the load was abandoned
        // rather than committed, and the row the warden cleared stays cleared.
        //
        // The bytes were briefly resident — there is no way to avoid that with
        // a synchronous load — but the spike is not *kept*, which is the
        // difference between a device that thrashes once and one that is
        // killed for holding on.
        if let abandoned = loadAbandonReason() {
            abandonReason = Self.abandonReason(for: abandoned)
            throw BrainGenerationFailure.loadAbandoned(abandoned)
        }

        slot.store(created, url: modelURL)
        // The bytes are in memory: the transient term retires into the
        // ledger's resident total, and the row is marked resident under the
        // same owner the reservation was made with — the handle box, not the
        // generator, so a preemption that lands between here and the next
        // `noteUse` still finds the row it asked about.
        lifecycle.didLoad(.translateBrain, owner: slot)
        // Committed even when the caller's stage deadline has already
        // expired — the 2.5 GB IS resident, and a ledger that declined to
        // count it would be exactly the undercount this migration exists to
        // remove. Under the testing bypass there is no permit to commit;
        // didLoad above already recorded the residency.
        if let reservation {
            lifecycle.commit(reservation)
        }
        committed = true
        return created
    }

    /// [PRESSURE-SAFE LOAD] The two signals a load must stand down for, taken.
    ///
    /// **One question, asked at each checkpoint.** They are the same two facts
    /// every time — the kernel's state, and whether a warden has asked for
    /// this position since the load was declared in flight — and each is read
    /// fresh, because the answer is a fact about a device that changes while
    /// the load is being prepared.
    ///
    /// The warden's ask is checked **first** and consumed: it is the more
    /// specific fact (this position, this load, this instant), and if it and a
    /// pressure reading are both outstanding, the ask is what explains why the
    /// slot is empty.
    ///
    /// The pressure half is `LocalBrainTranslationTier.pressureDeferral`, not
    /// a second comparison against the reading — the load path and the tier's
    /// pre-attempt gate must not be able to disagree about what the kernel
    /// said, or a load refused at the door would be taken again through the
    /// window of a copy that forgot one of the three levels.
    private func loadAbandonReason() -> LocalBrainDeferral? {
        if slot.consumeLoadAbandonRequest() { return .releaseRequestedDuringLoad }
        return LocalBrainTranslationTier.pressureDeferral(
            lifecycle.memoryPressureReading(),
            windowSeconds: config.brainTranslationCriticalPressureWindowSeconds)
    }

    /// The ledger's own token for a permit an abandon consumed.
    ///
    /// The deferral vocabulary is the tier's; this is the ledger's, and the
    /// two are not the same list — so the mapping is explicit and exhaustive
    /// rather than a rawValue bridge that would silently pair two enums by
    /// spelling. The first two cases are the pre-attempt gate's and cannot
    /// reach the load path (the gate runs before it); they are mapped rather
    /// than trapped so that adding one is a compile error here and not a
    /// runtime surprise on a device.
    private static func abandonReason(for deferral: LocalBrainDeferral) -> ReservationAbandonReason {
        switch deferral {
        case .memoryPressure, .recentCriticalPressure: return .memoryPressure
        case .releaseRequestedDuringLoad: return .preempted
        case .residentBrain, .insufficientHeadroom: return .loadFailed
        }
    }

    /// The catalog id behind a resolved model URL.
    ///
    /// The reservation's arithmetic is only as good as the artifact it is
    /// told about, and this actor is handed a URL and nothing else
    /// (`BrainTextGenerating.generate` carries no id, and widening that
    /// protocol would ripple into every double — including the scripted one
    /// the tier's tests drive). Resolution from the catalog by filename is
    /// the same mapping `ModelStore.path(for:)` inverted, and a URL that
    /// names no catalog artifact honestly resolves to `nil` (the ledger's
    /// own conservative fallback) rather than to a guess.
    private static func modelID(forURL url: URL) -> ModelID? {
        ModelCatalog.all.first { $0.filename == url.lastPathComponent }?.id
    }

    /// One attempt, raced against its deadline — **the handle load included**.
    ///
    /// The budget guard runs first and fails fast: prompt and output share the
    /// 1,024-token context, so a prompt that leaves less than the output
    /// headroom does not produce a shorter answer, it produces a truncated
    /// one — and under temp 0 with a fixed seed that truncation is
    /// deterministic, not transient.
    ///
    /// **The deadline used to start after the load** (2026-09-17, the device
    /// report). `brainTranslationTimeoutSeconds` bounded the decode and
    /// nothing else, while `loadHandle` — a synchronous, uninterruptible
    /// `llama_model_load_from_file` over a 2.5 GB GGUF — ran before the clock
    /// began. With `brainTranslationIdleUnloadSeconds` at 5 s almost every
    /// batch pays that load, so the bound the device actually hit was the
    /// pipeline's stage deadline a few seconds later, not this one; the batch
    /// was then abandoned mid-decode with nobody waiting for it. The config's
    /// own contract says the opposite ("a batch arriving after a longer gap
    /// pays one model load inside its own timeout — which is what the
    /// generous `brainTranslationTimeoutSeconds` is sized for"), and this is
    /// the code that makes that sentence true: an overrunning load now fails
    /// at the tier, at this deadline, with the decode never started.
    ///
    /// **Every exit that did not get an answer stops the decode.** The
    /// interruption used to live in the deadline task alone, so it ran only
    /// when the sleep won the race. A caller's cancellation makes `Task.sleep`
    /// throw instead, so `stop()` was never reached and the decode ran on: it
    /// held the `LLMCore` actor for its full length, every later batch queued
    /// behind it and blew its own deadline in turn, and each of those was
    /// reported as `inference_failed` — the device's repeated-failure tail,
    /// one cause and N events.
    ///
    /// The stop has to be issued from the group body's `defer`, and that is
    /// measured, not assumed: on the deadline the body unwinds 0.20 s in (the
    /// moment the sleep throws), and on the caller's cancellation it unwinds
    /// at the cancellation itself, while the `catch` *outside* the group does
    /// not run until 2.00 s — the scope exit first drains the children, and
    /// the decode child is a synchronous, non-cancellable loop inside the
    /// runtime that `group.cancelAll()` cannot stop. A stop issued after the
    /// group would therefore be a stop issued after the decode it was meant to
    /// bound. `defer` cannot await, so the call hops to this (idle) actor in a
    /// detached task; if the decode happened to finish on its own first, the
    /// hop can land after the next batch has begun its generation — `LLMCore`
    /// scopes an interruption to whichever generation is current when it is
    /// issued — which costs that batch an early stop it reports as
    /// unavailable and hands to the next tier. Never a wrong answer.
    private func run(modelURL: URL,
                     prompt: String,
                     jsonSchema: String,
                     timeout: TimeInterval) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [self] in
                    let llm = try await loadHandle(modelURL: modelURL)
                    // A deadline that fired while the (synchronous, and so
                    // uninterruptible) load was running must not be followed
                    // by a decode nobody is waiting for: the bytes would be
                    // spent on an answer the caller has already given up on.
                    try Task.checkCancellation()

                    let promptTokens = await llm.encode(prompt).count
                    guard promptTokens <= LocalIntentInterpreter.contextTokenBudget
                            - LocalIntentInterpreter.outputHeadroomTokens else {
                        throw BrainGenerationFailure.promptOverflow
                    }
                    // [MODEL-WARDEN] Step 2 — the lease is held, not merely
                    // taken. While this bracket is open the box answers a
                    // warden's `releaseForWarden` with `.refused(.inUse)`, so
                    // a preemption cannot free a runtime mid-decode; the
                    // decode's own `stopDecode` is what ends the window, and
                    // the contract's deferred free is what makes even a
                    // forced drop of the box's reference safe (the local
                    // `llm` keeps the runtime alive until this returns).
                    slot.beginDecode()
                    defer { slot.endDecode() }
                    return try await llm.core.generateWithConstraints(from: prompt,
                                                                     jsonSchema: jsonSchema)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw BrainGenerationFailure.timedOut
                }
                // The one point every exit passes through — the decode
                // returned, the deadline threw, the caller cancelled — and the
                // last one that is reached before the group drains, which is
                // the whole reason the stop lives here and not after the group.
                defer {
                    group.cancelAll()
                    Task { await self.stopDecode() }
                }
                guard let output = try await group.next() else {
                    throw BrainGenerationFailure.generationFailed
                }
                return output
            }
        } catch is CancellationError {
            // The caller stopped waiting. See
            // `BrainGenerationFailure.cancelled` for why this is not `timedOut`.
            throw BrainGenerationFailure.cancelled
        }
    }

    /// Stops the decode in flight on the resident handle, if there is one.
    /// Safe with nothing in flight, and with no handle at all.
    ///
    /// Reads the handle through the box rather than a stored property: the
    /// warden can drop the box's reference out from under this actor
    /// (`TranslateBrainHandleSlot.releaseForWarden`, or its force fallback),
    /// so the only safe way to ask "is there a live runtime to interrupt?" is
    /// the box's own locked read.
    private func stopDecode() {
        (slot.currentHandle as? LLM)?.stop()
    }

    #endif
}
