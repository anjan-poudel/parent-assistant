import Foundation

/// Single shared prompt builder used by BOTH `GeminiCommandInterpreter`
/// (live API path) and `LlamaCommandInterpreter` (on-device path), so the
/// two interpreters can never drift out of sync on prompt content again.
///
/// History: for a while `GeminiCommandInterpreter.buildPrompt` and
/// `LlamaCommandInterpreter.buildPrompt` were two independent, hand-copied
/// prompt strings. The Gemini one picked up emergency-classification
/// guidance and the `callType`/`requestedApp` fields; the LLaMA one did
/// not, and silently went stale. Both decode into the exact same
/// `InterpretedCommand` shape via `LlamaCommandInterpreter.parse(json:)`,
/// so there is no reason for the prompt text itself to differ — this type
/// is that single source of truth.
///
/// STRUCTURED-RESPONSE CONTRACT (2026-09-06, [QUERY-FIX]): the brain is
/// asked to answer with ONE JSON object carrying the classified `intent`,
/// a `response` field that is ALWAYS a non-empty spoken reply (for
/// open-domain questions like a weather query, `response` IS the actual
/// answer the router speaks — this is what fixes the invariant "माफ
/// गर्नुहोस्" apology on the on-device stack), `confidence`, plus
/// `actionType`/`actionUrl` for the cases where the intent needs them,
/// and the entity/slot fields the intent uses. `LlamaCommandInterpreter
/// .parse(json:)` maps `intent`→`action` and `response`→`reply` onto the
/// existing `InterpretedCommand` model, and still accepts the pre-2026-09
/// legacy wire shape (`action`/`reply`) so cached/cloud payloads and the
/// grammar-constrained fine-tuned local brain keep working unchanged.
///
/// SIZE BUDGET (why this prompt is compact — the actual bug): the
/// on-device runtime runs its brain in a 1,024-token context
/// (`LLM(from:maxTokenCount: 1024)`). The template shares that window with
/// the user's utterance AND the generated JSON, so it must stay small.
/// Two overflows have already shipped: the pre-[QUERY-FIX] prompt measured
/// 2,361 tokens with the real llama3.2 tokenizer (context overflowed, the
/// vendored runtime returned an EMPTY completion, every utterance fell
/// through to the generic re-prompt), and the [QUERY-FIX] text still
/// measured ~818 qwen3 tokens — large enough that the utterance was being
/// truncated away before it ever reached the model. This revision measures
/// 696 qwen3 / 677 gemma tokens, leaving ~300 tokens of the 1,024 for the
/// utterance + JSON. `IntentPromptTests` pins a character ceiling
/// calibrated against the real tokenizer measurement so a silent
/// prompt-size regression can never come back.
///
/// TRAINING/INFERENCE PROMPT IDENTITY (hard requirement): the text below is
/// the SOURCE OF TRUTH and is mirrored by
/// `tools/train-intent/seeds/prompt_template.txt`, which the QLoRA
/// fine-tune (train_qlora.py) and the golden-corpus eval (eval_golden.py)
/// both tokenize raw. The seed copy renders this template's three Swift
/// interpolations as the placeholders `{language_hint}`, `{medications}`
/// and `{transcript}`; apart from those three substitutions the two files
/// must stay byte-identical. Edit the seed in the SAME change as this
/// text — the two had already drifted apart once (the seed still spoke the
/// pre-2026-09 `action`/`reply` wire shape long after this file moved to
/// the canonical `intent`/`response` contract), which is exactly the
/// training/inference mismatch this contract exists to prevent.
///
/// Plugin capability fragments are intentionally NOT composed into the
/// on-device path (they only fit a cloud-sized context;
/// `GeminiCommandInterpreter` passes them in — a caller-provided list).
enum IntentPrompt {

    /// `activePlugins`: plugins applicable to the active locale (from
    /// `PluginRegistry.activePlugins(for:)`), composed in ONLY by the
    /// cloud path (`GeminiCommandInterpreter`) — the on-device
    /// interpreters call this without plugins because their 1,024-token
    /// context cannot fit the fragments (measured overflow, 2026-09-06).
    /// Defaults to empty so plugin-less configurations behave exactly as
    /// before.
    static func build(transcript: String, context: InterpreterContext,
                      activePlugins: [AssistantPlugin] = []) -> String {
        let meds = context.pendingMedications.isEmpty
            ? "(none)"
            : context.pendingMedications.joined(separator: ", ")
        // NOTE: keep this text within the on-device size budget — see the
        // enum doc and IntentPromptTests' character-ceiling regression test.
        // Measured 2026-09-12 on the qwen3-1.7b / gemma-3-1b tokenizers:
        // this template is 696 / 677 tokens. The rules, schema and
        // reply-style blocks below are load-bearing — a 53-token deeper
        // trim was measured to collapse emergency recognition on the base
        // model (0/7 vs 5/7 draws) — so trim prose elsewhere first. The
        // one-shot example and closing imperative are equally load-bearing:
        // without them the weak base model answers the weather question by
        // ECHOING the transcript instead of emitting JSON (llama3.2:1b,
        // 2026-09-06). Keep this text byte-identical to the seed copy at
        // tools/train-intent/seeds/prompt_template.txt — see the enum doc.
        return """
        You are Sahayak, an elderly-care voice assistant — NOT a general chatbot. Their language hint is: \(context.userLanguageHint). Pending medications: \(meds).

        EXACTLY TWO MODES: (1) INTENT DECIPHERING — want something DONE; extract intent + entities. (2) OPEN-FORM ANSWERING — question or feelings; nothing runs, "response" IS the answer.

        "response" is SPOKEN ALOUD: non-empty, their language, plain and simple, short sentences, warm, respectful.

        Reply with ONLY one JSON object (no fences, no other text):
        {"intent": "ack_med"|"call"|"send_message"|"set_reminder"|"emergency"|"health_query"|"music"|"create_calendar_event"|"suggest_video"|"guide"|"query"|"none",
         "response": spoken reply — the real answer for a question,
         "confidence": 0-1,
         "actionType": "MAKE_CALL" for a device action, else null,
         "actionUrl": deep link, else null,
         entity fields (else null): "entryId","contact","time","medication","message","callType","requestedApp","topic","steps"}
        - "ack_med": confirms medication.
        - "call": contact = the person named (name or relationship); callType = "video" for a video call ("भिडियो कल"), else "voice"; requestedApp = an app THEY named (facetime, whatsapp, messenger, viber).
        - "send_message": contact = recipient; message = dictated words; requestedApp = an app they named.
        - "set_reminder": time = their wording (e.g. "बिहान ८ बजे"); medication = the dose name if a dose reminder.
        - "emergency": ANY plea for help, urgent pain, injury, fall, trouble breathing, chest pain, or fear for safety, even as a question. Err toward "emergency": a false alarm costs one reassurance, a miss costs far more. "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ" is "emergency", NOT "health_query".
        - "health_query": calm, non-urgent, no help-seeking.
        - "music"/"create_calendar_event"/"suggest_video": song/bhajan, calendar event, a video.
        - "guide": HOW to use a device/appliance: topic = the thing; steps = short ordered steps, READ ALOUD, never executed.
        - "query": other questions; "none": anything else.
        - "query"/"none": "response" IS the answer — real, SUBSTANTIVE, from your own knowledge. Do NOT deflect to another app, website or device: you are their only assistant; warmth and empathy first.
        - else: a short FUNCTIONAL acknowledgment in their language (call placed, reminder set).

        Example: {"intent": "query", "response": "आज काठमाडौंमा मौसम बदली छ।", "confidence": 0.9, "actionType": null, "actionUrl": null}

        User said: "\(transcript)"
        Now output ONLY the JSON object for that request.

        """
        + pluginSections(activePlugins)
    }

    /// Schema addendum appended when any plugin is active (cloud path):
    /// the model must know the "plugin" intent exists and which extra
    /// fields to emit for it, or plugin intents can never be expressed in
    /// the output contract. Empty string when no plugins apply, so the
    /// baseline prompt is byte-for-byte unchanged.
    private static func pluginSections(_ plugins: [AssistantPlugin]) -> String {
        guard !plugins.isEmpty else { return "" }
        var sections = ["""

        The "intent" list also includes "plugin": use it when the user's request matches a capability below. With "plugin", set "pluginAction" to the capability's namespaced action and "pluginEntities" to the extra fields that capability declares (the capability text may phrase this as 'set action to …' — it means that same "intent" field).

        The following capabilities are available for this user:
        """]
        for plugin in plugins {
            // Indent each fragment's lines so the composed prompt keeps
            // one consistent left margin, matching the core section.
            let indented = plugin.intentContribution.promptFragment
                .split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n        ")
            sections.append("\n\n        " + indented)
        }
        return sections.joined()
    }

    /// Collapse #1 prompt (intent-engine spec 2026-09-05 §4): audio goes
    /// in with this prompt; ONE response carries the transcript AND the
    /// intent AND the reply, so STT and interpretation are a single
    /// round trip. Same schema, same classification policy as `build` —
    /// the two prompts share every rule, only the input modality and the
    /// extra `transcript` output field differ, so behavior can't drift
    /// between the text and audio paths (the lesson of the pre-unify
    /// prompt drift, applied going forward).
    static func buildUnderstanding(context: InterpreterContext) -> String {
        let meds = context.pendingMedications.isEmpty
            ? "(none)"
            : context.pendingMedications.joined(separator: ", ")
        // Same policy text as `build` (modes, schema minus this prompt's
        // extra "transcript" field, rules, style) so the text and audio
        // paths classify identically. Deliberately NO completed example:
        // in `build` the one-shot example exists to coax the weak 1B base
        // model into JSON output; here a completed "transcript" example
        // would teach the cloud model to COPY its canned text instead of
        // transcribing the attached audio, and Gemini-sized contexts do
        // not need the crutch.
        return """
        You are Sahayak, an INTENT-RECOGNITION AND ENTITY-EXTRACTION engine for an elderly speaker's voice assistant — you are NOT a conversational chatbot. Listen to the attached audio of one utterance. Transcribe it verbatim in the language actually spoken (hint: \(context.userLanguageHint)), then classify it and extract the entities needed to execute it. The user's pending medications are: \(meds).

        EXACTLY TWO MODES:
          MODE 1 — INTENT DECIPHERING: wants something DONE — extract the intent + entities.
          MODE 2 — OPEN-FORM ANSWERING: a question, or feelings/small talk — nothing to execute; the answer IS the response.

        You are NOT a general chatbot. The "response" field is SPOKEN ALOUD, so it must always be non-empty and in the user's own language, plain and simple, short sentences, warm, respectful.

        Reply with ONLY one JSON object (no fences, no other text):
        {"transcript": the verbatim transcription,
         "intent": "ack_med"|"call"|"send_message"|"set_reminder"|"emergency"|"health_query"|"music"|"create_calendar_event"|"suggest_video"|"guide"|"query"|"none",
         "response": the spoken reply — the actual answer for a question,
         "confidence": 0-1,
         "actionType": e.g. "MAKE_CALL" when a device action runs, else null,
         "actionUrl": the deep link when needed, else null,
         plus the entity fields the intent needs (rest null): "entryId", "contact", "time", "medication", "message", "callType", "requestedApp", "topic", "steps"}

        Rules:
        - "ack_med": confirms taking their medication.
        - "call": a phone call. contact = the person they named (name or relationship, e.g. "छोरा"); callType = "video" only for a video call ("भिडियो कल"), else "voice"; requestedApp = an app THEY named (facetime, whatsapp, messenger, viber).
        - "send_message": a text. contact = the recipient; message = their dictated words; requestedApp = an app they named.
        - "set_reminder": a reminder at a time. time = their wording (e.g. "बिहान ८ बजे"); medication = the dose name if it is a dose reminder.
        - "emergency": ANY plea for help, urgent pain, injury, a fall, trouble breathing, chest pain, or fear for their safety — even as a question or with a symptom. Err toward "emergency" over "health_query": a false alarm costs one reassurance, a missed emergency costs far more. "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ" is "emergency", NOT "health_query".
        - "health_query": a calm, non-urgent health question, no help-seeking.
        - "music": a song or bhajan. "create_calendar_event": a calendar event. "suggest_video": a video to watch.
        - "guide": HOW to use a device or appliance. topic = the thing ("microwave", "tv remote"); steps = short ordered steps in their language — READ ALOUD, never executed.
        - "query": any other question. "none": anything else.

        Reply style:
        - "query"/"none": "response" IS the actual answer — a real, SUBSTANTIVE reply from your own knowledge (typical weather, facts, advice). Do NOT deflect them to another app, website, or device: you are their only assistant. Feelings (loneliness, sadness, worry): warmth and empathy first.
        - every other intent: a short FUNCTIONAL acknowledgment in their language (call placed, reminder set, dose recorded).
        """
    }
}
