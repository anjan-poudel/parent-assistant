import CoreGraphics
import CoreVideo
import Foundation
import Vision
import simd

// C11 — `FrameAnchorEstimator` (owner device verdict, 2026-09-18, on the green
// overlay build: "the text is still shaky and jittery and unstable — back to
// the same old problem. STABILISE THE IMAGE FIRST, and secondly overlay text on
// top of the original text").
//
// The insight this file is: the overlay was already as steady as the machinery
// allows — the threshold hold and the box glide were fighting a *moving
// picture*. Water in a glass, not a shaking label. What the elder is looking at
// moves under their hand, and no amount of smoothing on the label fixes that:
// the *image itself* has to be held still, and then the (already stable) green
// box sits on the (now stable) printed words.
//
// What this file exists to make true:
//
//  - **The picture is held still, not the label.** The frame's content is
//    tracked against an anchor frame on device (`VNHomographicImage
//    RegistrationRequest`, Vision — no network, no model, no allocation per
//    call) and the *window the preview is drawn through* is panned by the
//    motion the hand did not mean. Composing the correction as a crop pan is
//    what keeps the feature's one-map rule: `LiveCameraPresentation` maps the
//    preview layer, the gestures and every placed box through the same crop, so
//    a box stays glued to the printed words it replaces *because* both readers
//    are given the same rectangle — there is no second transform to keep in
//    step.
//  - **Small motion is absorbed whole; intentional motion is followed.** Under
//    `frameStabDeadZone` of the frame the window tracks the content exactly, so
//    a hand tremor moves the window and leaves the *picture* still — the
//    printed words do not move on screen at all. Past the dead zone the window
//    follows the content with `frameStabFollowFactor`, so a deliberate re-frame
//    still happens, smoothly, and the window keeps up with where the elder has
//    pointed the camera instead of being dragged around by the tremor.
//  - **The correction is bounded, and the bounds are the frame's own edges.**
//    The window is inset by `frameStabMargin` and the correction may move it by
//    at most that much either way, so the picture can never expose the frame's
//    edge (a black sliver) and the correction is bounded by construction rather
//    than by a clamp that fights the law. The price is a small permanent
//    enlargement — the window shows `1 - 2·margin` of the frame — and it is the
//    price of having any room to correct into at all.
//  - **Honest under failure.** No anchor, a failed request, a frame in a format
//    this cannot read: the estimate is *held* (the picture keeps the window it
//    has) and never blanked, never zeroed, never invented. A measurement that is
//    not a hand's motion — a scene cut, a zoom, a lens change — re-bases the
//    anchor instead of being followed.
//  - **The recognition pass reads the raw frame.** This file's crop is the
//    *display's*; `CameraFrame.crop` (the elder's window) is still what the pass
//    hands Vision, and this stabilization is never applied to the pixels OCR
//    sees. What is stabilized is what the elder looks at, and what is read is
//    what the camera saw.
//  - **Pure where it can be, measured where it cannot.** The law
//    (`FrameStabilizationLaw`), the map (`FrameMotionMap`) and the composition
//    (`LiveCameraCrop.stabilized(by:)`) are value types with no camera, no
//    clock and no Vision in them, and the tests drive them directly. The one
//    impure seam is `FrameRegistration`, protocol-shaped so a test can hand in
//    an exact motion — and the shipped implementation is the only file that
//    speaks to Vision.
//
// **The sampling ceiling, and it is reported rather than hidden.** The
// registration runs at the *recognition* cadence (the gate in
// `LiveCameraSession` — nominally 4 Hz, reduced on a still scene), because a
// homography on every camera frame is a cost this feature does not have and
// cannot measure as free. A correction sampled at 4 Hz cancels the frame's
// steady drift and everything below about 1.5 Hz, gives partial cancellation
// between there and 2 Hz, and — this is the honest part — *does not* cancel a
// tremor above 2 Hz: a zero-order hold leaves `2A·sin(πf/f_s)` of the motion,
// which is the full motion at `f_s/2` and more than it above. This is a
// stabilizer for the *slow* band (the floaty drift and the framing creep that
// make small print hard to read on a phone) and a no-op for a fast shake. The
// cost of running it faster is measured (see `FrameAnchorEstimator.Cost`) so
// that "run it at the frame rate" is a decision with a number under it rather
// than a wish.

// MARK: - What the display is asked to do

/// The picture's own stabilization, as the display needs it: how far the window
/// the preview is drawn through has been panned, and how much room that window
/// has to be panned in.
///
/// Both numbers are **fractions of the frame** — the space `LiveCameraCrop`,
/// `NormalizedBox` and every placement rect are already in — so nothing here has
/// to know the container, the preview layer or the frame's pixels. A frame that
/// carries `.none` is a frame no stabilization was applied to: the display draws
/// the elder's window exactly as it always did, which is what a session with the
/// feature off, a frame that arrived before the first anchor, and every frame
/// ever delivered by a build before this one all say.
struct FrameStabilization: Equatable {

    /// Where the window has been moved to hold the content still, in frame
    /// fractions. `(0, 0)` is the elder's own window, unmoved.
    let offset: CGPoint

    /// How far the window has been inset — and therefore how far the offset may
    /// ever travel — in frame fractions. `0` is "no stabilization": nothing is
    /// inset, nothing may move, and the display is the plain window.
    let margin: Double

    /// The stabilization every caller that has none passes: no pan, no inset,
    /// the picture drawn exactly as the camera delivered it.
    static let none = FrameStabilization(offset: .zero, margin: 0)

    /// Whether this asks the display for anything at all.
    var isNone: Bool { self == .none }

    /// How far the offset may be from centre before the window would leave the
    /// frame. The inset and the travel are the same number by construction: a
    /// window inset by `margin` can be moved by exactly `margin` and no further
    /// without showing the frame's own edge.
    var travelLimit: Double { max(0, margin) }
}

extension LiveCameraCrop {

    /// The window the **display** is drawn through: this window, inset by the
    /// stabilization's margin and panned by its offset.
    ///
    /// The one place the correction becomes geometry, and deliberately an
    /// extension of the type both readers already map through — the preview
    /// layer's transform and the placement's `screenRect(for:...)` are functions
    /// of a crop, so giving both the same composed crop *is* the one-map rule.
    /// A crop whose inset would collapse it (a margin wider than the window
    /// allows, a degenerate zoom) is returned untouched: a display that cannot
    /// hold the stabilization is drawn as the elder's own window rather than as
    /// nothing.
    func stabilized(by stabilization: FrameStabilization) -> LiveCameraCrop {
        guard !stabilization.isNone else { return self }
        let margin = CGFloat(stabilization.margin)
        let inset = NormalizedBox(xMin: box.xMin + margin,
                                  yMin: box.yMin + margin,
                                  xMax: box.xMax - margin,
                                  yMax: box.yMax - margin)
        guard inset.xMax > inset.xMin, inset.yMax > inset.yMin else { return self }

        let travel = CGFloat(stabilization.travelLimit)
        let offset = CGPoint(x: min(travel, max(-travel, stabilization.offset.x)),
                             y: min(travel, max(-travel, stabilization.offset.y)))
        let moved = NormalizedBox(xMin: inset.xMin + offset.x,
                                  yMin: inset.yMin + offset.y,
                                  xMax: inset.xMax + offset.x,
                                  yMax: inset.yMax + offset.y)
        // The inset plus the clamp above already keep this inside the frame for
        // any window the zoom model produces; the guard is for a caller holding
        // a window this file never saw, and it refuses rather than draws a
        // window that has left the picture.
        guard moved.xMin >= -1e-9, moved.yMin >= -1e-9,
              moved.xMax <= 1 + 1e-9, moved.yMax <= 1 + 1e-9 else { return self }
        return LiveCameraCrop(box: moved)
    }
}

// MARK: - The policy

/// The stabilization's numbers, in this file's own vocabulary: what
/// `LiveTranslateConfig`'s `frameStab*` keys mean once they are geometry.
struct FrameStabilizationPolicy: Equatable {

    /// Whether the picture is stabilized at all. Off ⇒ every frame carries
    /// `.none` and the display is the plain window.
    let enabled: Bool

    /// The width of the dead zone, as a fraction of the frame: content motion
    /// under this is a hand tremor and is absorbed whole — the picture does not
    /// move on screen at all. Past it the window follows (see `followFactor`).
    let deadZone: Double

    /// How much of the way to the content's position the window travels per
    /// measurement once the dead zone is exceeded: `0.35` ⇒ a deliberate
    /// re-frame is followed over a few measurements, and the part of it that is
    /// not yet followed is what the elder sees the picture move by. `1` would
    /// follow instantly (no trace of the stabilization left for a deliberate
    /// move); very small values would let a slow pan spend the whole travel
    /// budget and leave the window pinned at the frame's edge.
    let followFactor: Double

    /// How far the window is inset, and therefore how far it may travel, in
    /// frame fractions. This is the correction's entire budget: a tremor of
    /// amplitude up to `margin` is absorbed completely, and a movement larger
    /// than it is followed (the window reaches the frame's edge and moves with
    /// the content from there).
    let margin: Double

    /// How far the content may be from the anchor — or how far the anchor's
    /// rect may have changed size — before the measurement is read as *not a
    /// hand's motion* (a scene cut, a lens change, a device zoom, a whip pan)
    /// and the anchor is re-based instead of followed.
    let rejectDelta: Double

    /// How long an anchor is kept before it is re-taken. An anchor is a
    /// reference image, and a reference that is older than this has drifted far
    /// enough from the current frame that the registration is measuring a
    /// difference the elder has long since moved past.
    let anchorSeconds: TimeInterval

    /// The long side of the small buffer the registration is run on. This is
    /// the whole cost knob: the registration's price is its pixels, and a
    /// registration does not need the recognition pass's resolution — it needs
    /// enough texture to find the same corner twice.
    let registrationSide: Int

    /// The widest dead zone and the widest window the law will honour: a
    /// quarter of the frame. A window wider than this would draw a third of the
    /// picture's own content nowhere at all, and a dead zone wider than it
    /// would swallow a deliberate re-frame whole.
    ///
    /// Written as a ratio rather than as its decimal spelling, because both
    /// spellings are already configured values (`ocrSampleInterval`,
    /// `translationMaxLengthRatio`), and `LiveTranslateSourceHygieneTests` —
    /// rightly — forbids a pipeline source from re-declaring one
    /// (NFR-LCT-011). The value itself is the one `frameStabMargin`'s own doc
    /// names as the point where the picture stops being the same picture held
    /// still.
    private static let widestFraction: Double = 0.5 / 2

    /// The policy a config asks for, with every value brought into the range
    /// this file can honour. A key outside its range is clamped rather than
    /// trusted: the law is total for every input, and a config that says
    /// "margin 3" (three frames wide) must not index the window off the
    /// picture.
    init(config: LiveTranslateConfig) {
        self.enabled = config.frameStabEnabled
        self.deadZone = min(Self.widestFraction, max(0, config.frameStabDeadZone))
        self.followFactor = min(1, max(0, config.frameStabFollowFactor))
        self.margin = min(Self.widestFraction, max(0, config.frameStabMargin))
        self.rejectDelta = min(1, max(0.01, config.frameStabRejectDelta))
        self.anchorSeconds = max(0.1, config.frameStabAnchorSeconds)
        self.registrationSide = min(512, max(32, config.frameStabRegistrationSide))
    }

    init(enabled: Bool = true,
         deadZone: Double,
         followFactor: Double,
         margin: Double,
         rejectDelta: Double = 0.2,
         anchorSeconds: TimeInterval = 2,
         registrationSide: Int = 256) {
        self.enabled = enabled
        self.deadZone = deadZone
        self.followFactor = followFactor
        self.margin = margin
        self.rejectDelta = rejectDelta
        self.anchorSeconds = anchorSeconds
        self.registrationSide = registrationSide
    }
}

// MARK: - The measurement

/// How the picture moved: where the content that was at one point is now, as a
/// projective map in **frame-normalized** coordinates (both components 0–1 of
/// the frame's own width and height — the space every box, crop and placement
/// rect in this feature is in).
///
/// A map rather than a displacement because a homography is what the
/// registration actually answers: the displacement of *one* point is what the
/// law needs, but the anchor's rect has to be carried across too (a zoom is a
/// size change, not a movement), and both come out of the same matrix.
struct FrameMotionMap: Equatable {

    /// The map in normalized coordinates: `(x, y, 1) → (x', y', w')`, with
    /// `(x'/w', y'/w')` the mapped point.
    let matrix: simd_double3x3

    init(matrix: simd_double3x3 = matrix_identity_double3x3) {
        self.matrix = matrix
    }

    /// The identity motion: nothing moved, which is what a registration that
    /// found nothing to move by is not allowed to claim (it answers `nil`
    /// instead — see `FrameRegistration`).
    static let identity = FrameMotionMap()

    /// A pure translation, which is what the translation-only fallback measures
    /// and what the tests drive the law with.
    static func translation(_ displacement: CGPoint) -> FrameMotionMap {
        FrameMotionMap(matrix: simd_double3x3(SIMD3(1, 0, 0),
                                              SIMD3(0, 1, 0),
                                              SIMD3(Double(displacement.x),
                                                    Double(displacement.y), 1)))
    }

    /// Where the content that was at `point` is now.
    func map(_ point: CGPoint) -> CGPoint { read(point) ?? point }

    /// Where the content that filled `rect` is now: the bounding box of the
    /// rect's four mapped corners. A projective map does not carry a rectangle
    /// to a rectangle, and the axis-aligned box that contains what it becomes is
    /// what the anchor bookkeeping is after — a centre to read the motion at,
    /// and a size to compare the frame's scale with.
    ///
    /// A map that cannot be read leaves the rect **exactly** where it was: a
    /// bounding box of four points that were not all read is not a rect, and the
    /// one thing this may never do is hand the bookkeeping a plausible-looking
    /// box in the wrong place. The corners are read before the box is built, so
    /// a degenerate map answers the rect itself — rebuilding the box from its
    /// corners would also round (`minX + width` is not `maxX` in binary), and a
    /// no-op that moves the rect by a few ulps is a no-op that drifts.
    func map(_ rect: CGRect) -> CGRect {
        var corners: [CGPoint] = []
        corners.reserveCapacity(4)
        for corner in [CGPoint(x: rect.minX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY)] {
            guard let mapped = read(corner) else { return rect }
            corners.append(mapped)
        }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              [minX, maxX, minY, maxY].allSatisfy(\.isFinite) else { return rect }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The map applied to one point, or `nil` when the map cannot be read *at
    /// that point* — a `NaN`, an infinity, a `w` of zero. One guard, in one
    /// place, for the point and the rect both.
    private func read(_ point: CGPoint) -> CGPoint? {
        let mapped = matrix * SIMD3(Double(point.x), Double(point.y), 1)
        guard mapped.x.isFinite, mapped.y.isFinite,
              mapped.z.isFinite, abs(mapped.z) > 1e-9 else { return nil }
        return CGPoint(x: mapped.x / mapped.z, y: mapped.y / mapped.z)
    }

    /// A matrix Vision measured in the **buffer's pixels**, read in frame
    /// fractions: `x_norm · pixelWidth` before the map, and the inverse after.
    ///
    /// The two spaces agree on their origin (both are top-left, both grow down
    /// the picture) and on their aspect (the registration buffer is a scaled
    /// copy of the frame, not a stretched one), so this is the whole of the
    /// conversion — and it is done here, once, rather than at every read.
    ///
    /// "Both grow down the picture" is the caller's side of the bargain: this
    /// function converts pixels to fractions, not conventions. A platform whose
    /// own space grows *up* the picture conjugates its matrix into this one
    /// before calling — see `VisionFrameRegistration.inTopDownPixels`.
    static func normalized(fromPixelMatrix matrix: simd_double3x3,
                           pixelSize: CGSize) -> FrameMotionMap {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .identity }
        let scale = simd_double3x3(SIMD3(Double(pixelSize.width), 0, 0),
                                   SIMD3(0, Double(pixelSize.height), 0),
                                   SIMD3(0, 0, 1))
        let inverse = simd_double3x3(SIMD3(1 / Double(pixelSize.width), 0, 0),
                                     SIMD3(0, 1 / Double(pixelSize.height), 0),
                                     SIMD3(0, 0, 1))
        return FrameMotionMap(matrix: inverse * matrix * scale)
    }
}

/// The one impure seam: how a motion is measured. The shipped implementation
/// speaks to Vision; a test hands in an exact motion, which is what makes the
/// law and the display testable without a camera and without a homography.
protocol FrameRegistration {
    /// The content's motion from `anchor` to `current`, both of which are
    /// registration-sized copies of the same frame dimensions — or `nil` when it
    /// cannot be measured, which the caller must read as "hold what you have",
    /// never as "nothing moved".
    func motion(from anchor: CVPixelBuffer, to current: CVPixelBuffer) -> FrameMotionMap?
}

// MARK: - The law

/// The correction's arithmetic, as pure functions: no camera, no clock, no
/// Vision, nothing to mock. Every rule the feature has about holding a picture
/// still is in this enum, and the estimator below is only the thing that feeds
/// it measurements.
enum FrameStabilizationLaw {

    /// Where the window is after one measurement of the content's motion.
    ///
    /// `residual` is the picture's own displacement on screen — how far the
    /// displayed content sits from where the anchor's display put it — and it is
    /// what decides between the law's two behaviours:
    ///
    ///  - **inside the dead zone: absorbed whole.** The window takes the
    ///    interval's motion entirely, so the picture does not move at all. A
    ///    tremor is therefore not *reduced*, it is cancelled: `+1 %` of tremor
    ///    moves the window `+1 %` and the printed words stay exactly where they
    ///    were.
    ///  - **past it: followed, smoothly.** The window travels
    ///    `followFactor` of the way toward the content's position (capped at the
    ///    travel the margin allows) instead of the whole interval, so a
    ///    deliberate movement is followed over a few measurements and its first
    ///    moments are the part the elder sees the picture move by. The residual
    ///    converges on the dead zone and stops there: a hand that has stopped
    ///    moving leaves the picture still, at the framing the movement asked
    ///    for.
    ///
    /// The two branches part company on what a *still hand* means, and it is
    /// the distinction the owner's verdict turns on:
    ///
    ///  - **inside the dead zone the window takes the interval whole**, so a
    ///    zero interval is exactly zero motion: the picture does not move at
    ///    all, and a hand that has stopped holding a still picture has a still
    ///    picture from that measurement on, not after a settling time.
    ///  - **past it the window keeps closing the residual** even when the
    ///    content has stopped, because the elder is *looking* at an unfinished
    ///    movement: the part that has not been followed yet is what they see the
    ///    picture travel by, and a glide that finished in one measurement would
    ///    be the jump this branch exists to avoid. It ends the same way —
    ///    the residual crosses into the dead zone and the window stops.
    static func offset(_ current: CGPoint,
                       interval: CGPoint,
                       cumulative: CGPoint,
                       residual: CGPoint,
                       policy: FrameStabilizationPolicy) -> CGPoint {
        let deadZone = CGFloat(policy.deadZone)
        let follow = CGFloat(policy.followFactor)
        let limit = CGFloat(policy.margin)
        let next = CGPoint(x: step(current: current.x, interval: interval.x,
                                   cumulative: cumulative.x, residual: residual.x,
                                   deadZone: deadZone, follow: follow, limit: limit),
                           y: step(current: current.y, interval: interval.y,
                                   cumulative: cumulative.y, residual: residual.y,
                                   deadZone: deadZone, follow: follow, limit: limit))
        return CGPoint(x: min(limit, max(-limit, next.x)),
                       y: min(limit, max(-limit, next.y)))
    }

    /// One axis of the law. Written per axis because a hand's tremor is not
    /// obliged to be diagonal: a motion that is inside the dead zone in one
    /// direction and past it in the other is absorbed in the first and followed
    /// in the second, which is what "the picture does not move" means for a
    /// mostly-vertical sway over a mostly-still hold.
    private static func step(current: CGFloat,
                             interval: CGFloat,
                             cumulative: CGFloat,
                             residual: CGFloat,
                             deadZone: CGFloat,
                             follow: CGFloat,
                             limit: CGFloat) -> CGFloat {
        guard current.isFinite, interval.isFinite,
              cumulative.isFinite, residual.isFinite else { return current }
        if abs(residual) <= deadZone {
            // The tremor, absorbed whole: the window takes the motion the
            // content just made, so the picture's position on screen — the
            // residual — does not change at all.
            return current + interval
        }
        // A deliberate movement, followed: the window travels a share of the
        // way to where the content now is (a share and not the whole interval,
        // so the movement is *seen*), and no further than the travel the frame
        // has room for.
        let target = min(limit, max(-limit, cumulative))
        return current + follow * (target - current)
    }

    /// The residual after the window has moved: the picture's displacement on
    /// screen, derived rather than accumulated, so no rounding can make the law
    /// believe a motion that is not there.
    static func residual(cumulative: CGPoint, offset: CGPoint, offsetAtAnchor: CGPoint) -> CGPoint {
        CGPoint(x: cumulative.x - (offset.x - offsetAtAnchor.x),
                y: cumulative.y - (offset.y - offsetAtAnchor.y))
    }
}

// MARK: - The estimator

/// Holds the anchor, drives the registration at the recognition cadence, and
/// answers the display with where to pan the window.
///
/// Mutable state, one writer: the session's frame tap. It is a value type with
/// no locking of its own — `LiveCameraSession` guards it, deliberately with a
/// lock of its **own** rather than the one the tap's other state uses, because
/// one of the calls it guards (`observe`) performs a Vision request and the
/// session's other lock is the one the consumer's pass-in-flight read and every
/// gesture write go through — and it is deliberately *total*: every path answers
/// a stabilization, and the paths that cannot measure answer with the one the
/// display already had.
struct FrameAnchorEstimator {

    /// What the registration cost, as exponential averages: the honest number
    /// under "run it faster". `prepSeconds` is the downscale-and-copy that fills
    /// the registration buffers, `registrationSeconds` is Vision's own time, and
    /// both are averages over the measurements *attempted* — an estimate this
    /// file held without asking Vision (before the first anchor, after a stale
    /// one, on a frame it cannot read) costs nothing and is not counted, while
    /// an attempt Vision declined was still paid for and is.
    struct Cost: Equatable {
        var samples: Int = 0
        var prepSeconds: Double = 0
        var registrationSeconds: Double = 0
        var totalSeconds: Double { prepSeconds + registrationSeconds }
    }

    let policy: FrameStabilizationPolicy
    private let registration: FrameRegistration
    private let clock: () -> TimeInterval

    /// The anchor: a registration-sized copy of the frame the elder's window was
    /// taken from, and when it was taken. Held for `anchorSeconds`.
    private var anchor: CVPixelBuffer?
    private var anchorSize: CGSize = .zero
    private var anchorTakenAt: TimeInterval?

    /// The rect of the current frame the anchored content occupies now, and the
    /// rect it occupied when the anchor was taken. Both in frame fractions; the
    /// difference between their centres is the content's motion since the
    /// anchor, and the ratio of their sizes is the scale it has taken on.
    private var trackedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var originRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The window's pan, and its value when the anchor was taken.
    private(set) var offset: CGPoint = .zero
    private var offsetAtAnchor: CGPoint = .zero

    /// The two small buffers the registration runs on, and the pool they come
    /// from — kept between measurements so the 4 Hz cadence costs no allocation.
    private var scratch = RegistrationScratch()

    private(set) var cost = Cost()
    /// Consecutive measurements the registration could not make. Exposed for
    /// the tests that pin "a failure is a hold, not a reset" and for a caller
    /// that wants to know the estimate is running blind.
    private(set) var unavailableMeasurements = 0

    init(policy: FrameStabilizationPolicy,
         registration: FrameRegistration = VisionFrameRegistration(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.policy = policy
        self.registration = registration
        self.clock = clock
    }

    /// Forgets the anchor and the correction: a new capture, a new zoom, a new
    /// scene. The next measurement takes a fresh anchor and the window starts
    /// from the elder's own framing, which is the honest answer for a session
    /// that has just been handed a different picture.
    ///
    /// The scratch buffers go too, not just the anchor: the two are copies of
    /// the picture, and a session that has stopped (or been interrupted, or
    /// re-framed) retains none of it. Re-taking an anchor re-allocates them,
    /// which is the trade this feature already made when it chose to keep the
    /// buffers across measurements at all — two allocations per gesture, none
    /// per frame.
    mutating func reset() {
        anchor = nil
        anchorSize = .zero
        anchorTakenAt = nil
        trackedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        originRect = trackedRect
        offset = .zero
        offsetAtAnchor = .zero
        unavailableMeasurements = 0
        scratch.close()
    }

    /// Observes one frame — the **raw** one, at the cadence the session chose —
    /// and answers what the display should do about it.
    ///
    /// Total by construction: every guard below returns a usable stabilization,
    /// because the one thing this feature may never do is blank the picture it
    /// is trying to hold still.
    mutating func observe(pixelBuffer: CVPixelBuffer,
                          pixelSize: CGSize,
                          timestamp: TimeInterval) -> FrameStabilization {
        guard policy.enabled, policy.margin > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return .none }
        let held = stabilization

        let started = clock()
        guard let current = scratch.fill(from: pixelBuffer, side: policy.registrationSide) else {
            scratch.close()
            return held
        }

        guard let anchor, anchorSize == pixelSize, let takenAt = anchorTakenAt else {
            adopt(current: current, size: pixelSize, timestamp: timestamp)
            return held
        }
        if timestamp - takenAt >= policy.anchorSeconds {
            adopt(current: current, size: pixelSize, timestamp: timestamp)
            return held
        }

        let registrationStarted = clock()
        let measured = registration.motion(from: anchor, to: current)
        let measuredSeconds = clock() - registrationStarted
        cost.samples += 1
        cost.registrationSeconds += (measuredSeconds - cost.registrationSeconds) / Double(cost.samples)
        cost.prepSeconds += ((registrationStarted - started) - cost.prepSeconds) / Double(cost.samples)

        guard let motion = measured else {
            // Vision could not measure this pair (a frozen frame, a scene with
            // nothing to register, a format it declined). The window stays
            // where it is: an estimate that is not being made must not move the
            // picture.
            unavailableMeasurements += 1
            return held
        }
        unavailableMeasurements = 0

        let mapped = motion.map(trackedRect)
        let scale = scale(of: mapped, from: trackedRect)
        let cumulative = CGPoint(x: mapped.midX - originRect.midX,
                                 y: mapped.midY - originRect.midY)
        let interval = CGPoint(x: mapped.midX - trackedRect.midX,
                               y: mapped.midY - trackedRect.midY)

        // A measurement this far from the anchor is not a hand's motion: a cut,
        // a lens change, a device zoom, a whip pan. The anchor goes, the window
        // stays — the picture must not jump for a measurement that describes a
        // different picture than the one being displayed.
        guard hypot(Double(cumulative.x), Double(cumulative.y)) <= policy.rejectDelta,
              abs(scale - 1) <= policy.rejectDelta else {
            adopt(current: current, size: pixelSize, timestamp: timestamp)
            return held
        }

        trackedRect = mapped
        let residual = FrameStabilizationLaw.residual(cumulative: cumulative,
                                                      offset: offset,
                                                      offsetAtAnchor: offsetAtAnchor)
        offset = FrameStabilizationLaw.offset(offset,
                                              interval: interval,
                                              cumulative: cumulative,
                                              residual: residual,
                                              policy: policy)
        return stabilization
    }

    /// The anchor's rect, in frame fractions: where the content the anchor was
    /// taken from sits in the current frame. `nil` before the first frame.
    var anchorRect: CGRect? {
        guard let anchorTakenAt, anchorSize != .zero, anchorTakenAt.isFinite else { return nil }
        return trackedRect
    }

    /// What the display is asked for right now.
    var stabilization: FrameStabilization {
        FrameStabilization(offset: offset, margin: policy.margin)
    }

    // MARK: The anchor

    /// Takes the frame just measured as the new reference. The **window does
    /// not move**: re-basing an anchor is a statement about which frame the next
    /// measurement is against, and a picture that jumped every time the
    /// reference was refreshed would be the very instability this file exists to
    /// remove.
    private mutating func adopt(current: CVPixelBuffer, size: CGSize, timestamp: TimeInterval) {
        anchor = current
        anchorSize = size
        anchorTakenAt = timestamp
        trackedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        originRect = trackedRect
        offsetAtAnchor = offset
        // The two buffers are swapped rather than copied: the frame that was
        // just filled is the anchor, and the next measurement fills the other.
        scratch.swap()
    }

    /// The frame's scale change between two rects: the mean of the two axes'
    /// ratios, so a map that is a pure translation answers exactly 1 and a map
    /// that is a zoom answers what a zoom is.
    private func scale(of mapped: CGRect, from rect: CGRect) -> Double {
        guard rect.width > 0, rect.height > 0,
              mapped.width.isFinite, mapped.height.isFinite else { return 1 }
        let horizontal = Double(mapped.width / rect.width)
        let vertical = Double(mapped.height / rect.height)
        return (horizontal + vertical) / 2
    }
}

// MARK: - Vision

/// The shipped measurement: Vision's image registration, on device, on two
/// small copies of the frame.
///
/// The ladder is the honest one the design asks for. `VNHomographicImage
/// RegistrationRequest` first — it is the measurement that sees the whole
/// picture (a translation *and* the scale a zoom puts on it) — and when it
/// cannot answer, `VNTranslationalImageRegistrationRequest`, which is the same
/// idea with the one degree of freedom a hand's tremor actually spends most of
/// its amplitude on. When neither answers, `nil`: a refusal, handed up as a
/// hold rather than as a zero.
///
/// The request's own semantics, as `Vision.framework` states them: the targeted
/// image is the *floating* one, and the transform it produces morphs the
/// floating image onto the reference — so the anchor is the targeted image and
/// the current frame is the handler's, and the matrix reads `anchor → current`.
///
/// **Its conventions, measured rather than assumed.** Both of Vision's
/// registration transforms are in the image's own **pixel** units — an 8 px
/// move of a 256 px buffer answers `tx = 8.0`, not `0.031` — and its **y axis
/// points up the picture**, while this feature's frame fractions grow *down* it
/// (Vision's observation space has its origin at the lower left, as every other
/// Vision rectangle does). The x axis needs no help; the y axis is flipped
/// about the picture's own middle by `inTopDownPixels` before the matrix is
/// handed on. Getting that wrong is not a subtle offset — the vertical half of
/// the correction would push the picture the way the hand was already pushing
/// it, *doubling* the vertical tremor while the horizontal half cancelled it,
/// which is worse than no stabilization at all and is exactly the complaint the
/// owner made. `FrameAnchorEstimatorTests` pins both the units and the
/// direction against synthetic shifts.
final class VisionFrameRegistration: FrameRegistration {

    /// Whether the platform answered a homography on the last measurement. Not
    /// policy — a fact the tests pin and the session's log can carry.
    private(set) var lastMeasurementWasProjective = false

    func motion(from anchor: CVPixelBuffer, to current: CVPixelBuffer) -> FrameMotionMap? {
        let size = CGSize(width: CVPixelBufferGetWidth(anchor),
                          height: CVPixelBufferGetHeight(anchor))
        guard CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(anchor),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(anchor) else {
            lastMeasurementWasProjective = false
            return nil
        }

        if let warp = warp(from: anchor, to: current) {
            lastMeasurementWasProjective = true
            let flipped = Self.inTopDownPixels(warp, height: Double(size.height))
            return FrameMotionMap.normalized(fromPixelMatrix: flipped, pixelSize: size)
        }
        lastMeasurementWasProjective = false
        guard let translation = translation(from: anchor, to: current) else { return nil }
        let matrix = simd_double3x3(columns: (SIMD3<Double>(Double(translation.a), Double(translation.b), 0),
                                              SIMD3<Double>(Double(translation.c), Double(translation.d), 0),
                                              SIMD3<Double>(Double(translation.tx), Double(translation.ty), 1)))
        let flipped = Self.inTopDownPixels(matrix, height: Double(size.height))
        return FrameMotionMap.normalized(fromPixelMatrix: flipped, pixelSize: size)
    }

    /// Vision's pixel matrix, y up, read as the picture's pixels, y down: the
    /// same point in two conventions, conjugated about the middle of the
    /// picture. `F` is its own inverse (`F·F` is the identity), so this is the
    /// whole of the conversion both ways.
    private static func inTopDownPixels(_ matrix: simd_double3x3, height: Double) -> simd_double3x3 {
        // As rows, the flip is `(x, y, 1) → (x, H − y, 1)`; as columns — which
        // is how a simd matrix is written out — the height belongs in the last
        // *column*, not the second. Put it in the second and the matrix's w
        // becomes `H·y + 1`, which does not fail loudly: it scales every mapped
        // point down by two orders of magnitude and answers a motion of
        // ~1e-5 for a shift of 8 px.
        let flip = simd_double3x3(columns: (SIMD3<Double>(1, 0, 0),
                                            SIMD3<Double>(0, -1, 0),
                                            SIMD3<Double>(0, height, 1)))
        return flip * matrix * flip
    }

    private func warp(from anchor: CVPixelBuffer, to current: CVPixelBuffer) -> simd_double3x3? {
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: anchor, options: [:])
        let handler = VNImageRequestHandler(cvPixelBuffer: current, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        // Columns one at a time: written as one nested expression, this
        // conversion is enough to make the type checker give up on the file.
        let warp = observation.warpTransform
        let first = SIMD3<Double>(Double(warp.columns.0.x), Double(warp.columns.0.y), Double(warp.columns.0.z))
        let second = SIMD3<Double>(Double(warp.columns.1.x), Double(warp.columns.1.y), Double(warp.columns.1.z))
        let third = SIMD3<Double>(Double(warp.columns.2.x), Double(warp.columns.2.y), Double(warp.columns.2.z))
        return simd_double3x3(first, second, third)
    }

    private func translation(from anchor: CVPixelBuffer, to current: CVPixelBuffer) -> CGAffineTransform? {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: anchor, options: [:])
        let handler = VNImageRequestHandler(cvPixelBuffer: current, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let transform = observation.alignmentTransform
        return transform.isIdentity ? nil : transform
    }
}

// MARK: - The buffers

/// The two small copies a registration runs on, and the one copy that fills
/// them.
///
/// Deliberately not the frame itself: a registration's cost is its pixels (and
/// a homography on a 1280 × 720 frame is a cost this feature's budget does not
/// have at 4 Hz), while what a registration needs is not resolution but
/// texture — the same corner found twice. `registrationSide` is that trade, and
/// it is the only knob on the cost.
private struct RegistrationScratch {

    /// The buffer the current frame is copied into, and the one the anchor
    /// lives in. Swapped rather than copied when an anchor is taken.
    private var current: CVPixelBuffer?
    private var anchor: CVPixelBuffer?
    private var size: CGSize = .zero

    /// Copies `source` into this scratch's current buffer, at
    /// `registrationSide`'s scale, and returns it. `nil` — never a bad buffer —
    /// when the picture cannot be read: a frame in a format this does not know,
    /// a buffer the platform will not lock, a size the scale would collapse.
    mutating func fill(from source: CVPixelBuffer, side: Int) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }

        let long = Double(max(sourceWidth, sourceHeight))
        let scale = min(1, Double(side) / long)
        let width = max(4, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(4, Int((Double(sourceHeight) * scale).rounded()))
        let wanted = CGSize(width: width, height: height)
        if size != wanted || current == nil || anchor == nil {
            guard let fresh = Self.make(width: width, height: height) else { return nil }
            guard let freshAnchor = Self.make(width: width, height: height) else { return nil }
            current = fresh
            anchor = freshAnchor
            size = wanted
        }
        guard let destination = current else { return nil }
        guard Self.copy(from: source, to: destination) else { return nil }
        return destination
    }

    /// Makes the buffer just filled this scratch's anchor.
    mutating func swap() {
        let filled = current
        current = anchor
        anchor = filled
    }

    /// Throws the buffers away: a stopped session holds no copy of the picture
    /// the elder has left.
    mutating func close() {
        current = nil
        anchor = nil
        size = .zero
    }

    /// A 32BGRA buffer Vision can hand to a texture cache, which is what keeps
    /// the registration off the CPU: an IOSurface-backed pixel buffer is one the
    /// GPU can sample without a copy.
    private static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey as String: false,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: false,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// The downscale: one sample per destination pixel, nearest neighbour. A
    /// registration measures *motion*, and a nearest-neighbour reduction keeps
    /// the frame's own edges where they were — an averaged reduction would
    /// soften exactly the corner the homography is looking for.
    private static func copy(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let sourceRow = CVPixelBufferGetBytesPerRow(source)
        let width = CVPixelBufferGetWidth(destination)
        let height = CVPixelBufferGetHeight(destination)
        let destinationRow = CVPixelBufferGetBytesPerRow(destination)
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else { return false }

        let from = sourceBase.assumingMemoryBound(to: UInt8.self)
        let into = destinationBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, y * sourceHeight / height)
            let sourceLine = from + sourceY * sourceRow
            let destinationLine = into + y * destinationRow
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, x * sourceWidth / width)
                let pixel = sourceLine + sourceX * 4
                let target = destinationLine + x * 4
                target[0] = pixel[0]
                target[1] = pixel[1]
                target[2] = pixel[2]
                target[3] = 255
            }
        }
        return true
    }
}
