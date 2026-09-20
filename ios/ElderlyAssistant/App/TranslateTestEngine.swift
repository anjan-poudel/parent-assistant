import Foundation

// MARK: - [TRANSLATE-TEST] The dev screen's engine seam (2026-09-21)
//
// The hidden Settings translate-test screen answers one question the
// household can otherwise only infer: "what does each engine actually say
// for the text I type, and what did it cost me in time?" The two engines
// are the SHIPPED ones — tier 1 (`LocalBrainTranslationTier`, the
// installed on-device brain) and tier 2 (`CloudTranslationTier`, the
// consent-gated Gemini path) — consumed through the seam below and never
// reimplemented. Nothing in this file changes what production does; it
// reads the same actors the camera session reads.
//
// Why a seam at all, when both tiers are concrete: the screen's view model
// has to be testable with no model on disk, no network and no consent
// record (the same reason `LocalBrainTranslating` exists for the pipeline,
// and `LiveTranslateSessionTestHarness` for the session). The protocol is
// two methods wide and exists only for THIS screen's tests — it is not a
// second tier abstraction and must not grow into one.
//
// The cloud path's consent gate is not consulted here on purpose. The gate
// is enforced INSIDE `CloudTranslationTier.resolve` (`gate.authorize()`,
// re-read per attempt, with the `Grant` proof type the transport requires),
// so a caller that goes through the tier cannot skip it. This file adds no
// bypass because it adds no path: the only way it reaches Gemini is the
// tier that already asks.

/// Which engine the screen asks. Raw value drives both the L10n key
/// (`settings.translateTest.engine.<rawValue>`) and the segmented picker's
/// identity, so a third engine cannot be added without a visible title.
enum TranslateTestEngine: String, CaseIterable, Identifiable {
    /// Tier 1 — the on-device brain. Local, consent-free, never sent.
    case local
    /// Tier 2 — the consent-gated cloud tier.
    case gemini

    var id: String { rawValue }

    var titleKey: String { "settings.translateTest.engine.\(rawValue)" }
}

/// What an engine would need before it can answer, in the screen's terms.
///
/// Deliberately three cases and no associated payload: the screen resolves
/// WHICH download to offer from `ModelCatalog.availableTranslationEntries`
/// at the point it draws the button, so this type stays comparable in a
/// test with no catalog fixture.
enum TranslateEngineReadiness: Equatable {
    /// The engine can run right now.
    case ready
    /// Tier 1 has no installed translation brain. The screen offers the
    /// catalog's download instead of a spinner that would never resolve.
    case modelMissing
    /// Tier 2 has no provider key on this device, so nothing could be sent
    /// even with consent.
    case providerKeyMissing
    /// The household's cloud master switch (`geminiCloudEnabled`) is off.
    ///
    /// A separate case from `providerKeyMissing` because it is a different
    /// fact and a different fix: the key may be present and consent may be
    /// on record, and the cloud is still shut because someone decided so.
    /// Folding the two together would tell the household to enter a key it
    /// already has.
    case cloudDisabled
}

/// One engine's answer for one string: the result — which already names the
/// tier that produced it — plus how long the caller waited.
///
/// The latency is wall-clock (measured around the `await`), not the tier's
/// own internal duration. That is the honest number for a comparison
/// screen: it is what the person typing actually waited, including the
/// queueing the tier's internal clock does not see.
struct TranslateProbeOutcome: Equatable {
    let result: TranslationResult
    let latencyMs: Int

    /// Tier 1 only: why the brain declined to attempt the batch, when it
    /// did. Carried as evidence rather than a branch — the outcome already
    /// says "no translation", and this says whether the model was even
    /// asked. `nil` for the cloud path and for a local attempt that ran.
    var localDeferral: LocalBrainDeferral? = nil
}

extension LocalBrainDeferral {
    /// The deferral's NAME, without its payload, for the screen's one-line
    /// cell.
    ///
    /// The associated values are real evidence (byte counts, pressure
    /// levels), but a card one line wide cannot carry them, and the case
    /// name is what tells a reader which of the warden's decisions they are
    /// looking at. It lives here rather than in the view so a suite can pin
    /// that every case has a distinct name — a new deferral added to the
    /// tier would otherwise render as an empty cell instead of failing.
    var displayToken: String {
        switch self {
        case .residentBrain: return "residentBrain"
        case .insufficientHeadroom: return "insufficientHeadroom"
        case .memoryPressure: return "memoryPressure"
        case .recentCriticalPressure: return "recentCriticalPressure"
        case .releaseRequestedDuringLoad: return "releaseRequestedDuringLoad"
        }
    }
}

/// One attempt at one string. Two methods, because the screen has exactly
/// two questions: can you run, and what do you say.
///
/// NOT `Sendable`, deliberately. These engines are built and called on the
/// main actor for one view, and saying otherwise would force every captured
/// reference (`ModelStore`, `LiveTranslateSettings`, the config) into a
/// `@Sendable` box that claimed a thread-safety none of them has. The
/// isolation that matters here is the tier's own, and both tiers are actors
/// — they keep it whether or not this protocol asserts anything.
protocol TranslateProbeEngine {
    /// The engine's answer for `text`. Never throws: "could not translate"
    /// is a degraded `TranslationResult`, which is the vocabulary the app
    /// already renders honestly.
    func probe(_ text: String) async -> TranslateProbeOutcome

    /// Whether the engine can run at all, asked before the button is
    /// offered so the screen can show a download rather than a wait.
    func readiness() async -> TranslateEngineReadiness
}

// MARK: - Tier 1 (on-device brain)

/// The on-device path, over the shipped tier 1.
///
/// The install question arrives as a closure rather than a `ModelStore` so
/// this adapter owns no store and a test can answer it without one — the
/// same shape the tier itself uses (`modelStore: ModelStore?`, "a tier
/// without one reports itself unavailable, honestly").
struct LocalBrainProbeEngine: TranslateProbeEngine {
    let brain: any LocalBrainTranslating
    /// "Is a translation brain installed and complete on this device" —
    /// the `ModelStore.isAvailable` question over the tier's own
    /// `brainTranslationModelIDs`.
    let isModelInstalled: () -> Bool
    /// Injectable clock, the seam convention the shipped tiers use
    /// (`LiveTranslateConsentGate.now`, `CloudTranslationTier.sleep`) so a
    /// suite can pin a latency instead of racing one.
    var now: () -> Date = { Date() }

    func readiness() async -> TranslateEngineReadiness {
        isModelInstalled() ? .ready : .modelMissing
    }

    func probe(_ text: String) async -> TranslateProbeOutcome {
        let started = now()
        let outcome = await brain.translate([text])
        let latencyMs = Int(now().timeIntervalSince(started) * 1000)

        // A string the attempt did not answer is ABSENT from `translations`
        // (the protocol's contract: "never an empty string, never the source
        // itself"), so presence is the whole test. What it means for the
        // screen is "tier 1 did not translate this" — `noTierResolved`,
        // which is the honest token for a failure no more specific cause
        // describes. The deferral, when there was one, travels beside it.
        let result: TranslationResult
        if let translation = outcome.translations[text] {
            result = .resolved(originalText: text,
                               translation: translation,
                               tier: .onDeviceBrain)
        } else {
            result = .degraded(originalText: text, reason: .noTierResolved)
        }
        return TranslateProbeOutcome(result: result,
                                     latencyMs: latencyMs,
                                     localDeferral: outcome.deferral)
    }
}

// MARK: - Tier 2 (cloud)

/// The cloud path, over the shipped tier 2.
///
/// Consent, the cost budget, sanitisation and the deadline all live inside
/// `CloudTranslationTier.resolve`; this adapter hands it one item and reads
/// back the `TranslationResult` the tier already knows how to produce (its
/// `BatchResult.result(for:)` maps a resolution to `resolved`, a failure to
/// `degraded` with the taxonomy's reason, and an unanswered item to
/// `pending`).
struct CloudProbeEngine: TranslateProbeEngine {
    let tier: CloudTranslationTier
    let targetLanguage: AppLanguage
    /// "Is a Gemini key configured" — the `GeminiConfigStore` question.
    /// Without one the tier would spend a request to learn what this
    /// already knows, and the screen would show a failure instead of the
    /// setup the household actually needs.
    let isProviderConfigured: () -> Bool
    /// "Is the household's cloud switch on" — `LiveTranslateSettings
    /// .geminiCloudEnabled`.
    ///
    /// THIS IS A GATE, not a display hint. The switch is enforced by
    /// `LiveTranslationPipeline`, which hands it to the pipeline and not to
    /// the tier — so a caller that goes straight to `CloudTranslationTier`
    /// (as this screen does) is ABOVE the only thing that reads it, and
    /// would put text on the wire with the household's cloud shut. The
    /// consent gate is still the tier's own (it re-reads it per attempt),
    /// but consent and this switch are two different doors, and this screen
    /// must knock on both.
    let isCloudEnabled: () -> Bool
    var now: () -> Date = { Date() }

    /// One item's id. A fixed key rather than a UUID: the tier's in-flight
    /// registry is keyed by it and the screen asks about exactly one string,
    /// so a stable key is what makes a re-run reuse the tier's own
    /// bookkeeping instead of minting a new claim per tap.
    static let itemID = "translate-test"

    func readiness() async -> TranslateEngineReadiness {
        // The switch is asked FIRST: with the cloud shut, "no key" is not
        // the fact that matters, and the household would go and add one
        // for a door that is still locked.
        guard isCloudEnabled() else { return .cloudDisabled }
        return isProviderConfigured() ? .ready : .providerKeyMissing
    }

    func probe(_ text: String) async -> TranslateProbeOutcome {
        // Refused here as well as in `readiness`, because a race is real:
        // the switch can be turned off between the screen's check and the
        // tap. The refusal is the taxonomy's own `.cloudDisabled`, so the
        // card shows the same token the shipped pipeline would log.
        guard isCloudEnabled() else {
            return TranslateProbeOutcome(
                result: .degraded(originalText: text, reason: .cloudDisabled),
                latencyMs: 0)
        }
        let item = CloudTranslationTier.Item(id: Self.itemID,
                                             text: text,
                                             // Never invented: detection
                                             // returned nothing here, so the
                                             // field is omitted from the
                                             // request exactly as the
                                             // pipeline omits it.
                                             detectedSourceLanguage: nil)
        let started = now()
        let batch = await tier.resolve(items: [item], targetLanguage: targetLanguage)
        let latencyMs = Int(now().timeIntervalSince(started) * 1000)
        return TranslateProbeOutcome(result: batch.result(for: item), latencyMs: latencyMs)
    }
}

// MARK: - Production wiring

/// The screen's dependencies: the coordinator's OWN instances.
///
/// Sharing the process-wide cache, consent gate, cost governor and
/// observability bus is the point rather than a shortcut — the screen
/// exists to show what the shipped path does, and a second gate reading the
/// same record would be a second thing to keep honest. It also means the
/// screen cannot spend budget, record consent or write cache entries that
/// the rest of the app does not see.
struct TranslateTestDependencies {
    let cache: LabelTranslationCache
    let consentGate: LiveTranslateConsentGate
    let costGovernor: GeminiCostGovernor
    let client: GeminiClient
    let observabilityBus: ObservabilityBus
    /// The coordinator's own store — `nil` only in a build without one. The
    /// tier takes it as a parameter and reports `.runtimeMissing` without
    /// it, so this is passed through rather than emulated: a store that is
    /// present here is the same store `ModelStore.isAvailable` was asked.
    let modelStore: ModelStore?
    /// "Is a Gemini key configured".
    let isProviderConfigured: () -> Bool
    /// "Is the household's cloud master switch on". Read live from the same
    /// `LiveTranslateSettings` the Settings leaf writes, so flipping it
    /// there is reflected on this screen's next check rather than at the
    /// next launch.
    let isCloudEnabled: () -> Bool
    /// Begins one one-shot mic capture and hands back the transcript. This
    /// is `AppCoordinator.startSearchPhraseCapture` — the SHIPPED
    /// single-utterance capture the Phone and Directions leaves already use
    /// (`SearchPhraseCapture`), not a second recogniser built for this
    /// screen. It is the right reuse for two reasons the screen could not
    /// fix on its own: every shipped recogniser is PUSH mode (it waits for
    /// buffers from an existing tap), and the shared engine has exactly one
    /// tap slot, so a screen that captured audio itself would fight the
    /// always-on pipeline. The coordinator's method owns that arbitration —
    /// it suspends the pipeline, runs the only tap, and restarts the
    /// pipeline when the capture settles.
    /// The inner `@escaping` is load-bearing, not decoration: it is the
    /// closure's REAL lifetime (the coordinator's completion fires after the
    /// tap ends, from a different turn), and without it written here the
    /// forwarding closure in `makeTranslateTestDependencies` has a
    /// non-escaping parameter and cannot hand it to
    /// `AppCoordinator.startSearchPhraseCapture`, which requires `@escaping`.
    /// Spelling it in the type is what makes the forward legal.
    let startCapture: (@escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) -> Void
    /// Ends an in-flight capture early. `AppCoordinator.cancelSearchPhraseCapture`.
    let cancelCapture: () -> Void
    var config: LiveTranslateConfig = .default
    /// The language the cloud tier is asked for. Read from the pipeline's
    /// own default so the two cannot disagree about the direction.
    var targetLanguage: AppLanguage = LiveTranslationPipeline.defaultTargetLanguage

    /// Builds the two engines, once per screen. The indicator is this
    /// screen's own (the tier moves a counter; production gives it the
    /// session's, and this screen has no session).
    ///
    /// `@MainActor` because the indicator it builds is — `@Observable`
    /// UI state is where the tier's "a cloud request is in flight" flag
    /// belongs, and this screen drives the tier from the main actor
    /// anyway. Everything else here is main-actor by the screen's nature.
    @MainActor
    func makeEngines() -> [TranslateTestEngine: any TranslateProbeEngine] {
        // The tier is given THIS screen's indicator: the counter it moves
        // belongs to the surface that asked, not to a session that is not
        // running. Its deadline sleeps for real (`sleep` defaulted), which
        // is what makes the cloud latency on screen an honest one.
        let indicator = CloudActivityIndicatorModel(observabilityBus: observabilityBus,
                                                    config: config)
        let brain = LocalBrainTranslationTier(config: config,
                                              modelStore: modelStore,
                                              events: LiveTranslateEvents(bus: observabilityBus,
                                                                          config: config),
                                              targetLanguage: targetLanguage)
        // The readiness question is the tier's OWN question, asked the same
        // way (`installedModel()`: the first of `brainTranslationModelIDs`
        // that is installed *and complete*). Spelling it here rather than
        // calling the tier would let the two drift, and a screen that says
        // "ready" for a brain the tier then refuses is worse than one that
        // says nothing.
        let isModelInstalled: () -> Bool = { [config, modelStore] in
            guard let modelStore else { return false }
            return config.brainTranslationModelIDs.contains { modelStore.isAvailable($0) }
        }
        return [
            .local: LocalBrainProbeEngine(brain: brain,
                                          isModelInstalled: isModelInstalled),
            .gemini: CloudProbeEngine(tier: CloudTranslationTier(cache: cache,
                                                                 consentGate: consentGate,
                                                                 costGovernor: costGovernor,
                                                                 client: client,
                                                                 config: config,
                                                                 observabilityBus: observabilityBus,
                                                                 indicator: indicator),
                                      targetLanguage: targetLanguage,
                                      isProviderConfigured: isProviderConfigured,
                                      isCloudEnabled: isCloudEnabled),
        ]
    }
}
