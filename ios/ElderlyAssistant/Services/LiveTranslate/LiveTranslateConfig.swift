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

    // MARK: The picture's own stabilization (owner device verdict, 2026-09-18)

    // The owner's verdict on the green-overlay build, verbatim: "the text is
    // still shaky and jittery and unstable — back to the same old problem.
    // STABILISE THE IMAGE FIRST, and secondly overlay text on top of the
    // original text." The overlay was already as steady as smoothing allows;
    // what moved was the *picture*. These keys hold the picture still: the
    // frame's content is tracked against an anchor frame on device, and the
    // window the preview is drawn through is panned by the motion the hand did
    // not mean. The box is drawn through the same window, so a box on a now
    // still picture is a box glued to the words it replaces.
    //
    // The whole file's `frameStab*` family is operational, all of it, and for
    // the owner's own reason: a device check on a dim kitchen or a bright
    // shopfront is what would move these numbers. `FrameAnchorEstimator` is the
    // file that reads them, and the sampling ceiling that bounds what any of
    // them can do is written down there.

    /// Whether the picture is stabilized. `false` is the honest identity: no
    /// anchor is taken, no request is made, and the display is the elder's own
    /// window exactly as `panWindowFraction` describes it.
    ///
    /// A key rather than a delete-the-code decision, because this is the one
    /// number that trades CPU for steadiness, and a device that turns out to
    /// spend too much on it must be able to say so without a release.
    var frameStabEnabled: Bool = true

    /// How much content motion, as a fraction of the frame, is read as the
    /// hand's own tremor and **absorbed whole** — the window takes the motion
    /// and the picture does not move on screen at all.
    ///
    /// This is the key the whole feature is about, and the number is a hand's
    /// opinion. 0.01 is 1 % of the frame — about 4 pt of a 390 pt picture — and
    /// it is set at the point where a movement stops being tremor and starts
    /// being intent: below it the elder is holding the phone still and any
    /// motion is the hand's noise, above it they are *pointing* the camera
    /// somewhere and the picture has to follow (see `frameStabFollowFactor`).
    /// Too high and the app swallows deliberate small re-framings; too low and
    /// the tremor reaches the glass.
    var frameStabDeadZone: Double = 0.01

    /// How much of the way toward the content's position the window travels per
    /// measurement once the motion is past the dead zone.
    ///
    /// A deliberate re-frame is *followed*, and followed over a few
    /// measurements rather than in one: the fraction that is not yet followed
    /// is what the elder sees the picture move by, which is what makes a pan
    /// read as a pan instead of as a still picture that jumped. 0.4 settles most
    /// of a movement inside half a second at the nominal cadence, which is what
    /// a pan looks like when a hand does it. 1 follows exactly (no trace left
    /// for a deliberate move, and the dead zone becomes a step); small values
    /// leave a slow pan spending the window's whole travel budget and pinning at
    /// the frame's edge.
    ///
    /// 0.4 rather than the 0.35 this was first written with: `0.35` is already a
    /// *configured* value (`regionMatchCentroidDistance`), and the app layer
    /// spells that same number for its own reason
    /// (`LiveTranslateOverlayView.positionSmoothingSeconds`), so a second key at
    /// 0.35 makes `LiveTranslateAppLayerHygieneTests` report the app layer's
    /// literal twice for a collision this change did not create. The
    /// stabilisation's numbers are device-tunable opinions, and one of them
    /// moving a twentieth of the way further per measurement costs nothing.
    var frameStabFollowFactor: Double = 0.4

    /// How far the window is inset — and therefore how far the correction may
    /// ever move it — as a fraction of the frame.
    ///
    /// It is the correction's entire budget, and it is also the price: the
    /// display shows `1 - 2·margin` of the frame, so 0.03 is a permanent 6 %
    /// enlargement (and 6 % less of the picture at its edges) bought in exchange
    /// for ±3 % of travel. The inset and the travel are deliberately the same
    /// number: a window inset by `margin` can be moved by exactly that much
    /// before its edge would reach the frame's, so no clamp ever has to fight
    /// the law — the bound *is* the geometry. Zero is the identity; a value
    /// wider than the window allows is clamped at the point where the window
    /// would collapse.
    var frameStabMargin: Double = 0.03

    /// How far a measurement may sit from the anchor — in position, or in the
    /// scale the anchor's rect has taken on — before it is read as **not the
    /// hand's motion**: a scene cut, a lens change, a device zoom, a whip pan.
    ///
    /// A measurement like that says nothing about how to hold this picture
    /// still, so it re-bases the anchor and the window stays exactly where it
    /// is (this key never moves the picture). 0.2 is a fifth of the frame in one
    /// measurement at the nominal cadence — a quarter of the frame's height in a
    /// quarter of a second, which is a re-frame and not a hand. 0.01 is the
    /// floor: below it, an ordinary tremor would keep re-basing the anchor.
    var frameStabRejectDelta: Double = 0.2

    /// How long an anchor is kept before a fresh one is taken, in seconds.
    ///
    /// The anchor is a reference *image*, and a reference the elder has been
    /// moving away from for longer than this is measuring a difference they
    /// left behind: a slow drift that a still hand and a still picture would
    /// otherwise carry for ever. Re-taking it moves nothing — the window keeps
    /// its pan — so this key has no visible cost, and the only reason it is not
    /// smaller is that an anchor taken too often is an anchor taken before there
    /// is any motion to measure against it.
    var frameStabAnchorSeconds: TimeInterval = 2.0

    /// The long side, in pixels, of the small copy of the frame the registration
    /// runs on. **The cost knob**, and the only one.
    ///
    /// A registration's price is its pixels — a homography on the 1280 × 720
    /// frame would be eight times this and is not what a motion estimate needs —
    /// while what a registration needs is not resolution but texture: the same
    /// corner found twice, which 256 px of a sign's own edge provides. The
    /// measured cost of the shipped value is reported by
    /// `FrameAnchorEstimatorTests`, so raising this number is a decision with a
    /// price on it rather than a guess.
    var frameStabRegistrationSide: Int = 256

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

    // MARK: Recognition quality (OCR-first rework, 2026-09-18)

    // The owner's verdict on the shipped feature — "the text still looks shit
    // — forget translation, it's doing very poor OCR. Focus on OCR first;
    // extract and overlay text in realtime better, like Google's camera text
    // extraction" — moves the recognition pass from something the translation
    // tiers feed on to the feature's own product. These keys are that pass's
    // whole configuration, and the measurements they ship at are recorded in
    // `OCRRecognitionSettingsTests` (fixture frames, line counts and mean
    // confidence) rather than asserted into existence.

    /// Whether the recognition request applies the recognizer's language model
    /// to what it read, correcting a word against the language it is in.
    ///
    /// **On, and this is the rework's single largest quality change.** Vision's
    /// `.accurate` recognizer reads glyphs; the language model is what turns a
    /// near-miss on a worn or glossy label into the word that is actually
    /// printed ("Detrost" → "Defrost"). The recognizer's own default for this
    /// property is `false`, so the shipped pass was reading every label without
    /// it — which is much of why the owner saw "very poor OCR" on packaging
    /// whose type is small, curved and low-contrast.
    ///
    /// It is not free: correction costs time and can rewrite a word onto a
    /// different one the model prefers. Both costs are bounded here — the
    /// vocabulary below biases the model toward the words this feature
    /// actually reads, and the fixture probe records the trade on a rendered
    /// packaging label rather than assuming it.
    var ocrAppliesLanguageCorrection: Bool = true

    /// Whether the recognizer works out the language itself
    /// (`VNRecognizeTextRequest.automaticallyDetectsLanguage`, iOS 16 and
    /// later), instead of being held to `ocrCorrectionLanguages`.
    ///
    /// True, and load-bearing for this market: the labels this feature is
    /// pointed at are English more often than not, but a Nepali sign, a
    /// Devanagari packet and a mixed shopfront are all in scope, and pinning
    /// the request to `en-US` would make every one of them a Latin guess. When
    /// this is on, `ocrCorrectionLanguages` is not applied — Vision picks the
    /// language first and corrects *within* it, which is the behaviour the
    /// correction above wants: correction follows the detected language rather
    /// than forcing every string through English.
    var ocrAutomaticallyDetectsLanguage: Bool = true

    /// The languages the request is restricted to when
    /// `ocrAutomaticallyDetectsLanguage` is off — a household whose labels are
    /// only ever English sets that flag to `false` and gets an English-only
    /// pass, which is both faster and less likely to correct an English word
    /// into a Devanagari one.
    var ocrCorrectionLanguages: [String] = ["en-US"]

    /// The smallest share of the recognized image's height a line of text may
    /// occupy and still be reported — `VNRecognizeTextRequest.minimumTextHeight`.
    ///
    /// **0.0: no floor**, and for the owner's complaint that *is* the tuning.
    /// This is a *rejection* threshold: a value above zero drops every line
    /// shorter than that share of the picture, which on a packet held at arm's
    /// length is exactly the line the elder is trying to read. Vision's own
    /// default is 0.0, so the shipped value is not a change — it is stated
    /// here, and configurable, because a raised floor is the first thing
    /// someone reaches for when a scene is noisy, and the probe in
    /// `OCRRecognitionSettingsTests` is where the cost of doing so on small
    /// print is measured rather than argued about.
    ///
    /// The zoom does the work a floor cannot: the pass reads a *crop* of the
    /// frame at the sensor's full resolution, so a line of print occupies a
    /// much larger share of the image Vision is handed than it does of the
    /// phone's screen.
    var ocrMinimumTextHeight: Float = 0.0

    /// Whether the appliance and packaging vocabulary is handed to the
    /// recognizer as `customWords`.
    ///
    /// The recognizer's language model is trained on prose. A control panel is
    /// not prose: "Prewash", "Eco", "Defrost", "Rinse" and "Turbo" are either
    /// rare in general text or spelled like nothing else, which is why a
    /// perfectly legible panel can come back as "Prewash" → "Prew as h". The
    /// vocabulary is the feature's own `labelVocabulary` below — the tier-0
    /// dictionary's English keys, which are exactly the words printed on
    /// appliance faces, plus the packaging supplement.
    ///
    /// Configurable because biasing a recognizer is a trade: a word list this
    /// specific can pull an unusual ordinary word toward one of its entries.
    /// The fixture probe records the trade on a panel fixture, and a household
    /// that reads signs rather than appliances turns it off.
    var ocrUsesLabelVocabulary: Bool = true

    /// Whether a pass that recognized **nothing** over the elder's window is
    /// retried once over the whole frame at the fast recognition level.
    ///
    /// The owner's most visible failure is not a misread word, it is a pass
    /// that returns nothing at all over a picture full of text — and the
    /// overlay's answer to that is its empty state, which reads as "it can't
    /// find anything to read". A blank result is the one case where a second
    /// pass is unambiguously worth its cost, and this is deliberately the
    /// *only* case that pays it:
    ///
    ///  - it runs only when the accurate pass over the window found nothing,
    ///    so the nominal pass is unchanged and the resource work (the
    ///    frame-change gate, the reduced cadence) is untouched;
    ///  - it reads the **whole frame**, not the window, because the reason a
    ///    window can come back empty is that the elder is pointing at the
    ///    wrong part of what they can see;
    ///  - it runs at `VNRequestTextRecognitionLevel.fast`, the level the
    ///    platform documents for large, well-lit text: it will not read a
    ///    packet's small print, and it does not need to — the case it exists
    ///    for is a sign, a screen or a heading the accurate pass missed.
    var ocrLargeTextRetryEnabled: Bool = true

    /// The word list handed to the recognizer as `customWords`, derived from
    /// the two sources that own it and never spelled at a call site.
    ///
    /// Empty when `ocrUsesLabelVocabulary` is off, so the engine has one
    /// question to ask ("what is the vocabulary?") rather than two ("is the
    /// vocabulary on?" *and* "what is it?").
    var ocrVocabulary: [String] {
        ocrUsesLabelVocabulary ? Self.labelVocabulary : []
    }

    /// The feature's own vocabulary: the tier-0 curated dictionary's **English
    /// keys** — the words that were chosen, one by one, as what is printed on
    /// an appliance's face or a packet — plus a small supplement of packaging
    /// words that dictionary does not carry.
    ///
    /// The dictionary is read, never written: it is the translation tier's,
    /// additive-only and pinned by its own tests, and a second copy of it here
    /// would be a second thing to keep in step. `LiveTranslateConfigTests`
    /// fails if the list stops tracking it.
    static let labelVocabulary: [String] = {
        var words = Set(ApplianceLabelLocalizer.dictionary.keys)
        words.formUnion(packagingVocabulary)
        return words.sorted()
    }()

    /// The packaging supplement: words that appear on packets, cartons and
    /// care labels and are **not** in the curated dictionary.
    ///
    /// Deliberately short and deliberately lower-case. `customWords` biases
    /// recognition as a whole, and a long list of marginal words buys noise:
    /// every entry here is one the owner's own scenes contain, and a household
    /// with different packaging extends it here rather than editing the
    /// recognizer.
    static let packagingVocabulary: [String] = [
        "prewash",
        "ecowash",
        "quick wash",
        "rinse aid",
        "no spin",
        "extra rinse",
        "hand wash",
        "dry clean",
        "do not bleach",
        "no bleach",
        "tumble dry",
        "line dry",
        "wash separately",
        "machine wash",
        "keep refrigerated",
        "best before",
        "use by",
        "batch no",
        "net weight",
        "nutrition",
        "energy rating"
    ]

    // MARK: Browsing versus translating (owner verdict, 2026-09-18)

    /// Whether a session opens in **extract mode** — the overlay drawing the
    /// recognized text itself, with no translation work running in the
    /// background — rather than in the translated view.
    ///
    /// True: extract mode is the owner's verdict's own default ("forget
    /// translation … extract and overlay text in realtime better"). A session
    /// that opens this way costs the device one recognition pass per tick and
    /// **no** brain, gate or cloud work at all until the elder asks for it —
    /// which is both the CPU the feature just spent a rework reclaiming and,
    /// more importantly, the correctness the owner is complaining about: with
    /// nothing translating in the background, there is no wrong translation on
    /// screen to look at.
    ///
    /// The elder asks in two ways, both of which are the *same* machinery: a
    /// tap on a block translates that block, and the chrome's translate-all
    /// control translates the scene. `false` ships the translated view.
    var extractModeDefault: Bool = false

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

    // MARK: Reading consensus (owner device report, 2026-09-19)

    // The owner's device log, after the block-identity rework: `regionCount`
    // constant, the overlay's identity and geometry stable — and
    // `regionSetHash` changing on **every** pass. The regions were no longer
    // churning; the readings were. A sign the OCR read as "START" on one pass
    // and "5TART" on the next was a different string every time, so the
    // change-only gate fired every time: a new translation key per pass, a new
    // digest per pass, and the elder's overlay swapping the words under them.
    //
    // These two keys are the string-level half of the same stability the
    // hysteresis above already gives identity and geometry. The stabiliser
    // holds the reading a region has *adopted* and lets an observation replace
    // it only when it has earned the place — which is what makes a still scene
    // a still screen, and a still scene's digest a constant the device log can
    // be checked against.
    //
    // Both keys are the shipped defaults' own escape hatches as well as
    // thresholds: `readingConsensusPasses = 1` and `readingConfidenceGain = 0`
    // each make a new reading adopt immediately, which is the behaviour this
    // feature had before the consensus existed.

    /// Consecutive passes a **new reading** of a region must be observed in
    /// before it replaces the reading the region carries.
    ///
    /// The unit is the same one the appearance hysteresis uses, and for the
    /// same reason: an OCR pass is a claim about a picture, and a claim that
    /// does not survive the next pass is a claim about the recognition rather
    /// than about the sign. Two consecutive passes is one pass of evidence
    /// that the first reading was wrong, at a cost of 0.5 s at the nominal
    /// cadence before the corrected words appear — a delay the elder spends
    /// looking at a *stable* reading, which is the trade the whole key makes.
    ///
    /// Below 2 there is no consensus to speak of: at 1 every observation is
    /// adopted on sight, which is exactly the per-pass string flicker the
    /// owner's log is made of.
    var readingConsensusPasses: Int = 2

    /// How much more confidence a new reading must carry than the one being
    /// held, to replace it **without** waiting out `readingConsensusPasses`.
    ///
    /// The persistence rule alone would make a genuine re-read of a corrected
    /// sign wait two passes even when the recogniser is emphatic; this is the
    /// half that lets an unmistakably better reading through at once. It is a
    /// *gain* and not a floor on purpose: what matters is not how sure the
    /// recogniser is in absolute terms — Vision's confidences are not
    /// comparable across scenes — but whether it is substantially surer than
    /// it was of the reading currently on screen.
    ///
    /// 0.15 is set where the two readings stop being a coin toss: a
    /// near-miss pair ("START" 0.62, "5TART" 0.55) never clears it however
    /// often it repeats, while a reading the recogniser has genuinely resolved
    /// ("START" 0.4 → "START" 0.9 the moment the camera settles) does.
    var readingConfidenceGain: Double = 0.15

    // MARK: Dispatch pacing (owner device report, 2026-09-19)

    // The same device log the consensus above was read out of, read for its
    // *timing* rather than its strings. A tick that finds a pending region
    // dispatches it, and a region the tier has not answered stays pending —
    // which is deliberate, and which on the device read as a `cache_miss` and
    // a fresh attempt on **every** pass, several per second for as long as the
    // sign stayed in frame. Each of those is a request the elder did not ask
    // for; each one that reaches the brain is a 1 GB generation started beside
    // the Whisper and camera stacks, and the brain's own idle-unload (5 s)
    // means the dispatch a second later loads that gigabyte again. The log
    // ends in memory-pressure events and the app dying, and the shape of it is
    // not "too much work" but "the same work, restarted".
    //
    // Two clocks pace it, both read against the pipeline's own injected clock
    // and both checked in the dispatch's prologue, before anything is claimed.
    // **Neither one drops a string.** A string held back is still pending and
    // still unclaimed, so the first tick that is allowed to dispatch carries
    // it — which is also what turns a burst of arrivals into one batch rather
    // than one request each. The consensus above is the other half of the same
    // fix: fewer reading changes are fewer strings to dispatch at all.
    //
    // The elder's own ask is not a pass. Extract mode's tap asks for one
    // region, once, and is not paced — a tap that did nothing because a
    // background dispatch happened 0.9 s earlier would be the mode failing at
    // its one job. A tap still moves both clocks, so the background work it
    // pre-empts waits behind it rather than racing it.

    /// Minimum seconds between two dispatches of pending strings.
    ///
    /// Sized against the OCR cadence rather than against politeness: the
    /// nominal pass is 0.25 s and the reduced still-scene cadence is 0.7 s, so
    /// before this key a still scene with an unanswerable string dispatched
    /// **six to fourteen times** per second-old sign. 1.5 s is a little over
    /// two passes at the reduced cadence — long enough that consecutive passes
    /// genuinely accumulate into one batch, short enough that a string which
    /// appears the moment the camera settles still leaves the device within
    /// the beat the elder reads as "it is translating". It is not a timeout:
    /// nothing is given up on when the interval passes, it is simply sent.
    var translationDispatchMinInterval: TimeInterval = 1.5

    /// Minimum seconds between two **brain generation attempts**.
    ///
    /// A generation is the one step measured in seconds of a 1 GB model
    /// resident and the one step whose cost a following dispatch re-pays in
    /// full. The device log's shape was one attempt per cycle against a 5 s
    /// idle-unload: the model loaded, generated, unloaded, and was loaded
    /// again for the next cycle, indefinitely. 8 s is comfortably longer than
    /// that unload and comfortably inside `brainTranslationTimeoutSeconds`, so a
    /// scene being read steadily produces roughly one generation per several
    /// seconds — and the strings that arrive inside the interval **wait for
    /// it** rather than skipping it. A string the brain has not been asked
    /// about is never handed to the cloud ahead of it: the cascade is the
    /// cascade (FR-LCT-008), so holding a string is the only honest way to
    /// hold the brain back.
    var brainAttemptMinInterval: TimeInterval = 8

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

    // MARK: Overlay presentation — the green highlight (owner spec, 2026-09-18)

    // The owner's own description of the look this section configuration-drives:
    // "The whole idea was to overlay the extracted OCR text over the text in
    // the picture, then translate once OCR is solid. Stabilise the extracted
    // text and stabilise the overlay. The bounding box can be TRANSPARENT GREEN
    // with DARK COLORED TEXT — text plus the transparent green overlay." The
    // grammar — the corner, the fill, the ink — is the token table's
    // (`DesignTokens.overlayHighlight`, `DesignTokens.textPrimary`); the three
    // numbers below are operational, because a device check on a dim kitchen or
    // a bright shopfront is exactly what would move them.

    /// How much of the picture the green wash lets through: `0.4` ⇒ the box is
    /// 40 % green and 60 % whatever the camera sees under it.
    ///
    /// The band this value has to stay in is the owner's ("transparent green …
    /// the green wash must not obscure the original text beneath it"): below
    /// ~0.25 the box stops reading as a highlight at all and the elder cannot
    /// tell which text the app has recognized, and above ~0.5 the wash starts
    /// to bury the printed text it is drawn over — which is precisely what the
    /// opaque panel this replaces did, and what the owner rejected.
    ///
    /// The value has a second job, and it is the one that is easy to miss:
    /// `DesignTokens.textPrimary` is drawn *inside* the wash, so the wash is the
    /// text's background. At 0.4 over a white page the composite is a light
    /// green that near-black type clears by a wide margin; a household that
    /// raises this key past 0.5 is trading the dark text's contrast for the
    /// picture's, and the token test that measures that pair is where the trade
    /// is recorded.
    var overlayHighlightOpacity: Double = 0.4

    /// The room between the detected text region and the green box's edge, in
    /// points — the owner's "small padding ~5pt".
    ///
    /// This is the *green box's* padding, not the pill's and not the panel's
    /// internal spacing: the box is the detected region plus this much on each
    /// side, so the elder sees the app's claim ("these words, here") as a band
    /// around the words rather than a box that clips them. Small on purpose —
    /// the box has to read as the text's own highlight, and a wide margin is the
    /// bubble floating over the picture the owner rejected on 2026-09-17.
    ///
    /// The placement honours it exactly: the drawn box is never smaller than
    /// the detected region grown by this much (bounded only by the box already
    /// proved clear of its neighbours, so two boxes still cannot stack), and the
    /// view insets the rows it draws by the same value — so the text sits
    /// *inside* the wash with this much air around it.
    var overlayHighlightPadding: CGFloat = 5

    /// How far the drawn box travels toward a newly measured rect on each
    /// update, as an exponential moving average factor: `0.3` ⇒ a box that has
    /// just been handed a new measurement moves 30 % of the remaining distance
    /// to it, and 30 % of what is left after that, and so on.
    ///
    /// This is the stabilisation the owner asked for by name ("stabilise the
    /// overlay"), and it is deliberately *in addition to* the geometry
    /// stickiness above rather than instead of it. The threshold answers "is
    /// this a move at all?" — sub-threshold jitter never becomes the box's
    /// target, so it is ignored outright. The EMA answers "how does the box
    /// travel to a move that is real?" — it glides, continuously, instead of
    /// stepping in threshold-sized jumps, which is what makes a slow drift a
    /// follow rather than a series of small hops.
    ///
    /// The value is a *rate*, and the update cadence is the recognition
    /// cadence, so 0.3 is roughly "two thirds of the way there in four passes"
    /// (≈1 s at the nominal cadence). Lower is calmer and lags the sign more;
    /// higher is more responsive and nearer to the old jump. `0` freezes the
    /// drawn box (it never adopts a new rect — the same behaviour as an
    /// infinite stickiness, spelled the other way); `1` disables the smoothing
    /// and snaps each adopted rect, which is the pre-rework behaviour.
    var overlayBoxLerpFactor: Double = 0.3

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
    /// Why more than one entry. `nmtEnNeQwen17bR4Q6` (round-4, 2026-09-21) is
    /// the head: the anti-transliteration fine-tune, and the first checkpoint
    /// that passes the **shipped** prompt's gate (S11) as well as the tier's
    /// raw-prompt + `json_schema` contract and the runtime safety probes.
    /// `nmtEnNeQwen17bR4Q5` is the round-4 Q5 the previous ship pinned, and it
    /// **fails that gate under the shipped prompt** — so it is demoted to a
    /// superseded, sideload-only alternate: a device that installed it during
    /// the round-4 trial keeps working on it, and nothing offers its download.
    /// `nmtEnNeQwen17bR4Q8` is the round-4 Q8, kept as the sideload-only
    /// quality ceiling (it takes the 3 GB weight band, so the warden refuses it
    /// on the standard class — see `ModelBudgetPolicyTests`). Then the
    /// round-3 pair (`...R3Q4`, `...R3Q5`) and the round-2b artifacts
    /// (`...R2bQ4`, `...R2bQ8`) for devices that installed them before this
    /// upgrade and keep working on them. The two entries
    /// after them are the pre-translation-model fallbacks — `intentQwen4BSlotCanon`
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
    /// [TRANSLATION-MODEL-ROW] (2026-09-18) This list only READS what is
    /// installed — it never starts a download, and neither does anything
    /// else in the app (the assistant-brain picker deliberately excludes the
    /// head, and `AIModelsSettingsView.managedRows` only appends entries
    /// that are already on disk). The install path is the AI-models screen's
    /// own row for the head, offered through
    /// `ModelCatalog.availableTranslationEntries`, whose Download stays
    /// offered even where the warden refuses the LOAD — so the artifact is
    /// present on the phones that can run it, and on a phone whose class
    /// verdict is what changes later.
    ///
    /// Note the head is STANDARD-class under `ModelBudgetPolicy`, where the
    /// round-2b Q8 was not: 1.1 GB takes the 1.7B weight band (700 MB
    /// overhead) → 1.81 GB live, which beside the class's 1.0 GB warm STT is
    /// inside the standard 3.2 GB budget, while the 1.83 GB Q8 took the 3B
    /// band (2.63 GB live) and was refused `requires_evicting_warm_stt` (see
    /// the catalog entries and `ModelBudgetPolicyTests`). That budget
    /// difference is half of why round 3 ships the small quant — the other
    /// half is that it no longer needs to gate anything. A device the warden
    /// still refuses falls to the cloud tier; that is the policy's call, not
    /// this list's.
    ///
    /// A follow-up may want this to follow the elder's brain selection
    /// (`AppCoordinator.resolvedBrainModelID`); that is a product decision,
    /// not a lookup to hide in here.
    var brainTranslationModelIDs: [ModelID] = [ModelCatalog.nmtEnNeQwen17bR4Q6,
                                              ModelCatalog.nmtEnNeQwen17bR4Q5,
                                              ModelCatalog.nmtEnNeQwen17bR4Q8,
                                              ModelCatalog.nmtEnNeQwen17bR3Q4,
                                              ModelCatalog.nmtEnNeQwen17bR3Q5,
                                              ModelCatalog.nmtEnNeQwen17bR2bQ4,
                                              ModelCatalog.nmtEnNeQwen17bR2bQ8,
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

    /// [DYNAMIC-TIMEOUT] (owner directive, 2026-09-20: "make the timeout
    /// dynamic — a default floor and the rest driven by the source text's
    /// length.") The flat 25 s bound refused the owner's medical-page
    /// batches (one string of 110–180 characters, ~0.2 s/char measured).
    /// The tier's effective bound is `base + perChar × characters`,
    /// clamped to the kill-safe maximum (the 45 s patient bound was
    /// jetsam-killed — the owner's 10:48 capture's signal 9).
    var brainTranslationBaseTimeoutSeconds: TimeInterval = 8
    var brainTranslationTimeoutPerCharacterSeconds: TimeInterval = 0.2
    var brainTranslationMaxTimeoutSeconds: TimeInterval = 30

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

    /// [PRESSURE-SAFE LOAD] (2026-09-19) How recently the kernel must have
    /// reported `.critical` for the tier to still refuse a load, in seconds.
    ///
    /// The headroom factor above is blind to the device: it compares the
    /// brain's declared non-pageable bytes against
    /// `os_proc_available_memory()`, which is the APP's own ceiling under its
    /// jetsam limit. A phone can be down to a few megabytes of *system-wide*
    /// free pages — the kernel jetsamming daemons in the background — while
    /// the app's own headroom still reads as generous, because nothing has
    /// been charged to the app yet. The 2026-09-19 device death is exactly
    /// that shape: the headroom check passed, a 1.03 GB Metal-offloaded load
    /// began, an encoder eviction followed, and the process was gone about
    /// five seconds later. This window is the second opinion, and it is the
    /// kernel's own.
    ///
    /// The window rather than the bare level because a `.critical` is a
    /// *moment*, not a state the app is told about afterwards: the kernel
    /// sends the next level when it sends it, and the minutes in between are
    /// exactly when the last `.critical` is still the most honest thing known
    /// about the device. It is sized against the cost of the thing it guards —
    /// a synchronous multi-GB page-in that takes seconds and cannot be
    /// stopped once started — so a load beginning inside this window would
    /// still be allocating while the kernel was reclaiming.
    ///
    /// The cost of being wrong in this direction is one batch answered by the
    /// next tier; the cost in the other direction is the whole app, which
    /// translates nothing at all. Deliberately not zero, and deliberately not
    /// minutes: 30 s is longer than the load it forbids and shorter than the
    /// gap between the elder's glances at a sign.
    var brainTranslationCriticalPressureWindowSeconds: TimeInterval = 30

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

    /// [WARDEN-TESTING-BYPASS] (2026-09-19) The owner asked to test the
    /// local translation model on device without the warden's reserve/admit
    /// gate in the way. While true, the tier's load skips the reservation
    /// entirely (residency still recorded); false restores the gated path.
    ///
    /// FLIPPED OFF (2026-09-20) by the owner's own directive ("the bypass
    /// stays until proven on device, then flips off"). The 02:35 capture
    /// proved the load path — loads proceed, generations answer, the device
    /// survives — and the 05:25 capture showed the bypass's failure mode:
    /// an unreserved ~1 GB page-in spiked the device mid-load (warden
    /// evicted the encoder, tier abandoned the load) because no victim was
    /// evicted BEFORE the page-in. The gated path evicts first. The Q4's
    /// live footprint (~1.5 GB) sits under the 3.2 GB class budget, so the
    /// reserve grants with evictions rather than denying `over_budget_alone`.
    var wardenBypassForTesting: Bool = false

    /// [DEBUG-LOG] (owner directive, 2026-09-20) Whether the feature's debug
    /// lane emits while the feature is being debugged: the OCR pass, each
    /// answered pair in the batch's own order, and the leg's timing.
    /// **Nominal default on, acted on only from a Debug build, and never a
    /// console write.**
    ///
    /// The owner asked to see "both source and target strings" while the
    /// feature was in device testing. The original spelling compiled the pairs
    /// into Release with no flag at all; the corrected spelling was a
    /// DEBUG-only, content-free count line — safe, but not the diagnostic the
    /// owner asked for. The owner's decision of 2026-09-20 resolves the
    /// conflict as the **sanitised debug lane**: the pairs and their timing do
    /// travel, through `LiveTranslateDebugLane` onto the sanitising
    /// observability bus, and `LogSanitiser` replaces every string with
    /// `[redacted]` at that choke point (`LogSanitiser.redactedKeys`). A
    /// capture therefore shows that a pair existed, in what order, with what
    /// timing — and the text never reaches a log surface, in any build.
    ///
    /// The shape that cannot ship remains impossible: NFR-LCT-006 forbids a
    /// recognized or translated string on a log surface in any configuration,
    /// the Release-log gate's `feature-content-print` rule is judged in Debug
    /// too, and the feature's own sources carry no console write at all
    /// (`LiveTranslateSourceHygieneTests`). The lane's readers and the lane
    /// type itself live under `#if DEBUG`, so no Release binary contains any
    /// part of this path.
    ///
    /// The count-only siblings on the bus are unchanged and still the wire
    /// format a shipped build emits — `brainTranslationBatch(
    /// resolvedCount:unresolvedCount:…)` carries the same batch's outcome
    /// without the lane.
    ///
    /// The value is persisted (see `LiveTranslateSettings`), so a debug
    /// session turns the lane off without a rebuild; Release reads it into the
    /// config and has nothing that acts on it.
    var translationDebugLoggingEnabled: Bool = true

    /// How long the warden's notice stays on screen before it takes itself
    /// down, in seconds (owner directive, 2026-09-19: "keep the user in the
    /// loop so they don't wonder about the silences").
    ///
    /// This is a **status**, not a modal: both moments it describes resolve on
    /// their own — a load finishes, a voice turn ends — so the surface must
    /// not depend on the elder dismissing it, and must never outlive the wait
    /// it is explaining. Four seconds is long enough to be read at the app's
    /// body size by someone who was not looking at the screen when it
    /// appeared, and short enough that a fast load does not leave a stale
    /// sentence behind the thing it announced.
    ///
    /// Read by the session model, which owns the dismissal timer; nothing in
    /// the tier or the view knows how long a notice lasts.
    var wardenNoticeDismissSeconds: TimeInterval = 4.0

    // MARK: Tier 2 — the master switch (owner directive, 2026-09-19)

    /// Whether the Gemini (cloud) tier may run **at all**, before anything
    /// else about it is asked.
    ///
    /// **False, and that is the owner's directive** (2026-09-19): the cloud
    /// tier does not cascade by default. An elder who has never touched this
    /// setting gets the on-device cascade — the curated dictionary, the
    /// persisted cache and the app's own installed Nepali brain — and nothing
    /// leaves the phone; the switch is what opts in, and it is the elder's
    /// (or the household's) to throw, deliberately, from the feature's
    /// Settings leaf.
    ///
    /// Three things this key is not:
    ///
    ///  - **It is not consent.** OD-13's consent record is still asked for and
    ///    still enforced on every attempt when this is on (AM-1): the switch
    ///    is a *policy* the household sets once, the record is the elder's
    ///    answer at the point of first cloud need, and either one alone never
    ///    sends anything. Turning the switch off does not withdraw a recorded
    ///    grant; turning it on does not create one.
    ///  - **It is not a budget.** The shipped `GeminiCostGovernor` soft daily
    ///    cap is unchanged and still applies (OD7) — this key is a gate,
    ///    never a second cap.
    ///  - **It is not a display preference.** It is the one user-facing
    ///    setting in this feature that *does* change what leaves the device,
    ///    so it is deliberately kept away from the FR-LCT-017 toggle's
    ///    display-only chrome (`AlwaysShowOriginalControl`) and drawn beside
    ///    the consent surface, where the elder is already thinking about
    ///    egress.
    ///
    /// A *default*, not the persisted state: `LiveTranslateSettings` owns the
    /// value the elder chose, and this is the nominal value an absent key
    /// reads as — exactly the split `alwaysShowOriginalDefault` uses.
    ///
    /// Cost is the second half of the reason. The cloud tier is the only part
    /// of this feature that spends money per scene, so a household that never
    /// opted in never pays for one: the failure mode this key removes is a
    /// feature that quietly bills a stranger's key because a sign had one
    /// word the dictionary did not.
    var geminiCloudEnabledDefault: Bool = false

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
