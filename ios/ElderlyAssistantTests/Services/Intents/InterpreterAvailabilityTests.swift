import XCTest
@testable import ElderlyAssistant

/// Interpreter-availability matrix (spec §7 "no dead ends";
/// interpreter-availability fix 2026-09-06). The reported bug: with
/// every interpreter unavailable — the fine-tuned intent GGUF is a
/// placeholder, the LLaMA stand-in needs its (no-longer-auto-downloaded)
/// model, and Gemini needs a key — the transcript was correct but the
/// reply was always the generic "I didn't understand". These tests pin
/// the two halves of the fix:
///
///  (a) HONESTY — when the brain chain is empty, the router speaks a
///      specific localized state message (model downloading / setup
///      needed), NOT the comprehension-failure re-prompt that blames
///      the user's speech;
///  (b) HEALTH — a cached stand-in answers plain queries through the
///      real router as before;
///  (c) WIRING — the assistant-brain model (the gate-passing Qwen 4B
///      seed-43 intent fine-tune, a real hosted artifact) is
///      auto-downloaded whenever the chain needs it and the model isn't
///      cached, and `BrainReadiness.resolve` mirrors the router's exact
///      layer ladder.
final class InterpreterAvailabilityTests: XCTestCase {

    private func ne(_ key: String) -> String {
        L10n.str(key, locale: Locale(identifier: "ne"))
    }

    /// A production-shaped brainless chain: `IntentRouter` (whose
    /// `isAvailable` is always true — the cache layer) with no reachable
    /// brain behind it, exactly as `AppCoordinator` wires it before the
    /// assistant-brain model lands or a Gemini key is configured.
    private func makeBrainlessRouter(bus: RecordingObservabilityBus) -> IntentRouter {
        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudEnabled = false
        router.cloudBrain = StubCommandInterpreter(available: false, result: nil)
        router.localBrain = LocalBrainChain(
            preferred: StubCommandInterpreter(available: false, result: nil),
            standIn: StubCommandInterpreter(available: false, result: nil))
        return router
    }

    private func makeCommandRouter(interpreter: CommandInterpreter,
                                   coordinator: StubCoordinator,
                                   bus: RecordingObservabilityBus) -> CommandRouter {
        CommandRouter(coordinator: coordinator,
                      observabilityBus: bus,
                      speaker: nil,
                      interpreter: interpreter)
    }

    /// Wait for the router's async interpret fallback (empty-chain
    /// completions and stub interpret both dispatch on main).
    private func waitForAsyncFallback() {
        let exp = expectation(description: "async fallback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        waitForExpectations(timeout: 2)
    }

    // MARK: - (a) Honest no-brain speech (the reported bug's fix)

    func testBrainDownloadingInFlightSpeaksDownloadMessageNotReprompt() {
        let coordinator = StubCoordinator()
        coordinator.brainReadiness = .downloadingBrain
        let bus = RecordingObservabilityBus()
        let router = makeCommandRouter(interpreter: makeBrainlessRouter(bus: bus),
                                       coordinator: coordinator,
                                       bus: bus)

        // Non-topic query: weather is pre-answered by `TopicPreAnswer`.
        let result = router.route(transcript: "मलाई एउटा कथा सुनाउनुहोस्")

        XCTAssertEqual(result, .unrecognised(transcript: "मलाई एउटा कथा सुनाउनुहोस्"))
        waitForAsyncFallback()
        let downloadingText = ne("router.brainDownloading")
        XCTAssertFalse(downloadingText.isEmpty)
        XCTAssertEqual(coordinator.genericReplies, [downloadingText],
                       "a downloading brain must speak the download state, not 'I didn't understand'")
        XCTAssertNotEqual(downloadingText, ne("router.reprompt"))
        XCTAssertTrue(bus.contains("command_unrecognised"),
                      "the routing outcome is still 'unrecognised' — only the spoken message is honest")
    }

    func testNoBrainAndNothingInFlightSpeaksSetupMessageNotReprompt() {
        let coordinator = StubCoordinator()
        coordinator.brainReadiness = .needsSetup
        let bus = RecordingObservabilityBus()
        let router = makeCommandRouter(interpreter: makeBrainlessRouter(bus: bus),
                                       coordinator: coordinator,
                                       bus: bus)

        // Non-topic query: weather is pre-answered by `TopicPreAnswer`.
        let result = router.route(transcript: "मलाई एउटा कथा सुनाउनुहोस्")

        XCTAssertEqual(result, .unrecognised(transcript: "मलाई एउटा कथा सुनाउनुहोस्"))
        waitForAsyncFallback()
        let setupText = ne("router.brainNeedsSetup")
        XCTAssertFalse(setupText.isEmpty)
        XCTAssertEqual(coordinator.genericReplies, [setupText],
                       "a missing brain with nothing downloading must say setup is needed, not 'I didn't understand'")
        XCTAssertNotEqual(setupText, ne("router.reprompt"))
        XCTAssertNotEqual(setupText, ne("router.brainDownloading"),
                          "the two honest messages must be distinct — one says 'downloading', one says 'set up'")
    }

    func testAvailableChainAbstentionKeepsGenericReprompt() {
        // A brain WAS listening (chain available) and abstained — the
        // generic re-prompt stays honest and unchanged in this case.
        let coordinator = StubCoordinator()   // brainReadiness defaults .available
        let bus = RecordingObservabilityBus()
        let router = makeCommandRouter(interpreter: makeBrainlessRouter(bus: bus),
                                       coordinator: coordinator,
                                       bus: bus)

        // A non-topic query: weather is now pre-answered by
        // `TopicPreAnswer` (NO-GIBBERISH) before the chain runs, so the
        // abstention regression needs a plain question outside the
        // weather/time/date/greeting table.
        _ = router.route(transcript: "मलाई एउटा कथा सुनाउनुहोस्")
        waitForAsyncFallback()

        XCTAssertTrue(bus.contains("command_unrecognised"))
        XCTAssertEqual(coordinator.genericReplies, [],
                       "an available chain's abstention must stay spoken-only (the generic re-prompt), "
                       + "not switch to the no-brain messages")
    }

    // MARK: - (b) Healthy path regression: cached stand-in answers

    func testCachedStandInAnswersPlainQueryThroughRouter() {
        // The "LLaMA cached" row of the matrix: the on-device stack with
        // the stand-in available must interpret normally — no fallback
        // speech at all, honest or otherwise.
        let coordinator = StubCoordinator()
        let bus = RecordingObservabilityBus()
        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudEnabled = false
        router.cloudBrain = StubCommandInterpreter(available: false, result: nil)
        let answer = makeCommand(action: .query, confidence: 0.9, reply: "एउटा राम्रो कथा सुनाउँछु।")
        router.localBrain = LocalBrainChain(
            preferred: StubCommandInterpreter(available: false, result: nil),
            standIn: StubCommandInterpreter(result: answer))
        let commandRouter = makeCommandRouter(interpreter: router,
                                              coordinator: coordinator,
                                              bus: bus)

        let exp = expectation(description: "async dispatch")
        DispatchQueue.main.async {
            if !coordinator.genericReplies.isEmpty { exp.fulfill() }
        }
        // Non-topic query: weather is pre-answered by `TopicPreAnswer`.
        _ = commandRouter.route(transcript: "मलाई एउटा कथा सुनाउनुहोस्")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(coordinator.genericReplies, ["एउटा राम्रो कथा सुनाउँछु।"],
                       "a cached stand-in must answer the plain query")
        XCTAssertFalse(bus.contains("command_unrecognised"),
                       "a real interpretation must not reach the unrecognised fallback at all")
    }

    // MARK: - (c) Auto-download wiring + readiness derivation

    func testDefaultBrainModelIsTheRealHostedLlamaArtifact() {
        // The auto-download target since 2026-09-14 is the gate-passing
        // slot-canonical Qwen 4B (v16, `intentQwen4BSlotCanon`) — the
        // retrain of the seed-43 brain that first cleared all five ship
        // gates, fixing the slot gates it failed. It must ship from the
        // hosted (https) GitHub release, not a LAN test URL the catalogue
        // carries for bake-off testing (qwen4BNepali still does).
        XCTAssertEqual(AppCoordinator.defaultBrainModelID, ModelCatalog.intentQwen4BSlotCanon)
        let entry = ModelCatalog.entry(for: AppCoordinator.defaultBrainModelID)
        XCTAssertNotNil(entry)
        let url = entry?.downloadURL.absoluteString ?? ""
        XCTAssertFalse(url.contains(".invalid"),
                       "the assistant-brain artifact must be a real hosted URL, not a placeholder")
        // Hosted means https: the catalogue also carries LAN-only test
        // entries (e.g. qwen4BNepali on the home server) that would pass
        // the placeholder check but must never become the auto-downloaded
        // default. The https pin stays.
        XCTAssertTrue(url.hasPrefix("https://"),
                      "the default brain must come from a hosted (https) URL, not a LAN/local address")
        XCTAssertGreaterThan(entry?.sizeBytes ?? 0, 0)
        XCTAssertEqual(entry?.kind, .llamaBase)
        // Delivery: 2.5 GB exceeds GitHub's 2 GiB per-asset cap, so the
        // default brain MUST declare ordered parts — a single-asset URL
        // would be a 404 on the release.
        let parts = entry?.downloadPartURLs ?? []
        XCTAssertGreaterThanOrEqual(parts.count, 2,
                                    "a >2 GiB artifact cannot ship as one GitHub asset")
        for part in parts {
            XCTAssertTrue(part.absoluteString.hasPrefix("https://"),
                          "every part must come from the hosted release")
        }
        XCTAssertEqual(parts.first?.absoluteString, url,
                       "downloadURL mirrors part 0 for readers that predate parts")
        // Guardrail: the default brain must be inside the service's hard
        // size cap (see ModelDownloadService.maxMultipartTotalBytes).
        XCTAssertLessThanOrEqual(entry?.sizeBytes ?? .max,
                                 ModelDownloadService.maxMultipartTotalBytes,
                                 "the default brain must fit the size guardrail")
        // Real artifact, not a stub: a full-length, non-zero sha256 pin —
        // OR the explicitly-marked pre-upload placeholder, which is the
        // honest state until the coordinator uploads the v16 asset and
        // supplies its digest. Any OTHER value still fails: this test is
        // what stops a fabricated pin from shipping.
        let sha = entry?.sha256 ?? ""
        if sha == ModelCatalogEntry.pendingSHA256 {
            XCTAssertGreaterThan(entry?.sizeBytes ?? 0, 2_147_483_648,
                                 "only a >2 GiB artifact needs the pending-digest "
                                 + "route; a small model has no excuse for an unpinned sha")
        } else {
            XCTAssertEqual(sha.count, 64,
                           "the default brain's sha256 must be a full 64-hex pin")
            XCTAssertNotEqual(sha, String(repeating: "0", count: 64),
                              "the default brain's sha256 must be a real pin, not a zero stub")
        }
    }

    // MARK: - (d) [MODEL-WARDEN] what "Automatic" resolves to on THIS device

    /// A probe that answers one RAM number. The resolution reads only
    /// `physicalMemoryBytes` (the class), so the headroom is the same
    /// stand-in the ledger suites use.
    private struct FixedRAMProbe: MemoryProbing {
        let physicalMemoryBytes: UInt64
        var availableProcessMemoryBytes: UInt64 { 3_400_000_000 }
    }

    private func ledger(ram: UInt64) -> ModelLifecycleManager {
        ModelLifecycleManager(probe: FixedRAMProbe(physicalMemoryBytes: ram))
    }

    func testAutomaticBrainStepsOffTheFourBDefaultOnASixGBPhone() {
        // The D1 hole, at the seam that loads the model: with no stored
        // preference the app runs what `resolveBrainModelID` returns, and on
        // the standard class the catalogue's 4B default is over budget
        // beside the warm STT — loading it would evict the ANE STT on every
        // turn. Automatic must therefore step down to the 1.7B.
        let ledger = ledger(ram: 6_000_000_000)
        XCTAssertEqual(
            AppCoordinator.resolveBrainModelID(storedPreference: nil,
                                               language: "ne",
                                               ledger: ledger),
            ModelCatalog.qwen3_1_7BInstruct)
        // ...and the default it stepped off is exactly the one the Settings
        // rows refuse, so the row and the pick are one answer.
        XCTAssertEqual(ledger.availability(
            of: ModelCatalog.entry(for: ModelCatalog.intentQwen4BSlotCanon)!),
                       .unavailable(reason: .overClassBudget))
        // The catalogue constant itself does NOT move: it is the artifact
        // the default is pinned to, device-blind by design.
        XCTAssertEqual(AppCoordinator.defaultBrainModelID,
                       ModelCatalog.intentQwen4BSlotCanon)
    }

    func testAutomaticBrainIsUnchangedWhereTheClassCanHoldTheDefault() {
        // The no-behaviour-change half: a roomy device resolves to the same
        // brain it always did, so nothing about this fix touches the phones
        // that were already fine.
        let ledger = ledger(ram: 8_000_000_000)
        XCTAssertEqual(
            AppCoordinator.resolveBrainModelID(storedPreference: nil,
                                               language: "ne",
                                               ledger: ledger),
            ModelCatalog.intentQwen4BSlotCanon)
        XCTAssertEqual(ledger.availability(
            of: ModelCatalog.entry(for: ModelCatalog.intentQwen4BSlotCanon)!),
                       .available)
    }

    func testAnExplicitBrainPreferenceIsNeverRePointed() {
        // The escape hatch, at the load seam: a household that stored the
        // 4B keeps the 4B on a class that refuses it — `soloOverBudget`, the
        // path that exists so a resident is never unloadable. The policy
        // gates the automatic path only.
        let ledger = ledger(ram: 6_000_000_000)
        XCTAssertEqual(
            AppCoordinator.resolveBrainModelID(
                storedPreference: ModelCatalog.intentQwen4BSlotCanon,
                language: "ne",
                ledger: ledger),
            ModelCatalog.intentQwen4BSlotCanon)
        // A stored id the catalogue no longer has is not a pick any more:
        // it falls through to the automatic resolution rather than wedging
        // the interpreter on a model that cannot be downloaded.
        XCTAssertEqual(
            AppCoordinator.resolveBrainModelID(
                storedPreference: ModelID("retired-brain-id"),
                language: "ne",
                ledger: ledger),
            ModelCatalog.qwen3_1_7BInstruct)
    }

    func testAutomaticBrainOnACompactPhoneDegradesHonestly() {
        // The compact finding at the seam: no shipped brain fits beside an
        // STT at all on the 4 GB class, so the resolution degrades to the
        // lightest compatible brain instead of looping, crashing, or
        // silently admitting the 4B. The model it lands on is still a real
        // catalogue entry of the right kind — degradation, not a dead end.
        let ledger = ledger(ram: 4_000_000_000)
        let resolved = AppCoordinator.resolveBrainModelID(storedPreference: nil,
                                                          language: "ne",
                                                          ledger: ledger)
        XCTAssertEqual(resolved, ModelCatalog.intentQwenS43)
        let entry = ModelCatalog.entry(for: resolved)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.kind, .llamaBase)
        XCTAssertTrue(entry?.languages.contains("ne") ?? false,
                      "the degraded pick must still serve the household's language")
    }

    func testAutoDownloadPolicyDownloadsWhenChainNeedsTheModel() {
        // On-device stack: cloud stays out of the chain even with a key
        // configured — the local model is required regardless.
        XCTAssertTrue(AppCoordinator.shouldAutoDownloadAssistantBrain(
            modelCached: false, cloudEnabled: false, cloudBrainAvailable: true))
        // Gemini stack before a key is configured: no cloud brain exists
        // yet — the default brain must arrive like it used to.
        XCTAssertTrue(AppCoordinator.shouldAutoDownloadAssistantBrain(
            modelCached: false, cloudEnabled: true, cloudBrainAvailable: false))
        // Brainless entirely.
        XCTAssertTrue(AppCoordinator.shouldAutoDownloadAssistantBrain(
            modelCached: false, cloudEnabled: false, cloudBrainAvailable: false))
    }

    func testAutoDownloadPolicySkipsWhenBrainAlreadyReachable() {
        // Model cached → never re-download, whatever the stack.
        XCTAssertFalse(AppCoordinator.shouldAutoDownloadAssistantBrain(
            modelCached: true, cloudEnabled: false, cloudBrainAvailable: false))
        XCTAssertFalse(AppCoordinator.shouldAutoDownloadAssistantBrain(
            modelCached: true, cloudEnabled: true, cloudBrainAvailable: true))
        // Live cloud brain on the Gemini stack → no local download needed.
        XCTAssertFalse(AppCoordinator.shouldAutoDownloadAssistantBrain(
            modelCached: false, cloudEnabled: true, cloudBrainAvailable: true))
    }

    func testBrainReadinessResolveMirrorsTheRouterLayerLadder() {
        // Local brain available → available, regardless of cloud config
        // (and regardless of a pointless in-flight download flag).
        XCTAssertEqual(BrainReadiness.resolve(localBrainAvailable: true,
                                              cloudEnabled: false,
                                              cloudBrainAvailable: false,
                                              brainDownloadInFlight: false), .available)
        XCTAssertEqual(BrainReadiness.resolve(localBrainAvailable: true,
                                              cloudEnabled: true,
                                              cloudBrainAvailable: true,
                                              brainDownloadInFlight: true), .available)
        // Live cloud brain on the Gemini stack → available.
        XCTAssertEqual(BrainReadiness.resolve(localBrainAvailable: false,
                                              cloudEnabled: true,
                                              cloudBrainAvailable: true,
                                              brainDownloadInFlight: false), .available)
        // On-device stack ignores a configured cloud brain (cloudEnabled
        // false) → the chain is empty → honest no-brain state.
        XCTAssertEqual(BrainReadiness.resolve(localBrainAvailable: false,
                                              cloudEnabled: false,
                                              cloudBrainAvailable: true,
                                              brainDownloadInFlight: false), .needsSetup)
        XCTAssertEqual(BrainReadiness.resolve(localBrainAvailable: false,
                                              cloudEnabled: false,
                                              cloudBrainAvailable: true,
                                              brainDownloadInFlight: true), .downloadingBrain)
        // Gemini stack, no key, nothing downloading → setup needed.
        XCTAssertEqual(BrainReadiness.resolve(localBrainAvailable: false,
                                              cloudEnabled: true,
                                              cloudBrainAvailable: false,
                                              brainDownloadInFlight: false), .needsSetup)
        // ... and the in-flight flag is the only difference for the
        // downloading message.
        XCTAssertEqual(BrainReadiness.resolve(localBrainAvailable: false,
                                              cloudEnabled: true,
                                              cloudBrainAvailable: false,
                                              brainDownloadInFlight: true), .downloadingBrain)
    }
}
