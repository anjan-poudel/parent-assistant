import XCTest
@testable import ElderlyAssistant

/// Vision surface of `GeminiClient` (design §3): request shape, JSON-mode
/// decode (including malformed/partial payloads), and the knowledge-source
/// tier. The Gemini boundary is faked via `FakeGeminiTransport`.
final class GeminiClientVisionTests: XCTestCase {

    private var configStore: GeminiConfigStore!
    private var bus: MockObservabilityBus!
    private var transport: FakeGeminiTransport!

    override func setUp() {
        super.setUp()
        configStore = GeminiConfigStore(storage: GeminiInMemoryStorage())
        configStore.save("fake-key")
        bus = MockObservabilityBus()
        transport = FakeGeminiTransport()
    }

    private func makeClient() -> GeminiClient {
        GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)
    }

    /// A complete, well-formed payload per design §3.1's JSON contract.
    private let fullPayload = #"""
    {
      "identity": {"brand": "Panasonic", "model": "NN-SN686S",
                   "category": "microwave", "displayName": "Panasonic microwave"},
      "steps": ["पानी कपमा राख्नुहोस्", "स्टार्ट थिच्नुहोस्"],
      "groundedControls": [
        {"label": "START", "stepNumber": 2,
         "normalizedBox": {"xMin": 0.6, "yMin": 0.7, "xMax": 0.9, "yMax": 0.8},
         "confidence": 0.92}
      ],
      "spokenSummary": "पानी राखेर स्टार्ट थिच्नुहोस्",
      "confidence": 0.88
    }
    """#

    // MARK: - Request shape

    func testIdentifySendsImageInlineDataAndJSONMode() async throws {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: fullPayload))
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])  // fake JPEG magic bytes

        _ = try await makeClient().identifyAppliance(
            imageData: imageData, mimeType: "image/jpeg", question: "चिया कसरी बनाउने",
            languageHint: "ne")

        let body = try XCTUnwrap(transport.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let inline = parts.compactMap { $0["inlineData"] as? [String: Any] }.first
        XCTAssertEqual(inline?["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(inline?["data"] as? String, imageData.base64EncodedString())
        let prompt = parts.compactMap { $0["text"] as? String }.first
        XCTAssertTrue(prompt?.contains("चिया कसरी बनाउने") == true)
        XCTAssertTrue(prompt?.contains("ne") == true)
        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNil(json["tools"], "no search tool unless explicitly requested")
    }

    func testIdentifyWithSearchGroundingAddsSearchTool() async throws {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: fullPayload))

        _ = try await makeClient().identifyAppliance(
            imageData: Data([1]), mimeType: "image/jpeg", question: nil,
            languageHint: "ne", allowSearchGrounding: true)

        let body = try XCTUnwrap(transport.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.first?["google_search"])
    }

    func testFollowUpWithoutImageOmitsInlineData() async throws {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: fullPayload))
        let identity = ApplianceIdentity(brand: "Panasonic", model: "NN-SN686S",
                                         category: "microwave", displayName: "Panasonic microwave")

        _ = try await makeClient().getApplianceInstructions(
            imageData: nil, mimeType: nil, appliance: identity,
            followUpQuestion: "अब के गर्ने", languageHint: "ne")

        let body = try XCTUnwrap(transport.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertNil(parts.compactMap { $0["inlineData"] as? [String: Any] }.first,
                     "text-only follow-up must not pay for an image part")
        let prompt = parts.compactMap { $0["text"] as? String }.first
        XCTAssertTrue(prompt?.contains("अब के गर्ने") == true)
        XCTAssertTrue(prompt?.contains("Panasonic") == true)
    }

    func testFollowUpWithImageIncludesInlineData() async throws {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: fullPayload))
        let identity = ApplianceIdentity(brand: nil, model: nil,
                                         category: "tv_remote", displayName: "TV remote")
        let imageData = Data([9, 8, 7])

        _ = try await makeClient().getApplianceInstructions(
            imageData: imageData, mimeType: "image/jpeg", appliance: identity,
            followUpQuestion: "दुई नम्बर बटन के हो", languageHint: "ne")

        let body = try XCTUnwrap(transport.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["inlineData"] as? [String: Any] }.first?["data"] as? String,
                       imageData.base64EncodedString())
    }

    // MARK: - Decode

    func testIdentifyDecodesFullPayload() async throws {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: fullPayload))

        let guidance = try await makeClient().identifyAppliance(
            imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")

        XCTAssertEqual(guidance.identity.brand, "Panasonic")
        XCTAssertEqual(guidance.identity.brandModelKey, "panasonic|nn-sn686s")
        XCTAssertEqual(guidance.steps.count, 2)
        XCTAssertEqual(guidance.groundedControls.count, 1)
        let control = try XCTUnwrap(guidance.groundedControls.first)
        XCTAssertEqual(control.normalizedBox.center.x, 0.75, accuracy: 0.0001)
        XCTAssertEqual(control.stepNumber, 2)
        XCTAssertEqual(guidance.confidence, 0.88, accuracy: 0.0001)
        XCTAssertEqual(guidance.knowledgeSource, .onDeviceModelKnowledge)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "gemini_vision_identify" && $0.outcome == "success"
        })
    }

    func testGroundedCallTagsKnowledgeSource() async throws {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: fullPayload))

        let guidance = try await makeClient().identifyAppliance(
            imageData: Data([1]), mimeType: "image/jpeg", question: nil,
            languageHint: "ne", allowSearchGrounding: true)

        XCTAssertEqual(guidance.knowledgeSource, .webSearchGrounded)
    }

    func testPartialPayloadGetsSafeDefaults() async throws {
        // Only identity + confidence present — everything else must
        // default (steps [], controls [], empty summary).
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(
            text: #"{"identity":{"category":"other","displayName":"unknown device"},"confidence":0.7}"#))

        let guidance = try await makeClient().identifyAppliance(
            imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")

        XCTAssertEqual(guidance.steps, [])
        XCTAssertEqual(guidance.groundedControls, [])
        XCTAssertEqual(guidance.spokenSummary, "")
        XCTAssertEqual(guidance.confidence, 0.7, accuracy: 0.0001)
    }

    func testMissingIdentityThrowsAndLogsParseFailed() async {
        // Syntactically valid JSON, but no identity object — nothing to
        // present or cache, so this is a parse failure, not a low-
        // confidence result.
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(
            text: #"{"steps":["x"],"confidence":0.9}"#))

        do {
            _ = try await makeClient().identifyAppliance(
                imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")
            XCTFail("expected a parse failure for a payload without identity")
        } catch {
            XCTAssertTrue(bus.emittedEvents.contains {
                $0.eventType == "gemini_vision_identify"
                    && $0.outcome == "failure" && $0.errorCode == "parse_failed"
            })
        }
    }

    func testMalformedNonJSONThrowsAndLogsParseFailed() async {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(
            text: "I cannot help with this image, sorry!"))

        do {
            _ = try await makeClient().identifyAppliance(
                imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")
            XCTFail("expected a parse failure for non-JSON text")
        } catch {
            XCTAssertTrue(bus.emittedEvents.contains {
                $0.eventType == "gemini_vision_identify"
                    && $0.outcome == "failure" && $0.errorCode == "parse_failed"
            })
        }
    }

    func testProseWrappedJSONIsRecovered() async {
        // The model wrapped the object in prose despite JSON mode — the
        // outermost {...} span is still decodable.
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(
            text: "Here is the answer:\n" + fullPayload + "\nHope that helps!"))

        let guidance = try await makeClient().identifyAppliance(
            imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")

        XCTAssertEqual(guidance.identity.displayName, "Panasonic microwave")
    }

    func testLossyControlDecodingDropsJunkElements() async throws {
        // One control is missing its box — it must be dropped without
        // sinking the two good ones.
        let payload = #"""
        {
          "identity": {"category": "tv_remote", "displayName": "remote"},
          "groundedControls": [
            {"label": "POWER", "stepNumber": 1,
             "normalizedBox": {"xMin": 0.1, "yMin": 0.1, "xMax": 0.3, "yMax": 0.2},
             "confidence": 0.9},
            {"label": "VOL+", "confidence": 0.8},
            {"label": "OK", "stepNumber": "2",
             "normalizedBox": {"xMin": 0.4, "yMin": 0.4, "xMax": 0.6, "yMax": 0.5},
             "confidence": 0.7}
          ],
          "confidence": 0.8
        }
        """#
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: payload))

        let guidance = try await makeClient().identifyAppliance(
            imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")

        XCTAssertEqual(guidance.groundedControls.map(\.label), ["POWER", "OK"])
        // stepNumber arrived as a string — tolerant decode still gets 2.
        XCTAssertEqual(guidance.groundedControls.last?.stepNumber, 2)
    }

    func testFollowUpParseFailureEmitsFollowupEvent() async {
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "not json"))
        let identity = ApplianceIdentity(brand: nil, model: nil, category: "other", displayName: "x")

        do {
            _ = try await makeClient().getApplianceInstructions(
                imageData: nil, mimeType: nil, appliance: identity,
                followUpQuestion: "q", languageHint: "ne")
            XCTFail("expected a parse failure")
        } catch {
            XCTAssertTrue(bus.emittedEvents.contains {
                $0.eventType == "gemini_vision_followup" && $0.errorCode == "parse_failed"
            })
        }
    }

    func testTransportFailureIsPropagatedWithVisionEvent() async {
        struct NetworkDown: Error {}
        transport.nextResult = .failure(NetworkDown())

        do {
            _ = try await makeClient().identifyAppliance(
                imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")
            XCTFail("expected the network error to propagate")
        } catch is NetworkDown {
            XCTAssertTrue(bus.emittedEvents.contains {
                $0.eventType == "gemini_vision_identify" && $0.outcome == "failure"
            })
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNotConfiguredThrowsBeforeAnyRequest() async {
        let unconfigured = GeminiConfigStore(storage: GeminiInMemoryStorage())
        let client = GeminiClient(configStore: unconfigured, observabilityBus: bus, transport: transport)

        do {
            _ = try await client.identifyAppliance(
                imageData: Data([1]), mimeType: "image/jpeg", question: nil, languageHint: "ne")
            XCTFail("expected notConfigured")
        } catch GeminiClient.GeminiClientError.notConfigured {
            XCTAssertNil(transport.lastRequest)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
