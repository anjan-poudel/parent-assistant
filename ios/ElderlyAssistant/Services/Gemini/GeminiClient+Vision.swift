import Foundation

/// Vision surface for the appliance helper (design:
/// docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md §3,
/// search-grounding tier from the addendum §12.2).
///
/// Kept deliberately separate from the audio path (`transcribe`/
/// `understand`): same `send(_:)` transport (one auth/timeout/observability
/// chokepoint), but image requests are `inlineData` JPEG + JSON-mode
/// responses decoded into `ApplianceGuidance`, not audio + raw text.
///
/// Bounding boxes are plain prompted-JSON fields, NOT a distinct
/// "grounding" API (design §3.2 — the parent doc's "grounding" language
/// conflated search-grounding metadata with object localization). Accuracy
/// is UNVERIFIED against a live endpoint; the policy layer
/// (`ApplianceGuidancePolicy`) treats wrong/missing boxes as an expected,
/// handled case.
extension GeminiClient {

    /// Vision call: identify what's in `imageData` and answer `question`
    /// (or "how do I use this?" if nil) from the photo + Gemini's own
    /// world knowledge. No manual-lookup pipeline (design §1).
    ///
    /// `allowSearchGrounding` adds the `google_search` tool so Gemini can
    /// pull model-specific manual knowledge from the web (addendum §12 —
    /// verified live against this API key on 2026-09-05). Costs a real
    /// search per call, so it stays opt-in; `ApplianceHelperSession` uses
    /// it only as the low-confidence retry tier.
    ///
    /// Throws `GeminiClientError` on transport/timeout/block/parse failure;
    /// callers must NOT treat a thrown error as "no such appliance" —
    /// only a successfully-decoded low-confidence result means that.
    func identifyAppliance(
        imageData: Data,
        mimeType: String,
        question: String?,
        languageHint: String,
        allowSearchGrounding: Bool = false
    ) async throws -> ApplianceGuidance {
        let prompt = Self.identifyPrompt(question: question, languageHint: languageHint)
        let request = GeminiRequest(
            contents: [.init(parts: [
                .text(prompt),
                .inlineData(mimeType: mimeType, data: imageData.base64EncodedString())
            ])],
            generationConfig: .init(responseMimeType: "application/json"),
            tools: allowSearchGrounding ? [.init(googleSearch: .init())] : nil
        )
        return try await sendVision(request, eventType: "gemini_vision_identify",
                                    imageByteCount: imageData.count,
                                    grounded: allowSearchGrounding)
    }

    /// Follow-up call once an appliance is already identified this session
    /// (`appliance.get_instructions`). `imageData` is optional: pass it
    /// again ONLY when `followUpQuestion` plausibly needs a NEW grounded
    /// control (boxes must be computed against actual pixel data) — a
    /// text-only follow-up ("what do I do next") can omit it and cost far
    /// fewer tokens (design §11 item 8).
    func getApplianceInstructions(
        imageData: Data?,
        mimeType: String?,
        appliance: ApplianceIdentity,
        followUpQuestion: String,
        languageHint: String,
        allowSearchGrounding: Bool = false
    ) async throws -> ApplianceGuidance {
        let prompt = Self.followUpPrompt(appliance: appliance,
                                         question: followUpQuestion,
                                         languageHint: languageHint)
        var parts: [GeminiRequest.Content.Part] = [.text(prompt)]
        if let imageData, let mimeType {
            parts.append(.inlineData(mimeType: mimeType, data: imageData.base64EncodedString()))
        }
        let request = GeminiRequest(
            contents: [.init(parts: parts)],
            generationConfig: .init(responseMimeType: "application/json"),
            tools: allowSearchGrounding ? [.init(googleSearch: .init())] : nil
        )
        return try await sendVision(request, eventType: "gemini_vision_followup",
                                    imageByteCount: imageData?.count,
                                    grounded: allowSearchGrounding)
    }

    // MARK: - Shared vision decode

    /// Transport + JSON-mode decode shared by both vision methods. Mirrors
    /// `GeminiCommandInterpreter`'s `parsed == nil` path on decode failure:
    /// log `outcome: "parse_failed"` and throw — not a crash, not a silent
    /// empty result.
    private func sendVision(_ request: GeminiRequest, eventType: String,
                            imageByteCount: Int?, grounded: Bool) async throws -> ApplianceGuidance {
        let start = Date()
        var emittedFailure = false
        do {
            let raw = try await send(request)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            guard var guidance = Self.decodeGuidance(raw) else {
                emit(eventType, outcome: "failure", durationMs: durationMs,
                     errorCode: "parse_failed")
                emittedFailure = true
                throw GeminiClientError.emptyResponse
            }
            guidance.knowledgeSource = grounded ? .webSearchGrounded : .onDeviceModelKnowledge
            var metadata: [String: String] = [:]
            if let imageByteCount {
                // Size bucket only — never the photo, never brand/model
                // (design §8's no-PII-in-metadata policy).
                metadata["size_bucket"] = imageByteCount <= 1_000_000 ? "≤1MB" : ">1MB"
            }
            emit(eventType, outcome: "success", durationMs: durationMs, metadata: metadata)
            return guidance
        } catch {
            if !emittedFailure {
                emit(eventType, outcome: "failure",
                     durationMs: Int(Date().timeIntervalSince(start) * 1000),
                     errorCode: String(describing: error))
            }
            throw error
        }
    }

    /// Decodes the model's JSON text into `ApplianceGuidance`. Tolerant
    /// path: the whole response is JSON-mode, but if the model still
    /// wrapped the object in prose, extract the outermost `{...}` span
    /// before giving up. Returns nil (caller maps to parse_failed) for
    /// anything else — including syntactically valid JSON that lacks the
    /// required `identity` object.
    static func decodeGuidance(_ raw: String) -> ApplianceGuidance? {
        let decoder = JSONDecoder()
        if let data = raw.data(using: .utf8),
           let g = try? decoder.decode(ApplianceGuidance.self, from: data) {
            return g
        }
        guard let open = raw.firstIndex(of: "{"),
              let close = raw.lastIndex(of: "}"), open < close else { return nil }
        let slice = String(raw[open...close])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? decoder.decode(ApplianceGuidance.self, from: data)
    }

    // MARK: - Prompts

    /// Prompt shape per design §3.1: JSON contract described in the prompt
    /// body (the shipped convention — prompt-engineered JSON mode, not
    /// native function calling; design §3.1/§11 item 9).
    static func identifyPrompt(question: String?, languageHint: String) -> String {
        """
        You are Sahayak's visual helper for an elderly speaker. Look at the attached photo of an \
        appliance, remote control, or screen. Answer using your own general knowledge of how such \
        devices work PLUS what you can see in the photo — you do not have access to any manual or \
        external database, so never claim to be quoting one.

        Reply with ONLY a single JSON object:
        {
          "identity": { "brand": string|null, "model": string|null,
                        "category": one of "microwave","tv_remote","smart_hub","washing_machine",
                                    "air_conditioner","other",
                        "displayName": string },
          "steps": [string, ...],
          "groundedControls": [
            { "label": string, "stepNumber": number|null,
              "normalizedBox": { "xMin": number, "yMin": number, "xMax": number, "yMax": number },
              "confidence": number }
          ],
          "spokenSummary": string,
          "confidence": number
        }
        Normalize all box coordinates to the range 0.0-1.0, origin top-left of the ORIGINAL photo, \
        independent of any resizing. If you cannot confidently locate a named control's real \
        position in this image, omit it from groundedControls rather than guessing.
        User's question (if any): "\(question ?? "(none — general how-to-use)")"
        Reply language: \(languageHint).
        """
    }

    static func followUpPrompt(appliance: ApplianceIdentity, question: String,
                               languageHint: String) -> String {
        """
        You are Sahayak's visual helper for an elderly speaker. They were just being helped with \
        their \(appliance.displayName.isEmpty ? appliance.category : appliance.displayName) and \
        have a follow-up question. Answer from your own knowledge of such devices\(appliance.brand != nil ? " (brand: \(appliance.brand!)\(appliance.model.map { ", model: \($0)" } ?? ""))" : "") — \
        never claim to be quoting a manual. If a photo is attached, use what you can see in it.

        Reply with ONLY a single JSON object in EXACTLY this shape:
        {
          "identity": { "brand": string|null, "model": string|null, "category": string,
                        "displayName": string },
          "steps": [string, ...],
          "groundedControls": [
            { "label": string, "stepNumber": number|null,
              "normalizedBox": { "xMin": number, "yMin": number, "xMax": number, "yMax": number },
              "confidence": number }
          ],
          "spokenSummary": string,
          "confidence": number
        }
        Box coordinates are normalized 0.0-1.0, origin top-left of the attached photo. If no photo \
        is attached, or you cannot confidently locate a named control, return an empty \
        groundedControls array rather than guessing.
        Follow-up question: "\(question)"
        Reply language: \(languageHint).
        """
    }
}
