import Foundation

/// A unit speaker-discriminative vector plus the identity of the embedder
/// that produced it (speaker-fingerprint research doc
/// docs/research-sections/speaker-fingerprint.md §3.2/§4.3).
///
/// Embeddings are pure data: this type owns only the math that
/// `SpeakerVerifier` and enrollment scoring share — L2 normalisation,
/// cosine similarity, and centroid averaging — all of it deterministic
/// and free of any ML runtime, so the whole scoring path unit-tests
/// without a model (the house pattern behind WakeWordConfig).
struct SpeakerEmbedding: Equatable, Sendable {

    let values: [Float]
    /// Stable identity of the embedder that produced this vector. A
    /// template stored under one embedder is never scored against an
    /// embedding from another — model/frontend changes require
    /// re-enrollment (research doc §10, "versioned for future model
    /// upgrades").
    let embedderID: String

    var dimension: Int { values.count }

    /// Rejects empty vectors; empty embeddings are a programming error,
    /// not a valid "no signal" state (silence is rejected earlier, at the
    /// embedder/quality layer).
    init?(values: [Float], embedderID: String) {
        guard !values.isEmpty else { return nil }
        self.values = values
        self.embedderID = embedderID
    }

    // MARK: - Vector math

    /// Cosine similarity in [-1, 1]. Returns nil when dimensions or
    /// embedder identities disagree — cross-embedder scoring must be a
    /// hard refusal, never a number (a score across embedders would look
    /// comparable when it is not; research doc §4.3: thresholds are
    /// embedder-specific and do not transfer).
    static func cosine(_ a: SpeakerEmbedding, _ b: SpeakerEmbedding) -> Float? {
        guard a.embedderID == b.embedderID, a.values.count == b.values.count else {
            return nil
        }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.values.count {
            dot += a.values[i] * b.values[i]
            normA += a.values[i] * a.values[i]
            normB += b.values[i] * b.values[i]
        }
        let product = normA.squareRoot() * normB.squareRoot()
        guard product > 0 else { return 0 }
        return dot / product
    }

    /// This vector with unit L2 norm. The zero vector normalises to
    /// itself (cosine scoring degrades to 0 against everything, which is
    /// the honest "no signal" answer).
    func l2Normalized() -> SpeakerEmbedding {
        var normSq: Float = 0
        for v in values { normSq += v * v }
        let norm = normSq.squareRoot()
        guard norm > 0 else { return self }
        return SpeakerEmbedding(
            values: values.map { $0 / norm },
            embedderID: embedderID
        )!
    }

    /// Mean of the given embeddings (all L2-normalised first, so longer
    /// utterances cannot dominate), re-normalised to unit length.
    /// Multi-utterance centroid averaging is the enrollment design the
    /// research doc pins (§4.3: 3–5 utterances, ~30% EER improvement).
    /// Returns nil for an empty set or mixed embedder identities.
    static func centroid(of embeddings: [SpeakerEmbedding]) -> SpeakerEmbedding? {
        guard !embeddings.isEmpty,
              let firstID = embeddings.first?.embedderID,
              embeddings.allSatisfy({ $0.embedderID == firstID }),
              let dimension = embeddings.first?.values.count,
              embeddings.allSatisfy({ $0.values.count == dimension }) else {
            return nil
        }
        var sums = [Float](repeating: 0, count: dimension)
        for embedding in embeddings {
            let normalized = embedding.l2Normalized()
            for i in 0..<dimension {
                sums[i] += normalized.values[i]
            }
        }
        let mean = sums.map { $0 / Float(embeddings.count) }
        return SpeakerEmbedding(values: mean, embedderID: firstID)?.l2Normalized()
    }
}
