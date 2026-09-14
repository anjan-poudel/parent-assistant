import Foundation

/// [T-037-a] The tokenizer seam for the intent encoder.
///
/// ## Why a seam (and what now sits behind it)
///
/// The encoder's CoreML graph consumes `input_ids` / `attention_mask`
/// (int32, shape `[1, 1...64]`) from the model's XLM-R SentencePiece
/// vocabulary — a 250k-piece `sentencepiece.bpe.model` plus a 17 MB HF
/// `tokenizer.json`. No linked dependency ships an XLM-R tokenizer
/// (Foundation/Accelerate/CoreML have none; the vendored packages are
/// whisper.cpp, llama.cpp, WhisperKit, ZIPFoundation and sherpa-onnx), so
/// the runtime carries its own:
/// `XlmrUnigramTokenizer` ([ENCODER-RUNTIME-READY]) implements the full
/// pipeline — precompiled-charsmap normalisation, Replace, Metaspace
/// pre-tokenization, Unigram Viterbi, `<s>`/`</s>` post-processing,
/// truncation — from a compact committed vocabulary table, and is gated on
/// a golden-fixture suite whose rows come from the PYTHON tokenizer, the
/// source of truth (`ios/ElderlyAssistantTests/Services/Intents/
/// XlmrUnigramTokenizerTests.swift`).
///
/// The protocol is what keeps the failure mode honest: a tokenizer that
/// cannot serve reports `isReady == false`
/// (`UnavailableIntentEncoderTokenizer`) and the interpreter's
/// `isAvailable` is false, so the app behaves exactly as before the
/// encoder existed (the local brain stays the LLaMA stand-in). Nothing is
/// ever faked: there is no "stub tokenizer" that returns plausible-looking
/// ids, because fabricated ids would produce fabricated logits and a
/// fabricated command.
///
/// ## Contract
///
/// `tokenize` receives the ALREADY-SANITISED transcript (the interpreter
/// runs `InputSanitiser.sanitise(_, level: .quarantine)` first) and must:
///  1. split it into whitespace words,
///  2. encode with `is_split_into_words` semantics (the T-033 alignment
///     rule — training and inference tokenise identically so word-level
///     BIO decoding cannot drift), truncating to `maxSequenceLength`,
///  3. report, for every token position, which word it belongs to.
///
/// Returning nil means "this tokenizer cannot serve this input"; the
/// interpreter treats that as an explicit failure, never as an empty
/// transcript.
protocol IntentEncoderTokenizing: AnyObject {

    /// Stable id for observability/model-compatibility checks. Never
    /// contains user content.
    var tokenizerID: String { get }

    /// False when the vocab is absent/unusable — the interpreter is then
    /// unavailable instead of silently failing every utterance.
    var isReady: Bool { get }

    /// Encodes a sanitised transcript for the encoder graph.
    func tokenize(sanitisedTranscript: String,
                  maxSequenceLength: Int) -> IntentEncoderTokenization?
}

/// One encoder input row: token ids, the attention mask, and the word each
/// token position came from (the `word_ids()` alignment the T-033 decode
/// rule needs).
struct IntentEncoderTokenization: Equatable {
    let tokenIds: [Int32]
    let attentionMask: [Int32]
    /// Word index per token position, parallel to `tokenIds`. Nil entries
    /// are special tokens / positions outside any word.
    let wordIndices: [Int?]
    /// The whitespace words, in order, that the word indices refer to.
    /// The span decoder maps these back to offsets in the sanitised
    /// transcript and validates the alignment before emitting anything.
    let words: [String]
}

/// Reports not-ready and refuses to tokenise — an explicit, observable
/// unavailability (no silent stub), by design. Still the default the
/// interpreter's initialiser takes, and still the object
/// `IntentEncoderRuntime.load` returns when the bundled vocabulary or the
/// companion meta.json cannot be read.
final class UnavailableIntentEncoderTokenizer: IntentEncoderTokenizing {
    let tokenizerID = "xlm-r-250k-unavailable"
    var isReady: Bool { false }
    func tokenize(sanitisedTranscript: String,
                  maxSequenceLength: Int) -> IntentEncoderTokenization? {
        nil
    }
}
