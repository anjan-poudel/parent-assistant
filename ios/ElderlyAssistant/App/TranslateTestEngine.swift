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

/// What tier 1 did with the string.
///
/// Three cases because the tier's return value cannot tell them apart by
/// itself: `LocalBrainTranslationOutcome` reports the same empty
/// `translations` dictionary for "the batch bound excluded this string",
/// "the warden declined before attempting" and "the brain ran and had no
/// answer" alike. Reporting all three as one `noTierResolved` result would
/// put a fault on a tier that was never asked.
enum LocalBrainDisposition: Equatable {
    /// The tier's own batch bound excluded the string before any attempt —
    /// a source over `brainTranslationMaxCharacters`, or a config with no
    /// room for one. Proven by asking the tier's own `batchPrefixLength`
    /// (`> 0` means it would have been asked), never inferred from the empty
    /// outcome.
    case neverAttempted
    /// The tier declined before attempting, and named why. The payload is
    /// the tier's own deferral, payload and all.
    case deferred(LocalBrainDeferral)
    /// The tier attempted (or tried to run) the brain and produced no
    /// translation for this string — the case the plain `noTierResolved`
    /// result is actually for.
    case attemptedWithoutAnswer

    /// The token the card prints.
    ///
    /// The deferral case renders the tier's OWN event vocabulary
    /// (`LocalBrainDeferral.eventToken`), so a card can be checked against
    /// the logs of the same run; the other two take the same spelling
    /// convention (snake_case tokens, never prose) because they are the same
    /// kind of fact.
    var token: String {
        switch self {
        case .neverAttempted: return "never_attempted"
        case .attemptedWithoutAnswer: return "attempted_without_answer"
        case .deferred(let deferral): return deferral.eventToken
        }
    }
}

extension LocalBrainDeferral {
    /// The deferral as the tier names it in its own events.
    ///
    /// Derived from `eventReason` rather than re-spelled here: a second
    /// switch over the same cases is a second place to forget one (and the
    /// two were in fact already drifting — this used to say `residentBrain`
    /// where the event schema says `resident_brain`), and the event token is
    /// what an operator reading the log beside this screen will see.
    var eventToken: String { eventReason.rawValue }
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

    /// Tier 1 only: what the tier did with the string, when it did not
    /// translate it. `nil` when the brain answered (and for the cloud path,
    /// which has no such states).
    var localDisposition: LocalBrainDisposition? = nil

    /// Tier 2 only: whether the answer was computed now or served from the
    /// device's own store. `nil` when nothing was answered.
    ///
    /// Read from `BatchResult.origins(for:)`, because `TranslationResult`
    /// alone cannot say this — it names the tier and drops the origin, so a
    /// cache hit would otherwise show as a cloud answer that took a
    /// millisecond, which would make the latency this screen exists to
    /// compare a lie.
    var cloudOrigin: LiveTranslateResolutionOrigin? = nil
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

/// The one method this screen asks of the cloud tier.
///
/// Declared here so `CloudProbeEngine` can be tested against a scripted
/// batch — the provenance and refusal branches below are the ones a live
/// tier can only produce with a network, a consent record and a cache, and
/// they are exactly the branches a reviewer has to be able to pin. The
/// conformance is on the shipped actor itself (`extension CloudTranslationTier:
/// CloudProbeTier {}`), so there is no wrapper between this screen and the
/// tier it is measuring.
///
/// `Sendable` because the conformer is an actor: an async requirement can be
/// satisfied by an actor's isolated method only when the protocol carries
/// that promise, and without it the conformance is a warning today and an
/// error in Swift 6.
protocol CloudProbeTier: Sendable {
    func resolve(items: [CloudTranslationTier.Item],
                 targetLanguage: AppLanguage) async -> CloudTranslationTier.BatchResult
}

extension CloudTranslationTier: CloudProbeTier {}

// MARK: - Tier 1 (on-device brain)

/// The on-device path, over the shipped tier 1.
///
/// The install question arrives as a closure rather than a `ModelStore` so
/// this adapter owns no store and a test can answer it without one — the
/// same shape the tier itself uses (`modelStore: ModelStore?`, "a tier
/// without one reports itself unavailable, honestly"). It is fed by the
/// tier's own `installedModel()` (see `makeEngines`), not by a second walk
/// of `brainTranslationModelIDs`, so the two cannot disagree about which
/// file counts as installed.
struct LocalBrainProbeEngine: TranslateProbeEngine {
    let brain: any LocalBrainTranslating
    /// The tier's own answer to "which catalogue entry will run", `nil` when
    /// none will. Async because the tier is an actor: the ask hops to it.
    let installedModel: () async -> ModelID?
    /// The tier's config, for its batch bound. Needed because the bound —
    /// not the tier's return value — is what says whether a string was ever
    /// handed to the brain (see `LocalBrainDisposition`).
    let config: LiveTranslateConfig
    /// Injectable clock, the seam convention the shipped tiers use
    /// (`LiveTranslateConsentGate.now`, `CloudTranslationTier.sleep`) so a
    /// suite can pin a latency instead of racing one.
    var now: () -> Date = { Date() }

    func readiness() async -> TranslateEngineReadiness {
        await installedModel() != nil ? .ready : .modelMissing
    }

    func probe(_ text: String) async -> TranslateProbeOutcome {
        // The bound is asked FIRST, before the brain is touched, because the
        // outcome the brain returns cannot answer this: a string over the
        // character bound never reaches it, and tier 1 returns the same empty
        // dictionary it returns for an attempt that failed. Charging that to
        // `.noTierResolved` would report a fault on a tier that was never
        // asked — and would show a latency for work that never happened.
        guard LocalBrainTranslationTier.batchPrefixLength(of: [text], config: config) > 0 else {
            return TranslateProbeOutcome(
                result: .degraded(originalText: text, reason: .noTierResolved),
                latencyMs: 0,
                localDisposition: .neverAttempted)
        }

        let started = now()
        let outcome = await brain.translate([text])
        let latencyMs = Int(now().timeIntervalSince(started) * 1000)

        // A string the attempt did not answer is ABSENT from `translations`
        // (the protocol's contract: "never an empty string, never the source
        // itself"), so presence is the whole test. What it means for the
        // screen is "tier 1 did not translate this" — `noTierResolved`,
        // which is the honest token for a failure no more specific cause
        // describes — and the disposition beside it says whether the brain
        // was asked at all.
        let result: TranslationResult
        let disposition: LocalBrainDisposition?
        if let translation = outcome.translations[text] {
            result = .resolved(originalText: text,
                               translation: translation,
                               tier: .onDeviceBrain)
            disposition = nil
        } else {
            result = .degraded(originalText: text, reason: .noTierResolved)
            disposition = outcome.deferral.map(LocalBrainDisposition.deferred) ?? .attemptedWithoutAnswer
        }
        return TranslateProbeOutcome(result: result,
                                     latencyMs: latencyMs,
                                     localDisposition: disposition)
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
    let tier: any CloudProbeTier
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
        // The same argument for the key: it can be cleared while the screen
        // is open, and the tier would spend a request to report a failure
        // this already knows the fix for — the setup the household has to
        // do. Asked here too so the card names the setup, not a dead call.
        guard isProviderConfigured() else {
            return TranslateProbeOutcome(
                result: .degraded(originalText: text, reason: .providerNotConfigured),
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
        return TranslateProbeOutcome(result: batch.result(for: item),
                                     latencyMs: latencyMs,
                                     // Provenance, when there was an answer:
                                     // `origins(for:)` omits unanswered
                                     // items, exactly as `resolved` does.
                                     cloudOrigin: batch.origins(for: [item])[item.id])
    }
}

// MARK: - Production wiring

/// The two engines the screen asks, plus the indicator that belongs to them.
///
/// The indicator travels WITH the engines because it is built from the same
/// tier: production gives the tier the session's indicator, and this screen
/// has no session, so the screen must render the one its own tier moves
/// (OD-13: a visible indicator while the cloud tier is active — a screen
/// that showed cloud activity with no indicator would be the one surface
/// exempt from that rule).
@MainActor
struct TranslateTestEngines {
    let engines: [TranslateTestEngine: any TranslateProbeEngine]
    let cloudIndicator: CloudActivityIndicatorModel
}

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
    func makeEngines() -> TranslateTestEngines {
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
        // The readiness question is the tier's OWN, asked of the tier
        // itself (`installedModel()`: the first of
        // `brainTranslationModelIDs` that is installed *and complete*).
        // Re-spelling the walk here would let the two drift, and a screen
        // that says "ready" for a brain the tier then refuses is worse than
        // one that says nothing.
        return TranslateTestEngines(
            engines: [
                .local: LocalBrainProbeEngine(brain: brain,
                                              installedModel: { await brain.installedModel() },
                                              config: config),
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
            ],
            cloudIndicator: indicator)
    }
}
