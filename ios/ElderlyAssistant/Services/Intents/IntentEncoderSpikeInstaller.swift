import Foundation

/// [ENCODER-RUNTIME-READY] What the install trigger decided when the
/// internal-testing encoder asked for readiness. Returned synchronously so
/// a test (and the caller's event trail) can tell a real install attempt
/// from a no-op without waiting on a 109 MB unzip.
enum IntentEncoderInstallDecision: Equatable {
    /// A zip is configured, the artifact is not installed, and the install
    /// is now running on the installer's own queue.
    case started
    /// The artifact is already in the ModelStore — nothing to do.
    case alreadyInstalled
    /// `INTENT_ENCODER_SPIKE_ZIP` is unset/blank: the internal-testing path
    /// has no artifact source, so the encoder stays unavailable. This is
    /// the shipped default — no UI, no placeholder URL, no network.
    case notConfigured
    /// An install from an earlier readiness check is still running.
    case inFlight
}

/// The install seam `IntentEncoderInterpreter.requestReadiness()` calls.
/// A protocol so the interpreter's gated lifecycle is testable without a
/// real 109 MB zip.
protocol IntentEncoderArtifactInstalling: AnyObject {
    func installIfConfigured(environment: [String: String]) -> IntentEncoderInstallDecision
}

/// Installs the pinned internal-testing encoder artifact from the tester's
/// own copy of the zip (`INTENT_ENCODER_SPIKE_ZIP`).
///
/// ## Contract
///
///  - **Reachable only in `INTENT_ENCODER` builds.** The only caller is
///    `IntentEncoderInterpreter.requestReadiness()`, which refuses unless
///    `IntentEncoderFeature.isEnabled`; the coordinator calls that only on
///    the gated path. A normal build has no reference to this type.
///  - **No UI, no network.** The zip is a local file the tester staged
///    (`ModelCatalog.configuredIntentEncoderSpikeZipURL`); the reserved-TLD
///    placeholder URL is deliberately NOT installed from.
///  - **Strict sha256 untouched.** This type does not verify anything: it
///    calls `ModelStore.installCoreMLEncoder(fromZip:for:)`, which keeps
///    the `.intentEncoder` rule that the ZIP's own sha256 must match the
///    catalog pin BEFORE unpacking.
///  - **Never silent.** Every outcome emits an event: the decision here
///    (started / skipped / failed, with a machine reason) plus ModelStore's
///    own `coreml_encoder_installed` / `coreml_encoder_checksum_mismatch`.
///    A missing zip file, an unreadable archive or a decoy `.mlmodelc` all
///    surface as `encoder_spike_install_failed`, never as a quiet no-op.
///  - **Off the main thread.** The unzip + checksum of 109 MB runs on this
///    object's own serial queue; the caller returns immediately, and
///    `LocalBrainChain` picks the encoder up on the first turn after the
///    install lands (it re-checks `isAvailable` every turn).
final class IntentEncoderSpikeInstaller: IntentEncoderArtifactInstalling {

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let modelId: ModelID
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "intent.encoder.install", qos: .utility)
    private let lock = NSLock()
    private var installing = false

    init(modelStore: ModelStore,
         observabilityBus: ObservabilityBus,
         modelId: ModelID = ModelCatalog.intentEncoderSpike,
         fileManager: FileManager = .default) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.modelId = modelId
        self.fileManager = fileManager
    }

    @discardableResult
    func installIfConfigured(environment: [String: String]) -> IntentEncoderInstallDecision {
        guard let zipURL = ModelCatalog.configuredIntentEncoderSpikeZipURL(
                environment: environment) else {
            return .notConfigured
        }
        guard !modelStore.isCoreMLCached(modelId) else {
            emit("encoder_spike_install_skipped", outcome: "info", errorCode: nil,
                 extra: ["reason": "already_installed"])
            return .alreadyInstalled
        }
        lock.lock()
        let busy = installing
        if !busy { installing = true }
        lock.unlock()
        guard !busy else { return .inFlight }
        emit("encoder_spike_install_started", outcome: "info", errorCode: nil,
             extra: ["reason": "configured"])
        queue.async { [weak self] in
            guard let self else { return }
            self.performInstall(from: zipURL)
            self.lock.lock()
            self.installing = false
            self.lock.unlock()
        }
        return .started
    }

    /// Runs on `queue`. The only failure detail that leaves this method is
    /// a short machine string — never a path, never archive contents.
    private func performInstall(from zipURL: URL) {
        guard fileManager.fileExists(atPath: zipURL.path) else {
            emit("encoder_spike_install_failed", outcome: "failure",
                 errorCode: "zip_missing")
            return
        }
        do {
            _ = try modelStore.installCoreMLEncoder(fromZip: zipURL, for: modelId)
            // Success is ModelStore's own `coreml_encoder_installed`.
        } catch ModelStoreError.checksumMismatch {
            // ModelStore already emitted `coreml_encoder_checksum_mismatch`
            // (outcome failure) before throwing; this trigger-level event
            // records that the readiness request is what attempted it.
            emit("encoder_spike_install_failed", outcome: "failure",
                 errorCode: "checksum")
        } catch {
            emit("encoder_spike_install_failed", outcome: "failure",
                 errorCode: "unzip")
        }
    }

    private func emit(_ eventType: String,
                      outcome: String,
                      errorCode: String?,
                      extra: [String: String] = [:]) {
        var metadata: [String: String] = ["model_id": modelId.rawValue]
        for (key, value) in extra { metadata[key] = value }
        observabilityBus.emit(ObservabilityEvent(
            component: "intent_encoder_install",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }
}
