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

// MARK: - Silent fallback (never gibberish)

/// No-op speaker. iOS ships no Nepali voice, so `SystemSpeechSpeaker`
/// falls back to en-US and reads Devanagari as gibberish — worse than
/// silence for the pilot (field report 2026-09-05: "khana"-like mangling
/// after every LLM reply). Used by PiperVoiceSpeaker as the fallback for
/// Nepali locales whenever the real Nepali voice can't speak (voice not
/// installed, synthesis failure); replies remain fully visible on the
/// conversation card.
final class NullSpeaker: Speaker {
    func speak(_ text: String, locale: Locale) async {}
    func cancel() {}
}

// MARK: - On-device TTS engine (sherpa-onnx)

/// Synthesis boundary — the fakeable seam for tests. Implementations turn
/// text into a WAV file on disk using a locally installed sherpa-layout
/// voice directory (model.onnx + tokens.txt + espeak-ng-data/).
protocol TTSEngine {
    /// Synthesizes `text` and returns the URL of a WAV file the caller
    /// owns (and should delete after playback). `speed` < 1.0 slows
    /// speech down (elderly-friendly default lives in PiperVoiceSpeaker).
    ///
    /// `speakerID` selects among a multi-speaker voice's speakers (the
    /// bundled ne_NP-google-medium-int8 exposes sids 0-17 — verified in
    /// the shipped export, see ResponseVoiceSelection). Single-speaker
    /// voices ignore it: sherpa only feeds the sid tensor to models that
    /// expose a "sid" input.
    func synthesize(_ text: String, voiceDirectory: URL, speed: Float,
                    speakerID: Int) throws -> URL

    /// Stops any in-flight synthesis as soon as possible.
    func cancelSynthesis()
}

extension TTSEngine {
    /// Convenience for single-speaker voices and pre-picker call sites.
    func synthesize(_ text: String, voiceDirectory: URL, speed: Float) throws -> URL {
        try synthesize(text, voiceDirectory: voiceDirectory, speed: speed, speakerID: 0)
    }
}

enum TTSEngineError: Error {
    case noModelFile(URL)
    case engineInitFailed(URL)
    case synthesisFailed
}

#if canImport(SherpaOnnx)
import SherpaOnnx

/// sherpa-onnx offline TTS (VITS + espeak-ng phonemization). One
/// `SherpaOnnxOfflineTtsWrapper` is kept per voice directory — engine
/// init is expensive (model load), so instances are cached and reused
/// across utterances. Thread safety: sherpa offline TTS instances are
/// not re-entrant; all calls are serialized on `engineQueue`.
final class SherpaTTSEngine: TTSEngine {
    private var engines: [URL: SherpaOnnxOfflineTtsWrapper] = [:]
    private let engineQueue = DispatchQueue(label: "tts.sherpa.engine", qos: .userInitiated)

    func synthesize(_ text: String, voiceDirectory: URL, speed: Float,
                    speakerID: Int = 0) throws -> URL {
        try engineQueue.sync {
            let tts = try engine(for: voiceDirectory)
            let audio = tts.generate(text: text, sid: speakerID, speed: speed)
            guard audio.n > 0 else { throw TTSEngineError.synthesisFailed }
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tts-\(UUID().uuidString).wav")
            guard audio.save(filename: out.path) != 0 else {
                throw TTSEngineError.synthesisFailed
            }
            return out
        }
    }

    func cancelSynthesis() {
        // sherpa offline generate() has no cancel; the caller discards
        // the result if it was cancelled while in flight (see
        // PiperVoiceSpeaker.cancel). Nothing to do here.
    }

    private func engine(for dir: URL) throws -> SherpaOnnxOfflineTtsWrapper {
        if let cached = engines[dir] { return cached }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let modelFile = contents.first(where: { $0.hasSuffix(".onnx") }) else {
            throw TTSEngineError.noModelFile(dir)
        }
        let tokens = dir.appendingPathComponent("tokens.txt").path
        let dataDir = dir.appendingPathComponent("espeak-ng-data").path
        let vits = sherpaOnnxOfflineTtsVitsModelConfig(
            model: dir.appendingPathComponent(modelFile).path,
            lexicon: "",
            tokens: tokens,
            dataDir: dataDir
        )
        let modelCfg = sherpaOnnxOfflineTtsModelConfig(vits: vits, numThreads: 2, debug: 0)
        var cfg = sherpaOnnxOfflineTtsConfig(model: modelCfg)
        let tts = SherpaOnnxOfflineTtsWrapper(config: &cfg)
        guard tts.sampleRate > 0 else {
            throw TTSEngineError.engineInitFailed(dir)
        }
        engines[dir] = tts
        return tts
    }
}
#else
/// Build without the sherpa-onnx package linked: always fails, so
/// PiperVoiceSpeaker falls back to system speech. Keeps the app
/// compilable in minimal configurations.
final class SherpaTTSEngine: TTSEngine {
    func synthesize(_ text: String, voiceDirectory: URL, speed: Float,
                    speakerID: Int = 0) throws -> URL {
        throw TTSEngineError.engineInitFailed(voiceDirectory)
    }
    func cancelSynthesis() {}
}
#endif

// MARK: - Piper (on-device, sherpa-onnx — the production speaker)

/// On-device Piper VITS speaker. Routes by locale to the installed voice
/// (Nepali for ne-*, English otherwise), synthesizes via `TTSEngine`, and
/// plays the WAV with AVAudioPlayer. Any failure — voice not installed,
/// engine error, decode failure — falls back to `SystemSpeechSpeaker`, so
/// the user-facing behavior can never regress below today's system TTS.
///
/// Voice personalisation (P0, slice B): Nepali utterances resolve
/// through the persisted `ResponseVoiceSelection` (chosen voice +
/// speaker id) and one-shot audition requests — see `resolveVoiceSpec`.
/// Untouched until the user picks: no selection, or the default
/// google-medium speaker 0, is byte-identical to the pre-picker path.
final class PiperVoiceSpeaker: NSObject, Speaker {
    private let fallback: SystemSpeechSpeaker
    private let silenceFallback: Speaker
    private let observabilityBus: ObservabilityBus
    private let modelStore: ModelStore
    private let engine: TTSEngine
    private let bundle: Bundle

    /// Elderly-friendly pace: 5% slower than the voice's natural rate.
    static let defaultSpeed: Float = 0.95

    private var player: AVAudioPlayer?
    private var currentContinuation: CheckedContinuation<Void, Never>?
    private var generationTask: Task<URL?, Never>?
    private var cancelled = false

    init(fallback: SystemSpeechSpeaker,
         observabilityBus: ObservabilityBus,
         modelStore: ModelStore,
         engine: TTSEngine? = nil,
         silenceFallback: Speaker = NullSpeaker(),
         bundle: Bundle = .main) {
        self.fallback = fallback
        self.silenceFallback = silenceFallback
        self.observabilityBus = observabilityBus
        self.modelStore = modelStore
        self.engine = engine ?? SherpaTTSEngine()
        self.bundle = bundle
        super.init()
    }

    /// The fallback that can never make things worse: Nepali gets silence
    /// (iOS has no Nepali system voice — system TTS reads Devanagari as
    /// gibberish, see NullSpeaker); English gets the system voice, which
    /// is good.
    private func fallbackSpeaker(for locale: Locale) -> Speaker {
        locale.languageCode?.hasPrefix("ne") == true ? silenceFallback : fallback
    }

    /// Voice routing: Nepali voice for Nepali locales, English voice for
    /// everything else (the English voice reads romanized text fine, and
    /// no other voices are shipped yet).
    static func voiceID(for locale: Locale) -> ModelID {
        if locale.languageCode?.hasPrefix("ne") == true {
            return ModelCatalog.piperNepali
        }
        return ModelCatalog.piperEnglishUS
    }

    // MARK: - Voice/speaker resolution (voice personalisation, slice B)

    /// One utterance's resolved voice: the voice directory + speaker id +
    /// the locale used for fallback choice and events.
    ///
    /// Resolution order (see `resolveVoiceSpec`): a matching one-shot
    /// audition request (Settings preview / post-apply proof sentence),
    /// then the persisted user choice for Nepali utterances, then the
    /// locale default above. No selection or the default choice = the
    /// exact pre-picker behavior.
    private struct VoiceSpec {
        var voiceID: ModelID
        var speakerID: Int
        /// Locale the utterance is treated as (auditions force ne-NP —
        /// the picker previews Nepali voices with the Nepali sample even
        /// when the Settings UI language is English).
        var locale: Locale
        /// True when the spec came from a consumed audition request.
        var usedAudition: Bool
    }

    private func resolveVoiceSpec(for text: String, locale: Locale) -> VoiceSpec {
        // 1) One-shot audition (preview): the speaker consumes it ONLY
        //    for the exact sample utterance, so a preview can never leak
        //    into unrelated replies and the live voice is never switched
        //    by a preview (research §6 confirm-before-apply).
        if let audition = ResponseVoiceSelection.consumeAudition(matchingText: text) {
            return VoiceSpec(voiceID: audition.voiceID,
                             speakerID: audition.speakerID,
                             locale: Locale(identifier: "ne-NP"),
                             usedAudition: true)
        }
        // 2) Persisted user choice — Nepali utterances only; the English
        //    reply voice is not user-selectable (P0 scope). Stored values
        //    are sanitised against the catalog on read.
        if locale.languageCode?.hasPrefix("ne") == true,
           let chosen = ResponseVoiceSelection.persisted(),
           !ResponseVoiceSelection.isDefault(chosen) {
            return VoiceSpec(voiceID: chosen.voiceID, speakerID: chosen.speakerID,
                             locale: locale, usedAudition: false)
        }
        // 3) Locale default — unchanged pre-picker behavior.
        return VoiceSpec(voiceID: Self.voiceID(for: locale), speakerID: 0,
                         locale: locale, usedAudition: false)
    }

    func speak(_ text: String, locale: Locale) async {
        cancel()
        cancelled = false
        let spec = resolveVoiceSpec(for: text, locale: locale)
        if spec.usedAudition || spec.speakerID != 0
            || spec.voiceID != Self.voiceID(for: spec.locale) {
            emit("tts_voice_" + (spec.usedAudition ? "audition" : "selected"),
                 locale: spec.locale, voice: spec)
        }
        guard let voiceDir = modelStore.ttsVoiceDirectory(for: spec.voiceID)
                ?? modelStore.installBundledTTSVoice(for: spec.voiceID, bundle: bundle) else {
            emit("tts_voice_missing_fallback", locale: spec.locale)
            await fallbackSpeaker(for: spec.locale).speak(text, locale: spec.locale)
            return
        }

        let task = Task.detached(priority: .userInitiated) { [engine] () -> URL? in
            try? engine.synthesize(text, voiceDirectory: voiceDir,
                                   speed: Self.defaultSpeed,
                                   speakerID: spec.speakerID)
        }
        generationTask = task
        let wav = await task.value
        guard let wav, !cancelled else {
            if wav == nil && !cancelled {
                emit("tts_synthesis_failed_fallback", locale: spec.locale)
                await fallbackSpeaker(for: spec.locale).speak(text, locale: spec.locale)
            }
            return
        }
        defer { try? FileManager.default.removeItem(at: wav) }
        emit("speak", locale: spec.locale)
        await play(wav, text: text, locale: spec.locale)
    }

    func cancel() {
        cancelled = true
        generationTask?.cancel()
        generationTask = nil
        engine.cancelSynthesis()
        player?.stop()
        player = nil
        fallback.cancel()
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Playback

    private func play(_ wav: URL, text: String, locale: Locale) async {
        do {
            let player = try AVAudioPlayer(contentsOf: wav)
            self.player = player
            player.delegate = self
            player.prepareToPlay()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                currentContinuation = cont
                player.play()
            }
        } catch {
            emit("tts_player_failed_fallback", locale: locale)
            await fallbackSpeaker(for: locale).speak(text, locale: locale)
        }
    }

    private func settlePlayback() {
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume()
        }
        player = nil
    }

    private func emit(_ eventType: String, locale: Locale) {
        observabilityBus.emit(ObservabilityEvent(
            component: "speaker",
            eventType: eventType,
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["state": locale.identifier]
        ))
    }

    /// Voice-usage event (voice personalisation, slice B): records WHICH
    /// voice+speaker an utterance used when it differs from the locale
    /// default. PII-free — catalog voice ids and speaker numbers only.
    private func emit(_ eventType: String, locale: Locale, voice: VoiceSpec) {
        observabilityBus.emit(ObservabilityEvent(
            component: "speaker",
            eventType: eventType,
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["state": "\(voice.voiceID.rawValue)#\(voice.speakerID)",
                       "locale": locale.identifier]
        ))
    }
}

extension PiperVoiceSpeaker: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        settlePlayback()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        settlePlayback()
    }
}
