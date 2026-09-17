import CoreGraphics
import Foundation

/// C14 — the single `Equatable` value that owns **every** operational
/// constant the live camera translation feature introduces (NFR-LCT-011),
/// with the defaults from the design's parameter table
/// (`specs/design-component.md` § "Configurable parameters and timeouts").
///
/// What this type exists to make true:
///  - no component declares its own copy of a default, and no operational
///    literal appears in the feature's pipeline sources: components take
///    the config at construction (`LiveTranslateConfig.default` is the only
///    place a nominal value is spelled),
///  - there is **no user-facing configuration surface** in v1: the device
///    spike values for OD1 and OD5 land as edits to this one type,
///  - the cost cap is **not** here (OD7): the shipped
///    `GeminiCostGovernor.softDailyCap` is consumed exactly as shipped and
///    stays family-editable. A second cap in this type would be a defect,
///    not a convenience, because two caps can disagree.
///
/// Pure value type: `Equatable`, no I/O, no singletons, no mutable static
/// state. A source-level test fails if one of these defaults is re-declared
/// as a literal in the feature's pipeline sources.
struct LiveTranslateConfig: Equatable {

    // MARK: Detection cadence (OD1)

    /// Seconds between OCR passes. Nominal ≈4 fps; not frozen — this is a
    /// device-spike output, not a design commitment (OD1).
    var ocrSampleInterval: TimeInterval = 0.25

    /// Multiplier applied to `ocrSampleInterval` once the device reaches
    /// `thermalStateThreshold`: the cadence slows rather than stopping.
    var thermalCadenceFactor: Double = 2.0

    /// The thermal state at which the reduced cadence takes effect.
    var thermalStateThreshold: ProcessInfo.ThermalState = .serious

    // MARK: Tracking / stabilisation

    /// Whether region tracking is requested at all. Tracking is a SHOULD
    /// (FR-LCT-004): an unsupported tracking request degrades the feature to
    /// OCR-only and is never an error shown to the elder.
    var trackingEnabled: Bool = true

    /// IoU above which two observations are considered the same region.
    var regionMatchIoU: Double = 0.3

    /// Normalised centroid distance below which two observations are
    /// considered the same region.
    var regionMatchCentroidDistance: Double = 0.35

    /// Consecutive passes a candidate must be seen before it is published as
    /// a region (overlay flicker bound).
    var regionAppearPasses: Int = 2

    /// Consecutive passes a published region must be missed before it is
    /// removed (overlay flicker bound).
    var regionMissPasses: Int = 2

    // MARK: Decluttering (OD5)

    /// Normalised centroid distance below which two nearby regions are
    /// merged into one overlay.
    var declutterMergeCentroidDistance: Double = 0.06

    /// Maximum number of overlays rendered at once in a dense scene.
    var declutterMaxRegions: Int = 8

    // MARK: Overlay (D1, OD2)

    /// Source strings of at most this many words are eligible for the
    /// in-place form (tier 0 only, D1).
    var inPlaceMaxSourceWordCount: Int = 3

    /// Minimum rendered point size for overlay text: the accessibility floor
    /// for the elder-facing surface.
    var overlayMinPointSize: CGFloat = 18

    /// The design's nominal value for the FR-LCT-017 preference, confirmed
    /// at the first device demo (OD2). This is a *default*, not the
    /// persisted state — `LiveTranslateSettings` owns the persisted value.
    var alwaysShowOriginalDefault: Bool = false

    // MARK: Tier 2

    /// Base timeout for one tier-2 request. **Derived, never stored (CL-8):**
    /// the shipped `GeminiClient.Config.default.timeoutSeconds` (25 s, sized
    /// for the slowest curated model) is the one source of truth, so a
    /// second, divergent value cannot exist. The design's parameter table
    /// records the same thing: changing this requires a change to the
    /// client's config, not to the feature.
    var cloudRequestTimeout: TimeInterval { GeminiClient.Config.default.timeoutSeconds }

    /// Grace added to the base timeout to form the tier-2 deadline: a
    /// transport that outlives its own timeout terminates the batch instead
    /// of leaving a region pending forever (failure table row 18).
    var cloudDeadlineGraceSeconds: TimeInterval = 5

    /// The total deadline for one tier-2 attempt. Derived from the two
    /// values above, so it can drift from neither.
    var cloudDeadlineSeconds: TimeInterval { cloudRequestTimeout + cloudDeadlineGraceSeconds }

    /// Automatic re-attempts for a transient failure, at most once (rows
    /// 13/14/17 of the design's retryability table).
    var cloudMaxRetries: Int = 1

    /// Strings per translation request.
    var cloudBatchMaxStrings: Int = 12

    /// Characters per translation request; a scene over either bound is
    /// split into sequential batches rather than dropped.
    var cloudBatchMaxCharacters: Int = 1200

    /// Per-string bound applied by `SceneTextSanitiser` (grapheme-safe
    /// truncation, never quarantine).
    var sceneTextMaxLength: Int = 120

    /// Response-size sanity bound: a translation longer than
    /// `ratio * source + allowance` characters is not accepted.
    var translationMaxLengthRatio: Double = 4.0

    /// Constant term of the response-size sanity bound (covers scripts that
    /// expand short source strings).
    var translationMaxLengthAllowance: Int = 64

    // MARK: Cache

    /// Entries kept in the general translation cache before LRU eviction.
    var cacheGeneralEntryLimit: Int = 200

    /// Whether repeated touches of the same cache key within one pass are
    /// coalesced into one write (the overlay renders at the OCR cadence).
    var cacheTouchCoalescing: Bool = true

    // MARK: Disclosure

    /// The version stamp carried by consent records (C09) and emitted on the
    /// consent events. Owned here so the OD3 copy review changes one place;
    /// a later approved copy change bumps this and every stale grant is
    /// invalidated rather than silently inherited.
    ///
    /// The OD3 copy review completed 2026-09-17 with the wording unchanged,
    /// so the stamp no longer says `draft.`. The bump retires any grant made
    /// under the old stamp rather than letting it be silently inherited; none
    /// existed in the field, the feature being unmerged at the time.
    ///
    /// Deliberately not a literal date run (`2026-09-16`): the shipped
    /// `LogSanitiser` scrubs digit runs of eight or more with common
    /// separators (the phone-shape guard), which would redact the value out
    /// of the consent events the evidence depends on. `16sep2026` carries
    /// the same meaning and survives the bus intact.
    var disclosureVersion: String = "livetranslate.disclosure.16sep2026.r1"

    static let `default` = LiveTranslateConfig()
}
