import XCTest
@testable import ElderlyAssistant

/// [CNR T-184] The v17 chat variant's catalog entry and the gated,
/// reversible promotion — FR-CNR-022 (versioned, reversible, gate-backed,
/// tier-selected swap) and NFR-CNR-003 (one brain resident, tier admission
/// memory-gated).
///
/// The shipped state under test throughout is the HONEST one: the run
/// `cnr-v17-20261015-0209` produced the artifact and the manifest, but its
/// full-gate report does not exist (the chat judge is blocked on a funded
/// API key; the latency gate is unmeasured until the Anzaan session), so
/// the promotion record is BLOCKED and the default does not serve v17. A
/// green record is constructed here only as the promotion HYPOTHETICAL —
/// the test evidence that the gate, not the size arithmetic, decides.
final class ModelCatalogChatVariantTests: XCTestCase {

    // MARK: - Fixtures

    private let compactPhone: UInt64 = 4_000_000_000     // < 5 GB
    private let standardPhone: UInt64 = 6_000_000_000    // 5–7 GB, the reference tier

    /// A probe that answers one RAM number — the same stand-in
    /// `InterpreterAvailabilityTests` uses. The resolution reads only
    /// `physicalMemoryBytes` (the class).
    private struct FixedRAMProbe: MemoryProbing {
        let physicalMemoryBytes: UInt64
        var availableProcessMemoryBytes: UInt64 { 3_400_000_000 }
    }

    private func ledger(ram: UInt64) -> ModelLifecycleManager {
        ModelLifecycleManager(probe: FixedRAMProbe(physicalMemoryBytes: ram))
    }

    /// The promotion HYPOTHETICAL: the shipped record with a green
    /// full-gate report filled in. Not shipped state — the gate is what
    /// this fixture exists to exercise.
    private static func greenRecord() -> ModelCatalog.ChatVariantPromotionRecord {
        ModelCatalog.ChatVariantPromotionRecord(
            modelID: ModelCatalog.intentQwenS43ChatV17,
            artifactSHA256: "e05cc8a266198336f508cef2f6d2a8887b3db1eee3f4a4159cdeb2ab3df59d71",
            artifactSizeBytes: 1_107_408_736,
            provenanceManifestSHA256: "fb7f7779c801706caddc74ef499198eb14c1ddc05dd89da1a7766cd476adab55",
            gateReportPath: "specs/runs/cnr-v17-20261015-0209/gate-report.json",
            gateReportSHA256: String(repeating: "a", count: 64),
            gates: [
                .init(name: "chat_judge", passed: true),
                .init(name: "latency", passed: true)
            ])
    }

    // MARK: - The entry (AC: the new entry exists beside the current one)

    func testTheChatVariantEntryPinsTheRealArtifactFacts() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentQwenS43ChatV17))
        XCTAssertEqual(entry.kind, .llamaBase)
        XCTAssertEqual(entry.filename, "intent-ne-qwen-s43-chat-v17-q4_k_m.gguf")
        // T-183's run `cnr-v17-20261015-0209`: the digest and size are the
        // produced artifact's real identity — quoted by the gate report and
        // the manifest this unit's record carries.
        XCTAssertEqual(entry.sizeBytes, 1_107_408_736)
        XCTAssertEqual(entry.sha256,
                       "e05cc8a266198336f508cef2f6d2a8887b3db1eee3f4a4159cdeb2ab3df59d71")
        XCTAssertEqual(entry.sha256.count, 64)
        XCTAssertNotEqual(entry.sha256, ModelCatalogEntry.pendingSHA256,
                          "the digest IS pinned — only delivery is pending")
        XCTAssertEqual(entry.minDeviceRAMBytes, 3_000_000_000)
        XCTAssertEqual(entry.languages, ["ne"])
        XCTAssertNil(entry.dependsOn)
        // Publication pending: the release asset does not exist (the run is
        // not promoted), so the URL is the RFC 2606 documentation
        // placeholder — a tap fails honestly instead of installing a wrong
        // file. The NAME quotes the gate state the same way.
        XCTAssertEqual(entry.downloadURL.host, "invalid.invalid")
        XCTAssertTrue(entry.displayName.contains("gates pending"),
                      "the row must quote the run's evidence posture: \(entry.displayName)")
    }

    func testTheEntryIsOfferedBesideThePreviousEntry() throws {
        let offered = ModelCatalog.availableBrainEntries.map(\.id)
        let position = try XCTUnwrap(offered.firstIndex(of: ModelCatalog.intentQwenS43ChatV17))
        let previous = try XCTUnwrap(offered.firstIndex(of: ModelCatalog.intentQwenS43))
        // The rollback target is present and selectable — versioned and
        // reversible is the requirement (FR-CNR-022).
        XCTAssertNotNil(ModelCatalog.entry(for: ModelCatalog.intentQwenS43))
        // The sibling pair reads together, after the list leader.
        XCTAssertEqual(position, 1)
        XCTAssertEqual(previous, position + 1)
        XCTAssertEqual(offered.first, ModelCatalog.intentQwen4BSlotCanon)
    }

    func testTheChatVariantSpeaksTheSameMeasuredChatSchemeAsItsBaseLineage() {
        // Served through the EXISTING framing seam — no chain, router or
        // prompt change is part of this unit (FR-CNR-022's scenario
        // "Selecting the entry serves the new model with no wiring
        // change"): the v17 row is the inherited `.qwen3` determination of
        // the seed-43 measurement, same as its base.
        XCTAssertEqual(LlamaCommandInterpreter.chatFormat(for: ModelCatalog.intentQwenS43ChatV17).kind,
                       LlamaCommandInterpreter.chatFormat(for: ModelCatalog.intentQwenS43).kind)
        XCTAssertNotNil(LlamaCommandInterpreter.measuredFraming(for: ModelCatalog.intentQwenS43ChatV17))
    }

    func testExplicitSelectionServesTheChatVariantWhileItIsUnpromoted() {
        // Rule 1 of `resolveBrainModelID`: an explicit pick wins
        // unconditionally — the household's own choice, which is what
        // "selectable" means for a gated entry (it is never SILENTLY
        // promoted; picking it by hand is not silence). Served through the
        // existing coordinator seam, no wiring change.
        XCTAssertEqual(
            AppCoordinator.resolveBrainModelID(
                storedPreference: ModelCatalog.intentQwenS43ChatV17,
                language: "ne",
                ledger: ledger(ram: standardPhone)),
            ModelCatalog.intentQwenS43ChatV17)
    }

    // MARK: - Promotion blocked (shipped state) and reported

    func testTheShippedPromotionRecordIsBlockedAndSaysWhy() {
        let record = ModelCatalog.chatVariantPromotionRecord
        // The binding pieces that ARE attached...
        XCTAssertEqual(record.modelID, ModelCatalog.intentQwenS43ChatV17)
        XCTAssertEqual(record.artifactSHA256,
                       "e05cc8a266198336f508cef2f6d2a8887b3db1eee3f4a4159cdeb2ab3df59d71")
        XCTAssertEqual(record.artifactSizeBytes, 1_107_408_736)
        XCTAssertEqual(record.provenanceManifestSHA256,
                       "fb7f7779c801706caddc74ef499198eb14c1ddc05dd89da1a7766cd476adab55")
        // ...and the one that is NOT: the run produced no full-gate report
        // (chat judge blocked on a funded API key; latency unmeasured
        // pending the Anzaan session), so promotion is blocked by the
        // missing evidence — NEVER by a hardcoded green.
        XCTAssertNil(record.gateReportPath)
        XCTAssertNil(record.gateReportSHA256)
        XCTAssertTrue(record.gates.isEmpty)
        XCTAssertEqual(ModelCatalog.promotionVerdict(for: record),
                       .blocked(.gateReportMissing))
        XCTAssertNil(ModelCatalog.promotedChatVariantEntry(),
                     "the shipped record must not promote anything")
    }

    func testABlockedRecordKeepsTheDefaultOnThePreviousAnswer() {
        let shipped = ModelCatalog.chatVariantPromotionRecord
        let neDefault = ModelCatalog.defaultEntry(kind: .llamaBase,
                                                  language: "ne",
                                                  promotionRecord: shipped)
        XCTAssertEqual(neDefault?.id, ModelCatalog.intentQwen4BSlotCanon,
                       "the catalogue's language answer does not move while "
                       + "the promotion evidence is incomplete")
        XCTAssertNotEqual(neDefault?.id, ModelCatalog.intentQwenS43ChatV17)
        // Byte-identical to the promotion-free question: the blocked record
        // adds NOTHING to the resolution. (Compared by id — a catalog
        // entry is identified by its id, `ModelCatalogEntry` carries no
        // Equatable conformance, the same convention `AutomaticPick ==`
        // uses.)
        XCTAssertEqual(neDefault?.id,
                       ModelCatalog.defaultEntry(kind: .llamaBase,
                                                 language: "ne",
                                                 promotionRecord: nil)?.id)
    }

    func testABlockedChatVariantIsNeverServedByTheAutomaticLadder() throws {
        let shipped = ModelCatalog.chatVariantPromotionRecord
        XCTAssertFalse(ModelCatalog.isAutomaticPickEligible(
            try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentQwenS43ChatV17)),
            record: shipped))
        XCTAssertTrue(ModelCatalog.isAutomaticPickEligible(
            try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentQwenS43)),
            record: shipped),
                      "the record gates only the artifact it names")
        // The reference tier's automatic answer stays the shipped one, on
        // the seam the app actually loads through.
        let resolved = AppCoordinator.resolveBrainModelID(
            storedPreference: nil, language: "ne",
            ledger: ledger(ram: standardPhone))
        XCTAssertNotEqual(resolved, ModelCatalog.intentQwenS43ChatV17,
                          "an unpromoted chat variant is never the automatic pick")
    }

    func testTheVariantsExtraBytesNeverWinTheLargestFittingStepWhileBlocked() throws {
        // THE regression this gate protects: v17 is 160 bytes LARGER than
        // the seed-43 file it retrains (1,107,408,736 vs 1,107,408,576), so
        // without the eligibility filter it would win step 2's
        // "largest fitting" comparison on every class the previous entry
        // serves — a silent promotion by size arithmetic. With a heavier
        // warm STT the 1.28 GB stock brain drops out and the pick must stay
        // on the previous entry, not slide onto its unpromoted retrain
        // (this is the same fact `LanguageModelResolverTests
        // .testTheWarmSTTFootprintMovesThePick` pins through the default
        // record).
        let pick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase,
            language: "ne",
            policy: .standard,
            physicalMemoryBytes: standardPhone,
            warmSTTLiveBytes: 1_300_000_000,
            promotionRecord: ModelCatalog.chatVariantPromotionRecord))
        XCTAssertEqual(pick.entry.id, ModelCatalog.intentQwenS43)
        XCTAssertGreaterThan(
            try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentQwenS43ChatV17)).sizeBytes,
            try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentQwenS43)).sizeBytes,
            "the fixture fact behind the hazard: v17 is the heavier file")
    }

    // MARK: - Promotion gated (green hypothetical) and recorded

    func testGreenEvidencePromotesTheDefaultToTheVariant() throws {
        let green = Self.greenRecord()
        guard case .promoted(let entry) =
                ModelCatalog.promotionVerdict(for: green) else {
            XCTFail("a complete green record must promote")
            return
        }
        XCTAssertEqual(entry.id, ModelCatalog.intentQwenS43ChatV17)
        // The promotion IS the default-resolution change: step -1 of
        // `defaultEntry` serves the record's entry for the language it was
        // promoted for...
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase,
                                                 language: "ne",
                                                 promotionRecord: green)?.id,
                       ModelCatalog.intentQwenS43ChatV17)
        // ...and touches nothing else: the en default, and every other
        // kind, are answered as before.
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .llamaBase,
                                                 language: "en",
                                                 promotionRecord: green)?.id,
                       ModelCatalog.qwen3_1_7BInstruct,
                       "the variant is ne-tagged — an en request is not its business")
        XCTAssertEqual(ModelCatalog.defaultEntry(kind: .whisperBase,
                                                 language: "ne",
                                                 promotionRecord: green)?.id,
                       ModelCatalog.whisperKitMediumV6,
                       "the record promotes a brain, not a kind")
    }

    func testPromotionServesTheVariantOnTheTierThatHoldsIt() throws {
        let pick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase,
            language: "ne",
            policy: .standard,
            physicalMemoryBytes: standardPhone,
            promotionRecord: Self.greenRecord()))
        XCTAssertEqual(pick.entry.id, ModelCatalog.intentQwenS43ChatV17,
                       "a promoted variant is step 1's default on the "
                       + "reference tier, exactly as the map's picks are")
        XCTAssertTrue(pick.availability.isAvailable)
        XCTAssertNil(pick.declinedDefaultReason,
                     "nothing was declined — this IS the default now")
        XCTAssertEqual(pick.deviceClass, .standard)
    }

    func testAMissingManifestBlocksAPromotion() {
        let green = Self.greenRecord()
        let noManifest = ModelCatalog.ChatVariantPromotionRecord(
            modelID: green.modelID,
            artifactSHA256: green.artifactSHA256,
            artifactSizeBytes: green.artifactSizeBytes,
            provenanceManifestSHA256: nil,
            gateReportPath: green.gateReportPath,
            gateReportSHA256: green.gateReportSHA256,
            gates: green.gates)
        XCTAssertEqual(ModelCatalog.promotionVerdict(for: noManifest),
                       .blocked(.manifestMissing),
                       "all gates green is not enough — the manifest hash is "
                       + "a binding piece of the promotion")
        XCTAssertNil(ModelCatalog.promotedChatVariantEntry(record: noManifest))
        XCTAssertNotEqual(
            ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne",
                                      promotionRecord: noManifest)?.id,
            ModelCatalog.intentQwenS43ChatV17)
    }

    func testARedGateBlocksAPromotionAndIsNamed() {
        let green = Self.greenRecord()
        let red = ModelCatalog.ChatVariantPromotionRecord(
            modelID: green.modelID,
            artifactSHA256: green.artifactSHA256,
            artifactSizeBytes: green.artifactSizeBytes,
            provenanceManifestSHA256: green.provenanceManifestSHA256,
            gateReportPath: green.gateReportPath,
            gateReportSHA256: green.gateReportSHA256,
            gates: [
                .init(name: "chat_judge", passed: true),
                .init(name: "latency", passed: false)
            ])
        XCTAssertEqual(ModelCatalog.promotionVerdict(for: red),
                       .blocked(.gateFailed("latency")),
                       "the FIRST failing gate in recorded order is named")
        XCTAssertNil(ModelCatalog.promotedChatVariantEntry(record: red))
        XCTAssertNotEqual(
            ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne",
                                      promotionRecord: red)?.id,
            ModelCatalog.intentQwenS43ChatV17,
            "a red gate must not move the default")
    }

    func testAnEmptyGateListIsNotAGreenReport() {
        let green = Self.greenRecord()
        let vacuous = ModelCatalog.ChatVariantPromotionRecord(
            modelID: green.modelID,
            artifactSHA256: green.artifactSHA256,
            artifactSizeBytes: green.artifactSizeBytes,
            provenanceManifestSHA256: green.provenanceManifestSHA256,
            gateReportPath: green.gateReportPath,
            gateReportSHA256: green.gateReportSHA256,
            gates: [])
        XCTAssertEqual(ModelCatalog.promotionVerdict(for: vacuous),
                       .blocked(.noGatesRecorded),
                       "zero recorded verdicts is not 'all gates passed'")
    }

    // MARK: - Hash/evidence mismatch rejected at entry validation

    func testAnArtifactMismatchIsRejectedAndTheEntryIsNotServed() {
        let green = Self.greenRecord()
        // The failure path FR-CNR-022 names: a GGUF whose hash differs from
        // the one the record names. This is the shape a corrupted or
        // swapped artifact produces, and it is checked FIRST — identity is
        // the root of trust.
        let wrongHash = ModelCatalog.ChatVariantPromotionRecord(
            modelID: green.modelID,
            artifactSHA256: String(repeating: "f", count: 64),
            artifactSizeBytes: green.artifactSizeBytes,
            provenanceManifestSHA256: green.provenanceManifestSHA256,
            gateReportPath: green.gateReportPath,
            gateReportSHA256: green.gateReportSHA256,
            gates: green.gates)
        XCTAssertEqual(ModelCatalog.promotionVerdict(for: wrongHash),
                       .blocked(.artifactMismatch))
        XCTAssertNil(ModelCatalog.promotedChatVariantEntry(record: wrongHash),
                     "a mismatched record must not serve the entry")
        XCTAssertNotEqual(
            ModelCatalog.defaultEntry(kind: .llamaBase, language: "ne",
                                      promotionRecord: wrongHash)?.id,
            ModelCatalog.intentQwenS43ChatV17)
        // Same for a size disagreement — a truncated file is a different
        // artifact, whatever its digest bytes claim.
        let wrongSize = ModelCatalog.ChatVariantPromotionRecord(
            modelID: green.modelID,
            artifactSHA256: green.artifactSHA256,
            artifactSizeBytes: green.artifactSizeBytes - 1,
            provenanceManifestSHA256: green.provenanceManifestSHA256,
            gateReportPath: green.gateReportPath,
            gateReportSHA256: green.gateReportSHA256,
            gates: green.gates)
        XCTAssertEqual(ModelCatalog.promotionVerdict(for: wrongSize),
                       .blocked(.artifactMismatch))
        // And a record naming an id the catalog does not ship promotes
        // nothing — there is no entry to serve.
        let unknown = ModelCatalog.ChatVariantPromotionRecord(
            modelID: ModelID("no-such-chat-variant"),
            artifactSHA256: green.artifactSHA256,
            artifactSizeBytes: green.artifactSizeBytes,
            provenanceManifestSHA256: green.provenanceManifestSHA256,
            gateReportPath: green.gateReportPath,
            gateReportSHA256: green.gateReportSHA256,
            gates: green.gates)
        XCTAssertEqual(ModelCatalog.promotionVerdict(for: unknown),
                       .blocked(.artifactMismatch))
    }

    func testAMapPickPointingAtABlockedVariantIsRefused() {
        // Belt and braces on the reference-data path: even a hand-edited
        // `languageDefaultPicks` that names the v17 entry does not promote
        // it while the record is blocked — promotion without the gate
        // evidence is impossible on this path too. (The shipped map still
        // names the 4B; the assertion here is about the enforcement, which
        // the catalog owns.)
        XCTAssertEqual(ModelCatalog.explicitDefaultEntry(
            kind: .llamaBase, language: "ne",
            promotionRecord: ModelCatalog.chatVariantPromotionRecord)?.id,
                       ModelCatalog.intentQwen4BSlotCanon)
        // With no record in play the map answers as written — nil record is
        // the promotion-free question, which the rollback test relies on.
        XCTAssertEqual(ModelCatalog.explicitDefaultEntry(
            kind: .llamaBase, language: "ne", promotionRecord: nil)?.id,
                       ModelCatalog.intentQwen4BSlotCanon)
    }

    // MARK: - Rollback is a catalog operation (no code change, no gate re-run)

    func testRollbackRevertsTheRecordAndThePreviousEntryServesAgain() throws {
        // PROMOTED (hypothetical): the resolution serves the variant...
        let promotedPick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase, language: "ne",
            policy: .standard, physicalMemoryBytes: standardPhone,
            promotionRecord: Self.greenRecord()))
        XCTAssertEqual(promotedPick.entry.id, ModelCatalog.intentQwenS43ChatV17)

        // ROLLED BACK: the record reverts (the shipped blocked value IS the
        // pre-promotion state) and the SAME resolution code — nothing else
        // changed, that is the whole point — serves the previous model
        // again, byte-for-byte the answer this build gives today.
        let revertedPick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase, language: "ne",
            policy: .standard, physicalMemoryBytes: standardPhone,
            promotionRecord: ModelCatalog.chatVariantPromotionRecord))
        XCTAssertNotEqual(revertedPick.entry.id, ModelCatalog.intentQwenS43ChatV17)
        XCTAssertEqual(promotedPick.entry.id == ModelCatalog.intentQwenS43ChatV17,
                       revertedPick.entry.id != ModelCatalog.intentQwenS43ChatV17,
                       "the record's value is the only difference between "
                       + "the two states")

        // No gate re-run: the rollback target's own evidence is the shipped
        // entry, unchanged in both states and independent of the record —
        // the previous entry already carries its own green gates.
        let previous = try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentQwenS43))
        XCTAssertEqual(previous.sha256,
                       "c2135f786ace9c1020a27bb115600d90f9e3c4d788c995730b379b67e1ae74ef")
        XCTAssertEqual(previous.sizeBytes, 1_107_408_576)
        XCTAssertTrue(ModelCatalog.availableBrainEntries.contains {
            $0.id == ModelCatalog.intentQwenS43
        }, "the rollback target stays offered through the whole exercise")
    }

    // MARK: - Exactly one model resident (NFR-CNR-003)

    func testTheVariantAndItsSiblingShareTheSingleBrainHandle() {
        // The variant swaps INTO the one brain slot — never beside it. The
        // real swap path is the interpreter's single handle; behaviorally:
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-variant-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let bus = MockObservabilityBus()
        let store = try! ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)

        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.switchBaseModel(to: ModelCatalog.intentQwenS43ChatV17)
        XCTAssertEqual(interp.baseModelID, ModelCatalog.intentQwenS43ChatV17)
        XCTAssertNil(interp.activeLoRAID)
        // Swapping back is the rollback at the handle level: one id, one
        // slot — the previous handle was dropped by the swap.
        interp.switchBaseModel(to: ModelCatalog.intentQwenS43)
        XCTAssertEqual(interp.baseModelID, ModelCatalog.intentQwenS43)

        // Both entries are the SAME kind, so the resolver and the
        // interpreter can only ever run one of them at a time: the slot is
        // the ledger's `.brain`, and the resolution returns exactly one id.
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.intentQwenS43ChatV17)?.kind,
                       ModelCatalog.entry(for: ModelCatalog.intentQwenS43)?.kind)
        XCTAssertEqual(ModelCatalog.entry(for: ModelCatalog.intentQwenS43ChatV17)?.kind,
                       .llamaBase)
    }

    func testTheInterpreterKeepsExactlyOneHandleSlot() throws {
        // The structural half of single residency: the interpreter owns ONE
        // `llmInstance` handle (not one per model), and `switchBaseModel`
        // nils it plus settles the ledger's brain account — a swap never
        // allocates a second instance.
        let source = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory(file: #filePath)
                .appendingPathComponent("ElderlyAssistant/Services/Voice/"
                                        + "LlamaCommandInterpreter.swift"))
        let declarations = source.components(separatedBy: "var llmInstance").count - 1
        XCTAssertEqual(declarations, 1,
                       "the interpreter must hold exactly ONE cached LLM "
                       + "handle — a second slot would be a second resident")
        let swapStart = try XCTUnwrap(source.range(of: "func switchBaseModel(to id: ModelID)"))
        let swapBody = String(source[swapStart.lowerBound...].prefix(600))
        XCTAssertTrue(swapBody.contains("llmInstance = nil"),
                      "a swap must drop the loaded handle so the next "
                      + "inference loads exactly one model")
        XCTAssertTrue(swapBody.contains("lifecycle.didUnload(.brain"),
                      "the swap settles the ledger's brain account — the "
                      + "old handle is not left budgeted as resident")
    }

    // MARK: - The tier decision is recorded with the tier named

    func testATierThatCannotHoldTheVariantKeepsTheAdmissibleModelAndNamesTheTier() throws {
        // Green record, compact class: the promoted variant is step 1's
        // default but the class cannot hold it beside the warm STT — the
        // resolver keeps an admissible model (the previous entry) rather
        // than risking a jetsam kill, and the record of the decision names
        // the tier (FR-CNR-022 failure path; NFR-CNR-003's memory-gated
        // admission).
        let pick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase, language: "ne",
            policy: .compact, physicalMemoryBytes: compactPhone,
            promotionRecord: Self.greenRecord()))
        XCTAssertEqual(pick.entry.id, ModelCatalog.intentQwenS43,
                       "the compact class keeps the previous entry — the "
                       + "tier's admissible model")
        XCTAssertNotEqual(pick.entry.id, ModelCatalog.intentQwenS43ChatV17,
                          "a tier that cannot hold it never gets it")
        XCTAssertEqual(pick.deviceClass, .compact,
                       "the decision carries the tier it was made for")
        XCTAssertEqual(pick.recordedReason, .requiresEvictingWarmSTT,
                       "and the consequence it paid is stated, not hidden")
        // The same naming holds on the shipped (blocked) record — the tier
        // in the record is policy truth, not promotion state.
        let shippedPick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase, language: "ne",
            policy: .compact, physicalMemoryBytes: compactPhone,
            promotionRecord: ModelCatalog.chatVariantPromotionRecord))
        XCTAssertEqual(shippedPick.deviceClass, .compact)
    }

    // MARK: - The block is reported (FR-CNR-022: "the violation is reported")

    func testTheShippedBlockIsReportedWithAClosedVocabularyToken() {
        guard case .blocked(let block) =
                ModelCatalog.promotionVerdict(for: ModelCatalog.chatVariantPromotionRecord) else {
            XCTFail("the shipped record is blocked")
            return
        }
        let event = AppCoordinator.chatVariantPromotionEvent(block: block)
        XCTAssertEqual(event.component, "model_lifecycle")
        XCTAssertEqual(event.eventType, "chat_variant_promotion")
        XCTAssertEqual(event.outcome, "info")
        XCTAssertEqual(event.metadata["slot"], "brain")
        XCTAssertEqual(event.metadata["reason"], "gate_report_missing",
                       "the shipped state's block, as the launch record "
                       + "states it")
        // Every key on the payload is allow-listed — the record must never
        // become a hole for a path, a gate name or a digest.
        for key in event.metadata.keys {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                          "metadata key \"\(key)\" is not in "
                          + "LogSanitiser.allowedKeys")
        }
        // The closed token vocabulary, one code per block — asserted whole
        // so adding a case without its token fails here.
        XCTAssertEqual(ModelCatalog.ChatVariantPromotionBlock.artifactMismatch.reasonCode,
                       "artifact_mismatch")
        XCTAssertEqual(ModelCatalog.ChatVariantPromotionBlock.gateReportMissing.reasonCode,
                       "gate_report_missing")
        XCTAssertEqual(ModelCatalog.ChatVariantPromotionBlock.manifestMissing.reasonCode,
                       "manifest_missing")
        XCTAssertEqual(ModelCatalog.ChatVariantPromotionBlock.noGatesRecorded.reasonCode,
                       "no_gates_recorded")
        XCTAssertEqual(ModelCatalog.ChatVariantPromotionBlock.gateFailed("latency").reasonCode,
                       "gate_failed",
                       "the gate NAME stays on the verdict, not in the log")
    }
}
