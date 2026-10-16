import XCTest
@testable import ElderlyAssistant

/// T-123 — the security evidence bundle, kept honest by a test.
///
/// `specs/SP-security-evidence-index.md` is what the `security-test` gate
/// reads for the Spotify feature's nine security-review evidence
/// obligations. An index that has quietly rotted is worse than no index: it
/// reports evidence for tests that were renamed, deleted, or never existed,
/// and it can mark an obligation passed on prose alone. This suite makes
/// those failure modes loud:
///
///  - all nine obligations O1 … O9 must be present, and nothing else;
///  - each must carry a producer, a command or artifact, a recorded output
///    and a passing status — a placeholder row or a "PENDING" status is
///    rejected by the same parser the real bundle goes through;
///  - every `<Suite>.<test>` token the bundle names must exist in the test
///    target, and every cited suite must be covered by the recorded
///    freshness run;
///  - the only incomplete entries allowed are the DV-7 device half
///    (T-124 dependency) and the scopes' Dashboard column (OD-S2
///    dependency); both must be present with their dependency named, and
///    any other pending fails;
///  - the bundle carries no credential, query, track-id or provider-body
///    shapes (NFR-SP-002 applies to the evidence itself).
///
/// It asserts existence and structure, never passing status: a test that is
/// listed, exists, and *fails* is a finding for the gate to see, and this
/// suite reporting it green would be exactly the dishonesty it exists to
/// prevent. The green comes from the recorded run in `/tmp/w7-gate.log`,
/// not from this file.
final class SpotifySecurityEvidenceIndexTests: XCTestCase {

    // MARK: - Locating the bundle

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

    private func bundleText(file: StaticString = #filePath) throws -> String {
        let url = try repositoryRoot(file: file)
            .appendingPathComponent("specs/SP-security-evidence-index.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw EvidenceDefect.missing("the evidence bundle is not readable at \(url.path)")
        }
        return text
    }

    private enum EvidenceDefect: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let what): return "evidence defect: \(what)"
            }
        }
    }

    // MARK: - The bundle's machine contract (one validator; fixtures included)

    struct Obligation: Equatable {
        let number: Int
        let producer: String
        let command: String?
        let artifact: String?
        let output: String
        let status: String
        let pendings: [String]
        let evidenceTokens: [String]
        let body: String
    }

    enum BundleDefect: Error, Equatable, CustomStringConvertible {
        case missingObligation(Int)
        case duplicateObligation(Int)
        case missingField(obligation: Int, field: String)
        case emptyField(obligation: Int, field: String)
        case badStatus(obligation: Int, status: String)
        case pendingMismatch(obligation: Int, detail: String)
        case placeholder(obligation: Int, token: String)

        var description: String {
            switch self {
            case .missingObligation(let n):
                return "bundle defect: no section for obligation O\(n)"
            case .duplicateObligation(let n):
                return "bundle defect: obligation O\(n) appears more than once"
            case .missingField(let n, let field):
                return "bundle defect: obligation O\(n) has no \(field): line"
            case .emptyField(let n, let field):
                return "bundle defect: obligation O\(n)'s \(field): is empty — "
                    + "a placeholder is not a recorded result"
            case .badStatus(let n, let status):
                return "bundle defect: obligation O\(n)'s Status '\(status)' is not a "
                    + "passing status (PASS or PASS-partial); a pending obligation "
                    + "is recorded as PASS-partial with its dependency named"
            case .pendingMismatch(let n, let detail):
                return "bundle defect: obligation O\(n) \(detail)"
            case .placeholder(let n, let token):
                return "bundle defect: obligation O\(n) contains the placeholder "
                    + "'\(token)' — a placeholder is not a recorded result"
            }
        }
    }

    /// The structural validator. Both the real bundle and the rejection
    /// fixtures go through this one function, so the failure path is
    /// genuinely exercised rather than asserted in prose.
    static func parseObligations(_ text: String,
                                 required: ClosedRange<Int> = 1...9) throws -> [Obligation] {
        let sections = try obligationSections(in: text)
        var out: [Obligation] = []
        for number in required {
            guard let body = sections[number] else { throw BundleDefect.missingObligation(number) }
            out.append(try parseObligation(number: number, body: body))
        }
        return out
    }

    static func parseObligation(number: Int, body: String) throws -> Obligation {
        func values(of label: String) -> [String] {
            body.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("- \(label):") else { return nil }
                return String(line.dropFirst("- \(label):".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        func value(of label: String) -> String? { values(of: label).first }

        guard let producer = value(of: "Producer") else {
            throw BundleDefect.missingField(obligation: number, field: "Producer")
        }
        guard !producer.isEmpty else {
            throw BundleDefect.emptyField(obligation: number, field: "Producer")
        }

        let command = value(of: "Command")
        let artifact = value(of: "Artifact")
        guard command != nil || artifact != nil else {
            throw BundleDefect.missingField(obligation: number, field: "Command or Artifact")
        }
        if let command, command.isEmpty, artifact == nil {
            throw BundleDefect.emptyField(obligation: number, field: "Command")
        }
        if let artifact, artifact.isEmpty, command == nil {
            throw BundleDefect.emptyField(obligation: number, field: "Artifact")
        }

        guard let output = value(of: "Output") else {
            throw BundleDefect.missingField(obligation: number, field: "Output")
        }
        guard !output.isEmpty else {
            throw BundleDefect.emptyField(obligation: number, field: "Output")
        }

        guard let status = value(of: "Status") else {
            throw BundleDefect.missingField(obligation: number, field: "Status")
        }
        guard status == "PASS" || status == "PASS-partial" else {
            throw BundleDefect.badStatus(obligation: number, status: status)
        }

        let pendings = values(of: "Pending")
        if status == "PASS-partial" && pendings.isEmpty {
            throw BundleDefect.pendingMismatch(
                obligation: number, detail: "is PASS-partial with no Pending: line")
        }
        if status == "PASS" && !pendings.isEmpty {
            throw BundleDefect.pendingMismatch(
                obligation: number, detail: "carries a Pending: line but is marked PASS")
        }
        for pending in pendings where pending.isEmpty {
            throw BundleDefect.emptyField(obligation: number, field: "Pending")
        }

        let tokens = namedTests(in: body)
        guard !tokens.isEmpty else {
            throw BundleDefect.missingField(
                obligation: number, field: "evidence (`<Suite>.<test>` token)")
        }

        for placeholder in ["TODO", "TBD", "FIXME", "XXX"] {
            if body.range(of: "\\b\(placeholder)\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil {
                throw BundleDefect.placeholder(obligation: number, token: placeholder)
            }
        }

        return Obligation(number: number, producer: producer, command: command,
                          artifact: artifact, output: output, status: status,
                          pendings: pendings, evidenceTokens: tokens, body: body)
    }

    /// The body of each `### O<n>` section, keyed by number, plus duplicate
    /// detection.
    static func obligationSections(in text: String) throws -> [Int: String] {
        var sections: [Int: [String]] = [:]
        var current: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if let number = obligationHeading(line) {
                guard sections[number] == nil else {
                    throw BundleDefect.duplicateObligation(number)
                }
                current = number
                sections[number] = []
                continue
            }
            if line.hasPrefix("#") { current = nil }
            if let number = current { sections[number, default: []].append(line) }
        }
        return sections.mapValues { $0.joined(separator: "\n") }
    }

    private static func obligationHeading(_ line: String) -> Int? {
        guard line.hasPrefix("### O") else { return nil }
        let rest = line.dropFirst("### O".count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, rest.count > digits.count,
              rest[rest.index(rest.startIndex, offsetBy: digits.count)] == " " else { return nil }
        return Int(digits)
    }

    /// Every `Suite.testName` token in a body, in order and without repeats.
    static func namedTests(in body: String) -> [String] {
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

    /// The tokens that do not resolve to a declared test, checked against
    /// the same "grep the test tree" mechanism the LCT index test uses.
    static func unknownTestTokens(_ tokens: [String],
                                  sources: [(name: String, text: String)]) -> [String] {
        var unknown: [String] = []
        for token in tokens {
            let parts = token.split(separator: ".").map(String.init)
            guard parts.count == 2 else { continue }
            let (suite, test) = (parts[0], parts[1])
            let declaring = sources.filter { $0.text.contains("class \(suite)") }
            if declaring.isEmpty
                || !declaring.contains(where: { $0.text.contains("func \(test)(") }) {
                unknown.append(token)
            }
        }
        return unknown
    }

    struct PendingRule {
        let obligation: Int
        let markers: [String]
    }

    /// The exactly-allowed incomplete entries. A `- Pending:` line outside
    /// this set fails the suite; a pending inside it must name the
    /// dependency. O1 is tolerated-but-not-required: the app-image scan may
    /// legitimately be recorded as pending device-build instead of run.
    static let allowedPendingRules: [PendingRule] = [
        PendingRule(obligation: 1, markers: ["T-124", "device-build"]),
        PendingRule(obligation: 6, markers: ["T-124", "DV-7"]),
        PendingRule(obligation: 8, markers: ["OD-S2", "Dashboard"]),
    ]

    static func pendingViolations(_ obligations: [Obligation]) -> [String] {
        var violations: [String] = []
        for obligation in obligations {
            // "Exactly the allowed halves" is a cap, not a subset check: a
            // second `- Pending:` entry on an allowed obligation is a
            // violation even when it names the same dependency (W7 review R3).
            if obligation.pendings.count > 1 {
                violations.append("O\(obligation.number) records "
                                  + "\(obligation.pendings.count) Pending: entries — "
                                  + "at most one pending per obligation is allowed")
                continue
            }
            for pending in obligation.pendings {
                guard let rule = allowedPendingRules.first(where: {
                    $0.obligation == obligation.number
                }) else {
                    violations.append("O\(obligation.number) records a Pending: entry "
                                      + "outside the allowed set — \(pending)")
                    continue
                }
                for marker in rule.markers where !pending.localizedCaseInsensitiveContains(marker) {
                    violations.append("O\(obligation.number)'s pending does not name "
                                      + "\(marker) — \(pending)")
                }
            }
        }
        return violations
    }

    /// The test target's Swift sources, by file name.
    private func testSources(file: StaticString = #filePath) throws -> [(name: String, text: String)] {
        let root = try repositoryRoot(file: file)
            .appendingPathComponent("ios/ElderlyAssistantTests")
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

    // MARK: - Scenario 1: every obligation has a complete, reproducible entry

    func testEveryObligationCarriesProducerCommandOrArtifactOutputAndAPassingStatus() throws {
        let text = try bundleText()
        let sections = try Self.obligationSections(in: text)
        XCTAssertEqual(Set(sections.keys).sorted(), Array(1...9),
                       "the bundle must hold exactly the nine obligations O1 … O9")

        let obligations = try Self.parseObligations(text)
        XCTAssertEqual(obligations.map(\.number), Array(1...9))
        for obligation in obligations {
            XCTAssertFalse(obligation.evidenceTokens.isEmpty,
                           "O\(obligation.number) names no test — an obligation with no "
                           + "named evidence is not evidenced")
            XCTAssertTrue(obligation.command != nil || obligation.artifact != nil,
                          "O\(obligation.number) has neither a command nor an artifact")
            XCTAssertFalse(obligation.output.isEmpty,
                           "O\(obligation.number) has no recorded output")
        }
    }

    func testNoTestNamedAnywhereInTheBundleIsMissingFromTheTarget() throws {
        let text = try bundleText()
        let sources = try testSources()
        let tokens = Self.namedTests(in: text)
        XCTAssertFalse(tokens.isEmpty, "the bundle names no test at all")

        let unknown = Self.unknownTestTokens(tokens, sources: sources)
        XCTAssertEqual(unknown, [],
                       "the bundle names tests that do not exist — the index has rotted: "
                       + unknown.joined(separator: ", "))
    }

    // MARK: - Scenario 2: the only incomplete entries are the allowed ones

    func testTheOnlyIncompleteEntriesAreTheExactlyAllowedPendings() throws {
        let text = try bundleText()
        let obligations = try Self.parseObligations(text)

        let violations = Self.pendingViolations(obligations)
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))

        // The two known-incomplete halves have not landed and must be
        // recorded, not papered over. When T-124's DV-7 capture or the
        // owner's OD-S2 registration lands, the bundle is updated to cite
        // the result and this test is updated in the same change — the
        // pending must never disappear by hand.
        let six = try XCTUnwrap(obligations.first { $0.number == 6 })
        let eight = try XCTUnwrap(obligations.first { $0.number == 8 })
        XCTAssertEqual(six.status, "PASS-partial",
                       "O6's device half (DV-7) has not landed; it must not read as PASS")
        XCTAssertEqual(eight.status, "PASS-partial",
                       "O8's Dashboard column has not landed; it must not read as PASS")
        XCTAssertTrue(six.pendings.contains { $0.contains("T-124") && $0.contains("DV-7") },
                      "O6 must name the DV-7 / T-124 dependency")
        XCTAssertTrue(eight.pendings.contains { $0.contains("OD-S2") },
                      "O8 must name the OD-S2 dependency")
    }

    // MARK: - The recorded freshness run covers every cited suite

    func testTheBundleRecordsBuildIdentityAndAFreshnessRunCoveringEveryCitedSuite() throws {
        let text = try bundleText()

        XCTAssertTrue(text.contains("feat/spotify-music-integration"),
                      "the bundle must record its branch")
        XCTAssertNotNil(text.range(of: "\\b[0-9a-f]{7,40}\\b", options: .regularExpression),
                        "the bundle must record the build identity (a git revision)")
        XCTAssertTrue(text.contains("Xcode"),
                      "the bundle must record the toolchain it was assembled with")
        XCTAssertTrue(text.contains("/tmp/w7-gate.log"),
                      "the bundle must cite the recorded freshness run")
        XCTAssertNotNil(text.range(of: "Executed [0-9]+ tests, with 0 failures",
                                   options: .regularExpression),
                        "the bundle must quote the freshness run's counts")

        let gateClasses = Self.recordedGateClasses(in: text)
        XCTAssertFalse(gateClasses.isEmpty,
                       "the bundle records no freshness-gate command, so no suite is "
                       + "covered by a fresh run")
        let cited = Set(Self.namedTests(in: text).compactMap {
            $0.split(separator: ".").first.map(String.init)
        })
        let uncovered = cited.subtracting(gateClasses)
        XCTAssertEqual(uncovered, [],
                       "these suites are cited as evidence but were not in the recorded "
                       + "freshness run: \(uncovered.sorted().joined(separator: ", "))")
    }

    /// The class list of the bundle's recorded freshness command — the one
    /// top-level `Command:` line wrapping `spotify-lockrun.sh` (obligation
    /// commands are bulleted and deliberately excluded; this must be the
    /// recorded run, not a per-obligation reproduction).
    static func recordedGateClasses(in text: String) -> Set<String> {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Command: "),
                  trimmed.contains("spotify-lockrun.sh"),
                  let range = trimmed.range(of: "test:unit ") else { continue }
            let classes = trimmed[range.upperBound...].split(separator: " ").compactMap { raw -> String? in
                let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                return token.range(of: "^[A-Za-z][A-Za-z0-9]*Tests$",
                                   options: .regularExpression) != nil ? token : nil
            }
            return Set(classes)
        }
        return []
    }

    // MARK: - The rejection path is exercised, not asserted in prose

    func testAnIncompleteObligationEntryIsRejectedByTheSameParser() {
        func section(_ number: Int,
                     producer: String? = "T-123",
                     command: String? = "reproduce-command",
                     artifact: String? = nil,
                     output: String? = "recorded",
                     status: String = "PASS",
                     pending: String? = nil,
                     evidence: String? = "- Evidence: `FakeSuite.testCase`") -> String {
            var lines = ["### O\(number) — fixture"]
            if let producer { lines.append("- Producer: \(producer)") }
            if let command { lines.append("- Command: \(command)") }
            if let artifact { lines.append("- Artifact: \(artifact)") }
            if let output { lines.append("- Output: \(output)") }
            lines.append("- Status: \(status)")
            if let pending { lines.append("- Pending: \(pending)") }
            if let evidence { lines.append(evidence) }
            return lines.joined(separator: "\n")
        }

        func rejects(_ fixture: String, required: ClosedRange<Int>? = nil,
                     names: String, file: StaticString = #filePath,
                     line: UInt = #line) {
            // Each fixture is validated against its own obligation range: a
            // fixture numbered O4 must be rejected for the O4 defect, not for
            // the absent O1 … O3 that the full-bundle range would demand
            // first. Callers testing the missing-obligation path pass an
            // explicit wider range.
            let range = required ?? {
                let firstLine = fixture.split(separator: "\n", maxSplits: 1)[0]
                let number = Self.obligationHeading(String(firstLine)) ?? 1
                return number...number
            }()
            XCTAssertThrowsError(try Self.parseObligations(fixture, required: range),
                                 file: file, line: line) { error in
                XCTAssertTrue("\(error)".contains(names),
                              "expected the rejection to name \(names); got: \(error)",
                              file: file, line: line)
            }
        }

        // A row without a producer, a command/artifact, or an output is not
        // an entry — each is rejected, naming the obligation.
        rejects(section(4, producer: nil), names: "O4")
        rejects(section(4, producer: ""), names: "O4")
        rejects(section(5, command: nil), names: "O5")
        rejects(section(5, output: nil), names: "O5")
        rejects(section(5, output: ""), names: "O5")
        // A status that is not a passing status is rejected — a pending row
        // must be PASS-partial with its dependency, never "PENDING".
        rejects(section(3, status: "PENDING"), names: "O3")
        rejects(section(3, status: "INCOMPLETE"), names: "O3")
        // Status and pending markers must agree.
        rejects(section(6, status: "PASS-partial"), names: "O6")
        rejects(section(6, status: "PASS",
                        pending: "DV-7 device capture (dependency: T-124)"), names: "O6")
        // A placeholder stands where a result belongs.
        rejects(section(2, output: "TODO"), names: "O2")
        // A named test with no evidence token is not evidence.
        rejects(section(7, evidence: nil), names: "O7")
        // A missing obligation is named, and a duplicate is refused.
        rejects(section(1), required: 1...2, names: "O2")
        rejects(section(1) + "\n" + section(1), names: "O1")

        // The token-existence rule, exercised on fixture sources: a token
        // whose suite or test does not exist is refused by the same
        // mechanism the real bundle is checked with.
        let fakeSources: [(name: String, text: String)] = [
            (name: "FakeSuite.swift",
             text: "final class FakeSuite: XCTestCase {\n    func testCase() {}\n}\n"),
        ]
        XCTAssertEqual(Self.unknownTestTokens(["FakeSuite.testCase"], sources: fakeSources), [])
        XCTAssertEqual(Self.unknownTestTokens(["FakeSuite.testMissing"], sources: fakeSources),
                       ["FakeSuite.testMissing"])
        XCTAssertEqual(Self.unknownTestTokens(["NoSuchSuite.testCase"], sources: fakeSources),
                       ["NoSuchSuite.testCase"])
    }

    func testAPendingOutsideTheAllowedSetIsRejectedByTheSameValidator() throws {
        // O3 is not one of the two halves allowed to be incomplete.
        let wrongObligation = try Self.parseObligations(
            "### O3 — fixture\n"
            + "- Producer: T-123\n- Command: cmd\n- Output: partial\n"
            + "- Status: PASS-partial\n- Pending: waiting on something else\n"
            + "- Evidence: `FakeSuite.testCase`\n",
            required: 3...3)
        XCTAssertFalse(Self.pendingViolations(wrongObligation).isEmpty,
                       "a pending outside the allowed set must be a violation")

        // O8 may be pending only with the OD-S2 dependency named.
        let missingDependency = try Self.parseObligations(
            "### O8 — fixture\n"
            + "- Producer: T-123\n- Command: cmd\n- Output: partial\n"
            + "- Status: PASS-partial\n- Pending: waiting on the registration\n"
            + "- Evidence: `FakeSuite.testCase`\n",
            required: 8...8)
        XCTAssertFalse(Self.pendingViolations(missingDependency).isEmpty,
                       "O8's pending must name OD-S2")

        // The allowed shape passes the same validator.
        let allowed = try Self.parseObligations(
            "### O8 — fixture\n"
            + "- Producer: T-123\n- Command: cmd\n- Output: partial\n"
            + "- Status: PASS-partial\n"
            + "- Pending: the Dashboard-registered scope column — owner step OD-S2\n"
            + "- Evidence: `FakeSuite.testCase`\n",
            required: 8...8)
        XCTAssertEqual(Self.pendingViolations(allowed), [])

        // A second Pending: entry on an allowed obligation is refused even
        // when it names the dependency — "exactly the two halves" must be a
        // cap the validator holds, not a subset it happens to accept
        // (W7 review R3).
        let duplicatePending = try Self.parseObligations(
            "### O6 — fixture\n"
            + "- Producer: T-123\n- Command: cmd\n- Output: partial\n"
            + "- Status: PASS-partial\n"
            + "- Pending: DV-7 device capture — T-124\n"
            + "- Pending: DV-7 device capture, duplicated — T-124\n"
            + "- Evidence: `FakeSuite.testCase`\n",
            required: 6...6)
        XCTAssertFalse(Self.pendingViolations(duplicatePending).isEmpty,
                       "a second Pending: entry on an allowed obligation must be a violation")
    }

    // MARK: - The bundle describes; it never copies sensitive material

    func testTheBundleCarriesNoCredentialQueryOrTrackIdentifierShapes() throws {
        let text = try bundleText()
        let forbidden: [(pattern: String, what: String)] = [
            ("spotify:track:[A-Za-z0-9]{22}", "a constructed track identifier"),
            ("Bearer\\s+[A-Za-z0-9._~-]{16,}", "a bearer-token value"),
            ("\"(access_token|refresh_token)\"\\s*:\\s*\"", "a provider token-body shape"),
            ("code_verifier=[A-Za-z0-9_~.-]{10,}", "a PKCE verifier value"),
        ]
        for (pattern, what) in forbidden {
            XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                         "the bundle contains \(what) — evidence describes, never copies "
                         + "(NFR-SP-002 applies to the evidence itself)")
        }
    }

    // MARK: - The bundle says what is not proven

    func testTheBundleRecordsLimitsGapsAndTheDeviceRecordItPointsAt() throws {
        let text = try bundleText()
        let lowercased = text.lowercased()

        for required in ["recorded limits", "not exercised"] {
            XCTAssertTrue(lowercased.contains(required),
                          "the bundle has no '\(required)' record — the gate must be able "
                          + "to read what was not proven")
        }
        XCTAssertTrue(text.contains("specs/SP-device-validation-protocol.md"),
                      "the device-only checks must be pointed at their own record (T-124)")

        // And it must not claim a device run it did not have.
        for forbidden in ["verified on device", "validated on device", "device run: pass"] {
            XCTAssertFalse(lowercased.contains(forbidden),
                           "the bundle claims '\(forbidden)'; no device run happened in "
                           + "this work")
        }
    }
}
