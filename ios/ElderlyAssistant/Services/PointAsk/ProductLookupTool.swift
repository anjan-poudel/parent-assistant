import Foundation

/// [POINT-TAP-ASK] (2026-09-19) Open Food Facts product lookup for the
/// point-tap-ask pipeline (Phase 2 standalone slice). Given a food-shaped
/// barcode from `PointAskBarcodeReader`, answers "what IS this thing"
/// from Open Food Facts' free, keyless public API — the provenance
/// behind a point-tap-ask answer about a packaged product.
///
/// House pattern: a caseless enum of pure statics (`SearchTool`,
/// `WeatherTool`) with a transport seam (`LocalToolTransport`) so tests
/// never touch the network — URL shape and JSON parsing are the tested
/// seams.
///
/// Honesty contract:
///  - LIVE data only from OFF (`world.openfoodfacts.org`), and every
///    spoken answer must carry the `source` line ("openfoodfacts.org")
///    so the answer is attributable, never impersonated.
///  - Distinct outcomes per distinct fact: `found` (a real record),
///    `notFound` (OFF answered: no such barcode — HTTP 404 or `status:0`),
///    `noNetwork` (transport failure — the device never heard back),
///    `malformed` (answered but unusable), `rateLimited` (the courtesy
///    throttle said wait). A blank product record reads as `notFound` —
///    a record with nothing speakable is the same honest outcome as no
///    record.
///  - NO key, NO per-user state: the request is just the barcode. The
///    barcode leaves the device to OFF — that is exactly why
///    `isFoodBarcode` gates the request to genuine product codes, never
///    arbitrary QR payloads.
///  - A ~15/min courtesy throttle keeps this household far inside OFF's
///    published fair-use guidance (100 req/min) — this app must never be
///    the neighbour that got a public API rate-limited.
///
/// The caller (Phase 1's pipeline) gates with `isFoodBarcode` BEFORE
/// calling `lookup`; `lookup` itself trusts its barcode argument, exactly
/// like `WeatherTool.fetchCurrent` trusts its coordinates.
enum ProductLookupTool {

    /// The attribution line every spoken answer must carry.
    static let source = "openfoodfacts.org"

    /// Round-trip budget for the lookup. Mirrors `WeatherTool`'s 8 s:
    /// long enough for a mobile link, short enough to not feel hung.
    static let fetchTimeoutSeconds: TimeInterval = 8

    /// OFF asks clients to identify themselves in the User-Agent (their
    /// fair-use policy), so every request carries this constant.
    static let userAgent = "ElderlyAssistant/1.0 (point-tap-ask; elderly-assistant iOS app)"

    /// Courtesy cap: 15 lookups per sliding minute. Deliberately ~7x
    /// below OFF's published 100/min guidance.
    static let courtesyLimitPerMinute = 15

    /// Max category hints kept per product — hints are for a short spoken
    /// reply, not a catalog dump.
    static let maxCategoryHints = 3

    // MARK: - Product info

    /// One OFF product record, reduced to what a spoken answer needs.
    /// `name`/`brands` are optional (OFF omits them constantly);
    /// `categoryHints` is capped at `maxCategoryHints`.
    struct ProductInfo: Equatable {
        /// The barcode this record was looked up by (provenance key).
        let barcode: String
        let name: String?
        let brands: String?
        let categoryHints: [String]
    }

    /// The honest outcome of a lookup. Every case is a distinct fact for
    /// the pipeline to map onto speech — never a catch-all.
    enum LookupOutcome: Equatable {
        case found(ProductInfo)
        /// OFF answered: no such barcode (HTTP 404 or `status: 0`).
        case notFound
        /// The transport failed — the device never heard back.
        case noNetwork
        /// OFF answered, but not in a usable shape (non-200 ≠ 404, or
        /// undecodable).
        case malformed
        /// The courtesy throttle engaged — try again in a moment.
        case rateLimited
    }

    /// Pure parse verdict — the seam `parseProductResponse` returns so
    /// the tests pin the wire-shape mapping without a network.
    enum ParseResult: Equatable {
        case product(ProductInfo)
        /// Explicit "product not found" (`status: 0`) or a record with
        /// nothing speakable in it.
        case notFound
        case malformed
    }

    // MARK: - URL

    /// OFF API v2 product endpoint for one barcode. Pure URL
    /// construction — the unit tests assert the exact shape. No key, no
    /// query: a product lookup carries nothing but the code.
    static func requestURL(barcode: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "world.openfoodfacts.org"
        components.path = "/api/v2/product/\(barcode).json"
        return components.url!
    }

    /// Builds the request the transport sends: the pure URL plus the
    /// OFF identification header and the timeout. Pure — no session.
    static func makeRequest(barcode: String) -> URLRequest {
        var request = URLRequest(url: requestURL(barcode: barcode))
        request.timeoutInterval = fetchTimeoutSeconds
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Food-shape gate

    /// The barcode lengths OFF actually indexes: EAN-8 (8), UPC-A (12),
    /// EAN-13 (13) and ITF-14/GTIN-14 (14).
    static let foodBarcodeLengths: Set<Int> = [8, 12, 13, 14]

    /// True only for a FOOD-SHAPED barcode: exactly 8/12/13/14 ASCII
    /// digits after trimming. This is the privacy gate — a QR payload
    /// (URL, coupon text, anything) fails it and never leaves the
    /// device.
    ///
    /// Deliberate omissions, documented rather than accidental:
    ///  - NO check-digit validation. A misread digit must cost at most
    ///    one honest `notFound` (OFF has no such code) — a wrong check
    ///    digit can never produce a WRONG product, and a valid code with
    ///    one misread digit must not be needlessly discarded.
    ///  - Devanagari (or any non-ASCII) digits are rejected — Vision
    ///    never emits them for EAN symbologies, and `Character.isNumber`
    ///    alone would wrongly admit them.
    static func isFoodBarcode(_ raw: String) -> Bool {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard foodBarcodeLengths.contains(candidate.count) else { return false }
        return candidate.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Parsing

    /// Wire format of the OFF v2 response. Everything optional: OFF
    /// omits fields per record, and an unknown barcode returns no
    /// `product` key at all, with `status: 0`.
    private struct ProductPayload: Decodable {
        struct Product: Decodable {
            let product_name: String?
            let brands: String?
            let categories: String?
            let categories_tags: [String]?
        }
        let status: Int?
        let product: Product?
    }

    /// Decodes an OFF response into the honest parse verdict. On ANY
    /// malformation (non-JSON, wrong shape) → `.malformed`; `status: 0`
    /// or a missing product key → `.notFound`; a product record whose
    /// name, brands AND categories are all blank → `.notFound` (nothing
    /// speakable is the same honest outcome as no record).
    static func parseProductResponse(data: Data, barcode: String) -> ParseResult {
        guard let payload = try? JSONDecoder().decode(ProductPayload.self, from: data) else {
            return .malformed
        }
        guard let product = payload.product else {
            return payload.status == 0 ? .notFound : .malformed
        }
        let name = cleaned(product.product_name)
        let brands = cleaned(product.brands)
        let hints = categoryHints(text: product.categories, tags: product.categories_tags)
        guard name != nil || brands != nil || !hints.isEmpty else { return .notFound }
        return .product(ProductInfo(barcode: barcode, name: name, brands: brands,
                                    categoryHints: hints))
    }

    /// Trims and empties→nil.
    private static func cleaned(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Category hints: the human-readable `categories` text when present
    /// (comma-separated), else the `categories_tags` list with its
    /// "xx:" language prefix stripped ("en:breakfasts" → "breakfasts").
    /// Capped at `maxCategoryHints`, OFF order preserved.
    private static func categoryHints(text: String?, tags: [String]?) -> [String] {
        var hints: [String] = []
        if let text {
            hints = text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if hints.isEmpty, let tags {
            hints = tags.map { tag in
                let parts = tag.split(separator: ":", maxSplits: 1)
                return parts.last.map(String.init) ?? ""
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        }
        return Array(hints.prefix(maxCategoryHints))
    }

    // MARK: - Lookup

    /// Looks a barcode up on OFF over `transport` (URLSession in
    /// production, a stub in tests) and reports the honest outcome:
    ///  - the courtesy throttle engages BEFORE any network work —
    ///    `.rateLimited` costs nothing and touches nothing;
    ///  - transport errors → `.noNetwork`;
    ///  - HTTP 404 → `.notFound`;
    ///  - any other non-200 → `.malformed`;
    ///  - 200 → the pure parse verdict, passed through unchanged.
    ///
    /// Caller contract: gate with `isFoodBarcode` first (this method
    /// trusts its barcode, like `WeatherTool.fetchCurrent` trusts its
    /// coordinates).
    static func lookup(barcode: String,
                       transport: LocalToolTransport = URLSession.shared,
                       throttle: CourtesyThrottle = .shared) async -> LookupOutcome {
        guard throttle.allowsAttempt() else { return .rateLimited }
        let request = makeRequest(barcode: barcode)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.fetchData(for: request)
        } catch {
            return .noNetwork
        }
        guard let http = response as? HTTPURLResponse else { return .noNetwork }
        if http.statusCode == 404 { return .notFound }
        guard http.statusCode == 200 else { return .malformed }
        switch parseProductResponse(data: data, barcode: barcode) {
        case .product(let info): return .found(info)
        case .notFound: return .notFound
        case .malformed: return .malformed
        }
    }
}

/// [POINT-TAP-ASK] (2026-09-19) The courtesy throttle behind
/// `ProductLookupTool.lookup`: at most `courtesyLimitPerMinute` attempts
/// in any sliding 60-second window. In-memory by design — the cap is a
/// per-process courtesy to a public API, not a persisted budget
/// (`PointAskQuota` is the persisted daily budget).
///
/// Testability: the clock is an injected closure (`now`), so the tests
/// slide the window deterministically without sleeping.
final class CourtesyThrottle {
    static let shared = CourtesyThrottle()

    private let limit: Int
    private let now: () -> Date
    private let lock = NSLock()
    private var stamps: [Date] = []

    init(limit: Int = ProductLookupTool.courtesyLimitPerMinute,
         now: @escaping () -> Date = Date.init) {
        self.limit = limit
        self.now = now
    }

    /// True when an attempt is allowed NOW — and records the attempt.
    /// Prunes stamps older than 60 s first; when the window is full the
    /// attempt is denied WITHOUT being recorded (a denied attempt must
    /// not extend its own punishment).
    func allowsAttempt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let instant = now()
        let cutoff = instant.addingTimeInterval(-60)
        stamps.removeAll { $0 < cutoff }
        guard stamps.count < limit else { return false }
        stamps.append(instant)
        return true
    }

    /// Zeroes the window (tests; a future settings "reset" action).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        stamps.removeAll()
    }
}
