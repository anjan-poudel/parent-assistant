import Foundation

// MARK: - Bundled user manual (user-manual-in-app task)

/// One section of the bundled user manual — the phone-friendly structured
/// content behind Settings → Manuals → "User manual". Ships as a plain
/// JSON bundle resource (`Resources/ManualText/userManual.json`, blue
/// folder reference in project.yml) with one entry per section, BILINGUAL
/// like the device manuals: every section carries its title and
/// paragraphs in BOTH shipped languages (`titleEn`/`titleNe`,
/// `paragraphsEn`/`paragraphsNe`), and the viewer resolves the ACTIVE
/// locale at render time (Nepali content for ne-*, English for everything
/// else — the house fallback). No markdown: bullets are plain paragraphs
/// that start with "• ".
struct UserManualSection: Codable, Equatable, Identifiable {
    let id: String
    let titleEn: String
    let titleNe: String
    let paragraphsEn: [String]
    let paragraphsNe: [String]

    /// The section's title in `locale` — Nepali for ne-*, English
    /// otherwise (the unknown-locale fallback). Pure, so the resolution
    /// is pinned by tests without a view.
    func title(locale: Locale) -> String {
        ApplianceLabelLocalizer.isNepali(locale) ? titleNe : titleEn
    }

    /// The section's paragraphs in `locale` — same rule as `title(locale:)`.
    func paragraphs(locale: Locale) -> [String] {
        ApplianceLabelLocalizer.isNepali(locale) ? paragraphsNe : paragraphsEn
    }

    /// True when the section carries usable content in BOTH languages —
    /// a section missing its Nepali translation is invalid, never
    /// silently dropped (the no-missing-translations rule).
    var isValid: Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !titleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !titleNe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let enOK = paragraphsEn.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let neOK = paragraphsNe.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return enOK && neOK
    }
}

/// Loads the bundled user-manual sections. The decode seam is injectable
/// (URL/Data → sections) so tests never depend on bundle contents; the
/// shipped artifact gets one honesty test that skips when the resource is
/// absent (the same pattern as `DialectCentroidTable`'s bundled test).
/// Whole-file decode: a malformed payload fails the load loudly (nil)
/// rather than silently dropping sections — the same rule as
/// `BundledManualCatalog.loadManifest`.
enum UserManualCatalog {

    /// Resource file name, without extension.
    static let bundledResourceName = "userManual"

    /// Bundle subdirectory the resource ships in — the project.yml blue
    /// folder reference lands `Resources/ManualText` as `ManualText/` in
    /// the app bundle.
    static let bundledSubdirectory = "ManualText"

    /// The shipped resource's URL inside `bundle`, or nil when absent.
    static func bundledURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: bundledResourceName,
                   withExtension: "json",
                   subdirectory: bundledSubdirectory)
    }

    /// Decodes the section list from a JSON file URL.
    static func loadSections(from url: URL) -> [UserManualSection]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return loadSections(from: data)
    }

    /// Decodes the section list from raw JSON data.
    static func loadSections(from data: Data) -> [UserManualSection]? {
        try? JSONDecoder().decode([UserManualSection].self, from: data)
    }

    /// The shipped sections, or nil when the resource is absent or
    /// malformed — the viewer shows an honest empty state instead of a
    /// partial manual (constitution: no silent stubs).
    static func bundledSections(bundle: Bundle = .main) -> [UserManualSection]? {
        guard let url = bundledURL(bundle: bundle) else { return nil }
        return loadSections(from: url)
    }
}
