import XCTest
@testable import ElderlyAssistant

/// Unit tests for the sherpa-onnx wake-word engine (voice-personalisation
/// P0 slice A) — honest unavailability, model-file resolution, and the
/// ModelStore kws directory-install path. (The pure selection decision
/// table is covered in WakeWordConfigTests.)
///
/// SAFETY INVARIANT: no test may hand a fake "complete" model directory
/// (garbage .onnx bytes) to `SherpaKWSWakeWordEngine(...)`/`attempt(...)`
/// with a directory that resolves — sherpa's C++ runtime can abort the
/// whole test host on unloadable models. Every test that reaches real
/// engine construction is gated on the REAL bundled model directory
/// (fetched by tools/fetch-kws-model.sh) and skips when it is absent.
final class SherpaKWSWakeWordEngineTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ModelStore!
    private var bus: MockObservabilityBus!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kws-engine-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private static var kwsEntry: ModelCatalogEntry {
        ModelCatalog.entry(for: ModelCatalog.sherpaKWSGigaSpeech)!
    }

    // MARK: - attempt() honest unavailability (never reaches C init)

    func testAttemptReturnsNilWithModelMissingEventWhenNothingInstalled() {
        // Empty ModelStore + bundle without a kws directory: both
        // resolution paths come up empty — nil engine, honest event.
        let bundle = makeEmptyFakeBundle()

        let engine = SherpaKWSWakeWordEngine.attempt(modelStore: store,
                                                     bundle: bundle,
                                                     observabilityBus: bus)

        XCTAssertNil(engine)
        let event = bus.emittedEvents.last {
            $0.component == "wake_word" && $0.eventType == "kws_engine_unavailable"
        }
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.outcome ?? "", "failure")
        XCTAssertEqual(event?.errorCode ?? "", "model_missing")
        XCTAssertNil(event?.metadata["missing"],
                     "no file name to report when the whole directory is absent")
    }

    func testAttemptInstallsFromBundleThenReportsMissingFile() throws {
        // Bundle HAS the model directory but it is incomplete (only
        // tokens.txt): the store install is a pure copy and succeeds, then
        // file validation names the missing encoder — nil engine, honest
        // event. (The directory never reaches sherpa, so garbage bytes
        // cannot be loaded.)
        let bundle = try makeFakeBundle(files: ["tokens.txt"])

        let engine = SherpaKWSWakeWordEngine.attempt(modelStore: store,
                                                     bundle: bundle,
                                                     observabilityBus: bus)

        XCTAssertNil(engine)
        XCTAssertTrue(store.isCached(ModelCatalog.sherpaKWSGigaSpeech),
                      "the incomplete model must still have been installed "
                      + "to the managed directory (reporting happens there)")
        let event = bus.emittedEvents.last {
            $0.component == "wake_word" && $0.eventType == "kws_engine_unavailable"
        }
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.errorCode ?? "", "missing_file")
        XCTAssertEqual(event?.metadata["missing"] ?? "", "encoder-*.int8.onnx")
    }

    func testAttemptRejectsEmptyKeywordsFileBeforeAnyCInit() throws {
        // An EMPTY keywords.txt would build a spotter that never fires — a
        // silent stub. The engine rejects it in pure Swift (file read)
        // BEFORE any sherpa call, so this test is host-safe even though
        // every required file exists.
        let bundle = try makeFakeBundle(files: [
            "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            "decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            "tokens.txt",
            "keywords.txt", // written empty by the helper
        ])

        let engine = SherpaKWSWakeWordEngine.attempt(modelStore: store,
                                                     bundle: bundle,
                                                     observabilityBus: bus)

        XCTAssertNil(engine)
        let event = bus.emittedEvents.last {
            $0.component == "wake_word" && $0.eventType == "kws_engine_init_failed"
        }
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.errorCode ?? "", "empty_keywords")
    }

    func testAttemptWithoutStoreFallsBackToBundleDirectory() throws {
        // No ModelStore injected (the static selection seam): the engine
        // must look straight into the bundle's kws/ directory, and report
        // model_missing when it is absent there too.
        let bundle = makeEmptyFakeBundle()

        let engine = SherpaKWSWakeWordEngine.attempt(bundle: bundle,
                                                     observabilityBus: bus)

        XCTAssertNil(engine)
        let event = bus.emittedEvents.last { $0.eventType == "kws_engine_unavailable" }
        XCTAssertEqual(event?.errorCode ?? "", "model_missing")
    }

    // MARK: - Model-file resolution (pure file system)

    func testResolveFailsWhenPathIsNotADirectory() throws {
        let file = tempRoot.appendingPathComponent("not-a-dir")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        guard case .failure(let reason) = SherpaKWSModelFiles.resolve(in: file) else {
            return XCTFail("expected failure for a non-directory path")
        }
        guard case .modelDirectoryMissing = reason else {
            return XCTFail("expected .modelDirectoryMissing, got \(reason)")
        }
    }

    func testResolveNamesEachMissingRequiredFileInOrder() throws {
        let dir = tempRoot.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "tokens".write(to: dir.appendingPathComponent("tokens.txt"),
                           atomically: true, encoding: .utf8)

        guard case .failure(let reason) = SherpaKWSModelFiles.resolve(in: dir) else {
            return XCTFail("expected failure for a directory with only tokens.txt")
        }
        guard case .missingRequiredFile(let name) = reason else {
            return XCTFail("expected .missingRequiredFile, got \(reason)")
        }
        XCTAssertEqual(name, "encoder-*.int8.onnx")
    }

    func testResolveFailsWhenKeywordsFileMissing() throws {
        let dir = tempRoot.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                     "decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                     "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                     "tokens.txt"] {
            try "x".write(to: dir.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
        }

        guard case .failure(let reason) = SherpaKWSModelFiles.resolve(in: dir) else {
            return XCTFail("expected failure without keywords.txt")
        }
        guard case .missingRequiredFile(let name) = reason else {
            return XCTFail("expected .missingRequiredFile, got \(reason)")
        }
        XCTAssertEqual(name, "keywords.txt")
    }

    func testResolveSucceedsWithInt8TrioAndTextFiles() throws {
        let dir = tempRoot.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "enc".write(to: dir.appendingPathComponent("encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx"),
                        atomically: true, encoding: .utf8)
        try "dec".write(to: dir.appendingPathComponent("decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx"),
                        atomically: true, encoding: .utf8)
        try "join".write(to: dir.appendingPathComponent("joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx"),
                         atomically: true, encoding: .utf8)
        try "tokens".write(to: dir.appendingPathComponent("tokens.txt"),
                           atomically: true, encoding: .utf8)
        try "▁YEAH ▁K AN CH H I".write(to: dir.appendingPathComponent("keywords.txt"),
                                       atomically: true, encoding: .utf8)
        // The fp32 twins must NOT confuse resolution.
        try "enc".write(to: dir.appendingPathComponent("encoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
                        atomically: true, encoding: .utf8)

        guard case .success(let files) = SherpaKWSModelFiles.resolve(in: dir) else {
            return XCTFail("expected success for a complete sherpa layout")
        }
        XCTAssertEqual(files.encoder.lastPathComponent,
                       "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx")
        XCTAssertEqual(files.decoder.lastPathComponent,
                       "decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx")
        XCTAssertEqual(files.joiner.lastPathComponent,
                       "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx")
        XCTAssertEqual(files.tokens.lastPathComponent, "tokens.txt")
        XCTAssertEqual(files.keywords.lastPathComponent, "keywords.txt")
    }

    func testBundledDirectoryLookupHonorsTheKwsSubdirectory() throws {
        let bundle = try makeFakeBundle(files: ["x"])
        let url = SherpaKWSModelFile.bundledDirectory(in: bundle)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, Self.kwsEntry.bundledResourceName)

        XCTAssertNil(SherpaKWSModelFile.bundledDirectory(in: makeEmptyFakeBundle()))
    }

    // MARK: - ModelStore kws directory install (mirror of TTSVoiceInstallTests)

    func testMissingKwsModelIsNotCached() {
        XCTAssertNil(store.kwsModelDirectory(for: ModelCatalog.sherpaKWSGigaSpeech))
        XCTAssertFalse(store.isCached(ModelCatalog.sherpaKWSGigaSpeech))
    }

    func testBundledKwsModelInstallsAndBecomesCached() throws {
        let bundle = try makeFakeBundle(files: ["README.md"])

        let installed = store.installBundledKWSModel(for: ModelCatalog.sherpaKWSGigaSpeech,
                                                     bundle: bundle)

        XCTAssertNotNil(installed)
        XCTAssertNotNil(store.kwsModelDirectory(for: ModelCatalog.sherpaKWSGigaSpeech))
        XCTAssertTrue(store.isCached(ModelCatalog.sherpaKWSGigaSpeech))
        // Idempotent: second install returns the same directory and does
        // not re-copy (bundle dirs can be large; the managed copy is the
        // durable one).
        XCTAssertEqual(store.installBundledKWSModel(for: ModelCatalog.sherpaKWSGigaSpeech,
                                                    bundle: bundle), installed)
        let files = try FileManager.default
            .contentsOfDirectory(atPath: installed!.path)
        XCTAssertEqual(files, ["README.md"])
    }

    func testNonKwsModelIsNotAffectedByKwsPath() {
        XCTAssertFalse(store.isCached(ModelCatalog.whisperMediumFinetunedNepali))
        XCTAssertNil(store.kwsModelDirectory(for: ModelCatalog.whisperMediumFinetunedNepali))
    }

    func testInstallReturnsNilWhenBundleHasNoKwsDirectory() {
        let bundle = makeEmptyFakeBundle()
        XCTAssertNil(store.installBundledKWSModel(for: ModelCatalog.sherpaKWSGigaSpeech,
                                                  bundle: bundle))
        XCTAssertFalse(store.isCached(ModelCatalog.sherpaKWSGigaSpeech))
    }

    // MARK: - Live smoke tests (real bundled model; skip on fresh clones)

    /// The operative keywords contract: sherpa's EncodeKeywords requires
    /// every space-separated token of every line to exist in tokens.txt
    /// (first whitespace field per line) — an OOV token fails spotter
    /// creation at runtime, so the bundled file must satisfy this purely
    /// textually. Fetch-script generated; runtime-editable by design, so
    /// the test asserts the contract, not an exact line.
    func testBundledKeywordsFileTokensAllExistInTokensTxt() throws {
        guard let dir = SherpaKWSModelFile.bundledDirectory() else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        let keywords = try String(contentsOf: dir.appendingPathComponent("keywords.txt"),
                                  encoding: .utf8)
        let lines = keywords.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1,
                       "the shipped file carries exactly the one wake phrase")
        let tokens = lines[0].split(separator: " ").map(String.init)
        XCTAssertFalse(tokens.isEmpty)

        let vocab = try Set(
            String(contentsOf: dir.appendingPathComponent("tokens.txt"),
                   encoding: .utf8)
                .split(separator: "\n")
                .compactMap { $0.split(separator: " ").first }
                .map(String.init)
        )
        for token in tokens {
            XCTAssertTrue(vocab.contains(token),
                          "keyword token '\(token)' is not in the model's "
                          + "tokens.txt — sherpa would refuse the file at "
                          + "init (OOV in EncodeBase)")
        }
    }

    /// End-to-end construction against the REAL model: the only unit-test
    /// path that may load ONNX (see the class doc's safety invariant).
    func testAttemptBuildsLiveEngineAgainstRealBundledModel() throws {
        guard SherpaKWSModelFile.bundledDirectory() != nil else {
            throw XCTSkip("kws model not bundled — run tools/fetch-kws-model.sh")
        }
        let engine = SherpaKWSWakeWordEngine.attempt(observabilityBus: bus)

        XCTAssertNotNil(engine, "real bundled model must produce a live engine")
        XCTAssertEqual(engine?.requiredSampleRate ?? 0, 16_000)
        XCTAssertEqual(engine?.frameLength ?? 0, 512)
        XCTAssertNil(engine?.onDetection)
        XCTAssertNoThrow(try engine?.start())
        engine?.stop()
        // A 512-sample silence frame must be harmless (no crash, no fire).
        engine?.process([Int16](repeating: 0, count: 512))
        let ready = bus.emittedEvents.last { $0.eventType == "kws_engine_ready" }
        XCTAssertEqual(ready?.outcome ?? "", "success")
    }

    // MARK: - Test doubles

    /// Bundle root → kws/<bundledResourceName>/<files...> — mirrors the
    /// real project.yml blue-folder layout and TTSVoiceInstallTests.
    private func makeFakeBundle(files: [String]) throws -> Bundle {
        let bundleRoot = tempRoot.appendingPathComponent("fake.bundle")
        let modelDir = bundleRoot
            .appendingPathComponent("kws", isDirectory: true)
            .appendingPathComponent(Self.kwsEntry.bundledResourceName!,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir,
                                                withIntermediateDirectories: true)
        for file in files {
            // keywords.txt is deliberately written EMPTY — the
            // empty-keywords rejection test relies on it (every other
            // file just needs to exist).
            let contents = file == "keywords.txt" ? "" : "x"
            try contents.write(to: modelDir.appendingPathComponent(file),
                               atomically: true, encoding: .utf8)
        }
        return Bundle(url: bundleRoot)!
    }

    private func makeEmptyFakeBundle() -> Bundle {
        let root = tempRoot.appendingPathComponent("empty.bundle")
        try? FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        return Bundle(url: root)!
    }
}
