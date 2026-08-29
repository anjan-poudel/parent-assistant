import Foundation
import AVFoundation

/// Text-to-speech output. Phase 1 uses `AVSpeechSynthesizer` — it's built
/// in, requires no models, and handles Nepali with the OS-provided voice
/// (quality varies). Phase 4 (per the research doc) swaps in
/// `PiperVoiceSpeaker` for the Piper VITS Nepali voice.
protocol Speaker: AnyObject {
    /// Speaks `text` in the given locale. Awaited call returns once
    /// speech has actually finished playing (or was cancelled).
    func speak(_ text: String, locale: Locale) async
    func cancel()
}

// MARK: - AVSpeechSynthesizer (default)

final class SystemSpeechSpeaker: NSObject, Speaker {
    private let synthesizer: AVSpeechSynthesizer
    private let observabilityBus: ObservabilityBus
    private var currentContinuation: CheckedContinuation<Void, Never>?

    init(observabilityBus: ObservabilityBus,
         synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.observabilityBus = observabilityBus
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, locale: Locale) async {
        cancel()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: locale)
        // Elderly-friendly defaults — slower rate, slightly higher volume.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            currentContinuation = continuation
            synthesizer.speak(utterance)
            emit("speak", outcome: "info", locale: locale.identifier)
        }
    }

    func cancel() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Voice selection

    private static func voice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        // Try the exact locale first (e.g. "ne-NP"). If iOS has no voice
        // for it, fall back to the language code alone, then to English.
        if let v = AVSpeechSynthesisVoice(language: locale.identifier) {
            return v
        }
        if let language = locale.languageCode,
           let v = AVSpeechSynthesisVoice(language: language) {
            return v
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func emit(_ eventType: String, outcome: String, locale: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "speaker",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: ["state": locale]
        ))
    }
}

extension SystemSpeechSpeaker: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume()
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume()
        }
    }
}

// MARK: - Piper (Phase 4 stub — logs + delegates)

/// Skeleton for the Piper VITS Nepali voice served through Sherpa-ONNX.
/// Doesn't do anything on its own yet — every call delegates to
/// `SystemSpeechSpeaker` so behaviour is identical to what ships today.
/// The class exists so wiring, tests, and settings UI can be built without
/// waiting on the real Piper integration.
final class PiperVoiceSpeaker: Speaker {
    private let fallback: SystemSpeechSpeaker
    private let observabilityBus: ObservabilityBus

    init(fallback: SystemSpeechSpeaker, observabilityBus: ObservabilityBus) {
        self.fallback = fallback
        self.observabilityBus = observabilityBus
    }

    func speak(_ text: String, locale: Locale) async {
        observabilityBus.emit(ObservabilityEvent(
            component: "speaker",
            eventType: "piper_stub_delegate",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: [:]
        ))
        await fallback.speak(text, locale: locale)
    }

    func cancel() {
        fallback.cancel()
    }
}
