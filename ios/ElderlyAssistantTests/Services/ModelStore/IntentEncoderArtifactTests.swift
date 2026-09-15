import XCTest
import ZIPFoundation
@testable import ElderlyAssistant

/// [T-037-a] Artifact delivery for the CoreML intent encoder: the catalog
/// entry is a spike (internal testing only), the install destination is
/// SCOPED AWAY from the whisper.cpp encoder paths, the zip checksum is
/// enforced before anything is unpacked, and the interpreter's
/// `isAvailable` follows install/delete.
///
/// T-035 §15.2 finding folded in: `installCoreMLEncoder` was Whisper-shaped
/// (destination derived from the ggml stem). The chosen resolution is the
/// scoped one — `ModelKind.intentEncoder` + the entry's own final URL — so
/// a spike encoder can never land where whisper.cpp auto-loads it.
final class IntentEncoderArtifactTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: RecordingObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-encoder-artifact-\(UUID().uuidString)")
        bus = RecordingObservabilityBus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    private func makeStore(checksumPolicy: ModelChecksumPolicy = .skip) throws -> ModelStore {
        try ModelStore(observabilityBus: bus,
                       rootDirectoryOverride: tmpRoot,
                       checksumPolicy: checksumPolicy)
    }

    /// A zip whose single top-level member is the `.mlmodelc` directory —
    /// the shape `installCoreMLEncoder` accepts (T-033's packaging).
    private func makeEncoderZip(dirName: String = "t033-encoder-int8.mlmodelc")
    throws -> (zip: URL, innerFile: String) {
        let fm = FileManager.default
        let stage = tmpRoot.appendingPathComponent("zipstage-\(UUID().uuidString)")
        let modelDir = stage.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let innerFile = "coremldata.bin"
        try Data("compiled-graph".utf8).write(to: modelDir.appendingPathComponent(innerFile))
        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("metadata.json"))
        let zipURL = tmpRoot.appendingPathComponent("encoder-\(UUID().uuidString).zip")
        // Zip the dir ITSELF: the archive's single top-level entry is the
        // model folder, which is the layout the installer expects.
        try fm.zipItem(at: modelDir, to: zipURL)
        return (zipURL, innerFile)
    }

    // MARK: Catalog

    func testCatalogEntryIsPinnedAndMarkedInternalTesting() throws {
        let entry = try XCTUnwrap(
            ModelCatalog.entry(for: ModelCatalog.intentEncoderSpike))
        XCTAssertEqual(entry.kind, .intentEncoder)
        XCTAssertEqual(entry.filename, "t033-encoder-int8.mlmodelc")
        XCTAssertEqual(entry.sizeBytes, 109_086_647)
        XCTAssertEqual(entry.sha256.count, 64, "a full SHA-256 hex digest")
        XCTAssertTrue(entry.sha256.hasPrefix("e0ff09231843"),
                      "the T-036 v0 export's measured zip hash")
        // No machine-specific path is committed, and no environment
        // variable is required: with the process environment this test runs
        // under (no override), the entry points at the app's own Documents
        // copy — `devicectl`/AirDrop is the whole handshake.
        if ProcessInfo.processInfo.environment["INTENT_ENCODER_SPIKE_ZIP"] == nil {
            XCTAssertEqual(entry.downloadURL,
                           ModelCatalog.intentEncoderSpikeDocumentsZipURL())
            XCTAssertEqual(entry.downloadURL.lastPathComponent,
                           "t033-encoder-int8-mlmodelc.zip")
        }
        XCTAssertFalse(entry.downloadURL.absoluteString.contains("/Users/"),
                       "a personal home-directory path must not be committed")
        let override = ModelCatalog.intentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "/tmp/t033-encoder-int8-mlmodelc.zip"])
        XCTAssertEqual(override.scheme, "file")
        XCTAssertEqual(override.path, "/tmp/t033-encoder-int8-mlmodelc.zip")
        // Only an EXPLICITLY blank override reaches the reserved-TLD
        // placeholder (RFC 2606 `.invalid` never resolves) — that is the
        // "internal-testing install switched off" state, not the default.
        let blanked = ModelCatalog.intentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "   "])
        XCTAssertEqual(blanked.host, "invalid.invalid")
        XCTAssertNotEqual(blanked, ModelCatalog.intentEncoderSpikeZipURL(environment: [:]))
        XCTAssertEqual(entry.dependsOn, nil)
        XCTAssertTrue(ModelKind.intentEncoder.isDirectoryArtifact)
        XCTAssertFalse(ModelKind.whisperBase.isDirectoryArtifact,
                       "the .bin kinds stay file URLs")

        // Not offered to a household, whatever picker asks.
        XCTAssertFalse(ModelCatalog.availableBrainEntries.contains { $0.id == entry.id })
        XCTAssertFalse(ModelCatalog.availableSTTEntries.contains { $0.id == entry.id })
        XCTAssertTrue(ModelCatalog.internalTestingEncoderEntries.contains { $0.id == entry.id })
    }

    /// 2026-09-14: `INTENT_ENCODER_SPIKE_ZIP` also accepts a path RELATIVE
    /// to the app's Documents directory. `devicectl` can copy the zip into
    /// the app data container's `Documents/`
    /// (`--domain-type appDataContainer --domain-identifier
    /// com.elderlyassistant.app --destination Documents/`) but never
    /// exposes the container UUID, so a tester cannot construct the
    /// absolute path the override used to require — the bare filename is
    /// the whole handshake now. Absolute values must keep their meaning.
    func testSpikeZipOverrideResolvesRelativePathsUnderDocuments() throws {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]

        // Relative (the devicectl route): resolved under Documents, not
        // against the process working directory.
        let relative = try XCTUnwrap(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "t033-encoder-int8-mlmodelc.zip"]))
        XCTAssertEqual(relative,
                       documents.appendingPathComponent("t033-encoder-int8-mlmodelc.zip"))
        XCTAssertEqual(relative.deletingLastPathComponent().path, documents.path)
        XCTAssertEqual(relative.scheme, "file")

        // Subdirectory + surrounding whitespace behave the same way.
        let nested = try XCTUnwrap(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "  staging/t033.zip  "]))
        XCTAssertEqual(nested, documents.appendingPathComponent("staging/t033.zip"))

        // Absolute: unchanged — used verbatim (whitespace trimmed only).
        let absolute = try XCTUnwrap(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "  /tmp/t033-encoder-int8-mlmodelc.zip "]))
        XCTAssertEqual(absolute.path, "/tmp/t033-encoder-int8-mlmodelc.zip")
        XCTAssertEqual(absolute.scheme, "file")

        // The picker/download entry point returns that same file URL, not
        // the reserved-TLD placeholder.
        XCTAssertEqual(
            ModelCatalog.intentEncoderSpikeZipURL(
                environment: ["INTENT_ENCODER_SPIKE_ZIP": "t033-encoder-int8-mlmodelc.zip"]),
            relative)
    }

    /// [ENCODER-ALWAYS-ON] `INTENT_ENCODER_SPIKE_ZIP` is an OVERRIDE, not a
    /// requirement: with the environment empty, BOTH the display/download
    /// URL and the installer's source resolve to the app-container
    /// `Documents/t033-encoder-int8-mlmodelc.zip`, so staging that one file
    /// is the whole setup — no environment variable, no container UUID.
    func testNoEnvironmentVariableIsNeededToResolveTheZipSource() throws {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        let expected = documents.appendingPathComponent("t033-encoder-int8-mlmodelc.zip")

        // The download/picker URL the catalog entry carries…
        XCTAssertEqual(ModelCatalog.intentEncoderSpikeZipURL(environment: [:]),
                       expected)
        // …and the source the INSTALL TRIGGER reads (the two must agree, or
        // the card would show a path that never installs).
        XCTAssertEqual(ModelCatalog.configuredIntentEncoderSpikeZipURL(environment: [:]),
                       expected)
        XCTAssertEqual(expected.lastPathComponent,
                       ModelCatalog.intentEncoderSpikeZipFilename)
        XCTAssertEqual(expected.deletingLastPathComponent().path, documents.path)
        XCTAssertEqual(expected.scheme, "file")

        // The ONLY "no source" state is an explicitly blank override (the
        // install switched off) — and it is honest about it at both seams.
        XCTAssertNil(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "   "]))
        XCTAssertNil(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "\t \n "]),
            "whitespace-only is blank, not a filename")
        XCTAssertNil(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": ""]))
    }

    /// The override still WINS over the Documents default — every value
    /// shape it already accepted keeps its meaning, and an override naming
    /// a file elsewhere never silently degrades to the default path.
    func testTheEnvironmentOverrideTakesPrecedenceOverTheDocumentsDefault() throws {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]

        let absolute = try XCTUnwrap(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "  /tmp/elsewhere.zip "]))
        XCTAssertEqual(absolute.path, "/tmp/elsewhere.zip")
        XCTAssertNotEqual(absolute, ModelCatalog.intentEncoderSpikeDocumentsZipURL())

        let nested = try XCTUnwrap(ModelCatalog.configuredIntentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "staging/t033.zip"]))
        XCTAssertEqual(nested, documents.appendingPathComponent("staging/t033.zip"))
        XCTAssertNotEqual(nested, ModelCatalog.intentEncoderSpikeDocumentsZipURL())

        // The display URL follows the same precedence.
        XCTAssertEqual(ModelCatalog.intentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "  /tmp/elsewhere.zip "]),
            absolute)
        XCTAssertEqual(ModelCatalog.intentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "staging/t033.zip"]),
            nested)
    }

    // MARK: Destination scoping (the T-035 §15.2 finding)

    func testInstallDestinationIsScopedAwayFromTheWhisperEncoderPath() throws {
        let store = try makeStore()
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.intentEncoderSpike))

        XCTAssertEqual(dest.lastPathComponent, "t033-encoder-int8.mlmodelc")
        XCTAssertEqual(dest.deletingLastPathComponent().lastPathComponent,
                       ModelKind.intentEncoder.rawValue)
        XCTAssertFalse(dest.path.contains("whisperBase"),
                       "never next to a ggml file: whisper.cpp auto-loads those")

        // Regression pin: the whisper-derived path is untouched — the
        // q5_1 stem strip still yields ggml-small-encoder.mlmodelc.
        let whisper = try XCTUnwrap(store.coreMLBundleFinalURL(
            for: ModelCatalog.whisperSmallMultilingual))
        XCTAssertEqual(whisper.lastPathComponent, "ggml-small-encoder.mlmodelc")
        XCTAssertNotEqual(whisper, dest)
    }

    // MARK: Install

    func testInstallFromZipIsCachedAndServedToTheInterpreter() throws {
        let store = try makeStore()
        let (zipURL, innerFile) = try makeEncoderZip()
        let id = ModelCatalog.intentEncoderSpike

        XCTAssertFalse(store.isCoreMLCached(id))
        let installed = try XCTUnwrap(store.installCoreMLEncoder(fromZip: zipURL, for: id))
        let dest = try XCTUnwrap(store.coreMLBundleFinalURL(for: id))

        XCTAssertEqual(installed, dest)
        XCTAssertTrue(store.isCoreMLCached(id))
        XCTAssertTrue(store.isCached(id),
                      "the directory artifact IS the cache state for this kind")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(innerFile).path))
        XCTAssertEqual(bus.events(named: "coreml_encoder_installed").count, 1)

        // Integration: the interpreter resolves availability from exactly
        // this ModelStore path (no second install mechanism).
        let interpreter = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: id,
            manifest: .t033Spike,
            tokenizer: StubIntentEncoderTokenizer(),
            config: .default)
        XCTAssertEqual(interpreter.installedModelDirectory, dest)
        XCTAssertTrue(interpreter.isAvailable)
    }

    func testFinalURLIsTheSameValueBeforeAndAfterInstall() throws {
        // Regression pin: `URL.appendingPathComponent(_:)` infers
        // `isDirectory` from the filesystem, so the SAME call used to
        // return `…mlmodelc` before an install and `…mlmodelc/` after —
        // two callers (install vs interpreter) then disagreed about the
        // same path in URL comparisons and recorded load paths.
        let store = try makeStore()
        let id = ModelCatalog.intentEncoderSpike
        let before = try XCTUnwrap(store.coreMLBundleFinalURL(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.path))

        let (zipURL, _) = try makeEncoderZip()
        let installed = try XCTUnwrap(store.installCoreMLEncoder(fromZip: zipURL, for: id))

        let after = try XCTUnwrap(store.coreMLBundleFinalURL(for: id))
        XCTAssertEqual(before, after)
        XCTAssertEqual(installed, after)
        XCTAssertTrue(after.hasDirectoryPath)
    }

    func testChecksumMismatchAbortsTheInstallAndLeavesNothingBehind() throws {
        // Strict policy (the shipped default): the fabricated zip cannot
        // match the catalog's real SHA-256, so nothing is unpacked.
        let store = try makeStore(checksumPolicy: .strict)
        let (zipURL, _) = try makeEncoderZip()
        let id = ModelCatalog.intentEncoderSpike

        XCTAssertThrowsError(
            try store.installCoreMLEncoder(fromZip: zipURL, for: id)
        ) { error in
            guard case ModelStoreError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }

        XCTAssertFalse(store.isCoreMLCached(id), "a bad artifact must not become available")
        XCTAssertEqual(bus.events(named: "coreml_encoder_checksum_mismatch").count, 1)
        XCTAssertFalse(bus.contains("coreml_encoder_installed"))
        let dest = try XCTUnwrap(store.coreMLBundleFinalURL(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testZipWithoutAnMlmodelcDirectoryIsRejected() throws {
        let store = try makeStore()
        let fm = FileManager.default
        let stage = tmpRoot.appendingPathComponent("loose-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let loose = stage.appendingPathComponent("weights.bin")
        try Data("not-coreml".utf8).write(to: loose)
        let zipURL = tmpRoot.appendingPathComponent("loose-\(UUID().uuidString).zip")
        try fm.zipItem(at: loose, to: zipURL)

        XCTAssertThrowsError(
            try store.installCoreMLEncoder(fromZip: zipURL, for: ModelCatalog.intentEncoderSpike)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ModelStore")
            XCTAssertEqual(nsError.code, 6)
        }
        XCTAssertFalse(store.isCoreMLCached(ModelCatalog.intentEncoderSpike))
    }

    func testDeleteRemovesTheInstalledEncoderDirectory() throws {
        let store = try makeStore()
        let (zipURL, _) = try makeEncoderZip()
        let id = ModelCatalog.intentEncoderSpike
        _ = try store.installCoreMLEncoder(fromZip: zipURL, for: id)
        XCTAssertTrue(store.isCoreMLCached(id))

        try store.delete(id)

        XCTAssertFalse(store.isCoreMLCached(id))
        XCTAssertFalse(store.isCached(id))
        let interpreter = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: id,
            manifest: .t033Spike,
            tokenizer: StubIntentEncoderTokenizer(),
            config: .default)
        XCTAssertFalse(interpreter.isAvailable,
                       "deleting the artifact takes the encoder out of service")
    }

    func testStaleWhisperEncoderSweepDoesNotTouchTheIntentEncoder() throws {
        // `removeStaleCoreMLBundles` deletes whisper-derived dirs; the scoped
        // intent encoder directory must survive it (and vice versa: this is
        // the guard against the install-path collision T-035 flagged).
        let store = try makeStore()
        let (zipURL, _) = try makeEncoderZip()
        let id = ModelCatalog.intentEncoderSpike
        _ = try store.installCoreMLEncoder(fromZip: zipURL, for: id)

        store.removeStaleCoreMLBundles()

        XCTAssertTrue(store.isCoreMLCached(id))
    }
}
