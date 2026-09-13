import Foundation

// MARK: - Response voice (voice-personalisation P0, slice B)

/// A user-selectable reply voice: one catalog TTS voice plus (for
/// multi-speaker voices) a speaker id.
///
/// Speaker counts below are VERIFIED facts about the shipped artifacts,
/// checked 2026-09-08 (docs/research-sections/response-voice.md §3):
/// - `piperNepali` (ne_NP-google-medium-int8): its own `onnx.json`
///   INSIDE the app's exact sherpa tarball declares `num_speakers: 18`
///   with an 18-entry speaker_id_map, and the ONNX graph itself exposes
///   a second `sid` input — sherpa's piper path feeds the sid tensor
///   exactly when input #4 is named "sid"
///   (sherpa-onnx/csrc/offline-tts-vits-model.cc, `RunVitsPiperOrCoqui`),
///   so sids 1-17 are REAL alternate speakers with zero download.
///   A listening pass on speakers 1-17 is still a documented follow-up
///   (research open question 1) — the picker previews each before use,
///   and no quality claim is made anywhere.
/// - `piperNepaliChitwan` (ne_NP-chitwan-medium-int8): `num_speakers: 1`
///   and no `sid` graph input — a single voice.
/// - Every other catalog TTS voice is single-speaker by the same check.
struct ResponseVoice: Codable, Equatable, Identifiable {
    var voiceID: ModelID
    var speakerID: Int

    var id: String { "\(voiceID.rawValue)#\(speakerID)" }

    init(voiceID: ModelID, speakerID: Int = 0) {
        self.voiceID = voiceID
        self.speakerID = speakerID
    }

    /// Verified speaker counts of the shipped TTS artifacts (see header).
    static func speakerCount(for voiceID: ModelID) -> Int {
        switch voiceID {
        case ModelCatalog.piperNepali: return 18
        case ModelCatalog.piperNepaliChitwan: return 1
        default: return 1
        }
    }

    /// Speaker ids 0..<count — the ids the sherpa `sid` input accepts.
    static func speakerIDs(for voiceID: ModelID) -> Range<Int> {
        0..<speakerCount(for: voiceID)
    }

    /// 1-based display numbering (sid 0 = "Voice 1" — today's voice).
    var displayNumber: Int { speakerID + 1 }

    /// Repairs a stored choice against the current catalog + speaker
    /// counts; nil when the voice is no longer a catalog TTS entry.
    /// Honest invalidation: a stale/foreign selection must fall back to
    /// the locale default rather than silently route somewhere odd.
    func sanitised() -> ResponseVoice? {
        guard let entry = ModelCatalog.entry(for: voiceID), entry.kind == .tts,
              Self.speakerIDs(for: voiceID).contains(speakerID) else {
            return nil
        }
        return self
    }
}

// MARK: - Persisted choice + one-shot audition channel

/// The "which voice should the assistant reply in" persisted choice,
/// AppLanguage-style UserDefaults persistence
/// (docs/research-sections/response-voice.md §7), plus the ONE-SHOT
/// AUDITION channel that lets the Settings picker hear a voice that is
/// NOT yet the live choice.
///
/// Why a channel at all: every utterance funnels through
/// `coordinator.speak(text:)` → SpeakQueue → the shared speaker with NO
/// voice parameter (all speech goes through the single shared speaker,
/// research §1), and `PiperVoiceSpeaker` must stay reachable without
/// touching the coordinator/queue seams. An audition request is the
/// per-utterance override: `PiperVoiceSpeaker.speak` consumes it only
/// when the utterance text equals the requested text, so a preview can
/// never leak into unrelated replies and the live voice never changes
/// before an explicit confirm (research §6).
struct VoiceAuditionRequest: Codable, Equatable {
    var voice: ResponseVoice
    /// The exact utterance text the audition rides on — the Settings
    /// sample sentence. The speaker consumes the request only for an
    /// utterance whose text matches.
    var text: String
    var requestedAt: Date
}

enum ResponseVoiceSelection {

    // MARK: Persisted choice (locale default until the user picks)

    private static let selectionKey = "ttsResponseVoiceSelection"
    private static let auditionKey = "ttsVoiceAuditionRequest"
    /// Per-language memory of the user's OWN voice picks (2026-09-13,
    /// fix 2) — see `remember(_:for:)`.
    private static let preferenceByLanguageKey = "ttsVoicePreferenceByLanguage"

    /// How long a pending audition request stays valid. Bounded so a
    /// request whose sample never spoke (queue preempted, screen left)
    /// cannot change a much-later utterance.
    static let auditionTTL: TimeInterval = 120

    /// The persisted choice, sanitised against the catalog. Nil = no
    /// choice yet — the locale default (google-medium speaker 0) rules,
    /// which is byte-identical to today's behavior.
    static func persisted(defaults: UserDefaults = .standard) -> ResponseVoice? {
        decode(ResponseVoice.self, key: selectionKey, defaults: defaults)?.sanitised()
    }

    /// True when the effective Nepali voice differs from the locale
    /// default (google-medium, speaker 0) — used by Settings to mark the
    /// current row and by tests.
    static func isDefault(_ voice: ResponseVoice) -> Bool {
        voice.voiceID == ModelCatalog.piperNepali && voice.speakerID == 0
    }

    /// Applies a confirmed choice. Refuses (returns false) a voice that
    /// sanitisation rejects — the caller keeps the previous choice.
    @discardableResult
    static func apply(_ voice: ResponseVoice,
                      defaults: UserDefaults = .standard) -> Bool {
        guard let clean = voice.sanitised() else { return false }
        encode(clean, key: selectionKey, defaults: defaults)
        return true
    }

    /// Clears the choice back to the locale default (Settings "Google —
    /// Voice 1" row calls this so the default is never orphaned).
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: selectionKey)
    }

    // MARK: Per-language memory of the user's own picks (2026-09-13, fix 2)

    /// The voices the user has EXPLICITLY picked, keyed by the app
    /// language they were picked in (ISO 639-1, lowercased). Stored under
    /// `ttsVoicePreferenceByLanguage` as a JSON `[language: ResponseVoice]`
    /// dictionary (the whole voice, not the bare id — a speaker choice like
    /// google-medium's speaker 5 is part of the pick).
    ///
    /// Why this exists: the app-language switch (LanguageModelResolver)
    /// has to move the reply voice away from a voice that cannot speak the
    /// new language, and the switch back used to land on the DEFAULT for
    /// the language — silently destroying a custom pick (e.g. chitwan) an
    /// en→ne→en round trip never intended to touch. The remembered pick is
    /// what the resolver prefers when returning to a language, and it is
    /// only ever written on an explicit user pick (`remember`), never by
    /// the automatic switch itself (otherwise the switch-back would
    /// overwrite the very pick it is supposed to restore).
    ///
    /// Values are returned RAW (undecoded/unvalidated aside from JSON
    /// decoding): a stale voice id must be ignored by the reader
    /// (`LanguageModelResolver`), never deleted — storage the user did not
    /// touch stays untouched.
    static func rememberedVoices(defaults: UserDefaults = .standard) -> [String: ResponseVoice] {
        decode([String: ResponseVoice].self,
               key: preferenceByLanguageKey,
               defaults: defaults) ?? [:]
    }

    /// Records an explicit pick of `voice` made while the app language was
    /// `language`. Refuses (returns false) a voice sanitisation rejects, so
    /// a non-catalog or out-of-range pick never enters the memory.
    @discardableResult
    static func remember(_ voice: ResponseVoice,
                         for language: String,
                         defaults: UserDefaults = .standard) -> Bool {
        guard let clean = voice.sanitised() else { return false }
        var map = rememberedVoices(defaults: defaults)
        map[language.lowercased()] = clean
        encode(map, key: preferenceByLanguageKey, defaults: defaults)
        return true
    }

    /// Test seam: drops the per-language memory entirely (the main
    /// selection is NOT touched — see `clear`).
    static func clearRememberedVoices(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: preferenceByLanguageKey)
    }

    // MARK: One-shot audition channel (preview; never the live voice)

    /// Registers an audition request: the NEXT utterance whose text is
    /// exactly `text` speaks with `voice` once, then the request is gone.
    /// Call this immediately before `coordinator.speak(text:)`.
    static func requestAudition(of voice: ResponseVoice,
                                for text: String,
                                at date: Date = Date(),
                                defaults: UserDefaults = .standard) {
        encode(VoiceAuditionRequest(voice: voice, text: text, requestedAt: date),
               key: auditionKey, defaults: defaults)
    }

    /// Consumes and returns the pending request when `text` matches and
    /// the request is unexpired; clears stale requests either way.
    static func consumeAudition(matchingText text: String,
                                now: Date = Date(),
                                defaults: UserDefaults = .standard) -> ResponseVoice? {
        guard let request = decode(VoiceAuditionRequest.self,
                                   key: auditionKey, defaults: defaults) else {
            return nil
        }
        guard request.text == text,
              now.timeIntervalSince(request.requestedAt) <= auditionTTL else {
            defaults.removeObject(forKey: auditionKey)
            return nil
        }
        defaults.removeObject(forKey: auditionKey)
        return request.voice
    }

    /// Test seam: drop any pending audition request.
    static func clearAudition(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: auditionKey)
    }

    // MARK: Codable helpers

    private static func decode<T: Decodable>(_ type: T.Type,
                                             key: String,
                                             defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T,
                                             key: String,
                                             defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
