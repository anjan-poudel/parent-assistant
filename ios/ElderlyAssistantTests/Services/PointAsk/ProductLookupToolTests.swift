import XCTest
@testable import ElderlyAssistant

/// [POINT-TAP-ASK] (2026-09-19) Open Food Facts lookup contract (pure
/// seams + stub transport — no network):
///  - the request URL is exactly the OFF v2 product endpoint with the
///    barcode embedded in the path — no key, no query, no per-user
///    state;
///  - the food-shape gate admits only 8/12/13/14-ASCII-digit payloads
///    (EAN-8 / UPC-A / EAN-13 / GTIN-14) and trims surrounding
///    whitespace;
///  - parsing maps the real wire shape to honest verdicts — found
///    records, `status: 0`/blank records → notFound, undecodable →
///    malformed — with category hints capped and tags-prefix stripped;
///  - `lookup` distinguishes notFound / noNetwork / malformed /
///    rateLimited, and the courtesy throttle engages BEFORE any network
///    work;
///  - the throttle allows exactly 15 attempts per sliding minute.
final class ProductLookupToolTests: XCTestCase {

    // MARK: - URL shape

    func testSourceConstantIsOpenFoodFacts() {
        XCTAssertEqual(ProductLookupTool.source, "openfoodfacts.org")
    }

    func testRequestURLTargetsOffV2ProductEndpoint() {
        let url = ProductLookupTool.requestURL(barcode: "3017620422003")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "world.openfoodfacts.org")
        XCTAssertEqual(components?.path, "/api/v2/product/3017620422003.json")
        XCTAssertNil(components?.queryItems,
                     "a barcode lookup carries no key and no query — nothing but the code")
    }

    func testMakeRequestCarriesIdentificationAndTimeout() {
        let request = ProductLookupTool.makeRequest(barcode: "3017620422003")

        XCTAssertEqual(request.url, ProductLookupTool.requestURL(barcode: "3017620422003"))
        XCTAssertEqual(request.timeoutInterval, ProductLookupTool.fetchTimeoutSeconds)
        // OFF's fair-use policy asks clients to identify themselves.
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ProductLookupTool.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: - Food-shape gate

    func testFoodGateAcceptsFoodBarcodeLengths() {
        XCTAssertTrue(ProductLookupTool.isFoodBarcode("3017620422003"), "EAN-13")
        XCTAssertTrue(ProductLookupTool.isFoodBarcode("036000291452"), "UPC-A (12)")
        XCTAssertTrue(ProductLookupTool.isFoodBarcode("12345670"), "EAN-8")
        XCTAssertTrue(ProductLookupTool.isFoodBarcode("12345678901234"), "GTIN-14")
    }

    func testFoodGateRejectsWrongLengths() {
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("1234567"), "7 digits")
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("12345678901"), "11 digits")
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("123456789012345"), "15 digits")
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("1234567890123456"), "16 digits")
    }

    func testFoodGateRejectsNonBarcodePayloads() {
        // A QR payload (URL, coupon text) must never leave the device.
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("https://example.com/recipe"))
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("HELLO1234567"))
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("301-7620-422003"), "formatted, not raw")
        // Devanagari digits are NOT ASCII — never a scannable EAN.
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("३०१७६२०४२२००३"))
        XCTAssertFalse(ProductLookupTool.isFoodBarcode(""))
        XCTAssertFalse(ProductLookupTool.isFoodBarcode("   \n  "))
    }

    func testFoodGateTrimsSurroundingWhitespace() {
        XCTAssertTrue(ProductLookupTool.isFoodBarcode(" 3017620422003 "))
        XCTAssertTrue(ProductLookupTool.isFoodBarcode("\n8901063010013\t"))
    }

    // MARK: - Parsing

    func testParseHappyPathDecodesProductInfo() {
        let data = Data("""
        {"code":"3017620422003","status":1,
         "product":{"product_name":"Nutella","brands":"Ferrero",
                    "categories":"Breakfasts, Spreads"}}
        """.utf8)

        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: data, barcode: "3017620422003"),
                       .product(ProductLookupTool.ProductInfo(
                           barcode: "3017620422003",
                           name: "Nutella",
                           brands: "Ferrero",
                           categoryHints: ["Breakfasts", "Spreads"])))
    }

    func testParseFallsBackToCategoryTagsWithPrefixStripped() {
        let data = Data("""
        {"code":"3017620422003","status":1,
         "product":{"product_name":"Nutella","brands":"Ferrero",
                    "categories_tags":["en:breakfasts","en:spreads","en:sweet-spreads"]}}
        """.utf8)

        let result = ProductLookupTool.parseProductResponse(data: data, barcode: "3017620422003")
        XCTAssertEqual(result, .product(ProductLookupTool.ProductInfo(
            barcode: "3017620422003", name: "Nutella", brands: "Ferrero",
            categoryHints: ["breakfasts", "spreads", "sweet-spreads"])))
    }

    func testParseCapsCategoryHintsAtThree() {
        let data = Data("""
        {"code":"3017620422003","status":1,
         "product":{"product_name":"Nutella","categories":"A, B, C, D, E"}}
        """.utf8)

        guard case .product(let info) =
            ProductLookupTool.parseProductResponse(data: data, barcode: "3017620422003") else {
            return XCTFail("expected a product")
        }
        XCTAssertEqual(info.categoryHints, ["A", "B", "C"])
    }

    func testParseToleratesMissingOptionalFields() {
        // OFF omits name/brands/categories per record; a record with any
        // ONE speakable field is still a usable product.
        let nameOnly = Data("""
        {"code":"x","status":1,"product":{"product_name":"Only a name"}}
        """.utf8)
        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: nameOnly, barcode: "x"),
                       .product(ProductLookupTool.ProductInfo(
                           barcode: "x", name: "Only a name", brands: nil,
                           categoryHints: [])))

        let brandsOnly = Data("""
        {"code":"x","status":1,"product":{"brands":"Ferrero"}}
        """.utf8)
        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: brandsOnly, barcode: "x"),
                       .product(ProductLookupTool.ProductInfo(
                           barcode: "x", name: nil, brands: "Ferrero",
                           categoryHints: [])))
    }

    func testParseMapsUnknownBarcodeStatusToNotFound() {
        // OFF's wire shape for an unknown barcode: HTTP 200, status 0,
        // no product key.
        let data = Data("""
        {"code":"9999999999999","status":0,"status_verbose":"product not found"}
        """.utf8)
        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: data, barcode: "9999999999999"),
                       .notFound)
    }

    func testParseMapsClaimedFoundWithoutProductToMalformed() {
        let data = Data(#"{"status":1,"status_verbose":"product found"}"#.utf8)
        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: data, barcode: "x"),
                       .malformed)
    }

    func testParseMapsBlankProductRecordToNotFound() {
        // A record with nothing speakable is the same honest outcome as
        // no record at all.
        let data = Data("""
        {"code":"x","status":1,
         "product":{"product_name":"","brands":"  ","categories":""}}
        """.utf8)
        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: data, barcode: "x"),
                       .notFound)
    }

    func testParseReturnsMalformedForNonJSONAndEmptyPayloads() {
        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: Data("not json".utf8),
                                                              barcode: "x"),
                       .malformed)
        XCTAssertEqual(ProductLookupTool.parseProductResponse(data: Data(), barcode: "x"),
                       .malformed)
        // Product key present but not an object.
        XCTAssertEqual(ProductLookupTool.parseProductResponse(
                           data: Data(#"{"status":1,"product":"oops"}"#.utf8), barcode: "x"),
                       .malformed)
    }

    // MARK: - Lookup (stub transport)

    private var transport: FakeProductLookupTransport!

    override func setUp() {
        super.setUp()
        transport = FakeProductLookupTransport()
    }

    func testLookupFoundPath() async {
        let data = Data("""
        {"code":"3017620422003","status":1,
         "product":{"product_name":"Nutella","brands":"Ferrero","categories":"Breakfasts"}}
        """.utf8)
        transport.nextResult = .success(FakeProductLookupTransport.response(data: data,
                                                                             statusCode: 200))

        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport)
        XCTAssertEqual(outcome, .found(ProductLookupTool.ProductInfo(
            barcode: "3017620422003", name: "Nutella", brands: "Ferrero",
            categoryHints: ["Breakfasts"])))
        // And the request that went out is exactly the built one.
        XCTAssertEqual(transport.lastRequest?.url,
                       ProductLookupTool.requestURL(barcode: "3017620422003"))
    }

    func testLookupHTTP404IsNotFound() async {
        transport.nextResult = .success(FakeProductLookupTransport.response(data: Data(),
                                                                             statusCode: 404))
        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport)
        XCTAssertEqual(outcome, .notFound)
    }

    func testLookupStatusZeroIsNotFound() async {
        let data = Data(#"{"status":0,"status_verbose":"product not found"}"#.utf8)
        transport.nextResult = .success(FakeProductLookupTransport.response(data: data,
                                                                             statusCode: 200))
        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport)
        XCTAssertEqual(outcome, .notFound)
    }

    func testLookupNon200StatusIsMalformed() async {
        transport.nextResult = .success(FakeProductLookupTransport.response(data: Data(),
                                                                             statusCode: 500))
        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport)
        XCTAssertEqual(outcome, .malformed)
    }

    func testLookupGarbagePayloadIsMalformed() async {
        transport.nextResult = .success(FakeProductLookupTransport.response(
            data: Data("not json".utf8), statusCode: 200))
        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport)
        XCTAssertEqual(outcome, .malformed)
    }

    func testLookupTransportFailureIsNoNetwork() async {
        transport.nextResult = .failure(URLError(.notConnectedToInternet))
        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport)
        XCTAssertEqual(outcome, .noNetwork)
    }

    func testLookupNonHTTPResponseIsNoNetwork() async {
        let response = URLResponse(url: URL(string: "https://world.openfoodfacts.org")!,
                                   mimeType: nil, expectedContentLength: 0,
                                   textEncodingName: nil)
        transport.nextResult = .success((Data(), response))
        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport)
        XCTAssertEqual(outcome, .noNetwork)
    }

    // MARK: - Courtesy throttle

    func testThrottleAllowsFifteenThenDenies() {
        let current = Date(timeIntervalSince1970: 1_700_000_000)
        let throttle = CourtesyThrottle(now: { current })

        for attempt in 1...ProductLookupTool.courtesyLimitPerMinute {
            XCTAssertTrue(throttle.allowsAttempt(), "attempt \(attempt) must be allowed")
        }
        XCTAssertFalse(throttle.allowsAttempt(), "the 16th attempt must be denied")
    }

    func testThrottleWindowSlidesAfterAMinute() {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        let throttle = CourtesyThrottle(now: { current })
        for _ in 0..<ProductLookupTool.courtesyLimitPerMinute {
            _ = throttle.allowsAttempt()
        }

        current = current.addingTimeInterval(61)
        XCTAssertTrue(throttle.allowsAttempt(), "a full minute later the window is fresh")
    }

    func testThrottlePrunesOldAttemptsWhenTheWindowSlides() {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        let throttle = CourtesyThrottle(now: { current })
        for _ in 0..<10 { _ = throttle.allowsAttempt() }

        current = current.addingTimeInterval(59)
        for _ in 0..<5 {
            XCTAssertTrue(throttle.allowsAttempt(), "15 total — the window is not full")
        }
        XCTAssertFalse(throttle.allowsAttempt(), "16th within the window is denied")

        // Now both batches (t0 and t0+59) are older than 60 s — the
        // window is empty again.
        current = current.addingTimeInterval(61)
        XCTAssertTrue(throttle.allowsAttempt())
    }

    func testThrottleResetClearsAllAttempts() {
        let current = Date(timeIntervalSince1970: 1_700_000_000)
        let throttle = CourtesyThrottle(now: { current })
        for _ in 0..<ProductLookupTool.courtesyLimitPerMinute {
            _ = throttle.allowsAttempt()
        }
        XCTAssertFalse(throttle.allowsAttempt())

        throttle.reset()
        XCTAssertTrue(throttle.allowsAttempt(), "a reset opens a fresh window")
    }

    func testLookupThrottledDoesNotTouchTheNetwork() async {
        let current = Date(timeIntervalSince1970: 1_700_000_000)
        let throttle = CourtesyThrottle(now: { current })
        for _ in 0..<ProductLookupTool.courtesyLimitPerMinute {
            _ = throttle.allowsAttempt()
        }

        let outcome = await ProductLookupTool.lookup(barcode: "3017620422003",
                                                     transport: transport,
                                                     throttle: throttle)
        XCTAssertEqual(outcome, .rateLimited)
        XCTAssertEqual(transport.fetchCount, 0,
                       "a throttled lookup must never reach the transport")
        XCTAssertNil(transport.lastRequest)
    }
}

/// Fake `LocalToolTransport` — lets tests control the OFF response/error
/// without touching the network. Same shape as `FakeGeminiTransport`.
final class FakeProductLookupTransport: LocalToolTransport {
    var nextResult: Result<(Data, URLResponse), Error>!
    private(set) var lastRequest: URLRequest?
    private(set) var fetchCount = 0

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        fetchCount += 1
        switch nextResult! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    static func response(data: Data, statusCode: Int) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: URL(string: "https://world.openfoodfacts.org")!,
                                       statusCode: statusCode, httpVersion: nil,
                                       headerFields: nil)!
        return (data, response)
    }
}
