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

    /// How many passes a region's normalized string stays available as an
    /// identity signal once its box has left every geometry threshold.
    ///
    /// Identity is keyed by the string first (T-009 amended at the first
    /// device demo): a camera movement that carries a sign's box away from
    /// the box the region was last seen at is not a new sign, and re-keying
    /// it would release the identifier, repaint the overlay and re-ask a
    /// question that has already been answered. The window bounds how long
    /// that claim holds — a sighting long after the last one is a new
    /// observation of the same text, not the same region.
    ///
    /// The shipped value matches `regionMissPasses`: at the shipped
    /// hysteresis a tracked region is alive for exactly one missed pass, so
    /// the string rule covers every region the stabiliser is still willing to
    /// vouch for and no further.
    var regionStringIdentityPasses: Int = 2

    // MARK: Decluttering (OD5)

    /// Normalised centroid distance below which two nearby regions are
    /// merged into one overlay.
    ///
    /// Raised from the OD5 spike value (owner UX rework, 2026-09-17: "the
    /// bubbles are everywhere and shaky and get stacked and clustered
    /// depending on text"). A sign read in two pieces — or one sentence the
    /// detector split — is *one* thing to the elder, and at the old distance
    /// the two halves rendered as two boxes fighting for the same pixels.
    /// Merging is the cheapest way to buy quiet: the union box covers the
    /// same printed text with one overlay instead of two.
    var declutterMergeCentroidDistance: Double = 0.12

    /// Maximum number of overlays rendered at once in a dense scene. Kept
    /// small deliberately: the overlay is now the *glance* surface, and the
    /// snapshot card is the reading surface, so a dense scene shows few large
    /// stable boxes rather than many small ones (owner UX rework, 2026-09-17).
    var declutterMaxRegions: Int = 6

    // MARK: Publication (T-026)

    /// The largest per-coordinate movement of a region's box that is treated
    /// as recognition jitter rather than as a position update — expressed, as
    /// box coordinates are, as a fraction of the container dimension.
    ///
    /// A cycle whose published state would differ from the last published one
    /// in nothing but boxes that moved by at most this much publishes
    /// **nothing**: the consumer keeps the value it has, the overlay keeps the
    /// rects it drew, and a wobble nobody can see stops costing a render. The
    /// next cycle is compared against the same baseline, so a steady drift
    /// still publishes the moment it crosses the threshold.
    ///
    /// This is a *rendering* gate and nothing else. It cannot re-ask or
    /// un-answer a question: the translation gate is keyed by recognized text
    /// and runs in the stabiliser, which has already consumed the pass. Any
    /// change to text, to an outcome, to the policy, to the container or to
    /// the frame publishes normally, epsilon or not.
    ///
    /// 0.02 is 2% of the container dimension.
    var publishBoxEpsilon: Double = 0.02

    /// How far a region's newly measured box may drift from the box **last
    /// rendered** for it before the overlay adopts the new geometry —
    /// expressed, as box coordinates are, as a fraction of the container
    /// dimension.
    ///
    /// The publish epsilon above decides whether a *cycle* is worth
    /// publishing; this one decides whether a **drawn box** is worth moving,
    /// and it is the elder's complaint that asked for it (owner device
    /// verdict, 2026-09-17, after the first rework shipped: "they still jump
    /// around, though not as much as before. Not usable"). Two things move a
    /// box that has not changed its string:
    ///
    ///  - the detector's own per-pass jitter, which the publish gate holds at
    ///    2 % *per coordinate* but still delivers whenever any box crosses
    ///    it, and which accumulates: the gate's baseline is the last
    ///    delivered publication, so a slow creep republishes;
    ///  - everything a box's geometry is *derived* from. The in-place box is
    ///    the region's rect grown into the free space its neighbours leave
    ///    (`inPlaceMaxBox`), so one sign drifting re-measures every box near
    ///    it, and a background region that never moved a pixel can still be
    ///    handed a different rect.
    ///
    /// While a region's normalized string is unchanged, the overlay therefore
    /// holds the rect it last drew and adopts the new one only when the
    /// difference is above this threshold. A steady drift still lands — the
    /// comparison is against the rects on screen, so the difference
    /// accumulates until it is one the elder could see — and the move then
    /// glides rather than snaps (T-021's position smoothing).
    ///
    /// 0.04 is 4 % of the container dimension: on a phone-held-portrait
    /// container that is roughly 16 pt across and 34 pt down, comfortably
    /// above the detector's jitter and well below a move an elder would
    /// follow with their eyes.
    var overlayGeometryStickiness: Double = 0.04

    // MARK: Overlay (D1, OD2)

    /// The point size floor for the **in-place** form — the box that covers a
    /// region's printed text and draws the translation in its place.
    ///
    /// In-place text is allowed below `overlayMinPointSize` because it stands
    /// where text of roughly that size already stood: a sign's own type is not
    /// the app's body size, and refusing to match it would push every small
    /// sign into a callout. The floor is still a floor — below it the region
    /// gets a callout rather than type the elder cannot read, and the
    /// **callout and card** floors stay at `overlayMinPointSize`
    /// (owner UX rework, 2026-09-17: replace-in-place is the default render
    /// for every region).
    var inPlaceMinPointSize: CGFloat = 16

    /// How far the in-place box may grow past the region's own text box, as a
    /// factor: 1.4 ⇒ at most 20 % of the region's own size clear on each axis.
    ///
    /// A ceiling, not an entitlement: the growth is taken only from free space
    /// (see `LiveOverlayPlacement.inPlaceBox`), so a box surrounded by other
    /// text keeps the region's own size and wraps its translation into it.
    var inPlaceMaxGrowth: Double = 1.4

    /// The padding between an in-place box's edge and the text block inside
    /// it, in points.
    ///
    /// The in-place form is a *replacement*, not a bubble: the box is the
    /// region's own printed rect, grown only as far as the translation needs
    /// (see `LiveOverlayPlacement.inPlaceTightBox`), so this is the whole
    /// breathing room between the type and the box that replaces the sign's
    /// type. Deliberately much tighter than the callout's `pillPadding` — a
    /// wide margin around a short translation is what made the owner read the
    /// in-place boxes as bubbles floating over the picture (owner device
    /// verdict, 2026-09-17: "the bubbles are blue background with white text …
    /// they still jump around"). The callout keeps the token spacing: it is a
    /// separate surface beside the text, and it has to read as one.
    var inPlacePadding: CGFloat = 5

    /// The corner radius of an in-place box, in points.
    ///
    /// Corners that hug the text line height, so the box reads as the sign's
    /// own type replaced rather than as a rounded pill: `DesignTokens`'
    /// `bubbleCornerRadius` (14) is a *bubble* corner, right for a callout
    /// that floats over the picture and wrong for a box standing where a line
    /// of print stood. The callout keeps the token's radius.
    var inPlaceCornerRadius: CGFloat = 6

    /// Minimum rendered point size for overlay text: the accessibility floor
    /// for the elder-facing surface.
    var overlayMinPointSize: CGFloat = 18

    /// The design's nominal value for the FR-LCT-017 preference, confirmed
    /// at the first device demo (OD2). This is a *default*, not the
    /// persisted state — `LiveTranslateSettings` owns the persisted value.
    var alwaysShowOriginalDefault: Bool = false

    // MARK: Tier 1 — the on-device brain

    /// The 4B Nepali brain the on-device translation tier runs, newest first:
    /// the first entry that is installed and complete is the one that runs.
    ///
    /// A pinned list rather than "whatever the elder picked for the assistant
    /// brain": the tier's contract is that it is the app's own installed
    /// Nepali brain, and a preference the household can switch at any moment
    /// would make the tier's availability change under a running session for
    /// reasons unrelated to translation.
    ///
    /// Why two entries and not one. `intentQwen4BSlotCanon` is the app's
    /// current brain (`AppCoordinator.defaultBrainModelID`) — the artifact a
    /// device that has used the assistant at all will have. `intentQwen4BS43`
    /// is the seed-43 fine-tune the owner named when this tier was specified;
    /// it is a hidden (superseded, not removed) catalog entry, so a device
    /// that cached it keeps it and a device that never did is not left without
    /// a brain. A single pinned id would leave the tier unavailable on every
    /// device holding the other one — the exact "can't translate" the tier
    /// exists to remove — so the list is the honest shape of "a brain is
    /// installed, either of these will do". Order matters only when a device
    /// holds both.
    ///
    /// A follow-up may want this to follow the elder's brain selection
    /// (`AppCoordinator.resolvedBrainModelID`); that is a product decision,
    /// not a lookup to hide in here.
    var brainTranslationModelIDs: [ModelID] = [ModelCatalog.intentQwen4BSlotCanon,
                                              ModelCatalog.intentQwen4BS43]

    /// Deadline for one brain translation attempt. Latency here is seconds,
    /// not milliseconds — a 4B model generating a batch of short
    /// translations on a phone — and the existing pending state covers the
    /// wait, so the bound is generous. It is still a bound: a generation that
    /// outlives it is stopped and the strings fall through to the cloud
    /// rather than holding the cycle open (failure, never a hang).
    ///
    /// Nominal, not frozen: the device spike to come may move it.
    var brainTranslationTimeoutSeconds: TimeInterval = 25

    /// Strings per brain request. Everything unresolved in one cycle goes to
    /// the brain in ONE generation (the tier's whole point is one call, not
    /// one per region), so this is the point at which a scene is too big for
    /// a single request — the surplus strings are left unresolved for the
    /// cloud tier, never dropped.
    ///
    /// It exists because the shared context is 1,024 tokens (`n_ctx`):
    /// prompt and output share it, so an unbounded batch is a truncated
    /// answer. 8 strings of a scene's short sign text leaves room for both.
    var brainTranslationMaxStrings: Int = 8

    /// Characters per brain request — the second bound on the same batch, for
    /// a scene of two long lines rather than eight short ones. Same rule: the
    /// surplus is left to the cloud, never dropped.
    var brainTranslationMaxCharacters: Int = 800

    /// How long the tier's resident handle may sit unused before it is
    /// released. The translation tier is not in the residency ledger (see
    /// `LocalBrainTranslationTier`'s header for why it cannot be), so this is
    /// its own answer to the same problem that ledger exists for: a camera
    /// session that goes quiet gives the 4B's memory back instead of parking
    /// it until the app dies. A batch arriving after a longer gap pays one
    /// model load inside its own timeout — which is what the generous
    /// `brainTranslationTimeoutSeconds` is sized for.
    var brainTranslationIdleUnloadSeconds: TimeInterval = 30

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
