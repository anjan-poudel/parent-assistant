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

/// Streaming counterpart — testable seam for the SSE path
/// (`streamGenerateContent`). URLSession conforms for free.
protocol GeminiStreamingTransport {
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

extension URLSession: GeminiStreamingTransport {
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await bytes(for: request, delegate: nil)
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
        /// 6s was sized for gemini-2.5-flash-lite's typical latency and
        /// was too short the moment the model picker (2026-09-04) let
        /// this point at gemini-2.5-pro — confirmed live via a real
        /// device log: `NSURLErrorDomain Code=-1001 "The request timed
        /// out."` against `gemini-2.5-pro:generateContent`. 25s
        /// comfortably covers the slowest curated model
        /// (`GeminiModelCatalog`); `AppCoordinator.voiceWatchdogSeconds`
        /// must stay longer than this PLUS max capture time, or the same
        /// class of bug recurs from the other direction.
        static let `default` = Config(timeoutSeconds: 25)
    }

    private let configStore: GeminiConfigStore
    private let observabilityBus: ObservabilityBus
    private let transport: GeminiTransport
    private let streamingTransport: GeminiStreamingTransport
    private let config: Config

    init(configStore: GeminiConfigStore,
         observabilityBus: ObservabilityBus,
         transport: GeminiTransport = URLSession.shared,
         streamingTransport: GeminiStreamingTransport = URLSession.shared,
         config: Config = .default) {
        self.configStore = configStore
        self.observabilityBus = observabilityBus
        self.transport = transport
        self.streamingTransport = streamingTransport
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
    ///
    /// `useSearchGrounding`: adds Google's `google_search` tool to the
    /// request so Gemini can search the web and synthesize from results
    /// instead of relying on training knowledge alone. Verified live
    /// against this API key on 2026-09-05 (a real model-specific question
    /// returned a cited, correct answer with `groundingMetadata`
    /// present). Used by plugins whose questions are time-sensitive or
    /// model-specific (e.g. `NepaliCalendarPlugin`) — costs more (a real
    /// search per call) and adds latency, so it stays opt-in per call,
    /// never a blanket default.
    func generateJSON(prompt: String, useSearchGrounding: Bool = false) async throws -> String {
        let request = GeminiRequest(
            contents: [.init(parts: [.text(prompt)])],
            generationConfig: .init(responseMimeType: "application/json"),
            tools: useSearchGrounding ? [.init(googleSearch: .init())] : nil
        )
        return try await send(request)
    }

    /// Collapse #1 (intent-engine spec 2026-09-05 §4): ONE call does STT
    /// + intent + reply — audio in, `{transcript, <intent fields>, reply}`
    /// out. Replaces the two-call transcribe→interpret pair when the
    /// Gemini recognizer is active: the transcript half feeds the
    /// pipeline/UI as usual, the command half waits in `IntentRouter`'s
    /// preparse slot for that same transcript, so the interpretation
    /// layer makes ZERO additional network calls.
    ///
    /// The intent half is optional by construction: an utterance that
    /// produces no parseable command still returns its transcript (the
    /// router then falls back exactly as if interpretation had failed —
    /// same failure shape, no new edge cases).
    func understand(audioData: Data, mimeType: String,
                    context: InterpreterContext) async throws -> GeminiUnderstanding {
        let prompt = IntentPrompt.buildUnderstanding(context: context)
        let request = GeminiRequest(
            contents: [.init(parts: [
                .text(prompt),
                .inlineData(mimeType: mimeType, data: audioData.base64EncodedString())
            ])],
            generationConfig: .init(responseMimeType: "application/json")
        )
        let raw = try await send(request)
        let transcript = (try? JSONDecoder().decode(TranscriptProbe.self, from: Data(raw.utf8)))?.transcript ?? ""
        let command = LlamaCommandInterpreter.parse(json: raw)
        return GeminiUnderstanding(transcript: transcript, command: command)
    }

    /// Only the transcript is probed separately; the full payload parses
    /// through `LlamaCommandInterpreter.parse(json:)`, whose Codable shape
    /// ignores the extra `transcript` key for free.
    private struct TranscriptProbe: Decodable { let transcript: String? }

    /// Streaming variant of `understand` (spec §3.3 + collapse #1):
    /// `streamGenerateContent` (SSE). The response is ONE JSON object
    /// streamed in chunks; each chunk's partial text is accumulated, and
    /// the transcript-so-far is reported via `onPartialTranscript` as it
    /// grows — the live-caption pill gets progressively-revealed text,
    /// which batch whisper.cpp could never offer. The final parse is
    /// identical to the non-streaming path (no new failure shapes).
    func understandStreaming(audioData: Data, mimeType: String,
                             context: InterpreterContext,
                             onPartialTranscript: @escaping (String) -> Void
    ) async throws -> GeminiUnderstanding {
        guard let apiKey = configStore.apiKey, !apiKey.isEmpty else {
            throw GeminiClientError.notConfigured
        }
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(configStore.model):streamGenerateContent?alt=sse&key=\(apiKey)"
        ) else {
            throw GeminiClientError.invalidURL
        }
        let prompt = IntentPrompt.buildUnderstanding(context: context)
        let body = GeminiRequest(
            contents: [.init(parts: [
                .text(prompt),
                .inlineData(mimeType: mimeType, data: audioData.base64EncodedString())
            ])],
            generationConfig: .init(responseMimeType: "application/json")
        )
        var request = URLRequest(url: url, timeoutInterval: config.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let start = Date()
        var accumulated = ""
        var lastReported = ""
        let (bytes, response) = try await streamingTransport.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            emit("gemini_http_error", outcome: "failure", durationMs: 0,
                 errorCode: String((response as? HTTPURLResponse)?.statusCode ?? -1))
            throw GeminiClientError.invalidResponse
        }
        for try await line in bytes.lines {
            guard let chunk = Self.parseSSELine(line) else { continue }
            accumulated += chunk
            if let partial = Self.extractPartialTranscript(from: accumulated),
               partial != lastReported {
                lastReported = partial
                onPartialTranscript(partial)
            }
        }
        emit("gemini_call", outcome: "success",
             durationMs: Int(Date().timeIntervalSince(start) * 1000))
        let transcript = (try? JSONDecoder().decode(TranscriptProbe.self, from: Data(accumulated.utf8)))?.transcript ?? lastReported
        let command = LlamaCommandInterpreter.parse(json: accumulated)
        return GeminiUnderstanding(transcript: transcript, command: command)
    }

    /// One SSE frame → the chunk's text. Frames are `data: {json}`; the
    /// terminal `data: [DONE]` and blanks/comments return nil.
    static func parseSSELine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let response = try? JSONDecoder().decode(GeminiResponse.self, from: data) else {
            return nil
        }
        return response.candidates?.first?.content?.parts?
            .compactMap { $0.text }.joined()
    }

    /// The transcript-so-far out of an accumulated PARTIAL JSON string —
    /// matches `"transcript": "…` with JSON-string escapes honored,
    /// tolerant of the string being unterminated (stream still open).
    static func extractPartialTranscript(from text: String) -> String? {
        guard let keyRange = text.range(of: "\"transcript\""),
              let colonRange = text.range(of: ":", range: keyRange.upperBound..<text.endIndex),
              let quoteIndex = text[colonRange.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        var out = ""
        var escaped = false
        var idx = text.index(after: quoteIndex)
        while idx < text.endIndex {
            let c = text[idx]
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u": break  // \uXXXX — rare in Nepali transcripts mid-stream; skip
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                return out  // string closed — full transcript so far
            } else {
                out.append(c)
            }
            idx = text.index(after: idx)
        }
        return out.isEmpty ? nil : out
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

    /// Module-internal (not private) so the vision surface in
    /// `GeminiClient+Vision.swift` funnels through the exact same
    /// auth/timeout/observability chokepoint as every other call —
    /// including the shared per-day cost counter the parent design
    /// requires to live at this single point (design §8).
    func send(_ body: GeminiRequest) async throws -> String {
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

    /// Module-internal for the same reason as `send(_:)` — vision calls
    /// emit feature-level events (`gemini_vision_identify`, …) on top of
    /// the transport-level events `send` already emits.
    func emit(_ eventType: String, outcome: String, durationMs: Int, errorCode: String? = nil,
              metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "gemini_client",
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }
}

// MARK: - Collapsed understand result

/// The two halves of one collapsed Gemini call (spec §4 collapse #1).
/// `command` is nil when the model's intent half didn't parse — the
/// transcript is still perfectly usable.
struct GeminiUnderstanding {
    let transcript: String
    let command: InterpretedCommand?
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

    struct Tool: Encodable {
        struct GoogleSearch: Encodable {}
        let googleSearch: GoogleSearch

        private enum CodingKeys: String, CodingKey {
            case googleSearch = "google_search"
        }
    }

    let contents: [Content]
    var generationConfig: GenerationConfig?
    var tools: [Tool]?
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
