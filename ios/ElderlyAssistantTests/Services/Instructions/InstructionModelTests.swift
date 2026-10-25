import XCTest
import UIKit
@testable import ElderlyAssistant

/// The value-layer contract for instructions (T-001; design L2 §3.3–§3.5,
/// §4.1–§4.4, §9.1).
///
/// Every case is either a pure value assertion or one of the two metadata
/// paths. No test writes outside its own temporary directory: the file
/// cases plant their source bytes in a per-test folder and let the prober /
/// inspector read them.
final class InstructionModelTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> Instruction {
        try JSONDecoder().decode(Instruction.self, from: Data(json.utf8))
    }

    private func encodedObject(_ instruction: Instruction) throws -> [String: Any] {
        let data = try JSONEncoder().encode(instruction)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A valid, audio-only PCM WAV — a real media file with no video
    /// track. Deterministic bytes: 0.1 s of silence at 8 kHz mono/16-bit.
    private func writeSilentWAV(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let sampleCount = UInt32(Double(sampleRate) * 0.1)
        let dataBytes = sampleCount * 2

        var data = Data()

        func appendASCII(_ value: String) {
            data.append(contentsOf: Array(value.utf8))
        }
        func appendUInt32LE(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }
        func appendUInt16LE(_ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }

        appendASCII("RIFF")
        appendUInt32LE(36 + dataBytes)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32LE(16)              // fmt chunk size
        appendUInt16LE(1)               // linear PCM
        appendUInt16LE(1)               // mono
        appendUInt32LE(sampleRate)
        appendUInt32LE(sampleRate * 2)  // byte rate
        appendUInt16LE(2)               // block align
        appendUInt16LE(16)              // bits per sample
        appendASCII("data")
        appendUInt32LE(dataBytes)
        data.append(Data(repeating: 0, count: Int(dataBytes)))

        try data.write(to: url)
    }

    /// A deterministic accepted-video value. No bytes are read: P-7 says the
    /// staged metadata and timestamps are the equality contract.
    private func makeAcceptedVideo(
        validatedAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> AcceptedInstructionVideo {
        let staged = StagedInstructionVideo(
            draftId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            root: .routines,
            stagedURL: URL(fileURLWithPath: "/tmp/instruction-staging/payload.mov"),
            byteCount: 4_096,
            metadata: InstructionVideoMetadata(durationSeconds: 1.5,
                                               hasVideoTrack: true,
                                               isPlayable: true),
            sourceExtension: "mov",
            stagedAt: Date(timeIntervalSince1970: 1_000)
        )
        return AcceptedInstructionVideo(staged: staged, validatedAt: validatedAt)
    }

    // MARK: - Wire model

    func testRawKindTextImageVideoRoundTrip() throws {
        let originals: [Instruction] = [
            Instruction(kind: "text", text: "Take the blue pill"),
            Instruction(kind: "image",
                        caption: "Blue box",
                        filename: "instruction-11111111-1111-1111-1111-111111111111.jpg"),
            Instruction(kind: "video",
                        caption: "Lunch routine",
                        filename: "instruction-22222222-2222-2222-2222-222222222222.mov"),
        ]

        for original in originals {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Instruction.self, from: data)

            XCTAssertEqual(decoded.kind, original.kind,
                           "the raw kind must survive verbatim, never an enum spelling")
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(decoded.knownKind, InstructionKind(rawValue: original.kind))
            XCTAssertTrue(decoded.isPresent)
        }

        // A text instruction invents no media fields on the wire.
        let textObject = try encodedObject(originals[0])
        XCTAssertEqual(textObject["kind"] as? String, "text")
        XCTAssertEqual(textObject["text"] as? String, "Take the blue pill")
        XCTAssertNil(textObject["caption"])
        XCTAssertNil(textObject["filename"])
        XCTAssertNil(textObject["url"])

        // ...and the authoring payload nulls what the kind cannot carry.
        let fromTextPayload = InstructionPayload(kind: .text,
                                                 text: "  Take the blue pill  ",
                                                 caption: "stale caption",
                                                 filename: "stale.jpg").instruction
        XCTAssertEqual(fromTextPayload.kind, "text")
        XCTAssertEqual(fromTextPayload.text, "Take the blue pill")
        XCTAssertNil(fromTextPayload.caption)
        XCTAssertNil(fromTextPayload.filename)
        XCTAssertNil(fromTextPayload.url)

        let fromVideoPayload = InstructionPayload(kind: .video,
                                                  text: "stale text",
                                                  caption: "  Lunch routine  ",
                                                  filename: "instruction-3.mov").instruction
        XCTAssertEqual(fromVideoPayload.kind, "video")
        XCTAssertNil(fromVideoPayload.text)
        XCTAssertEqual(fromVideoPayload.caption, "Lunch routine")
        XCTAssertEqual(fromVideoPayload.filename, "instruction-3.mov")
        XCTAssertNil(fromVideoPayload.url)
    }

    func testIsPresentRequiresNonBlankText() {
        XCTAssertFalse(Instruction(kind: "text").isPresent)
        XCTAssertFalse(Instruction(kind: "text", text: "").isPresent)
        XCTAssertFalse(Instruction(kind: "text", text: " \n\t ").isPresent)
        XCTAssertTrue(Instruction(kind: "text", text: "Take the blue pill").isPresent)
        XCTAssertTrue(Instruction(kind: "text", text: "  padded  ").isPresent)

        XCTAssertEqual(Instruction(kind: "text", text: "  padded  ").trimmedText, "padded")
        XCTAssertNil(Instruction(kind: "text", text: "   ").trimmedText)

        XCTAssertFalse(Instruction(kind: "image").isPresent)
        XCTAssertFalse(Instruction(kind: "image", filename: "").isPresent)
        XCTAssertTrue(Instruction(kind: "image", filename: "instruction-1.jpg").isPresent)
        XCTAssertTrue(Instruction(kind: "video", filename: "instruction-1.mov").isPresent)

        // A blank/missing kind is never present, even if it carries text:
        // it is the tolerant-decode floor, not an unknown future kind.
        XCTAssertFalse(Instruction(kind: "").isPresent)
        XCTAssertFalse(Instruction(kind: "", text: "orphaned").isPresent)

        // Unknown kinds are forward tolerance: anything renderable means
        // present, so the surface shows the plain unsupported note.
        XCTAssertTrue(Instruction(kind: "link", url: "stored-url").isPresent)
        XCTAssertTrue(Instruction(kind: "audio", text: "Listen").isPresent)
        XCTAssertFalse(Instruction(kind: "link").isPresent)

        XCTAssertEqual(InstructionKind.reportable("text"), "text")
        XCTAssertEqual(InstructionKind.reportable("image"), "image")
        XCTAssertEqual(InstructionKind.reportable("video"), "video")
        XCTAssertEqual(InstructionKind.reportable("link"), "unknown")
        XCTAssertEqual(InstructionKind.reportable(""), "unknown")
    }

    func testTolerantDecodeIgnoresUnknownFields() throws {
        let decoded = try decode("""
        {
          "kind": "image",
          "filename": "instruction-1.jpg",
          "caption": "Blue box",
          "text": 7,
          "future_field": 42
        }
        """)

        XCTAssertEqual(decoded.kind, "image")
        XCTAssertEqual(decoded.filename, "instruction-1.jpg")
        XCTAssertEqual(decoded.caption, "Blue box")
        XCTAssertNil(decoded.text,
                     "a wrong-typed field becomes nil; it never fails the decode")
        XCTAssertTrue(decoded.isPresent)

        let reencoded = try encodedObject(decoded)
        XCTAssertNil(reencoded["future_field"], "unknown fields are dropped on encode")
        XCTAssertEqual(reencoded["kind"] as? String, "image")
        XCTAssertEqual(reencoded["filename"] as? String, "instruction-1.jpg")

        // Unknown kinds round-trip verbatim and stay displayable.
        let link = try decode(#"{"kind":"link","url":"stored-url","future_field":1}"#)
        XCTAssertEqual(link.kind, "link")
        XCTAssertEqual(link.url, "stored-url")
        XCTAssertNil(link.knownKind)
        XCTAssertTrue(link.isPresent)

        let audio = try decode(#"{"kind":"audio","text":"Listen"}"#)
        XCTAssertEqual(audio.kind, "audio")
        XCTAssertNil(audio.knownKind)
        XCTAssertTrue(audio.isPresent)
    }

    func testMissingKindDecodesAsAbsent() throws {
        let missingKind = try decode(#"{"text":"Take the blue pill"}"#)
        XCTAssertEqual(missingKind.kind, "")
        XCTAssertNil(missingKind.knownKind)
        XCTAssertFalse(missingKind.isPresent,
                       "a missing kind yields absence, not a decode failure")

        let wrongTypeKind = try decode(#"{"kind":7,"text":"Take the blue pill"}"#)
        XCTAssertEqual(wrongTypeKind.kind, "")
        XCTAssertFalse(wrongTypeKind.isPresent)

        let blankText = try decode(#"{"kind":"text","text":"   "}"#)
        XCTAssertEqual(blankText.kind, "text")
        XCTAssertFalse(blankText.isPresent)

        // Unknown fields on an otherwise absent instruction change nothing.
        let unknownOnly = try decode(#"{"future_field":{"nested":true}}"#)
        XCTAssertEqual(unknownOnly.kind, "")
        XCTAssertFalse(unknownOnly.isPresent)
    }

    func testCaptionIsOptional() throws {
        let text = Instruction(kind: "text", text: "Take the blue pill")
        XCTAssertNil(text.caption)
        XCTAssertNil(text.trimmedCaption)
        XCTAssertNil(try encodedObject(text)["caption"],
                     "a nil caption adds no key to the stored payload")

        let image = Instruction(kind: "image", filename: "instruction-1.jpg")
        let decodedImage = try JSONDecoder().decode(Instruction.self,
                                                    from: JSONEncoder().encode(image))
        XCTAssertNil(decodedImage.caption)
        XCTAssertTrue(decodedImage.isPresent)

        let captioned = Instruction(kind: "video",
                                    caption: "  Lunch routine  ",
                                    filename: "instruction-2.mov")
        XCTAssertEqual(captioned.caption, "  Lunch routine  ",
                       "decode keeps the stored value verbatim; trimming is a write concern")
        XCTAssertEqual(captioned.trimmedCaption, "Lunch routine")

        let decoded = try JSONDecoder().decode(Instruction.self,
                                               from: JSONEncoder().encode(captioned))
        XCTAssertEqual(decoded.caption, "  Lunch routine  ")
        XCTAssertEqual(decoded, captioned)
    }

    // MARK: - Draft algebra (design §4.2, §11.3 G)

    func testDraftTruthTableRows() {
        // .loading | any | any → nil.
        let loading = InstructionDraft.loading()
        XCTAssertEqual(loading.loadState, .loading)
        XCTAssertNil(loading.resolvedWrite)
        XCTAssertNil(loading.resolvedCommit)

        // .failed | any | any → nil; mutations on a failed draft are inert.
        var failed = InstructionDraft.failed()
        failed.setText("ignored")
        XCTAssertEqual(failed.loadState, .failed)
        XCTAssertFalse(failed.hasChanges)
        XCTAssertNil(failed.write)
        XCTAssertNil(failed.resolvedWrite)
        XCTAssertNil(failed.resolvedCommit)

        // .loaded | false | any → nil.
        let loaded = InstructionDraft.loaded(
            instruction: Instruction(kind: "text", text: "Old words"))
        XCTAssertEqual(loaded.loadState, .loaded)
        XCTAssertFalse(loaded.hasChanges)
        XCTAssertNil(loaded.resolvedWrite)
        XCTAssertNil(loaded.resolvedCommit)

        // A mutation that is reverted is not a change.
        var reverted = loaded
        reverted.setText("New words")
        XCTAssertNotNil(reverted.resolvedWrite)
        reverted.revert()
        XCTAssertFalse(reverted.hasChanges)
        XCTAssertNil(reverted.write)
        XCTAssertNil(reverted.pendingMedia)
        XCTAssertNil(reverted.resolvedWrite)
        XCTAssertEqual(reverted.payload,
                       InstructionPayload(kind: .text, text: "Old words"))

        // .loaded | true | nil → nil. The internal seam pins this row; no
        // public mutation can reach "changed but authored nothing".
        let authoredNothing = InstructionDraft(
            loadState: .loaded,
            hasChanges: true,
            write: nil,
            pendingMedia: nil,
            payload: InstructionPayload(kind: .text, text: "x"),
            original: nil
        )
        XCTAssertNil(authoredNothing.resolvedWrite)
        XCTAssertNil(authoredNothing.resolvedCommit)

        // .loaded | true | .set(payload) → that write.
        var textSet = InstructionDraft.loaded(instruction: nil)
        textSet.setText("  Take the blue pill  ")
        let textPayload = InstructionPayload(kind: .text, text: "  Take the blue pill  ")
        XCTAssertTrue(textSet.hasChanges)
        XCTAssertEqual(textSet.write, .set(textPayload))
        XCTAssertEqual(textSet.resolvedWrite, .set(textPayload))
        XCTAssertEqual(textSet.resolvedCommit,
                       InstructionCommit(write: .set(textPayload), pendingMedia: nil))

        // The same row for a media payload that already has stored bytes.
        var mediaSet = InstructionDraft.loaded(instruction: nil)
        mediaSet.chooseKind(.video)
        mediaSet.setExistingMedia(filename: "instruction-1.mov", caption: "Lunch")
        let mediaPayload = InstructionPayload(kind: .video,
                                              caption: "Lunch",
                                              filename: "instruction-1.mov")
        XCTAssertEqual(mediaSet.resolvedWrite, .set(mediaPayload))

        // .loaded | true | .remove → .remove.
        var removed = loaded
        removed.removeInstruction()
        XCTAssertEqual(removed.resolvedWrite, .remove)
        XCTAssertEqual(removed.resolvedCommit,
                       InstructionCommit(write: .remove, pendingMedia: nil))

        // Mutations that do not belong to the chosen kind are inert; they
        // never silently convert a text draft into media (or back).
        var textDraft = InstructionDraft.loaded(
            instruction: Instruction(kind: "text", text: "Words"))
        textDraft.setCaption("ignored")
        textDraft.setExistingMedia(filename: "ignored.jpg", caption: "ignored")
        XCTAssertFalse(textDraft.hasChanges)
        XCTAssertNil(textDraft.resolvedWrite)

        var imageDraft = InstructionDraft.loaded(
            instruction: Instruction(kind: "image",
                                     filename: "instruction-1.jpg"))
        imageDraft.setText("ignored")
        XCTAssertFalse(imageDraft.hasChanges)

        // Re-choosing the same kind is not an edit.
        var sameKind = InstructionDraft.loaded(
            instruction: Instruction(kind: "text", text: "Words"))
        sameKind.chooseKind(.text)
        XCTAssertFalse(sameKind.hasChanges)
        XCTAssertNil(sameKind.resolvedWrite)
    }

    func testSetMediaWithoutPendingIsUnresolved() {
        // A chosen image kind plus a caption is still not a savable page.
        var imageDraft = InstructionDraft.loaded(instruction: nil)
        imageDraft.chooseKind(.image)
        imageDraft.setCaption("Blue box")
        XCTAssertTrue(imageDraft.hasChanges)
        XCTAssertNil(imageDraft.payload?.filename)
        XCTAssertNil(imageDraft.pendingMedia)
        XCTAssertNil(imageDraft.resolvedWrite)
        XCTAssertNil(imageDraft.resolvedCommit)

        // Same for video.
        var videoDraft = InstructionDraft.loaded(instruction: nil)
        videoDraft.chooseKind(.video)
        videoDraft.setCaption("Lunch routine")
        XCTAssertNil(videoDraft.resolvedWrite)

        // A picked image is the pending bytes that make the draft resolvable.
        let pickedImage = UIImage()
        var pendingImage = InstructionDraft.loaded(instruction: nil)
        pendingImage.setPendingImage(pickedImage, caption: "Blue box")
        XCTAssertEqual(pendingImage.resolvedWrite,
                       .set(InstructionPayload(kind: .image, caption: "Blue box")))
        XCTAssertEqual(pendingImage.resolvedCommit?.pendingMedia,
                       .image(pickedImage))

        // The caption is optional on new media.
        var uncaptioned = InstructionDraft.loaded(instruction: nil)
        uncaptioned.setPendingImage(UIImage(), caption: nil)
        XCTAssertEqual(uncaptioned.resolvedWrite,
                       .set(InstructionPayload(kind: .image)))

        // A validated video likewise resolves only through its pending value.
        let acceptedVideo = makeAcceptedVideo()
        var pendingVideo = InstructionDraft.loaded(instruction: nil)
        pendingVideo.setPendingVideo(acceptedVideo, caption: "Lunch routine")
        XCTAssertEqual(pendingVideo.resolvedWrite,
                       .set(InstructionPayload(kind: .video, caption: "Lunch routine")))
        XCTAssertEqual(pendingVideo.resolvedCommit?.pendingMedia,
                       .video(acceptedVideo))

        // Existing media resolves from its stored filename, with no bytes to
        // copy. A caption-only edit keeps that filename and no pending media.
        var existing = InstructionDraft.loaded(instruction: nil)
        existing.chooseKind(.video)
        existing.setExistingMedia(filename: "instruction-1.mov", caption: "Lunch")
        XCTAssertEqual(existing.resolvedWrite,
                       .set(InstructionPayload(kind: .video,
                                               caption: "Lunch",
                                               filename: "instruction-1.mov")))
        XCTAssertNil(existing.pendingMedia)

        // An empty filename is not a stored filename.
        existing.setExistingMedia(filename: "", caption: nil)
        XCTAssertNil(existing.resolvedWrite)

        // Caption-only edit of a loaded existing image (design §4.2).
        var captionOnly = InstructionDraft.loaded(
            instruction: Instruction(kind: "image",
                                     caption: "Old caption",
                                     filename: "instruction-2.jpg"))
        captionOnly.setCaption("  New caption  ")
        XCTAssertEqual(captionOnly.resolvedWrite,
                       .set(InstructionPayload(kind: .image,
                                               caption: "  New caption  ",
                                               filename: "instruction-2.jpg")))
        XCTAssertNil(captionOnly.pendingMedia,
                     "a caption edit writes no media")

        // Both media kinds carry caption + filename, so a kind switch keeps
        // them; a switch away from text clears its words.
        var switched = InstructionDraft.loaded(
            instruction: Instruction(kind: "image",
                                     caption: "Blue box",
                                     filename: "instruction-3.jpg"))
        switched.chooseKind(.video)
        XCTAssertEqual(switched.resolvedWrite,
                       .set(InstructionPayload(kind: .video,
                                               caption: "Blue box",
                                               filename: "instruction-3.jpg")))

        var fromText = InstructionDraft.loaded(
            instruction: Instruction(kind: "text", text: "stale words"))
        fromText.chooseKind(.image)
        XCTAssertEqual(fromText.payload, InstructionPayload(kind: .image))
        XCTAssertEqual(fromText.payload?.instruction.text, nil)
    }

    func testRemoveDraftResolvesToRemove() {
        var draft = InstructionDraft.loaded(
            instruction: Instruction(kind: "text", text: "Take the blue pill"))
        draft.removeInstruction()

        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.write, .remove)
        XCTAssertEqual(draft.resolvedWrite, .remove)
        XCTAssertEqual(draft.resolvedCommit,
                       InstructionCommit(write: .remove, pendingMedia: nil))

        // Never the "empty text means delete" shape.
        if let resolved = draft.resolvedWrite, case .set = resolved {
            XCTFail("removal resolved to a set write")
        }
        XCTAssertNotEqual(draft.resolvedWrite,
                          .set(InstructionPayload(kind: .text, text: nil)))

        // Pending bytes are always dropped by an explicit removal.
        var withPending = InstructionDraft.loaded(instruction: nil)
        withPending.setPendingVideo(makeAcceptedVideo(), caption: nil)
        withPending.removeInstruction()
        XCTAssertNil(withPending.pendingMedia)
        XCTAssertEqual(withPending.resolvedWrite, .remove)
        XCTAssertNil(withPending.resolvedCommit?.pendingMedia)

        // Reverting restores the original and clears the remove.
        draft.revert()
        XCTAssertNil(draft.write)
        XCTAssertNil(draft.resolvedWrite)
        XCTAssertEqual(draft.original,
                       Instruction(kind: "text", text: "Take the blue pill"))
    }

    func testPayloadNeverCarriesStaleFields() {
        // A text edit of a stored image loses the media fields entirely.
        var textDraft = InstructionDraft.loaded(
            instruction: Instruction(kind: "image",
                                     text: "stale text",
                                     caption: "stale caption",
                                     filename: "stale.jpg"))
        textDraft.chooseKind(.text)
        textDraft.setText("  Take the blue pill  ")
        guard let textWrite = textDraft.resolvedWrite,
              case .set(let textPayload) = textWrite else {
            return XCTFail("expected a resolved text write")
        }
        XCTAssertEqual(textPayload.kind, .text)
        let textInstruction = textPayload.instruction
        XCTAssertEqual(textInstruction.kind, "text")
        XCTAssertEqual(textInstruction.text, "Take the blue pill")
        XCTAssertNil(textInstruction.caption)
        XCTAssertNil(textInstruction.filename)
        XCTAssertNil(textInstruction.url)

        // Pending image bytes clear the old filename and carry no stray text.
        var imageDraft = InstructionDraft.loaded(
            instruction: Instruction(kind: "text", text: "stale text"))
        imageDraft.setPendingImage(UIImage(), caption: "  Blue box  ")
        guard let imageWrite = imageDraft.resolvedWrite,
              case .set(let imagePayload) = imageWrite else {
            return XCTFail("expected a resolved image write")
        }
        let imageInstruction = imagePayload.instruction
        XCTAssertEqual(imageInstruction.kind, "image")
        XCTAssertNil(imageInstruction.text)
        XCTAssertEqual(imageInstruction.caption, "Blue box")
        XCTAssertNil(imageInstruction.filename,
                     "the store mints the filename at commit; none may be stale")
        XCTAssertNil(imageInstruction.url)
        XCTAssertEqual(imageDraft.payload?.instruction, imageInstruction,
                       "the draft's editable payload mirrors the committed shape")

        // A caption-only media edit writes only caption and filename.
        var existing = InstructionDraft.loaded(
            instruction: Instruction(kind: "video",
                                     text: "stale text",
                                     caption: "old",
                                     filename: "instruction-1.mov"))
        existing.setCaption("  Lunch routine  ")
        guard let videoWrite = existing.resolvedWrite,
              case .set(let videoPayload) = videoWrite else {
            return XCTFail("expected a resolved video write")
        }
        let videoInstruction = videoPayload.instruction
        XCTAssertEqual(videoInstruction.kind, "video")
        XCTAssertNil(videoInstruction.text)
        XCTAssertEqual(videoInstruction.caption, "Lunch routine")
        XCTAssertEqual(videoInstruction.filename, "instruction-1.mov")
        XCTAssertNil(videoInstruction.url)

        // Pending video bytes resolve without a filename and without text.
        var pendingVideo = InstructionDraft.loaded(instruction: nil)
        pendingVideo.setPendingVideo(makeAcceptedVideo(), caption: "  Lunch  ")
        guard let pendingWrite = pendingVideo.resolvedWrite,
              case .set(let pendingPayload) = pendingWrite else {
            return XCTFail("expected a resolved pending-video write")
        }
        XCTAssertNil(pendingPayload.instruction.text)
        XCTAssertEqual(pendingPayload.instruction.caption, "Lunch")
        XCTAssertNil(pendingPayload.instruction.filename)
        XCTAssertNil(pendingPayload.instruction.url)
    }

    func testCommitPairsWriteAndPendingMedia() {
        // Pending image pairs with the image write.
        let image = UIImage()
        var imageDraft = InstructionDraft.loaded(instruction: nil)
        imageDraft.setPendingImage(image, caption: "Blue box")
        let imagePayload = InstructionPayload(kind: .image, caption: "Blue box")
        XCTAssertEqual(imageDraft.resolvedCommit,
                       InstructionCommit(write: .set(imagePayload),
                                         pendingMedia: .image(image)))

        // Pending video pairs with the video write.
        let video = makeAcceptedVideo()
        var videoDraft = InstructionDraft.loaded(instruction: nil)
        videoDraft.setPendingVideo(video, caption: "Lunch routine")
        let videoPayload = InstructionPayload(kind: .video, caption: "Lunch routine")
        XCTAssertEqual(videoDraft.resolvedCommit,
                       InstructionCommit(write: .set(videoPayload),
                                         pendingMedia: .video(video)))

        // A text write never carries pending media, even in a hand-built
        // state (design §4.2: "a text write can never smuggle an image").
        let textOnly = InstructionDraft(
            loadState: .loaded,
            hasChanges: true,
            write: .set(InstructionPayload(kind: .text, text: "Words")),
            pendingMedia: .image(image),
            payload: InstructionPayload(kind: .text, text: "Words"),
            original: nil
        )
        XCTAssertEqual(textOnly.resolvedCommit,
                       InstructionCommit(
                           write: .set(InstructionPayload(kind: .text, text: "Words")),
                           pendingMedia: nil))

        // A pending medium of the wrong kind is dropped even when the write
        // itself resolves from a stored filename.
        let storedImagePayload = InstructionPayload(kind: .image,
                                                    filename: "instruction-1.jpg")
        let mismatched = InstructionDraft(
            loadState: .loaded,
            hasChanges: true,
            write: .set(storedImagePayload),
            pendingMedia: .video(video),
            payload: storedImagePayload,
            original: nil
        )
        XCTAssertEqual(mismatched.resolvedWrite, .set(storedImagePayload))
        XCTAssertEqual(mismatched.resolvedCommit,
                       InstructionCommit(write: .set(storedImagePayload),
                                         pendingMedia: nil))

        // Unresolved drafts have no commit at all.
        var unresolved = InstructionDraft.loaded(instruction: nil)
        unresolved.chooseKind(.image)
        XCTAssertNil(unresolved.resolvedWrite)
        XCTAssertNil(unresolved.resolvedCommit)
    }

    func testAcceptedVideoIsEquatable() {
        let first = makeAcceptedVideo()
        let same = makeAcceptedVideo()
        XCTAssertEqual(first, same,
                       "equal staged values compare equal without reading bytes")
        XCTAssertEqual(first.staged.byteCount, 4_096)
        XCTAssertEqual(first.staged.metadata,
                       InstructionVideoMetadata(durationSeconds: 1.5,
                                                hasVideoTrack: true,
                                                isPlayable: true))
        XCTAssertEqual(InstructionPendingMedia.video(first),
                       InstructionPendingMedia.video(same))

        let later = makeAcceptedVideo(
            validatedAt: Date(timeIntervalSince1970: 2_001))
        XCTAssertNotEqual(first, later)
        XCTAssertNotEqual(InstructionPendingMedia.video(first),
                          InstructionPendingMedia.video(later))

        let otherStaged = StagedInstructionVideo(
            draftId: UUID(),
            root: .events,
            stagedURL: URL(fileURLWithPath: "/tmp/other/payload.mp4"),
            byteCount: 1,
            metadata: InstructionVideoMetadata(durationSeconds: 2,
                                               hasVideoTrack: true,
                                               isPlayable: true),
            sourceExtension: "mp4",
            stagedAt: Date(timeIntervalSince1970: 3_000)
        )
        let moved = AcceptedInstructionVideo(
            staged: otherStaged,
            validatedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertNotEqual(first, moved)

        // The image payload value is Equatable too (P-7).
        let image = UIImage()
        XCTAssertEqual(InstructionPendingMedia.image(image),
                       InstructionPendingMedia.image(image))
    }

    // MARK: - Owners and roots

    func testOwnerRootsAreDisjoint() {
        XCTAssertEqual(InstructionRoot.routines.rawValue, "InstructionVideos")
        XCTAssertEqual(InstructionRoot.events.rawValue, "EventInstructionVideos")
        XCTAssertEqual(Set(InstructionRoot.allCases).count, 2)

        let routineId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let routine = InstructionOwner.routine(routineId)
        let event = InstructionOwner.event("event-1")

        XCTAssertEqual(routine.root, .routines)
        XCTAssertEqual(event.root, .events)
        XCTAssertNotEqual(routine.root, event.root)

        XCTAssertEqual(routine.directoryName, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(routine.directoryName, routineId.uuidString)
        XCTAssertTrue(InstructionFilename.isPlain(routine.directoryName))
        XCTAssertEqual(InstructionOwner.routine(routineId), routine)

        // Even handed the same identifier text, the two owner kinds land in
        // different roots and different directory names.
        let eventWithSameText = InstructionOwner.event(routineId.uuidString)
        XCTAssertNotEqual(routine.root, eventWithSameText.root)
        XCTAssertNotEqual(routine.directoryName, eventWithSameText.directoryName)
    }

    func testEventOwnerUsesLowercaseSHA256Hex() {
        // Known answer: SHA-256("event-1") begins ce36863f51b6baf9d16397ffb3e9af50.
        let expected = "ev-ce36863f51b6baf9d16397ffb3e9af50"
        XCTAssertEqual(InstructionOwner.eventDirectoryName(for: "event-1"), expected)
        XCTAssertEqual(InstructionOwner.event("event-1").directoryName, expected)

        let owner = InstructionOwner.event("EK-Event/with unsafe:characters")
        XCTAssertTrue(owner.directoryName.hasPrefix("ev-"))
        XCTAssertEqual(owner.directoryName.count, 35, "ev- plus 32 hex characters")
        let hex = String(owner.directoryName.dropFirst(3))
        XCTAssertNotNil(hex.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertEqual(owner.directoryName, owner.directoryName.lowercased())
        XCTAssertTrue(InstructionFilename.isPlain(owner.directoryName))

        XCTAssertNotEqual(InstructionOwner.eventDirectoryName(for: "event-1"),
                          InstructionOwner.eventDirectoryName(for: "event-2"))
        XCTAssertEqual(InstructionOwner.eventDirectoryName(for: "").count, 35,
                       "even an empty identifier yields a stable, plain directory name")
    }

    // MARK: - Duration boundary

    func testDurationRoundsUpAtTheInclusiveBoundary() {
        XCTAssertEqual(InstructionVideoDuration.roundedSeconds(180), 180)
        XCTAssertEqual(InstructionVideoDuration.roundedSeconds(180.2), 180)
        XCTAssertEqual(InstructionVideoDuration.roundedSeconds(180.5), 181)
        XCTAssertEqual(InstructionVideoDuration.roundedSeconds(179.6), 180)
        XCTAssertEqual(InstructionVideoDuration.roundedSeconds(0), 0)

        XCTAssertFalse(InstructionVideoDuration.exceedsLimit(180, limit: 180),
                       "exactly 180 seconds is allowed — the cap is inclusive")
        XCTAssertFalse(InstructionVideoDuration.exceedsLimit(180.2, limit: 180),
                       "180.2 rounds to 180 and is allowed")
        XCTAssertTrue(InstructionVideoDuration.exceedsLimit(180.5, limit: 180),
                      "180.5 rounds to 181 and is refused")
        XCTAssertFalse(InstructionVideoDuration.exceedsLimit(179.6, limit: 180))
        XCTAssertTrue(InstructionVideoDuration.exceedsLimit(181, limit: 180))

        XCTAssertTrue(InstructionVideoDuration.exceedsLimit(Double.nan, limit: 180))
        XCTAssertTrue(InstructionVideoDuration.exceedsLimit(Double.infinity, limit: 180))
    }

    // MARK: - Filename guard

    func testFilenameGuardRejectsTraversalAndEmptyNames() {
        let refused = [
            "",
            ".",
            "..",
            "../evil.jpg",
            "..\\evil.jpg",
            "dir/evil.jpg",
            "/absolute.jpg",
            "instruction-1.jpg/x",
        ]
        for name in refused {
            XCTAssertFalse(InstructionFilename.isPlain(name),
                           "expected the guard to refuse \(name)")
        }

        let accepted = [
            "instruction-1.jpg",
            "instruction-ABCD.mov",
            "a",
            "a b.jpg",
            "..hidden",
        ]
        for name in accepted {
            XCTAssertTrue(InstructionFilename.isPlain(name),
                          "expected the guard to accept \(name)")
        }

        XCTAssertEqual(InstructionFilename.sanitizedExtension("mp4"), "mp4")
        XCTAssertEqual(InstructionFilename.sanitizedExtension("m4v"), "m4v")
        XCTAssertEqual(InstructionFilename.sanitizedExtension("MOV"), "mov",
                       "a recorder's uppercase extension keeps its value")
        XCTAssertEqual(InstructionFilename.sanitizedExtension("12345678"), "12345678")
        XCTAssertEqual(InstructionFilename.sanitizedExtension("123456789"), "mov")
        XCTAssertEqual(InstructionFilename.sanitizedExtension(""), "mov")
        XCTAssertEqual(InstructionFilename.sanitizedExtension("m-4"), "mov")
        XCTAssertEqual(InstructionFilename.sanitizedExtension(".mp4"), "mov")
        XCTAssertEqual(InstructionFilename.sanitizedExtension("mp4 "), "mov")
    }

    // MARK: - Configuration

    func testConfigurationDefaultsMatchDesign() {
        let limits = InstructionVideoLimits.standard
        XCTAssertEqual(limits.maxDurationSeconds, 180)
        XCTAssertEqual(limits.maxBytes, 209_715_200)

        let video = InstructionVideoConfiguration.standard
        XCTAssertEqual(video.limits, limits)
        XCTAssertEqual(video.validationTimeoutSeconds, 20)
        XCTAssertEqual(video.orphanGraceSeconds, 60)
        XCTAssertEqual(video.stagingChunkBytes, 1_048_576)

        let capture = InstructionCaptureConfiguration.standard
        XCTAssertEqual(capture.video, video)
        XCTAssertEqual(capture.recordingQuality, .high)
        XCTAssertEqual(InstructionRecordingQuality(rawValue: "high"), .high)
        XCTAssertEqual(InstructionRecordingQuality(rawValue: "medium"), .medium)
        XCTAssertNil(InstructionRecordingQuality(rawValue: "low"))
    }

    // MARK: - Metadata paths

    func testProbeRejectsMissingSource() throws {
        let prober = AVInstructionVideoProber()

        let missing = tempDirectory.appendingPathComponent("missing-\(UUID().uuidString).mov")
        XCTAssertEqual(prober.probe(url: missing), .failure(.unreadableSource))

        let directory = tempDirectory.appendingPathComponent("a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        XCTAssertEqual(prober.probe(url: directory), .failure(.unreadableSource))

        let remote = try XCTUnwrap(URL(string: "https://example.com/instruction.mov"))
        XCTAssertEqual(prober.probe(url: remote), .failure(.unreadableSource),
                       "only file URLs are accepted")

        let emptyFile = tempDirectory.appendingPathComponent("empty.mov")
        try Data().write(to: emptyFile)
        XCTAssertEqual(prober.probe(url: emptyFile), .failure(.unsupportedFormat),
                       "a readable file that is not playable is a format refusal")
    }

    func testInspectRejectsNonVideo() async throws {
        let inspector = AVInstructionVideoInspector()

        let audioOnly = tempDirectory.appendingPathComponent("audio-only.wav")
        try writeSilentWAV(to: audioOnly)

        let inspected = await inspector.inspect(url: audioOnly)
        XCTAssertEqual(inspected, .failure(.unsupportedFormat),
                       "a valid media file with no video track is an unsupported format")

        // The synchronous pre-staging probe reaches the same mapping.
        XCTAssertEqual(AVInstructionVideoProber().probe(url: audioOnly),
                       .failure(.unsupportedFormat))

        // The async path never throws and never returns an NSError: a
        // missing source is a typed failure.
        let missing = tempDirectory.appendingPathComponent("missing-\(UUID().uuidString).mp4")
        let missingResult = await inspector.inspect(url: missing)
        XCTAssertEqual(missingResult, .failure(.unreadableSource))
    }
}
