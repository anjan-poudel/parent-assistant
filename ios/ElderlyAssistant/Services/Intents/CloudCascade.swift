import Foundation

/// [CLOUD-CASCADE] (2026-09-16) The cloud cascade tier's persisted,
/// configurable settings — the internal card's rows (Settings → AI मोडेल,
/// the hidden internal screen), read by `AppCoordinator` at startup and on
/// every flip.
///
/// What the tier is for: the encoder's ladder serves a confident local
/// answer; the LARGE local brain (the picker brain) answers everything the
/// encoder abstained on or came back unsure about — and when THAT answer is
/// below this threshold while an online provider is configured, the turn
/// goes to the cloud instead (with a spoken hold cue first, because the
/// user is about to wait again).
///
/// Persistence follows the house pattern (`VoiceOutputVolume`,
/// `IntentEncoderPreferences`): plain UserDefaults, a UI preference and not
/// a secret, clamped on READ as well as on write so a hand-edited plist can
/// never hand the tier a nonsensical threshold.
enum CloudCascadeSettings {

    /// Stable UserDefaults keys — never rename them: a rename silently
    /// resets every tester's setting to the default.
    static let thresholdKey = "cloudCascade.threshold"
    static let enabledKey = "cloudCascade.enabled"

    /// 97 % — the shipped default: the online brain takes a turn whose
    /// local answer is not nearly certain, and a 97 %-confident local
    /// answer still stays local.
    static let defaultThreshold = 0.97

    /// The configurable range. The floor sits at the router's own accept
    /// band's neighbourhood rather than at 0: below it the tier would
    /// escalate turns the ladder already handles, and a threshold of 1.00
    /// means "escalate everything the local brain is not certain about",
    /// which is the honest top of the range.
    static let minimumThreshold = 0.50
    static let maximumThreshold = 1.00
    static let thresholdStep = 0.01

    static func clamp(_ threshold: Double) -> Double {
        guard threshold.isFinite else { return defaultThreshold }
        return min(maximumThreshold, max(minimumThreshold, threshold))
    }

    /// The effective threshold: the persisted value (clamped), or
    /// `defaultThreshold` when the key was never written.
    static func threshold(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: thresholdKey) != nil else {
            return defaultThreshold
        }
        return clamp(defaults.double(forKey: thresholdKey))
    }

    /// Persists a clamped threshold (the only write path).
    static func setThreshold(_ threshold: Double, defaults: UserDefaults = .standard) {
        defaults.set(clamp(threshold), forKey: thresholdKey)
    }

    /// The internal card's switch. **Default ON**: the tier's rule is the
    /// requested behaviour, and it stays inert on its own wherever no
    /// cloud provider is configured — the switch exists so a tester can
    /// hold the ladder local-first on purpose, not to arm the feature.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - Card arithmetic (0.97 ⇄ 97 %)

    /// The threshold as the card shows it — 0.97 → 97.
    static func percent(_ threshold: Double) -> Int {
        Int((clamp(threshold) * 100).rounded())
    }

    /// The threshold a card percentage means — 97 → 0.97.
    static func threshold(percent: Int) -> Double {
        clamp(Double(percent) / 100)
    }

    /// One ±-press: moves the threshold by whole percent steps,
    /// saturating at the ends of the range.
    static func stepped(_ threshold: Double, bySteps steps: Int) -> Double {
        clamp(threshold + Double(steps) * thresholdStep)
    }
}

/// [CLOUD-CASCADE] The tier's PURE rule — the whole routing decision in one
/// place, with no interpreter, no bus and no clock, so the threshold truth
/// table is unit-testable on its own.
///
/// The contract, in order:
///  · the switch must be on (the internal card's "off" is a real off),
///  · the provider must be ready — configured AND within budget AND its
///    interpreter up (`CloudBrainEndpoint.isReady`); an unconfigured
///    household is inert, which is what keeps the tier silent for every
///    pre-cascade configuration,
///  · and the local answer must be STRICTLY below the threshold. Equality
///    stays local: "97 % or better is good enough" is the whole point of a
///    97 % default.
enum CloudCascadePolicy {

    static func escalates(localConfidence: Double,
                          threshold: Double,
                          isEnabled: Bool,
                          isCloudReady: Bool) -> Bool {
        guard isEnabled, isCloudReady else { return false }
        return localConfidence < threshold
    }
}

/// One escalated turn's audit record — what the activity log and the app
/// log line say about it. Numbers and a provider id only: never the
/// transcript, never the reply (C9 policy, the same rule every event in the
/// intent layer holds to).
struct CloudCascadeEscalation: Equatable {
    /// The provider id the turn went to ("gemini").
    let provider: String
    /// The configured threshold the local answer fell below.
    let threshold: Double
    /// The local brain's own confidence in the answer it was overruled on.
    let localConfidence: Double
}

/// [CLOUD-CASCADE] The tier as `IntentRouter` holds it: the resolved
/// provider endpoint, the two settings, and the two side effects of a
/// firing turn, each behind a seam so the router stays speaker- and
/// storage-free.
///
/// Nil on the router (the default, and every pre-cascade construction site)
/// means "no tier": the ladder behaves byte-identically to before this
/// type existed.
struct CloudCascadeConfiguration {

    /// The provider seam: which online brain takes an escalated turn.
    let endpoint: CloudBrainEndpoint

    /// Below this, the turn escalates (equality stays local).
    let threshold: Double

    /// The internal card's switch, read per turn so a flip acts on the next
    /// utterance.
    let isEnabled: Bool

    /// The spoken hold cue — run exactly ONCE, immediately BEFORE the cloud
    /// call, so the user hears why the wait just got longer. Nil is silent
    /// (tests, and any wiring without a speaker).
    let holdCue: (() -> Void)?

    /// The trail a firing turn leaves behind — the activity-log row and the
    /// app log line, both owned by the coordinator. Run once per escalated
    /// turn, before the cloud call. Nil leaves no trace.
    let onEscalated: ((CloudCascadeEscalation) -> Void)?

    init(endpoint: CloudBrainEndpoint,
         threshold: Double,
         isEnabled: Bool,
         holdCue: (() -> Void)? = nil,
         onEscalated: ((CloudCascadeEscalation) -> Void)? = nil) {
        self.endpoint = endpoint
        self.threshold = threshold
        self.isEnabled = isEnabled
        self.holdCue = holdCue
        self.onEscalated = onEscalated
    }

    /// The whole decision for one local answer, delegating to the pure
    /// policy with THIS configuration's inputs.
    func escalates(localConfidence: Double) -> Bool {
        CloudCascadePolicy.escalates(localConfidence: localConfidence,
                                     threshold: threshold,
                                     isEnabled: isEnabled,
                                     isCloudReady: endpoint.isReady)
    }
}
