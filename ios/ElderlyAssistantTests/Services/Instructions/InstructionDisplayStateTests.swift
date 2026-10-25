import XCTest
@testable import ElderlyAssistant

/// The collapsed display-state contract (T-003; design L2 §3.4 IF-3, §4.6,
/// §4.10, §11.3 D/F-6/F-12).
///
/// Every case here is a pure value assertion: `InstructionPresentation` reads
/// no store, file or locale, so the suite never plants bytes. Playability is
/// the store's separate answer and is not an input to this function.
final class InstructionDisplayStateTests: XCTestCase {

    func testPresentationCollapsesEveryStoredShape() {
        // text | non-blank text | text(text). The stored value is trimmed;
        // the card never shows leading/trailing blank space.
        XCTAssertEqual(
            InstructionPresentation.state(
                for: Instruction(kind: "text", text: "  Take the blue pill  "),
                isExpected: false),
            .text(text: "Take the blue pill"))

        // image | filename and caption | image(filename, caption).
        XCTAssertEqual(
            InstructionPresentation.state(
                for: Instruction(kind: "image",
                                 caption: "  Blue box  ",
                                 filename: "instruction-1.jpg"),
                isExpected: false),
            .image(filename: "instruction-1.jpg", caption: "Blue box"))

        // video | filename and caption | video(filename, caption).
        XCTAssertEqual(
            InstructionPresentation.state(
                for: Instruction(kind: "video",
                                 caption: "Lunch routine",
                                 filename: "instruction-2.mov"),
                isExpected: false),
            .video(filename: "instruction-2.mov", caption: "Lunch routine"))

        // text | blank text | none. A text kind is never `.unsupported`.
        XCTAssertEqual(
            InstructionPresentation.state(
                for: Instruction(kind: "text", text: " \n\t "),
                isExpected: false),
            .none)

        // "video never playable on device" — a KNOWN video maps to `.video`,
        // not `.unsupported`: this function is pure and cannot judge local
        // playability. The card shows the store's unavailable line at render
        // time (design §4.10; §11.3 D and F-12). Only an unknown stored kind
        // is `.unsupported` (the next row).
        XCTAssertEqual(
            InstructionPresentation.state(
                for: Instruction(kind: "video", filename: "gone.mov"),
                isExpected: false),
            .video(filename: "gone.mov", caption: nil))

        // A kind the surface cannot render | unsupported(text). F-6a's
        // future link kind still shows its saved words and no control.
        XCTAssertEqual(
            InstructionPresentation.state(
                for: Instruction(kind: "link", text: "Saved words"),
                isExpected: false),
            .unsupported(text: "Saved words"))

        // absent | owner expects an instruction | removed.
        XCTAssertEqual(
            InstructionPresentation.state(for: nil, isExpected: true),
            .removed)

        // absent | owner never had an instruction | none.
        XCTAssertEqual(
            InstructionPresentation.state(for: nil, isExpected: false),
            .none)
    }

    func testBlankTextIsNoneNotUnsupported() {
        let blankShapes = [
            Instruction(kind: "text"),
            Instruction(kind: "text", text: ""),
            Instruction(kind: "text", text: " \n\t "),
            // Only `text` counts for the text kind: stray media fields do
            // not make a blank-text instruction present.
            Instruction(kind: "text",
                        text: "   ",
                        caption: "orphan caption",
                        filename: "orphan.jpg"),
        ]

        for blank in blankShapes {
            XCTAssertEqual(
                InstructionPresentation.state(for: blank, isExpected: false),
                .none)
            XCTAssertEqual(
                InstructionPresentation.state(for: blank, isExpected: true),
                .removed)

            if case .unsupported = InstructionPresentation.state(
                for: blank, isExpected: false) {
                XCTFail("blank text is absent, never unsupported")
            }
        }
    }

    func testAbsentInstructionIsRemovedOnlyWhenExpected() {
        // Nil is the common absent shape.
        XCTAssertEqual(InstructionPresentation.state(for: nil, isExpected: true),
                       .removed)
        XCTAssertEqual(InstructionPresentation.state(for: nil, isExpected: false),
                       .none)

        // Every not-present stored shape follows the same rule:
        // expected ⇒ removed, never expected ⇒ none.
        let absentShapes = [
            Instruction(kind: "image"),
            Instruction(kind: "image", filename: ""),
            Instruction(kind: "video"),
            Instruction(kind: "video", caption: "orphan caption"),
            Instruction(kind: ""),
            Instruction(kind: "", text: "orphaned"),
            Instruction(kind: "link"),
        ]

        for absent in absentShapes {
            XCTAssertFalse(absent.isPresent)
            XCTAssertEqual(
                InstructionPresentation.state(for: absent, isExpected: false),
                .none)
            XCTAssertEqual(
                InstructionPresentation.state(for: absent, isExpected: true),
                .removed)
        }

        // A represented instruction ignores `isExpected` entirely.
        let present = Instruction(kind: "text", text: "Take the blue pill")
        XCTAssertEqual(
            InstructionPresentation.state(for: present, isExpected: false),
            .text(text: "Take the blue pill"))
        XCTAssertEqual(
            InstructionPresentation.state(for: present, isExpected: true),
            .text(text: "Take the blue pill"))
    }

    func testUnsupportedCarriesSavedText() {
        // An independently unknown kind with words: the words survive.
        let audio = Instruction(kind: "audio", text: "  Listen  ")
        let audioState = InstructionPresentation.state(for: audio,
                                                       isExpected: false)
        XCTAssertEqual(audioState, .unsupported(text: "Listen"))

        // F-6a: a future link-only instruction has no text; the plain note
        // still appears and the stored URL is not surfaced as a control.
        let link = Instruction(kind: "link", url: "stored-url")
        let linkState = InstructionPresentation.state(for: link,
                                                      isExpected: false)
        XCTAssertEqual(linkState, .unsupported(text: nil))

        // Text wins over caption/url when several fields are present.
        let future = Instruction(kind: "link",
                                 text: "Saved words",
                                 caption: "caption",
                                 url: "stored-url")
        XCTAssertEqual(
            InstructionPresentation.state(for: future, isExpected: false),
            .unsupported(text: "Saved words"))

        // No play or open control is produced: every unsupported state is
        // the plain note case, never a media case carrying a filename/URL.
        for state in [audioState, linkState] {
            switch state {
            case .unsupported:
                break
            case .video, .image:
                XCTFail("unsupported must not produce a play or photo control")
            case .none, .text, .removed:
                XCTFail("expected an unsupported state")
            }
        }
    }

    // MARK: - T-007: the plain-copy map (IF-4, design §3.4, §3.3, §10.5)

    /// Third Gherkin scenario: every typed failure maps to exactly one
    /// stable copy key. The keys are the shipping `instruction.*` family,
    /// never the stale `instruction.import.*` / `instruction.permission.*`
    /// names the task text drifted to.
    func testEveryFailureMapsToAKey() {
        XCTAssertEqual(InstructionMessageKey.forImport(.unreadableSource),
                       "instruction.video.unreadable")
        XCTAssertEqual(InstructionMessageKey.forImport(.unsupportedFormat),
                       "instruction.video.unreadable")
        XCTAssertEqual(InstructionMessageKey.forImport(.tooLong),
                       "instruction.video.tooLong")
        XCTAssertEqual(InstructionMessageKey.forImport(.tooLarge),
                       "instruction.video.tooLarge")
        XCTAssertEqual(InstructionMessageKey.forImport(.validationTimedOut),
                       "instruction.video.unreadable")

        // Every store failure wrapped by an import write shares the one
        // "could not be saved" sentence (§3.3).
        for storageError in storageErrors {
            XCTAssertEqual(
                InstructionMessageKey.forImport(.writeFailed(storageError)),
                "instruction.video.saveFailed")
        }

        // Cancellation is the only import failure with no copy at all.
        XCTAssertNil(InstructionMessageKey.forImport(.cancelled))

        // All four playback failures render the same fallback line.
        for failure in playbackFailures {
            XCTAssertEqual(InstructionMessageKey.forPlayback(failure),
                           "instruction.video.unavailable")
        }

        // All three image failures render the same fallback line.
        for failure in imageFailures {
            XCTAssertEqual(InstructionMessageKey.forImage(failure),
                           "instruction.image.unavailable")
        }

        XCTAssertEqual(InstructionMessageKey.forPermission(.cameraDenied),
                       "instruction.camera.denied")
        XCTAssertEqual(InstructionMessageKey.forPermission(.microphoneDenied),
                       "instruction.microphone.denied")
        XCTAssertEqual(InstructionMessageKey.forPermission(.cameraUnavailable),
                       "instruction.camera.unavailable")

        // Every failure except cancellation produces a non-empty key.
        for error in importErrors where error != .cancelled {
            XCTAssertFalse((InstructionMessageKey.forImport(error) ?? "").isEmpty)
        }
    }

    /// Every mapped key resolves in the shipping String Catalog, in both
    /// languages: an `en` value and a Nepali `ne` value, with no English
    /// fallback in `ne` (NFR-RIE-002; design §10.5).
    func testEveryMappedKeyResolvesInBothLanguages() {
        let keys = mappedMessageKeys
        XCTAssertFalse(keys.isEmpty, "the failure map produced no keys")

        let catalogURL = FeatureSourceScan.iosDirectory()
            .appendingPathComponent(
                "ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: catalogURL),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            XCTFail("could not read the shipping String Catalog at \(catalogURL.path)")
            return
        }

        for key in keys.sorted() {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                XCTFail("\(key) is missing from the shipping catalogue")
                continue
            }
            for language in ["en", "ne"] {
                let localization = localizations[language] as? [String: Any]
                guard let unit = localization?["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    XCTFail("\(key) has no \(language) value")
                    continue
                }
                if language == "ne" {
                    XCTAssertTrue(hasDevanagari(value),
                                  "\(key) has an English-looking Nepali value")
                }
            }
        }
    }

    /// T-013: the routine write seam's failures map to the design's plain
    /// keys, in the shipping catalogue's `instruction.*` family (§3.3).
    func testForWriteMapsEachWriteError() {
        XCTAssertEqual(InstructionMessageKey.forWrite(.ownerNotFound),
                       "instruction.removed")
        XCTAssertEqual(InstructionMessageKey.forWrite(.unresolvedPayload),
                       "instruction.saveFailed")
        XCTAssertEqual(InstructionMessageKey.forWrite(.persistenceFailed),
                       "instruction.saveFailed")

        XCTAssertEqual(InstructionMessageKey.forWrite(.mediaWriteFailed(.invalidOwner)),
                       "instruction.saveFailed")
        for storageError in [InstructionStorageError.stagingFailed,
                             .protectionFailed, .commitFailed] {
            XCTAssertEqual(
                InstructionMessageKey.forWrite(.mediaWriteFailed(storageError)),
                "instruction.video.saveFailed")
        }

        // The table gives `.deleteFailed` / `.purgeFailed` no user copy
        // (logged only). `forWrite` is total and never returns nil, so the
        // generic save line is the honest fallback; a media WRITE cannot
        // produce either case.
        for storageError in [InstructionStorageError.deleteFailed, .purgeFailed] {
            XCTAssertEqual(
                InstructionMessageKey.forWrite(.mediaWriteFailed(storageError)),
                "instruction.saveFailed")
        }

        for error in writeErrors {
            XCTAssertFalse(InstructionMessageKey.forWrite(error).isEmpty)
        }
    }

    /// A message key is a localisation identifier, not a diagnostic: no
    /// snake_case code, no error type name, no spaces. This is the pin that
    /// keeps an internal token from leaking into elder-facing copy.
    func testMessageKeyHasNoCodeOrDiagnostic() {
        let keys = mappedMessageKeys
        XCTAssertEqual(keys, [
            "instruction.video.unreadable",
            "instruction.video.tooLong",
            "instruction.video.tooLarge",
            "instruction.video.saveFailed",
            "instruction.video.unavailable",
            "instruction.image.unavailable",
            "instruction.camera.denied",
            "instruction.microphone.denied",
            "instruction.camera.unavailable",
            "instruction.removed",
            "instruction.saveFailed"
        ])

        let errorTokens = [
            InstructionErrorCode.unreadableSource.rawValue,
            InstructionErrorCode.unsupportedFormat.rawValue,
            InstructionErrorCode.tooLong.rawValue,
            InstructionErrorCode.tooLarge.rawValue,
            InstructionErrorCode.validationTimedOut.rawValue,
            InstructionErrorCode.writeFailed.rawValue,
            InstructionErrorCode.invalidOwner.rawValue,
            InstructionErrorCode.stagingFailed.rawValue,
            InstructionErrorCode.protectionFailed.rawValue,
            InstructionErrorCode.commitFailed.rawValue,
            InstructionErrorCode.deleteFailed.rawValue,
            InstructionErrorCode.purgeFailed.rawValue,
            InstructionErrorCode.unsupported.rawValue,
            InstructionErrorCode.playerFailed.rawValue,
            InstructionErrorCode.interrupted.rawValue,
            InstructionErrorCode.timedOut.rawValue
        ]

        for key in keys {
            XCTAssertTrue(key.hasPrefix("instruction."),
                          "\(key) is not in the instruction key family")
            XCTAssertNil(key.rangeOfCharacter(from: .whitespacesAndNewlines),
                         "\(key) contains whitespace")
            XCTAssertFalse(key.contains("_"),
                           "\(key) looks like a snake_case error code")
            XCTAssertFalse(key.lowercased().contains("error"),
                           "\(key) names an error, not a plain outcome")
            XCTAssertFalse(key.contains("NSError"))
            // The stale keys in the planning text are not shipping keys.
            XCTAssertFalse(key.hasPrefix("instruction.import."),
                           "\(key) is the task-text drift, not the catalogue")
            XCTAssertFalse(key.hasPrefix("instruction.permission."),
                           "\(key) is the task-text drift, not the catalogue")
            for token in errorTokens {
                XCTAssertFalse(key.contains(token),
                               "\(key) contains the error token \(token)")
            }
            for segment in key.split(separator: ".") {
                XCTAssertFalse(segment.isEmpty)
                XCTAssertTrue(segment.allSatisfy { $0.isLetter },
                              "\(key) has a non-word segment")
            }
        }
    }

    // MARK: - T-007 helpers

    private var importErrors: [InstructionImportError] {
        [
            .unreadableSource,
            .unsupportedFormat,
            .tooLong,
            .tooLarge,
            .validationTimedOut,
            .writeFailed(.stagingFailed),
            .cancelled
        ]
    }

    private var storageErrors: [InstructionStorageError] {
        [.invalidOwner, .stagingFailed, .protectionFailed,
         .commitFailed, .deleteFailed, .purgeFailed]
    }

    private var playbackFailures: [InstructionPlaybackFailure] {
        [.unsupported, .playerFailed, .interrupted, .timedOut]
    }

    private var imageFailures: [InstructionImageFailure] {
        [.rejectedFilename, .missingFile, .unreadableFile]
    }

    private var permissionProblems: [InstructionPermissionProblem] {
        [.cameraDenied, .microphoneDenied, .cameraUnavailable]
    }

    /// Every `InstructionWriteError` shape the routine seam can produce
    /// (T-013), including both media-storage directions.
    private var writeErrors: [InstructionWriteError] {
        [.ownerNotFound, .unresolvedPayload, .persistenceFailed]
            + storageErrors.map { InstructionWriteError.mediaWriteFailed($0) }
    }

    /// Every copy key the five mapping functions can return, for the
    /// catalogue and shape pins.
    private var mappedMessageKeys: Set<String> {
        var keys = Set<String>()
        for error in importErrors {
            if let key = InstructionMessageKey.forImport(error) {
                keys.insert(key)
            }
        }
        for failure in playbackFailures {
            keys.insert(InstructionMessageKey.forPlayback(failure))
        }
        for failure in imageFailures {
            keys.insert(InstructionMessageKey.forImage(failure))
        }
        for problem in permissionProblems {
            keys.insert(InstructionMessageKey.forPermission(problem))
        }
        for error in writeErrors {
            keys.insert(InstructionMessageKey.forWrite(error))
        }
        return keys
    }

    /// Devanagari (U+0900–U+097F), by scalar — no regular expression: the
    /// same grapheme-cluster caveat the shipped copy tests record.
    private func hasDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }
}
