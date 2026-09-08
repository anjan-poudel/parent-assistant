import XCTest
@testable import ElderlyAssistant

/// Pure vector math behind speaker scoring — cosine, L2 normalisation,
/// centroid averaging. Fixed vectors only; no audio, no embedder runtime.
final class SpeakerEmbeddingMathTests: XCTestCase {

    private func emb(_ values: [Float], id: String = "test.v1") -> SpeakerEmbedding {
        SpeakerEmbedding(values: values, embedderID: id)!
    }

    // MARK: - Construction

    func testRejectsEmptyVector() {
        XCTAssertNil(SpeakerEmbedding(values: [], embedderID: "test.v1"),
                     "an empty embedding is a programming error, not a signal")
    }

    func testExposesDimensionAndEmbedderID() {
        let e = emb([1, 2, 3])
        XCTAssertEqual(e.dimension, 3)
        XCTAssertEqual(e.embedderID, "test.v1")
    }

    // MARK: - Cosine similarity

    func testCosineOfIdenticalVectorsIsOne() {
        XCTAssertEqual(SpeakerEmbedding.cosine(emb([1, -2, 3]), emb([1, -2, 3]))!, 1.0,
                       accuracy: 1e-5)
    }

    func testCosineOfOrthogonalVectorsIsZero() {
        XCTAssertEqual(SpeakerEmbedding.cosine(emb([1, 0, 0]), emb([0, 1, 0]))!, 0.0,
                       accuracy: 1e-5)
    }

    func testCosineOfOppositeVectorsIsMinusOne() {
        XCTAssertEqual(SpeakerEmbedding.cosine(emb([2, 0]), emb([-2, 0]))!, -1.0,
                       accuracy: 1e-5)
    }

    func testCosineIsScaleInvariant() {
        let a = emb([1, 2, 3])
        let scaled = emb([10, 20, 30])
        XCTAssertEqual(SpeakerEmbedding.cosine(a, scaled)!, 1.0, accuracy: 1e-5,
                       "cosine must not depend on vector magnitude")
    }

    func testCosineKnownValue() {
        // cos([1,1,1,1], [1,0,1,0]) = 2 / (2·√2) = 1/√2
        let a = emb([1, 1, 1, 1])
        let b = emb([1, 0, 1, 0])
        XCTAssertEqual(SpeakerEmbedding.cosine(a, b)!,
                       (1.0 / Float(2).squareRoot()), accuracy: 1e-5)
    }

    func testCosineRefusesDimensionMismatch() {
        XCTAssertNil(SpeakerEmbedding.cosine(emb([1, 0]), emb([1, 0, 0])),
                     "cross-dimension scoring must be a hard refusal")
    }

    func testCosineRefusesCrossEmbedderScoring() {
        let a = emb([1, 0, 0], id: "a.v1")
        let b = emb([1, 0, 0], id: "b.v1")
        XCTAssertNil(SpeakerEmbedding.cosine(a, b),
                     "a score across embedders looks comparable when it is not — refuse it")
    }

    func testCosineOfZeroVectorIsZero() {
        XCTAssertEqual(SpeakerEmbedding.cosine(emb([0, 0]), emb([1, 1]))!, 0.0,
                       accuracy: 1e-5,
                       "silence must not win or lose a margin against anything")
    }

    // MARK: - L2 normalisation

    func testNormalizationYieldsUnitNorm() {
        let normalized = emb([3, 4, 0]).l2Normalized()
        XCTAssertEqual(normalized.values[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(normalized.values[1], 0.8, accuracy: 1e-5)
        XCTAssertEqual(normalized.values[2], 0.0, accuracy: 1e-5)
    }

    func testNormalizationPreservesEmbedderID() {
        XCTAssertEqual(emb([3, 4]).l2Normalized().embedderID, "test.v1")
    }

    func testNormalizedCosineOfNormalizedVectorsIsTheDotProduct() {
        let a = emb([1, 2, 3]).l2Normalized()
        let b = emb([-1, 4, 2]).l2Normalized()
        var dot: Float = 0
        for i in 0..<3 { dot += a.values[i] * b.values[i] }
        XCTAssertEqual(SpeakerEmbedding.cosine(a, b)!, dot, accuracy: 1e-5)
    }

    // MARK: - Centroid

    func testCentroidOfIdenticalVectorsIsThatVector() {
        let v = emb([1, 2, 3])
        let centroid = SpeakerEmbedding.centroid(of: [v, v, v])!
        XCTAssertEqual(SpeakerEmbedding.cosine(centroid, v)!, 1.0, accuracy: 1e-5)
        XCTAssertEqual(centroid.embedderID, "test.v1")
    }

    func testCentroidIsNormalized() {
        let centroid = SpeakerEmbedding.centroid(of: [emb([1, 0]), emb([0, 1])])!
        let normSq = centroid.values.reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertEqual(normSq, 1.0, accuracy: 1e-5,
                       "the enrolled template must be unit-length")
    }

    func testCentroidIsTheMeanDirection() {
        // (1,0) and (0,1) → centroid points along (1,1)/√2.
        let centroid = SpeakerEmbedding.centroid(of: [emb([1, 0]), emb([0, 1])])!
        XCTAssertEqual(centroid.values[0], 1.0 / Float(2).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(centroid.values[1], 1.0 / Float(2).squareRoot(), accuracy: 1e-5)
    }

    func testCentroidRefusesEmptySet() {
        XCTAssertNil(SpeakerEmbedding.centroid(of: []))
    }

    func testCentroidRefusesMixedEmbedders() {
        XCTAssertNil(SpeakerEmbedding.centroid(of: [
            emb([1, 0], id: "a.v1"), emb([0, 1], id: "b.v1")
        ]))
    }

    func testCentroidRefusesMixedDimensions() {
        XCTAssertNil(SpeakerEmbedding.centroid(of: [
            emb([1, 0, 0]), emb([0, 1])
        ]))
    }

    func testCentroidIsScaleInvariant() {
        // Longer utterances must not dominate the template by magnitude:
        // (3,0) and (0,9) have the same DIRECTION story as (1,0) and
        // (0,1) — the centroid must be (1,1)/√2 either way.
        let loud = emb([0, 9])
        let quiet = emb([3, 0])
        let centroid = SpeakerEmbedding.centroid(of: [quiet, loud])!
        XCTAssertEqual(centroid.values[0], 1.0 / Float(2).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(centroid.values[1], 1.0 / Float(2).squareRoot(), accuracy: 1e-5)
    }
}
