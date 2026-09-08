import XCTest
@testable import ElderlyAssistant

/// `SpeakerEmbedderSelection` + `VoiceBiometricStatusResolver` — the
/// honesty machinery (WakeWordConfigTests' pattern applied to voice
/// login): what the embedder is, and what Settings may truthfully say.
final class SpeakerEmbedderSelectionTests: XCTestCase {

    // MARK: - Selection

    func testSelectionFallsBackToMFCCWhenNoCoreMLCandidate() {
        let embedder = SpeakerEmbedderSelection.make(coreMLCandidate: nil)
        XCTAssertEqual(embedder.embedderID, "mfcc.stats.v1",
                       "no ECAPA candidate → the deterministic MFCC fallback ships")
        XCTAssertTrue(embedder.isAvailable)
    }

    func testSelectionPrefersCoreMLCandidateWhenPresent() {
        let candidate = StubSpeakerEmbedder()
        candidate.embedderID = "ecapa.coreml.v1"
        let embedder = SpeakerEmbedderSelection.make(coreMLCandidate: { candidate })
        XCTAssertTrue(embedder === candidate,
                      "a real ECAPA embedder must pass through untouched")
    }

    func testSelectionPrefersMFCCOverADecliningCandidate() {
        // The ECAPA spike declines (no model in this build) → MFCC, never Null.
        let embedder = SpeakerEmbedderSelection.make(coreMLCandidate: { nil })
        XCTAssertEqual(embedder.embedderID, "mfcc.stats.v1")
    }

    func testSelectionNeverReturnsNull() {
        XCTAssertFalse(SpeakerEmbedderSelection.make(coreMLCandidate: nil) is NullSpeakerEmbedder,
                       "voice login ON must always have a working embedder")
    }

    func testDisabledSelectionIsNullAndUnavailable() {
        let embedder = SpeakerEmbedderSelection.disabled()
        XCTAssertTrue(embedder is NullSpeakerEmbedder)
        XCTAssertFalse(embedder.isAvailable)
        XCTAssertEqual(embedder.embed(collectedPCM: [1, 2, 3]),
                       .failure(.unavailable))
    }

    // MARK: - Status derivation

    private func profileResult(_ profile: EnrolledVoiceProfile?) -> Result<EnrolledVoiceProfile?, StorageError> {
        .success(profile)
    }

    private func profile(embedderID: String) -> EnrolledVoiceProfile {
        EnrolledVoiceProfile(schemaVersion: VoiceBiometricStore.currentSchemaVersion,
                             embedderID: embedderID,
                             embedding: [1, 0, 0],
                             createdAt: Date(), utteranceCount: 3,
                             perUtteranceSpeechSeconds: [2, 2, 2])
    }

    func testStatusIsDisabledWhenNotEnabled() {
        let status = VoiceBiometricStatusResolver.status(
            enabled: false,
            profileLoad: profileResult(profile(embedderID: "mfcc.stats.v1")),
            currentEmbedderID: "mfcc.stats.v1")
        XCTAssertEqual(status, .disabled,
                       "a stored template changes nothing while voice login is OFF")
    }

    func testStatusIsNotEnrolledWhenNoTemplate() {
        let status = VoiceBiometricStatusResolver.status(
            enabled: true,
            profileLoad: profileResult(nil),
            currentEmbedderID: "mfcc.stats.v1")
        XCTAssertEqual(status, .notEnrolled)
    }

    func testStatusIsEnrolledWhenEmbeddersMatch() {
        let status = VoiceBiometricStatusResolver.status(
            enabled: true,
            profileLoad: profileResult(profile(embedderID: "mfcc.stats.v1")),
            currentEmbedderID: "mfcc.stats.v1")
        XCTAssertEqual(status, .enrolled(embedderID: "mfcc.stats.v1"))
    }

    func testStatusIsNeedsReenrollmentWhenEmbedderChanged() {
        // The ECAPA-migration moment (doc §10): a template exists but the
        // launch embedder is different — Settings must say re-enroll,
        // never Active.
        let status = VoiceBiometricStatusResolver.status(
            enabled: true,
            profileLoad: profileResult(profile(embedderID: "mfcc.stats.v1")),
            currentEmbedderID: "ecapa.coreml.v1")
        XCTAssertEqual(status, .needsReenrollment(templateEmbedderID: "mfcc.stats.v1"))
    }

    func testStatusIsUnreadableWhenLoadFails() {
        let status = VoiceBiometricStatusResolver.status(
            enabled: true,
            profileLoad: .failure(.encryptedReadFailed),
            currentEmbedderID: "mfcc.stats.v1")
        XCTAssertEqual(status, .templateUnreadable)
    }

    func testStatusNeverClaimsEnrolledWithNullEmbedder() {
        // The disabled selection resolves to .disabled regardless of a
        // stored template — the honesty contract: no silent Active.
        let status = VoiceBiometricStatusResolver.status(
            enabled: false,
            profileLoad: profileResult(profile(embedderID: "null")),
            currentEmbedderID: "null")
        XCTAssertEqual(status, .disabled)
    }
}
