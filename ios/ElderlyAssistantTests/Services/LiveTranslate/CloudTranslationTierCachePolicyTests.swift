import XCTest
@testable import ElderlyAssistant

/// [FOCUS-CAPTURE] `CloudTranslationTier.CachePolicy`: the tier's read of the
/// persisted layers, and the caller's choice about the write.
///
/// The focused read is a capture of something the elder pointed at, and what
/// they pointed at may be a letter, a prescription or a card with a name on it.
/// The shipped store is the *feature's* memory of translations it has paid for;
/// adding a capture's strings to it would put the contents of that letter on
/// disk for the session and for every later one. So the tier gained one
/// additive parameter: the read stays exactly where it was, and the write can
/// be declined.
///
/// Three claims, in the order the tier meets them:
///
///  1. **`.persist` is the default and is the shipped behaviour.** Called
///     without the parameter the tier writes what it resolved — pinned here so
///     a future edit cannot make "no argument" mean "do not store" and silently
///     stop the live path from remembering anything.
///  2. **`.readOnly` declines the write.** The answer still comes back to the
///     caller; it just is not added to the persisted layer, and the byte-level
///     evidence (the storage double's write count for the cache's own key) is
///     that nothing at all was written.
///  3. **`.readOnly` still reads.** What the store already holds is answered
///     from the store, with no request and no prompt — the capture reuses the
///     device's curated dictionary and the session's paid-for answers exactly
///     as the live path does.
final class CloudTranslationTierCachePolicyTests: XCTestCase {

    private struct Harness {
        let tier: CloudTranslationTier
        let gate: LiveTranslateConsentGate
        let cache: LabelTranslationCache
        let transport: TierTranslationTransport
        let bus: LiveTranslateSanitisingBus
        let storage: LabelTranslationCacheTestStorage
    }

    /// The tier's own composition, assembled the way `CloudTranslationTierTests`
    /// assembles it: the real gate, governor and cache over a byte-level
    /// storage double, and only the transport scripted.
    @MainActor
    private func makeHarness(config: LiveTranslateConfig = .default) -> Harness {
        let bus = LiveTranslateSanitisingBus()
        let storage = LabelTranslationCacheTestStorage()
        let configStore = GeminiConfigStore(storage: storage)
        configStore.save("fake-key")
        let gate = LiveTranslateConsentGate(storage: storage, config: config, observabilityBus: bus)
        _ = gate.record(granted: true)
        let governor = GeminiCostGovernor(storage: storage, observabilityBus: bus)
        let cache = LabelTranslationCache(storage: storage,
                                          config: config,
                                          observabilityBus: bus,
                                          dictionary: [:])
        let indicator = CloudActivityIndicatorModel(observabilityBus: bus, config: config)
        let transport = TierTranslationTransport()
        var clientConfig = GeminiClient.Config.default
        // One attempt per scripted answer: the request count is evidence here,
        // so the client's own retries stay out of it.
        clientConfig.maxTransportRetries = 0
        let client = GeminiClient(configStore: configStore,
                                  observabilityBus: bus,
                                  transport: transport,
                                  config: clientConfig,
                                  costGovernor: governor)
        let tier = CloudTranslationTier(cache: cache,
                                        consentGate: gate,
                                        costGovernor: governor,
                                        client: client,
                                        config: config,
                                        observabilityBus: bus,
                                        indicator: indicator)
        return Harness(tier: tier, gate: gate, cache: cache,
                       transport: transport, bus: bus, storage: storage)
    }

    /// A sentence-class string: long enough that the class rule would lead with
    /// the cloud, which is what makes a request the expected outcome.
    private let askedText = "Members only beyond this point"
    private let answer = "सदस्यहरू मात्र"

    private func item(_ id: String, _ text: String) -> CloudTranslationTier.Item {
        CloudTranslationTier.Item(id: id, text: text, detectedSourceLanguage: "en")
    }

    /// The one answer the scripted transport gives, by wire id.
    private func respond(_ harness: Harness) {
        harness.transport.autoRespond = { byID in
            let out = byID.mapValues { _ in self.answer }
            return String(data: try! JSONSerialization.data(withJSONObject: out),
                          encoding: .utf8)!
        }
    }

    // MARK: - The default: the write happens

    @MainActor
    func testTheDefaultPolicyPersistsTheAnswerTheTierPaidFor() async {
        let harness = makeHarness()
        respond(harness)

        let result = await harness.tier.resolve(items: [item("r1", askedText)])

        XCTAssertEqual(harness.transport.requestCount, 1)
        XCTAssertEqual(result.resolved["r1"]?.translation, answer)
        XCTAssertEqual(result.resolved["r1"]?.origin, .cloud, "the cloud produced it")
        guard case .success(.some(let hit)) = harness.cache.lookup(text: askedText) else {
            return XCTFail("the shipped policy stores what it resolved")
        }
        XCTAssertEqual(hit.translation, answer)
        XCTAssertGreaterThan(harness.storage.writeCount(forKey: LabelTranslationCache.storageKey), 0,
                             "the answer reached the persisted channel")
    }

    // MARK: - The policy a capture takes: read, and do not write

    @MainActor
    func testTheReadOnlyPolicyAnswersTheCallerAndWritesNothing() async {
        let harness = makeHarness()
        respond(harness)

        let result = await harness.tier.resolve(items: [item("r1", askedText)],
                                                cachePolicy: .readOnly)

        // The caller is answered exactly as before: a policy is not a
        // degradation, and the elder asked for the translation, not for an
        // audit of where it goes.
        XCTAssertEqual(harness.transport.requestCount, 1)
        XCTAssertEqual(result.resolved["r1"]?.translation, answer)
        XCTAssertEqual(result.resolved["r1"]?.origin, .cloud)
        // And nothing was written — not an entry, not a payload.
        XCTAssertEqual(harness.cache.generalEntryCount, 0,
                       "a capture's answer must not join the persisted layer")
        XCTAssertEqual(harness.storage.writeCount(forKey: LabelTranslationCache.storageKey), 0,
                       "a capture must not write the cache's own payload")
    }

    @MainActor
    func testTheReadOnlyPolicyStillReadsWhatTheStoreAlreadyHolds() async {
        let harness = makeHarness()
        respond(harness)
        // What the live path paid for a moment ago, in the store the capture
        // may read and may not add to.
        XCTAssertTrue(harness.cache.store(text: askedText, translation: answer).isSuccess)
        let writesAfterSeeding = harness.storage.writeCount(forKey: LabelTranslationCache.storageKey)

        let result = await harness.tier.resolve(items: [item("r1", askedText)],
                                                cachePolicy: .readOnly)

        XCTAssertEqual(result.resolved["r1"]?.translation, answer)
        XCTAssertEqual(result.resolved["r1"]?.origin, .cache(.persistedLayer),
                       "the store answered it, not a model")
        XCTAssertEqual(result.resolved["r1"]?.tier, .cloud,
                       "a cloud-produced string stays a cloud translation when the "
                       + "device's own store serves it (CL-3)")
        XCTAssertEqual(harness.transport.requestCount, 0, "nothing left the device")
        XCTAssertEqual(harness.storage.writeCount(forKey: LabelTranslationCache.storageKey),
                       writesAfterSeeding,
                       "reading through a capture does not write")
    }

    @MainActor
    func testTheReadOnlyPolicyStillReadsTheCuratedDictionary() async {
        let harness = makeHarness()
        XCTAssertTrue(harness.cache.store(text: "Light", translation: "बत्ती").isSuccess)

        let result = await harness.tier.resolve(items: [item("r1", "Light")],
                                                cachePolicy: .readOnly)

        XCTAssertEqual(result.resolved["r1"]?.translation, "बत्ती")
        XCTAssertEqual(harness.transport.requestCount, 0,
                       "the device's own answer never needed the network, on either policy")
    }

    @MainActor
    func testTheReadOnlyPolicyDoesNotWeakenTheGate() async {
        // The policy is about the *store*, never about permission: a capture
        // with no consent still cannot reach the provider.
        let harness = makeHarness()
        respond(harness)
        XCTAssertTrue(harness.gate.revoke().isSuccess)

        let result = await harness.tier.resolve(items: [item("r1", askedText)],
                                                cachePolicy: .readOnly)

        XCTAssertEqual(harness.transport.requestCount, 0)
        XCTAssertEqual(result.resolved["r1"], nil)
        XCTAssertNotNil(result.failures["r1"], "an unconsented ask fails honestly")
        XCTAssertEqual(harness.storage.writeCount(forKey: LabelTranslationCache.storageKey), 0)
    }

    // MARK: - The shape of the policy

    func testTheTwoPoliciesAreDistinctValues() {
        // The policy is a value, not a flag: a caller that passes the wrong one
        // has passed a different value rather than a truthy/falsy accident.
        // Which one a *call with no argument* means is pinned behaviourally by
        // `testTheDefaultPolicyPersistsTheAnswerTheTierPaidFor` above — the one
        // place the default is observable.
        XCTAssertNotEqual(CloudTranslationTier.CachePolicy.persist,
                          CloudTranslationTier.CachePolicy.readOnly)
    }
}
