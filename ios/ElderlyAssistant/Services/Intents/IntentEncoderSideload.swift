import Foundation

/// [T-036 SIDELOAD] INTERNAL TESTING — publish blocked on the 8,000-row
/// calibration corpus (T-035/T-038).
///
/// The TRAINED intent-encoder artifact, delivered to a DEVICE for internal
/// on-device testing over the home LAN. This is the artifact-side sibling
/// of `IntentEncoderFeature`/`IntentEncoderWiring` (the runtime gate) and
/// deliberately lives OUTSIDE `ModelCatalog.swift`:
///
///  - the shipped catalog keeps its own pin for the T-036 v0 baseline
///    (`ModelCatalog.intentEncoderSpike`, still resolvable and still
///    covered by its tests), and
///  - the entry below is a SUPERSET added by resolver
///    (`ModelCatalog.entryIncludingInternalSideload(for:)`), never a
///    mutation of the shipped list. Every shipped id resolves exactly as
///    before; this one id resolves ONLY where the internal-testing path
///    asks for it.
///
/// ## What is sideloaded
///
/// The T-036 full-run int8 CoreML export:
///
///  - run `t036-full-0.1.0-internal-noised6b-topup-20260914-071945`
///  - checkpoint sha256 prefix `0bd6bafb` (the run's `gates` block; the
///    same digest is `artifact_digest` in the artifact's `meta.json`)
///  - `coreml/t033-encoder-int8-mlmodelc.zip` — 109,079,441 bytes,
///    sha256 `d8f549ec…68afbcdc`, one top-level
///    `t033-encoder-int8.mlmodelc` directory (the export's own name; the
///    store installs it under THIS entry's `filename`, see below)
///  - int8-quantized mlprogram, `computeUnits = .all`; the export report
///    measured intent agreement 1.0 / slot-tag agreement 0.9971 against
///    the fp32 model over 189 rows, p50 18.4 ms (x86 CPU_ONLY proxy —
///    device-class latency is UNMEASURED)
///
/// Provenance was checked end-to-end before pinning: the zip on the server
/// and the Mac-side `coreml-v3` build hash identically, and the artifact
/// `model.pt` behind that build hashes to the run's `0bd6bafb…`.
///
/// ## Why the pin is NOT the spike entry's pin
///
/// Different artifact, different facts: this export's label sets are the
/// full schema-v2 ones (12 intents / 13 BIO tags) and its logits need the
/// fitted calibration temperature 1.412564 — neither is true of the T-036
/// v0 baseline, so reusing that entry would either reject this zip
/// (checksum) or silently mislabel every utterance (manifest). Hence its
/// own id, its own digest, its own installed directory name.
///
/// ## INTERNAL TESTING — publish blocked
///
/// The artifact FAILS the T-038 harness gates today (`closed_intent_
/// accuracy` 0.8726, `contact_f1` 0.3125, `side_effect_precision` 0.9412,
/// `abstention_precision` 0.7222, calibration max deviation 0.2744), which
/// is exactly why this is a sideload for the developer's own device rather
/// than a shipped brain: it is NOT offered in any picker, NOT in
/// `ModelCatalog.all`, and requires an `INTENT_ENCODER` build (a compile-
/// time condition absent from Release). Publication is blocked on the
/// 8,000-row calibration corpus (T-035/T-038).
enum IntentEncoderSideload {

    // MARK: - Artifact identity

    /// Catalog id for the trained artifact. Distinct from
    /// `ModelCatalog.intentEncoderSpike` so a device that installed the
    /// baseline can never be mistaken for one running this artifact.
    static let modelID = ModelID("intent-encoder-t036-noised6b-int8")

    /// The directory name the store installs the `.mlmodelc` under. Must
    /// stay distinct from the spike entry's `t033-encoder-int8.mlmodelc`:
    /// same name would mean same destination directory, and `isCoreMLCached`
    /// could not tell the two artifacts apart on disk.
    static let installedDirectoryName = "t033-encoder-t036-noised6b-int8.mlmodelc"

    /// The zip's own size and SHA-256 — the values `ModelStore
    /// .installCoreMLEncoder(fromZip:for:)` verifies BEFORE unpacking
    /// (`.intentEncoder` rule: the pin is the archive's hash).
    static let zipBytes: Int64 = 109_079_441
    static let zipSHA256 =
        "d8f549ecb2e37b44bbcf21a243cbfc00f917d47f7f4e7187d547f51168afbcdc"

    /// Filename under the LAN web root (a name of our own so the export's
    /// `t033-encoder-int8-mlmodelc.zip` and this one can never be served
    /// interchangeably).
    static let zipFilename = "t033-encoder-t036-noised6b-int8-mlmodelc.zip"

    /// Server-side provenance, recorded for the event trail and the
    /// reviewer — never for the user.
    static let runName =
        "t036-full-0.1.0-internal-noised6b-topup-20260914-071945"
    static let checkpointSHA256Prefix = "0bd6bafbc30d"
    static let artifactDigest =
        "0bd6bafbc30dd2d34308b18bd582f607b1bb524f46369c2d492e34060ec1a8e5"

    /// Environment override for a tester NOT on the home LAN (or with the
    /// zip already staged on the device):
    ///
    ///     INTENT_ENCODER_SIDELOAD_URL=/path/to/t033-encoder-t036-noised6b-int8-mlmodelc.zip
    ///     INTENT_ENCODER_SIDELOAD_URL=https://…/t033-encoder-t036-noised6b-int8-mlmodelc.zip
    ///
    /// A BLANK value disables the sideload entirely (no fetch, no
    /// network) — the same "blank falls back / disables" convention as the
    /// tester-copy override on the spike entry.
    static let environmentOverrideKey = "INTENT_ENCODER_SIDELOAD_URL"

    /// Where the home server serves the artifact (the same LAN web root
    /// the brain models are fetched from — `python3 -m http.server 8765`,
    /// `…/models/web/encoder-dev/`). Committing a LAN URL follows the
    /// existing `qwen4BNepali` precedent for TESTING-only artifacts;
    /// `Info.plist`'s `NSAllowsLocalNetworking` is what makes the cleartext
    /// fetch possible, exactly as it is for that entry.
    static let lanZipURL = URL(
        string: "http://192.168.1.117:8765/encoder-dev/\(zipFilename)")!

    /// The zip source for this run: the tester's override when present,
    /// else the LAN URL. Nil when the override is explicitly blank
    /// (sideload disabled).
    static func resolvedZipURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = environment[environmentOverrideKey] else {
            return lanZipURL
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A bare path is the common case for a locally staged zip.
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return URL(string: trimmed)
    }

    // MARK: - Manifest (the label ORDER the logits index into)

    /// The artifact's own `meta.json` label sets, verbatim — order is
    /// load-bearing (it is the head index order), so these arrays are
    /// copied character-for-character from
    /// `train/artifact/meta.json` of the run above, not re-sorted.
    ///
    /// `calibrationTemperature` is the FITTED value from the artifact's
    /// `calibration.json` (temperature scaling, 3,285 fit rows): the
    /// interpreter divides intent logits by it before the softmax, so the
    /// confidence the 0.4/0.7 band policy sees is the calibrated one.
    /// Using `IntentEncoderManifest.t033Spike` here (10 intents / 5 tags /
    /// temperature 1.0) would mislabel this artifact's outputs — the
    /// reason the manifest ships with the runtime and not the zip.
    static let manifest = IntentEncoderManifest(
        id: "t036-noised6b-minilm-int8",
        version: "t036-internal-1",
        intents: [
            "ack_med",
            "call",
            "emergency",
            "set_reminder",
            "health_query",
            "music",
            "send_message",
            "guide",
            "create_calendar_event",
            "suggest_video",
            "query",
            "none"
        ],
        tags: [
            "O",
            "B-contact", "I-contact",
            "B-time", "I-time",
            "B-medication", "I-medication",
            "B-message", "I-message",
            "B-topic", "I-topic",
            "B-app", "I-app"
        ],
        maxSequenceLength: 64,
        calibrationTemperature: 1.412564
    )

    // MARK: - Catalog entry (internal testing only)

    /// The entry the gated path installs and serves. INTERNAL TESTING —
    /// publish blocked on the 8,000-row calibration corpus (T-035/T-038).
    ///
    /// `kind == .intentEncoder` is what makes the store treat this as a
    /// DIRECTORY artifact: the zip is verified against `zipSHA256` and
    /// unpacked to `Models/intentEncoder/<installedDirectoryName>`, never
    /// next to a whisper.cpp model (where an `.mlmodelc` would be
    /// auto-loaded).
    static let entry = ModelCatalogEntry(
        id: modelID,
        kind: .intentEncoder,
        displayName: "Intent encoder — T-036 noised6b (internal testing only)",
        filename: installedDirectoryName,
        downloadURL: resolvedZipURL() ?? lanZipURL,
        sizeBytes: zipBytes,
        sha256: zipSHA256,
        // int8 encoder body ~119 MB; the same generous 2 GB floor as the
        // spike entry — this is not a low-RAM path.
        minDeviceRAMBytes: 2_000_000_000,
        dependsOn: nil,
        // Multilingual (Nepali + English) by training data; the encoder is
        // language-neutral from the catalog's point of view, so it is not
        // gated on the app language.
        languages: []
    )

    /// Entry lookup for this artifact only (nil for every other id).
    static func entry(for id: ModelID) -> ModelCatalogEntry? {
        id == modelID ? entry : nil
    }
}

// MARK: - Resolver seam

extension ModelCatalog {

    /// Entry resolver that knows the shipped catalog AND the internal
    /// sideload, for the seams that must see both (`ModelStore`'s
    /// `entryProvider`, and the gated encoder path).
    ///
    /// The shipped catalog is consulted FIRST and is authoritative: this
    /// function can only ever ADD the sideload id, never shadow or change
    /// a shipped entry. A build WITHOUT `INTENT_ENCODER` may still resolve
    /// the id (the resolver is compile-time unconditional so the store's
    /// path handling stays testable) — what keeps the artifact out of
    /// service there is `IntentEncoderFeature.isEnabled` in the installer
    /// and the interpreter's own `isAvailable`, not the lookup.
    static func entryIncludingInternalSideload(for id: ModelID) -> ModelCatalogEntry? {
        if let shipped = entry(for: id) { return shipped }
        return IntentEncoderSideload.entry(for: id)
    }

    /// The internal-testing sideload entries, alongside the shipped
    /// catalog's own `internalTestingEncoderEntries`. INTERNAL TESTING —
    /// publish blocked on the 8,000-row calibration corpus (T-035/T-038).
    /// Deliberately NOT merged into `availableBrainEntries` /
    /// `availableSTTEntries`: no picker may offer it to a household.
    static var internalSideloadEncoderEntries: [ModelCatalogEntry] {
        [IntentEncoderSideload.entry]
    }
}

// MARK: - LAN installer

/// What the sideload trigger decided, returned synchronously so a caller
/// (and a test) can tell a real fetch from a no-op without waiting on a
/// 109 MB download + checksum + unzip.
enum IntentEncoderSideloadDecision: Equatable {
    /// The `INTENT_ENCODER` compilation condition is absent (or the
    /// caller did not offer it) — the shipped default. Nothing was
    /// constructed, fetched or emitted.
    case disabled
    /// No zip source: the tester blanked the override. Nothing fetched.
    case notConfigured
    /// The artifact is already in the ModelStore.
    case alreadyInstalled
    /// An earlier fetch/install is still running.
    case inFlight
    /// The fetch (or a local copy) is now running on the installer's own
    /// queue. `LocalBrainChain` re-checks availability every turn, so a
    /// successful install is picked up without any explicit reload.
    case started
}

/// Fetches the T-036 sideload zip from the LAN (or a staged file) and
/// installs it into `ModelStore`.
///
/// ## Contract
///
///  - **Reachable only in `INTENT_ENCODER` builds.** The caller is the
///    gated encoder path in `AppCoordinator`; the first check here is the
///    same compile-time gate, so a shipped build can never fetch.
///  - **Never silent.** Every outcome emits: the decision
///    (started / skipped / failed with a machine reason) plus
///    `ModelStore`'s own `coreml_encoder_installed` /
///    `coreml_encoder_checksum_mismatch`. A 404, an unreachable LAN, a
///    truncated download or a substituted archive surfaces as
///    `encoder_sideload_failed`, never as a quiet no-op.
///  - **Strict sha256 untouched.** This type verifies nothing itself: it
///    calls `ModelStore.installCoreMLEncoder(fromZip:for:)`, which keeps
///    the `.intentEncoder` rule that the ZIP's own sha256 must match the
///    entry pin before anything is unpacked.
///  - **No paths, no user content, ever.** Event metadata carries the
///    model id and the SOURCE KIND (or host) — never a file path, never
///    archive contents (NFR-016).
///  - **Off the main thread.** Download + 109 MB checksum + unzip run on
///    this object's own serial queue; the caller returns immediately.
final class IntentEncoderSideloadInstaller {

    /// Transport seam: fetch `url` and hand back a LOCAL file URL. The
    /// default is a real `URLSession` download; tests inject a closure so
    /// no test ever touches the network (or a 109 MB file).
    typealias Downloader = (URL, @escaping (Result<URL, Error>) -> Void) -> Void

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let modelId: ModelID
    private let fileManager: FileManager
    private let downloader: Downloader
    private let queue = DispatchQueue(label: "intent.encoder.sideload", qos: .utility)
    private let lock = NSLock()
    private var installing = false

    init(modelStore: ModelStore,
         observabilityBus: ObservabilityBus,
         modelId: ModelID = IntentEncoderSideload.modelID,
         fileManager: FileManager = .default,
         downloader: @escaping Downloader = IntentEncoderSideloadInstaller.lanDownload) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.modelId = modelId
        self.fileManager = fileManager
        self.downloader = downloader
    }

    /// The gated trigger. `isGateEnabled` is injectable (defaulting to the
    /// compile-time condition) exactly like
    /// `IntentEncoderWiring.gatedEncoder(isEnabled:)`, so the gate's
    /// effect is testable on a build that does NOT define `INTENT_ENCODER`.
    @discardableResult
    func installIfNeeded(
        isGateEnabled: Bool = IntentEncoderFeature.isEnabled,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IntentEncoderSideloadDecision {
        guard isGateEnabled else { return .disabled }
        guard let zipURL = IntentEncoderSideload.resolvedZipURL(
                environment: environment) else {
            emit("encoder_sideload_skipped", outcome: "info", errorCode: nil,
                 extra: ["reason": "no_source"])
            return .notConfigured
        }
        guard !modelStore.isCoreMLCached(modelId) else {
            emit("encoder_sideload_skipped", outcome: "info", errorCode: nil,
                 extra: ["reason": "already_installed"])
            return .alreadyInstalled
        }
        lock.lock()
        let busy = installing
        if !busy { installing = true }
        lock.unlock()
        guard !busy else { return .inFlight }
        emit("encoder_sideload_started", outcome: "info", errorCode: nil,
             extra: ["source": Self.sourceKind(of: zipURL)])
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.installing = false
                self.lock.unlock()
            }
            if zipURL.isFileURL {
                // A staged copy needs no transport at all.
                self.performInstall(from: zipURL)
            } else {
                self.downloader(zipURL) { result in
                    switch result {
                    case .success(let localZip):
                        // The transport's temp file belongs to it; once
                        // the install returns we are done with our copy.
                        defer { try? self.fileManager.removeItem(at: localZip) }
                        self.performInstall(from: localZip)
                    case .failure(let error):
                        self.emit("encoder_sideload_failed", outcome: "failure",
                                  errorCode: Self.errorCode(for: error))
                    }
                }
            }
        }
        return .started
    }

    /// Runs on `queue`. The only failure detail that leaves this method is
    /// a short machine string.
    private func performInstall(from zipURL: URL) {
        guard fileManager.fileExists(atPath: zipURL.path) else {
            emit("encoder_sideload_failed", outcome: "failure",
                 errorCode: "zip_missing")
            return
        }
        do {
            _ = try modelStore.installCoreMLEncoder(fromZip: zipURL, for: modelId)
            // Success is ModelStore's own `coreml_encoder_installed`.
            emit("encoder_sideload_installed", outcome: "success", errorCode: nil)
        } catch ModelStoreError.checksumMismatch {
            // ModelStore already emitted `coreml_encoder_checksum_mismatch`;
            // this records that the sideload is what attempted it.
            emit("encoder_sideload_failed", outcome: "failure",
                 errorCode: "checksum")
        } catch {
            emit("encoder_sideload_failed", outcome: "failure",
                 errorCode: "unzip")
        }
    }

    /// Default transport: one real download from the LAN web root.
    static func lanDownload(_ url: URL,
                            completion: @escaping (Result<URL, Error>) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        let task = session.downloadTask(with: url) { tempURL, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            guard let tempURL else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            // `tempURL` is deleted when this handler returns — take
            // ownership of the bytes first.
            let kept = FileManager.default.temporaryDirectory
                .appendingPathComponent("encoder-sideload-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: tempURL, to: kept)
                completion(.success(kept))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Machine-readable source kind for the event trail: the host for a
    /// network fetch (never a full URL), `file` for a staged copy.
    private static func sourceKind(of url: URL) -> String {
        url.isFileURL ? "file" : (url.host ?? "remote")
    }

    private static func errorCode(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timeout"
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .secureConnectionFailed:
                return "unreachable"
            default: return "transport"
            }
        }
        return "transport"
    }

    private func emit(_ eventType: String,
                      outcome: String,
                      errorCode: String?,
                      extra: [String: String] = [:]) {
        var metadata: [String: String] = [
            "model_id": modelId.rawValue,
            "run": IntentEncoderSideload.runName
        ]
        for (key, value) in extra { metadata[key] = value }
        observabilityBus.emit(ObservabilityEvent(
            component: "intent_encoder_sideload",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }
}
