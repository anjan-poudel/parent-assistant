import XCTest
@testable import ElderlyAssistant

/// [FOCUS-CAPTURE] The focused read's in-memory answers: the same tap twice
/// costs one translation, and pointing at a letter puts nothing on disk.
///
/// The suite is written against the three rules the type's own doc states, in
/// the order a read meets them:
///
///  1. **The TTL is checked on read, not on a timer.** A test drives the clock
///     rather than sleeping, which is the whole reason the clock is injected —
///     and the stale entry is *removed* by the read that found it, so the bound
///     is also a bound on what the cache holds.
///  2. **The cost bound is in characters**, both halves of the pair: the source
///     the elder would be re-asking about and the translation they would be
///     shown again.
///  3. **Eviction is the platform's.** Nothing here counts entries or reports a
///     hit rate, because `NSCache` may drop anything at any time. So this suite
///     never asserts a count over a *bound* — only over what one key answers.
final class LiveTranslateMemoryCacheTests: XCTestCase {

    /// A clock the test moves by hand: the injected `now` seam exists so the
    /// TTL can be tested without sleeping for ten minutes.
    private final class TestClock {
        var now: Date

        init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.now = now
        }

        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeCache(ttl: TimeInterval = LiveTranslateConfig.default.memoryCacheTTLSeconds,
                           maxCost: Int = LiveTranslateConfig.default.memoryCacheMaxCost,
                           clock: TestClock) -> LiveTranslateMemoryCache {
        var config = LiveTranslateConfig.default
        config.memoryCacheTTLSeconds = ttl
        config.memoryCacheMaxCost = maxCost
        return LiveTranslateMemoryCache(config: config, now: { clock.now })
    }

    private func resolved(_ original: String, _ translation: String) -> TranslationResult {
        .resolved(originalText: original, translation: translation, tier: .dictionary)
    }

    // MARK: - The round trip

    func testAnAnswerStoredUnderAKeyComesBackForIt() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        let hit = await cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testAKeyNobodyStoredAnswersNothing() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        let miss = await cache.lookup("light|ne")
        XCTAssertNil(miss)
    }

    func testAnEmptyKeyIsRefusedOnBothSides() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        // Stored under "" and asked for as "" — the two would otherwise agree
        // with each other about a key no caller can legitimately form.
        await cache.store(resolved("Light", "बत्ती"), forKey: "")

        let miss = await cache.lookup("")
        XCTAssertNil(miss)
    }

    func testAStoredKeyIsCaseAndSeparatorSensitiveLikeThePersistedCache() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        // The cache is keyed by whatever the caller passes; the key *derivation*
        // is `LabelTranslationCache.normalizationKey` and is not duplicated
        // here. A second derivation would be a second source of truth.
        let miss = await cache.lookup("Light|ne")
        XCTAssertNil(miss)
    }

    // MARK: - The TTL

    func testAnAnswerInsideTheTTLIsStillAnswered() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(599)

        let hit = await cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testAnAnswerAtTheTTLBoundaryIsExpired() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(600)

        let miss = await cache.lookup("light|ne")
        XCTAssertNil(miss)
    }

    func testTheReadThatFoundAStaleAnswerIsTheOneThatDropsIt() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(601)
        _ = await cache.lookup("light|ne")
        // The clock is wound back: were the entry still there, it would be
        // inside the TTL again. A read-only expiry would answer it.
        clock.advance(-120)

        let miss = await cache.lookup("light|ne")
        XCTAssertNil(miss, "the stale entry must be removed, not merely skipped")
    }

    func testAClockThatWentBackwardsIsNotAnExpiry() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        // A device clock correction, not ten minutes of reading: only a
        // genuinely old entry is dropped.
        clock.advance(-5)

        let hit = await cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testEachEntryCarriesItsOwnInsertionMoment() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(400)
        await cache.store(resolved("Gate", "गेट"), forKey: "gate|ne")

        clock.advance(250) // light is stale at 650, gate is fresh at 250

        let light = await cache.lookup("light|ne")
        let gate = await cache.lookup("gate|ne")
        XCTAssertNil(light)
        XCTAssertEqual(gate, resolved("Gate", "गेट"))
    }

    // MARK: - Non-terminal answers

    func testAPendingAnswerIsStoredLikeAnyOtherWhenAStorerAsksForIt() async {
        // The *policy* of not storing pending answers belongs to the caller
        // (`LiveTranslateFocusCapture.remember`), which is the only thing that
        // knows which outcomes were terminal. This type stores what it is
        // given; a test that expected otherwise would be testing the caller
        // through the wrong type.
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        await cache.store(.pending("Light"), forKey: "light|ne")

        let hit = await cache.lookup("light|ne")
        XCTAssertEqual(hit, .pending("Light"))
    }

    func testADegradedAnswerRoundTripsWithItsReason() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        await cache.store(.degraded(originalText: "Light", reason: .noTierResolved), forKey: "light|ne")

        let hit = await cache.lookup("light|ne")
        XCTAssertEqual(hit, .degraded(originalText: "Light", reason: .noTierResolved))
    }

    // MARK: - Cost

    func testTheCostOfAnEntryIsBothHalvesOfThePair() {
        XCTAssertEqual(LiveTranslateMemoryCache.cost(of: resolved("Light", "Batti")), 10)
        XCTAssertEqual(LiveTranslateMemoryCache.cost(of: .pending("Light")), 10,
                       "a pending answer costs its own text twice: it is both halves")
    }

    func testTheCostCountsCharactersAndNotBytesOrScalars() {
        // `String.count` is the grapheme count, which is the unit every other
        // bound in this feature speaks (`String.prefix`, the sanitiser's
        // per-string bound). Counting UTF-16 units instead would bill a
        // Devanagari word at twice its length and evict the cache early.
        let result = resolved("Light", "बत्ती")
        let characters = "Light".count + "बत्ती".count
        XCTAssertEqual(LiveTranslateMemoryCache.cost(of: result), characters)
        XCTAssertLessThan(characters, "Light".count + "बत्ती".utf16.count)
    }

    func testACacheBuiltOverTheShippedCostBoundAnswers() async {
        let clock = TestClock()
        let cache = makeCache(maxCost: LiveTranslateConfig.default.memoryCacheMaxCost, clock: clock)

        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        let hit = await cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testANonsensicalCostBoundCannotMakeTheInitialiserTrap() async {
        // `totalCostLimit` is a hint and a negative bound is a caller's
        // mistake, not a crash: the initialiser clamps rather than trapping.
        let clock = TestClock()
        let cache = makeCache(maxCost: -1, clock: clock)

        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        // What such a cache holds is the platform's business — `NSCache` may
        // drop anything at any time — so this asserts only that the type
        // survives being built over it.
        _ = await cache.lookup("light|ne")
    }

    // MARK: - Clearing

    func testClearingDropsEveryAnswer() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)
        await cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")
        await cache.store(resolved("Gate", "गेट"), forKey: "gate|ne")

        await cache.clear()

        let light = await cache.lookup("light|ne")
        let gate = await cache.lookup("gate|ne")
        XCTAssertNil(light)
        XCTAssertNil(gate)
    }

    func testTheDefaultTTLAndBoundAreTheConfigsOwnValues() {
        XCTAssertEqual(LiveTranslateConfig.default.memoryCacheTTLSeconds, 600)
        XCTAssertEqual(LiveTranslateConfig.default.memoryCacheMaxCost, 512_000)
    }
}
