import XCTest
@testable import ElderlyAssistant

/// Guards the Settings STT-engine list + naming contract. Since the
/// catalog declutter (2026-09-12) the picker/downloads list is CURATED:
/// it offers the best options in preference order, while superseded /
/// CPU-only / lower-quality duplicates stay in the catalog (`all`) but
/// are not offered — a cached one still needs a deletable row. Names are
/// short, mutually distinct, and honest for a non-technical user —
/// language + size or version + runtime where it matters, no raw
/// filenames/quantization codes, exactly one "default".
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

    // MARK: - (b) Each name carries a language word AND a class word

    func testSTTDisplayNamesCarryLanguageAndClassWords() {
        let languageWords = ["nepali", "english", "multilingual"]
        // Size OR version: the renaming scheme (2026-09-12) replaced the
        // medium-v5/v6 size words with the version the fine-tune is
        // known by — that IS the honest class marker for those rows.
        let classWords = ["small", "medium", "large", "v5", "v6"]
        for entry in allSTTEntries {
            let name = entry.displayName.lowercased()
            XCTAssertTrue(languageWords.contains { name.contains($0) },
                          "'\(entry.displayName)' must name its language "
                          + "(Nepali / English / Multilingual)")
            XCTAssertTrue(classWords.contains { name.contains($0) },
                          "'\(entry.displayName)' must carry a plain-word size "
                          + "(Small / Medium / Large) or version (v5 / v6), "
                          + "not a model code")
        }
    }

    func testSTTDisplayNamesExposeNoRawIdentifiers() {
        let forbidden = ["ggml", ".bin", "q5", "q8", "q4",
                         "kiranpantha", "distill", "legacy"]
        // ("fine-tun" dropped 2026-09-06: the teacher's displayName
        // legitimately says "fine-tuned" — the word describes what the
        // model IS for the household, not an internal token. "stt —" and
        // "ane" dropped 2026-09-12: the renaming scheme prefixes every
        // row with the modality ("Nepali STT — …") and states the runtime
        // where it matters ("· fast (ANE)"). "legacy" stays forbidden
        // here — only the hidden LLaMA brains carry it.)
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

    // MARK: - Curation: what the picker/downloads list offers

    /// The declutter rule (2026-09-12): the list is CURATED and in
    /// preference order — v6 first (best accuracy), then the ANE fast
    /// path, then the bundled default, then the fallbacks.
    ///
    /// Updated 2026-09-16 (per-language defaults PR): the v6 ANE leads,
    /// because it is both the best-measured accuracy on the fast path AND
    /// the ne auto-switch target (`ModelCatalog.languageDefaultPicks`) —
    /// the picker's first row is deliberately the model a language switch
    /// lands on. `whisperKitNepaliMedium` (the v3 ANE) is listed: 02b2596
    /// re-offered it on user request, because the v6 **q6** quant mangled
    /// short medication phrases; the v6 entry now ships the **q8** rebuild,
    /// so v6 keeps the lead.
    func testAvailableSTTEntriesIsTheCuratedListInPreferenceOrder() {
        XCTAssertEqual(ModelCatalog.availableSTTEntries.map(\.id),
                       [ModelCatalog.whisperKitMediumV6,
                        ModelCatalog.whisperMediumV6,
                        ModelCatalog.whisperKitNepaliMedium,
                        ModelCatalog.whisperMediumV5,
                        ModelCatalog.whisperKitMediumV5,
                        ModelCatalog.whisperKitNepali,
                        ModelCatalog.whisperKitNepaliLargeBase,
                        ModelCatalog.whisperMediumFinetunedNepali,
                        ModelCatalog.whisperFinetunedNepaliQ8,
                        ModelCatalog.whisperSmallMultilingual,
                        ModelCatalog.whisperBaseEn],
                       "The picker/downloads list is curated: best options "
                       + "first, superseded engines gone (they stay in `all`)")
    }

    /// Superseded / CPU-only / duplicate-quality engines must not be
    /// offered — but must stay in the catalog so a device that cached one
    /// can still see and delete it.
    func testSupersededSTTEnginesAreNotOfferedButStayDeletable() {
        let offered = Set(ModelCatalog.availableSTTEntries.map(\.id))
        let hidden = [ModelCatalog.whisperLargeV3Nepali,     // CPU-only Large
                      ModelCatalog.whisperLargeV3NepaliV2,   // CPU-only, never beat its base
                      ModelCatalog.whisperFinetunedNepali,   // q5_0 of the q8 small
                      ModelCatalog.whisperSmallNepali]       // mid-training distill
        for id in hidden {
            XCTAssertFalse(offered.contains(id),
                           "\(id.rawValue) is decluttered — must not be offered")
            XCTAssertNotNil(ModelCatalog.entry(for: id),
                            "\(id.rawValue) must stay in `all` so a cached "
                            + "device can still delete it")
        }
        // The v3 ANE is offered again (02b2596, user-requested) — it is not
        // a hidden entry. Pinned so a future declutter has to be deliberate.
        XCTAssertTrue(offered.contains(ModelCatalog.whisperKitNepaliMedium),
                      "the v3 ANE was re-offered for the q6-mangling window; "
                      + "hiding it again is a product decision, not a cleanup")
        XCTAssertEqual(offered.count + hidden.count, allSTTEntries.count,
                       "curated + hidden must account for every STT entry — "
                       + "a new engine has to be classified deliberately")
    }

    func testTheBundledDefaultIsStillOffered() {
        // v6 leads on accuracy now, so the bundled default is no longer
        // first — but it must remain selectable (and marked as default).
        XCTAssertTrue(ModelCatalog.availableSTTEntries.contains {
            $0.id == ModelCatalog.whisperMediumFinetunedNepali
        })
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

    // MARK: - Settings section headers (STT/brain split, 2026-09-12)

    func testSettingsSectionHeadersAreLocalizedEnAndNe() {
        // The split surfaces ("Speech recognition" / "Assistant brain")
        // must read in the household's language like every other row — and
        // so must the translation card's header and its note
        // ([TRANSLATION-MODEL-ROW], 2026-09-18), which are the only copy on
        // the screen explaining what that model is for and that a phone may
        // hold it without being able to run it.
        for key in ["settings.stt.section", "settings.brain.section",
                    "settings.translation.section", "settings.translation.note"] {
            let en = L10n.str(key, locale: Locale(identifier: "en"))
            let ne = L10n.str(key, locale: Locale(identifier: "ne-NP"))
            XCTAssertNotEqual(en, key, "\(key) must have an English value")
            XCTAssertNotEqual(ne, key, "\(key) must have a Nepali value")
            XCTAssertNotEqual(en, ne, "\(key) must actually be translated")
        }
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
