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

/// [LOUD-TTS] Response-playback loudness seam: switches the shared audio
/// session to `.voicePrompt` mode while the assistant speaks and restores
/// the capture preset afterwards (see `AudioSessionManager`). A static
/// seam — the same pattern as `NewsSourceEditorSeam` — installed by
/// `AppCoordinator.start()`; the no-op default keeps speaker unit tests
/// audio-free.
enum ResponsePlaybackModeSeam {
    static var begin: () -> Void = {}
    static var end: () -> Void = {}
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

        // [LOUD-TTS] Spoken responses get the loudness-optimized session
        // mode for the duration of the utterance (restored by the
        // delegate's finish/cancel below and by cancel()).
        ResponsePlaybackModeSeam.begin()

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
        ResponsePlaybackModeSeam.end()
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
        ResponsePlaybackModeSeam.end()
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume()
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        ResponsePlaybackModeSeam.end()
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

    /// Warm-start seam: preloads the engine instance for
    /// `voiceDirectory` (model.onnx load + espeak-ng data) so the first
    /// synthesis skips engine construction. Throws exactly like the
    /// construction inside `synthesize` would. The default is a no-op so
    /// fakes and the non-sherpa stub build inherit it without change.
    func warm(voiceDirectory: URL) throws
}

extension TTSEngine {
    /// Convenience for single-speaker voices and pre-picker call sites.
    func synthesize(_ text: String, voiceDirectory: URL, speed: Float) throws -> URL {
        try synthesize(text, voiceDirectory: voiceDirectory, speed: speed, speakerID: 0)
    }

    func warm(voiceDirectory: URL) throws {}
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
    /// [TURN-TIMING] Fired once per NEW engine creation with the load ms
    /// (cached engines do not fire) — the `tts_voice_loaded` stage
    /// boundary, wired by PiperVoiceSpeaker to the turn tracer.
    var onEngineCreated: ((_ loadMs: Int) -> Void)?

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

    func warm(voiceDirectory: URL) throws {
        // Same serialization as synthesis: engine construction is not
        // re-entrant, and the warm must not race a live synthesize.
        try engineQueue.sync {
            _ = try engine(for: voiceDirectory)
        }
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
        // [VAD-REGRESSION] (2026-09-10): the sherpa VITS session creation
        // SEGFAULTS onnxruntime when it runs OFF-MAIN on the x86_64
        // simulator — the same crash class as the KWS engine's documented
        // off-main segfault (crash 204647, EXC_BAD_ACCESS in
        // ConstantFolding). Seven crash reports from one morning
        // (2026-09-10 02:21–06:14) all fault on `tts.sherpa.engine` inside
        // `onnxruntime::InferenceSession::Initialize` /
        // `DataTypeImpl::GetDataType` / `OpSchema` teardown; the
        // [WARM-START] boot warms made this construction run at every
        // launch, so every launch — and every first reply — became a
        // crash lottery on the sim, and each crash relaunched the app
        // into a fresh boot (the reported endless spinner + re-read
        // briefing + never-completing voice cycles). The project's
        // proven workaround for this class is session creation ON MAIN
        // (that is how the KWS engine has run since crash 204647).
        // Synthesis stays on this queue; only the one-time construction
        // hops — and only on the simulator (the crash class is x86_64-
        // sim-specific; device builds construct exactly as before). The
        // isMainThread guard keeps a hypothetical main-queue caller from
        // deadlocking on main.sync.
        // [TURN-TIMING] Engine load is the expensive one-time part of the
        // first synthesis — measure it for the `tts_voice_loaded` stage.
        func construct() -> Result<SherpaOnnxOfflineTtsWrapper, Error> {
            Result {
                let loadStart = CFAbsoluteTimeGetCurrent()
                let tts = SherpaOnnxOfflineTtsWrapper(config: &cfg)
                let loadMs = Int((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
                guard tts.sampleRate > 0 else {
                    throw TTSEngineError.engineInitFailed(dir)
                }
                onEngineCreated?(loadMs)
                return tts
            }
        }
        let tts: SherpaOnnxOfflineTtsWrapper
        #if targetEnvironment(simulator)
        if Thread.isMainThread {
            tts = try construct().get()
        } else {
            tts = try DispatchQueue.main.sync(execute: construct).get()
        }
        #else
        // Device: construct on the calling queue (engineQueue) — the
        // pre-[VAD-REGRESSION] behavior, byte-identical.
        tts = try construct().get()
        #endif
        engines[dir] = tts
        return tts
    }
}
#else
/// Build without the sherpa-onnx package linked: always fails, so
/// PiperVoiceSpeaker falls back to system speech. Keeps the app
/// compilable in minimal configurations.
final class SherpaTTSEngine: TTSEngine {
    /// [TURN-TIMING] Never fires in this configuration (no engine is ever
    /// created) — declared so PiperVoiceSpeaker's wiring compiles both ways.
    var onEngineCreated: ((_ loadMs: Int) -> Void)?
    func synthesize(_ text: String, voiceDirectory: URL, speed: Float,
                    speakerID: Int = 0) throws -> URL {
        throw TTSEngineError.engineInitFailed(voiceDirectory)
    }
    func cancelSynthesis() {}
    /// Honest refusal (the protocol's default no-op would claim a warm
    /// that can never help — synthesis fails in this build regardless).
    func warm(voiceDirectory: URL) throws {
        throw TTSEngineError.engineInitFailed(voiceDirectory)
    }
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
    /// [TURN-TIMING] Turn-scoped stage tracer (nil = timing off).
    private let turnTracer: VoiceTurnLatencyTracer?
    /// [LAT-M2] Shared pre-ack WAV cache the warm-time build writes and
    /// the router's fast-lane player reads. A nil injection gets a
    /// private instance pointing at the SAME default directory — the
    /// files are the shared state (see `AckAudioCache`).
    private let ackCache: AckAudioCache

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
         bundle: Bundle = .main,
         turnTracer: VoiceTurnLatencyTracer? = nil,
         ackCache: AckAudioCache? = nil) {
        self.fallback = fallback
        self.silenceFallback = silenceFallback
        self.observabilityBus = observabilityBus
        self.modelStore = modelStore
        self.turnTracer = turnTracer
        self.ackCache = ackCache ?? AckAudioCache()
        let sherpa = SherpaTTSEngine()
        // [TURN-TIMING] Voice engine ready — the load ms rides as a point
        // entry when a fresh engine loads inside a live turn.
        sherpa.onEngineCreated = { loadMs in
            turnTracer?.mark("tts_voice_loaded", elapsedMs: loadMs)
        }
        self.engine = engine ?? sherpa
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
        // [TURN-TIMING] Synthesis finished (voice load + generation) —
        // playback starts next. No-op outside a live turn.
        turnTracer?.mark("tts_done")
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
        // [LOUD-TTS] Restore the capture mode (a no-op when playback never
        // began — the seam's depth guard handles it).
        ResponsePlaybackModeSeam.end()
        fallback.cancel()
        if let cont = currentContinuation {
            currentContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Warm-start seam (boot warm phase)

    /// Preloads one catalog voice's sherpa engine so the first reply
    /// doesn't pay engine construction. Resolves the directory exactly
    /// like `speak` (installed, else bundled install — idempotent), then
    /// warms the engine for it. One engine instance serves every speaker
    /// of the voice (the sid tensor is per-call), so warming the
    /// directory covers all sids. Synchronous on the caller's queue;
    /// completion is called inline.
    func warm(voiceID: ModelID, completion: (WarmStartEngineResult) -> Void) {
        guard let dir = modelStore.ttsVoiceDirectory(for: voiceID)
                ?? modelStore.installBundledTTSVoice(for: voiceID, bundle: bundle) else {
            completion(.failed(reason: "voice_missing"))
            return
        }
        do {
            try engine.warm(voiceDirectory: dir)
            completion(.ready)
        } catch {
            print("[speaker] warm failed for \(voiceID.rawValue): \(error)")
            completion(.failed(reason: "engine_init_failed"))
        }
    }

    // MARK: - Playback

    private func play(_ wav: URL, text: String, locale: Locale) async {
        do {
            let player = try AVAudioPlayer(contentsOf: wav)
            self.player = player
            player.delegate = self
            player.prepareToPlay()
            // [LOUD-TTS] Spoken responses get the loudness-optimized
            // session mode for the duration of the playback (restored by
            // settlePlayback and cancel() below).
            ResponsePlaybackModeSeam.begin()
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
        ResponsePlaybackModeSeam.end()
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

// MARK: - Warm-start seam (boot warm phase)

/// PiperVoiceSpeaker is the production speaker, so it is the TTS warm
/// seam the boot's warm phase constructs the sherpa engines through.
extension PiperVoiceSpeaker: TTSVoiceWarming {}

// MARK: - Ack-cache warm seam ([LAT-M2])

/// PiperVoiceSpeaker is also the ack-cache warm seam: it owns the
/// engine, the model store, and the voice resolution ladder, so the
/// pre-acks are synthesized with exactly the voice the next reply will
/// use. The build runs DETACHED (it must never hold the warm queue or
/// any boot stage) and reports per-build observability events —
/// `ack_cache`/`warm` started/ready/partial/failed.
extension PiperVoiceSpeaker: AckCachePreSynthesizing {

    func buildAckCache(locale: Locale,
                       completion: @escaping (AckCacheWarmResult) -> Void) {
        let spec = AckVoiceSpec.resolve(locale: locale)
        guard let voiceDir = modelStore.ttsVoiceDirectory(for: spec.voiceID)
                ?? modelStore.installBundledTTSVoice(for: spec.voiceID,
                                                     bundle: bundle) else {
            emitAckWarm(outcome: "failed", reason: "voice_missing",
                        durationMs: nil, spec: spec)
            completion(.failed(reason: "voice_missing"))
            return
        }
        let variants = (1...3)
            .map { AckCacheBuilder.Variant(
                index: $0,
                text: L10n.str("voiceAck.moment\($0)", locale: locale)) }
            .filter { !$0.text.isEmpty }
        guard !variants.isEmpty else {
            emitAckWarm(outcome: "failed", reason: "catalog_empty",
                        durationMs: nil, spec: spec)
            completion(.failed(reason: "catalog_empty"))
            return
        }
        emitAckWarm(outcome: "started", reason: nil, durationMs: nil, spec: spec)
        let cache = ackCache
        let engine = engine
        Task.detached(priority: .utility) {
            let start = CFAbsoluteTimeGetCurrent()
            let result = AckCacheBuilder.build(
                engine: engine,
                voiceDirectory: voiceDir,
                speed: Self.defaultSpeed,
                variants: variants,
                spec: spec,
                cache: cache)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            switch result {
            case .ready:
                self.emitAckWarm(outcome: "ready", reason: nil,
                                 durationMs: ms, spec: spec)
            case .partial(let built):
                self.emitAckWarm(outcome: "partial",
                                 reason: "variants_built_\(built)",
                                 durationMs: ms, spec: spec)
            case .failed(let reason):
                self.emitAckWarm(outcome: "failed", reason: reason,
                                 durationMs: ms, spec: spec)
            }
            completion(result)
        }
    }

    /// Per-build event on the `ack_cache` component — PII-free catalog
    /// ids + locale only, never ack audio or text.
    private func emitAckWarm(outcome: String,
                             reason: String?,
                             durationMs: Int?,
                             spec: AckVoiceSpec) {
        observabilityBus.emit(ObservabilityEvent(
            component: "ack_cache",
            eventType: "warm",
            durationMs: durationMs,
            outcome: outcome,
            errorCode: outcome == "failed" ? reason : nil,
            metadata: [
                "voice": spec.voiceID.rawValue,
                "speaker": "\(spec.speakerID)",
                "locale": spec.locale.identifier,
            ]
        ))
    }
}
