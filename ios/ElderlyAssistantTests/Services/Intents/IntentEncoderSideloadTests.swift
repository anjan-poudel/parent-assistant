import XCTest
import ZIPFoundation
@testable import ElderlyAssistant

/// [T-036 SIDELOAD] The TRAINED intent-encoder artifact as an internal-
/// testing sideload: the pin is the artifact's own zip digest, the entry
/// is invisible to every household surface, the manifest carries the
/// artifact's OWN label order + fitted temperature, the resolver is a
/// strict superset of the shipped catalog, and the gated installer fetches
/// (or takes a staged copy) into the ModelStore the interpreter reads.
///
/// INTERNAL TESTING — publish blocked on the 8,000-row calibration corpus
/// (T-035/T-038).
final class IntentEncoderSideloadTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: RecordingObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-encoder-sideload-\(UUID().uuidString)")
        bus = RecordingObservabilityBus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    /// The store the app builds for the gated encoder path: the shipped
    /// catalog PLUS the sideload resolver. `.skip` checksums let a tiny
    /// fabricated zip stand in for the 109 MB artifact.
    private func makeStore(
        checksumPolicy: ModelChecksumPolicy = .skip
    ) throws -> ModelStore {
        try ModelStore(observabilityBus: bus,
                       rootDirectoryOverride: tmpRoot,
                       checksumPolicy: checksumPolicy,
                       entryProvider: ModelCatalog.entryIncludingInternalSideload(for:))
    }

    /// A zip shaped like the T-036 export: one top-level
    /// `<export-name>.mlmodelc` directory (the export's own name — the
    /// store installs it under the ENTRY's filename).
    private func makeEncoderZip(
        dirName: String = "t033-encoder-int8.mlmodelc"
    ) throws -> (zip: URL, innerFile: String) {
        let fm = FileManager.default
        let stage = tmpRoot.appendingPathComponent("zipstage-\(UUID().uuidString)")
        let modelDir = stage.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let innerFile = "coredata.bin"
        try Data("compiled-graph".utf8).write(to: modelDir.appendingPathComponent(innerFile))
        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("metadata.json"))
        let zipURL = tmpRoot.appendingPathComponent("sideload-\(UUID().uuidString).zip")
        try fm.zipItem(at: modelDir, to: zipURL)
        return (zipURL, innerFile)
    }

    private func waitUntil(_ predicate: () -> Bool,
                           _ message: String,
                           timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !predicate() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(predicate(), message)
    }

    // MARK: Pin

    func testSideloadEntryPinsTheTrainedArtifactAndIsNotOfferedToHouseholds() throws {
        let entry = try XCTUnwrap(
            ModelCatalog.entryIncludingInternalSideload(
                for: IntentEncoderSideload.modelID))
        XCTAssertEqual(entry.id, ModelID("intent-encoder-t036-noised6b-int8"))
        XCTAssertEqual(entry.kind, .intentEncoder)
        XCTAssertEqual(entry.filename, "t033-encoder-t036-noised6b-int8.mlmodelc")
        // The artifact's own archive facts (verified against the server
        // copy and the Mac-side coreml-v3 build during the sideload).
        XCTAssertEqual(entry.sizeBytes, 109_079_441)
        XCTAssertEqual(entry.sha256,
                       "d8f549ecb2e37b44bbcf21a243cbfc00f917d47f7f4e7187d547f51168afbcdc")
        XCTAssertEqual(entry.sha256.count, 64, "a full SHA-256 hex digest")
        XCTAssertEqual(entry.dependsOn, nil)
        XCTAssertTrue(ModelKind.intentEncoder.isDirectoryArtifact)

        // A DIFFERENT artifact from the T-036 v0 baseline the shipped
        // catalog still pins — different id, digest and install directory,
        // so neither can masquerade as the other on disk.
        let spike = try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.intentEncoderSpike))
        XCTAssertNotEqual(entry.id, spike.id)
        XCTAssertNotEqual(entry.sha256, spike.sha256)
        XCTAssertNotEqual(entry.filename, spike.filename)

        // Not offered to a household, whatever picker asks.
        XCTAssertFalse(ModelCatalog.availableBrainEntries.contains { $0.id == entry.id })
        XCTAssertFalse(ModelCatalog.availableSTTEntries.contains { $0.id == entry.id })
        XCTAssertFalse(ModelCatalog.internalTestingEncoderEntries.contains { $0.id == entry.id },
                       "the shipped catalog list stays the spike pin")
        XCTAssertTrue(ModelCatalog.internalSideloadEncoderEntries.contains { $0.id == entry.id })
    }

    func testSideloadSourceIsTheLanWebRootAndOverridable() throws {
        let lan = try XCTUnwrap(IntentEncoderSideload.resolvedZipURL(environment: [:]))
        XCTAssertEqual(lan.scheme, "http")
        XCTAssertEqual(lan.host, "192.168.1.117")
        XCTAssertEqual(lan.port, 8765)
        XCTAssertEqual(lan.path,
                       "/encoder-dev/t033-encoder-t036-noised6b-int8-mlmodelc.zip")
        // The committed URL is device-reachable (unlike the spike entry's
        // reserved-TLD placeholder) but still not a personal path.
        let entry = try XCTUnwrap(
            ModelCatalog.entryIncludingInternalSideload(
                for: IntentEncoderSideload.modelID))
        XCTAssertNotEqual(entry.downloadURL.host, "invalid.invalid")
        XCTAssertFalse(entry.downloadURL.absoluteString.contains("/Users/"))

        // A staged copy: bare path and file URL both resolve.
        let path = "/tmp/t033-encoder-t036-noised6b-int8-mlmodelc.zip"
        XCTAssertEqual(
            IntentEncoderSideload.resolvedZipURL(
                environment: ["INTENT_ENCODER_SIDELOAD_URL": path])?.path,
            path)
        let file = "file:///tmp/staged.zip"
        XCTAssertEqual(
            IntentEncoderSideload.resolvedZipURL(
                environment: ["INTENT_ENCODER_SIDELOAD_URL": file])?.absoluteString,
            file)
        // A BLANK override disables the sideload (no placeholder, no
        // network) — the same convention as the spike entry's blank
        // `INTENT_ENCODER_SPIKE_ZIP`.
        XCTAssertNil(IntentEncoderSideload.resolvedZipURL(
            environment: ["INTENT_ENCODER_SIDELOAD_URL": "   "]))
    }

    // MARK: Resolver

    func testResolverIsASupersetThatKeepsTheShippedCatalogAuthoritative() throws {
        // Every shipped id resolves to EXACTLY its shipped entry
        // (`ModelCatalogEntry` is not Equatable, so compare the facts).
        for id in [ModelCatalog.whisperSmallMultilingual,
                   ModelCatalog.intentQwen4BSlotCanon,
                   ModelCatalog.intentEncoderSpike] {
            let resolved = ModelCatalog.entryIncludingInternalSideload(for: id)
            let shipped = try XCTUnwrap(ModelCatalog.entry(for: id))
            XCTAssertEqual(resolved?.id, shipped.id)
            XCTAssertEqual(resolved?.kind, shipped.kind)
            XCTAssertEqual(resolved?.filename, shipped.filename)
            XCTAssertEqual(resolved?.sha256, shipped.sha256)
            XCTAssertEqual(resolved?.sizeBytes, shipped.sizeBytes)
            XCTAssertEqual(resolved?.downloadURL, shipped.downloadURL)
        }
        // The sideload id is NOT in the shipped catalog...
        XCTAssertNil(ModelCatalog.entry(for: IntentEncoderSideload.modelID))
        XCTAssertFalse(ModelCatalog.all.contains { $0.id == IntentEncoderSideload.modelID })
        // ...and the resolver is the only thing that knows it.
        XCTAssertEqual(
            ModelCatalog.entryIncludingInternalSideload(
                for: IntentEncoderSideload.modelID)?.id,
            IntentEncoderSideload.modelID)
        XCTAssertNil(ModelCatalog.entryIncludingInternalSideload(
            for: ModelID("no-such-model")))
    }

    // MARK: Manifest

    func testManifestCarriesTheArtifactsOwnLabelSetsAndCalibration() throws {
        let manifest = IntentEncoderSideload.manifest
        // Verbatim from the run's `train/artifact/meta.json` — order is
        // the head index order, so a re-sort would mislabel outputs.
        XCTAssertEqual(manifest.intents, [
            "ack_med", "call", "emergency", "set_reminder", "health_query",
            "music", "send_message", "guide", "create_calendar_event",
            "suggest_video", "query", "none"
        ])
        XCTAssertEqual(manifest.tags, [
            "O", "B-contact", "I-contact", "B-time", "I-time",
            "B-medication", "I-medication", "B-message", "I-message",
            "B-topic", "I-topic", "B-app", "I-app"
        ])
        XCTAssertEqual(manifest.maxSequenceLength, 64)
        XCTAssertEqual(manifest.calibrationTemperature, 1.412564, accuracy: 1e-9)
        // The extra labels the baseline manifest cannot express decode to
        // real schema-v2 slots (not `.unknown`, which abstains).
        XCTAssertEqual(manifest.decode(tag: "B-app"), .slot(.app))
        XCTAssertEqual(manifest.decode(tag: "I-medication"), .slot(.medication))
        XCTAssertEqual(manifest.decode(tag: "B-topic"), .slot(.topic))
        XCTAssertEqual(manifest.decode(tag: "O"), .outside)
        // Identity differs from the baseline manifest — the mismatch is
        // detectable in the event trail instead of silent.
        XCTAssertNotEqual(manifest, IntentEncoderManifest.t033Spike)
        XCTAssertNotEqual(manifest.intents.count,
                          IntentEncoderManifest.t033Spike.intents.count)
    }

    // MARK: Installer

    func testInstallIsDisabledWithoutTheCompileTimeGate() throws {
        let store = try makeStore()
        let installer = IntentEncoderSideloadInstaller(
            modelStore: store, observabilityBus: bus,
            downloader: { _, _ in XCTFail("a gated-off build must not fetch") })

        XCTAssertEqual(installer.installIfNeeded(isGateEnabled: false), .disabled)

        XCTAssertTrue(bus.eventTypes.isEmpty, "the shipped default is silent")
        XCTAssertFalse(store.isCoreMLCached(IntentEncoderSideload.modelID))
    }

    func testBlankOverrideMeansNoSourceAndNoFetch() throws {
        let store = try makeStore()
        let installer = IntentEncoderSideloadInstaller(
            modelStore: store, observabilityBus: bus,
            downloader: { _, _ in XCTFail("no source configured — nothing to fetch") })

        XCTAssertEqual(
            installer.installIfNeeded(
                isGateEnabled: true,
                environment: ["INTENT_ENCODER_SIDELOAD_URL": "  "]),
            .notConfigured)
        XCTAssertEqual(bus.events(named: "encoder_sideload_skipped").count, 1)
        XCTAssertFalse(store.isCoreMLCached(IntentEncoderSideload.modelID))
    }

    func testFetchInstallsTheZipAndTheInterpreterServesIt() throws {
        let store = try makeStore()
        let (zipURL, innerFile) = try makeEncoderZip()
        let installer = IntentEncoderSideloadInstaller(
            modelStore: store, observabilityBus: bus,
            downloader: { url, completion in
                // The installer fetches the LAN URL; the transport hands
                // back a local file, exactly like URLSession's temp file.
                XCTAssertEqual(url, IntentEncoderSideload.lanZipURL)
                completion(.success(zipURL))
            })

        XCTAssertFalse(store.isCoreMLCached(IntentEncoderSideload.modelID))
        XCTAssertEqual(installer.installIfNeeded(isGateEnabled: true), .started)

        waitUntil({ store.isCoreMLCached(IntentEncoderSideload.modelID) },
                  "the fetched zip must land in the ModelStore")
        XCTAssertEqual(bus.events(named: "encoder_sideload_started").count, 1)
        XCTAssertEqual(bus.events(named: "encoder_sideload_installed").count, 1)
        XCTAssertFalse(bus.contains("encoder_sideload_failed"))

        // The installed directory is the ENTRY's name (the export's own
        // name inside the zip is different) and it is scoped to the
        // intentEncoder folder — never a whisper.cpp auto-load path.
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: IntentEncoderSideload.modelID))
        XCTAssertEqual(dest.lastPathComponent,
                       IntentEncoderSideload.installedDirectoryName)
        XCTAssertEqual(dest.deletingLastPathComponent().lastPathComponent,
                       ModelKind.intentEncoder.rawValue)
        XCTAssertFalse(dest.path.contains("whisperBase"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(innerFile).path))

        // Integration: the gated interpreter resolves availability from
        // exactly this path, with the artifact's own manifest.
        let interpreter = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: IntentEncoderSideload.modelID,
            manifest: IntentEncoderSideload.manifest,
            tokenizer: StubIntentEncoderTokenizer(),
            config: .default)
        XCTAssertEqual(interpreter.installedModelDirectory, dest)
        XCTAssertTrue(interpreter.isAvailable)
        XCTAssertEqual(interpreter.manifestIdentity.id, "t036-noised6b-minilm-int8")
        XCTAssertEqual(interpreter.manifestIdentity.version, "t036-internal-1")

        // A second trigger is a no-op, not a re-download.
        XCTAssertEqual(installer.installIfNeeded(isGateEnabled: true),
                       .alreadyInstalled)
    }

    func testStagedFileOverrideInstallsWithoutAnyTransport() throws {
        let store = try makeStore()
        let (zipURL, innerFile) = try makeEncoderZip()

        let installer = IntentEncoderSideloadInstaller(
            modelStore: store, observabilityBus: bus,
            downloader: { _, _ in XCTFail("a staged file needs no transport") })

        XCTAssertEqual(
            installer.installIfNeeded(
                isGateEnabled: true,
                environment: ["INTENT_ENCODER_SIDELOAD_URL": zipURL.path]),
            .started)

        waitUntil({ store.isCoreMLCached(IntentEncoderSideload.modelID) },
                  "the staged zip must install")
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: IntentEncoderSideload.modelID))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(innerFile).path))
        XCTAssertEqual(bus.events(named: "encoder_sideload_started").first?
            .metadata["source"], "file")
    }

    func testUnreachableSourceFailsLoudlyAndLeavesNothingBehind() throws {
        let store = try makeStore()
        let installer = IntentEncoderSideloadInstaller(
            modelStore: store, observabilityBus: bus,
            downloader: { _, completion in
                completion(.failure(URLError(.cannotConnectToHost)))
            })

        XCTAssertEqual(installer.installIfNeeded(isGateEnabled: true), .started)

        waitUntil({ !self.bus.events(named: "encoder_sideload_failed").isEmpty },
                  "an unreachable LAN must not fail silently")
        let failure = try XCTUnwrap(
            bus.events(named: "encoder_sideload_failed").first)
        XCTAssertEqual(failure.outcome, "failure")
        XCTAssertEqual(failure.errorCode, "unreachable")
        XCTAssertEqual(failure.metadata["model_id"],
                       IntentEncoderSideload.modelID.rawValue)
        XCTAssertEqual(failure.metadata["run"], IntentEncoderSideload.runName)
        XCTAssertFalse(bus.contains("encoder_sideload_installed"))
        XCTAssertFalse(store.isCoreMLCached(IntentEncoderSideload.modelID))

        // A retry is allowed once the failed attempt is over (the in-flight
        // flag clears just after the completion handler returns).
        var retried = IntentEncoderSideloadDecision.inFlight
        let retryDeadline = Date().addingTimeInterval(5)
        while Date() < retryDeadline {
            retried = installer.installIfNeeded(isGateEnabled: true)
            if retried == .started { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(retried, .started,
                       "a failed attempt must not wedge the sideload on `inFlight`")
        waitUntil({ self.bus.events(named: "encoder_sideload_failed").count == 2 },
                  "the second attempt must run")
    }

    func testSecondTriggerWhileFetchingReportsInFlight() throws {
        let store = try makeStore()
        let gate = DispatchSemaphore(value: 0)
        let installer = IntentEncoderSideloadInstaller(
            modelStore: store, observabilityBus: bus,
            downloader: { _, completion in
                // Hold the fetch open so the second trigger observes the
                // first one still running.
                _ = gate.wait(timeout: .now() + 10)
                completion(.failure(URLError(.timedOut)))
            })

        XCTAssertEqual(installer.installIfNeeded(isGateEnabled: true), .started)
        XCTAssertEqual(installer.installIfNeeded(isGateEnabled: true), .inFlight)
        gate.signal()
        waitUntil({ !self.bus.events(named: "encoder_sideload_failed").isEmpty },
                  "the held fetch must finish")
    }

    func testChecksumMismatchIsRejectedUnderTheStrictPolicy() throws {
        // The app's real policy: the fabricated zip cannot match the
        // artifact's pin, so nothing is unpacked and the failure is typed.
        let store = try makeStore(checksumPolicy: .strict)
        let (zipURL, _) = try makeEncoderZip()
        let installer = IntentEncoderSideloadInstaller(
            modelStore: store, observabilityBus: bus,
            downloader: { _, completion in completion(.success(zipURL)) })

        XCTAssertEqual(installer.installIfNeeded(isGateEnabled: true), .started)

        waitUntil({ self.bus.contains("encoder_sideload_failed") },
                  "a substituted archive must fail, not install")
        XCTAssertEqual(
            bus.events(named: "encoder_sideload_failed").first?.errorCode,
            "checksum")
        XCTAssertEqual(bus.events(named: "coreml_encoder_checksum_mismatch").count, 1)
        XCTAssertFalse(bus.contains("encoder_sideload_installed"))
        XCTAssertFalse(store.isCoreMLCached(IntentEncoderSideload.modelID))
    }
}
