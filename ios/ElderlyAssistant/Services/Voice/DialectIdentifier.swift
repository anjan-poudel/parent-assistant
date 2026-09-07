import Foundation

// MARK: - On-device dialect identification (voice-personalisation P0, slice D)

/// Classifies the user's Nepali dialect from a WhisperKit encoder embedding
/// (nearest-centroid / kNN over a bundled centroid table) and maps the
/// resulting label to per-user decode-biasing prompt tokens.
///
/// Seam contract (see docs/voice-personalisation-p0-plan.md slice D and
/// docs/research-sections/accent-adaptation.md §4.1, §4.4):
/// - The *label + seam* is the P0 deliverable; accent *packs* are server work.
///   A non-default label only ever toggles prompt-token biasing in the
///   WhisperKit `DecodingOptions` path — no model switching happens here.
/// - The bundled table (`Resources/DialectCentroids.json`) ships as
///   **SEED-CENTROIDS**: placeholder centroids until the server-side
///   calibration pipeline (field corpus per dialect cluster, ≥10 h/cluster)
///   regenerates it. Seeds are unit vectors of random direction, so cosine
///   similarity to any real embedding is ≈ 0 and classification honestly
///   falls back to `.default` (margin confidence ≈ 0.5 < 0.6 gate).
/// - Honest <60%-confidence → `.default` (the base "default pack"). No
///   embedding or a table that cannot be trusted is also `.default`, with the
///   reason surfaced so callers can emit honest observability.
/// - PII-free: this file never touches audio, transcripts, or contact data —
///   events built from it carry only the label raw value.
///
/// Embedding contract: one mean-pooled vector per (short) sample, produced
/// by the enrolment caller from WhisperKit's public encoder chain — mel
/// features (`featureExtractor.logMelSpectrogram`) through
/// `audioEncoder.encodeFeatures` (`encoder_output_embeds`), then
/// `DialectEmbeddingVector.meanPooled`. The pinned WhisperKit revision
/// (branch main @ ea872ffd) exposes that chain publicly; see
/// WhisperKitSpeechRecognizer.extractDialectEmbedding(from:).
///
/// Prompt-token contract: ≤100 tokens (research §4.1: prompt biasing
/// degrades past ~200 tokens) of whisper BPE ids, precomputed server-side
/// with the calibration run (deterministic) and stored per cluster. The
/// decode path consumes token ids only — no runtime tokenizer dependency.

// MARK: - Label

/// Stable, persisted dialect labels. Raw values are persistence keys and
/// event metadata — never rename (add cases instead).
enum DialectLabel: String, Codable, CaseIterable, Sendable, Equatable {
    /// Eastern Nepali (Koshi/Purbeli-speaking regions).
    case eastern
    /// Far-western Doteli complex (ISO dty) — the most acoustically
    /// distinct variety; the research's first priority pack candidate.
    case doteli
    /// No dialect identified → the base "default pack" (standard/central
    /// Nepali coverage of the shipped model). Also the persisted value for
    /// every user until enrolment classifies them.
    case `default`

    /// True when a real dialect pack selection exists (decode biasing is
    /// active). `.default` keeps existing STT behaviour byte-identical.
    var selectsPack: Bool { self != .default }
}

// MARK: - Persisted per-user preference

/// UserDefaults persistence for the user's dialect label, same shape as
/// `AppLanguage` ("appLanguage" → this uses "dialectLabel"). Injected
/// defaults make tests hermetic.
enum DialectPreference {
    static let defaultsKey = "dialectLabel"

    static func persisted(defaults: UserDefaults = .standard) -> DialectLabel {
        guard let raw = defaults.string(forKey: defaultsKey),
              let label = DialectLabel(rawValue: raw) else {
            return .default
        }
        return label
    }

    static func persist(_ label: DialectLabel, defaults: UserDefaults = .standard) {
        defaults.set(label.rawValue, forKey: defaultsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

// MARK: - Bundled centroid table

/// The bundled dialect centroid table (JSON, formatVersion 1).
///
/// Schema (decode keys are camelCase):
/// ```
/// {
///   "formatVersion": 1,
///   "encoder": "whisperkit-ne-medium",      // catalog artifact the embeddings come from
///   "embeddingDimension": 1024,             // vector length of one pooled embedding
///   "similarityMetric": "cosine",           // only supported metric
///   "confidenceGate": 0.6,                  // < gate → .default (research: <60%)
///   "generation": { "status": "...", "path": "...", "date": null },
///   "clusters": [
///     { "id": "eastern",
///       "centroid": [ ... embeddingDimension floats ... ],
///       "promptTokenIds": [ ... whisper BPE ids, ≤ 100 ... ],
///       "promptText": [ ... reference strings for calibration review ... ] }
///   ]
/// }
/// ```
/// Generation path (documented in full by tools/generate-seed-dialect-centroids.py
/// and the bundled file's `generation.path`): mean-pool
/// `encoder_output_embeds` of the shipped `whisperkit-ne-medium` over the
/// contracted per-cluster field corpus (≥10 h per cluster), unit-normalise
/// each embedding, average per cluster, and tokenise the per-cluster prompt
/// with whisper's BPE tokenizer. Until that pipeline exists the shipped file
/// is SEED-CENTROIDS and must not drive enrolment decisions (it can't — it
/// classifies nothing above the gate by construction).
struct DialectCentroidTable: Decodable, Sendable {
    struct Cluster: Decodable, Sendable {
        let id: String
        /// Unit-normalised centroid; count must equal `embeddingDimension`.
        let centroid: [Float]
        /// Precomputed whisper BPE token ids (≤ maxPromptTokenCount).
        /// Empty while seeds ship; filled by the calibration pipeline.
        let promptTokenIds: [Int]
        /// Human-readable reference (calibration review only — never used at
        /// decode time; decode consumes `promptTokenIds`).
        let promptText: [String]
    }

    struct Generation: Decodable, Sendable {
        /// "SEED-CENTROIDS" while placeholder; "calibrated" once the field-
        /// corpus pipeline has produced real centroids.
        let status: String
        /// Documented generation path (human-readable).
        let path: String
        /// Calibration completion date; nil for seeds.
        let date: String?
    }

    let formatVersion: Int
    /// Model artifact id the embeddings were extracted from (ModelCatalog).
    let encoder: String
    let embeddingDimension: Int
    /// Only "cosine" is supported; tables claiming anything else are
    /// rejected as corrupt.
    let similarityMetric: String
    /// Confidence below this gate classifies as `.default`. Research:
    /// <60% confidence → default pack. Defaults to 0.6 when absent.
    let confidenceGate: Float
    let generation: Generation
    let clusters: [Cluster]

    /// Max prompt tokens applied at decode time (research §4.1: biasing
    /// degrades past ~200 shared-context tokens; P0 budget ≤100).
    static let maxPromptTokenCount = 100

    static let bundledResourceName = "DialectCentroids"

    /// Loads the shipped table from the given bundle. Returns nil when the
    /// resource is absent; throws when it exists but cannot be decoded.
    static func bundled(in bundle: Bundle = .main) throws -> DialectCentroidTable? {
        guard let url = bundle.url(forResource: bundledResourceName,
                                   withExtension: "json") else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DialectCentroidTable.self, from: data)
    }

    /// Process-wide cache for the decode hot path (static let is lazily
    /// initialised once, thread-safely). A missing/corrupt bundled table
    /// caches as nil — the decode path then behaves exactly like `.default`
    /// and the recognizer reports the reason honestly once per session.
    static let bundledCached: DialectCentroidTable? = {
        try? DialectCentroidTable.bundled()
    }()

    func cluster(for label: DialectLabel) -> Cluster? {
        guard label != .default else { return nil }
        return clusters.first { $0.id == label.rawValue }
    }

    /// Deterministic label → prompt-token mapping for decode biasing.
    /// `.default` (and any label the table does not know) → empty. Never
    /// more than `maxPromptTokenCount` ids.
    func promptTokenIds(for label: DialectLabel) -> [Int] {
        guard let cluster = cluster(for: label) else { return [] }
        return Array(cluster.promptTokenIds.prefix(Self.maxPromptTokenCount))
    }

    // MARK: Honest validation

    enum Issue: Equatable, Sendable {
        case unsupportedFormatVersion(Int)
        case unsupportedMetric(String)
        case invalidEmbeddingDimension(Int)
        case invalidConfidenceGate(Float)
        case emptyClusters
        case duplicateClusterId(String)
        case unknownClusterId(String)
        case invalidCentroidLength(cluster: String, expected: Int, actual: Int)
        case negativeTokenId(cluster: String)
    }

    /// Structural checks in deterministic order. A table with any issue must
    /// not classify — its answers would be silently wrong, so the caller
    /// reports `.default` + `.tableCorrupt` instead.
    func issues() -> [Issue] {
        var found: [Issue] = []
        if formatVersion != 1 { found.append(.unsupportedFormatVersion(formatVersion)) }
        if similarityMetric != "cosine" { found.append(.unsupportedMetric(similarityMetric)) }
        if embeddingDimension <= 0 { found.append(.invalidEmbeddingDimension(embeddingDimension)) }
        if !(confidenceGate > 0 && confidenceGate <= 1) {
            found.append(.invalidConfidenceGate(confidenceGate))
        }
        if clusters.isEmpty { found.append(.emptyClusters) }
        var seen = Set<String>()
        for cluster in clusters {
            if !seen.insert(cluster.id).inserted {
                found.append(.duplicateClusterId(cluster.id))
            } else if DialectLabel(rawValue: cluster.id) == nil
                        || DialectLabel(rawValue: cluster.id) == .default {
                found.append(.unknownClusterId(cluster.id))
            }
            if cluster.centroid.count != embeddingDimension {
                found.append(.invalidCentroidLength(cluster: cluster.id,
                                                    expected: embeddingDimension,
                                                    actual: cluster.centroid.count))
            }
            if cluster.promptTokenIds.contains(where: { $0 < 0 }) {
                found.append(.negativeTokenId(cluster: cluster.id))
            }
        }
        return found
    }
}

// MARK: - Embedding reduction

/// Pure helpers for turning a WhisperKit encoder output tensor
/// (`encoder_output_embeds`, shape [1, 1, frames, dim] typically) into the
/// single pooled vector the classifier consumes. Kept CoreML-free so the
/// pooling semantics are exhaustively unit-testable; the recognizer bridges
/// MLMultiArray → (shape, flat values) and calls here.
enum DialectEmbeddingVector {
    /// Mean-pools a row-major tensor over every axis except the embedding
    /// axis — defined as the *single* axis whose extent equals
    /// `embeddingDimension` (frame-pooled utterance vector, per research
    /// §4.4's frozen-encoder practice). Returns nil when the tensor is
    /// malformed, the axis is ambiguous, or the extent never appears.
    static func meanPooled(shape: [Int],
                           values: [Float],
                           embeddingDimension: Int) -> [Float]? {
        guard !shape.isEmpty,
              shape.allSatisfy({ $0 > 0 }),
              embeddingDimension > 0 else { return nil }
        let total = shape.reduce(1, *)
        guard values.count == total else { return nil }
        let embeddingAxes = shape.indices.filter { shape[$0] == embeddingDimension }
        guard embeddingAxes.count == 1 else { return nil }
        let embeddingAxis = embeddingAxes[0]

        // Row-major strides: elements of a trailing axis are contiguous.
        var strides = [Int](repeating: 0, count: shape.count)
        var stride = 1
        for axis in (0..<shape.count).reversed() {
            strides[axis] = stride
            stride *= shape[axis]
        }

        var sums = [Float](repeating: 0, count: embeddingDimension)
        var counts = [Int](repeating: 0, count: embeddingDimension)
        let embeddingStride = strides[embeddingAxis]
        for (index, value) in values.enumerated() {
            let coordinate = (index / embeddingStride) % embeddingDimension
            sums[coordinate] += value
            counts[coordinate] += 1
        }
        var pooled = [Float](repeating: 0, count: embeddingDimension)
        for i in 0..<embeddingDimension where counts[i] > 0 {
            pooled[i] = sums[i] / Float(counts[i])
        }
        return pooled
    }
}

// MARK: - Classifier

/// Classification outcome: the *effective* label (already gated — anything
/// below the table's confidence gate comes back as `.default`) plus the
/// reason, so callers can emit honest observability without guessing.
struct DialectClassification: Equatable, Sendable {
    let label: DialectLabel
    /// Margin confidence in [0, 1]: `0.5 + (best - secondBest) / 2` over
    /// cosine *agreement* (similarities clipped to ≥ 0 — a negative cosine
    /// is "no evidence", and an anti-correlated embedding must not win by
    /// margin over an even worse centroid). With a single cluster the
    /// second-best agreement is 0 ("no evidence for any alternative"), so a
    /// lone centroid needs agreement 1.0 for confidence 1.0.
    let confidence: Float
    let reason: DialectClassificationReason
}

enum DialectClassificationReason: Equatable, Sendable {
    case classified
    case lowConfidence(Float)
    case emptyEmbedding
    case nonFiniteEmbedding
    case dimensionMismatch(expected: Int, actual: Int)
    case tableMissing
    case tableCorrupt(String)
}

/// Nearest-centroid classifier over the bundled table (kNN with k = 1, which
/// research §4.4 reports at 0.94–0.96 on frozen Whisper encoder embeddings;
/// the margin confidence doubles as the "kNN density" sanity check).
///
/// Pure and deterministic — no I/O, no audio, no user data.
struct DialectIdentifier: Sendable {
    /// nil when the caller could not load/decode the bundled table — an
    /// honest `.tableMissing`, never a guess.
    let table: DialectCentroidTable?

    init(table: DialectCentroidTable?) {
        self.table = table
    }

    /// The shipped table from the app bundle (nil when absent/corrupt).
    static var bundled: DialectIdentifier {
        DialectIdentifier(table: DialectCentroidTable.bundledCached)
    }

    func classify(embedding: [Float]) -> DialectClassification {
        guard let table else {
            return DialectClassification(label: .default,
                                         confidence: 0,
                                         reason: .tableMissing)
        }
        if let firstIssue = table.issues().first {
            return DialectClassification(label: .default,
                                         confidence: 0,
                                         reason: .tableCorrupt(String(describing: firstIssue)))
        }
        guard !embedding.isEmpty else {
            return DialectClassification(label: .default,
                                         confidence: 0,
                                         reason: .emptyEmbedding)
        }
        // NaN/inf elements would poison every similarity (and produce a
        // misleading lowConfidence(NaN)) — refuse with an explicit reason.
        guard embedding.allSatisfy(\.isFinite) else {
            return DialectClassification(label: .default,
                                         confidence: 0,
                                         reason: .nonFiniteEmbedding)
        }
        guard embedding.count == table.embeddingDimension else {
            return DialectClassification(label: .default,
                                         confidence: 0,
                                         reason: .dimensionMismatch(expected: table.embeddingDimension,
                                                                    actual: embedding.count))
        }

        // Cosine agreement: negative similarity is clipped to 0 ("no
        // evidence") so anti-correlated embeddings cannot win by margin.
        let agreements = table.clusters.map {
            max(0, cosineSimilarity(embedding, $0.centroid))
        }
        let bestIndex = agreements.indices.max { agreements[$0] < agreements[$1] } ?? 0
        let best = agreements[bestIndex]
        // Second-best agreement across the *remaining* clusters; 0 when only
        // one cluster exists (see DialectClassification.confidence docs).
        let rest = agreements.enumerated()
            .filter { $0.offset != bestIndex }
            .map(\.element)
        let secondBest = rest.max() ?? 0
        let confidence = min(1, max(0, 0.5 + (best - secondBest) / 2))

        guard confidence >= table.confidenceGate,
              let label = DialectLabel(rawValue: table.clusters[bestIndex].id) else {
            return DialectClassification(label: .default,
                                         confidence: confidence,
                                         reason: .lowConfidence(confidence))
        }
        return DialectClassification(label: label,
                                     confidence: confidence,
                                     reason: .classified)
    }

    /// Cosine similarity in [-1, 1]; a zero-norm vector scores 0 against
    /// everything (silence/no-signal embeddings cannot win a margin).
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let product = (normA.squareRoot() * normB.squareRoot())
        guard product > 0 else { return 0 }
        return dot / product
    }
}
