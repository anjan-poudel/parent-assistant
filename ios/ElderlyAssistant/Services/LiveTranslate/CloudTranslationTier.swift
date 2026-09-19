import Foundation

// C08 orchestration + C15 cost integration — `CloudTranslationTier` (T-019).
//
// One attempt, end to end, in the design's fixed order:
//
//   1. **Validate the need** — the dictionary/cache layer answers what it can,
//      and nothing else leaves this actor for those strings (FR-LCT-020).
//   2. **Sanitise and bound** (C07) — a quarantined string never enters a
//      payload and its region is returned degraded immediately, not left
//      waiting on a batch that will not carry it.
//   3. **Consent** (C09) — fail closed, before a key is claimed.
//   4. **Budget** (C15) — the session latch, then the shipped governor's read.
//   5. **In-flight claim** — keys are claimed atomically, so the same string
//      arriving from two regions is one attempt with one shared outcome.
//   6. **One batched request** per batch of claimed keys (FR-LCT-009).
//   7. **Decode and validate** — only requested ids, only string values,
//      size-sanity bound (T-018's parser).
//   8. **Store** validated translations in C05 (a store failure is recorded
//      and never breaks the render: the cache accelerates, it cannot gate).
//   9. **Release** every claimed key in a `defer`, on every exit path — which
//      is also the cloud indicator's off switch (T-016).
//
// What this file exists to make true:
//
//  - **One caller, one network path.** `GeminiClient.translateStrings` is the
//    only outbound translation call and it requires a `Grant` minted by the
//    consent gate, so a request cannot be built without a consent read. This
//    actor is where that read happens; there is no second transport, endpoint
//    or URLSession anywhere in the feature.
//  - **No consent, no request — on every path (AM-1).** Every attempt mints
//    its own proof by re-reading the gate *immediately before it*, the first
//    attempt as much as the retry. A withdrawal between attempts therefore
//    blocks the retry structurally rather than by remembered discipline, and a
//    revocation cancels whatever is registered in flight.
//  - **Cancellation is terminal.** A cancellation-shaped transport error, or a
//    cancelled task, is never retried: it is the one classification the retry
//    table cannot undo, because the thing that cancelled it (a withdrawal, a
//    deadline) is a decision, not a fault.
//  - **One terminal outcome per region per cycle, always (AM-8, CL-1).** A key
//    already claimed by an in-flight request is never re-requested: the caller
//    awaits that request's task and adopts the same outcome for its region, so
//    no region can stay pending behind a key someone else already owns.
//  - **Attribution is truthful (CL-3).** A resolution carries where it came
//    from, and the tier's one mapper (`ResolutionOrigin.tier`) answers with the
//    shipped `LabelTranslationCache.Origin.tier`: a curated entry is tier 0, a
//    persisted (cloud-produced) entry is attributed to the cloud tier, and a
//    genuine response from this attempt is the cloud tier. The overlay's
//    in-place rule (FR-LCT-015) may only draw tier 0, so a cached cloud string
//    can never be drawn in place.
//  - **A spent budget latches for the session (FR-LCT-013).** Once the
//    governor refuses — or refuses a call the tier observes — the latch closes
//    and no later call re-reads the budget: raising the cap mid-session cannot
//    reopen egress; the next session re-consults the governor.
//  - **The deadline has one source of truth (CL-8).** It is the config's
//    derived `cloudDeadlineSeconds` — the shipped client's base timeout plus
//    the configured grace — and exceeding it terminates the regions as
//    degraded instead of leaving an unbounded pending state. The retry budget
//    lives *inside* that deadline (failure table row 18).
//
// The actor exists for the claim step: `inFlight` is the registry that makes
// "one attempt per key" atomic, and actor isolation is what makes two regions
// arriving in the same cycle race for it correctly instead of hoping.

actor CloudTranslationTier {

    // MARK: - Items and results

    /// One unresolved region's string, as the pipeline hands it over.
    struct Item: Equatable {
        let id: String
        let text: String
        /// Vision's detected source language, or nil. Never invented: when
        /// detection returned nothing, the field is omitted from the request.
        let detectedSourceLanguage: String?
    }

    /// Where a resolution came from. The tier names the origin rather than
    /// collapsing it into a tier, because the *reason* a string is tier 0
    /// (curated dictionary vs. a persisted cloud translation served from cache)
    /// is exactly what CL-3 requires to stay visible.
    enum ResolutionOrigin: Equatable {
        /// A cache/dictionary layer answered — no request happened this time.
        case cache(LabelTranslationCache.Origin)
        /// A genuine response from this attempt.
        case cloud

        /// The one origin → tier mapper (CL-3). A curated entry is tier 0; a
        /// persisted entry and a live response are the cloud tier, because a
        /// translation the cloud produced is a cloud translation even when it
        /// is served from the device's own store — and only tier 0 may be
        /// drawn in place (FR-LCT-008, FR-LCT-015).
        var tier: TranslationTier {
            switch self {
            case .cache(let layer): return layer.tier
            case .cloud: return .cloud
            }
        }
    }

    /// One region's answer: the translation, and what produced it.
    struct Resolution: Equatable {
        let translation: String
        let origin: ResolutionOrigin

        var tier: TranslationTier { origin.tier }
    }

    /// The terminal outcome of one cycle.
    ///
    /// There is no pending case: every item the caller asked about appears in
    /// exactly one of `resolved` and `failures`, which is what makes "no
    /// region remains pending forever" a property of the type rather than a
    /// hope (AM-8).
    struct BatchResult: Equatable {
        let resolved: [String: Resolution]
        let failures: [String: LiveTranslateError]

        var resolvedCount: Int { resolved.count }
        var unresolvedCount: Int { failures.count }

        /// The overlay's value type for one region (FR-LCT-008: a resolved
        /// result names the tier that produced it, a failure degrades with the
        /// mapping's reason and shows the original text). An item this batch
        /// did not ask about stays pending — the honest answer, since this
        /// batch makes no claim about it.
        func result(for item: Item) -> TranslationResult {
            if let resolution = resolved[item.id] {
                return .resolved(originalText: item.text,
                                 translation: resolution.translation,
                                 tier: resolution.tier)
            }
            if let error = failures[item.id] {
                return .degraded(originalText: item.text, reason: error.unavailableReason)
            }
            return .pending(item.text)
        }
    }

    // MARK: - Dependencies

    private let cache: LabelTranslationCache
    private let gate: LiveTranslateConsentGate
    private let costGovernor: GeminiCostGovernor
    private let client: GeminiClient
    private let config: LiveTranslateConfig
    private let events: LiveTranslateEvents
    private let indicator: CloudActivityIndicatorModel
    /// The deadline race's sleep. Production sleeps the derived deadline;
    /// tests supply an immediate or never-returning sleep so the race is
    /// exercised without a wall-clock wait (the same seam convention as the
    /// gate's `now`).
    ///
    /// A `Duration`, not a nanosecond count: the lifetime of this file is
    /// expressed in the same unit the deadline is (`TimeInterval` seconds →
    /// `Duration`), so no unit conversion and no bare scale factor exists here
    /// to get wrong.
    private let sleep: @Sendable (Duration) async throws -> Void

    // MARK: - State (actor-isolated)

    /// Keys claimed by a request that has not terminated yet. The value is the
    /// batch task, so a second caller can await it rather than re-request.
    private var inFlight: [String: Task<[String: KeyOutcome], Never>] = [:]
    /// Whether the day's budget has been observed exhausted. Once true it
    /// stays true for the life of this actor — a session, by construction.
    private var costLatched = false

    // MARK: - Init

    init(cache: LabelTranslationCache,
         consentGate: LiveTranslateConsentGate,
         costGovernor: GeminiCostGovernor,
         client: GeminiClient,
         config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         indicator: CloudActivityIndicatorModel,
         sleep: @escaping @Sendable (Duration) async throws -> Void = {
             try await Task<Never, Never>.sleep(for: $0)
         }) {
        self.cache = cache
        self.gate = consentGate
        self.costGovernor = costGovernor
        self.client = client
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        self.indicator = indicator
        self.sleep = sleep
    }

    // MARK: - Evidence

    /// Whether the session's cost latch has closed. Evidence for tests and for
    /// `security-test`; there is no setter.
    var isCostLatched: Bool { costLatched }

    /// How many keys are currently claimed by an in-flight request. Evidence:
    /// it is zero before the first cycle and must be zero after every exit
    /// path, which is what "every claimed key is released" means observably.
    var inFlightKeyCount: Int { inFlight.count }

    /// The batch deadline, derived from the config (which derives it from the
    /// shipped client's base timeout plus the grace — CL-8). Exposed so the
    /// derivation is assertable rather than implied.
    var deadlineSeconds: TimeInterval { config.cloudDeadlineSeconds }

    // MARK: - The cycle

    /// Resolves every item the caller hands over, terminally.
    func resolve(items: [Item], targetLanguage: AppLanguage = .nepali) async -> BatchResult {
        guard !items.isEmpty else { return BatchResult(resolved: [:], failures: [:]) }

        var resolved: [String: Resolution] = [:]
        var failures: [String: LiveTranslateError] = [:]

        // 1. Validate the need. The dictionary/cache layer answers first, and
        //    a read fault is a miss (self-healing, never elder-facing).
        var candidates: [Item] = []
        for item in items {
            if case .success(let hit) = cache.lookup(text: item.text, targetLanguage: targetLanguage),
               let hit {
                resolved[item.id] = Resolution(translation: hit.translation,
                                               origin: .cache(hit.origin))
            } else {
                candidates.append(item)
            }
        }
        guard !candidates.isEmpty else { return BatchResult(resolved: resolved, failures: failures) }

        // 2. Sanitise and bound. Quarantined strings are excluded here, before
        //    anything else can see them, and their regions degrade now rather
        //    than waiting on a batch they are not part of.
        let verdict = SceneTextSanitiser.sanitiseBatch(
            candidates.map { .init(id: $0.id, text: $0.text) },
            maxLength: config.sceneTextMaxLength)
        SceneTextSanitiser.record(verdict, on: events)
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for quarantined in verdict.quarantined {
            failures[quarantined.id] = .textQuarantined(quarantined.reason)
        }

        // One target per distinct key: two regions with the same text are one
        // request item with one outcome (AM-8).
        var orderedKeys: [String] = []
        var targetByKey: [String: Target] = [:]
        var idsByKey: [String: [String]] = [:]
        var dedupedCount = 0
        for sendable in verdict.sendable {
            guard let source = byID[sendable.id] else { continue }
            let key = LabelTranslationCache.normalizationKey(text: source.text,
                                                             targetLanguage: targetLanguage)
            idsByKey[key, default: []].append(sendable.id)
            if targetByKey[key] == nil {
                targetByKey[key] = Target(key: key,
                                          wireText: sendable.text,
                                          originalText: source.text,
                                          sourceLanguage: source.detectedSourceLanguage)
                orderedKeys.append(key)
            } else {
                dedupedCount += 1
            }
        }

        if !orderedKeys.isEmpty {
            await runCloudPath(orderedKeys: orderedKeys,
                               targetByKey: targetByKey,
                               idsByKey: idsByKey,
                               targetLanguage: targetLanguage,
                               dedupedWithinCycle: dedupedCount,
                               resolved: &resolved,
                               failures: &failures)
        }

        reportDegradation(failures)
        return BatchResult(resolved: resolved, failures: failures)
    }

    // MARK: - The cloud path (steps 3–9)

    private func runCloudPath(orderedKeys: [String],
                              targetByKey: [String: Target],
                              idsByKey: [String: [String]],
                              targetLanguage: AppLanguage,
                              dedupedWithinCycle: Int,
                              resolved: inout [String: Resolution],
                              failures: inout [String: LiveTranslateError]) async {
        // 3. Consent — fail closed, and before any key is claimed.
        //
        //    The proof that authorizes a request is minted per attempt inside
        //    `attemptSequence` (AM-1): a `Grant` is a statement about the read
        //    that produced it, never a standing permission, so this read is
        //    the fixed order's policy step and not a token to carry forward.
        switch gate.authorize() {
        case .success:
            break
        case .failure(let error):
            for key in orderedKeys { fail(key: key, idsByKey: idsByKey, with: error, into: &failures) }
            return
        }

        // 4. Budget — the latch first (it is the session's own state), then the
        //    shipped governor's read. Nothing here counts: the count is the
        //    client's, at the transport boundary.
        if costLatched || !costGovernor.allowsCall() {
            latchCost()
            let error = LiveTranslateError.costBudgetExhausted
            for key in orderedKeys { fail(key: key, idsByKey: idsByKey, with: error, into: &failures) }
            return
        }

        // 5. Claim. A key already in flight is not re-requested: its owner's
        //    task is awaited and the same outcome is adopted (AM-8, CL-1).
        var claimed: [String] = []
        var bridged: [(key: String, task: Task<[String: KeyOutcome], Never>)] = []
        for key in orderedKeys {
            if let existing = inFlight[key] {
                bridged.append((key, existing))
            } else {
                claimed.append(key)
            }
        }

        // 6. One batched request per batch of claimed keys, sequentially. The
        //    bounds are the config's; nothing is dropped when a scene exceeds
        //    them.
        let claimedTexts = claimed.map { targetByKey[$0]?.wireText ?? "" }
        let batches = SceneTextSanitiser.bound(claimedTexts,
                                               maxStrings: config.cloudBatchMaxStrings,
                                               maxCharacters: config.cloudBatchMaxCharacters)
        var offset = 0
        var batchIndex = 0
        while batchIndex < batches.count {
            let batch = batches[batchIndex]
            let keys = Array(claimed[offset..<(offset + batch.count)])
            offset += batch.count
            let targets = keys.compactMap { targetByKey[$0] }
            events.translationBatchRequested(stringCount: targets.count,
                                             batchIndex: batchIndex,
                                             batchCount: batches.count)

            let start = Date()
            let regionIDs = keys.flatMap { idsByKey[$0] ?? [] }
            let outcomes = await runClaimedBatch(targets, targetLanguage: targetLanguage)
            for key in keys {
                adopt(outcomes[key], for: key, idsByKey: idsByKey,
                      resolved: &resolved, failures: &failures)
            }
            let resolvedForBatch = regionIDs.filter { resolved[$0] != nil }.count
            events.translationBatchResolved(
                resolvedCount: resolvedForBatch,
                unresolvedCount: regionIDs.count - resolvedForBatch,
                durationMs: Int(Date().timeIntervalSince(start) * 1000))
            batchIndex += 1
        }

        // 5 (continued). A bridged key's outcome is another cycle's work; adopt
        //    it when that request terminates. Every in-flight task is itself
        //    deadline-bounded, so this wait is bounded too.
        let dedupedTotal = bridged.count + dedupedWithinCycle
        if dedupedTotal > 0 { events.translationDedupeHit(keyCount: dedupedTotal) }
        for bridge in bridged {
            let outcomes = await bridge.task.value
            adopt(outcomes[bridge.key], for: bridge.key, idsByKey: idsByKey,
                  resolved: &resolved, failures: &failures)
        }
    }

    /// Reports the unretryable-refusal kinds the call site cannot see, once per
    /// reason, with the region count it covers.
    private func reportDegradation(_ failures: [String: LiveTranslateError]) {
        var counts: [TranslationUnavailableReason: Int] = [:]
        for error in failures.values { counts[error.unavailableReason, default: 0] += 1 }
        for reason in counts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            events.translationDegraded(reason: reason, regionCount: counts[reason] ?? 0)
        }
    }

    private func fail(key: String,
                      idsByKey: [String: [String]],
                      with error: LiveTranslateError,
                      into failures: inout [String: LiveTranslateError]) {
        for id in idsByKey[key] ?? [] { failures[id] = error }
    }

    private func adopt(_ outcome: KeyOutcome?,
                       for key: String,
                       idsByKey: [String: [String]],
                       resolved: inout [String: Resolution],
                       failures: inout [String: LiveTranslateError]) {
        // Every claimed key receives an outcome; the fallback exists so a
        // region can never be left pending if that invariant is ever broken.
        switch outcome ?? .failed(.cloudTransient(.other)) {
        case .resolved(let translation, let origin):
            for id in idsByKey[key] ?? [] {
                resolved[id] = Resolution(translation: translation, origin: origin)
            }
        case .failed(let error):
            for id in idsByKey[key] ?? [] { failures[id] = error }
        }
    }

    // MARK: - One batch's request lifecycle

    /// Runs one batch: claim the keys, register the work with the gate, bound
    /// it with the deadline, and release on every exit path.
    private func runClaimedBatch(_ targets: [Target],
                                 targetLanguage: AppLanguage) async -> [String: KeyOutcome] {
        // The task handle is what a revocation cancels, so it exists before the
        // registration and the registration exists before any await.
        let deadline = deadlineDuration
        let task = Task {
            await self.runDeadlineBoundedAttempts(targets,
                                                  targetLanguage: targetLanguage,
                                                  deadline: deadline)
        }
        for target in targets { inFlight[target.key] = task }
        let registration = gate.registerInFlight { task.cancel() }
        defer {
            for target in targets { inFlight.removeValue(forKey: target.key) }
            registration.release()
        }
        return await task.value
    }

    /// The derived deadline as the clock's own unit, from the config's
    /// seconds (`cloudRequestTimeout + cloudDeadlineGraceSeconds`, CL-8).
    private var deadlineDuration: Duration {
        .seconds(deadlineSeconds)
    }

    /// The deadline wraps the whole attempt sequence — the retry budget is
    /// inside it (failure table row 18) — so a request that outlives its own
    /// timeout terminates the batch instead of leaving it pending.
    private func runDeadlineBoundedAttempts(_ targets: [Target],
                                            targetLanguage: AppLanguage,
                                            deadline: Duration) async -> [String: KeyOutcome] {
        await withTaskGroup(of: RaceTick.self) { group in
            group.addTask {
                .work(await self.attemptSequence(targets, targetLanguage: targetLanguage))
            }
            group.addTask { await self.deadlineTick(deadline) }

            var outcomes: [String: KeyOutcome] = [:]
            var decided = false
            while let tick = await group.next() {
                switch tick {
                case .work(let value):
                    outcomes = value
                    decided = true
                case .deadlineExceeded:
                    outcomes = Self.allFailed(targets, with: .cloudDeadlineExceeded)
                    decided = true
                case .deadlineSleepCancelled:
                    // Something else cancelled the sleep — a withdrawal
                    // cancels the work task, and with it this group's
                    // children. The work child still returns its terminal
                    // outcome, so keep waiting for it.
                    continue
                }
                if decided { break }
            }
            group.cancelAll()
            // Unreachable: the work child always returns a value. Stated
            // rather than assumed, because returning here would leave the
            // batch's regions pending.
            return decided ? outcomes : Self.allFailed(targets, with: .cloudTransient(.other))
        }
    }

    /// The deadline's half of the race. A cancelled sleep is deliberately
    /// distinguishable from an elapsed one: a withdrawal cancels the work, and
    /// reporting that as "deadline exceeded" would be a false cause.
    private func deadlineTick(_ duration: Duration) async -> RaceTick {
        do {
            try await sleep(duration)
        } catch {
            return .deadlineSleepCancelled
        }
        return .deadlineExceeded
    }

    /// Attempts the batch at most `cloudMaxRetries + 1` times, retrying only
    /// what the table allows, and minting a fresh consent proof per attempt.
    private func attemptSequence(_ targets: [Target],
                                 targetLanguage: AppLanguage) async -> [String: KeyOutcome] {
        var attempt = 0
        while true {
            // AM-1: the gate is re-read immediately before **every** attempt,
            // the retry included. A withdrawal between attempts therefore ends
            // here, before a request can be built.
            let grant: LiveTranslateConsentGate.Grant
            switch gate.authorize() {
            case .success(let proof):
                grant = proof
            case .failure(let error):
                return Self.allFailed(targets, with: error)
            }

            // The latch is checked per attempt too: a budget that ran out
            // while a batch was in flight blocks the retry, not just the next
            // cycle.
            if costLatched {
                return Self.allFailed(targets, with: .costBudgetExhausted)
            }

            do {
                let outcome = try await send(targets, targetLanguage: targetLanguage, grant: grant)
                return adopt(outcome, for: targets, targetLanguage: targetLanguage)
            } catch {
                let failure = Self.classify(error)

                // A spent budget is terminal and session-latching: no retry,
                // no alternative request shape (FR-LCT-013).
                if case .costBudgetExhausted = failure {
                    latchCost()
                    return Self.allFailed(targets, with: failure)
                }

                // AM-1: a cancellation shape is never retryable. The reason
                // reported is the freshest gate read — a withdrawal that
                // caused the cancellation is named as the consent failure it
                // is, rather than as a vague transport fault.
                if Task.isCancelled || Self.isCancellationShaped(error) {
                    if case .failure(let consentError) = gate.authorize() {
                        return Self.allFailed(targets, with: consentError)
                    }
                    return Self.allFailed(targets, with: failure)
                }

                guard attempt < config.cloudMaxRetries, RetryPolicy.isRetryable(failure) else {
                    return Self.allFailed(targets, with: failure)
                }
                attempt += 1
            }
        }
    }

    /// One request, through the shipped client chokepoint. The indicator is on
    /// exactly while a request is in flight, and returns to off through the
    /// same scoped release on success, failure and cancellation alike (T-016).
    private func send(_ targets: [Target],
                      targetLanguage: AppLanguage,
                      grant: LiveTranslateConsentGate.Grant) async throws -> TranslationResponseParser.Outcome {
        let items = targets.enumerated().map { index, target in
            GeminiClient.TranslationItem(id: String(index),
                                         text: target.wireText,
                                         sourceLanguage: target.sourceLanguage)
        }
        return try await indicator.withRequestInFlight {
            try await client.translateStrings(items: items,
                                              targetLanguage: targetLanguage.rawValue,
                                              consent: grant,
                                              translationConfig: config)
        }
    }

    /// Validated translations become resolutions and are stored; everything
    /// the parser refused becomes a per-region failure (row 19: terminal for
    /// that item only, never retried inside the batch).
    private func adopt(_ outcome: TranslationResponseParser.Outcome,
                       for targets: [Target],
                       targetLanguage: AppLanguage) -> [String: KeyOutcome] {
        var results: [String: KeyOutcome] = [:]
        for (index, target) in targets.enumerated() {
            let id = String(index)
            if let translation = outcome.translations[id] {
                // A store failure is recorded by the cache itself and never
                // changes the outcome: the translation still renders.
                _ = cache.store(text: target.originalText,
                                translation: translation,
                                targetLanguage: targetLanguage)
                results[target.key] = .resolved(translation, origin: .cloud)
            } else {
                results[target.key] = .failed(.cloudResponseUnusable(outcome.rejections[id] ?? .missingIDs))
            }
        }
        return results
    }

    private func latchCost() {
        guard !costLatched else { return }
        costLatched = true
        events.costExhaustedLatched()
    }

    // MARK: - Classification (the retryability table, rows 10–20)

    private static func allFailed(_ targets: [Target],
                                  with error: LiveTranslateError) -> [String: KeyOutcome] {
        var results: [String: KeyOutcome] = [:]
        for target in targets { results[target.key] = .failed(error) }
        return results
    }

    /// The shipped error shapes into the feature's taxonomy (T-002's table,
    /// reused rather than re-derived), plus this layer's own two additions.
    private static func classify(_ error: Error) -> LiveTranslateError {
        if let gemini = error as? GeminiClient.GeminiClientError {
            return LiveTranslateError.fromGemini(gemini)
        }
        if let translation = error as? GeminiClient.TranslationError {
            switch translation {
            case .responseUnusable(let defect):
                // A body that is not a usable JSON object is the same defect
                // class as the shipped client's empty response (row 17).
                switch defect {
                case .empty, .notJSON: return .cloudResponseUnusable(.notJSON)
                }
            case .consentProofMismatch:
                // The proof did not stand for the copy in force: consent is
                // not in force. Fail closed, never retried.
                return .consentDenied
            case .emptyBatch, .requestNotBuildable:
                // A request that cannot be built will not build on retry; the
                // shipped conversion table routes that class to
                // `providerNotConfigured` (it is what `.invalidURL` maps to).
                // Both cases are unreachable through this actor — it never
                // sends an empty or unencodable batch — and are stated rather
                // than defaulted so the compiler keeps this mapping complete.
                return .providerNotConfigured
            }
        }
        return LiveTranslateError.fromTransport(error)
    }

    /// A cancellation shape: the task was cancelled, or the transport reported
    /// the request as cancelled. Terminal, never retried (AM-1).
    private static func isCancellationShaped(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

// MARK: - Supporting types

/// One claimed key's request payload: what travels, and what the key means
/// locally. The two are deliberately separate — the wire carries the sanitised
/// text, while the cache is keyed by the recognized text the region owns.
private struct Target: Equatable {
    let key: String
    let wireText: String
    let originalText: String
    let sourceLanguage: String?
}

/// One claimed key's terminal state.
private enum KeyOutcome: Equatable {
    case resolved(String, origin: CloudTranslationTier.ResolutionOrigin)
    case failed(LiveTranslateError)
}

/// One completion of the deadline race.
private enum RaceTick: Equatable {
    case work([String: KeyOutcome])
    case deadlineExceeded
    case deadlineSleepCancelled
}

/// The design's retryability table, rows 10–20, as code. Exhaustive with no
/// default: a new error case must be classified deliberately rather than
/// inheriting a retry.
private enum RetryPolicy {
    static func isRetryable(_ error: LiveTranslateError) -> Bool {
        switch error {
        case .cloudTransient:
            // Timeout, offline, connection lost, unclassified (row 13).
            return true
        case .cloudResponseUnusable:
            // Malformed, empty or unusable response (row 17).
            return true
        case .cloudRejected(let status):
            // 408 / 429 / 5xx once (row 14); every other 4xx never (row 15) —
            // a malformed request does not become well-formed by repeating it.
            return status == 408 || status == 429 || (500...599).contains(status)
        case .cloudDisabled,              // the master switch is off: the pipeline
                                          // gates before this tier is ever reached,
                                          // so there is no request to repeat
             .providerNotConfigured,      // row 10
             .consentNotRecorded,         // row 11
             .consentDenied,              // row 11
             .consentRecordUnreadable,    // row 11
             .costBudgetExhausted,        // row 12
             .cloudPolicyBlocked,         // row 16
             .cloudDeadlineExceeded,      // row 18
             .textQuarantined,            // row 21 — not a cloud failure at all
             .speechFailed,
             .cameraPermissionNotDetermined,
             .cameraPermissionDenied,
             .cameraUnavailable,
             .cameraSessionInterrupted,
             .ocrUnavailable,
             .ocrPassFailed,
             .trackingUnsupported,
             .cacheReadFailed,
             .cacheWriteFailed:
            return false
        }
    }
}
