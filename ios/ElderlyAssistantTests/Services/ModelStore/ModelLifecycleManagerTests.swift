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
                          evictable: Bool = true,
                          priority: ModelPriority = .foreground,
                          resident: ModelResident? = nil) -> FakeOwner {
        manager.register(slot: slot, modelID: modelID, owner: owner,
                         evictable: evictable, priority: priority,
                         resident: resident) { [weak owner] in
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

    // MARK: - 13. [MODEL-WARDEN] Step 2 — priority, preemption, the thrash guard
    //
    // Step 1 made a load a *permit*; Step 2 makes the permit recallable. Three
    // properties are pinned here, and each one is a rule rather than a
    // mechanism:
    //
    //  - the victim walk reads the **ladder** before the clock (a background
    //    resident goes before a foreground one, however recently it was used);
    //  - an owner can be **asked** before its bytes are taken, and the answer
    //    decides whether the registered release path runs at all — with the
    //    one hard exception that `perAttemptContext` (whisper.cpp) is never
    //    forced, because `whisper_free` under a running `whisper_full`
    //    crashes;
    //  - an evict-then-reload loop is **damped** rather than served, so the
    //    warden cannot spend the session thrashing one slot.

    /// An owner that can be asked rather than only told. Records every ask so
    /// a case can prove the ask happened — including the refusals the warden
    /// obeyed, which are the ones no closure call would otherwise reveal.
    private final class FakeResident: ModelResident {
        private(set) var askCount = 0
        var ack: UnloadAck = .released
        func releaseForWarden() -> UnloadAck {
            askCount += 1
            return ack
        }
    }

    private func footprint(_ slot: ModelSlot, _ modelID: ModelID? = nil) -> UInt64 {
        ModelLifecycleInventory.footprint(for: slot, modelID: modelID).liveBytes
    }

    private func preemptedEvents(_ events: [ModelLifecycleEvent]) -> [PreemptionOutcome] {
        events.compactMap {
            if case .preempted(_, let outcome) = $0 { return outcome }
            return nil
        }
    }

    func testTheLadderIsThePurposeLadder() {
        // The priorities are derived from the purpose, not passed in beside
        // it: a load site cannot claim a `.voiceTurn` and carry a background
        // rung, which is the shape that would let a prefetch preempt a turn.
        XCTAssertEqual(ReservationPurpose.voiceTurn.priority, .safetyCritical)
        XCTAssertEqual(ReservationPurpose.liveTranslate.priority, .foreground)
        XCTAssertEqual(ReservationPurpose.warm.priority, .background)
        XCTAssertEqual(ReservationPurpose.maintenance.priority, .background)
        XCTAssertLessThan(ModelPriority.background, .foreground)
        XCTAssertLessThan(ModelPriority.foreground, .safetyCritical)

        XCTAssertEqual(request(.brain, modelID: brain17B, owner: nil,
                               purpose: .liveTranslate).priority,
                       .foreground)
        XCTAssertEqual(request(.brain, modelID: brain17B, owner: nil,
                               purpose: .voiceTurn).priority,
                       .safetyCritical)
    }

    func testTheVictimWalkReadsTheLadderBeforeTheClock() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }

        let ttsLive = footprint(.ttsVoices)
        let correctorLive = footprint(.sttCorrector)
        let vadLive = footprint(.vad)
        // One byte short of holding everything: exactly one eviction is
        // enough, so WHICH resident goes is the whole assertion.
        let tight = makeManager(budget: ttsLive + correctorLive + vadLive - 1)

        // The corrector is the least recently used — Step 1's LRU walk would
        // take it. It is also `.foreground`, which is why the ladder does not.
        let correctorOwner = FakeOwner()
        tight.register(slot: .sttCorrector, modelID: nil, owner: correctorOwner,
                       priority: .foreground) { [weak correctorOwner] in
            correctorOwner?.unload()
        }
        tight.didLoad(.sttCorrector, owner: correctorOwner)
        now = now.addingTimeInterval(600)

        let ttsOwner = FakeOwner()
        tight.register(slot: .ttsVoices, modelID: nil, owner: ttsOwner,
                       priority: .background) { [weak ttsOwner] in
            ttsOwner?.unload()
        }
        tight.didLoad(.ttsVoices, owner: ttsOwner)

        let vadOwner = FakeOwner()
        guard let reservation = reserveOrFail(
            tight, request(.vad, modelID: nil, owner: vadOwner)) else { return }

        XCTAssertEqual(reservation.evicted, [.ttsVoices],
                       "a background resident's bytes go before a foreground "
                       + "one's, however recently used")
        XCTAssertEqual(ttsOwner.unloadCount, 1)
        XCTAssertEqual(correctorOwner.unloadCount, 0)
        XCTAssertFalse(tight.isResident(.ttsVoices))
        XCTAssertTrue(tight.isResident(.sttCorrector))
    }

    func testAPreemptedOwnerThatReleasesIsNotAlsoUnloaded() {
        var events: [ModelLifecycleEvent] = []
        let tight = makeManager(budget: footprint(.ttsVoices) + footprint(.brain, brain17B) - 1)
        // The case's manager, not `setUp`'s: the asks are made by the ledger
        // the reservation was taken on, and an event sink on the other one
        // would observe nothing at all.
        tight.onEvent = { events.append($0) }

        let ttsOwner = FakeOwner()
        let resident = FakeResident()   // .released
        tight.register(slot: .ttsVoices, modelID: nil, owner: ttsOwner,
                       priority: .background, resident: resident) { [weak ttsOwner] in
            ttsOwner?.unload()
        }
        tight.didLoad(.ttsVoices, owner: ttsOwner)

        guard let reservation = reserveOrFail(
            tight, request(.brain, modelID: brain17B, owner: ttsOwner)) else { return }

        XCTAssertEqual(resident.askCount, 1, "the warden must ask, not only take")
        XCTAssertEqual(ttsOwner.unloadCount, 0,
                       "the owner gave the bytes back on the ask; invoking the "
                       + "registered release path as well would drop a handle "
                       + "that is already gone")
        XCTAssertEqual(reservation.preempted,
                       [PreemptionRecord(slot: .ttsVoices, outcome: .released)])
        XCTAssertEqual(preemptedEvents(events), [.released])
        XCTAssertFalse(tight.isResident(.ttsVoices))
    }

    func testARefusalOnADeferredFreeSlotIsForced() {
        var events: [ModelLifecycleEvent] = []
        let intentID = ModelCatalog.intentNepali1B
        let sttID = ModelCatalog.whisperMediumFinetunedNepali
        let tight = makeManager(budget: footprint(.intentBrain, intentID)
                                + footprint(.speechToText, sttID) - 1)
        tight.onEvent = { events.append($0) }

        let intentOwner = FakeOwner()
        let resident = FakeResident()
        resident.ack = .refused(.inUse)
        tight.register(slot: .intentBrain, modelID: intentID, owner: intentOwner,
                       priority: .background, resident: resident) { [weak intentOwner] in
            intentOwner?.unload()
        }
        tight.didLoad(.intentBrain, owner: intentOwner)

        guard let reservation = reserveOrFail(
            tight, request(.speechToText, modelID: sttID, owner: intentOwner)) else { return }

        XCTAssertEqual(resident.askCount, 1)
        XCTAssertEqual(intentOwner.unloadCount, 1,
                       "a llama handle is `actorDeferredFree`: the free is "
                       + "deferred by ARC, so a refusal can be overruled")
        XCTAssertEqual(reservation.preempted,
                       [PreemptionRecord(slot: .intentBrain,
                                         outcome: .forced(reason: .inUse))])
        XCTAssertEqual(preemptedEvents(events), [.forced(reason: .inUse)])
        XCTAssertFalse(tight.isResident(.intentBrain))
    }

    func testARefusalOnAPerAttemptContextSlotIsObeyed() {
        var events: [ModelLifecycleEvent] = []
        let sttID = ModelCatalog.whisperMediumFinetunedNepali
        let tight = makeManager(budget: footprint(.speechToText, sttID)
                                + footprint(.brain, brain17B) - 1)
        tight.onEvent = { events.append($0) }

        let sttOwner = FakeOwner()
        let resident = FakeResident()
        resident.ack = .refused(.inUse)
        tight.register(slot: .speechToText, modelID: sttID, owner: sttOwner,
                       priority: .background, resident: resident) { [weak sttOwner] in
            sttOwner?.unload()
        }
        tight.didLoad(.speechToText, owner: sttOwner)

        guard case .failure(let denial) = tight.reserve(
            request(.brain, modelID: brain17B, owner: sttOwner)) else {
            return XCTFail("whisper_free under a running whisper_full crashes: "
                           + "a refusal that cannot be forced has to become a "
                           + "refused LOAD, not a freed handle")
        }

        XCTAssertEqual(denial, .budgetExhausted(by: .speechToText))
        XCTAssertEqual(denial.token, "budget_exhausted")
        XCTAssertEqual(resident.askCount, 1)
        XCTAssertEqual(sttOwner.unloadCount, 0,
                       "the one rule this protocol will not bend: "
                       + "`perAttemptContext` is never forced")
        XCTAssertTrue(tight.isResident(.speechToText),
                      "a refusal the warden obeys hands the bytes back to the "
                      + "ledger — they were never taken")
        XCTAssertEqual(preemptedEvents(events), [.refused(reason: .inUse)])
        XCTAssertFalse(events.contains(.evicted(slot: .speechToText, reason: .budget)),
                       "a refusal is not an eviction")
        XCTAssertFalse(events.contains(.evicted(slot: .speechToText, reason: .preemption)))
    }

    func testTheThrashGuardDampsAnEvictAndReloadLoop() {
        var events: [ModelLifecycleEvent] = []
        let config = ModelWardenConfig.default
        let tight = makeManager(budget: footprint(.ttsVoices)
                                + footprint(.brain, brain17B) - 1)
        tight.onEvent = { events.append($0) }

        let ttsOwner = FakeOwner()
        tight.register(slot: .ttsVoices, modelID: nil, owner: ttsOwner) { [weak ttsOwner] in
            ttsOwner?.unload()
        }
        let brainOwner = FakeOwner()

        // The loop the guard exists to break: take the voices for a translate
        // load, hand them back, take them again — each round a load-driven
        // eviction of the SAME resident. The purpose is `.liveTranslate`
        // rather than `.voiceTurn` on purpose: a live voice turn is exempt
        // from the guard (see `guardSparedLocked`), so a turn would evict the
        // fourth time too and this case would pin the exemption instead of
        // the damping.
        for _ in 0..<config.preemptionsBeforeQuarantine {
            tight.didLoad(.ttsVoices, owner: ttsOwner)
            guard let reservation = reserveOrFail(tight, request(
                .brain, modelID: brain17B, owner: brainOwner,
                purpose: .liveTranslate)) else { return }
            tight.abandon(reservation, reason: .cancelled)
        }
        XCTAssertEqual(ttsOwner.unloadCount, config.preemptionsBeforeQuarantine)

        tight.didLoad(.ttsVoices, owner: ttsOwner)
        guard case .failure(let denial) = tight.reserve(request(
            .brain, modelID: brain17B, owner: brainOwner,
            purpose: .liveTranslate)) else {
            return XCTFail("the guard must refuse the load rather than evict "
                           + "the same resident for the fourth time")
        }

        XCTAssertEqual(denial.token, "thrash_guarded")
        XCTAssertEqual(denial.thrashGuardFiring?.slot, .ttsVoices)
        XCTAssertEqual(denial.thrashGuardFiring?.kind, .victimSpared)
        XCTAssertEqual(ttsOwner.unloadCount, config.preemptionsBeforeQuarantine,
                       "the spared resident was not evicted for the load that "
                       + "was refused")
        XCTAssertTrue(tight.isResident(.ttsVoices))
        XCTAssertTrue(events.contains {
            if case .thrashGuarded(.ttsVoices, .victimSpared, _) = $0 { return true }
            return false
        }, "the firing is reported in the ledger's own vocabulary")

        // Damping, not a wedge: the quarantine expires and the same load is
        // judged on its merits again.
        now = now.addingTimeInterval(config.preemptionQuarantineSeconds + 1)
        XCTAssertNotNil(reserveOrFail(tight, request(
            .brain, modelID: brain17B, owner: brainOwner,
            purpose: .liveTranslate)))
    }

    func testTheLoadRateCapBoundsLargePageInsInsideTheMinute() {
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }
        let owner = FakeOwner()
        register(.brain, modelID: brain17B, owner: owner)
        let cap = ModelWardenConfig.default.maxLoadsPerMinute

        for _ in 0..<cap {
            guard let reservation = reserveOrFail(manager, request(
                .brain, modelID: brain17B, owner: owner,
                purpose: .liveTranslate)) else { return }
            manager.abandon(reservation, reason: .loadFailed)
        }

        guard case .failure(let denial) = manager.reserve(request(
            .brain, modelID: brain17B, owner: owner, purpose: .liveTranslate)) else {
            return XCTFail("\(cap) large page-ins inside one rolling minute is "
                           + "the churn the cap exists to bound")
        }
        XCTAssertEqual(denial.token, "thrash_guarded")
        XCTAssertEqual(denial.thrashGuardFiring?.kind, .loadRateExceeded)
        XCTAssertEqual(denial.thrashGuardFiring?.count, cap)
        XCTAssertTrue(events.contains {
            if case .thrashGuarded(_, .loadRateExceeded, let count) = $0 {
                return count == cap
            }
            return false
        }, "the firing is reported in the ledger's own vocabulary")

        // The guard is a config surface, not a constant in the branch.
        manager.wardenConfig.thrashGuardEnabled = false
        guard let unguarded = reserveOrFail(manager, request(
            .brain, modelID: brain17B, owner: owner,
            purpose: .liveTranslate)) else { return }
        manager.abandon(unguarded, reason: .loadFailed)
        manager.wardenConfig.thrashGuardEnabled = true

        // Two exemptions, both deliberate: the synchronous maintenance path
        // (not a feature loop) and a live voice turn (the household is
        // waiting — the guard damps churn, it does not stand between the
        // user and an answer).
        guard let maintenance = reserveOrFail(manager, request(
            .brain, modelID: brain17B, owner: owner, purpose: .maintenance)) else { return }
        manager.abandon(maintenance, reason: .loadFailed)
        guard let turn = reserveOrFail(manager, request(
            .brain, modelID: brain17B, owner: owner, purpose: .voiceTurn)) else { return }
        XCTAssertEqual(turn.priority, .safetyCritical)
        manager.abandon(turn, reason: .loadFailed)

        // …and the window is rolling, not a latch.
        now = now.addingTimeInterval(61)
        XCTAssertNotNil(reserveOrFail(manager, request(
            .brain, modelID: brain17B, owner: owner, purpose: .liveTranslate)))
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

    // MARK: - 14. [PRESSURE-SAFE LOAD] the kernel's reading

    /// The ledger is the only object in the app that hears the kernel's
    /// memory-pressure level, and until this it only ever *acted* on it —
    /// evicting, cancelling reservations — without saying what it heard. A
    /// load gate that has to decide whether to allocate 1 GB cannot ask the
    /// eviction history; it has to be able to ask the level (and how long ago
    /// the last critical was), which is what this reading is.

    func testThePressureReadingStartsUnknownAndRecordsWhatTheKernelSaid() {
        XCTAssertEqual(manager.memoryPressureReading(), .unknown)

        manager.handleMemoryPressure(level: .warning)
        XCTAssertEqual(manager.memoryPressureReading().level, .warning)
        XCTAssertNil(manager.memoryPressureReading().secondsSinceCritical,
                     "a warning is not a critical: nothing has nearly killed us yet")
        XCTAssertEqual(manager.memoryPressureReading().secondsSinceWarning, 0,
                       "[PRESSURE-LATCH] a warning carries its own age. The level alone "
                       + "cannot be trusted to clear — the UIKit route records it and nothing "
                       + "takes it back — so the age is the whole basis of the gate's escape")

        now = now.addingTimeInterval(12)
        manager.handleMemoryPressure(level: .critical)
        XCTAssertEqual(manager.memoryPressureReading(),
                       MemoryPressureReading(level: .critical, secondsSinceCritical: 0,
                                             secondsSinceWarning: 12))

        now = now.addingTimeInterval(4)
        XCTAssertEqual(manager.memoryPressureReading(),
                       MemoryPressureReading(level: .critical, secondsSinceCritical: 4,
                                             secondsSinceWarning: 16))

        // The level eases; the fact that it was critical four seconds ago
        // does not. Both are in the reading because they are different
        // questions: "is the device asking now" and "was it nearly over".
        manager.handleMemoryPressure(level: .normal)
        let eased = manager.memoryPressureReading()
        XCTAssertEqual(eased.level, .normal, "the level is what the kernel last said")
        XCTAssertEqual(eased.secondsSinceCritical, 4,
                       "the age of the last critical survives it — that is the reading a "
                       + "load gate needs in the window after the kernel goes quiet")
        XCTAssertEqual(eased.secondsSinceWarning, 16,
                       "and so does the warning's age: easing the level says the squeeze is "
                       + "over, not that it never happened")
    }

    /// The UIKit path records the level too. `didReceiveMemoryWarning` is
    /// UIKit relaying the kernel's `.warning`, and a gate that only heard the
    /// dispatch source would miss every warning on a device where that source
    /// failed to install.
    func testTheUIKitWarningPathRecordsTheLevelAsWell() {
        manager.handleMemoryPressure()

        XCTAssertEqual(manager.memoryPressureReading().level, .warning)
        XCTAssertNil(manager.memoryPressureReading().secondsSinceCritical)
        XCTAssertEqual(manager.memoryPressureReading().secondsSinceWarning, 0,
                       "[PRESSURE-LATCH] this is the route that can latch — it records the "
                       + "level and no counterpart ever clears it — so the timestamp it "
                       + "leaves behind is what lets a later load tell it has gone stale")
    }

    /// The level is recorded **before** the sweep runs, and that ordering is
    /// the whole reason a load gate racing the sweep sees the new state rather
    /// than the one before it. The seam is the eviction callback itself: it
    /// runs outside the lock, mid-sweep, exactly as a concurrent gate would —
    /// and a gate that asked here would otherwise be told `.normal` while the
    /// device is being squeezed.
    func testTheLevelIsRecordedBeforeAnythingIsEvicted() {
        let owner = FakeOwner()
        var readingDuringEviction: MemoryPressureReading?
        owner.onUnload = { [weak manager] in
            readingDuringEviction = manager?.memoryPressureReading()
        }
        XCTAssertTrue(load(.brain, modelID: brain17B, owner: owner).isAllowed)

        manager.handleMemoryPressure(level: .critical)

        XCTAssertEqual(owner.unloadCount, 1, "the sweep must actually have run")
        XCTAssertEqual(readingDuringEviction,
                       MemoryPressureReading(level: .critical, secondsSinceCritical: 0),
                       "a load that asks mid-sweep must see the critical, not the level before it")
    }

    // MARK: - The translation preemption policy (owner directive, 2026-09-19)
    //
    // "ModelWarden should UNLOAD other models and load the translation model
    // … If a voice command is activated, translation has LOWER priority and
    // can be offloaded to make room for the voice stack."
    //
    // The cases below are that policy in full, and the first two need a
    // manager with **no** budget override: everything else in this file pins
    // one budget with `budgetOverrideBytes`, while this policy is precisely
    // about the difference between the two budgets a real device produces.

    /// The Q8 translation head: 1.83 GB of weights in the 3B row, 2.63 GB
    /// live. It is the artifact the owner is testing on device, and the one
    /// whose refusal turned the tier cloud-only.
    private var translateQ8: ModelID { ModelCatalog.nmtEnNeQwen17bR2bQ8 }

    /// A manager on the scripted probe with no budget override, so the class
    /// budget comes from the scripted physical memory and the session budget
    /// from the scripted headroom.
    private func makeUnpinnedManager() -> ModelLifecycleManager {
        ModelLifecycleManager(
            probe: probe,
            clock: { [unowned self] in self.now },
            idleEvictionSeconds: ModelLifecycleManager.defaultIdleEvictionSeconds)
    }

    /// Registers and drives a slot resident on a manager other than the one
    /// `setUp` built.
    @discardableResult
    private func load(_ slot: ModelSlot,
                      modelID: ModelID?,
                      owner: FakeOwner,
                      on manager: ModelLifecycleManager,
                      priority: ModelPriority = .foreground,
                      resident: ModelResident? = nil) -> FakeOwner {
        manager.register(slot: slot, modelID: modelID, owner: owner,
                         evictable: true, priority: priority,
                         resident: resident) { [weak owner] in
            owner?.unload()
        }
        manager.didLoad(slot, owner: owner)
        return owner
    }

    /// A foreground translation load that cannot fit the SESSION budget
    /// evicts what it may and is admitted against the CLASS budget.
    ///
    /// This is the device failure the policy exists for: the probe reading
    /// collapses `effectiveBudgetBytes` below the 2.63 GB the Q8 needs, the
    /// old branch answered `over_budget_alone` because
    /// `.translateBrain` does not `admitSoloOverBudget`, and a refused load
    /// is a camera session that stopped translating.
    func testAForegroundTranslationLoadEvictsAWarmResidentAndIsAdmitted() {
        // 6 GB physical → `.standard` → a 3.2 GB class budget; 1.5 GB of
        // headroom with a warm 1 GB STT resident beside it.
        probe.availableProcessMemoryBytes = 1_500_000_000
        let manager = makeUnpinnedManager()
        var events: [ModelLifecycleEvent] = []
        manager.onEvent = { events.append($0) }

        let warmOwner = FakeOwner()
        load(.speechToText, modelID: sttQ8, owner: warmOwner, on: manager,
             priority: .background)

        let incoming = footprint(.translateBrain, translateQ8)
        let warm = footprint(.speechToText, sttQ8)
        let sessionBudget = ModelLifecycleBudget.effectiveBudgetBytes(
            deviceClass: .standard,
            availableBytes: probe.availableProcessMemoryBytes,
            residentLiveBytes: warm)
        // The setup, asserted rather than assumed — if these two ever stop
        // holding, the case is no longer testing the refusal it was written
        // for and should fail loudly rather than pass vacuously.
        XCTAssertLessThan(sessionBudget, incoming,
                          "the session budget must be below the model, or the "
                          + "old branch would never have refused it")
        XCTAssertLessThanOrEqual(incoming,
                                 ModelLifecycleBudget.standardModelsBudgetBytes,
                                 "…and the model must be INSIDE the class "
                                 + "budget, which is the other half of the rule")

        let translateOwner = FakeOwner()
        // Registered as the generator registers it before its own load.
        manager.register(slot: .translateBrain, modelID: translateQ8,
                         owner: translateOwner, evictable: true,
                         priority: ReservationPurpose.liveTranslate.priority) { [weak translateOwner] in
            translateOwner?.unload()
        }

        guard let reservation = reserveOrFail(
            manager, request(.translateBrain, modelID: translateQ8,
                             owner: translateOwner, purpose: .liveTranslate))
        else { return }

        XCTAssertEqual(reservation.budgetBytes,
                       ModelLifecycleBudget.standardModelsBudgetBytes,
                       "a foreground translation load is judged against the "
                       + "class budget, not the collapsed session one")
        XCTAssertFalse(reservation.soloOverBudget,
                       "it is not over the budget it was judged against")
        XCTAssertEqual(reservation.evicted, [.speechToText],
                       "the warm background resident is what makes the room")
        XCTAssertEqual(warmOwner.unloadCount, 1)
        XCTAssertFalse(manager.isResident(.speechToText))
        XCTAssertFalse(events.contains(.reservationDenied(
            slot: .translateBrain, reason: .overBudgetAlone(
                liveBytes: incoming,
                budgetBytes: sessionBudget), purpose: .liveTranslate)),
            "`over_budget_alone` is the refusal this directive removes")
    }

    /// The bound the policy keeps: a model over the **class** budget is over
    /// it whatever is evicted, and stays refused.
    func testATranslationModelOverTheClassBudgetIsStillRefused() {
        let manager = makeUnpinnedManager()   // default probe: 3.4 GB free
        let incoming = footprint(.translateBrain, brain4B)
        XCTAssertGreaterThan(incoming,
                             ModelLifecycleBudget.standardModelsBudgetBytes,
                             "the 4B must be over the 3.2 GB class budget for "
                             + "this case to mean anything")

        guard case .failure(let denial) = manager.reserve(
            request(.translateBrain, modelID: brain4B, owner: nil,
                    purpose: .liveTranslate)) else {
            return XCTFail("eviction cannot shrink a model below its own "
                           + "bytes: a 4B on a standard phone stays refused")
        }
        XCTAssertEqual(denial, .overBudgetAlone(liveBytes: incoming,
                                                budgetBytes: ModelLifecycleBudget.standardModelsBudgetBytes))
        XCTAssertEqual(denial.token, "over_budget_alone")
    }

    /// A voice turn takes the translation model back — asked, then handed
    /// over, and never also unloaded by the unconditional path.
    func testAVoiceTurnReservationPreemptsTheTranslationResident() {
        var events: [ModelLifecycleEvent] = []
        // The pinned budget is the standard class's own, which is what makes
        // the translation head and the 1.7B brain over it together.
        let tight = makeManager(budget: ModelLifecycleBudget.standardModelsBudgetBytes)
        tight.onEvent = { events.append($0) }

        let translateOwner = FakeOwner()
        let resident = FakeResident()   // .released
        tight.register(slot: .translateBrain, modelID: translateQ8,
                       owner: translateOwner, evictable: true,
                       priority: ReservationPurpose.liveTranslate.priority,
                       resident: resident) { [weak translateOwner] in
            translateOwner?.unload()
        }
        tight.didLoad(.translateBrain, owner: translateOwner)

        // The household is talking: a live voice turn's brain load cannot fit
        // beside the translation head.
        guard let reservation = reserveOrFail(
            tight, request(.brain, modelID: brain17B, owner: translateOwner,
                           purpose: .voiceTurn)) else { return }

        XCTAssertEqual(resident.askCount, 1,
                       "the warden asks a resident below the request — a voice "
                       + "turn is the only thing above it")
        XCTAssertEqual(translateOwner.unloadCount, 0,
                       "the owner gave the bytes back on the ask; invoking the "
                       + "registered release path as well would drop a handle "
                       + "that is already gone")
        XCTAssertEqual(reservation.preempted,
                       [PreemptionRecord(slot: .translateBrain, outcome: .released)])
        XCTAssertEqual(preemptedEvents(events), [.released])
        XCTAssertFalse(tight.isResident(.translateBrain))
        XCTAssertEqual(reservation.evicted, [.translateBrain],
                       "the victim is the translation model and nothing else")
    }

    /// The other direction does not cross: a translation load cannot take the
    /// bytes of the brain a live turn is decoding on.
    ///
    /// Structural rather than special-cased — the victim order drops any
    /// resident with a pin (`loadEvictionOrderLocked`), which is what
    /// `beginUse`/`endUse` set around an inference — and it is the bound the
    /// owner named ("never the active voice turn's brain/STT"). The load is
    /// then refused as a budget shortfall, not admitted over it.
    func testATranslationLoadCannotTakeTheVoiceTurnsPinnedBrain() {
        probe.availableProcessMemoryBytes = 1_500_000_000
        let manager = makeUnpinnedManager()

        let brainOwner = FakeOwner()
        load(.brain, modelID: brain17B, owner: brainOwner, on: manager)
        manager.beginUse(of: .brain)   // an inference is in flight

        guard case .failure(let denial) = manager.reserve(
            request(.translateBrain, modelID: translateQ8, owner: nil,
                    purpose: .liveTranslate)) else {
            return XCTFail("the pinned brain is exactly what may not be taken")
        }

        XCTAssertEqual(denial, .budgetExhausted(by: .brain))
        XCTAssertEqual(brainOwner.unloadCount, 0)
        XCTAssertTrue(manager.isResident(.brain))
        manager.endUse(of: .brain)
    }

    /// The ladder the two directions ride on, pinned as one assertion so a
    /// future purpose cannot quietly move either side of it.
    func testTranslationRanksBelowTheVoiceStackAndMayOnlyEvictItsWayIn() {
        XCTAssertLessThan(ReservationPurpose.liveTranslate.priority,
                          ReservationPurpose.voiceTurn.priority)
        XCTAssertTrue(ReservationPurpose.liveTranslate.mayEvictPastTheSessionBudget)
        for other in [ReservationPurpose.voiceTurn, .warm, .maintenance] {
            XCTAssertFalse(other.mayEvictPastTheSessionBudget,
                           "\(other) must stay inside the session budget")
        }
    }
}
