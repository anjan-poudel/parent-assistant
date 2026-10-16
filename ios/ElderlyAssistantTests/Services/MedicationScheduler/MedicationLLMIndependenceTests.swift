import XCTest

/// T-022 — the medication unit's self-containment guard (source
/// inspection, the `PinnedSurfaceGuardTests` / `FeatureSourceScan`
/// convention).
///
/// The invariant: medication scheduling is deterministic, offline and
/// model-free. No file the medication unit ships may reference the LLM /
/// brain / interpreter stack — not the voice interpreters, not the intent
/// router, not the prompt composer, not the cloud client the brain can
/// fall back to. A schedule that depends on a model is a schedule that can
/// silently fail to fire, and this guard makes that dependency impossible
/// to introduce unseen: it reads the SOURCE at test time and fails naming
/// the file, the symbol and the line.
///
/// ## Coverage — why THIS file set
///
///  - every `.swift` file under
///    `ElderlyAssistant/Services/MedicationScheduler` — the unit's whole
///    service directory, ENUMERATED (not listed), so a file added later is
///    scanned the day it lands; and
///  - the three medication-only app-layer files that carry the unit's
///    views and notification plumbing:
///    `App/MedicationManageListView.swift`,
///    `App/MedicationVisualAidViews.swift`,
///    `Services/Notifications/MedicationVisualAidFireHandler.swift`.
///  - the floor: every file name the feature ships is pinned in
///    `expectedFiles` and must still resolve under the scanned set, so a
///    relocated or emptied directory fails loudly instead of shrinking the
///    scan to a passing no-op. Shared files the feature already touched
///    (`AppCoordinator`, `CommandRouter`, `SettingsView`, the family
///    notifier) are NOT scanned: they legitimately wire the LLM stack and
///    the medication feature both, and this guard is about the medication
///    unit itself.
///
/// Test files and this guard are excluded by construction (the scan roots
/// are production directories only).
///
/// ## Coverage — why THIS symbol set
///
/// Each symbol is a declared type of the LLM / interpreter stack, verified
/// present in the app today:
///  - `CommandInterpreter`, `GeminiCommandInterpreter`,
///    `LlamaCommandInterpreter`, `SwitchableCommandInterpreter`,
///    `NullCommandInterpreter` — the interpreter protocol and its
///    conformers (Services/Voice);
///  - `LocalIntentInterpreter`, `IntentRouter`, `LocalBrainChain`,
///    `InterpreterContext` — the on-device intent stack (Services/Intents,
///    Services/Voice);
///  - `JudgingCommandInterpreter`, `InterpreterFailureReporting`,
///    `LLMInterpreterWarming` — the interpreter seams;
///  - `IntentPrompt` — the LLM prompt composer (`IntentPrompt.build`);
///  - `LocalBrainTranslating` — the translation brain tier;
///  - `GeminiClient` — the cloud LLM client.
///
/// Matching rules, chosen for the guard's purpose and stated rather than
/// implied:
///  - comments are STRIPPED before matching (a file that documents "no LLM
///    symbols" must not fail this guard — `MedicationAckResolver.swift`
///    does exactly that), while string literals stay visible (a string
///    naming an interpreter type is still a reference);
///  - matches are case-insensitive full tokens at a leading word boundary,
///    so a suffix-carrying variant (`CommandInterpreterFactory`) is caught
///    too;
///  - a prefix-attached variant (`MyCommandInterpreterWrapper`) is NOT a
///    token match — the real prefixed types (`GeminiCommandInterpreter`,
///    `LlamaCommandInterpreter`, `SwitchableCommandInterpreter`,
///    `NullCommandInterpreter`, `LocalIntentInterpreter`) carry their own
///    entries above.
///
/// `testTheSweepFailsOnASeededReferenceInAnyScannedFile` and
/// `testTheSweepSparesUnrelatedIdentifiers` pin the predicate itself: the
/// sweep must fail on every seeded symbol and must not fire on benign
/// look-alikes, so a green scan can never be a vacuous one.
final class MedicationLLMIndependenceTests: XCTestCase {

    // MARK: - The pinned file set (one source of truth is this file)

    /// The unit's service directory: enumerated, so new files are scanned.
    private static let medicationDirectory = "ElderlyAssistant/Services/MedicationScheduler"

    /// The medication-only app-layer files the unit ships (resolved
    /// explicitly; a missing one is a loud failure, never a skip).
    private static let appLayerFiles = [
        "ElderlyAssistant/App/MedicationManageListView.swift",
        "ElderlyAssistant/App/MedicationVisualAidViews.swift",
        "ElderlyAssistant/Services/Notifications/MedicationVisualAidFireHandler.swift",
    ]

    /// The floor: every medication file the feature ships must resolve
    /// under the scanned set. New files are extra coverage; a file on this
    /// list going missing fails the guard.
    private static let expectedFiles = [
        "AckClarificationConfig.swift",
        "ConfirmationChallenge.swift",
        "DependencyProtocols.swift",
        "DoseLine.swift",
        "DoubleDoseDetector.swift",
        "EscalationEngine.swift",
        "IdHashing.swift",
        "MedicationAckResolver.swift",
        "MedicationEditorDraft.swift",
        "MedicationEvidenceStore.swift",
        "MedicationLabelOCR.swift",
        "MedicationLabelScanner.swift",
        "MedicationPurpose.swift",
        "MedicationPurposeLookup.swift",
        "MedicationScheduler.swift",
        "MedicationSchedulerProtocol.swift",
        "MedicationSlotClock.swift",
        "Models.swift",
        "PhotoVerifier.swift",
        "PlatformAlarmScheduler.swift",
        "ScannedSchedule.swift",
        "MedicationManageListView.swift",
        "MedicationVisualAidViews.swift",
        "MedicationVisualAidFireHandler.swift",
    ]

    // MARK: - The pinned symbol set

    private static let llmSymbols = [
        "CommandInterpreter",
        "GeminiCommandInterpreter",
        "LlamaCommandInterpreter",
        "SwitchableCommandInterpreter",
        "NullCommandInterpreter",
        "LocalIntentInterpreter",
        "IntentRouter",
        "LocalBrainChain",
        "InterpreterContext",
        "JudgingCommandInterpreter",
        "InterpreterFailureReporting",
        "LLMInterpreterWarming",
        "IntentPrompt",
        "LocalBrainTranslating",
        "GeminiClient",
    ]

    private static let surface = "medication unit LLM-independence guard"

    // MARK: - The guard

    /// NFR-MSR-002's self-containment, pinned on the source: no LLM /
    /// brain / interpreter / router symbol appears in any file the
    /// medication unit ships. Fails naming the file, the symbol and the
    /// line; fails loudly when a pinned file has gone missing.
    func testMedicationUnitNoLLMSymbols() {
        let files = scannedFiles()
        XCTAssertFalse(files.isEmpty, "\(Self.surface): the scanned file set must not be empty")

        // The floor: nothing the feature ships may vanish from the scan.
        let scannedNames = Set(files.map(\.lastPathComponent))
        for expected in Self.expectedFiles {
            XCTAssertTrue(scannedNames.contains(expected),
                          "\(Self.surface): \(expected) is missing from the scanned "
                          + "medication file set — a removed or relocated file must fail "
                          + "this guard, not silently shrink it")
        }

        var violations: [String] = []
        for url in files {
            // codeText strips comments and keeps string literals; an
            // unreadable file is an explicit XCTFail inside it.
            let text = FeatureSourceScan.codeText(of: url)
            if let failure = Self.llmReferenceFailure(
                in: text, file: FeatureSourceScan.relativePath(of: url)) {
                violations.append(failure)
            }
        }

        XCTAssertTrue(violations.isEmpty,
                      "\(Self.surface): a medication file must never reference the "
                      + "LLM stack — scheduling is model-free by design:\n"
                      + violations.joined(separator: "\n"))
    }

    // MARK: - Pure predicate (unit-testable over synthetic text)

    /// `nil` = the source references no LLM symbol. A non-nil result names
    /// the file, the symbol and the matching line — the failure a
    /// deliberately introduced dependency must produce.
    static func llmReferenceFailure(in source: String, file: String) -> String? {
        let alternation = llmSymbols
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "\\b(\(alternation))",
                                                   options: [.caseInsensitive]) else {
            XCTFail("\(surface): the symbol pattern must compile")
            return nil
        }
        for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let lineText = String(line)
            let range = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
            if let match = regex.firstMatch(in: lineText, options: [], range: range),
               let matched = Range(match.range(at: 1), in: lineText) {
                return "\(surface): \(file) references `\(lineText[matched])` at line "
                    + "\(offset + 1): \(lineText.trimmingCharacters(in: .whitespaces))"
            }
        }
        return nil
    }

    // MARK: - The predicate is falsifiable (a green scan must mean something)

    /// Every pinned symbol, seeded into a synthetic source, must be caught
    /// and named — and a lowercase usage must be caught too (the sweep is
    /// case-insensitive), so the guard cannot pass by matching nothing.
    func testTheSweepFailsOnASeededReferenceInAnyScannedFile() {
        for symbol in Self.llmSymbols {
            let seeded = """
            import Foundation

            struct SeededUse {
                let value = \(symbol)()
            }
            """
            let failure = Self.llmReferenceFailure(in: seeded, file: "Seeded.swift")
            XCTAssertNotNil(failure, "\(Self.surface): `\(symbol)` must be caught")
            XCTAssertTrue(failure?.contains(symbol) == true,
                          "\(Self.surface): the failure must name `\(symbol)`, "
                          + "got: \(failure ?? "nil")")
            XCTAssertTrue(failure?.contains("Seeded.swift") == true,
                          "\(Self.surface): the failure must name the file")
            XCTAssertTrue(failure?.contains("line 4") == true,
                          "\(Self.surface): the failure must name the line, "
                          + "got: \(failure ?? "nil")")
        }

        // Case-insensitive on purpose: a lowercase-held reference is the
        // same dependency.
        let lowercaseSeed = "func step(_ context: interpreterContext) {}\n"
        XCTAssertNotNil(Self.llmReferenceFailure(in: lowercaseSeed, file: "Seeded.swift"),
                        "\(Self.surface): an `interpreterContext` usage must be caught")
    }

    /// The precision half: benign identifiers that merely LOOK adjacent
    /// must not fail the sweep — the guard must not become noise that
    /// pressures a future task into weakening it.
    func testTheSweepSparesUnrelatedIdentifiers() {
        let benign = [
            "let interpretationScore = 0",
            "func interpret(_ text: String) -> String { text }",
            "struct MyCommandInterpreterWrapper {}",
            "let brainstormingCount = 3",
        ]
        for line in benign {
            XCTAssertNil(Self.llmReferenceFailure(in: line + "\n", file: "Benign.swift"),
                         "\(Self.surface): a benign identifier must not fail: \(line)")
        }
    }

    // MARK: - Helpers

    /// The medication unit's production files: the service directory
    /// enumerated plus the pinned app-layer files, each of which must
    /// exist (a missing one is an explicit failure inside this helper).
    private func scannedFiles(file: StaticString = #filePath) -> [URL] {
        var files = FeatureSourceScan.swiftFiles(in: Self.medicationDirectory, file: file)

        let ios = FeatureSourceScan.iosDirectory(file: file)
        for relativePath in Self.appLayerFiles {
            let url = ios.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                files.append(url)
            } else {
                XCTFail("\(Self.surface): the medication app-layer file \(relativePath) "
                        + "must exist — a removed file fails the guard, never shrinks it")
            }
        }
        return files
    }
}
