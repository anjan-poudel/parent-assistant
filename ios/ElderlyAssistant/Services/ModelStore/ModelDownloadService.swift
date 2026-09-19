import Foundation
import Combine

enum ModelDownloadState: Equatable {
    case notStarted
    case queued
    case downloading(bytesReceived: Int64, totalBytes: Int64)
    case verifying
    case completed
    case failed(reason: String)
    case cancelled
}

enum ModelDownloadError: Error {
    case unknownModel
    case insufficientDiskSpace
    case httpError(status: Int)
    case transportError(Error)
    case checksumFailed
}

/// Foreground-session model download. For Phase 1 the user is looking at
/// the download UI during first-run so foreground is fine; upgrading to
/// `URLSessionConfiguration.background(withIdentifier:)` is a follow-up
/// (bind to the app delegate's completion handler; identifier stability
/// across relaunches; etc).
///
/// State per model is `@Published` so ContentView can render progress. The
/// service is single-writer per model — a second call to `start(_:)` for a
/// model already downloading is a no-op.
final class ModelDownloadService: NSObject, ObservableObject {

    @Published private(set) var states: [ModelID: ModelDownloadState] = [:]

    private let store: ModelStore
    private let observabilityBus: ObservabilityBus
    private let sessionFactory: () -> URLSession
    /// Free-space probe for the pre-flight disk guard (see `start(_:)`).
    /// A seam for the same reason `sessionFactory` is one: the guard
    /// measures the HOST volume, so a test that drives the real 2.5 GB
    /// catalog entry through a stubbed transport must not start failing
    /// because the machine running the suite happens to be nearly full.
    /// `nil` means "not measurable" — the guard is skipped, exactly as it
    /// already is when the volume query fails.
    private let availableBytesProvider: () -> Int64?
    private var tasks: [ModelID: URLSessionDownloadTask] = [:]
    /// Multipart downloads in flight, keyed by model. A multipart model
    /// has NO entry in `tasks` — its parts are owned by the runner, which
    /// `cancel(_:)` reaches through here.
    private var multipart: [ModelID: MultipartDownload] = [:]

    /// Minimum free bytes we require on the volume before starting a
    /// download. Adds 300 MB safety margin over the model's declared size.
    private let diskSafetyMarginBytes: Int64 = 300_000_000

    /// HARD CAP on the total bytes one download may declare — parts or
    /// single file (the spec's `MAX_MULTIPART_TOTAL_BYTES`). Multipart
    /// delivery exists only to route around GitHub's 2 GiB per-asset cap;
    /// it is not a licence to ship arbitrary sizes, so ANY entry whose
    /// declared total exceeds this is refused before a byte moves,
    /// whatever its delivery shape. 3 GB also happens to clear the
    /// largest artifact the app has a reason to ship (the 2.5 GB 4B
    /// brain) while catching a mis-declared or substituted multi-part
    /// entry.
    static let maxMultipartTotalBytes: Int64 = 3_000_000_000

    /// How many parts may be in flight at once. Three keeps the pipe full
    /// on a phone connection without fanning a multi-GB download out into
    /// enough sockets to invite the OS to kill the app.
    static let maxConcurrentParts = 3

    init(store: ModelStore,
         observabilityBus: ObservabilityBus,
         sessionFactory: (() -> URLSession)? = nil,
         availableBytesProvider: (() -> Int64?)? = nil) {
        self.store = store
        self.observabilityBus = observabilityBus
        self.sessionFactory = sessionFactory ?? {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 6 * 60 * 60
            return URLSession(configuration: config)
        }
        self.availableBytesProvider = availableBytesProvider ?? {
            try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
        super.init()
    }

    // MARK: - Public API

    func start(_ id: ModelID) {
        guard let entry = ModelCatalog.entry(for: id) else {
            update(id, .failed(reason: "unknown model"))
            return
        }
        start(entry)
    }

    /// The entry-driven core of `start(_:)`. `ModelCatalog` is the only
    /// production source of entries; this overload exists so tests can
    /// drive a synthetic entry through the REAL flow (the size-cap
    /// refusal needs an entry no release ships, and the multipart
    /// reassembly can be exercised without a multi-GB download).
    func start(_ entry: ModelCatalogEntry) {
        let id = entry.id
        if case .downloading = states[id] ?? .notStarted { return }
        if states[id] == .completed, store.isCached(id) { return }

        // SIZE GUARDRAIL, first because it is policy rather than local
        // resources: a multipart delivery must not become the hole through
        // which arbitrary model sizes slip past review. `sizeBytes` is the
        // ASSEMBLED full file for a multipart entry (the parts sum to it),
        // so this one comparison covers both delivery shapes — and it runs
        // before the disk/RAM/OS guards so an over-large entry is refused
        // for the honest reason on every device.
        guard entry.sizeBytes <= Self.maxMultipartTotalBytes else {
            update(id, .failed(reason: "model too large"))
            emit("download_size_cap_rejected", outcome: "failure",
                 modelId: id, errorCode: "too_large")
            return
        }

        // Disk-space guard. Directory artifacts (WhisperKit) size by their
        // zip, not the placeholder `sizeBytes`.
        let requiredBytes = entry.whisperKitZipURL != nil
            ? entry.whisperKitZipBytes : entry.sizeBytes
        if let free = availableBytesProvider(),
           free < requiredBytes + diskSafetyMarginBytes {
            update(id, .failed(reason: "not enough disk space"))
            emit("download_disk_full", outcome: "failure", modelId: id, errorCode: "disk_full")
            return
        }

        guard MemoryProbe.canFit(entry.minDeviceRAMBytes) else {
            update(id, .failed(reason: "device does not have enough memory for this model"))
            emit("download_ram_tier_rejected", outcome: "failure", modelId: id, errorCode: "ram_tier")
            return
        }

        // q6 palettized CoreML is spec v9 (grouped palettization) — needs
        // iOS 18+ at runtime; refuse before wasting a ~1.2 GB download.
        if entry.requiresiOS18,
           !ProcessInfo.processInfo.isOperatingSystemAtLeast(
               OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0)) {
            update(id, .failed(reason: "this model requires iOS 18"))
            emit("download_os_tier_rejected", outcome: "failure", modelId: id, errorCode: "os_tier")
            return
        }

        // If a completed artifact is already on disk, short-circuit.
        // WhisperKit models are directories, not single files.
        let alreadyCached = entry.whisperKitZipURL != nil
            ? store.directoryURL(for: id) != nil
            : store.isCached(id)
        if alreadyCached {
            update(id, .completed)
            return
        }

        update(id, .queued)

        // Multipart delivery: N ordered assets for ONE file, reassembled
        // after every part has landed (see `MultipartDownload`).
        if let parts = entry.downloadPartURLs, !parts.isEmpty {
            startMultipart(entry, parts: parts)
            return
        }

        let session = sessionFactory()
        let task = session.downloadTask(with: entry.whisperKitZipURL ?? entry.downloadURL)
        task.taskDescription = id.rawValue
        tasks[id] = task
        session.delegateQueue.maxConcurrentOperationCount = 1
        // We use a per-call delegate because the closure-based API doesn't
        // give us progress. Attach via a proxy delegate object.
        let proxy = DownloadProxyDelegate(service: self, modelId: id)
        // Replace the session with one that has our delegate.
        let delegated = URLSession(
            configuration: session.configuration,
            delegate: proxy,
            delegateQueue: nil
        )
        let delegatedTask = delegated.downloadTask(with: entry.whisperKitZipURL ?? entry.downloadURL)
        delegatedTask.taskDescription = id.rawValue
        tasks[id] = delegatedTask
        proxy.retainer = delegated   // keep session alive until task done
        delegatedTask.resume()
        emit("download_started", outcome: "info", modelId: id, errorCode: nil)
    }

    func cancel(_ id: ModelID) {
        // Multipart: the runner cancels EVERY in-flight part task and
        // deletes the part temp files (a cancelled reassembly must not
        // leave GBs behind), then the shared `.cancelled` state below is
        // published. Its per-task cancellation errors are suppressed —
        // this is not a download failure.
        multipart[id]?.cancel()
        multipart[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id, .cancelled)
        emit("download_cancelled", outcome: "info", modelId: id, errorCode: nil)
    }

    /// Reset the tracked state for `id` back to `.notStarted`. Used after
    /// the caller has deleted the cached file so the row shows a fresh
    /// Download button.
    func reset(_ id: ModelID) {
        update(id, .notStarted)
    }

    // MARK: - Multipart delivery

    /// Starts the ordered-part download for `entry`. The runner owns the
    /// part tasks, the progress accounting and the temp files; the service
    /// owns the reassembly, the checksum and the install (see
    /// `handleMultipartFinished`). Exactly one runner exists per model —
    /// `start(_:)`'s downloading guard already rejected a second start.
    private func startMultipart(_ entry: ModelCatalogEntry, parts: [URL]) {
        let runner = MultipartDownload(
            entry: entry,
            partURLs: parts,
            configuration: sessionFactory().configuration,
            service: self
        )
        multipart[entry.id] = runner
        emit("download_started", outcome: "info", modelId: entry.id, errorCode: nil)
        runner.begin()
    }

    /// Cumulative progress across every part: `received` is the sum of
    /// what each in-flight part has written so far and `total` the full
    /// file's expected bytes, so the existing determinate progress UI
    /// renders one bar for the whole model rather than per-part bars.
    fileprivate func handleMultipartProgress(_ id: ModelID, received: Int64, total: Int64) {
        update(id, .downloading(bytesReceived: received, totalBytes: total))
    }

    /// Every part has landed and been moved out of URLSession's temp area:
    /// concatenate them IN ORDER, then run the ordinary full-file checksum
    /// + install path — the reassembled file is verified exactly like a
    /// single-file download, so a corrupt or substituted part fails
    /// `finalize` and installs nothing.
    fileprivate func handleMultipartFinished(_ id: ModelID, partFiles: [URL]) {
        var staged: URL?
        do {
            let staging = try store.stagingURL(for: id)
            staged = staging
            let fm = FileManager.default
            if fm.fileExists(atPath: staging.path) {
                try fm.removeItem(at: staging)
            }
            try Self.concatenateParts(partFiles, into: staging)
            update(id, .verifying)
            _ = try store.finalize(id)
            update(id, .completed)
            emit("download_completed", outcome: "success", modelId: id, errorCode: nil)
            // Parity with the single-file path: a WhisperKit-style model
            // may have an ANE companion to fetch after the artifact lands.
            fetchEncoderIfNeeded(for: id)
        } catch ModelStoreError.checksumMismatch {
            update(id, .failed(reason: "checksum failed"))
            emit("download_checksum_failed", outcome: "failure", modelId: id, errorCode: "checksum")
        } catch {
            // Never leave a partly-written staging file behind: the store's
            // own `finalize` deletes staging on the paths it reaches, but a
            // failure INSIDE the concatenation (disk full, unreadable part)
            // never gets there.
            if let staged { try? FileManager.default.removeItem(at: staged) }
            update(id, .failed(reason: "\(error)"))
            emit("download_finalize_failed", outcome: "failure", modelId: id, errorCode: "finalize")
        }
        multipart[id] = nil
        tasks[id] = nil
    }

    /// The transfer reported "finished" but what landed is NOT the
    /// artifact: an HTTP error page (a 404 asset name answers with a 9-byte
    /// `Not Found` body), or a body with no bytes at all. Neither may be
    /// staged and checksummed — that path ends in `finalize` blaming the
    /// checksum for a download that never happened, which is exactly the
    /// 2026-09-14 on-device report (a 2.5 GB model "failing checksum" 423 ms
    /// after it started). Fails with the status/byte count as the reason.
    fileprivate func handleUnusableDownload(_ id: ModelID, reason: String,
                                            event: String, errorCode: String,
                                            metadata: [String: String] = [:]) {
        update(id, .failed(reason: reason))
        emit(event, outcome: "failure", modelId: id, errorCode: errorCode,
             metadata: metadata)
        tasks[id] = nil
    }

    /// A multipart attempt died (transport error, an unusable part, or a
    /// runtime size-cap overrun). The runner has already cancelled the
    /// remaining parts and deleted every temp file by the time this is
    /// called.
    fileprivate func handleMultipartFailure(_ id: ModelID, reason: String,
                                            event: String, errorCode: String,
                                            metadata: [String: String] = [:]) {
        handleUnusableDownload(id, reason: reason, event: event,
                               errorCode: errorCode, metadata: metadata)
        multipart[id] = nil
    }

    // MARK: - Bundled (no-network) installs

    /// [BOOT-REVIEW P1-5] Reports the byte progress of an app-bundled
    /// artifact being copied into place by `ModelStore.installBundledModel`.
    /// The published shape is IDENTICAL to a download's, so the
    /// model-specific UI (Settings → AI मोडेल rows) renders the same
    /// determinate bar + "received / total" text with no extra plumbing —
    /// the user sees real numbers for a copy exactly as for a download.
    /// No network task is registered: `cancel(_:)` cannot interrupt a copy
    /// (there is nothing to resume, and the copy is a local disk op).
    func reportBundledInstallProgress(_ id: ModelID, received: Int64,
                                      totalBytes: Int64) {
        update(id, .downloading(bytesReceived: received, totalBytes: totalBytes))
    }

    /// Terminates a bundled-install report stream: `.completed` when the
    /// artifact landed, `.failed` otherwise (the row then offers its
    /// normal download path as the recovery).
    func reportBundledInstallOutcome(_ id: ModelID, installed: Bool,
                                     reason: String = "bundled copy failed") {
        update(id, installed ? .completed : .failed(reason: reason))
    }

    // MARK: - Called by DownloadProxyDelegate

    fileprivate func handleProgress(_ id: ModelID, received: Int64, total: Int64) {
        update(id, .downloading(bytesReceived: received, totalBytes: total))
    }

    fileprivate func handleFinishedDownload(_ id: ModelID, tempURL: URL) {
        // Same rule as the multipart parts: a body with no bytes is not a
        // download. Staging it would only ever reach the verifier as a
        // checksum mismatch, naming the wrong culprit.
        guard Self.fileSize(at: tempURL) > 0 else {
            handleUnusableDownload(id,
                                   reason: "downloaded file is empty (0 bytes)",
                                   event: "download_empty",
                                   errorCode: "empty",
                                   metadata: ["bytes": "0"])
            return
        }
        do {
            // WhisperKit directory artifact: install the zip (checksum is
            // verified inside) — no single-file staging/finalize, and no
            // whisper.cpp encoder companion to chase.
            if ModelCatalog.entry(for: id)?.whisperKitZipURL != nil {
                update(id, .verifying)
                _ = try store.installWhisperKitModel(fromZip: tempURL, for: id)
                update(id, .completed)
                emit("download_completed", outcome: "success", modelId: id, errorCode: nil)
                tasks[id] = nil
                return
            }
            // [YOLO] The point-ask detector is a CoreML-only DIRECTORY
            // artifact (a zip of the compiled `.mlmodelc`): the
            // single-file staging/finalize below would leave the ZIP
            // sitting where a directory is expected and `isCached` would
            // still answer no, so the download must never "complete" that
            // way. Verify the zip's strict sha256 and unpack it into the
            // kind's final directory — the `.intentEncoder` install shape
            // (`ModelStore.installCoreMLEncoder(fromZip:for:)`).
            if ModelCatalog.entry(for: id)?.kind == .yoloDetector {
                update(id, .verifying)
                _ = try store.installCoreMLEncoder(fromZip: tempURL, for: id)
                update(id, .completed)
                emit("download_completed", outcome: "success", modelId: id, errorCode: nil)
                tasks[id] = nil
                return
            }
            let staging = try store.stagingURL(for: id)
            let fm = FileManager.default
            if fm.fileExists(atPath: staging.path) {
                try fm.removeItem(at: staging)
            }
            try fm.moveItem(at: tempURL, to: staging)
            update(id, .verifying)
            _ = try store.finalize(id)
            update(id, .completed)
            emit("download_completed", outcome: "success", modelId: id, errorCode: nil)
            // M2: after the model lands, fetch the ANE encoder zip and
            // unpack it next to the model (whisper.cpp auto-loads it).
            fetchEncoderIfNeeded(for: id)
        } catch ModelStoreError.checksumMismatch {
            update(id, .failed(reason: "checksum failed"))
            emit("download_checksum_failed", outcome: "failure", modelId: id, errorCode: "checksum")
        } catch {
            update(id, .failed(reason: "\(error)"))
            emit("download_finalize_failed", outcome: "failure", modelId: id, errorCode: "finalize")
        }
        tasks[id] = nil
    }

    /// Downloads and installs the optional ANE encoder companion. Best-
    /// effort: a failure here leaves the model fully usable on CPU, so it
    /// logs and moves on rather than marking the model failed.
    private func fetchEncoderIfNeeded(for id: ModelID) {
        guard let entry = ModelCatalog.entry(for: id),
              let encoderURL = entry.coreMLEncoderDownloadURL,
              !store.isCoreMLCached(id) else { return }
        emit("encoder_download_start", outcome: "info", modelId: id, errorCode: nil)
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: encoderURL) { [weak self] zipURL, _, error in
            guard let self, let zipURL else {
                self?.emit("encoder_download_failed", outcome: "failure",
                           modelId: id, errorCode: "transport")
                return
            }
            do {
                _ = try self.store.installCoreMLEncoder(fromZip: zipURL, for: id)
                self.emit("encoder_download_completed", outcome: "success",
                          modelId: id, errorCode: nil)
            } catch {
                self.emit("encoder_download_failed", outcome: "failure",
                          modelId: id, errorCode: "unzip")
            }
        }
        task.resume()
    }

    fileprivate func handleError(_ id: ModelID, _ error: Error) {
        update(id, .failed(reason: "\(error)"))
        emit("download_failed", outcome: "failure", modelId: id, errorCode: "transport")
        tasks[id] = nil
    }

    // MARK: - Helpers

    /// Byte size of a file on disk (0 when it is missing or unreadable).
    /// The download paths use it to tell "the artifact landed" from "an HTTP
    /// error page landed": nothing about a URLSession completion says the
    /// bytes are the model.
    static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Concatenates `parts` IN ORDER (part 0 first) into `destination`,
    /// creating it fresh. Streams through a 1 MB buffer — a 2.5 GB
    /// reassembly must never sit in RAM — and throws on the first read or
    /// write failure, leaving the partial file for the caller to remove
    /// (reassembly is all-or-nothing: a truncated model must not reach the
    /// verifier as if it were a whole file).
    static func concatenateParts(_ parts: [URL], into destination: URL,
                                 fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while autoreleasepool(invoking: { () -> Bool in
                let chunk = input.readData(ofLength: 1_048_576)
                if chunk.isEmpty { return false }
                output.write(chunk)
                return true
            }) {}
        }
    }

    private func update(_ id: ModelID, _ state: ModelDownloadState) {
        DispatchQueue.main.async { [weak self] in
            self?.states[id] = state
        }
    }

    private func emit(_ eventType: String, outcome: String,
                      modelId: ModelID, errorCode: String?,
                      metadata: [String: String] = [:]) {
        var fields = metadata
        fields["state"] = modelId.rawValue
        observabilityBus.emit(ObservabilityEvent(
            component: "model_download",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: fields
        ))
    }
}

// MARK: - Multipart runner

/// One multipart download in flight — the delivery path for a model whose
/// single file exceeds GitHub's 2 GiB per-asset cap.
///
/// Lifecycle: at most `ModelDownloadService.maxConcurrentParts` parts are
/// fetched at once, each by its OWN `URLSessionDownloadTask` against this
/// runner's session, so the delegate sees per-part progress. A part's
/// temporary file is MOVED the instant `didFinishDownloadingTo` fires (iOS
/// deletes the URL it hands us when that callback returns) into a
/// per-download temp directory; the next pending part starts from the same
/// callback, which is what keeps the concurrency window full without a
/// semaphore. When every part has landed the ordered file list goes to the
/// service, which concatenates + verifies + installs it.
///
/// Failure is all-or-nothing: any part failure (or a runtime size-cap
/// overrun) cancels the remaining tasks, deletes the whole temp directory
/// and publishes `.failed` — a half-reassembled multi-GB model must never
/// survive an attempt, and neither must its parts.
private final class MultipartDownload: NSObject, URLSessionDownloadDelegate {

    let modelId: ModelID
    private let entry: ModelCatalogEntry
    private let partURLs: [URL]
    private let configuration: URLSessionConfiguration
    private weak var service: ModelDownloadService?
    private var retainer: URLSession?

    /// Part temp files live here for the duration of the attempt —
    /// outside the store's staging area, so an interrupted reassembly can
    /// never be mistaken for a staged model.
    private let tempDirectory: URL
    /// High-water mark of bytes written per part (progress snapshots are
    /// not monotonic across delegate callbacks).
    private var received: [Int64]
    /// Per-part expected sizes as the server reports them (0 = unknown).
    private var expected: [Int64]
    /// Part index → finished temp file. A part is "landed" only once its
    /// bytes are safely in our own temp directory.
    private var landedParts: [Int: URL] = [:]
    private var nextToStart = 0
    private var inFlight = 0
    /// Set by the first terminal event (finished / failed / cancelled).
    /// Late delegate callbacks — including the cancellation errors
    /// `invalidateAndCancel` provokes — must not restart the flow or
    /// publish a second outcome.
    private var isTerminal = false
    private var isCancelled = false

    init(entry: ModelCatalogEntry, partURLs: [URL],
         configuration: URLSessionConfiguration,
         service: ModelDownloadService,
         tempRoot: URL = FileManager.default.temporaryDirectory) {
        self.entry = entry
        self.modelId = entry.id
        self.partURLs = partURLs
        self.configuration = configuration
        self.service = service
        self.received = Array(repeating: 0, count: partURLs.count)
        self.expected = Array(repeating: 0, count: partURLs.count)
        self.tempDirectory = tempRoot
            .appendingPathComponent("model-parts-\(entry.id.rawValue)-\(UUID().uuidString)",
                                    isDirectory: true)
        super.init()
    }

    func begin() {
        try? FileManager.default.createDirectory(at: tempDirectory,
                                                 withIntermediateDirectories: true)
        let session = URLSession(configuration: configuration,
                                 delegate: self,
                                 delegateQueue: nil)
        retainer = session
        startPendingParts()
    }

    /// Cancels every in-flight part and removes the temp files. The
    /// caller publishes `.cancelled`; the per-task `NSURLErrorCancelled`
    /// callbacks this provokes are swallowed (`isCancelled`).
    func cancel() {
        isCancelled = true
        isTerminal = true
        cleanUp(invalidate: true)
    }

    // MARK: - Part scheduling

    private func startPendingParts() {
        while inFlight < ModelDownloadService.maxConcurrentParts,
              nextToStart < partURLs.count,
              !isTerminal {
            let index = nextToStart
            nextToStart += 1
            guard let session = retainer else { return }
            let task = session.downloadTask(with: partURLs[index])
            task.taskDescription = String(index)
            inFlight += 1
            task.resume()
        }
    }

    /// The part index a task belongs to, from the description set when the
    /// task was created.
    private func partIndex(of task: URLSessionTask) -> Int? {
        task.taskDescription.flatMap(Int.init)
    }

    /// Total bytes the whole file is expected to occupy: the sum of the
    /// parts' declared sizes when every part reported one, else the
    /// catalog's declared full-file size (a server that omits
    /// Content-Length must not make the bar jump around).
    private var totalBytes: Int64 {
        let sum = expected.reduce(0, +)
        return expected.allSatisfy { $0 > 0 } && sum > 0 ? sum : entry.sizeBytes
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard !isTerminal, let index = partIndex(of: downloadTask) else { return }
        received[index] = totalBytesWritten
        if totalBytesExpectedToWrite > 0 {
            expected[index] = totalBytesExpectedToWrite
        }
        // Runtime half of the size guardrail: the entry's declared size
        // was already gated before the first byte moved, but a server
        // serving MORE than the catalog declares must not be allowed to
        // land it. Aborts the whole attempt, not just this part.
        if received.reduce(0, +) > ModelDownloadService.maxMultipartTotalBytes {
            fail(reason: "model too large", event: "download_size_cap_rejected",
                 errorCode: "too_large")
            return
        }
        service?.handleMultipartProgress(modelId,
                                        received: received.reduce(0, +),
                                        total: totalBytes)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !isTerminal, let index = partIndex(of: downloadTask) else { return }

        // THE HTTP STATUS IS PART OF THE RESULT. URLSession calls this for
        // ANY completed transfer — an HTTP error page included. GitHub
        // answers a mistyped asset name with `404` + a 9-byte `Not Found`
        // body, so both parts of the v16 brain "landed" in ~400 ms,
        // reassembled to 18 bytes and died in `finalize` as
        // `finalize_checksum_mismatch`: a 2.5 GB download reported as a
        // checksum failure, 423 ms after it started, without a byte of the
        // model ever being fetched (2026-09-14 on-device report). Refuse a
        // non-2xx HERE, naming the part and the status.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            fail(reason: "part \(index) could not be fetched: HTTP \(http.statusCode) "
                        + HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                 event: "download_part_http_error",
                 errorCode: "part_http_error",
                 metadata: ["part": "\(index)", "http_status": "\(http.statusCode)"])
            return
        }

        // MUST move now — iOS deletes `location` when this returns.
        let destination = tempDirectory.appendingPathComponent(
            String(format: "part%02d", index))
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            fail(reason: "\(error)", event: "download_failed", errorCode: "transport")
            return
        }

        // A 2xx that carried no bytes is not a part either — same rule as
        // the status above, so a silent short reassembly can never reach the
        // verifier and come back as a "checksum" verdict.
        let bytes = ModelDownloadService.fileSize(at: destination)
        guard bytes > 0 else {
            fail(reason: "part \(index) yielded 0 bytes",
                 event: "download_part_empty",
                 errorCode: "part_empty",
                 metadata: ["part": "\(index)", "bytes": "0"])
            return
        }

        landedParts[index] = destination
        inFlight -= 1
        if landedParts.count == partURLs.count {
            finish()
        } else {
            startPendingParts()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // A successful task reports nil here after `didFinishDownloadingTo`
        // has already moved its bytes; only a real error is actionable,
        // and a cancellation we provoked is not a failure.
        guard let error, !isTerminal, !isCancelled else { return }
        fail(reason: "\(error)", event: "download_failed", errorCode: "transport")
    }

    // MARK: - Terminal paths

    private func finish() {
        guard !isTerminal else { return }
        isTerminal = true
        let ordered = (0..<partURLs.count).compactMap { landedParts[$0] }
        guard ordered.count == partURLs.count else {
            // Unreachable: `landedParts.count` gates this call. Treated as
            // a failure rather than trusting a short file to checksum.
            cleanUp(invalidate: true)
            service?.handleMultipartFailure(modelId, reason: "incomplete parts",
                                            event: "download_failed",
                                            errorCode: "transport")
            return
        }
        // Second lock on the same door as the per-part checks: a reassembly
        // with no bytes in it can only ever come back from the verifier as
        // "checksum", which is exactly the misdiagnosis this path now
        // refuses to produce.
        let assembledBytes = ordered.reduce(Int64(0)) {
            $0 + ModelDownloadService.fileSize(at: $1)
        }
        guard assembledBytes > 0 else {
            cleanUp(invalidate: true)
            service?.handleMultipartFailure(modelId,
                                            reason: "no part bytes were fetched",
                                            event: "download_parts_empty",
                                            errorCode: "part_empty",
                                            metadata: ["parts": "\(partURLs.count)"])
            return
        }
        // Hand the ordered parts to the service (which concatenates,
        // verifies and installs synchronously), then drop the temp files —
        // success and failure both end with nothing left on disk.
        service?.handleMultipartFinished(modelId, partFiles: ordered)
        cleanUp(invalidate: false)
    }

    private func fail(reason: String, event: String, errorCode: String,
                      metadata: [String: String] = [:]) {
        guard !isTerminal else { return }
        isTerminal = true
        cleanUp(invalidate: true)
        service?.handleMultipartFailure(modelId, reason: reason,
                                        event: event, errorCode: errorCode,
                                        metadata: metadata)
    }

    private func cleanUp(invalidate: Bool) {
        if invalidate {
            retainer?.invalidateAndCancel()
        } else {
            retainer?.finishTasksAndInvalidate()
        }
        retainer = nil
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

// MARK: - Delegate proxy

/// URLSession delegate lives here so `ModelDownloadService` doesn't have to
/// be `NSObject`-only visible via ObjC runtime. Also lets us keep the
/// session alive for the duration of the task without another retain cycle.
private final class DownloadProxyDelegate: NSObject, URLSessionDownloadDelegate {
    weak var service: ModelDownloadService?
    let modelId: ModelID
    var retainer: URLSession?

    init(service: ModelDownloadService, modelId: ModelID) {
        self.service = service
        self.modelId = modelId
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        service?.handleProgress(modelId,
                                received: totalBytesWritten,
                                total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // An HTTP error page arrives through this same callback (see the
        // multipart runner: a mistyped v16 asset name produced a 9-byte
        // `Not Found` that only surfaced as "checksum failed"). Never hand
        // an error page to the store as if it were the artifact.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            service?.handleUnusableDownload(
                modelId,
                reason: "HTTP \(http.statusCode) "
                        + HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                event: "download_http_error",
                errorCode: "http_error",
                metadata: ["http_status": "\(http.statusCode)"])
            retainer = nil
            return
        }
        // Move IMMEDIATELY — iOS deletes `location` when this delegate
        // returns. Handled inside the service.
        service?.handleFinishedDownload(modelId, tempURL: location)
        retainer = nil
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            service?.handleError(modelId, error)
        }
        retainer = nil
    }
}
