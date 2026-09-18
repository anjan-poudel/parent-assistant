import CoreGraphics
import Foundation

/// How large a frame the capture stack asks the platform for.
///
/// A two-case intent rather than an `AVCaptureSession.Preset` value: this type
/// is read by the pipeline, the placement and the view, none of which import
/// AVFoundation, and the mapping from "how big a picture does the elder need"
/// to a preset — including the ordered fallback when a device cannot deliver
/// one — belongs at the capture seam that owns the session. The shipped layer
/// reads it through `AVFoundationCaptureLayer.presets(for:)`.
enum LiveTranslateCaptureQuality: String, Equatable {
    /// The pre-change behaviour: `vga640x480`, 307,200 pixels per frame.
    case standard
    /// The default: `hd1280x720`, 921,600 pixels per frame — four times the
    /// detail for the recognition pass, and the size this feature's CPU budget
    /// was re-measured against.
    case high
}

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

    // MARK: Frame-change gate (resource rework, 2026-09-17)

    /// Side of the square luminance signature the frame-change gate reduces
    /// each frame to before comparing it with the last frame recognition ran
    /// on: 64 × 64 = 4,096 samples.
    ///
    /// The gate is *three orders of magnitude* cheaper than the work it exists
    /// to skip — 4,096 strided byte reads and subtractions (tens of
    /// microseconds) against a Vision OCR pass (tens of milliseconds), which is
    /// the only reason it may run on every delivered sample.
    ///
    /// 64 is also the point past which the answer stops changing: recognition
    /// is a high-level decision about a scene, and a finer signature detects
    /// sensor noise rather than a different picture.
    var frameSignatureSide: Int = 64

    /// Mean absolute luminance difference (0–1, per sampled pixel) at or above
    /// which the incoming frame counts as a materially different scene.
    ///
    /// Below the threshold the two frames are "the same picture" as far as
    /// recognition is concerned: sensor noise, the last digit of a hand's
    /// tremor, and an auto-exposure settling all measure under 2 %. A real
    /// change — a sign entering frame, the camera panning — moves the mean by
    /// far more, because it moves whole regions of pixels rather than a
    /// fraction of a level.
    var frameChangeThreshold: Double = 0.02

    /// The cadence the frame tap falls back to while the scene is not
    /// changing: 0.7 s ≈ 1.4 fps.
    ///
    /// Not zero, and not a hard stop. The stabiliser publishes a region only
    /// after `regionAppearPasses` consecutive sightings, so a gate that dropped
    /// *every* unchanged frame would leave a sign discovered on its first
    /// sighting unpublished for ever — a functional regression traded for a
    /// CPU win, which is not a trade this feature makes. An unchanged frame is
    /// therefore still delivered at this interval; the reduced cadence *is* the
    /// refresh rate. A still scene costs ~1.4 OCR passes a second instead of
    /// the nominal 4 (a 65 % cut in the feature's dominant CPU term) and a
    /// moving one keeps the full cadence.
    var stableSampleInterval: TimeInterval = 0.7

    /// Consecutive OCR passes that produced no new or changed region before the
    /// pipeline reports the scene stale and the cadence drops to
    /// `stableSampleInterval`.
    ///
    /// This is the signal a frame change cannot see: a scene that keeps
    /// *moving* without containing any new *text* — a hand, a reflection, a
    /// screen playing video behind the sign — is churn the elder cannot use,
    /// and it would otherwise hold the full cadence open indefinitely. Three
    /// passes is under a second at the nominal cadence, and a tracking pass
    /// interleaved between two text-bearing OCR passes cannot reach it
    /// (the counter resets on any change), so a live pan is never mistaken for
    /// a stale scene.
    var stalePassesBeforeReducedCadence: Int = 3

    // MARK: Camera quality — zoom, lens switching and focus (owner report, 2026-09-17)

    /// How large a frame the capture stack asks the platform for.
    ///
    /// The owner's report is "blurry and not sharp enough for small packaging
    /// text", and the shipped stack was asking for `vga640x480`: a 4 mm line of
    /// print on a packet is a handful of pixels at that size, and no amount of
    /// downstream work puts detail back into a frame that never had it. `.high`
    /// asks for 1280 × 720 — four times the pixels, four times the detail
    /// handed to Vision, and past the point where the frame is the limiting
    /// term for small print.
    ///
    /// Explicitly **not** `.photo` (4032 × 3024). That is ~48 MB per frame in
    /// the 32BGRA the detector reads, and Vision's cost scales with pixels: it
    /// would trade away the resource work this feature just landed (the
    /// frame-diff gate, the reduced cadence, the tracking bound — all of it
    /// written against crash reports showing ~99 % CPU and 1.4 GB) for detail
    /// the recognition pass cannot afford to look at. Enlarging the *view* is
    /// the zoom's job, and the zoom costs the CPU nothing extra: the device
    /// crops the sensor before the data output ever sees the frame. A device
    /// whose active format cannot deliver 720p falls back in the order
    /// `AVFoundationCaptureLayer.presets(for:)` states, which ends at the size
    /// every back camera has delivered since iOS 4.
    ///
    /// Named `cameraQuality`, not `captureQuality`, so the label does not read
    /// as a spend limit: `LiveTranslateConfigTests` fails if any member's name
    /// contains "cap" (OD7 — this feature owns no cost cap), and a legitimate
    /// knob that trips a name-based guard is a knob that has to move, not a
    /// guard that has to weaken.
    var cameraQuality: LiveTranslateCaptureQuality = .high

    /// The widest zoom the elder can reach, **in the readout's unit**: the
    /// number on the control, which is the number the system camera's own
    /// readout would print for the same picture (1 = the wide camera's native
    /// field of view, 0.5 = the ultra-wide, 3 = the telephoto on a 14 Pro Max).
    ///
    /// The unit is the elder's, not the device's, and the conversion between
    /// the two is one rule (`CameraZoomCapabilities.deviceFactor(forReadout:)`,
    /// via `displayMultiplier`): a virtual device's own `videoZoomFactor` calls
    /// its wide camera 2, so a key read in the device's unit would put the
    /// control's "1×" on a factor that is not 1 in the numbers the platform
    /// switches lenses at. Every zoom key here is in this one unit.
    ///
    /// 1, not the device's own minimum, on purpose. A triple camera reaches
    /// down to 0.5 — the ultra-wide — and the ultra-wide is the *worst* of the
    /// three lenses for a line of small print: the smallest sensor, the widest
    /// distortion, the most of the frame spent on things that are not the
    /// label. Zooming *out* is offered as far as the wide camera, which is
    /// where the reading is done; a household that wants the ultra-wide's field
    /// of view (a whole shelf rather than one packet) lowers this key to 0.5.
    /// The model never widens past the running device's own report, so this is
    /// a floor and not a promise.
    var minVideoZoom: Double = 1.0

    /// The longest zoom factor the elder can reach, as a ceiling only: the
    /// running device's `maxAvailableVideoZoomFactor` — the active format's
    /// `videoMaxZoomFactor`, which the platform may report as anything from 4
    /// to 120 depending on the device and the format it is in — narrows it, and
    /// the model clamps to whichever is smaller. Asking for a factor above the
    /// device's own maximum is an `NSRangeException`, not a clamp, which is why
    /// the effective bound is always `min(config, device)` and never the
    /// config's number alone.
    ///
    /// 8 is past what a packet needs: on a 14 Pro Max, 8× is the telephoto
    /// digitally extended past its optical range (the telephoto's own view is
    /// the 3× this key's unit calls 3), and the usable end of the
    /// zoom for print on a packet is well before it. The bound exists so a
    /// pinch cannot wander into a factor where the picture is mush and the
    /// readout is the only thing still changing.
    var maxVideoZoom: Double = 8.0

    /// The zoom a session starts at, in the readout's unit: the wide camera's
    /// native view, which is the whole frame and the sharpest thing the device
    /// can show.
    var initialVideoZoom: Double = 1.0

    /// One press of **+** or **−**, in the readout's unit: half a factor, so
    /// 1× → 1.5× → 2× on the control, and no press can jump over a lens
    /// switch-over factor without landing on it (the model pulls a step that
    /// crosses one back onto it).
    ///
    /// Half a step rather than the system camera's snap between its lens
    /// buttons, because the elder who cannot see the small print is also
    /// judging *how much* bigger they need it, and one big press that overshoots
    /// leaves them hunting in the other direction.
    var zoomStep: Double = 0.5

    /// How near a pinch **release** has to stop to a lens switch-over factor,
    /// as a fraction of that factor, before the release lands on the factor
    /// itself. 0.08 ⇒ within 8 % — 1.84–2.16 around a device whose published
    /// switch-over factor is 2.0. A fraction, so it needs no unit: it is
    /// applied to the factors the device itself publishes.
    ///
    /// The two halves of the rule are different on purpose: a press *snaps*
    /// (deterministic, one lens change per press), a pinch *settles* (the
    /// elder's own fingers chose the number). Snapping a release that stopped
    /// just short of a switch is what stops the readout and the picture
    /// disagreeing about which lens is live. `0` disables the settle.
    var zoomSwitchSnapTolerance: Double = 0.08

    /// Whether a drag of one finger over the picture moves the visible window
    /// while the picture is zoomed.
    ///
    /// The elder's own reading gesture, and the half of the owner's report
    /// ("I expected pinch zoom and panning") that a zoom alone does not answer:
    /// at 3× the label they are chasing may be at the frame's edge, and holding
    /// the whole phone steady to move a two-centimetre picture is not something
    /// a hand does. `false` takes the gesture away and leaves the zoom as it
    /// was — the ± buttons still work, and there is nothing else to move.
    var panEnabled: Bool = true

    /// The window's size at the far end of its ramp, as a fraction of the
    /// frame: 0.7 means the elder may narrow the visible picture to 70 % of
    /// what the frame holds, which is as far as they can push it in either
    /// direction before the window's edge reaches the frame's.
    ///
    /// The window narrows with the **zoom** (see `panStartZoom`/`panFullZoom`)
    /// and this is where it ends up. It is the feature's one trade between pan
    /// room and sharpness, and it is a small one: the pan room it buys is
    /// ±15 % of the frame either way before the clamp, and the display
    /// magnification it costs is 1 / 0.7 ≈ 1.43× of what the lens delivers —
    /// the recognition pass reads the *frame*, so the small print is not
    /// upscaled for Vision, only the picture on the glass is. A household that
    /// wants more room (0.5: ±25 %, 2× on the display) or less (0.85: ±7.5 %,
    /// 1.18×) changes this one number.
    ///
    /// A value that cannot describe a window — zero, negative, past 1 — is
    /// read as 1: no window, no pan, and the picture exactly as the sensor
    /// delivered it, which is the behaviour this feature shipped with.
    var panWindowFraction: Double = 0.7

    /// The readouts the window's ramp runs between, in the readout's unit (the
    /// same unit as the zoom keys above): the whole frame at or below
    /// `panStartZoom`, `panWindowFraction` at or above `panFullZoom`, and
    /// linear between them.
    ///
    /// The ramp exists because a window is only useful once there is something
    /// to move to. At 1× the whole frame is on screen and panning would only
    /// crop away content the elder can already see; by the time they have
    /// zoomed to `panFullZoom` they are reading one label and the window's
    /// edges are what they are chasing. Tying the window to the zoom rather
    /// than to the pan also keeps the pinch's own arithmetic stable: the window
    /// the fingers land on cannot change under them.
    var panStartZoom: Double = 1.0
    var panFullZoom: Double = 4.0

    /// The pinch's exponent: the recogniser's cumulative scale raised to this
    /// power before it moves the zoom. 1 is the scale itself.
    ///
    /// A key rather than a constant because pinch feel is a hand's opinion, not
    /// arithmetic: on a phone held in one hand with the thumb and forefinger of
    /// the other, the same scale reads as a bigger movement than it does on a
    /// stand. Below 1 the picture moves less for the same fingers, above 1 more.
    /// It is applied to the scale only — the anchoring, the lens switches and
    /// the release settle are all unchanged — and a value that is not a
    /// positive number is read as 1.
    var pinchSensitivity: Double = 1.0

    /// Whether the pan goes home when the session exits and when an
    /// interruption takes the camera away and gives it back.
    ///
    /// **True** — the elder's own default state: they put the phone down,
    /// something else used the camera, and they pick it up again at the middle
    /// of the frame rather than at whatever corner the last frame happened to
    /// be in. Also what the system camera does. False suits the elder who is
    /// interrupted *while* reading one label and wants to come back to the same
    /// place; the zoom itself is unaffected either way (the session restores
    /// the factor it opened at).
    var panResetsOnExit: Bool = true

    /// The focus point a session starts at, in the device's normalized
    /// coordinates (0,0 top-left … 1,1 bottom-right): the centre of the frame,
    /// which is where a package being held up for the camera is.
    ///
    /// A tap on the picture replaces it; this is only the starting point, and
    /// it is set for the same reason the mode below is: focus left wherever the
    /// previous session put it is focus on nothing in particular.
    var focusPointOfInterest: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// Whether the autofocus scan is restricted to the near range
    /// (`AVCaptureAutoFocusRangeRestrictionNear`).
    ///
    /// This is the single most useful line in this section for the owner's
    /// complaint. The elder holds a packet 20–40 cm from the lens; the pattern
    /// behind them — a window, a shelf, a television — is what an unrestricted
    /// autofocus loves to find, and a camera that has focused on the far wall
    /// draws the packet as a soft blur. Restricting the scan to near subjects
    /// removes the far wall from the search space entirely, so the only way the
    /// focus can land is on something the elder's own arm can reach. It takes
    /// effect only in `.autoFocus`/`.continuousAutoFocus`, which is why the
    /// focus mode is always set after it.
    var focusNearRangeRestriction: Bool = true

    /// Whether smooth autofocus is asked for where the device supports it.
    ///
    /// **Off**, from the SDK's own guidance: "disabling smooth autofocus is
    /// more appropriate for video processing where a fast autofocus is
    /// necessary" — and this pipeline is video processing, where the pass that
    /// follows a focus change is the one that reads the small print. Smooth
    /// autofocus is slower by design (it trades speed for a cine-like
    /// transition), which is the wrong trade when the elder is waiting to hear
    /// what the packet says. The key exists because smooth focus also hunts
    /// less on a shaking handheld, and a device check may prefer it.
    var smoothAutoFocus: Bool = false

    /// Whether the session starts with focus held at its current lens position
    /// (`.locked`) rather than searching.
    ///
    /// Off: a lock at a distance nobody chose is a lock on the wrong distance,
    /// and the elder's first sight of the screen should already be focused. It
    /// is the focus-lock control's *initial* state; the control itself (a tap
    /// on the lock) is what the elder uses while reading.
    var focusLockDefault: Bool = false

    /// Whether the device reports substantial changes to the subject area
    /// (`AVCaptureDevice.subjectAreaDidChangeNotification`).
    ///
    /// On, and this is the half of "keep it sharp" that a tap cannot do. A tap
    /// focuses where the elder pointed; a packet that is then turned over, held
    /// closer, or moved into a shadow is a different subject area at a
    /// different distance, and the device's own report is what brings the focus
    /// search back to the close range without the elder having to tap again.
    /// The response is deliberately *continuous* focus at the near range and not
    /// another one-shot scan: a one-shot on every report would pump the lens
    /// every time a hand crossed the frame, which is the hunting that makes a
    /// picture look worse than it is.
    var subjectAreaChangeMonitoring: Bool = true

    /// Whether the platform may turn video HDR on for the active format
    /// (`automaticallyAdjustsVideoHDREnabled`).
    ///
    /// On — which is also the platform's own default, stated here rather than
    /// inherited so the choice is the feature's. HDR is *for* the owner's
    /// complaint: a glossy packet under a kitchen light is exactly the scene
    /// that clips its highlights and buries its small print, and the platform's
    /// tone mapping recovers both ends of that range before the frame reaches
    /// Vision.
    ///
    /// The escape hatch matters more than the default: an adaptive tone map is
    /// a luma remap, and luma is what the frame-change gate compares (see
    /// `frameChangeThreshold`). If a device check ever shows the reduced cadence
    /// not engaging on a still scene — the gate reading HDR adaptation as the
    /// picture changing — this is the first key to turn off.
    var automaticVideoHDR: Bool = true

    // MARK: Tracking / stabilisation

    /// Whether region tracking is requested at all. Tracking is a SHOULD
    /// (FR-LCT-004): an unsupported tracking request degrades the feature to
    /// OCR-only and is never an error shown to the elder.
    var trackingEnabled: Bool = true

    /// IoU above which two observations are considered the same region.
    var regionMatchIoU: Double = 0.3

    /// Rectangles followed per tracking pass, at most.
    ///
    /// A tracking pass costs **one `VNTrackRectangleRequest` per remembered
    /// rectangle**, run one after another on the detector's serial Vision
    /// queue, so an unbounded pass over a dense scene is the most expensive
    /// thing this feature can do per frame — more than the OCR pass it exists
    /// to avoid, and the reason a static scene used to burn a full core while
    /// nothing on screen was moving.
    ///
    /// The surplus is not an error and not a loss of text. A key the tracker
    /// was not asked about is simply absent from the pass, which is the
    /// documented tracking-loss path (FR-LCT-004): the stabiliser holds the
    /// last OCR-confirmed geometry, so the overlay keeps drawing the box it
    /// already had. 6 matches `declutterMaxRegions` — the number of overlays
    /// the elder can actually see — so nothing that is not rendered can cost a
    /// request.
    var trackingMaxRectanglesPerPass: Int = 6

    /// Normalised centroid distance below which two observations are
    /// considered the same region.
    var regionMatchCentroidDistance: Double = 0.35

    /// Consecutive passes a candidate must be seen before it is published as
    /// a region (overlay flicker bound).
    var regionAppearPasses: Int = 2

    /// Consecutive passes a published region must be missed before it is
    /// removed (overlay flicker bound).
    ///
    /// This bounds **identity**: how long the stabiliser keeps vouching for a
    /// region that is no longer seen. It is deliberately not the bound on how
    /// long the *overlay* may stay — see `overlayDepartureGraceSeconds`, which
    /// is the elder-visible half of a departure.
    var regionMissPasses: Int = 2

    /// How long a **published** region may stay on screen after its last
    /// sighting, in seconds (owner device verdict, 2026-09-17: "the
    /// translation sticks around even when the camera moved away").
    ///
    /// `regionMissPasses` bounds departures in *passes*, which is the right
    /// unit for identity and the wrong one for the overlay. Two consecutive
    /// misses is 0.5 s at the nominal cadence but **1.4 s** at the reduced
    /// still-scene cadence (`stableSampleInterval`, 0.7 s) — and the scene is
    /// still exactly when the elder pans off a sign, so the slow cadence is
    /// the one a departure almost always runs at. Add the OCR pass and the
    /// removal's own animation and the translation visibly hangs over text the
    /// camera left; a *time* bound is the one that matches what the elder
    /// sees.
    ///
    /// A published region whose last sighting is at least this far behind the
    /// current pass stops being published, so it leaves the emitted set on the
    /// next pass at the latest: the overlay clears within **one cycle plus
    /// this grace**, at any cadence. The region keeps its identity, its box
    /// and its translation until `regionMissPasses` retires it, and re-entering
    /// the emitted set still costs `regionAppearPasses` fresh consecutive
    /// sightings — the appearance hysteresis, and with it the anti-jitter the
    /// two-sided rule exists for, is untouched. Drift-following while visible
    /// is likewise untouched: a region that is *seen* — recognized or tracked —
    /// refreshes its last sighting and never comes near this bound.
    ///
    /// 0.5 s is deliberately above the nominal pass interval (0.25 s), so one
    /// dropped pass at full cadence still cannot clear a box, while a camera
    /// that has genuinely moved on clears it in well under a second.
    var overlayDepartureGraceSeconds: TimeInterval = 1.2

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

    // MARK: Scene blocks (owner UX verdict, 2026-09-18)

    /// Seconds between two object passes.
    ///
    /// The object pass is the feature's **slow** pass, and the cadence is the
    /// reason it can afford to exist: it costs one objectness-saliency request
    /// plus one classification request per object, and what it answers — which
    /// appliances and screens are in the picture — is a property of the scene,
    /// not of a frame. An appliance does not become a different appliance
    /// between two OCR passes, so the result is cached and reused until this
    /// interval has passed.
    ///
    /// Two seconds is deliberately several OCR passes (the nominal pass is a
    /// quarter second): the grouping the objects feed changes only when the
    /// elder points the camera at something else, and the text the elder reads
    /// is refreshed at the OCR cadence throughout. The first pass of a session
    /// always runs the object pass — there is nothing cached to reuse yet.
    var objectPassCadenceSeconds: TimeInterval = 2

    /// How far apart two recognized lines may be, in normalized frame units,
    /// and still be merged into one block.
    ///
    /// The owner's direction is the value: **fewer, bigger** translations, not
    /// per-line fidelity ("maximize text regions — bigger but fewer
    /// translations"). Lines of one paragraph sit a small fraction of the frame
    /// height apart; a menu read as five lines is one surface to the elder, and
    /// at a tight distance it renders as five panels fighting for the same
    /// pixels. Generous on purpose — 10% of the frame height — because the
    /// failure it prevents (a swarm of small boxes) is the one the elder
    /// actually saw, while the failure it risks (two unrelated signs a tenth of
    /// a frame apart merging) is bounded by the second half of the merge rule:
    /// two lines only merge if they also share a column.
    var blockMergeDistance: Double = 0.1

    /// Blocks emitted per pass, at most.
    ///
    /// The count the overlay is allowed to draw. Four is the owner's own bound
    /// ("a small number (≤3–4 visible) of large, stable, translation-ready
    /// surfaces") and it is the whole point of the rework: a dense scene is not
    /// served by translating every line, it is served by the few surfaces a
    /// person can actually read, with the snapshot card as the reading surface
    /// for everything else.
    ///
    /// The blocks outside the bound are not errors and lose no text — they are
    /// exactly what the snapshot card exists for — and the bound is what the
    /// object pass uses too (a scene that resolves to four surfaces does not
    /// need classes for regions the overlay could never draw).
    var maxVisibleBlocks: Int = 4

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
    var overlayGeometryStickiness: Double = 0.06

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

    /// The largest fraction of the container a **bounded panel** may occupy
    /// vertically (`0.45` ⇒ never more than 45 % of the container's height).
    ///
    /// A block whose lines cannot be stacked as a panel at the body floor inside
    /// its own grown box is still a block the elder has to be able to read: the
    /// **bounded panel** draws those very lines at that very floor, inside a box
    /// capped at this fraction of the container and scrolled when they overflow
    /// (owner refinement, 2026-09-18). The cap is the whole reason the form can
    /// exist — without it the last resort for a page of text would be a surface
    /// the size of the screen, which is the snapshot card's job, not the live
    /// overlay's.
    ///
    /// A *fraction* and not a point size, because the container is what the
    /// rects were measured in (the same reason `overlayGeometryStickiness` is
    /// one): a rotation, a small phone and an iPad all get a panel that is the
    /// same share of what the elder is looking at. The lines inside are drawn at
    /// `overlayMinPointSize` (floored by the app's body minimum), never
    /// shrunk to fit — the bounded panel scrolls instead.
    var panelMaxHeightFraction: Double = 0.45

    /// Minimum rendered point size for overlay text: the accessibility floor
    /// for the elder-facing surface.
    var overlayMinPointSize: CGFloat = 18

    /// The design's nominal value for the FR-LCT-017 preference, confirmed
    /// at the first device demo (OD2). This is a *default*, not the
    /// persisted state — `LiveTranslateSettings` owns the persisted value.
    var alwaysShowOriginalDefault: Bool = false

    // MARK: Tier 1 — the on-device brain

    /// The Nepali brain the on-device translation tier runs, newest first:
    /// the first entry that is installed and complete is the one that runs.
    ///
    /// A pinned list rather than "whatever the elder picked for the assistant
    /// brain": the tier's contract is that it is the app's own installed
    /// Nepali brain, and a preference the household can switch at any moment
    /// would make the tier's availability change under a running session for
    /// reasons unrelated to translation.
    ///
    /// Why more than one entry. `nmtEnNeQwen17bR2bQ8` (round-2b, 2026-09-18)
    /// is the artifact the tier was built for: a real EN→NE translation
    /// fine-tune that passes the tier's own raw-prompt + `json_schema`
    /// contract (88.2% usable, 0/34 polarity, 0/12 probes). The two entries
    /// after it are the pre-translation-model fallbacks — `intentQwen4BSlotCanon`
    /// is the app's current assistant brain (`AppCoordinator.defaultBrainModelID`),
    /// the artifact a device that has used the assistant at all will have,
    /// and `intentQwen4BS43` is the seed-43 fine-tune the owner named when
    /// this tier was specified; it is a hidden (superseded, not removed)
    /// catalog entry, so a device that cached it keeps it and a device that
    /// never did is not left without a brain. A single pinned id would leave
    /// the tier unavailable on every device holding another one — the exact
    /// "can't translate" the tier exists to remove — so the list is the
    /// honest shape of "a brain is installed, any of these will do".
    ///
    /// **Order matters** — but only as "first INSTALLED wins"
    /// (`LocalBrainTranslationTier.installedModel`): the head is used when it
    /// is on disk, and there is no per-attempt retry down this list (a load
    /// the warden refuses does not fall through to the next id — the strings
    /// go to the tier behind this one). The head is therefore the newest
    /// artifact, and installing it is what opts a device into the better
    /// translations; a device holding only a fallback keeps working.
    ///
    /// Note the head is `roomy`-class only under `ModelBudgetPolicy`
    /// (1.83 GB takes the 3B weight band → 2.63 GB live, over both the
    /// compact and the standard co-residency budget — see the catalog
    /// entry). On a 6 GB phone the warden refuses its load and the strings
    /// fall to the cloud tier; that is the policy's call, not this list's.
    ///
    /// A follow-up may want this to follow the elder's brain selection
    /// (`AppCoordinator.resolvedBrainModelID`); that is a product decision,
    /// not a lookup to hide in here.
    var brainTranslationModelIDs: [ModelID] = [ModelCatalog.nmtEnNeQwen17bR2bQ8,
                                              ModelCatalog.intentQwen4BSlotCanon,
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

    /// Grace added to `brainTranslationTimeoutSeconds` to form the pipeline's
    /// own deadline for the whole brain stage.
    ///
    /// The tier bounds itself (the deadline above stops the decode), but a
    /// bound a component enforces on itself only helps the caller if the call
    /// *returns*: a stage that failed to end — a 4B load thrashing through a
    /// pressured device's page cache is the realistic one, and it is not
    /// covered by the decode deadline at all — would hold the strings it
    /// claimed for the rest of the session, and every tick after it would skip
    /// them as "already dispatched". The region would sit on the pending copy
    /// while the cloud could have answered it in the same cycle.
    ///
    /// So the pipeline waits on its own clock too, and this is the slack it
    /// allows the tier's bound to land in. It is deliberately short: the tier's
    /// answer should always win when it is coming at all, and the grace only
    /// has to cover the difference between "the decode stopped" and "the call
    /// came back".
    var brainTranslationStageGraceSeconds: TimeInterval = 3

    /// The pipeline's deadline for one brain stage. Derived from the two values
    /// above, so it can drift from neither — the same shape the cloud deadline
    /// uses (`cloudRequestTimeout + cloudDeadlineGraceSeconds`).
    ///
    /// On expiry the pipeline stops waiting: the strings it handed over go on
    /// to the gate in that same cycle, and the generation finishes (or does
    /// not) with nobody listening. A deferred translation is a worse
    /// translation; a stranded region is a worse product.
    var brainTranslationStageDeadlineSeconds: TimeInterval {
        brainTranslationTimeoutSeconds + brainTranslationStageGraceSeconds
    }

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
    ///
    /// Re-tuned 2026-09-17 (30 s → 5 s) against the device's own crash
    /// reports. The 30 s window was sized for "one model load inside the
    /// timeout", which it does buy; what it also bought was a 2.5 GB GGUF
    /// resident across *every* scene the elder looked at for half a minute
    /// after the last generation — and on a 5.5 GB device whose live camera
    /// footprint was already measured at 1.18–1.41 GB, that residency is what
    /// the memory-pressure crashes were made of. 5 s is still longer than any
    /// inter-region gap inside one scene (the pipeline batches one generation
    /// per cycle, not per region), so it does not reload between regions of
    /// the same sign; it only stops the tier from holding GBs through the
    /// elder's next ten glances at nothing.
    ///
    /// Deliberately *not* "release after every batch": a 4B GGUF costs a full
    /// file page-in to re-load, and paying that per batch is the CPU burn the
    /// watchdog kills for. Freeing the memory quickly and keeping the reload
    /// rare is the pairing that satisfies both pressure and the CPU limit.
    var brainTranslationIdleUnloadSeconds: TimeInterval = 5

    /// Headroom floor, as a multiple of the brain's declared **hard**
    /// footprint (`ModelFootprint.hardBytes` — the part of a model's cost the
    /// OS cannot reclaim on our behalf, i.e. the KV and output buffers rather
    /// than the pageable weights), below which the tier does not load at all
    /// and the batch is deferred to the cloud.
    ///
    /// This is the device's own arithmetic, not a new number: `hardBytes` is
    /// exactly what `ModelLifecycleInventory` declares, and the ledger's own
    /// hard-headroom rule is that this is the quantity to compare against the
    /// probe. Requiring 1.0× means "only add the brain's non-pageable cost if
    /// the app currently has that much headroom under its jetsam ceiling";
    /// the weights themselves are mmap'd and pageable, so they are not charged
    /// twice.
    ///
    /// It exists because the alternative on a pressured device is worse than a
    /// missing translation: crossing the ceiling gets the whole app killed, and
    /// a killed app translates nothing at all. The strings are not lost — they
    /// go to the next tier, which is the same honest outcome as any other
    /// brain unavailability.
    var brainTranslationHeadroomFactor: Double = 1.0

    /// Whether the tier defers to a brain that is already resident for another
    /// owner — the voice pipeline's `.brain` or `.intentBrain` slot — rather
    /// than running a second multi-GB generation alongside it.
    ///
    /// Read-only, and deliberately so: this tier takes no residency slot (see
    /// the tier's header), so it must never evict, register or claim. It only
    /// asks the ledger whether a brain is live and, if one is, hands its
    /// strings to the cloud. Two 4B workloads at once on a 5.5 GB device is
    /// the single fastest way to get killed, and a deferred translation beats a
    /// dead app; the voice brain is the resident the household is actively
    /// talking to, so it is the one that keeps the device.
    var brainTranslationDefersToResidentBrain: Bool = true

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
