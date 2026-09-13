import Foundation

/// [T-037-a] The label surface the intent encoder runtime is allowed to
/// emit — schema v2, frozen here as an explicit allow-list.
///
/// The encoder is a classification model, not a generative one: it emits an
/// action id and a per-token BIO tag id, and NOTHING in the CoreML graph
/// constrains those ids to the schema the router understands (there is no
/// GBNF grammar on this path — the plan document's "defense in depth
/// replaces grammar enforcement"). Every decoder output therefore passes
/// through this file before it can become an `InterpretedCommand`, and any
/// value outside these sets abstains instead of producing a fabricated
/// action or slot.
///
/// Keep in sync with:
///   - `LlamaGrammar.commandJSONSchema` / `LocalIntentInterpreter.intentSchema`
///     (the two LLM-side pinned copies of the same 12-action catalog), and
///   - `InterpretedCommand.Action`.
enum IntentEncoderSchema {

    /// The 12 intent/v2 catalog actions as wire strings — the same enum the
    /// LLM grammar pins. `plugin` is deliberately ABSENT: plugin actions are
    /// contributed at runtime by a registered `AssistantPlugin` and are
    /// never something a fine-tuned encoder may claim (see
    /// `docs/superpowers/specs/2026-09-05-plugin-architecture-design.md`).
    static let actionRawValues: Set<String> = [
        "ack_med", "call", "emergency", "set_reminder", "health_query",
        "music", "send_message", "guide", "create_calendar_event",
        "suggest_video", "query", "none"
    ]

    /// Maps a decoded intent string onto `InterpretedCommand.Action`, or nil
    /// when the value is not one of the 12 schema-v2 actions. The
    /// membership check is explicit (not just `Action(rawValue:)`) so the
    /// plugin escape hatch can never be reached from encoder output.
    static func action(forRawValue raw: String) -> InterpretedCommand.Action? {
        guard actionRawValues.contains(raw) else { return nil }
        return InterpretedCommand.Action(rawValue: raw)
    }

    /// Slot types schema v2 can carry. This is the set T-034 defines spans
    /// for (contact, time, medication, message, topic, app/method).
    ///
    /// A model whose BIO tag set contains anything else cannot have those
    /// tags decoded: the whole output abstains. That rule is what protects
    /// the shipped consumers — `NepaliTimeParser`, `ContactResolver`, and
    /// the medication span that `CommandRouter` uses directly as the
    /// reminder title (`command.medication ?? L10n.str("reminder.defaultTitle")`)
    /// — from a slot whose type the runtime has no contract for.
    ///
    /// NOTE: there is deliberately no `MedicationResolver` referenced here.
    /// T-035 §15.1 records that such a type appears only in spec text and
    /// does not exist under `ios/`; the encoder emits a verbatim span and
    /// nothing in this runtime resolves it against a medication list.
    static let slotTypes: Set<IntentEncoderSlotType> = [
        .contact, .time, .medication, .message, .topic, .app
    ]
}

/// The schema-v2 slot vocabulary, as the encoder's BIO tag names spell it
/// (`B-contact` / `I-contact`).
enum IntentEncoderSlotType: String, CaseIterable, Equatable {
    case contact
    case time
    case medication
    case message
    case topic
    /// "app/method" in T-034 — the surface the user named for a call
    /// ("फोन", "फेसटाइम", "व्हाट्सएप"). Carried into
    /// `InterpretedCommand.requestedApp` when the action is `call`.
    case app
}

/// Versioned description of one encoder artifact: which action ids and BIO
/// tag ids the artifact's output heads index into, and the sequence length
/// its CoreML model was built for.
///
/// Why this must be explicit Swift data and not read from the artifact:
/// the CoreML graph's outputs are bare logits (`intent_logits`,
/// `slot_logits`) — the id→label mapping lives in the TRAINING run's
/// `meta.json`, which is not part of the ModelStore zip. Shipping the
/// mapping with the runtime and versioning it makes a model/runtime
/// mismatch detectable instead of silently mislabelling every utterance.
struct IntentEncoderManifest: Equatable {

    /// Stable id of the model the manifest describes — event metadata only.
    let id: String
    /// Manifest/artifact version — event metadata only.
    let version: String
    /// Ordered intent labels, exactly the order of the intent head's logits
    /// (i.e. the training `meta.json` `intents` array, verbatim).
    let intents: [String]
    /// Ordered BIO tag labels, exactly the order of the slot head's logits
    /// (i.e. the training `meta.json` `tags` array, verbatim).
    let tags: [String]
    /// The `max_len` the exporter traced the model with (RangeDim 1...max).
    let maxSequenceLength: Int
    /// Contract `calibration_temperature` (`applied_in: interpreter_code`):
    /// the intent logits are DIVIDED by this before the softmax, so the
    /// confidence the 0.4/0.7 band policy sees is the calibrated one.
    /// Defaults to 1.0 — the identity, correct for an uncalibrated artifact
    /// such as the T-033 spike. A non-finite or non-positive value falls
    /// back to 1.0 at the decode site rather than producing NaNs.
    let calibrationTemperature: Double

    init(id: String,
         version: String,
         intents: [String],
         tags: [String],
         maxSequenceLength: Int,
         calibrationTemperature: Double = 1.0) {
        self.id = id
        self.version = version
        self.intents = intents
        self.tags = tags
        self.maxSequenceLength = maxSequenceLength
        self.calibrationTemperature = calibrationTemperature
    }

    /// What a decoded tag id means.
    enum TagDecode: Equatable {
        /// `O` — no slot at this token.
        case outside
        /// A schema-v2 slot.
        case slot(IntentEncoderSlotType)
        /// A tag that is NOT in the schema-v2 vocabulary — the caller must
        /// abstain rather than guess a home for it.
        case unknown(String)
    }

    /// Decodes one BIO tag name (`B-contact`, `I-time`, `O`).
    ///
    /// The B-/I- distinction is carried by the surface form only for
    /// alignment; the runtime decodes contiguous runs of a slot type
    /// (mirroring `bakeoff_encoder.spans_from_tags`), so the caller does
    /// not need it separately.
    func decode(tag: String) -> TagDecode {
        if tag == "O" { return .outside }
        let name: String
        if tag.hasPrefix("B-") || tag.hasPrefix("I-") {
            name = String(tag.dropFirst(2))
        } else {
            // A tag shape the BIO scheme does not define — treat as unknown
            // rather than silently dropping a token that may carry a slot.
            return .unknown(tag)
        }
        guard let type = IntentEncoderSlotType(rawValue: name),
              IntentEncoderSchema.slotTypes.contains(type) else {
            return .unknown(tag)
        }
        return .slot(type)
    }

    /// Decodes a raw logit index into a tag. Out-of-range indices (a model
    /// whose head is wider than the manifest) are `unknown`, never a crash.
    func decode(tagIndex index: Int) -> TagDecode {
        guard index >= 0, index < tags.count else {
            return .unknown("tag_index_\(index)")
        }
        return decode(tag: tags[index])
    }

    /// Decodes a raw logit index into an intent string, nil out of range.
    func intent(at index: Int) -> String? {
        guard index >= 0, index < intents.count else { return nil }
        return intents[index]
    }

    // MARK: - The T-033 spike checkpoint (internal testing only)

    /// The T-033 bake-off C3 artifact (`t033-encoder-int8.mlmodelc`), the
    /// ONLY encoder shipped to internal testers today.
    ///
    /// HONEST LABEL — read this before trusting its output:
    ///  - It was fine-tuned on a LEGACY LLM-format dataset snapshot, NOT on
    ///    the T-034 schema-v2 BIO data. Its slot labels therefore cover
    ///    only `contact` and `time`; medication/message/topic/app spans are
    ///    simply not producible by it, and its calibration is unmeasured.
    ///  - The runtime validates strictly anyway (action ∈ schema-v2 enum,
    ///    slot type ∈ schema-v2 set, offsets inside the sanitised
    ///    transcript) and ABSTAINS on anything unknown. An unavailable
    ///    slot is an abstention, never an invented one.
    ///  - It is not a release brain: `ModelCatalog.availableBrainEntries`
    ///    does not list it and `ModelCatalog` marks it
    ///    internal-testing / spike.
    ///
    /// Label order is verbatim from the training run's `meta.json` and is
    /// committed, checkable in-repo, at
    /// `tools/train-intent/docs/t033-evidence/C3-label-order.json`
    /// (the earlier pointer at `C3-coreml-report.json` was wrong — that
    /// report carries no `intents`/`tags` keys): intents alphabetical,
    /// tags `O` first, then contact/time B/I pairs, `max_len` 64.
    /// `calibrationTemperature` is the explicit 1.0 identity — the spike
    /// is uncalibrated, and inventing a temperature for it would be a
    /// fabricated confidence.
    static let t033Spike = IntentEncoderManifest(
        id: "t033-c3-minilm-int8",
        version: "t033-spike-1",
        intents: [
            "ack_med", "call", "emergency", "guide", "health_query",
            "music", "none", "query", "send_message", "set_reminder"
        ],
        tags: ["O", "B-contact", "I-contact", "B-time", "I-time"],
        maxSequenceLength: 64,
        calibrationTemperature: 1.0
    )
}
