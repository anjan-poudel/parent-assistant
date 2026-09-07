import XCTest
@testable import ElderlyAssistant

/// Slice D (voice-personalisation P0): dialect identification from encoder
/// embeddings — nearest-centroid correctness, <60% confidence gating to the
/// default label, honest handling of missing/corrupt tables and embeddings,
/// label persistence, and label → prompt-token mapping. All tests are pure
/// (injected tables/data), except the one shipped-artifact check which reads
/// the app bundle's DialectCentroids.json.
final class DialectIdentifierTests: XCTestCase {

    // MARK: - Helpers

    /// Orthogonal unit centroids: eastern → x-axis, doteli → y-axis.
    private func makeTable(confidenceGate: Float = 0.6,
                           clusterIDs: [String] = ["eastern", "doteli"],
                           promptTokenIds: [String: [Int]] = [:]) -> DialectCentroidTable {
        DialectCentroidTable(
            formatVersion: 1,
            encoder: "whisperkit-ne-medium",
            embeddingDimension: 3,
            similarityMetric: "cosine",
            confidenceGate: confidenceGate,
            generation: DialectCentroidTable.Generation(status: "SEED-CENTROIDS",
                                                        path: "test",
                                                        date: nil),
            clusters: clusterIDs.enumerated().map { index, id in
                var centroid = [Float](repeating: 0, count: 3)
                centroid[index] = 1
                return DialectCentroidTable.Cluster(
                    id: id,
                    centroid: centroid,
                    promptTokenIds: promptTokenIds[id] ?? [],
                    promptText: []
                )
            }
        )
    }

    private func isolateDefaults() -> UserDefaults {
        let suite = "dialect-identifier-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Nearest-centroid correctness

    func testNearestCentroidWins() {
        let identifier = DialectIdentifier(table: makeTable())
        // Unit embedding tilted firmly toward the eastern (x-axis) centroid.
        let norm: Float = (0.9 * 0.9 + 0.3 * 0.3).squareRoot()
        let embedding: [Float] = [0.9 / norm, 0.3 / norm, 0]

        let result = identifier.classify(embedding: embedding)

        XCTAssertEqual(result.label, .eastern)
        XCTAssertEqual(result.reason, .classified)
        // sim(eastern) = 0.9/norm ≈ 0.9487, sim(doteli) = 0.3/norm ≈ 0.3162
        // confidence = 0.5 + (0.9487 − 0.3162)/2 ≈ 0.8162
        XCTAssertEqual(result.confidence, 0.8162, accuracy: 1e-3)
    }

    func testOtherClusterWinsWhenCloser() {
        let identifier = DialectIdentifier(table: makeTable())
        let norm: Float = (0.2 * 0.2 + 0.98 * 0.98).squareRoot()
        let embedding: [Float] = [0.2 / norm, 0.98 / norm, 0]

        let result = identifier.classify(embedding: embedding)

        XCTAssertEqual(result.label, .doteli)
        XCTAssertEqual(result.reason, .classified)
    }

    func testConfidenceFormulaMatchesMargin() {
        let identifier = DialectIdentifier(table: makeTable())
        // Equidistant from both centroids → margin 0 → confidence 0.5.
        let half = 1 / (2 as Float).squareRoot()
        let result = identifier.classify(embedding: [half, half, 0])
        XCTAssertEqual(result.confidence, 0.5, accuracy: 1e-6)
    }

    // MARK: - Confidence gating (<60% → default)

    func testLowConfidenceFallsBackToDefaultLabel() {
        let identifier = DialectIdentifier(table: makeTable())
        let half = 1 / (2 as Float).squareRoot()

        let result = identifier.classify(embedding: [half, half, 0])

        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.confidence, 0.5, accuracy: 1e-6)
        guard case .lowConfidence(let confidence) = result.reason else {
            return XCTFail("expected .lowConfidence, got \(result.reason)")
        }
        XCTAssertEqual(confidence, 0.5, accuracy: 1e-6)
    }

    func testConfidenceAboveGateClassifies() {
        // The spec's "<60% → default" means ≥ 0.6 must classify. Exact-0.6
        // margins are float-fragile, so use a margin of 0.22 (confidence
        // 0.61, comfortably above the gate): unit embedding
        // [cos α, sin α, 0] with cos α − sin α = 0.22 →
        // s = (−0.22 + √(2 − 0.22²)) / 2 ≈ 0.5884983894.
        let identifier = DialectIdentifier(table: makeTable())
        let embedding: [Float] = [0.8084983894, 0.5884983894, 0]

        let result = identifier.classify(embedding: embedding)

        XCTAssertEqual(result.confidence, 0.61, accuracy: 1e-4)
        XCTAssertEqual(result.label, .eastern)
        XCTAssertEqual(result.reason, .classified)
    }

    func testConfidenceJustBelowGateFallsBack() {
        // Margin 0.19 → confidence 0.595 < 0.6 → default label.
        // s = (−0.19 + √(2 − 0.19²)) / 2 ≈ 0.6056960825.
        let identifier = DialectIdentifier(table: makeTable())
        let embedding: [Float] = [0.7956960825, 0.6056960825, 0]

        let result = identifier.classify(embedding: embedding)

        XCTAssertEqual(result.confidence, 0.595, accuracy: 1e-4)
        XCTAssertEqual(result.label, .default)
        guard case .lowConfidence = result.reason else {
            return XCTFail("expected .lowConfidence, got \(result.reason)")
        }
    }

    func testSingleClusterTableUsesSimilarityAgainstNothing() {
        // One cluster: second-best is −1, so confidence = (sim + 1) / 2.
        let table = makeTable(clusterIDs: ["eastern"])
        let identifier = DialectIdentifier(table: table)

        let strong = identifier.classify(embedding: [0.9, 0.1, 0])
        // sim ≈ 0.9939 → confidence ≈ 0.9969
        XCTAssertEqual(strong.label, .eastern)
        XCTAssertEqual(strong.confidence, 0.9969, accuracy: 1e-3)

        let orthogonal = identifier.classify(embedding: [0, 1, 0])
        XCTAssertEqual(orthogonal.label, .default)
        XCTAssertEqual(orthogonal.confidence, 0.5, accuracy: 1e-6)
        guard case .lowConfidence = orthogonal.reason else {
            return XCTFail("expected .lowConfidence, got \(orthogonal.reason)")
        }
    }

    func testNegativeSimilarityCannotClassify() {
        // Anti-correlated with eastern (−1) and orthogonal to doteli: an
        // "opposite of eastern" signal is *no evidence* for doteli — clipped
        // agreements [0, 0] → confidence 0.5 → default.
        let identifier = DialectIdentifier(table: makeTable())
        let result = identifier.classify(embedding: [-1, 0, 0])
        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.confidence, 0.5, accuracy: 1e-6)
        guard case .lowConfidence = result.reason else {
            return XCTFail("expected .lowConfidence, got \(result.reason)")
        }
    }

    // MARK: - Honest no-embedding / no-table states

    func testEmptyEmbeddingIsDefaultWithReason() {
        let identifier = DialectIdentifier(table: makeTable())
        let result = identifier.classify(embedding: [])
        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.reason, .emptyEmbedding)
    }

    func testZeroVectorScoresZeroEverywhere() {
        let identifier = DialectIdentifier(table: makeTable())
        let result = identifier.classify(embedding: [0, 0, 0])
        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.confidence, 0.5, accuracy: 1e-6)
    }

    func testDimensionMismatchIsDefaultWithReason() {
        let identifier = DialectIdentifier(table: makeTable())
        let result = identifier.classify(embedding: [1, 0, 0, 0])
        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.reason,
                       .dimensionMismatch(expected: 3, actual: 4))
    }

    func testNonFiniteEmbeddingIsDefaultWithReason() {
        let identifier = DialectIdentifier(table: makeTable())
        // A NaN or infinity would poison every similarity into a misleading
        // lowConfidence(NaN) — the classifier must refuse explicitly.
        let nanResult = identifier.classify(embedding: [.nan, 0, 0])
        XCTAssertEqual(nanResult.label, .default)
        XCTAssertEqual(nanResult.reason, .nonFiniteEmbedding)

        let infResult = identifier.classify(embedding: [.infinity, 0, 0])
        XCTAssertEqual(infResult.label, .default)
        XCTAssertEqual(infResult.reason, .nonFiniteEmbedding)
    }

    func testMissingTableIsDefaultWithReason() {
        let identifier = DialectIdentifier(table: nil)
        let result = identifier.classify(embedding: [1, 0, 0])
        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.reason, .tableMissing)
    }

    // MARK: - Table corruption (never classify on a table that lies)

    func testEmptyClustersRejectedAsCorrupt() {
        let table = makeTable(clusterIDs: [])
        let result = DialectIdentifier(table: table).classify(embedding: [1, 0, 0])
        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.reason, .tableCorrupt("emptyClusters"))
    }

    func testUnknownClusterIdRejected() {
        let table = makeTable(clusterIDs: ["eastern", "klingon"])
        let result = DialectIdentifier(table: table).classify(embedding: [1, 0, 0])
        XCTAssertEqual(result.label, .default)
        XCTAssertEqual(result.reason, .tableCorrupt("unknownClusterId(\"klingon\")"))
    }

    func testDefaultAsClusterIdRejected() {
        // The `default` label is the no-pack state, never a cluster.
        let table = makeTable(clusterIDs: ["eastern", "default"])
        let result = DialectIdentifier(table: table).classify(embedding: [1, 0, 0])
        XCTAssertEqual(result.label, .default)
        guard case .tableCorrupt = result.reason else {
            return XCTFail("expected .tableCorrupt, got \(result.reason)")
        }
    }

    func testCentroidLengthMismatchRejected() {
        var table = makeTable()
        // Replace doteli's centroid with a wrong-length one via re-decode of
        // JSON — simplest honest construction of the corrupt state.
        table = try! JSONDecoder().decode(
            DialectCentroidTable.self,
            from: Data("""
            {"formatVersion":1,"encoder":"whisperkit-ne-medium",
             "embeddingDimension":3,"similarityMetric":"cosine",
             "confidenceGate":0.6,
             "generation":{"status":"SEED-CENTROIDS","path":"test","date":null},
             "clusters":[
               {"id":"eastern","centroid":[1,0,0],"promptTokenIds":[],"promptText":[]},
               {"id":"doteli","centroid":[1,0],"promptTokenIds":[],"promptText":[]}]}
            """.utf8))

        let result = DialectIdentifier(table: table).classify(embedding: [1, 0, 0])
        XCTAssertEqual(result.label, .default)
        guard case .tableCorrupt(let detail) = result.reason else {
            return XCTFail("expected .tableCorrupt, got \(result.reason)")
        }
        XCTAssertTrue(detail.contains("invalidCentroidLength"))
        XCTAssertTrue(detail.contains("doteli"))
    }

    func testUnsupportedFormatVersionAndMetricRejected() {
        let json = """
        {"formatVersion":99,"encoder":"x","embeddingDimension":3,
         "similarityMetric":"euclidean","confidenceGate":0.6,
         "generation":{"status":"SEED-CENTROIDS","path":"test","date":null},
         "clusters":[{"id":"eastern","centroid":[1,0,0],
                      "promptTokenIds":[],"promptText":[]}]}
        """
        let table = try! JSONDecoder().decode(
            DialectCentroidTable.self, from: Data(json.utf8))
        let issues = table.issues()
        XCTAssertTrue(issues.contains(.unsupportedFormatVersion(99)))
        XCTAssertTrue(issues.contains(.unsupportedMetric("euclidean")))
    }

    func testCorruptJSONThrowsOnDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            DialectCentroidTable.self, from: Data("{not json".utf8)))
    }

    // MARK: - Label → prompt-token mapping

    func testPromptTokenMappingPerLabel() {
        let table = makeTable(
            promptTokenIds: ["eastern": [101, 202, 303], "doteli": [404]]
        )
        XCTAssertEqual(table.promptTokenIds(for: .eastern), [101, 202, 303])
        XCTAssertEqual(table.promptTokenIds(for: .doteli), [404])
        XCTAssertEqual(table.promptTokenIds(for: .default), [],
                       "default label never biases")
    }

    func testPromptTokenMappingTruncatesToMax() {
        let many = Array(0..<(DialectCentroidTable.maxPromptTokenCount + 50))
        let table = makeTable(promptTokenIds: ["eastern": many])
        let mapped = table.promptTokenIds(for: .eastern)
        XCTAssertEqual(mapped.count, DialectCentroidTable.maxPromptTokenCount)
        XCTAssertEqual(mapped, Array(0..<DialectCentroidTable.maxPromptTokenCount))
    }

    func testPromptTokenMappingUnknownAndEmpty() {
        let table = makeTable()
        XCTAssertEqual(table.promptTokenIds(for: .eastern), [],
                       "seed table carries no tokens yet")
        XCTAssertEqual(table.promptTokenIds(for: .doteli), [])
    }

    // MARK: - Persistence (hermetic defaults suite)

    func testPersistenceRoundTrip() {
        let defaults = isolateDefaults()
        XCTAssertEqual(DialectPreference.persisted(defaults: defaults), .default)

        DialectPreference.persist(.doteli, defaults: defaults)
        XCTAssertEqual(DialectPreference.persisted(defaults: defaults), .doteli)

        DialectPreference.reset(defaults: defaults)
        XCTAssertEqual(DialectPreference.persisted(defaults: defaults), .default)
    }

    func testPersistenceIgnoresUnknownRawValue() {
        let defaults = isolateDefaults()
        defaults.set("klingon", forKey: DialectPreference.defaultsKey)
        XCTAssertEqual(DialectPreference.persisted(defaults: defaults), .default)
    }

    // MARK: - Embedding pooling (pure, shared with the recognizer seam)

    func testMeanPoolOverFrames() {
        // Shape [2, 3] with embedding axis = trailing 3 (dimension 3):
        // rows [1,2,3] and [10,20,30] → pooled [5.5, 11, 16.5].
        let pooled = DialectEmbeddingVector.meanPooled(
            shape: [2, 3], values: [1, 2, 3, 10, 20, 30], embeddingDimension: 3)
        XCTAssertEqual(pooled, [5.5, 11, 16.5])
    }

    func testMeanPoolIdentityOnPlainVector() {
        let values: [Float] = [0.1, 0.2, 0.3]
        let pooled = DialectEmbeddingVector.meanPooled(
            shape: [3], values: values, embeddingDimension: 3)
        XCTAssertEqual(pooled, values)
    }

    func testMeanPoolTypicalEncoderShape() {
        // [1, 1, 4, 2]: 4 frames of 2 dims; frame f contributes
        // [f, f+1] → pooled [1.5, 2.5].
        let pooled = DialectEmbeddingVector.meanPooled(
            shape: [1, 1, 4, 2],
            values: [0, 1, 1, 2, 2, 3, 3, 4].map { Float($0) },
            embeddingDimension: 2)
        XCTAssertEqual(pooled, [1.5, 2.5])
    }

    func testMeanPoolAmbiguousAxisIsNil() {
        // Two axes both of extent 2 — cannot know which is the embedding
        // axis; refusing is the honest answer.
        let pooled = DialectEmbeddingVector.meanPooled(
            shape: [2, 2, 2],
            values: [Float](repeating: 1, count: 8),
            embeddingDimension: 2)
        XCTAssertNil(pooled)
    }

    func testMeanPoolRejectsMalformedTensors() {
        // Count mismatch.
        XCTAssertNil(DialectEmbeddingVector.meanPooled(
            shape: [2, 3], values: [1, 2, 3], embeddingDimension: 3))
        // Dimension never appears in the shape.
        XCTAssertNil(DialectEmbeddingVector.meanPooled(
            shape: [2, 2], values: [1, 2, 3, 4], embeddingDimension: 3))
        // Zero-size axis.
        XCTAssertNil(DialectEmbeddingVector.meanPooled(
            shape: [2, 0], values: [], embeddingDimension: 0))
        // Empty shape.
        XCTAssertNil(DialectEmbeddingVector.meanPooled(
            shape: [], values: [], embeddingDimension: 3))
    }

    // MARK: - Shipped artifact honesty

    func testBundledSeedTableIsStructurallyValidAndHonest() throws {
        guard Bundle.main.url(forResource: DialectCentroidTable.bundledResourceName,
                              withExtension: "json") != nil else {
            // The seed JSON ships via project.yml as an app-bundle resource;
            // before xcodegen generate it is absent even in test hosts.
            throw XCTSkip("DialectCentroids.json not bundled yet "
                          + "(run xcodegen generate + build)")
        }
        let table = try DialectCentroidTable.bundled()
        let unwrapped = try XCTUnwrap(table)
        XCTAssertEqual(unwrapped.formatVersion, 1)
        XCTAssertEqual(unwrapped.encoder, "whisperkit-ne-medium")
        XCTAssertEqual(unwrapped.similarityMetric, "cosine")
        XCTAssertEqual(unwrapped.confidenceGate, 0.6)
        XCTAssertEqual(unwrapped.embeddingDimension, 1024)
        XCTAssertGreaterThanOrEqual(unwrapped.clusters.count, 2)
        XCTAssertEqual(unwrapped.issues(), [], "shipped table must validate")
        XCTAssertEqual(unwrapped.generation.status, "SEED-CENTROIDS",
                       "calibration data is pending — the shipped table must "
                       + "still declare itself a seed")

        for cluster in unwrapped.clusters {
            XCTAssertEqual(cluster.centroid.count, unwrapped.embeddingDimension)
            XCTAssertTrue(cluster.promptTokenIds.isEmpty,
                          "seed table must not invent lexical bias")
            let label = DialectLabel(rawValue: cluster.id)
            XCTAssertNotNil(label)
            XCTAssertNotEqual(label, .default)
        }

        // A seed table must never classify anything: real embeddings are
        // near-orthogonal to random unit centroids → confidence ≈ 0.5.
        let identifier = DialectIdentifier(table: unwrapped)
        var random = [Float](repeating: 0, count: unwrapped.embeddingDimension)
        for i in random.indices {
            random[i] = sin(Float(i) * 12.9898) * 43758.5453
            random[i] -= random[i].rounded(.down)
            random[i] = random[i] * 2 - 1
        }
        let result = identifier.classify(embedding: random)
        XCTAssertEqual(result.label, .default,
                       "SEED centroids must fall back to the default label")
        XCTAssertLessThan(result.confidence, 0.6)
    }
}
