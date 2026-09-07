import Foundation
import UIKit

// MARK: - Bundled manual content model

/// One step of a bundled default manual (2026-09-07, bundled-manuals
/// task). `text` carries the step instruction in every shipped language
/// ("en"/"ne"); `image` (a path relative to the images folder, e.g.
/// "iphone/step-01.png") and `annotation` are optional because content
/// rules only ship an image when a clean official screenshot exists and
/// only annotate an element that is actually visible in it.
struct BundledManualStep: Codable, Equatable {
    let number: Int
    let text: [String: String]
    let image: String?
    let annotation: BundledAnnotation?
}

/// The circled element of one step: its label in every shipped language
/// plus the normalized center of the element in the image, 0–1, top-left
/// origin (measured on the actual downloaded image by the authoring
/// tooling — see Resources/Manuals/README.md).
struct BundledAnnotation: Codable, Equatable {
    let label: [String: String]
    let x: Double
    let y: Double
}

/// One bundled default manual: a manifest.json entry (schema v1). A
/// manual without any annotation decodes fine — its steps render as
/// text-only cards, exactly like unlocalizable photo answers.
struct BundledManual: Codable, Equatable {
    let id: String
    let title: [String: String]
    let overview: [String: String]
    /// Path of the photo shown for the whole manual, relative to the
    /// images folder ("iphone/overview.png" → Manuals/images/iphone/
    /// overview.png). The per-step cards crop THIS image.
    let overviewImage: String
    let steps: [BundledManualStep]
}

// MARK: - Catalog

/// Loads and maps the bundled instruction manuals shipped inside the app
/// bundle under `Manuals/` (blue folder reference in project.yml, so the
/// whole directory — manifest.json + images/ — lands in the bundle
/// preserving its layout).
///
/// Runtime mapping (2026-09-07): a bundled manual is presented through
/// the EXACT same `ApplianceGuidance` shape a fresh photo answer produces
/// — the existing step-card/crop UI renders it unchanged:
///   - identity.category   = the manual's stable id (the content contract
///     says ids are never renumbered/renamed),
///   - identity.displayName = the localized manual title,
///   - steps                = localized step texts, in authoring order,
///   - groundedControls     = one control per annotation, confidence 1.0
///     (content is shipped, not guessed — no hedging), box = the
///     annotation's normalized center ± 0.09 half-extent,
///   - spokenSummary        = the localized overview,
///   - knowledgeSource      = .onDeviceModelKnowledge (it IS on-device
///     content; no web search was involved).
enum BundledManualCatalog {

    /// Envelope compatibility contract (Resources/Manuals/README.md):
    /// bump only for breaking layout/schema changes; old clients must be
    /// able to ignore manuals they do not know.
    static let schemaVersion = 1

    private struct ManifestEnvelope: Decodable {
        let schemaVersion: Int
        let manuals: [BundledManual]
    }

    /// Decodes the manifest from the app bundle. Returns nil when the
    /// manifest is absent, unreadable, malformed, or carries a
    /// schemaVersion this client does not understand — the caller shows
    /// an honest empty state instead of a partial catalog.
    static func loadManifest(bundle: Bundle = .main) -> [BundledManual]? {
        guard let url = bundle.url(forResource: "manifest", withExtension: "json",
                                   subdirectory: "Manuals") else { return nil }
        return loadManifest(from: url)
    }

    /// Pure manifest decode — injectable URL seam for tests (temp dir,
    /// not Bundle.main). Whole-file decode: one malformed manual fails
    /// the load loudly rather than silently dropping content.
    static func loadManifest(from url: URL) -> [BundledManual]? {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(ManifestEnvelope.self, from: data),
              envelope.schemaVersion == schemaVersion else { return nil }
        return envelope.manuals
    }

    /// The manual with the given stable id, or nil.
    static func manual(id: String, bundle: Bundle = .main) -> BundledManual? {
        loadManifest(bundle: bundle)?.first { $0.id == id }
    }

    /// The value of a bilingual text field in `locale`'s language —
    /// Nepali when `ApplianceLabelLocalizer` says the locale is Nepali,
    /// English otherwise; falls back to the other language defensively
    /// (the content contract requires both, so the fallback is never hit
    /// in practice).
    static func localized(_ text: [String: String], locale: Locale) -> String {
        let primary = ApplianceLabelLocalizer.isNepali(locale) ? "ne" : "en"
        let secondary = primary == "en" ? "ne" : "en"
        return text[primary] ?? text[secondary] ?? ""
    }

    /// Resolves a manifest image path ("iphone/step-01.png") to the
    /// actual file inside the bundle's Manuals/images folder. Stem
    /// matching, deliberately extension-agnostic: the image-fetcher may
    /// have saved a .jpg where the manifest says .png (the manifest's
    /// extension is informational), so the FIRST file whose name minus
    /// its extension equals the path's stem wins.
    static func image(named path: String, in bundle: Bundle = .main) -> UIImage? {
        guard let imagesFolder = bundle.url(forResource: "images",
                                            withExtension: nil,
                                            subdirectory: "Manuals") else { return nil }
        return image(named: path, imagesFolder: imagesFolder)
    }

    /// UIImage loading half of `image(named:in:)` — the images folder is
    /// passed in so tests can point it at a temp dir.
    static func image(named path: String, imagesFolder: URL) -> UIImage? {
        guard let url = imageFileURL(named: path, imagesFolder: imagesFolder) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Pure stem-matching file lookup (injectable seam for tests).
    static func imageFileURL(named path: String, imagesFolder: URL) -> URL? {
        let directory = imagesFolder
            .appendingPathComponent((path as NSString).deletingLastPathComponent,
                                    isDirectory: true)
        let stem = (path as NSString).deletingPathExtension
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == stem }
    }

    /// Maps one bundled manual onto the live-answer guidance shape — see
    /// the enum doc for the exact field mapping. `locale` selects the
    /// language for every text field.
    static func guidance(for manual: BundledManual, locale: Locale) -> ApplianceGuidance {
        let halfExtent = 0.09
        let controls = manual.steps.compactMap { step -> GroundedControl? in
            guard let annotation = step.annotation else { return nil }
            return GroundedControl(
                label: localized(annotation.label, locale: locale),
                stepNumber: step.number,
                normalizedBox: NormalizedBox(xMin: annotation.x - halfExtent,
                                             yMin: annotation.y - halfExtent,
                                             xMax: annotation.x + halfExtent,
                                             yMax: annotation.y + halfExtent),
                confidence: 1.0)
        }
        return ApplianceGuidance(
            identity: ApplianceIdentity(brand: nil,
                                        model: nil,
                                        category: manual.id,
                                        displayName: localized(manual.title, locale: locale)),
            steps: manual.steps.map { localized($0.text, locale: locale) },
            groundedControls: controls,
            spokenSummary: localized(manual.overview, locale: locale),
            confidence: 1.0,
            knowledgeSource: .onDeviceModelKnowledge)
    }
}
