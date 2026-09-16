import XCTest
@testable import ElderlyAssistant

/// [MODEL-LIFECYCLE] Budget arithmetic, LRU eviction, the no-two-heavy
/// invariant, idle eviction on a fake clock, and the reload-after-eviction
/// paths.
///
/// Everything here is deterministic by construction: the memory probe is
/// scripted and the clock is injected, so no test depends on the host
/// machine's RAM or on wall-clock time. The budget is pinned with
/// `budgetOverrideBytes` so the arithmetic is the same on a 16 GB Mac as on
/// the 6 GB device the mechanism exists for.
final class ModelLifecycleManagerTests: XCTestCase {

    // MARK: - Doubles

    /// A scripted probe. `available` is settable mid-test so a case can model
    /// the headroom actually growing after an eviction.
    private final class ScriptedProbe: MemoryProbing {
        var physicalMemoryBytes: UInt64
        var availableProcessMemoryBytes: UInt64

        init(physicalMemoryBytes: UInt64 = 6_000_000_000,
             availableProcessMemoryBytes: UInt64 = 3_400_000_000) {
            self.physicalMemoryBytes = physicalMemoryBytes
            self.availableProcessMemoryBytes = availableProcessMemoryBytes
        }
    }

    /// A release path that records that it ran. Mirrors the real owners'
    /// contract: dropping the reference is what frees the model.
    private final class FakeOwner {
        private(set) var unloadCount = 0
        var onUnload: (() -> Void)?
        func unload() {
            unloadCount += 1
            onUnload?()
        }
    }

    private var probe: ScriptedProbe!
    private var now: Date!
    private var manager: ModelLifecycleManager!

    /// The 6 GB class budget, pinned so the arithmetic is host-independent.
    private let budget = ModelLifecycleBudget.standardModelsBudgetBytes

    override func setUp() {
        super.setUp()
        probe = ScriptedProbe()
        now = Date(timeIntervalSince1970: 1_700_000_000)
        manager = makeManager(budget: budget)
    }

    /// A manager on the scripted probe and the fake clock, with the budget
    /// pinned. `budgetOverrideBytes` also pins the device class, which is
    /// what keeps these tests independent of the host's RAM.
    private func makeManager(budget: UInt64) -> ModelLifecycleManager {
        ModelLifecycleManager(
            probe: probe,
            clock: { [unowned self] in self.now },
            idleEvictionSeconds: ModelLifecycleManager.defaultIdleEvictionSeconds,
            budgetOverrideBytes: budget)
    }

    override func tearDown() {
        manager = nil
        probe = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func register(_ slot: ModelSlot,
                          modelID: ModelID?,
                          owner: FakeOwner,
                          evictable: Bool = true) -> FakeOwner {
        manager.register(slot: slot, modelID: modelID, owner: owner,
                         evictable: evictable) { [weak owner] in
            owner?.unload()
        }
        return owner
    }

    /// Registers a slot and drives it fully resident, as a real load would.
    @discardableResult
    private func load(_ slot: ModelSlot,
                      modelID: ModelID?,
                      owner: FakeOwner) -> LoadAdmission {
        register(slot, modelID: modelID, owner: owner)
        let admission = manager.prepareLoad(of: slot, modelID: modelID)
        if admission.isAllowed { manager.didLoad(slot, owner: owner) }
        return admission
    }

    private var sttQ8: ModelID { ModelCatalog.whisperKitMediumV6 }   // 800 MB ANE
    private var brain4B: ModelID { ModelCatalog.intentQwen4BSlotCanon }  // 2.5 GB
    private var brain17B: ModelID { ModelCatalog.qwen3_1_7BInstruct }    // 1.28 GB

    // MARK: - 1. Budget arithmetic

    func testDeviceClassBoundaries() {
        // 4 GB tier.
        XCTAssertEqual(ModelLifecycleBudget.deviceClass(physicalMemoryBytes: 4_000_000_000),
                       .compact)
        // The 6 GB tier this whole mechanism exists for.
        XCTAssertEqual(ModelLifecycleBudget.deviceClass(physicalMemoryBytes: 6_000_000_000),
                       .standard)
        // 8 GB tier.
        XCTAssertEqual(ModelLifecycleBudget.deviceClass(physicalMemoryBytes: 8_000_000_000),
                       .roomy)
    }

    func testDeviceClassBudgets() {
        XCTAssertEqual(ModelLifecycleBudget.modelsBudgetBytes(for: .compact),
                       2_000_000_000)
        XCTAssertEqual(ModelLifecycleBudget.modelsBudgetBytes(for: .standard),
                       3_200_000_000)
        XCTAssertEqual(ModelLifecycleBudget.modelsBudgetBytes(for: .roomy),
                       5_000_000_000)
    }

    func testEffectiveBudgetIsCappedByClassEvenWhenHeadroomLooksGenerous() {
        // A roomy-looking reading on the 6 GB class must NOT relax the
        // co-residency invariant the class constant encodes.
        let effective = ModelLifecycleBudget.effectiveBudgetBytes(
            deviceClass: .standard,
            availableBytes: 6_000_000_000,
            residentLiveBytes: 0)
        XCTAssertEqual(effective, ModelLifecycleBudget.standardModelsBudgetBytes)
    }

    func testEffectiveBudgetFallsWithTheProbe() {
        // Headroom 2.0 GB, nothing resident → ceiling 2.0 GB, minus margin.
        let effective = ModelLifecycleBudget.effectiveBudgetBytes(
            deviceClass: .standard,
            availableBytes: 2_000_000_000,
            residentLiveBytes: 0)
        XCTAssertEqual(effective,
                       2_000_000_000 - ModelLifecycleBudget.safetyMarginBytes)
    }

    func testEffectiveBudgetRecoversCeilingFromResidentBytes() {
        // 2.0 GB headroom with 1.0 GB of our own models resident implies a
        // 3.0 GB ceiling — the budget must track the ceiling, not the
        // momentary headroom, or every load would shrink the budget.
        let withResident = ModelLifecycleBudget.effectiveBudgetBytes(
            deviceClass: .standard,
            availableBytes: 2_000_000_000,
            residentLiveBytes: 1_000_000_000)
        XCTAssertEqual(withResident,
                       3_000_000_000 - ModelLifecycleBudget.safetyMarginBytes)
    }

    // MARK: - 2. The inventory

    func testWhisperKitFootprintIsResidentAndHeavy() {
        let footprint = ModelLifecycleInventory.footprint(for: .speechToText,
                                                          modelID: sttQ8)
        XCTAssertEqual(footprint.role, .stt)
        XCTAssertTrue(footprint.isHeavy)
        XCTAssertEqual(footprint.residency, .residentWeights)
        XCTAssertEqual(footprint.releaseContract, .synchronousDrop)
        // ANE weights are not pageable: the hard cost is the whole thing.
        XCTAssertEqual(footprint.hardBytes, footprint.liveBytes)
        // 800 MB artifact + a 200 MB activation floor.
        XCTAssertEqual(footprint.liveBytes, 1_000_000_000)
    }

    func testWhisperCPPFootprintHasPageableWeights() {
        let footprint = ModelLifecycleInventory.footprint(
            for: .speechToText, modelID: ModelCatalog.whisperMediumFinetunedNepali)
        XCTAssertEqual(footprint.residency, .pageableWeights)
        XCTAssertEqual(footprint.releaseContract, .perAttemptContext)
        // The OS can take the mmap'd weight pages back; only the KV and the
        // mel/audio buffers are hard.
        XCTAssertLessThan(footprint.hardBytes, footprint.liveBytes)
        XCTAssertEqual(footprint.hardBytes,
                       ModelLifecycleInventory.whisperCPPOverheadBytes)
    }

    func testBrainFootprintsMatchTheCatalogMeasurements() {
        let fourB = ModelLifecycleInventory.footprint(for: .brain, modelID: brain4B)
        // Catalog: "2.5 GB file, ~3.5-4 GB live" — the 4B class row.
        XCTAssertEqual(fourB.liveBytes, fourB.weightsBytes + 900_000_000)
        XCTAssertEqual(fourB.residency, .pageableWeights)
        XCTAssertEqual(fourB.releaseContract, .actorDeferredFree)

        let oneSevenB = ModelLifecycleInventory.footprint(for: .brain,
                                                          modelID: brain17B)
        // Catalog: "1.3 GB file, live footprint ~2 GB".
        XCTAssertEqual(oneSevenB.liveBytes, oneSevenB.weightsBytes + 700_000_000)
    }

    func testEncoderAndCorrectorAreLight() {
        let encoder = ModelLifecycleInventory.footprint(for: .intentEncoder)
        XCTAssertEqual(encoder.role, .encoder)
        XCTAssertFalse(encoder.isHeavy)

        let corrector = ModelLifecycleInventory.footprint(for: .sttCorrector)
        XCTAssertEqual(corrector.role, .corrector)
        XCTAssertFalse(corrector.isHeavy)
        // Not a model at all: a bundled lexicon that lives for the process.
        XCTAssertEqual(corrector.residency, .processWide)
        XCTAssertEqual(corrector.releaseContract, .processLifetime)
    }

    // MARK: - 3. The no-two-heavy invariant

    func testFourBBrainEvictsResidentSTT() {
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)

        let brainOwner = FakeOwner()
        let admission = load(.brain, modelID: brain4B, owner: brainOwner)

        // THE invariant: on the 6 GB class these two never co-reside.
        XCTAssertEqual(admission, .allowed(evicted: [.speechToText]))
        XCTAssertEqual(sttOwner.unloadCount, 1, "STT must be really unloaded")
        XCTAssertFalse(manager.isResident(.speechToText))
        XCTAssertTrue(manager.isResident(.brain))
    }

    func testSeventeenBBrainCoResidesWithQ8STT() {
        // The numbers allow it: 1.0 GB (q8 ANE) + ~2.0 GB (1.7B) ≤ 3.2 GB.
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)

        let brainOwner = FakeOwner()
        let admission = load(.brain, modelID: brain17B, owner: brainOwner)

        XCTAssertEqual(admission, .allowed(evicted: []),
                       "the 1.7B brain is the pairing the budget was sized to admit")
        XCTAssertEqual(sttOwner.unloadCount, 0)
        XCTAssertTrue(manager.isResident(.speechToText))
        XCTAssertTrue(manager.isResident(.brain))
    }

    func testNonQ8WhisperKitEvictsTheSeventeenBBrain() {
        // The full 1.6 GB medium costs ~2.0 GB live, so 1.7B + it is 4.0 GB
        // — over budget. The task's invariant names the q8 artifact
        // precisely because the full one does NOT co-reside.
        let brainOwner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: brainOwner).isAllowed)

        let sttOwner = FakeOwner()
        let admission = load(.speechToText,
                             modelID: ModelCatalog.whisperKitNepaliMedium,
                             owner: sttOwner)

        XCTAssertEqual(admission, .allowed(evicted: [.brain]))
        XCTAssertEqual(brainOwner.unloadCount, 1)
    }

    func testLightModelsSurviveAHeavyEviction() {
        // Heavy-first eviction: the encoder is NOT sacrificed even though
        // it is the least recently used slot in the ledger, because freeing
        // 144 MB cannot close a gap a 2 GB brain opened.
        let encoderOwner = FakeOwner()
        manager.register(slot: .intentEncoder, modelID: nil,
                         owner: encoderOwner, evictable: true) { [weak encoderOwner] in
            encoderOwner?.unload()
        }
        manager.didLoad(.intentEncoder, owner: encoderOwner)
        // Make the encoder the least recently used thing in the ledger.
        now = now.addingTimeInterval(600)

        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)

        let brainOwner = FakeOwner()
        let admission = load(.brain, modelID: brain4B, owner: brainOwner)

        // The 4B brain is over budget on its own, so the light slots are
        // not even candidates: they could not have helped.
        XCTAssertEqual(admission, .allowed(evicted: [.speechToText]))
        XCTAssertEqual(encoderOwner.unloadCount, 0)
        XCTAssertTrue(manager.isResident(.intentEncoder))
    }

    func testLightModelIsEvictedWhenItCanActuallyCloseTheGap() {
        // The converse of the test above: when the incoming model DOES fit
        // under the budget, light models become candidates — because then
        // their bytes are what closes the remaining gap.
        //
        // A 2.1 GB budget makes the arithmetic explicit: q8 STT (1.0 GB) +
        // the encoder (0.14 GB) + the 1.7B brain (1.98 GB) is over, but the
        // brain ALONE is under — so the encoder is worth taking, and only
        // the light bytes can finish the job.
        let tight = makeManager(budget: 2_100_000_000)

        let encoderOwner = FakeOwner()
        tight.register(slot: .intentEncoder, modelID: nil,
                       owner: encoderOwner, evictable: true) { [weak encoderOwner] in
            encoderOwner?.unload()
        }
        tight.didLoad(.intentEncoder, owner: encoderOwner)

        let sttOwner = FakeOwner()
        tight.register(slot: .speechToText, modelID: sttQ8, owner: sttOwner) { [weak sttOwner] in
            sttOwner?.unload()
        }
        tight.didLoad(.speechToText, owner: sttOwner)

        let brainOwner = FakeOwner()
        tight.register(slot: .brain, modelID: brain17B, owner: brainOwner) { [weak brainOwner] in
            brainOwner?.unload()
        }
        let admission = tight.prepareLoad(of: .brain, modelID: brain17B)

        // Heavy first, light last — and the light one goes only because it
        // is load-bearing for the arithmetic.
        XCTAssertEqual(admission, .allowed(evicted: [.speechToText, .intentEncoder]))
        XCTAssertEqual(encoderOwner.unloadCount, 1)
        tight.didLoad(.brain, owner: brainOwner)
        XCTAssertLessThanOrEqual(tight.snapshot().residentLiveBytes,
                                 2_100_000_000)
    }

    // MARK: - 4. LRU ordering

    func testEvictionOrderIsLeastRecentlyUsedFirst() {
        // Admitted STT, then the brain, then TOUCHED THE BRAIN — so the
        // admission order and the recency order deliberately disagree: STT
        // is the least recently used even though it was admitted first.
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)

        now = now.addingTimeInterval(10)
        let brainOwner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: brainOwner).isAllowed)

        now = now.addingTimeInterval(10)
        manager.noteUse(of: .brain)

        // The squeeze needs both gone (1.0 GB + 1.98 GB against a 1.6 GB
        // target), so the ORDER of the returned victims is the assertion:
        // LRU first, admission order ignored.
        let evicted = manager.handleMemoryPressure()

        XCTAssertEqual(evicted, [.speechToText, .brain])
        XCTAssertEqual(sttOwner.unloadCount, 1)
        XCTAssertEqual(brainOwner.unloadCount, 1)
    }

    func testNoteUseReordersTheEvictionOrder() {
        // Same residents, but the brain is the LRU after the touch, and
        // evicting it alone brings the total under the pressure budget.
        let brainOwner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: brainOwner).isAllowed)

        now = now.addingTimeInterval(10)
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)

        // Touch STT: now the brain is the least recently used heavy, and
        // its 1.98 GB alone is what the squeeze needs.
        now = now.addingTimeInterval(10)
        manager.noteUse(of: .speechToText)

        let evicted = manager.handleMemoryPressure()
        XCTAssertEqual(evicted, [.brain],
                       "the touch, not the admission order, decides the victim")
        XCTAssertEqual(brainOwner.unloadCount, 1)
        XCTAssertEqual(sttOwner.unloadCount, 0)
        XCTAssertTrue(manager.isResident(.speechToText))
    }

    // MARK: - 5. Idle eviction on a fake clock

    func testIdleEvictionWaitsForTheThreshold() {
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)

        // Just under the threshold: nothing goes.
        now = now.addingTimeInterval(ModelLifecycleManager.defaultIdleEvictionSeconds - 1)
        XCTAssertEqual(manager.evictIdle(), [])
        XCTAssertTrue(manager.isResident(.speechToText))

        // At the threshold: the heavy model unloads.
        now = now.addingTimeInterval(1)
        XCTAssertEqual(manager.evictIdle(), [.speechToText])
        XCTAssertEqual(sttOwner.unloadCount, 1)
        XCTAssertFalse(manager.isResident(.speechToText))
    }

    func testIdleEvictionLeavesLightModelsAlone() {
        let encoderOwner = FakeOwner()
        manager.register(slot: .intentEncoder, modelID: nil,
                         owner: encoderOwner) { [weak encoderOwner] in
            encoderOwner?.unload()
        }
        manager.didLoad(.intentEncoder, owner: encoderOwner)

        now = now.addingTimeInterval(ModelLifecycleManager.defaultIdleEvictionSeconds * 10)
        XCTAssertEqual(manager.evictIdle(), [])
        XCTAssertTrue(manager.isResident(.intentEncoder))
    }

    func testIdleEvictionRespectsAPin() {
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)

        manager.beginUse(of: .speechToText)
        now = now.addingTimeInterval(ModelLifecycleManager.defaultIdleEvictionSeconds * 10)
        XCTAssertEqual(manager.evictIdle(), [],
                       "an in-flight use must never have its model pulled")
        XCTAssertEqual(sttOwner.unloadCount, 0)

        // Releasing the pin is itself a use: the model was in flight a
        // moment ago, so the idle clock restarts rather than expiring.
        manager.endUse(of: .speechToText)
        XCTAssertEqual(manager.evictIdle(), [])

        now = now.addingTimeInterval(ModelLifecycleManager.defaultIdleEvictionSeconds)
        XCTAssertEqual(manager.evictIdle(), [.speechToText])
        XCTAssertEqual(sttOwner.unloadCount, 1)
    }

    // MARK: - 6. Reload after eviction

    func testReloadAfterEvictionSucceedsAndIsCountedAgain() {
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)
        XCTAssertEqual(manager.snapshot().residentLiveBytes, 1_000_000_000)

        manager.evictIdle(now: now.addingTimeInterval(999))
        XCTAssertEqual(manager.snapshot().residentLiveBytes, 0)

        // The owner re-registers by going back through the gate, exactly as
        // the recognizer does on its next load.
        let admission = manager.prepareLoad(of: .speechToText, modelID: sttQ8)
        XCTAssertTrue(admission.isAllowed)
        manager.didLoad(.speechToText, owner: sttOwner)
        XCTAssertTrue(manager.isResident(.speechToText))
        XCTAssertEqual(manager.snapshot().residentLiveBytes, 1_000_000_000)
    }

    func testEvictedBrainCanReload() {
        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)
        let brainOwner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain4B, owner: brainOwner).isAllowed)
        XCTAssertFalse(manager.isResident(.speechToText))

        // Loading STT again evicts the brain (it is the only evictable heavy).
        let admission = manager.prepareLoad(of: .speechToText, modelID: sttQ8)
        XCTAssertEqual(admission, .allowed(evicted: [.brain]))
        manager.didLoad(.speechToText, owner: sttOwner)
        XCTAssertFalse(manager.isResident(.brain))

        // And the brain reloads afterwards, evicting STT in turn.
        let second = manager.prepareLoad(of: .brain, modelID: brain4B)
        XCTAssertEqual(second, .allowed(evicted: [.speechToText]))
        manager.didLoad(.brain, owner: brainOwner)
        XCTAssertTrue(manager.isResident(.brain))
    }

    // MARK: - 7. The solo escape hatch

    func testOverBudgetModelAloneIsAdmittedAndAnnounced() {
        // A 4B brain is ~3.4 GB live — over the 3.2 GB class budget on its
        // own. Refusing it would make the app's DEFAULT brain unloadable.
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }

        let brainOwner = FakeOwner()
        let admission = load(.brain, modelID: brain4B, owner: brainOwner)

        XCTAssertTrue(admission.isAllowed)
        let expected = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: brain4B).liveBytes
        XCTAssertTrue(events.contains(.soloOverBudget(
            slot: .brain, liveBytes: expected, budgetBytes: budget)),
            "an over-budget admission must never be silent")
    }

    // MARK: - 8. Denials

    func testInsufficientHeadroomDeniesTheLoad() {
        let brainOwner = FakeOwner()
        register(.brain, modelID: brain4B, owner: brainOwner)
        // The probe says the app has 200 MB left; the brain's NON-pageable
        // bytes alone exceed that.
        probe.availableProcessMemoryBytes = 200_000_000

        let admission = manager.prepareLoad(of: .brain, modelID: brain4B)
        XCTAssertEqual(admission, .denied(.insufficientHeadroom))
        XCTAssertEqual(brainOwner.unloadCount, 0)
    }

    func testPinnedResidentBlocksALoadThatWouldCrossTheBudget() {
        let brainOwner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain4B, owner: brainOwner).isAllowed)
        manager.beginUse(of: .brain)   // an inference is in flight

        let sttOwner = FakeOwner()
        register(.speechToText, modelID: sttQ8, owner: sttOwner)
        let admission = manager.prepareLoad(of: .speechToText, modelID: sttQ8)

        XCTAssertEqual(admission, .denied(.budgetExhausted))
        XCTAssertEqual(brainOwner.unloadCount, 0)
        XCTAssertEqual(sttOwner.unloadCount, 0)

        // Once the inference settles the load goes through — by evicting
        // the brain, which is then reloadable on demand.
        manager.endUse(of: .brain)
        XCTAssertEqual(manager.prepareLoad(of: .speechToText, modelID: sttQ8),
                       .allowed(evicted: [.brain]))
    }

    func testUnregisteredSlotIsDenied() {
        XCTAssertEqual(manager.prepareLoad(of: .brain, modelID: brain4B),
                       .denied(.unregisteredSlot))
    }

    // MARK: - 9. Owner scoping and dead owners

    func testResidencyUpdatesAreOwnerScoped() {
        // `.speechToText` is one slot with two possible engines; whichever
        // registered last owns it, and the other's updates are ignored.
        let whisperKit = FakeOwner()
        register(.speechToText, modelID: sttQ8, owner: whisperKit)
        manager.didLoad(.speechToText, owner: whisperKit)
        XCTAssertTrue(manager.isResident(.speechToText))

        let whisperCPP = FakeOwner()
        register(.speechToText, modelID: sttQ8, owner: whisperCPP)
        // The other engine's release must not clear the live owner's state.
        manager.didUnload(.speechToText, owner: whisperKit)
        XCTAssertTrue(manager.isResident(.speechToText))

        manager.didUnload(.speechToText, owner: whisperCPP)
        XCTAssertFalse(manager.isResident(.speechToText))
    }

    func testDeadOwnerStopsCountingTowardTheBudget() {
        var owner: FakeOwner? = FakeOwner()
        register(.brain, modelID: brain4B, owner: owner!)
        manager.didLoad(.brain, owner: owner!)
        XCTAssertEqual(manager.snapshot().residentLiveBytes,
                       ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: brain4B).liveBytes)

        owner = nil
        XCTAssertEqual(manager.snapshot().residentLiveBytes, 0,
                       "a deallocated owner can never be released — its bytes "
                       + "must stop reserving budget")
    }

    func testProcessWideSlotIsNotPruned() {
        // The corrector has no owner by construction; it must still count.
        manager.register(slot: .sttCorrector, modelID: nil, owner: nil) {}
        manager.didLoad(.sttCorrector)
        XCTAssertTrue(manager.isResident(.sttCorrector))
        XCTAssertEqual(manager.snapshot().residentLiveBytes,
                       ModelLifecycleInventory.correctorLexiconBytes)
    }

    // MARK: - 10. Memory pressure

    func testMemoryPressureSqueezesToHalfTheClassBudget() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }

        let sttOwner = FakeOwner()
        XCTAssertTrue(load(.speechToText, modelID: sttQ8, owner: sttOwner).isAllowed)
        now = now.addingTimeInterval(10)   // STT is now unambiguously the LRU
        let brainOwner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: brainOwner).isAllowed)

        let evicted = manager.handleMemoryPressure()

        // 3.2 GB class budget → the level-2 squeeze target is 1.6 GB.
        // Resident is 1.0 + 1.98 GB; evicting the LRU heavy (STT) leaves
        // 1.98 GB, still over, so the sweep continues and the brain goes
        // too. That is the intended aggression for a real memory warning.
        XCTAssertEqual(evicted, [.speechToText, .brain])
        XCTAssertEqual(sttOwner.unloadCount, 1)
        XCTAssertEqual(brainOwner.unloadCount, 1)
        XCTAssertLessThanOrEqual(manager.snapshot().residentLiveBytes,
                                 UInt64(Double(budget)
                                        * ModelLifecycleManager.memoryPressureBudgetFraction))
        XCTAssertTrue(events.contains { if case .memoryPressure = $0 { return true }
                                        ; return false })
    }
}
