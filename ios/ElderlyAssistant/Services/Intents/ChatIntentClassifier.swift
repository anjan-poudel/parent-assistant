import Foundation

/// Stage 1 of the conversational-augmentation plan: a lightweight, PURE
/// classifier that decides whether an utterance is CHIT-CHAT or a COMMAND
/// — the decision that lets a chat turn take the free-text reply shape
/// while every command utterance keeps today's intent-slot schema,
/// byte-for-byte.
///
/// Why a heuristic and not the encoder: the intent encoder
/// (`IntentEncoderSchema`) is a fine-tuned classification model whose
/// label surface is FROZEN at the 12 schema-v2 actions — adding a `chat`
/// class to it is a retraining change (a later stage of the plan), not a
/// routing change. This classifier therefore sits ABOVE the encoder, in
/// the router's own decision path, and changes nothing about which model
/// serves a turn: it only decides which PROMPT + SCHEMA the generative
/// brain is asked with.
///
/// The rule is deliberately CONSERVATIVE, because the two mistakes are not
/// symmetric:
///   - a false `.command` costs exactly nothing — the utterance takes
///     today's path, unchanged;
///   - a false `.chat` takes a real command off its execution path (the
///     chat shape carries no slots), so every ambiguous shape resolves to
///     `.command`.
///
/// Consequences of that asymmetry, in full:
///   - A content/domain cue anywhere in the utterance forces `.command`,
///     even when the utterance opened as a greeting ("नमस्ते, भोलिको
///     मौसम कस्तो छ?" is a weather question, not small talk).
///   - Chat formulas match the WHOLE normalized utterance — never a
///     prefix — so a longer request that merely contains a polite word
///     ("नमस्ते भन्नुहोस् छोरालाई") is not swallowed by the table.
///   - Questions with any information content stay `.command`: the
///     existing `query` action already answers them with a substantive
///     spoken reply, and the chat shape's free-text field is for
///     utterances that ask for nothing.
///
/// Relationship to the deterministic pre-answers (`TopicPreAnswer`): the
/// router answers `weather`/`time`/`date`/`greeting` topics from its
/// pre-written table BEFORE any interpreter is consulted, so a bare
/// "नमस्ते" is answered deterministically today and never reaches this
/// classifier on the shipped path. Those rows are deliberately KEPT
/// here anyway: the classifier must be correct standalone (it is pure and
/// unit-tested on its own), and the pre-answer table self-excludes
/// call-shaped utterances — the case where a greeting really does have to
/// be routed rather than pre-answered.
///
/// Pure and total: same input ⇒ same decision, no model, no clock, no
/// state, no locale lookup. Matching conventions mirror the house style
/// (`TopicPreAnswer` / `KeywordIntentRule`): lowercase, trim, drop
/// punctuation, collapse whitespace; Devanagari cue words are matched as
/// whole tokens so a fused postposition cannot widen them.
enum ChatIntentClassifier {

    enum Decision: Equatable {
        /// Nothing to execute and nothing to look up — a greeting, thanks,
        /// a farewell, an expression of feeling, or small talk. The brain
        /// is asked with the chat prompt + `LlamaGrammar.chatJSONSchema`.
        case chat
        /// Today's path, unchanged: the intent-slot prompt + command
        /// schema.
        case command
    }

    /// Chit-chat that matches the WHOLE utterance (after normalization).
    /// Exact match is what keeps this table safe: a polite word inside a
    /// longer request can never claim the turn.
    ///
    /// Covers the four shapes the plan names — greeting, thanks, farewell,
    /// feeling/small talk — plus the "how are you / I'm fine" exchange,
    /// which is the most common small-talk pair for this audience.
    static let chatFormulas: Set<String> = [
        // — greetings (see the enum doc: usually pre-answered upstream) —
        "नमस्ते", "नमस्कार", "हेलो", "हाई", "हैलो", "सुप्रभात", "शुभ प्रभात",
        "शुभ रात्री", "शुभ सन्ध्या", "शुभ साँझ",
        "hi", "hello", "hey", "namaste",
        "good morning", "good afternoon", "good evening", "good night",
        // — how are you / I'm fine —
        "कस्तो छ", "कस्तो छ नि", "कस्तो छौ", "कस्तो छन्", "कसरी छ", "कसरी छन्",
        "हजुरलाई कस्तो छ", "तपाईंलाई कस्तो छ", "तपाईलाई कस्तो छ",
        "सञ्चै छ", "सन्चै छ", "सञ्चै छन्", "सन्चै छन्", "सञ्चै छु", "सन्चै छु",
        "म ठीक छु", "ठीक छु", "मलाई ठीक छ", "राम्रो छ", "ठीक छ",
        "खाना खानुभयो", "खाना खानु भयो", "के गर्दै", "के गर्दै हुनुहुन्छ",
        "how are you", "how are you doing", "how is it going", "how is it going",
        "hows it going", "how do you do",
        // The apostrophe forms normalize to their unpunctuated spelling
        // ("i'm fine" → "im fine"), so BOTH spellings are listed — the
        // table is matched against normalized text, never against the
        // transcript as typed.
        "i am fine", "i'm fine", "im fine", "i am good", "i'm good", "im good",
        "i am ok", "i'm ok", "im ok",
        "nice to meet you", "good to see you", "take care",
        // — thanks —
        "धन्यवाद", "धेरै धन्यवाद", "धन्यवाद हजुर", "घन्यवाद",
        "thank you", "thanks", "thank you very much", "many thanks",
        // — farewells —
        "बिदा", "अब बिदा", "फेरि भेटौंला", "भेटौंला", "ल ल बिदा", "जाऊँ है",
        "bye", "goodbye", "bye bye", "see you", "see you later",
        // — feelings / small talk (no request inside) —
        "मलाई एक्लो लाग्छ", "एक्लो लाग्छ", "मलाई दिक्क लाग्छ", "दिक्क लाग्छ",
        "मन दुख्यो", "मलाई राम्रो लागेन", "थकाइ लाग्यो", "मलाई थकाइ लाग्यो",
        "लामो समय भयो", "सम्झे तपाईंलाई", "तपाईंलाई सम्झे",
        "i feel lonely", "i am lonely", "i'm lonely", "im lonely",
        "i am sad", "i'm sad", "im sad",
        "i am tired", "i'm tired", "im tired",
        "i miss you", "long time no see"
    ]

    /// A greeting word that may OPEN a longer chat turn. Only consulted
    /// when the utterance carries no content cue — see `classify`.
    static let greetingOpeners: Set<String> = [
        "नमस्ते", "नमस्कार", "हेलो", "हाई", "हैलो", "सुप्रभात",
        "hi", "hello", "hey", "namaste",
        "good morning", "good afternoon", "good evening"
    ]

    /// What may follow a greeting opener without turning the turn into a
    /// request: a vocative/address term, a discourse filler, or another
    /// greeting ("नमस्ते हजुर", "hello hello"). Anything else after the
    /// opener — a verb, a person, a domain word — leaves the utterance on
    /// the command path, which is what keeps "नमस्ते भन्नुहोस् छोरालाई"
    /// ("say hello to my son") a message request.
    static let greetingFollowUps: Set<String> = [
        "हजुर", "हजुर्", "नि", "नी", "जी", "सर", "म्याडम", "बा", "आमा",
        "दाई", "दिदी", "भाई", "बहिनी", "ल", "हो", "हैन", "फेरि",
        "there", "sir", "madam", "everyone", "all"
    ]

    /// Content/domain cues — the words a real request is made of. Any one
    /// of them anywhere in the utterance resolves to `.command`, whatever
    /// else the utterance contains. Deliberately domain words (things the
    /// assistant can act on or look up) rather than verbs, so everyday
    /// small talk cannot trip them.
    ///
    /// English cues match as whole tokens; Nepali cues match as whole
    /// tokens too (the fused-postposition convention `KeywordIntentRule`
    /// documents), which is why the medication spellings are enumerated.
    static let commandCues: Set<String> = [
        // — calls, messages, people —
        "call", "phone", "facetime", "whatsapp", "viber", "messenger",
        "message", "text", "sms", "send",
        "फोन", "फोनका", "सम्झाउ", "सम्झाउनु", "सम्झाउनुस्", "सम्झाउनुहोस्",
        "पठाउ", "पठाउनु", "पठाउनुस्", "पठाउनुहोस्", "सन्देश", "म्यासेज",
        "भाइबर", "व्हाट्सएप", "मेसेन्जर", "फेसटाइम",
        // — reminders, alarms, time-of-day commands —
        "remind", "reminder", "alarm", "timer", "reminderr",
        "अलार्म", "टाइमर", "रिमाइन्डर", "बजे", "सम्झाउन",
        // — medication / health —
        "medicine", "medication", "pill", "dose", "tablet", "prescription",
        "औषधि", "औषधी", "दवाई", "दबाइ", "दवाइ", "चक्की", "प्रेसर", "सुगर",
        // — calendar / appointments —
        "calendar", "appointment", "event", "schedule", "meeting",
        "पात्रो", "क्यालेन्डर", "भेट", "भेटघाट", "अपोइन्टमेन्ट",
        // — weather / news / search —
        "weather", "forecast", "temperature", "news", "search", "google",
        "मौसम", "खबर", "समाचार", "खोज", "गुगल", "तापक्रम",
        // — media —
        "play", "music", "song", "bhajan", "video", "youtube", "movie",
        "गीत", "भजन", "संगीत", "भिडियो", "युट्युब", "चलचित्र", "बजाउ",
        "बजाउनु", "बजाउनुस्", "बजाउनुहोस्", "हेर", "हेर्नु", "हेर्नुस्",
        // — apps, device actions, directions —
        "open", "camera", "photo", "picture", "navigate", "directions",
        "क्यामेरा", "फोटो", "खोल", "खोल्नु", "खोल्नुस्", "खोल्नुहोस्",
        "कहाँ", "कता", "दिशा", "बाटो",
        // — open questions with content —
        "how much", "how many", "what is", "who is", "when is", "कति", "कहिले",
        "कुन", "के हो", "कति छ", "गणना", "हिसाब"
    ]

    /// The routing decision. See the enum doc for the safety asymmetry.
    static func classify(_ transcript: String) -> Decision {
        let text = normalized(transcript)
        // An empty or punctuation-only utterance is never chat: there is
        // nothing to reply to, and the router's existing empty-transcript
        // handling (sanitiser guard) stays the only path.
        guard !text.isEmpty else { return .command }
        // Content wins over every formula below, always.
        guard !containsCommandCue(in: text) else { return .command }
        if chatFormulas.contains(text) { return .chat }
        // A greeting that opens a longer turn ("नमस्ते हजुर", "hello
        // hello") — only reachable when no content cue fired above, and
        // only when EVERY remaining token is a greeting or an address
        // term. A verb or a person after the opener is a request.
        if let rest = textAfterGreetingOpener(text),
           rest.split(separator: " ").allSatisfy({
               greetingOpeners.contains(String($0)) || greetingFollowUps.contains(String($0))
           }) {
            return .chat
        }
        return .command
    }

    // MARK: - Normalization + matching

    /// Lowercase, strip punctuation (including the Devanagari danda and
    /// the question/exclamation marks an STT transcript carries), collapse
    /// whitespace. Mirrors the house precedent in `TopicPreAnswer` and
    /// `VoiceContactSearchRoute`.
    static func normalized(_ transcript: String) -> String {
        var out = ""
        out.reserveCapacity(transcript.count)
        for scalar in transcript.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                out.unicodeScalars.append(" ")
            } else if CharacterSet.punctuationCharacters.contains(scalar)
                        || CharacterSet.symbols.contains(scalar) {
                // Dropped, not replaced with a space: "नमस्ते।" and
                // "hello!" must normalize to the same formula token.
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Whole-token cue scan. Tokens are compared exactly, and multi-word
    /// cues ("how much") are checked as a phrase over the normalized text.
    private static func containsCommandCue(in text: String) -> Bool {
        let tokens = Set(text.split(separator: " ").map(String.init))
        if !tokens.isDisjoint(with: commandCues) { return true }
        // Multi-word cues that are not single tokens.
        for cue in commandCues where cue.contains(" ") {
            if text.contains(cue) { return true }
        }
        return false
    }

    /// The text that FOLLOWS a leading greeting opener, or nil when the
    /// utterance does not open with one. Longest opener first, so a
    /// multi-word opener ("good morning") is preferred over any single
    /// word that prefixes it; the space requirement is what stops
    /// "helloo" from opening with "hello".
    private static func textAfterGreetingOpener(_ text: String) -> String? {
        let openers = greetingOpeners.sorted { $0.count > $1.count }
        for opener in openers where text.hasPrefix(opener + " ") {
            return String(text.dropFirst(opener.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
