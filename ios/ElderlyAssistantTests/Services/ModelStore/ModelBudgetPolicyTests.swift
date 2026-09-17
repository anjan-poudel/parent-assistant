import XCTest
@testable import ElderlyAssistant

/// [MODEL-WARDEN] Step 3 — the per-class policy: what a device class may
/// **choose**, as distinct from what the ledger may hold.
///
/// The case the whole gate exists for is here and it is one line of
/// arithmetic: on the 6 GB class a 3B brain *fits the budget alone* and does
/// not fit beside the STT the voice turn needs warm, so it is refused with
/// that reason rather than admitted and then paid for with a 77 s cold STT
/// load on every turn.
///
/// Everything is expressed against the catalog and the inventory, so a size
/// bump in `ModelCatalog` moves these expectations with it — the tests pin
/// the *policy*, not the artifact sizes.
final class ModelBudgetPolicyTests: XCTestCase {

    private var brain3B: ModelID { ModelCatalog.llama3_2_3B }
    private var brain4B: ModelID { ModelCatalog.intentQwen4BSlotCanon }
    private var brain17B: ModelID { ModelCatalog.qwen3_1_7BInstruct }
    private var intent1B: ModelID { ModelCatalog.intentNepali1B }
    private var sttANE: ModelID { ModelCatalog.whisperKitMediumV6 }

    private let compactPhone: UInt64 = 4_000_000_000     // < 5 GB
    private let standardPhone: UInt64 = 6_000_000_000    // 5–7 GB
    private let roomyPhone: UInt64 = 8_000_000_000        // ≥ 7 GB

    private func entry(_ id: ModelID) -> ModelCatalogEntry {
        guard let entry = ModelCatalog.entry(for: id) else {
            fatalError("catalog is missing \(id.rawValue)")
        }
        return entry
    }

    private func availability(_ id: ModelID,
                              on memory: UInt64) -> ModelAvailability {
        ModelBudgetPolicy.policy(forPhysicalMemoryBytes: memory)
            .availability(of: entry(id), physicalMemoryBytes: memory)
    }

    // MARK: - 1. The class → brain ladder

    func testThreeBIsUnavailableOnTheSixGBClassWithAReason() {
        // The headline case. At 2.82 GB live the 3B is *under* the 3.2 GB
        // class budget — the refusal is not "this phone cannot run it", it
        // is "this phone cannot run it and keep the STT warm", and the two
        // sentences lead a household to different choices.
        let result = availability(brain3B, on: standardPhone)
        XCTAssertFalse(result.isAvailable)
        XCTAssertEqual(result.reason, .requiresEvictingWarmSTT)
    }

    func testThreeBIsAvailableOnTheSevenGBClass() {
        // 2.82 GB + 1.0 GB of warm ANE STT = 3.82 GB, comfortably inside the
        // 5.0 GB roomy budget. Same model, same arithmetic, different class.
        XCTAssertEqual(availability(brain3B, on: roomyPhone), .available)
    }

    func testTheFourBIsOverTheStandardClassBudget() {
        // 3.40 GB live alone against a 3.2 GB budget: no eviction could make
        // room, which is the reason `soloOverBudget` exists for a preference
        // already stored — and the reason the picker must not offer it as a
        // normal choice on this class.
        let result = availability(brain4B, on: standardPhone)
        XCTAssertEqual(result.reason, .overClassBudget)
    }

    func testTheFourBIsAvailableOnTheRoomyClass() {
        // 3.40 GB + the ANE STT is 4.40 GB against 5.0 GB: this is the class
        // the pairing was sized for, and the only one where the 4B
        // co-resides rather than displacing.
        XCTAssertEqual(availability(brain4B, on: roomyPhone), .available)
    }

    func testTheSeventeenBCoResidesWithTheWarmSTTOnTheStandardClass() {
        // 1.98 GB + 1.0 GB = 2.98 GB ≤ 3.2 GB. This is the ladder's standard
        // rung, and it is load-bearing: a policy that refused this too would
        // leave the 6 GB class with no brain at all.
        XCTAssertEqual(availability(brain17B, on: standardPhone), .available)
    }

    func testTheCompactClassRefusesEveryShippedBrain() {
        // A finding, pinned so it cannot regress into a surprise: the
        // smallest shipped brain (`intentNepali1B`, 1.81 GB live) plus the
        // 0.65 GB STT that class runs is 2.46 GB against a 2.0 GB budget.
        // The 4 GB class cannot co-reside a brain with an STT at all —
        // which is why §3.2 pairs it with the small whisper.cpp context and
        // why the refusal is the honest answer rather than a silent admit.
        for id in [intent1B, brain17B, brain3B, brain4B] {
            let result = availability(id, on: compactPhone)
            XCTAssertFalse(result.isAvailable, "\(id.rawValue) on the 4 GB class")
            XCTAssertNotNil(result.reason)
        }
    }

    func testTheDeviceGateIsStillTheFirstWord() {
        // `minDeviceRAMBytes` is the catalog's own claim about the phone and
        // it is checked before the class arithmetic: a model the device
        // cannot hold at all reads as a device problem, not as a class
        // policy problem, and the two are different sentences for the user.
        // The 3B declares 5.5 GB; a 4 GB phone fails that before any
        // arithmetic runs.
        let result = availability(brain3B, on: compactPhone)
        XCTAssertEqual(result.reason, .deviceTooSmall)
    }

    func testTheLadderIsCheckedEvenWhenTheArithmeticWouldAllowIt() {
        // A tightened ladder — the owner's §7 Q1 decision expressed as a
        // one-line policy — must refuse a model that the memory arithmetic
        // would have admitted. This is `overBrainCeiling`: a *product*
        // refusal, which is why it is a separate word from the two memory
        // ones and why the field exists rather than a hard-coded comparison.
        let tightened = ModelBudgetPolicy(
            deviceClass: .roomy,
            workingSetIdleBytes: 400 * 1_000_000,
            workingSetCameraBytes: 1_400_000_000,
            largestAllowedBrainFileBytes: 1_000_000_000,
            warmSTTReserveBytes: 1_000_000_000,
            requiresWarmSTTCoResidency: false,
            maxTransientReserveBytes: ModelLifecycleBudget.roomyModelsBudgetBytes,
            maxLoadsPerMinute: 4)
        XCTAssertEqual(
            tightened.availability(of: entry(brain3B),
                                   physicalMemoryBytes: roomyPhone),
            .unavailable(reason: .overBrainCeiling))
    }

    // MARK: - 2. The lighter residents are not the policy's business

    func testLightResidentsAreGatedByTheDeviceOnly() {
        // Voices, the wake-word spotter, the VAD and the encoder are all
        // ≤ 0.14 GB and co-reside by design. Inventing a class rule for
        // them would refuse choices that work — the failure mode this whole
        // gate exists to avoid — so the only question asked of them is the
        // catalog's own device claim.
        let policy = ModelBudgetPolicy.standard
        for id in [ModelCatalog.piperNepali, ModelCatalog.piperEnglishUS] {
            XCTAssertEqual(policy.availability(of: entry(id),
                                               physicalMemoryBytes: standardPhone),
                           .available)
        }
    }

    func testAvailabilityIsNotAPreferenceQuestion() {
        // A row's availability is a property of the class, not of what is
        // currently selected: resolving it with the ANE STT warm and with
        // nothing selected must give the same answer for every entry, or a
        // household switching language would see the picker change shape.
        let policy = ModelBudgetPolicy.standard
        let withWarm = policy.availability(
            of: entry(brain3B),
            physicalMemoryBytes: standardPhone,
            warmSTTLiveBytes: ModelBudgetPolicy.warmSTTLiveBytes(
                forSTTModelID: sttANE))
        let withPolicyReserve = policy.availability(
            of: entry(brain3B), physicalMemoryBytes: standardPhone)
        XCTAssertEqual(withWarm, withPolicyReserve)
        XCTAssertEqual(withWarm, .unavailable(reason: .requiresEvictingWarmSTT))
    }

    func testTheWarmSTTFootprintFollowsTheSelectedModel() {
        // The reason can change with the *selected* STT, which is the
        // distinction the two `whisperBase` backends make real: the ANE
        // graph is 1.0 GB and whisper.cpp medium is 0.91 GB, and only the
        // bigger one decides the 3B's sentence on a 6 GB phone.
        let ane = ModelBudgetPolicy.warmSTTLiveBytes(forSTTModelID: sttANE)
        let cpp = ModelBudgetPolicy.warmSTTLiveBytes(
            forSTTModelID: ModelCatalog.whisperMediumFinetunedNepali)
        XCTAssertEqual(ane, 1_000_000_000)
        XCTAssertNotNil(cpp)
        XCTAssertLessThan(cpp ?? .max, ane ?? 0)
        XCTAssertNil(ModelBudgetPolicy.warmSTTLiveBytes(forSTTModelID: nil))
    }

    // MARK: - 3. The session profile

    func testTheIdleSessionBudgetIsTheClassBudget() {
        // The identity that keeps two spellings of one number from drifting:
        // with nothing heavy on screen the policy's budget IS the ledger's
        // class budget, for every class.
        for (policy, _) in [
            (ModelBudgetPolicy.compact, compactPhone),
            (ModelBudgetPolicy.standard, standardPhone),
            (ModelBudgetPolicy.roomy, roomyPhone)
        ] {
            XCTAssertEqual(
                policy.sessionModelBudgetBytes(session: .idle),
                ModelLifecycleBudget.modelsBudgetBytes(for: policy.deviceClass),
                "\(policy.deviceClass.rawValue)")
        }
    }

    func testTheCameraSessionSpendsTheWorkingSetDifference() {
        // §3.3's "the camera session changes the budget, not just the
        // model": `W(t)` grows by 1.1 GB, so the model budget shrinks by the
        // same 1.1 GB. Not wired into the camera pipeline in Step 3; this
        // is the arithmetic it will call.
        let policy = ModelBudgetPolicy.standard
        XCTAssertEqual(policy.sessionModelBudgetBytes(session: .cameraLive),
                       policy.sessionModelBudgetBytes(session: .idle) - 1_100_000_000)
        XCTAssertEqual(ModelBudgetPolicy.compact.sessionModelBudgetBytes(session: .cameraLive),
                       2_000_000_000 - 1_100_000_000)
    }

    func testThePolicyAgreesWithTheLedgerOnTheLoadRateDefault() {
        // The class's rate default and Step 2's guard default are two
        // spellings of one number, held equal here rather than by an
        // initializer so neither can drift unnoticed.
        for policy in [ModelBudgetPolicy.compact, .standard, .roomy] {
            XCTAssertEqual(policy.maxLoadsPerMinute,
                           ModelWardenConfig.default.maxLoadsPerMinute)
        }
        XCTAssertEqual(ModelBudgetPolicy.standard.maxTransientReserveBytes,
                       ModelLifecycleBudget.standardModelsBudgetBytes)
    }

    // MARK: - 4. What a row may say

    func testEveryReasonHasAContentFreeTokenAKeyAndASentence() {
        // The vocabulary is closed and both spellings are constant: the token
        // is what a field capture carries, the key is what a Settings row
        // resolves, and neither names an artifact — no filename, no model id,
        // no size. The key's own prefix is part of that: it routes through
        // the same `model.*` family the rows already use.
        XCTAssertEqual(Set(ModelUnavailabilityReason.allCases.map(\.rawValue)),
                       ["device_too_small", "over_class_budget",
                        "requires_evicting_warm_stt", "over_brain_ceiling"])
        XCTAssertEqual(Set(ModelUnavailabilityReason.allCases.map(\.localizationKey)),
                       ["model.unavailable.deviceTooSmall",
                        "model.unavailable.overClassBudget",
                        "model.unavailable.requiresEvictingWarmSTT",
                        "model.unavailable.overBrainCeiling"])
        for reason in ModelUnavailabilityReason.allCases {
            let text = ModelBudgetPolicy.displayText(for: reason)
            XCTAssertFalse(text.isEmpty)
            for leak in [".gguf", "q4", "Q4", "MB", "GB", "whisper",
                         "qwen", "intentNepali", "llama"] {
                XCTAssertFalse(text.lowercased().contains(leak.lowercased()),
                               "\(reason.rawValue) leaks \(leak): \(text)")
            }
        }
    }

    // MARK: - 5. The seam the Settings rows call

    /// A probe that answers one number. The availability check reads only
    /// `physicalMemoryBytes` (the class), so the headroom is the same
    /// stand-in the lifecycle suite's scripted probe uses — 0 here would be
    /// the "not measured" value and would quietly deny every load if this
    /// probe were ever reused for one.
    private struct FixedProbe: MemoryProbing {
        let physicalMemoryBytes: UInt64
        var availableProcessMemoryBytes: UInt64 { 3_400_000_000 }
    }

    func testTheManagerAnswersWithTheClassItAdmitsAgainst() {
        // `ModelLifecycleManager.availability(of:)` is the gate the rows ask
        // — it must derive the class from the ledger's own probe, so the
        // sentence a household reads is about the device the ledger budgets.
        // Same entry, two probes, two answers: the seam is what moves.
        let standard = ModelLifecycleManager(probe: FixedProbe(
            physicalMemoryBytes: standardPhone))
        XCTAssertEqual(standard.availability(of: entry(brain3B)),
                       .unavailable(reason: .requiresEvictingWarmSTT))
        let roomy = ModelLifecycleManager(probe: FixedProbe(
            physicalMemoryBytes: roomyPhone))
        XCTAssertEqual(roomy.availability(of: entry(brain3B)), .available)
        // And a light resident is nobody's policy problem, on either.
        for manager in [standard, roomy] {
            XCTAssertEqual(manager.availability(of: entry(ModelCatalog.piperNepali)),
                           .available)
        }
    }

    func testTheManagerAnswersWithTheWarmSTTItHasRegistered() {
        // The seam's second half. The 3B's sentence on the standard class
        // turns on which STT backend the ledger will load (the ANE graph is
        // 1.0 GB, whisper.cpp 0.91 GB), and the ledger already knows — it is
        // the registered `.speechToText` model. A caller passing a preference
        // in would be a second source for a fact the ledger holds.
        let manager = ModelLifecycleManager(probe: FixedProbe(
            physicalMemoryBytes: standardPhone))
        manager.register(slot: .speechToText,
                         modelID: ModelCatalog.whisperMediumFinetunedNepali,
                         owner: nil) {}
        XCTAssertEqual(
            manager.availability(of: entry(brain3B)),
            ModelBudgetPolicy.standard.availability(
                of: entry(brain3B),
                physicalMemoryBytes: standardPhone,
                warmSTTLiveBytes: ModelBudgetPolicy.warmSTTLiveBytes(
                    forSTTModelID: ModelCatalog.whisperMediumFinetunedNepali)))
    }

    func testTheAvailabilityInputsAreTheOnesTheRowsAnswerWith() {
        // [MODEL-WARDEN] `availabilityInputs` is the triple the AUTOMATIC
        // pick walks its ladder with (one reading, many questions);
        // `availability(of:)` is the same policy applied to one entry, which
        // is what a Settings row asks. They must be the same answer, or a row
        // could refuse a model the picker then loads.
        let manager = ModelLifecycleManager(probe: FixedProbe(
            physicalMemoryBytes: standardPhone))
        var inputs = manager.availabilityInputs
        XCTAssertEqual(inputs.physicalMemoryBytes, standardPhone)
        XCTAssertEqual(inputs.policy.deviceClass, .standard)
        // No STT registered → the class's own reserve, exactly as
        // `availability(of:)` falls back.
        XCTAssertNil(inputs.warmSTTLiveBytes)

        // With the ledger's STT registered, both sides move together.
        manager.register(slot: .speechToText,
                         modelID: ModelCatalog.whisperMediumFinetunedNepali,
                         owner: nil) {}
        inputs = manager.availabilityInputs
        XCTAssertEqual(inputs.warmSTTLiveBytes,
                       ModelBudgetPolicy.warmSTTLiveBytes(
                           forSTTModelID: ModelCatalog.whisperMediumFinetunedNepali))
        for entry in ModelCatalog.availableBrainEntries {
            XCTAssertEqual(
                inputs.policy.availability(of: entry,
                                           physicalMemoryBytes: inputs.physicalMemoryBytes,
                                           warmSTTLiveBytes: inputs.warmSTTLiveBytes),
                manager.availability(of: entry),
                "\(entry.id.rawValue): the inputs and the row disagree")
        }
    }

    func testTheRowSentenceIsNeverTheBareKey() {
        // The wiring the Settings row and the picker marker use. Whichever
        // path answers — the string table or the English fallback — a
        // household must never be shown `model.unavailable.overClassBudget`,
        // which is the one outcome nobody can act on.
        for reason in ModelUnavailabilityReason.allCases {
            for locale in [Locale(identifier: "en"), Locale(identifier: "ne")] {
                let note = AIModelsSettingsView.unavailableNote(reason,
                                                                locale: locale)
                XCTAssertFalse(note.isEmpty)
                XCTAssertNotEqual(note, reason.localizationKey)
                XCTAssertFalse(note.contains("model.unavailable"),
                               "\(reason.rawValue) → \(note)")
            }
        }
    }

    func testTheRowSentenceIsTranslatedInEveryShippedLanguage() {
        // A key added for one language and forgotten in the other is how a
        // household ends up reading English on a Nepali phone — the failure
        // the string table's own "translated" states exist to prevent.
        for reason in ModelUnavailabilityReason.allCases {
            XCTAssertNotEqual(
                AIModelsSettingsView.unavailableNote(reason,
                                                     locale: Locale(identifier: "en")),
                AIModelsSettingsView.unavailableNote(reason,
                                                     locale: Locale(identifier: "ne")),
                reason.rawValue)
        }
    }

    func testThePickerMarkerOutranksTheDownloadNote() {
        // One suffix at a time. `unavailable` is the stronger statement and
        // the only actionable one: a download would change nothing, so the
        // row must not read "not downloaded" as if fetching it were the fix.
        let en = Locale(identifier: "en")
        let model = entry(brain4B)
        let marked = AIModelsSettingsView.sttOptionLabel(
            entry: model, downloaded: false, unavailable: true, locale: en)
        XCTAssertTrue(marked.contains(model.displayName(locale: en)), marked)
        XCTAssertTrue(marked.lowercased().contains("not for this phone"), marked)
        XCTAssertFalse(marked.lowercased().contains("not downloaded"), marked)
        // The two pre-existing states are unchanged: bare name when
        // installed, the download note when not — no regression for the
        // rows the declutter work pinned.
        XCTAssertEqual(AIModelsSettingsView.sttOptionLabel(
            entry: model, downloaded: true, locale: en),
            model.displayName(locale: en))
        XCTAssertTrue(AIModelsSettingsView.sttOptionLabel(
            entry: model, downloaded: false, locale: en)
            .lowercased().contains("not downloaded"))
    }

    func testAnUnavailableReasonIsReadableWithoutUnwrappingTheEnum() {
        XCTAssertNil(ModelAvailability.available.reason)
        XCTAssertTrue(ModelAvailability.available.isAvailable)
        let refused = ModelAvailability.unavailable(reason: .overClassBudget)
        XCTAssertFalse(refused.isAvailable)
        XCTAssertEqual(refused.reason, .overClassBudget)
    }

    // MARK: - 6. The automatic pick asks the same gate the rows read

    /// [MODEL-WARDEN] Closing the D1 hole: the resolution
    /// (`LanguageModelResolver.resolvedAutomaticPick`) must decide with the
    /// same verdict the Settings rows render through
    /// `ModelLifecycleManager.availability(of:)`. A household that reads
    /// "not for this phone" on a row must not then get that model from an
    /// automatic device, and a model the pick lands on must be one the
    /// ledger itself would offer. Both go through `ModelBudgetPolicy`, and
    /// this pins that they agree on the two classes where it matters.
    func testTheAutomaticPickAgreesWithTheLedgerTheRowsRead() throws {
        let standard = ModelLifecycleManager(probe: FixedProbe(
            physicalMemoryBytes: standardPhone))
        let pick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase,
            language: "ne",
            policy: ModelBudgetPolicy.policy(for: .standard),
            physicalMemoryBytes: standardPhone))
        XCTAssertEqual(pick.entry.id, ModelCatalog.qwen3_1_7BInstruct)
        XCTAssertEqual(standard.availability(of: pick.entry), .available,
                       "the model Automatic picks must be one the ledger offers")
        // The default it stepped off is refused, with exactly the reason the
        // pick records as its explanation — one sentence, one vocabulary.
        XCTAssertEqual(pick.declinedDefaultReason, .overClassBudget)
        XCTAssertEqual(standard.availability(of: entry(brain4B)),
                       .unavailable(reason: .overClassBudget))

        // The compact class: the ledger refuses the pick too, and that
        // refusal IS the honest degradation — no crash, no loop, and no
        // silent admit of what the policy refused.
        let compact = ModelLifecycleManager(probe: FixedProbe(
            physicalMemoryBytes: compactPhone))
        let degraded = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase,
            language: "ne",
            policy: ModelBudgetPolicy.policy(for: .compact),
            physicalMemoryBytes: compactPhone))
        XCTAssertEqual(compact.availability(of: degraded.entry),
                       .unavailable(reason: .requiresEvictingWarmSTT))
        XCTAssertEqual(degraded.recordedReason, .requiresEvictingWarmSTT)
    }

    func testNoBrainTheAutomaticPickMayDrawFromFitsTheCompactClass() {
        // The compact finding from the picker's side: the resolution's step
        // 2 (the largest artifact that fits beside the warm STT) has NO
        // candidate on this class, so step 3 is the only honest answer
        // there. Pinned over the CURATED list — the entries a pick may
        // actually draw from — rather than the whole catalog, so a
        // decluttered entry that would fit cannot make this vacuous.
        let policy = ModelBudgetPolicy.compact
        for entry in ModelCatalog.availableBrainEntries {
            XCTAssertFalse(policy.availability(of: entry,
                                               physicalMemoryBytes: compactPhone)
                .isAvailable,
                           "\(entry.id.rawValue) on the 4 GB class")
        }
    }

    func testTheRecordedReasonIsContentFreeAndRidesAnAllowedKey() throws {
        // "Recorded honestly" has two halves, and the second is the one that
        // fails silently: the token has to be content-free (no artifact, no
        // size, no path — the closed vocabulary already pins the spelling)
        // AND it has to survive the sanitiser, which drops every metadata key
        // it does not know. A model id, a filename or a size would be dropped
        // (or, worse, carried); the reason token rides `reason`, which the
        // allow-list already blesses, so a field capture can say WHY
        // Automatic moved without saying what it moved to.
        let pick = try XCTUnwrap(LanguageModelResolver.resolvedAutomaticPick(
            kind: .llamaBase,
            language: "ne",
            policy: ModelBudgetPolicy.standard,
            physicalMemoryBytes: standardPhone))
        let token = try XCTUnwrap(pick.recordedReason).rawValue
        XCTAssertEqual(token, "over_class_budget")
        XCTAssertTrue(LogSanitiser.allowedKeys.contains("reason"),
                      "the key the token rides is already allow-listed")
        // The two keys the coordinator's `automatic_brain_pick` event
        // carries (this token under `reason`, the ledger's slot under
        // `slot`): both existing entries, no allow-list growth for this fix.
        XCTAssertTrue(LogSanitiser.allowedKeys.contains("slot"))
        XCTAssertTrue(ModelUnavailabilityReason.allCases.map(\.rawValue).contains(token),
                      "the record is drawn from the closed vocabulary, not composed")
        for leak in [pick.entry.id.rawValue, ".gguf", "/", "GB", "qwen", "1_7B"] {
            XCTAssertFalse(token.contains(leak),
                           "the recorded reason leaks \(leak): \(token)")
        }
    }

    func testTheBatchGateAnswersForEveryEntryAsTheSingleGateDoes() {
        // The picker asks for a whole list at once; the answer must be the
        // same one the single-entry call gives, or a row's state would
        // depend on how it was rendered.
        let entries = ModelCatalog.availableBrainEntries
        XCTAssertFalse(entries.isEmpty)
        let policy = ModelBudgetPolicy.standard
        let batch = policy.availability(in: entries,
                                        physicalMemoryBytes: standardPhone,
                                        warmSTTModelID: sttANE)
        XCTAssertEqual(batch.count, entries.count)
        for entry in entries {
            XCTAssertEqual(batch[entry.id],
                           policy.availability(of: entry,
                                               physicalMemoryBytes: standardPhone,
                                               warmSTTLiveBytes: 1_000_000_000),
                           entry.id.rawValue)
        }
    }
}
