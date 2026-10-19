import Foundation

/// The loop's payload-version identity (T-054 §3.3) — what a consent is
/// a consent TO, and what the egress gate compares against before
/// anything leaves the device.
///
/// `schemaSha8` is the short prefix of SHA-256 over the schema artifact
/// landed verbatim from T-054 §3.1 at `specs/loop_egress_schema.yaml`
/// (repo root, beside the design notes, until `tools/train-intent/` takes
/// it over). T-059 checks the shipped serialiser and the shipped payload
/// against THAT artifact rather than against prose, and the consent is
/// meaningless if the artifact is still prose at the moment the consent
/// is written — which is why the artifact is landed here, in the capture
/// task, before any egress code exists at all (T-054 §11).
///
/// `LearningLoopStoreTests.testSchemaSha8MatchesTheShippedArtifact`
/// recomputes the digest from the file on disk and fails when it drifts
/// from the constant below. Re-hashing silently would silently change what
/// every existing consent means: the accepted version is the whole point
/// of recording it.
enum LearningLoopSchema {

    /// The consent's scope (T-054 §3.3): `payload_version` in the
    /// artifact. Deliberately NOT the envelope's `v`, which is the
    /// wire-format version — a change to either that widens a value space
    /// re-triggers consent, but they are different promises.
    static let payloadVersion = "loop-1"

    /// First 8 hex of SHA-256 over `schemaArtifactPath`:
    /// `cdfa7328c473abe7bea1afd19a23d7abe61093e8c3bb31114dc9008f9a63e186`.
    static let schemaSha8 = "cdfa7328"

    /// Repo-relative path of the hashed artifact — the drift test's
    /// lookup, and the pointer a reader follows to the contract itself.
    static let schemaArtifactPath = "specs/loop_egress_schema.yaml"
}
