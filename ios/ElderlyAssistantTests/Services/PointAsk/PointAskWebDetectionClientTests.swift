import XCTest
@testable import ElderlyAssistant

/// [POINT-TAP-ASK] (2026-09-19) Google Vision webDetection client
/// contract (stub transport — no network):
///  - the request body is the documented images:annotate shape — one
///    image, one WEB_DETECTION feature — and the API key travels ONLY in
///    the `x-goog-api-key` header, never the URL (T-050/B2);
///  - parsing maps the real wire shape into provenance rows (best
///    guesses, scored entities, top matching/similar pages), drops rows
///    without usable content, caps entities at 5 and pages at 3, and
///    returns nil on ANY malformation or an all-empty detection;
///  - `detect` gates on configuration before any network work, then maps
///    HTTP status and unusable payloads to distinct honest errors and
///    propagates transport errors as-is;
///  - `PointAskCloudConfigStore` mirrors `SearchConfigStore` (encrypted
///    storage, keyed round-trip, blank-save clears, clear removes).
final class PointAskWebDetectionClientTests: XCTestCase {

    // MARK: - Request building

    func testRequestBodyIsTheDocumentedAnnotateShape() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0])   // fake JPEG head
        let body = try XCTUnwrap(PointAskWebDetectionClient.requestBody(imageData: image))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let requests = try XCTUnwrap(json["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 1, "this client always sends exactly one image")

        let request = try XCTUnwrap(requests.first)
        let imageDict = try XCTUnwrap(request["image"] as? [String: Any])
        XCTAssertEqual(imageDict["content"] as? String, image.base64EncodedString())

        let features = try XCTUnwrap(request["features"] as? [[String: Any]])
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0]["type"] as? String, "WEB_DETECTION")
        XCTAssertEqual(features[0]["maxResults"] as? Int,
                       PointAskWebDetectionClient.webDetectionMaxResults)
    }

    func testMakeRequestUsesHeaderAuthAndPostJSON() throws {
        let image = Data([1, 2, 3])
        let request = try XCTUnwrap(PointAskWebDetectionClient.makeRequest(
            imageData: image, apiKey: "vision-key", timeout: 25))

        XCTAssertEqual(request.url?.absoluteString, PointAskWebDetectionClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "vision-key")
        XCTAssertFalse(request.url?.absoluteString.contains("vision-key") ?? false,
                       "the key must never ride in the URL (T-050/B2)")
        XCTAssertNotNil(request.httpBody)
    }

    // MARK: - Parsing

    private let sampleVisionResponse = """
    {"responses":[{"webDetection":{
      "webEntities":[
        {"entityId":"/m/01xq0k1","score":1.2,"description":"Nutella"},
        {"entityId":"/m/0c6m","score":0.9,"description":"Ferrero"}],
      "bestGuessLabels":[{"label":"Nutella","languageCode":"en"}],
      "pagesWithMatchingImages":[
        {"url":"https://example.com/nutella","pageTitle":"Nutella — Example"},
        {"url":"https://example.org/about"}],
      "visuallySimilarImages":[
        {"url":"https://example.net/photo1","score":0.8}]
    }}]}
    """

    func testParseDecodesProvenanceRows() {
        let provenance = PointAskWebDetectionClient.parseWebDetection(
            data: Data(sampleVisionResponse.utf8))

        XCTAssertEqual(provenance, PointAskWebDetectionClient.WebDetectionProvenance(
            bestGuesses: [.init(label: "Nutella")],
            entities: [.init(description: "Nutella", score: 1.2),
                       .init(description: "Ferrero", score: 0.9)],
            matchingPages: [.init(url: "https://example.com/nutella",
                                  title: "Nutella — Example"),
                            .init(url: "https://example.org/about", title: nil)],
            similarPages: [.init(url: "https://example.net/photo1", title: nil)]))
    }

    func testParseKeepsUnnormalizedEntityScores() {
        // Vision web scores are NOT clamped to 1.0 — a 1.2 must survive
        // the round trip exactly.
        let provenance = PointAskWebDetectionClient.parseWebDetection(
            data: Data(sampleVisionResponse.utf8))
        XCTAssertEqual(provenance?.entities.first?.score, 1.2)
    }

    func testParseDefaultsMissingEntityScoreToZero() {
        let data = Data("""
        {"responses":[{"webDetection":{"webEntities":[{"description":"Nutella"}]}}]}
        """.utf8)
        XCTAssertEqual(PointAskWebDetectionClient.parseWebDetection(data: data)?.entities,
                       [.init(description: "Nutella", score: 0)])
    }

    func testParseCapsEntitiesAndPages() {
        let entities = (0..<8).map { ("Entity \($0)", Double($0)) }
        let pages = (0..<6).map { ["url": "https://example.com/p\($0)",
                                   "pageTitle": "Page \($0)"] }
        let similar = (0..<6).map { ["url": "https://example.com/s\($0)"] }
        let json = visionJSON(entities: entities, guesses: ["Guess"],
                              pages: pages, similar: similar)

        let provenance = PointAskWebDetectionClient.parseWebDetection(data: json)

        XCTAssertEqual(provenance?.bestGuesses, [.init(label: "Guess")])
        XCTAssertEqual(provenance?.entities.count, 5)
        XCTAssertEqual(provenance?.entities.first?.description, "Entity 0")
        XCTAssertEqual(provenance?.matchingPages.count, 3)
        XCTAssertEqual(provenance?.similarPages.count, 3)
    }

    func testParseDropsUnusableRows() {
        // Entities without a description, guesses blanked, pages without
        // an absolute URL — none of them are provenance.
        let json = visionJSON(
            entities: [("Nutella", 1.0), ("", 0.5)],
            guesses: ["  ", "Ferrero"],
            pages: [["url": "not a url"], ["url": "https://ok.example", "pageTitle": "T"]],
            similar: [["url": ""]])

        XCTAssertEqual(PointAskWebDetectionClient.parseWebDetection(data: json),
                       PointAskWebDetectionClient.WebDetectionProvenance(
                           bestGuesses: [.init(label: "Ferrero")],
                           entities: [.init(description: "Nutella", score: 1.0)],
                           matchingPages: [.init(url: "https://ok.example", title: "T")],
                           similarPages: []))
    }

    func testParseReturnsNilForMalformedPayloads() {
        XCTAssertNil(PointAskWebDetectionClient.parseWebDetection(data: Data("not json".utf8)))
        XCTAssertNil(PointAskWebDetectionClient.parseWebDetection(data: Data()))
        // Empty response list.
        XCTAssertNil(PointAskWebDetectionClient.parseWebDetection(
            data: Data(#"{"responses":[]}"#.utf8)))
        // Response without webDetection.
        XCTAssertNil(PointAskWebDetectionClient.parseWebDetection(
            data: Data(#"{"responses":[{"faceAnnotations":[]}]}"#.utf8)))
        // webDetection present but every array empty — an empty answer
        // and a broken answer are the same outcome.
        XCTAssertNil(PointAskWebDetectionClient.parseWebDetection(
            data: Data(#"{"responses":[{"webDetection":{}}]}"#.utf8)))
    }

    /// Builds a Vision-shaped response payload from row arrays.
    private func visionJSON(entities: [(String, Double)] = [],
                            guesses: [String] = [],
                            pages: [[String: Any]] = [],
                            similar: [[String: Any]] = []) -> Data {
        var web: [String: Any] = [:]
        if !entities.isEmpty {
            web["webEntities"] = entities.map {
                ["entityId": "", "score": $0.1, "description": $0.0]
            }
        }
        if !guesses.isEmpty {
            web["bestGuessLabels"] = guesses.map { ["label": $0] }
        }
        if !pages.isEmpty { web["pagesWithMatchingImages"] = pages }
        if !similar.isEmpty { web["visuallySimilarImages"] = similar }
        let payload: [String: Any] = ["responses": [["webDetection": web]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - detect (stub transport)

    private var configStore: PointAskCloudConfigStore!
    private var transport: FakeGeminiTransport!

    override func setUp() {
        super.setUp()
        configStore = PointAskCloudConfigStore(storage: GeminiInMemoryStorage())
        transport = FakeGeminiTransport()
    }

    private func httpResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: PointAskWebDetectionClient.endpoint)!,
                        statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    func testDetectThrowsNotConfiguredWithoutKey() async {
        let client = PointAskWebDetectionClient(configStore: configStore, transport: transport)
        do {
            _ = try await client.detect(imageData: Data([1]))
            XCTFail("expected notConfigured")
        } catch PointAskWebDetectionClient.WebDetectionError.notConfigured {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(transport.sendCount, 0,
                       "an unconfigured client must never touch the network")
    }

    func testDetectReturnsProvenanceOnSuccess() async throws {
        configStore.saveAPIKey("vision-key")
        transport.nextResult = .success((Data(sampleVisionResponse.utf8),
                                         httpResponse(statusCode: 200)))
        let client = PointAskWebDetectionClient(configStore: configStore, transport: transport)

        let provenance = try await client.detect(imageData: Data([1, 2, 3]))

        XCTAssertEqual(provenance.bestGuesses, [.init(label: "Nutella")])
        // The request the transport saw carries the key in the header.
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "x-goog-api-key"),
                       "vision-key")
        XCTAssertEqual(transport.lastRequest?.url?.absoluteString,
                       PointAskWebDetectionClient.endpoint)
    }

    func testDetectMapsHTTPStatusToHTTPError() async {
        configStore.saveAPIKey("vision-key")
        transport.nextResult = .success((Data(), httpResponse(statusCode: 429)))
        let client = PointAskWebDetectionClient(configStore: configStore, transport: transport)

        do {
            _ = try await client.detect(imageData: Data([1]))
            XCTFail("expected httpError")
        } catch PointAskWebDetectionClient.WebDetectionError.httpError(let status) {
            XCTAssertEqual(status, 429)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDetectMapsUnusablePayloadToUnusableResponse() async {
        configStore.saveAPIKey("vision-key")
        transport.nextResult = .success((Data(#"{"responses":[]}"#.utf8),
                                         httpResponse(statusCode: 200)))
        let client = PointAskWebDetectionClient(configStore: configStore, transport: transport)

        do {
            _ = try await client.detect(imageData: Data([1]))
            XCTFail("expected unusableResponse")
        } catch PointAskWebDetectionClient.WebDetectionError.unusableResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDetectPropagatesTransportErrors() async {
        configStore.saveAPIKey("vision-key")
        struct NetworkDown: Error {}
        transport.nextResult = .failure(NetworkDown())
        let client = PointAskWebDetectionClient(configStore: configStore, transport: transport)

        do {
            _ = try await client.detect(imageData: Data([1]))
            XCTFail("expected the transport error to propagate")
        } catch is NetworkDown {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - PointAskCloudConfigStore (mirror of SearchConfigStore)

    func testConfigStoreRoundTripAcrossInstances() {
        let storage = GeminiInMemoryStorage()
        let first = PointAskCloudConfigStore(storage: storage)
        XCTAssertFalse(first.isConfigured)
        XCTAssertNil(first.apiKey)

        first.saveAPIKey("  vision-key-1  ")
        XCTAssertEqual(first.apiKey, "vision-key-1", "whitespace trims on save")
        XCTAssertTrue(first.isConfigured)

        // A fresh store over the same storage reads the key back.
        let reloaded = PointAskCloudConfigStore(storage: storage)
        XCTAssertEqual(reloaded.apiKey, "vision-key-1")
        XCTAssertTrue(reloaded.isConfigured)
    }

    func testConfigStoreSavingBlankClears() {
        let store = PointAskCloudConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("vision-key")
        store.saveAPIKey("   ")
        XCTAssertNil(store.apiKey)
        XCTAssertFalse(store.isConfigured)
    }

    func testConfigStoreClearRemovesPersistedKey() {
        let storage = GeminiInMemoryStorage()
        let store = PointAskCloudConfigStore(storage: storage)
        store.saveAPIKey("vision-key")

        store.clear()

        XCTAssertNil(store.apiKey)
        XCTAssertFalse(store.isConfigured)
        // And nothing survives on the storage itself.
        let reloaded = PointAskCloudConfigStore(storage: storage)
        XCTAssertFalse(reloaded.isConfigured)
    }
}
