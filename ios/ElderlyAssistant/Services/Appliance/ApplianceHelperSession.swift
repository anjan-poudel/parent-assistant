import Foundation
import UIKit

/// One capture→answer session of the appliance helper: owns the pipeline
/// from a captured photo to a presented `ApplianceGuidance`, so
/// `ApplianceHelperView` stays a dumb renderer and the flow itself stays
/// unit-testable against a fake `GeminiTransport`.
///
/// Pipeline (design §2 + addendum §12.2):
///   1. Uniform-scale the photo (never crop — §5.3) and hash the JPEG.
///   2. Photo-hash cache lookup → instant hit, zero network.
///   3. `identifyAppliance` (photo + Gemini's own knowledge).
///   4. Confidence < 0.4 → check the brand+model cache for a better
///      existing answer for the SAME appliance (this is the design §2's
///      "checked AFTER the call too": brand+model only becomes knowable
///      once the call returns) — else ONE search-grounded retry
///      (addendum §12.2's verified manual-substitute).
///   5. Cache the winner under both keys; present + speak the summary.
@MainActor
final class ApplianceHelperSession: ObservableObject {

    /// What the sheet renders. `.capturing` shows the camera affordance,
    /// `.working` a spinner, `.guidance` the photo + overlay + steps card,
    /// `.unavailable` a localized, honest failure with a retry affordance
    /// (constitution: no silent stubs).
    enum State: Equatable {
        case capturing
        case working
        case guidance(ApplianceGuidancePolicy.Presentation, image: UIImage)
        case unavailable(message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.capturing, .capturing), (.working, .working): return true
            case let (.guidance(lp, _), .guidance(rp, _)): return lp == rp
            case let (.unavailable(lm), .unavailable(rm)): return lm == rm
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .capturing

    /// The elder's question from the voice turn (nil = general how-to-use).
    let question: String?
    let locale: Locale

    private let geminiClient: GeminiClient
    private let cache: ApplianceCache
    private let observabilityBus: ObservabilityBus
    private let speaker: Speaker?

    /// Serializes capture handling (a double-tap on the shutter must not
    /// start two overlapping Gemini calls).
    private var inFlight = false

    /// Nonisolated so `presentationView(for:)` (called synchronously, off
    /// the main actor, by `CommandRouter`) can build the session; all
    /// state mutations after init are main-confined by the class.
    nonisolated init(question: String?, locale: Locale, geminiClient: GeminiClient,
                     cache: ApplianceCache, observabilityBus: ObservabilityBus, speaker: Speaker?) {
        self.question = question
        self.locale = locale
        self.geminiClient = geminiClient
        self.cache = cache
        self.observabilityBus = observabilityBus
        self.speaker = speaker
    }

    private var languageHint: String {
        locale.language.languageCode?.identifier ?? "ne"
    }

    /// Entry point from the camera picker.
    func handleCapturedPhoto(_ image: UIImage) {
        guard !inFlight else { return }
        inFlight = true
        state = .working
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            await self.runPipeline(image)
        }
    }

    /// "Try again" from an error or the closer-photo hint.
    func retake() {
        guard !inFlight else { return }
        state = .capturing
    }

    // MARK: - Pipeline

    private func runPipeline(_ image: UIImage) async {
        guard let prepared = ApplianceImagePreparer.prepare(image) else {
            emit("appliance_prepare_failed", outcome: "failure")
            state = .unavailable(message: L10n.str("appliance.error.photoUnusable", locale: locale))
            return
        }

        // 2. Photo-hash cache hit — zero network.
        if let hit = cache.lookup(photoHash: prepared.photoHash) {
            emit("gemini_vision_cache_hit", outcome: "success",
                 metadata: ["via": "photo_hash", "stale": hit.stale ? "true" : "false"])
            present(hit.entry.guidance, image: prepared.image)
            return
        }

        // 3. Photo-only identify.
        let fresh: ApplianceGuidance
        do {
            fresh = try await geminiClient.identifyAppliance(
                imageData: prepared.jpegData, mimeType: "image/jpeg",
                question: question, languageHint: languageHint)
        } catch {
            emit("appliance_identify_failed", outcome: "failure",
                 errorCode: String(describing: error))
            state = .unavailable(message: Self.failureMessage(for: error, locale: locale))
            return
        }

        // 4a. Low confidence → brand+model cache may already hold a better
        // answer for this same appliance (design §2's post-call check).
        if fresh.confidence < ApplianceGuidancePolicy.identificationConfidenceThreshold,
           let key = fresh.identity.brandModelKey,
           let cached = cache.lookup(brandModelKey: key),
           cached.entry.guidance.confidence >= ApplianceGuidancePolicy.identificationConfidenceThreshold {
            emit("gemini_vision_cache_hit", outcome: "success",
                 metadata: ["via": "brand_model", "stale": cached.stale ? "true" : "false"])
            // Keep the fresh photo-hash answer too — a retake of THIS
            // exact frame should hit its own question's answer.
            cache.store(fresh, photoHash: prepared.photoHash)
            present(cached.entry.guidance, image: prepared.image)
            return
        }

        // 4b. Low confidence → ONE search-grounded retry (addendum §12.2:
        // never grounded by default; reserved for the tier photo-only is
        // honestly unconfident about).
        var winner = fresh
        if fresh.confidence < ApplianceGuidancePolicy.identificationConfidenceThreshold,
           let grounded = try? await geminiClient.identifyAppliance(
               imageData: prepared.jpegData, mimeType: "image/jpeg",
               question: question, languageHint: languageHint,
               allowSearchGrounding: true),
           grounded.confidence > fresh.confidence {
            winner = grounded
        }

        // 5. Cache under both keys and present (even a still-low-confidence
        // winner — §4.1: hedge, never refuse).
        cache.store(winner, photoHash: prepared.photoHash)
        present(winner, image: prepared.image)
    }

    private func present(_ guidance: ApplianceGuidance, image: UIImage) {
        let presentation = ApplianceGuidancePolicy.presentation(for: guidance)
        state = .guidance(presentation, image: image)
        // Spoken immediately; the full step list stays on screen for as
        // long as the elder wants to re-read it (design §2 — never rely
        // on hearing alone). Hedged answers SAY the hedge first (§4.1).
        var spoken = guidance.spokenSummary
        if presentation.hedged {
            spoken = L10n.str("appliance.hedgePrefix", locale: locale) + " " + spoken
        }
        if !spoken.isEmpty {
            let locale = self.locale
            Task { await self.speaker?.speak(spoken, locale: locale) }
        }
    }

    /// Localized, distinguishable failures (design §7): timeout, offline,
    /// and "can't help" are different situations and must not share one
    /// generic message.
    static func failureMessage(for error: Error, locale: Locale) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return L10n.str("appliance.error.offline", locale: locale)
            case NSURLErrorTimedOut:
                return L10n.str("appliance.error.timeout", locale: locale)
            default: break
            }
        }
        return L10n.str("appliance.error.generic", locale: locale)
    }

    private func emit(_ eventType: String, outcome: String, errorCode: String? = nil,
                      metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "plugin_appliance_helper",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }
}
