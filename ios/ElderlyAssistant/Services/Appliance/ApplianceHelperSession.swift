import Foundation
import UIKit

/// One capture→answer session of the appliance helper: owns the pipeline
/// from a captured photo to a presented `ApplianceGuidance`, so
/// `ApplianceHelperView` stays a dumb renderer and the flow itself stays
/// unit-testable against a fake `GeminiTransport`.
///
/// Pipeline (design §2 + addendum §12.2, duplicate detection extended
/// 2026-09-06 — local-cache-manuals):
///   1. Uniform-scale the photo (never crop — §5.3) and hash the JPEG.
///   2. Question-aware cache lookup, FIRST (no LLM call on a hit):
///      a. exact photo-hash key — same photo bytes AND same question;
///      b. appliance identity (brand+model) + question key — checked
///         once the identify call names the appliance (identity is only
///         knowable after Gemini sees the photo), replacing the old
///         bare brand+model check with one that never answers a
///         different question from cache.
///   3. `identifyAppliance` (photo + Gemini's own knowledge).
///   4. Confidence < 0.4 → identity+question cache lookup for the SAME
///      appliance+question answered better before — else ONE
///      search-grounded retry (addendum §12.2's verified
///      manual-substitute).
///   5. Cache the winner under the photo-hash+question key, together
///      with a downscaled photo copy — that entry is the saved "manual"
///      the manuals library lists and re-renders with zero network.
///   6. Present + speak the summary.
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

    /// True while `.guidance` shows a SAVED MANUAL opened from the
    /// library (camera-less, read-only) rather than a fresh answer — the
    /// view hides the retake/closer-photo affordances that only make
    /// sense mid-capture.
    @Published private(set) var isViewingManual = false
    /// Per-step images for a presented BUNDLED manual, keyed by step
    /// number (2026-09-07) — step annotations are measured on the step's
    /// own screenshot, not the overview.
    @Published private(set) var bundledStepImages: [Int: UIImage] = [:]

    /// The elder's question from the voice turn (nil = general how-to-use).
    let question: String?
    let locale: Locale

    /// Internal so the manuals library (same feature surface) can read
    /// the entry list for its rows.
    let cache: ApplianceCache

    private let geminiClient: GeminiClient
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
        isViewingManual = false
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
        isViewingManual = false
        state = .capturing
    }

    // MARK: - Manuals library (cache-only re-render)

    /// Opens a SAVED manual as guidance rendered entirely from the cache —
    /// no camera, no Gemini. Same `present` path as a fresh answer, so the
    /// existing per-step card UI (zoomable close-ups included) renders the
    /// stored guidance + its stored photo.
    ///
    /// Returns false when the manual is no longer in the cache (deleted
    /// elsewhere) or its photo is unreadable — the caller then stays in
    /// the library rather than showing a fabricated result.
    func presentManual(entryID: UUID) -> Bool {
        guard let hit = cache.lookup(entryID: entryID),
              let jpeg = cache.imageJPEG(entryID: entryID),
              let image = UIImage(data: jpeg) else { return false }
        isViewingManual = true
        present(hit.entry.guidance, image: image)
        return true
    }

    /// Opens a BUNDLED default manual (2026-09-07, bundled-manuals task):
    /// the shipped catalog replaces both camera and Gemini — zero
    /// network, zero identification. `BundledManualCatalog` maps the
    /// manual onto the same `ApplianceGuidance` shape a fresh photo
    /// answer produces, so the existing per-step card UI (zoomable
    /// close-ups included) renders it unchanged against the manual's
    /// overview image.
    ///
    /// `locale` selects the catalog's language for the spoken summary,
    /// card text, and control labels. Returns false when the overview
    /// image cannot be loaded (the images folder is a separate content
    /// deliverable) — the caller then stays put rather than presenting a
    /// broken photo-less manual.
    func presentBundledManual(_ manual: BundledManual, locale: Locale) -> Bool {
        guard let image = BundledManualCatalog.image(named: manual.overviewImage) else { return false }
        isViewingManual = true
        var stepImages: [Int: UIImage] = [:]
        for step in manual.steps {
            if let name = step.image,
               let stepImage = BundledManualCatalog.image(named: name) {
                stepImages[step.number] = stepImage
            }
        }
        bundledStepImages = stepImages
        present(BundledManualCatalog.guidance(for: manual, locale: locale), image: image)
        return true
    }

    // MARK: - Pipeline

    private func runPipeline(_ image: UIImage) async {
        guard let prepared = ApplianceImagePreparer.prepare(image) else {
            emit("appliance_prepare_failed", outcome: "failure")
            state = .unavailable(message: L10n.str("appliance.error.photoUnusable", locale: locale))
            return
        }

        // 2a. Question-aware photo-hash duplicate — zero network. The
        // question dimension is load-bearing: the SAME photo asked a
        // different question needs a fresh answer, not the old one.
        if let hit = cache.lookup(photoHash: prepared.photoHash, question: question) {
            emit("appliance_cache_hit", outcome: "success",
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

        // 4a. Identity + question duplicate detection (design §2's
        // post-call cache check, question-aware since 2026-09-06): a weak
        // fresh identification of an appliance whose brand+model already
        // answered THIS question confidently — a re-photograph, or a
        // second unit of the same model — skips the grounded retry and
        // serves the cached guide. Only when the fresh answer is weak: a
        // confident fresh answer is kept, because its boxes belong to the
        // photo in front of the elder. Never matches across questions.
        if fresh.confidence < ApplianceGuidancePolicy.identificationConfidenceThreshold,
           let key = fresh.identity.brandModelKey,
           let cached = cache.lookup(brandModelKey: key, question: question),
           cached.entry.guidance.confidence >= ApplianceGuidancePolicy.identificationConfidenceThreshold {
            emit("appliance_cache_hit", outcome: "success",
                 metadata: ["via": "identity_question", "stale": cached.stale ? "true" : "false"])
            // Keep the fresh photo-hash answer too — a retake of THIS
            // exact frame should hit its own question's answer.
            cache.store(fresh, photoHash: prepared.photoHash, question: question,
                        imageJPEG: Self.thumbnail(of: prepared.image))
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

        // 5. Cache under the photo-hash+question key with the downscaled
        // photo (the saved manual) and present (even a still-low-
        // confidence winner — §4.1: hedge, never refuse).
        cache.store(winner, photoHash: prepared.photoHash, question: question,
                    imageJPEG: Self.thumbnail(of: prepared.image))
        present(winner, image: prepared.image)
    }

    /// The downscaled photo copy kept for cache-only re-render. Prepared
    /// frames are at most 1024px; the copy is ~256px — see
    /// `ApplianceImagePreparer.thumbnailLongEdge`.
    private static func thumbnail(of preparedImage: UIImage) -> Data? {
        ApplianceImagePreparer.thumbnailJPEG(of: preparedImage)
    }

    private func present(_ guidance: ApplianceGuidance, image: UIImage) {
        let presentation = ApplianceGuidancePolicy.presentation(for: guidance)
        state = .guidance(presentation, image: image)
        // Spoken immediately (also when a saved manual opens — the elder
        // asked to see it, hearing the summary first matches how every
        // other guidance arrives); the full step list stays on screen for
        // as long as the elder wants to re-read it (design §2 — never
        // rely on hearing alone). Hedged answers SAY the hedge first (§4.1).
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
