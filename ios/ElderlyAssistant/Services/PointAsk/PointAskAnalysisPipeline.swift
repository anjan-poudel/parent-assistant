import CoreGraphics
import Foundation
import Vision

// The analysis stage (design §2, research §Q6 stages 3–7): the parallel
// local passes — OCR over the crop, dictionary/cache translation, image
// classification — and then the consent-gated Gemini VLM on the ≤768 px
// upload. The fallback ladder is the design §3 table, and this file's job
// is to make "honest, never fabricated" structural:
//
//  - **Ladder-1 is a complete answer, not an error state.** With the
//    cloud switch off (the shipped default), the findings carry OCR text,
//    its dictionary/cache translation and the classifier's name — enough
//    for the session to speak "It looks like a bottle. The label says: …"
//    — and the VLM stage is never attempted.
//  - **No egress without a grant (AM-7).** The VLM stage consults the
//    gate per attempt, including the retry, and hands the minted `Grant`
//    to `identifyPointAsk` — whose signature requires it. A denied,
//    unreadable or withdrawn consent is a skip with its own reason token,
//    never a fall-through.
//  - **Revocation cancels in-flight work (AM-1).** The VLM task is
//    registered with the gate for the duration of the attempt; a
//    withdrawal cancels it and the stage reports `revoked` rather than
//    retrying.
//  - **Failure has one retry, then honesty (ladder 6).** Transport,
//    timeout and parse failures retry once; the second failure leaves
//    `vlm` nil and the session falls to the ladder-1 answer or the honest
//    failure line — never a fabricated answer, never a silent empty card.
//  - **Medicines are refused, not identified.** The VLM prompt carries
//    the refusal instruction (design §1 item 4), the decoded `isMedicine`
//    flag is surfaced to the session, and the session speaks the
//    app-owned refusal copy — the model's words never carry the
//    health-guideline sentence.
//  - **Content-free by schema.** OCR text and the model's words exist in
//    the findings (the session composes the spoken answer from them) but
//    no event ever carries them: every metadata value is a count, a
//    duration, a closed token or a confidence (the `PointAskEvents`
//    contract).

/// The failure taxonomy — the design's closed set, mapped onto the
/// evidence-carrying error codes.
enum PointAskError: Error, Equatable, LogSafeErrorCode {
    /// The gate refused: no record for the current disclosure version.
    case consentNotRecorded
    /// The gate refused: the elder declined or revoked.
    case consentDenied
    /// The gate refused: the record cannot be trusted.
    case consentRecordUnreadable
    /// The OCR pass could not be performed at all.
    case ocrPassFailed
    /// The classification pass could not be performed at all.
    case classifyPassFailed
    /// The crop could not be taken from the frame.
    case cropFailed
    /// The mask pass could not be performed at all (opt-in path).
    case maskPassFailed
    /// [YOLO] The object-detector pass could not be performed at all —
    /// the model missing, unloadable, or the Vision request refused. The
    /// resolver degrades to the mask/saliency/pad ladder, never an error
    /// to the elder.
    case yoloPassFailed
    /// The VLM stage failed after its retries — never presented as "no
    /// such object", which is what a successful low-confidence answer
    /// means instead.
    case vlmFailed

    var logSafeErrorCode: String {
        switch self {
        case .consentNotRecorded: return "pointask_consent_not_recorded"
        case .consentDenied: return "pointask_consent_denied"
        case .consentRecordUnreadable: return "pointask_consent_unreadable"
        case .ocrPassFailed: return "pointask_ocr_failed"
        case .classifyPassFailed: return "pointask_classify_failed"
        case .cropFailed: return "pointask_crop_failed"
        case .maskPassFailed: return "pointask_mask_failed"
        case .yoloPassFailed: return "pointask_yolo_failed"
        case .vlmFailed: return "pointask_vlm_failed"
        }
    }
}

/// What the pipeline hands the session: the raw materials of the answer,
/// structured so the session's composition (the spoken line and the card,
/// in the active language) never reaches back into the pipeline. Content
/// lives here and only here — it is spoken, never logged.
struct PointAskFindings: Equatable {

    /// The recognized label text, joined and bounded to the prompt budget.
    var ocrText: String = ""
    /// The dictionary/cache translation of `ocrText`, or nil when the
    /// tiers could not resolve it.
    var translatedText: String?
    /// The classifier's name for the crop, above the configured
    /// confidence floor — Vision's own answer or nothing, never
    /// substituted.
    var classLabel: String?
    var classConfidence: Double = 0
    /// [YOLO] The winning detector box's COCO label, carried from the
    /// resolver's anchored target through the analysis request. When
    /// present it leads the ladder-1 "It looks like …" line ahead of the
    /// crop classifier's name (the detector names the WHOLE object the
    /// elder tapped, the classifier names the crop it boxed).
    var detectedLabel: String?
    /// The VLM answer, when the stage ran and succeeded.
    var vlm: PointAskGuidance?
    /// Whether the VLM stage was reached at all (the switch was on, the
    /// client configured and the gate allowed it). False for every skip
    /// reason.
    var vlmAttempted: Bool = false
    /// The VLM answered below the confidence threshold — the session
    /// appends the hedge line.
    var hedge: Bool = false
    /// The VLM's answer was a medicine refusal — the session speaks the
    /// app-owned refusal copy instead of the identification.
    var medicineRefusal: Bool = false
    /// The shared cost governor's cap stopped the VLM stage; the session
    /// announces it (the shipped `router.capReached` line) and serves the
    /// ladder-1 answer.
    var quotaCapped: Bool = false

    /// Whether anything local is known — OCR text or a class name (the
    /// detector's or the classifier's). The session's honest-failure
    /// decision turns on this: no local content *and* no VLM is the one
    /// case that speaks the failure line.
    var hasLocalContent: Bool {
        !ocrText.isEmpty || classLabel != nil || detectedLabel != nil
    }
}

/// One analysis: the crop (full resolution, for the local passes) and the
/// upload JPEG (≤768 px, for the VLM). Both come from the anchored box —
/// the pipeline never sees the frame.
struct PointAskAnalysisRequest {
    let crop: CVPixelBuffer
    let uploadJPEG: Data
    /// [YOLO] The anchored target's detector label, when the tap box was
    /// a real YOLO detection. Carried into the findings so the session's
    /// ladder-1 composition can name the object.
    var detectedLabel: String? = nil
}

// MARK: - Classification seam

/// The classifier's answer, in Vision's vocabulary.
struct PointAskClassification: Equatable {
    let label: String
    let confidence: Double
}

/// The classification seam: what the crop *is*, answered on device
/// (research §Q6 stage 5: `VNClassifyImageRequest`, 20–60 ms). A protocol
/// so the pipeline's tests drive a fake — the shipped engine is the only
/// production implementation.
protocol PointAskClassificationEngine: AnyObject {

    /// Whether a classification request can be created and run here.
    var supportsClassification: Bool { get }

    /// The crop's top class above the configured floor, or nil when the
    /// classifier cannot name one confidently. Throws when the request
    /// could not be run at all.
    func classify(_ crop: CVPixelBuffer) throws -> PointAskClassification?
}

/// The shipped classifier: `VNClassifyImageRequest` over the crop, with
/// `regionOfInterest` set to the whole crop — stated, not inherited, so
/// the "classify this region, not the frame" intent is the request's own
/// configuration (the same explicitness the shipped object engine
/// documents for its per-box passes).
final class VisionPointAskClassifier: PointAskClassificationEngine {

    private let classifyRequest = VNClassifyImageRequest()
    private let minimumConfidence: Float

    init(minimumConfidence: Float = PointAskConfig.default.classifierMinimumConfidence) {
        self.minimumConfidence = minimumConfidence
    }

    /// The request exists on every OS this app deploys to (image
    /// classification is an iOS 13 API); there is no honest "no" a probe
    /// could return here. A device where the request cannot be *run* is
    /// handled where it happens: the pass throws and the pipeline degrades
    /// with its own event.
    var supportsClassification: Bool { true }

    func classify(_ crop: CVPixelBuffer) throws -> PointAskClassification? {
        // The crop *is* the region of interest: stated explicitly, so the
        // request's scope cannot drift to a default that reads more than
        // the tapped box.
        classifyRequest.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        let handler = VNImageRequestHandler(cvPixelBuffer: crop, options: [:])
        do {
            try handler.perform([classifyRequest])
        } catch {
            throw PointAskError.classifyPassFailed
        }
        guard let top = classifyRequest.results?.first,
              top.confidence >= minimumConfidence else { return nil }
        return PointAskClassification(label: top.identifier, confidence: Double(top.confidence))
    }
}

// MARK: - The pipeline

/// The analysis stage, as an actor: one pass per chip tap, all state
/// confined, findings handed over in one whole value (the
/// `LiveTranslationPipeline` shape).
actor PointAskAnalysisPipeline {

    private let ocrEngine: LiveTextRecognitionEngine
    private let classifier: PointAskClassificationEngine
    private let cache: LabelTranslationCache
    private let consentGate: PointAskConsentGate
    private let client: GeminiClient
    private let config: PointAskConfig
    private let events: PointAskEvents
    private let targetLanguage: AppLanguage

    init(ocrEngine: LiveTextRecognitionEngine,
         classifier: PointAskClassificationEngine,
         cache: LabelTranslationCache,
         consentGate: PointAskConsentGate,
         client: GeminiClient,
         targetLanguage: AppLanguage,
         config: PointAskConfig = .default,
         observabilityBus: ObservabilityBus) {
        self.ocrEngine = ocrEngine
        self.classifier = classifier
        self.cache = cache
        self.consentGate = consentGate
        self.client = client
        self.targetLanguage = targetLanguage
        self.config = config
        self.events = PointAskEvents(bus: observabilityBus, config: config)
    }

    /// Runs one analysis to completion — every stage the ladder reaches,
    /// with the OCR and classification passes run in parallel (they read
    /// different engines and different request objects), the translation
    /// after them (it needs the recognized text), and the consent-gated
    /// VLM last. The session's answer is composed from the returned
    /// findings; nothing here speaks or renders.
    func analyze(_ request: PointAskAnalysisRequest,
                 cloudEnabled: Bool) async -> PointAskFindings {
        var findings = PointAskFindings()
        // [YOLO] The resolver's winning label rides the request into the
        // findings — the pipeline is the single place the answer's raw
        // materials are assembled, and content stays out of events.
        findings.detectedLabel = request.detectedLabel

        // Stages 3 + 5 run in parallel; stage 4 (translation) follows
        // because its input is the OCR stage's output. The engines are
        // captured into locals: the stage bodies run in their own tasks,
        // off the actor, and only plain values may cross that boundary.
        let ocrEngine = self.ocrEngine
        let classifier = self.classifier
        async let ocr = runStage(timeout: config.ocrStageTimeoutSeconds, drain: nil) {
            try ocrEngine.recognizeText(in: request.crop)
        }
        async let classification = runStage(timeout: config.classifyStageTimeoutSeconds, drain: nil) {
            try classifier.classify(request.crop)
        }
        let ocrOutcome = await ocr
        let classOutcome = await classification

        switch ocrOutcome.value {
        case .success(let regions):
            let joined = regions.map(\.text).joined(separator: " ")
            findings.ocrText = String(joined.prefix(config.promptTextMaxLength))
            events.ocrCompleted(count: regions.count, durationMs: ocrOutcome.durationMs)
        case .failure:
            events.ocrFailed(reason: .requestFailed, durationMs: ocrOutcome.durationMs)
        case .timeout:
            events.ocrFailed(reason: .stageTimeout, durationMs: ocrOutcome.durationMs)
        }

        switch classOutcome.value {
        case .success(let classification):
            if let classification {
                findings.classLabel = classification.label
                findings.classConfidence = classification.confidence
            }
            events.classifyCompleted(durationMs: classOutcome.durationMs)
        case .failure:
            events.classifyFailed(reason: .requestFailed, durationMs: classOutcome.durationMs)
        case .timeout:
            events.classifyFailed(reason: .stageTimeout, durationMs: classOutcome.durationMs)
        }

        // Stage 4: dictionary/cache translation of what OCR found. The
        // cache is lock-guarded and self-healing; a fault is the same
        // honest miss as an absent entry (FR-LCT-023).
        let translateStart = Date()
        if findings.ocrText.isEmpty {
            events.translateCompleted(count: 0, durationMs: Self.msSince(translateStart))
        } else {
            switch cache.lookup(text: findings.ocrText, targetLanguage: targetLanguage) {
            case .success(.some(let hit)):
                findings.translatedText = hit.translation
            case .success(.none), .failure:
                break
            }
            events.translateCompleted(count: findings.translatedText == nil ? 0 : 1,
                                      durationMs: Self.msSince(translateStart))
        }

        // Stage 7: the consent-gated VLM, only when the master switch is
        // on — the gate itself is consulted per attempt inside the stage.
        if cloudEnabled {
            await vlmStage(into: &findings, request: request)
        } else {
            events.vlmSkipped(reason: .cloudDisabled)
        }

        let confidence = findings.vlm.map(\.confidence)
        events.analysisAnswered(origin: findings.vlm != nil ? .vlm : .localLadder,
                                confidence: confidence,
                                count: findings.ocrText.isEmpty ? 0 : 1)
        return findings
    }

    // MARK: The VLM stage (consent-gated)

    private func vlmStage(into findings: inout PointAskFindings,
                          request: PointAskAnalysisRequest) async {
        guard client.isAvailable else {
            // Cloud unconfigured is not an error: the ladder-1 answer is
            // the product (design §3 ladder 4). The switch stays on, the
            // Settings leaf (Phase 2) shows the state.
            events.vlmSkipped(reason: .cloudDisabled)
            return
        }

        // The gate is consulted per attempt — the retry included — and
        // the proof is minted inside the loop, so a revocation between
        // attempts blocks the retry rather than re-sending under a grant
        // the elder withdrew (AM-1).
        var attempts = 0
        while attempts <= config.vlmMaxRetries {
            attempts += 1
            let grant: PointAskConsentGate.Grant
            switch consentGate.authorize() {
            case .success(let minted):
                grant = minted
            case .failure(let error):
                events.vlmSkipped(reason: Self.skipReason(for: error))
                return
            }
            findings.vlmAttempted = true

            switch await attemptVLM(request: request, grant: grant, ocrHint: ocrHint(from: findings)) {
            case .answer(let guidance):
                if guidance.isMedicine {
                    // The model's own words are dropped for a refusal: the
                    // session speaks the app-owned copy (design §1 item 4).
                    findings.medicineRefusal = true
                    findings.vlm = nil
                } else {
                    findings.vlm = guidance
                    findings.hedge = guidance.confidence < config.vlmConfidenceThreshold
                }
                return
            case .quota:
                findings.quotaCapped = true
                return
            case .failure:
                continue
            }
        }
        // Every attempt failed: the findings carry no VLM answer and the
        // session falls to the ladder-1 answer (or the honest failure
        // line when there is nothing local either).
        findings.vlm = nil
    }

    /// The OCR text the VLM prompt is handed, after the injection check:
    /// a marker-bearing label is withheld rather than injected into the
    /// prompt (the `InputSanitiser` contract — ask, never copy).
    private func ocrHint(from findings: PointAskFindings) -> String? {
        let hint = findings.ocrText
        guard !hint.isEmpty, !InputSanitiser.containsInjectionMarker(hint) else { return nil }
        return hint
    }

    private enum VLMAttemptOutcome {
        case answer(PointAskGuidance)
        case quota
        case failure
    }

    private func attemptVLM(request: PointAskAnalysisRequest,
                            grant: PointAskConsentGate.Grant,
                            ocrHint: String?) async -> VLMAttemptOutcome {
        let start = Date()
        // The client is captured into a local for the same reason the
        // stage bodies are: the attempt's task runs off the actor, and
        // only plain values cross that boundary.
        let client = self.client
        let languageHint = targetLanguage.rawValue
        let attempt = Task {
            try await client.identifyPointAsk(
                imageData: request.uploadJPEG,
                mimeType: "image/jpeg",
                ocrText: ocrHint,
                languageHint: languageHint,
                grant: grant)
        }
        // Registration is the cancellation seam: a revocation ends this
        // attempt rather than retrying it (AM-1).
        let registration = consentGate.registerInFlight { attempt.cancel() }
        let outcome: VLMAttemptOutcome
        do {
            let guidance = try await attempt.value
            events.vlmCompleted(confidence: guidance.confidence,
                                durationMs: Self.msSince(start))
            outcome = .answer(guidance)
        } catch GeminiClient.GeminiClientError.dailyCapReached {
            events.vlmSkipped(reason: .quotaCapped)
            outcome = .quota
        } catch is CancellationError {
            events.vlmSkipped(reason: .revoked)
            outcome = .failure
        } catch GeminiClient.GeminiClientError.emptyResponse {
            events.vlmFailed(reason: .parseFailed, durationMs: Self.msSince(start))
            outcome = .failure
        } catch {
            events.vlmFailed(reason: .transportFailed, durationMs: Self.msSince(start))
            outcome = .failure
        }
        registration.release()
        return outcome
    }

    private static func skipReason(for error: PointAskError) -> PointAskCloudSkipReason {
        switch error {
        case .consentNotRecorded: return .consentNotRecorded
        case .consentDenied: return .consentDenied
        case .consentRecordUnreadable: return .consentUnreadable
        default: return .cloudDisabled
        }
    }

    // MARK: Bounded stages

    /// One local stage under its configured deadline.
    ///
    /// The pass runs in its own task; the deadline task races it. On a
    /// timeout the pipeline **stops waiting** — the pass finishes (or
    /// does not) with nobody listening, exactly the live-translate
    /// pipeline's stage-deadline shape (`brainTranslationStageDeadlineSeconds`:
    /// "a stage that failed to end must not hold the answer open"). The
    /// returned task is the drain: the caller awaits it before the *next*
    /// stage, so the shared Vision engine is never asked for two passes
    /// at once, whatever the deadline did.
    private func runStage<T: Sendable>(
        timeout: TimeInterval,
        drain: Task<Void, Never>?,
        _ body: @escaping @Sendable () throws -> T
    ) async -> StageOutcome<T> {
        if let drain { await drain.value }
        let start = Date()
        let attempt = Task<Result<T, Error>, Never> {
            do { return .success(try body()) } catch { return .failure(error) }
        }
        let verdict = await withTaskGroup(of: StageVerdict<T>.self) { group in
            group.addTask { .resolved(await attempt.value) }
            group.addTask {
                try? await Task<Never, Never>.sleep(
                    nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return .timedOut
            }
            let winner = await group.next() ?? .timedOut
            // Cancelling the group cancels the *sleep*, never the pass:
            // the attempt task is its own task and finishes on its own.
            group.cancelAll()
            return winner
        }
        // The drain awaits the pass's own end, so the engines stay serial.
        let drainTask = Task<Void, Never> { _ = await attempt.value }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        switch verdict {
        case .resolved(.success(let value)):
            return StageOutcome(value: .success(value), drain: drainTask, durationMs: durationMs)
        case .resolved(.failure):
            return StageOutcome(value: .failure, drain: drainTask, durationMs: durationMs)
        case .timedOut:
            return StageOutcome(value: .timeout, drain: drainTask, durationMs: durationMs)
        }
    }

    private enum StageVerdict<T> {
        case resolved(Result<T, Error>)
        case timedOut
    }

    private static func msSince(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

/// One bounded stage's outcome: what the pass produced, its evidence
/// duration, and the drain the next stage awaits.
struct StageOutcome<T> {
    enum Value {
        case success(T)
        case failure
        case timeout
    }

    let value: Value
    let drain: Task<Void, Never>
    let durationMs: Int
}
