import XCTest
@testable import ElderlyAssistant

/// T-013 — the appliance helper's label presentation seam (FR-LCT-020,
/// NFR-LCT-012, R8): one caller-side resolver over the shared dictionary and
/// the shared store.
///
/// The three-case R8 regression test lives here:
///
///  - `testR8CaseOneADictionaryKnownLabelRendersExactlyAsBeforeTheSeam`
///  - `testR8CaseTwoACachePopulatedLabelRendersTheCachedTranslation`
///  - `testR8CaseThreeTheLocalizerWinsOverTheCacheWhenBothWouldAnswer`
///
/// Together they are the recorded delta: every label the helper *translates*
/// today renders identically; the one new outcome is a pass-through label the
/// live path already resolved rendering its cached translation.
final class ApplianceHelperLabelSeamTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    private var storage: LabelTranslationCacheTestStorage!
    private var bus: LiveTranslateSanitisingBus!

    override func setUp() {
        super.setUp()
        storage = LabelTranslationCacheTestStorage()
        bus = LiveTranslateSanitisingBus()
    }

    private func makeCache() -> LabelTranslationCache {
        LabelTranslationCache(storage: storage,
                              observabilityBus: bus,
                              dictionary: ApplianceLabelLocalizer.dictionary)
    }

    /// A persisted entry, seeded the way the live path's tier-2 completion
    /// would have left it (the helper itself never writes).
    private func seedPersisted(label: String,
                               translation: String,
                               tier: TranslationTier? = nil) {
        var entries: [LabelTranslationCache.Entry] = []
        if let data = storage.bytes(forKey: LabelTranslationCache.storageKey),
           let payload = try? JSONDecoder().decode(LabelTranslationCache.Persisted.self, from: data) {
            entries = payload.entries
        }
        entries.append(LabelTranslationCache.Entry(
            key: LabelTranslationCache.normalizationKey(text: label, targetLanguage: .nepali),
            translation: translation,
            lastAccessSequence: entries.count + 1,
            tierToken: tier?.rawValue))
        let payload = LabelTranslationCache.Persisted(
            schemaVersion: LabelTranslationCache.Persisted.currentSchemaVersion,
            entries: entries)
        guard let data = try? JSONEncoder().encode(payload) else {
            return XCTFail("could not seed the store payload")
        }
        storage.setRaw(data, forKey: LabelTranslationCache.storageKey)
    }

    private func resolve(_ label: String,
                         locale: Locale? = nil,
                         cache: LabelTranslationCache?) -> ApplianceLabelResolver.Resolution {
        ApplianceLabelResolver.resolve(label: label,
                                       locale: locale ?? nepali,
                                       cache: cache)
    }

    // MARK: - R8, case one: a translated label renders exactly as before

    func testR8CaseOneADictionaryKnownLabelRendersExactlyAsBeforeTheSeam() {
        let cache = makeCache()
        for label in ["Start", "  Stop  ", "POWER", "keep warm", "Wash"] {
            let shipped = ApplianceLabelLocalizer.display(for: label, locale: nepali)
            let throughSeam = resolve(label, cache: cache).display
            XCTAssertEqual(throughSeam, shipped,
                           "'\(label)' must render byte-for-byte what the shipped localizer renders")
            XCTAssertEqual(throughSeam.secondary,
                           label.trimmingCharacters(in: .whitespacesAndNewlines),
                           "a translated label keeps its printed English reference line")
        }
        XCTAssertEqual(resolve("Start", cache: cache).display.primary, "सुरु गर्ने")
        XCTAssertEqual(resolve("Start", cache: cache).display.secondary, "Start")
    }

    // MARK: - R8, case two: the one recorded delta

    func testR8CaseTwoACachePopulatedLabelRendersTheCachedTranslation() {
        // A label the localizer passes through (it is not curated), resolved
        // by the live path earlier in the session.
        seedPersisted(label: "Delayed Start", translation: "ढिलो सुरु")
        let cache = makeCache()

        // Nothing changes without a cache: the shipped pass-through stands.
        let withoutCache = ApplianceLabelLocalizer.display(for: "Delayed Start", locale: nepali)
        XCTAssertEqual(withoutCache.primary, "Delayed Start")
        XCTAssertNil(withoutCache.secondary)

        let resolution = resolve("Delayed Start", cache: cache)
        XCTAssertEqual(resolution.display.primary, "ढिलो सुरु",
                       "the delta R8 records: a pass-through label with a persisted entry "
                       + "now renders that translation")
        XCTAssertEqual(resolution.display.secondary, "Delayed Start",
                       "the printed English stays as the reference line, exactly as for a "
                       + "curated label")
        XCTAssertEqual(resolution.origin, .persistedLayer)
        XCTAssertEqual(resolution.tier, .cloud)
    }

    /// …and for **any** persisted entry, not only a cloud-produced one. The
    /// seam's guard asks whether the cache layer answered, while `Origin` now
    /// carries *which tier* produced the answer: comparing the whole origin
    /// against the cloud-default value is the easy mistake, and it would make
    /// every on-device answer invisible to the helper — the same label
    /// rendering untranslated while the store holds its translation. The tier
    /// travels through unchanged (FR-LCT-008).
    func testABrainProducedEntryIsStillServedByTheSeam() {
        seedPersisted(label: "Delayed Start", translation: "ढिलो सुरु", tier: .onDeviceBrain)
        let cache = makeCache()

        let resolution = resolve("Delayed Start", cache: cache)

        XCTAssertEqual(resolution.display.primary, "ढिलो सुरु",
                       "an on-device answer is a persisted answer to this seam")
        XCTAssertEqual(resolution.display.secondary, "Delayed Start",
                       "the printed English stays as the reference line")
        XCTAssertTrue(resolution.origin?.isPersistedLayer == true)
        XCTAssertEqual(resolution.tier, .onDeviceBrain,
                       "the answer is attributed to the tier that produced it, not to cloud")
    }

    // MARK: - R8, case three: precedence

    func testR8CaseThreeTheLocalizerWinsOverTheCacheWhenBothWouldAnswer() {
        // Both layers can answer for this label: the curated table has it, and
        // a persisted entry for the same key exists (seeded, as a
        // pre-extension store could have left it).
        seedPersisted(label: "Start", translation: "बोगस")
        let cache = makeCache()
        XCTAssertEqual(storage.bytes(forKey: LabelTranslationCache.storageKey)?.isEmpty, false)

        let resolution = resolve("Start", cache: cache)
        XCTAssertEqual(resolution.display.primary, "सुरु गर्ने",
                       "the localizer's own result is used; the cache never overrides a "
                       + "translation the localizer produces")
        XCTAssertEqual(resolution.origin, .curatedDictionary)
        XCTAssertEqual(resolution.tier, .dictionary)
        XCTAssertEqual(resolution.display,
                       ApplianceLabelLocalizer.display(for: "Start", locale: nepali))
    }

    // MARK: - The same label, both surfaces

    func testTheSameLabelResolvesIdenticallyOnBothSurfaces() {
        let cache = makeCache()
        let helpers = resolve("keep warm", cache: cache)
        guard case .success(.some(let live)) = cache.lookup(text: "keep warm") else {
            return XCTFail("the live path must resolve the same label")
        }
        XCTAssertEqual(helpers.display.primary, live.translation)
        XCTAssertEqual(helpers.tier, live.tier)
        XCTAssertEqual(helpers.origin, live.origin)

        // And the same for a persisted label resolved through the seam.
        seedPersisted(label: "Delayed Start", translation: "ढिलो सुरु")
        let persistedCache = makeCache()
        let helperHit = resolve("delayed   start", cache: persistedCache)
        XCTAssertEqual(helperHit.display.primary, "ढिलो सुरु")
        guard case .success(.some(let liveHit)) = persistedCache.lookup(text: "Delayed Start") else {
            return XCTFail("the live path must resolve the persisted label")
        }
        XCTAssertEqual(helperHit.display.primary, liveHit.translation)
        XCTAssertEqual(helperHit.tier, liveHit.tier)
    }

    func testAHelperResolvedLabelIsACacheHitForTheLivePathWithNoCloudRequest() {
        seedPersisted(label: "Delayed Start", translation: "ढिलो सुरु")
        let cache = makeCache()
        let hitsBefore = bus.events(named: "cache_hit").count

        let helperResolution = resolve("Delayed Start", cache: cache)
        XCTAssertEqual(helperResolution.display.primary, "ढिलो सुरु")
        let missesAfterHelper = bus.events(named: "cache_miss").count

        // The live path resolving the same key is served from the persisted
        // layer — a hit, which is what "no cloud request" means at this seam:
        // the tier-2 requester is never reached, for a string already known.
        guard case .success(.some(let live)) = cache.lookup(text: "Delayed Start") else {
            return XCTFail("the live path must be served from the shared store")
        }
        XCTAssertEqual(live.origin, .persistedLayer)
        XCTAssertGreaterThan(bus.events(named: "cache_hit").count, hitsBefore)
        XCTAssertEqual(bus.events(named: "cache_miss").count, missesAfterHelper,
                       "no miss was recorded for a label the shared store holds")

        // The helper path itself has no network dependency to make a request
        // with, and it never writes.
        XCTAssertTrue(bus.events(named: "translation_batch_requested").isEmpty,
                      "no translation batch was requested for a label the store already holds")
        let resolverSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/Appliance/ApplianceLabelResolver.swift"))
        for symbol in ["URLSession", "URLRequest", "GeminiClient", "translate(", "URLComponents"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: symbol), in: resolverSource),
                         "\(symbol) would give the helper a cloud path it must not have")
        }
        // The helper stores no entry: the payload's entries are the ones that
        // were already there. (A lookup may move the LRU counter — that is
        // the cache's own bookkeeping, coalesced to one write per key per
        // session, and it is not the helper adding anything.)
        let payload = storage.bytes(forKey: LabelTranslationCache.storageKey)
            .flatMap { try? JSONDecoder().decode(LabelTranslationCache.Persisted.self, from: $0) }
        XCTAssertEqual(payload?.entries.map(\.translation), ["ढिलो सुरु"])
        XCTAssertNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: "cache.store("), in: resolverSource),
                     "the seam must never write a translation")
    }

    // MARK: - The seam's scope: shared data, not shared policy

    func testTheHelperDoesNotAugmentOutsideTheShippedGates() {
        seedPersisted(label: "Delayed Start", translation: "ढिलो सुरु")
        let cache = makeCache()

        // English UI: verbatim, exactly as shipped.
        XCTAssertEqual(resolve("Delayed Start", locale: english, cache: cache).display.primary,
                       "Delayed Start")
        XCTAssertNil(resolve("Delayed Start", locale: english, cache: cache).origin)

        // Already Devanagari: never re-translated, even with a cache present.
        XCTAssertEqual(resolve("ढिलो सुरु", cache: cache).display.primary, "ढिलो सुरु")
        XCTAssertNil(resolve("ढिलो सुरु", cache: cache).origin)

        // Empty label: untouched.
        XCTAssertEqual(resolve("   ", cache: cache).display.primary, "   ")

        // No cache wired (every shipped call site that has not changed): the
        // shipped behaviour, unchanged.
        XCTAssertEqual(resolve("Delayed Start", cache: nil).display.primary, "Delayed Start")
        XCTAssertNil(resolve("Delayed Start", cache: nil).origin)
    }

    func testThereIsExactlyOneStoreAndOneDictionaryAcrossTheSurfaces() {
        let ios = FeatureSourceScan.iosDirectory()
        let allSources = FeatureSourceScan.swiftFiles(in: "ElderlyAssistant/Services")

        let cacheDeclarations = allSources.filter {
            FeatureSourceScan.codeText(of: $0).contains("final class LabelTranslationCache")
        }
        XCTAssertEqual(cacheDeclarations.map { FeatureSourceScan.relativePath(of: $0) },
                       ["ElderlyAssistant/Services/LiveTranslate/LabelTranslationCache.swift"],
                       "exactly one translation store implementation")

        let dictionaries = allSources.filter {
            FeatureSourceScan.codeText(of: $0)
                .contains("static let dictionary: [String: String]")
        }
        XCTAssertEqual(dictionaries.map { FeatureSourceScan.relativePath(of: $0) },
                       ["ElderlyAssistant/Services/Appliance/ApplianceLabelLocalizer.swift"],
                       "exactly one curated EN→NE table, read by both surfaces")

        // The seam's own file holds no state and no second location: it reads
        // the shared store and returns a value.
        let resolver = FeatureSourceScan.codeText(
            of: ios.appendingPathComponent("ElderlyAssistant/Services/Appliance/ApplianceLabelResolver.swift"))
        for symbol in ["storage.write", "write(key:", "UserDefaults", "FileManager",
                       "LabelTranslationCache(", "static var"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: symbol), in: resolver),
                         "\(symbol) in the resolver would be a private store or shared mutable state")
        }

        // The presentation view writes no translation data anywhere: it has no
        // storage dependency at all.
        let view = FeatureSourceScan.codeText(
            of: ios.appendingPathComponent("ElderlyAssistant/Services/Appliance/ApplianceHelperView.swift"))
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "storage\\.write", in: view))
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "UserDefaults", in: view))
    }

    func testTheHelperIsNotExposedToTheLivePathsConsentState() {
        // Structural: the seam has no consent input, so there is no consent
        // state it could consult — the helper's behaviour is identical in the
        // absence, denial or unreadability of a live-path record.
        let resolver = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/Appliance/ApplianceLabelResolver.swift"))
        for symbol in ["consent", "Consent", "disclosureVersion", "LiveTranslateError"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: symbol), in: resolver),
                         "\(symbol) would couple the helper to the live path's consent policy")
        }
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "static func resolve\\(label: String,",
                                                     in: resolver),
                        "the resolver's inputs are the label, the active locale and the shared store")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: "cache: LabelTranslationCache?) -> Resolution"),
            in: resolver),
                        "the shared store is the only store the seam can reach")

        // Behavioural: the helper resolves the same way whatever the store
        // says — an absent payload, an unreadable one, or no store at all.
        seedPersisted(label: "Delayed Start", translation: "ढिलो सुरु")
        let populated = resolve("Delayed Start", cache: makeCache())
        let absent = resolve("Delayed Start", cache: makeCache())
        storage.setRaw(Data("corrupt".utf8), forKey: LabelTranslationCache.storageKey)
        let unreadableStore = resolve("Delayed Start", cache: makeCache())
        XCTAssertEqual(populated.display.primary, "ढिलो सुरु")
        XCTAssertEqual(absent.display.primary, "ढिलो सुरु")
        XCTAssertEqual(unreadableStore.display.primary, "Delayed Start",
                       "a broken store leaves the shipped pass-through standing — and that is "
                       + "the whole of the helper's failure behaviour")

        // A curated label resolves identically in every one of those states.
        for cache in [makeCache(), makeCache()] {
            XCTAssertEqual(resolve("Start", cache: cache).display.primary, "सुरु गर्ने")
        }
        XCTAssertEqual(resolve("Start", cache: nil).display.primary, "सुरु गर्ने")
    }

    // MARK: - The presentation path itself

    func testThePresentationViewResolvesThroughTheSeamAndDefaultsToTheShippedBehaviour() {
        // The view's seam is wired: its label resolution goes through the
        // resolver (the presentation path, not a parallel implementation).
        let view = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/Appliance/ApplianceHelperView.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "\\.resolve\\(label: control.label, locale: locale, cache: labelCache\\)", in: view),
                        "the helper's label section must resolve through the shared seam")
        XCTAssertNil(FeatureSourceScan.firstMatch(
            of: "ApplianceLabelLocalizer\\.display\\(for: control.label", in: view),
                     "the direct localizer call at the seam was the thing being replaced")

        // The plugin hands the shared store to the presented view, and both
        // initialisers still accept a plugin built without one.
        let plugin = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/Plugins/ApplianceHelperPlugin.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "init\\(storage: EncryptedLocalStorage, labelCache: LabelTranslationCache\\? = nil\\)",
            in: plugin))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "ApplianceHelperView\\(session: session, labelCache: labelCache\\)", in: plugin))

        // And the composition root builds exactly one shared instance and
        // hands it to the plugin and to both presentation sites.
        let coordinator = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "self\\.labelTranslationCache = LabelTranslationCache\\(", in: coordinator),
                        "the shared store is built once, in the app's composition root")
    }
}
