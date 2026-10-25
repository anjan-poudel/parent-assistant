import XCTest
import UIKit
@testable import ElderlyAssistant

/// C09 — the routine settings instruction row and sheet (T-023; design L2
/// §2.9, §4.2, §10.5, §11.3 M/O/Q).
///
/// SwiftUI cannot be rendered in-process in this harness, so every rendering
/// claim is pinned either at a pure value seam the view itself uses — the
/// row's label/symbol mapping, the save-outcome reducer and the shared
/// editor's draft rules — or with a `FeatureSourceScan.codeText` source pin
/// over `RoutineSettingsView.swift` (comments stripped). No `AppCoordinator`,
/// routine store or video store is constructed: the sheet's write path is
/// pinned where it is written, not by faking the whole environment.
@MainActor
final class RoutineSettingsInstructionTests: XCTestCase {

    // MARK: - Row (deliverable 1; design §2.9, §10.5)

    /// Every routine row carries the instruction control, labelled for the
    /// action the person can take now, and opens a sheet for its own entry.
    func testInstructionRowIsPresentForARoutine() {
        XCTAssertEqual(RoutineSettingsView.instructionButtonKey(hasInstruction: false),
                       "instruction.add",
                       "an entry with no instruction offers the add action")
        XCTAssertEqual(RoutineSettingsView.instructionButtonKey(hasInstruction: true),
                       "instruction.change",
                       "an entry with a present instruction offers the change action")
        XCTAssertEqual(RoutineSettingsView.instructionButtonSymbol(hasInstruction: false),
                       "text.bubble",
                       "the absent state is the plain quote/text bubble")
        XCTAssertEqual(RoutineSettingsView.instructionButtonSymbol(hasInstruction: true),
                       "text.bubble.fill",
                       "the present state is the filled quote/text bubble")
        XCTAssertGreaterThanOrEqual(RoutineSettingsView.instructionTapTarget, 44,
                                    "design §10.1: the row target is 44×44 pt")
        XCTAssertEqual(RoutineSettingsView.instructionTapTarget,
                       DesignTokens.minTapTargetSize)

        let settings = sourceOfType("RoutineSettingsView")
        let row = member("private func routineManageRow", of: settings)
        XCTAssertFalse(row.isEmpty)
        XCTAssertTrue(row.contains("instructionEditor = RoutineInstructionEditorPresentation("),
                      "the row opens the instruction sheet for its entry")
        XCTAssertTrue(row.contains("coordinator.instructionCaptureCoordinator(draftSession: .routines)"),
                      "each sheet session takes its capture coordinator from the one seam")
        XCTAssertFalse(row.contains("InstructionVideoCaptureCoordinator("),
                       "the row never constructs a capture coordinator itself")
        XCTAssertTrue(member("private static func hasInstruction(", of: settings)
            .contains("entry.instruction?.isPresent == true"),
            "the label reads IF-1, not a store")
    }

    // MARK: - Save seam (design §2.9, §4.2, IF-32)

    /// A text edit resolves to one text write; the wrapper sends it to the
    /// coordinator's single routine seam and nowhere else.
    func testTextCommitGoesThroughCoordinator() {
        var draft = InstructionDraft.loaded(instruction: nil)
        draft.setText("Take the blue pill")
        XCTAssertEqual(draft.resolvedCommit?.write,
                       .set(InstructionPayload(kind: .text, text: "Take the blue pill")))
        XCTAssertNil(draft.resolvedCommit?.pendingMedia,
                     "a text write never carries media bytes")

        let wrapper = sourceOfType("RoutineInstructionEditorSheet")
        let save = member("private func save(", of: wrapper)
        XCTAssertTrue(save.contains(
            "coordinator.saveRoutineInstruction(commit, entryId: entry.id)"),
            "one text commit goes through IF-32 unchanged")
        XCTAssertEqual(occurrences(of: "saveRoutineInstruction", in: wrapper), 1,
                       "the wrapper has exactly one write path")
        XCTAssertFalse(member("var body", of: wrapper).contains("saveRoutineInstruction"),
                       "the shared editor reports the commit; the host alone writes")
    }

    /// An image kind without pending bytes cannot resolve; the shared picker
    /// supplies those bytes through the host's `pickImage` completion.
    func testImageDraftRequiresPendingMedia() {
        var draft = InstructionDraft.loaded(instruction: nil)
        draft.chooseKind(.image)
        XCTAssertNil(draft.resolvedCommit,
                     "choosing image authors no bytes and cannot resolve")
        XCTAssertFalse(InstructionEditorView.canSave(draft),
                       "Save stays closed until the draft resolves")

        draft.setPendingImage(UIImage(), caption: "The blue box")
        XCTAssertNotNil(draft.resolvedCommit,
                        "the picked image's bytes make the media write resolvable")
        XCTAssertTrue(InstructionEditorView.canSave(draft))

        let wrapper = sourceOfType("RoutineInstructionEditorSheet")
        XCTAssertTrue(wrapper.contains("VisualAidPhotoPicker(selectionLimit: 1)"),
                      "one image from the app's existing permission-free picker")
        XCTAssertTrue(wrapper.contains("completion?(picked.first)"),
                      "the first (only) picked image is handed to the stored completion")
        let pick = member("private func pickImage", of: wrapper)
        XCTAssertTrue(pick.contains("pendingImageCompletion = completion"))
        XCTAssertTrue(pick.contains("isPickingImage = true"))
    }

    /// A video draft resolves only through the session's capture
    /// coordinator; the wrapper receives it and never builds a second one.
    func testVideoDraftUsesCaptureCoordinator() {
        var draft = InstructionDraft.loaded(instruction: nil)
        draft.chooseKind(.video)
        XCTAssertNil(draft.resolvedCommit,
                     "video resolution needs accepted pending bytes")

        let settings = sourceOfType("RoutineSettingsView")
        XCTAssertEqual(
            occurrences(of: "instructionCaptureCoordinator(draftSession: .routines)",
                        in: settings),
            1,
            "one capture session per sheet presentation, created only by the row tap")
        XCTAssertTrue(settings.contains("let capture: InstructionVideoCaptureCoordinator"),
                      "the presentation holds the session coordinator")

        let wrapper = sourceOfType("RoutineInstructionEditorSheet")
        let body = member("var body", of: wrapper)
        XCTAssertTrue(body.contains("capture: capture"),
                      "the shared editor receives the session coordinator")
        XCTAssertFalse(body.contains("instructionCaptureCoordinator"),
                       "a re-render never builds a second coordinator")
        XCTAssertFalse(wrapper.contains("InstructionVideoCaptureCoordinator("),
                       "the sheet never constructs a coordinator itself")
    }

    /// Cancelling clears the presentation and never touches the save seam.
    func testCancelDoesNotCallSave() {
        let wrapper = sourceOfType("RoutineInstructionEditorSheet")
        let body = member("var body", of: wrapper)
        XCTAssertTrue(body.contains("onCancel: onClose"),
                      "the editor's cancel path is the host's close closure")

        let save = member("private func save(", of: wrapper)
        XCTAssertFalse(save.contains("onCancel"),
                       "the write path is not reachable from a cancellation")

        let settings = sourceOfType("RoutineSettingsView")
        let sheet = branch(from: ".sheet(item: $instructionEditor)",
                           to: "private func routineManageRow", in: settings)
        XCTAssertTrue(sheet.contains("onClose: { instructionEditor = nil }"),
                      "cancelling only clears the presentation")
        XCTAssertFalse(sheet.contains("saveRoutineInstruction"))
        XCTAssertFalse(sheet.contains("setInstruction"),
                       "no store write is reachable from dismiss")
    }

    // MARK: - Failure honesty (design §11.3, T-023)

    /// Every typed write failure becomes exactly one plain catalogue line.
    func testSaveFailureShowsOnePlainLine() {
        XCTAssertEqual(
            RoutineSettingsView.saveOutcome(Result<Void, InstructionWriteError>.success(())),
            .dismissAndRefresh,
            "success is the only dismissal")

        let rows: [(InstructionWriteError, String)] = [
            (.ownerNotFound, "instruction.removed"),
            (.unresolvedPayload, "instruction.saveFailed"),
            (.persistenceFailed, "instruction.saveFailed"),
            (.mediaWriteFailed(.invalidOwner), "instruction.saveFailed"),
            (.mediaWriteFailed(.stagingFailed), "instruction.video.saveFailed"),
            (.mediaWriteFailed(.protectionFailed), "instruction.video.saveFailed"),
            (.mediaWriteFailed(.commitFailed), "instruction.video.saveFailed"),
            (.mediaWriteFailed(.deleteFailed), "instruction.saveFailed")
        ]
        for (error, expected) in rows {
            guard case .showFailure(let key) =
                    RoutineSettingsView.saveOutcome(.failure(error)) else {
                XCTFail("a write failure must produce one plain line for \(error)")
                continue
            }
            XCTAssertEqual(key, expected)
            XCTAssertEqual(key, InstructionMessageKey.forWrite(error),
                           "the reducer adds no mapping of its own")
            XCTAssertTrue(key.hasPrefix("instruction."),
                          "only catalogue keys leave the reducer")
            XCTAssertFalse(key.contains("\n"),
                           "one plain line, never a multi-line diagnostic")
        }

        // The editor renders the key it is handed; the wrapper composes no
        // copy, shows no alert and never retries by itself.
        let wrapper = sourceOfType("RoutineInstructionEditorSheet")
        XCTAssertTrue(member("var body", of: wrapper)
            .contains("saveFailureKey: saveFailureKey"))
        let save = member("private func save(", of: wrapper)
        XCTAssertEqual(occurrences(of: "saveFailureKey =", in: save), 1)
        XCTAssertFalse(save.contains("L10n"),
                       "no sentence is composed at this seam")
        XCTAssertFalse(save.contains("alert"))
    }

    /// A failure keeps the draft exactly as it was: the reducer has no draft
    /// to touch and the failure arm only writes the one key.
    func testSaveFailureKeepsDraft() {
        guard case .showFailure(let key) =
                RoutineSettingsView.saveOutcome(.failure(.persistenceFailed)) else {
            return XCTFail("expected the failure outcome")
        }
        XCTAssertEqual(key, "instruction.saveFailed")

        let wrapper = sourceOfType("RoutineInstructionEditorSheet")
        let save = member("private func save(", of: wrapper)
        XCTAssertTrue(save.contains("saveFailureKey = key"))
        XCTAssertFalse(save.contains("draft ="),
                       "a failed save never reseeds or clears the draft")
        XCTAssertFalse(save.contains("draft."),
                       "a failed save never mutates the draft either")
        XCTAssertEqual(occurrences(of: "onSaved()", in: save), 1,
                       "only success dismisses the sheet")

        // The draft is seeded exactly once, from the stored instruction, in
        // the sheet's init; no other assignment exists.
        XCTAssertEqual(
            occurrences(of: "InstructionDraft.loaded(instruction: entry.instruction)",
                        in: wrapper),
            1)
        XCTAssertTrue(member("init(entry:", of: wrapper).contains(
            "_draft = State(initialValue: InstructionDraft.loaded(instruction: entry.instruction))"))
        XCTAssertFalse(member("var body", of: wrapper).contains("InstructionDraft.loaded"))
    }

    // MARK: - Baseline preservation (design §11.3 M)

    /// The photo visual-aid flow, its sheet wiring and the refresh key are
    /// unchanged; the instruction row joins the row without reordering the
    /// photo control or the toggle.
    func testExistingVisualAidFlowIsUnchanged() {
        let settings = sourceOfType("RoutineSettingsView")

        let photoSheet = branch(from: ".sheet(item: $photoEditorEntry)",
                                to: ".sheet(item: $instructionEditor)",
                                in: settings)
        XCTAssertTrue(photoSheet.contains("ReminderVisualAidEditorView("))
        XCTAssertTrue(photoSheet.contains("entryId: entry.id"))
        XCTAssertTrue(photoSheet.contains(
            "title: entry.displayTitle(locale: coordinator.activeLocale)"))
        XCTAssertTrue(photoSheet.contains("aids: entry.visualAids"))
        XCTAssertTrue(photoSheet.contains("store: coordinator.visualAidStore"),
                      "the photo editor still reads the one visual-aid store")
        XCTAssertTrue(photoSheet.contains("locale: coordinator.activeLocale"))
        XCTAssertTrue(photoSheet.contains("coordinator.setRoutineVisualAids(entry.id, aids: aids)"),
                      "photo edits still persist immediately through the same seam")
        XCTAssertTrue(photoSheet.contains("photoEditorEntry = nil"))
        XCTAssertTrue(photoSheet.contains("entriesVersion += 1"))

        let row = member("private func routineManageRow", of: settings)
        XCTAssertTrue(row.contains(
            "Image(systemName: entry.visualAids.isEmpty ? \"photo.badge.plus\" : \"photo.fill\")"),
            "the photo symbol's two states are byte-identical")
        XCTAssertTrue(row.contains(".accessibilityLabel(Text(\"visualAid.add\"))"))
        XCTAssertTrue(row.contains("photoEditorEntry = entry"))
        XCTAssertTrue(row.contains("coordinator.setRoutineEntryEnabled(entry.id, enabled: enabled)"))

        // The refresh key and the row summaries keep their exact shape.
        XCTAssertTrue(settings.contains(
            "\"\\(entriesVersion)|\\(coordinator.conversationHistory.count)\""))
        XCTAssertTrue(settings.contains("|\\(coordinator.activeLocale.identifier)"))
        XCTAssertTrue(settings.contains("routineSummaries = Dictionary("))
        XCTAssertTrue(settings.contains(
            "private func scheduleSummary(_ entry: RoutineEntry) -> String"))

        // Photo, then instruction, then the toggle: the existing controls
        // keep their relative order.
        guard let photo = row.range(of: "photoEditorEntry = entry"),
              let instruction = row.range(
                of: "instructionEditor = RoutineInstructionEditorPresentation("),
              let toggle = row.range(of: "Toggle(\"\"") else {
            return XCTFail("the row's controls are missing")
        }
        XCTAssertLessThan(photo.lowerBound, toggle.lowerBound,
                          "the photo button still precedes the toggle")
        XCTAssertLessThan(instruction.lowerBound, toggle.lowerBound)
    }

    // MARK: - Source hygiene (design §11.3 O/Q)

    /// The view reaches no scheduler, instruction store, importer or file
    /// manager; the file's only store reference is the pre-existing photo
    /// editor seam.
    func testNoStoreReferenceInView() {
        let settings = source()
        for token in ["RoutineScheduler", "routineScheduler",
                      "InstructionVideoStore", "instructionVideoStore",
                      "InstructionVideoImporter", "instructionVideoImporter",
                      "FileManager", "fileManager"] {
            XCTAssertFalse(settings.contains(token),
                           "the routine settings view must not reach \(token)")
        }

        let wrapper = sourceOfType("RoutineInstructionEditorSheet")
        XCTAssertFalse(wrapper.contains("store:"),
                       "the instruction sheet holds no store")
        XCTAssertFalse(wrapper.contains("visualAidStore"))
        XCTAssertEqual(occurrences(of: "visualAidStore", in: settings), 1,
                       "only the photo editor's existing store seam remains")
    }

    /// No Settings deep link and no photo-library permission path: the only
    /// picker is the app's existing out-of-process, permission-free wrapper.
    func testNoSettingsDeepLinkOrPhotoLibrary() {
        let settings = source()
        for token in ["UIApplication", "openSettingsURLString",
                      "PHPhotoLibrary", "PHAsset", "requestAuthorization",
                      "PhotosPicker", "import PhotosUI",
                      "UIActivityViewController", "NSPhotoLibrary",
                      "openURL", "http://", "https://"] {
            XCTAssertFalse(settings.contains(token),
                           "no Settings deep link or photo-library path may appear: \(token)")
        }

        // The allowed reference is pinned so this test cannot pass by
        // deleting the image path.
        XCTAssertTrue(settings.contains("VisualAidPhotoPicker(selectionLimit: 1)"))
    }

    /// The row's VoiceOver label resolves the same catalogue key the label
    /// mapping names, through `L10n` and the environment's `.locale`.
    func testAccessibilityLabelOnInstructionRow() {
        XCTAssertEqual(RoutineSettingsView.instructionButtonKey(hasInstruction: false),
                       "instruction.add")
        XCTAssertEqual(RoutineSettingsView.instructionButtonKey(hasInstruction: true),
                       "instruction.change")

        let settings = sourceOfType("RoutineSettingsView")
        XCTAssertTrue(settings.contains("@Environment(\\.locale) private var locale"),
                      "the row resolves its label through the app's locale")
        let row = member("private func routineManageRow", of: settings)
        XCTAssertTrue(row.contains(".accessibilityLabel(Text(L10n.str("),
                      "the instruction button carries an explicit VoiceOver label")
        XCTAssertTrue(row.contains("RoutineSettingsView.instructionButtonKey("))
        XCTAssertTrue(row.contains("locale: locale"))
        XCTAssertTrue(row.contains("RoutineSettingsView.instructionButtonSymbol("))
        XCTAssertTrue(row.contains("minWidth: RoutineSettingsView.instructionTapTarget"))
        XCTAssertTrue(row.contains("minHeight: RoutineSettingsView.instructionTapTarget"))

        // Both mapped keys ship in both languages (NFR-RIE-002).
        let english = Locale(identifier: "en")
        let nepali = Locale(identifier: "ne")
        for key in [RoutineSettingsView.instructionButtonKey(hasInstruction: false),
                    RoutineSettingsView.instructionButtonKey(hasInstruction: true)] {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertFalse(en.isEmpty, "\(key) must resolve in English")
            XCTAssertFalse(ne.isEmpty, "\(key) must resolve in Nepali")
            XCTAssertNotEqual(en, key, "\(key) is missing from the catalogue")
            XCTAssertNotEqual(ne, key, "\(key) is missing from the Nepali catalogue")
            XCTAssertNotEqual(en, ne, "\(key) has no distinct Nepali copy")
        }
    }

    // MARK: - Source helpers

    private func source(file: StaticString = #filePath) -> String {
        FeatureSourceScan.codeText(of: settingsURL(file: file))
    }

    private func settingsURL(file: StaticString = #filePath) -> URL {
        FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/RoutineSettingsView.swift")
    }

    /// One top-level type, from its column-0 declaration to the next one.
    private func sourceOfType(_ name: String, file: StaticString = #filePath) -> String {
        let lines = source(file: file)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("struct \(name)") || $0.hasPrefix("enum \(name)")
        }) else {
            XCTFail("no type named \(name) in RoutineSettingsView.swift")
            return ""
        }
        let declarations = ["struct ", "enum ", "extension ", "final class ",
                            "class ", "@MainActor", "#if"]
        let end = lines[(start + 1)...].firstIndex { line in
            guard let first = line.first, first != " ", first != "\t" else {
                return false
            }
            return declarations.contains { line.hasPrefix($0) }
        } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// One member of a type source, from the marker to the next 4-space
    /// declaration. Markers are source text, never line numbers.
    private func member(_ marker: String, of source: String) -> String {
        guard let start = source.range(of: marker) else {
            XCTFail("no member \(marker)")
            return ""
        }
        let tail = source[start.lowerBound...]
        let searchStart = tail.index(tail.startIndex, offsetBy: marker.count)
        let endMarkers = ["\n    private ", "\n    static ", "\n    @",
                          "\n    func ", "\n    var ", "\n    init(",
                          "\n    let ", "\n    enum "]
        var end = tail.endIndex
        for endMarker in endMarkers {
            if let found = tail.range(of: endMarker,
                                      range: searchStart..<tail.endIndex),
               found.lowerBound < end {
                end = found.lowerBound
            }
        }
        return String(tail[..<end])
    }

    /// The text between two markers, failing loudly when either is missing.
    private func branch(from start: String, to end: String,
                        in source: String) -> String {
        guard let startRange = source.range(of: start) else {
            XCTFail("missing \(start)")
            return ""
        }
        guard let endRange = source.range(
            of: end, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("missing \(end) after \(start)")
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
