import XCTest
@testable import ElderlyAssistant

/// Pure pressure-tiered brain pick tests ([VOICE-OOM] B', 2026-10-10):
/// the tier walk from the hardening brief, the installed-only /
/// no-download / never-up guarantees, the language gate, the pressure
/// freshness doctrine, the shared load-refusal predicate, and the
/// degraded-mode state (F) that drives Home's status pill — all without a
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
}
