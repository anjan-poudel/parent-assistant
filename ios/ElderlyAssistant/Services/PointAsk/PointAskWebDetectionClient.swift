import Foundation

/// [POINT-TAP-ASK] (2026-09-19) Google Cloud Vision `webDetection` REST
/// client for the point-tap-ask pipeline (Phase 2 standalone slice): the
/// "who made this / what is this" provenance tier. Given one image
/// (the same crop `PointAskCrop` hands the barcode reader), it asks
/// Vision's WEB_DETECTION feature for best-guess labels, scored web
/// entities and the top matching/similar page URLs — rows the pipeline
/// turns into an attributed spoken answer ("according to
/// openfoodfacts.org / the web").
///
/// House pattern: the request/response JSON shapes are the pure tested
/// seams (buildable and parseable with no network); the transport is a
/// `GeminiTransport`-shaped seam (URLSession in production, a stub in
/// tests) exactly like `GeminiClient` — which is also why the API key
/// travels ONLY in the `x-goog-api-key` header, never the URL (T-050/B2:
/// URLs leak into error descriptions, proxies and crash reports; headers
/// do not).
///
/// Honesty contract:
///  - Only REAL Vision webDetection rows are returned, each carrying its
///    own score — never a synthesized label.
///  - A detection with nothing usable in it (every array empty or
///    blanked) parses as nil → `unusableResponse`, exactly like a
///    malformed payload: an empty answer and a broken answer are the
///    same outcome for the pipeline (honest fallback line).
///  - Distinct errors per distinct fact: `notConfigured` (no key —
///    checked BEFORE any network work), `httpError(status:)` (the
///    upstream status, nothing else — the raw body is dropped, per
///    T-050/B2), `unusableResponse` (answered, but no provenance in it).
///    Transport errors propagate as-is.
///
/// NOTE (honesty, not hedging): written against Google's documented
/// images:annotate shape; not yet exercised against a live endpoint —
/// verify with a real API key on-device before relying on it (device
/// verification item, like `GeminiClient` at its inception).
///
/// `PointAskQuota` (the daily attempt budget) is enforced by the
/// pipeline, not here — this client reports what Vision says, and stays
/// quota-free so its tests stay network-free.
final class PointAskWebDetectionClient {

    enum WebDetectionError: Error, Equatable {
        /// No API key configured — checked before any network work.
        case notConfigured
        case invalidURL
        /// Upstream HTTP failure. Carries the status ONLY — the raw
        /// upstream body was dropped (T-050/B2).
        case httpError(status: Int)
        /// The response decoded but carries no usable provenance.
        case unusableResponse
    }

    /// Everything the pipeline needs from one webDetection response.
    struct WebDetectionProvenance: Equatable {
        struct BestGuess: Equatable {
            let label: String
        }
        struct Entity: Equatable {
            let description: String
            /// Vision web scores are UNNORMALIZED — they can exceed 1.0.
            /// Kept raw; the pipeline compares scores relative to each
            /// other, never against a 0–1 assumption.
            let score: Double
        }
        struct SourcePage: Equatable {
            let url: String
            /// `pagesWithMatchingImages` entries carry a page title;
            /// `visuallySimilarImages` entries do not.
            let title: String?
        }
        let bestGuesses: [BestGuess]
        let entities: [Entity]
        let matchingPages: [SourcePage]
        let similarPages: [SourcePage]

        var isEmpty: Bool {
            bestGuesses.isEmpty && entities.isEmpty
                && matchingPages.isEmpty && similarPages.isEmpty
        }
    }

    /// Vision REST endpoint (annotate is the batch entry point; this
    /// client always sends exactly one image).
    static let endpoint = "https://vision.googleapis.com/v1/images:annotate"

    /// `maxResults` requested from the WEB_DETECTION feature — Vision's
    /// per-feature cap on returned rows.
    static let webDetectionMaxResults = 10

    /// Row caps the parser applies (the request asks for up to 10, the
    /// reply needs only the top few).
    static let maxWebEntities = 5
    static let maxSourcePages = 3

    /// One round-trip budget, sized like `GeminiClient.Config.default`
    /// (25 s): webDetection is a heavyweight Vision feature.
    static let defaultTimeoutSeconds: TimeInterval = 25

    private let configStore: PointAskCloudConfigStore
    private let transport: GeminiTransport
    private let timeoutSeconds: TimeInterval

    init(configStore: PointAskCloudConfigStore,
         transport: GeminiTransport = URLSession.shared,
         timeoutSeconds: TimeInterval = PointAskWebDetectionClient.defaultTimeoutSeconds) {
        self.configStore = configStore
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
    }

    var isAvailable: Bool { configStore.isConfigured }

    // MARK: - Request building

    /// Wire format of the images:annotate request — one image, one
    /// WEB_DETECTION feature. Encoded with `JSONEncoder`, the house way
    /// (`GeminiRequest`).
    private struct AnnotateRequest: Encodable {
        struct Image: Encodable {
            let content: String
        }
        struct Feature: Encodable {
            let type: String
            let maxResults: Int
        }
        struct Request: Encodable {
            let image: Image
            let features: [Feature]
        }
        let requests: [Request]
    }

    /// Builds the request BODY (pure JSON building — the round-trip
    /// tests decode and assert this exact shape). nil only if the body
    /// cannot be encoded (never for a valid `Data`).
    static func requestBody(imageData: Data,
                            maxResults: Int = webDetectionMaxResults) -> Data? {
        let body = AnnotateRequest(requests: [
            .init(image: .init(content: imageData.base64EncodedString()),
                  features: [.init(type: "WEB_DETECTION", maxResults: maxResults)])
        ])
        return try? JSONEncoder().encode(body)
    }

    /// Builds the full request: POST to `endpoint`, JSON body, and the
    /// API key in the `x-goog-api-key` HEADER (T-050/B2 — never a query
    /// item). nil when the body cannot be built.
    static func makeRequest(imageData: Data,
                            apiKey: String,
                            timeout: TimeInterval = defaultTimeoutSeconds) -> URLRequest? {
        guard let url = URL(string: endpoint),
              let body = requestBody(imageData: imageData) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body
        return request
    }

    // MARK: - Response parsing

    /// Wire format of the annotate response. Everything optional and
    /// nested behind a single-element `responses` array — Vision omits
    /// `webDetection` entirely when the feature found nothing.
    private struct AnnotateResponse: Decodable {
        struct Response: Decodable {
            struct WebDetection: Decodable {
                struct WebEntity: Decodable {
                    let entityId: String?
                    let score: Double?
                    let description: String?
                }
                struct BestGuessLabel: Decodable {
                    let label: String?
                    let languageCode: String?
                }
                struct WebImage: Decodable {
                    let url: String?
                    let score: Double?
                }
                struct WebPage: Decodable {
                    let url: String?
                    let pageTitle: String?
                }
                let webEntities: [WebEntity]?
                let bestGuessLabels: [BestGuessLabel]?
                let pagesWithMatchingImages: [WebPage]?
                let visuallySimilarImages: [WebImage]?
            }
            let webDetection: WebDetection?
        }
        let responses: [Response]?
    }

    /// Decodes an annotate response into provenance rows. Returns nil on
    /// ANY malformation (non-JSON, wrong shape, no `responses`) AND when
    /// the detection is all-empty — an empty answer and a broken answer
    /// are the same outcome for the pipeline. Rows are dropped when they
    /// lack a usable description/label/URL; entities and pages are
    /// capped at `maxWebEntities`/`maxSourcePages`.
    static func parseWebDetection(data: Data) -> WebDetectionProvenance? {
        guard let payload = try? JSONDecoder().decode(AnnotateResponse.self, from: data),
              let web = payload.responses?.first?.webDetection else {
            return nil
        }
        let guesses = (web.bestGuessLabels ?? []).compactMap { label -> WebDetectionProvenance.BestGuess? in
            guard let text = cleaned(label.label) else { return nil }
            return WebDetectionProvenance.BestGuess(label: text)
        }
        let entities = (web.webEntities ?? []).compactMap { entity -> WebDetectionProvenance.Entity? in
            guard let description = cleaned(entity.description) else { return nil }
            return WebDetectionProvenance.Entity(description: description, score: entity.score ?? 0)
        }
        let matching = (web.pagesWithMatchingImages ?? []).compactMap { page -> WebDetectionProvenance.SourcePage? in
            guard let url = usableURL(page.url) else { return nil }
            return WebDetectionProvenance.SourcePage(url: url, title: cleaned(page.pageTitle))
        }
        let similar = (web.visuallySimilarImages ?? []).compactMap { image -> WebDetectionProvenance.SourcePage? in
            guard let url = usableURL(image.url) else { return nil }
            return WebDetectionProvenance.SourcePage(url: url, title: nil)
        }
        let provenance = WebDetectionProvenance(
            bestGuesses: guesses,
            entities: Array(entities.prefix(maxWebEntities)),
            matchingPages: Array(matching.prefix(maxSourcePages)),
            similarPages: Array(similar.prefix(maxSourcePages)))
        guard !provenance.isEmpty else { return nil }
        return provenance
    }

    /// Trims and empties→nil.
    private static func cleaned(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A page URL is usable only when it is an absolute URL (has a
    /// scheme) — a bare-path string is not a source anyone can visit.
    private static func usableURL(_ raw: String?) -> String? {
        guard let trimmed = cleaned(raw),
              URL(string: trimmed)?.scheme != nil else { return nil }
        return trimmed
    }

    // MARK: - Detection

    /// Runs webDetection on `imageData` (a JPEG crop). Throws
    /// `WebDetectionError` on configuration/HTTP/parse failure; transport
    /// errors propagate as-is — the pipeline catches everything.
    func detect(imageData: Data) async throws -> WebDetectionProvenance {
        guard let apiKey = configStore.apiKey, !apiKey.isEmpty else {
            throw WebDetectionError.notConfigured
        }
        guard let request = Self.makeRequest(imageData: imageData,
                                             apiKey: apiKey,
                                             timeout: timeoutSeconds) else {
            throw WebDetectionError.invalidURL
        }
        let (data, response) = try await transport.send(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDetectionError.httpError(status: -1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebDetectionError.httpError(status: http.statusCode)
        }
        guard let provenance = Self.parseWebDetection(data: data) else {
            throw WebDetectionError.unusableResponse
        }
        return provenance
    }
}

/// [POINT-TAP-ASK] (2026-09-19) Holds the Google Cloud Vision API key
/// for `PointAskWebDetectionClient` — a deliberate mirror of
/// `SearchConfigStore`/`GeminiConfigStore`: `EncryptedLocalStorage`
/// (Keychain, Data Protection Complete), never `UserDefaults`, never
/// hardcoded. Entered by a family member in Settings (the elderly
/// primary user is not asked to handle API keys).
final class PointAskCloudConfigStore: ObservableObject {
    private static let apiKeyStorageKey = "pointask.cloudApiKey"

    private let storage: EncryptedLocalStorage

    @Published private(set) var apiKey: String?

    /// The web detection tier fires ONLY when a key exists — an empty
    /// key reads as unconfigured, and the pipeline falls back to its
    /// keyless tiers.
    var isConfigured: Bool { apiKey != nil }

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.apiKey = Self.load(key: Self.apiKeyStorageKey, storage: storage)
    }

    /// Save (whitespace-trimmed) or clear the key. Saving empty text
    /// clears it.
    func saveAPIKey(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = storage.delete(key: Self.apiKeyStorageKey)
            apiKey = nil
            return
        }
        _ = storage.write(key: Self.apiKeyStorageKey, value: trimmed)
        apiKey = trimmed
    }

    /// Removes the key (the Settings "remove" action) — the web
    /// detection tier stops firing until reconfigured.
    func clear() {
        _ = storage.delete(key: Self.apiKeyStorageKey)
        apiKey = nil
    }

    private static func load(key: String, storage: EncryptedLocalStorage) -> String? {
        guard case .success(let value) = storage.read(key: key, type: String.self),
              !value.isEmpty else { return nil }
        return value
    }
}
