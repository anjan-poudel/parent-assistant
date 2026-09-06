import XCTest
@testable import ElderlyAssistant

/// Guards the Settings STT-engine list + naming contract (STT-picker task):
/// the picker offers EVERY catalog STT engine (cached or not) and the
/// downloads list covers the same set, placeholder-only entries stay out
/// of both, and display names are short, mutually distinct, and honest
/// for a non-technical user — language + plain-word size + runtime where
/// it matters, no raw filenames/quantization codes, exactly one "default".
final class ModelCatalogSTTNamingTests: XCTestCase {

    private var allSTTEntries: [ModelCatalogEntry] {
        ModelCatalog.entries(kind: .whisperBase)
    }

    private func duplicates(in names: [String]) -> [String] {
        Dictionary(grouping: names, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
    }

    // MARK: - (a) Every STT display name is unique

    func testSTTDisplayNamesAreUnique() {
        let names = allSTTEntries.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "Each STT engine needs its own readable name — near-duplicates: "
                       + duplicates(in: names).joined(separator: ", "))
    }

    // MARK: - (b) Each name carries a language word AND a size word

    func testSTTDisplayNamesCarryLanguageAndSizeWords() {
        let languageWords = ["nepali", "english", "multilingual"]
        let sizeWords = ["small", "medium", "large"]
        for entry in allSTTEntries {
            let name = entry.displayName.lowercased()
            XCTAssertTrue(languageWords.contains { name.contains($0) },
                          "'\(entry.displayName)' must name its language "
                          + "(Nepali / English / Multilingual)")
            XCTAssertTrue(sizeWords.contains { name.contains($0) },
                          "'\(entry.displayName)' must carry a plain-word size "
                          + "(Small / Medium / Large), not a model code")
        }
    }

    func testSTTDisplayNamesExposeNoRawIdentifiers() {
        let forbidden = ["ggml", ".bin", "q5", "q8", "q4", "ane",
                         "kiranpantha", "stt —", "distill", "fine-tun", "legacy"]
        for entry in allSTTEntries {
            let name = entry.displayName.lowercased()
            for token in forbidden {
                XCTAssertFalse(name.contains(token),
                               "'\(entry.displayName)' leaks internal token '\(token)'")
            }
        }
    }

    // MARK: - (c) Exactly one entry claims to be the default

    func testExactlyOneSTTEntryMarkedDefault() {
        let marked = allSTTEntries.filter { $0.displayName.lowercased().contains("default") }
        XCTAssertEqual(marked.map(\.id), [ModelCatalog.whisperMediumFinetunedNepali],
                       "Exactly one STT engine may be marked default — got "
                       + marked.map { $0.id.rawValue }.joined(separator: ", "))
    }

    // MARK: - Selectable/downloadable set covers the catalog, minus placeholders

    func testAvailableSTTEntriesOffersEveryPickableEngine() {
        let available = ModelCatalog.availableSTTEntries
        let offered = Set(available.map(\.id))
        let expected = Set(allSTTEntries.map(\.id))
            .subtracting([ModelCatalog.whisperKitNepali])
        XCTAssertEqual(offered, expected,
                       "Picker/downloads must offer every catalog STT engine "
                       + "except placeholder-only entries")
        // Regression: engines the old requiredModelIds list omitted from
        // the Settings screen entirely (cached or otherwise).
        for id in [ModelCatalog.whisperFinetunedNepali,
                   ModelCatalog.whisperSmallNepali,
                   ModelCatalog.whisperBaseEn,
                   ModelCatalog.whisperKitNepaliMedium] {
            XCTAssertTrue(offered.contains(id), "\(id.rawValue) must be offered")
        }
    }

    func testAvailableSTTEntriesDefaultComesFirst() {
        XCTAssertEqual(ModelCatalog.availableSTTEntries.first?.id,
                       ModelCatalog.whisperMediumFinetunedNepali,
                       "The bundled default should lead the picker")
    }

    // MARK: - L10n catalog agrees with the canonical English names

    func testEnglishL10nNamesMatchCatalogDisplayNames() {
        let en = Locale(identifier: "en")
        for entry in ModelCatalog.availableSTTEntries {
            XCTAssertEqual(entry.displayName(locale: en), entry.displayName,
                           "model.name.\(entry.id.rawValue) English value drifted "
                           + "from the catalog displayName")
        }
    }

    func testNepaliSTTNamesAreAlsoDistinct() {
        let ne = Locale(identifier: "ne-NP")
        let names = ModelCatalog.availableSTTEntries.map { $0.displayName(locale: ne) }
        XCTAssertEqual(Set(names).count, names.count,
                       "Nepali picker rows must stay distinguishable too: "
                       + duplicates(in: names).joined(separator: ", "))
    }

    // MARK: - Picker option-label helper (installed vs not-yet-downloaded)

    func testSTTPickerLabelNamesNotDownloadedStateHonestly() {
        let en = Locale(identifier: "en")
        let entry = ModelCatalog.entry(for: ModelCatalog.whisperMediumFinetunedNepali)!
        let name = entry.displayName(locale: en)

        // Installed: plain name, no suffix.
        XCTAssertEqual(AIModelsSettingsView.sttOptionLabel(entry: entry,
                                                           downloaded: true,
                                                           locale: en), name)
        // Not installed: same name plus an honest marker.
        let label = AIModelsSettingsView.sttOptionLabel(entry: entry,
                                                        downloaded: false,
                                                        locale: en)
        XCTAssertTrue(label.contains(name), label)
        XCTAssertTrue(label.lowercased().contains("not downloaded"), label)
    }

    func testSTTPickerOptionLabelNeverDuplicatesAutomaticOption() {
        // The "Automatic" (nil) option is the picker's first row; a
        // model name must never read like the automatic choice.
        for entry in ModelCatalog.availableSTTEntries {
            XCTAssertFalse(entry.displayName.lowercased().contains("automatic"),
                           entry.displayName)
        }
    }
}
