import Foundation

// MARK: - [TRANSLATE-TEST] The dev screen's engine seam (2026-09-21)
//
// The hidden Settings translate-test screen answers one question the
// household can otherwise only infer: "what does each engine actually say
// for the text I type, and what did it cost me in time?" The two engines
// are the SHIPPED ones — tier 1 (`LocalBrainTranslationTier`, the
// on-device brain) and tier 2 (`CloudTranslationTier`, the
// consent-gated Gemini path) — consumed through the seam below and never
// reimplemented. Nothing in this file changes what production does; it
// reads the same actors the camera session reads.
//
// Why a seam at all, when both tiers are concrete: the screen's view model
// has to be testable with no model on disk, no network and no consent
// record (the same reason `LocalBrainTranslating` exists for the pipeline,
// and `LiveTranslateSessionTestHarness` for the session). The protocols
// here are one or two methods wide and exist only for THIS screen's tests —
// they are not a second tier abstraction and must not grow into one.
//
// The cloud path's consent gate is not consulted here on purpose. The gate
// is enforced INSIDE `CloudTranslationTier.resolve` (`gate.authorize()`,
// re-read per attempt, with the `Grant` proof type the transport requires),
// so a caller that goes through the tier cannot skip it. This file adds no
// bypass because it adds no path: the only way it reaches Gemini is the
// tier that already asks.

/// One row of the screen's model dropdown: a ladder model, or the cloud.
///
/// The local side names a MODEL rather than an engine (2026-09-21). "Local"
/// used to mean "whatever tier 1 would pick", which is the ladder's first
/// installed entry — a fine default and a poor instrument: the ladder holds
/// several quants and a superseded head, and the question this screen gets
/// asked is precisely which of them answers, and how well. So the screen
/// offers the ladder, one row per model, and Gemini beside it.
enum TranslateTestSelection: Hashable {
    /// Tier 1, run against THIS model — installed or not. A model that is
    /// not installed is a valid selection: the screen shows its download
    /// row rather than a run button that could only refuse.
    case model(ModelID)
    /// Tier 2, the consent-gated cloud path.
    case gemini

    /// The model this selection names, or `nil` for the cloud.
    ///
    /// The one answer to "is this row a model": the card and the readiness
    /// line are gated on it rather than on a sentinel name, so the cloud can
    /// never be described in a model's terms.
    var modelID: ModelID? {
        guard case .model(let id) = self else { return nil }
        return id
    }
}

/// What an engine would need before it can answer, in the screen's terms.
///
/// Five cases, and no associated payload beyond the refusal's own reason
/// token: the screen resolves WHICH download to offer from the selection
/// itself, so this type stays comparable in a test with no catalog fixture.
///
/// It was three (`ready`, `modelMissing`, `providerKeyMissing`) until the
/// 2026-09-21 review, which is why the doc used to say three. Each split
/// since is a pair with OPPOSITE fixes, which is the test for whether a case
/// is its own: `modelUnavailable` is "this phone cannot run it" where
/// `modelMissing` is "install it", and `cloudDisabled` is "someone shut the
/// cloud off" where `providerKeyMissing` is "enter a key". A screen that
/// folded either pair together would tell the household to do the one thing
/// that cannot help.
enum TranslateEngineReadiness: Equatable {
    /// The engine can run right now.
    case ready
    /// The selected model is not installed. The screen offers that entry's
    /// download row instead of a spinner that would never resolve.
    case modelMissing
    /// The model IS on disk and this device class still refuses it — the
    /// ledger's verdict, carried with its own reason.
    ///
    /// [MODEL-SWITCH] (2026-09-21 review) Its own case rather than a second
    /// spelling of `modelMissing`: the two have opposite fixes (install it
    /// vs. this phone cannot run it), and a screen that called a refused but
    /// installed model "Ready" — which is what the readiness line did before
    /// this — offers a button whose only outcome is a refusal.
    case modelUnavailable(reason: ModelUnavailabilityReason)
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

    /// The card's value for this disposition: the token, prefixed by the one
    /// sentence a deferral needs and nothing else does.
    ///
    /// [MODEL-SWITCH] (2026-09-21 review) A device that declined reports the
    /// same empty outcome as a model that ran and had nothing to say, and on
    /// the normal device state — the intent brain resident — that is EVERY
    /// row, at 0 ms. A bare `resident_brain` reads as the model failing.
    /// "Device busy, not attempted" is what actually happened, and the token
    /// stays beside it because the log will use it.
    ///
    /// [DEVSCREEN-EVICT] `evictedForRoom` changes which sentence is true, and
    /// it is the difference between two opposite findings. With nothing
    /// evicted, "device busy" is the whole story: something else was using
    /// the memory and this run did not ask it to move. With something
    /// evicted, the memory WAS freed and the model still could not run —
    /// "device busy" would then read as an ordinary refusal and hide the fact
    /// that the device has just been emptied and still cannot hold the
    /// model. The tokens of what left are in the sentence, because they are
    /// the same vocabulary as the `evicted` events.
    func caption(locale: Locale, evictedForRoom: [ModelSlot] = []) -> String {
        guard case .deferred = self else { return token }
        guard !evictedForRoom.isEmpty else {
            return L10n.fmt("settings.translateTest.result.busy", locale: locale, token)
        }
        return L10n.fmt("settings.translateTest.result.evictedThenRefused",
                        locale: locale,
                        evictedForRoom.map(\.rawValue).joined(separator: ", "),
                        token)
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

    /// Tier 1 only: how much of `latencyMs` went on getting the model's
    /// handle ready, in milliseconds — `nil` when nothing measured it (the
    /// cloud path, and any generator that does not report the split).
    ///
    /// **Why it is beside the latency rather than subtracted from it.** The
    /// comparison this screen exists for is between MODELS, and a total that
    /// includes a 2.5 GB page-in is not a fact about the model: with the
    /// idle unload at five seconds, the first run on a row pays the load and
    /// the second does not, so the same weights read as 12 s and then as
    /// 400 ms. The headline stays the wall clock — that is what the person
    /// waited, and hiding it would be the other lie — and the card prints
    /// this share beside it, so the decode-only figure is on screen for
    /// every reader who wants the comparison.
    var loadMs: Int? = nil

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

    /// Tier 1 only: the residents the warden unloaded so this attempt could
    /// load its model — empty whenever nothing was evicted, which is every
    /// run the warden's walk had no answer for.
    ///
    /// [LOAD-EVICT] What the warden's walk COST, on the card of the run that
    /// spent it. It is drawn on both endings: a run that then answered (the
    /// price of the answer) and a run that was still refused (`caption` reads
    /// it to say so). A `var` with a default, like the fields above, so the
    /// shipped initializer shape — and every fake in the suites — keeps
    /// compiling unchanged.
    var evictedForRoom: [ModelSlot] = []
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
                 targetLanguage: AppLanguage,
                 cachePolicy: CloudTranslationTier.CachePolicy) async -> CloudTranslationTier.BatchResult
}
extension CloudProbeTier {
    func resolve(items: [CloudTranslationTier.Item],
                 targetLanguage: AppLanguage) async -> CloudTranslationTier.BatchResult {
        await resolve(items: items, targetLanguage: targetLanguage, cachePolicy: .persist)
    }
}

extension CloudTranslationTier: CloudProbeTier {}

// (2026-09-21 review) Tier 1 used to be reached through a second protocol
// declared here — `LocalBrainModelTier`, one method wide, the named attempt.
// It is gone, and the comment it carried is worth keeping: the requirement
// now lives on the pipeline's own seam as an additive member
// (`LocalBrainTranslating.translate(_:using:)`), so there is one statement
// of the capability rather than two, and the screen's `brain` is typed by
// the same protocol the camera drives.
//
// **A requirement, not a defaulted convenience** (2026-09-21 review round
// 2). It was declared with a default implementation that forwarded to the
// unnamed call, on the reasoning that a brain whose world holds one model
// could answer honestly by resolving it itself. The reasoning is sound for
// such a brain and wrong for this screen: a conformer that never learned to
// distinguish models would answer a caller who asked for the Q8 out of its
// OWN resolution, under the Q8's row — a comparison the screen exists to
// make, silently measuring a different artifact. So the default is gone and
// every conformer states what it does with a name; `LocalBrainProbeEngine`
// below is the caller that depends on it.

// MARK: - Tier 1 (on-device brain)

/// The on-device path, over the shipped tier 1, bound to ONE model.
///
/// The install question arrives as a closure rather than a `ModelStore` so
/// this adapter owns no store and a test can answer it without one — the
/// same shape the tier itself uses (`modelStore: ModelStore?`, "a tier
/// without one reports itself unavailable, honestly").
///
/// **[MODEL-SWITCH] One predicate, asked twice** (2026-09-21 review). It is
/// the question the tier's own RUN GATE asks — `ModelStore.path(for:)`,
/// non-nil only when the artifact is on disk (`attempt`'s guard) — so the
/// row's marker, this engine's readiness and the install card all say what
/// the run would actually do. The screen previously answered it three ways
/// (`isAvailable`, `path(for:)`, `isInstalled(entry)`), which is three ways
/// to disagree on screen about one file.
///
/// One engine per ladder model, all sharing the ONE tier instance the
/// coordinator owns. That sharing is the shipped shape, not a shortcut: the
/// tier holds a single resident handle and keys it by model URL, so
/// switching models reloads the handle and switching back reloads it again
/// — which is what the device would do in production, and what the screen
/// should therefore be measuring.
struct LocalBrainProbeEngine: TranslateProbeEngine {
    /// The pipeline's own seam, which carries the named attempt
    /// (`LocalBrainTranslating.translate(_:using:)`) — the same protocol the
    /// camera drives, so nothing about this screen can narrow it.
    let brain: any LocalBrainTranslating
    /// The model this engine runs. Named, never resolved: the ladder's own
    /// preference is the tier's business, and this screen exists to ask what
    /// a specific model says.
    let model: ModelID
    /// Whether that model can run now (see the type's note).
    let isInstalled: (ModelID) -> Bool
    /// What the ledger says about a model the store HAS: the reason token it
    /// would refuse to admit it for, or `nil` when it would admit it.
    ///
    /// Asked because "on disk" is not "runnable": the warden refuses some
    /// models by device class, and a row that said "Ready" for one of those
    /// would offer a button whose only outcome is a refusal. `nil` rather
    /// than a `Bool` because the refusal's own sentence is what the screen
    /// shows.
    let unavailabilityReason: (ModelID) -> ModelUnavailabilityReason?
    /// The tier's config, for its batch bound. Needed because the bound —
    /// not the tier's return value — is what says whether a string was ever
    /// handed to the brain (see `LocalBrainDisposition`).
    let config: LiveTranslateConfig
    /// Injectable clock, the seam convention the shipped tiers use
    /// (`LiveTranslateConsentGate.now`, `CloudTranslationTier.sleep`) so a
    /// suite can pin a latency instead of racing one.
    var now: () -> Date = { Date() }

    func readiness() async -> TranslateEngineReadiness {
        // The store's answer first: a model that is not on disk has a more
        // useful thing to say than its class verdict (its download row).
        guard isInstalled(model) else { return .modelMissing }
        // Then the ledger's, which is the question this screen used to skip:
        // an installed model the device class refuses is not ready, and
        // saying so is the difference between "install it" and "this phone
        // cannot run it".
        if let reason = unavailabilityReason(model) { return .modelUnavailable(reason: reason) }
        return .ready
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
        let outcome = await brain.translate([text], using: model)
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
                                     // The tier's own split of that wait,
                                     // when its generator measured one —
                                     // `nil` for a fake, for the cloud, and
                                     // for any path that never reached a
                                     // generation.
                                     loadMs: outcome.loadDurationMs,
                                     localDisposition: disposition,
                                     // [DEVSCREEN-EVICT] What the tier had to
                                     // unload first, when the warden's walk
                                     // had an answer: empty on every run that
                                     // did not evict, and carried whether or
                                     // not the string was answered.
                                     evictedForRoom: outcome.evictedForRoom)
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

// MARK: - The ladder, as the dropdown needs it

/// One row of the model dropdown, as the screen draws it.
struct TranslateTestModelOption: Identifiable, Equatable {
    /// The model this row selects.
    let id: ModelID
    /// The name to print when this build's catalog carries no entry for
    /// `id` (a catalog swap mid-flight). The label itself is composed by the
    /// SHARED AI-models composer — see `TranslateTestModel.label(for:locale:)`
    /// — so this is a fallback and never a second name.
    let displayName: String
    /// Whether the tier's run gate would accept this model right now — the
    /// ONE predicate (`LocalBrainProbeEngine`'s note): the row's marker, the
    /// readiness line and the install card all read this, so the screen
    /// cannot say "not downloaded" in the picker and "Ready" in the row.
    let isInstalled: Bool
    /// Whether the ledger refuses it on this device class. Independent of
    /// `isInstalled`: a model can be on disk and still refused, and the row
    /// has to be able to say so.
    let isUnavailable: Bool
}

/// What the dropdown needs to know about the ladder and the device.
///
/// Closures rather than the catalog, the store and the download service
/// themselves, for the same reason the rest of this file takes closures: the
/// view model has to be testable with no catalog, no store and no file on
/// disk. It also has to stay LIVE — a download can finish while the screen
/// is open, and "is this installed" is a question about the device, not a
/// value captured when the screen was built.
struct TranslateTestModelSource {
    /// The ladder's TRANSLATION rungs, in the order the tier itself would
    /// try them.
    ///
    /// Built by the tier's own rule — `LocalBrainTranslationTier
    /// .translationModelIDs(from: config.brainTranslationModelIDs)` — rather
    /// than by a list of ids spelled here or by the catalogue's own
    /// translation list ([MODEL-SWITCH], 2026-09-21 review). The ladder
    /// carries the assistant's intent brains in its tail as fallbacks for
    /// its own resolution; a picker that offered them would send a
    /// translation prompt to a slot-filling brain and would offer Delete for
    /// an artifact the brain section manages. The tier is the one place that
    /// knows which rungs are translations, and its refusal and this list are
    /// the same predicate, so a row cannot be offered and then refused.
    ///
    /// Still read from the CONFIG rather than from a list of ids spelled
    /// here, so a catalog swap that adds, retires or reorders translation
    /// models changes this dropdown without a line of this screen changing.
    ///
    /// **Every rung here is a catalog entry, and always was**
    /// (2026-09-21 review round 2). The rule above — `translationModelIDs
    /// (from:)` — is `ladder.filter { ModelCatalog.isTranslationModel($0) }`,
    /// and that predicate is membership in `allTranslationEntries`, so the
    /// filtered list is a subset of the catalog BY CONSTRUCTION. The earlier
    /// version of this doc promised something else — "an id the catalog does
    /// not carry yet is still offered, under its own raw name" — and the
    /// promise is what was wrong, not the code: there is no rung this screen
    /// can draw that has no name to draw it with. The raw-id branches
    /// downstream of this (`displayName`'s fallback, `selectedModelName`'s)
    /// are therefore unreachable through production wiring and kept only as
    /// the contract of a hand-built source — see their own notes.
    let ladder: [ModelID]
    /// The catalog's display name for a model, or the id itself when the
    /// catalog has no entry for it.
    ///
    /// The fallback is DEAD through production wiring (see `ladder`): the
    /// ladder is filtered by catalogue membership, and the coordinator's own
    /// closure (`AppCoordinator.makeTranslateTestDependencies`) reads the
    /// entry for the name. It survives because this is a closure the type
    /// does not own — a suite can hand one that answers `nil` for a name, and
    /// a row with no name would be a row with a blank label. Showing the raw
    /// id is the honest answer in that case, and it keeps the row selectable.
    let displayName: (ModelID) -> String
    /// Whether the model can run now: the question the tier's own run gate
    /// asks (`ModelStore.path(for:)`). The ONE predicate — see
    /// `LocalBrainProbeEngine`'s note.
    let isInstalled: (ModelID) -> Bool
    /// What the ledger says about a model the store has: the reason it would
    /// refuse to admit it, or `nil` when it would.
    ///
    /// Asked of the same manager the AI-models rows ask
    /// (`ModelLifecycleManager.availability(of:)`), so a row this screen
    /// marks "not for this phone" is marked that way for the same reason,
    /// with the same reason token, as the row in Settings.
    let unavailabilityReason: (ModelID) -> ModelUnavailabilityReason?
}

// MARK: - Production wiring

/// The engines the screen asks, plus the indicator that belongs to them.
///
/// The indicator travels WITH the engines because it is built from the same
/// tier: production gives the tier the session's indicator, and this screen
/// has no session, so the screen must render the one its own tier moves
/// (OD-13: a visible indicator while the cloud tier is active — a screen
/// that showed cloud activity with no indicator would be the one surface
/// exempt from that rule).
@MainActor
struct TranslateTestEngines {
    let engines: [TranslateTestSelection: any TranslateProbeEngine]
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
    /// The ladder and the two questions the dropdown asks about it.
    let modelSource: TranslateTestModelSource
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

    /// Builds one engine per dropdown row, once per screen. The indicator is
    /// this screen's own (the tier moves a counter; production gives it the
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
        // ONE tier for the whole ladder, with one resident handle inside it
        // (see `LocalBrainProbeEngine`). A tier per model would hold a 2–3 GB
        // handle per row and blow the device on the second one.
        //
        // [LOAD-EVICT] (2026-09-22) This screen builds the tier exactly as
        // production does. A refusal that is about the device's other
        // residents is answered by having the warden unload them (see
        // `LocalBrainTranslationTier.gateForLoad`) for every caller now — that
        // is what makes the Q8 measurable on a phone whose warm STT is holding
        // the bytes, and the owner's device settled that it is also what the
        // shipped gate must do. It used to be this screen's ONE
        // production-visible difference, behind the persisted download bypass;
        // the bypass switch now governs DOWNLOADS only
        // (`ModelDownloadService`), which is what its row in the technical
        // sheet has always said.
        let brain = LocalBrainTranslationTier(
            config: config,
            modelStore: modelStore,
            events: LiveTranslateEvents(bus: observabilityBus, config: config),
            targetLanguage: targetLanguage)
        var engines: [TranslateTestSelection: any TranslateProbeEngine] = [:]
        for id in modelSource.ladder {
            engines[.model(id)] = LocalBrainProbeEngine(brain: brain,
                                                        model: id,
                                                        isInstalled: modelSource.isInstalled,
                                                        unavailabilityReason: modelSource.unavailabilityReason,
                                                        config: config)
        }
        engines[.gemini] = CloudProbeEngine(tier: CloudTranslationTier(cache: cache,
                                                                       consentGate: consentGate,
                                                                       costGovernor: costGovernor,
                                                                       client: client,
                                                                       config: config,
                                                                       observabilityBus: observabilityBus,
                                                                       indicator: indicator),
                                            targetLanguage: targetLanguage,
                                            isProviderConfigured: isProviderConfigured,
                                            isCloudEnabled: isCloudEnabled)
        return TranslateTestEngines(engines: engines, cloudIndicator: indicator)
    }
}
