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

// MARK: - The pick latch ([PICK-HYSTERESIS], 2026-10-14)

/// [PICK-HYSTERESIS] The hysteresis latch that sits between the raw
/// per-turn pick and the model swap: a raw change must REPEAT for
/// several consecutive turns before it flips what actually runs.
///
/// The audit's finding 3C/15 (`docs/native-responsiveness-audit.md`)
/// named the hole: `PressureBrainPickResolver.resolve` is consulted
/// EVERY turn against a fresh sample, and a device oscillating around
/// the fit margin — the headroom half of `pressureEngages` reads the
/// raw probe with no freshness requirement — can therefore alternate
/// 4B→1B→4B, each swap an unload plus a next-turn full page-in (~3.4 GB,
/// ~10 s for the 4B; the 1B ≈ 4.8 s — `ModelCostModel`). The load-rate
/// thrash guard covers load RATE, not swap rate, and `switchBaseModel`
/// bypasses it entirely, so nothing between the resolver and the swap
/// brakes.
///
/// The measurement this latch exists for, and the owner's ruling that
/// made it the top priority (2026-10-14): the field console on the
/// iPhone 17 Pro Max showed the device AT its ceiling — `liveBytes`
/// 4.49 GB against the 3.54 GB class budget — with the whisper weights
/// released mid-turn for "ram_headroom", and the owner reads the
/// eviction ping-pong as "the most likely instability source" for the
/// jumbled STT episodes seen under load.
///
/// ### The asymmetry, and why
///
/// DOWN is fast (2 consecutive pressurized turns), UP is slow (4
/// consecutive clean turns), and M > N is the point:
///
///  - A late step-down is bounded. The load-site terminal gate
///    (`PressureBrainPickResolver.pressureRefusesLoad` in
///    `LlamaCommandInterpreter.loadLLMHandle`) refuses a load that
///    cannot clear the margin and the router's deterministic reply
///    answers — the audit's own trade, verbatim: "a latched 1B for one
///    extra turn under real pressure is the intended behavior." N = 2 is
///    the smallest N that is a latch at all; N = 1 is the per-turn
///    behavior this change replaces.
///  - A premature RECOVER is what the ping-pong spends: it pages the
///    big model back in at ~10 s AND re-arms the next eviction. Four
///    consecutive clean samples is the evidence bar that headroom has
///    actually returned — on a conversational cadence that is minutes of
///    sustained headroom, not a blip between two warnings.
///
/// ### Why turns, not seconds
///
/// The cost this prevents is paid in TURNS — a swap's page-in lands on
/// the next turn — and the pick is only ever asked per turn
/// (`recordTranscript` → `applyPressureBrainPickForTurn`). A wall-clock
/// window would add a second, invisible clock (and a timer) to a seam
/// whose only events are turns; consecutive samples are the same
/// evidence with no clock to drift. The thresholds are fields with
/// defaults, so retuning them is a one-line change, not a rewrite.
///
/// ### In-memory only, and the two re-baselines
///
/// The latch is per-process state — a `var` on the coordinator, never
/// persisted. The degraded tier is a property of THIS process's pressure
/// history: a relaunch has none, and a latch restored from disk would
/// hold a step-down against evidence that could be hours stale. On a
/// fresh process the first decision therefore ADOPTS the raw pick (there
/// is no prior state to protect, the boot warm has loaded the remembered
/// pick, and turn one behaves exactly as it does today); the latch's
/// guarantee begins with the second turn.
///
/// A change of the remembered pick — Settings, or the automatic
/// resolution changing under it — also re-baselines (adopt raw, clear
/// both streaks): an explicit pick outranks hysteresis the same way it
/// outranks the language table (`AppCoordinator.resolveBrainModelID`
/// rule 1), and streaks counted against a different remembered pick
/// would be arithmetic about a model nobody chose.
///
/// ### What a streak is
///
/// Streaks compare the picks' live-byte ranks — `.keep` ranks at the
/// remembered pick's live bytes, `.stepDown` at its own, `.lightweight`
/// at zero, the same currency the resolver's never-up rule spends. A raw
/// pick that ranks strictly BELOW the latched pick is a degrade sample;
/// any other disagreement (up, or a lateral equal-byte swap the
/// resolver's own rules make unreachable) is a recover sample — the
/// latch never moves faster than the recover threshold except DOWN. A
/// turn whose raw pick EQUALS the latched pick clears both streaks,
/// which is the hysteresis itself: an alternating signal — the
/// margin-oscillation case — accumulates neither streak and therefore
/// never flips at all.
///
/// One deliberate consequence, stated: a latched `stepDown` id deleted
/// from the store mid-session self-heals through these same rules — the
/// resolver can no longer produce it, so the walk's next candidate
/// (smaller, equal, or nothing at all) accumulates its own streak and
/// the latch leaves the deleted id within max(N, M) turns.
struct PressureBrainPickLatch: Equatable {

    /// [PICK-HYSTERESIS] Consecutive pressurized turns needed before the
    /// latch steps DOWN. 2 is the smallest N that is a latch at all, and
    /// the extra turn it buys costs at most one deterministic reply (the
    /// load-site terminal gate refuses a load that cannot clear the
    /// margin — never an OOM).
    static let defaultDegradeTurns = 2

    /// [PICK-HYSTERESIS] Consecutive clean turns needed before the latch
    /// steps back UP. 4 is the anti-ping-pong number: a single clean
    /// sample between two pressurized ones must never pay the ~3.4 GB
    /// page-in back, and four consecutive samples on a conversational
    /// cadence is minutes of sustained headroom. M > N is the point
    /// (pinned by a test).
    static let defaultRecoverTurns = 4

    /// The thresholds, as fields with defaults — a configurable surface
    /// in the same sense `ModelBudgetPolicy`'s numbers are.
    let degradeTurns: Int
    let recoverTurns: Int

    /// The pick currently in force — what the coordinator applied and
    /// what `DegradedVoiceMode` describes. `.keep` until a first
    /// decision; the first decision re-baselines anyway.
    private(set) var latchedPick: PressureBrainPick = .keep

    /// The remembered pick the latch was last re-baselined against, `nil`
    /// before the first decision — a change is an explicit act, and it
    /// re-baselines rather than counting against the old baseline.
    private(set) var latchedRememberedPick: ModelID?

    /// Consecutive turns whose raw pick ranked strictly below the
    /// latched pick. Reaching `degradeTurns` flips; any other turn's
    /// outcome clears it (consecutive is the word that makes this
    /// hysteresis).
    private(set) var degradeStreak = 0

    /// Consecutive turns whose raw pick disagreed without ranking below.
    /// Reaching `recoverTurns` flips; cleared like `degradeStreak`.
    private(set) var recoverStreak = 0

    init(degradeTurns: Int = PressureBrainPickLatch.defaultDegradeTurns,
         recoverTurns: Int = PressureBrainPickLatch.defaultRecoverTurns) {
        self.degradeTurns = degradeTurns
        self.recoverTurns = recoverTurns
    }

    /// One turn's latched pick — the pick the coordinator should run.
    ///
    /// - `raw` is `PressureBrainPickResolver.resolve`'s answer for this
    ///   turn: a sample, not a decision, until it repeats.
    /// - `rememberedPick` is the pick the household would run with no
    ///   pressure; a change from the last decision re-baselines.
    /// - `liveBytes` prices the picks for the down/up comparison — the
    ///   same injected default the resolver takes, so the two can never
    ///   disagree about which model is smaller.
    mutating func decide(
        raw: PressureBrainPick,
        rememberedPick: ModelID,
        liveBytes: (ModelID) -> UInt64 = {
            ModelLifecycleInventory.footprint(for: .brain, modelID: $0).liveBytes
        }
    ) -> PressureBrainPick {
        // An explicit (re-)pick — first use, Settings, a changed
        // automatic resolution — re-baselines: adopt the raw pick
        // outright and clear the streaks. The household's choice
        // outranks hysteresis the same way it outranks the language
        // table.
        guard latchedRememberedPick == rememberedPick else {
            latchedRememberedPick = rememberedPick
            adopt(raw)
            return raw
        }

        // The turn agrees with what is in force — either the healthy
        // steady state or the latch's own hold. Either way it is not
        // evidence FOR a change, so both streaks clear.
        if raw == latchedPick {
            degradeStreak = 0
            recoverStreak = 0
            return latchedPick
        }

        let rawRank = Self.rank(of: raw,
                                rememberedPick: rememberedPick,
                                liveBytes: liveBytes)
        let latchedRank = Self.rank(of: latchedPick,
                                    rememberedPick: rememberedPick,
                                    liveBytes: liveBytes)

        if rawRank < latchedRank {
            degradeStreak += 1
            recoverStreak = 0
            if degradeStreak >= degradeTurns { adopt(raw) }
        } else {
            recoverStreak += 1
            degradeStreak = 0
            if recoverStreak >= recoverTurns { adopt(raw) }
        }
        return latchedPick
    }

    /// Adopts `pick` as the state in force and zeroes both streaks — the
    /// streak that produced the flip is spent, and the other direction
    /// starts counting fresh.
    private mutating func adopt(_ pick: PressureBrainPick) {
        latchedPick = pick
        degradeStreak = 0
        recoverStreak = 0
    }

    /// The live-byte rank a pick occupies: `.keep` at the remembered
    /// pick's live bytes, `.stepDown` at its own, `.lightweight` at zero
    /// (nothing loads). Pure, so the ordering the streaks compare
    /// against is pinned without a latch.
    static func rank(of pick: PressureBrainPick,
                     rememberedPick: ModelID,
                     liveBytes: (ModelID) -> UInt64) -> UInt64 {
        switch pick {
        case .keep: return liveBytes(rememberedPick)
        case .stepDown(let id): return liveBytes(id)
        case .lightweight: return 0
        }
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
