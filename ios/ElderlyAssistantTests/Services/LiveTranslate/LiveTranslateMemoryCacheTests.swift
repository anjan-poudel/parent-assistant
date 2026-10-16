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

        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        let hit = cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testAKeyNobodyStoredAnswersNothing() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        let miss = cache.lookup("light|ne")
        XCTAssertNil(miss)
    }

    func testAnEmptyKeyIsRefusedOnBothSides() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        // Stored under "" and asked for as "" — the two would otherwise agree
        // with each other about a key no caller can legitimately form.
        cache.store(resolved("Light", "बत्ती"), forKey: "")

        let miss = cache.lookup("")
        XCTAssertNil(miss)
    }

    func testAStoredKeyIsCaseAndSeparatorSensitiveLikeThePersistedCache() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        // The cache is keyed by whatever the caller passes; the key *derivation*
        // is `LabelTranslationCache.normalizationKey` and is not duplicated
        // here. A second derivation would be a second source of truth.
        let miss = cache.lookup("Light|ne")
        XCTAssertNil(miss)
    }

    // MARK: - The TTL

    func testAnAnswerInsideTheTTLIsStillAnswered() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(599)

        let hit = cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testAnAnswerAtTheTTLBoundaryIsExpired() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(600)

        let miss = cache.lookup("light|ne")
        XCTAssertNil(miss)
    }

    func testTheReadThatFoundAStaleAnswerIsTheOneThatDropsIt() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(601)
        _ = cache.lookup("light|ne")
        // The clock is wound back: were the entry still there, it would be
        // inside the TTL again. A read-only expiry would answer it.
        clock.advance(-120)

        let miss = cache.lookup("light|ne")
        XCTAssertNil(miss, "the stale entry must be removed, not merely skipped")
    }

    func testAClockThatWentBackwardsIsNotAnExpiry() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        // A device clock correction, not ten minutes of reading: only a
        // genuinely old entry is dropped.
        clock.advance(-5)

        let hit = cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testAReadDoesNotMoveTheExpiryItRead() async {
        // Review finding 8's other half: a lookup is a read, not a use. Were it
        // to re-arm the entry, a string the elder keeps pointing at — the
        // notice they are reading line by line — would never expire.
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(500)
        let inside = cache.lookup("light|ne")
        XCTAssertEqual(inside, resolved("Light", "बत्ती"))

        // At 600 s the entry is at the bound its own insertion set — not one
        // the read restarted.
        clock.advance(100)
        let miss = cache.lookup("light|ne")
        XCTAssertNil(miss, "the read must not have re-armed the entry")
    }

    func testEachEntryCarriesItsOwnInsertionMoment() async {
        let clock = TestClock()
        let cache = makeCache(ttl: 600, clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        clock.advance(400)
        cache.store(resolved("Gate", "गेट"), forKey: "gate|ne")

        clock.advance(250) // light is stale at 650, gate is fresh at 250

        let light = cache.lookup("light|ne")
        let gate = cache.lookup("gate|ne")
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

        cache.store(.pending("Light"), forKey: "light|ne")

        let hit = cache.lookup("light|ne")
        XCTAssertEqual(hit, .pending("Light"))
    }

    func testADegradedAnswerIsRefusedByTheStore() async {
        // Review finding 8. A failure is not an answer, and the TTL is ten
        // minutes: storing one made a transient outage look permanent — every
        // re-tap inside the window read the same failure back, and with the
        // read re-arming the entry each time, a string the elder kept pointing
        // at never expired at all. The type's rule is now that only terminal,
        // resolved answers are remembered.
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        cache.store(.degraded(originalText: "Light", reason: .noTierResolved),
                          forKey: "light|ne")

        let miss = cache.lookup("light|ne")
        XCTAssertNil(miss, "the next tap must be allowed to ask again")
    }

    func testADegradedAnswerCannotDisplaceAResolvedOne() async {
        // The refusal is a policy about *what* is stored, so it also protects
        // the entry already there: a string that resolved on a previous tap is
        // not overwritten by a later failure for the same string.
        let clock = TestClock()
        let cache = makeCache(clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        cache.store(.degraded(originalText: "Light", reason: .noTierResolved),
                          forKey: "light|ne")

        let hit = cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
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

        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        let hit = cache.lookup("light|ne")
        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }

    func testANonsensicalCostBoundCannotMakeTheInitialiserTrap() async {
        // `totalCostLimit` is a hint and a negative bound is a caller's
        // mistake, not a crash: the initialiser clamps rather than trapping.
        let clock = TestClock()
        let cache = makeCache(maxCost: -1, clock: clock)

        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")

        // What such a cache holds is the platform's business — `NSCache` may
        // drop anything at any time — so this asserts only that the type
        // survives being built over it.
        _ = cache.lookup("light|ne")
    }

    // MARK: - Clearing

    func testClearingDropsEveryAnswer() async {
        let clock = TestClock()
        let cache = makeCache(clock: clock)
        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")
        cache.store(resolved("Gate", "गेट"), forKey: "gate|ne")

        cache.clear()

        let light = cache.lookup("light|ne")
        let gate = cache.lookup("gate|ne")
        XCTAssertNil(light)
        XCTAssertNil(gate)
    }

    func testTheDefaultTTLAndBoundAreTheConfigsOwnValues() {
        XCTAssertEqual(LiveTranslateConfig.default.memoryCacheTTLSeconds, 600)
        XCTAssertEqual(LiveTranslateConfig.default.memoryCacheMaxCost, 512_000)
    }

    // MARK: - The live cycle's constraint

    /// **Not `async`, and that is the assertion.** The live cycle reads this
    /// layer *inside* its resolution pass and fills it between `apply` and
    /// `publish` — both points sit in a stretch the pipeline's own scenario
    /// tests pin to the publication. Every `await` there is a place another
    /// task can land: as an `actor`, each read and each store was a suspension
    /// in the middle of a cycle, and a plan task could publish out of order
    /// there. That is what the first gate run on this branch measured — eight
    /// reds, every one of them a publication count off by one or a region
    /// settled a cycle early, all eight gone when the three call sites were
    /// stubbed out, none of them about what the cache answered.
    ///
    /// Written without `async` so the constraint is enforced by the compiler
    /// rather than left to a review: declaring the type as an `actor` again, or
    /// adding an `await` to either call in the pipeline, stops this test
    /// compiling — which is the only kind of regression test a suspension point
    /// can have.
    func testTheLiveCycleCanReadAndWriteItWithoutSuspending() {
        let clock = TestClock()
        let cache = makeCache(clock: clock)

        cache.store(resolved("Light", "बत्ती"), forKey: "light|ne")
        let hit = cache.lookup("light|ne")

        XCTAssertEqual(hit, resolved("Light", "बत्ती"))
    }
}
