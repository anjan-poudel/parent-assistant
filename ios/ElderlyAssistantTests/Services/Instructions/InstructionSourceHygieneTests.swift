import XCTest
@testable import ElderlyAssistant

/// T-026 — release-log gate registration and source hygiene for the
/// reminders-instructions feature.
///
/// The gate itself (`ios/tools/check-release-log-safety.py`) is a Python rule
/// engine invoked by `ios/tools/check-release-log-safety.sh` from `ios/build.sh`;
/// it is a build-blocking gate, not an XCTest. The simulator test bundle has no
/// `Process`, so this suite **does not spawn Python and does not claim to**.
/// Its gate cases are honest source pins over the engine: the registered
/// feature roots, the event-type register, the seeded temporary-copy
/// self-test, the non-zero exit path, and the self-test's
/// shipping-tree-unchanged design. The live gate run is performed by the build
/// script, and was validated manually during T-026: exit 0 on the shipping
/// tree, exit 1 on a temporary copy carrying an interpolated instruction-text
/// log, with the copy removed afterwards and the shipping file's digest
/// unchanged.
///
/// The hygiene cases scan the feature's three roots with
/// `FeatureSourceScan.codeText` (comments stripped, string literals kept) and
/// pin the scope boundary in design §8.3 / §11.3 P: no egress, no
/// photo-library access, no `copyItem` staging copy, no transcode/compression/
/// trim API, and no runtime merged-Info.plist lookup for usage strings. Every
/// detector is also exercised on a synthetic planted string in the same test,
/// so a detector that silently stopped matching fails here instead of passing
/// forever.
///
/// What this suite does not prove: like the gate, it is static and textual. It
/// cannot see a network call behind a helper, a key built at run time in a
/// variable, or a framework sink it does not name. A green suite means "no
/// defect of these shapes is spelled in these files", not "the boundary is
/// impossible to cross". The suite is read-only: it writes nothing, anywhere.
final class InstructionSourceHygieneTests: XCTestCase {

    // MARK: - Constants and locating the inputs

    private let gateRelativePath = "tools/check-release-log-safety.py"
    private let sanitizerRelativePath =
        "ElderlyAssistant/Services/Observability/LogSanitiser.swift"
    private let instructionDirectory = "ElderlyAssistant/Services/Instructions"

    private let instructionRoots = [
        "Services/Instructions",
        "App/InstructionViews.swift",
        "App/InstructionCapture.swift"
    ]

    private enum GateDefect: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let what):
                return "gate source defect: \(what)"
            }
        }
    }

    /// One scanned feature source: its `ios/`-relative path and comment-free code.
    private struct ScannedSource {
        let relativePath: String
        let code: String
    }

    /// One forbidden spelling, with the id used in the failure message.
    private struct ForbiddenPattern {
        let id: String
        let pattern: String
        var options: NSRegularExpression.Options = []
    }

    /// A file under `ios/`, read as UTF-8.
    private func readIOSFile(_ relative: String,
                             file: StaticString = #filePath) throws -> String {
        let url = FeatureSourceScan.iosDirectory(file: file).appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The body of a top-level Python registry (`NAME = [ … ]` or `NAME = { … }`).
    /// The terminator is the first line that is exactly the closing bracket at
    /// column zero — the shipped style for both registries.
    private func registryBody(named name: String, terminator: String,
                              in source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(name) = ") }) else {
            return nil
        }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line == terminator {
                return body.joined(separator: "\n")
            }
            body.append(line)
        }
        return nil
    }

    /// The quoted string literals in a source fragment, in source order.
    private func quotedStrings(in text: String) -> [String] {
        let pattern = "\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The registry keys of `FEATURE_EVENT_TYPES`: a line of exactly four
    /// spaces, a quoted snake_case name and a colon. Comment lines start with
    /// `#` and description strings follow the colon, so they cannot be read as
    /// keys.
    private func eventTypeKeys(in body: String) -> [String] {
        let pattern = "(?m)^    \"([a-z0-9_]+)\"\\s*:"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, options: [], range: range).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// `LogSanitiser.allowedKeys`, read from the shipped source (line comments
    /// stripped first, because some comments quote examples).
    private func allowedKeys(in source: String) throws -> Set<String> {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.contains("static let allowedKeys: Set<String> = [")
        }) else {
            throw GateDefect.missing("LogSanitiser.allowedKeys declaration")
        }
        var body: [String] = []
        var closed = false
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces) == "]" {
                closed = true
                break
            }
            body.append(line)
        }
        guard closed else {
            throw GateDefect.missing("the closing bracket of LogSanitiser.allowedKeys")
        }
        let uncommented = body.map { line -> String in
            guard let comment = line.range(of: "//") else { return line }
            return String(line[..<comment.lowerBound])
        }
        return Set(quotedStrings(in: uncommented.joined(separator: "\n")))
    }

    /// Every Swift file under the three instruction roots, comment-free.
    private func featureSources(file: StaticString = #filePath) -> [ScannedSource] {
        let ios = FeatureSourceScan.iosDirectory(file: file)
        var urls = FeatureSourceScan.swiftFiles(in: instructionDirectory, file: file)
        urls.append(ios.appendingPathComponent("ElderlyAssistant/App/InstructionViews.swift"))
        urls.append(ios.appendingPathComponent("ElderlyAssistant/App/InstructionCapture.swift"))
        return urls.map {
            ScannedSource(relativePath: FeatureSourceScan.relativePath(of: $0, file: file),
                          code: FeatureSourceScan.codeText(of: $0))
        }
    }

    /// The feature root that covers a `Services/…`/`App/…` (source-root-relative)
    /// path, using the gate's own matching rule: an exact file entry or a
    /// directory prefix followed by `/`. `Services/InstructionsExtra` is not a
    /// child of `Services/Instructions`.
    private func isCovered(_ relativeToSourceRoot: String, by roots: [String]) -> Bool {
        roots.contains { root in
            relativeToSourceRoot == root || relativeToSourceRoot.hasPrefix(root + "/")
        }
    }

    // MARK: - Small regex and reporting helpers

    /// Every line of `text` matching `pattern`.
    private func lineMatches(of pattern: String, in text: String,
                             options: NSRegularExpression.Options = [])
        -> [(line: Int, text: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("bad scan pattern: \(pattern)")
            return []
        }
        var hits: [(line: Int, text: String)] = []
        for (offset, lineSub) in text.split(separator: "\n",
                                           omittingEmptySubsequences: false).enumerated() {
            let line = String(lineSub)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                hits.append((line: offset + 1, text: line))
            }
        }
        return hits
    }

    /// Fails when any scanned source matches any forbidden pattern.
    private func assertNoMatches(of patterns: [ForbiddenPattern],
                                 in sources: [ScannedSource],
                                 context: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertFalse(sources.isEmpty, "the feature's sources must be scanned, not skipped",
                       file: file, line: line)
        for source in sources {
            XCTAssertFalse(source.code.isEmpty,
                           "\(source.relativePath) scanned as empty",
                           file: file, line: line)
            for entry in patterns {
                for hit in lineMatches(of: entry.pattern, in: source.code,
                                       options: entry.options) {
                    XCTFail("\(source.relativePath):\(hit.line) \(context): "
                            + "\(entry.id) — \(hit.text.trimmingCharacters(in: .whitespaces))",
                            file: file, line: line)
                }
            }
        }
    }

    /// Falsifiability: the detector must fire on a string that deliberately
    /// carries the token. Without this, a pattern that stopped matching would
    /// make its "no matches" assertion vacuously green forever.
    private func assertDetectorFires(_ pattern: String,
                                     options: NSRegularExpression.Options = [],
                                     on planted: String,
                                     label: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertFalse(lineMatches(of: pattern, in: planted, options: options).isEmpty,
                       "the \(label) detector did not fire on its own planted token — "
                       + "the scan proves nothing",
                       file: file, line: line)
    }

    /// A fixed-length window after a marker, for pinning one self-test leg's
    /// tuple rather than a token that also appears in another leg or in RULES.
    private func section(after marker: String, length: Int, in source: String) -> String? {
        guard let range = source.range(of: marker) else { return nil }
        let available = source.distance(from: range.lowerBound, to: source.endIndex)
        let end = source.index(range.lowerBound, offsetBy: min(length, available))
        return String(source[range.lowerBound..<end])
    }

    // MARK: - Scenario: the gate scans the feature roots

    func testFeatureRootsAreRegistered() throws {
        let gate = try readIOSFile(gateRelativePath)
        let roots = try XCTUnwrap(
            registryBody(named: "FEATURE_ROOTS", terminator: "]", in: gate),
            "FEATURE_ROOTS could not be read from the gate")
        let entries = Set(quotedStrings(in: roots))

        for root in instructionRoots {
            XCTAssertTrue(entries.contains(root),
                          "FEATURE_ROOTS is missing '\(root)' — the feature's files "
                          + "would be graded as 'other' and rules 3-6 would not apply")
        }

        // The directory entry carries every file under Services/Instructions;
        // the two App files are exact entries because App/ is shared.
        XCTAssertTrue(roots.contains("\"Services/Instructions\""),
                      "the directory root must be spelled as a directory entry")

        // RoutineNotificationContent.swift is deliberately not a root: it lives
        // in a shared directory, writes no log, and carries two producer keys
        // plus a Bool (design §6.5). A file root would pass and claim nothing.
        // The check is over the registry's quoted entries, not the comment
        // text that deliberately names the file to explain the decision.
        XCTAssertFalse(entries.contains { $0.contains("RoutineNotificationContent") },
                       "RoutineNotificationContent.swift must not become a root — "
                       + "it writes no log and claims nothing (design §6.5)")

        // No existing root was removed or weakened. These representative
        // entries span earlier features; a deletion here would silently shrink
        // the gate's claim.
        for kept in ["Services/LiveTranslate",
                     "Services/Intents/CloudChat",
                     "Services/MedicationScheduler/MedicationScheduler.swift",
                     "Services/Calls",
                     "App/SettingsTabs.swift"] {
            XCTAssertTrue(entries.contains(kept),
                          "an existing FEATURE_ROOTS entry was removed: '\(kept)'")
        }

        // The allow-list authority is still the shipped source, not a copy.
        XCTAssertTrue(gate.contains(
            "DEFAULT_ALLOW_LIST = os.path.join(DEFAULT_SOURCE_ROOT,"),
                      "the gate no longer reads the shipped LogSanitiser.swift")
        XCTAssertTrue(gate.contains("\"Services/Observability/LogSanitiser.swift\""),
                      "DEFAULT_ALLOW_LIST no longer names the shipped allow-list")
    }

    func testEveryFeatureFileIsCoveredByARoot() throws {
        let sources = featureSources()
        XCTAssertGreaterThanOrEqual(sources.count, 15,
                                    "expected the 13 Services/Instructions files plus the "
                                    + "two App files; saw \(sources.count)")

        var seen = Set<String>()
        for source in sources {
            XCTAssertTrue(seen.insert(source.relativePath).inserted,
                          "\(source.relativePath) was scanned twice")
            let sourceRootRelative: String
            if source.relativePath.hasPrefix("ElderlyAssistant/") {
                sourceRootRelative = String(source.relativePath.dropFirst("ElderlyAssistant/".count))
            } else {
                sourceRootRelative = source.relativePath
            }
            XCTAssertTrue(isCovered(sourceRootRelative, by: instructionRoots),
                          "\(source.relativePath) is not covered by any instruction root")
        }

        // The files that carry the staging seam and the event emitter must be
        // in the scanned set, so this is not a collection of unrelated view files.
        for required in ["Services/Instructions/InstructionVideoStore.swift",
                         "Services/Instructions/InstructionObservability.swift"] {
            XCTAssertTrue(sources.contains { source in
                source.relativePath.hasSuffix(required)
            }, "\(required) was not scanned")
        }

        // Falsifiability: the coverage predicate accepts a root child and
        // rejects a lookalike sibling and a same-prefix path outside the root.
        XCTAssertTrue(isCovered("Services/Instructions/Nested/NewFile.swift",
                                by: instructionRoots))
        XCTAssertFalse(isCovered("Services/InstructionsExtra/NewFile.swift",
                                 by: instructionRoots))
        XCTAssertTrue(isCovered("App/InstructionViews.swift", by: instructionRoots))
        XCTAssertFalse(isCovered("App/InstructionViewsExtra.swift", by: instructionRoots))
    }

    // MARK: - Scenario: the gate recognises the new event types

    func testSevenEventTypesRegistered() throws {
        let gate = try readIOSFile(gateRelativePath)
        let body = try XCTUnwrap(
            registryBody(named: "FEATURE_EVENT_TYPES", terminator: "}", in: gate),
            "FEATURE_EVENT_TYPES could not be read from the gate")
        let registered = Set(eventTypeKeys(in: body))

        let expected: Set<String> = [
            "instruction_media_import",
            "instruction_media_delete",
            "instruction_media_availability",
            "instruction_playback",
            "instruction_image_load",
            "instruction_capture_permission",
            "instruction_orphan_purge"
        ]
        for name in expected {
            XCTAssertTrue(registered.contains(name),
                          "FEATURE_EVENT_TYPES is missing '\(name)'")
        }
        // Exactly the seven instruction_* catalogue names: an extra
        // instruction_* entry would need a deliberate updated expectation, not
        // a quiet widening of this assertion.
        let instructionNames = Set(registered.filter { $0.hasPrefix("instruction_") })
        XCTAssertEqual(instructionNames, expected)

        // No existing event-type entry was removed (representative set from
        // the conversational, medication and calendar features).
        for kept in ["reply_grammar_flag",
                     "cloud_chat_served",
                     "medication_ack_resolved",
                     "calendar_share_write_failed"] {
            XCTAssertTrue(registered.contains(kept),
                          "an existing FEATURE_EVENT_TYPES entry was removed: '\(kept)'")
        }

        // The shipped allow-list still carries every key the seven payloads
        // use; the feature adds no entry and removes none (design §6.6).
        let sanitizer = try readIOSFile(sanitizerRelativePath)
        let allowed = try allowedKeys(in: sanitizer)
        for key in ["outcome", "state", "duration_ms", "error_code",
                    "count", "kind", "entry_id_hash"] {
            XCTAssertTrue(allowed.contains(key),
                          "LogSanitiser.allowedKeys lost '\(key)' — the instruction "
                          + "payload would be dropped or redacted")
        }
    }

    func testUnknownEventTypeFailsGate() throws {
        let gate = try readIOSFile(gateRelativePath)
        let body = try XCTUnwrap(
            registryBody(named: "FEATURE_EVENT_TYPES", terminator: "}", in: gate))
        let registered = Set(eventTypeKeys(in: body))
        XCTAssertFalse(registered.contains("instruction_future_unknown"),
                       "the seeded name must be unregistered for this test to mean anything")

        // The gate has no event-name allow-list, deliberately: a feature-root
        // file emits many event names that are graded by the root, not by the
        // event-type registry. An unknown event name therefore fails the gate
        // by the same route as a known one — every emission statement in a
        // feature-root file is judged by rules 5-6, whatever it is called. A
        // bare unknown event with `metadata: [:]` is not content and correctly
        // passes; an unlisted key or a content-bearing field fails.
        XCTAssertTrue(gate.contains("if role == \"feature\":"),
                      "the feature-root branch is gone — rules 3-6 would not run")
        XCTAssertTrue(gate.contains(
            "judge_feature(relative, line_no, text, allowed_keys, in_debug)"),
                      "feature-root statements are no longer judged by judge_feature")
        XCTAssertTrue(gate.contains(
            "judge_feature_payload(relative, line_no, text, allowed_keys)"),
                      "the event-payload family is no longer applied")
        XCTAssertTrue(gate.contains("\"feature-unlisted-metadata-key\""),
                      "the unlisted-metadata-key rule is gone")
        XCTAssertTrue(gate.contains("if name not in allowed_keys:"),
                      "the allow-list decision point is gone")

        // The failure convention is unchanged: violations mean exit 1.
        let violationExit = try XCTUnwrap(
            section(after: "    if violations:", length: 1200, in: gate),
            "the violation-reporting block is gone")
        XCTAssertTrue(violationExit.contains("return 1"),
                      "a violation no longer exits non-zero")
        XCTAssertTrue(gate.contains("sys.exit(main())"),
                      "the engine no longer propagates main()'s exit code")

        // The gate's own self-test plants the unknown name in a temporary copy
        // of a feature file and requires exit 1 with the rule and key named.
        let leg = try XCTUnwrap(
            section(after: "\"seeded-unknown-event-in-feature-copy\"",
                    length: 800, in: gate),
            "the unknown-event self-test leg is missing")
        XCTAssertTrue(leg.contains("instruction_future_unknown"),
                      "the seeded unknown name is not in the leg")
        XCTAssertTrue(leg.contains("feature-unlisted-metadata-key"),
                      "the leg does not require the rule to be named")
        XCTAssertTrue(leg.contains("'transcript'"),
                      "the leg does not require the unlisted key to be named")
        XCTAssertTrue(leg.contains("1,"),
                      "the leg does not expect a non-zero exit")
    }

    // MARK: - Scenario: a planted free-text log fails the gate

    func testPlantedFreeTextLogFailsGate() throws {
        let gate = try readIOSFile(gateRelativePath)

        // The self-test copies a real instruction feature file into a
        // temporary tree, appends the seed in memory, and expects the engine
        // to fail on the copy. The shipping file is only ever read.
        XCTAssertTrue(gate.contains(
            "_SELF_TEST_INSTRUCTION_COPY = \"Services/Instructions/InstructionObservability.swift\""),
                      "the temporary-copy leg no longer names the feature file")
        XCTAssertTrue(gate.contains("seeded instruction text"),
                      "the seeded instruction-text statement is gone")
        XCTAssertTrue(gate.contains("\\(instructionText)"),
                      "the seed no longer interpolates instruction text")
        XCTAssertTrue(gate.contains("_shipped_feature_source(_SELF_TEST_INSTRUCTION_COPY)"),
                      "the copy is no longer read from the shipped tree")

        let leg = try XCTUnwrap(
            section(after: "\"seeded-instruction-text-in-feature-copy\"",
                    length: 800, in: gate),
            "the planted free-text self-test leg is missing")
        XCTAssertTrue(leg.contains("feature-console-write"),
                      "the leg does not require the console-write rule")
        XCTAssertTrue(leg.contains("feature-content-print"),
                      "the leg does not require the content-print rule")
        XCTAssertTrue(leg.contains("_SEED_INSTRUCTION_TEXT"),
                      "the leg does not require the seeded statement to be named")
        XCTAssertTrue(leg.contains("1,"),
                      "the leg does not expect a non-zero exit")

        // Falsifiability: the same two shapes the seed uses are detected by a
        // Swift-side mirror of the gate's rules (a console-write opener and a
        // content word), so this pin is not merely textual trust.
        let planted = "\n        print(\"seeded instruction text: \\(instructionText)\")\n"
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "(?<![A-Za-z0-9_])(print|debugPrint|NSLog|os_log|fputs)\\s*\\(",
            in: planted), "the console-write mirror missed the seed")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "(?<![A-Za-z0-9_])[A-Za-z0-9]*Texts?(?![A-Za-z0-9_])",
            in: planted), "the content-word mirror missed the seed")

        // The live run is the build script's gate, not this test: Process is
        // unavailable in the test bundle. During T-026 the manual run on a
        // temporary copy exited 1 and named
        // Services/Instructions/InstructionObservability.swift with
        // feature-console-write and feature-content-print; the shipping file's
        // sha256 was identical before and after and the copy was deleted.
    }

    // MARK: - Scenario: source hygiene proves the scope boundary

    func testNoNetworkOrUploadInFeatureSources() throws {
        // Precise tokens, not bare words: `share` would match
        // `AVAudioSession.sharedInstance()`, which is the microphone/playback
        // audio session, not a sharing surface. The forbidden spellings below
        // are the network clients and the share/export surfaces the design
        // names (§8.3, §11.3 P).
        let patterns = [
            ForbiddenPattern(id: "URLSession",
                             pattern: "(?<![A-Za-z0-9_])URLSession(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "URLRequest",
                             pattern: "(?<![A-Za-z0-9_])URLRequest(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "NWConnection",
                             pattern: "(?<![A-Za-z0-9_])NWConnection(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "import Network",
                             pattern: "(?<![A-Za-z0-9_.])import Network(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "WebSocket",
                             pattern: "(?<![A-Za-z0-9_])WebSocket(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "CFSocket",
                             pattern: "(?<![A-Za-z0-9_])CFSocket(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "upload",
                             pattern: "(?i)(?<![A-Za-z0-9_])upload"),
            ForbiddenPattern(id: "UIActivityViewController",
                             pattern: "(?<![A-Za-z0-9_])UIActivityViewController(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "UIActivity",
                             pattern: "(?<![A-Za-z0-9_])UIActivity(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "NSSharingService",
                             pattern: "(?<![A-Za-z0-9_])NSSharingService(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "ShareLink",
                             pattern: "(?<![A-Za-z0-9_])ShareLink(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "NSFileProvider",
                             pattern: "(?<![A-Za-z0-9_])NSFileProvider(?![A-Za-z0-9_])")
        ]
        assertNoMatches(of: patterns, in: featureSources(),
                        context: "network, upload or share API in the instruction sources "
                        + "(NFR-RIE-003)")

        let planted = """
        let session = URLSession.shared
        session.uploadTask(with: request)
        let share = UIActivityViewController(activityItems: [], applicationActivities: nil)
        let activity = UIActivity()
        """
        assertDetectorFires("(?<![A-Za-z0-9_])URLSession(?![A-Za-z0-9_])",
                            on: planted, label: "URLSession")
        assertDetectorFires("(?i)(?<![A-Za-z0-9_])upload", on: planted, label: "upload")
        assertDetectorFires("(?<![A-Za-z0-9_])UIActivityViewController(?![A-Za-z0-9_])",
                            on: planted, label: "share sheet")
        assertDetectorFires("(?<![A-Za-z0-9_])UIActivity(?![A-Za-z0-9_])",
                            on: planted, label: "UIActivity")
    }

    func testNoPhotoLibraryAccess() throws {
        // The video picker is `PHPickerViewController` from PhotosUI. It runs
        // out of the app's process and reads only the file the person chose;
        // it requires **no** photo-library permission, so it is deliberately
        // not flagged (design §8.3's last row, §11.3 P). The forbidden tokens
        // are the in-process Photos surface and its authorization calls.
        let patterns = [
            ForbiddenPattern(id: "PHPhotoLibrary",
                             pattern: "(?<![A-Za-z0-9_])PHPhotoLibrary(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "PHAsset",
                             pattern: "(?<![A-Za-z0-9_])PHAsset(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "PHFetchResult",
                             pattern: "(?<![A-Za-z0-9_])PHFetchResult(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "PHImageManager",
                             pattern: "(?<![A-Za-z0-9_])PHImageManager(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "PHCachingImageManager",
                             pattern: "(?<![A-Za-z0-9_])PHCachingImageManager(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "PHAuthorizationStatus",
                             pattern: "(?<![A-Za-z0-9_])PHAuthorizationStatus(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "requestAuthorization",
                             pattern: "(?<![A-Za-z0-9_])requestAuthorization(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "NSPhotoLibraryUsageDescription",
                             pattern: "NSPhotoLibraryUsageDescription"),
            ForbiddenPattern(id: "NSPhotoLibraryAddUsageDescription",
                             pattern: "NSPhotoLibraryAddUsageDescription"),
            // `import PhotosUI` is the picker module and must stay allowed;
            // the word boundary after `Photos` rejects the `U` of `PhotosUI`.
            ForbiddenPattern(id: "import Photos",
                             pattern: "(?<![A-Za-z0-9_.])import Photos(?![A-Za-z0-9_])")
        ]
        let sources = featureSources()
        assertNoMatches(of: patterns, in: sources,
                        context: "photo-library access in the instruction sources "
                        + "(NFR-RIE-005; the picker is out-of-process)")

        // The legitimate picker is present and does not trip any pattern.
        let capture = try XCTUnwrap(
            sources.first { $0.relativePath.hasSuffix("App/InstructionCapture.swift") },
            "App/InstructionCapture.swift was not scanned")
        XCTAssertTrue(capture.code.contains("PHPickerViewController"),
                      "the out-of-process picker is missing — this test's negative "
                      + "control no longer exists")
        let pickerLine = "let picker = PHPickerViewController(configuration: configuration)"
        for entry in patterns {
            XCTAssertTrue(lineMatches(of: entry.pattern, in: pickerLine,
                                      options: entry.options).isEmpty,
                          "\(entry.id) wrongly flags the out-of-process PHPicker")
        }

        assertDetectorFires("(?<![A-Za-z0-9_])PHPhotoLibrary(?![A-Za-z0-9_])",
                            on: "PHPhotoLibrary.requestAuthorization { _ in }",
                            label: "PHPhotoLibrary")
        assertDetectorFires("(?<![A-Za-z0-9_])PHAsset(?![A-Za-z0-9_])",
                            on: "let assets = PHAsset.fetchAssets(with: nil)",
                            label: "PHAsset")
    }

    func testNoCopyItemInVideoStore() throws {
        // Design §5.2 / §8.3 (B-3): the destination is created with
        // `.completeFileProtection` before any byte is written, then filled by
        // a bounded chunked stream through `InstructionStagingFileOps`. A
        // `copyItem` would reintroduce the copy-then-set-permissions window
        // this feature removed. The scan covers all three roots, so a future
        // file cannot reintroduce it beside the store either.
        let pattern = "(?<![A-Za-z0-9_])copyItem(?![A-Za-z0-9_])"
        let sources = featureSources()
        assertNoMatches(of: [ForbiddenPattern(id: "copyItem", pattern: pattern)],
                        in: sources,
                        context: "copyItem in the instruction staging path (design §5.2, §8.3)")

        let store = try XCTUnwrap(
            sources.first { $0.relativePath.hasSuffix(
                "Services/Instructions/InstructionVideoStore.swift") },
            "InstructionVideoStore.swift was not scanned")
        XCTAssertTrue(store.code.contains("InstructionStagingFileOps"),
                      "the staging seam is gone — the create-before-write guarantee "
                      + "cannot be reasoned about")
        XCTAssertTrue(store.code.contains("SystemInstructionStagingFileOps"),
                      "the production staging seam is gone")

        assertDetectorFires(pattern,
                            on: "try fileManager.copyItem(at: source, to: destination)",
                            label: "copyItem")
    }

    func testNoTranscodeOrTrimAPI() throws {
        // The feature parses the file as AVFoundation parses any player input;
        // it never transcodes, re-encodes, frames-decodes or trims. Text
        // trimming (`trimmingCharacters(in:)`, `trimmedOrNil`) is unrelated
        // and stays allowed: the `trim(`/`trimming(` patterns require the call
        // parenthesis immediately after the word, which `trimmingCharacters`
        // does not have.
        let patterns = [
            ForbiddenPattern(id: "AVAssetExportSession",
                             pattern: "(?<![A-Za-z0-9_])AVAssetExportSession(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "AVAssetReader",
                             pattern: "(?<![A-Za-z0-9_])AVAssetReader(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "AVAssetWriter",
                             pattern: "(?<![A-Za-z0-9_])AVAssetWriter(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "AVAssetWriterInput",
                             pattern: "(?<![A-Za-z0-9_])AVAssetWriterInput(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "AVMutableComposition",
                             pattern: "(?<![A-Za-z0-9_])AVMutableComposition(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "AVMutableVideoComposition",
                             pattern: "(?<![A-Za-z0-9_])AVMutableVideoComposition(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "AVVideoComposition",
                             pattern: "(?<![A-Za-z0-9_])AVVideoComposition(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "exportAsynchronously",
                             pattern: "(?<![A-Za-z0-9_])exportAsynchronously(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "presetName",
                             pattern: "(?<![A-Za-z0-9_])presetName(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "VTCompressionSession",
                             pattern: "(?<![A-Za-z0-9_])VTCompressionSession(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "VideoToolbox",
                             pattern: "(?<![A-Za-z0-9_])VideoToolbox(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "AVVideoCompressionPropertiesKey",
                             pattern: "AVVideoCompressionPropertiesKey"),
            ForbiddenPattern(id: "compressionProperties",
                             pattern: "(?<![A-Za-z0-9_])compressionProperties(?![A-Za-z0-9_])"),
            ForbiddenPattern(id: "transcode",
                             pattern: "(?i)(?<![A-Za-z0-9_])transcode"),
            ForbiddenPattern(id: "trim(",
                             pattern: "(?<![A-Za-z0-9_])trim\\s*\\("),
            ForbiddenPattern(id: "trimming(",
                             pattern: "(?<![A-Za-z0-9_])trimming\\s*\\(")
        ]
        assertNoMatches(of: patterns, in: featureSources(),
                        context: "transcode, compression or trimming API in the instruction "
                        + "sources (NFR-RIE-003)")

        let planted = """
        let export = AVAssetExportSession(asset: asset, presetName: preset)
        export.exportAsynchronously { }
        composition.trim(start: .zero, end: .zero)
        """
        assertDetectorFires("(?<![A-Za-z0-9_])AVAssetExportSession(?![A-Za-z0-9_])",
                            on: planted, label: "AVAssetExportSession")
        assertDetectorFires("(?<![A-Za-z0-9_])exportAsynchronously(?![A-Za-z0-9_])",
                            on: planted, label: "exportAsynchronously")
        assertDetectorFires("(?<![A-Za-z0-9_])trim\\s*\\(",
                            on: planted, label: "trim(")

        // The legitimate text operation is not a video trim.
        let legitimate = "let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)"
        XCTAssertTrue(lineMatches(of: "(?<![A-Za-z0-9_])trim\\s*\\(",
                                  in: legitimate).isEmpty,
                      "the trim detector flags ordinary text trimming")
        XCTAssertTrue(lineMatches(of: "(?<![A-Za-z0-9_])trimming\\s*\\(",
                                  in: legitimate).isEmpty,
                      "the trimming detector flags trimmingCharacters")
    }

    func testNoMergedInfoDictionaryUsageForUsageStrings() throws {
        // Design §11.3 N: registered usage strings are proven from the built
        // app bundle's InfoPlist.strings resources. The merged Info.plist
        // dictionary returns the base plist's English value even when neither
        // strings file shipped, so `Bundle.main.object(forInfoDictionaryKey:)`
        // cannot detect a missing Nepali/localised resource and is not
        // evidence of registration. This suite forbids the lookup for a usage
        // string in any shape: the key literal in the call, or the key within
        // a small window of the dictionary read (a key held in a variable).
        let sources = featureSources()
        for source in sources {
            let hits = usageStringLookupLines(in: source.code)
            XCTAssertTrue(hits.isEmpty,
                          "\(source.relativePath) reads a usage string from the merged "
                          + "Info dictionary at line(s) \(hits) — prove registration from "
                          + "the built bundle's InfoPlist.strings instead (design §11.3 N)")
        }

        // Falsifiability, plus the legitimate neighbour: a non-usage key is
        // not flagged.
        let planted = #"let camera = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String"#
        XCTAssertEqual(usageStringLookupLines(in: planted), [1],
                       "the usage-string detector missed its own planted lookup")
        let legitimate = "let version = Bundle.main.object(forInfoDictionaryKey: "
            + "\"CFBundleShortVersionString\") as? String"
        XCTAssertTrue(usageStringLookupLines(in: legitimate).isEmpty,
                      "the usage-string detector flags an ordinary Info.plist lookup")
    }

    /// The lines that read a usage string from the merged Info.plist
    /// dictionary. `object(forInfoDictionaryKey:)` with a direct
    /// `…UsageDescription` key literal, `infoDictionary[…]` with the same
    /// key, or any `object(forInfoDictionaryKey:)` within two lines of a
    /// `UsageDescription` token.
    private func usageStringLookupLines(in code: String) -> [Int] {
        let direct = "object\\s*\\(\\s*forInfoDictionaryKey\\s*:\\s*\"[^\"]*UsageDescription\""
        let dictionary = "infoDictionary\\s*\\[[^\\]]*UsageDescription"
        let read = "object\\s*\\(\\s*forInfoDictionaryKey\\s*:"
        let usage = "UsageDescription"
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var hits = Set<Int>()
        for (index, line) in lines.enumerated() {
            if !lineMatches(of: direct, in: line).isEmpty
                || !lineMatches(of: dictionary, in: line).isEmpty {
                hits.insert(index + 1)
            }
            if !lineMatches(of: read, in: line).isEmpty {
                let lower = max(0, index - 2)
                let upper = min(lines.count - 1, index + 2)
                if (lower...upper).contains(where: { lines[$0].contains(usage) }) {
                    hits.insert(index + 1)
                }
            }
        }
        return hits.sorted()
    }

    // MARK: - Scenario: the gate remains honest about its limits

    func testGateSelfTestDoesNotModifyShippingTree() throws {
        let gate = try readIOSFile(gateRelativePath)

        // 1. Every self-test tree is built in a temporary directory, and the
        //    real engine is pointed at that root as a subprocess.
        XCTAssertTrue(gate.contains(
            "tempfile.TemporaryDirectory(prefix=\"log-safety-coverage-\")"),
                      "the coverage self-test no longer builds a temporary tree")
        XCTAssertTrue(gate.contains(
            "source_root = os.path.join(tmp, SELF_TEST_SOURCE_DIR)"),
                      "the self-test no longer writes under its temporary directory")
        XCTAssertTrue(gate.contains("\"--source-root\", source_root"),
                      "the self-test no longer runs the engine over the temporary root")

        // 2. The copy legs read a shipping file read-only and append the seed
        //    in memory; the only write in the loop is under `source_root`.
        let reader = try XCTUnwrap(
            section(after: "def _shipped_feature_source(relative: str) -> str:",
                    length: 400, in: gate),
            "the read-only shipped-file helper is missing")
        XCTAssertTrue(reader.contains(
            "with open(os.path.join(DEFAULT_SOURCE_ROOT, relative), encoding=\"utf-8\") as handle:"),
                      "the shipped-file helper is no longer an explicit read")
        XCTAssertFalse(reader.contains("\"w\""),
                       "the shipped-file helper opens a shipping path for writing")

        let selfTest = try XCTUnwrap(
            section(after: "def run_self_test(quiet=False) -> int:",
                    length: 5160, in: gate),
            "run_self_test is missing")
        XCTAssertTrue(selfTest.contains("path = os.path.join(source_root, relative)"),
                      "the self-test writes a path that is not under its temp root")
        XCTAssertTrue(selfTest.contains("with open(path, \"w\", encoding=\"utf-8\") as handle:"),
                      "the self-test's write shape changed — the temp-dir guarantee "
                      + "must be re-established, not assumed")
        XCTAssertFalse(selfTest.contains("open(os.path.join(DEFAULT_SOURCE_ROOT"),
                       "the self-test writes directly into the shipping tree")

        // 3. The shipping bytes are compared before and after every guarded
        //    leg, and a change fails the leg. This is the check, not a promise.
        XCTAssertTrue(selfTest.contains("shipped_before"),
                      "the before-digest of the shipping file is gone")
        XCTAssertTrue(selfTest.contains("shipped_after"),
                      "the after-digest of the shipping file is gone")
        XCTAssertTrue(selfTest.contains(
            "the shipping tree changed during a temporary-copy leg"),
                      "a changed shipping tree no longer fails a copy leg")

        // 4. The copy legs declare the shipping file as guarded.
        let copyLeg = try XCTUnwrap(
            section(after: "\"seeded-instruction-text-in-feature-copy\"",
                    length: 800, in: gate),
            "the planted free-text copy leg is missing")
        XCTAssertTrue(copyLeg.contains("[_SELF_TEST_INSTRUCTION_COPY]"),
                      "the copy leg no longer guards the shipping file's bytes")

        // The live gate run is the build script's (`check-release-log-safety.sh`
        // from `ios/build.sh`), not this test: the simulator bundle has no
        // Process. During T-026 the manual run on a temporary copy exited 1,
        // named the copied file with both rules, left the shipping file's
        // sha256 identical, and removed the temporary copy.
    }
}
