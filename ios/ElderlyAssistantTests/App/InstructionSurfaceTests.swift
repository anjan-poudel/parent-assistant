import XCTest
import UIKit
@testable import ElderlyAssistant

/// C08 — the three instruction surfaces (T-018; design L2 §2.8, §4.9–§4.10,
/// §10.1–§10.3, §11.3 O and Q).
///
/// SwiftUI cannot be rendered in-process in this harness, so each rendering
/// claim is pinned at the value seam that decides it — the card's `Surface`,
/// the cover's `messageKey`, the editor's draft helpers and Save gate — plus
/// a `FeatureSourceScan.codeText` source pin for the rules that must never
/// appear in the file (a player in the card, a photo-library path, inline
/// copy, a fixed text height). No rendering engine is faked.
///
/// T-021 extends this suite for the fired screen; the sixteen T-018 names
/// below keep their behaviour when it lands.
@MainActor
final class InstructionSurfaceTests: XCTestCase {

    // MARK: - Card (T-018 deliverable 1; design §4.10)

    /// `.none` is nothing at all — an `EmptyView`, never an empty container
    /// with padding (P-9, NFR-RIE-010).
    func testCardRendersNoneAsEmptyView() {
        XCTAssertEqual(InstructionCardView.surface(for: .none, hasPlayback: false),
                       .nothing)
        XCTAssertEqual(InstructionCardView.surface(for: .none, hasPlayback: true),
                       .nothing,
                       "a playback action never makes an absent instruction appear")

        let card = sourceOfType("InstructionCardView")
        let body = member("var body", of: card)
        guard let guardStart = body.range(of: "if case .none = state"),
              let elseMarker = body.range(of: "} else {",
                                          range: guardStart.upperBound..<body.endIndex) else {
            XCTFail("the card's none guard is missing from body")
            return
        }
        let noneArm = String(body[guardStart.upperBound..<elseMarker.lowerBound])
        XCTAssertTrue(noneArm.contains("EmptyView()"))
        XCTAssertFalse(noneArm.contains("VStack"))
        XCTAssertFalse(noneArm.contains(".padding"))
        XCTAssertFalse(noneArm.contains("appSurface"))

        // The container and padding exist only in the non-empty arm.
        let elseArm = String(body[elseMarker.lowerBound...])
        XCTAssertTrue(elseArm.contains(".padding(16)"))
        XCTAssertTrue(elseArm.contains(".appSurface(role: .card)"))
    }

    /// `.text` is the instruction's words, full width, never truncated.
    func testCardRendersText() {
        let state = InstructionDisplayState.text(text: "Take the blue pill")
        XCTAssertEqual(InstructionCardView.surface(for: state, hasPlayback: true),
                       .text("Take the blue pill"))

        let card = sourceOfType("InstructionCardView")
        let content = member("private var surfaceContent", of: card)
        let textBranch = branch(from: "case .text", to: "case .image", in: content)
        XCTAssertTrue(textBranch.contains("Text(text)"))
        XCTAssertTrue(textBranch.contains("frame(maxWidth: .infinity"))
        XCTAssertTrue(textBranch.contains("appearance.typography.bodyPointSize"))
        XCTAssertTrue(textBranch.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(textBranch.contains("lineLimit("),
                       "instruction text is never truncated")

        // T-021 passes the formatted fire time; the card renders it as its
        // own line above the surface, and only for a non-`.none` state.
        XCTAssertTrue(card.contains("let timeText: String?"))
        XCTAssertTrue(member("var body", of: card).contains("Text(timeText)"))
    }

    /// `.image` carries the caption as its own optional text; the photo is
    /// loaded by the card in `.task(id:)`, never in `body`.
    func testCardRendersImageWithOptionalCaption() {
        XCTAssertEqual(
            InstructionCardView.surface(
                for: .image(filename: "instruction-1.jpg", caption: "Blue box"),
                hasPlayback: false),
            .image(caption: "Blue box"))
        XCTAssertEqual(
            InstructionCardView.surface(
                for: .image(filename: "instruction-1.jpg", caption: nil),
                hasPlayback: false),
            .image(caption: nil))

        let card = sourceOfType("InstructionCardView")
        let content = member("private var surfaceContent", of: card)
        let imageBranch = branch(from: "case .image", to: "case .video", in: content)
        XCTAssertTrue(imageBranch.contains(
            "imageContent(filename: filename, caption: caption)"))

        let imageContent = member("private func imageContent", of: card)
        XCTAssertTrue(imageContent.contains("if let caption"))
        XCTAssertTrue(imageContent.contains("captionText(caption)"))
        XCTAssertTrue(imageContent.contains(".task(id: filename)"),
                      "the photo loads in a task keyed on the bare filename")
        XCTAssertTrue(imageContent.contains("InstructionSurfaceKeys.imageAccessibility"))
        XCTAssertFalse(member("var body", of: card).contains("loadImage("),
                       "no file read happens in body")
        XCTAssertTrue(card.contains("@MainActor"))
    }

    /// `.video` offers a ≥44 pt Play control and a caption; without a
    /// playback path it shows the one plain line, never a dead control.
    func testCardRendersVideoPlayAt44Points() {
        XCTAssertEqual(
            InstructionCardView.surface(
                for: .video(filename: "instruction-2.mov", caption: "Lunch routine"),
                hasPlayback: true),
            .video(caption: "Lunch routine", hasPlay: true))
        XCTAssertEqual(
            InstructionCardView.surface(
                for: .video(filename: "instruction-2.mov", caption: nil),
                hasPlayback: false),
            .video(caption: nil, hasPlay: false))

        XCTAssertGreaterThanOrEqual(InstructionCardView.playTapTarget, 44,
                                    "design §10.1: the play target is 44×44 pt")
        XCTAssertEqual(InstructionCardView.playTapTarget,
                       DesignTokens.minTapTargetSize)
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44)

        let card = sourceOfType("InstructionCardView")
        XCTAssertEqual(occurrences(of: "InstructionCardView.playTapTarget", in: card),
                       2,
                       "the play control carries the floor on both axes")
        let content = member("private var surfaceContent", of: card)
        let video = branch(from: "case .video", to: "case .unsupported", in: content)
        XCTAssertTrue(video.contains("Button"),
                      "the play affordance is a real button")
        XCTAssertTrue(video.contains("onPlay(filename)"))
        XCTAssertTrue(video.contains("minWidth: InstructionCardView.playTapTarget"))
        XCTAssertTrue(video.contains("minHeight: InstructionCardView.playTapTarget"))
        XCTAssertTrue(video.contains("InstructionSurfaceKeys.videoPlay"))
        XCTAssertTrue(video.contains("InstructionSurfaceKeys.videoUnavailable"),
                      "no playback path shows the one plain line instead")
        XCTAssertFalse(card.contains("VideoPlayer("))
        XCTAssertFalse(card.contains("AVPlayer"))
    }

    /// `.unsupported` keeps the saved words, adds exactly one plain note and
    /// offers no play/open/link control (FR-RIE-024, §11.3 Q).
    func testCardRendersUnsupportedNote() {
        XCTAssertEqual(
            InstructionCardView.surface(for: .unsupported(text: "Saved words"),
                                        hasPlayback: true),
            .unsupported("Saved words"))
        XCTAssertEqual(
            InstructionCardView.surface(for: .unsupported(text: nil),
                                        hasPlayback: false),
            .unsupported(nil))

        let card = sourceOfType("InstructionCardView")
        let content = member("private var surfaceContent", of: card)
        let unsupported = branch(from: "case .unsupported", to: "case .removed",
                                 in: content)
        XCTAssertTrue(unsupported.contains("InstructionSurfaceKeys.unsupported"))
        XCTAssertTrue(unsupported.contains("Text(text)"))
        XCTAssertFalse(unsupported.contains("Button"))
        XCTAssertFalse(unsupported.contains("onPlay"))
        XCTAssertFalse(unsupported.contains("Link"))
        XCTAssertFalse(unsupported.contains("openURL"))
        XCTAssertFalse(unsupported.contains("videoPlay"))
    }

    /// `.removed` is the one plain removed line and nothing else: no dead
    /// control, no invented content.
    func testCardRendersRemovedLine() {
        XCTAssertEqual(InstructionCardView.surface(for: .removed, hasPlayback: true),
                       .removed)
        XCTAssertEqual(InstructionCardView.surface(for: .removed, hasPlayback: false),
                       .removed)

        let card = sourceOfType("InstructionCardView")
        let content = member("private var surfaceContent", of: card)
        guard let removedStart = content.range(of: "case .removed") else {
            XCTFail("the card's removed arm is missing")
            return
        }
        let removed = String(content[removedStart.lowerBound...])
        XCTAssertTrue(removed.contains("InstructionSurfaceKeys.removed"))
        XCTAssertFalse(removed.contains("Button"))
        XCTAssertFalse(removed.contains("onPlay"))
        XCTAssertFalse(removed.contains("Image(systemName"))

        XCTAssertEqual(
            L10n.str(InstructionSurfaceKeys.removed,
                     locale: Locale(identifier: "en")),
            "This instruction is no longer available.")
    }

    // MARK: - Failure copy (T-018 deliverable 1; design §6.2, §10.3)

    /// Every image failure collapses to one plain line: no filename, path,
    /// extension, error code or technical detail.
    func testImageFailureShowsOnePlainLine() {
        guard let image = UIImage(systemName: "star") else {
            XCTFail("no fixture image")
            return
        }
        if case .image(let loaded) = InstructionCardView.imageOutcome(.success(image)) {
            XCTAssertTrue(loaded === image, "the decoded photo is rendered as-is")
        } else {
            XCTFail("a decoded photo renders")
        }
        for failure in [InstructionImageFailure.rejectedFilename,
                        .missingFile,
                        .unreadableFile] {
            if case .unavailable = InstructionCardView.imageOutcome(.failure(failure)) {
                // The one plain line.
            } else {
                XCTFail("\(failure) must collapse to the one plain line")
            }
        }

        let line = L10n.str(InstructionSurfaceKeys.imageUnavailable,
                            locale: Locale(identifier: "en"))
        XCTAssertEqual(line, "This photo can't be shown.")
        XCTAssertFalse(line.contains("/"))
        XCTAssertFalse(line.contains("_"))
        XCTAssertFalse(line.lowercased().contains("error"))
        XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits))
        for token in [".jpg", ".png", ".mov", "NSError", "domain"] {
            XCTAssertFalse(line.contains(token))
        }

        // The card never interpolates the filename into copy, and the
        // no-loader path shows the same one line.
        let card = sourceOfType("InstructionCardView")
        XCTAssertFalse(card.contains("Text(filename"))
        XCTAssertFalse(card.contains("Text(\\(filename)"))
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "InstructionSurfaceKeys.imageUnavailable", in: card),
            2,
            "the failed-load and no-loader paths both use the one line")
    }

    /// Every playback failure renders the same one plain line in the cover;
    /// Close stays available in every phase, including failure.
    func testVideoFailureShowsOnePlainLine() {
        for failure in [InstructionPlaybackFailure.unsupported,
                        .playerFailed,
                        .interrupted,
                        .timedOut] {
            XCTAssertEqual(
                InstructionCoverView.messageKey(for: .failed(failure)),
                InstructionSurfaceKeys.videoUnavailable)
            XCTAssertEqual(
                InstructionCoverView.messageKey(for: .failed(failure)),
                InstructionMessageKey.forPlayback(failure),
                "the cover resolves the same key the failure map names")
        }
        XCTAssertEqual(InstructionCoverView.messageKey(for: .preparing),
                       InstructionSurfaceKeys.videoPreparing)
        XCTAssertEqual(InstructionCoverView.messageKey(for: .preflighting),
                       InstructionSurfaceKeys.videoPreparing)
        XCTAssertNil(InstructionCoverView.messageKey(for: .idle))
        XCTAssertNil(InstructionCoverView.messageKey(for: .ready))
        XCTAssertNil(InstructionCoverView.messageKey(for: .finished))
        XCTAssertNil(InstructionCoverView.messageKey(for: .closed))

        let line = L10n.str(InstructionSurfaceKeys.videoUnavailable,
                            locale: Locale(identifier: "en"))
        XCTAssertEqual(line, "This video can't be played right now.")
        XCTAssertFalse(line.lowercased().contains("error"))
        XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits))

        let cover = sourceOfType("InstructionCoverView")
        XCTAssertTrue(member("var body", of: cover).contains("coverContent"))
        XCTAssertTrue(member("var body", of: cover).contains("closeBar"),
                      "Close is composed outside the phase switch")

        let close = member("private var closeBar", of: cover)
        XCTAssertTrue(close.contains("controller.close()"))
        XCTAssertTrue(close.contains("onClose()"))
        XCTAssertTrue(close.contains("DesignTokens.minTapTargetSize"))

        let content = member("private var coverContent", of: cover)
        guard let failedStart = content.range(of: "case .failed") else {
            XCTFail("the cover's failed branch is missing")
            return
        }
        let failed = String(content[failedStart.lowerBound...])
        XCTAssertTrue(failed.contains("InstructionMessageKey.forPlayback(failure)"))
        XCTAssertFalse(failed.contains("Button"),
                       "the failure branch adds no control")
    }

    // MARK: - No autoplay (T-018 deliverable 2; FR-RIE-018)

    /// The card constructs no player and no controller; the cover starts a
    /// session only after activation, exactly once, and never retries.
    func testNoAutoplaySourcePin() {
        let card = sourceOfType("InstructionCardView")
        XCTAssertFalse(card.contains("InstructionPlaybackController("))
        XCTAssertFalse(card.contains("AVPlayer("))
        XCTAssertFalse(card.contains(".start()"))
        XCTAssertFalse(card.contains(".play()"))
        XCTAssertFalse(card.contains("InstructionCoverView("))
        let content = member("private var surfaceContent", of: card)
        let video = branch(from: "case .video", to: "case .unsupported", in: content)
        XCTAssertTrue(video.contains("Button"))
        XCTAssertTrue(video.contains("onPlay(filename)"),
                      "the tap calls the host's action; the host owns playback")

        let cover = sourceOfType("InstructionCoverView")
        XCTAssertEqual(occurrences(of: "controller.start()", in: cover), 1,
                       "one start, never a retry loop")
        XCTAssertTrue(cover.contains("startsWhenPresented"))
        XCTAssertTrue(cover.contains("if case .ready = state"))
        XCTAssertTrue(cover.contains("controller.player?.play()"),
                      "the only play call is the ready phase of the activation")
        XCTAssertFalse(cover.contains("Timer"))
        XCTAssertFalse(cover.contains("Task.sleep"))
        XCTAssertFalse(cover.contains("retry"))
        XCTAssertFalse(cover.contains("AVPlayer("),
                       "the cover renders the controller's player")
        XCTAssertFalse(cover.contains("InstructionPlaybackController("))

        XCTAssertFalse(sourceOfType("InstructionEditorView").contains(".play()"),
                       "the editor never starts playback")
    }

    // MARK: - Editor (T-018 deliverable 3; design §2.8.4–6, §4.2)

    /// Text entry is a draft mutation, Save follows one resolved commit, and
    /// removal is its own explicit action.
    func testEditorTextDraft() {
        var draft = InstructionDraft.loaded(instruction: nil)
        XCTAssertFalse(InstructionEditorView.canSave(draft),
                       "nothing authored yet, so nothing resolves")
        draft.chooseKind(.text)
        draft.setText("Take the blue pill")
        XCTAssertTrue(InstructionEditorView.canSave(draft))
        XCTAssertEqual(
            draft.resolvedCommit?.write,
            .set(InstructionPayload(kind: .text, text: "Take the blue pill")))
        XCTAssertNil(draft.resolvedCommit?.pendingMedia)

        // Clearing the words is a text write, not a delete.
        var existing = InstructionDraft.loaded(
            instruction: Instruction(kind: "text", text: "Old words"))
        existing.setText("")
        XCTAssertEqual(
            existing.resolvedCommit?.write,
            .set(InstructionPayload(kind: .text, text: "")),
            "empty text never becomes a remove")

        // Remove is explicit and only offered for an existing instruction.
        XCTAssertTrue(InstructionEditorView.removeIsOffered(for: existing))
        existing.removeInstruction()
        XCTAssertEqual(existing.resolvedCommit?.write, .remove)
        XCTAssertFalse(InstructionEditorView.removeIsOffered(
            for: InstructionDraft.loaded(instruction: nil)))

        XCTAssertEqual(InstructionEditorView.kindKey(for: .text),
                       "instruction.kind.text")
        XCTAssertEqual(InstructionEditorView.kindKey(for: .image),
                       "instruction.kind.image")
        XCTAssertEqual(InstructionEditorView.kindKey(for: .video),
                       "instruction.kind.video")

        let editor = sourceOfType("InstructionEditorView")
        XCTAssertTrue(editor.contains("draft.resolvedCommit"))
        XCTAssertTrue(editor.contains("onSave(commit)"))
        XCTAssertTrue(editor.contains("draft.removeInstruction()"))
        XCTAssertTrue(editor.contains("InstructionSurfaceKeys.textPlaceholder"))
        for token in ["InstructionVideoStore(", "InstructionWriteService",
                      "RoutineScheduler", "FreeFormEventService", "AppCoordinator"] {
            XCTAssertFalse(editor.contains(token),
                           "the editor must not reach \(token)")
        }
    }

    /// A fresh media draft has no bytes and no stored filename, so it cannot
    /// save; a picked photo becomes the pending bytes, and a stored image
    /// can save a caption change without copying media.
    func testEditorImageDraftRequiresPendingMedia() {
        guard let image = UIImage(systemName: "star") else {
            XCTFail("no fixture image")
            return
        }
        var draft = InstructionDraft.loaded(instruction: nil)
        draft.chooseKind(.image)
        XCTAssertNil(draft.resolvedCommit,
                     "media without pending bytes or a stored file cannot save")
        XCTAssertFalse(InstructionEditorView.canSave(draft))

        draft = InstructionEditorView.applyingPickedImage(image,
                                                          caption: nil,
                                                          to: draft)
        XCTAssertTrue(InstructionEditorView.canSave(draft))
        if case .image(let pending) = draft.pendingMedia {
            XCTAssertTrue(pending === image,
                          "the picked photo's exact bytes become pending media")
        } else {
            XCTFail("the picked photo becomes pending bytes")
        }
        XCTAssertEqual(
            draft.resolvedCommit?.write,
            .set(InstructionPayload(kind: .image, caption: nil)))
        XCTAssertNotNil(draft.resolvedCommit?.pendingMedia)

        // A cancelled pick changes nothing.
        XCTAssertEqual(
            InstructionEditorView.applyingPickedImage(nil, caption: "x", to: draft),
            draft)

        // The caption survives the pick and is trimmed in the authored value.
        let captioned = InstructionEditorView.applyingPickedImage(
            image, caption: "  Blue box  ", to: draft)
        XCTAssertEqual(captioned.payload?.caption, "  Blue box  ")
        if case .set(let payload) = captioned.resolvedCommit?.write {
            XCTAssertEqual(payload.instruction.caption, "Blue box",
                           "the commit trims the caption")
        } else {
            XCTFail("a picked image commits as a media set")
        }

        // A stored image needs no pending bytes for a caption edit.
        var stored = InstructionDraft.loaded(
            instruction: Instruction(kind: "image",
                                     caption: "Old",
                                     filename: "instruction-1.jpg"))
        stored.setCaption("New")
        XCTAssertNotNil(stored.resolvedCommit,
                        "a stored filename resolves the media write")
        XCTAssertNil(stored.resolvedCommit?.pendingMedia)

        XCTAssertEqual(InstructionEditorView.imageButtonKey(hasImage: false),
                       "visualAid.add")
        XCTAssertEqual(InstructionEditorView.imageButtonKey(hasImage: true),
                       "instruction.image.change")

        let editor = sourceOfType("InstructionEditorView")
        XCTAssertTrue(editor.contains("pickImage"),
                      "the photo comes from the host's existing flow")
        XCTAssertTrue(editor.contains("InstructionSurfaceKeys.captionPlaceholder"))
    }

    /// Video entry goes through the capture coordinator; an accepted video is
    /// consumed exactly once into the draft, and every stop maps to one plain
    /// line through `InstructionMessageKey`.
    func testEditorVideoDraftUsesCaptureCoordinator() {
        let accepted = makeAcceptedVideo()
        var draft = InstructionDraft.loaded(instruction: nil)
        draft.chooseKind(.video)
        XCTAssertNil(draft.resolvedCommit,
                     "media without pending bytes or a stored file cannot save")

        let applied = InstructionEditorView.applyingAcceptedVideo(accepted,
                                                                  to: draft)
        XCTAssertEqual(applied.pendingMedia, .video(accepted))
        XCTAssertEqual(applied.resolvedCommit?.pendingMedia, .video(accepted))
        XCTAssertEqual(
            applied.resolvedCommit?.write,
            .set(InstructionPayload(kind: .video, caption: nil)))

        // A caption that belonged to the video draft survives the handoff.
        var captioned = InstructionDraft.loaded(instruction: nil)
        captioned.chooseKind(.video)
        captioned.setCaption("Lunch routine")
        let withCaption = InstructionEditorView.applyingAcceptedVideo(accepted,
                                                                      to: captioned)
        XCTAssertEqual(withCaption.payload?.caption, "Lunch routine")
        XCTAssertEqual(
            withCaption.resolvedCommit?.write,
            .set(InstructionPayload(kind: .video, caption: "Lunch routine")))

        // The capture machine's one plain line per state.
        XCTAssertNil(InstructionEditorView.feedbackKey(for: .idle))
        XCTAssertNil(InstructionEditorView.feedbackKey(for: .picking))
        XCTAssertNil(InstructionEditorView.feedbackKey(for: .recording))
        XCTAssertNil(InstructionEditorView.feedbackKey(for: .ready(accepted)))
        XCTAssertEqual(InstructionEditorView.feedbackKey(for: .validating),
                       "instruction.video.validating")
        XCTAssertEqual(
            InstructionEditorView.feedbackKey(for: .failed(.permission(.cameraDenied))),
            "instruction.camera.denied")
        XCTAssertEqual(
            InstructionEditorView.feedbackKey(for: .failed(.permission(.microphoneDenied))),
            "instruction.microphone.denied")
        XCTAssertEqual(
            InstructionEditorView.feedbackKey(for: .failed(.permission(.cameraUnavailable))),
            "instruction.camera.unavailable")
        XCTAssertEqual(
            InstructionEditorView.feedbackKey(for: .failed(.importError(.tooLong))),
            "instruction.video.tooLong")
        XCTAssertEqual(
            InstructionEditorView.feedbackKey(for: .failed(.importError(.tooLarge))),
            "instruction.video.tooLarge")
        XCTAssertEqual(
            InstructionEditorView.feedbackKey(for: .failed(.importError(.unreadableSource))),
            "instruction.video.unreadable")
        XCTAssertNil(
            InstructionEditorView.feedbackKey(for: .failed(.importError(.cancelled))),
            "a cancelled pick has no copy")

        // The editor uses the coordinator's seam and nothing else.
        let editor = sourceOfType("InstructionEditorView")
        XCTAssertTrue(editor.contains("@ObservedObject private var capture"))
        XCTAssertTrue(editor.contains("capture.pick()"))
        XCTAssertTrue(editor.contains("capture.record()"))
        XCTAssertTrue(editor.contains("capture.cancel()"))
        XCTAssertEqual(occurrences(of: "capture.consumeAccepted()", in: editor), 1,
                       "an accepted video is consumed exactly once")
        XCTAssertTrue(editor.contains("InstructionSurfaceKeys.foregroundNote"),
                      "the foreground-only limitation is stated where video is chosen")
        XCTAssertFalse(editor.contains("VideoPlayer("))
        XCTAssertFalse(editor.contains("AVPlayer"))
        XCTAssertFalse(editor.contains("InstructionVideoStore("))

        XCTAssertEqual(InstructionEditorView.videoButtonKey(hasVideo: false),
                       "instruction.video.add")
        XCTAssertEqual(InstructionEditorView.videoButtonKey(hasVideo: true),
                       "instruction.video.change")
    }

    // MARK: - Honest capability (T-018 deliverable 4; §11.3 Q)

    /// No photo-library import, permission request, link/YouTube playback,
    /// share sheet, transcode or Settings deep link exists in the surface
    /// file; the photo path is the host's injected closure.
    func testNoPhotoLibrarySourcePin() {
        let code = source()
        let forbidden = ["PhotosUI", "PHPicker", "PHPhotoLibrary",
                         "UIImagePickerController", "AVCaptureDevice",
                         "AVAssetExportSession", "requestAccess",
                         "requestRecordPermission", "openSettingsURLString",
                         "UIApplication", "UIActivityViewController",
                         "UIDocumentPicker", "NSPhotoLibraryUsageDescription",
                         "NSCameraUsageDescription",
                         "NSMicrophoneUsageDescription", "Link(", "openURL"]
        for token in forbidden {
            XCTAssertFalse(code.contains(token),
                           "InstructionViews.swift must not contain \(token)")
        }
        let lowercased = code.lowercased()
        for token in ["youtube", "http://", "https://", "openurl", "upload",
                      "transcode", "share"] {
            XCTAssertFalse(lowercased.contains(token),
                           "InstructionViews.swift must not contain \(token)")
        }

        let editor = sourceOfType("InstructionEditorView")
        XCTAssertTrue(editor.contains("capture.pick()"),
                      "video comes from the capture coordinator")
        XCTAssertTrue(editor.contains("capture.record()"))
        XCTAssertTrue(editor.contains("pickImage"),
                      "the photo comes from the host's existing flow")
    }

    // MARK: - Localisation (T-018 deliverable 5; NFR-RIE-002)

    /// Every literal compiled into the view file is either an SF Symbol name
    /// or a catalogue key that resolves in both shipped languages.
    func testNoHardCodedElderFacingStrings() {
        let code = source()
        let literals = stringLiterals(in: code)
        XCTAssertFalse(literals.isEmpty)

        let keys = Set(literals.filter {
            !$0.isEmpty && !Self.allowedSymbols.contains($0)
        })
        XCTAssertFalse(keys.isEmpty, "the views render no catalogue keys?")
        let catalog = catalogEntries()
        for key in keys.sorted() {
            XCTAssertTrue(Self.allowedKeyPrefixes.contains(where: { key.hasPrefix($0) }),
                          "\(key) is an inline literal, not a catalogue key")
            let en = catalogValue(key, "en", in: catalog)
            let ne = catalogValue(key, "ne", in: catalog)
            XCTAssertNotNil(en, "\(key) is missing from the shipping catalogue")
            XCTAssertNotNil(ne, "\(key) has no Nepali value")
            XCTAssertNotEqual(en, ne, "\(key) is untranslated")
            XCTAssertTrue(isDevanagari(ne ?? ""),
                          "\(key) has an English-looking Nepali value")
        }

        // No sentence is compiled into a view; all copy is 2–3 word keys.
        for literal in literals where !literal.isEmpty {
            XCTAssertFalse(literal.contains(" "),
                           "\(literal) looks like inline elder-facing copy")
        }
        XCTAssertFalse(code.contains("Text(\""),
                       "no inline Text copy")
        XCTAssertFalse(code.contains(".accessibilityLabel(Text(\""),
                       "no inline accessibility copy")
        XCTAssertGreaterThanOrEqual(occurrences(of: "L10n.str(", in: code), 20)
    }

    /// Design §10.3 labels: the photo and the play control each carry their
    /// own label; captions are separate text, never merged into the label.
    func testAccessibilityLabelsMatchDesign() {
        let english = Locale(identifier: "en")
        let nepali = Locale(identifier: "ne")

        XCTAssertEqual(InstructionSurfaceKeys.imageAccessibility,
                       "instruction.image.accessibility")
        XCTAssertEqual(L10n.str(InstructionSurfaceKeys.imageAccessibility,
                                locale: english),
                       "Instruction photo")
        XCTAssertTrue(isDevanagari(L10n.str(InstructionSurfaceKeys.imageAccessibility,
                                            locale: nepali)))

        XCTAssertEqual(InstructionSurfaceKeys.videoAccessibility,
                       "instruction.video.accessibility")
        XCTAssertEqual(L10n.str(InstructionSurfaceKeys.videoAccessibility,
                                locale: english),
                       "Instruction video. Play")
        XCTAssertTrue(isDevanagari(L10n.str(InstructionSurfaceKeys.videoAccessibility,
                                            locale: nepali)))

        let card = sourceOfType("InstructionCardView")
        let content = member("private var surfaceContent", of: card)
        let video = branch(from: "case .video", to: "case .unsupported", in: content)
        XCTAssertTrue(video.contains("Button"))
        XCTAssertTrue(video.contains(".accessibilityLabel"))
        XCTAssertTrue(video.contains("InstructionSurfaceKeys.videoAccessibility"))
        XCTAssertTrue(video.contains("InstructionSurfaceKeys.videoPlay"),
                      "the control also carries a visible label, not colour alone")

        let imageContent = member("private func imageContent", of: card)
        XCTAssertTrue(imageContent.contains(".accessibilityLabel"))
        XCTAssertTrue(imageContent.contains("InstructionSurfaceKeys.imageAccessibility"))

        // A caption is its own text and is not part of the media label.
        let caption = member("private func captionText", of: card)
        XCTAssertTrue(caption.contains("Text(caption)"))
        XCTAssertFalse(caption.contains("accessibilityLabel"))
    }

    /// Design §10.2: no fixed text heights (nothing clips at large Dynamic
    /// Type), no truncation of instruction text, and every font uses the
    /// scaled typography token.
    func testDynamicTypeDoesNotUseFixedHeights() {
        let code = source()
        for line in code.split(separator: "\n") {
            let text = String(line)
            guard text.contains(".frame("), text.contains("height:") else { continue }
            let stripped = text
                .replacingOccurrences(of: "minHeight:", with: "")
                .replacingOccurrences(of: "maxHeight:", with: "")
            XCTAssertFalse(stripped.contains("height:"),
                           "fixed height clips at large Dynamic Type: \(text)")
        }
        XCTAssertFalse(code.contains("lineLimit("),
                       "instruction text and captions are never truncated")
        for line in code.split(separator: "\n") where line.contains(".font(") {
            XCTAssertTrue(line.contains("appearance.typography."),
                          "font must use the scaled typography token: \(line)")
        }
        XCTAssertTrue(sourceOfType("InstructionEditorView").contains("ScrollView"),
                      "the editor scrolls instead of clipping")

        // The 44 pt floor is a minimum, never a fixed row height.
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44)
    }

    // MARK: - Fired screen (T-021; design §2.15.4, §4.10–§4.11, §10.3)
    //
    // SwiftUI cannot be rendered in-process, so the fired screen is pinned
    // at its value seams — `timeText`, `cardState` and `footerIsEmpty`, the
    // exact helpers the body calls — plus source pins on the branches that
    // cannot be constructed here. The sixteen T-018 names above keep their
    // behaviour untouched.

    /// `.reminder` is a typed value carrying the instruction, the
    /// notification's expectation flag and the fire date (design §4.11).
    func testReminderContentCarriesInstructionAndExpectsFlag() {
        let entryId = UUID()
        let aid = VisualAid(filename: "aid.jpg")
        let instruction = Instruction(kind: "text", text: "Take the blue pill")
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let content = reminderContent(title: "Morning walk",
                                      aids: [aid],
                                      instruction: instruction,
                                      expectsInstruction: true,
                                      firedAt: firedAt)

        guard case .reminder(let title, let aids, let carried,
                             let expects, let date) = content else {
            XCTFail("the reminder case must carry all five values")
            return
        }
        XCTAssertEqual(title, "Morning walk")
        XCTAssertEqual(aids, [aid])
        XCTAssertEqual(carried, instruction)
        XCTAssertTrue(expects)
        XCTAssertEqual(date, firedAt)

        let fired = FiredRoutineVisualAids(entryId: entryId, content: content)
        XCTAssertEqual(fired.id, entryId, "the entry id is the presentation identity")
        XCTAssertEqual(fired.content, content)
        XCTAssertEqual(fired, FiredRoutineVisualAids(entryId: entryId, content: content))
        XCTAssertNotEqual(fired, FiredRoutineVisualAids(entryId: UUID(), content: content),
                          "two presentations of different entries are not equal")

        // The declaration is the design's §4.11 delta, not a bag of fields.
        let overlayRegion = firedScreenRegion()
        XCTAssertTrue(overlayRegion.contains("case reminder(title: String"))
        XCTAssertTrue(overlayRegion.contains("aids: [VisualAid]"))
        XCTAssertTrue(overlayRegion.contains("instruction: Instruction?"))
        XCTAssertTrue(overlayRegion.contains("expectsInstruction: Bool"))
        XCTAssertTrue(overlayRegion.contains("firedAt: Date"))
    }

    /// D6, present case: the card state is the instruction's own kind and
    /// the formatted fire time reaches the card.
    func testPresentInstructionRendersCardTime() {
        let content = reminderContent(
            instruction: Instruction(kind: "text", text: "Take the blue pill"),
            expectsInstruction: true)

        XCTAssertEqual(RoutineVisualAidOverlay.cardState(for: content),
                       .text(text: "Take the blue pill"))
        let expected = LocaleFormatters.shortTime(locale: Locale(identifier: "en"))
            .string(from: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(RoutineVisualAidOverlay.timeText(
            for: content, locale: Locale(identifier: "en")), expected)
        XCTAssertFalse(RoutineVisualAidOverlay.footerIsEmpty(for: content),
                       "a present instruction renders the footer card")

        let overlayRegion = firedScreenRegion()
        XCTAssertTrue(overlayRegion.contains("InstructionCardView("))
        XCTAssertTrue(overlayRegion.contains(
            "state: RoutineVisualAidOverlay.cardState(for: fired.content)"))
        XCTAssertTrue(overlayRegion.contains(
            "timeText: RoutineVisualAidOverlay.timeText(for: fired.content"))
        XCTAssertEqual(occurrences(of: "instruction?.isPresent == true",
                                   in: overlayRegion), 1,
                       "the D6 gate is stated exactly once (N-5)")
    }

    /// D6, removed case: the notification said an instruction existed, so
    /// the removed line renders AND the fire time stays.
    func testRemovedInstructionKeepsTitleAndTime() {
        let content = reminderContent(instruction: nil, expectsInstruction: true)

        XCTAssertEqual(RoutineVisualAidOverlay.cardState(for: content), .removed,
                       "the notification said an instruction existed")
        let expected = LocaleFormatters.shortTime(locale: Locale(identifier: "en"))
            .string(from: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(RoutineVisualAidOverlay.timeText(
            for: content, locale: Locale(identifier: "en")), expected,
                       "a removed instruction keeps the fire time")
        XCTAssertFalse(RoutineVisualAidOverlay.footerIsEmpty(for: content),
                       "the removed line is a real card, not an empty container")
        XCTAssertEqual(InstructionCardView.surface(
            for: RoutineVisualAidOverlay.cardState(for: content), hasPlayback: false),
            .removed)

        // The title still comes from the content; the card never invents one.
        let overlayRegion = firedScreenRegion()
        XCTAssertTrue(overlayRegion.contains("title: title"))
        XCTAssertTrue(overlayRegion.contains("InstructionCardView("))
    }

    /// D6, photo-only case: no instruction and none expected ⇒ no time line
    /// and an empty footer. Today's screen, byte-for-byte.
    func testPhotoOnlyFiringPassesNilTimeAndEmptyFooter() {
        let content = reminderContent(instruction: nil, expectsInstruction: false)

        XCTAssertNil(RoutineVisualAidOverlay.timeText(
            for: content, locale: Locale(identifier: "en")),
                     "no instruction and none expected means no time line")
        XCTAssertEqual(RoutineVisualAidOverlay.cardState(for: content), .none)
        XCTAssertTrue(RoutineVisualAidOverlay.footerIsEmpty(for: content))
        XCTAssertEqual(InstructionCardView.surface(
            for: RoutineVisualAidOverlay.cardState(for: content), hasPlayback: true),
            .nothing)

        let footer = member("private func instructionFooter", of: firedScreenRegion())
        XCTAssertTrue(footer.contains(
            "RoutineVisualAidOverlay.footerIsEmpty(for: fired.content)"))
        XCTAssertTrue(footer.contains("EmptyView()"))
    }

    /// `.none` is `EmptyView`, never an empty container with padding: the
    /// footer's empty arm composes nothing at all (P-9, NFR-RIE-010).
    func testNoneStateRendersEmptyViewNotAContainer() {
        let photoOnly = reminderContent(instruction: nil, expectsInstruction: false)
        XCTAssertEqual(RoutineVisualAidOverlay.cardState(for: photoOnly), .none)
        XCTAssertTrue(RoutineVisualAidOverlay.footerIsEmpty(for: photoOnly))

        let footer = member("private func instructionFooter", of: firedScreenRegion())
        guard let gateStart = footer.range(of: "if RoutineVisualAidOverlay.footerIsEmpty"),
              let elseMarker = footer.range(of: "} else {",
                                            range: gateStart.upperBound..<footer.endIndex) else {
            XCTFail("the footer's emptiness gate is missing")
            return
        }
        let emptyArm = String(footer[gateStart.upperBound..<elseMarker.lowerBound])
        XCTAssertTrue(emptyArm.contains("EmptyView()"))
        XCTAssertFalse(emptyArm.contains("InstructionCardView"))
        XCTAssertFalse(emptyArm.contains("VStack"))
        XCTAssertFalse(emptyArm.contains(".padding"))
        XCTAssertFalse(emptyArm.contains("appSurface"))
    }

    /// The deleted owner becomes the shared screen with the notice title, no
    /// aids, no footer card and the same Close path (FR-RIE-019).
    func testUnavailableRendersNoticeWithClose() {
        let unavailable = FiredRoutineVisualAids.Content.unavailable
        XCTAssertEqual(RoutineVisualAidOverlay.cardState(for: unavailable), .none)
        XCTAssertNil(RoutineVisualAidOverlay.timeText(
            for: unavailable, locale: Locale(identifier: "en")))
        XCTAssertTrue(RoutineVisualAidOverlay.footerIsEmpty(for: unavailable))

        let overlayRegion = firedScreenRegion()
        let afterSwitch = branch(from: "switch fired.content",
                                 to: "private func instructionFooter",
                                 in: overlayRegion)
        guard let unavailableStart = afterSwitch.range(of: "case .unavailable") else {
            XCTFail("the fired screen has no unavailable arm")
            return
        }
        let unavailableArm = String(afterSwitch[unavailableStart.lowerBound...])
        XCTAssertTrue(unavailableArm.contains("ReminderVisualAidScreen("))
        XCTAssertTrue(unavailableArm.contains(
            "RoutineVisualAidOverlay.reminderUnavailableKey"))
        XCTAssertTrue(unavailableArm.contains("aids: []"))
        XCTAssertTrue(unavailableArm.contains("onClose: onClose"),
                      "the shared screen's Close is the notice's exit")
        XCTAssertFalse(unavailableArm.contains("footer:"),
                       "the notice uses the EmptyView convenience initializer")
        XCTAssertFalse(unavailableArm.contains("InstructionCardView"))
        XCTAssertFalse(unavailableArm.contains("timeText"))
        XCTAssertFalse(unavailableArm.contains("firedAt"))

        // Close is the shared screen's own button and calls the host's path.
        let screen = typeSource("ReminderVisualAidScreen", in: visualAidViewsSource())
        XCTAssertTrue(screen.contains("Button(action: onClose)"))
    }

    /// `.unavailable` carries no title and no date at all — not empty ones,
    /// absent ones — so the notice can never claim either (design §4.11).
    func testUnavailableCarriesNoTitleOrTime() {
        // Value shape: the case has no associated values.
        let mirrored = Mirror(reflecting: FiredRoutineVisualAids.Content.unavailable)
        XCTAssertEqual(mirrored.children.count, 0,
                       "the unavailable notice carries no title, aid or date")
        XCTAssertEqual(FiredRoutineVisualAids.Content.unavailable, .unavailable)

        // Source shape: the declaration is a bare case.
        let overlayRegion = firedScreenRegion()
        guard let caseRange = overlayRegion.range(of: "case unavailable") else {
            XCTFail("Content has no unavailable case")
            return
        }
        let lineEnd = overlayRegion[caseRange.lowerBound...].firstIndex(of: "\n")
            ?? overlayRegion.endIndex
        let declaration = String(overlayRegion[caseRange.lowerBound..<lineEnd])
        XCTAssertEqual(declaration, "case unavailable")
        XCTAssertFalse(overlayRegion.contains("case unavailable(title"))
        XCTAssertFalse(overlayRegion.contains("case unavailable(instruction"))
        XCTAssertFalse(overlayRegion.contains("case unavailable(firedAt"))

        XCTAssertNil(RoutineVisualAidOverlay.timeText(
            for: .unavailable, locale: Locale(identifier: "en")),
                     "there is no firedAt to format")
    }

    /// The notice's copy is resolved by the view from the shipping catalogue
    /// in both languages (design §4.11, §10.5 row 35).
    func testOverlayResolvesReminderUnavailableKeyInBothLanguages() {
        XCTAssertEqual(RoutineVisualAidOverlay.reminderUnavailableKey,
                       "instruction.reminderUnavailable")

        let catalog = catalogEntries()
        let en = catalogValue(RoutineVisualAidOverlay.reminderUnavailableKey,
                              "en", in: catalog)
        let ne = catalogValue(RoutineVisualAidOverlay.reminderUnavailableKey,
                              "ne", in: catalog)
        XCTAssertEqual(en, "This reminder is no longer available.")
        XCTAssertNotNil(ne)
        XCTAssertNotEqual(en, ne)
        XCTAssertTrue(isDevanagari(ne ?? ""), "the notice has a Nepali value")

        XCTAssertTrue(firedScreenRegion().contains(
            "L10n.str(RoutineVisualAidOverlay.reminderUnavailableKey"),
                      "the overlay resolves the key itself")
    }

    /// The fire time comes from the shared cached short-time formatter, not
    /// an inline date format (design §4.10; Gherkin time-format scenario).
    func testOverlayUsesSharedShortTimeFormatter() {
        let content = reminderContent(
            instruction: Instruction(kind: "text", text: "Wear shoes"),
            expectsInstruction: true)
        let locale = Locale(identifier: "en")
        let expected = LocaleFormatters.shortTime(locale: locale)
            .string(from: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(RoutineVisualAidOverlay.timeText(for: content, locale: locale),
                       expected)

        let overlayRegion = firedScreenRegion()
        XCTAssertTrue(overlayRegion.contains(
            "LocaleFormatters.shortTime(locale: locale).string(from: firedAt)"))
        for inline in ["DateFormatter(", "dateFormat", "timeStyle", "dateStyle",
                       "setLocalizedDateFormatFromTemplate"] {
            XCTAssertFalse(overlayRegion.contains(inline),
                           "the overlay builds no date format inline: \(inline)")
        }
    }

    /// The overlay is a view: it reaches no store, scheduler, file manager or
    /// coordinator method. Only the injected closures name those seams.
    func testOverlayHasNoStoreAccess() {
        // ONLY the overlay + the presentation value. The shared screen
        // before it legitimately reads the photo store, and ContentView is
        // the composition seam that legitimately names the coordinator.
        let overlayRegion = firedScreenRegion()
        let forbidden = ["scheduler", "Scheduler", "coordinator", "Coordinator",
                         "FileManager", "fileManager", "NSFileManager",
                         "store.", ".load(", ".save(", ".delete(", ".availability(",
                         "instructionVideoStore", "visualAidStore",
                         "medicationVisualAidStore", "entriesIfReadable",
                         "loadEntries"]
        for token in forbidden {
            XCTAssertFalse(overlayRegion.contains(token),
                           "RoutineVisualAidOverlay must not reach \(token) directly")
        }
        XCTAssertTrue(overlayRegion.contains("playbackURL(fired.entryId, filename)"),
                      "the only playability source is the injected closure")
        XCTAssertTrue(overlayRegion.contains("makePlayback(url, nil)"),
                      "the only playback factory is the injected closure")

        // Playback is wired, not dead code: availability is resolved off the
        // draw path and a playable video's tap presents the shared cover.
        XCTAssertTrue(overlayRegion.contains(".task(id: fired)"))
        XCTAssertTrue(overlayRegion.contains("resolvePlayableVideos(for: fired)"))
        XCTAssertTrue(overlayRegion.contains("playableVideos.contains(filename)"),
                      "onPlay exists only for a resolved-playable video")
        XCTAssertTrue(overlayRegion.contains("InstructionCoverView("))
        XCTAssertTrue(overlayRegion.contains("startsWhenPresented: true"))
        XCTAssertEqual(occurrences(of: "controller.close()", in: overlayRegion), 2,
                       "Close and the cover's dismissal both close the session")

        // The composition seam asks the coordinator for playability; the
        // view never names the store (design §2.15.2).
        let contentView = contentViewSource()
        XCTAssertTrue(contentView.contains("RoutineVisualAidOverlay("))
        XCTAssertTrue(contentView.contains(
            "coordinator.instructionPlaybackAvailability("))
        XCTAssertTrue(contentView.contains("owner: .routine(entryId)"))
        XCTAssertFalse(contentView.contains("instructionVideoStore"))
        XCTAssertTrue(contentView.contains(
            "coordinator.makeInstructionPlayback(url: url, title: title)"))
    }

    /// N-5 / NFR-RIE-010: a photo-only foreground firing renders exactly
    /// today's screen. The card is `.none`, the footer empty and the fire
    /// time nil — no time line, no container, no dead control.
    func testFiredScreenBaselinePhotoBehaviourUnchanged() {
        let aid = VisualAid(filename: "aid.jpg")
        let photoOnly = reminderContent(aids: [aid],
                                        instruction: nil,
                                        expectsInstruction: false)
        XCTAssertNil(RoutineVisualAidOverlay.timeText(
            for: photoOnly, locale: Locale(identifier: "en")))
        XCTAssertEqual(RoutineVisualAidOverlay.cardState(for: photoOnly), .none)
        XCTAssertTrue(RoutineVisualAidOverlay.footerIsEmpty(for: photoOnly))
        XCTAssertEqual(InstructionCardView.surface(
            for: RoutineVisualAidOverlay.cardState(for: photoOnly), hasPlayback: true),
            .nothing)

        let overlayRegion = firedScreenRegion()
        XCTAssertTrue(overlayRegion.contains("ReminderVisualAidScreen("))
        XCTAssertTrue(overlayRegion.contains("title: title"))
        XCTAssertTrue(overlayRegion.contains("aids: aids"))
        XCTAssertTrue(overlayRegion.contains("store: store"))
        XCTAssertTrue(overlayRegion.contains("locale: locale"))
        XCTAssertTrue(overlayRegion.contains("onClose: onClose"))

        // The shared photo screen and the picker other wave-7 units compile
        // against are untouched.
        let views = visualAidViewsSource()
        let screen = typeSource("ReminderVisualAidScreen", in: views)
        XCTAssertTrue(screen.contains("let title: String"))
        XCTAssertTrue(screen.contains("let aids: [VisualAid]"))
        XCTAssertTrue(screen.contains("let store: VisualAidStore"))
        XCTAssertTrue(screen.contains("@ViewBuilder let footer: Footer"))
        XCTAssertTrue(screen.contains("init(entryId: UUID, title: String, aids: [VisualAid]"))
        XCTAssertTrue(screen.contains("imagePager"))
        XCTAssertTrue(screen.contains("Text(title)"))
        XCTAssertTrue(views.contains(
            "extension ReminderVisualAidScreen where Footer == EmptyView"))

        let picker = typeSource("VisualAidPhotoPicker", in: views)
        XCTAssertTrue(picker.contains("let selectionLimit: Int"))
        XCTAssertTrue(picker.contains("let onPicked: ([UIImage]) -> Void"))

        // The overlay is still mounted in the same place with the same shape.
        let contentView = contentViewSource()
        XCTAssertTrue(contentView.contains(
            "presentation: coordinator.firedRoutineVisualAids"))
        XCTAssertTrue(contentView.contains("store: coordinator.visualAidStore"))
        XCTAssertTrue(contentView.contains("locale: coordinator.activeLocale"))
        XCTAssertTrue(contentView.contains(
            "onClose: coordinator.dismissFiredRoutineVisualAids"))
    }

    // MARK: - Source helpers

    private static let allowedSymbols: Set<String> = [
        "play.fill", "checkmark", "record.circle", "trash"
    ]

    private static let allowedKeyPrefixes = ["instruction.", "visualAid.", "common."]

    private func source(file: StaticString = #filePath) -> String {
        FeatureSourceScan.codeText(of: viewsURL(file: file))
    }

    private func viewsURL(file: StaticString = #filePath) -> URL {
        FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/InstructionViews.swift")
    }

    /// One top-level type, from its column-0 declaration to the next one.
    private func sourceOfType(_ name: String, file: StaticString = #filePath) -> String {
        let lines = source(file: file)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("struct \(name)") || $0.hasPrefix("enum \(name)")
        }) else {
            XCTFail("no type named \(name) in InstructionViews.swift")
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

    /// String literals in code text (comments already stripped, literals
    /// preserved by `FeatureSourceScan.codeText`).
    private func stringLiterals(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"") else {
            XCTFail("bad literal pattern")
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let literalRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[literalRange])
        }
    }

    // MARK: - T-021 source helpers

    /// `VisualAidViews.swift` with comments stripped (T-021's file).
    private func visualAidViewsSource(file: StaticString = #filePath) -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/VisualAidViews.swift"))
    }

    /// `ContentView.swift` with comments stripped — the composition seam.
    private func contentViewSource(file: StaticString = #filePath) -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/App/ContentView.swift"))
    }

    /// ONLY `FiredRoutineVisualAids` + `RoutineVisualAidOverlay`, up to the
    /// photo editor. The shared screen before it legitimately reads the photo
    /// store and the editor after it legitimately writes through it.
    private func firedScreenRegion(file: StaticString = #filePath) -> String {
        region(in: visualAidViewsSource(file: file),
               from: "struct FiredRoutineVisualAids",
               to: "struct ReminderVisualAidEditorView")
    }

    /// The text between two code markers, failing loudly when either is
    /// missing (the house region idiom).
    private func region(in text: String, from start: String, to end: String) -> String {
        guard let startRange = text.range(of: start) else {
            XCTFail("no `\(start)` in the source")
            return ""
        }
        guard let endRange = text.range(of: end,
                                        range: startRange.upperBound..<text.endIndex) else {
            XCTFail("no `\(end)` after `\(start)`")
            return ""
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// One top-level type in arbitrary comment-stripped source (the same
    /// column-0 rule the InstructionViews helper applies).
    private func typeSource(_ name: String, in text: String) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("struct \(name)") || $0.hasPrefix("enum \(name)")
        }) else {
            XCTFail("no type named \(name) in the source")
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

    // MARK: - Catalogue helpers

    private func catalogEntries(file: StaticString = #filePath) -> [String: Any] {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            XCTFail("could not read the shipping String Catalog at \(url.path)")
            return [:]
        }
        return strings
    }

    private func catalogValue(_ key: String, _ language: String,
                              in catalog: [String: Any]) -> String? {
        guard let entry = catalog[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[language] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any] else {
            return nil
        }
        return unit["value"] as? String
    }

    /// Devanagari (U+0900–U+097F), by scalar — the same grapheme-safe check
    /// the shipped copy suites use.
    private func isDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    // MARK: - Fixtures

    /// One `.reminder` presentation value for the D6 matrix. The fire date
    /// is fixed so the formatted time can be compared against the shared
    /// formatter without a clock read.
    private func reminderContent(
        title: String = "Morning walk",
        aids: [VisualAid] = [],
        instruction: Instruction? = nil,
        expectsInstruction: Bool = false,
        firedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FiredRoutineVisualAids.Content {
        .reminder(title: title,
                  aids: aids,
                  instruction: instruction,
                  expectsInstruction: expectsInstruction,
                  firedAt: firedAt)
    }

    private func makeAcceptedVideo() -> AcceptedInstructionVideo {
        AcceptedInstructionVideo(
            staged: StagedInstructionVideo(
                draftId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                root: .routines,
                stagedURL: URL(fileURLWithPath: "/tmp/instruction-staging/payload.mov"),
                byteCount: 4_096,
                metadata: InstructionVideoMetadata(durationSeconds: 1.5,
                                                   hasVideoTrack: true,
                                                   isPlayable: true),
                sourceExtension: "mov",
                stagedAt: Date(timeIntervalSince1970: 1_000)),
            validatedAt: Date(timeIntervalSince1970: 1_010))
    }
}
