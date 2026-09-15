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

// MARK: - [TG-12] The dialect canonicalizer

/// The canonicalization layer's suite
/// (`Services/Voice/DialectCanonicalizer.swift`). It lives beside the
/// dialect-identifier tests because the two consume the same axis with the
/// same resource-loading shape: this file already reads a shipped JSON table
/// out of the app bundle and already refuses to trust content the calibration
/// pipeline has not produced yet.
///
/// AUTHORED UNDER A TESTING HOLD. No `xcodebuild`, simulator or gate was run
/// for this task, so nothing below is evidence of a green suite — the task's
/// verification is `swiftc -parse` plus the reasoning in each test's comment.
/// The three safety tests (`testPinnedSafetyFixturesAreLossless`…,
/// `testNegationMarkerTouchedRefusesBhayaToBhayo`,
/// `testSafetyAndPickerInputsKeepTheOriginal`) are the ones that must actually
/// run before the canonicalizer is switched on.
extension DialectIdentifierTests {

    // MARK: Fixtures and helpers

    private func makeEntry(_ id: String,
                           kind: String = "orthographic",
                           variant: String,
                           canonical: String,
                           status: VariantTableEntry.Status = .confirmed,
                           examples: [String]? = nil) -> VariantTableEntry {
        VariantTableEntry(
            id: id,
            kindRaw: kind,
            variant: variant,
            canonical: canonical,
            status: status,
            modelImpact: "known_word",
            resolves: ["N5"],
            note: "synthetic test entry",
            evidence: VariantTableEntry.Evidence(
                source: .authored,
                corpusRevision: nil,
                rowIDs: [],
                occurrences: 0,
                fixtureExamples: examples ?? [variant, variant + " भन्नुहोस"])
        )
    }

    private func makeTable(_ id: String,
                           dialect: DialectLabel? = nil,
                           entries: [VariantTableEntry]) -> VariantTable {
        VariantTable(formatVersion: 1,
                     tableID: id,
                     dialectRaw: dialect?.rawValue,
                     generation: VariantTable.Generation(status: "TEST",
                                                         path: "test",
                                                         date: nil),
                     entries: entries)
    }

    private func makeSet(orthographic: VariantTable? = nil,
                         panRegional: VariantTable? = nil,
                         sttReductions: VariantTable? = nil,
                         dialectTables: [DialectLabel: VariantTable] = [:])
    -> VariantTableSet {
        VariantTableSet(orthographic: orthographic,
                        panRegional: panRegional,
                        sttReductions: sttReductions,
                        dialectTables: dialectTables,
                        loadIssues: [])
    }

    /// Every table admitted, every conditional region included — the widest
    /// policy the layer can run under, so the safety tests below are not
    /// quietly testing an inert configuration.
    private func widestPolicy() -> DialectCanonicalizer.Policy {
        DialectCanonicalizer.Policy(enabled: true,
                                    orthographicOnly: false,
                                    includeConditionalTables: true)
    }

    private func canonicalize(_ text: String,
                              dialect: DialectLabel = .default,
                              tables: VariantTableSet,
                              policy: DialectCanonicalizer.Policy)
    -> CanonicalizationResult {
        DialectCanonicalizer.canonicalize(text,
                                          dialect: dialect,
                                          tables: tables,
                                          policy: policy)
    }

    /// The shipped set, or a skip when the app bundle has not been generated.
    private func bundledVariantTables() throws -> VariantTableSet {
        let tables = VariantTableSet.load()
        guard tables.orthographic != nil else {
            throw XCTSkip("VariantTables/*.json not bundled yet "
                          + "(run xcodegen generate + build)")
        }
        return tables
    }

    // MARK: The shipped rule inventory, pinned

    /// Every shipped rule as (input, expected output, rule id, dialect).
    /// Written out literally rather than read from the tables so it is an
    /// INDEPENDENT second source: a rule added, renamed or silently retargeted
    /// in a JSON file fails `testEveryShippedRuleHasAPinnedInOutPair` instead
    /// of travelling with the data it would have to disagree with.
    ///
    /// The dialect is part of the row because a runnable region rule only fires
    /// for the label its table declares — a pinned pair that forgot it would
    /// pass for the wrong reason on a pan-regional row and fail for the wrong
    /// reason on a doteli one.
    private static let pinnedRulePairs: [(input: String, expected: String,
                                          ruleID: String, dialect: DialectLabel)] = [
        // canonical-orthographic (dialect-agnostic)
        ("गर्नुहोस", "गर्नुहोस्", "orth-halanta-garnuhos", .default),
        ("औषधी", "औषधि", "orth-halanta-aushadhi", .default),
        // canonical-panregional (dialect-agnostic)
        ("भोली", "भोलि", "pan-drift-bholi", .default),
        ("ह्वाट्सएपमा", "वाट्सएपमा", "pan-loan-whatsapp", .default),
        // canonical-stt-reductions (dialect-agnostic)
        ("गर्नुस्", "गर्नुहोस्", "stt-reduction-garnus", .default),
        // canonical-eastern (conditional, confirmed rows)
        ("गइछ", "गएछ", "east-perfective-gaincha", .eastern),
        ("भइछ", "भएछ", "east-perfective-bhaincha", .eastern),
        ("खाइछ", "खाएछ", "east-perfective-khaincha", .eastern),
        // canonical-doteli (conditional, confirmed rows)
        ("रह्याको", "रहेको", "dot-past-rahyako", .doteli),
        ("भण्याको", "भनेको", "dot-past-bhanyako", .doteli),
    ]

    /// Rules that must ship but must NOT fire: the four unconfirmed eastern
    /// rows awaiting T-062's N5. Pinned for the same reason — an entry that
    /// became runnable without an answer would show up here.
    private static let pinnedInertPairs: [(input: String, ruleID: String)] = [
        ("दिउसो", "east-ortho-diuso"),
        ("बेल्का", "east-ortho-belka"),
        ("साझ", "east-ortho-sanjh"),
        ("रात", "east-lex-rat"),
    ]

    /// The safety fixture set: every member of the three frozen classes plus
    /// carrier sentences that put frozen material NEXT TO text the tables do
    /// rewrite — the positions where a rewrite could disturb a match. Literal
    /// for the same reason as the pairs above: the freeze's own copy must not
    /// be able to shrink the test.
    private static let pinnedSafetyFixtures: [String] = [
        // emergency (CommandRouter.emergencyPhrases)
        "help", "emergency", "i fell", "fell down", "chest pain",
        "can't breathe", "cant breathe",
        "मद्दत", "सहयोग गर", "बचाउ", "आपतकाल", "लडेँ", "लडें",
        "लड्नुभयो", "सास फेर्न सकिन", "सास फेर्न गाह्रो", "छाती दुख्यो",
        // denial guard
        "i didn't", "i did not", "not yet", "haven't", "havent",
        "औषधि खाएको छैन", "औषधी खाएको छैन", "खाएको छैन",
        "नखाए", "नखाएको", "लिएको छैन", "भएन", "छैन",
        // medication acknowledgement, phrases
        "i took", "i've taken", "ive taken", "took my medication",
        "took my medicine", "taken my medication", "taken my medicine",
        "yes i took it",
        "औषधि खाएँ", "औषधि खाए", "औषधी खाएँ", "औषधी खाए",
        "दवाई खाएँ", "दवाई खाए", "दबाइ खाएँ", "दबाइ खाए",
        "औषधि लिएको छु", "औषधी लिएको छु", "दवाई लिएको छु",
        "लिइसकेँ", "लिइसकें", "खाइसकेँ", "खाइसकें",
        // medication acknowledgement, whole tokens
        "done", "taken", "took", "ate", "खाएँ", "खाए", "भयो",
        // frozen material beside text a rule DOES rewrite
        "मैले औषधी खाएको छैन", "बुबा नखाए", "आमाले खाए भन्नुभयो",
        "मद्दत गर्नुहोस्", "छाती दुख्यो, औषधी खाएको छैन",
        "भयो भन्नुभयो", "खाए, भयो", "भोली औषधि खाएँ",
        "औषधी खाएको छैन भोली", "गर्नुहोस भोली",
        // the routing lists beyond the net
        "कसैलाई फोन गर", "यो फोटो ह्वाट्सएपमा पठाउनुहोस",
        "हो", "होइन", "yes", "no", "correct", "nope",
        "मेरो ब्रीफिङ सुनाऊ", "समाचार सुनाऊ", "खबर पढ",
    ]

    // MARK: Shipped-table schema

    func testBundledVariantTablesValidateAndDeclareTheirDialect() throws {
        let tables = try bundledVariantTables()

        XCTAssertFalse(tables.hasLoadDegradation,
                       "no shipped table may be undecodable or mislabelled: "
                       + "\(tables.loadIssues)")

        for table in [tables.orthographic, tables.panRegional, tables.sttReductions]
            .compactMap({ $0 }) {
            XCTAssertTrue(table.tableID.hasPrefix("canonical-"),
                          "unexpected table id \(table.tableID)")
        }
        for label in DialectLabel.allCases where label != .default {
            guard let table = tables.dialectTables[label] else {
                XCTFail("region table missing for \(label.rawValue)")
                continue
            }
            // The filename/declaration cross-check the loader enforces — a
            // region file that declares no dialect would otherwise be
            // consulted as the pan-regional set for every speaker.
            XCTAssertEqual(table.dialectRaw, label.rawValue,
                           "canonical-\(label.rawValue).json must declare its own dialect")
        }
    }

    func testShippedEntriesPassEveryStructuralIssueCheck() throws {
        let tables = try bundledVariantTables()
        let all = [tables.orthographic, tables.panRegional, tables.sttReductions]
            .compactMap { $0 } + tables.dialectTables.values

        XCTAssertGreaterThanOrEqual(all.count, 5)
        for table in all {
            XCTAssertEqual(table.issues(), [],
                           "\(table.tableID) must validate: \(table.issues())")
            XCTAssertFalse(table.entries.isEmpty)
            XCTAssertEqual(Set(table.entries.map(\.id)).count, table.entries.count)
            for entry in table.entries {
                XCTAssertNotNil(entry.kind, "unknown kind \(entry.kindRaw)")
                XCTAssertNotEqual(entry.variant, entry.canonical)
                XCTAssertGreaterThanOrEqual(entry.evidence.fixtureExamples.count, 2,
                                            "\(entry.id) needs two cited examples")
                for example in entry.evidence.fixtureExamples {
                    XCTAssertTrue(example.contains(entry.variant),
                                  "\(entry.id) fixture does not contain the variant: \(example)")
                }
            }
        }
    }

    func testEveryShippedRuleHasAPinnedInOutPair() throws {
        let tables = try bundledVariantTables()
        let shippedIDs = Set(([tables.orthographic, tables.panRegional, tables.sttReductions]
            .compactMap { $0 } + tables.dialectTables.values)
            .flatMap { $0.entries.map(\.id) })
        let pinnedIDs = Set(Self.pinnedRulePairs.map(\.ruleID)
            + Self.pinnedInertPairs.map(\.ruleID))

        XCTAssertEqual(shippedIDs, pinnedIDs,
                       "a shipped rule was added or removed without a pinned "
                       + "in/out pair (or an inert-pair row) in this file")
    }

    func testShippedRulePairsCanonicalizeExactlyAsPinned() throws {
        let tables = try bundledVariantTables()
        let policy = widestPolicy()

        for pair in Self.pinnedRulePairs {
            let result = canonicalize(pair.input,
                                      dialect: pair.dialect,
                                      tables: tables,
                                      policy: policy)
            XCTAssertEqual(result.canonical, pair.expected,
                           "\(pair.ruleID) failed on \(pair.input)")
            XCTAssertEqual(result.applications.map(\.ruleID), [pair.ruleID],
                           "\(pair.ruleID) must be the single recorded application")
            let application = try XCTUnwrap(result.applications.first)
            XCTAssertFalse(application.original.isEmpty)
            XCTAssertFalse(application.canonical.isEmpty)
            // Provenance names the table that contributed the rule, and the
            // dialect that is the table's — which is what makes a log line
            // traceable to a reviewable row rather than to "a normalizer".
            XCTAssertEqual(application.dialect,
                           pair.dialect == .default ? nil : pair.dialect)
        }
    }

    func testUnconfirmedRulesShipButNeverFire() throws {
        let tables = try bundledVariantTables()
        let policy = widestPolicy()

        for pair in Self.pinnedInertPairs {
            let result = canonicalize(pair.input,
                                      dialect: .eastern,
                                      tables: tables,
                                      policy: policy)
            XCTAssertEqual(result.canonical, pair.input,
                           "\(pair.ruleID) is unconfirmed and must not fire")
            XCTAssertTrue(result.isIdentity)
            XCTAssertFalse(result.applications.map(\.ruleID).contains(pair.ruleID))
        }

        // …and the table says so: the four unconfirmed rows are reported inert
        // rather than silently absent.
        let selection = tables.selection(for: .eastern, policy: policy)
        XCTAssertTrue(selection.notes.contains("inert_entries:canonical-eastern:4"),
                      "notes were \(selection.notes)")
    }

    // MARK: Conditional gating (T-062's open questions)

    func testRegionTablesAreNotConsultedUntilTheAnswersLand() throws {
        let tables = try bundledVariantTables()

        // Default policy: region-marked tables are loaded but never consulted.
        let closed = canonicalize("गइछ", dialect: .eastern, tables: tables,
                                  policy: DialectCanonicalizer.Policy(enabled: true))
        XCTAssertEqual(closed.canonical, "गइछ")
        XCTAssertTrue(closed.isIdentity)
        XCTAssertTrue(closed.notes.contains("dialect_table_conditional:eastern"),
                      "notes were \(closed.notes)")

        // …and for a `.default` speaker they are not even a candidate.
        let defaultSpeaker = canonicalize("गइछ", dialect: .default, tables: tables,
                                          policy: widestPolicy())
        XCTAssertEqual(defaultSpeaker.canonical, "गइछ",
                       "a dialect rule must never fire for a speaker with no label")

        // Opened deliberately, they run.
        let open = canonicalize("गइछ", dialect: .eastern, tables: tables,
                                policy: widestPolicy())
        XCTAssertEqual(open.canonical, "गएछ")
    }

    func testADialectNeverBorrowsAnotherRegionsTable() throws {
        let tables = try bundledVariantTables()
        let result = canonicalize("गइछ", dialect: .doteli, tables: tables,
                                  policy: widestPolicy())
        XCTAssertEqual(result.canonical, "गइछ",
                       "an eastern rule must not fire for a doteli speaker: "
                       + "introducing another region's error is the one "
                       + "direction a canonicalizer must never move")
    }

    // MARK: The losslessness invariant (§4.7)

    /// The shipped rules that fail the WIDER keyword-layer invariant. MEASURED
    /// with the real matcher over the committed banks (offline harness,
    /// 2026-09-15) rather than reasoned: Swift's `String.contains` matches at
    /// GRAPHEME CLUSTER boundaries, so `वाट्सएप` is found inside `वाट्सएपमा` but
    /// NOT inside `ह्वाट्सएपमा`, where it starts mid-cluster after the `ह्`
    /// conjunct. `ह्वाट्सएपमा → वाट्सएपमा` therefore moves an utterance INTO the
    /// sensitive-call block.
    ///
    /// It ships anyway because the COMPOSITION keeps canonical text away from
    /// every routing consumer (D-1) — and it is asserted as an exception below,
    /// so a stale or silently widened set fails rather than passes.
    private static let keywordLayerExceptions: Set<String> = ["pan-loan-whatsapp"]

    /// §4.7's invariant, plus the wider keyword-layer invariant with the
    /// measured exceptions applied to the rules that are allowed to differ.
    private func assertNoRoutingDrift(_ result: CanonicalizationResult,
                                      original: String,
                                      line: UInt = #line) {
        XCTAssertTrue(CanonicalSafetyFreeze.isLossless(original: original,
                                                       canonical: result.canonical),
                      "§4.7 violated for \(original) -> \(result.canonical)", line: line)
        let applied = result.applications.map(\.ruleID)
        let before = CanonicalSafetyFreeze.matchedKeywordClauses(in: original)
        let after = CanonicalSafetyFreeze.matchedKeywordClauses(in: result.canonical)
        guard !Set(applied).isDisjoint(with: Self.keywordLayerExceptions) else {
            XCTAssertEqual(after, before,
                           "a keyword-layer match changed for \(original) -> "
                           + "\(result.canonical) via \(applied)", line: line)
            return
        }
        // An excepted rule may only move an utterance INTO the call block. Any
        // other difference — a clause dropped, a safety clause touched — is a
        // failure even for an excepted rule.
        XCTAssertTrue(after.contains(.sensitiveCall),
                      "the documented exception must actually introduce the call "
                      + "clause (\(original) -> \(result.canonical))", line: line)
        XCTAssertTrue(after.subtracting(before).isSubset(of: [.sensitiveCall]),
                      "an excepted rule changed more than the call clause: "
                      + "\(before) -> \(after)", line: line)
        XCTAssertTrue(before.subtracting(after).isEmpty,
                      "an excepted rule REMOVED a clause: \(before) -> \(after)",
                      line: line)
    }

    func testPinnedSafetyFixturesAreLossless() throws {
        let tables = try bundledVariantTables()
        let policy = widestPolicy()
        var rewritten = 0

        for fixture in Self.pinnedSafetyFixtures {
            for dialect in DialectLabel.allCases {
                let result = canonicalize(fixture, dialect: dialect,
                                          tables: tables, policy: policy)
                if result.canonical != fixture { rewritten += 1 }
                assertNoRoutingDrift(result, original: fixture)
            }
        }
        XCTAssertGreaterThan(rewritten, 0, "the fixture set must include text that "
                              + "is actually rewritten, or the gate is vacuous")
    }

    func testFrozenClassesSurviveEveryShippedRule() throws {
        let tables = try bundledVariantTables()
        let policy = widestPolicy()
        var sawRewrite = false

        // Carrier sentences place each frozen form next to each shipped rule's
        // surface, so a rule that rewrote ACROSS a frozen form — the hazard the
        // token boundary exists for — cannot pass by rewriting nothing.
        for frozen in CanonicalSafetyFreeze.substringLists + CanonicalSafetyFreeze.tokenList {
            for pair in Self.pinnedRulePairs {
                for carrier in ["\(frozen) \(pair.input)", "\(pair.input) \(frozen)"] {
                    let result = canonicalize(carrier, dialect: pair.dialect,
                                              tables: tables, policy: policy)
                    if result.canonical != carrier { sawRewrite = true }
                    assertNoRoutingDrift(result, original: carrier)
                }
            }
        }
        XCTAssertTrue(sawRewrite, "carriers must include rewritten text or this "
                      + "test proves nothing")
    }

    func testLosslessnessTracksTheKeywordLayerNotJustTheNet() {
        // The one shipped rule that fails the WIDER invariant, and the reason
        // "measured, not reasoned" is written on it: Swift's `String.contains`
        // matches at grapheme-cluster boundaries, so वाट्सएप is found inside
        // वाट्सएपमा but NOT inside ह्वाट्सएपमा — there it starts mid-cluster,
        // after the ह् conjunct. A scalar-based matcher (Python's `in`) says the
        // opposite, which is how the false version of this comment survived
        // review until the offline harness ran the real matcher.
        XCTAssertFalse(CanonicalSafetyFreeze.matchedKeywordClauses(in: "ह्वाट्सएपमा")
            .contains(.sensitiveCall))
        XCTAssertTrue(CanonicalSafetyFreeze.matchedKeywordClauses(in: "वाट्सएपमा")
            .contains(.sensitiveCall))
        // Pinned as a KNOWN EXCEPTION (see `keywordLayerExceptions`), stated in
        // the failing direction so it cannot go stale silently.
        XCTAssertFalse(CanonicalSafetyFreeze
            .isKeywordLayerLossless(original: "ह्वाट्सएपमा",
                                    canonical: "वाट्सएपमा"))
        // What IS load-bearing in the shipped composition: §4.7's invariant over
        // the safety net, which holds for that rule.
        XCTAssertTrue(CanonicalSafetyFreeze.isLossless(original: "ह्वाट्सएपमा",
                                                       canonical: "वाट्सएपमा"))
        // The wider invariant still catches a rewrite that moves an utterance
        // between SAFETY clauses — it is not decoration.
        XCTAssertFalse(CanonicalSafetyFreeze
            .isKeywordLayerLossless(original: "भया", canonical: "भयो"))
        XCTAssertFalse(CanonicalSafetyFreeze
            .isKeywordLayerLossless(original: "नखाए", canonical: "खाए"))
    }

    func testThePhraseListsAreClausesNotMembers() {
        // The clause-level reading, pinned on the case that forced it: both
        // औषधी खाए and औषधि खाए are ack-list members, so moving between them
        // fires the SAME clause and cannot change the medication flow. A
        // member-level comparison would have refused a rule the design ships.
        XCTAssertEqual(CanonicalSafetyFreeze.matchedClauses(in: "औषधी खाए"),
                       CanonicalSafetyFreeze.matchedClauses(in: "औषधि खाए"))
        XCTAssertTrue(CanonicalSafetyFreeze.isLossless(original: "औषधी खाए",
                                                       canonical: "औषधि खाए"))
        // Sanity: the clause sets are otherwise not all equal — the fixture
        // would prove nothing if everything matched everything.
        XCTAssertNotEqual(CanonicalSafetyFreeze.matchedClauses(in: "औषधि खाए"),
                          CanonicalSafetyFreeze.matchedClauses(in: "भयो"))
        XCTAssertEqual(CanonicalSafetyFreeze.matchedClauses(in: "भयो"),
                       [.acknowledgementToken])
        XCTAssertTrue(CanonicalSafetyFreeze.matchedClauses(in: "आपतकाल")
            .contains(.emergency))
    }

    func testLosslessnessTripsWhenARuleWouldIntroduceAFrozenMatch() {
        // The invariant must actually be able to FAIL, or it is decoration.
        XCTAssertFalse(CanonicalSafetyFreeze
            .isLossless(original: "भया", canonical: "भयो"))
        XCTAssertFalse(CanonicalSafetyFreeze
            .isLossless(original: "नखाए", canonical: "खाए"))
        XCTAssertFalse(CanonicalSafetyFreeze
            .isLossless(original: "औषधि खाएको छैन", canonical: "औषधि खाए"))
    }

    func testTheFreezeFoldsWhitespaceTheWayTheNetDoes() {
        // The net collapses interior whitespace before its emergency check
        // (CommandRouter.swift:606-620 — the STT joins per-segment text with
        // single spaces, so an utterance arrives with interior runs), and the
        // freeze's matchers fold identically. Parity matters in BOTH
        // directions: a transcript the net acts on but the freeze reads as
        // harmless would let a table rewrite a distress utterance, and one the
        // freeze refuses but the net ignores would refuse a legal table.
        XCTAssertTrue(CanonicalSafetyFreeze.matchedClauses(in: "मद्दत  गर्नुहोस्")
            .contains(.emergency))
        XCTAssertTrue(CanonicalSafetyFreeze
            .isLossless(original: "मद्दत  गर्नुहोस्", canonical: "मद्दत गर्नुहोस्"))
        // A rewrite that INTRODUCED an emergency phrase under the folded
        // reading is an introduction clause (b) must catch, not wave through.
        XCTAssertFalse(CanonicalSafetyFreeze
            .isLossless(original: "सहयोग", canonical: "सहयोग  गर"))
        XCTAssertTrue(CanonicalSafetyFreeze.touches(variant: "सहयोग",
                                                    canonical: "सहयोग  गर"))
    }

    // MARK: Negation-marker refusal (§4.3 `negationMarkerTouched`)

    func testNegationMarkerTouchedRefusesBhayaToBhayo() {
        // The live finding behind this test: T-062 files भया -> भयो as
        // CONFIRMED (it is attested in DialectLexicon.json), but भयो is a
        // shipped medication-ack TOKEN. The rewrite maps a form ONTO frozen
        // material, which §4.7 forbids outright — a text that would have
        // reached no safety branch would start matching the ack branch.
        XCTAssertTrue(CanonicalSafetyFreeze.touches(variant: "भया", canonical: "भयो"))

        let entry = makeEntry("dot-past-bhaya",
                              kind: "morphophonemic",
                              variant: "भया",
                              canonical: "भयो")
        let table = makeTable("canonical-doteli", dialect: .doteli, entries: [entry])
        XCTAssertTrue(table.issues().contains(.negationMarkerTouched(entry: "dot-past-bhaya")),
                      "issues were \(table.issues())")

        // Per-table fail-closed: ONE defective entry refuses the WHOLE table
        // (D-4), because a partially applied table yields a transcript that is
        // neither the original nor a known canonical form.
        let tables = makeSet(dialectTables: [.doteli: table])
        let result = canonicalize("भया", dialect: .doteli, tables: tables,
                                  policy: widestPolicy())
        XCTAssertEqual(result.canonical, "भया", "the table must canonicalize nothing")
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.degraded)
        XCTAssertTrue(result.notes.contains("table_rejected:canonical-doteli:1"),
                      "notes were \(result.notes)")
    }

    func testNegationMarkerTouchedRefusesTheNakhayeToKhayeHazard() {
        // The hazard the shipped comment names: खाए sits inside नखाए.
        XCTAssertTrue(CanonicalSafetyFreeze.touches(variant: "नखाए", canonical: "खाए"))
        // …and the same rule written the other way round (an ack turned into a
        // refusal) is refused too: §4.7 freezes both directions.
        XCTAssertTrue(CanonicalSafetyFreeze.touches(variant: "खाए", canonical: "नखाए"))
        // A prefix-attached marker that neither side spells as a token.
        XCTAssertTrue(CanonicalSafetyFreeze.touches(variant: "खाएको", canonical: "नखाएको"))
    }

    func testNegationMarkerTouchedLeavesEveryShippedRuleAlone() throws {
        let tables = try bundledVariantTables()
        for table in ([tables.orthographic, tables.panRegional, tables.sttReductions]
            .compactMap { $0 } + tables.dialectTables.values) {
            for entry in table.entries {
                XCTAssertFalse(CanonicalSafetyFreeze
                    .touches(variant: entry.variant, canonical: entry.canonical),
                               "\(entry.id) would be refused")
            }
        }
    }

    func testTheShippedDoteliTableDocumentsItsRefusal() throws {
        // The refused row is not silently missing: the file says why, so a
        // later reader cannot "restore" it by adding a table entry.
        guard let url = Bundle.main.url(forResource: "canonical-doteli",
                                        withExtension: "json",
                                        subdirectory: VariantTableSet.resourceSubdirectory)
            ?? Bundle.main.url(forResource: "canonical-doteli", withExtension: "json") else {
            throw XCTSkip("canonical-doteli.json not bundled yet")
        }
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let refused = try XCTUnwrap(json["refusedEntries"] as? [[String: Any]])
        let heading = try XCTUnwrap(refused.first)
        XCTAssertEqual(heading["variant"] as? String, "भया")
        XCTAssertEqual(heading["canonical"] as? String, "भयो")
        let reason = try XCTUnwrap(heading["reason"] as? String)
        XCTAssertTrue(reason.contains("ackTokens"))
        XCTAssertTrue(reason.contains("T-077"))
    }

    // MARK: Composition (§4.6 / D-1)

    /// The pair's two consumers, pulled apart: the safety half is the
    /// ORIGINAL, forever (D-1), and the model half is the prepared text —
    /// which, since [CORRECTION-ANYBRAIN], is what the PICKER brain reads
    /// too. The two accessors deliberately no longer agree, and this is the
    /// test that says so: `pickerBrainInput` used to BE `safetyNetInput`
    /// (§4.6 / E-17), which is exactly the rule the layer switches needed
    /// lifted to be testable against the picker brain.
    func testSafetyNetKeepsTheOriginalWhileThePickerBrainReadsThePreparedText() {
        let tables = makeSet(orthographic: makeTable(
            "canonical-orthographic",
            entries: [makeEntry("test-halanta", variant: "गर्नुहोस",
                                canonical: "गर्नुहोस्")]))
        let pair = IntentInputCanonicalization.prepare(
            sanitisedTranscript: "अब यो काम गर्नुहोस",
            dialect: .default,
            tables: tables,
            policy: widestPolicy())

        XCTAssertEqual(pair.original, "अब यो काम गर्नुहोस")
        XCTAssertEqual(pair.modelInput, "अब यो काम गर्नुहोस्")
        XCTAssertFalse(pair.isIdentity)
        // D-1: the keyword safety net reads the original, forever.
        XCTAssertEqual(pair.safetyNetInput, "अब यो काम गर्नुहोस")
        // [CORRECTION-ANYBRAIN] §4.6 as relocated: a MODEL reads the prepared
        // text, and the picker brain is a model — so a canonicalization that
        // rewrote the text a model reads reaches the picker's prompt, not the
        // router.
        XCTAssertEqual(pair.pickerBrainInput, "अब यो काम गर्नुहोस्")
        XCTAssertEqual(pair.pickerBrainInput, pair.modelInput,
                       "the two model consumers read the same string")
        XCTAssertNotEqual(pair.safetyNetInput, pair.pickerBrainInput,
                          "the fixture must actually rewrite, or this test "
                          + "proves nothing about the two consumers")
    }

    /// The INERT half of the same rule: while no layer rewrote anything the
    /// two accessors are the same string again, which is what keeps the
    /// shipped default (both keys absent) byte-identical — a picker brain
    /// that reads `pickerBrainInput` cannot tell this pair from the raw
    /// transcript.
    func testAnInertPairStillHandsThePickerBrainTheOriginal() {
        let pair = IntentInputCanonicalization.prepare(
            sanitisedTranscript: "अब यो काम गर्नुहोस",
            dialect: .default,
            tables: VariantTableSet(orthographic: nil, panRegional: nil,
                                    sttReductions: nil, dialectTables: [:],
                                    loadIssues: []),
            policy: DialectCanonicalizer.Policy(enabled: false))

        XCTAssertTrue(pair.isIdentity)
        XCTAssertEqual(pair.pickerBrainInput, "अब यो काम गर्नुहोस")
        XCTAssertEqual(pair.pickerBrainInput, pair.original)
        XCTAssertEqual(pair.pickerBrainInput, pair.safetyNetInput)
    }

    func testDisabledPolicyIsAByteIdenticalPassThrough() {
        let tables = makeSet(orthographic: makeTable(
            "canonical-orthographic",
            entries: [makeEntry("test-halanta", variant: "गर्नुहोस",
                                canonical: "गर्नुहोस्")]))
        for text in ["अब यो काम गर्नुहोस", "औषधी खाएको छैन", "", "भया"] {
            let pair = IntentInputCanonicalization.prepare(
                sanitisedTranscript: text,
                dialect: .default,
                tables: tables,
                policy: DialectCanonicalizer.Policy(enabled: false))
            XCTAssertEqual(pair.canonical, text)
            XCTAssertEqual(pair.original, text)
            XCTAssertTrue(pair.isIdentity)
            XCTAssertTrue(pair.applications.isEmpty)
            // No rule_ids key: metadata for an inert pass must carry no
            // provenance, so a consumer cannot believe a rewrite happened.
            XCTAssertNil(pair.observabilityMetadata["rule_ids"])
        }
    }

    func testEmptyTranscriptIsIdentityUnderTheWidestPolicy() {
        let result = canonicalize("", dialect: .eastern,
                                  tables: makeSet(), policy: widestPolicy())
        XCTAssertEqual(result.canonical, "")
        XCTAssertTrue(result.isIdentity)
    }

    // MARK: The kill switch

    func testCanonicalizerPreferenceDefaultsOff() {
        let defaults = isolateDefaults()
        let preferences = CanonicalizerPreferences(defaults: defaults)

        XCTAssertFalse(preferences.canonicalizerEnabled,
                       "an absent key must read as OFF")

        // …and the runtime policy composes BOTH gates with the shipped gate
        // function, so the toggle alone can never enable it.
        XCTAssertFalse(DialectCanonicalizer.Policy
            .runtime(defaults: defaults, isCompiledIn: true, isToggleOn: nil).enabled)
        XCTAssertFalse(DialectCanonicalizer.Policy
            .runtime(defaults: defaults, isCompiledIn: false, isToggleOn: true).enabled,
                       "the compile-time gate cannot be talked round by a stored value")

        preferences.setCanonicalizerEnabled(true)
        XCTAssertTrue(preferences.canonicalizerEnabled)
        XCTAssertTrue(DialectCanonicalizer.Policy
            .runtime(defaults: defaults, isCompiledIn: true, isToggleOn: nil).enabled)
        XCTAssertFalse(DialectCanonicalizer.Policy
            .runtime(defaults: defaults, isCompiledIn: false, isToggleOn: nil).enabled)
        // [ENCODER-ALWAYS-ON] The `INTENT_ENCODER` condition is part of the
        // app target's DEFAULT compilation conditions now (ios/project.yml),
        // so the defaulted `isCompiledIn` reads TRUE in this build and the
        // runtime policy follows the STORED key — which is why the shipped
        // default rests on that key being absent, pinned above and by the
        // reset below. The compile-time half still cannot be talked round
        // (the `isCompiledIn: false` cases above and below).
        XCTAssertTrue(DialectCanonicalizer.Policy.runtime(defaults: defaults).enabled)

        preferences.reset()
        XCTAssertFalse(preferences.canonicalizerEnabled)
        XCTAssertFalse(DialectCanonicalizer.Policy.runtime(defaults: defaults).enabled,
                       "a fresh install is inert again")
    }

    // MARK: Fail-closed per table (D-4)

    func testOneBadEntryRefusesOnlyItsOwnTable() {
        let good = makeTable("canonical-orthographic", entries: [
            makeEntry("good-halanta", variant: "गर्नुहोस", canonical: "गर्नुहोस्")
        ])
        let bad = makeTable("canonical-panregional", entries: [
            makeEntry("bad-evidence", variant: "भोली", canonical: "भोलि",
                      examples: ["भोली"])  // one example: below the §4.3.1 floor
        ])
        let tables = makeSet(orthographic: good, panRegional: bad)
        let result = canonicalize("गर्नुहोस भोली", dialect: .default,
                                  tables: tables, policy: widestPolicy())

        XCTAssertEqual(result.canonical, "गर्नुहोस् भोली",
                       "the valid table still runs; the rejected one changes nothing")
        XCTAssertTrue(result.degraded)
        XCTAssertTrue(result.notes.contains("table_rejected:canonical-panregional:1"),
                      "notes were \(result.notes)")
    }

    func testStructuralIssuesFailTheTable() {
        func issues(_ entry: VariantTableEntry, formatVersion: Int = 1) -> [VariantTable.Issue] {
            VariantTable(formatVersion: formatVersion,
                         tableID: "t",
                         dialectRaw: nil,
                         generation: VariantTable.Generation(status: "TEST", path: "t", date: nil),
                         entries: [entry]).issues()
        }

        XCTAssertEqual(issues(makeEntry("e", variant: "क", canonical: "ख"), formatVersion: 2),
                       [.unsupportedFormatVersion(2)])
        XCTAssertTrue(issues(makeEntry("e", kind: "transliteration",
                                       variant: "क", canonical: "ख"))
            .contains(.unknownKind("transliteration")))
        XCTAssertTrue(issues(makeEntry("e", variant: "", canonical: "ख"))
            .contains(.emptyVariantOrCanonical(entry: "e")))
        XCTAssertTrue(issues(makeEntry("e", variant: "क", canonical: "क"))
            .contains(.variantEqualsCanonical(entry: "e")))

        // No evidence at all, versus evidence that refutes its own source.
        let blank = VariantTableEntry(
            id: "e", kindRaw: "orthographic", variant: "क", canonical: "ख",
            status: .confirmed, modelImpact: nil, resolves: [], note: nil,
            evidence: .authoredEmpty)
        XCTAssertTrue(issues(blank).contains(.evidenceMissing(entry: "e")))

        let corpusWithoutCount = VariantTableEntry(
            id: "e", kindRaw: "orthographic", variant: "क", canonical: "ख",
            status: .confirmed, modelImpact: nil, resolves: [], note: nil,
            evidence: VariantTableEntry.Evidence(source: .corpus,
                                                 corpusRevision: "rev-1",
                                                 rowIDs: ["r1"],
                                                 occurrences: 0,
                                                 fixtureExamples: []))
        XCTAssertTrue(issues(corpusWithoutCount)
            .contains(.evidenceContradictsSource(entry: "e")))

        // Duplicate ids and an unusable dialect label.
        let duplicate = VariantTable(formatVersion: 1, tableID: "t",
                                     dialectRaw: nil,
                                     generation: VariantTable.Generation(status: "TEST",
                                                                         path: "t", date: nil),
                                     entries: [makeEntry("e", variant: "क", canonical: "ख"),
                                               makeEntry("e", variant: "ग", canonical: "घ")])
        XCTAssertTrue(duplicate.issues().contains(.duplicateEntryID("e")))

        let mislabelled = VariantTable(formatVersion: 1, tableID: "t",
                                       dialectRaw: "western",
                                       generation: VariantTable.Generation(status: "TEST",
                                                                           path: "t", date: nil),
                                       entries: [makeEntry("e", variant: "क", canonical: "ख")])
        XCTAssertTrue(mislabelled.issues().contains(.unknownDialect("western")))
        XCTAssertNil(mislabelled.dialect)

        let empty = VariantTable(formatVersion: 1, tableID: "t", dialectRaw: nil,
                                 generation: VariantTable.Generation(status: "TEST",
                                                                     path: "t", date: nil),
                                 entries: [])
        XCTAssertTrue(empty.issues().contains(.emptyEntries))
    }

    func testMalformedStatusFailsTheFileClosed() throws {
        let json = """
        {"formatVersion": 1, "tableID": "t", "generation": {"status": "TEST", "path": "t"},
         "entries": [{"id": "e", "kind": "orthographic", "variant": "क",
                      "canonical": "ख", "status": "probably"}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(VariantTable.self,
                                                      from: Data(json.utf8)),
                             "an unrecognised status must not silently become "
                             + "`confirmed` — the file fails closed instead")
    }

    func testRevisionMovesWithContentAndIsStableOtherwise() {
        let first = makeSet(orthographic: makeTable("canonical-orthographic", entries: [
            makeEntry("a", variant: "गर्नुहोस", canonical: "गर्नुहोस्")
        ]))
        let same = makeSet(orthographic: makeTable("canonical-orthographic", entries: [
            makeEntry("a", variant: "गर्नुहोस", canonical: "गर्नुहोस्")
        ]))
        let changed = makeSet(orthographic: makeTable("canonical-orthographic", entries: [
            makeEntry("a", variant: "गर्नुहोस", canonical: "गर्नुहोस्"),
            makeEntry("b", variant: "गर्नुस्", canonical: "गर्नुहोस्")
        ]))

        XCTAssertEqual(first.revision, same.revision)
        XCTAssertNotEqual(first.revision, changed.revision)
        XCTAssertTrue(first.revision.hasPrefix("TEST#"))
        XCTAssertEqual(VariantTableSet.empty.revision, "none")
    }

    // MARK: Provenance and the §4.5 span map

    func testApplicationsCarryExactRangesAndSurfaceForms() throws {
        let tables = makeSet(panRegional: makeTable("canonical-panregional", entries: [
            makeEntry("bholi", variant: "भोली", canonical: "भोलि")
        ]))
        let text = "भोली बिहान"
        let result = canonicalize(text, dialect: .default, tables: tables,
                                  policy: widestPolicy())

        XCTAssertEqual(result.canonical, "भोलि बिहान")
        let application = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(application.ruleID, "bholi")
        XCTAssertEqual(application.tableID, "canonical-panregional")
        XCTAssertNil(application.dialect)
        XCTAssertEqual(application.original, "भोली")
        XCTAssertEqual(application.canonical, "भोलि")
        XCTAssertEqual(application.originalRange, 0..<4)
        XCTAssertEqual(application.canonicalRange, 0..<4)

        // The ranges are only meaningful if they SLICE the two strings to the
        // recorded surfaces — the property the span decoder will rely on.
        let textScalars = Array(text.unicodeScalars)
        let canonicalScalars = Array(result.canonical.unicodeScalars)
        XCTAssertEqual(String(String.UnicodeScalarView(
            textScalars[application.originalRange])), application.original)
        XCTAssertEqual(String(String.UnicodeScalarView(
            canonicalScalars[application.canonicalRange])), application.canonical)
    }

    func testLengthChangingRewriteRecordsBothRanges() {
        // A halanta-added rewrite is one scalar longer, which is the case that
        // makes the provenance arithmetic non-trivial.
        let tables = makeSet(orthographic: makeTable("canonical-orthographic", entries: [
            makeEntry("halanta", variant: "गर्नुहोस", canonical: "गर्नुहोस्")
        ]))
        let text = "काम गर्नुहोस भोली"
        let result = canonicalize(text, dialect: .default, tables: tables,
                                  policy: widestPolicy())

        XCTAssertEqual(result.canonical, "काम गर्नुहोस् भोली")
        let application = result.applications.first
        XCTAssertEqual(application?.originalRange, 4..<12)
        XCTAssertEqual(application?.canonicalRange, 4..<13)

        let scalars = Array(text.unicodeScalars)
        XCTAssertEqual(String(String.UnicodeScalarView(scalars[4..<12])), "गर्नुहोस")
        XCTAssertEqual(String(String.UnicodeScalarView(scalars[4..<13])), "गर्नुहोस्")
    }

    func testDigitFoldAndNFCBuiltinsAreRecorded() {
        // O-5: the digit fold is a builtin, not a table row, and it is still
        // recorded as an application (D-5: `applications` is never empty when
        // `canonical != original`).
        let digits = canonicalize("८ बजे", dialect: .default,
                                  tables: makeSet(), policy: widestPolicy())
        XCTAssertEqual(digits.canonical, "8 बजे")
        XCTAssertEqual(digits.applications.map(\.ruleID),
                       ["builtin-devanagari-digit-fold"])

        // O-1: NFC is a no-op for Devanagari matras (the two-part vowel signs
        // have no canonical decomposition), so that class is pinned as
        // unchanged…
        let nepali = canonicalize("को नि", dialect: .default,
                                  tables: makeSet(), policy: widestPolicy())
        XCTAssertEqual(nepali.canonical, "को नि")
        XCTAssertTrue(nepali.isIdentity)

        // …and the transform itself is pinned on a run where it does compose,
        // including the length change (2 scalars → 1) that the offset
        // arithmetic has to survive.
        let composed = canonicalize("cafe\u{0301}", dialect: .default,
                                    tables: makeSet(), policy: widestPolicy())
        XCTAssertEqual(composed.canonical, "café")
        XCTAssertEqual(composed.applications.map(\.ruleID),
                       ["builtin-nfc-precomposition"])
        XCTAssertEqual(composed.applications.first?.originalRange, 3..<5)
        XCTAssertEqual(composed.applications.first?.canonicalRange, 3..<4)
    }

    func testSpanMapIsExactInsideAnApplicationAndWidenedAcrossOne() {
        let tables = makeSet(panRegional: makeTable("canonical-panregional", entries: [
            makeEntry("bholi", variant: "भोली", canonical: "भोलि")
        ]))
        let result = canonicalize("भोली बिहान", dialect: .default,
                                  tables: tables, policy: widestPolicy())
        let pair = IntentTranscriptPair(original: "भोली बिहान",
                                        canonical: result.canonical,
                                        applications: result.applications,
                                        degraded: result.degraded,
                                        tableRevision: result.tableRevision,
                                        notes: result.notes)

        // Untouched region.
        XCTAssertEqual(pair.originalRange(forCanonicalRange: 5..<10), .untouched(5..<10))
        // Wholly inside the application → the application's own original range.
        XCTAssertEqual(pair.originalRange(forCanonicalRange: 0..<4), .exact(0..<4))
        // Straddling an application boundary → widened, and the caller must
        // then abstain for any span a side effect depends on (§4.5).
        let straddle = pair.originalRange(forCanonicalRange: 3..<6)
        XCTAssertTrue(straddle.requiresAbstention)
        XCTAssertEqual(straddle, .widened(0..<10))
    }

    func testObservabilityMetadataCarriesNoSurfaceForms() {
        let tables = makeSet(panRegional: makeTable("canonical-panregional", entries: [
            makeEntry("bholi", variant: "भोली", canonical: "भोलि")
        ]))
        let result = canonicalize("भोली बिहान", dialect: .default,
                                  tables: tables, policy: widestPolicy())
        let metadata = result.observabilityMetadata

        XCTAssertEqual(metadata["application_count"], "1")
        XCTAssertEqual(metadata["rule_ids"], "bholi")
        XCTAssertEqual(metadata["table_ids"], "canonical-panregional")
        XCTAssertEqual(metadata["kinds"], "orthographic")
        XCTAssertEqual(metadata["degraded"], "false")
        for (key, value) in metadata {
            XCTAssertFalse(value.contains("भोली"), "\(key) leaked an original form")
            XCTAssertFalse(value.contains("भोलि"), "\(key) leaked a canonical form")
            XCTAssertFalse(value.contains("बिहान"), "\(key) leaked a transcript")
        }

        // The payload the ENCODER emits from is the pair's — and it is the same
        // one, assembled by the same builder, so the two cannot drift into
        // different disclosure rules.
        let pair = IntentInputCanonicalization.prepare(sanitisedTranscript: "भोली बिहान",
                                                       dialect: .default,
                                                       tables: tables,
                                                       policy: widestPolicy())
        XCTAssertEqual(pair.observabilityMetadata, metadata)
        for (key, value) in pair.observabilityMetadata {
            XCTAssertFalse(value.contains("भोली"), "\(key) leaked an original form")
            XCTAssertFalse(value.contains("भोलि"), "\(key) leaked a canonical form")
            XCTAssertFalse(value.contains("बिहान"), "\(key) leaked a transcript")
        }
    }

    // MARK: Stages

    func testStageOrderIsTheDesignsAndARuleCannotRewriteAnothersOutput() {
        XCTAssertEqual(CanonicalizationKind.allCases
            .sorted { $0.stageOrder < $1.stageOrder }
            .map(\.rawValue),
                       ["orthographic", "misSegmentation", "lexicalVariant", "clippedForm"])
        // T-062's dialect-axis vocabulary maps onto the same four stages, so a
        // dialect bank is loadable as data unchanged.
        XCTAssertEqual(CanonicalizationKind.mapping("morphophonemic"), .lexicalVariant)
        XCTAssertEqual(CanonicalizationKind.mapping("lexical"), .lexicalVariant)
        XCTAssertEqual(CanonicalizationKind.mapping("clipped"), nil)

        // A stage-1 rule produces "गर्नुहोस्"; a stage-3 rule that would then
        // rewrite that output must not: edits are sealed, so no rule can
        // consume another rule's production.
        let stageOne = makeEntry("stage-one", kind: "orthographic",
                                 variant: "गर्नुहोस", canonical: "गर्नुहोस्")
        let stageThree = makeEntry("stage-three", kind: "lexicalVariant",
                                   variant: "गर्नुहोस्", canonical: "कुरा")
        let tables = makeSet(orthographic: makeTable("canonical-orthographic",
                                                     entries: [stageOne]),
                             panRegional: makeTable("canonical-panregional",
                                                    entries: [stageThree]))
        let result = canonicalize("गर्नुहोस", dialect: .default, tables: tables,
                                  policy: widestPolicy())
        XCTAssertEqual(result.canonical, "गर्नुहोस्")
        XCTAssertEqual(result.applications.map(\.ruleID), ["stage-one"])
    }
}

// MARK: - [TG-12] The STT-error corrector

/// The correction layer's suite (`Services/Voice/SttErrorCorrector.swift`,
/// Phase 1 of the STT-error-correction addendum). It lives in this file for the
/// same reason the canonicalizer's does: the two share the composition seam
/// (`IntentInputCanonicalization.prepare`), the same resource-loading shape, and
/// the same AUTHORING guard — a fixture that loads through the app's own loader
/// is the only fixture that says anything about the app.
///
/// AUTHORED UNDER A TESTING HOLD. No `xcodebuild`, simulator or gate was run for
/// this task (the task's constraint, and the iOS build environment's own
/// [ios-build-environment-quirks] caveat), so nothing below is evidence of a
/// green suite: the verification is `swiftc -parse` plus the measured numbers in
/// each comment. The verdicts pinned here — 0.8125/0.83/0.6625/0.2625 and the
/// `safety_veto` arms — were measured against the shipped bank on this host, not
/// chosen.
extension DialectIdentifierTests {

    // MARK: Corrector fixtures

    /// A hand-built corrector bank: the whole data contract in JSON, so a
    /// fixture can set the threshold, the lexicon, the measured rows, the
    /// entity banks and the priors independently of the shipped measurement.
    ///
    /// JSON rather than a Swift literal because the bank IS JSON and the loader
    /// under test is the app's own (`CorrectionLexicon.decode`) — a fixture that
    /// loads here loads in the app, and one that fails to load fails the same
    /// way (fail-closed, `degraded`).
    ///
    /// `lowerBound`/`upperBound` are the card's selectable range and are
    /// permissive here on purpose: the range gates `Policy.runtime` and the
    /// settings surface, which have their own fixtures, and a fixture that
    /// wanted a 0.50 threshold should not have to pretend 0.50 is calibrated.
    private func makeCorrectionLexicon(
        threshold: Double = 0.80,
        lowerBound: Double = 0.0,
        upperBound: Double = 1.0,
        stale: Bool = false,
        lexicon: [String],
        rows: [(id: String, variant: String, canonical: String,
                errorClass: String, occurrences: Int)] = [],
        entities: [String: [String]] = [:],
        l1: [(w: String, c: String, score: Double)] = [],
        l2: [(frame: String, c: String, score: Double)] = [],
        l3: [(cue: String, c: String, score: Double)] = [],
        folds: [(scalars: [String], occurrences: Int)] = [(["श", "स"], 12)],
        elides: [String] = ["्"],
        /// The edit tier's bound. Tests that mean to exercise ONE generator set
        /// this to 0 so the other tiers cannot produce the candidate: a test
        /// that says "the phonetic key found it" must be able to rule out the
        /// edit distance having found it first.
        levenshteinBound: Int = 2,
        /// Refusal fixtures only. The loader refuses a WHOLE bank over one bad
        /// row (`safetySetTouched`, `foldWithoutSupport`, `emptyEntries`), and a
        /// test that pins a refusal has to hold the refused bank, not a usable
        /// one. Every other fixture asserts the bank is clean, because a
        /// fixture that silently degrades would make its test prove nothing.
        allowingIssues: Bool = false,
        runRevision: String = "correction-fixture/v1"
    ) -> CorrectionLexicon {
        func quoted(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        let lexiconJSON = lexicon
            .map { "{\"token\": \(quoted($0)), \"occurrences\": 7}" }
            .joined(separator: ",")
        let rowsJSON = rows.map { row in
            "{\"id\": \(quoted(row.id)), \"kind\": \"orthographic\", "
                + "\"variant\": \(quoted(row.variant)), "
                + "\"canonical\": \(quoted(row.canonical)), \"evidence\": {"
                + "\"source\": \"corpus\", \"errorClass\": \(quoted(row.errorClass)), "
                + "\"occurrences\": \(row.occurrences), "
                + "\"corpusRevision\": \"fixture-corpus\"}}"
        }.joined(separator: ",")
        let entitiesJSON = entities.keys.sorted().map { name in
            let values = (entities[name] ?? []).map(quoted).joined(separator: ",")
            return "\(quoted(name)): [\(values)]"
        }.joined(separator: ",")
        let l1JSON = l1.map {
            "{\"w\": \(quoted($0.w)), \"c\": \(quoted($0.c)), \"count\": 3, \"score\": \($0.score)}"
        }.joined(separator: ",")
        let l2JSON = l2.map {
            "{\"frame\": \(quoted($0.frame)), \"candidates\": [{\"c\": \(quoted($0.c)), \"count\": 3, \"score\": \($0.score)}]}"
        }.joined(separator: ",")
        let l3JSON = l3.map {
            "{\"cue\": \(quoted($0.cue)), \"candidates\": [{\"c\": \(quoted($0.c)), \"count\": 3, \"score\": \($0.score)}]}"
        }.joined(separator: ",")

        let table = """
        {
          "formatVersion": 1,
          "generation": { "status": "FIXTURE" },
          "entries": [\(rowsJSON)],
          "correctionBank": {
            "formatVersion": 1,
            "toolRevision": "correction-fixture",
            "runRevision": \(quoted(runRevision)),
            "corpusRevision": "fixture-corpus",
            "weights": { "similarity": 0.35, "prefixCompletion": 0.40,
                         "phoneticKey": 0.15, "frameFit": 0.05,
                         "pairedKeyword": 0.05 },
            "scoring": { "levenshteinBound": \(levenshteinBound), "lengthWindow": 2,
                         "maxPrefixSlack": 4, "prefixPenaltyStep": 0.25,
                         "maxCandidates": 8, "marginThreshold": 0.15 },
            "calibration": { "correctThresholdDefault": \(threshold),
                             "kneeThreshold": \(threshold),
                             "precisionAtDefault": 0.95, "recallAtDefault": 0.5,
                             "precisionFloor": 0.95, "appliedAtDefault": 1,
                             "bindingConstraint": "fixture",
                             "calibratedFallback": 1.0,
                             "lowerBound": \(lowerBound),
                             "upperBound": \(upperBound),
                             "stale": \(stale),
                             "runRevision": \(quoted(runRevision)),
                             "corpusRevision": "fixture-corpus" },
            "lexicon": [\(lexiconJSON)],
            "entities": { \(entitiesJSON) },
            "priors": { "l1": [\(l1JSON)], "l2": [\(l2JSON)], "l3": [\(l3JSON)] }
          }
        }
        """
        let foldEntries = folds.enumerated().map { index, fold in
            let scalars = fold.scalars.map(quoted).joined(separator: ",")
            return """
            { "id": "fold-\(index)", "group": "fixture-group",
              "foldKind": "unify", "scalars": [\(scalars)],
              "evidence": { "source": "corpus", "occurrences": \(fold.occurrences),
                            "corpusRevision": "fixture-corpus" } }
            """
        }
        let elideEntries = elides.enumerated().map { index, scalar in
            """
            { "id": "elide-\(index)", "group": "fixture-group",
              "foldKind": "elide", "scalars": [\(quoted(scalar))],
              "evidence": { "source": "corpus", "occurrences": 40,
                            "corpusRevision": "fixture-corpus" } }
            """
        }
        let representatives = folds.map { quoted($0.scalars[$0.scalars.count - 1]) }
            .joined(separator: ",")
        let foldKeys = folds.map { quoted($0.scalars[0]) }.joined(separator: ",")
        let phonetic = """
        {
          "formatVersion": 1,
          "tableID": "phonetic-key",
          "resolvedKey": {
            "unify": { },
            "elide": [\(elides.map(quoted).joined(separator: ","))],
            "conflicts": []
          },
          "entries": [\((foldEntries + elideEntries).joined(separator: ","))],
          "unsupportedGroups": []
        }
        """
        // The `unify` map is written from the fold list, so a fixture cannot
        // declare a fold the entries do not carry (the loader refuses that
        // pairing on purpose — see `resolvedKeyFoldsUnknownScalar`).
        let unifyJSON = folds.map { quoted($0.scalars[0]) + ": " + quoted($0.scalars[$0.scalars.count - 1]) }
            .joined(separator: ",")
        let phoneticWithUnify = phonetic.replacingOccurrences(
            of: "\"unify\": { }", with: "\"unify\": { \(unifyJSON) }")
        _ = foldKeys
        _ = representatives

        guard let lexicon = CorrectionLexicon.decode(
            tableData: Data(table.utf8),
            phoneticData: Data(phoneticWithUnify.utf8)) else {
            XCTFail("the fixture bank did not decode")
            return CorrectionLexicon.decode(tableData: Data(table.utf8),
                                            phoneticData: Data(phoneticWithUnify.utf8))!
        }
        if !allowingIssues {
            XCTAssertTrue(lexicon.issues.isEmpty,
                          "the fixture bank is not usable: \(lexicon.issues.map(\.rawValue))")
        }
        return lexicon
    }

    /// The shipped policy's shape, aimed at a fixture bank: the threshold comes
    /// from the bank's own manifest unless a fixture overrides it, which is the
    /// path `Policy.runtime` takes once a tester has switched the layer on.
    private func correctionPolicy(_ lexicon: CorrectionLexicon,
                                  threshold: Double? = nil,
                                  mode: STTCorrector.Mode = .apply)
    -> STTCorrector.Policy {
        STTCorrector.Policy(
            mode: mode,
            correctThreshold: threshold ?? lexicon.calibration.correctThresholdDefault,
            marginThreshold: lexicon.scoring.marginThreshold,
            thresholdRange: lexicon.calibration.range,
            maxCandidates: lexicon.scoring.maxCandidates)
    }

    /// The shipped banks, or a skip when the app bundle has not been generated
    /// — the same guard `bundledVariantTables()` uses.
    private func bundledCorrectionLexicon() throws -> CorrectionLexicon {
        guard let lexicon = CorrectionLexicon.load() else {
            throw XCTSkip("VariantTables/canonical-stt-reductions.json or "
                          + "phonetic-key.json not bundled yet "
                          + "(run xcodegen generate + build)")
        }
        return lexicon
    }

    /// The single decision for one token surface. A second decision for the same
    /// surface is itself a contract violation (one `TokenDecision` per token),
    /// so it fails here rather than being silently picked between.
    private func correctionDecision(_ result: CorrectionResult,
                                    for surface: String) throws -> CorrectionDecision {
        let matches = result.decisions.filter { $0.surface == surface }
        XCTAssertEqual(matches.count, 1,
                       "expected exactly one decision for \(surface), got \(matches.count)")
        return try XCTUnwrap(matches.first).decision
    }

    // MARK: The gate (§5.5)

    /// The applied arm, ON the floor. The fixture's threshold is the shipped
    /// 0.8125 and the fixture's score is the shipped score for this pair, so the
    /// boundary pinned here is the one the shipped bank sits on: `>=` applies.
    ///
    /// Measured 0.8125 = 0.35·0.75 (one insertion over a span of 4) + 0.40·1.0
    /// (a one-scalar prefix completion) + 0.15·1.0 (the halanta elision makes
    /// the two phonetic keys equal).
    func testTheCorrectorAppliesAtTheCalibratedFloor() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.8125,
                                            lexicon: ["होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let result = STTCorrector.correct("भोलि होस", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))

        XCTAssertEqual(result.corrected, "भोलि होस्")
        XCTAssertFalse(result.isIdentity)
        XCTAssertFalse(result.degraded)
        XCTAssertEqual(result.applications.count, 1)
        let application = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(application.score, 0.8125, accuracy: 1e-9)
        XCTAssertEqual(application.score, result.thresholdUsed, accuracy: 1e-9,
                       "the fixture must sit exactly on the floor, or it does not "
                       + "pin the boundary it claims to")
        XCTAssertEqual(application.errorClass, .truncation)
        XCTAssertEqual(application.entryID, "fixture-hos")
        XCTAssertEqual(application.evidence.classOrigin, .measured,
                       "the pair row is measured, so the class is a measurement")
        XCTAssertEqual(application.lexiconRevision, "correction-fixture/v1")
        // One decision per token, and the untouched word is not silently absent.
        XCTAssertEqual(result.decisions.count, 2)
        XCTAssertEqual(try correctionDecision(result, for: "भोलि").reason, "no_candidate")
        XCTAssertEqual(try correctionDecision(result, for: "होस").reason, "corrected")
        XCTAssertEqual(result.observabilityMetadata["correction_state"], "applied")
    }

    /// One step above the floor: pass-through, and the decision NAMES the score
    /// it refused (A-9 — a non-application is a decision, not a silence).
    func testTheCorrectorPassesThroughBelowTheFloor() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.85,
                                            lexicon: ["होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let result = STTCorrector.correct("भोलि होस", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))

        XCTAssertEqual(result.corrected, "भोलि होस")
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.applications.isEmpty)
        guard case .belowThreshold(let best) = try correctionDecision(result, for: "होस")
        else {
            XCTFail("expected below_threshold, got "
                    + "\(try correctionDecision(result, for: "होस").reason)")
            return
        }
        XCTAssertEqual(best, 0.8125, accuracy: 1e-9,
                       "the refusal reports the score it compared, not a proxy")
        XCTAssertEqual(result.observabilityMetadata["correction_state"], "passed")
        XCTAssertEqual(result.observabilityMetadata["correction_reasons"],
                       "below_threshold:1,no_candidate:1")
    }

    /// Two candidates equidistant from the token: refused, never guessed
    /// (§5.5 clause 2). Measured margin 0.0 — the two differ only in their last
    /// scalar, so they tie exactly at the floor.
    func testATieIsRefusedRatherThanGuessed() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.50,
                                            lexicon: ["खाए", "खाएँ", "खाएन",
                                                      "होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let result = STTCorrector.correct("खाए", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))

        XCTAssertTrue(result.isIdentity, "an ambiguous token is never rewritten")
        guard case .ambiguous(let margin) = try correctionDecision(result, for: "खाए")
        else {
            XCTFail("expected ambiguous, got "
                    + "\(try correctionDecision(result, for: "खाए").reason)")
            return
        }
        XCTAssertEqual(margin, 0.0, accuracy: 1e-9)
    }

    // MARK: The vetoes (§5.8)

    /// The negation-marker rule, both directions, measured on the fixture that
    /// IS the hazard: `खाए` sits inside `नखाए`, and `खाएँ` is a shipped ack
    /// token — a corrector that completed `खाए → खाएँ` would be rewriting text
    /// the medication-ack path reads.
    func testACorrectionTouchingTheFrozenSetIsRefused() throws {
        // The freeze's own verdicts first, so the fixture's premise is checked
        // independently of the corrector.
        XCTAssertTrue(CanonicalSafetyFreeze.touches(variant: "खाए", canonical: "खाएँ"))
        XCTAssertTrue(CanonicalSafetyFreeze.touches(variant: "नखाए", canonical: "खाए"))

        let lexicon = makeCorrectionLexicon(threshold: 0.50,
                                            lexicon: ["खाए", "खाएँ", "होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let truncated = STTCorrector.correct("खाए", lexicon: lexicon,
                                             policy: correctionPolicy(lexicon))
        XCTAssertTrue(truncated.isIdentity)
        guard case .safetyVeto(let rule) =
            try correctionDecision(truncated, for: "खाए") else {
            XCTFail("the completion was not vetoed")
            return
        }
        XCTAssertEqual(rule, .safetySetTouched)
        XCTAssertEqual(truncated.observabilityMetadata["correction_veto"],
                       "safety_set_touched")

        // The direction the router cares about: `नखाए` is a DENIAL, `खाए` an
        // ACK. At a threshold low enough to admit the repair (0.20) the veto is
        // the only thing standing between a refusal and a recorded dose.
        let denialLexicon = makeCorrectionLexicon(threshold: 0.20,
                                                  lexicon: ["नखाए", "खाए",
                                                            "होस", "होस्"],
                                                  rows: [("fixture-hos", "होस",
                                                          "होस्", "truncation", 5)])
        let denial = STTCorrector.correct("नखाए", lexicon: denialLexicon,
                                          policy: correctionPolicy(denialLexicon))
        XCTAssertEqual(denial.corrected, "नखाए")
        guard case .safetyVeto(let denialRule) =
            try correctionDecision(denial, for: "नखाए") else {
            XCTFail("नखाए → खाए was not vetoed")
            return
        }
        XCTAssertEqual(denialRule, .safetySetTouched)
    }

    /// The row-level half of §5.8.1: a bank that CARRIES a safety-touching pair
    /// is refused whole — not filtered, not repaired. Measured:
    /// `issues=["safetySetTouched"] usable=false entries=0`.
    func testASafetyTouchingRowRefusesTheWholeBank() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.50,
                                            lexicon: ["नखाए", "खाए"],
                                            rows: [("fixture-nakhae", "नखाए", "खाए",
                                                    "prefix_extension", 4)],
                                            allowingIssues: true)

        XCTAssertFalse(lexicon.isUsable)
        XCTAssertEqual(lexicon.issues, [.safetySetTouched])
        XCTAssertTrue(lexicon.entries.isEmpty,
                      "a refused bank exposes no entries at all")

        // Fail-closed downstream: an unusable bank degrades, it does not run.
        let result = STTCorrector.correct("औषधि नखाए", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.degraded)
        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(result.decisions.first?.decision.reason, "degraded")
        XCTAssertEqual(result.observabilityMetadata["correction_state"], "degraded")
    }

    /// The entity veto (§5.8.3): a contact token completed into a DIFFERENT
    /// contact is refused, because dialling the wrong person is the failure this
    /// bank exists to prevent. Measured: `सीता` (a tagged contact) with the
    /// phonetically-folded candidate `शीता` → `safety_veto entity_ambiguity`.
    func testAContactTokenIsRefusedANonCompletionCandidate() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.40,
                                            lexicon: ["सीता", "शीता", "होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)],
                                            entities: ["contact": ["सीता"]],
                                            folds: [(["श", "स"], 12)],
                                            levenshteinBound: 0)
        // The pair is generated (the fold makes the keys equal), so the veto —
        // not the generator — is what refuses it.
        XCTAssertTrue(lexicon.candidates(for: "सीता").contains("शीता"))

        let result = STTCorrector.correct("सीता", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))
        XCTAssertEqual(result.corrected, "सीता")
        guard case .safetyVeto(let rule) = try correctionDecision(result, for: "सीता")
        else {
            XCTFail("expected entity_ambiguity, got "
                    + "\(try correctionDecision(result, for: "सीता").reason)")
            return
        }
        XCTAssertEqual(rule, .entityAmbiguity)
    }

    /// §5.7: inside a required span a correction is a strict prefix completion or
    /// nothing. Measured both arms on the same bank — `औषधि → औषधी` is a
    /// substitution and is refused inside a medication span; `होस → होस्` is a
    /// one-scalar completion and still applies inside one.
    func testARequiredSpanAdmitsOnlyAStrictCompletion() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.40,
                                            lexicon: ["औषधि", "औषधी"],
                                            rows: [("fixture-aushadhi", "औषधि",
                                                    "औषधी", "phonetic_confusion", 9)],
                                            folds: [(["ि", "ी"], 30), (["श", "स"], 12)],
                                            levenshteinBound: 0)
        let span = STTCorrector.CorrectionContext(requiredSpans: [0..<4: .medication])
        let substituted = STTCorrector.correct("औषधि", lexicon: lexicon,
                                               context: span,
                                               policy: correctionPolicy(lexicon))
        XCTAssertEqual(substituted.corrected, "औषधि")
        guard case .requiredSpan(let spanClass) =
            try correctionDecision(substituted, for: "औषधि") else {
            XCTFail("a substitution inside a required span was not refused")
            return
        }
        XCTAssertEqual(spanClass, .medication)

        let completing = makeCorrectionLexicon(lexicon: ["होस", "होस्"],
                                               rows: [("fixture-hos", "होस", "होस्",
                                                       "truncation", 5)])
        let completionSpan = STTCorrector.CorrectionContext(requiredSpans: [0..<3: .medication])
        let completed = STTCorrector.correct("होस", lexicon: completing,
                                             context: completionSpan,
                                             policy: correctionPolicy(completing))
        XCTAssertEqual(completed.corrected, "होस्",
                       "the rule restricts the span, it does not freeze it")
    }

    // MARK: The generators (§5.3)

    /// The phonetic tier, with the edit tier switched OFF so the key table is
    /// provably the generator: measured keys equal
    /// (`औषधि`/`औषधी` both fold to the same four scalars) and the pair scores
    /// 0.4125 via a key hit the edit tier could not have produced at bound 0.
    func testThePhoneticKeyTierGeneratesThroughTheKeyTable() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.40,
                                            lexicon: ["औषधि", "औषधी"],
                                            rows: [("fixture-aushadhi", "औषधि",
                                                    "औषधी", "phonetic_confusion", 9)],
                                            folds: [(["ि", "ी"], 30), (["श", "स"], 12)],
                                            levenshteinBound: 0)
        XCTAssertEqual(lexicon.phonetic.key(of: "औषधि"),
                       lexicon.phonetic.key(of: "औषधी"))

        let result = STTCorrector.correct("औषधि", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))
        XCTAssertEqual(result.corrected, "औषधी")
        let application = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(application.score, 0.4125, accuracy: 1e-9)
        XCTAssertEqual(application.errorClass, .phoneticConfusion)
    }

    /// A-3 as the runtime enforces it: a fold with NO measured support is not
    /// applied — it refuses the bank it arrives in. Zero-support folds were
    /// excluded at authoring time; the loader is the second lock.
    func testAFoldWithNoMeasuredSupportIsRefusedNotApplied() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.40,
                                            lexicon: ["औषधि", "औषधी"],
                                            rows: [("fixture-aushadhi", "औषधि",
                                                    "औषधी", "phonetic_confusion", 9)],
                                            folds: [(["ि", "ी"], 0), (["श", "स"], 12)],
                                            levenshteinBound: 0,
                                            allowingIssues: true)
        XCTAssertEqual(lexicon.issues, [.foldWithoutSupport])
        XCTAssertFalse(lexicon.isUsable)

        // The arm that makes this the right failure mode: with the count
        // restored the SAME fixture applies the SAME correction (see the
        // phonetic-tier test above) — so the refusal is the count, not the pair.
        let result = STTCorrector.correct("औषधि", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.degraded)
    }

    /// The edit tier is BOUNDED and its attribution is honest about what it is:
    /// with no prefix and no key hit, `गर्नुहोस् → गरनुहोस्` still applies (a
    /// one-scalar insertion, score 0.4611) and the class is derived from the
    /// repair's SHAPE, attributed to the generating lexicon row — a lexicon
    /// ordinal, never a surface form (C-6), and labelled `derived_from_shape` so
    /// it is never read as a measurement (A-9).
    func testTheEditTierIsBoundedAndItsAttributionIsDerived() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.45,
                                            lexicon: ["गरनुहोस्", "गर्नुहोस्"],
                                            rows: [("fixture-garnuhos", "गरनुहोस्",
                                                    "गर्नुहोस्", "phonetic_confusion", 2)])
        let result = STTCorrector.correct("गर्नुहोस्", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))

        XCTAssertEqual(result.corrected, "गरनुहोस्")
        let application = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(application.score, 0.461111111111111, accuracy: 1e-9)
        XCTAssertEqual(application.errorClass, .insertion)
        XCTAssertEqual(application.entryID, "lex-1")
        XCTAssertEqual(application.evidence.classOrigin, .derivedFromShape)
        // The shipped rule: an id never carries a surface form.
        XCTAssertNil(application.entryID.unicodeScalars
            .first { (0x0900...0x097F).contains($0.value) })
    }

    // MARK: The paired prior (§5.4)

    /// L1 with corpus support: the row for THIS candidate among THIS token's
    /// neighbours adds exactly `w₅ × score` — measured 0.4125 → 0.4150 for a
    /// 0.05 row at weight 0.05.
    func testAnL1RowForTheCandidateAddsItsWeightedScore() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.40,
                                            lexicon: ["औषधि", "औषधी"],
                                            rows: [("fixture-aushadhi", "औषधि",
                                                    "औषधी", "phonetic_confusion", 9)],
                                            l1: [("खान", "औषधी", 0.05)],
                                            folds: [(["ि", "ी"], 30), (["श", "स"], 12)],
                                            levenshteinBound: 0)
        let result = STTCorrector.correct("औषधि खान", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))

        let application = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(application.evidence.pairedKeyword, 0.05, accuracy: 1e-9)
        XCTAssertEqual(application.evidence.surface, 0.4125, accuracy: 1e-9)
        XCTAssertEqual(application.evidence.total, 0.4150, accuracy: 1e-9)
        XCTAssertEqual(application.evidence.total - application.evidence.surface,
                       0.05 * 0.05, accuracy: 1e-9, "the weight is the bank's")
    }

    /// Zero corpus support contributes ZERO — not a fallback number measured for
    /// a different question. Two arms, both measured: no row at all (0.4125 =
    /// the surface score exactly) and a row for a DIFFERENT candidate (0.4125
    /// again — the cross term must not fire).
    func testAPriorWithoutCorpusSupportContributesZero() throws {
        func bank(l1: [(w: String, c: String, score: Double)]) -> CorrectionLexicon {
            makeCorrectionLexicon(threshold: 0.40,
                                  lexicon: ["औषधि", "औषधी"],
                                  rows: [("fixture-aushadhi", "औषधि", "औषधी",
                                          "phonetic_confusion", 9)],
                                  l1: l1,
                                  folds: [(["ि", "ी"], 30), (["श", "स"], 12)],
                                  levenshteinBound: 0)
        }
        for (label, fixture) in [("no rows", bank(l1: [])),
                                 ("a row for another candidate",
                                  bank(l1: [("खान", "औषधि", 0.05)]))] {
            let result = STTCorrector.correct("औषधि खान", lexicon: fixture,
                                              policy: correctionPolicy(fixture))
            let application = try XCTUnwrap(result.applications.first)
            XCTAssertEqual(application.evidence.pairedKeyword, 0.0, accuracy: 1e-9, label)
            XCTAssertEqual(application.evidence.context, 0.0, accuracy: 1e-9, label)
            XCTAssertEqual(application.evidence.total,
                           application.evidence.surface, accuracy: 1e-9, label)
            XCTAssertEqual(application.evidence.total, 0.4125, accuracy: 1e-9, label)
        }
    }

    /// §5.4's backoff, on three measured fixtures: the L2 frame prior adds its
    /// own weight (0.4125 → 0.4135 for a 0.02 frame score), the L3 cue prior
    /// does when L2 is silent (0.4125 → 0.4140 for a 0.03 cue score), and L3
    /// does NOT when L2 already fired (0.4135, not 0.4145 — the strongest
    /// level wins rather than summing).
    func testThePriorBacksOffFromL1ToL2ToL3AndNeverSums() throws {
        func bank(l2: [(frame: String, c: String, score: Double)],
                  l3: [(cue: String, c: String, score: Double)]) -> CorrectionLexicon {
            makeCorrectionLexicon(threshold: 0.40,
                                  lexicon: ["औषधि", "औषधी"],
                                  rows: [("fixture-aushadhi", "औषधि", "औषधी",
                                          "phonetic_confusion", 9)],
                                  l2: l2, l3: l3,
                                  folds: [(["ि", "ी"], 30), (["श", "स"], 12)],
                                  levenshteinBound: 0)
        }
        func total(_ fixture: CorrectionLexicon) throws -> Double {
            let result = STTCorrector.correct("औषधि खान", lexicon: fixture,
                                              policy: correctionPolicy(fixture))
            return try XCTUnwrap(result.applications.first).evidence.total
        }

        let frameOnly = bank(l2: [("content", "औषधी", 0.02)], l3: [])
        XCTAssertEqual(try total(frameOnly), 0.4135, accuracy: 1e-9)

        let cueOnly = bank(l2: [], l3: [("खान", "औषधी", 0.03)])
        XCTAssertEqual(try total(cueOnly), 0.4140, accuracy: 1e-9)

        let both = bank(l2: [("content", "औषधी", 0.02)], l3: [("खान", "औषधी", 0.03)])
        XCTAssertEqual(try total(both), 0.4135, accuracy: 1e-9,
                       "L3 is a backoff, not an addend")
    }

    /// The recorded deviation, pinned where it is checkable: the gate compares
    /// the SURFACE score, so context evidence (≤ 0.10) can never carry a
    /// candidate across the floor that the text itself did not clear. Measured:
    /// with the L1 row the total is 0.4150 but the surface is 0.4125, and at
    /// τ = 0.4140 the decision is `below_threshold(best: 0.4125)`.
    func testTheContextBonusCannotCarryACandidateAcrossTheFloor() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.414,
                                            lexicon: ["औषधि", "औषधी"],
                                            rows: [("fixture-aushadhi", "औषधि",
                                                    "औषधी", "phonetic_confusion", 9)],
                                            l1: [("खान", "औषधी", 0.05)],
                                            folds: [(["ि", "ी"], 30), (["श", "स"], 12)],
                                            levenshteinBound: 0)
        let result = STTCorrector.correct("औषधि खान", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))

        XCTAssertTrue(result.isIdentity)
        guard case .belowThreshold(let best) = try correctionDecision(result, for: "औषधि")
        else {
            XCTFail("the context bonus moved a candidate across the floor")
            return
        }
        XCTAssertEqual(best, 0.4125, accuracy: 1e-9,
                       "the compared score is the surface one")
        XCTAssertGreaterThan(best, 0.0)
    }

    // MARK: The modes (§6.4)

    /// Shadow: decide, log, apply NOTHING. The counterfactual arm must leave the
    /// text byte-identical while still recording the decision it would have
    /// made — that is the only way the arm can be compared against apply.
    func testShadowDecidesWithoutRewriting() throws {
        let lexicon = makeCorrectionLexicon(lexicon: ["होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let result = STTCorrector.correct("भोलि होस", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon, mode: .shadow))

        XCTAssertEqual(result.mode, .shadow)
        XCTAssertEqual(result.corrected, "भोलि होस")
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.applications.isEmpty, "shadow applies nothing")
        XCTAssertEqual(try correctionDecision(result, for: "होस").reason, "corrected",
                       "…but the counterfactual decision is still made and logged")
        XCTAssertEqual(result.observabilityMetadata["correction_state"], "shadow")
        XCTAssertEqual(result.observabilityMetadata["correction_applied_count"], "0")
        XCTAssertEqual(result.observabilityMetadata["correction_reasons"],
                       "corrected:1,no_candidate:1")
    }

    /// Off is the control arm: no decisions are computed at all, so the layer
    /// cannot influence anything by being consulted.
    func testOffIsTheControlArm() throws {
        let lexicon = makeCorrectionLexicon(lexicon: ["होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let result = STTCorrector.correct("भोलि होस", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon, mode: .off))

        XCTAssertEqual(result.mode, .off)
        XCTAssertEqual(result.corrected, "भोलि होस")
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertTrue(result.decisions.allSatisfy { $0.decision.reason == "disabled" })
        XCTAssertNil(result.decisions.first?.best, "off generates no candidates")
        XCTAssertEqual(result.observabilityMetadata["correction_state"], "disabled")
        XCTAssertEqual(result.logLines.count, 2)
    }

    /// A missing or unusable bank is a VALUE, not a crash and not a silent
    /// no-op: every token is `degraded`, the text is untouched, and the state
    /// says so — so the event and the card can report a layer that could not run
    /// rather than a layer that found nothing.
    func testAMissingBankDegradesAndRewritesNothing() throws {
        let policy = STTCorrector.Policy(mode: .apply, correctThreshold: 0.40,
                                         marginThreshold: 0.15,
                                         thresholdRange: 0.0...1.0, maxCandidates: 8)
        let result = STTCorrector.correct("भोलि होस", lexicon: nil, policy: policy)

        XCTAssertTrue(result.degraded)
        XCTAssertTrue(result.isIdentity)
        XCTAssertEqual(result.corrected, "भोलि होस")
        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertTrue(result.decisions.allSatisfy { $0.decision.reason == "degraded" })
        XCTAssertEqual(result.lexiconRevision, "absent")
        XCTAssertEqual(result.observabilityMetadata["correction_state"], "degraded")
        // Fail-closed threshold: an unusable bank cannot lower the bar.
        XCTAssertEqual(CorrectionLexicon.Calibration.failClosedThreshold, 1.0)
    }

    // MARK: Observability (§6.6)

    /// A-16 at the egress boundary: every key is on the allow-list, no value
    /// carries a surface form or a raw score, and the payload survives the
    /// sanitiser unchanged (an unknown key would be dropped silently — which is
    /// how a "count-only" event would quietly lose the field a Phase-2 reader
    /// needs, so it is asserted rather than assumed).
    func testTheCorrectionEventIsCountOnlyAndSurvivesTheSanitiser() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.8125,
                                            lexicon: ["होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let result = STTCorrector.correct("भोलि होस", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))
        let metadata = result.observabilityMetadata

        XCTAssertEqual(metadata["correction_mode"], "apply")
        XCTAssertEqual(metadata["correction_state"], "applied")
        XCTAssertEqual(metadata["correction_applied_count"], "1")
        XCTAssertEqual(metadata["correction_tokens_considered"], "2")
        XCTAssertEqual(metadata["correction_entry_ids"], "fixture-hos")
        XCTAssertEqual(metadata["correction_classes"], "truncation:1")
        XCTAssertEqual(metadata["correction_class_origins"], "measured:1")
        // The tilde is load-bearing: a hyphenated range is matched by the
        // sanitizer's phone-number guard and arrives as `[redacted]` (measured —
        // see `CorrectionResult.bucket`), which is why the equality assertion
        // below is the one that matters most in this test.
        XCTAssertEqual(metadata["correction_threshold_bucket"], "0.80~0.85")
        XCTAssertEqual(metadata["correction_best_bucket"], "0.80~0.85")
        XCTAssertEqual(metadata["correction_margin_bucket"], "0.80~0.85")
        XCTAssertEqual(metadata["correction_lexicon_revision"], "correction-fixture/v1")

        for (key, value) in metadata {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                          "correction key is not on the egress allow-list: \(key)")
            for leak in ["भोलि", "होस", "होस्", "0.8125"] {
                XCTAssertFalse(value.contains(leak),
                               "\(key) carries a surface form or a raw score: \(value)")
            }
        }

        let event = ObservabilityEvent(component: "intent_encoder",
                                       eventType: "turn_correction",
                                       durationMs: nil,
                                       outcome: "applied",
                                       errorCode: nil,
                                       metadata: metadata)
        XCTAssertEqual(LogSanitiser().sanitise(event).metadata, metadata,
                       "the payload must pass the egress sanitiser intact")
    }

    /// The two disclosures, side by side on ONE result: the on-device readout is
    /// the user's own words (it is shown to the person holding the phone and is
    /// never persisted), and the egressing payload — built from the same result
    /// — carries none of them.
    func testTheReadoutShowsThePairOnDeviceWhileTheEventNeverDoes() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.8125,
                                            lexicon: ["होस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let result = STTCorrector.correct("भोलि होस", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))
        let readout = try XCTUnwrap(result.readout)
        let shown = readout.rows.map { "\($0.label)=\($0.value)" }.joined(separator: " ")
        XCTAssertTrue(shown.contains("होस→होस्"),
                      "the internal card shows the pair: \(shown)")
        XCTAssertFalse(result.observabilityMetadata.values.joined().contains("होस"))

        // A transcript with no tokens has no readout at all — nil, not empty.
        let silent = STTCorrector.correct("", lexicon: lexicon,
                                          policy: correctionPolicy(lexicon))
        XCTAssertNil(silent.readout)
    }

    // MARK: The shipped bank

    /// The shipped bank's own manifest, pinned. These are the numbers the
    /// calibration report and the settings card quote; a re-fit that moves the
    /// threshold without moving this test is the drift A-12 exists to prevent.
    func testTheShippedBankLoadsCleanAtItsCalibratedThreshold() throws {
        let lexicon = try bundledCorrectionLexicon()
        XCTAssertTrue(lexicon.issues.isEmpty,
                      "issues: \(lexicon.issues.map(\.rawValue))")
        XCTAssertTrue(lexicon.skipped.isEmpty,
                      "skipped: \(lexicon.skipped.map { "\($0.id):\($0.issue.rawValue)" })")
        XCTAssertEqual(lexicon.entries.count, 104)
        XCTAssertEqual(lexicon.lexicon.count, 1453)
        XCTAssertEqual(lexicon.revision, "correction-banks/v3#e133253b")
        XCTAssertEqual(lexicon.calibration.runRevision, "correction-banks/v3#e133253b")
        XCTAssertEqual(lexicon.calibration.corpusRevision, "7f71b8ae")
        XCTAssertFalse(lexicon.calibration.stale)
        XCTAssertTrue(lexicon.calibration.isUsable)

        XCTAssertEqual(lexicon.calibration.correctThresholdDefault, 0.8125,
                       accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(lexicon.calibration.kneeThreshold), 0.83,
                       accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(lexicon.calibration.precisionAtDefault), 0.9524,
                       accuracy: 1e-4)
        XCTAssertEqual(lexicon.calibration.bindingConstraint, "precision_floor")
        XCTAssertEqual(lexicon.calibration.range, 0.8125...1.0)
        XCTAssertEqual(lexicon.scoring.marginThreshold, 0.15, accuracy: 1e-9)
        XCTAssertEqual(lexicon.calibration.calibratedFallback, 1.0, accuracy: 1e-9,
                       "the fallback is the inert end, not a livelier number")
        // Every fold the runtime applies is a fold the evidence paid for (A-3).
        XCTAssertNotNil(lexicon.phonetic.key(of: "होस").first)
    }

    /// Every calibrated application, as an in/out pair. Measured against the
    /// shipped bank at 0.8125 (the fidelity replay of §5.5.1's calibration set:
    /// 8 distinct applications, missing 0, extra 0) — exhaustive, so a re-fit
    /// that widens the applied set fails here.
    func testEveryCalibratedApplicationHasAPinnedInOutPair() throws {
        let lexicon = try bundledCorrectionLexicon()
        let policy = correctionPolicy(lexicon)
        let pinned = [("गर्दिनुस", "गर्दिनुस्", "lex-305"),
                      ("दिनुस", "दिनुस्", "lex-834"),
                      ("देखाइदिनुस", "देखाइदिनुस्", "lex-35"),
                      ("परोस", "परोस्", "lex-751"),
                      ("बजाउनुस", "बजाउनुस्", "lex-144"),
                      ("सुन्नुहोस", "सुन्नुहोस्", "lex-43"),
                      ("हाल्दिनुस", "हाल्दिनुस्", "lex-871"),
                      ("होस", "होस्", "lex-1016")]
        for (noisy, corrected, entryID) in pinned {
            let result = STTCorrector.correct(noisy, lexicon: lexicon, policy: policy)
            XCTAssertEqual(result.corrected, corrected, "\(noisy) was not corrected")
            let application = try XCTUnwrap(result.applications.first,
                                            "\(noisy) produced no application")
            XCTAssertEqual(application.errorClass, .truncation)
            XCTAssertEqual(application.entryID, entryID)
            XCTAssertEqual(application.evidence.classOrigin, .derivedFromShape,
                           "the design's own finding: none of the calibration's 8 "
                           + "applications is a top-K pair row, so all 8 are "
                           + "attributed to the generating lexicon row")
            XCTAssertGreaterThanOrEqual(application.evidence.surface,
                                        policy.correctThreshold)
        }
    }

    /// The other half of the operating point (C-3b): at the shipped threshold a
    /// clean transcript is left alone. Measured: 0 applications over the 8000
    /// golden-corpus utterances, and identity on this line.
    func testTheShippedThresholdLeavesACleanTranscriptAlone() throws {
        let lexicon = try bundledCorrectionLexicon()
        let policy = correctionPolicy(lexicon)
        let clean = "भोलि बिहान औषधि खान सम्झाइदिनु"
        let result = STTCorrector.correct(clean, lexicon: lexicon, policy: policy)

        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(result.observabilityMetadata["correction_state"], "passed")
        XCTAssertEqual(result.decisions.count, 5)
    }

    // MARK: Composition (§4.6)

    /// The seam, end to end, with BOTH layers rewriting: the corrector completes
    /// `सम्झाइदिनु → सम्झाइदिनुस` and the canonicalizer's rule is written on the
    /// CORRECTOR'S OUTPUT (`सम्झाइदिनुस → सम्झाइदिनुस्`), so the order is
    /// load-bearing — run the other way round, the canonicalizer would see
    /// `सम्झाइदिनु`, match nothing, and `modelInput` would end at
    /// `सम्झाइदिनुस`. Everything the safety net reads stays the original.
    func testTheCorrectorRunsBeforeTheCanonicalizerAtTheSeam() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.65,
                                            lexicon: ["सम्झाइदिनुस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        // A synthetic stage-1 rule whose variant is the corrector's output.
        let entry = makeEntry("test-order",
                              variant: "सम्झाइदिनुस",
                              canonical: "सम्झाइदिनुस्",
                              examples: ["सम्झाइदिनुस", "भोलि सम्झाइदिनुस"])
        let tables = makeSet(orthographic: makeTable("canonical-orthographic",
                                                     entries: [entry]))
        let pair = IntentInputCanonicalization.prepare(
            sanitisedTranscript: "भोलि सम्झाइदिनु",
            dialect: .default,
            tables: tables,
            policy: IntentInputCanonicalization.Policy(enabled: true),
            correctionPolicy: correctionPolicy(lexicon),
            correctionLexicon: lexicon)

        XCTAssertEqual(pair.original, "भोलि सम्झाइदिनु")
        XCTAssertEqual(pair.correctedInput, "भोलि सम्झाइदिनुस")
        XCTAssertEqual(pair.modelInput, "भोलि सम्झाइदिनुस्")
        XCTAssertEqual(pair.applications.map(\.ruleID), ["test-order"])
        XCTAssertEqual(pair.correction?.applications.count, 1)
        XCTAssertFalse(pair.isIdentity)
        XCTAssertFalse(pair.canonicalizationIsIdentity)

        // D-1: the safety net, the emergency path and the med-ack path read the
        // ORIGINAL, whatever either layer did.
        XCTAssertEqual(pair.safetyNetInput, "भोलि सम्झाइदिनु")
        // [CORRECTION-ANYBRAIN] …while both MODELS read the prepared text, and
        // in the matrix's order: the canonicalizer's output, not the
        // corrector's and not the raw transcript.
        XCTAssertEqual(pair.pickerBrainInput, "भोलि सम्झाइदिनुस्")
        XCTAssertEqual(pair.pickerBrainInput, pair.modelInput)
        XCTAssertNotEqual(pair.pickerBrainInput, pair.correctedInput)

        // Neither layer's surface forms may reach the egressing payload.
        for (key, value) in pair.observabilityMetadata {
            for leak in ["भोलि", "सम्झाइदिनु", "सम्झाइदिनुस", "सम्झाइदिनुस्"] {
                XCTAssertFalse(value.contains(leak), "\(key) leaked \(leak)")
            }
        }
    }

    /// The control: while the corrector is off, the seam is what it was before
    /// the layer existed — the canonicalizer still works, and the payload is
    /// byte-for-byte the canonicalization payload with no `correction_` key at
    /// all (so a Phase-2 reader cannot see a layer that did not run).
    func testTheSeamIsUnchangedWhileTheCorrectorIsOff() throws {
        let lexicon = makeCorrectionLexicon(threshold: 0.65,
                                            lexicon: ["सम्झाइदिनुस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let entry = makeEntry("test-order",
                              variant: "सम्झाइदिनुस",
                              canonical: "सम्झाइदिनुस्",
                              examples: ["सम्झाइदिनुस", "भोलि सम्झाइदिनुस"])
        let tables = makeSet(orthographic: makeTable("canonical-orthographic",
                                                     entries: [entry]))
        let pair = IntentInputCanonicalization.prepare(
            sanitisedTranscript: "भोलि सम्झाइदिनु",
            dialect: .default,
            tables: tables,
            policy: IntentInputCanonicalization.Policy(enabled: true),
            correctionPolicy: correctionPolicy(lexicon, mode: .off),
            correctionLexicon: lexicon)

        XCTAssertEqual(pair.correctedInput, "भोलि सम्झाइदिनु")
        XCTAssertEqual(pair.modelInput, "भोलि सम्झाइदिनु",
                       "the rule is written on the corrected form, so with the "
                       + "corrector off nothing matches — exactly as before")
        XCTAssertTrue(pair.isIdentity)
        XCTAssertEqual(pair.observabilityMetadata, pair.canonicalizationMetadata)
        XCTAssertFalse(pair.observabilityMetadata.keys.contains { $0.hasPrefix("correction_") })
    }

    // MARK: [CORRECTION-TOGGLES] The four-way matrix

    /// The two switches the internal-testing card carries for the
    /// pre-intent layers, in the order they run:
    /// `sanitise → correct → canonicalize → tokenize`. Every combination
    /// below is produced by WRITING THE STORED KEYS (through the same
    /// `IntentEncoderPreferences` the coordinator's `didSet` writes) and
    /// resolving both policies through the SHIPPED gate functions
    /// (`STTCorrector.Policy.runtime`, `DialectCanonicalizer.Policy.runtime`)
    /// with no explicit `isToggleOn` / `correctionPolicy` override — so the
    /// suite exercises the real pairing, not a hand-built `Policy`.
    private enum LayerSwitch: String, CaseIterable {
        case neither
        case correctorOnly
        case canonicalizerOnly
        case both

        var corrector: Bool { self == .correctorOnly || self == .both }
        var canonicalizer: Bool { self == .canonicalizerOnly || self == .both }
    }

    /// One transcript, one measured correction row and two canonicalization
    /// rules, arranged so every arm of the matrix is OBSERVABLE — a
    /// combination that quietly did nothing would otherwise be
    /// indistinguishable from one that ran:
    ///
    ///   - the corrector's row is `सम्झाइदिनु → सम्झाइदिनुस`, above the
    ///     fixture bank's 0.65 floor;
    ///   - rule A (`test-order`) is keyed on the CORRECTOR'S OUTPUT
    ///     (`सम्झाइदिनुस → सम्झाइदिनुस्`), so it can fire only when the
    ///     corrector ran first — the §6.1 order, made observable rather than
    ///     asserted;
    ///   - rule B (`test-plain`) is keyed on a token the corrector never
    ///     touches (`गर्नुहोस → गर्नुहोस्`; it is not in the bank and is
    ///     outside every candidate window), so the canonicalizer-only arm
    ///     rewrites something instead of looking identical to the inert one.
    private func makeToggleMatrixFixture()
    -> (lexicon: CorrectionLexicon, tables: VariantTableSet, transcript: String) {
        let lexicon = makeCorrectionLexicon(
            threshold: 0.65,
            lexicon: ["सम्झाइदिनुस", "होस्"],
            rows: [("fixture-hos", "होस", "होस्", "truncation", 5)])
        let tables = makeSet(orthographic: makeTable("canonical-orthographic", entries: [
            makeEntry("test-order",
                      variant: "सम्झाइदिनुस",
                      canonical: "सम्झाइदिनुस्",
                      examples: ["सम्झाइदिनुस", "भोलि सम्झाइदिनुस"]),
            makeEntry("test-plain",
                      variant: "गर्नुहोस",
                      canonical: "गर्नुहोस्",
                      examples: ["गर्नुहोस", "अब गर्नुहोस"])
        ]))
        return (lexicon, tables, "भोलि सम्झाइदिनु गर्नुहोस")
    }

    /// The seam for one combination: the switches are persisted first, then
    /// both policies are resolved from the SAME store — which is the whole
    /// point of the matrix, since a switch that never reaches a policy would
    /// make every arm below agree.
    private func matrixPair(_ combination: LayerSwitch,
                            defaults: UserDefaults,
                            fixture: (lexicon: CorrectionLexicon,
                                      tables: VariantTableSet,
                                      transcript: String))
    -> (pair: IntentTranscriptPair, policy: DialectCanonicalizer.Policy) {
        let preferences = IntentEncoderPreferences(defaults: defaults)
        preferences.setCorrectorEnabled(combination.corrector)
        preferences.setCanonicalizerEnabled(combination.canonicalizer)

        let policy = DialectCanonicalizer.Policy.runtime(defaults: defaults,
                                                         isCompiledIn: true)
        let pair = IntentInputCanonicalization.prepare(
            sanitisedTranscript: fixture.transcript,
            dialect: .default,
            tables: fixture.tables,
            policy: policy,
            correctionPolicy: STTCorrector.Policy.runtime(defaults: defaults,
                                                          isCompiledIn: true,
                                                          lexicon: fixture.lexicon),
            correctionLexicon: fixture.lexicon)
        return (pair, policy)
    }

    /// The matrix itself: each combination's policy outcome, its effect at the
    /// seam, and the invariants that must hold in ALL FOUR — the safety net's
    /// input stays the ORIGINAL, the MODEL's input is the prepared text, and
    /// the ORDER (the canonicalizer's input is the corrector's output, never
    /// the raw transcript).
    func testTheFourWayMatrixResolvesAndRunsEveryCombinationInOrder() throws {
        let fixture = makeToggleMatrixFixture()
        let defaults = isolateDefaults()
        let original = fixture.transcript

        var seen: [LayerSwitch: IntentTranscriptPair] = [:]
        for combination in LayerSwitch.allCases {
            let (pair, policy) = matrixPair(combination, defaults: defaults,
                                            fixture: fixture)
            seen[combination] = pair

            // D-1, in every combination, on every arm: the keyword safety net
            // reads the ORIGINAL sanitised transcript.
            XCTAssertEqual(pair.safetyNetInput, original,
                           "\(combination): the safety net must read the original")
            // [CORRECTION-ANYBRAIN] The model's input is the prepared text in
            // every combination — the same string the encoder's tokenizer and
            // the picker brain's prompt are handed, so "which brain answers"
            // cannot change what the layers did. Inert combinations (neither)
            // make the two agree again, which is the shipped default.
            XCTAssertEqual(pair.pickerBrainInput, pair.modelInput,
                           "\(combination): every model consumer reads modelInput")
            if !combination.corrector && !combination.canonicalizer {
                XCTAssertEqual(pair.pickerBrainInput, original,
                               "\(combination): with both switches off nothing "
                               + "was rewritten, so the model's input is the "
                               + "transcript itself")
            }

            // The order invariant, stated as an equality that a reversed
            // composition would fail: re-canonicalizing the pair's own
            // `correctedInput` reproduces exactly what the seam produced. If
            // the canonicalizer had read the raw transcript, this would agree
            // only by accident — and rule A is written so that it cannot.
            let rederived = DialectCanonicalizer.canonicalize(pair.correctedInput,
                                                              dialect: .default,
                                                              tables: fixture.tables,
                                                              policy: policy)
            XCTAssertEqual(pair.modelInput, rederived.canonical,
                           "\(combination): modelInput must be the canonicalization "
                           + "OF the corrector's output")
            XCTAssertEqual(pair.applications.map(\.ruleID),
                           rederived.applications.map(\.ruleID),
                           "\(combination): provenance must agree with the re-derivation")

            // The corrector's own gate: on exactly when the switch is on.
            XCTAssertEqual(pair.correction?.mode == .off, !combination.corrector,
                           "\(combination): the corrector's arm follows its switch")
            if combination.corrector {
                XCTAssertEqual(pair.correction?.applications.count, 1,
                               "\(combination): one measured row fires, and the "
                               + "canonicalizer's rule-B token is left alone")
            }
        }

        let neither = try XCTUnwrap(seen[.neither])
        let correctorOnly = try XCTUnwrap(seen[.correctorOnly])
        let canonicalizerOnly = try XCTUnwrap(seen[.canonicalizerOnly])
        let both = try XCTUnwrap(seen[.both])

        // NEITHER — the shipped default, and a byte-identical pass-through.
        XCTAssertEqual(neither.modelInput, original)
        XCTAssertEqual(neither.pickerBrainInput, original,
                       "the picker brain reads the transcript itself — the "
                       + "pre-relocation string, byte for byte")
        XCTAssertEqual(neither.correctedInput, original)
        XCTAssertTrue(neither.isIdentity)
        XCTAssertTrue(neither.applications.isEmpty)
        XCTAssertEqual(neither.correction?.mode, .off)
        XCTAssertFalse(neither.observabilityMetadata.keys.contains {
            $0.hasPrefix("correction_")
        }, "a layer that did not run adds no keys to the payload")
        XCTAssertEqual(neither.observabilityMetadata, neither.canonicalizationMetadata)

        // CORRECTOR ONLY — the corrected text, canonicalized by nobody. Rule A
        // is keyed on the corrected form and does NOT fire here: the
        // canonicalizer is genuinely off, not merely unmatched.
        XCTAssertEqual(correctorOnly.correctedInput, "भोलि सम्झाइदिनुस गर्नुहोस")
        XCTAssertEqual(correctorOnly.modelInput, "भोलि सम्झाइदिनुस गर्नुहोस",
                       "rule A's variant is not in the raw text and rule B's is "
                       + "not in the corrected one")
        XCTAssertEqual(correctorOnly.pickerBrainInput, "भोलि सम्झाइदिनुस गर्नुहोस",
                       "corrector only: the PICKER brain is handed the corrected "
                       + "text and the canonicalizer's rule never fires")
        XCTAssertTrue(correctorOnly.applications.isEmpty)
        XCTAssertFalse(correctorOnly.isIdentity)
        XCTAssertTrue(correctorOnly.observabilityMetadata.keys.contains {
            $0.hasPrefix("correction_")
        }, "the corrector's own count-only keys ride the payload when it ran")
        XCTAssertNil(correctorOnly.observabilityMetadata["rule_ids"],
                     "and the canonicalizer's provenance stays absent")

        // CANONICALIZER ONLY — the raw text went in and rule B fired; rule A
        // could not, because the corrector never produced its variant.
        XCTAssertEqual(canonicalizerOnly.correctedInput, original)
        XCTAssertEqual(canonicalizerOnly.modelInput, "भोलि सम्झाइदिनु गर्नुहोस्")
        XCTAssertEqual(canonicalizerOnly.pickerBrainInput, "भोलि सम्झाइदिनु गर्नुहोस्",
                       "canonicalizer only: the picker brain is handed the "
                       + "canonical text")
        XCTAssertEqual(canonicalizerOnly.applications.map(\.ruleID), ["test-plain"])
        XCTAssertEqual(canonicalizerOnly.correction?.mode, .off)
        XCTAssertFalse(canonicalizerOnly.observabilityMetadata.keys.contains {
            $0.hasPrefix("correction_")
        })

        // BOTH — the one combination in which rule A can fire, because it is
        // keyed on what only the corrector can produce. This is the order
        // invariant with teeth: reverse the composition and this expectation
        // is unreachable, not merely different.
        XCTAssertEqual(both.correctedInput, "भोलि सम्झाइदिनुस गर्नुहोस")
        XCTAssertEqual(both.modelInput, "भोलि सम्झाइदिनुस् गर्नुहोस्")
        XCTAssertEqual(both.pickerBrainInput, "भोलि सम्झाइदिनुस् गर्नुहोस्",
                       "both: the picker brain is handed the one string only "
                       + "the ordered composition can produce")
        XCTAssertEqual(both.applications.map(\.ruleID).sorted(),
                       ["test-order", "test-plain"])
        XCTAssertEqual(both.correction?.applications.count, 1)
        XCTAssertFalse(both.isIdentity)
        XCTAssertFalse(both.canonicalizationIsIdentity)
    }

    // MARK: [CORRECTION-ANYBRAIN] the matrix at the LOCAL SLOT's input
    //
    // The pair-level matrix above says what the seam produces. These say
    // WHERE the shipped seam runs and WHO reads its output: the local slot's
    // input (`LocalBrainChain.InputSeam`), in front of whichever brain serves
    // — the encoder (`PreparedTranscriptInterpreting`) or the picker brain.
    // Before the relocation the seam lived inside `IntentEncoderInterpreter`,
    // so with the encoder off neither switch had any effect at all.

    /// One turn of a chain.
    @discardableResult
    private func runChain(_ chain: LocalBrainChain,
                          _ transcript: String) -> InterpretedCommand? {
        let exp = expectation(description: "chain")
        var out: InterpretedCommand?
        chain.interpret(transcript: transcript,
                        context: InterpreterContext(pendingMedications: [],
                                                    userLanguageHint: "ne")) { result in
            out = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        return out
    }

    /// The seam the local slot runs for one matrix combination: the SHIPPED
    /// composition (`IntentEncoderWiring.localSlotInputSeam`'s body —
    /// `IntentInputCanonicalization.prepare`, both policies resolved from the
    /// stored switches), with the fixture's tables and lexicon in place of the
    /// bundled ones, plus a record of what it was run on. The two switches are
    /// written FIRST, through the same `IntentEncoderPreferences` the
    /// coordinator's `didSet` writes, so every cell below is produced by
    /// flipping the two keys and letting the shipped resolution do the rest.
    private func makeMatrixProbe(_ combination: LayerSwitch,
                                 defaults: UserDefaults,
                                 fixture: (lexicon: CorrectionLexicon,
                                           tables: VariantTableSet,
                                           transcript: String)) -> SlotSeamProbe {
        let preferences = IntentEncoderPreferences(defaults: defaults)
        preferences.setCorrectorEnabled(combination.corrector)
        preferences.setCanonicalizerEnabled(combination.canonicalizer)
        let tables = fixture.tables
        let lexicon = fixture.lexicon
        return SlotSeamProbe { text in
            IntentInputCanonicalization.prepare(
                sanitisedTranscript: text,
                dialect: .default,
                tables: tables,
                policy: DialectCanonicalizer.Policy.runtime(defaults: defaults,
                                                            isCompiledIn: true),
                correctionPolicy: STTCorrector.Policy.runtime(defaults: defaults,
                                                              isCompiledIn: true,
                                                              lexicon: lexicon),
                correctionLexicon: lexicon)
        }
    }

    /// A seam plus its record: how often the slot ran it, on what text, and the
    /// pair it produced. "Once per turn" and "on the SANITISED transcript" are
    /// measured here rather than promised in a comment.
    private final class SlotSeamProbe {
        private(set) var callCount = 0
        private(set) var preparedInputs: [String] = []
        private(set) var pairs: [IntentTranscriptPair] = []
        private let prepare: (String) -> IntentTranscriptPair

        init(prepare: @escaping (String) -> IntentTranscriptPair) {
            self.prepare = prepare
        }

        var seam: LocalBrainChain.InputSeam {
            LocalBrainChain.InputSeam { [self] text in
                callCount += 1
                preparedInputs.append(text)
                let pair = prepare(text)
                pairs.append(pair)
                return pair
            }
        }
    }

    /// The four-way matrix at the SLOT's input with the PICKER BRAIN serving —
    /// the encoder switch OFF case this relocation exists for.
    ///
    /// Before it, the picker brain's prompt was the raw transcript and the two
    /// rows had no effect at all while the encoder was off (the rows were
    /// disabled in Settings, and the composition lived inside the encoder's
    /// interpreter). Now the same stored keys rewrite the text the picker brain
    /// reads, in every combination — and the pair the seam actually produced
    /// still carries the ORIGINAL for the safety half.
    func testTheFourWayMatrixReachesThePickerBrainWhenTheEncoderIsOff() throws {
        let fixture = makeToggleMatrixFixture()
        let defaults = isolateDefaults()
        let original = fixture.transcript
        let sanitised = InputSanitiser.sanitise(original, level: .quarantine)

        for combination in LayerSwitch.allCases {
            let probe = makeMatrixProbe(combination, defaults: defaults, fixture: fixture)
            let picker = StubCommandInterpreter(
                result: makeCommand(action: .query, confidence: 0.9))
            // The slot with the encoder out of it: `preferred` cannot serve, so
            // the chain falls through to the stand-in — the picker brain.
            let chain = LocalBrainChain(
                preferred: StubCommandInterpreter(available: false, result: nil),
                standIn: picker,
                inputSeam: probe.seam)

            XCTAssertNotNil(runChain(chain, original),
                            "\(combination): the picker brain answers")

            let pair = try XCTUnwrap(probe.pairs.last,
                                     "\(combination): the slot must have run the seam")
            let expected = matrixPair(combination, defaults: defaults,
                                      fixture: fixture).pair
            XCTAssertEqual(pair, expected,
                           "\(combination): the slot's seam is the shipped "
                           + "composition, resolved from the stored switches")

            XCTAssertEqual(probe.callCount, 1,
                           "\(combination): once per turn — not once per brain, "
                           + "and not once per entry point")
            XCTAssertEqual(probe.preparedInputs, [sanitised],
                           "\(combination): the seam sees sanitised text only — "
                           + "the sanitiser stays the boundary and stays first")
            // The safety half, in EVERY combination, on the pair that ran.
            XCTAssertEqual(pair.safetyNetInput, original,
                           "\(combination): the safety net's input is the original")
            XCTAssertEqual(picker.lastTranscript, pair.pickerBrainInput,
                           "\(combination): the picker brain reads the pair's "
                           + "prepared text")
            XCTAssertEqual(picker.lastTranscript, pair.modelInput,
                           "\(combination): the same string the encoder would "
                           + "tokenize")
            if combination.corrector || combination.canonicalizer {
                XCTAssertNotEqual(picker.lastTranscript, original,
                                  "\(combination): a switch that is ON must change "
                                  + "what the picker brain reads — the whole point")
            } else {
                XCTAssertEqual(picker.lastTranscript, original,
                               "\(combination): nothing rewritten, so the picker "
                               + "brain reads the transcript itself, byte for byte")
            }
        }
    }

    /// The same four cells with the ENCODER's shape serving: a brain that
    /// consumes the pair is handed the PAIR — never a string — and the seam ran
    /// exactly once for the turn, so no brain can correct its own output.
    func testTheFourWayMatrixReachesTheEncoderShapeWithoutASecondRun() throws {
        let fixture = makeToggleMatrixFixture()
        let defaults = isolateDefaults()
        let original = fixture.transcript

        for combination in LayerSwitch.allCases {
            let probe = makeMatrixProbe(combination, defaults: defaults, fixture: fixture)
            let encoder = PreparedBrainSpy()
            let picker = StubCommandInterpreter(
                result: makeCommand(action: .query, confidence: 0.9))
            let chain = LocalBrainChain(preferred: encoder,
                                        standIn: picker,
                                        inputSeam: probe.seam)

            XCTAssertNotNil(runChain(chain, original),
                            "\(combination): the encoder shape answers")
            let pair = try XCTUnwrap(probe.pairs.last)

            XCTAssertEqual(encoder.pairs, [pair],
                           "\(combination): the pair itself reached the brain that "
                           + "consumes it")
            XCTAssertTrue(encoder.transcripts.isEmpty,
                          "\(combination): a prepared brain must not be reached "
                          + "through the string entry point while a pair exists")
            XCTAssertEqual(probe.callCount, 1,
                           "\(combination): the layers ran once — the consuming "
                           + "brain prepares nothing (no correct∘correct)")
            XCTAssertEqual(picker.callCount, 0,
                           "\(combination): an available encoder-shaped brain is "
                           + "the only brain consulted")
            XCTAssertEqual(encoder.pairs.last?.safetyNetInput, original,
                           "\(combination): the safety half is untouched on the "
                           + "encoder's arm too")
            XCTAssertEqual(encoder.pairs.last?.modelInput, pair.modelInput,
                           "\(combination): the pair is handed over verbatim")
        }
    }

    /// The cascade's leg of the contract: when the encoder abstains and the
    /// picker brain answers the SAME turn, it answers the PREPARED text.
    /// Escalation chooses a brain, never an input — a picker that quietly
    /// reverted to the raw transcript would make the two layer switches
    /// untestable in exactly the mode the card offers.
    func testCascadeEscalationHandsThePickerBrainThePreparedText() throws {
        let fixture = makeToggleMatrixFixture()
        let defaults = isolateDefaults()
        let original = fixture.transcript
        let both = matrixPair(.both, defaults: defaults, fixture: fixture).pair
        let probe = makeMatrixProbe(.both, defaults: defaults, fixture: fixture)
        let abstaining = PreparedBrainSpy(result: nil)
        let picker = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.9))
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = LocalBrainChain(
            preferred: abstaining,
            standIn: picker,
            cascade: LocalBrainChain.Cascade(acceptThreshold: 0.7) { reasons.append($0) },
            inputSeam: probe.seam)

        XCTAssertEqual(runChain(chain, original)?.confidence, 0.9,
                       "one turn, one answer: the picker brain answered")
        XCTAssertEqual(reasons, [.abstained])
        XCTAssertEqual(picker.lastTranscript, both.pickerBrainInput,
                       "the escalated brain reads the prepared text")
        XCTAssertNotEqual(picker.lastTranscript, original,
                          "escalation must not revert the input")
        XCTAssertEqual(probe.callCount, 1,
                       "the escalation reuses the turn's one prepared pair")
    }

    /// The policy outcomes themselves, one row per combination: the corrector
    /// switch moves the corrector's arm and ONLY the corrector's, the
    /// canonicalizer switch moves the canonicalizer's gate and only that, and
    /// the compile gate still cannot be talked round by either stored value —
    /// the property that keeps a release build inert whatever the card says.
    func testEachSwitchMovesOnlyItsOwnGateAndTheCompileGateStillWins() {
        let lexicon = makeCorrectionLexicon(threshold: 0.65,
                                            lexicon: ["सम्झाइदिनुस", "होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])

        for combination in LayerSwitch.allCases {
            let defaults = isolateDefaults()
            let preferences = IntentEncoderPreferences(defaults: defaults)
            preferences.setCorrectorEnabled(combination.corrector)
            preferences.setCanonicalizerEnabled(combination.canonicalizer)

            // The stored keys are what they were set to (an absent key would
            // read OFF, so the round trip is part of the matrix).
            XCTAssertEqual(preferences.isCorrectorEnabled, combination.corrector,
                           "\(combination): the corrector switch round-trips")
            XCTAssertEqual(preferences.isCanonicalizerEnabled,
                           combination.canonicalizer,
                           "\(combination): the canonicalizer switch round-trips")

            let correctorPolicy = STTCorrector.Policy.runtime(defaults: defaults,
                                                              isCompiledIn: true,
                                                              lexicon: lexicon)
            let canonicalizerPolicy = DialectCanonicalizer.Policy.runtime(
                defaults: defaults, isCompiledIn: true)

            XCTAssertEqual(correctorPolicy.mode == .apply, combination.corrector,
                           "\(combination): the corrector's arm follows its own switch")
            XCTAssertEqual(canonicalizerPolicy.enabled, combination.canonicalizer,
                           "\(combination): the canonicalizer's gate follows its own "
                           + "switch")
            // The loop is itself the independence proof: across the four rows
            // each gate moves only when ITS switch moves ((correctorOnly) vs
            // (both) differs only in the canonicalizer's, and (neither) vs
            // (correctorOnly) only in the corrector's).

            // The compile gate is still a gate: with INTENT_ENCODER absent,
            // BOTH layers are inert in every combination — including the
            // stored `.apply` the corrector's own key would otherwise select.
            XCTAssertEqual(STTCorrector.Policy.runtime(defaults: defaults,
                                                       isCompiledIn: false,
                                                       lexicon: lexicon).mode,
                           .off,
                           "\(combination): the compile gate cannot be stored round")
            XCTAssertFalse(DialectCanonicalizer.Policy.runtime(defaults: defaults,
                                                               isCompiledIn: false)
                .enabled,
                           "\(combination): nor can the canonicalizer's")
        }
    }

    /// The corrector's arm resolution, pinned: an explicit argument wins, then
    /// a stored three-way mode (the debugger's arm, which must keep working),
    /// then the card's switch. The switch is what makes the matrix reachable
    /// with no debugger at all; the stored arm is what keeps a deliberate
    /// `.shadow` or `.off` pin meaningful.
    func testTheCorrectorSwitchIsTheThirdSourceOfTheArm() {
        let lexicon = makeCorrectionLexicon(threshold: 0.65,
                                            lexicon: ["होस्"],
                                            rows: [("fixture-hos", "होस", "होस्",
                                                    "truncation", 5)])
        let settings = STTCorrectionSettings(defaults: isolateDefaults(),
                                             lexicon: lexicon)

        // No stored mode, switch off: the control arm — the shipped state.
        // (`settings` is here to pin the type's own defaults; the assertions
        // below go through the store `Policy.runtime` actually reads.)
        let offDefaults = isolateDefaults()
        XCTAssertNil(STTCorrectionSettings(defaults: offDefaults, lexicon: lexicon)
            .storedMode, "an absent key is an ABSENT arm, not a stored .off")
        XCTAssertEqual(STTCorrector.Policy.runtime(defaults: offDefaults,
                                                   isCompiledIn: true,
                                                   lexicon: lexicon).mode, .off)

        // No stored mode, switch on: `.apply` — the card can turn the layer on
        // with no debugger and no second key.
        let onDefaults = isolateDefaults()
        IntentEncoderPreferences(defaults: onDefaults).setCorrectorEnabled(true)
        XCTAssertEqual(STTCorrector.Policy.runtime(defaults: onDefaults,
                                                   isCompiledIn: true,
                                                   lexicon: lexicon).mode, .apply)

        // A stored arm outranks the switch, in both directions: the
        // debugger's `.shadow` survives a switch that is on, and a stored
        // `.off` is a deliberate control-arm pin rather than an absence.
        let shadowDefaults = isolateDefaults()
        IntentEncoderPreferences(defaults: shadowDefaults).setCorrectorEnabled(true)
        STTCorrectionSettings(defaults: shadowDefaults, lexicon: lexicon).setMode(.shadow)
        XCTAssertEqual(STTCorrector.Policy.runtime(defaults: shadowDefaults,
                                                   isCompiledIn: true,
                                                   lexicon: lexicon).mode, .shadow)

        let pinnedOffDefaults = isolateDefaults()
        IntentEncoderPreferences(defaults: pinnedOffDefaults).setCorrectorEnabled(true)
        STTCorrectionSettings(defaults: pinnedOffDefaults, lexicon: lexicon).setMode(.off)
        XCTAssertEqual(STTCorrector.Policy.runtime(defaults: pinnedOffDefaults,
                                                   isCompiledIn: true,
                                                   lexicon: lexicon).mode, .off)
        // `reset()` is what clears the pin.
        STTCorrectionSettings(defaults: pinnedOffDefaults, lexicon: lexicon).reset()
        XCTAssertNil(STTCorrectionSettings(defaults: pinnedOffDefaults, lexicon: lexicon)
            .storedMode)
        XCTAssertEqual(STTCorrector.Policy.runtime(defaults: pinnedOffDefaults,
                                                   isCompiledIn: true,
                                                   lexicon: lexicon).mode, .apply,
                       "with the pin cleared the switch is the arm again")

        // An explicit argument outranks everything — the call sites that pass
        // one (tests, a future settings surface) are not silently re-routed.
        XCTAssertEqual(STTCorrector.Policy.runtime(defaults: pinnedOffDefaults,
                                                   isCompiledIn: true,
                                                   isModeOn: .shadow,
                                                   lexicon: lexicon).mode, .shadow)
        // The settings type's own reading of an absent key, unchanged by any
        // of the above: the conservative value.
        XCTAssertEqual(settings.mode, .off)
        XCTAssertNil(settings.threshold, "no debugger has moved the threshold either")
    }

    /// The canonicalizer's two keys: the card's switch
    /// (`intentEncoder.canonicalizer`) turns the gate on, the key this class
    /// shipped with stays READABLE beside it (a device or a debugger that set
    /// it is not silently switched off), and `reset()` clears both.
    func testTheCanonicalizerSwitchAndTheOlderKeyBothRead() {
        let defaults = isolateDefaults()
        let preferences = CanonicalizerPreferences(defaults: defaults)
        XCTAssertEqual(IntentEncoderPreferences.canonicalizerKey,
                       "intentEncoder.canonicalizer")

        // The card's switch alone: on.
        IntentEncoderPreferences(defaults: defaults).setCanonicalizerEnabled(true)
        XCTAssertTrue(preferences.canonicalizerEnabled,
                      "the internal-testing switch is a source of the gate")
        XCTAssertTrue(DialectCanonicalizer.Policy.runtime(defaults: defaults,
                                                          isCompiledIn: true).enabled)

        // The older key alone: still on (nothing is silently switched off).
        let legacyOnly = isolateDefaults()
        legacyOnly.set(true, forKey: CanonicalizerPreferences.canonicalizerEnabledKey)
        XCTAssertTrue(CanonicalizerPreferences(defaults: legacyOnly).canonicalizerEnabled)

        // The class's own setter keeps BOTH keys in step, so a debugger
        // reading either one sees the truth.
        preferences.setCanonicalizerEnabled(false)
        XCTAssertFalse(preferences.canonicalizerEnabled)
        XCTAssertFalse(defaults.bool(forKey: CanonicalizerPreferences.canonicalizerEnabledKey))
        XCTAssertFalse(DialectCanonicalizer.Policy.runtime(defaults: defaults,
                                                           isCompiledIn: true).enabled)

        IntentEncoderPreferences(defaults: defaults).setCanonicalizerEnabled(true)
        preferences.setCanonicalizerEnabled(true)
        preferences.reset()
        XCTAssertFalse(preferences.canonicalizerEnabled,
                       "reset clears the switch as well as the older key")
        XCTAssertNil(defaults.object(forKey: IntentEncoderPreferences.canonicalizerKey))
        XCTAssertNil(defaults.object(forKey: CanonicalizerPreferences.canonicalizerEnabledKey))
    }
}
