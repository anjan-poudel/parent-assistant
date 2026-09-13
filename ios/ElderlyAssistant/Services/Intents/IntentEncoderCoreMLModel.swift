import Foundation

#if canImport(CoreML)
import CoreML

/// [T-037-a] The concrete `IntentEncoderModelRunning` — loads the compiled
/// `t033-encoder-int8.mlmodelc` directory installed by
/// `ModelStore.installCoreMLEncoder(fromZip:for:)` and runs one prediction.
///
/// ## I/O contract (do not guess — from the T-033 export)
///
/// Authoritative source: `tools/train-intent/src/bakeoff_export_coreml.py`
/// (`ct.convert(... inputs/outputs ...)`) and the compiled artifact's own
/// `metadata.json`:
///   - inputs:  `input_ids`, `attention_mask` — int32, shape `[1, 1...64]`
///              (`RangeDim(1, max_len)`, max_len 64 for the C3 checkpoint)
///   - outputs: `intent_logits` `[1, num_intents]`,
///              `slot_logits`  `[1, seq, num_tags]` — Float16
///
/// The label ORDER behind those logits lives in `IntentEncoderManifest`,
/// not in the graph — see the manifest's doc comment.
///
/// Errors are deliberately content-free (`loadFailed("coreml_load")`):
/// no file paths and no weights data reach observability (C9 / NFR-016).
final class CoreMLIntentEncoderModel: IntentEncoderModelRunning {

    static let inputIDsName = "input_ids"
    static let attentionMaskName = "attention_mask"
    static let intentLogitsName = "intent_logits"
    static let slotLogitsName = "slot_logits"

    private let modelURL: URL
    private let lock = NSLock()
    private var model: MLModel?

    init(contentsOf url: URL) {
        self.modelURL = url
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    /// Loads the compiled model. `computeUnits = .all` lets CoreML place
    /// the graph on the Neural Engine where available, falling back to
    /// GPU/CPU — the whole point of the CoreML delivery path.
    func load() throws {
        lock.lock()
        let alreadyLoaded = model != nil
        lock.unlock()
        if alreadyLoaded { return }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            // Never surface the underlying error string (it can carry the
            // artifact path); the caller reports a typed reason.
            throw IntentEncoderModelError.loadFailed("coreml_load")
        }
        lock.lock()
        model = loaded
        lock.unlock()
    }

    func unload() {
        lock.lock()
        model = nil
        lock.unlock()
    }

    func predict(tokenIds: [Int32],
                 attentionMask: [Int32]) throws -> IntentEncoderLogits {
        lock.lock()
        let current = model
        lock.unlock()
        guard let current else {
            throw IntentEncoderModelError.predictionFailed("not_loaded")
        }
        guard !tokenIds.isEmpty, tokenIds.count == attentionMask.count else {
            throw IntentEncoderModelError.predictionFailed("input_shape")
        }

        do {
            let ids = try MLMultiArray(shape: [1, NSNumber(value: tokenIds.count)],
                                       dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: attentionMask.count)],
                                        dataType: .int32)
            for position in tokenIds.indices {
                ids[[0, position] as [NSNumber]] = NSNumber(value: tokenIds[position])
                mask[[0, position] as [NSNumber]] = NSNumber(value: attentionMask[position])
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                Self.inputIDsName: MLFeatureValue(multiArray: ids),
                Self.attentionMaskName: MLFeatureValue(multiArray: mask)
            ])
            let output = try current.prediction(from: provider)
            guard let intentLogits = output.featureValue(for: Self.intentLogitsName)?
                    .multiArrayValue,
                  let slotLogits = output.featureValue(for: Self.slotLogitsName)?
                    .multiArrayValue else {
                throw IntentEncoderModelError.unexpectedOutput("missing_heads")
            }
            return IntentEncoderLogits(
                intentLogits: try Self.readIntentLogits(intentLogits),
                slotLogits: try Self.readSlotLogits(slotLogits))
        } catch let error as IntentEncoderModelError {
            throw error
        } catch {
            throw IntentEncoderModelError.predictionFailed("coreml_predict")
        }
    }

    // MARK: - Output reading

    /// `intent_logits` is `[1, n]` — flattened to `n` scores.
    private static func readIntentLogits(_ array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 2, shape[0] == 1, shape[1] > 0 else {
            throw IntentEncoderModelError.unexpectedOutput("intent_shape")
        }
        var scores = [Float](repeating: 0, count: shape[1])
        for index in 0..<shape[1] {
            scores[index] = array[[0, index] as [NSNumber]].floatValue
        }
        return scores
    }

    /// `slot_logits` is `[1, seq, tags]` — one score row per token.
    private static func readSlotLogits(_ array: MLMultiArray) throws -> [[Float]] {
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] > 0 else {
            throw IntentEncoderModelError.unexpectedOutput("slot_shape")
        }
        var rows = [[Float]](repeating: [], count: shape[1])
        for token in 0..<shape[1] {
            var row = [Float](repeating: 0, count: shape[2])
            for tag in 0..<shape[2] {
                row[tag] = array[[0, token, tag] as [NSNumber]].floatValue
            }
            rows[token] = row
        }
        return rows
    }
}

#endif
