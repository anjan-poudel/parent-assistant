import Foundation

/// [CHAT-SAMPLING] (T-167, feature `conversational-nepali-replies`) The CHAT
/// shape's decode parameters and the per-turn override that applies them to
/// the ONE resident on-device brain handle.
///
/// The on-device brain answers two shapes through ONE handle:
///   - the COMMAND shape (`interpret`, `IntentPrompt.build`) — temperature 0,
///     the fixed seed and the command GBNF schema. Determinism is a
///     NO-GIBBERISH invariant (FR-CNR-004): a command decode must be
///     byte-identical to a cold one, whatever ran before it;
///   - the CHAT shape (`respondToChat`, `IntentPrompt.buildChat`) — the
///     reviewed temperature `chatTemperature` (0.3, design-l1 §5.1 / OD-1)
///     at the SAME fixed seed, so a chat reply stays reproducible
///     (NFR-CNR-001) while it escapes greedy decoding's most-cliché tokens.
///
/// The override is PER TURN, never per sequence: `apply(_:to:)` is awaited
/// immediately before each decode, and every decode path (command, chat and
/// the judge) re-asserts its own parameters first, so the sampling state is
/// a property of the turn being decoded and not of the turn before it
/// (design-l1 §5.2). A chat turn at 0.3 therefore cannot leak into a command
/// decode: the command shape puts temperature 0 back on the handle before its
/// own decode.
///
/// One handle, no second instance: this type changes PARAMETERS on the
/// resident handle. It never creates, loads or configures a model — a second
/// handle is the [VOICE-OOM] bug class (two ~3 GB weight copies) and is what
/// NFR-CNR-003's "exactly one brain model resident" forbids. Nothing here
/// allocates context or touches the 1,024-token discipline.
///
/// The values are named constants on purpose: `chatTemperature` and
/// `chatSeed` are recorded, reviewed values (design-l1 §5.1) — changing
/// either is a reviewed change to a constant, not a tunable. The chat seed
/// is the same fixed seed the command shape uses (one seed for both shapes,
/// recorded here by name); a random or time-derived seed is a defect
/// (NFR-CNR-001).
enum ChatSampling {

    // MARK: - Recorded constants

    /// The reviewed chat decode temperature — "exactly 0.3" (design-l1
    /// §5.1, OD-1). Deliberately NOT a mutation of
    /// `OnDeviceSampling.temperature`: the command shape's temp-0 constant
    /// and the handle-creation call are untouched (FR-CNR-004).
    static let chatTemperature: Float = 0.3

    /// The chat decode's fixed seed — a recorded named constant, the same on
    /// every device. It IS `OnDeviceSampling.fixedSeed` (the NO-GIBBERISH
    /// fix's seed, one seed for both shapes), named here so the chat shape's
    /// seed is readable without reaching into the command sampler.
    static let chatSeed: UInt32 = OnDeviceSampling.fixedSeed

    // MARK: - The requested-parameters record (the determinism seam)

    /// One decode path's REQUESTED parameters — what the interpreter's
    /// `lastDecodeParameters` record carries and what the determinism tests
    /// and DV-5 read.
    ///
    /// `schema` is the decode's GBNF schema string itself (the same
    /// `LlamaGrammar` constant the sampler is handed), so the record shows
    /// which shape's constraint a decode ran under rather than a label that
    /// could drift from it.
    struct DecodeParameters: Equatable {
        let temperature: Float
        let seed: UInt32
        let schema: String
    }

    /// The COMMAND shape's parameters — the shipped invariants: temperature
    /// 0 (`OnDeviceSampling.temperature`), the fixed seed, the command GBNF
    /// schema. Frozen: a change here is a NO-GIBBERISH invariant violation
    /// (FR-CNR-004), not a tuning.
    static let commandParameters = DecodeParameters(
        temperature: OnDeviceSampling.temperature,
        seed: OnDeviceSampling.fixedSeed,
        schema: LlamaGrammar.commandJSONSchema)

    /// The CHAT shape's parameters — the chat temperature at the fixed seed,
    /// under the chat schema (whose single-value intent enum is what makes a
    /// chat decode structurally unable to claim a command).
    static let chatParameters = DecodeParameters(
        temperature: chatTemperature,
        seed: chatSeed,
        schema: LlamaGrammar.chatJSONSchema)

    /// The parameters of a DETERMINISTIC decode path that carries a schema of
    /// its own (the semantic judge's pick schema): temperature 0 plus the
    /// fixed seed, so such a path re-asserts determinism instead of
    /// inheriting whatever the last turn left on the handle.
    static func deterministicParameters(schema: String) -> DecodeParameters {
        DecodeParameters(temperature: OnDeviceSampling.temperature,
                         seed: OnDeviceSampling.fixedSeed,
                         schema: schema)
    }

    // MARK: - The per-turn override

    /// The sampling-parameter surface of the resident handle.
    ///
    /// One write is all a turn needs, and in production only the real handle
    /// witnesses this: `LLMCore` is an actor, so the awaited write is ordered
    /// against `generateWithConstraints` on the actor's own serialized
    /// execution (the whole turn additionally runs on the `llama.command`
    /// queue). A recording test double witnesses it to observe what a turn
    /// asked for without a model.
    protocol ParameterHandle: AnyObject {
        /// Apply this turn's parameters. Awaited immediately before the
        /// decode, so no other code path can interleave a field change
        /// mid-decode.
        func setDecodeParameters(temperature: Float, seed: UInt32) async
    }

    /// Apply one turn's parameters to the resident handle and return them as
    /// the caller's record of what was requested. The caller AWAITS this
    /// before its decode.
    ///
    /// Always applies — deliberately no "already applied, skip" shortcut. A
    /// skip is only correct if the handle's state is guaranteed, and the
    /// handle deliberately persists across turns (that persistence is exactly
    /// why the command shape re-asserts temperature 0 after a chat turn). A
    /// shortcut that skipped on equal values would read as an optimisation and
    /// behave like the set-once defect the determinism tests exist to catch.
    @discardableResult
    static func apply(_ parameters: DecodeParameters,
                      to handle: ParameterHandle) async -> DecodeParameters {
        await handle.setDecodeParameters(temperature: parameters.temperature,
                                         seed: parameters.seed)
        return parameters
    }
}
