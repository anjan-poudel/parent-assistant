import CoreGraphics
import Foundation

/// The single `Equatable` value that owns every operational constant the
/// point, tap & ask feature introduces — the same contract
/// `LiveTranslateConfig` holds for live translation (NFR-LCT-011's shape):
///
///  - no component declares its own copy of a default, and no operational
///    literal appears in the feature's pipeline sources: components take
///    the config at construction (`PointAskConfig.default` is the only place
///    a nominal value is spelled),
///  - the master switch default is **off** (`cloudEnabledDefault`): the
///    consent gate still enforces per attempt, and the switch is a policy
///    the household sets — neither is the other (the shipped
///    `LiveTranslateConfig.geminiCloudEnabledDefault` split),
///  - the cost cap is **not** here: the shipped `GeminiCostGovernor` is
///    consumed exactly as shipped through the shared `GeminiClient`, and a
///    second cap would be a defect, not a convenience (OD7). The 50/day
///    point-ask quota is a Phase 2 addition and deliberately absent.
///
/// Defaults come from the approved design
/// (`docs/superpowers/specs/2026-09-19-point-tap-ask-design.md` §1, §2, §4)
/// and its research report's stage table (§Q6).
struct PointAskConfig: Equatable {

    // MARK: Disclosure

    /// The version stamp carried by consent records (C09's mechanism) and
    /// emitted on the consent events. Owned here so a copy review changes one
    /// place; a later approved copy change bumps this and every stale grant
    /// is invalidated rather than silently inherited.
    ///
    /// Deliberately not a literal date run (`2026-09-19`): the shipped
    /// `LogSanitiser` scrubs digit runs of eight or more with common
    /// separators, which would redact the value out of the consent events
    /// the evidence depends on. `19sep2026` carries the same meaning and
    /// survives the bus intact (the `livetranslate.disclosure.16sep2026.r1`
    /// precedent).
    var disclosureVersion: String = "pointask.disclosure.19sep2026.r1"

    // MARK: Cloud master switch

    /// Whether the cloud (Gemini VLM) tier may run **at all**, before
    /// anything else about it is asked.
    ///
    /// **False** — the owner's locked decision (design §1 item 2): ladder-1
    /// is a complete answer without egress. An elder who has never touched
    /// the setting gets the on-device answer (box → OCR → dictionary/cache
    /// translation → classifier) and nothing leaves the phone; the switch
    /// opts in. It is a *policy*, not consent: the `PointAskConsentGate`
    /// record is still asked for and still enforced on every attempt, and
    /// either one alone never sends anything.
    ///
    /// A *default*, not the persisted state: `PointAskSettings` owns the
    /// value the household chose, and this is the nominal value an absent
    /// key reads as.
    var cloudEnabledDefault: Bool = false

    // MARK: Crop

    /// How far the anchored box extends past the tapped object (or the tap,
    /// when no object box contains it), as a fraction of the box's own
    /// extent: `0.15` ⇒ 15 % of padding on each side. This is the box the
    /// elder sees on screen *and* the crop the pipeline reads, so what is
    /// shown is exactly what is analysed.
    var cropPadFraction: Double = 0.15

    /// The long side, in pixels, of the JPEG upload. The crop is re-encoded
    /// down to this before it leaves the device — never the raw crop, and
    /// never the frame (design §1 item 6).
    var maxUploadSide: Int = 768

    // MARK: Box and chip

    /// How long an anchored box stays on screen without a chip tap before it
    /// retires back to `.awaitingTap`, in seconds (design §4: "box ages out
    /// after 5 s without chip tap").
    var boxAgeOutSeconds: TimeInterval = 5

    /// Whether anchoring a box immediately starts the answer's work.
    ///
    /// **True** is the shipped behaviour and the design's (§4: tap → box →
    /// answer). It says the anchor *is* the question — an elder who tapped
    /// something wants to know what it is, and a second confirming tap would
    /// be the feature asking them to ask twice.
    ///
    /// **False** is the opt-out a caller takes when the anchor is not the
    /// question. The live-translate focus capture is that caller: there the
    /// box is the *target*, the elder's question is asked by the control they
    /// press afterwards, and starting the pipeline's own ladder on the anchor
    /// would run a second, different answer's work for a question nobody
    /// asked — and pay for it. With the flag false the anchor still lands,
    /// still stays `.boxAnchored`, and `PointAskSessionModel.anchoredTarget`
    /// still names the box, so a caller can read the target and do its own
    /// thing with it.
    ///
    /// A *default*, not the persisted state: this is an operational constant
    /// of the feature, and the household has no preference about it.
    var autoAnalyzeOnAnchor: Bool = true

    // MARK: Target resolution

    /// How long a saliency pass's boxes are reused before the next tap
    /// refreshes them, in seconds. The pass costs one saliency request plus
    /// one classification per box, so it is cached — a second tap on the
    /// same scene hits the cache, and only a tap after this interval pays
    /// the pass again (research §Q6 stage 1: tap → box <50 ms, refresh only
    /// when stale).
    var saliencyCacheSeconds: TimeInterval = 2

    /// The smallest share of the frame an object box may occupy to be a tap
    /// target (the same floor `VisionObjectDetectionEngine` ships with).
    var minimumObjectArea: Double = 0.01

    /// How many object boxes the tap hit-test asks the saliency engine for.
    /// Bounded deliberately: the shipped engine classifies one box per
    /// object, and the resolver needs geometry only — two boxes cover a
    /// tap's realistic candidates while keeping the first-tap pass inside
    /// the stage budget.
    var resolverObjectLimit: Int = 2

    // MARK: Local stage timeouts

    /// Deadline for the OCR stage. The pass itself is Vision's (tens of
    /// milliseconds); the deadline is the pipeline's own bound — a stage
    /// that has not returned is left to finish while the pipeline proceeds
    /// with the answer it has, exactly as the live-translate pipeline treats
    /// its brain stage (`brainTranslationStageDeadlineSeconds` reasoning).
    var ocrStageTimeoutSeconds: TimeInterval = 1.0

    /// Deadline for the classification stage, same shape as the OCR one.
    var classifyStageTimeoutSeconds: TimeInterval = 1.0

    /// The pipeline's overall deadline for the whole local ladder — crop is
    /// already done by the time the pipeline runs, so this bounds OCR +
    /// dictionary/cache translation + classification together. Sized well
    /// above the research's honest budget (≤ ~350 ms total) so a real device
    /// never trips it, while a wedged pass still cannot hold the answer
    /// open.
    var localStagesDeadlineSeconds: TimeInterval = 2.0

    // MARK: Cloud VLM stage

    /// Base timeout for one VLM request. **Derived, never stored (CL-8):**
    /// the shipped `GeminiClient.Config.default.timeoutSeconds` (25 s, sized
    /// for the slowest curated model) is the one source of truth, exactly as
    /// `LiveTranslateConfig.cloudRequestTimeout` derives it.
    var cloudRequestTimeout: TimeInterval { GeminiClient.Config.default.timeoutSeconds }

    /// Grace added to the base timeout to form the pipeline's own deadline
    /// for the VLM stage (the live-translate `cloudDeadlineGraceSeconds`
    /// shape): the client bounds itself, but a stage that failed to *return*
    /// must not hold the answer open.
    var cloudDeadlineGraceSeconds: TimeInterval = 5

    /// The total deadline for one VLM stage.
    var cloudDeadlineSeconds: TimeInterval { cloudRequestTimeout + cloudDeadlineGraceSeconds }

    /// Automatic re-attempts of the VLM call after a failed attempt, at most
    /// once (design §2: "25 s timeout, one retry"; ladder 6: transport,
    /// timeout and parse failures get exactly one retry, then the honest
    /// failure).
    var vlmMaxRetries: Int = 1

    /// The confidence below which a VLM answer is spoken with the hedge
    /// line appended (design §3 ladder 5: VLM low confidence <0.4). The
    /// Phase-2 grounded retry replaces the hedge for a first low-confidence
    /// answer; Phase 1 hedges immediately.
    var vlmConfidenceThreshold: Double = 0.4

    /// The lowest classifier confidence that names the object in the
    /// ladder-1 answer — the same floor the shipped object engine uses. An
    /// unnamed object is still answered honestly: the answer skips the
    /// "it looks like …" sentence rather than guessing a class.
    var classifierMinimumConfidence: Float = 0.15

    // MARK: Mask engine (opt-in spike)

    /// Whether the mask engine is asked for at all. **False** — the mask
    /// path is a spike behind `PointAskMaskEngine.supportsMasks` (design §1
    /// item 6 / ship gate: "opt-in stays behind the probe"); the shipped
    /// path hit-tests the existing saliency boxes. A device spike measures
    /// the mask request's latency before this default is ever moved.
    /// [TAP-FIX] (2026-09-19) Default ON: the instance-mask pass is what
    /// makes the box WRAP the object (the tight silhouette extent) — the
    /// behaviour the owner's first device test asked for. The probe still
    /// gates availability honestly (pre-iOS 17 devices and failed passes
    /// fall to the saliency/pad ladder).
    var maskEngineEnabled: Bool = true

    /// The most OCR text, in characters, handed into the VLM prompt. The
    /// text is a *hint* for the model, never an instruction, and a short
    /// bound keeps the prompt token cost predictable. Grapheme-safe by
    /// construction (`String.prefix` operates on characters).
    var promptTextMaxLength: Int = 300

    static let `default` = PointAskConfig()
}

/// The genuinely user-facing setting this feature owns in Phase 1: the
/// cloud tier's master switch (design §1 item 2, §5) — the same shape as
/// `LiveTranslateSettings.geminiCloudEnabled`.
///
/// Persistence: `UserDefaults`, following the shipped `LiveTranslateSettings`
/// precedent. It is a UI preference containing no user content, so it does
/// not belong on the encrypted file channel. It is **not consent**: a
/// recorded grant is still required, and still enforced per attempt (AM-1).
struct PointAskSettings: Equatable {

    /// The prefix reserved for this feature in `UserDefaults`.
    static let featureKeyPrefix = "pointask."

    /// The cloud tier's master switch, declared once so no call site spells
    /// it.
    static let cloudEnabledKey = "pointask.geminiCloudEnabled"

    /// Every key this feature is allowed to write to `UserDefaults`: one
    /// boolean preference and nothing else.
    static let featureKeys: Set<String> = [cloudEnabledKey]

    private let defaults: UserDefaults
    let config: PointAskConfig

    init(defaults: UserDefaults = .standard,
         config: PointAskConfig = .default) {
        self.defaults = defaults
        self.config = config
    }

    /// Whether the cloud tier may run at all. An absent key means the
    /// household has never opted in, which is the config's nominal default
    /// (**false**), not `false` by accident. The read is *not* cached: the
    /// session re-reads it on every attempt decision, so the value the elder
    /// sees and the gate the pipeline runs behind cannot disagree for longer
    /// than the write takes to land.
    var cloudEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.cloudEnabledKey) != nil else {
                return config.cloudEnabledDefault
            }
            return defaults.bool(forKey: Self.cloudEnabledKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.cloudEnabledKey)
        }
    }

    /// The switch's single write path — the Settings leaf's row (Phase 2)
    /// and the session model's own setter behind it. One setter, one key.
    func setCloudEnabled(_ value: Bool) {
        cloudEnabled = value
    }
}
