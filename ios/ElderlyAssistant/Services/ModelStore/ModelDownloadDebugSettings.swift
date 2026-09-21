import Foundation

/// [DEVSCREEN-DOWNLOAD] The DEBUG-ONLY switches the model download service
/// reads, and the one that matters here: `ignoreFitPolicyKey`.
///
/// The hidden translation test screen exists to run the A/B on models the
/// warden's availability policy refuses on this device class
/// (`.requiresEvictingWarmSTT`, `.overClassBudget`). A policy that cannot be
/// stepped around makes that screen useless for exactly the models it is
/// there to measure — its Download button would end in
/// `download_policy_rejected` every time.
///
/// So the carve-out is a PERSISTED, DEFAULT-OFF preference rather than a
/// flag baked into the screen: the owner turns it on for as long as the A/B
/// runs and turns it back off, and until then every surface — the
/// household's own Settings rows included — downloads under the unchanged
/// policy. It is surfaced as a switch row in the hidden technical sheet
/// (see `TranslateTestView`).
///
/// It bypasses POLICY only. The size cap, the disk guard, the RAM floor and
/// the iOS tier are facts about the phone and the artifact, not about the
/// device class's budget, and every one of them still refuses a download
/// with this switch on (pinned by
/// `MultipartDownloadTests.testTheDeveloperBypassSkipsTheClassVerdictAndNothingElse`).
enum ModelDownloadDebugSettings {

    /// The [DEVSCREEN-DOWNLOAD] switch's key. Declared once so no call site
    /// spells it, and so the service, the switch row and the install card's
    /// caption cannot drift onto different keys.
    static let ignoreFitPolicyKey = "modelDownload.ignoreModelFitPolicyForDownloads"

    /// Whether the warden's availability verdict may be skipped for a
    /// DOWNLOAD.
    ///
    /// `bool(forKey:)` answers `false` for an unset key, which is exactly
    /// the default this wants: nobody bypasses the fit policy until a
    /// developer has persisted the choice. `defaults` is injected so a test
    /// can prove that default against a store of its own rather than the
    /// process's.
    static func ignoresFitPolicy(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: ignoreFitPolicyKey)
    }
}
