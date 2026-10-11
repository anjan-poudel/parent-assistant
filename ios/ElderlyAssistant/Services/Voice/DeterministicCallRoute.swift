import Foundation

/// Deterministic CALL fallback (2026-10-11). The `call` intent was the
/// only core action whose execution path ran EXCLUSIVELY through the LLM
/// interpreter: when the interpreter was unavailable (brain downloading,
/// jetsam-evicted mid-turn, OOM) or abstained, `routeKeywordRemainder`'s
/// blunt sensitive-call block answered every call-shaped utterance with a
/// fixed, misleading line — `router.sensitiveBlocked`, "calling stays off
/// until secure authentication is ready". No such auth gate exists: the
/// speaker-biometric service's CommandRouter gating was never wired
/// (`SpeakerBiometricService` — NOT WIRED list, doc §3.1), and the real
/// gate is the spoken yes/no confirmation every call path already shares.
/// The elder heard a permanent-sounding refusal for what was really "the
/// interpreter didn't parse this".
///
/// This type closes that gap deterministically, mirroring the
/// voice-contact-search pattern: a direct-call utterance ("छोरालाई फोन
/// गर", "call maiya") is stripped of call verbs / app words / suffixes
/// and the remainder is a NAME QUERY for the coordinator's EXISTING
/// `requestCallConfirmation` seam — which resolves against family
/// contacts via `ContactResolver` (threshold + ambiguity margin, never
/// guesses a person) and asks the same spoken confirmation the LLM path
/// uses. The confirmation IS the gate; nothing here dials anything, and
/// every extracted query is disclosed back to the elder before any
/// action is pended.
enum DeterministicCallRoute {

    /// What a transcript means for the deterministic call fallback.
    enum Decision: Equatable {
        /// Not a direct call request — route on (or fall through) as
        /// before.
        case notDirectCall
        /// Call-shaped, and a name candidate survived extraction.
        case call(query: String)
        /// Call-shaped, but nothing usable survived extraction (no name
        /// given, or only pronouns/drop words).
        case callNoName
    }

    // MARK: - Call-specific drop vocabulary

    /// Latin app/verb words dropped by CONTAINMENT — safe because no
    /// real name contains them ("viberma", "whatsappma" romanized
    /// compounds are dropped whole).
    private static let latinContainmentDrops = [
        "viber", "whatsapp", "facetime", "messenger", "video", "audio"
    ]
    /// Latin call verbs dropped WHOLE-TOKEN only — containment would eat
    /// real names ("call" ⊂ "callie").
    private static let latinExactDrops = [
        "call", "calls", "calling", "dial", "dials",
        "someone", "somebody", "anyone", "anybody"
    ]
    /// Devanagari app words dropped by containment — no real name
    /// contains them ("ह्वाट्सएपमा", "भिडियोकल" are dropped whole).
    /// All three WhatsApp spellings in the router's vocabulary are
    /// covered (ह्वाट्सएप / वाट्सएप / व्हाट्सएप — see `sensitiveCallPhrases`).
    private static let devanagariContainmentDrops = [
        "भिडियो", "ह्वाट्सएप", "वाट्सएप", "व्हाट्सएप", "म्यासेन्जर", "मेसेन्जर",
        "फेसटाइम", "भाइबर"
    ]
    /// Devanagari words dropped WHOLE-TOKEN only: "कल" containment would
    /// eat a real name ("कल" ⊂ "कल्याणी"). The indefinite/third-person
    /// pronouns are drops only as bare stems — their dative forms
    /// ("कसैलाई") are suffix-stripped first in `callQuery` and then hit
    /// this same list. The लगाऊ-family verbs are the call forms of
    /// "फोन लगाऊ" / "नम्बर लगाऊ" — the shared extractor's drop table
    /// covers only the गर-/खोज-families, so the call-specific verbs are
    /// dropped here (whole-token, never containment: "लगाउ" could fuse
    /// into nothing real, but containment would be a new trap class for
    /// zero gain).
    private static let devanagariExactDrops = [
        "कल", "कसै", "कोही", "कोहि", "कुनै", "उस", "उन", "उनी",
        "लगाऊ", "लगाउ", "लगाउनुहोस्", "लगाउनुस्",
        "लगाइदेऊ", "लगाइदेउ", "लगाइदिनु"
    ]

    // MARK: - Decision

    /// Lowercases and decides, exactly like the sibling pre-route stages.
    /// The direct-call shape test reuses `VoiceContactSearchRoute`'s
    /// widened `isDirectCallUtterance` (one table, never duplicated —
    /// same extraction reason as the MTC barge-in predicate), plus a
    /// LOCAL bare-फोन branch (see below) that deliberately does NOT
    /// enter the shared table (there, it would veto the contact-search
    /// stage's own "फोन नम्बर खोज" marker).
    static func decide(transcript raw: String) -> Decision {
        let text = raw
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // [CALL-VOCAB] (2026-10-12) A location question is never a call
        // request — the bare-फोन/कल markers must not capture "मेरो फोन
        // कहाँ छ" (where is my phone).
        guard !hasLocationQuestion(text) else { return .notDirectCall }
        let callShaped = VoiceContactSearchRoute.isDirectCallUtterance(text)
            || barePhoneRequest(text)
        guard callShaped else { return .notDirectCall }
        guard let query = callQuery(fromTranscript: text) else {
            return .callNoName
        }
        return .call(query: query)
    }

    /// [CALL-VOCAB] (2026-10-12) Bare "फोन" as the whole request verb —
    /// "स्यानुलाई फोन" (phone Syanu). Field case: the elder drops the
    /// verb, and the shared table cannot carry a bare-फोन marker (it
    /// would veto the contact-search stage's own phone-word markers),
    /// so this branch lives HERE, in the call fallback only.
    static func barePhoneRequest(_ text: String) -> Bool {
        token("फोन", in: text)
    }

    /// Location-question vocabulary — "कहाँ" (where) and friends. A
    /// question word in the utterance means the speaker is asking ABOUT
    /// something, never requesting a call to a person. Devanagari
    /// containment (fused forms like "कहाँछ"); Latin whole-token.
    static func hasLocationQuestion(_ text: String) -> Bool {
        ["कहाँ", "कता", "खोइ"].contains { text.contains($0) }
            || token("where", in: text)
    }

    /// Whole-token match — identical semantics to
    /// `CommandRouter.containsToken` (split on whitespace + punctuation,
    /// exact equality), mirrored here so this type can never depend on
    /// router internals.
    private static func token(_ token: String, in text: String) -> Bool {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .contains { $0 == token }
    }

    /// The extracted name candidate for a call-shaped transcript, or nil
    /// when nothing usable survives. General drop words, possessive/
    /// dative suffixes and honorifics come from
    /// `VoiceContactSearchRoute.extractQuery` (the shared extractor); the
    /// call-specific vocabulary above is stripped first. The suffix
    /// sequence mirrors `extractQuery`'s own (Latin "'s" first, then the
    /// Devanagari possessive/dative list) and runs BEFORE the drop check
    /// so dative pronouns ("कसैलाई", "someone's") are dropped whole
    /// instead of surviving as bare stems.
    static func callQuery(fromTranscript raw: String) -> String? {
        let cleaned = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token -> String in
                var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return t }
                if t.hasSuffix("'s") || t.hasSuffix("’s") {
                    t = String(t.dropLast(2))
                }
                for suffix in ["को", "की", "का", "लाई", "ले"]
                where t.hasSuffix(suffix) && t.count > suffix.count + 1 {
                    t = String(t.dropLast(suffix.count))
                    break
                }
                t = t.trimmingCharacters(
                    in: CharacterSet.punctuationCharacters.union(CharacterSet(charactersIn: "।॥"))
                )
                guard !t.isEmpty else { return t }
                let devanagari = t.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
                if devanagari {
                    if devanagariExactDrops.contains(t)
                        || devanagariContainmentDrops.contains(where: { t.contains($0) }) {
                        return ""
                    }
                } else {
                    if latinExactDrops.contains(t)
                        || latinContainmentDrops.contains(where: { t.contains($0) }) {
                        return ""
                    }
                }
                return t
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return VoiceContactSearchRoute.extractQuery(from: cleaned)
    }
}
