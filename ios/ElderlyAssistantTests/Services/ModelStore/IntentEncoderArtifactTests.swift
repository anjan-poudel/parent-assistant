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
        XCTAssertEqual(entry.sizeBytes, 109_075_268)
        XCTAssertEqual(entry.sha256.count, 64, "a full SHA-256 hex digest")
        XCTAssertTrue(entry.sha256.hasPrefix("6056ba41ba37"),
                      "the T-033 C3 export's measured zip hash")
        // No machine-specific path is committed. The default is a
        // reserved-TLD placeholder (RFC 2606 `.invalid` never resolves);
        // an internal tester points the entry at their own copy via the
        // environment override.
        XCTAssertEqual(entry.downloadURL.host, "invalid.invalid",
                       "non-routable placeholder — never a device-reachable URL")
        XCTAssertEqual(entry.downloadURL.path,
                       "/t033-spike/t033-encoder-int8-mlmodelc.zip")
        XCTAssertFalse(entry.downloadURL.absoluteString.contains("/Users/"),
                       "a personal home-directory path must not be committed")
        let override = ModelCatalog.intentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "/tmp/t033-encoder-int8-mlmodelc.zip"])
        XCTAssertEqual(override.scheme, "file")
        XCTAssertEqual(override.path, "/tmp/t033-encoder-int8-mlmodelc.zip")
        let placeholder = ModelCatalog.intentEncoderSpikeZipURL(environment: [:])
        XCTAssertEqual(ModelCatalog.intentEncoderSpikeZipURL(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "   "]),
            placeholder,
            "a blank override falls back to the placeholder")
        XCTAssertEqual(placeholder.host, "invalid.invalid")
        XCTAssertEqual(entry.dependsOn, nil)
        XCTAssertTrue(ModelKind.intentEncoder.isDirectoryArtifact)
        XCTAssertFalse(ModelKind.whisperBase.isDirectoryArtifact,
                       "the .bin kinds stay file URLs")

        // Not offered to a household, whatever picker asks.
        XCTAssertFalse(ModelCatalog.availableBrainEntries.contains { $0.id == entry.id })
        XCTAssertFalse(ModelCatalog.availableSTTEntries.contains { $0.id == entry.id })
        XCTAssertTrue(ModelCatalog.internalTestingEncoderEntries.contains { $0.id == entry.id })
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
