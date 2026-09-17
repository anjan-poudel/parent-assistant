import XCTest
@testable import ElderlyAssistant

/// T-001 / T-003 — the source-level checks that make NFR-LCT-011 and
/// NFR-LCT-006 true rather than aspirational: no operational literal for a
/// configured parameter appears in the feature's pipeline sources, the config
/// type is the only place a nominal value is spelled, and no emitter can carry
/// free text to the log surface.
///
/// These checks are deliberately **falsifiable**: the scanner is re-run over
/// `LiveTranslateConfig.swift`, where the literals legitimately live, and must
/// find every one of them there. A scan that cannot detect the shape it
/// forbids proves nothing, and would pass forever once broken.
final class LiveTranslateSourceHygieneTests: XCTestCase {

    private let configFile = "ElderlyAssistant/Services/LiveTranslate/LiveTranslateConfig.swift"
    private let eventsFile = "ElderlyAssistant/Services/LiveTranslate/LiveTranslateEvents.swift"

    /// The distinctive defaults, with the parameter each belongs to. Small
    /// integers (1, 2, 5, 8, 12) are deliberately out of scope: as bare
    /// tokens they appear in ordinary code far too often to be a signal, and
    /// a check that cries wolf gets switched off. The values below are the
    /// ones a copy-paste would actually carry.
    private let configuredDefaults: [(literal: String, parameter: String)] = [
        ("0.25", "ocrSampleInterval"),
        ("2.0", "thermalCadenceFactor"),
        ("0.3", "regionMatchIoU"),
        ("0.35", "regionMatchCentroidDistance"),
        ("0.06", "declutterMergeCentroidDistance"),
        ("4.0", "translationMaxLengthRatio"),
        ("18", "overlayMinPointSize"),
        ("64", "translationMaxLengthAllowance"),
        ("120", "sceneTextMaxLength"),
        ("200", "cacheGeneralEntryLimit"),
        ("1200", "cloudBatchMaxCharacters")
    ]

    /// Files allowed to carry one of those literals, each with the reason. A
    /// later task that genuinely needs an unrelated literal (a UI animation
    /// duration, say) adds an entry here in its own change, so the decision is
    /// recorded and reviewed instead of the scan being quietly widened. An
    /// entry without a reason is itself a failure.
    private let exemptFiles: [(path: String, reason: String)] = []

    // MARK: Scenario: every parameter resolves from one value

    /// A literal's own spelling, guarded so `0.3` does not fire on `0.35` and
    /// `120` does not fire inside `1200` or `12000`.
    private func pattern(for literal: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: literal)
        return "(?<![0-9.])\(escaped)(?![0-9])"
    }

    private func violations(in file: URL) -> [String] {
        let code = FeatureSourceScan.codeText(of: file)
        var found: [String] = []
        for entry in configuredDefaults {
            if let match = FeatureSourceScan.firstMatch(of: pattern(for: entry.literal), in: code) {
                found.append("\(FeatureSourceScan.relativePath(of: file)):\(match.line) "
                             + "re-declares \(entry.parameter) = \(entry.literal)")
            }
        }
        return found
    }

    func testNoConfiguredDefaultIsRedeclaredInTheFeaturesPipelineSources() {
        for exemption in exemptFiles {
            XCTAssertFalse(exemption.reason.isEmpty,
                           "\(exemption.path) is exempted with no recorded reason")
        }
        let exempt = Set(exemptFiles.map(\.path))
        let files = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
            .filter { FeatureSourceScan.relativePath(of: $0) != configFile }
            .filter { !exempt.contains(FeatureSourceScan.relativePath(of: $0)) }
        XCTAssertFalse(files.isEmpty, "the feature's sources must be scanned, not skipped")

        for file in files {
            XCTAssertEqual(violations(in: file), [],
                           "an operational literal belongs to LiveTranslateConfig alone (NFR-LCT-011)")
        }
    }

    /// The falsification check: the same scan, over the one file where those
    /// literals are the point, must find all of them.
    func testTheScanActuallyDetectsTheLiteralsWhereTheyLegitimatelyLive() {
        let url = FeatureSourceScan.iosDirectory().appendingPathComponent(configFile)
        let found = violations(in: url)
        XCTAssertEqual(found.count, configuredDefaults.count,
                       "the scanner missed a literal it is supposed to catch: \(found)")
    }

    func testTheConfigIsTheOnlyFileDeclaringTheFeaturesDefaults() {
        let declarations = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
            .filter { FeatureSourceScan.codeText(of: $0).contains("static let `default`") }
            .map { FeatureSourceScan.relativePath(of: $0) }
        XCTAssertEqual(declarations, [configFile],
                       "one config type, one default value (NFR-LCT-011)")
    }

    // MARK: Scenario: log hygiene inside the feature

    /// Stricter than the shipped release gate, deliberately: that gate flags
    /// prints that carry transcript content or a raw error, while the feature
    /// must have no uncontrolled console write at all (NFR-LCT-006). Its
    /// events go through the sanitising bus or not at all.
    func testTheFeatureSourcesContainNoPrintStatements() {
        let pattern = "(?<![A-Za-z0-9_])(print|debugPrint|NSLog|os_log|fputs)\\s*\\("
        let files = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
        for file in files {
            let code = FeatureSourceScan.codeText(of: file)
            XCTAssertFalse(code.isEmpty, "\(FeatureSourceScan.relativePath(of: file)) scanned as empty")
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                         "\(FeatureSourceScan.relativePath(of: file)) writes to the console directly")
        }
    }

    // MARK: Scenario: content is not expressible on the event API

    /// The structural half of the content-free claim in
    /// `LiveTranslateEventsTests`: **no emitter takes a `String`**, so a
    /// recognized or translated string has no parameter to travel in. The
    /// private `emit(_:outcome:errorCode:metadata:durationMs:)` carries the
    /// event *type*, which is a compile-time literal at every call site and is
    /// pinned by the catalogue test; its metadata is keyed by `MetadataKey`,
    /// so an undeclared key is a compile error rather than a dropped field.
    func testNoEmitterAcceptsFreeText() {
        let url = FeatureSourceScan.iosDirectory().appendingPathComponent(eventsFile)
        let code = FeatureSourceScan.codeText(of: url)
        let signature = try! NSRegularExpression(pattern: "func ([A-Za-z0-9_]+)\\(([^)]*)\\)")
        let whole = NSRange(code.startIndex..<code.endIndex, in: code)

        var checked = 0
        for match in signature.matches(in: code, options: [], range: whole) {
            let name = Range(match.range(at: 1), in: code).map { String(code[$0]) } ?? "?"
            let parameters = Range(match.range(at: 2), in: code).map { String(code[$0]) } ?? ""
            checked += 1
            guard name != "emit" else { continue }
            XCTAssertNil(parameters.range(of: "\\bString\\b", options: .regularExpression),
                         "\(name)(…) accepts free text — content would be expressible on the event API")
        }
        XCTAssertGreaterThanOrEqual(checked, 30,
                                    "the scan saw \(checked) signatures; an empty scan proves nothing")
    }

    /// One route to the bus, and it is the typed one: every metadata value is
    /// built from `MetadataKey` and an integer, a closed token or the config's
    /// version stamp. A second `bus.emit(` call site would be an escape hatch
    /// out of that schema.
    func testTheTypedEmitterIsTheOnlyRouteToTheBus() {
        let url = FeatureSourceScan.iosDirectory().appendingPathComponent(eventsFile)
        let code = FeatureSourceScan.codeText(of: url)
        let calls = try! NSRegularExpression(pattern: "bus\\.emit\\(")
        let whole = NSRange(code.startIndex..<code.endIndex, in: code)
        XCTAssertEqual(calls.numberOfMatches(in: code, options: [], range: whole), 1,
                       "only the private emit(_:) may write to the bus; a second call site bypasses the schema")
    }
}
