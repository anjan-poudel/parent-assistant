import XCTest
@testable import ElderlyAssistant

/// Guards the capability-specific degraded state ([BOOT-REVIEW, design
/// item], 2026-09-10): the generic transient "Some features are running
/// with reduced functionality" capsule is replaced by a PERSISTENT state
/// that names the feature, names the affected control, offers exactly ONE
/// recovery action, and keeps the detail in Settings.
///
/// Two contracts are pinned here:
///
///  1. the projection from the boot machine's failed stages (de-duped,
///     stably ordered, never inventing a capability for `.ready`), and
///  2. the SHIPPED catalog copy in both languages — same catalog-binding
///     pattern as `StartupBootTests`/`VoiceSessionBindingTests`, because
///     an unresolved `startup.degraded.*` key would render raw on screen
///     (and a missing Nepali value would show English mid-Nepali app).
final class StartupDegradationTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    // MARK: - Stage → capability projection

    func testEveryNonReadyStageMapsToItsCapability() {
        XCTAssertEqual(StartupDegradation(stage: .restoringData)?.capability,
                       .savedData)
        XCTAssertEqual(StartupDegradation(stage: .preparingVoice)?.capability,
                       .voiceActivation)
        XCTAssertEqual(StartupDegradation(stage: .warmingEngines)?.capability,
                       .speechEngineWarm)
        XCTAssertEqual(StartupDegradation(stage: .finishingSetup)?.capability,
                       .modelSetup)
        XCTAssertNil(StartupDegradation(stage: .ready),
                     ".ready is not a degraded capability")
    }

    func testStageRoundTripsThroughItsCapability() {
        // capability → stage → capability must be the identity, or a
        // recovery action would retry the wrong boot phase.
        for capability in StartupDegradation.Capability.allCases {
            let stage = StartupDegradation(capability: capability).stage
            XCTAssertEqual(StartupDegradation(stage: stage)?.capability,
                           capability,
                           "\(capability) maps to \(stage), which maps back "
                           + "to a different capability")
        }
    }

    func testNoFailuresMeansNoDegradation() {
        XCTAssertTrue(StartupDegradation.degradations(forFailedStages: []).isEmpty)
    }

    func testFailureOrderIsStableNotCallOrder() {
        // Safety-adjacent data first, then voice, then the optional warm —
        // the capsule must not reorder itself launch to launch.
        let degradations = StartupDegradation.degradations(
            forFailedStages: [.finishingSetup, .preparingVoice,
                              .warmingEngines, .restoringData])
        XCTAssertEqual(degradations.map(\.capability),
                       [.savedData, .voiceActivation, .speechEngineWarm,
                        .modelSetup])
    }

    func testRepeatedFailureOfAStageAppearsOnce() {
        let degradations = StartupDegradation.degradations(
            forFailedStages: [.restoringData, .restoringData, .restoringData])
        XCTAssertEqual(degradations.count, 1)
        XCTAssertEqual(degradations.first?.capability, .savedData)
    }

    func testReadyIsIgnoredWhenMixedWithRealFailures() {
        let degradations = StartupDegradation.degradations(
            forFailedStages: [.ready, .preparingVoice])
        XCTAssertEqual(degradations.map(\.capability), [.voiceActivation])
    }

    func testEveryCapabilityIsReachableFromAFailure() {
        let allStages = StartupBootStage.allCases.filter { $0 != .ready }
        let reached = Set(StartupDegradation
            .degradations(forFailedStages: allStages)
            .map(\.capability))
        XCTAssertEqual(reached, Set(StartupDegradation.Capability.allCases),
                       "a non-ready boot stage has no user-facing degradation")
    }

    // MARK: - Key shape

    func testKeysUseTheReviewedPrefixAndOneOfEachRole() {
        for capability in StartupDegradation.Capability.allCases {
            let degradation = StartupDegradation(capability: capability)
            for key in [degradation.titleKey, degradation.detailKey,
                        degradation.recoveryKey, degradation.diagnosticKey,
                        degradation.controlKey] {
                XCTAssertTrue(key.hasPrefix("startup.degraded."),
                              "\(key) is outside the reserved prefix")
            }
            XCTAssertEqual(degradation.titleKey,
                           "startup.degraded.\(capability.rawValue).title")
            XCTAssertEqual(degradation.diagnosticKey,
                           "startup.degraded.\(capability.rawValue).diagnostic")
        }
    }

    func testKeysAreUniquePerCapabilityAndRole() {
        var keys: [String] = []
        for capability in StartupDegradation.Capability.allCases {
            let degradation = StartupDegradation(capability: capability)
            keys += [degradation.titleKey, degradation.detailKey,
                     degradation.recoveryKey, degradation.diagnosticKey,
                     degradation.controlKey]
        }
        XCTAssertEqual(Set(keys).count, keys.count,
                       "two roles share a catalog key")
    }

    // MARK: - Shipped copy (both languages)

    func testEveryDegradationKeyResolvesInBothLanguages() {
        for capability in StartupDegradation.Capability.allCases {
            let degradation = StartupDegradation(capability: capability)
            for key in [degradation.titleKey, degradation.detailKey,
                        degradation.recoveryKey, degradation.diagnosticKey,
                        degradation.controlKey] {
                for (locale, label) in [(nepali, "Nepali"), (english, "English")] {
                    let value = L10n.str(key, locale: locale)
                    XCTAssertFalse(value.isEmpty, "\(key) empty in \(label)")
                    XCTAssertFalse(value.hasPrefix("startup.degraded."),
                                   "\(key) unresolved in \(label): \(value)")
                }
            }
        }
    }

    func testNepaliCopyDiffersFromEnglish() {
        // A copied-through English string would show up as an untranslated
        // capsule in the middle of an otherwise Nepali UI.
        for capability in StartupDegradation.Capability.allCases {
            let degradation = StartupDegradation(capability: capability)
            for key in [degradation.titleKey, degradation.detailKey,
                        degradation.recoveryKey, degradation.diagnosticKey,
                        degradation.controlKey] {
                XCTAssertNotEqual(L10n.str(key, locale: nepali),
                                  L10n.str(key, locale: english),
                                  "\(key) is untranslated (ne == en)")
            }
        }
    }

    func testNamesTheFeatureAndControlInBothLanguages() {
        // The whole point of the design item: the state says WHICH feature
        // is degraded and WHICH control it affects.
        XCTAssertEqual(L10n.str(StartupDegradation(capability: .voiceActivation).titleKey,
                                locale: english),
                       "Voice activation is unavailable")
        XCTAssertEqual(L10n.str(StartupDegradation(capability: .voiceActivation).controlKey,
                                locale: english),
                       "Talk button")
        XCTAssertEqual(L10n.str(StartupDegradation(capability: .voiceActivation).controlKey,
                                locale: nepali),
                       "बोल्ने बटन")
        XCTAssertEqual(L10n.str(StartupDegradation(capability: .savedData).titleKey,
                                locale: nepali),
                       "सुरक्षित विवरणहरू लोड हुन सकेनन्")
    }

    func testRecoveryCopyIsASingleAction() {
        // One action per capability: a short imperative label, never a
        // sentence and never a list ("Try again, or …" would be two).
        for capability in StartupDegradation.Capability.allCases {
            let label = L10n.str(
                StartupDegradation(capability: capability).recoveryKey,
                locale: english)
            XCTAssertLessThanOrEqual(label.split(separator: " ").count, 3,
                                     "\(capability) recovery label reads as more than one action: \(label)")
            XCTAssertFalse(label.contains(","),
                           "\(capability) recovery label offers alternatives")
        }
    }

    // MARK: - Boot machine projection

    func testBootSurfacesDegradationsForItsFailedStages() {
        let boot = StartupBoot()
        XCTAssertTrue(boot.degradations.isEmpty)

        boot.recordFailure(.restoringData)
        boot.recordFailure(.preparingVoice)
        XCTAssertEqual(boot.degradations.map(\.capability),
                       [.savedData, .voiceActivation])

        // The state is PERSISTENT: it survives the boot reaching `.ready`
        // (the old capsule hid itself after six seconds; this one stays
        // until the capability genuinely recovers).
        boot.advance(to: .ready)
        XCTAssertTrue(boot.isComplete)
        XCTAssertEqual(boot.degradations.count, 2)
    }

    func testClearingAFailureRemovesOnlyThatCapability() {
        let boot = StartupBoot()
        boot.recordFailure(.restoringData)
        boot.recordFailure(.finishingSetup)

        boot.clearFailure(.restoringData)
        XCTAssertEqual(boot.degradations.map(\.capability), [.modelSetup])
    }

    func testCapabilityOrderingIsStableAcrossBoots() {
        let first = StartupBoot()
        first.recordFailure(.finishingSetup)
        first.recordFailure(.restoringData)
        let second = StartupBoot()
        second.recordFailure(.restoringData)
        second.recordFailure(.finishingSetup)
        XCTAssertEqual(first.degradations.map(\.capability),
                       second.degradations.map(\.capability),
                       "the capsule's order must not depend on failure timing")
    }
}
