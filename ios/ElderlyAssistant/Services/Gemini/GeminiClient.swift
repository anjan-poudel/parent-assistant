import Foundation

/// Thin abstraction over the network call so tests can inject a fake
/// transport without touching the network. `URLSession` conforms for free.
protocol GeminiTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GeminiTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// REST client for the Gemini Generative Language API
/// (`generativelanguage.googleapis.com/v1beta`). This is the v2 pivot's
/// replacement for `LlamaCommandInterpreter` + `WhisperSpeechRecognizer` —
/// see docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md.
///
/// NOTE (honesty, not hedging): this client is written against Google's
/// documented `generateContent` request/response shape, but has not been
/// exercised against a live endpoint in this environment (no network
/// credentials available at implementation time). Verify against a real
/// API key on-device before relying on it — the JSON field names here
/// (`inlineData`, `mimeType`, `generationConfig`, `responseMimeType`) are
/// the current documented camelCase names as of this writing.
///
/// Deliberately uses `generationConfig.responseMimeType = "application/json"`
/// (guarantees syntactically valid JSON) WITHOUT a full `responseSchema`
/// (Google's OpenAPI-subset schema DSL) — this keeps the client's surface
/// small and reuses `LlamaCommandInterpreter.parse(json:)` for shape
/// validation, at the cost of not getting schema-level enforcement from
/// Gemini itself. Adding a full `responseSchema` is a reasonable follow-up
/// once this simpler path is verified live.
final class GeminiClient {

    enum GeminiClientError: Error {
        case notConfigured
        case invalidURL
        case invalidResponse
        case httpError(status: Int, body: String?)
        case emptyResponse
        case blockedByProvider(reason: String)
    }

    struct Config {
        var timeoutSeconds: TimeInterval
        static let `default` = Config(timeoutSeconds: 6)
    }

    private let configStore: GeminiConfigStore
    private let observabilityBus: ObservabilityBus
    private let transport: GeminiTransport
    private let config: Config

    init(configStore: GeminiConfigStore,
         observabilityBus: ObservabilityBus,
         transport: GeminiTransport = URLSession.shared,
         config: Config = .default) {
        self.configStore = configStore
        self.observabilityBus = observabilityBus
        self.transport = transport
        self.config = config
    }

    var isAvailable: Bool { configStore.isConfigured }

    /// Transcribes a single utterance. `mimeType` must match `audioData`'s
    /// actual encoding (e.g. "audio/wav").
    func transcribe(audioData: Data, mimeType: String, languageHint: String) async throws -> String {
        let prompt = """
        Transcribe the following audio verbatim, in the language actually \
        spoken (hint: \(languageHint), but transcribe what you actually hear, \
        not what the hint implies if they differ). Reply with ONLY the \
        transcription text — no commentary, no quotation marks, no labels.
        """
        let request = GeminiRequest(
            contents: [.init(parts: [
                .text(prompt),
                .inlineData(mimeType: mimeType, data: audioData.base64EncodedString())
            ])],
            generationConfig: nil
        )
        let text = try await send(request)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends a text prompt expecting a JSON-object response. Caller (e.g.
    /// `GeminiCommandInterpreter`) owns the prompt content and decodes the
    /// result — this method only guarantees "valid JSON came back", not
    /// any particular shape.
    func generateJSON(prompt: String) async throws -> String {
        let request = GeminiRequest(
            contents: [.init(parts: [.text(prompt)])],
            generationConfig: .init(responseMimeType: "application/json")
        )
        return try await send(request)
    }

    /// Vision call: identify/describe `imageData` in response to `prompt`.
    /// Used by the (not-yet-built) appliance/TV Visual Helper — exposed
    /// now so that feature can be added without touching this client.
    func analyzeImage(imageData: Data, mimeType: String, prompt: String) async throws -> String {
        let request = GeminiRequest(
            contents: [.init(parts: [
                .text(prompt),
                .inlineData(mimeType: mimeType, data: imageData.base64EncodedString())
            ])],
            generationConfig: nil
        )
        return try await send(request)
    }

    // MARK: - Transport

    private func send(_ body: GeminiRequest) async throws -> String {
        guard let apiKey = configStore.apiKey, !apiKey.isEmpty else {
            throw GeminiClientError.notConfigured
        }
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(configStore.model):generateContent?key=\(apiKey)"
        ) else {
            throw GeminiClientError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let start = Date()
        let (data, response) = try await transport.send(request)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw GeminiClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            emit("gemini_http_error", outcome: "failure", durationMs: durationMs,
                 errorCode: String(http.statusCode))
            throw GeminiClientError.httpError(status: http.statusCode,
                                              body: String(data: data, encoding: .utf8))
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        if let blockReason = decoded.promptFeedback?.blockReason {
            emit("gemini_blocked", outcome: "failure", durationMs: durationMs, errorCode: blockReason)
            throw GeminiClientError.blockedByProvider(reason: blockReason)
        }
        guard let text = decoded.candidates?.first?.content?.parts?.first(where: { $0.text != nil })?.text,
              !text.isEmpty else {
            emit("gemini_empty_response", outcome: "failure", durationMs: durationMs)
            throw GeminiClientError.emptyResponse
        }
        emit("gemini_call", outcome: "success", durationMs: durationMs)
        return text
    }

    private func emit(_ eventType: String, outcome: String, durationMs: Int, errorCode: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: "gemini_client",
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}

// MARK: - Request/response wire types

struct GeminiRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            var text: String?
            var inlineData: InlineData?

            struct InlineData: Encodable {
                let mimeType: String
                let data: String
            }

            static func text(_ value: String) -> Part { Part(text: value, inlineData: nil) }
            static func inlineData(mimeType: String, data: String) -> Part {
                Part(text: nil, inlineData: InlineData(mimeType: mimeType, data: data))
            }
        }
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        var responseMimeType: String?
    }

    let contents: [Content]
    var generationConfig: GenerationConfig?
}

struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
        let finishReason: String?
    }
    struct PromptFeedback: Decodable { let blockReason: String? }

    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}
