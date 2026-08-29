import Foundation
import AVFoundation

/// Owns the `AVAudioSession` configuration for always-on voice.
///
/// Configured for `.playAndRecord` with `.measurement` mode so the input tap
/// gets low-latency, minimally-processed mic audio suitable for wake-word
/// detection and speech recognition. Handles interruptions and route changes
/// (headset plug, phone call, Siri) so the pipeline resumes automatically.
///
/// Requires `audio` in `UIBackgroundModes` (already declared in Info.plist)
/// so the tap keeps running when the screen locks.
final class AudioSessionManager {

    enum ActivationError: Error {
        case sessionConfigurationFailed(Error)
        case activationFailed(Error)
        case microphonePermissionDenied
    }

    private let session: AVAudioSession
    private let observabilityBus: ObservabilityBus
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    init(observabilityBus: ObservabilityBus,
         session: AVAudioSession = AVAudioSession.sharedInstance()) {
        self.observabilityBus = observabilityBus
        self.session = session
    }

    deinit {
        [interruptionObserver, routeChangeObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    /// Requests mic permission and activates the audio session. The completion
    /// runs on the main queue.
    func activate(completion: @escaping (Result<Void, ActivationError>) -> Void) {
        requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emit(eventType: "audio_activate", outcome: "denied")
                completion(.failure(.microphonePermissionDenied))
                return
            }

            do {
                try self.session.setCategory(
                    .playAndRecord,
                    mode: .measurement,
                    options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
                )
                try self.session.setActive(true, options: [.notifyOthersOnDeactivation])
            } catch {
                self.emit(eventType: "audio_activate", outcome: "failure",
                          errorCode: "activation_failed")
                completion(.failure(.activationFailed(error)))
                return
            }

            self.subscribeToInterruptions()
            self.emit(eventType: "audio_activate", outcome: "success")
            completion(.success(()))
        }
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        emit(eventType: "audio_deactivate", outcome: "success")
    }

    // MARK: - Permission

    private func requestMicrophonePermission(_ callback: @escaping (Bool) -> Void) {
        // iOS 17 renamed the API; support both.
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { callback(granted) }
            }
        } else {
            session.requestRecordPermission { granted in
                DispatchQueue.main.async { callback(granted) }
            }
        }
    }

    // MARK: - Interruption handling

    private func subscribeToInterruptions() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.emit(eventType: "audio_interruption_began", outcome: "info")
            case .ended:
                try? self.session.setActive(true)
                self.emit(eventType: "audio_interruption_ended", outcome: "info")
            @unknown default:
                break
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.emit(eventType: "audio_route_changed", outcome: "info")
        }
    }

    private func emit(eventType: String, outcome: String, errorCode: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: "audio_session",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
