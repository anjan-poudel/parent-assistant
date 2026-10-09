import Foundation

// MARK: - Pressure-tiered brain pick ([VOICE-OOM] B', 2026-10-10)
//
// The hardening brief's change B was a typed refusal AT the load site. The
// owner's amendment (B') moved the decision EARLIER: a per-turn, pressure-
// tiered brain pick made BEFORE the brain load, so a device under kernel
// warning/critical steps down to the largest installed brain that really
// fits instead of walking into the load and refusing it after the fact
// (the pre-ack has already played by then, and the ledger's class budget —
// the number the old refusal would have been built on — is exactly the
// number that is NOT the app's real free memory on a sick system: the
// field device's class said room while the kernel had ~30 MB left).
//
// The decision is pure and performs no IO: the coordinator resolves the
// inputs (the manager's kernel-pressure reading, `os_proc_available_memory()`,
// the remembered pick, the installed brains) and applies the outcome
// through the interpreter's existing `switchBaseModel` seam. Three
// outcomes:
//
//   .keep        no fresh pressure evidence and no catastrophic headroom —
//                run the remembered/explicit pick unchanged (the shipped
//                behavior, on every healthy device),
//   .stepDown(id) pressure is real and a SMALLER installed brain fits
//                `available − safetyMargin` — run that one instead,
//   .lightweight nothing fits — no local brain runs this turn; the
//                router's existing deterministic/keyword fallback answers.
//                This is the terminal case where the original B refusal
//                survives, now enforced at the load site by the same
//                arithmetic (`pressureRefusesLoad`).
//
// The rules that make it safe:
//  - INSTALLED ONLY. A candidate must already be on disk; under pressure
//    this resolver can never trigger a download (a multi-GB download
//    mid-pressure is the opposite of the hardening). The candidate pool is
//    the curated list — the same pool the Settings picker offers — so a
//    hidden/legacy artifact cannot be picked by pressure.
//  - NEVER UP. A candidate may not exceed the remembered pick's live
//    bytes; pressure steps DOWN or keeps, it never upgrades.
//  - The remembered pick leads the candidate list, so an equal-size
//    sibling can never displace what the household chose (`max(by:)`
//    keeps the first of equal sizes — the same tie rule
//    `LanguageModelResolver.resolvedAutomaticPick` states).
//  - The language gate is `LanguageModelResolver.isLanguageCompatible`
//    (the same walk shape), but the REMEMBERED pick bypasses it — an
//    explicit pick outranks the language table, the same rule
//    `AppCoordinator.resolveBrainModelID` rule 1 states.
//
// The numbers are real, not class-budget arithmetic: `liveBytes` comes
// from `ModelLifecycleInventory` and the fit is computed against the app's
// CURRENT free memory.

/// What a turn should run from the local brain's point of view.
enum PressureBrainPick: Equatable {
    /// Run the remembered/explicit pick unchanged (no fresh pressure
    /// evidence, or the pick itself fits under the margin).
    case keep
    /// Run this smaller installed brain instead of the remembered pick.
    case stepDown(ModelID)
    /// No installed brain fits under pressure — the deterministic
    /// fallback answers this turn.
    case lightweight
}

/// The pure decision table behind the pick. Injectable and IO-free: every
/// input is a value and `liveBytes` is a function parameter (the
/// production default reads the model-lifecycle inventory), so the tier
/// walk is unit-testable without a device, a store, or a ledger.
enum PressureBrainPickResolver {

    /// [VOICE-OOM] The page-in headroom every pressurized fit must leave
    /// behind: a load is admitted only while `available − liveBytes`
    /// still clears this. 768 MB covers the brain's own page-in spike
    /// plus the turn's other allocations (ack WAV, KV growth, tokenizer
    /// scratch) — the brief's ">= 768 MB suggested", taken at its
    /// conservative end. One constant, so the pick and the load-site
    /// refusal (`pressureRefusesLoad`) can never disagree.
    static let safetyMarginBytes: UInt64 = 768_000_000

    /// [VOICE-OOM] How long a kernel warning/critical stays "evidence"
    /// for a load decision. The manager's level can LATCH on the
    /// UIKit-notification route (nothing on that path ever clears it —
    /// `MemoryPressureReading.secondsSinceWarning` exists for exactly
    /// this), and refusing every load for the life of the process after
    /// one transient warning would be a worse failure than the one this
    /// hardening prevents. 30 s mirrors
    /// `LiveTranslateConfig.brainTranslationCriticalPressureWindowSeconds`
    /// and the doctrine in `LocalBrainTranslationTier.pressureDeferral`.
    static let pressureWindowSeconds: TimeInterval = 30

    /// [VOICE-OOM] Whether there is FRESH kernel-pressure evidence that
    /// should tier this turn's brain pick — or the app's free memory is
    /// below the margin itself (the sick-device ~30 MB case, which must
    /// engage the arithmetic even if the level reads normal or stale).
    ///
    /// The freshness half is delegated to
    /// `LocalBrainTranslationTier.pressureDeferral` on purpose: the latch
    /// doctrine (a stale warning/critical ages out; a RECENT critical
    /// counts even after the level reads normal; a hand-built reading
    /// with no ages is treated as fresh) lives in ONE place in this
    /// codebase, and a second spelling of it would drift.
    static func pressureEngages(
        reading: MemoryPressureReading,
        availableProcessMemoryBytes: UInt64,
        marginBytes: UInt64 = safetyMarginBytes,
        pressureWindowSeconds: TimeInterval = pressureWindowSeconds
    ) -> Bool {
        if LocalBrainTranslationTier.pressureDeferral(
            reading, windowSeconds: pressureWindowSeconds) != nil {
            return true
        }
        // No fresh kernel signal — the app's own account still decides
        // when it cannot even host a turn's spikes. On a healthy device
        // `available` is the multi-GB ceiling estimate and this never
        // engages; at ~30 MB free it always does.
        return availableProcessMemoryBytes < marginBytes
    }

    /// [VOICE-OOM] Whether the pick has decided this brain must NOT load
    /// right now — the shared predicate the fit filter and the load-site
    /// terminal gate in `LlamaCommandInterpreter.loadLLMHandle` both use,
    /// so the two can never disagree about the same turn.
    static func pressureRefusesLoad(
        reading: MemoryPressureReading,
        availableProcessMemoryBytes: UInt64,
        liveBytes: UInt64,
        marginBytes: UInt64 = safetyMarginBytes,
        pressureWindowSeconds: TimeInterval = pressureWindowSeconds
    ) -> Bool {
        guard pressureEngages(
            reading: reading,
            availableProcessMemoryBytes: availableProcessMemoryBytes,
            marginBytes: marginBytes,
            pressureWindowSeconds: pressureWindowSeconds) else { return false }
        return availableProcessMemoryBytes < liveBytes + marginBytes
    }

    /// The pick for one turn. Pure.
    ///
    /// - `rememberedPick` is the model the app would run with no pressure
    ///   (`AppCoordinator.resolvedBrainModelID` — the stored preference or
    ///   the automatic pick).
    /// - `installedModelIDs` is the on-disk set; a candidate outside it is
    ///   invisible (never downloaded, never invented).
    static func resolve(
        reading: MemoryPressureReading,
        availableProcessMemoryBytes: UInt64,
        language: String,
        rememberedPick: ModelID,
        installedModelIDs: Set<ModelID>,
        liveBytes: (ModelID) -> UInt64 = {
            ModelLifecycleInventory.footprint(for: .brain, modelID: $0).liveBytes
        },
        marginBytes: UInt64 = safetyMarginBytes,
        pressureWindowSeconds: TimeInterval = pressureWindowSeconds
    ) -> PressureBrainPick {
        guard pressureEngages(
            reading: reading,
            availableProcessMemoryBytes: availableProcessMemoryBytes,
            marginBytes: marginBytes,
            pressureWindowSeconds: pressureWindowSeconds) else { return .keep }

        let cap = liveBytes(rememberedPick)

        // The remembered pick leads — the current choice is never
        // displaced by an equal-size sibling.
        var candidates: [ModelCatalogEntry] = []
        if let rememberedEntry = ModelCatalog.entry(for: rememberedPick) {
            candidates.append(rememberedEntry)
        }
        candidates.append(contentsOf: ModelCatalog.curatedEntries(kind: .llamaBase)
            .filter { $0.id != rememberedPick }
            .filter { installedModelIDs.contains($0.id) }
            .filter { LanguageModelResolver.isLanguageCompatible($0, language: language) })

        let fitting = candidates
            .filter { installedModelIDs.contains($0.id) }
            .filter { entry in
                let live = liveBytes(entry.id)
                guard live <= cap else { return false } // never up
                return !pressureRefusesLoad(
                    reading: reading,
                    availableProcessMemoryBytes: availableProcessMemoryBytes,
                    liveBytes: live,
                    marginBytes: marginBytes,
                    pressureWindowSeconds: pressureWindowSeconds)
            }
        guard let best = fitting.max(by: { liveBytes($0.id) < liveBytes($1.id) }) else {
            return .lightweight
        }
        return best.id == rememberedPick ? .keep : .stepDown(best.id)
    }
}

// MARK: - The degraded-mode status (F, 2026-10-10)

/// What the main screen's degraded-mode pill shows for the turn in force.
/// Published by the coordinator each turn; `.normal` hides the pill.
enum DegradedVoiceMode: Equatable {
    /// The remembered pick ran (or no pressure) — nothing to show.
    case normal
    /// A smaller brain ran under pressure — "Simple mode — low memory".
    case smallerBrain
    /// No brain could run; the deterministic reply path answered —
    /// "Simple answer — low memory".
    case lightweight

    /// The mode one turn's pick resolves to — pure, so the transitions
    /// (normal -> smallerBrain -> normal recovery; smallerBrain ->
    /// lightweight) are pinned without a coordinator or a view.
    static func resolved(from pick: PressureBrainPick) -> DegradedVoiceMode {
        switch pick {
        case .keep: return .normal
        case .stepDown: return .smallerBrain
        case .lightweight: return .lightweight
        }
    }

    /// The catalog key for the pill's caption, or nil when the mode shows
    /// nothing. UI copy lives in `Localizable.xcstrings`
    /// (`home.degradedMode.*`), localized ne/en like every other string.
    var copyKey: String? {
        switch self {
        case .normal: return nil
        case .smallerBrain: return "home.degradedMode.smallerBrain"
        case .lightweight: return "home.degradedMode.lightweight"
        }
    }

    /// The pill's caption resolved for `locale` — nil for `.normal`, so
    /// the view renders the CURRENT state only and nothing at rest.
    func pillText(locale: Locale) -> String? {
        copyKey.map { L10n.str($0, locale: locale) }
    }
}
