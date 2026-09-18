import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import XCTest
import simd
@testable import ElderlyAssistant

/// C11 — the picture's own stabilization (owner device verdict, 2026-09-18, on
/// the green-overlay build: *"the text is still shaky and jittery and unstable —
/// back to the same old problem. STABILISE THE IMAGE FIRST, and secondly overlay
/// text on top of the original text"*).
///
/// The overlay was already as steady as smoothing allows; it was the *picture*
/// that moved. This suite is the three claims that make the fix a fact rather
/// than a hope, and each of them is one section below:
///
///  - **the law holds a picture still** — a motion inside the dead zone is
///    absorbed whole, so the printed words do not move on the glass at all; a
///    deliberate movement is followed smoothly until the picture has caught up
///    with where the elder pointed; and the correction is bounded by the frame's
///    own edges, so it can never expose a black sliver;
///  - **the correction and the boxes are one map** — the window the preview is
///    drawn through and the window the placement maps through are the *same*
///    value (`LiveCameraCrop.stabilized(by:)`), so a region's green box is drawn
///    on the pixels its words occupy. The test that says so is arithmetic: the
///    box lands in the rect it was in when the anchor's display was drawn;
///  - **failure is honest** — a registration that cannot measure holds the
///    window it has (never a reset, never a blank), and a measurement that is not
///    a hand's motion re-bases the anchor without moving the picture.
///
/// The last section runs the *shipped* Vision registration on two synthetic
/// frames and prints what it costs, because "run the registration at the frame
/// rate" is a decision that needs a number under it — and because the sign
/// convention of the platform's matrix is the one fact this feature's arithmetic
/// cannot survive getting wrong.
final class FrameAnchorEstimatorTests: XCTestCase {

    /// A phone-shaped portrait container and a camera-shaped landscape frame:
    /// the combination the live overlay actually draws into, so the point
    /// figures quoted in the comments below are the ones on the glass.
    private let container = CGSize(width: 390, height: 844)
    private let frame = CGSize(width: 1920, height: 1080)

    // MARK: - The law

    /// The law's own numbers for a test that is about the law: a wide margin so
    /// the travel cap is not what is being measured, and an anchor that is old
    /// only on the clock the test drives.
    private func lawPolicy(deadZone: Double = 0.01,
                           followFactor: Double = 0.35,
                           margin: Double = 0.2) -> FrameStabilizationPolicy {
        FrameStabilizationPolicy(deadZone: deadZone, followFactor: followFactor,
                                 margin: margin, rejectDelta: 0.2, anchorSeconds: 10,
                                 registrationSide: 64)
    }

    /// One measurement of a content motion that happened in a single step, from
    /// a window at rest: what the window did, and where the picture ended up on
    /// the glass relative to the anchor's display.
    private func lawStep(deadZone: Double,
                         motion: Double,
                         followFactor: Double = 0.35,
                         margin: Double = 0.2)
        -> (offset: CGPoint, onScreen: CGFloat) {
        let policy = lawPolicy(deadZone: deadZone, followFactor: followFactor, margin: margin)
        let cumulative = CGPoint(x: motion, y: 0)
        let residual = FrameStabilizationLaw.residual(cumulative: cumulative, offset: .zero,
                                                      offsetAtAnchor: .zero)
        let offset = FrameStabilizationLaw.offset(.zero, interval: cumulative,
                                                  cumulative: cumulative, residual: residual,
                                                  policy: policy)
        let after = FrameStabilizationLaw.residual(cumulative: cumulative, offset: offset,
                                                   offsetAtAnchor: .zero)
        return (offset, after.x)
    }

    /// Runs the law over a list of content positions — frame fractions relative
    /// to the anchor — exactly as the estimator feeds it: one measurement per
    /// position, the interval being what the content did since the previous one.
    private func runLaw(positions: [CGFloat],
                        policy: FrameStabilizationPolicy) -> [(offset: CGPoint, onScreen: CGFloat)] {
        var offset = CGPoint.zero
        var previous: CGFloat = 0
        var steps: [(offset: CGPoint, onScreen: CGFloat)] = []
        for position in positions {
            let cumulative = CGPoint(x: position, y: 0)
            let interval = CGPoint(x: position - previous, y: 0)
            let residual = FrameStabilizationLaw.residual(cumulative: cumulative, offset: offset,
                                                          offsetAtAnchor: .zero)
            offset = FrameStabilizationLaw.offset(offset, interval: interval, cumulative: cumulative,
                                                  residual: residual, policy: policy)
            steps.append((offset, cumulative.x - offset.x))
            previous = position
        }
        return steps
    }

    func testATremorInsideTheDeadZoneIsAbsorbedWholeSoThePrintedWordsDoNotMove() {
        // A hand holding the phone still: the drift of a tremor moves the
        // content in +x and back, in steps well inside the dead zone. What the
        // elder must see is a picture that does not move — not a reduced
        // movement, no movement — while the window does all of the travelling.
        let tremor: [CGFloat] = [0.006, 0.002, 0.005, 0.0, 0.004]

        let steps = runLaw(positions: tremor, policy: lawPolicy())

        for (index, step) in steps.enumerated() {
            XCTAssertEqual(step.onScreen, 0, accuracy: 1e-12,
                           "measurement \(index): the words moved on the glass, which is the whole complaint")
            XCTAssertEqual(step.offset.x, tremor[index], accuracy: 1e-12,
                           "measurement \(index): the window took the whole of the motion, which is what cancels it")
        }
        XCTAssertGreaterThan(tremor.map(abs).max()! * CGFloat(container.width), 2,
                             "the tremor this absorbs is over 2 pt on the glass: not a rounding artifact")
    }

    func testADeliberateMovementIsFollowedSmoothlyRatherThanJumped() {
        // The elder re-frames: the phone moves 8 % of the frame to the right, in
        // one step, and stops there. The window takes a share of the way per
        // measurement, so the movement is *seen* — the part that has not been
        // followed yet is what the elder watches the picture travel by — and it
        // ends where the elder pointed.
        let policy = lawPolicy()
        let cumulative = CGPoint(x: 0.08, y: 0)
        var offset = CGPoint.zero
        var offsets: [CGPoint] = []
        var onScreen: [CGFloat] = []

        for index in 0..<12 {
            // The hand moves once and then holds still; the estimator's interval
            // is the content's motion since the *last* measurement, so every
            // measurement after the first has a zero interval.
            let interval = CGPoint(x: index == 0 ? 0.08 : 0, y: 0)
            let residual = FrameStabilizationLaw.residual(cumulative: cumulative, offset: offset,
                                                          offsetAtAnchor: .zero)
            offset = FrameStabilizationLaw.offset(offset, interval: interval, cumulative: cumulative,
                                                  residual: residual, policy: policy)
            let after = FrameStabilizationLaw.residual(cumulative: cumulative, offset: offset,
                                                       offsetAtAnchor: .zero)
            offsets.append(offset)
            onScreen.append(after.x)
        }

        XCTAssertEqual(offsets[0].x, 0.028, accuracy: 1e-12,
                       "one measurement is a share of the movement (0.35 × 0.08), never the whole of it")
        XCTAssertGreaterThan(onScreen[0], policy.deadZone,
                             "and the elder sees the picture move by the part that is not yet followed")
        XCTAssertTrue(zip(onScreen, onScreen.dropFirst()).allSatisfy { $0 >= $1 },
                      "the residual never grows: the pan reads as a pan and never as a bounce")
        XCTAssertGreaterThan(onScreen[0] - onScreen.last!, 0.04,
                             "and it shrinks by much more than an epsilon on the way to rest")
        XCTAssertTrue(offsets.allSatisfy { $0.x <= cumulative.x + 1e-12 },
                      "the window closes the gap from behind and never overshoots")
        XCTAssertEqual(Array(offsets.suffix(4)), Array(repeating: offsets.last!, count: 4),
                       "a hand that has stopped leaves the picture still: the law comes to rest, it does not creep")
        XCTAssertLessThanOrEqual(onScreen.last!, policy.deadZone,
                                 "and it rests inside the dead zone, so any further tremor is absorbed whole")
    }

    func testTheDeadZoneBoundaryIsInsideTheZoneAndOneHairPastItIsNot() {
        // The comparison is `<=`, and the boundary is worth pinning: it decides
        // which side of the owner's complaint a 1 % motion falls on. A motion
        // exactly as wide as the dead zone is a tremor (absorbed whole); the law
        // flips to following at the first measurement past it.
        let atBoundary = lawStep(deadZone: 0.02, motion: 0.02)
        XCTAssertEqual(atBoundary.offset.x, 0.02, accuracy: 1e-12,
                       "the boundary is inside the zone: absorbed whole")
        XCTAssertEqual(atBoundary.onScreen, 0, accuracy: 1e-12)

        let pastBoundary = lawStep(deadZone: 0.019, motion: 0.02)
        XCTAssertEqual(pastBoundary.offset.x, 0.35 * 0.02, accuracy: 1e-12,
                       "one hair past it: followed, by a share of the way")
        XCTAssertGreaterThan(pastBoundary.onScreen, 0,
                             "and the picture moves by what has not been followed yet")
    }

    func testASwayInsideTheZoneOneWayIsAbsorbedWhileTheWayPastItIsFollowed() {
        // A hand is not obliged to shake diagonally. A mostly-horizontal
        // re-frame with a little vertical sway is followed in x and absorbed
        // whole in y — one axis at a time. A law written on the *length* of the
        // motion would follow both, and the vertical jitter would reach the
        // glass.
        let policy = lawPolicy()
        let cumulative = CGPoint(x: 0.09, y: 0.004)
        let residual = FrameStabilizationLaw.residual(cumulative: cumulative, offset: .zero,
                                                      offsetAtAnchor: .zero)

        let offset = FrameStabilizationLaw.offset(.zero, interval: cumulative, cumulative: cumulative,
                                                  residual: residual, policy: policy)

        XCTAssertEqual(offset.x, 0.35 * 0.09, accuracy: 1e-12, "past the dead zone: followed")
        XCTAssertEqual(offset.y, 0.004, accuracy: 1e-12, "inside it: absorbed whole")
    }

    func testTheWindowStopsAtTheEdgeTheMarginBoughtRatherThanFollowingPastIt() {
        // A whip pan a quarter of a frame wide, against a window that owns 5 %.
        // The window travels its whole budget and stops: the picture moves for
        // the rest of the motion, and that is what "the correction is bounded by
        // the frame's own edges" costs. The alternative is a black sliver at the
        // edge of the picture, which is the one failure the owner would see
        // instantly.
        let policy = lawPolicy(followFactor: 1, margin: 0.05)

        let whip = lawStep(deadZone: 0.01, motion: 0.25, followFactor: 1, margin: 0.05)
        XCTAssertEqual(whip.offset.x, 0.05, accuracy: 1e-12, "the window travels its whole budget")
        XCTAssertEqual(whip.onScreen, 0.2, accuracy: 1e-12, "and the picture takes the rest of the motion")

        // No input can take it further: the travel is the clamp as well as the
        // target the follow branch aims at.
        let beyond = FrameStabilizationLaw.offset(CGPoint(x: 0.05, y: 0),
                                                  interval: CGPoint(x: 0.2, y: 0),
                                                  cumulative: CGPoint(x: 0.45, y: 0),
                                                  residual: CGPoint(x: 0.4, y: 0),
                                                  policy: policy)
        XCTAssertEqual(beyond.x, 0.05, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(beyond.x, policy.margin)
    }

    func testAMeasurementThatIsNotANumberLeavesThatAxisWhereItIs() {
        // A degenerate registration or a broken matrix must not be able to move
        // the picture — and the law is **per axis**, because a hand is not
        // obliged to shake diagonally. So an axis that cannot be read is left
        // exactly where it is, while the other axis (a perfectly good
        // measurement) is free to do its work. Both halves are the claim: a
        // `NaN` that reached the offset would blank or displace the preview, and
        // a `NaN` that spread into a *neighbouring* axis's decision would take
        // the correction offline for a measurement that was only half broken.
        let current = CGPoint(x: 0.004, y: -0.002)
        let interval = CGPoint(x: 0.05, y: 0.05)

        let xBroken = FrameStabilizationLaw.offset(current, interval: interval,
                                                   cumulative: CGPoint(x: CGFloat.nan, y: 0),
                                                   residual: CGPoint(x: CGFloat.nan, y: 0),
                                                   policy: lawPolicy())
        XCTAssertEqual(xBroken.x, current.x, "the axis that cannot be read does not move")
        XCTAssertEqual(xBroken.y, current.y + interval.y, accuracy: 1e-12,
                       "and the axis that can be read still absorbs its tremor")

        let yBroken = FrameStabilizationLaw.offset(current, interval: interval,
                                                   cumulative: CGPoint(x: 0, y: CGFloat.infinity),
                                                   residual: CGPoint(x: 0, y: CGFloat.infinity),
                                                   policy: lawPolicy())
        XCTAssertEqual(yBroken.y, current.y, "the same the other way round")
        XCTAssertEqual(yBroken.x, current.x + interval.x, accuracy: 1e-12)

        let bothBroken = FrameStabilizationLaw.offset(current, interval: interval,
                                                      cumulative: CGPoint(x: CGFloat.nan,
                                                                          y: CGFloat.nan),
                                                      residual: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                                      policy: lawPolicy())
        XCTAssertEqual(bothBroken, current, "a measurement the law cannot read at all does not move the window")
    }

    func testThePicturesDisplacementIsDerivedFromTheWindowAndTheAnchor() {
        // The residual is the picture's own displacement on the glass: what the
        // content did, less what the window has done *since the anchor was
        // taken*. Derived rather than accumulated, so no rounding can make the
        // law believe a motion that is not there.
        let residual = FrameStabilizationLaw.residual(cumulative: CGPoint(x: 0.03, y: -0.01),
                                                      offset: CGPoint(x: 0.01, y: 0.004),
                                                      offsetAtAnchor: CGPoint(x: 0.004, y: 0.004))

        XCTAssertEqual(residual.x, 0.024, accuracy: 1e-12, "0.03 − (0.01 − 0.004)")
        XCTAssertEqual(residual.y, -0.01, accuracy: 1e-12, "−0.01 − (0.004 − 0.004)")
    }

    // MARK: - The window the picture is drawn through

    func testTheIdentityStabilizationDrawsTheEldersOwnWindow() {
        XCTAssertTrue(FrameStabilization.none.isNone)
        XCTAssertEqual(FrameStabilization.none.offset, .zero)
        XCTAssertEqual(FrameStabilization.none.margin, 0)
        XCTAssertEqual(FrameStabilization.none.travelLimit, 0,
                       "no inset means no travel: there is no room to correct into")

        let zoomed = LiveCameraCrop(box: NormalizedBox(xMin: 0.25, yMin: 0.25, xMax: 0.75, yMax: 0.75))
        XCTAssertEqual(LiveCameraCrop.whole.stabilized(by: .none), .whole)
        XCTAssertEqual(zoomed.stabilized(by: .none), zoomed,
                       "a frame with no stabilization is the window the elder's own gesture made")

        // A margin of zero is the same statement in geometry, whatever the
        // offset says: there is nowhere to move the window to.
        XCTAssertEqual(LiveCameraCrop.whole.stabilized(
            by: FrameStabilization(offset: CGPoint(x: 0.01, y: 0), margin: 0)), .whole)
    }

    func testTheMarginInsetsTheWindowAndTheOffsetPansIt() {
        // The whole composition, in one assertion: the elder's window (here the
        // whole frame) inset by the margin — which is the room the correction
        // lives in, and the permanent enlargement that buys it — and then panned
        // by the correction.
        let composed = LiveCameraCrop.whole.stabilized(
            by: FrameStabilization(offset: CGPoint(x: 0.01, y: -0.02), margin: 0.03))

        XCTAssertEqual(composed.box.xMin, 0.04, accuracy: 1e-12, "0.03 of inset, 0.01 of pan")
        XCTAssertEqual(composed.box.yMin, 0.01, accuracy: 1e-12, "0.03 of inset, 0.02 of pan back")
        XCTAssertEqual(composed.box.xMax, 0.98, accuracy: 1e-12)
        XCTAssertEqual(composed.box.yMax, 0.95, accuracy: 1e-12)
        XCTAssertEqual(composed.width, 0.94, accuracy: 1e-12,
                       "the picture is drawn 1/0.94 larger: the price of the room")
        XCTAssertEqual(composed.center.x, 0.51, accuracy: 1e-12)
    }

    func testAnOffsetWiderThanTheMarginIsClampedSoTheWindowStaysInsideTheFrame() {
        // The law already keeps the offset inside the travel, and the crop
        // clamps as well: a display handed an impossible correction draws the
        // window at the edge of the picture rather than off it.
        let composed = LiveCameraCrop.whole.stabilized(
            by: FrameStabilization(offset: CGPoint(x: 0.4, y: -0.4), margin: 0.03))

        XCTAssertEqual(composed.box.xMin, 0.06, accuracy: 1e-12, "inset 0.03, panned the whole 0.03")
        XCTAssertEqual(composed.box.yMin, 0.0, accuracy: 1e-12, "and no further: the frame's edge is the bound")
        XCTAssertEqual(composed.box.xMax, 1.0, accuracy: 1e-12)
        XCTAssertEqual(composed.box.yMax, 0.94, accuracy: 1e-12)
    }

    func testAMarginWiderThanTheWindowRefusesAndTheWindowIsDrawnUnmoved() {
        // The refusal is the *window's*, not the frame's: a display that cannot
        // hold the inset is the elder's own window, never nothing at all.
        for margin in [0.5, 0.7, 3.0] {
            XCTAssertEqual(LiveCameraCrop.whole.stabilized(
                by: FrameStabilization(offset: .zero, margin: margin)), .whole,
                           "a window that cannot hold the inset is drawn as the elder's own")
        }

        let zoomed = LiveCameraCrop(box: NormalizedBox(xMin: 0.25, yMin: 0.25, xMax: 0.75, yMax: 0.75))
        XCTAssertEqual(zoomed.stabilized(by: FrameStabilization(offset: .zero, margin: 0.26)), zoomed,
                       "a margin the whole frame can hold may still not fit a zoomed window")
        XCTAssertEqual(zoomed.stabilized(by: FrameStabilization(offset: .zero, margin: 0.24)).box.xMin,
                       0.49, accuracy: 1e-12)
    }

    func testAWindowThisFileNeverSawIsRefusedRatherThanDrawnOffThePicture() {
        // The inset plus the clamp keep every window this feature produces
        // inside the frame; the last guard is for a caller holding a window this
        // file never saw, and it refuses rather than drawing a picture that has
        // left the frame.
        let outside = LiveCameraCrop(box: NormalizedBox(xMin: -0.2, yMin: 0.1, xMax: 0.4, yMax: 0.5))

        XCTAssertEqual(outside.stabilized(by: FrameStabilization(offset: CGPoint(x: 0.02, y: 0), margin: 0.03)),
                       outside,
                       "a window that has already left the picture is drawn as it is, never moved further out")
    }

    func testEveryOffsetTheLawCanHoldIsAWindowInsideTheFrame() {
        // Swept rather than reasoned about, because a black sliver at the edge
        // of the picture is the one failure the owner would see instantly: for
        // any window, any margin in the policy's range and any offset the law
        // can produce, the drawn window is inside the frame and has not
        // collapsed.
        let windows = [LiveCameraCrop.whole,
                       LiveCameraCrop(box: NormalizedBox(xMin: 0.25, yMin: 0.3, xMax: 0.75, yMax: 0.7)),
                       LiveCameraCrop(box: NormalizedBox(xMin: 0.0, yMin: 0.0, xMax: 0.4, yMax: 0.5))]

        for window in windows {
            for margin in [0.01, 0.03, 0.1, 0.25] {
                for step in stride(from: -0.5, through: 0.5, by: 0.05) {
                    let composed = window.stabilized(
                        by: FrameStabilization(offset: CGPoint(x: step, y: -step), margin: margin))
                    XCTAssertTrue(composed.box.isValid,
                                  "margin \(margin), offset \(step): the window collapsed")
                    XCTAssertGreaterThanOrEqual(composed.box.xMin, -1e-9,
                                                "margin \(margin), offset \(step): the window left the frame")
                    XCTAssertGreaterThanOrEqual(composed.box.yMin, -1e-9)
                    XCTAssertLessThanOrEqual(composed.box.xMax, 1 + 1e-9)
                    XCTAssertLessThanOrEqual(composed.box.yMax, 1 + 1e-9)
                }
            }
        }
    }

    // MARK: - The measurement, read in frame fractions

    func testATranslationMovesAPointAndTheRectAroundIt() {
        let motion = FrameMotionMap.translation(CGPoint(x: 0.1, y: -0.05))

        let point = motion.map(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(point.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(point.y, 0.45, accuracy: 1e-12)

        let rect = motion.map(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        XCTAssertEqual(rect.minX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.35, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.2, accuracy: 1e-9, "a translation does not resize what it moves")
        XCTAssertEqual(rect.height, 0.2, accuracy: 1e-9)
    }

    func testAPixelTranslationIsReadInFrameFractions() {
        // Vision answers in the buffer's own pixels; every rect this feature
        // places is a fraction of the frame. 12.8 px of a 128 px buffer is a
        // tenth of the picture — and the same matrix against a different buffer
        // is a different motion, which is why the conversion needs the size.
        let inPixels = FrameMotionMap.translation(CGPoint(x: 12.8, y: 7.2)).matrix

        let normalized = FrameMotionMap.normalized(fromPixelMatrix: inPixels,
                                                   pixelSize: CGSize(width: 128, height: 72))
        let moved = normalized.map(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(moved.x, 0.6, accuracy: 1e-12, "12.8 / 128")
        XCTAssertEqual(moved.y, 0.6, accuracy: 1e-12, "7.2 / 72")

        let other = FrameMotionMap.normalized(fromPixelMatrix: inPixels,
                                              pixelSize: CGSize(width: 256, height: 72))
        XCTAssertEqual(other.map(CGPoint(x: 0.5, y: 0.5)).x, 0.55, accuracy: 1e-12, "12.8 / 256")
    }

    func testADegenerateFrameSizeIsTheIdentityMotion() {
        // Before the first frame, and on a buffer the platform declined to size,
        // there is no motion to read: the honest answer is none, not a division
        // by zero.
        for size in [CGSize.zero, CGSize(width: 0, height: 72), CGSize(width: 128, height: 0)] {
            let motion = FrameMotionMap.normalized(
                fromPixelMatrix: FrameMotionMap.translation(CGPoint(x: 10, y: 10)).matrix,
                pixelSize: size)
            XCTAssertEqual(motion, .identity)
            XCTAssertEqual(motion.map(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5))
        }
    }

    func testAProjectiveMapCarriesARectToTheBoxThatContainsIt() {
        // A zoom about the picture's centre: a homography is not a translation,
        // and the anchor's rect *grows* — which is how the estimator tells a
        // lens or a device zoom from a hand.
        let zoom = simd_double3x3(columns: (SIMD3<Double>(1.5, 0, 0),
                                            SIMD3<Double>(0, 1.5, 0),
                                            SIMD3<Double>(-0.25, -0.25, 1)))
        let motion = FrameMotionMap(matrix: zoom)

        XCTAssertEqual(motion.map(CGPoint(x: 0.5, y: 0.5)).x, 0.5, accuracy: 1e-12,
                       "the picture's centre is the fixed point of the zoom")

        let rect = motion.map(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        XCTAssertEqual(rect.midX, 0.5, accuracy: 1e-12)
        XCTAssertEqual(rect.width, 0.3, accuracy: 1e-12, "1.5 × the rect it came from")
    }

    func testAMatrixThatCannotBeReadLeavesThePointAndTheRectWhereTheyWere() {
        let singular = FrameMotionMap(matrix: simd_double3x3(columns: (SIMD3<Double>(1, 0, 0),
                                                                       SIMD3<Double>(0, 1, 0),
                                                                       SIMD3<Double>(0, 0, 0))))
        XCTAssertEqual(singular.map(CGPoint(x: 0.3, y: 0.7)), CGPoint(x: 0.3, y: 0.7),
                       "a matrix with no w is not a motion: the point is left where it was")
        XCTAssertEqual(singular.map(CGRect(x: 0.3, y: 0.7, width: 0.1, height: 0.1)),
                       CGRect(x: 0.3, y: 0.7, width: 0.1, height: 0.1))

        let notANumber = FrameMotionMap(matrix: simd_double3x3(columns: (SIMD3<Double>(1, 0, 0),
                                                                         SIMD3<Double>(0, 1, 0),
                                                                         SIMD3<Double>(Double.nan, 0, 1))))
        XCTAssertEqual(notANumber.map(CGPoint(x: 0.3, y: 0.7)), CGPoint(x: 0.3, y: 0.7))
    }

    // MARK: - The estimator

    /// A registration that answers exactly what a test says the picture did: the
    /// seam that makes the law, the anchor bookkeeping and the display testable
    /// with no camera and no homography. `nil` is a refusal, which the estimator
    /// must read as "hold what you have", never as "nothing moved".
    private final class ScriptedRegistration: FrameRegistration {
        private var motions: [FrameMotionMap?]
        private(set) var calls = 0

        init(_ motions: [FrameMotionMap?]) { self.motions = motions }

        func motion(from anchor: CVPixelBuffer, to current: CVPixelBuffer) -> FrameMotionMap? {
            defer { calls += 1 }
            return motions.isEmpty ? nil : motions.removeFirst()
        }
    }

    private func makeEstimator(_ registration: FrameRegistration,
                               enabled: Bool = true,
                               margin: Double = 0.03,
                               deadZone: Double = 0.01,
                               followFactor: Double = 0.35,
                               anchorSeconds: TimeInterval = 10) -> FrameAnchorEstimator {
        FrameAnchorEstimator(
            policy: FrameStabilizationPolicy(enabled: enabled, deadZone: deadZone,
                                             followFactor: followFactor, margin: margin,
                                             rejectDelta: 0.2, anchorSeconds: anchorSeconds,
                                             registrationSide: 64),
            registration: registration)
    }

    /// A frame-sized 32BGRA buffer. Its contents do not matter to a scripted
    /// measurement; what matters is that the estimator's own scratch path reads
    /// a real buffer of this size and format.
    private func frameBuffer(width: Int = 64, height: Int = 48) throws -> CVPixelBuffer {
        let sample = try SampleBufferFactory.make(width: width, height: height,
                                                  pts: CMTime(value: 1, timescale: 1))
        return try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    }

    private let frameSize = CGSize(width: 64, height: 48)
    private let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    func testTheFirstFrameTakesTheAnchorAndMovesNothing() throws {
        let registration = ScriptedRegistration([])
        var estimator = makeEstimator(registration)

        let held = estimator.observe(pixelBuffer: try frameBuffer(), pixelSize: frameSize, timestamp: 0)

        XCTAssertEqual(held.offset, .zero, "there is nothing to correct against yet")
        XCTAssertEqual(held.margin, 0.03,
                       "but the window is already inset: that inset is the room the correction is held in, "
                       + "and taking it later would make the picture jump when the first tremor arrives")
        XCTAssertFalse(held.isNone)
        XCTAssertEqual(estimator.anchorRect, unitRect,
                       "the anchor is the whole of the frame the elder's window was taken from")
        XCTAssertEqual(registration.calls, 0, "the first frame is the reference: there is nothing to measure yet")
        XCTAssertEqual(estimator.cost.samples, 0, "and it costs nothing")
    }

    func testATremorIsAbsorbedEndToEndAndTheWindowDoesTheWork() throws {
        let tremor = CGPoint(x: 0.008, y: -0.004)
        let registration = ScriptedRegistration([FrameMotionMap.translation(tremor)])
        var estimator = makeEstimator(registration)
        let buffer = try frameBuffer()
        _ = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0)

        let held = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0.25)

        XCTAssertEqual(held.offset.x, tremor.x, accuracy: 1e-9, "the window took the whole tremor")
        XCTAssertEqual(held.offset.y, tremor.y, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(Double(hypot(held.offset.x, held.offset.y)), held.travelLimit,
                                 "…without spending more travel than the inset bought")
        XCTAssertEqual(estimator.unavailableMeasurements, 0)
        XCTAssertEqual(estimator.cost.samples, 1, "one measurement was attempted, and paid for")
        XCTAssertEqual(registration.calls, 1)

        // The anchor's rect has moved with the content it was taken from: that is
        // the sense in which the tracker tracks — the next measurement's interval
        // is read against it.
        let anchor = try XCTUnwrap(estimator.anchorRect)
        XCTAssertEqual(anchor.midX, 0.5 + tremor.x, accuracy: 1e-9)
        XCTAssertEqual(anchor.midY, 0.5 + tremor.y, accuracy: 1e-9)
    }

    func testARegistrationThatCannotMeasureHoldsTheWindowAndSaysSo() throws {
        // The registration refuses (a frozen frame, a scene with nothing to
        // register, a format it declined). An estimate that is not being made
        // must not move the picture — and must not throw away the one it has.
        let motion = FrameMotionMap.translation(CGPoint(x: 0.02, y: 0))
        let registration = ScriptedRegistration([motion, nil, nil, motion])
        var estimator = makeEstimator(registration)
        let buffer = try frameBuffer()
        _ = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0)
        let measured = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0.25)
        XCTAssertEqual(measured.offset.x, 0.007, accuracy: 1e-9,
                       "past the 1 % dead zone, so the window is 0.35 of the way")

        for attempt in 1...2 {
            let held = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize,
                                         timestamp: 0.25 + 0.25 * Double(attempt))
            XCTAssertEqual(held, measured,
                           "refusal \(attempt): the display keeps the window it had — never a reset, never a blank")
            XCTAssertFalse(held.isNone, "and never the identity either: the correction is still held")
        }
        XCTAssertEqual(estimator.unavailableMeasurements, 2, "the caller can see the estimate is running blind")
        XCTAssertEqual(registration.calls, 3, "every attempt was made, refusals included")
        XCTAssertNotNil(estimator.anchorRect, "a refusal does not throw the anchor away")

        let recovered = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 1.0)
        XCTAssertEqual(estimator.unavailableMeasurements, 0, "a measurement that lands clears the count")
        XCTAssertGreaterThan(recovered.offset.x, measured.offset.x,
                             "and the correction carries on from where it was")
    }

    func testAMeasurementThatIsNotAHandsMotionRebasesTheAnchorAndHoldsThePicture() throws {
        // Half a frame in one measurement is a scene cut, a whip pan, a lens
        // change — not a hand. Following it would make the display jump for a
        // measurement that describes a different picture than the one on screen.
        let jump = FrameMotionMap.translation(CGPoint(x: 0.5, y: 0))
        let registration = ScriptedRegistration([jump, jump])
        var estimator = makeEstimator(registration)
        let buffer = try frameBuffer()
        _ = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0)

        let held = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0.25)

        XCTAssertEqual(held.offset, .zero, "the picture does not jump for a measurement that describes another one")
        XCTAssertEqual(estimator.anchorRect, unitRect, "the anchor is re-based on the frame it could not follow")
        XCTAssertEqual(estimator.unavailableMeasurements, 0, "a rejection is not a refusal: the registration answered")
        XCTAssertEqual(estimator.cost.samples, 1, "and it was paid for")

        let again = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0.5)
        XCTAssertEqual(again.offset, .zero, "the same cut again re-bases again: the picture never follows it")
    }

    func testAZoomIsRejectedAsAScaleRatherThanFollowedAsAMovement() throws {
        // A device zoom resizes everything in the frame. The measurement is a
        // scale, not a movement, and the estimator refuses it even though the
        // content's centre has not moved at all.
        let zoom = simd_double3x3(columns: (SIMD3<Double>(1.5, 0, 0),
                                            SIMD3<Double>(0, 1.5, 0),
                                            SIMD3<Double>(-0.25, -0.25, 1)))
        let registration = ScriptedRegistration([FrameMotionMap(matrix: zoom)])
        var estimator = makeEstimator(registration)
        let buffer = try frameBuffer()
        _ = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0)

        let held = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0.25)

        XCTAssertEqual(held.offset, .zero, "a 1.5× scale is not a hand's motion")
        XCTAssertEqual(estimator.anchorRect, unitRect, "the anchor goes with the picture it was taken from")
    }

    func testAStaleAnchorIsRetakenRatherThanMeasuredAgainst() throws {
        // The anchor is a reference *image*, and a reference the elder has been
        // moving away from for longer than `frameStabAnchorSeconds` is measuring
        // a difference they left behind — so it is replaced without asking
        // Vision to measure against it at all.
        let registration = ScriptedRegistration([FrameMotionMap.translation(CGPoint(x: 0.02, y: 0))])
        var estimator = makeEstimator(registration, anchorSeconds: 1)
        let buffer = try frameBuffer()
        _ = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0)

        let held = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 2)

        XCTAssertEqual(held.offset, .zero)
        XCTAssertEqual(registration.calls, 0, "a stale anchor is replaced without paying for a measurement")
        XCTAssertEqual(estimator.anchorRect, unitRect, "the new anchor is the frame in hand")
    }

    func testAChangedFrameSizeTakesAFreshAnchor() throws {
        // A rotation, a preset change, a device that hands over a different
        // buffer: the picture the anchor was taken from is not the picture in
        // hand, and a matrix between two sizes measures nothing.
        let registration = ScriptedRegistration([FrameMotionMap.translation(CGPoint(x: 0.02, y: 0))])
        var estimator = makeEstimator(registration)
        _ = estimator.observe(pixelBuffer: try frameBuffer(width: 64, height: 48),
                              pixelSize: CGSize(width: 64, height: 48), timestamp: 0)

        let held = estimator.observe(pixelBuffer: try frameBuffer(width: 64, height: 32),
                                     pixelSize: CGSize(width: 64, height: 32), timestamp: 0.25)

        XCTAssertEqual(held.offset, .zero)
        XCTAssertEqual(registration.calls, 0)
        XCTAssertEqual(estimator.anchorRect, unitRect)
    }

    func testTheFeatureOffIsTheIdentityAndCostsNoRequest() throws {
        let registration = ScriptedRegistration([FrameMotionMap.translation(CGPoint(x: 0.02, y: 0))])
        var estimator = makeEstimator(registration, enabled: false)
        let buffer = try frameBuffer()

        let held = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0)

        XCTAssertEqual(held, .none)
        XCTAssertEqual(registration.calls, 0, "a feature that is off makes no request")
        XCTAssertEqual(estimator.cost.samples, 0)
        XCTAssertNil(estimator.anchorRect, "and takes no anchor: nothing is being held still")
        XCTAssertEqual(LiveCameraCrop.whole.stabilized(by: held), .whole,
                       "so the display is the elder's own window, exactly as before the feature existed")
    }

    func testAMarginOfZeroIsTheIdentityToo() throws {
        // The other way to ask for no stabilization: a window with no room to
        // correct into. It is the same answer to the display.
        var estimator = makeEstimator(ScriptedRegistration([]), margin: 0)

        let held = estimator.observe(pixelBuffer: try frameBuffer(), pixelSize: frameSize, timestamp: 0)

        XCTAssertEqual(held, .none)
    }

    func testAResetForgetsTheAnchorAndTheCorrectionButNotTheCost() throws {
        let registration = ScriptedRegistration([FrameMotionMap.translation(CGPoint(x: 0.02, y: 0))])
        var estimator = makeEstimator(registration)
        let buffer = try frameBuffer()
        _ = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0)
        _ = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0.25)
        XCTAssertNotEqual(estimator.stabilization, .none, "the premise: there is a correction to forget")

        estimator.reset()

        // The *correction* is gone; the inset is not, and must not be. The
        // margin is the room the correction is held in, so it is there from the
        // first frame of every session the feature is on — dropping it here
        // would make the picture jump outwards on every zoom and every
        // interruption, which is the instability this file removes.
        XCTAssertEqual(estimator.stabilization.offset, .zero,
                       "a new capture starts from the elder's own framing")
        XCTAssertEqual(estimator.stabilization.margin, 0.03,
                       "and keeps the room the correction lives in")
        XCTAssertNil(estimator.anchorRect, "it holds no anchor, and no copy of the picture it came from")
        XCTAssertEqual(estimator.unavailableMeasurements, 0)
        XCTAssertEqual(estimator.cost.samples, 1,
                       "the cost is what the feature spent, not a fact about the anchor: it is not forgotten")

        let next = estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 1.0)
        XCTAssertEqual(next.offset, .zero, "the next frame is a fresh anchor, not a measurement against the old one")
    }

    // MARK: - One map for the picture and the boxes

    private func moved(_ box: NormalizedBox, by displacement: CGPoint) -> NormalizedBox {
        NormalizedBox(xMin: box.xMin + displacement.x, yMin: box.yMin + displacement.y,
                      xMax: box.xMax + displacement.x, yMax: box.yMax + displacement.y)
    }

    private let regionBox = NormalizedBox(xMin: 0.4, yMin: 0.42, xMax: 0.6, yMax: 0.5)

    func testTheCorrectionGluesThePrintedWordsToTheSamePlaceOnTheGlass() {
        // The whole point of the correction, as arithmetic. The words moved by
        // the tremor; the window moved by the tremor the law absorbed; and the
        // box the placement draws lands in **exactly the rect it was in** when
        // the anchor's display was drawn. The box is glued to its words because
        // the picture and the box are one map, not because a second transform
        // was kept in step with the first (owner device verdict, 2026-09-18:
        // "overlay text on top of the original text").
        let tremor = CGPoint(x: 0.008, y: -0.004)
        let anchored = LiveCameraCrop.whole.stabilized(
            by: FrameStabilization(offset: .zero, margin: 0.03))
        let held = LiveCameraCrop.whole.stabilized(
            by: FrameStabilization(offset: tremor, margin: 0.03))

        let before = LiveOverlayPlacement.screenRect(for: regionBox, containerSize: container,
                                                     framePixelSize: frame, crop: anchored)
        let after = LiveOverlayPlacement.screenRect(for: moved(regionBox, by: tremor),
                                                    containerSize: container,
                                                    framePixelSize: frame, crop: held)

        XCTAssertEqual(after.minX, before.minX, accuracy: 1e-9, "the box is on its words after the tremor")
        XCTAssertEqual(after.minY, before.minY, accuracy: 1e-9)
        XCTAssertEqual(after.width, before.width, accuracy: 1e-9)
        XCTAssertEqual(after.height, before.height, accuracy: 1e-9)

        // Not vacuous: with the window where the anchor left it, the same tremor
        // would have put the box 3 pt to the right — a green box floating off
        // the text it is supposed to be covering.
        let drifted = LiveOverlayPlacement.screenRect(for: moved(regionBox, by: tremor),
                                                      containerSize: container,
                                                      framePixelSize: frame, crop: anchored)
        XCTAssertGreaterThan(abs(drifted.minX - before.minX), 2,
                             "an 0.8 % tremor is over 2 pt on this container")
    }

    func testTheEstimatorsOwnCorrectionIsWhatMovesTheBoxWithTheWords() throws {
        // The same claim with the tremor the *estimator* absorbed rather than one
        // this test chose: the law's own answer is what the display composes, so
        // the box and the picture cannot disagree about it.
        let registration = ScriptedRegistration([FrameMotionMap.translation(CGPoint(x: 0.008, y: -0.004))])
        var estimator = makeEstimator(registration)
        let buffer = try frameBuffer()

        let anchored = LiveCameraCrop.whole.stabilized(
            by: estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0))
        let held = LiveCameraCrop.whole.stabilized(
            by: estimator.observe(pixelBuffer: buffer, pixelSize: frameSize, timestamp: 0.25))
        XCTAssertEqual(held.box.xMin, 0.038, accuracy: 1e-9,
                       "the premise: the window is inset 0.03 and panned by the tremor the law absorbed")

        let before = LiveOverlayPlacement.screenRect(for: regionBox, containerSize: container,
                                                     framePixelSize: frame, crop: anchored)
        let after = LiveOverlayPlacement.screenRect(for: moved(regionBox, by: CGPoint(x: 0.008, y: -0.004)),
                                                    containerSize: container,
                                                    framePixelSize: frame, crop: held)

        XCTAssertEqual(after.minX, before.minX, accuracy: 1e-9)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1e-9)
        XCTAssertEqual(after.width, before.width, accuracy: 1e-9)
    }

    func testTheStabilizedWindowDrawsNoBoxForTextItNoLongerCovers() {
        // The price of the inset, pinned rather than implied: while the
        // correction has its room, the outermost `frameStabMargin` of the frame
        // is not displayed. A region recognized there has no place on the glass,
        // so it is not drawn — and it is not *forgotten*: it is placed again the
        // moment the window covers it.
        let policy = LiveTranslateOverlaySurface.policy(config: .default, alwaysShowOriginal: false)
        let held = LiveCameraCrop.whole.stabilized(
            by: FrameStabilization(offset: .zero, margin: 0.03))
        let edge = TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: 0),
            text: "गेट", normalizedText: "गेट",
            box: NormalizedBox(xMin: 0.0, yMin: 0.4, xMax: 0.02, yMax: 0.45),
            detectedLanguage: "ne", confidence: 0.9)
        let inside = TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: 1),
            text: "खोल्नुहोस्", normalizedText: "खोल्नुहोस्",
            box: NormalizedBox(xMin: 0.4, yMin: 0.4, xMax: 0.6, yMax: 0.45),
            detectedLanguage: "ne", confidence: 0.9)

        let placements = LiveOverlayPlacement.place(
            regions: [edge, inside], results: [:],
            containerSize: container, framePixelSize: frame,
            safeArea: CGRect(origin: .zero, size: container),
            crop: held, policy: policy, stateCopy: { _ in nil })

        XCTAssertEqual(placements.count, 1, "the region the window has left is not drawn")
        XCTAssertEqual(placements.first?.region.id, inside.id,
                       "the one the window still covers is")
    }

    // MARK: - The shipped registration, measured

    /// A 32BGRA frame with texture a registration can hold on to: 8 × 8 blocks
    /// of pseudo-random grey from a hash of the block's coordinates, so the
    /// picture is deterministic and has corners everywhere. `shift` moves the
    /// *content* by that many pixels, filling what comes in at the edge with a
    /// flat grey — what a hand moving the phone does to the picture.
    private func texturedBuffer(width: Int, height: Int,
                                shift: (x: Int, y: Int) = (0, 0)) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess, "CVPixelBufferCreate failed with \(status)")
        let surface = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(surface, [])
        defer { CVPixelBufferUnlockBaseAddress(surface, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(surface))
        let stride = CVPixelBufferGetBytesPerRow(surface)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let value = texture(x: x - shift.x, y: y - shift.y, width: width, height: height)
                let pixel = bytes + y * stride + x * 4
                pixel[0] = value
                pixel[1] = value
                pixel[2] = value
                pixel[3] = 255
            }
        }
        return surface
    }

    /// One pixel of the pattern: a grey that is constant over an 8 × 8 block and
    /// varies from block to block. High enough frequency to give a registration
    /// corners; low enough that a downscale does not alias it away.
    private func texture(x: Int, y: Int, width: Int, height: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 128 }
        var hash = UInt64(bitPattern: Int64((x / 8) &* 73_856_093 ^ (y / 8) &* 19_349_663))
        hash ^= hash >> 33
        hash = hash &* 0xff51afd7ed558ccd
        hash ^= hash >> 33
        return UInt8(hash & 0xFF)
    }

    func testTheShippedRegistrationMeasuresAKnownShiftTheWayTheContentMoved() throws {
        // The one place in the feature that pins Vision's sign convention, which
        // every number above depends on: the *anchor* is the request's targeted
        // (floating) image, the handler holds the current frame, and the matrix
        // therefore reads anchor → current. Inverted, the correction would
        // double the tremor instead of cancelling it — and it would look
        // plausible on every still frame.
        let anchor = try texturedBuffer(width: 256, height: 256)
        let registration = VisionFrameRegistration()

        for shift in [(x: 8, y: 0), (x: 0, y: -6), (x: -5, y: 4)] {
            let current = try texturedBuffer(width: 256, height: 256, shift: shift)
            let motion = try XCTUnwrap(registration.motion(from: anchor, to: current),
                                       "the shipped ladder declined a synthetic shift of \(shift)")
            let centre = CGPoint(x: 0.5, y: 0.5)
            let moved = motion.map(centre)
            // The tolerance is the test's teeth: the smallest shift here is
            // 4 px of 256 (0.0156 of a frame), so a *reversed* axis — the one
            // mistake this measurement can make that still looks plausible —
            // misses by twice that and cannot pass. Measured error on this
            // machine is ~1e-4.
            XCTAssertEqual(moved.x - centre.x, Double(shift.x) / 256, accuracy: 0.01,
                           "shift \(shift): the map moves the content the way the content moved")
            XCTAssertEqual(moved.y - centre.y, Double(shift.y) / 256, accuracy: 0.01)
        }
        XCTAssertTrue(registration.lastMeasurementWasProjective,
                      "and it answered with the homography, not the translation-only fallback")
    }

    func testTheShippedRegistrationsCostIsMeasuredAndFitsTheRecognitionCadence() throws {
        // The number under "run the registration at the frame rate". The feature
        // measures one homography per recognition sample (nominally 4 Hz,
        // `frameStabRegistrationSide`'s 256 px buffers), and the figure is
        // printed so that raising the cadence is a decision with a price on it
        // rather than a wish. This runs on a simulator's CPU, so the assertion is
        // deliberately loose: what it rules out is a measurement that does not
        // fit the cadence at all.
        let anchor = try texturedBuffer(width: 256, height: 256)
        let current = try texturedBuffer(width: 256, height: 256, shift: (6, 4))
        let registration = VisionFrameRegistration()
        _ = registration.motion(from: anchor, to: current)  // the framework's first call is warm-up

        let rounds = 12
        var total: Double = 0
        for _ in 0..<rounds {
            let started = CFAbsoluteTimeGetCurrent()
            _ = registration.motion(from: anchor, to: current)
            total += CFAbsoluteTimeGetCurrent() - started
        }
        let average = total / Double(rounds)
        let cadence = LiveTranslateConfig.default.ocrSampleInterval
        print("[framestab] live-registration average-seconds=\(String(format: "%.4f", average)) "
              + "average-ms=\(String(format: "%.1f", average * 1000)) rounds=\(rounds) side=256 "
              + "cadence-seconds=\(cadence) share-of-cadence=\(String(format: "%.1f%%", average / cadence * 100))")

        XCTAssertGreaterThan(average, 0, "a measurement that took no time at all is one that did not run")
        XCTAssertLessThan(average, cadence / 2,
                          "a registration that costs half the interval is not one this feature can run in it")
    }

    func testTheEstimatorReportsTheCostItPaidForTheRegistration() throws {
        // The feature's own accounting, on the feature's own path: the shipped
        // policy (256 px buffers) and the shipped registration, over a short run
        // of a real, textured picture.
        //
        // A *run*, because the first measurement of a session is not the
        // interesting one: it pays for the second registration buffer and for
        // Vision's first call in the process, and the number that decides
        // whether this feature can run at 4 Hz is the steady state. Both are
        // printed — the first measurement's cost is a real cost a session pays
        // once, and hiding it would make the cadence argument dishonest.
        var estimator = FrameAnchorEstimator(policy: FrameStabilizationPolicy(config: .default),
                                             registration: VisionFrameRegistration())
        let anchor = try texturedBuffer(width: 256, height: 256)
        let current = try texturedBuffer(width: 256, height: 256, shift: (6, 4))
        let size = CGSize(width: 256, height: 256)

        _ = estimator.observe(pixelBuffer: anchor, pixelSize: size, timestamp: 0)
        XCTAssertEqual(estimator.cost.samples, 0,
                       "the anchor frame costs nothing: there is nothing to register it against")

        let held = estimator.observe(pixelBuffer: current, pixelSize: size, timestamp: 0.1)
        let firstMeasurement = estimator.cost.totalSeconds
        XCTAssertEqual(estimator.cost.samples, 1)
        XCTAssertGreaterThan(firstMeasurement, 0, "the measurement ran, and the clock saw it")

        // Eight more, at the cadence the session actually takes them at, inside
        // the two seconds an anchor lives for.
        for step in 2...9 {
            _ = estimator.observe(pixelBuffer: current, pixelSize: size,
                                  timestamp: 0.1 * Double(step))
        }
        XCTAssertEqual(estimator.cost.samples, 9)
        let cadence = LiveTranslateConfig.default.ocrSampleInterval
        print("[framestab] estimator samples=\(estimator.cost.samples) "
              + "first-total-ms=\(String(format: "%.1f", firstMeasurement * 1000)) "
              + "average-total-ms=\(String(format: "%.1f", estimator.cost.totalSeconds * 1000)) "
              + "average-prep-ms=\(String(format: "%.1f", estimator.cost.prepSeconds * 1000)) "
              + "average-registration-ms=\(String(format: "%.1f", estimator.cost.registrationSeconds * 1000)) "
              + "cadence-seconds=\(cadence) "
              + "share-of-cadence=\(String(format: "%.1f%%", estimator.cost.totalSeconds / cadence * 100))")

        XCTAssertGreaterThan(estimator.cost.prepSeconds, 0, "the downscale-and-copy is part of the price")
        XCTAssertGreaterThan(estimator.cost.registrationSeconds, 0, "and so is Vision's own time")
        XCTAssertLessThan(estimator.cost.totalSeconds, cadence / 2,
                          "the measurement has to fit inside the interval it is taken at")
        XCTAssertLessThan(estimator.cost.totalSeconds, firstMeasurement,
                          "and it is the steady state that is being asserted, not the warm-up")

        // And the correction the measurement produced is in the direction the
        // content moved: the feature's whole arithmetic, end to end.
        XCTAssertGreaterThan(held.offset.x, 0, "the content moved right: the window follows it right")
        XCTAssertGreaterThan(held.offset.y, 0, "and down: the window follows it down")
        XCTAssertEqual(estimator.unavailableMeasurements, 0)
    }
}
