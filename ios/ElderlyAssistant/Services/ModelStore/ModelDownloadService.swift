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
    private var tasks: [ModelID: URLSessionDownloadTask] = [:]

    /// Minimum free bytes we require on the volume before starting a
    /// download. Adds 300 MB safety margin over the model's declared size.
    private let diskSafetyMarginBytes: Int64 = 300_000_000

    init(store: ModelStore,
         observabilityBus: ObservabilityBus,
         sessionFactory: (() -> URLSession)? = nil) {
        self.store = store
        self.observabilityBus = observabilityBus
        self.sessionFactory = sessionFactory ?? {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 6 * 60 * 60
            return URLSession(configuration: config)
        }
        super.init()
    }

    // MARK: - Public API

    func start(_ id: ModelID) {
        guard let entry = ModelCatalog.entry(for: id) else {
            update(id, .failed(reason: "unknown model"))
            return
        }
        if case .downloading = states[id] ?? .notStarted { return }
        if states[id] == .completed, store.isCached(id) { return }

        // Disk-space guard. Directory artifacts (WhisperKit) size by their
        // zip, not the placeholder `sizeBytes`.
        let requiredBytes = entry.whisperKitZipURL != nil
            ? entry.whisperKitZipBytes : entry.sizeBytes
        if let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
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

    // MARK: - Called by DownloadProxyDelegate

    fileprivate func handleProgress(_ id: ModelID, received: Int64, total: Int64) {
        update(id, .downloading(bytesReceived: received, totalBytes: total))
    }

    fileprivate func handleFinishedDownload(_ id: ModelID, tempURL: URL) {
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

    private func update(_ id: ModelID, _ state: ModelDownloadState) {
        DispatchQueue.main.async { [weak self] in
            self?.states[id] = state
        }
    }

    private func emit(_ eventType: String, outcome: String,
                      modelId: ModelID, errorCode: String?) {
        observabilityBus.emit(ObservabilityEvent(
            component: "model_download",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: ["state": modelId.rawValue]
        ))
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
