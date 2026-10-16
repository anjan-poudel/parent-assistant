import XCTest
@testable import ElderlyAssistant

/// [MODEL-WARDEN] Step 3 — the cost model's arithmetic.
///
/// Two halves, both deterministic: the model's own arithmetic (percentiles,
/// priors, pressure, the hold threshold) as pure values, and the ordering it
/// produces inside `ModelLifecycleManager` (which is where §7.4's ANE
/// default now lives).
final class ModelCostModelTests: XCTestCase {

    // MARK: - Doubles, mirroring `ModelLifecycleManagerTests`

    private final class ScriptedProbe: MemoryProbing {
        var physicalMemoryBytes: UInt64
        var availableProcessMemoryBytes: UInt64
        var physFootprintBytes: UInt64

        init(physicalMemoryBytes: UInt64 = 6_000_000_000,
             availableProcessMemoryBytes: UInt64 = 3_400_000_000,
             physFootprintBytes: UInt64 = 0) {
            self.physicalMemoryBytes = physicalMemoryBytes
            self.availableProcessMemoryBytes = availableProcessMemoryBytes
            self.physFootprintBytes = physFootprintBytes
        }
    }

    private final class FakeOwner {
        private(set) var unloadCount = 0
        func unload() { unloadCount += 1 }
    }

    private var probe: ScriptedProbe!
    private var now: Date!
    private var manager: ModelLifecycleManager!

    private let budget = ModelLifecycleBudget.standardModelsBudgetBytes

    override func setUp() {
        super.setUp()
        probe = ScriptedProbe()
        now = Date(timeIntervalSince1970: 1_700_000_000)
        manager = makeManager(budget: budget)
    }

    override func tearDown() {
        manager = nil
        probe = nil
        super.tearDown()
    }

    private func makeManager(budget: UInt64) -> ModelLifecycleManager {
        ModelLifecycleManager(
            probe: probe,
            clock: { [unowned self] in self.now },
            idleEvictionSeconds: ModelLifecycleManager.defaultIdleEvictionSeconds,
            budgetOverrideBytes: budget)
    }

    @discardableResult
    private func load(_ slot: ModelSlot,
                      modelID: ModelID?,
                      owner: FakeOwner,
                      into target: ModelLifecycleManager? = nil) -> LoadAdmission {
        let manager = target ?? self.manager!
        manager.register(slot: slot, modelID: modelID, owner: owner) { [weak owner] in
            owner?.unload()
        }
        let admission = manager.prepareLoad(of: slot, modelID: modelID)
        if admission.isAllowed { manager.didLoad(slot, owner: owner) }
        return admission
    }

    private var sttANE: ModelID { ModelCatalog.whisperKitMediumV6 }
    private var brain4B: ModelID { ModelCatalog.intentQwen4BSlotCanon }
    private var brain17B: ModelID { ModelCatalog.qwen3_1_7BInstruct }
    private var intent1B: ModelID { ModelCatalog.intentNepali1B }

    private func footprint(_ slot: ModelSlot, _ modelID: ModelID? = nil) -> ModelFootprint {
        ModelLifecycleInventory.footprint(for: slot, modelID: modelID)
    }

    private func request(_ slot: ModelSlot,
                         modelID: ModelID?,
                         owner: AnyObject?,
                         purpose: ReservationPurpose = .voiceTurn,
                         replaces: Bool = true) -> ModelLoadRequest {
        ModelLoadRequest(slot: slot, modelID: modelID, owner: owner,
                         purpose: purpose, replacesSlotContents: replaces)
    }

    private func reserveOrFail(_ manager: ModelLifecycleManager,
                               _ request: ModelLoadRequest,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> ModelReservation? {
        switch manager.reserve(request) {
        case .success(let reservation):
            return reservation
        case .failure(let denial):
            XCTFail("expected the reservation to be granted, got \(denial)",
                    file: file, line: line)
            return nil
        }
    }

    // MARK: - 1. Measurement

    func testAnUnmeasuredKeyAnswersWithThePriorAndSaysSo() {
        var model = ModelCostModel()
        let cost = model.cost(slot: .speechToText, modelID: sttANE,
                              deviceClass: .standard)
        XCTAssertFalse(cost.isMeasured)
        XCTAssertEqual(cost.sampleCount, 0)
        XCTAssertNil(cost.p95Ms)

        // The prior is what the ordering uses in the meantime, and it is the
        // *expensive* one: an eviction decided before any device number
        // exists must not be decided as if the reload were free.
        let seconds = model.reloadCostSeconds(
            slot: .speechToText, modelID: sttANE,
            footprint: footprint(.speechToText, sttANE),
            deviceClass: .standard)
        XCTAssertEqual(seconds, ModelReloadPrior.aneSpeechToTextSeconds)
    }

    func testTheMeasuredP95ReplacesThePrior() {
        var model = ModelCostModel()
        for ms in [1_000.0, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 90_000] {
            model.record(loadMs: ms, slot: .speechToText, modelID: sttANE,
                         deviceClass: .standard, at: now)
        }
        let cost = model.cost(slot: .speechToText, modelID: sttANE,
                              deviceClass: .standard)
        XCTAssertEqual(cost.sampleCount, 8)
        XCTAssertTrue(cost.isMeasured)
        // Nearest rank over eight sorted samples at 95 % is the maximum.
        XCTAssertEqual(cost.p95Ms, 90_000)
        XCTAssertEqual(cost.p50Ms, 4_000)

        // The reload is planned against the *tail*, not the median: a
        // household waits through the slow one.
        XCTAssertEqual(model.reloadCostSeconds(
            slot: .speechToText, modelID: sttANE,
            footprint: footprint(.speechToText, sttANE),
            deviceClass: .standard), 90)
    }

    func testTheBucketIsBounded() {
        var model = ModelCostModel()
        for i in 1...(ModelCostModel.maxSamplesPerKey + 4) {
            model.record(loadMs: Double(i) * 1_000, slot: .speechToText,
                         modelID: sttANE, deviceClass: .standard, at: now)
        }
        // The oldest readings fall off, so the reading kept is the newest
        // window — a reload cost from a thermal-throttled hour must not
        // outlive the residents it describes.
        XCTAssertEqual(model.cost(slot: .speechToText, modelID: sttANE,
                                  deviceClass: .standard).sampleCount,
                       ModelCostModel.maxSamplesPerKey)
        // Readings 1…12 land, the newest eight are kept — 5 000…12 000 ms —
        // and the median of those is 8 000.
        XCTAssertEqual(model.cost(slot: .speechToText, modelID: sttANE,
                                  deviceClass: .standard).p50Ms,
                       Double(ModelCostModel.maxSamplesPerKey) * 1_000)
    }

    func testGarbageReadingsAreDroppedRatherThanStored() {
        var model = ModelCostModel()
        for bad in [0.0, -1.0, .nan, .infinity] {
            model.record(loadMs: bad, slot: .speechToText, modelID: sttANE,
                         deviceClass: .standard, at: now)
        }
        XCTAssertFalse(model.cost(slot: .speechToText, modelID: sttANE,
                                  deviceClass: .standard).isMeasured,
                       "a clock step must not be able to move a p95")
    }

    func testTheTwoSTTBackendsDoNotShareAKey() {
        // `.speechToText` is one *slot* and two artifacts. Pricing them the
        // same would let the cheap backend inherit the expensive one's prior
        // — or worse, the reverse: an eviction decided on whisper.cpp's 2 s
        // would throw away the ANE graph's 77 s.
        var model = ModelCostModel()
        model.record(loadMs: 1_800, slot: .speechToText,
                     modelID: ModelCatalog.whisperMediumFinetunedNepali,
                     deviceClass: .standard, at: now)
        XCTAssertTrue(model.cost(slot: .speechToText,
                                 modelID: ModelCatalog.whisperMediumFinetunedNepali,
                                 deviceClass: .standard).isMeasured)
        XCTAssertFalse(model.cost(slot: .speechToText, modelID: sttANE,
                                  deviceClass: .standard).isMeasured)
    }

    func testThePriorsAreTheOnesTheProposalRecords() {
        // Read off §5.5, pinned here so a later edit to the table is a
        // deliberate act rather than a drift.
        XCTAssertEqual(ModelReloadPrior.aneSpeechToTextSeconds, 77)
        XCTAssertEqual(ModelReloadPrior.aneSpeechToTextRecompileSeconds, 135)
        XCTAssertEqual(ModelReloadPrior.whisperCPPSeconds, 2)

        // A brain's prior scales with its artifact: the 4B is a bigger
        // page-in than the 1.7B, so it is the dearer victim.
        let big = ModelReloadPrior.seconds(slot: .brain, modelID: brain4B,
                                           footprint: footprint(.brain, brain4B))
        let small = ModelReloadPrior.seconds(slot: .brain, modelID: brain17B,
                                             footprint: footprint(.brain, brain17B))
        XCTAssertGreaterThan(big, small)
        XCTAssertGreaterThan(small, ModelReloadPrior.brainFloorSeconds)

        // The corrector has no release path at all: it is never a victim on
        // reload-cost grounds, and `evictionPressure` says so numerically
        // rather than by a flag the comparator has to remember to read.
        XCTAssertEqual(ModelReloadPrior.seconds(slot: .sttCorrector, modelID: nil,
                                                footprint: footprint(.sttCorrector)),
                       .infinity)
    }

    func testThePriorIsNeverZero() {
        // A reload priced as free is the one error that matters: the
        // ordering would then prefer the resident the product cannot afford
        // to lose. The floor is below every load the app performs and above
        // the arithmetic's need for a non-zero divisor.
        var model = ModelCostModel()
        for id in [brain17B, brain4B] {
            XCTAssertGreaterThanOrEqual(
                model.reloadCostSeconds(slot: .brain, modelID: id,
                                        footprint: footprint(.brain, id),
                                        deviceClass: .standard),
                ModelCostModel.minimumReloadCostSeconds)
        }
    }

    // MARK: - 2. The pressure scalar

    func testPressureIsBytesPerSecondOfReloadPainWeightedByIdleness() {
        // 1 GB idle for 60 s with a 2 s reload is 30 GB·s per second of
        // reload pain — the same bytes and the same idleness with a 77 s
        // reload is 15× smaller, which is §7.4 as arithmetic.
        let cheap = ModelCostModel.evictionPressure(idleSeconds: 60,
                                                    freedBytes: 1_000_000_000,
                                                    reloadCostSeconds: 2)
        let dear = ModelCostModel.evictionPressure(idleSeconds: 60,
                                                   freedBytes: 1_000_000_000,
                                                   reloadCostSeconds: 60)
        XCTAssertEqual(cheap, 60 * 1_000_000_000 / 2)
        XCTAssertEqual(dear, 60 * 1_000_000_000 / 60)
        XCTAssertGreaterThan(cheap, dear)

        // Each term does one job: staler and bigger both raise pressure.
        XCTAssertGreaterThan(
            ModelCostModel.evictionPressure(idleSeconds: 120, freedBytes: 1_000_000_000,
                                            reloadCostSeconds: 2),
            cheap)
        XCTAssertGreaterThan(
            ModelCostModel.evictionPressure(idleSeconds: 60, freedBytes: 2_000_000_000,
                                            reloadCostSeconds: 2),
            cheap)
    }

    func testAResidentWithNoReleasePathIsNeverPreferredAsAVictim() {
        XCTAssertEqual(ModelCostModel.evictionPressure(idleSeconds: 10_000,
                                                       freedBytes: 2_600_000,
                                                       reloadCostSeconds: .infinity),
                       0)
        XCTAssertEqual(ModelCostModel.evictionPressure(idleSeconds: 10_000,
                                                       freedBytes: 2_600_000,
                                                       reloadCostSeconds: 0),
                       0)
        // A negative idle cannot happen, and if it did it must not produce a
        // negative score that sorts *after* the unloadable ones.
        XCTAssertEqual(ModelCostModel.evictionPressure(idleSeconds: -5,
                                                       freedBytes: 1_000,
                                                       reloadCostSeconds: 2),
                       0)
    }

    // MARK: - 3. The hold arithmetic

    func testTheConfiguredIdleWindowIsAFloorNotACeiling() {
        // The shipped configuration: the ANE's 77 s prior is *under* the
        // 120 s base, so every threshold the app applies is unmoved by Step
        // 3 — which is what keeps it out of the TTL constants' way.
        XCTAssertEqual(
            ModelCostModel.idleThresholdSeconds(configuredBase: 120,
                                                reloadCostSeconds: 77,
                                                idleEvictionPenalty: 1,
                                                workingSetIsPressed: false),
            120)
        // A device that measured the 135 s ANE recompile earns a longer
        // hold — the one behaviour the arithmetic adds.
        XCTAssertEqual(
            ModelCostModel.idleThresholdSeconds(configuredBase: 120,
                                                reloadCostSeconds: 135,
                                                idleEvictionPenalty: 1,
                                                workingSetIsPressed: false),
            135)
    }

    func testAPressedWorkingSetSuppressesTheExtension() {
        // When the measured `W(t)` has outgrown the class's assumption, the
        // app — not the models — is what grew, and holding models longer
        // would lengthen the wrong thing.
        XCTAssertEqual(
            ModelCostModel.idleThresholdSeconds(configuredBase: 120,
                                                reloadCostSeconds: 135,
                                                idleEvictionPenalty: 1,
                                                workingSetIsPressed: true),
            120)
    }

    func testThePenaltyScalesTheEarnedHold() {
        // §4.4 D2's inequality: the penalty is how much a household minds
        // waiting, and it divides the reload cost to get a window.
        XCTAssertEqual(ModelCostModel.holdSeconds(reloadCostSeconds: 60,
                                                  idleEvictionPenalty: 2), 30)
        XCTAssertEqual(ModelCostModel.holdSeconds(reloadCostSeconds: 60,
                                                  idleEvictionPenalty: 0), 0)
    }

    func testTheWorkingSetIsWhatTheLedgerCannotAccountFor() {
        let sample = ModelFootprintCostSample(
            deviceClass: .standard,
            physFootprintBytes: 2_000_000_000,
            ceilingBytes: 3_500_000_000,
            residentLiveBytes: 1_500_000_000,
            transientLiveBytes: 200_000_000,
            at: now)
        XCTAssertEqual(sample.workingSetBytes, 300_000_000)

        // Saturating, both ways: a probe that reads low must neither trap
        // nor fabricate a negative working set.
        let lowProbe = ModelFootprintCostSample(
            deviceClass: .standard, physFootprintBytes: 100,
            ceilingBytes: 3_500_000_000, residentLiveBytes: 1_000,
            transientLiveBytes: 1_000, at: now)
        XCTAssertEqual(lowProbe.workingSetBytes, 0)
    }

    func testTheCeilingIsRecordedAsItsMinimum() {
        // A generous reading must not be able to relax the class budget,
        // so the observed ceiling is the lowest one seen.
        var model = ModelCostModel()
        for ceiling in [3_800_000_000, 3_500_000_000, 3_600_000_000] {
            model.record(ModelFootprintCostSample(
                deviceClass: .standard, physFootprintBytes: 1_000_000_000,
                ceilingBytes: UInt64(ceiling), residentLiveBytes: 0,
                transientLiveBytes: 0, at: now))
        }
        XCTAssertEqual(model.observedCeilingBytes(for: .standard), 3_500_000_000)
        XCTAssertNil(model.observedCeilingBytes(for: .compact))
    }

    // MARK: - 4. The victim order the manager actually walks

    func testTheANESttIsEvictedLastAmongEqualCostVictims() {
        // Both residents are heavy and equally idle, and the ANE STT is the
        // *staler* of the two — so Step 2's `(least recent first)` rule picks
        // it, and the cost model must not. 1.0 GB at 77 s is a smaller
        // pressure than 1.81 GB at 2.77 s however the clock votes.
        //
        // A 100 s head start for the STT, then 81 s more before the load:
        // STT idle 181 s, intent brain idle 100 s.
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttANE, owner: sttOwner).isAllowed)

        now = now.addingTimeInterval(81)
        let intentOwner = FakeOwner()
        XCTAssertTrue(load(.intentBrain, modelID: intent1B, owner: intentOwner).isAllowed)
        XCTAssertEqual(sttOwner.unloadCount, 0)

        now = now.addingTimeInterval(100)
        let brainOwner = FakeOwner()
        let admission = load(.brain, modelID: brain17B, owner: brainOwner)

        // One victim, and it is the intent brain: 1.81 GB freed closes the
        // gap, and the ANE STT is spared the 77 s reload it would have paid.
        XCTAssertEqual(admission, .allowed(evicted: [.intentBrain]))
        XCTAssertEqual(intentOwner.unloadCount, 1)
        XCTAssertEqual(sttOwner.unloadCount, 0)
        XCTAssertTrue(manager.isResident(.speechToText))
    }

    func testTheOrdinalOrderWouldHaveEvictedTheANEStt() {
        // The same scenario with Step 2's comparator: the ANE STT is the
        // least recently used heavy resident, so it goes first — and because
        // its 1.0 GB does not close the gap, the intent brain goes too. Two
        // evictions and a 77 s reload where the cost model needs one and
        // buys none. This is the difference Step 3 makes, measured.
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttANE, owner: sttOwner).isAllowed)

        now = now.addingTimeInterval(81)
        let intentOwner = FakeOwner()
        XCTAssertTrue(load(.intentBrain, modelID: intent1B, owner: intentOwner).isAllowed)

        now = now.addingTimeInterval(100)
        manager.wardenConfig.costAwareEvictionEnabled = false
        let brainOwner = FakeOwner()
        let admission = load(.brain, modelID: brain17B, owner: brainOwner)

        XCTAssertEqual(admission, .allowed(evicted: [.speechToText, .intentBrain]))
        XCTAssertEqual(sttOwner.unloadCount, 1)
        XCTAssertEqual(intentOwner.unloadCount, 1)
    }

    func testTheANESttIsStillAVictimWhenNothingElseCanCloseTheGap() {
        // §7.4's default is a *preference*, not a protection. The 4B swap on
        // the 6 GB class needs 3.4 GB and there is exactly one resident
        // holding anything like that much: the invariant the suite already
        // encodes ("STT and the 4B never co-reside") survives the cost
        // model, because with the STT idle for an hour its pressure finally
        // exceeds a cheaper rival's.
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttANE, owner: sttOwner).isAllowed)

        now = now.addingTimeInterval(600)
        let brainOwner = FakeOwner()
        let admission = load(.brain, modelID: brain4B, owner: brainOwner)

        XCTAssertEqual(admission, .allowed(evicted: [.speechToText]),
                       "the 4B is over budget alone, so nothing light can "
                       + "help and the ANE STT is the only heavy candidate")
        XCTAssertEqual(sttOwner.unloadCount, 1)
        XCTAssertFalse(manager.isResident(.speechToText))
        XCTAssertTrue(manager.isResident(.brain))
    }

    func testTheOrderStillReadsTheLadderFirst() {
        // The ladder is Step 2's and it is untouched, and the case that
        // proves it is one where the cost model would have chosen
        // differently. Both are light, so heavy-first cannot be doing the
        // work for us; the budget holds all three with exactly one eviction
        // to spare, so WHICH resident goes is the whole assertion.
        //
        //  - `.ttsVoices`, `.background`, deliberately *fresh* (idle 10 s)
        //    and small (83.8 MB), cheap to reload.
        //  - `.intentEncoder`, `.foreground`, stale (idle 300 s) and the
        //    bigger of the two, so its pressure is ~68× the voices'.
        //
        // Left to the cost model, the encoder goes. The ladder says the
        // background prefetch goes first, and the ladder is the first key.
        let encoderLive = footprint(.intentEncoder).liveBytes
        let voicesLive = footprint(.ttsVoices).liveBytes
        // Budgeted to hold both residents exactly, so the one-byte VAD
        // request cannot fit beside them and exactly one eviction closes it.
        let tight = makeManager(budget: encoderLive + voicesLive)

        let encoderOwner = FakeOwner()
        tight.register(slot: .intentEncoder, modelID: nil, owner: encoderOwner,
                       priority: .foreground) { [weak encoderOwner] in
            encoderOwner?.unload()
        }
        tight.didLoad(.intentEncoder, owner: encoderOwner)
        now = now.addingTimeInterval(300)

        let voicesOwner = FakeOwner()
        tight.register(slot: .ttsVoices, modelID: nil, owner: voicesOwner,
                       priority: .background) { [weak voicesOwner] in
            voicesOwner?.unload()
        }
        tight.didLoad(.ttsVoices, owner: voicesOwner)
        now = now.addingTimeInterval(10)

        let vadOwner = FakeOwner()
        tight.register(slot: .vad, modelID: nil, owner: vadOwner) { [weak vadOwner] in
            vadOwner?.unload()
        }
        guard let reservation = reserveOrFail(
            tight, request(.vad, modelID: nil, owner: vadOwner)) else { return }

        XCTAssertEqual(reservation.evicted, [.ttsVoices],
                       "a background resident's bytes go before a foreground "
                       + "one's, however the cost model scores them")
        XCTAssertEqual(voicesOwner.unloadCount, 1)
        XCTAssertEqual(encoderOwner.unloadCount, 0)
        XCTAssertTrue(tight.isResident(.intentEncoder))
    }

    // MARK: - 5. The manager's cost surface

    func testALoadSiteCanReportWhatTheReloadCosts() {
        // The seam the recognizers call. Before any measurement the manager
        // answers with the prior, and after one it answers with the
        // measurement — so the number the ordering used is checkable.
        let owner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttANE, owner: owner).isAllowed)
        XCTAssertEqual(manager.reloadCostSeconds(for: .speechToText), 77)
        XCTAssertFalse(manager.measuredLoadCost(for: .speechToText).isMeasured)

        manager.noteLoadCost(loadMs: 200_000, slot: .speechToText, modelID: sttANE)
        XCTAssertEqual(manager.reloadCostSeconds(for: .speechToText), 200)
        XCTAssertEqual(manager.measuredLoadCost(for: .speechToText).sampleCount, 1)

        XCTAssertNil(manager.reloadCostSeconds(for: .vad),
                     "an unregistered slot has no cost to report")
    }

    func testAMeasuredReloadLongerThanTheBaseExtendsTheHold() {
        // The one behaviour the hold arithmetic adds: a device that has
        // measured a 200 s ANE reload must not sweep the graph at 120 s.
        let owner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttANE, owner: owner).isAllowed)
        manager.noteLoadCost(loadMs: 200_000, slot: .speechToText, modelID: sttANE)

        now = now.addingTimeInterval(ModelLifecycleManager.defaultIdleEvictionSeconds + 1)
        XCTAssertEqual(manager.evictIdle(), [],
                       "the ANE STT earned a longer hold than the base window")
        XCTAssertTrue(manager.isResident(.speechToText))

        now = now.addingTimeInterval(80)
        XCTAssertEqual(manager.evictIdle(), [.speechToText])
        XCTAssertEqual(owner.unloadCount, 1)
    }

    func testAnUnmeasuredResidentKeepsTheShippedWindow() {
        // Step 3 changes no shipped threshold: with the priors under the
        // 120 s base, the sweep behaves exactly as it did in Step 2.
        let owner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttANE, owner: owner).isAllowed)

        now = now.addingTimeInterval(ModelLifecycleManager.defaultIdleEvictionSeconds - 1)
        XCTAssertEqual(manager.evictIdle(), [])
        now = now.addingTimeInterval(1)
        XCTAssertEqual(manager.evictIdle(), [.speechToText])
    }

    func testAPressedWorkingSetSuppressesAMeasuredExtension() {
        // The footprint stream says the *app* has grown past what the class
        // budget assumed. Responding by holding models longer would make the
        // wrong thing worse, so the extension is suppressed.
        let owner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttANE, owner: owner).isAllowed)
        manager.noteLoadCost(loadMs: 200_000, slot: .speechToText, modelID: sttANE)

        // 1.0 GB resident and a 1.6 GB footprint means 600 MB of working set
        // against the 300 MB the class assumed.
        probe.physFootprintBytes = 1_600_000_000
        manager.sampleFootprint()
        XCTAssertEqual(manager.measuredWorkingSetBytes(), 600_000_000)

        now = now.addingTimeInterval(ModelLifecycleManager.defaultIdleEvictionSeconds + 1)
        XCTAssertEqual(manager.evictIdle(), [.speechToText],
                       "a pressed working set suppresses the extension")
    }

    func testTheFootprintSampleFeedsTheCostModel() {
        let owner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: owner).isAllowed)
        let resident = footprint(.brain, brain17B).liveBytes
        probe.physFootprintBytes = resident + 350_000_000
        manager.sampleFootprint()

        XCTAssertEqual(manager.measuredWorkingSetBytes(), 350_000_000)
        let costs = manager.snapshot().reloadCostSeconds
        XCTAssertNotNil(costs[.brain])
        XCTAssertNil(costs[.speechToText],
                     "an unregistered slot has no cost to report")
    }

    func testAProbeThatCannotReadTheFootprintDoesNotFeedTheModel() {
        let owner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: owner).isAllowed)
        manager.sampleFootprint()   // physFootprintBytes is 0
        XCTAssertNil(manager.measuredWorkingSetBytes(),
                     "a failed probe must not become a working-set reading")
    }
}
