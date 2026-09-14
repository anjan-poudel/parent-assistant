import Foundation

/// [ENCODER-RUNTIME-READY] The T-036 artifact's label sets, decoded from the
/// bundled companion resource.
///
/// ## Why a companion resource and not "the meta.json from the zip"
///
/// The delivered artifact zip carries exactly one top-level directory —
/// `t033-encoder-int8.mlmodelc` — and nothing else (verified against the
/// shipped bytes; see `specs/T-036-notes.md`). The training run's
/// `artifact/meta.json`, which is the ONLY place the intent order, the BIO
/// tag order, `max_len`, the fitted `calibration_temperature` and the
/// `artifact_digest` are recorded, is therefore NOT delivered with the
/// graph. The CoreML graph's outputs are bare logits (`intent_logits`,
/// `slot_logits`); the id→label mapping has to come from somewhere, and
/// `IntentEncoderManifest`'s own docs (written for the T-033 spike) already
/// state the design rule: ship the mapping with the runtime and version it,
/// so a model/runtime mismatch is detectable rather than silently
/// mislabelling every utterance.
///
/// So the mapping ships as
/// `Resources/Intents/encoder_spike_meta.json` — an unchanged subset of the
/// producing run's `artifact/meta.json`, values copied verbatim (the file's
/// own `_readme` / `_provenance` keys record where it came from and are
/// ignored here). This type is the ONLY decoder of that file: label order
/// reaches the interpreter through it and nowhere else.
struct IntentEncoderArtifactMeta: Equatable {
    /// The manifest the interpreter decodes with (label sets, sequence
    /// length, calibration temperature).
    let manifest: IntentEncoderManifest
    /// The producing run's `artifact_digest` — the sha256 of its `model.pt`,
    /// committed as the project's 12-character hex reference. Nothing on
    /// device can re-derive it (the export zip's own sha256 is what
    /// `ModelStore` verifies strictly before unpacking, pinned in
    /// `ModelCatalog.intentEncoderSpike`); it is carried so a label-set /
    /// artifact mismatch is checkable in-repo and by tests, not dropped.
    let artifactDigest: String
}

/// Loader for the companion resource. Errors are explicit and content-free
/// (a key name or a reason, never a file path or a value).
enum IntentEncoderManifestResource {

    static let resourceName = "encoder_spike_meta"
    static let resourceExtension = "json"
    /// Blue folder reference in `project.yml` → `Intents/` in the app
    /// bundle (same pattern as `Manuals/`, `NumberWords/`).
    static let resourceSubdirectory = "Intents"

    enum LoadError: Error, Equatable {
        /// The resource is not in the bundle at all — a build/packaging
        /// fault, never a runtime condition to paper over.
        case resourceMissing
        case unreadable(String)
        case malformed(String)
    }

    /// Loads and validates the bundled companion resource.
    ///
    /// Validation is deliberate: a manifest whose label order is one key off
    /// would mislabel EVERY utterance silently, so each invariant the
    /// decoder relies on is checked here and a violation throws rather than
    /// producing a plausible-looking manifest.
    static func load(bundle: Bundle = .main) throws -> IntentEncoderArtifactMeta {
        guard let url = bundle.url(forResource: resourceName,
                                   withExtension: resourceExtension,
                                   subdirectory: resourceSubdirectory) else {
            throw LoadError.resourceMissing
        }
        return try load(contentsOf: url)
    }

    static func load(contentsOf url: URL) throws -> IntentEncoderArtifactMeta {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable("read")
        }
        return try decode(data)
    }

    /// The pure decode + validation step (unit-testable without a bundle).
    static func decode(_ data: Data) throws -> IntentEncoderArtifactMeta {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LoadError.unreadable("json")
        }
        guard let object = raw as? [String: Any] else {
            throw LoadError.malformed("root_not_object")
        }
        guard let manifestID = object["manifest_id"] as? String, !manifestID.isEmpty else {
            throw LoadError.malformed("manifest_id")
        }
        guard let version = object["manifest_version"] as? String, !version.isEmpty else {
            throw LoadError.malformed("manifest_version")
        }
        guard let intents = object["intents"] as? [String], !intents.isEmpty,
              intents.allSatisfy({ !$0.isEmpty }) else {
            throw LoadError.malformed("intents")
        }
        guard let tags = object["tags"] as? [String], !tags.isEmpty else {
            throw LoadError.malformed("tags")
        }
        // Every tag must be decodable by `IntentEncoderManifest.decode`: `O`
        // or a B-/I- pair over a schema-v2 slot type. A tag outside that set
        // would make the runtime abstain on every utterance that touches it,
        // so it is caught at load time instead.
        for tag in tags {
            switch IntentEncoderManifest(id: manifestID, version: version,
                                         intents: intents, tags: [tag],
                                         maxSequenceLength: 1).decode(tag: tag) {
            case .outside, .slot: continue
            case .unknown(let name): throw LoadError.malformed("tag:\(name)")
            }
        }
        guard let maxLength = object["max_len"] as? Int,
              maxLength >= 2, maxLength <= 512 else {
            throw LoadError.malformed("max_len")
        }
        guard let temperature = object["calibration_temperature"] as? Double,
              temperature.isFinite, temperature > 0 else {
            throw LoadError.malformed("calibration_temperature")
        }
        guard let digest = object["artifact_digest"] as? String,
              digest.count == 12,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw LoadError.malformed("artifact_digest")
        }
        let manifest = IntentEncoderManifest(id: manifestID,
                                             version: version,
                                             intents: intents,
                                             tags: tags,
                                             maxSequenceLength: maxLength,
                                             calibrationTemperature: temperature)
        return IntentEncoderArtifactMeta(manifest: manifest, artifactDigest: digest)
    }
}
