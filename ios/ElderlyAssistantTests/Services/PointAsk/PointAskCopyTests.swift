import XCTest
@testable import ElderlyAssistant

/// The point, tap & ask copy surface (design §1, §5, §6): every user-visible
/// string is a catalog entry with a Nepali (Devanagari) value, the consent
/// copy clones the shipped `livetranslate.consent.*` formula, the cloud
/// switch says what "off" means, the camera purpose sentence discloses the
/// point-ask send, the disclosure version is stamped — and **no image
/// leaves the device without a consent Grant** (AM-7), checked at the
/// source.
///
/// The copy itself follows the shipped consent formula the owner has
/// already reviewed; these tests assert properties (present, localised,
/// disclosed, formula-preserving), not the reviewer's final wording.
final class PointAskCopyTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    /// The feature's copy surfaces. Every one must resolve in both languages.
    private let featureKeys = [
        "pointask.chip.label",
        "pointask.cloudIndicator.label",
        "pointask.answer.looksLike",
        "pointask.answer.labelSays",
        "pointask.answer.medicineRefusal",
        "pointask.state.failed",
        "pointask.consent.title",
        "pointask.consent.body",
        "pointask.consent.grant",
        "pointask.consent.decline",
        "pointask.consent.failed",
        "pointask.consent.grantedTitle",
        "pointask.consent.grantedNote",
        "pointask.consent.revoke",
        "pointask.consent.revokeFailedTitle",
        "pointask.consent.revokeFailedNote",
        "pointask.settings.cloud.title",
        "pointask.settings.cloud.note"
    ]

    /// Devanagari (U+0900–U+097F), by scalar — not by regular expression
    /// (`range(of:options:.regularExpression)` declines any match whose
    /// range would split a grapheme cluster; the shipped live-translate
    /// copy tests record both defects).
    private func hasDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// The feature's own sources, as `FeatureSourceScan` paths: the
    /// `Services/PointAsk/` tree plus the Gemini client extension.
    private var pointAskSourceURLs: [URL] {
        FeatureSourceScan.swiftFiles(in: "ElderlyAssistant/Services/PointAsk")
            + [FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/Gemini/GeminiClient+PointAsk.swift")]
    }

    /// The same scan as `matchingLines(of:)` but over an explicit URL
    /// set — the sanctioned-webDetection exclusion uses it.
    private func matchingLines(in urls: [URL], of patterns: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                XCTFail("bad scan pattern: \(pattern)")
                continue
            }
            var hits: [String] = []
            for url in urls {
                let code = FeatureSourceScan.codeText(of: url)
                for (offset, line) in code.split(separator: "\n",
                                                 omittingEmptySubsequences: false).enumerated() {
                    let text = String(line)
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    if regex.firstMatch(in: text, options: [], range: range) != nil {
                        hits.append("\(FeatureSourceScan.relativePath(of: url)):\(offset + 1) "
                            + text.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
            result[pattern] = hits
        }
        return result
    }

    private func matchingLines(of pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return []
        }
        var hits: [String] = []
        for url in pointAskSourceURLs {
            let code = FeatureSourceScan.codeText(of: url)
            for (offset, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    hits.append("\(FeatureSourceScan.relativePath(of: url)):\(offset + 1) "
                                + text.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return hits
    }

    // MARK: Scenario: every user-visible string resolves in both languages

    func testEveryFeatureStringResolvesInNepaliAndEnglish() {
        for key in featureKeys {
            let ne = L10n.str(key, locale: nepali)
            let en = L10n.str(key, locale: english)

            XCTAssertNotEqual(ne, key, "\(key) does not resolve in Nepali")
            XCTAssertNotEqual(en, key, "\(key) does not resolve in English")
            XCTAssertTrue(hasDevanagari(ne), "\(key) has no Devanagari value: \(ne)")
            XCTAssertNotEqual(ne, en, "\(key) has the same value in both languages")
        }
    }

    func testEveryFeatureStringIsCatalogBackedRatherThanASwiftLiteral() {
        let values = featureKeys.flatMap { key in
            [L10n.str(key, locale: english), L10n.str(key, locale: nepali)]
        }
        for url in pointAskSourceURLs {
            let code = FeatureSourceScan.codeText(of: url)
            for value in values {
                XCTAssertFalse(code.contains(value),
                               "\(FeatureSourceScan.relativePath(of: url)) contains the "
                               + "user-visible string \(value.debugDescription) as a literal")
            }
        }
    }

    /// A pinned inventory: a later task that adds feature copy extends this
    /// list in the same change, so an entry with no surface — or a surface
    /// with no entry — is a deliberate decision rather than a drift.
    func testTheCatalogHoldsExactlyTheFeaturesDeclaredKeys() {
        let catalog = sourceCatalog()
        let featureEntries = catalog.keys.filter { $0.hasPrefix("pointask.") }.sorted()
        XCTAssertEqual(featureEntries, featureKeys.sorted(),
                       "a catalog entry that no surface uses (or a surface with no entry) is a drift")
    }

    // MARK: Scenario: the consent copy is the shipped formula (design §5)

    func testTheConsentBodyIsTheApprovedFormulaInBothLanguages() {
        let en = L10n.str("pointask.consent.body", locale: english).lowercased()

        XCTAssertTrue(en.contains("only that picture"),
                      "what leaves: only the tapped crop — the shipped formula's 'only': \(en)")
        XCTAssertTrue(en.contains("nothing else"),
                      "nothing else from the camera is sent: \(en)")
        XCTAssertTrue(en.contains("nothing is sent until you agree"),
                      "nothing leaves before agreement: \(en)")
        XCTAssertTrue(en.contains("any time"),
                      "the elder can stop it any time: \(en)")

        let ne = L10n.str("pointask.consent.body", locale: nepali)
        XCTAssertTrue(hasDevanagari(ne))
        XCTAssertTrue(ne.contains("मात्र"), "the Nepali body says 'only': \(ne)")
        XCTAssertTrue(ne.contains("पठाइँदैन"), "the Nepali body says 'not sent': \(ne)")
        XCTAssertTrue(ne.contains("जहिले"), "the Nepali body says 'any time': \(ne)")
    }

    func testTheConsentFailureCopyNamesNoCause() {
        // The elder can see this for a broken write or a broken read-back.
        // Naming one cause would be a lie in the other case.
        let en = L10n.str("pointask.consent.failed", locale: english).lowercased()
        XCTAssertFalse(en.contains("internet") || en.contains("network") || en.contains("disk"),
                       "a storage failure line must stay true for every storage failure: \(en)")
    }

    func testTheRevocationFailureCopyIsHonestAboutARelaunch() {
        // AM-4: a withdrawal that could not be recorded is told, including
        // the one way it can silently come back — a relaunch reading a
        // surviving record.
        let en = L10n.str("pointask.consent.revokeFailedNote", locale: english).lowercased()
        XCTAssertTrue(en.contains("nothing is being sent"),
                      "the note must say egress is stopped now: \(en)")
        XCTAssertTrue(en.contains("restart") || en.contains("restarted"),
                      "the note must name the relaunch window: \(en)")
        let ne = L10n.str("pointask.consent.revokeFailedNote", locale: nepali)
        XCTAssertTrue(ne.contains("पठाइँदैन") && ne.contains("खोल्दा"),
                      "the Nepali note says the same two things: \(ne)")
    }

    // MARK: Scenario: the cloud switch says what "off" means, in both languages

    func testTheCloudSwitchCopySaysWhatOffMeansInBothLanguages() {
        let note = "pointask.settings.cloud.note"

        let enNote = L10n.str(note, locale: english).lowercased()
        XCTAssertTrue(enNote.contains("off"),
                      "the note must name the state it explains: \(enNote)")
        XCTAssertTrue(enNote.contains("by itself") || enNote.contains("on the phone"),
                      "the note must say the phone answers by itself: \(enNote)")
        XCTAssertTrue(enNote.contains("nothing is sent") || enNote.contains("nothing leaves"),
                      "the note must say nothing leaves the phone: \(enNote)")

        let neNote = L10n.str(note, locale: nepali)
        XCTAssertTrue(hasDevanagari(neNote))
        XCTAssertTrue(neNote.contains("बन्द"),
                      "the Nepali note must name the off state: \(neNote)")
        XCTAssertTrue(neNote.contains("फोन"),
                      "the Nepali note must name the phone: \(neNote)")
        XCTAssertTrue(neNote.contains("पठाइँदैन"),
                      "the Nepali note must say nothing is sent: \(neNote)")

        // The provider is named in the title in both languages.
        XCTAssertTrue(L10n.str("pointask.settings.cloud.title", locale: english).contains("Gemini"))
        XCTAssertTrue(L10n.str("pointask.settings.cloud.title", locale: nepali).contains("Gemini"))
    }

    // MARK: Scenario: the medicine refusal copy is the app's own words

    func testTheMedicineRefusalCopyNamesTheHealthGuidelineInBothLanguages() {
        let en = L10n.str("pointask.answer.medicineRefusal", locale: english)
        XCTAssertTrue(en.contains("medicine"),
                      "the refusal names what was asked about: \(en)")
        XCTAssertTrue(en.contains("doctor") && en.contains("family"),
                      "the refusal points to the doctor and the family: \(en)")

        let ne = L10n.str("pointask.answer.medicineRefusal", locale: nepali)
        XCTAssertTrue(ne.contains("औषधि"), "the Nepali refusal names medicines: \(ne)")
        XCTAssertTrue(ne.contains("डाक्टर") && ne.contains("परिवार"),
                      "the Nepali refusal points to the doctor and the family: \(ne)")
    }

    // MARK: Scenario: the camera purpose sentence discloses the point-ask send

    func testThePurposeStringDisclosesThePointAskSend() {
        let purpose = cameraPurposeString().lowercased()

        XCTAssertTrue(purpose.contains("camera"),
                      "the purpose string must name the camera")
        XCTAssertTrue(purpose.contains("what is this?"),
                      "the purpose string must name the chip the send is triggered by")
        XCTAssertTrue(purpose.contains("only that picture"),
                      "the purpose string must state the crop-only limit")
        XCTAssertTrue(purpose.contains("nothing else"),
                      "the purpose string must state that nothing else is sent")
        XCTAssertTrue(purpose.contains("cloud service"),
                      "the purpose string must name the destination")
    }

    func testTheShippedPurposeDisclosuresAreStillPresent() {
        let purpose = cameraPurposeString().lowercased()
        XCTAssertTrue(purpose.contains("medication"),
                      "the shipped medication-verification disclosure must not be weakened")
        XCTAssertTrue(purpose.contains("appliance"),
                      "the shipped appliance-photo disclosure must still say photos are sent")
        XCTAssertTrue(purpose.contains("live translation"),
                      "the shipped live-translation disclosure must not be weakened")
    }

    // MARK: Scenario: the disclosure version stamps this copy revision

    func testTheDisclosureVersionIdentifiesThisCopyRevision() {
        let version = PointAskConfig.default.disclosureVersion
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(version.range(of: "r[0-9]+", options: .regularExpression),
                        "the stamp carries a revision ordinal, so an approved copy change bumps it: \(version)")
        XCTAssertTrue(version.hasPrefix("pointask.disclosure"),
                      "the stamp names the copy it belongs to: \(version)")

        // It must survive the log surface, or the consent evidence loses the
        // stamp that makes a stale grant detectable.
        let clean = LogSanitiser().sanitise(ObservabilityEvent(
            component: "pointask", eventType: "consent_recorded", durationMs: nil,
            outcome: "success", errorCode: nil, metadata: ["disclosureVersion": version]))
        XCTAssertEqual(clean.metadata["disclosureVersion"], version,
                       "the stamp must not be scrubbed by the shipped PII guard")
    }

    // MARK: Scenario: no image egress without a Grant (AM-7, source-scan)

    func testTheOnlyEgressPathRequiresTheGatesProof() {
        // `identifyPointAsk` — the one function a crop can leave through —
        // takes a `PointAskConsentGate.Grant` as a required parameter, and
        // its initialiser is private to the gate file.
        let clientSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/Gemini/GeminiClient+PointAsk.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "grant:\\s*PointAskConsentGate\\.Grant", in: clientSource),
                        "the request builder's signature requires the proof")
    }

    func testThePipelineIsTheOnlyCallerAndPassesTheMintedGrant() {
        let matches = matchingLines(of: "identifyPointAsk\\(")
        let declarations = matches.filter {
            $0.hasPrefix("ElderlyAssistant/Services/Gemini/GeminiClient+PointAsk.swift")
        }
        XCTAssertEqual(declarations.count, 1,
                       "the builder is declared exactly once, in the client extension: \(matches)")
        let callers = matches.filter { !$0.hasPrefix("ElderlyAssistant/Services/Gemini/") }
        XCTAssertEqual(callers.count, 1,
                       "exactly one call site can send a crop, and it is the pipeline's: \(callers)")
        XCTAssertTrue(callers[0].hasPrefix("ElderlyAssistant/Services/PointAsk/"
                                           + "PointAskAnalysisPipeline.swift"))

        let pipelineSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/PointAsk/"
                                        + "PointAskAnalysisPipeline.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "grant:\\s*grant", in: pipelineSource),
                        "the call hands over the grant the gate minted, not a local value")
        XCTAssertEqual(occurrences(of: "consentGate\\.authorize\\(\\)", in: pipelineSource), 1,
                       "the gate is the only producer of the proof the call needs")
    }

    func testThePipelineTouchesTheClientOnlyThroughTheGateGuardedPaths() {
        let pipelineSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/PointAsk/"
                                        + "PointAskAnalysisPipeline.swift"))
        guard let regex = try? NSRegularExpression(pattern: "client\\.[A-Za-z0-9_]+") else {
            return XCTFail("bad scan pattern")
        }
        let whole = NSRange(pipelineSource.startIndex..<pipelineSource.endIndex, in: pipelineSource)
        let touched = Set(regex.matches(in: pipelineSource, options: [], range: whole).compactMap {
            Range($0.range, in: pipelineSource).map { String(pipelineSource[$0]) }
        })

        XCTAssertEqual(touched, ["client.isAvailable", "client.identifyPointAsk"],
                       "the pipeline can reach the client only through the availability "
                       + "check and the grant-requiring identify call")
    }

    func testNoOtherSendPathExistsInTheFeature() {
        // `sendVisionDecoded` appears once in the feature — inside
        // `identifyPointAsk` — and no PointAsk source opens a transport,
        // a session or a file upload of its own. The ONE sanctioned
        // exception is Phase 2's `PointAskWebDetectionClient` — the
        // approved Vision webDetection egress client with its own
        // request-building and transport seam; its lines are excluded
        // from the forbidden scan.
        let visionCalls = matchingLines(of: "sendVisionDecoded\\(")
        XCTAssertEqual(visionCalls.count, 1, "one vision chokepoint: \(visionCalls)")
        XCTAssertTrue(visionCalls[0].hasPrefix("ElderlyAssistant/Services/Gemini/"
                                               + "GeminiClient+PointAsk.swift"))

        // The Phase-2 sanctioned egress clients — the approved Vision
        // webDetection client and the Open Food Facts lookup tool, each
        // with its own transport seam behind the consent/quota gates.
        let sanctionedEgressFiles: Set<String> = [
            "PointAskWebDetectionClient.swift",
            "ProductLookupTool.swift",
        ]
        let webDetectionSource = FeatureSourceScan.swiftFiles(
            in: "ElderlyAssistant/Services/PointAsk")
            .filter { sanctionedEgressFiles.contains($0.lastPathComponent) }
        let forbiddenHits = matchingLines(in: pointAskSourceURLs
            .filter { !webDetectionSource.contains($0) },
            of: ["URLSession", "URLRequest", "Data\\(contentsOf"])
        for (pattern, hits) in forbiddenHits where !hits.isEmpty {
            XCTFail("a second egress path ('\(pattern)') in the feature's sources: \(hits)")
        }
    }

    // MARK: Scenario: the event schema is allow-listed and pinned

    func testEveryCatalogueMetadataKeyIsAllowListed() {
        for (eventType, entry) in PointAskEventCatalogue.entries {
            for key in entry.metadataKeys {
                XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                              "\(eventType) metadata key '\(key)' is not in the shipped allow-list")
            }
        }
    }

    func testEveryEmitterKeyIsDeclaredAndEveryEmitterEventIsCatalogued() {
        for key in PointAskEvents.MetadataKey.allCases {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key.rawValue),
                          "MetadataKey case '\(key)' has no allow-list entry")
        }

        // Every `emit("…")` type in the emitter source is a catalogue entry,
        // and every entry's component is the feature's own.
        let eventsSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/PointAsk/PointAskEvents.swift"))
        guard let regex = try? NSRegularExpression(pattern: "emit\\(\"([a-z_]+)\"") else {
            return XCTFail("bad scan pattern")
        }
        let whole = NSRange(eventsSource.startIndex..<eventsSource.endIndex, in: eventsSource)
        let emitted = Set(regex.matches(in: eventsSource, options: [], range: whole).compactMap {
            Range($0.range(at: 1), in: eventsSource).map { String(eventsSource[$0]) }
        })
        XCTAssertFalse(emitted.isEmpty, "the scan must see the emitters it is checking")
        XCTAssertEqual(emitted, Set(PointAskEventCatalogue.entries.keys),
                       "an emitter for an undeclared type, or a declared type no emitter produces")
        XCTAssertEqual(PointAskEventCatalogue.component, "pointask")
    }

    // MARK: Helpers

    /// The source String Catalog, parsed as the artifact that ships —
    /// asserting on the file the feature edits rather than on a built copy.
    private func sourceCatalog() -> [String: Any] {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            XCTFail("could not read the String Catalog at \(url.path)")
            return [:]
        }
        return strings
    }

    private func cameraPurposeString() -> String {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let purpose = plist["NSCameraUsageDescription"] as? String else {
            XCTFail("could not read NSCameraUsageDescription from \(url.path)")
            return ""
        }
        return purpose
    }

    private func occurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return 0
        }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: whole)
    }
}
