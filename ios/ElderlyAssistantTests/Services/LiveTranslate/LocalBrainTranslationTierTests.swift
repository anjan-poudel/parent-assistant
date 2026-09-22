import XCTest
@testable import ElderlyAssistant

/// Tier 1 — the on-device translation tier (FR-LCT-008 as amended
/// 2026-09-17, FR-LCT-020, NFR-LCT-010).
///
/// The tier is exercised over a **deterministic fake** for the one thing that
/// needs a model: the generation. Everything that is a rule rather than a
/// runtime call — which model runs, what one batch contains, what a malformed
/// or partial answer means, what a failure is recorded as, whether the device
/// may spend the memory on a load at all, and the fact that nothing but counts
/// ever reaches the log — is driven here without a model on disk.
///
/// **The direction of every fixture is load-bearing.** Sources are English and
/// answers are Nepali, because that is the shipped direction: the vision
/// runtime that feeds this feature reads English scene text (it has no
/// Devanagari recognition language at all), and the elder's language — Nepali
/// — is the language a translation is a translation *into*. The fixtures this
/// suite shipped with were the other way round, which is the defect the
/// 2026-09-17 rules below pin.
final class LocalBrainTranslationTierTests: XCTestCase {

    private let config = LiveTranslateConfig.default

    /// Strings no dictionary knows and only the brain can answer: English
    /// words, printed on a sign, which is what the camera can actually read.
    private let brainText = "Pharmacy"
    private let secondBrainText = "Open"
    private let thirdBrainText = "No entry"

    /// What a Nepali-speaking elder must be shown for those signs.
    ///
    /// Every answer is a Nepali *sentence* rather than a bare noun, and since
    /// 2026-09-18 that is load-bearing rather than stylistic: the tier's
    /// language rule (`NepaliOutputGate`) settles a region only on an answer
    /// with Nepali evidence — with the short-answer exemption (2026-09-20)
    /// now accepting markerless answers of two words or fewer, which is why
    /// the fixtures stay sentences: they are what the gate can still be
    /// asked to vouch for. The cost of the long-answer rule is measured in
    /// `NepaliOutputGateTests`.
    private let brainAnswer = "यो औषधि पसल हो"
    private let secondBrainAnswer = "खुला छ"
    private let thirdBrainAnswer = "भित्र पस्न मनाही छ"

    // MARK: - Doubles

    /// The generation, scripted.
    final class ScriptedGenerator: BrainTextGenerating, @unchecked Sendable {
        /// What the model "answers". Set per test.
        var output = ""
        /// A failure to throw instead of answering (timeout, load failure, …).
        var failure: BrainGenerationFailure?
        /// An error the tier did not classify — the shape a llama.cpp
        /// `LLMError` (or any other runtime throw) arrives in.
        var runtimeError: Error?
        /// Whether a handle is already open on the model. Drives the one case
        /// where the memory gate must not refuse: the bytes are spent already.
        var holdingHandle = false

        private(set) var prompts: [String] = []
        private(set) var timeouts: [TimeInterval] = []
        private(set) var releaseCount = 0
        /// Which artifact each generation was run against. Recorded since
        /// [TRANSLATE-TEST] because the tier can now be asked for a NAMED
        /// model, and "the model it ran is the model it was told to run" is
        /// a claim about this URL rather than about the tier's return value.
        private(set) var modelURLs: [URL] = []

        func generate(prompt: String,
                      jsonSchema: String,
                      modelURL: URL,
                      timeout: TimeInterval) async throws -> BrainGenerationOutput {
            prompts.append(prompt)
            timeouts.append(timeout)
            modelURLs.append(modelURL)
            if let failure { throw failure }
            if let runtimeError { throw runtimeError }
            // The measurement rides with the answer it belongs to
            // ([MODEL-SWITCH], 2026-09-21 review round 2).
            return BrainGenerationOutput(text: output, loadMs: loadDurationMs)
        }

        func isHoldingHandle() async -> Bool { holdingHandle }

        /// What the runtime measured for the load inside that generation —
        /// `nil` (the default) is "nothing measured", the answer every
        /// hand-written fake honestly gives. Set by the tests that make a
        /// claim about the split between the load and the decode.
        var loadDurationMs: Int?

        func release() async { releaseCount += 1 }
    }

    /// The app's headroom reading, scripted. `headroom` is what the resource
    /// gate compares against the model's hard bytes, so the arithmetic is a
    /// fact about this file rather than about the machine the suite runs on.
    /// The read is counted, because "the gate short-circuits before it looks
    /// at memory" is itself a claim worth pinning.
    private final class ScriptedProbe: MemoryProbing {
        var physicalMemoryBytes: UInt64
        var headroom: UInt64
        private(set) var headroomReads = 0

        var availableProcessMemoryBytes: UInt64 {
            headroomReads += 1
            return headroom
        }

        init(physicalMemoryBytes: UInt64 = 6_000_000_000,
             headroom: UInt64 = 8_000_000_000) {
            self.physicalMemoryBytes = physicalMemoryBytes
            self.headroom = headroom
        }
    }

    /// A slot's owner, kept alive by the test that made it resident: the
    /// ledger prunes entries whose owner has died, so a resident brain is
    /// only resident for as long as somebody holds this.
    ///
    /// `unloadCount` is the warden suite's convention, copied here for the
    /// [LOAD-EVICT] cases: an eviction is only *this* owner being let go
    /// if the closure the ledger was handed actually ran, and a test that
    /// asserted on ledger state alone could not tell an unload from a slot
    /// that had never been resident in the first place.
    private final class FakeOwner {
        private(set) var unloadCount = 0
        func unload() { unloadCount += 1 }
    }

    // MARK: - Fixtures

    private static let modelID = ModelCatalog.intentQwen4BS43

    /// A store over a temporary root with exactly one synthetic catalog entry,
    /// installed only when `installed` is true. The synthetic entry is the
    /// store's own test seam (`entryProvider`), so the real
    /// `isAvailable`/`isCached`/`path(for:)` logic under test is the shipped
    /// one and only the catalog is doubled.
    private func makeStore(installed: Bool,
                           root: URL) throws -> ModelStore {
        let id = Self.modelID
        return try makeStore(root: root, serving: [id], installed: installed ? [id] : [])
    }

    /// The general store: a catalog serving exactly `serving`, with the
    /// artifact on disk for exactly `installed`. Both halves are needed by the
    /// configured-list test, where an entry can be written down in the catalog
    /// *and* in the preference list without being on the device.
    ///
    /// Every entry gets its own filename, so nothing about one id's staged
    /// bytes can be found under another's path.
    private func makeStore(root: URL,
                           serving: [ModelID],
                           installed: [ModelID]) throws -> ModelStore {
        let entries = Dictionary(uniqueKeysWithValues: serving.map { id in
            (id, ModelCatalogEntry(id: id,
                                   kind: .llamaBase,
                                   displayName: "Test brain",
                                   filename: "\(id)-q4_k_m.gguf",
                                   downloadURL: URL(string: "https://example.invalid/brain.gguf")!,
                                   downloadPartURLs: nil,
                                   sizeBytes: 4_000,
                                   sha256: "unused-with-skip-policy",
                                   minDeviceRAMBytes: 0,
                                   dependsOn: nil))
        })
        let store = try ModelStore(observabilityBus: NullObservabilityBus(),
                                   rootDirectoryOverride: root,
                                   checksumPolicy: .skip,
                                   entryProvider: { entries[$0] })

        for id in installed {
            let staged = try store.stagingURL(for: id)
            try Data("not a real model".utf8).write(to: staged)
            _ = try store.finalize(id)
        }
        return store
    }

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-tier-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The tier over a scripted store and generator.
    ///
    /// The probe and the ledger default to values that *permit* the load — a
    /// fresh manager with nothing resident and an abundance of headroom — so
    /// every test that is not about the resource gate is about the thing it
    /// says it is about, and none of them depend on how much memory the host
    /// happens to have free. The tests that are about the gate drive both.
    private func withTier<T>(installed: Bool = true,
                             config: LiveTranslateConfig = .default,
                             targetLanguage: AppLanguage = .nepali,
                             memory: MemoryProbing? = nil,
                             ledger: ModelLifecycleManager? = nil,
                             onWardenNotice: (@Sendable (LocalBrainWardenNotice) -> Void)? = nil,
                             run: (LocalBrainTranslationTier, ScriptedGenerator, LiveTranslateSanitisingBus) async throws -> T) async rethrows -> T {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = LiveTranslateSanitisingBus()
        let store = try! makeStore(installed: installed, root: root)
        let events = LiveTranslateEvents(bus: bus, config: config)
        let generator = ScriptedGenerator()
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: events,
                                             generator: generator,
                                             targetLanguage: targetLanguage,
                                             memory: memory ?? ScriptedProbe(),
                                             ledger: ledger ?? ModelLifecycleManager(probe: ScriptedProbe()),
                                             onWardenNotice: onWardenNotice)
        return try await run(tier, generator, bus)
    }

    // MARK: - [LOAD-EVICT] Making room for a load the gate would refuse

    /// The STT the owner's device is holding warm — the recogniser that is
    /// not decoding anything right now and whose ~1 GB is what the translation
    /// head cannot fit beside.
    private static let warmSTT = ModelCatalog.whisperKitMediumV6

    /// The owner's device as a fixture: a warm `slot` resident in the ledger,
    /// a manager pinned to a budget the resident and the incoming model can
    /// only share by evicting, and the headroom the tier's gate reads.
    ///
    /// The pin is `warm + incoming - 1` rather than the real 3.2 GB class
    /// budget, so the arithmetic is a fact about this file rather than about
    /// how large the catalog's 4B happens to be today — the same convention
    /// (`budgetOverrideBytes`) every pinned case in the warden suite uses.
    /// `freeing` is what the resident gives back when it is unloaded: a real
    /// device gets the bytes back, and a test can also model one that does
    /// not (the device that is genuinely full).
    ///
    /// `priority` is the resident's rung on the warden's ladder. It orders the
    /// walk rather than gating it — a lone resident is a candidate whatever it
    /// holds — so the `.background` the warm STT really carries is what makes
    /// it the *first* thing taken when the voice positions are resident too.
    private func makeWarmResidentEvictionFixture(
        slot: ModelSlot,
        modelID: ModelID,
        priority: ModelPriority,
        headroom: UInt64,
        freeing freedBytes: UInt64
    ) -> (ledger: ModelLifecycleManager, owner: FakeOwner, probe: ScriptedProbe) {
        let probe = ScriptedProbe(headroom: headroom)
        let incoming = ModelLifecycleInventory.footprint(for: .translateBrain,
                                                         modelID: Self.modelID).liveBytes
        let warm = ModelLifecycleInventory.footprint(for: slot, modelID: modelID).liveBytes
        let ledger = ModelLifecycleManager(
            probe: ScriptedProbe(),
            budgetOverrideBytes: warm + incoming - 1)
        let owner = FakeOwner()
        ledger.register(slot: slot,
                        modelID: modelID,
                        owner: owner,
                        evictable: true,
                        priority: priority) { [weak owner] in
            owner?.unload()
            probe.headroom += freedBytes
        }
        ledger.didLoad(slot, owner: owner)
        XCTAssertTrue(ledger.isResident(slot),
                      "the fixture's warm \(slot.rawValue) must actually be resident")
        return (ledger, owner, probe)
    }

    /// The owner's phone in one call: the warm recogniser holding the bytes
    /// the translation head cannot fit beside, on a 6 GB class probe.
    private func makeWarmSTTEvictionFixture(
        headroom: UInt64,
        freeing freedBytes: UInt64
    ) -> (ledger: ModelLifecycleManager, owner: FakeOwner, probe: ScriptedProbe) {
        makeWarmResidentEvictionFixture(slot: .speechToText,
                                        modelID: Self.warmSTT,
                                        priority: .background,
                                        headroom: headroom,
                                        freeing: freedBytes)
    }

    /// **The owner's device, and the bug this fixes (2026-09-22).**
    ///
    /// A 6 GB class probe, the app's available memory below the head's declared
    /// non-pageable bytes, and a warm STT resident in the ledger — the shape
    /// the owner reported from the phone, where the translation head refused
    /// `insufficientHeadroom` even though the warden's own reserve path was
    /// proven to admit it by evicting the recogniser.
    ///
    /// Production used to stop at `deferralForLoad`'s first answer, so the
    /// refusal was the last word and the eviction hatch never got its turn. It
    /// does not stop there any more (`gateForLoad`), and this is the test that
    /// mirrors the capture: the batch runs, the warm STT is what made the room,
    /// and the outcome names it.
    ///
    /// The unload closure raises the probe's reading, which is what a real
    /// eviction does to a real device — the gate's second pass is judged
    /// against the memory that actually came back, not against the reading
    /// that produced the first refusal.
    func testTheWarmSTTIsEvictedAndTheTranslationRuns() async throws {
        let required = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: Self.modelID).hardBytes
        let fixture = makeWarmSTTEvictionFixture(headroom: required / 2,
                                                 freeing: required)
        let (ledger, sttOwner, probe) = fixture

        try await withTier(memory: probe, ledger: ledger) { tier, generator, bus in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "the model was loaded and asked: the gate asks the "
                           + "warden before a headroom reading is taken as final")
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertNil(outcome.deferral)
            XCTAssertEqual(outcome.evictedForRoom, [.speechToText],
                           "the warm STT is what made the room, and the outcome "
                           + "names it")
            XCTAssertEqual(sttOwner.unloadCount, 1,
                           "the warden's own victim walk did the unloading")
            XCTAssertFalse(ledger.isResident(.speechToText))
            XCTAssertEqual(batchEvent(bus)?.metadata["resolvedCount"], "1")
        }
    }

    /// **The other half of the resident rule (2026-09-22).** The same device
    /// state with the voice pipeline's own brain in place of the recogniser,
    /// and nothing else in the ledger: the gate's first answer is
    /// `.residentBrain`, the warden is asked, and its walk takes the voice
    /// brain — a `.foreground` `.liveTranslate` load is entitled to those
    /// bytes, and with nothing lower on the ladder there is nothing else to
    /// spend first.
    ///
    /// This is the owner's directive, pinned: "ModelWarden should UNLOAD other
    /// models and load the translation model", in the warden's own priority
    /// order. The refusal is not gone — it is *answered*, and only where the
    /// warden's walk has an answer. The cases where it does not (a resident the
    /// warden may not take, the kernel's pressure rules) are pinned around it.
    func testAnEvictableVoiceBrainIsOffloadedForTheTranslationLoad() async throws {
        let (ledger, voiceOwner, probe) = makeWarmResidentEvictionFixture(
            slot: .brain,
            modelID: Self.modelID,
            priority: .foreground,
            headroom: 8_000_000_000,
            freeing: 0)

        try await withTier(memory: probe, ledger: ledger) { tier, generator, bus in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "the voice brain's bytes are what the load needed, "
                           + "and the warden gave them up")
            XCTAssertNil(outcome.deferral)
            XCTAssertEqual(outcome.evictedForRoom, [.brain],
                           "the outcome names the position the warden emptied")
            XCTAssertEqual(voiceOwner.unloadCount, 1)
            XCTAssertFalse(ledger.isResident(.brain))
            XCTAssertEqual(batchEvent(bus)?.metadata["resolvedCount"], "1")
        }
    }

    /// **And the room is still not enough.** A device whose warm STT was
    /// resident *and* whose free memory does not come back to the required
    /// figure — a phone with something else holding the pages — must refuse,
    /// and the refusal must say what was spent trying.
    ///
    /// Without `evictedForRoom` this outcome is indistinguishable from an
    /// ordinary busy-device refusal, which is the opposite finding: "the device
    /// was in use" versus "the device was emptied and the model still does not
    /// fit". The tokens are asserted, not just the counts, because the surface
    /// prints exactly these.
    func testARefusalThatSurvivesTheEvictionSaysSo() async throws {
        let required = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: Self.modelID).hardBytes
        // `freeing: 0` — the STT goes, the pages do not come back.
        let fixture = makeWarmSTTEvictionFixture(headroom: required / 2, freeing: 0)
        let (ledger, sttOwner, probe) = fixture

        try await withTier(memory: probe, ledger: ledger) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty,
                          "the model does not fit even with the device to itself")
            XCTAssertEqual(outcome.deferral,
                           .insufficientHeadroom(requiredBytes: Double(required),
                                                 availableBytes: Double(probe.headroom)),
                           "the second answer is the one reported: the numbers "
                           + "are the device's, not the first refusal's")
            XCTAssertEqual(outcome.evictedForRoom, [.speechToText],
                           "…and it says what was spent getting there")
            XCTAssertEqual(sttOwner.unloadCount, 1)
            XCTAssertEqual(batchEvent(bus)?.outcome, "degraded")
        }
    }

    /// **The warden's walk is not asked about the kernel's rule.** A
    /// `.critical` reading ([PRESSURE-SAFE LOAD], the 2026-09-19 device death)
    /// refuses, and it does so *before* anything is offered to the warden:
    /// unloading a resident does not answer "the system is out of pages", and
    /// the bytes of the elder's warm recogniser are not the camera's to spend
    /// on a device that is being killed.
    ///
    /// The resident here is evictable and the warden would take it for any load
    /// that got as far as asking — which is exactly what makes this the honest
    /// test of where the pass stops.
    func testTheWardensWalkIsNotAskedToAnswerTheKernelsPressureRefusal() async throws {
        let required = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: Self.modelID).hardBytes
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)

        let sttOwner = FakeOwner()
        let probe = ScriptedProbe(headroom: required / 2)
        ledger.register(slot: .speechToText,
                        modelID: Self.warmSTT,
                        owner: sttOwner,
                        evictable: true,
                        priority: .background) { [weak sttOwner] in
            sttOwner?.unload()
            probe.headroom += required
        }
        ledger.didLoad(.speechToText, owner: sttOwner)

        try await withTier(memory: probe, ledger: ledger) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty)
            XCTAssertEqual(outcome.deferral, .memoryPressure(level: .critical))
            XCTAssertTrue(outcome.evictedForRoom.isEmpty,
                          "the kernel's refusal is not answered by unloading a "
                          + "resident: nothing was offered to the warden")
            XCTAssertEqual(sttOwner.unloadCount, 0)
            XCTAssertTrue(ledger.isResident(.speechToText))
        }
    }

    /// The same boundary, one level quieter: a `.critical` that has since
    /// eased out of the level but is still inside its window. Nothing is
    /// offered to the warden here either, for the same reason — the window is
    /// about the device the kernel was about to kill, and no eviction answers
    /// it. The warm STT is present and evictable, so the only thing keeping it
    /// resident is the rule.
    func testTheWardensWalkIsNotAskedToAnswerARecentCriticalPressure() async throws {
        let required = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: Self.modelID).hardBytes
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)
        ledger.handleMemoryPressure(level: .normal)
        clock.advance(5)

        let sttOwner = FakeOwner()
        let probe = ScriptedProbe(headroom: required / 2)
        ledger.register(slot: .speechToText,
                        modelID: Self.warmSTT,
                        owner: sttOwner,
                        evictable: true,
                        priority: .background) { [weak sttOwner] in
            sttOwner?.unload()
            probe.headroom += required
        }
        ledger.didLoad(.speechToText, owner: sttOwner)

        try await withTier(memory: probe, ledger: ledger) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty)
            XCTAssertEqual(outcome.deferral,
                           .recentCriticalPressure(secondsSince: 5, windowSeconds: 30))
            XCTAssertTrue(outcome.evictedForRoom.isEmpty,
                          "the window is not answered by unloading a resident")
            XCTAssertEqual(sttOwner.unloadCount, 0)
            XCTAssertTrue(ledger.isResident(.speechToText))
        }
    }

    // MARK: - [READINESS-EVICT] The same walk, asked before a batch

    /// **The readiness question on the owner's device.** A 6 GB class probe
    /// with the warm recogniser resident: the translation head's gate refuses
    /// on headroom, the warden's walk takes the STT's bytes, and the answer
    /// this returns is the one the RUN would give — admitted, at the cost of
    /// the warm STT.
    ///
    /// That is what the translate-test screen's button is gated on. It used
    /// to be gated on the warden's OFFER-side advisory
    /// (`ModelLifecycleManager.availability(of:)`), which refuses this very
    /// model as `.requiresEvictingWarmSTT` and so disabled a button whose run
    /// works every time — the reported bug.
    func testTheAdmissionQuestionEvictsTheWarmSTTForTheHeadItAdmits() async throws {
        let required = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: Self.modelID).hardBytes
        let (ledger, sttOwner, probe) = makeWarmSTTEvictionFixture(headroom: required / 2,
                                                                   freeing: required)

        try await withTier(memory: probe, ledger: ledger) { tier, _, _ in
            let admission = await tier.admissionForLoad(of: Self.modelID)

            XCTAssertEqual(admission, .admittedByEvicting([.speechToText]),
                           "the run's own answer: admitted, and the warm STT is the price")
            XCTAssertEqual(sttOwner.unloadCount, 1,
                           "the warden's own victim walk did the unloading")
            XCTAssertFalse(ledger.isResident(.speechToText))
        }
    }

    /// And the same question on the device where the room is not enough: the
    /// walk spends the recogniser, the re-ask refuses, and the refusal is what
    /// comes back — with the numbers of the device as it is now, not the first
    /// refusal's. A readiness line that reported "ready" here would offer a
    /// button whose run refuses.
    func testTheAdmissionQuestionReportsTheRefusalTheWalkCouldNotAnswer() async throws {
        let required = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: Self.modelID).hardBytes
        // `freeing: 0` — the STT goes, the pages do not come back.
        let (ledger, sttOwner, probe) = makeWarmSTTEvictionFixture(headroom: required / 2,
                                                                   freeing: 0)

        try await withTier(memory: probe, ledger: ledger) { tier, _, _ in
            let admission = await tier.admissionForLoad(of: Self.modelID)

            XCTAssertEqual(admission,
                           .refused(.insufficientHeadroom(requiredBytes: Double(required),
                                                          availableBytes: Double(probe.headroom))),
                           "the second answer is the one reported")
            XCTAssertEqual(sttOwner.unloadCount, 1)
        }
    }

    /// The kernel's rule is not offered to the walk on the readiness path
    /// either: the same device under a `.critical` reading answers with the
    /// pressure refusal, and nothing is unloaded to try to answer it.
    func testTheAdmissionQuestionKeepsTheKernelsRefusalAndSpendsNothing() async throws {
        let required = ModelLifecycleInventory.footprint(for: .brain,
                                                         modelID: Self.modelID).hardBytes
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)

        let sttOwner = FakeOwner()
        let probe = ScriptedProbe(headroom: required / 2)
        ledger.register(slot: .speechToText,
                        modelID: Self.warmSTT,
                        owner: sttOwner,
                        evictable: true,
                        priority: .background) { [weak sttOwner] in
            sttOwner?.unload()
            probe.headroom += required
        }
        ledger.didLoad(.speechToText, owner: sttOwner)

        try await withTier(memory: probe, ledger: ledger) { tier, _, _ in
            let admission = await tier.admissionForLoad(of: Self.modelID)

            XCTAssertEqual(admission, .refused(.memoryPressure(level: .critical)))
            XCTAssertEqual(sttOwner.unloadCount, 0,
                           "the kernel's refusal is not answered by unloading a resident")
            XCTAssertTrue(ledger.isResident(.speechToText))
        }
    }

    /// A manager with `slot` fully resident (registered, admitted, marked
    /// loaded). Returns the owner, which the caller must keep alive.
    ///
    /// `evictable` is the axis the warden's walk reads: the tests whose
    /// subject is the *deferral rule* — "another owner's brain is live, so
    /// this batch is not asked" — pass `false`, which is the shape production
    /// gives the residents the app must not unload (the VAD, the wake-word
    /// model, the encoder). With an evictable resident the walk has an answer
    /// and takes it, and that half of the behaviour is pinned in the
    /// [LOAD-EVICT] section below rather than here.
    @discardableResult
    private func makeLedger(residing slot: ModelSlot,
                            evictable: Bool = true) -> (ModelLifecycleManager, FakeOwner) {
        let owner = FakeOwner()
        let manager = ModelLifecycleManager(probe: ScriptedProbe(),
                                            budgetOverrideBytes: ModelLifecycleBudget.standardModelsBudgetBytes)
        manager.register(slot: slot, modelID: Self.modelID, owner: owner,
                         evictable: evictable,
                         unload: { [weak owner] in _ = owner })
        let admission = manager.prepareLoad(of: slot, modelID: Self.modelID)
        XCTAssertTrue(admission.isAllowed, "the fixture's own load must be admitted: \(admission)")
        manager.didLoad(slot, owner: owner)
        XCTAssertTrue(manager.isResident(slot), "the fixture must actually be resident")
        return (manager, owner)
    }

    /// The answer a real generation would produce for these sources, in the
    /// grammar the tier constrains the decode to.
    private func answer(_ translations: [String]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["translations": translations]),
               encoding: .utf8)!
    }

    /// The batch event's metadata, as a dictionary, for the tests that make a
    /// claim about what was reported rather than about what came back.
    private func batchEvent(_ bus: LiveTranslateSanitisingBus) -> ObservabilityEvent? {
        bus.events(named: "brain_translation_batch").first
    }

    // MARK: Availability — installed, or honestly not

    func testAnInstalledModelIsTheOneThatRuns() async throws {
        try await withTier { tier, _, _ in
            let model = await tier.installedModel()
            XCTAssertEqual(model, Self.modelID)
        }
    }

    /// The configured preference list, newest first: a device holding only the
    /// second entry still has a brain.
    func testTheFirstInstalledEntryOfTheConfiguredListRuns() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = Self.modelID
        // The preferred entry is written down in both the catalog and the
        // preference list, and is not on the device; the device holds the
        // fallback. Both facts are needed for the rule to be the thing under
        // test: the list is walked in order, and an entry that is not
        // installed does not win by being first.
        let store = try makeStore(root: root,
                                  serving: [ModelCatalog.intentQwen4BSlotCanon, id],
                                  installed: [id])

        var config = LiveTranslateConfig.default
        config.brainTranslationModelIDs = [ModelCatalog.intentQwen4BSlotCanon, id]
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: LiveTranslateEvents(bus: LiveTranslateSanitisingBus(),
                                                                         config: config),
                                             generator: ScriptedGenerator(),
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let model = await tier.installedModel()
        XCTAssertEqual(model, id,
                       "the first entry that is installed decides, not the first entry written down")
    }

    /// And the other half of the same rule: when both are on the device, the
    /// earlier entry of the list wins.
    func testAnEarlierInstalledEntryBeatsALaterOne() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferred = ModelCatalog.intentQwen4BSlotCanon
        let store = try makeStore(root: root,
                                  serving: [preferred, Self.modelID],
                                  installed: [preferred, Self.modelID])

        var config = LiveTranslateConfig.default
        config.brainTranslationModelIDs = [preferred, Self.modelID]
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: LiveTranslateEvents(bus: LiveTranslateSanitisingBus(),
                                                                         config: config),
                                             generator: ScriptedGenerator(),
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let model = await tier.installedModel()
        XCTAssertEqual(model, preferred, "the preference list is an order, not a set")
    }

    /// [TRANSLATE-TEST] The additive named-model overload: a caller that
    /// names a model gets THAT model, even when the ladder would have picked
    /// another one — and the pipeline's own call still resolves the ladder,
    /// unchanged. Both halves in one test because they are one claim: the
    /// overload is additive only if the no-argument entry point behaves
    /// exactly as it did before it existed.
    func testANamedModelRunsAndTheLaddlersOwnCallIsUnchanged() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Two TRANSLATION models on the device, the ladder's head among them:
        // with only one installed the two paths would agree by accident.
        //
        // Translation models rather than the intent brains this used to name
        // (2026-09-21 review): the named path now refuses a model that is not
        // one of this config's translation rungs, because a translation prompt
        // sent to a slot-filling brain is exactly the mistake naming makes
        // possible. The rule that used to make this fixture arbitrary is
        // `testTheNamedPathRefusesAModelThisTierDoesNotTranslateWith`.
        let head = ModelCatalog.nmtEnNeQwen17bR4Q5
        let other = ModelCatalog.nmtEnNeQwen17bR3Q4
        let store = try makeStore(root: root, serving: [head, other], installed: [head, other])

        var config = LiveTranslateConfig.default
        config.brainTranslationModelIDs = [head, other]
        let namedGenerator = ScriptedGenerator()
        namedGenerator.output = answer([brainAnswer])
        let namedTier = LocalBrainTranslationTier(config: config,
                                                  modelStore: store,
                                                  events: LiveTranslateEvents(bus: LiveTranslateSanitisingBus(),
                                                                              config: config),
                                                  generator: namedGenerator,
                                                  memory: ScriptedProbe(),
                                                  ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let named = await namedTier.translate([brainText], using: other)

        XCTAssertEqual(named.translations, [brainText: brainAnswer])
        XCTAssertEqual(try XCTUnwrap(namedGenerator.modelURLs.last).lastPathComponent,
                       "\(other)-q4_k_m.gguf",
                       "the NAMED model is the one the generation runs against")

        // And the ladder's own answer is untouched: the head is still what
        // the pipeline's no-argument call resolves — and runs. A second tier
        // over the same store, because the first one's load may have left a
        // resident brain in the ledger, and the gate that refuses a load on
        // top of one is a different rule than the one under test here.
        let ladderGenerator = ScriptedGenerator()
        ladderGenerator.output = answer([brainAnswer])
        let ladderTier = LocalBrainTranslationTier(config: config,
                                                   modelStore: store,
                                                   events: LiveTranslateEvents(bus: LiveTranslateSanitisingBus(),
                                                                               config: config),
                                                   generator: ladderGenerator,
                                                   memory: ScriptedProbe(),
                                                   ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let resolved = await ladderTier.installedModel()
        XCTAssertEqual(resolved, head, "the preference order still decides for the pipeline")
        _ = await ladderTier.translate([brainText])
        XCTAssertEqual(try XCTUnwrap(ladderGenerator.modelURLs.last).lastPathComponent,
                       "\(head)-q4_k_m.gguf")
    }

    /// A named model that is not on the device is reported exactly as the
    /// ladder-resolution failure always was: the same reason, the same
    /// stage, nothing generated.
    func testANamedModelThatIsNotInstalledIsReportedAsAMissingModel() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = Self.modelID
        let bus = LiveTranslateSanitisingBus()
        // Served by the catalog, absent from the device — the shape a
        // download row exists for.
        let store = try makeStore(root: root, serving: [absent], installed: [])
        let generator = ScriptedGenerator()
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: LiveTranslateEvents(bus: bus, config: config),
                                             generator: generator,
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let outcome = await tier.translate([brainText], using: absent)

        XCTAssertEqual(outcome, .none)
        XCTAssertTrue(generator.prompts.isEmpty, "an absent model is not attempted")
        let event = bus.events(named: "brain_translation_unavailable").first
        XCTAssertEqual(event?.metadata["reason"], "model_not_installed")
        XCTAssertEqual(event?.metadata["failureStage"], "availability")
    }

    /// [MODEL-KIND] The NAMED path refuses a model this tier does not
    /// translate with, however it got named (2026-09-21 review). Two ways to
    /// fail one question — the ladder's fallback tail (a brain entry that is
    /// NOT a translation model) and a model off this tier's ladder entirely —
    /// and both refuse BEFORE a byte is paged in, so a screen that offered
    /// such a row cannot spend 4 GB discovering it.
    func testTheNamedPathRefusesAModelThisTierDoesNotTranslateWith() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Served and installed, both of them: neither refusal below is the
        // store's answer, which is the point — "installed" is not "runnable
        // by this tier".
        let fallbackBrain = Self.modelID
        let offLadder = ModelCatalog.nmtEnNeQwen17bR4Q5
        let store = try makeStore(root: root,
                                  serving: [fallbackBrain, offLadder],
                                  installed: [fallbackBrain, offLadder])

        var config = LiveTranslateConfig.default
        // The ladder as a device that has the fallback tail and nothing else
        // would spell it: the brain entry is ON this list, which is exactly
        // why membership alone is not the check.
        config.brainTranslationModelIDs = [fallbackBrain]
        let bus = LiveTranslateSanitisingBus()
        let generator = ScriptedGenerator()
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: LiveTranslateEvents(bus: bus, config: config),
                                             generator: generator,
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let brain = await tier.translate([brainText], using: fallbackBrain)
        XCTAssertEqual(brain, .none, "an intent brain is not a translation model, on the ladder or not")
        XCTAssertTrue(generator.prompts.isEmpty, "refused before the load, not after")

        let off = await tier.translate([brainText], using: offLadder)
        XCTAssertEqual(off, .none, "a translation model this tier's ladder does not carry")

        let reasons = bus.events(named: "brain_translation_unavailable")
            .compactMap { $0.metadata["reason"] }
        XCTAssertEqual(reasons, ["not_a_translation_model", "not_a_translation_model"])
        XCTAssertEqual(bus.events(named: "brain_translation_unavailable")
                        .map { $0.metadata["failureStage"] } ?? [],
                       ["availability", "availability"],
                       "the reason is the first thing actually wrong: the model IS on the device")
    }

    /// …and the LADDER path is deliberately not checked (2026-09-21 review).
    /// A device whose ladder resolves to its fallback tail legitimately runs
    /// that brain — it is the only tier 1 it has — so refusing there would
    /// take the feature away from exactly the devices the tail exists for.
    /// The refusal is a rule about NAMING a model, not about running one.
    func testTheLadderPathStillRunsTheFallbackBrainItResolved() async throws {
        try await withTier { tier, generator, bus in
            generator.output = self.answer([self.brainAnswer])

            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty,
                          "the tier's own resolution is not a refusal")
        }
    }

    /// [MODEL-SWITCH] The load is reported BESIDE the wait, never instead of
    /// it (2026-09-21 review): the headline stays the whole attempt — that is
    /// what the event has always meant and what the deadline bounds — and the
    /// load's share is the additive number a model-to-model comparison needs.
    /// Without it, the first probe of a model reads as tens of seconds and
    /// the second as a few hundred milliseconds, and the screen has been
    /// asked to call the difference a fact about the MODELS.
    func testTheLoadShareIsReportedBesideTheWholeWait() async throws {
        try await withTier { tier, generator, bus in
            generator.output = self.answer([self.brainAnswer])
            generator.loadDurationMs = 1_100

            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertEqual(outcome.loadDurationMs, 1_100, "the generation's own load, passed through")
            let event = self.batchEvent(bus)
            XCTAssertEqual(event?.metadata["durationMs"], "\(outcome.durationMs)",
                           "the batch event keeps the whole attempt, load included")
        }
    }

    /// A generator that measured nothing reports `nil`, never a made-up zero:
    /// a zero here reads as "this model needed no loading", which is a claim
    /// no fake is in a position to make (2026-09-21 review).
    func testAGeneratorThatMeasuredNoLoadReportsNone() async throws {
        try await withTier { tier, generator, _ in
            generator.output = self.answer([self.brainText])

            let outcome = await tier.translate([self.brainText])

            XCTAssertNil(outcome.loadDurationMs)
        }
    }

    func testNoInstalledModelIsReportedAndNothingIsGenerated() async throws {
        try await withTier(installed: false) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(outcome, .none)
            XCTAssertTrue(generator.prompts.isEmpty,
                          "no model on disk: no generation, and no attempt to load one")
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.outcome, "degraded")
            XCTAssertEqual(event?.metadata["reason"], "model_not_installed")
            XCTAssertEqual(event?.metadata["failureStage"], "availability",
                           "no attempt was made: the model is not on the device")
        }
    }

    func testAMissingStoreIsReportedAsAMissingRuntime() async throws {
        let bus = LiveTranslateSanitisingBus()
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: nil,
                                             events: LiveTranslateEvents(bus: bus, config: config),
                                             generator: ScriptedGenerator(),
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))
        let outcome = await tier.translate([brainText])

        XCTAssertEqual(outcome, .none)
        let event = bus.events(named: "brain_translation_unavailable").first
        XCTAssertEqual(event?.metadata["reason"], "runtime_missing")
        XCTAssertEqual(event?.metadata["failureStage"], "availability")
    }

    func testAnEmptyBatchIsNotAnAttempt() async throws {
        try await withTier { tier, generator, bus in
            let outcome = await tier.translate([])

            XCTAssertEqual(outcome, .none)
            XCTAssertTrue(generator.prompts.isEmpty)
            XCTAssertTrue(bus.events.isEmpty,
                          "there is nothing to report about a batch nobody asked for")
        }
    }

    // MARK: One batch, not one call per region

    func testEveryUnresolvedStringOfACycleGoesIntoOneGeneration() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer([brainAnswer, secondBrainAnswer, thirdBrainAnswer])
            let sources = [brainText, secondBrainText, thirdBrainText]

            let outcome = await tier.translate(sources)

            XCTAssertEqual(generator.prompts.count, 1,
                           "N unresolved strings are ONE generation, not N")
            XCTAssertEqual(outcome.translations, [brainText: brainAnswer,
                                                  secondBrainText: secondBrainAnswer,
                                                  thirdBrainText: thirdBrainAnswer])
            let event = bus.events(named: "brain_translation_batch").first
            XCTAssertEqual(event?.metadata["resolvedCount"], "3")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "0")
            XCTAssertEqual(event?.outcome, "success")
        }
    }

    func testThePromptCarriesTheSourcesInOrderAndKeepsTheSchemaOutOfIt() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer([brainAnswer, secondBrainAnswer])
            _ = await tier.translate([brainText, secondBrainText])

            let prompt = try XCTUnwrap(generator.prompts.first)
            let first = try XCTUnwrap(prompt.range(of: brainText))
            let second = try XCTUnwrap(prompt.range(of: secondBrainText))
            XCTAssertLessThan(first.lowerBound, second.lowerBound,
                              "the answer is matched back positionally, so the order is load-bearing")
            XCTAssertFalse(prompt.contains("\"translations\""),
                           "the schema is a parameter to the sampler, never part of the prompt "
                           + "(appending it is what truncated the intent brain's generations)")
            XCTAssertFalse(prompt.contains("type"), "no schema text in the prompt")
        }
    }

    /// The one instruction a generation cannot check for itself is the
    /// direction, so it has to be *said* — and said as a pair, because the
    /// prompt that shipped here named the wrong direction ("translate Nepali
    /// sign text into English"), an instruction the English input already
    /// satisfied. The model obeyed it, the literature it produced was settled
    /// as a translation, and the cloud was never asked. This is the pin on the
    /// pair: English in, Nepali out.
    func testThePromptAsksForTheSessionsTargetLanguage() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer([brainAnswer])
            _ = await tier.translate([brainText])

            let prompt = try XCTUnwrap(generator.prompts.first)
            XCTAssertTrue(prompt.contains("You translate English text into Nepali."),
                          "the direction is stated as source → target, in words: \(prompt)")
            XCTAssertFalse(prompt.lowercased().contains("into english"),
                           "the direction is the session's, never the reverse")
        }
    }

    /// The prompt is built from the session's target rather than from a
    /// hard-coded language, so the one direction the design excludes (OD6's
    /// phrase card) is still a *stated* direction rather than a wrong one if a
    /// target ever changes.
    func testTheStatedDirectionFollowsTheTargetLanguage() {
        let inNepali = LocalBrainTranslationTier.prompt(for: ["Pharmacy"],
                                                        targetLanguage: .nepali)
        XCTAssertTrue(inNepali.hasPrefix("You translate English text into Nepali."),
                      "shipped direction: \(inNepali)")

        let inEnglish = LocalBrainTranslationTier.prompt(for: ["फार्मेसी"],
                                                         targetLanguage: .english)
        XCTAssertTrue(inEnglish.hasPrefix("You translate Nepali text into English."),
                      "the mirror direction is derived, not duplicated: \(inEnglish)")
    }

    func testTheEffectiveTimeoutIsTheOneTheGenerationGets() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationBaseTimeoutSeconds = 7
        config.brainTranslationTimeoutPerCharacterSeconds = 0
        config.brainTranslationMaxTimeoutSeconds = 60
        try await withTier(config: config) { tier, generator, _ in
            generator.output = answer([brainAnswer])
            _ = await tier.translate([brainText])
            XCTAssertEqual(generator.timeouts, [7],
                           "the generation gets the EFFECTIVE bound — the dynamic "
                           + "formula's, not a literal at the call site")
        }
    }

    // MARK: The batch is bounded, and the surplus is never dropped

    func testAStringCountOverTheBoundIsLeftForTheNextTier() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationMaxStrings = 2
        try await withTier(config: config) { tier, generator, bus in
            generator.output = answer([brainAnswer, secondBrainAnswer])
            let sources = [brainText, secondBrainText, thirdBrainText]

            let outcome = await tier.translate(sources)

            XCTAssertEqual(generator.prompts.count, 1)
            let prompt = try XCTUnwrap(generator.prompts.first)
            XCTAssertFalse(prompt.contains(thirdBrainText), "the surplus is not in the request")
            XCTAssertEqual(Set(outcome.translations.keys), [brainText, secondBrainText])
            XCTAssertNil(outcome.translations[thirdBrainText],
                         "the string over the bound is unresolved, not dropped")
            XCTAssertEqual(bus.events(named: "brain_translation_batch").first?.metadata["unresolvedCount"],
                           "1",
                           "the count is about the batch the caller handed over, surplus included")
        }
    }

    func testACharacterCountOverTheBoundIsLeftForTheNextTier() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationMaxCharacters = 10
        try await withTier(config: config) { tier, generator, _ in
            let long = String(repeating: "क", count: 8)
            generator.output = answer([brainAnswer, secondBrainAnswer])

            let outcome = await tier.translate([long, long])

            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations.count, 1,
                           "only the prefix that fits is asked about")
        }
    }

    func testASceneThatFitsNothingIsReportedAndNotAttempted() async throws {
        var config = LiveTranslateConfig.default
        // Below the source string's own grapheme count, so the very first
        // string cannot be part of any request.
        config.brainTranslationMaxCharacters = 2
        try await withTier(config: config) { tier, generator, bus in
            XCTAssertGreaterThan(brainText.count, 2, "the fixture must not fit")
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            XCTAssertTrue(generator.prompts.isEmpty,
                          "one string that cannot fit the context is not a request")
            let event = bus.events(named: "brain_translation_batch").first
            XCTAssertEqual(event?.metadata["resolvedCount"], "0")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "1")
            XCTAssertEqual(event?.outcome, "degraded")
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty,
                          "nothing was unavailable — the batch simply did not fit")
        }
    }

    // MARK: Reading the answer

    func testAnAnswerThatStopsEarlyLeavesTheTailUnresolved() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer([brainAnswer])
            let outcome = await tier.translate([brainText, secondBrainText])

            XCTAssertEqual(outcome.translations, [brainText: brainAnswer])
            XCTAssertNil(outcome.translations[secondBrainText],
                         "a short answer must not shift translations onto the wrong sign")
        }
    }

    func testAnEchoAnEmptyStringAndAnOversizedStringAreEachUnresolved() async throws {
        try await withTier { tier, generator, _ in
            let oversized = String(repeating: "x", count: 500)
            generator.output = answer([brainText, "", oversized])

            let outcome = await tier.translate([brainText, secondBrainText, thirdBrainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "an echo is not a translation, an empty string is not an answer, "
                          + "and neither is a string over the shipped sanity bound")
        }
    }

    /// The echo a 4B model actually produces is not byte-identical to its
    /// source: it is the same words in the model's own typography. Byte
    /// equality (what shipped) lets `OPEN` → `Open` through, which settles the
    /// sign as translated while the elder reads no translation at all.
    func testANearEchoOfTheSourceIsNotATranslation() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["pharmacy", "OPEN."])
            let outcome = await tier.translate([brainText, secondBrainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "case and punctuation are not a translation")
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["unresolvedCount"], "2")
            XCTAssertEqual(event?.outcome, "degraded")
        }
    }

    /// The rule the whole fallback depends on: an answer that is not in the
    /// target's script did not change language, so it cannot settle a region.
    /// This is the direction defect as a rule rather than as a wording.
    func testAnAnswerInTheWrongScriptIsUnresolvedEvenWhenItIsNoEcho() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer(["Chemist shop"])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "English is not a Nepali translation of an English sign")
        }
    }

    /// The script rule is about the *target*, so it is not a rule about
    /// Nepali: the English target refuses an answer with no Latin letter in it
    /// and accepts an English one.
    func testTheScriptRuleFollowsTheTargetLanguage() async throws {
        try await withTier(targetLanguage: .english) { tier, generator, _ in
            generator.output = answer([brainAnswer])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "Devanagari is not an English translation")
        }
        try await withTier(targetLanguage: .english) { tier, generator, _ in
            generator.output = answer(["Drug store"])
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome.translations, [brainText: "Drug store"])
        }
    }

    // MARK: The language rule (2026-09-18)

    /// The script rule's blind spot, as a fixture. Devanagari is Hindi's script
    /// as well as Nepali's, so a Hindi answer passes the script rule by
    /// construction — the 2026-09-18 evaluation produced exactly this string
    /// from off-the-shelf rungs, and it settled a region as translated.
    func testAHindiAnswerIsUnresolvedEvenThoughItIsInTheTargetScript() async throws {
        let hindi = "जल के निकट विद्युत उपकरण रखो नहीं।"
        XCTAssertTrue(LocalBrainTranslationTier.usesTheTargetScript(hindi, targetLanguage: .nepali),
                      "the fixture must be the hard case — it is Devanagari, so the script rule is no help")

        try await withTier { tier, generator, bus in
            generator.output = answer([hindi])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "Hindi must not settle a region as the elder's own language")
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["unresolvedCount"], "1",
                           "the string is unresolved, so the next tier is asked for it")
            XCTAssertEqual(event?.outcome, "degraded")
        }
    }

    /// The other 2026-09-18 shape: the model echoed the instruction back in
    /// Nepali. It is Devanagari, it is not an echo of the source, and it is not
    /// a translation — so nothing but the language rule can refuse it.
    func testAnInstructionEchoInNepaliIsUnresolved() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["अंग्रेजी शब्दहरू नेपालीमा अनुवाद गर्नुहोस्। एक लाइनमा…"])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "the instruction is not an answer to it")
            XCTAssertEqual(batchEvent(bus)?.metadata["unresolvedCount"], "1")
        }
    }

    /// The rule is at the tier's answer gate and nowhere else: `accepts` is
    /// what refuses, and the refusals are the two shapes above plus the
    /// marker-free one below. The pin matters because the gate is the only
    /// place a region can be settled on the device.
    func testTheLanguageRuleRefusesHindiAndEchoesAndKeepsNepali() {
        XCTAssertNil(LocalBrainTranslationTier.accepts("खुला है।",
                                                      for: brainText,
                                                      targetLanguage: .nepali,
                                                      config: config),
                     "Hindi")
        XCTAssertNil(LocalBrainTranslationTier.accepts("यो अंग्रेजी वाक्य नेपालीमा अनुवाद गर्नुहोस्।",
                                                      for: brainText,
                                                      targetLanguage: .nepali,
                                                      config: config),
                     "the instruction echoed back")
        XCTAssertEqual(brainAnswer,
                       LocalBrainTranslationTier.accepts(brainAnswer,
                                                         for: brainText,
                                                         targetLanguage: .nepali,
                                                         config: config),
                       "and a Nepali sentence is still an answer")
    }

    /// The fixture the pipeline suite drives through its own double, checked
    /// against the real gate: an answer that suite publishes must be one the
    /// shipped tier would also accept, or the two suites are pinning different
    /// features.
    func testTheAnswerThePipelineSuitePublishesIsOneTheTierWouldAccept() {
        XCTAssertEqual("यहाँ भित्र प्रवेश मात्र",
                       LocalBrainTranslationTier.accepts("यहाँ भित्र प्रवेश मात्र",
                                                         for: "Entry inside only",
                                                         targetLanguage: .nepali,
                                                         config: config))
    }

    /// [SHORT-ANSWER-EXEMPTION] (2026-09-20) The trade-off flipped: a
    /// correct translation that is a single shared noun now SETTLES. The
    /// old conservative rule left it for the next tier, and the owner's
    /// 02:35 capture showed what that bought the elder: every real short
    /// answer refused, and nothing ever shown. The bounded risk is stated
    /// in `NepaliOutputGate`.
    func testAShortMarkerFreeAnswerNowSettles() {
        XCTAssertEqual(LocalBrainTranslationTier.accepts("फार्मेसी",
                                                         for: brainText,
                                                         targetLanguage: .nepali,
                                                         config: config),
                       "फार्मेसी",
                       "a lone shared noun settles the sign: the short-answer exemption")
    }

    /// The exemption's other half: a markerless answer long enough to carry
    /// grammar but not carrying it is still refused — a sentence has room
    /// for evidence, and its absence still means what it always did.
    func testALongMarkerFreeAnswerIsStillLeftForTheNextTier() {
        XCTAssertNil(LocalBrainTranslationTier.accepts("पाणी जवळ विजेची उपकरणे ठेवू नका कारण ते धोकादायक आहे.",
                                                       for: brainText,
                                                       targetLanguage: .nepali,
                                                       config: config),
                     "a long markerless answer is not established as Nepali — it must not settle the sign")
    }

    /// A source with no letters has no script to be translated into, so the
    /// script rule is skipped for it — while the echo rule still applies.
    func testANumeralsOnlySourceIsNotRefusedForItsScript() {
        XCTAssertNil(LocalBrainTranslationTier.accepts("24",
                                                      for: "24",
                                                      targetLanguage: .nepali,
                                                      config: config),
                     "the source again is not a translation, numerals or not")
        XCTAssertEqual(LocalBrainTranslationTier.accepts("२४",
                                                         for: "24",
                                                         targetLanguage: .nepali,
                                                         config: config),
                       "२४",
                       "a numerals-only sign is not refused for having no script to translate into")
    }

    func testAnAnswerThatIsNotTheGrammarIsUnresolvedRatherThanRendered() async throws {
        let prose = "I am sorry, I cannot help with that."
        try await withTier { tier, generator, bus in
            generator.output = prose

            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            let event = batchEvent(bus)
            XCTAssertEqual(event?.outcome, "degraded")
            // [EMPTY-DECODE] The report's discriminating case: something WAS
            // emitted, so this is not the empty decode — and it never parsed,
            // so no per-string rule ran and none may be blamed. The length
            // separates "the decode stopped mid-stream" from "the decode ran
            // to the end in the wrong shape".
            XCTAssertEqual(event?.metadata["generationShape"], "unparsable")
            XCTAssertEqual(event?.metadata["generationLength"], String(prose.count))
            XCTAssertEqual(event?.metadata["rejections"], "none",
                           "no string rule ran, because no string was ever reached")
        }
    }

    // MARK: The generation's own report ([EMPTY-DECODE], 2026-09-19)
    //
    // The owner's device capture: the Q4_K_M head loaded, every batch ran
    // 7–20 seconds, and every batch resolved nothing — with `resolvedCount`,
    // `unresolvedCount` and `durationMs` as the only evidence. Those three
    // cannot tell a decode that emitted nothing from one whose every answer a
    // rule refused, and the two need opposite fixes. These tests pin the half
    // that tells them apart: the raw character count, the structural shape,
    // and which rule refused what.

    /// The decisive case, and the one the owner's phone is suspected of:
    /// nothing came back at all. No answer rule can be blamed — the shape
    /// says the failure is upstream of every one of them.
    func testAGenerationThatEmittedNothingReportsItsLengthAndTheEmptyShape() async throws {
        try await withTier { tier, generator, bus in
            generator.output = ""

            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome.translations, [:])
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["generationLength"], "0",
                           "zero characters is the fact the whole diagnostic turns on")
            XCTAssertEqual(event?.metadata["generationShape"], "empty")
            XCTAssertEqual(event?.metadata["rejections"], "none")
        }
    }

    /// JSON, but not the grammar's object: a decode that stopped after the
    /// opening brace, or an answer shaped by something other than the schema.
    func testAnAnswerWithoutTheTranslationsArrayReportsThatShape() async throws {
        try await withTier { tier, generator, bus in
            generator.output = #"{"translation": "यो औषधि पसल हो"}"#

            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome.translations, [:],
                           "a plausible answer under the wrong key is still not an answer")
            XCTAssertEqual(batchEvent(bus)?.metadata["generationShape"], "no_array")
        }
    }

    /// The end-to-end histogram: an answer that is Devanagari, is not the
    /// source, and carries no Nepali-exclusive evidence — the rejection the
    /// owner's short sign text was most exposed to before the short-answer
    /// exemption, and the one that looks exactly like success in every
    /// count the batch event used to carry. The fixture is long so the
    /// exemption does not apply to it.
    func testARefusedAnswerIsNamedInTheHistogramOnTheEvent() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["पाणी जवळ विजेची उपकरणे ठेवू नका कारण ते धोकादायक आहे."])

            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome.translations, [:])
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["generationShape"], "array",
                           "the answer WAS the grammar's object — the failure is in a rule")
            XCTAssertEqual(event?.metadata["rejections"], "no_nepali_evidence:1",
                           "and the histogram names which one")
        }
    }

    /// [SHORT-ANSWER-EXEMPTION] The 02:35 capture's fix, end to end: a
    /// short markerless Devanagari answer is a translation now, not a
    /// rejection — the histogram says `none`, and the region settles.
    func testAShortMarkerlessAnswerResolvesEndToEnd() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["फार्मेसी"])

            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome.translations, [brainText: "फार्मेसी"],
                           "the short-answer exemption settles the sign")
            XCTAssertEqual(batchEvent(bus)?.metadata["rejections"], "none",
                           "and nothing was refused")
        }
    }

    /// Every rule, named. The pure classification, so the fixture can cover
    /// rules one scripted generation cannot reach in a single call: a short
    /// array, a non-string, and each of the six answer rules.
    func testTheRejectionHistogramNamesEveryRuleThatRefusedAnAnswer() {
        // One call, four sources, four different rules. The marker-free
        // fixture is LONG — the short-answer exemption (2026-09-20) accepts
        // short markerless answers now, and the rule's refusal needs a
        // sentence with room for grammar.
        let mixed = LocalBrainTranslationTier.report(
            answer(["", "पाणी जवळ विजेची उपकरणे ठेवू नका कारण ते धोकादायक आहे.", "खुला है।", "Pharmacy"]),
            sources: ["Pharmacy", "Open", "24", "No entry"],
            targetLanguage: .nepali,
            config: config)
        XCTAssertEqual(mixed.shape, .array)
        XCTAssertEqual(mixed.translations, [:])
        XCTAssertEqual(mixed.rejections, [.empty: 1,
                                          .noNepaliEvidence: 1,
                                          .hindiEvidence: 1,
                                          .wrongScript: 1],
                       "an empty answer, a marker-free one, a Hindi one and an English one "
                       + "are four different facts, and the histogram keeps them apart")

        // The positional half: a short array, a value that is not a string,
        // and the source echoed back.
        let ragged = LocalBrainTranslationTier.report(
            #"{"translations": ["Pharmacy", 42]}"#,
            sources: ["Pharmacy", "Open", "24"],
            targetLanguage: .nepali,
            config: config)
        XCTAssertEqual(ragged.length, #"{"translations": ["Pharmacy", 42]}"#.count)
        XCTAssertEqual(ragged.rejections, [.echo: 1, .nonString: 1, .missing: 1],
                       "an echo, a non-string and a position the array never reached")

        // The size bound and the instruction echo, which the rules above would
        // otherwise mask: both are Devanagari and neither is the source.
        let overBound = String(repeating: "नेपालीमा ", count: 20)
        let instruction = "यो अंग्रेजी वाक्य नेपालीमा अनुवाद गर्नुहोस्।"
        let refused = LocalBrainTranslationTier.report(
            answer([overBound, instruction]),
            sources: ["Pharmacy", "Open"],
            targetLanguage: .nepali,
            config: config)
        XCTAssertEqual(refused.rejections, [.tooLong: 1, .instructionEcho: 1],
                       "over the cloud's own length bound, and the instruction read back")
        XCTAssertGreaterThan(overBound.count,
                             TranslationResponseParser.maxLength(forSource: "Pharmacy", config: config),
                             "the fixture must actually be over the bound")
    }

    /// The other end: an accepted generation reports its own length, the array
    /// shape, and no rejection at all — the histogram's `none` is a statement
    /// that every rule was reached and passed.
    func testAnAcceptedGenerationReportsTheArrayShapeWithNoRejections() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer([brainAnswer])

            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome.translations, [brainText: brainAnswer])
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["generationShape"], "array")
            XCTAssertEqual(event?.metadata["generationLength"], String(answer([brainAnswer]).count))
            XCTAssertEqual(event?.metadata["rejections"], "none")
        }
    }

    /// The two sparse groups on one event are disjoint, which is what makes
    /// the absence of a reading readable: a declined batch never ran, so it
    /// carries no shape to misread as a decode result.
    func testADeclinedBatchCarriesNoGenerationReading() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure()

        try await withTier(ledger: ledger) { tier, _, bus in
            _ = await tier.translate([self.brainText])

            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["reason"], "memory_pressure")
            for key in ["generationLength", "generationShape", "rejections"] {
                XCTAssertNil(event?.metadata[key],
                             "a batch that was never attempted must not report a \(key)")
            }
        }
    }

    func testTranslationsAreTrimmedAndAttributedToTheBrainAlone() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer(["  \(brainAnswer)  "])
            let outcome = await tier.translate([brainText])
            XCTAssertEqual(outcome.translations[brainText], brainAnswer)
        }
    }

    // MARK: A failure is a reason, never a hang and never a stub

    /// The reason token says the attempt was abandoned; the stage token says
    /// where in the attempt it stopped. Both ride on every unavailability
    /// event: a reader who sees `inference_timeout` alone cannot tell a load
    /// that never finished from a decode that ran past the deadline, and that
    /// ambiguity is exactly what the 2026-09-17 device console could not
    /// resolve.
    func testATimedOutGenerationIsReportedAndAnswersNothing() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .timedOut
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_timeout")
            XCTAssertEqual(event?.metadata["failureStage"], "deadline",
                           "the deadline fired on the generation itself, not on the load")
            XCTAssertTrue(bus.events(named: "brain_translation_batch").isEmpty,
                          "a generation that never produced an answer did not resolve a batch")
        }
    }

    func testAFailedLoadIsReportedWithItsOwnReason() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .loadFailed
            _ = await tier.translate([brainText])
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "model_load_failed")
            XCTAssertEqual(event?.metadata["failureStage"], "load")
        }
    }

    func testAPromptWithNoRoomToAnswerIsReportedRatherThanTruncated() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .promptOverflow
            _ = await tier.translate([brainText])
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_failed")
            XCTAssertEqual(event?.metadata["failureStage"], "prompt_budget",
                           "the prompt did not fit the window the tier enforces")
        }
    }

    /// The caller stopped waiting — the pipeline's stage deadline, or the
    /// capture session ending. The tier stops the decode with it, and says so:
    /// `cancelled` is a stage of its own precisely so that a stopped decode is
    /// never read as a broken one. On the device this was the tail of the
    /// 2026-09-17 session, where every abandoned batch was reported as
    /// `inference_failed` and looked like a model fault.
    func testACancelledAttemptIsReportedAsAStoppedAttempt() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .cancelled
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_timeout",
                           "a stopped attempt is the same reason token as a deadline hit")
            XCTAssertEqual(event?.metadata["failureStage"], "cancelled",
                           "…but a different stage: nobody's generation failed here")
        }
    }

    /// A throw the tier has no classification for — a llama.cpp `LLMError`, a
    /// failed allocation, a grammar the template refused. It lands on the
    /// decode stage, which is the honest reading: the attempt reached the
    /// decode and the decode is what threw.
    func testAnUnclassifiedThrowIsReportedAsADecodeFailure() async throws {
        struct RuntimeThrow: Error {}
        try await withTier { tier, generator, bus in
            generator.runtimeError = RuntimeThrow()
            _ = await tier.translate([brainText])
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_failed")
            XCTAssertEqual(event?.metadata["failureStage"], "decode")
        }
    }

    func testReleaseDropsTheResidentHandle() async throws {
        try await withTier { tier, generator, _ in
            await tier.release()
            XCTAssertEqual(generator.releaseCount, 1)
        }
    }

    // MARK: The device pays for the load only when it can

    /// Another owner's brain is live: the voice pipeline holds one while the
    /// household is talking to it, and a second 4B decode alongside it is the
    /// shape that gets the app killed. The translation is the workload that can
    /// afford to wait, and the strings are left for the cloud.
    func testTheBatchIsNotAskedWhenAnotherOwnersBrainIsResident() async throws {
        // `evictable: false` is what keeps this the *rule's* test rather than
        // the warden's: the walk has nothing it is allowed to take, so the
        // refusal `deferralForLoad` produced is the one that stands. With an
        // evictable resident the warden is asked and answers — that half is
        // pinned in the [LOAD-EVICT] section below.
        let (ledger, owner) = makeLedger(residing: .brain, evictable: false)
        let probe = ScriptedProbe()
        try await withTier(memory: probe, ledger: ledger) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText, self.secondBrainText])

            XCTAssertTrue(generator.prompts.isEmpty,
                          "the 4B is live for the voice pipeline: this batch does not load it")
            XCTAssertTrue(outcome.translations.isEmpty)
            XCTAssertEqual(outcome.deferral, .residentBrain)
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["resolvedCount"], "0")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "2",
                           "every string handed over is reported unresolved, so the caller knows "
                           + "to send all of them onward")
            XCTAssertEqual(event?.outcome, "degraded")
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty,
                          "nothing was unavailable — the device was busy with something else")
            XCTAssertEqual(probe.headroomReads, 0,
                           "the residency rule is asked first: no memory is read to refuse a load "
                           + "that another owner's brain already forbids")
            _ = owner
        }
    }

    /// The intent brain counts as another owner's brain too: it is a second
    /// llama handle for the same 4B class, and co-residency is exactly what the
    /// ledger's budget exists to prevent.
    func testTheBatchIsNotAskedWhenTheIntentBrainIsResident() async throws {
        let (ledger, owner) = makeLedger(residing: .intentBrain, evictable: false)
        try await withTier(ledger: ledger) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty)
            XCTAssertEqual(outcome.deferral, .residentBrain)
            _ = owner
        }
    }

    /// Not enough headroom to hold the model's non-pageable bytes: this is the
    /// state that gets a phone killed, so the batch goes to the cloud instead.
    /// The comparison is the app's own declared quantity — the same
    /// `ModelFootprint.hardBytes` the ledger budgets with — not a number this
    /// tier invented.
    func testTheBatchIsNotAskedWhenThereIsNoHeadroomForTheLoad() async throws {
        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: Self.modelID)
        let probe = ScriptedProbe(headroom: footprint.hardBytes / 2)
        try await withTier(memory: probe) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty, "no load: no generation")
            XCTAssertEqual(outcome.deferral,
                           .insufficientHeadroom(requiredBytes: Double(footprint.hardBytes),
                                                 availableBytes: Double(probe.headroom)))
            XCTAssertEqual(batchEvent(bus)?.outcome, "degraded")
            XCTAssertGreaterThan(probe.headroomReads, 0, "the gate read the headroom to decide")
        }
    }

    /// The configured factor scales the requirement, so a device can be told to
    /// keep a margin rather than to spend its last byte.
    func testTheHeadroomFactorScalesTheRequirement() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationHeadroomFactor = 2
        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: Self.modelID)
        let probe = ScriptedProbe(headroom: footprint.hardBytes)
        try await withTier(config: config, memory: probe) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty,
                          "one model's worth of headroom is not two models' worth")
            XCTAssertEqual(outcome.deferral,
                           .insufficientHeadroom(requiredBytes: Double(footprint.hardBytes) * 2,
                                                 availableBytes: Double(footprint.hardBytes)))
        }
    }

    /// With the headroom above the requirement the load is admitted, so the
    /// gate is a gate rather than a refusal.
    func testTheBatchIsAskedWhenTheDeviceCanPayForTheLoad() async throws {
        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: Self.modelID)
        let probe = ScriptedProbe(headroom: footprint.hardBytes * 4)
        try await withTier(memory: probe) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertNil(outcome.deferral)
        }
    }

    /// A handle is already open on the model: the bytes are spent, so the
    /// headroom reading is not a reason to refuse the batch that is already
    /// paying for them.
    func testAResidentHandleIsNotRefusedForHeadroom() async throws {
        let probe = ScriptedProbe(headroom: 0)
        try await withTier(memory: probe) { tier, generator, _ in
            generator.holdingHandle = true
            generator.output = answer([self.brainAnswer])
            _ = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "the handle is open: the load the gate guards is not going to happen")
        }
    }

    /// The deferral to another owner is configurable, so a device that would
    /// rather queue behind the voice pipeline than skip the tier can say so.
    func testDeferringToAResidentBrainIsConfigurable() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationDefersToResidentBrain = false
        let (ledger, owner) = makeLedger(residing: .brain)
        try await withTier(config: config, ledger: ledger) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            _ = owner
        }
    }

    /// A gate that fired is not an unavailable tier, and the difference is what
    /// the caller reads to decide whether the batch is owed to the cloud.
    func testADeferredBatchReportsItselfAsUnresolvedRatherThanUnavailable() async throws {
        let (ledger, owner) = makeLedger(residing: .brain, evictable: false)
        try await withTier(ledger: ledger) { tier, _, bus in
            _ = await tier.translate([self.brainText])

            XCTAssertEqual(bus.events(named: "brain_translation_batch").count, 1)
            XCTAssertEqual(bus.events(named: "brain_translation_batch").first?.outcome, "degraded")
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty)
            _ = owner
        }
    }

    // MARK: Nothing but counts and closed tokens reaches the log

    func testNoEventCarriesAStringFromTheBatch() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer([brainAnswer])
            _ = await tier.translate([brainText, secondBrainText])

            for event in bus.events {
                for (key, value) in event.metadata {
                    XCTAssertFalse(value.contains(brainText) || value.contains(secondBrainText),
                                   "\(event.eventType).\(key) carries a source string")
                    XCTAssertFalse(value.contains(brainAnswer),
                                   "\(event.eventType).\(key) carries a translation")
                    XCTAssertFalse(value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                                   "\(event.eventType).\(key) carries Devanagari — content reached the log")
                }
            }
        }
    }

    func testTheBatchEventCarriesTheDurationTheTierMeasured() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer([brainAnswer])
            let outcome = await tier.translate([brainText])

            let event = try XCTUnwrap(bus.events(named: "brain_translation_batch").first)
            XCTAssertEqual(event.metadata["durationMs"], String(outcome.durationMs))
            XCTAssertEqual(event.durationMs, outcome.durationMs,
                          "the top-level duration and the metadata key come from one measurement")
            XCTAssertGreaterThanOrEqual(outcome.durationMs, 0)
        }
    }

    // MARK: [MODEL-WARDEN] Step 2 — the tier's own position

    /// The tier's residency contract, in one place.
    ///
    /// The load path itself (`LlamaBrainTextGenerator.loadHandle`) is under
    /// `#if canImport(LLM)` and needs a real GGUF to run, so what a unit test
    /// can hold to account is the *position* that path registers: the
    /// footprint it is counted as, the priority it carries, and the release
    /// contract that decides whether the warden may overrule a refusal.
    func testTheTranslatePositionIsABrainClassRowOfItsOwn() {
        let id = Self.modelID
        let translate = ModelLifecycleInventory.footprint(for: .translateBrain,
                                                          modelID: id)
        let brain = ModelLifecycleInventory.footprint(for: .brain, modelID: id)

        // The same bytes as the voice brain: it is the same artifact class,
        // and charging it anything else would make the ledger's total
        // unreconcilable against `phys_footprint`.
        XCTAssertEqual(translate.liveBytes, brain.liveBytes)
        XCTAssertEqual(translate.hardBytes, brain.hardBytes)
        XCTAssertEqual(translate.role, .brain)
        XCTAssertEqual(translate.residency, .pageableWeights)
        // A llama handle survives being dropped while a decode runs (ARC
        // keeps the runtime alive), which is what lets the warden force it.
        XCTAssertEqual(translate.releaseContract, .actorDeferredFree)
        XCTAssertTrue(translate.releaseContract.allowsForcedUnload)
        // …and the one that may never be forced, for contrast: freeing a
        // whisper.cpp context under a running `whisper_full` crashes.
        XCTAssertFalse(ModelReleaseContract.perAttemptContext.allowsForcedUnload)
        XCTAssertFalse(ModelReleaseContract.processLifetime.allowsForcedUnload)
    }

    /// The tier's handle is registered as a *resident the warden can ask*, and
    /// the answer is honest about what is in flight: a decode means the
    /// handle is in use, and an idle handle is handed straight over.
    func testTheTierHandleSlotAnswersTheWardenHonestly() {
        let box = TranslateBrainHandleSlot()
        let url = URL(fileURLWithPath: "/tmp/not-a-real-model.gguf")

        XCTAssertEqual(box.releaseForWarden(), .notHolding,
                       "no handle: nothing to give back, and the warden is told which")

        box.store("a handle", url: url)
        XCTAssertTrue(box.isHoldingHandle)
        XCTAssertEqual(box.releaseForWarden(), .released)
        XCTAssertFalse(box.isHoldingHandle)
        XCTAssertNil(box.currentHandle)
        XCTAssertNil(box.heldModelURL, "the URL goes with the handle it named")

        box.store("a handle", url: url)
        box.beginDecode("a handle")
        XCTAssertEqual(box.releaseForWarden(), .refused(.inUse),
                       "an inference is running on it")
        XCTAssertTrue(box.isHoldingHandle,
                      "a refusal is not a partial drop: the handle is still there")
        XCTAssertEqual(box.currentHandle as? String, "a handle")

        box.endDecode("a handle")
        XCTAssertEqual(box.releaseForWarden(), .released,
                       "the lease is held for the decode and released after it")
    }

    /// One handle at a time, by construction ([MODEL-SWITCH], 2026-09-21
    /// review). The switch's own fix is an ORDERING inside `loadHandle`, and
    /// that method is `#if canImport(LLM)` — it needs a real GGUF to run, the
    /// same limit the residency test above records. What a suite can hold is
    /// the property the ordering leans on: a second `store` REPLACES the
    /// first handle and its URL rather than joining it, and `drop` clears
    /// both halves together. If the box could hold two, dropping before
    /// loading would not be enough to stop a switch double-residing.
    func testAHandleSlotHoldsOneModelAtATime() {
        let box = TranslateBrainHandleSlot()
        let first = URL(fileURLWithPath: "/tmp/\(Self.modelID)-q4_k_m.gguf")
        let second = URL(fileURLWithPath: "/tmp/\(ModelCatalog.nmtEnNeQwen17bR4Q5)-q4_k_m.gguf")

        box.store("first handle", url: first)
        box.store("second handle", url: second)

        XCTAssertEqual(box.currentHandle as? String, "second handle",
                       "the box keeps one handle, so the old model's bytes are not held here")
        XCTAssertEqual(box.heldModelURL, second,
                       "…and the URL travels with the handle it names, never orphaned")

        box.drop()
        XCTAssertNil(box.currentHandle)
        XCTAssertNil(box.heldModelURL, "a drop is not a partial one: both halves go")
        XCTAssertFalse(box.isHoldingHandle)
    }

    /// [MODEL-SWITCH] A decode that outlives its handle stays reachable
    /// (2026-09-21 review round 2).
    ///
    /// The switch drops the box's handle while an earlier decode may still be
    /// unwinding on that runtime: the loop is synchronous and
    /// non-cancellable, so `stop` shortens it but does not end it. Before
    /// this fix the runtime went with the drop — nothing could stop it, and
    /// the generator had already told the ledger its bytes were back while
    /// the model was still in memory. The box's half is what a suite can hold
    /// without a GGUF: the runtime stays referenced, and reachable for a
    /// stop, until its decode ends.
    func testASupersededDecodeStaysReachableUntilItEnds() {
        let box = TranslateBrainHandleSlot()
        box.store("old handle", url: URL(fileURLWithPath: "/tmp/old-model.gguf"))
        box.beginDecode("old handle")

        box.drop()

        XCTAssertFalse(box.isHoldingHandle, "the box's reference is gone: the switch moved on")
        XCTAssertTrue(box.isDecoding, "…but the runtime is still decoding on that model")
        XCTAssertTrue(box.runtimesToInterrupt.contains { ($0 as? String) == "old handle" },
                      "a stop can still reach it — the superseded decode is the one nobody else can stop")

        box.endDecode("old handle")

        XCTAssertFalse(box.isDecoding, "the decode is over, so its bytes may be retired")
        XCTAssertFalse(box.runtimesToInterrupt.contains { ($0 as? String) == "old handle" },
                       "…and the box stops holding a runtime it no longer runs")
    }

    /// [MODEL-SWITCH] The ledger's release waits for a superseded decode
    /// (2026-09-21 review round 2) — the other half of the test above.
    ///
    /// Dropping the box's handle is not the moment the old model leaves
    /// memory: the runtime is still decoding, and the box still references
    /// it. Retiring the tier's row at the drop is how a switch ends up with
    /// two models resident while the ledger books one — the arithmetic the
    /// next load then reserves against.
    ///
    /// Driven without a GGUF, like the residency tests beside it: the two
    /// calls a switch makes are `slot.drop()` and the settle, and both are
    /// reachable here through `release()`.
    func testTheLedgerKeepsTheBytesUntilASupersededDecodeEnds() async {
        let ledger = ModelLifecycleManager(
            probe: ScriptedProbe(),
            budgetOverrideBytes: ModelLifecycleBudget.standardModelsBudgetBytes)
        let generator = LlamaBrainTextGenerator(config: config, lifecycle: ledger)
        // The shipped registration's owner IS the box (that is what makes the
        // tier's own releases owner-scoped), so the fixture registers the
        // same way rather than approximating it with a separate object.
        ledger.register(slot: .translateBrain, modelID: Self.modelID, owner: generator.slot,
                        priority: ReservationPurpose.liveTranslate.priority,
                        resident: generator.slot) {}
        generator.slot.store("a handle", url: URL(fileURLWithPath: "/tmp/not-a-real-model.gguf"))
        ledger.didLoad(.translateBrain, owner: generator.slot)
        generator.slot.beginDecode("a handle")

        await generator.release()

        XCTAssertFalse(generator.slot.isHoldingHandle, "the switch dropped the box's handle")
        XCTAssertTrue(ledger.isResident(.translateBrain),
                      "…and the model is STILL resident: a decode is running on it")

        generator.slot.endDecode("a handle")
        await generator.release()

        XCTAssertFalse(ledger.isResident(.translateBrain),
                       "the decode ended: the bytes are back, and only now is the row retired")
    }

    /// The two rows are distinct positions: registering the tier's does not
    /// replace the voice interpreter's, which is exactly why the tier could
    /// not register at all before `.translateBrain` existed (one entry per
    /// slot, so its release closure would have freed the interpreter's
    /// handle).
    func testRegisteringTheTierPositionLeavesTheVoiceBrainsReleaseClosureAlone() {
        let manager = ModelLifecycleManager(
            probe: ScriptedProbe(),
            budgetOverrideBytes: ModelLifecycleBudget.standardModelsBudgetBytes)
        let voiceOwner = FakeOwner()
        let tierOwner = FakeOwner()
        var voiceUnloads = 0
        var tierUnloads = 0

        manager.register(slot: .brain, modelID: Self.modelID, owner: voiceOwner,
                         priority: .foreground) { [weak voiceOwner] in
            _ = voiceOwner
            voiceUnloads += 1
        }
        manager.didLoad(.brain, owner: voiceOwner)

        let box = TranslateBrainHandleSlot()
        manager.register(slot: .translateBrain, modelID: Self.modelID, owner: tierOwner,
                         priority: ReservationPurpose.liveTranslate.priority,
                         resident: box) { [weak tierOwner] in
            _ = tierOwner
            tierUnloads += 1
        }
        manager.didLoad(.translateBrain, owner: tierOwner)

        XCTAssertNotEqual(ModelSlot.brain, ModelSlot.translateBrain)
        XCTAssertTrue(manager.isResident(.brain))
        XCTAssertTrue(manager.isResident(.translateBrain))
        XCTAssertEqual(manager.snapshot().priorities[.brain], .foreground)
        XCTAssertEqual(manager.snapshot().priorities[.translateBrain], .foreground)

        // Evicting the voice position runs the voice interpreter's release,
        // not the tier's.
        manager.evict(.brain, reason: .explicit)
        XCTAssertEqual(voiceUnloads, 1)
        XCTAssertEqual(tierUnloads, 0,
                       "the tier's handle is not what a `.brain` eviction frees")
        XCTAssertTrue(manager.isResident(.translateBrain),
                      "…and the tier's resident is still counted")
        _ = (voiceOwner, tierOwner)
    }

    /// The tier does not defer to its own position.
    ///
    /// A self-deferral would be a deadlock, not a policy: the handle can only
    /// become resident by way of a batch, so a batch that refused to run
    /// while `.translateBrain` was resident could never run again. The rule
    /// is about the *other* owners' brains, and the two cases here differ
    /// only in which slot holds the row.
    func testTheTierDoesNotDeferToItsOwnResidentPosition() async throws {
        let (ledger, owner) = makeLedger(residing: .translateBrain)
        try await withTier(ledger: ledger) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertNil(outcome.deferral,
                         "its own resident handle is the load being reused, not a reason to wait")
            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            _ = owner
        }
        // The contrast case, unchanged from Step 1: the SAME residency on the
        // voice interpreter's position does defer — the warden's walk has
        // nothing it may take here (`evictable: false`, the shape production
        // gives the residents the app must not unload), so the deferral is
        // final. An evictable voice brain is a different test, and it lives in
        // the [LOAD-EVICT] section.
        let (voiceLedger, voiceOwner) = makeLedger(residing: .brain, evictable: false)
        try await withTier(ledger: voiceLedger) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])
            XCTAssertEqual(outcome.deferral, .residentBrain)
            XCTAssertTrue(generator.prompts.isEmpty)
            _ = voiceOwner
        }
    }

    // MARK: [PRESSURE-SAFE LOAD] — the kernel's own view of the device
    //
    // The 2026-09-19 device death, as four rules. The owner's phone was
    // already starved when the session started — the system was jetsamming
    // daemons minutes before it — and the tier loaded anyway, because the
    // headroom gate it had is blind to the device: `os_proc_available_memory`
    // is the APP's account under its own ceiling, and a phone whose system is
    // out of free pages can still read as roomy by it. A 1.03 GB Metal
    // offloaded load began, memory-pressure events fired, and the process was
    // gone about five seconds later.
    //
    // The rule these tests pin is the second opinion, and it is the kernel's.

    /// A clock this file owns, so "critical fired five seconds ago" is an
    /// assertion rather than a sleep. The ledger takes it as its `clock:`.
    private final class PressureClock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// A ledger on the scripted probe and a clock this file drives — the same
    /// shape `ModelLifecycleManagerTests` uses, so the pressure arithmetic is
    /// a fact about this file and not about the machine running it. The budget
    /// is pinned for the same reason.
    private func makePressureLedger(_ clock: PressureClock) -> ModelLifecycleManager {
        ModelLifecycleManager(probe: ScriptedProbe(),
                              clock: { clock.now },
                              budgetOverrideBytes: ModelLifecycleBudget.standardModelsBudgetBytes)
    }

    /// A generator on the **gated** path. The checkpoints the load-in-flight
    /// tests are about live in the reserve's neighbourhood, and the testing
    /// bypass is precisely what removes the reserve — so these tests are about
    /// the shipped arithmetic-off-but-device-on configuration only in the
    /// sense that they run the warden's own machinery.
    private func makeGenerator(on ledger: ModelLifecycleManager) -> LlamaBrainTextGenerator {
        var config = LiveTranslateConfig.default
        config.wardenBypassForTesting = false
        return LlamaBrainTextGenerator(config: config, lifecycle: ledger)
    }

    /// A URL that names a real catalog artifact — which is what the load path
    /// resolves the model (and therefore the footprint the reservation is made
    /// against) from: `loadHandle` maps a URL back to a ModelID by matching the
    /// last path component against `ModelCatalog.all`. Nothing exists at the
    /// path, which is the point: the tests below are about the decisions taken
    /// before any file is opened.
    private func catalogURL(_ id: ModelID) throws -> URL {
        let filename = try XCTUnwrap(ModelCatalog.all.first { $0.id == id }?.filename,
                                     "\(id) must be a catalog artifact")
        return URL(fileURLWithPath: "/tmp/\(filename)")
    }

    /// A sink for the ledger's event stream, so a test can make a claim about
    /// what the ledger was *told* and not only about what the load returned.
    /// The callbacks run synchronously on the calling task.
    private final class EventSink {
        var events: [ModelLifecycleEvent] = []

        func abandonReasons(for slot: ModelSlot) -> [ReservationAbandonReason] {
            events.compactMap { event in
                guard case .reservationAbandoned(slot: let reported, reason: let reason) = event,
                      reported == slot else { return nil }
                return reason
            }
        }
    }

    /// The rule the owner's phone died for, and the one the testing bypass
    /// must **not** be able to turn off.
    ///
    /// The probe is deliberately generous — four times the brain's hard
    /// footprint — because the refusal has to come from the kernel's signal
    /// and not from the arithmetic. A test that let the headroom rule fire
    /// first would pass on the exact bug it exists to catch: the arithmetic is
    /// the half that was already happy on the device that died.
    func testTheTestingBypassDoesNotSkipThePressureRule() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        let probe = ScriptedProbe(headroom: 32_000_000_000)
        ledger.handleMemoryPressure(level: .critical)

        try await withTier(memory: probe, ledger: ledger) { tier, generator, bus in
            XCTAssertFalse(LiveTranslateConfig.default.wardenBypassForTesting,
                           "the bypass flipped off with the 2026-09-20 device pass — the gated "
                           + "path is the shipped default, and this rule has to hold in it")
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty,
                          "no generation: the load was never attempted")
            XCTAssertEqual(outcome.deferral, .memoryPressure(level: .critical))
            XCTAssertEqual(probe.headroomReads, 0,
                           "the kernel's reading is asked before the arithmetic — the stronger "
                           + "signal decides, and the arithmetic is not even consulted")
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["reason"], "memory_pressure",
                           "the event says why the brain was never asked")
            XCTAssertEqual(event?.metadata["resolvedCount"], "0")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "1")
            XCTAssertEqual(event?.outcome, "degraded")
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty,
                          "nothing was unavailable — the device declined to be loaded")
        }
    }

    /// [LOAD-SERIALIZATION] The load path stands an in-flight STT load down
    /// before it starts allocating — the owner's 15:39 collision, pinned: an
    /// STT warm finishing in the same second the translation load was
    /// admitted was the exact two-page-in spike the device died from. The
    /// warm is anticipatory and re-loads on demand; this load answers the
    /// elder's live request.
    ///
    /// The load path is reached directly (the real generator, the gated
    /// configuration): the scripted generator the `withTier` tests use never
    /// enters `loadHandle`, which is where the preempt lives. Without the
    /// preempt, the reserve below would be refused `loadInFlight(holder:
    /// .speechToText)` and the permit would survive the whole attempt.
    func testTheLoadPreemptsAnInFlightSTTReservation() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .normal)
        let sttOwner = FakeOwner()
        guard case .success(let sttReservation) = ledger.reserve(ModelLoadRequest(
            slot: .speechToText,
            modelID: ModelCatalog.whisperKitNepaliMedium,
            owner: sttOwner,
            purpose: .voiceTurn,
            replacesSlotContents: true)) else {
            XCTFail("expected the STT reservation to be granted")
            return
        }

        let generator = makeGenerator(on: ledger)
        let modelURL = try catalogURL(Self.modelID)

        do {
            _ = try await generator.generate(prompt: "1. \(brainText)",
                                             jsonSchema: LocalBrainTranslationTier.jsonSchema,
                                             modelURL: modelURL,
                                             timeout: 5)
            XCTFail("the generation cannot succeed in tests: no model artifact is installed")
        } catch {
            // The downstream load is not the fact under test — the preempt is.
        }
        XCTAssertFalse(ledger.isReservationHeld(sttReservation.id),
                       "the in-flight STT permit stood down before the translation "
                       + "load started allocating")
    }

    /// The UIKit path — the level-2 warning the app has always handled — is
    /// the same rule. A gate that only listened to the dispatch source would
    /// miss every warning on a device where that source failed to install.
    func testAWarningPressureLevelDefersTheLoadAsWell() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure()

        try await withTier(ledger: ledger) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty)
            XCTAssertEqual(outcome.deferral, .memoryPressure(level: .warning))
            XCTAssertEqual(batchEvent(bus)?.metadata["reason"], "memory_pressure")
        }
    }

    /// A `.critical` is an *instant*, not a state, and the window is what
    /// carries it past the moment: the kernel says nothing more until it says
    /// something, so the quiet seconds afterwards are exactly when "we were
    /// nearly killed" is still the most honest thing known about the device.
    /// The level having eased back to `.normal` does not reopen the gate.
    func testARecentCriticalPressureDefersAfterTheLevelHasEased() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)
        ledger.handleMemoryPressure(level: .normal)
        clock.advance(5)

        try await withTier(ledger: ledger) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty,
                          "the level is normal and the device is still the one that was about to "
                          + "be killed four seconds ago")
            XCTAssertEqual(outcome.deferral,
                           .recentCriticalPressure(secondsSince: 5, windowSeconds: 30))
            XCTAssertEqual(batchEvent(bus)?.metadata["reason"], "recent_critical_pressure")
        }
    }

    /// The window is a window and not a latch. Without this the rule would be
    /// a device that never loads again after one bad minute, which is a worse
    /// product than the crash it prevents — the tier would defer every batch
    /// for the rest of the session.
    func testACriticalPressureOlderThanTheWindowNoLongerDefersTheLoad() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)
        ledger.handleMemoryPressure(level: .normal)
        clock.advance(LiveTranslateConfig.default.brainTranslationCriticalPressureWindowSeconds + 1)

        try await withTier(ledger: ledger) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "the window has passed: the load is allowed again")
            XCTAssertNil(outcome.deferral)
        }
    }

    /// [PRESSURE-LATCH] The owner's 15:51 capture as a regression pin: the
    /// level latches at `.critical` — no `.normal` ever follows — and the
    /// tier must load anyway once the critical is older than the window,
    /// because the alternative is every batch refused with
    /// `reason=memory_pressure durationMs=0` for the rest of the session
    /// while the warden sits silent.
    func testALatchedCriticalOlderThanTheWindowNoLongerDefersTheLoad() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)
        clock.advance(40)

        try await withTier(ledger: ledger) { tier, generator, bus in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "40s past the window the critical is history, not a device state: "
                           + "nothing has ever cleared the level, and the load must still happen")
            XCTAssertNil(outcome.deferral)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertNotEqual(batchEvent(bus)?.metadata["reason"], "memory_pressure",
                              "and the batch does not carry the pressure reason")
        }
    }

    /// [PRESSURE-LATCH] The same window, applied to the level that can *latch*.
    ///
    /// `.critical` was assumed paired — the dispatch source that sends it
    /// sends `.normal` when the squeeze ends, and that second event is what
    /// clears the level — but the owner's 15:51 capture showed it latching
    /// the same way: forty-two seconds of refusals while the warden was
    /// silent. A `.warning` routed from
    /// `UIApplication.didReceiveMemoryWarningNotification` has no counterpart —
    /// the app records the level and nothing on that route ever takes it back —
    /// so a gate that refused on the bare level would refuse every load for the
    /// rest of the process's life after one transient warning, reporting
    /// `durationMs=0` and `reason=memory_pressure` on every batch with no
    /// device state that could ever change the answer.
    ///
    /// The age is what makes that recoverable, and this is the owner-visible
    /// half of it: a warning 40 seconds old — past the 30-second window, and
    /// with no `.normal` following it, exactly as the UIKit route leaves it —
    /// must not stand between the tier and a translation.
    func testAWarningOlderThanTheWindowNoLongerDefersTheLoad() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure()
        clock.advance(40)

        try await withTier(ledger: ledger) { tier, generator, bus in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "40s past the window the warning is history, not a device state: "
                           + "nothing has ever cleared the level, and the load must still happen")
            XCTAssertNil(outcome.deferral)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertNotEqual(batchEvent(bus)?.metadata["reason"], "memory_pressure",
                              "and the batch does not carry the pressure reason")
        }
    }

    /// The two edges of that window, on the pure function the pre-attempt gate
    /// and the load path share — so neither caller can drift from the other on
    /// the one level whose level alone cannot be trusted.
    func testTheWarningWindowRefusesWhileFreshAndReleasesOnceStale() {
        let window = LiveTranslateConfig.default.brainTranslationCriticalPressureWindowSeconds
        func reading(_ warningAge: TimeInterval?, criticalAge: TimeInterval? = nil)
            -> MemoryPressureReading {
            MemoryPressureReading(level: .warning,
                                  secondsSinceCritical: criticalAge,
                                  secondsSinceWarning: warningAge)
        }

        XCTAssertEqual(LocalBrainTranslationTier.pressureDeferral(reading(0), windowSeconds: window),
                       .memoryPressure(level: .warning),
                       "a warning happening now is refused, as it always was")
        XCTAssertEqual(LocalBrainTranslationTier.pressureDeferral(reading(window - 1),
                                                                  windowSeconds: window),
                       .memoryPressure(level: .warning),
                       "one second inside the window is inside it")
        XCTAssertNil(LocalBrainTranslationTier.pressureDeferral(reading(window), windowSeconds: window),
                     "at the window the warning is stale — the same boundary the critical rule "
                     + "uses — and the latched level stops refusing anything on its own")
        XCTAssertEqual(LocalBrainTranslationTier.pressureDeferral(reading(window + 10,
                                                                           criticalAge: 5),
                                                                  windowSeconds: window),
                       .recentCriticalPressure(secondsSince: 5, windowSeconds: window),
                       "a stale warning does not erase a critical that fired seconds ago: the "
                       + "critical-age check still runs behind it")

        // A reading built without an age at all is a reading from before this
        // key existed. It is refused, because "no timestamp" must not become a
        // way past the gate — the freshness has to be *stated* to be believed.
        XCTAssertEqual(LocalBrainTranslationTier.pressureDeferral(reading(nil), windowSeconds: window),
                       .memoryPressure(level: .warning))
    }

    /// [PRESSURE-LATCH] The same window, on the level the original fix
    /// declared immune.
    ///
    /// The assumption was that a `.critical` is paired: the dispatch source
    /// that sends it also sends `.normal` when the squeeze ends, so a level
    /// that still read `.critical` was a device that was still critical. The
    /// owner's 15:51 device capture (2026-09-19) falsified it: forty-two
    /// seconds of `reason=memory_pressure` refusals while the warden was
    /// silent. A critical now ages out on the same window: fresh refuses as
    /// the level itself (the token a capture already knows), stale falls
    /// through to the caller's headroom arithmetic.
    func testTheCriticalWindowRefusesWhileFreshAndReleasesOnceStale() {
        let window = LiveTranslateConfig.default.brainTranslationCriticalPressureWindowSeconds
        func reading(_ criticalAge: TimeInterval?) -> MemoryPressureReading {
            MemoryPressureReading(level: .critical,
                                  secondsSinceCritical: criticalAge,
                                  secondsSinceWarning: nil)
        }

        XCTAssertEqual(LocalBrainTranslationTier.pressureDeferral(reading(0), windowSeconds: window),
                       .memoryPressure(level: .critical),
                       "a critical happening now is refused, as it always was")
        XCTAssertEqual(LocalBrainTranslationTier.pressureDeferral(reading(window - 1),
                                                                  windowSeconds: window),
                       .memoryPressure(level: .critical),
                       "one second inside the window is inside it")
        XCTAssertNil(LocalBrainTranslationTier.pressureDeferral(reading(window), windowSeconds: window),
                     "at the window the critical is stale — the same boundary the warning rule "
                     + "uses — and the latched level stops refusing anything on its own")

        // The conservative half, unchanged: no timestamp is not a way past
        // the gate — the freshness has to be *stated* to be believed.
        XCTAssertEqual(LocalBrainTranslationTier.pressureDeferral(reading(nil), windowSeconds: window),
                       .memoryPressure(level: .critical))
    }

    /// The other side of the same gate, so it is a gate and not a refusal:
    /// `.normal` is what the source reports when it is first activated, and it
    /// is the shipped state on a healthy device.
    func testANormalPressureReadingLetsTheLoadProceed() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .normal)

        try await withTier(ledger: ledger) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertNil(outcome.deferral)
        }
    }

    /// The pressure rule is a gate on a **load**, and this is where that
    /// boundary is drawn: a handle that is already open has already paid, so
    /// refusing the batch that reuses it would cost an answer and return no
    /// byte.
    ///
    /// Pinned rather than left implicit because it is a real trade — decoding
    /// on a resident handle still touches the mmap'd weights, so it is not
    /// free — and the decision is that a multi-second decode of bytes already
    /// in memory is not the spike the load was. It is also very nearly
    /// unreachable in the field: a `.critical` evicts every evictable
    /// resident, so a handle still resident through one is one the warden
    /// could not take.
    func testAResidentHandleIsNotRefusedForPressure() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)

        try await withTier(memory: ScriptedProbe(headroom: 0), ledger: ledger) { tier, generator, _ in
            generator.holdingHandle = true
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "the bytes are spent: this batch pays no load")
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
        }
    }

    /// The pressure rule with a `.warning` and no headroom to speak of is
    /// still the pressure rule: the kernel's level is the first of the two
    /// that refuses, so the numbers a capture sees are the level's and not the
    /// arithmetic's.
    func testThePressureRuleOutranksTheHeadroomArithmetic() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: Self.modelID)
        let probe = ScriptedProbe(headroom: footprint.hardBytes / 2)
        ledger.handleMemoryPressure()

        try await withTier(memory: probe, ledger: ledger) { tier, _, _ in
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(outcome.deferral, .memoryPressure(level: .warning),
                           "the kernel's level is the stronger signal, so it is the reason recorded")
        }
    }

    // MARK: [PRESSURE-SAFE LOAD] — the load in flight
    //
    // The half of the fix that is about the *window* rather than about the
    // gate. `LLM.init` is synchronous and cannot be interrupted; the reserve
    // before it evicts, and evictions run release closures (`llama_model_free`
    // is not instant); and the slot holds nothing throughout, so a warden
    // asking during any of it used to be told `.notHolding` — "nothing was
    // there to drop". It was true and it was the defect: the warden believed
    // the bytes were back, and the load filled the row it had just cleared.

    /// The distinct third answer, and the abandon signal that goes with it.
    func testASlotWithALoadInFlightRefusesTheWardenAndRecordsTheAsk() {
        let box = TranslateBrainHandleSlot()

        box.beginLoad()
        XCTAssertTrue(box.isLoading)
        XCTAssertFalse(box.isHoldingHandle,
                       "…and it still holds nothing: the handle does not exist until the load returns")
        XCTAssertEqual(box.releaseForWarden(), .refused(.cannotReleaseNow),
                       "a load is in flight — not 'nothing to drop', which is what shipped")
        XCTAssertTrue(box.consumeLoadAbandonRequest(),
                      "the ask is what stands the load down; without it the warden acks a drop "
                      + "the load re-fills microseconds later")
        XCTAssertFalse(box.consumeLoadAbandonRequest(),
                       "taken once per ask, or a warden's ask outlives the load it was about")

        box.endLoad()
        XCTAssertFalse(box.isLoading)
        XCTAssertEqual(box.releaseForWarden(), .notHolding,
                       "with the load over and nothing ever stored, an empty slot is honestly empty")
    }

    /// The fallback half of the same signal: when the release contract permits
    /// forcing, the warden's registered closure runs `drop()` directly, and a
    /// drop during a load is the position being taken just as surely as an
    /// ask is.
    func testADropDuringALoadAlsoStandsItDown() {
        let box = TranslateBrainHandleSlot()

        box.beginLoad()
        box.drop()
        XCTAssertTrue(box.consumeLoadAbandonRequest(),
                      "the force fallback is the same message: this position is no longer yours")
        box.endLoad()

        // …and a drop while nothing is loading is just the idle release, which
        // must not leave a signal behind for the next load to find.
        box.drop()
        XCTAssertFalse(box.consumeLoadAbandonRequest())
    }

    /// A load that opens while an older ask is still outstanding does not
    /// inherit it: the flag is cleared on the way in, so a warden that has
    /// stopped asking cannot stand down a load it was never asking about.
    func testAnAbandonAskDoesNotSurviveIntoTheNextLoad() {
        let box = TranslateBrainHandleSlot()

        box.beginLoad()
        XCTAssertEqual(box.releaseForWarden(), .refused(.cannotReleaseNow))
        box.endLoad()

        box.beginLoad()
        XCTAssertFalse(box.consumeLoadAbandonRequest(),
                       "the ask was about the load that is over, not the one starting now")
        box.endLoad()

        XCTAssertEqual(box.releaseForWarden(), .notHolding)
        XCTAssertFalse(box.isLoading)
    }

    /// **The window the reserve opens.** The warden is asked first and its
    /// evictions are real unloads, so seconds can pass between the permission
    /// and the allocation; a `.critical` landing anywhere in that interval is
    /// the device withdrawing a permission the warden had already granted. The
    /// load must stand down, and it must say so in its own words rather than
    /// as a load failure — nothing was wrong with the artifact.
    ///
    /// The seam is the ledger's own event stream: `reserved` is emitted the
    /// instant the permit is granted, so firing the level from its handler
    /// puts the event *between* the reserve and the construction, which is
    /// precisely where the check has to be.
    func testAPressureFiredBetweenTheReserveAndTheConstructionAbandonsTheLoad() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.onEvent = { event in
            if case .reserved = event { ledger.handleMemoryPressure(level: .critical) }
        }

        // The gated path, because that is the one with a reserve in it to be
        // interrupted — and a URL that names a real catalogue artifact, so the
        // footprint the reservation is made against is the shipped one.
        let generator = makeGenerator(on: ledger)
        let modelURL = try catalogURL(Self.modelID)

        do {
            _ = try await generator.generate(prompt: "1. \(brainText)",
                                             jsonSchema: LocalBrainTranslationTier.jsonSchema,
                                             modelURL: modelURL,
                                             timeout: 5)
            XCTFail("the load must not have been attempted: the device withdrew the permission")
        } catch let failure as BrainGenerationFailure {
            XCTAssertEqual(failure, .loadAbandoned(.memoryPressure(level: .critical)),
                           "an abandoned load is its own fact, never a load failure")
        }
    }

    /// …and before the warden was asked at all, which is the other half of the
    /// same rule: a device that is already critical never opens a reservation,
    /// so there is no permit to withdraw and no eviction to undo. The load
    /// path is reached here directly, so the only checkpoint that can catch it
    /// is the one before the reserve.
    func testAPressureAlreadyCriticalBeforeTheLoadAbandonsItBeforeTheWardenIsAsked() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        ledger.handleMemoryPressure(level: .critical)

        let generator = makeGenerator(on: ledger)
        let modelURL = try catalogURL(Self.modelID)

        do {
            _ = try await generator.generate(prompt: "1. \(brainText)",
                                             jsonSchema: LocalBrainTranslationTier.jsonSchema,
                                             modelURL: modelURL,
                                             timeout: 5)
            XCTFail("the load must not have been attempted at all")
        } catch let failure as BrainGenerationFailure {
            XCTAssertEqual(failure, .loadAbandoned(.memoryPressure(level: .critical)))
        }
        XCTAssertTrue(ledger.inFlightReservations().isEmpty,
                      "checkpoint 1 runs before the reserve: no permit was ever taken")
    }

    /// The same window, ended the other way. A warden that wants *this*
    /// position back while the load is filling it must be able to stand the
    /// load down — and it reaches the slot through the one call the protocol
    /// has, `releaseForWarden()`. That call is made here directly rather than
    /// through an eviction because a slot with a load in flight holds nothing
    /// and is not resident: no sweep will choose it, which is exactly why the
    /// old `.notHolding` answer went unnoticed.
    func testAWardenAskBetweenTheReserveAndTheConstructionAbandonsTheLoad() async throws {
        let clock = PressureClock()
        let ledger = makePressureLedger(clock)
        let sink = EventSink()

        let generator = makeGenerator(on: ledger)
        ledger.onEvent = { event in
            sink.events.append(event)
            // The instant the permit is granted — and the slot registered,
            // which `loadHandle` does before it asks — the warden asks for the
            // position back.
            if case .reserved = event { _ = generator.slot.releaseForWarden() }
        }
        let modelURL = try catalogURL(Self.modelID)

        do {
            _ = try await generator.generate(prompt: "1. \(brainText)",
                                             jsonSchema: LocalBrainTranslationTier.jsonSchema,
                                             modelURL: modelURL,
                                             timeout: 5)
            XCTFail("the position was taken: the load must stand down, not fill it anyway")
        } catch let failure as BrainGenerationFailure {
            XCTAssertEqual(failure, .loadAbandoned(.releaseRequestedDuringLoad),
                           "the ask is the reason, not the pressure the ask is not")
        }

        // The permit went back with the reason the ask implies. Without the
        // slot's in-flight answer the warden would have been told `.notHolding`
        // and the load would have filled the row it had just cleared.
        XCTAssertEqual(sink.abandonReasons(for: .translateBrain), [.preempted])
    }

    /// `.translateBrain` does not admit itself over budget alone.
    ///
    /// Before Step 2 the tier reserved as a PEER on `.brain`, so an artifact
    /// that did not fit beside the voice brain was refused and the strings
    /// went to the cloud. Moving it to its own position must not quietly
    /// turn that refusal into a 3.4 GB admission on a 6 GB phone — which is
    /// what the `soloOverBudget` escape hatch would do if the position
    /// admitted it.
    func testTheTierPositionCannotSoloOverBudget() {
        XCTAssertFalse(ModelSlot.translateBrain.admitsSoloOverBudget)
        XCTAssertFalse(ModelSlot.speechToText.admitsSoloOverBudget)
        // The two that may: the app cannot run without a default brain.
        XCTAssertTrue(ModelSlot.brain.admitsSoloOverBudget)
        XCTAssertTrue(ModelSlot.intentBrain.admitsSoloOverBudget)

        let live = ModelLifecycleInventory.footprint(for: .translateBrain,
                                                     modelID: ModelCatalog.intentQwen4BSlotCanon).liveBytes
        let manager = ModelLifecycleManager(probe: ScriptedProbe(),
                                            budgetOverrideBytes: live / 2)
        let owner = FakeOwner()
        manager.register(slot: .translateBrain, modelID: ModelCatalog.intentQwen4BSlotCanon,
                         owner: owner, priority: .foreground) { [weak owner] in _ = owner }

        guard case .failure(let denial) = manager.reserve(ModelLoadRequest(
            slot: .translateBrain,
            modelID: ModelCatalog.intentQwen4BSlotCanon,
            owner: owner,
            purpose: .liveTranslate,
            replacesSlotContents: true)) else {
            return XCTFail("a 4B that does not fit the device is not made to fit "
                           + "by calling it the camera's brain")
        }
        XCTAssertEqual(denial.token, "over_budget_alone")
    }

    // MARK: - The warden's two moments (owner directive, 2026-09-19)
    //
    // "Keep the user in the loop so they don't wonder about the silences": one
    // sentence for a model that is loading, one for a model the voice stack
    // has taken. Each moment is a notice pushed at the surface *and* an event
    // on the feature's own vocabulary, and the two are asserted together so a
    // notice cannot reach an elder without a line in the capture.

    /// Collects the notices a tier pushes, in order. A class rather than a
    /// captured `var`, because the sink is `@Sendable` and the test reads it
    /// after the pushes.
    private final class NoticeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [LocalBrainWardenNotice] = []

        func record(_ notice: LocalBrainWardenNotice) {
            lock.lock()
            storage.append(notice)
            lock.unlock()
        }

        var notices: [LocalBrainWardenNotice] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// The tier over a **real** generator, for the one path that needs the
    /// warden's box to be the real one: the preemption notice. Nothing here
    /// generates — no model is ever loaded, and the handle is a string.
    private func withRealGeneratorTier<T>(
        ledger: ModelLifecycleManager,
        notices: NoticeBox,
        run: (LocalBrainTranslationTier, LlamaBrainTextGenerator, LiveTranslateSanitisingBus) async throws -> T
    ) async rethrows -> T {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = LiveTranslateSanitisingBus()
        let store = try! makeStore(installed: true, root: root)
        let generator = LlamaBrainTextGenerator(config: config, lifecycle: ledger)
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: LiveTranslateEvents(bus: bus, config: config),
                                             generator: generator,
                                             targetLanguage: .nepali,
                                             memory: ScriptedProbe(),
                                             ledger: ledger,
                                             onWardenNotice: { notices.record($0) })
        return try await run(tier, generator, bus)
    }

    /// The "hold on a sec" moment: a batch that has to pay a load says so —
    /// on the surface and on the event vocabulary, with the count of strings
    /// riding on it.
    func testALoadThatIsDueIsAnnouncedWithTheBatchItIsHoldingUp() async throws {
        let notices = NoticeBox()
        try await withTier(onWardenNotice: { notices.record($0) }) { tier, generator, bus in
            generator.holdingHandle = false
            generator.output = answer([brainAnswer, secondBrainAnswer])

            let outcome = await tier.translate([brainText, secondBrainText])

            XCTAssertEqual(outcome.translations.count, 2)
            XCTAssertEqual(notices.notices, [.loadingModel])
            let announced = bus.events(named: "brain_translation_load_announced").first
            XCTAssertEqual(announced?.outcome, "pending")
            XCTAssertEqual(announced?.metadata["count"], "2",
                           "the count is the batch the wait is holding up")
        }
    }

    /// …and a batch whose handle is already resident announces nothing: the
    /// elder is not waiting for a load that is not happening.
    func testAResidentHandleIsNotAnnouncedAsAWait() async throws {
        let notices = NoticeBox()
        try await withTier(onWardenNotice: { notices.record($0) }) { tier, generator, bus in
            generator.holdingHandle = true
            generator.output = answer([brainAnswer])

            _ = await tier.translate([brainText])

            XCTAssertTrue(notices.notices.isEmpty)
            XCTAssertTrue(bus.events(named: "brain_translation_load_announced").isEmpty)
        }
    }

    /// The late-attach half of the same seam (`setWardenNoticeSink`). The
    /// session model does not need it — it attaches at construction, through
    /// `LiveTranslationPipeline` — but a surface built *after* the session is
    /// must still hear every notice from the moment it attaches, and this is
    /// the path that promises it. An attached sink is the init sink: the next
    /// load announces to it.
    func testASinkAttachedAfterConstructionHearsTheNextNotice() async throws {
        let notices = NoticeBox()
        try await withTier { tier, generator, _ in
            await tier.setWardenNoticeSink { notices.record($0) }
            generator.holdingHandle = false
            generator.output = answer([brainAnswer])

            _ = await tier.translate([brainText])

            XCTAssertEqual(notices.notices, [.loadingModel])
        }
    }

    /// And detaching is what a surface that has gone away gets: no sink, no
    /// push. The moment still happened — the capture keeps it — but nobody is
    /// told a sentence for a screen that is no longer there.
    func testADetachedSinkHearsNothing() async throws {
        let notices = NoticeBox()
        try await withTier(onWardenNotice: { notices.record($0) }) { tier, generator, _ in
            await tier.setWardenNoticeSink(nil)
            generator.holdingHandle = false
            generator.output = answer([brainAnswer])

            _ = await tier.translate([brainText])

            XCTAssertTrue(notices.notices.isEmpty,
                          "a detached surface is not owed a notice it cannot draw")
        }
    }

    /// The hand-off: the warden takes the handle the tier did not offer, and
    /// the sentence the elder is owed goes out. Nothing was decoding, so the
    /// count is an honest zero.
    func testAnOffloadByTheWardenIsAnnouncedWithWhatItCost() async throws {
        let notices = NoticeBox()
        let ledger = ModelLifecycleManager(
            probe: ScriptedProbe(),
            budgetOverrideBytes: ModelLifecycleBudget.standardModelsBudgetBytes)

        try await withRealGeneratorTier(ledger: ledger, notices: notices) { _, generator, bus in
            // The wiring under test is the tier's own: the generator was
            // built by `withRealGeneratorTier`, the tier's init installed its
            // handler on the box, and the notice has to come back through
            // both the event vocabulary and the surface sink.
            generator.slot.store("a handle", url: URL(fileURLWithPath: "/tmp/not-a-real-model.gguf"))

            // What happens on the warden's thread when a voice turn needs the
            // bytes: the ask, answered by handing the handle over.
            XCTAssertEqual(generator.slot.releaseForWarden(), .released)

            // The tier hears it on a `Task` hop, so the assertions wait for it
            // rather than assuming a scheduling order.
            for _ in 0..<200 where bus.events(named: "brain_translation_preempted").isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let preempted = bus.events(named: "brain_translation_preempted").first
            XCTAssertEqual(preempted?.outcome, "preempted")
            XCTAssertEqual(preempted?.metadata["count"], "0",
                           "an idle handle costs no answer")
            XCTAssertEqual(preempted?.metadata.count, 1,
                           "counts only — no model id, no path, no sentence")
            XCTAssertEqual(notices.notices, [.offloadedForVoiceTurn])
            XCTAssertFalse(generator.slot.isHoldingHandle)
        }
    }

    /// The generator's handler lands on the box the warden asks — the one
    /// line the whole notice path hangs on.
    func testTheWardenHandlerIsInstalledOnTheBoxTheWardenAsks() {
        let notices = NoticeBox()
        let generator = LlamaBrainTextGenerator(config: config)
        generator.setWardenOffloadHandler { notices.record(.offloadedForVoiceTurn) }
        generator.slot.store("a handle", url: URL(fileURLWithPath: "/tmp/not-a-real-model.gguf"))

        XCTAssertEqual(generator.slot.releaseForWarden(), .released)
        XCTAssertEqual(notices.notices, [.offloadedForVoiceTurn])
    }

    /// The forced half of the ask — a refusal overruled, or a budget eviction
    /// of this position — says the same sentence, and says it after the
    /// handle is gone.
    func testTheForcedDropSaysTheSameSentence() {
        let notices = NoticeBox()
        let box = TranslateBrainHandleSlot()
        box.setOffloadHandler { notices.record(.offloadedForVoiceTurn) }
        box.store("a handle", url: URL(fileURLWithPath: "/tmp/not-a-real-model.gguf"))
        box.beginDecode("a handle")

        XCTAssertEqual(box.releaseForWarden(), .refused(.inUse))
        XCTAssertTrue(notices.notices.isEmpty,
                      "a refusal that kept the handle is not a hand-off")

        box.dropForWarden()
        XCTAssertFalse(box.isHoldingHandle)
        XCTAssertEqual(notices.notices, [.offloadedForVoiceTurn])
    }

    /// Every notice has a sentence, in both languages, keyed off the notice
    /// itself — this is the seam a surface renders, so a notice the catalog
    /// cannot answer is a silence with extra steps.
    func testEveryNoticeKeyIsACatalogEntry() {
        let notices = LocalBrainWardenNotice.allCases
        XCTAssertEqual(Set(notices.map(\.copyKey)).count, notices.count,
                       "two notices sharing one sentence cannot be told apart")
        for notice in notices {
            XCTAssertTrue(notice.copyKey.hasPrefix("livetranslate."),
                          "\(notice.rawValue) must stay on the feature's copy surface")
        }
    }
}
