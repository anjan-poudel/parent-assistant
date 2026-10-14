import XCTest
@testable import ElderlyAssistant

/// Pure pressure-tiered brain pick tests ([VOICE-OOM] B', 2026-10-10):
/// the tier walk from the hardening brief, the installed-only /
/// no-download / never-up guarantees, the language gate, the pressure
/// freshness doctrine, the shared load-refusal predicate, the
/// degraded-mode state (F) that drives Home's status pill, and the
/// [PICK-HYSTERESIS] latch (2026-10-14) that holds a raw per-turn sample
/// to a consecutive-turn streak before it flips the pick — all without a
/// device, a store, or a ledger (the walk is a pure function of values).
final class PressureBrainPickTests: XCTestCase {

    // MARK: - Fixtures

    /// The live-bytes table the walk is tested against. Deliberately
    /// injected (the resolver takes `liveBytes` as a parameter) so the
    /// arithmetic is pinned by numbers and not by the inventory's
    /// internals; the production default is exercised separately
    /// (`testProductionDefaultsUseTheInventoryFootprints`).
    private func live(_ id: ModelID) -> UInt64 {
        switch id {
        case ModelCatalog.intentQwen4BSlotCanon: return 3_400_000_000
        case ModelCatalog.qwen4BNepali: return 3_400_000_000
        case ModelCatalog.qwen3_4BInstruct: return 3_400_000_000
        case ModelCatalog.intentQwenS43: return 1_807_000_000
        case ModelCatalog.qwen3_1_7BInstruct: return 1_980_000_000
        case ModelCatalog.intentGemma1B: return 1_314_000_000
        default: return 0
        }
    }

    private let normal = MemoryPressureReading(
        level: .normal, secondsSinceCritical: nil, secondsSinceWarning: nil)
    private let freshWarning = MemoryPressureReading(
        level: .warning, secondsSinceCritical: nil, secondsSinceWarning: 5)
    private let staleWarning = MemoryPressureReading(
        level: .warning, secondsSinceCritical: nil, secondsSinceWarning: 120)
    private let freshCritical = MemoryPressureReading(
        level: .critical, secondsSinceCritical: 2, secondsSinceWarning: nil)
    private let recentCriticalUnderNormal = MemoryPressureReading(
        level: .normal, secondsSinceCritical: 10, secondsSinceWarning: nil)

    private func resolve(reading: MemoryPressureReading,
                         available: UInt64,
                         language: String,
                         remembered: ModelID,
                         installed: Set<ModelID>) -> PressureBrainPick {
        PressureBrainPickResolver.resolve(
            reading: reading,
            availableProcessMemoryBytes: available,
            language: language,
            rememberedPick: remembered,
            installedModelIDs: installed,
            liveBytes: live)
    }

    // MARK: - Tier walk

    /// Normal pressure → the remembered/explicit pick runs unchanged, even
    /// when the probe looks tight. The explicit pick's over-budget
    /// admission (`soloOverBudget`) is the shipped contract on healthy
    /// days and this change must not alter it.
    func testNormalPressureKeepsTheExplicitPick() {
        let pick = resolve(reading: normal,
                           available: 2_000_000_000,
                           language: "ne",
                           remembered: ModelCatalog.intentQwen4BSlotCanon,
                           installed: [ModelCatalog.intentQwen4BSlotCanon,
                                       ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .keep)
    }

    /// A fresh warning does NOT itself force a step-down: the remembered
    /// pick stays when IT fits under the margin (4B live 3.4 GB + 768 MB
    /// <= 4.5 GB available).
    func testFreshWarningKeepsTheRememberedPickWhenItFits() {
        let pick = resolve(reading: freshWarning,
                           available: 4_500_000_000,
                           language: "ne",
                           remembered: ModelCatalog.intentQwen4BSlotCanon,
                           installed: [ModelCatalog.intentQwen4BSlotCanon])
        XCTAssertEqual(pick, .keep)
    }

    /// Warn + 3.0 GB free: the 4B (3.4 GB + 768 MB) does not fit; the
    /// 1.7B (1.98 GB + 768 MB) does — the largest installed brain that
    /// fits is chosen.
    func testFreshWarningStepsDownToTheLargestInstalledBrainThatFits() {
        let pick = resolve(reading: freshWarning,
                           available: 3_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [ModelCatalog.qwen3_4BInstruct,
                                       ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .stepDown(ModelCatalog.qwen3_1_7BInstruct))
    }

    /// Warn + 2.0 GB free: even the 1.7B (2.748 GB required) does not fit
    /// — nothing fits, the deterministic path answers.
    func testFreshWarningOnATighterCeilingFallsToLightweight() {
        let pick = resolve(reading: freshWarning,
                           available: 2_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [ModelCatalog.qwen3_4BInstruct,
                                       ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .lightweight)
    }

    /// The field device's death: critical pressure, ~30 MB free. Nothing
    /// fits — the pick is lightweight, the terminal case where the
    /// brief's original refusal survives.
    func testCriticalWithTinyFreeMemoryFallsToLightweight() {
        let pick = resolve(reading: freshCritical,
                           available: 30_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [ModelCatalog.qwen3_4BInstruct,
                                       ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .lightweight)
    }

    /// A catastrophically low probe engages the arithmetic by itself —
    /// even with a normal level and no ages (the stale/latched half of
    /// the manager's reading can read normal while the app has nothing).
    func testCatastrophicallyLowProbeEngagesWithoutKernelSignal() {
        let pick = resolve(reading: normal,
                           available: 30_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [ModelCatalog.qwen3_4BInstruct,
                                       ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .lightweight)
    }

    // MARK: - Pressure freshness doctrine (reused from the latch)

    /// A warning older than the window ages out (the manager's level can
    /// latch on the UIKit route, where nothing ever clears it) — the
    /// remembered pick runs. If the stale level were honored, this input
    /// would step down to the 1.7B or lightweight (both fail the fit at
    /// 2.0 GB), so `.keep` pins the escape.
    func testStaleWarningAgesOutAndKeepsTheRememberedPick() {
        let pick = resolve(reading: staleWarning,
                           available: 2_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [ModelCatalog.qwen3_4BInstruct,
                                       ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .keep)
    }

    /// A recent critical counts even after the level reads normal again —
    /// the same doctrine `LocalBrainDeferral.pressureDeferral` encodes.
    func testRecentCriticalUnderNormalLevelStillTiersTheTurn() {
        let pick = resolve(reading: recentCriticalUnderNormal,
                           available: 3_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [ModelCatalog.qwen3_4BInstruct,
                                       ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .stepDown(ModelCatalog.qwen3_1_7BInstruct))
    }

    // MARK: - Installed-only / no-download / never-up

    /// A fitting brain that is NOT installed is invisible: the pick falls
    /// to lightweight rather than naming a model that would have to be
    /// downloaded mid-pressure.
    func testInstalledOnlyNeverChoosesAnUninstalledBrain() {
        let pick = resolve(reading: freshWarning,
                           available: 3_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [ModelCatalog.qwen3_4BInstruct])
        XCTAssertEqual(pick, .lightweight,
                       "the 1.7B fits the arithmetic but is not on disk — never downloaded under pressure")
    }

    /// Nothing installed at all: the pick refuses to invent a model.
    func testPressureNeverDownloadsWhenNothingIsInstalled() {
        let pick = resolve(reading: freshWarning,
                           available: 3_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_4BInstruct,
                           installed: [])
        XCTAssertEqual(pick, .lightweight)
    }

    /// The candidate pool is the CURATED list (the same pool the Settings
    /// picker offers): a hidden artifact (installed, small enough to fit)
    /// can never be picked by pressure.
    func testHiddenArtifactsAreNeverPickedByPressure() {
        let pick = resolve(reading: freshWarning,
                           available: 2_300_000_000, // gemma live 1.314 + 768 MB fits
                           language: "ne",
                           remembered: ModelCatalog.intentQwen4BSlotCanon,
                           installed: [ModelCatalog.intentQwen4BSlotCanon,
                                       ModelCatalog.intentGemma1B])
        XCTAssertEqual(pick, .lightweight,
                       "intentGemma1B is hidden from the picker and must stay hidden from the pressure walk")
    }

    /// Pressure never UPGRADES: a bigger installed brain that fits the
    /// arithmetic is still excluded by the remembered pick's live-bytes
    /// cap — the remembered pick itself fits, so the answer is `.keep`.
    /// (Without the cap the answer would be `.stepDown(qwen3_4BInstruct)`.)
    func testNeverStepsUpABiggerInstalledBrain() {
        let pick = resolve(reading: freshWarning,
                           available: 5_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.qwen3_1_7BInstruct,
                           installed: [ModelCatalog.qwen3_1_7BInstruct,
                                       ModelCatalog.qwen3_4BInstruct])
        XCTAssertEqual(pick, .keep)
    }

    /// Equal live bytes: the remembered pick LEADS the candidate list, so
    /// the tie keeps the household's pick (`max(by:)` keeps the first of
    /// equal sizes) instead of an equal-size sibling.
    func testRememberedPickLeadsTheTie() {
        let pick = resolve(reading: freshWarning,
                           available: 4_500_000_000, // both 4B entries fit (3.4 + 768 MB)
                           language: "ne",
                           remembered: ModelCatalog.qwen4BNepali,
                           installed: [ModelCatalog.qwen4BNepali,
                                       ModelCatalog.intentQwen4BSlotCanon])
        XCTAssertEqual(pick, .keep,
                       "an equal-size sibling must never displace the remembered pick")
    }

    // MARK: - Language gate

    /// An installed Nepali-only brain is never chosen for an English
    /// household (and vice versa), while a language-neutral brain always
    /// competes.
    func testLanguageGateExcludesOtherLanguageBrains() {
        let installed: Set<ModelID> = [ModelCatalog.qwen3_4BInstruct,
                                       ModelCatalog.intentQwenS43]

        let english = resolve(reading: freshWarning,
                              available: 3_000_000_000,
                              language: "en",
                              remembered: ModelCatalog.qwen3_4BInstruct,
                              installed: installed)
        XCTAssertEqual(english, .lightweight,
                       "intentQwenS43 is ne-only — invisible to an en household")

        let nepali = resolve(reading: freshWarning,
                             available: 3_000_000_000,
                             language: "ne",
                             remembered: ModelCatalog.qwen3_4BInstruct,
                             installed: installed)
        XCTAssertEqual(nepali, .stepDown(ModelCatalog.intentQwenS43),
                       "the same brain is the step-down for the language it serves")
    }

    /// The REMEMBERED pick bypasses the language gate — an explicit pick
    /// outranks the language table (the same rule
    /// `AppCoordinator.resolveBrainModelID` rule 1 states).
    func testExplicitRememberedPickBypassesTheLanguageGate() {
        let pick = resolve(reading: freshWarning,
                           available: 3_000_000_000,
                           language: "en",
                           remembered: ModelCatalog.intentQwenS43,
                           installed: [ModelCatalog.intentQwenS43])
        XCTAssertEqual(pick, .keep)
    }

    // MARK: - The shared load-refusal predicate

    /// `pressureRefusesLoad` is the load-site half of the same arithmetic;
    /// the coordinator's pick and the interpreter's terminal gate must
    /// never disagree about a turn.
    func testPressureRefusesLoadMatrix() {
        // Normal pressure, healthy ceiling — never refuses (the shipped
        // over-budget admission still applies).
        XCTAssertFalse(PressureBrainPickResolver.pressureRefusesLoad(
            reading: normal,
            availableProcessMemoryBytes: 2_000_000_000,
            liveBytes: 3_400_000_000))
        // Normal pressure, catastrophic ceiling — refuses (the stale-half
        // guard).
        XCTAssertTrue(PressureBrainPickResolver.pressureRefusesLoad(
            reading: normal,
            availableProcessMemoryBytes: 30_000_000,
            liveBytes: 3_400_000_000))
        // Fresh warning, 4.0 GB free vs 3.4 + 0.768 needed — refuses.
        XCTAssertTrue(PressureBrainPickResolver.pressureRefusesLoad(
            reading: freshWarning,
            availableProcessMemoryBytes: 4_000_000_000,
            liveBytes: 3_400_000_000))
        // Fresh warning, 4.2 GB free — admits.
        XCTAssertFalse(PressureBrainPickResolver.pressureRefusesLoad(
            reading: freshWarning,
            availableProcessMemoryBytes: 4_200_000_000,
            liveBytes: 3_400_000_000))
        // A stale warning is not evidence; 1.5 GB free is above the
        // margin, so the ledger's own admission stands.
        XCTAssertFalse(PressureBrainPickResolver.pressureRefusesLoad(
            reading: staleWarning,
            availableProcessMemoryBytes: 1_500_000_000,
            liveBytes: 3_400_000_000))
    }

    // MARK: - Production defaults (inventory wiring)

    /// The default `liveBytes` closure reads the model-lifecycle
    /// inventory: the 4B must price above the 1.7B there, and a
    /// starved probe must resolve to lightweight with the REAL numbers.
    func testProductionDefaultsUseTheInventoryFootprints() {
        let fourB = ModelLifecycleInventory.footprint(
            for: .brain, modelID: ModelCatalog.intentQwen4BSlotCanon).liveBytes
        let oneSevenB = ModelLifecycleInventory.footprint(
            for: .brain, modelID: ModelCatalog.qwen3_1_7BInstruct).liveBytes
        XCTAssertGreaterThan(fourB, oneSevenB,
                             "the real inventory must price the 4B above the 1.7B")

        let pick = PressureBrainPickResolver.resolve(
            reading: freshCritical,
            availableProcessMemoryBytes: 30_000_000,
            language: "en",
            rememberedPick: ModelCatalog.qwen3_4BInstruct,
            installedModelIDs: [ModelCatalog.qwen3_4BInstruct,
                                ModelCatalog.qwen3_1_7BInstruct])
        XCTAssertEqual(pick, .lightweight,
                       "with the real inventory numbers nothing fits 30 MB free")
    }

    // MARK: - Degraded-mode state (F)

    func testDegradedModeResolvesFromPick() {
        XCTAssertEqual(DegradedVoiceMode.resolved(from: .keep), .normal)
        XCTAssertEqual(DegradedVoiceMode.resolved(
            from: .stepDown(ModelCatalog.qwen3_1_7BInstruct)), .smallerBrain)
        XCTAssertEqual(DegradedVoiceMode.resolved(from: .lightweight), .lightweight)
    }

    /// normal -> smallerBrain -> (still smallerBrain) -> normal recovery:
    /// the pill follows the CURRENT pick only, with no timers and no
    /// history.
    func testDegradedModeTransitionsThroughDegradationAndRecovery() {
        let stepDown = PressureBrainPick.stepDown(ModelCatalog.qwen3_1_7BInstruct)
        let modes = [PressureBrainPick.keep, stepDown, stepDown, .keep]
            .map(DegradedVoiceMode.resolved(from:))
        XCTAssertEqual(modes, [.normal, .smallerBrain, .smallerBrain, .normal])
    }

    func testDegradedModeStepsFromSmallerBrainToLightweight() {
        let stepDown = PressureBrainPick.stepDown(ModelCatalog.qwen3_1_7BInstruct)
        let modes = [stepDown, .lightweight, stepDown]
            .map(DegradedVoiceMode.resolved(from:))
        XCTAssertEqual(modes, [.smallerBrain, .lightweight, .smallerBrain])
    }

    func testDegradedModePillCopyResolvesInBothLanguages() {
        let ne = Locale(identifier: "ne-NP")
        let en = Locale(identifier: "en-US")

        XCTAssertEqual(DegradedVoiceMode.smallerBrain.pillText(locale: en),
                       "Simple mode — low memory")
        XCTAssertEqual(DegradedVoiceMode.smallerBrain.pillText(locale: ne),
                       "सरल मोड — कम मेमोरी")
        XCTAssertEqual(DegradedVoiceMode.lightweight.pillText(locale: en),
                       "Simple answer — low memory")
        XCTAssertEqual(DegradedVoiceMode.lightweight.pillText(locale: ne),
                       "सरल जवाफ — कम मेमोरी")
        XCTAssertNil(DegradedVoiceMode.normal.pillText(locale: en),
                     "the normal mode renders nothing — the pill hides itself")
        XCTAssertNil(DegradedVoiceMode.normal.pillText(locale: ne))
    }

    func testDegradedModeCopyKeysMatchTheCatalogEntries() {
        XCTAssertEqual(DegradedVoiceMode.normal.copyKey, nil)
        XCTAssertEqual(DegradedVoiceMode.smallerBrain.copyKey,
                       "home.degradedMode.smallerBrain")
        XCTAssertEqual(DegradedVoiceMode.lightweight.copyKey,
                       "home.degradedMode.lightweight")
    }

    // MARK: - The pick latch ([PICK-HYSTERESIS], 2026-10-14)

    private let fourB = ModelCatalog.qwen3_4BInstruct
    private let oneSevenB = ModelCatalog.qwen3_1_7BInstruct
    private let oneB = ModelCatalog.intentGemma1B

    /// One turn's RAW pick, resolved for real — the latch tests feed a
    /// streak the same samples production feeds it (only the deliberate
    /// hand-built cases construct enums directly, and say so).
    private func rawPick(reading: MemoryPressureReading,
                         available: UInt64,
                         language: String = "en",
                         remembered: ModelID,
                         installed: Set<ModelID>) -> PressureBrainPick {
        PressureBrainPickResolver.resolve(
            reading: reading,
            availableProcessMemoryBytes: available,
            language: language,
            rememberedPick: remembered,
            installedModelIDs: installed,
            liveBytes: live)
    }

    /// Feeds a latch one turn per entry and returns what actually ran.
    private func drive(_ latch: inout PressureBrainPickLatch,
                       raws: [PressureBrainPick],
                       remembered: ModelID) -> [PressureBrainPick] {
        var picks: [PressureBrainPick] = []
        for raw in raws {
            picks.append(latch.decide(raw: raw,
                                      rememberedPick: remembered,
                                      liveBytes: live))
        }
        return picks
    }

    /// Feeds a latch one turn per (reading, available) sample — each raw
    /// pick resolved for real — and returns what actually ran.
    private func driveResolved(_ latch: inout PressureBrainPickLatch,
                               samples: [(MemoryPressureReading, UInt64)],
                               remembered: ModelID,
                               language: String = "en",
                               installed: Set<ModelID>) -> [PressureBrainPick] {
        var picks: [PressureBrainPick] = []
        for (reading, available) in samples {
            let raw = rawPick(reading: reading,
                              available: available,
                              language: language,
                              remembered: remembered,
                              installed: installed)
            picks.append(latch.decide(raw: raw,
                                      rememberedPick: remembered,
                                      liveBytes: live))
        }
        return picks
    }

    /// The shipped thresholds, and the asymmetry that is the whole point:
    /// recovery must demand strictly more evidence than degradation.
    func testLatchThresholdsAreAsymmetricWithShippedDefaults() {
        XCTAssertEqual(PressureBrainPickLatch.defaultDegradeTurns, 2)
        XCTAssertEqual(PressureBrainPickLatch.defaultRecoverTurns, 4)
        XCTAssertGreaterThan(PressureBrainPickLatch.defaultRecoverTurns,
                             PressureBrainPickLatch.defaultDegradeTurns)
    }

    /// The live-byte rank the streaks compare: lightweight below every
    /// step-down, every step-down below `.keep` (which ranks at the
    /// remembered pick's own bytes).
    func testPickRankOrdersLightweightBelowStepDownBelowKeep() {
        XCTAssertEqual(PressureBrainPickLatch.rank(
            of: .keep, rememberedPick: fourB, liveBytes: live), 3_400_000_000)
        XCTAssertEqual(PressureBrainPickLatch.rank(
            of: .stepDown(oneSevenB), rememberedPick: fourB, liveBytes: live),
            1_980_000_000)
        XCTAssertEqual(PressureBrainPickLatch.rank(
            of: .lightweight, rememberedPick: fourB, liveBytes: live), 0)
    }

    /// A fresh process has no history to protect: the first decision
    /// adopts the raw pick (turn one behaves exactly as it does today),
    /// and the latch's guarantee begins with turn two — one clean sample
    /// is not a recovery.
    func testFreshLatchAdoptsRawOnFirstDecisionThenHolds() {
        var latch = PressureBrainPickLatch()
        let adopted = latch.decide(raw: .stepDown(oneSevenB),
                                   rememberedPick: fourB,
                                   liveBytes: live)
        XCTAssertEqual(adopted, .stepDown(oneSevenB))
        XCTAssertEqual(latch.latchedPick, .stepDown(oneSevenB))
        XCTAssertEqual(latch.latchedRememberedPick, fourB)

        let held = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)
        XCTAssertEqual(held, .stepDown(oneSevenB))
        XCTAssertEqual(latch.recoverStreak, 1)
    }

    /// THE field case (the 2026-10-14 console): one transient pressurized
    /// sample must NOT flip the pick — and a following clean one clears
    /// the evidence entirely.
    func testASinglePressurizedSampleDoesNotFlipThePick() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)

        let one = drive(&latch, raws: [.stepDown(oneSevenB)], remembered: fourB)
        XCTAssertEqual(one, [.keep],
                       "one pressured sample is not enough evidence to unload a model")
        XCTAssertEqual(latch.degradeStreak, 1)

        let cleared = drive(&latch, raws: [.keep, .stepDown(oneSevenB)], remembered: fourB)
        XCTAssertEqual(cleared, [.keep, .keep],
                       "the clean turn resets the streak — the next sample counts from one again")
        XCTAssertEqual(latch.degradeStreak, 1)
    }

    /// Degrade-after-N: the flip lands on the second consecutive
    /// pressurized turn, and the flip spends the streak.
    func testDegradeFlipsOnTheSecondConsecutivePressurizedTurn() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)

        let picks = drive(&latch,
                          raws: [.stepDown(oneSevenB), .stepDown(oneSevenB)],
                          remembered: fourB)
        XCTAssertEqual(picks, [.keep, .stepDown(oneSevenB)])
        XCTAssertEqual(latch.latchedPick, .stepDown(oneSevenB))
        XCTAssertEqual(latch.degradeStreak, 0)
        XCTAssertEqual(latch.recoverStreak, 0)
    }

    /// The margin-oscillation case the audit named: an alternating signal
    /// accumulates neither streak and therefore never flips at all.
    func testAnAlternatingSignalNeverFlipsThePick() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)

        let picks = drive(&latch,
                          raws: [.stepDown(oneSevenB), .keep,
                                 .stepDown(oneSevenB), .keep,
                                 .stepDown(oneSevenB), .keep],
                          remembered: fourB)
        XCTAssertEqual(picks, Array(repeating: PressureBrainPick.keep, count: 6))
        XCTAssertEqual(latch.degradeStreak, 0)
        XCTAssertEqual(latch.recoverStreak, 0)
    }

    /// Recover-after-M (M > N): a degraded latch comes back only on the
    /// fourth consecutive clean turn.
    func testRecoverFlipsOnlyOnTheFourthConsecutiveCleanTurn() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)
        _ = drive(&latch,
                  raws: [.stepDown(oneSevenB), .stepDown(oneSevenB)],
                  remembered: fourB)
        XCTAssertEqual(latch.latchedPick, .stepDown(oneSevenB))

        let threeClean = drive(&latch, raws: [.keep, .keep, .keep], remembered: fourB)
        XCTAssertEqual(threeClean,
                       Array(repeating: PressureBrainPick.stepDown(oneSevenB), count: 3),
                       "recovery waits for M — k < M clean turns change nothing")
        XCTAssertEqual(latch.recoverStreak, 3)

        let fourthClean = drive(&latch, raws: [.keep], remembered: fourB)
        XCTAssertEqual(fourthClean, [.keep])
        XCTAssertEqual(latch.latchedPick, .keep)
        XCTAssertEqual(latch.recoverStreak, 0)
    }

    /// Counter reset: an interruption mid-recovery clears the streak —
    /// the evidence is only worth what it is consecutive.
    func testAnInterveningSqueezeResetsTheRecoverStreak() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)
        _ = drive(&latch,
                  raws: [.stepDown(oneSevenB), .stepDown(oneSevenB)],
                  remembered: fourB)

        let picks = drive(&latch,
                          raws: [.keep, .keep,
                                 .stepDown(oneB), // a deeper squeeze, not a clean turn
                                 .keep, .keep, .keep],
                          remembered: fourB)
        XCTAssertEqual(picks,
                       Array(repeating: PressureBrainPick.stepDown(oneSevenB),
                             count: 6))
        XCTAssertEqual(latch.recoverStreak, 3,
                       "three clean turns after the interruption is three, not five")
        XCTAssertEqual(latch.degradeStreak, 0)

        let seventh = drive(&latch, raws: [.keep], remembered: fourB)
        XCTAssertEqual(seventh, [.keep],
                       "the fourth CONSECUTIVE clean turn is the flip")
    }

    /// A deeper squeeze within the degraded tier is a DOWN move (N), and
    /// climbing back up within it is an UP move (M) — the ladder has one
    /// rule, whichever rungs it connects.
    func testDeeperStepDownAndPartialRecoveryEachUseTheirOwnStreak() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)
        _ = drive(&latch,
                  raws: [.stepDown(oneSevenB), .stepDown(oneSevenB)],
                  remembered: fourB)

        let deeper = drive(&latch,
                           raws: [.stepDown(oneB), .stepDown(oneB)],
                           remembered: fourB)
        XCTAssertEqual(deeper, [.stepDown(oneSevenB), .stepDown(oneB)])

        let climb = drive(&latch,
                          raws: Array(repeating: .stepDown(oneSevenB), count: 4),
                          remembered: fourB)
        XCTAssertEqual(climb, [.stepDown(oneB), .stepDown(oneB),
                               .stepDown(oneB), .stepDown(oneSevenB)])
    }

    /// The terminal rung obeys the same clock: nothing-fits degrades fast
    /// and is left slowly.
    func testTerminalLightweightDegradesFastAndRecoversSlow() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)

        let down = drive(&latch, raws: [.lightweight, .lightweight], remembered: fourB)
        XCTAssertEqual(down, [.keep, .lightweight])

        let up = drive(&latch,
                       raws: Array(repeating: .keep, count: 4),
                       remembered: fourB)
        XCTAssertEqual(up, [.lightweight, .lightweight,
                            .lightweight, .keep])
    }

    /// An explicit re-pick re-baselines the latch: the household's choice
    /// is adopted outright, streaks and all, instead of counting against
    /// a baseline nobody chose any more.
    func testRememberedPickChangeRebaselinesTheLatchImmediately() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)
        _ = drive(&latch,
                  raws: [.stepDown(oneSevenB), .stepDown(oneSevenB)],
                  remembered: fourB)
        XCTAssertEqual(latch.latchedPick, .stepDown(oneSevenB))

        let afterRepick = latch.decide(raw: .keep,
                                       rememberedPick: oneSevenB,
                                       liveBytes: live)
        XCTAssertEqual(afterRepick, .keep)
        XCTAssertEqual(latch.latchedRememberedPick, oneSevenB)
        XCTAssertEqual(latch.degradeStreak, 0)
        XCTAssertEqual(latch.recoverStreak, 0)

        // And the other direction: a re-pick back to the 4B under
        // pressure adopts the raw step-down on the spot.
        var second = PressureBrainPickLatch()
        _ = second.decide(raw: .keep, rememberedPick: oneSevenB, liveBytes: live)
        let adopted = second.decide(raw: .stepDown(oneSevenB),
                                    rememberedPick: fourB,
                                    liveBytes: live)
        XCTAssertEqual(adopted, .stepDown(oneSevenB))
        XCTAssertEqual(second.latchedPick, .stepDown(oneSevenB))
    }

    /// The fit boundary in exact bytes: refusal is strict
    /// (`available < live + margin`), so `available == live + margin`
    /// admits the 4B and one byte less steps down. A device hovering on
    /// that byte — the field console's case — flips the RAW pick every
    /// turn, and the latch holds every time.
    func testMarginOscillationAcrossTheExactFitBoundaryNeverFlips() {
        // 4B live 3.4 GB + margin 768 MB = 4.168 GB exactly.
        let fits: UInt64 = 4_168_000_000
        let refuses: UInt64 = 4_167_999_999
        let installed: Set<ModelID> = [fourB, oneSevenB]

        XCTAssertEqual(rawPick(reading: freshWarning, available: fits,
                               remembered: fourB, installed: installed),
                       .keep)
        XCTAssertEqual(rawPick(reading: freshWarning, available: refuses,
                               remembered: fourB, installed: installed),
                       .stepDown(oneSevenB),
                       "one byte under the fit line is a step-down sample")

        var latch = PressureBrainPickLatch()
        let picks = driveResolved(&latch,
                                  samples: [(freshWarning, fits),
                                            (freshWarning, refuses),
                                            (freshWarning, fits),
                                            (freshWarning, refuses),
                                            (freshWarning, fits),
                                            (freshWarning, refuses)],
                                  remembered: fourB,
                                  installed: installed)
        XCTAssertEqual(picks, Array(repeating: PressureBrainPick.keep, count: 6),
                       "the ping-pong needs two CONSECUTIVE samples; the hover never provides them")
    }

    /// Sustained pressure across the same boundary does flip — down on
    /// the second sample, back up only on the fourth sustained fit.
    func testSustainedPressureAcrossTheBoundaryFlipsDownThenUp() {
        let fits: UInt64 = 4_168_000_000
        let refuses: UInt64 = 4_167_999_999
        let installed: Set<ModelID> = [fourB, oneSevenB]
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)

        let down = driveResolved(&latch,
                                 samples: [(freshWarning, refuses),
                                           (freshWarning, refuses)],
                                 remembered: fourB,
                                 installed: installed)
        XCTAssertEqual(down, [.keep, .stepDown(oneSevenB)])

        let up = driveResolved(&latch,
                               samples: Array(repeating: (freshWarning, fits),
                                              count: 4),
                               remembered: fourB,
                               installed: installed)
        XCTAssertEqual(up, [.stepDown(oneSevenB), .stepDown(oneSevenB),
                            .stepDown(oneSevenB), .keep])
    }

    /// `pressureEngages`' own headroom boundary, exact: the
    /// catastrophic-probe half is strict too, so a probe exactly AT the
    /// margin with no kernel signal does not engage, and one byte under
    /// engages as nothing-fits at that headroom — which the latch still
    /// holds for its first turn.
    func testExactMarginByteDoesNotEngageAndOneByteUnderDoes() {
        let margin = PressureBrainPickResolver.safetyMarginBytes

        XCTAssertEqual(rawPick(reading: normal, available: margin,
                               remembered: fourB, installed: [fourB]),
                       .keep)
        XCTAssertEqual(rawPick(reading: normal, available: margin - 1,
                               remembered: fourB, installed: [fourB]),
                       .lightweight,
                       "engages by the app's own account, and at this headroom nothing fits")

        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)
        let picks = driveResolved(&latch,
                                  samples: [(normal, margin - 1),
                                            (normal, margin - 1)],
                                  remembered: fourB,
                                  installed: [fourB])
        XCTAssertEqual(picks, [.keep, .lightweight],
                       "even the terminal rung waits out the first sample")
    }

    /// The pill keeps its "current state only" meaning under the latch:
    /// a held turn renders the mode of the pick that RAN, the flip turn
    /// renders the new one, and a single clean sample does not flip the
    /// pill back.
    func testDegradedModeFollowsTheLatchedPickNotTheRawSample() {
        var latch = PressureBrainPickLatch()
        _ = latch.decide(raw: .keep, rememberedPick: fourB, liveBytes: live)

        let picks = drive(&latch,
                          raws: [.stepDown(oneSevenB),
                                 .stepDown(oneSevenB),
                                 .keep],
                          remembered: fourB)
        XCTAssertEqual(picks.map(DegradedVoiceMode.resolved(from:)),
                       [.normal, .smallerBrain, .smallerBrain])
    }
}
