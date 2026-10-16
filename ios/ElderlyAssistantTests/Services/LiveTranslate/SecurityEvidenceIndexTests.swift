import XCTest
@testable import ElderlyAssistant

/// T-029 — the evidence index, kept honest by a test.
///
/// `specs/LCT-security-evidence-index.md` is what the `security-test` gate
/// reads, and an index that has quietly rotted is worse than no index: it
/// reports coverage for tests that were renamed, deleted, or never existed.
/// This suite makes that failure mode loud:
///
///  - every amendment AM-1 … AM-10 must name at least one test;
///  - every named test must exist in the test target;
///  - every test in `SecurityEvidenceBoundaryTests` must be named here, so
///    evidence cannot be added without being indexed;
///  - the index must keep its residual-risk, known-limitation and
///    unexercised-path sections, naming SR-1;
///  - AM-5's enforcement point — a build gate, not an XCTest — must actually
///    be wired ahead of the first `xcodebuild`, and every rule the engine
///    declares must have both fixtures.
///
/// It asserts existence and structure, never passing status: a test that is
/// listed, exists, and *fails* is a finding for the gate to see, and this
/// suite reporting it green would be exactly the dishonesty it exists to
/// prevent.
final class SecurityEvidenceIndexTests: XCTestCase {

    // MARK: - Locating the evidence

    /// The repository root, from this file's own path: the `ios/` directory
    /// is found by structure (`FeatureSourceScan`), and the spec area is its
    /// sibling.
    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        let ios = FeatureSourceScan.iosDirectory(file: file)
        let root = ios.deletingLastPathComponent()
        let specs = root.appendingPathComponent("specs")
        guard FileManager.default.fileExists(atPath: specs.path) else {
            throw EvidenceDefect.missing("no specs/ directory at \(specs.path)")
        }
        return root
    }

    private func indexText(file: StaticString = #filePath) throws -> String {
        let url = try repositoryRoot(file: file)
            .appendingPathComponent("specs/LCT-security-evidence-index.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw EvidenceDefect.missing("the evidence index is not readable at \(url.path)")
        }
        return text
    }

    private enum EvidenceDefect: Error, CustomStringConvertible {
        case missing(String)
        case malformed(String)

        var description: String {
            switch self {
            case .missing(let what): return "evidence defect: \(what)"
            case .malformed(let what): return "evidence defect: \(what)"
            }
        }
    }

    // MARK: - Parsing

    /// The body of each `### AM-<n>` section, keyed by number.
    private func amendmentSections(in text: String) -> [Int: String] {
        var sections: [Int: [String]] = [:]
        var current: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if let number = Self.amendmentHeading(line) {
                current = number
                sections[number] = []
                continue
            }
            if line.hasPrefix("### ") || line.hasPrefix("## ") || line == "---" {
                current = nil
            }
            if let number = current {
                sections[number, default: []].append(line)
            }
        }
        return sections.mapValues { $0.joined(separator: "\n") }
    }

    private static func amendmentHeading(_ line: String) -> Int? {
        guard line.hasPrefix("### AM-") else { return nil }
        let rest = line.dropFirst("### AM-".count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// Every `Suite.testName` token in a body, in order and without repeats.
    private func namedTests(in body: String) -> [String] {
        let pattern = "([A-Z][A-Za-z0-9_]*)\\.(test[A-Za-z0-9_]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: body, options: [], range: range) {
            guard let suite = Range(match.range(at: 1), in: body),
                  let test = Range(match.range(at: 2), in: body) else { continue }
            let token = "\(body[suite]).\(body[test])"
            if seen.insert(token).inserted { out.append(token) }
        }
        return out
    }

    /// The test target's Swift sources, by file name.
    private func testSources(file: StaticString = #filePath) throws -> [(name: String, text: String)] {
        let root = try repositoryRoot(file: file).appendingPathComponent("ios/ElderlyAssistantTests")
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else {
            throw EvidenceDefect.missing("no test target at \(root.path)")
        }
        var sources: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            sources.append((url.lastPathComponent, text))
        }
        guard !sources.isEmpty else {
            throw EvidenceDefect.missing("the test target contains no Swift sources")
        }
        return sources
    }

    // MARK: - AM-1 … AM-10 each name a real test

    func testEveryAmendmentMapsToAtLeastOneNamedTestThatExists() throws {
        let text = try indexText()
        let sections = amendmentSections(in: text)
        let sources = try testSources()

        for amendment in 1...10 {
            guard let body = sections[amendment] else {
                XCTFail("the evidence index has no '### AM-\(amendment)' section")
                continue
            }
            let names = namedTests(in: body)
            XCTAssertFalse(names.isEmpty,
                           "AM-\(amendment) names no test — an amendment with no named "
                           + "evidence is not evidenced")

            for token in names {
                let parts = token.split(separator: ".").map(String.init)
                guard parts.count == 2 else { continue }
                let (suite, test) = (parts[0], parts[1])
                let declaring = sources.filter { $0.text.contains("class \(suite)") }
                XCTAssertFalse(declaring.isEmpty,
                               "AM-\(amendment) names \(token), but no test file declares "
                               + "class \(suite)")
                let implementing = declaring.filter { $0.text.contains("func \(test)(") }
                XCTAssertFalse(implementing.isEmpty,
                               "AM-\(amendment) names \(token), but \(suite) does not "
                               + "declare \(test) — the index has rotted")
            }
        }
    }

    /// The same existence rule, applied to the **whole document** rather than
    /// only to the `### AM-` sections: the index may not name a test that does
    /// not exist anywhere, including in the tables for requirements that are
    /// not amendments (the spend latch, failure isolation, the egress paths).
    func testNoTestNamedAnywhereInTheIndexIsMissingFromTheTarget() throws {
        let text = try indexText()
        let sources = try testSources()
        let names = namedTests(in: text)
        XCTAssertFalse(names.isEmpty, "the index names no test at all")

        for token in names {
            let parts = token.split(separator: ".").map(String.init)
            guard parts.count == 2 else { continue }
            let (suite, test) = (parts[0], parts[1])
            let declaring = sources.filter { $0.text.contains("class \(suite)") }
            XCTAssertFalse(declaring.isEmpty,
                           "the index names \(token), but no file in the test target declares "
                           + "class \(suite)")
            XCTAssertTrue(declaring.contains { $0.text.contains("func \(test)(") },
                          "the index names \(token), but \(suite) does not declare \(test)")
        }
    }

    // MARK: - No orphaned evidence

    func testEveryBoundaryEvidenceTestIsIndexedHere() throws {
        let text = try indexText()
        let sources = try testSources()
        let boundary = try XCTUnwrap(sources.first { $0.name == "SecurityEvidenceBoundaryTests.swift" },
                                     "the boundary evidence suite is missing from the target")

        let pattern = "func (test[A-Za-z0-9_]+)\\("
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(boundary.text.startIndex..<boundary.text.endIndex,
                            in: boundary.text)
        let tests = regex.matches(in: boundary.text, options: [], range: range).compactMap {
            Range($0.range(at: 1), in: boundary.text).map { String(boundary.text[$0]) }
        }
        XCTAssertFalse(tests.isEmpty, "the boundary suite declares no tests")

        for test in tests {
            XCTAssertTrue(text.contains("SecurityEvidenceBoundaryTests.\(test)"),
                          "\(test) is evidence the security-test gate should be able to find, "
                          + "but the index does not name it")
        }
    }

    // MARK: - The index says what was not proven

    func testTheIndexRecordsResidualRisksKnownLimitationsAndUnexercisedPaths() throws {
        let text = try indexText()
        let lowercased = text.lowercased()

        for required in ["residual", "known limitations", "not exercised"] {
            XCTAssertTrue(lowercased.contains(required),
                          "the evidence index does not have a '\(required)' section — the "
                          + "gate must be able to read what was not proven")
        }
        XCTAssertTrue(text.contains("SR-1"),
                      "SR-1 is a recorded residual and must not be retired silently")
        XCTAssertTrue(lowercased.contains("not exercisable"),
                      "the index must record the paths that cannot be exercised rather than "
                      + "claiming them")
        XCTAssertTrue(text.contains("specs/LCT-device-validation-protocol.md"),
                      "the device-only checks must be pointed at their own record")

        // And it must not claim a device run it did not have.
        for forbidden in ["airplane-mode run passed", "verified on device", "device run: pass"] {
            XCTAssertFalse(lowercased.contains(forbidden),
                           "the index claims '\(forbidden)'; no device run happened in this work")
        }
    }

    // MARK: - AM-5's enforcement point is wired, and every rule is fixtured

    func testAM5TheGateIsWiredAheadOfEveryTestScopeAndEveryRuleHasFixtures() throws {
        let root = try repositoryRoot()
        let tools = root.appendingPathComponent("ios/tools")

        // 1. The fixture suite and the engine exist.
        for name in ["check-release-log-safety.py", "check-release-log-safety.sh",
                     "check-release-log-safety-fixtures.py"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: tools.appendingPathComponent(name).path),
                          "\(name) is missing — AM-5's enforcement point is gone")
        }

        // 2. The shell gate runs the engine *and* its own fixture suite.
        let shell = try String(contentsOf: tools.appendingPathComponent(
            "check-release-log-safety.sh"), encoding: .utf8)
        XCTAssertTrue(shell.contains("check-release-log-safety-fixtures.py"),
                      "the gate does not run its own fixture suite, so a rule that stopped "
                      + "firing would pass every build")

        // 3. build.sh calls the gate inside run_tests, before any xcodebuild.
        let build = try String(contentsOf: root.appendingPathComponent("ios/build.sh"),
                               encoding: .utf8)
        let buildLines = build.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let runTestsIndex = buildLines.firstIndex(where: { $0.hasPrefix("run_tests()") }),
              let gateIndex = buildLines.firstIndex(where: {
                  $0.hasPrefix("    ") && $0.contains("check-release-log-safety.sh")
              }),
              let firstTestRun = buildLines.firstIndex(where: {
                  $0.hasPrefix("    ") && $0.hasPrefix("    xcodebuild test")
              }) else {
            return XCTFail("build.sh no longer has the shape this check understands — "
                           + "the gate's wiring must be re-established, not assumed")
        }
        XCTAssertGreaterThan(gateIndex, runTestsIndex,
                             "the log-safety gate is no longer called from run_tests")
        XCTAssertLessThan(gateIndex, firstTestRun,
                          "the log-safety gate must run ahead of every test scope, not after it")

        // 4. Every rule the engine declares has both fixtures.
        let engine = try String(contentsOf: tools.appendingPathComponent(
            "check-release-log-safety.py"), encoding: .utf8)
        let ruleIDs = Self.declaredRuleIDs(in: engine)
        XCTAssertFalse(ruleIDs.isEmpty,
                       "the engine's rule registry could not be read — the fixture check "
                       + "below would be vacuously green")
        for rule in ruleIDs {
            for kind in ["positive", "negative"] {
                let path = tools.appendingPathComponent(
                    "log-safety-fixtures/\(rule)/\(kind)").path
                XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                              "rule '\(rule)' has no \(kind) fixture — a rule without both "
                              + "fixtures is not covered")
            }
        }
    }

    /// The keys of the engine's `RULES = { … }` registry.
    private static func declaredRuleIDs(in engine: String) -> [String] {
        var ids: [String] = []
        var inRegistry = false
        for line in engine.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("RULES") && line.contains("{") {
                inRegistry = true
                continue
            }
            guard inRegistry else { continue }
            if line.hasPrefix("}") { break }
            // Registry entries are written as
            //     "rule-id":
            //         "what the rule means",
            // so a key is a quote at exactly four spaces of indentation ending
            // in a colon. Taking any quoted line instead would read the
            // *descriptions* as rule ids — which is the defect this check
            // exists to catch, so it is pinned by shape: id-shaped, colon-
            // terminated, four spaces in.
            guard line.hasPrefix("    \""), !line.hasPrefix("        \"") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(":") else { continue }
            let id = String(trimmed.dropFirst().prefix { $0 != "\"" })
            guard id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else {
                continue
            }
            ids.append(id)
        }
        return ids
    }
}
