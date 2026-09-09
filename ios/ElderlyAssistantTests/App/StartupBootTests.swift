import XCTest
@testable import ElderlyAssistant

/// Guards the progressive-startup boot machine (startup-perf task,
/// 2026-09-09): phases progress monotonically forward, failures degrade
/// honestly WITHOUT halting boot, and every stage label resolves through
/// the shipped string catalog in both languages (the same catalog-binding
/// pattern as `VoiceSessionBindingTests` — a regression here shows
/// English on the spinner while the rest of the app stays Nepali).
///
/// [LAUNCH-SCREEN] Spinner dismissal now passes through the
/// minimum-visibility floor (`StartupBoot.spinnerMinVisibleSeconds`, see
/// `StartupBootSpinnerFloorTests`): tests asserting dismissal drive a
/// fake clock (`TestClock`) past the floor first — the floor never
/// delays boot work, only the spinner's collapse.
final class StartupBootTests: XCTestCase {

    // MARK: - Phase progression

    func testInitialStateShowsNoSpinnerBeforeBootStarts() {
        let boot = StartupBoot()
        // No boot is running yet — the spinner must not claim "Loading…"
        // (on first run the onboarding wizard precedes `start()`).
        XCTAssertEqual(boot.stage, .restoringData)
        XCTAssertFalse(boot.hasStarted)
        XCTAssertFalse(boot.spinnerVisible)
        XCTAssertFalse(boot.isComplete)
        XCTAssertFalse(boot.hasFailures)

        boot.begin()
        XCTAssertTrue(boot.hasStarted)
        XCTAssertTrue(boot.spinnerVisible)
    }

    func testPhasesProgressForwardToReady() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.begin()
        boot.advance(to: .preparingVoice)
        XCTAssertEqual(boot.stage, .preparingVoice)
        XCTAssertTrue(boot.spinnerVisible)

        boot.advance(to: .finishingSetup)
        XCTAssertEqual(boot.stage, .finishingSetup)
        XCTAssertTrue(boot.spinnerVisible)

        // [LAUNCH-SCREEN] A fast boot reaches `.ready` before the
        // minimum-visibility floor — boot is complete but the spinner
        // stays perceivable until the floor passes.
        boot.advance(to: .ready)
        XCTAssertEqual(boot.stage, .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertTrue(boot.spinnerVisible,
                      "the 2.5 s floor holds the spinner past a fast .ready")

        // Once the floor elapses the gate dismisses the spinner.
        clock.advance(by: StartupBoot.spinnerMinVisibleSeconds + 0.5)
        boot.dismissSpinnerIfFloorElapsed()
        XCTAssertFalse(boot.spinnerVisible)
    }

    func testWarmStartStageSitsBetweenVoiceAndSetup() {
        let boot = StartupBoot()
        boot.begin()
        boot.advance(to: .preparingVoice)
        boot.advance(to: .warmingEngines)
        XCTAssertEqual(boot.stage, .warmingEngines)
        XCTAssertTrue(boot.spinnerVisible,
                      "the warm phase is honest boot work — the spinner stays up")

        boot.advance(to: .finishingSetup)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)

        // Rank order pinned: a monotonic machine's stages must never
        // allow the warm stage to rewind past voice-prep or skip ahead
        // of setup.
        XCTAssertLessThan(StartupBootStage.preparingVoice.rank,
                          StartupBootStage.warmingEngines.rank)
        XCTAssertLessThan(StartupBootStage.warmingEngines.rank,
                          StartupBootStage.finishingSetup.rank)
        XCTAssertLessThan(StartupBootStage.finishingSetup.rank,
                          StartupBootStage.ready.rank)
    }

    func testWarmPhaseFailureDegradesWithoutHalting() {
        let boot = StartupBoot()
        boot.recordFailure(.warmingEngines)
        XCTAssertEqual(boot.failedStages, [.warmingEngines])
        boot.advance(to: .warmingEngines)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete,
                      "a failed warm means the first conversation pays the load — today's behavior, never a blocked boot")
    }

    func testBackwardAdvanceIsANoOp() {
        let boot = StartupBoot()
        boot.advance(to: .finishingSetup)
        // A late/out-of-order phase completion must never rewind the
        // spinner.
        boot.advance(to: .restoringData)
        boot.advance(to: .preparingVoice)
        XCTAssertEqual(boot.stage, .finishingSetup)
    }

    func testDuplicateAdvanceIsANoOp() {
        let boot = StartupBoot()
        boot.advance(to: .ready)
        boot.advance(to: .ready)
        XCTAssertEqual(boot.stage, .ready)
    }

    // MARK: - Honest failure degradation

    func testFailureDoesNotHaltBoot() {
        let clock = TestClock()
        let boot = StartupBoot(clock: clock.tick)
        boot.recordFailure(.restoringData)
        XCTAssertTrue(boot.hasFailures)

        // Boot keeps moving and completes; the degraded caption owns the
        // user-facing honesty. ([LAUNCH-SCREEN]: the clock runs past the
        // visibility floor — which starts at begin() — so the dismissal
        // assertion stays meaningful; failures themselves never hold the
        // spinner.)
        boot.begin()
        clock.advance(by: StartupBoot.spinnerMinVisibleSeconds + 0.5)
        boot.advance(to: .preparingVoice)
        boot.advance(to: .finishingSetup)
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertFalse(boot.spinnerVisible)
        XCTAssertEqual(boot.failedStages, [.restoringData])
    }

    func testStageFailsAtMostOnce() {
        let boot = StartupBoot()
        boot.recordFailure(.preparingVoice)
        boot.recordFailure(.preparingVoice)
        XCTAssertEqual(boot.failedStages, [.preparingVoice])
    }

    func testBeginOnlyRestartsACompletedBoot() {
        let boot = StartupBoot()
        boot.advance(to: .preparingVoice)
        boot.recordFailure(.restoringData)

        // A running boot is never rewound by a second begin().
        boot.begin()
        XCTAssertEqual(boot.stage, .preparingVoice)
        XCTAssertEqual(boot.failedStages, [.restoringData])

        // A COMPLETED boot may restart: fresh stage, failures cleared.
        boot.advance(to: .ready)
        boot.begin()
        XCTAssertEqual(boot.stage, .restoringData)
        XCTAssertFalse(boot.hasFailures)
    }

    // MARK: - Catalog binding (Nepali + English, both shipped languages)

    func testStageLabelsResolveInBothLanguages() {
        let ne = Locale(identifier: "ne-NP")
        let en = Locale(identifier: "en-US")

        XCTAssertEqual(L10n.str(StartupBootStage.restoringData.labelKey, locale: ne),
                       "तपाईंको डाटा लोड हुँदैछ…")
        XCTAssertEqual(L10n.str(StartupBootStage.preparingVoice.labelKey, locale: ne),
                       "आवाज तयार हुँदैछ…")
        XCTAssertEqual(L10n.str(StartupBootStage.warmingEngines.labelKey, locale: ne),
                       "आवाज पहिल्यै लोड गर्दै…")
        XCTAssertEqual(L10n.str(StartupBootStage.finishingSetup.labelKey, locale: ne),
                       "सेटअप पूरा हुँदैछ…")
        XCTAssertEqual(L10n.str(StartupBootStage.ready.labelKey, locale: ne), "तयार")
        XCTAssertEqual(L10n.str("startup.degraded", locale: ne),
                       "केही सुविधा कम क्षमतामा चलिरहेका छन्")

        XCTAssertEqual(L10n.str(StartupBootStage.restoringData.labelKey, locale: en),
                       "Loading your data…")
        XCTAssertEqual(L10n.str(StartupBootStage.preparingVoice.labelKey, locale: en),
                       "Preparing voice…")
        XCTAssertEqual(L10n.str(StartupBootStage.warmingEngines.labelKey, locale: en),
                       "Warming up voice…")
        XCTAssertEqual(L10n.str(StartupBootStage.finishingSetup.labelKey, locale: en),
                       "Finishing setup…")
        XCTAssertEqual(L10n.str(StartupBootStage.ready.labelKey, locale: en), "Ready")
        XCTAssertEqual(L10n.str("startup.degraded", locale: en),
                       "Some features are running with reduced functionality")
    }

    func testEveryStageHasAHonestLabel() {
        // Any stage added later MUST carry a catalog key or the spinner
        // would render the raw key ("startup.x") — the honest-label
        // contract is per-stage, not per-phase.
        for stage in StartupBootStage.allCases {
            let nepali = L10n.str(stage.labelKey, locale: Locale(identifier: "ne-NP"))
            let english = L10n.str(stage.labelKey, locale: Locale(identifier: "en-US"))
            XCTAssertFalse(nepali.isEmpty, "\(stage) label empty in Nepali")
            XCTAssertFalse(english.isEmpty, "\(stage) label empty in English")
            XCTAssertFalse(nepali.hasPrefix("startup."),
                           "\(stage) label unresolved in Nepali: \(nepali)")
            XCTAssertFalse(english.hasPrefix("startup."),
                           "\(stage) label unresolved in English: \(english)")
        }
    }
}
