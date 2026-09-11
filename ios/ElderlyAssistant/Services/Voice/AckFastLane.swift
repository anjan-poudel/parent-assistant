import Foundation
import AVFoundation

// MARK: - Ack fast lane ([LAT-M2], 2026-09-11)
//
// The pre-acknowledgment ("एक छिन…" / "one moment…") is the ONE utterance
// whose latency the user feels directly: it must start within ~200 ms of
// the routing decision or the assistant reads as sluggish for the whole
// slow-stage round-trip it fronts. Before this task the ack was spoken
// through the normal TTS path — the ack itself PAID synthesis latency
// (engine queue + VITS generation + WAV write) before its first sample
// reached the speaker.
//
// The fast lane removes synthesis from the ack path entirely:
//
//  1. `AckAudioCache` — a file-backed store of pre-synthesized ack WAVs
//     (Caches/ack-audio/<locale>-<voiceID>-s<speakerID>/ack1..3.wav).
//  2. `AckCacheBuilder` — synthesizes the three variants through the
//     shared `TTSEngine` and stores them. Pure with respect to the
//     caller: no audio IO, no session touches — unit-testable with a
//     fake engine.
//  3. `AckFastLanePlayer` — plays the cached WAV directly through
//     AVAudioPlayer. Session handling is the same world as the bell
//     player's (TimerAlarmBellPlayer): begin a playback-optimized mode
//     before playing, restore exactly once when playback settles.
//     Deliberately the VOICE-reply seam (`ResponsePlaybackModeSeam`)
//     rather than the bell's save/restore-category switch: the bell
//     owns the phone (mic unavailable is fine), while an ack is a voice
//     reply inside the always-on loop — switching the shared session to
//     `.playback` mid-turn would strand the mic. The seam is
//     depth-counted (AudioSessionManager), so an ack overlapping the
//     result utterance's playback nests safely.
//
// Warm-time build: after the warm-start plan's TTS step settles (the
// engine exists), `AppCoordinator` asks the speaker seam
// (`AckCachePreSynthesizing.buildAckCache`) to pre-synthesize the three
// variants for the ACTIVE locale. Gated by the same warm-start
// preference and skipped on the simulator (the same reasons the TTS
// warm itself is — see WarmStartPlanner.ttsSteps).
//
// Honest limits (documented, not worked around):
//  - A voice-picker change (a non-default Nepali voice/speaker) changes
//    the cache key, so the previously built WAVs miss until the next
//    warm rebuild — the ack then falls back to synthesis (the pre-task
//    behavior) and the miss is logged, never silently degraded.
//  - A locale switch after warm misses the same way. English-variant
//    acks on a Nepali UI (or vice versa) are not pre-built (active
//    locale only, per the plan).
//  - If the ack is still playing when the result utterance's synthesis
//    begins, PiperVoiceSpeaker's per-utterance cancel ends the playback
//    seam; the depth counter restores the capture mode for the ack's
//    tail. The window is bounded by the LLM round-trip (seconds), so
//    the overlap is vanishing in practice.
//  - Cache files are regenerated per warm; orphaned files from old
//    voices/locales are inert (a miss, not a wrong-voice ack) — the
//    cache is keyed, so a stale file can never play for the wrong
//    voice.

// MARK: - Router seam

/// [LAT-M2] The router's seam for the ack fast lane. Nil (the default)
/// keeps the router on the pre-task synthesis path byte-identically —
/// the same dormant-seam pattern as the search/YouTube tool seams.
protocol PreAckPlaying: AnyObject {
    /// Fired exactly once per started cached-ack playback when it
    /// settles (finished, decode error, or cancelled). The router uses
    /// it for the per-utterance speak bookkeeping
    /// (`noteSpeakFinished` / `noteSpeakingEnded`), mirroring the
    /// `ReplySpeakLane` tail's semantics.
    var onPlaybackFinished: (() -> Void)? { get set }

    /// Plays the cached pre-ack WAV for `variant` (1...3) in `locale`
    /// directly — no synthesis. Returns true when a cached asset
    /// existed and playback started; false = miss or player failure,
    /// and the caller falls back to the synthesis path.
    @discardableResult
    func playCachedAck(variant: Int, locale: Locale) -> Bool

    func cancel()
}

// MARK: - Cache slot resolution

/// The voice+speaker+locale a pre-ack cache slot belongs to. The cache
/// key is the whole spec: a WAV synthesized with voice A must never
/// play when the effective reply voice is B.
struct AckVoiceSpec: Equatable {
    var voiceID: ModelID
    var speakerID: Int
    var locale: Locale

    /// The voice+speaker the pre-acks for `locale` synthesize with —
    /// mirrors `PiperVoiceSpeaker.resolveVoiceSpec`'s selection ladder
    /// WITHOUT the audition branch (an audition request matches only
    /// its own sample text, which the ack texts can never be). The
    /// persisted user choice applies to Nepali utterances only, exactly
    /// like the speaker.
    static func resolve(locale: Locale) -> AckVoiceSpec {
        if locale.languageCode?.hasPrefix("ne") == true,
           let chosen = ResponseVoiceSelection.persisted(),
           !ResponseVoiceSelection.isDefault(chosen) {
            return AckVoiceSpec(voiceID: chosen.voiceID,
                                speakerID: chosen.speakerID,
                                locale: locale)
        }
        return AckVoiceSpec(voiceID: PiperVoiceSpeaker.voiceID(for: locale),
                            speakerID: 0,
                            locale: locale)
    }
}

// MARK: - File-backed WAV store

/// [LAT-M2] File-backed store of pre-synthesized ack WAVs. The FILES
/// are the shared state — the warm-time builder (speaker seam) writes
/// them, the player reads them; the one production instance is created
/// by `AppCoordinator` and handed to both. Thread-safe: writes run on
/// the warm/synthesis queue, reads on main (a miss only ever costs an
/// existence check — the fast path's budget).
final class AckAudioCache {

    /// Production cache root: Caches/ack-audio (per-app sandbox).
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory,
                                      in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("ack-audio", isDirectory: true)
    }

    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(root: URL = AckAudioCache.defaultDirectory(),
         fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    private func directory(spec: AckVoiceSpec) -> URL {
        root
            .appendingPathComponent(
                "\(spec.locale.identifier)-\(spec.voiceID.rawValue)-s\(spec.speakerID)",
                isDirectory: true)
    }

    /// The cached WAV for `variant`, or nil when the slot was never
    /// built (or was cleared). Existence-checked on every call — a
    /// stale file removed by the OS cache eviction reads as a miss.
    func wavURL(variant: Int, spec: AckVoiceSpec) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let url = directory(spec: spec).appendingPathComponent("ack\(variant).wav")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Moves a synthesized WAV into its cache slot (replacing any
    /// previous build of the same slot).
    @discardableResult
    func store(wav: URL, variant: Int, spec: AckVoiceSpec) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let dir = directory(spec: spec)
        try fileManager.createDirectory(at: dir,
                                        withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("ack\(variant).wav")
        try? fileManager.removeItem(at: dest)
        try fileManager.moveItem(at: wav, to: dest)
        return dest
    }

    /// Drops every cached slot for one spec (a voice-picker change's
    /// stale audio). Inert files never play (keyed lookup), so this is
    /// hygiene, not correctness.
    func remove(spec: AckVoiceSpec) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: directory(spec: spec))
    }
}

// MARK: - Warm-time builder

/// [LAT-M2] One warm build's terminal outcome. The strings are event
/// reasons, never user copy.
enum AckCacheWarmResult: Equatable {
    case ready
    case partial(built: Int)
    case failed(reason: String)
}

/// [LAT-M2] Pure builder: synthesizes the ack variants through the
/// shared `TTSEngine` and stores them in the cache. No audio IO, no
/// session touches — unit-tested with a fake engine. Callers serialize
/// it themselves (the warm queue / the engine's own queue): sherpa
/// synthesis is already serialized on its engine queue.
enum AckCacheBuilder {

    /// One pre-ack slot: the catalog variant number (1...3) and its
    /// localized text.
    struct Variant: Equatable {
        var index: Int
        var text: String
    }

    /// Builds every variant; the engine's returned WAV is MOVED into
    /// the cache (leftovers are removed on failure).
    static func build(engine: TTSEngine,
                      voiceDirectory: URL,
                      speed: Float,
                      variants: [Variant],
                      spec: AckVoiceSpec,
                      cache: AckAudioCache) -> AckCacheWarmResult {
        guard !variants.isEmpty else { return .failed(reason: "no_variants") }
        var built = 0
        var firstFailure: String?
        for variant in variants {
            do {
                let wav = try engine.synthesize(variant.text,
                                                voiceDirectory: voiceDirectory,
                                                speed: speed,
                                                speakerID: spec.speakerID)
                do {
                    try cache.store(wav: wav, variant: variant.index, spec: spec)
                    built += 1
                } catch {
                    try? FileManager.default.removeItem(at: wav)
                    firstFailure = firstFailure ?? "store_failed"
                }
            } catch {
                firstFailure = firstFailure ?? "synthesis_failed"
            }
        }
        if built == variants.count { return .ready }
        if built > 0 { return .partial(built: built) }
        return .failed(reason: firstFailure ?? "unknown")
    }
}

// MARK: - Speaker warm seam

/// [LAT-M2] Warm-time seam on the speaker: pre-synthesizes the three
/// ack variants for `locale` into the shared `AckAudioCache`, using the
/// speaker's resolved voice and its own `TTSEngine` (the warm engine).
/// `PiperVoiceSpeaker` conforms. `completion` reports the build outcome
/// on an arbitrary queue — never assumed main.
protocol AckCachePreSynthesizing: AnyObject {
    func buildAckCache(locale: Locale,
                       completion: @escaping (AckCacheWarmResult) -> Void)
}

// MARK: - Production player

/// [LAT-M2] The production `PreAckPlaying`: AVAudioPlayer over the
/// cached WAV, session handling per the voice-reply seam (see the file
/// header for the bell-player comparison). Honest failures: a miss
/// returns false untouched (no session churn, no event — the ROUTER
/// logs `ack_cache_miss`); a player setup failure emits
/// `ack_player_failed` and returns false so the router still falls
/// back to synthesis. `onPlaybackFinished` fires exactly once per
/// started playback — finish, decode error, or cancel — so the
/// router's speak bookkeeping stays balanced.
final class AckFastLanePlayer: NSObject, PreAckPlaying, AVAudioPlayerDelegate {

    var onPlaybackFinished: (() -> Void)?

    private let cache: AckAudioCache
    private let observabilityBus: ObservabilityBus
    /// Injectable for tests; production builds the real AVAudioPlayer.
    private let playerFactory: (URL) throws -> AVAudioPlayer
    private var player: AVAudioPlayer?
    private var playbackPending = false

    init(cache: AckAudioCache,
         observabilityBus: ObservabilityBus,
         playerFactory: @escaping (URL) throws -> AVAudioPlayer = {
             try AVAudioPlayer(contentsOf: $0)
         }) {
        self.cache = cache
        self.observabilityBus = observabilityBus
        self.playerFactory = playerFactory
        super.init()
    }

    @discardableResult
    func playCachedAck(variant: Int, locale: Locale) -> Bool {
        let spec = AckVoiceSpec.resolve(locale: locale)
        guard let url = cache.wavURL(variant: variant, spec: spec) else {
            return false   // miss — the router logs + falls back
        }
        // A second ack while one still plays: the previous settles
        // first (its finished note fires), then the new one starts.
        cancel()
        do {
            let setupStart = CFAbsoluteTimeGetCurrent()
            let newPlayer = try playerFactory(url)
            newPlayer.delegate = self
            newPlayer.volume = 1.0
            newPlayer.prepareToPlay()
            let setupMs = Int((CFAbsoluteTimeGetCurrent() - setupStart) * 1000)
            player = newPlayer
            playbackPending = true
            // [LAT-M2] Voice-reply playback mode for the ack's duration
            // (depth-counted — nests with the result utterance's own
            // begin/end).
            ResponsePlaybackModeSeam.begin()
            newPlayer.play()
            emit("ack_cache_hit", outcome: "success",
                 durationMs: setupMs, spec: spec)
            return true
        } catch {
            emit("ack_player_failed", outcome: "failure",
                 errorCode: "\((error as NSError).domain)", spec: spec)
            return false
        }
    }

    func cancel() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        settle()
    }

    /// Fires the finished note exactly once per started playback.
    private func settle() {
        guard playbackPending else { return }
        playbackPending = false
        ResponsePlaybackModeSeam.end()
        onPlaybackFinished?()
    }

    // MARK: AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                     successfully flag: Bool) {
        self.player = nil
        settle()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer,
                                        error: Error?) {
        self.player = nil
        settle()
    }

    // MARK: Observability

    private func emit(_ eventType: String, outcome: String,
                      durationMs: Int? = nil,
                      errorCode: String? = nil,
                      spec: AckVoiceSpec) {
        observabilityBus.emit(ObservabilityEvent(
            component: "ack_cache",
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [
                "voice": spec.voiceID.rawValue,
                "speaker": "\(spec.speakerID)",
                "locale": spec.locale.identifier,
            ]
        ))
    }
}
