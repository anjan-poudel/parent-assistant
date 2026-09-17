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
        /// Defaults to 0 — the protocol's "not measured" value — so every
        /// test written before Step 0 keeps the behaviour it was written
        /// against, and the sample tests below opt in explicitly.
        var physFootprintBytes: UInt64

        init(physicalMemoryBytes: UInt64 = 6_000_000_000,
             availableProcessMemoryBytes: UInt64 = 3_400_000_000,
             physFootprintBytes: UInt64 = 0) {
            self.physicalMemoryBytes = physicalMemoryBytes
            self.availableProcessMemoryBytes = availableProcessMemoryBytes
            self.physFootprintBytes = physFootprintBytes
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

    func testIntentBrainIsAHeavyBrainWithItsOwnSlot() {
        // [TRUNCATION-FIX] The local intent interpreter's 1B handle now
        // has a ledger row of its own — the same 1.7B arithmetic as the
        // picker brain, and heavy, so budget math can never again admit
        // a 4B on top of it as if it did not exist.
        let intent = ModelLifecycleInventory.footprint(for: .intentBrain,
                                                       modelID: ModelCatalog.intentNepali1B)
        XCTAssertEqual(intent.role, .brain)
        XCTAssertTrue(intent.isHeavy)
        XCTAssertEqual(intent.residency, .pageableWeights)
        XCTAssertEqual(intent.releaseContract, .actorDeferredFree)
        XCTAssertGreaterThan(intent.liveBytes, 1_000_000_000,
                             "the 1.1 GB artifact plus runtime overhead is a >1 GB resident")
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

    // MARK: - 11. [MODEL-WARDEN] Step 1 — the reservation
    //
    // Step 0 made the ledger honest; Step 1 makes an *admitted* load a
    // reservation. The hole these cases pin is the interval between the
    // decision and `didLoad`, where the incoming bytes used to be counted
    // by nobody: `peak_footprint = M + T + W`, and `T` did not exist.
    //
    // The scripted probe and the injected clock make every case here
    // deterministic — no case sleeps, and none depends on the host's RAM.

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

    func testReserveCountsTheIncomingBytesAndCommitRetiresThem() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }
        let owner = FakeOwner()
        register(.brain, modelID: brain4B, owner: owner)
        let live = ModelLifecycleInventory.footprint(for: .brain,
                                                     modelID: brain4B).liveBytes

        guard let reservation = reserveOrFail(
            manager, request(.brain, modelID: brain4B, owner: owner)) else { return }

        // `T(t)` is non-zero for exactly the interval the load occupies —
        // the interval a second admitted load used to be budgeted against
        // as if it were free.
        XCTAssertEqual(reservation.liveBytes, live)
        XCTAssertTrue(reservation.isLargeLoad)
        XCTAssertEqual(manager.snapshot().transientLiveBytes, live)
        XCTAssertEqual(manager.inFlightReservations().map(\.slot), [.brain])
        XCTAssertTrue(events.contains(.reserved(slot: .brain,
                                                liveBytes: live,
                                                purpose: .voiceTurn,
                                                isLargeLoad: true)))

        manager.commit(reservation)

        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0)
        XCTAssertTrue(manager.inFlightReservations().isEmpty)
        XCTAssertTrue(events.contains(.reservationCommitted(slot: .brain,
                                                            heldSeconds: 0)),
                      "commit must report how long the permit was held")
    }

    func testReserveThenAbandonReleasesTheBytesAndSaysWhy() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)

        guard let reservation = reserveOrFail(
            manager, request(.brain, modelID: brain17B, owner: owner)) else { return }
        manager.abandon(reservation, reason: .loadFailed)

        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0)
        XCTAssertTrue(events.contains(.reservationAbandoned(slot: .brain,
                                                            reason: .loadFailed)))
        // The permit is not sticky: the next ask is judged on its own
        // merits rather than on the corpse of the last one.
        XCTAssertNotNil(reserveOrFail(
            manager, request(.brain, modelID: brain17B, owner: owner)))
    }

    func testReservationTTLReapsALoadThatNeverCommitted() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)
        guard let reservation = reserveOrFail(
            manager, request(.brain, modelID: brain17B, owner: owner)) else { return }

        // One second short of the TTL the load is still in flight and
        // still holding its bytes.
        now = now.addingTimeInterval(ModelWardenConfig.default.reservationTTLSeconds - 1)
        XCTAssertTrue(manager.reapExpiredReservations().isEmpty)
        XCTAssertEqual(manager.snapshot().transientLiveBytes, reservation.liveBytes)

        now = now.addingTimeInterval(2)
        let reaped = manager.reapExpiredReservations()

        XCTAssertEqual(reaped.map(\.id), [reservation.id])
        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0)
        XCTAssertTrue(events.contains(.reservationAbandoned(slot: .brain,
                                                            reason: .ttlExpired)))
    }

    func testReservationPastTheWatchdogIsReapedUnderItsOwnReason() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)
        _ = reserveOrFail(manager, request(.brain, modelID: brain17B, owner: owner))

        now = now.addingTimeInterval(ModelWardenConfig.default.loadWatchdogSeconds)

        XCTAssertEqual(manager.reapExpiredReservations().count, 1)
        XCTAssertTrue(events.contains(.reservationAbandoned(
            slot: .brain, reason: .watchdogExpired)),
            "the watchdog is evidence, the TTL is housekeeping — the "
            + "reasons must not be conflated")
    }

    func testSecondReservationOnTheSameSlotIsRejected() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)
        _ = reserveOrFail(manager, request(.brain, modelID: brain17B, owner: owner))

        let second = manager.reserve(request(.brain,
                                             modelID: brain17B,
                                             owner: owner))

        guard case .failure(let denial) = second else {
            return XCTFail("a second reservation on one pipeline position "
                           + "would double-book the position's bytes")
        }
        XCTAssertEqual(denial, .alreadyReserved(slot: .brain, holder: .voiceTurn))
        XCTAssertEqual(denial.token, "already_reserved")
        XCTAssertFalse(denial.token.contains("("),
                       "the bus token must be content-free")
    }

    func testTwoLargeLoadsAreNeverInFlightTogether() {
        let sttOwner = FakeOwner()
        register(.speechToText, modelID: sttQ8, owner: sttOwner)
        let ttsOwner = FakeOwner()
        register(.ttsVoices, modelID: nil, owner: ttsOwner)
        let brainOwner = FakeOwner()
        register(.brain, modelID: brain4B, owner: brainOwner)

        // 1. The ANE load takes the serial slot…
        guard let stt = reserveOrFail(
            manager, request(.speechToText, modelID: sttQ8, owner: sttOwner)),
              // 2. …and a SMALL load is not serialized behind it (the cap
              //    is on the spike, and a voice cache is not a spike).
              let tts = reserveOrFail(
                manager, request(.ttsVoices, modelID: nil, owner: ttsOwner))
        else { return }
        // 3. A second LARGE load is refused, and the refusal names the
        //    load it is waiting behind.
        guard case .failure(let denial) = manager.reserve(
            request(.brain, modelID: brain4B, owner: brainOwner)) else {
            return XCTFail("two large page-ins at once is the spike the "
                           + "watchdog kills for")
        }
        XCTAssertEqual(denial, .loadInFlight(holder: .speechToText))
        XCTAssertEqual(denial.token, "load_in_flight")
        // 4. Fail-fast, not queue: the refusal was synchronous, and once
        //    the first load hands its permit back the queue is free again.
        manager.abandon(tts, reason: .loadFailed)
        manager.abandon(stt, reason: .cancelled)
        XCTAssertNotNil(reserveOrFail(
            manager, request(.brain, modelID: brain4B, owner: brainOwner)))
    }

    func testTheTransientTermIsWhatRefusesTheSecondLoad() {
        // The pinned budget is one byte short of the two loads together, so
        // the ONLY thing that can refuse the second ask is the first one's
        // uncommitted reservation — nothing is resident, and the second ask
        // fits on its own.
        let sttLive = ModelLifecycleInventory.footprint(for: .speechToText,
                                                        modelID: sttQ8).liveBytes
        let ttsLive = ModelLifecycleInventory.footprint(for: .ttsVoices,
                                                        modelID: nil).liveBytes
        let tight = makeManager(budget: sttLive + ttsLive - 1)
        let sttOwner = FakeOwner()
        tight.register(slot: .speechToText, modelID: sttQ8, owner: sttOwner) {}
        let ttsOwner = FakeOwner()
        tight.register(slot: .ttsVoices, modelID: nil, owner: ttsOwner) {}

        guard let stt = reserveOrFail(
            tight, request(.speechToText, modelID: sttQ8, owner: sttOwner))
        else { return }
        XCTAssertEqual(tight.snapshot().residentLiveBytes, 0)

        guard case .failure(let denial) = tight.reserve(
            request(.ttsVoices, modelID: nil, owner: ttsOwner)) else {
            return XCTFail("the in-flight load's bytes were not counted")
        }
        guard case .budgetExhausted = denial else {
            return XCTFail("expected a budget refusal, got \(denial)")
        }
        // …and the refusal is provisional, not sticky.
        tight.abandon(stt, reason: .loadFailed)
        XCTAssertNotNil(reserveOrFail(
            tight, request(.ttsVoices, modelID: nil, owner: ttsOwner)))
    }

    func testFailFastRefusalOnInsufficientHeadroom() {
        let owner = FakeOwner()
        register(.brain, modelID: brain4B, owner: owner)
        // 200 MB left; the brain's non-pageable bytes alone exceed that, so
        // no amount of eviction helps and the honest answer is "not now".
        probe.availableProcessMemoryBytes = 200_000_000

        guard case .failure(let denial) = manager.reserve(
            request(.brain, modelID: brain4B, owner: owner)) else {
            return XCTFail("a model whose hard bytes exceed the headroom "
                           + "must be refused, not attempted")
        }
        guard case .insufficientHeadroom = denial else {
            return XCTFail("expected the headroom refusal, got \(denial)")
        }
        XCTAssertEqual(denial.token, "insufficient_headroom")
        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0,
                       "a refused load reserves nothing")
    }

    func testCriticalPressureCancelsEveryPendingReservation() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)
        _ = reserveOrFail(manager, request(.brain, modelID: brain17B, owner: owner))

        manager.handleMemoryPressure(level: .critical)

        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0)
        XCTAssertTrue(events.contains(.reservationAbandoned(
            slot: .brain, reason: .memoryPressure)),
            "a permission to create a spike must not survive the kernel "
            + "saying it is out of memory")
    }

    func testBackgroundingWithdrawsPendingReservationsButKeepsResidents() {
        let brainOwner = FakeOwner()
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: brainOwner).isAllowed)
        let ttsOwner = FakeOwner()
        register(.ttsVoices, modelID: nil, owner: ttsOwner)
        _ = reserveOrFail(manager, request(.ttsVoices, modelID: nil, owner: ttsOwner))

        let withdrawn = manager.cancelPendingReservations(reason: .backgrounded)

        XCTAssertEqual(withdrawn.map(\.slot), [.ttsVoices])
        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0)
        // Residency is the eviction policy's business, not the scene's:
        // backgrounding must not cost the ANE specialization.
        XCTAssertTrue(manager.isResident(.brain))
        XCTAssertEqual(brainOwner.unloadCount, 0)
    }

    func testDeadOwnerReservationIsReapedRatherThanKeptAlive() {
        var owner: FakeOwner? = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner!)
        _ = reserveOrFail(manager, request(.brain, modelID: brain17B, owner: owner!))

        owner = nil   // the load site died with the load in flight

        XCTAssertEqual(manager.reapExpiredReservations().count, 1)
        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0)
    }

    func testOwnerlessReservationSurvivesGCUntilItsTTL() {
        // A maintenance load with no owner has no owner to observe dying;
        // it must be reaped by the clock, never mistaken for an abandoned
        // one on the next unrelated reserve.
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)
        guard let reservation = reserveOrFail(
            manager, request(.brain, modelID: brain17B, owner: nil)) else { return }

        // An unrelated load's gate runs the GC. The ownerless reservation
        // must survive it — it has an owner-shaped hole, not a dead owner.
        XCTAssertNotNil(reserveOrFail(
            manager, request(.ttsVoices, modelID: nil, owner: owner)))

        XCTAssertTrue(manager.inFlightReservations().contains {
            $0.id == reservation.id
        })
        XCTAssertGreaterThanOrEqual(manager.snapshot().transientLiveBytes,
                                    reservation.liveBytes)
    }

    func testAStoppedLoadDoesNotStrandTheNextCaller() {
        // The composition the two migrated load sites depend on: the tier
        // races its load against a deadline (and deliberately does not
        // cancel the loser), the voice interpreter stops its decode on
        // cancellation. Both end in the same warden call — `abandon` — and
        // what that call must guarantee is that the NEXT caller is judged
        // on a free ledger rather than blocked behind a load nobody is
        // waiting for.
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)

        guard let tier = reserveOrFail(manager, request(.brain,
                                                        modelID: brain17B,
                                                        owner: owner,
                                                        purpose: .liveTranslate))
        else { return }
        manager.abandon(tier, reason: .cancelled)   // the deadline won

        guard let turn = reserveOrFail(manager, request(.brain,
                                                       modelID: brain17B,
                                                       owner: owner,
                                                       purpose: .voiceTurn))
        else { return }
        XCTAssertEqual(turn.purpose, .voiceTurn)
        manager.abandon(turn, reason: .cancelled)

        XCTAssertNotNil(reserveOrFail(manager, request(.brain,
                                                      modelID: brain17B,
                                                      owner: owner,
                                                      purpose: .liveTranslate)))
    }

    func testPrepareLoadStillCommitsItsOwnReservation() {
        // `prepareLoad` is the synchronous fast path, expressed in terms of
        // reserve + commit: the decision is identical and nothing is left
        // in the transient term afterwards.
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)

        XCTAssertEqual(manager.prepareLoad(of: .brain, modelID: brain17B),
                       .allowed(evicted: []))
        XCTAssertEqual(manager.snapshot().transientLiveBytes, 0)
        XCTAssertTrue(manager.inFlightReservations().isEmpty)
    }

    // MARK: - 12. [MODEL-WARDEN] Step 0 — the footprint sample

    func testTheFootprintSampleRidesWithTheLoadItMeasures() {
        // The ledger's total is arithmetic; `phys_footprint` is the kernel's
        // own number. They are only comparable if the sample is taken at the
        // moment the bytes land, which is what this pins.
        probe.physFootprintBytes = 1_234_000_000
        probe.availableProcessMemoryBytes = 2_000_000_000
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }

        XCTAssertTrue(load(.brain, modelID: brain17B, owner: FakeOwner()).isAllowed)

        let live = ModelLifecycleInventory.footprint(for: .brain,
                                                     modelID: brain17B).liveBytes
        XCTAssertTrue(events.contains(.footprintSample(
            physFootprintBytes: 1_234_000_000,
            // Ceiling and footprint are reported as a pair: the reading that
            // says how much is spent is meaningless without the one that
            // says how much there is.
            ceilingBytes: 3_234_000_000,
            residentLiveBytes: live,
            transientLiveBytes: 0)),
            "a committed load must report the kernel's own footprint")
        XCTAssertEqual(manager.snapshot().physFootprintBytes, 1_234_000_000)
    }

    func testAProbeThatCannotReadTheFootprintReportsSilence() {
        // 0 is the honest "not measured" value, so the sample is skipped
        // rather than emitted as a real-looking reading of zero bytes.
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }

        XCTAssertTrue(load(.brain, modelID: brain17B, owner: FakeOwner()).isAllowed)

        XCTAssertFalse(events.contains { if case .footprintSample = $0 { return true }
                                         return false },
                       "a failed probe must not fabricate a footprint")
        XCTAssertEqual(manager.snapshot().physFootprintBytes, 0)
    }
}
