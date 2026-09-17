import Combine
import CoreGraphics
import Foundation

// The camera's zoom and focus surface (owner report, 2026-09-17: "the camera is
// blurry and not sharp enough for small packaging text; they want zoom in/out
// and automatic lens switching like the standard camera app").
//
// Two halves, and the split is the point:
//
//  - **`LiveCameraZoomModel` is pure.** Bounds, steps, the lens switch-over
//    arithmetic and the pinch maths are a value with no AVFoundation, no device
//    and no I/O in it, so every rule below is unit-tested against literals
//    rather than against hardware — including the rules that decide when the
//    elder's own step lands *on* a lens switch.
//  - **`LiveCameraZoomSurface` is the observation surface.** It is the one
//    object the session view renders and the one place a gesture becomes a
//    device call. It owns no policy of its own: it asks the session what the
//    running device can do, hands the model's answer to the session, and
//    republishes whatever the device actually applied. Every dependency is
//    injected as a closure, so the pinch/step/lock behaviour is exercised in
//    tests with no camera at all.
//
// Nothing here switches a lens. The device does that itself: setting
// `videoZoomFactor` past a published switch-over factor is what makes an
// iPhone's virtual camera hand over from the wide angle to the telephoto (and
// back), which is the automatic lens switching the standard camera app has.
// What this file does with those factors is read them — so a step lands on the
// switch instead of beside it, and so the readout says which lens is live.

/// The lens sets a capture device can be built from, in the order the capture
/// layer looks for them.
///
/// The virtual multi-lens devices come first on purpose: a virtual device is
/// the only kind that publishes `virtualDeviceSwitchOverVideoZoomFactors`, and
/// the platform's own automatic switching (including the close-range fallback
/// to the ultra-wide that a triple camera performs on its own) only exists
/// while one is active. A single wide-angle camera is the honest last resort —
/// it zooms digitally, which is worse but never nothing.
enum CameraLensSet: Equatable, CaseIterable {
    case triple
    case dualWide
    case wideAngle

    /// Triple, then dual-wide, then the plain wide angle. The order is the
    /// feature's own decision and is asserted as a value, not left to the
    /// order of a `switch` somewhere.
    static let discoveryOrder: [CameraLensSet] = [.triple, .dualWide, .wideAngle]

    /// How many switch-over factors a device of this set publishes.
    ///
    /// The platform's own rule: constituents minus one — the factor at which
    /// one lens's field of view matches the next lens's full field of view.
    /// A dual-wide device (ultra-wide + wide) has one switch (at 2×, the
    /// ultra-wide's field of view handed to the wide angle); a triple adds the
    /// telephoto's; a single lens has none, and that is the case the model must
    /// handle rather than assume away.
    var switchOverFactorCount: Int {
        switch self {
        case .triple: return 2
        case .dualWide: return 1
        case .wideAngle: return 0
        }
    }
}

/// What a running device reports about zoom: the factors it can deliver and the
/// factors at which it swaps lenses.
///
/// A value, so the stub layer in the tests and the shipped AVFoundation layer
/// answer the same question in the same vocabulary. `unknown` is the honest
/// answer before a device is configured — the model then works from the app's
/// own bounds alone.
struct CameraZoomCapabilities: Equatable {

    /// `minAvailableVideoZoomFactor ... maxAvailableVideoZoomFactor`, or `nil`
    /// before a device exists.
    ///
    /// The maximum is the *active format's*, not a constant: it changes when
    /// the platform picks a different format, which is why the device is asked
    /// again after every step rather than remembered once.
    var range: ClosedRange<Double>?

    /// `virtualDeviceSwitchOverVideoZoomFactors` — ascending, one per
    /// constituent beyond the first. Empty for a single-lens device.
    var switchOverFactors: [Double]

    /// Whether the widest lens the device can show is its ultra-wide camera, so
    /// that the device's raw factor 1 is *wider* than the lens the system
    /// camera's readout calls "1×".
    ///
    /// False where there is no device, and false for a device whose widest
    /// constituent is the wide angle camera (or that has one lens only): on
    /// those, a raw factor is already the number the system readout would show.
    /// The default is that honest answer, so a stub or a test that does not care
    /// about the readout's unit does not have to state one.
    var widestLensIsUltraWide: Bool = false

    /// The unit the readout prints: raw zoom × this = the number the system
    /// camera's own readout would print for the same picture. 1 where nothing
    /// needs converting.
    ///
    /// It is also the ratio between the two spaces this feature works in: the
    /// config's zoom keys are in the readout's, and everything the device is
    /// asked for is in the raw one (`LiveCameraZoomModel` — "Units"). Nothing
    /// states it twice; the conversion goes through the members below.
    ///
    /// Derived from the device's own geometry rather than read from the ratio
    /// the platform publishes for it. The relation the platform's ratio
    /// expresses is this one: the first switch-over factor is where the widest
    /// lens's field of view matches the wide camera's full field of view
    /// (`AVCaptureDevice.virtualDeviceSwitchOverVideoZoomFactors`), and the wide
    /// camera is the lens the system readout calls 1×, so the readout's unit is
    /// that factor's reciprocal. Deriving it keeps the feature on its iOS 16
    /// floor, where the published ratio does not exist, and keeps this file's
    /// arithmetic testable without a camera in the room; on a device whose
    /// widest lens is already the wide camera the two agree, at 1.
    var displayMultiplier: Double {
        guard widestLensIsUltraWide,
              let first = switchOverFactors.first,
              first > 1 else { return 1 }
        return 1 / first
    }

    /// A config value in the readout's unit as the device's own factor: what
    /// the elder saw, in the numbers `videoZoomFactor` speaks.
    ///
    /// A multiplier of 1 — every single-lens device, and every caller that has
    /// no device to ask — makes this the identity, which is why a test that does
    /// not care about the unit can keep using raw numbers.
    func deviceFactor(forReadout readout: Double) -> Double {
        LiveCameraZoomModel.deviceFactor(forReadout: readout,
                                         displayMultiplier: displayMultiplier)
    }

    /// The factors a **display-space config** reaches on this device: the
    /// config's own limits converted into the device's factor space, then
    /// narrowed by what the device reports.
    ///
    /// One rule, used by the session's clamp and by the model the view renders,
    /// so the range the elder is held to cannot differ between the two.
    func rawBounds(for config: LiveTranslateConfig) -> ClosedRange<Double> {
        LiveCameraZoomModel.effectiveBounds(
            configMin: deviceFactor(forReadout: config.minVideoZoom),
            configMax: deviceFactor(forReadout: config.maxVideoZoom),
            deviceRange: range)
    }

    /// The factor to open the device at: the config's opening value converted
    /// into the device's space and held inside this device's bounds, so the
    /// session at rest and the first thing a gesture does agree about where the
    /// elder starts.
    func openingFactor(for config: LiveTranslateConfig) -> Double {
        LiveCameraZoomModel.clamped(deviceFactor(forReadout: config.initialVideoZoom),
                                    to: rawBounds(for: config))
    }

    static let unknown = CameraZoomCapabilities(range: nil,
                                                switchOverFactors: [],
                                                widestLensIsUltraWide: false)
}

// MARK: - The virtual crop (owner follow-up, 2026-09-18: "rudimentary — I
// expected pinch zoom and panning")

/// The rectangle of the delivered frame the elder is looking at — the camera's
/// *virtual crop*: the zoom's window, moved by the pan. Frame-normalized
/// (0–1, origin top-left), which is the space the detector's boxes, the
/// stabiliser's regions and `NormalizedBox` all already speak.
///
/// One value, three consumers, and the sharing is the point:
///
///  - the **recognition pass** crops the frame's buffer to this rectangle
///    before Vision sees it, so what is recognized is exactly what is on
///    screen — the small print in the corner, and not the shelf behind it
///    (`LiveTextDetector`);
///  - the **placement** maps a region's box through it, so a callout stays
///    glued to the region it belongs to while the picture is zoomed or moved
///    (`LiveOverlayPlacement`);
///  - the **preview** is drawn through it (`LiveCameraPresentation`), so the
///    picture the elder sees and the picture Vision reads are one picture.
///
/// `.whole` is the identity. A session that has not zoomed and has not panned
/// hands `whole` to all three, and each of them behaves exactly as it did
/// before this type existed — which is what keeps every shipped geometry test
/// true rather than merely updated.
///
/// The **sensor** zoom stays optical: nothing here re-zooms the device. This is
/// the display-space half of the framing — a crop of the frame the device
/// already delivered — so panning costs no lens quality and no second capture
/// (`LiveCameraZoomModel.cropFraction` owns how big the window may get).
struct LiveCameraCrop: Equatable {

    /// The visible rectangle, in the frame's own normalized coordinates.
    let box: NormalizedBox

    /// The whole frame: the identity crop.
    static let whole = LiveCameraCrop(
        box: NormalizedBox(xMin: 0, yMin: 0, xMax: 1, yMax: 1))

    var width: Double { box.xMax - box.xMin }
    var height: Double { box.yMax - box.yMin }

    /// The window's centre, in frame-normalized coordinates. The frame's own
    /// centre is `(0.5, 0.5)`, so this is also "where the elder has moved the
    /// window to".
    var center: CGPoint {
        CGPoint(x: (box.xMin + box.xMax) / 2, y: (box.yMin + box.yMax) / 2)
    }

    /// Whether this is the whole frame — the identity mapping, and the answer
    /// that lets a consumer skip its crop path entirely.
    var isWhole: Bool { self == .whole }

    /// A frame-normalized point as a point inside this crop: 0–1 from the
    /// crop's own top-left corner, and outside that range for a point that is
    /// outside the window.
    func cropPoint(ofFramePoint point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - box.xMin) / width,
                y: (point.y - box.yMin) / height)
    }

    /// The inverse of `cropPoint`.
    func framePoint(ofCropPoint point: CGPoint) -> CGPoint {
        CGPoint(x: box.xMin + point.x * width,
                y: box.yMin + point.y * height)
    }

    /// A frame-normalized box in this crop's coordinates (unbounded: a box
    /// that extends past the window keeps the part that is outside it, so a
    /// caller can tell "partly visible" from "not visible").
    func cropBox(ofFrameBox box: NormalizedBox) -> NormalizedBox {
        NormalizedBox(xMin: (box.xMin - self.box.xMin) / width,
                      yMin: (box.yMin - self.box.yMin) / height,
                      xMax: (box.xMax - self.box.xMin) / width,
                      yMax: (box.yMax - self.box.yMin) / height)
    }

    /// The inverse of `cropBox`, clamped into the frame: a box Vision found
    /// inside the crop cannot describe a region beyond the frame's own edges,
    /// and a float that lands a hair outside them is a rounding artifact.
    func frameBox(ofCropBox box: NormalizedBox) -> NormalizedBox {
        func clamped(_ value: Double) -> Double { Swift.min(1, Swift.max(0, value)) }
        return NormalizedBox(xMin: clamped(self.box.xMin + box.xMin * width),
                             yMin: clamped(self.box.yMin + box.yMin * height),
                             xMax: clamped(self.box.xMin + box.xMax * width),
                             yMax: clamped(self.box.yMin + box.yMax * height))
    }

    /// Whether any part of a frame-normalized box is inside this crop — what
    /// decides whether a region can be drawn at all: the window has been moved
    /// away from it, so it has no place on screen to be glued to.
    func intersects(_ box: NormalizedBox) -> Bool {
        box.xMax > self.box.xMin && box.xMin < self.box.xMax
            && box.yMax > self.box.yMin && box.yMin < self.box.yMax
    }
}

/// How the frame is presented on screen once the camera is zoomed and the
/// window moved: the visible crop, and the rect (in the container's own
/// coordinates) the **whole** frame would be drawn in.
///
/// `pictureRect` is the aspect-fit rect the feature has always mapped through
/// (`ApplianceOverlayMapper.displayedImageRect`, NFR-LCT-012) — the crop's
/// aspect is the frame's, so the crop is drawn in exactly that rect and the
/// overlay's placement and the preview cannot disagree about where a box is.
///
/// The whole mapping is here, and all of it is one affine map:
/// `containerRect(ofFrameBox:)` is what the placement draws,
/// `layerTransform(anchor:)` is what the preview layer is drawn with, and the
/// test that pins the two against each other is what makes "a callout stays
/// glued to its region while the picture moves" a fact about arithmetic rather
/// than a hope about two code paths.
struct LiveCameraPresentation: Equatable {

    /// What part of the frame is visible.
    let crop: LiveCameraCrop

    /// Where the whole frame would be drawn: the container-space rect an
    /// unzoomed, unpanned frame would fill. The crop's content fills it.
    let pictureRect: CGRect

    init(crop: LiveCameraCrop, pictureRect: CGRect) {
        self.crop = crop
        self.pictureRect = pictureRect
    }

    /// Whether there is a picture to map at all: before the first frame, or in
    /// a container that has not been laid out, there is nothing to show and
    /// every mapping below is the identity the caller should not apply.
    var isUsable: Bool {
        pictureRect.width > 0 && pictureRect.height > 0 && crop.width > 0 && crop.height > 0
    }

    /// A frame-normalized point's position in the container.
    func containerPoint(ofFramePoint point: CGPoint) -> CGPoint {
        CGPoint(x: pictureRect.minX + (point.x - crop.box.xMin) / crop.width * pictureRect.width,
                y: pictureRect.minY + (point.y - crop.box.yMin) / crop.height * pictureRect.height)
    }

    /// The inverse of `containerPoint`: where on the frame a point of the
    /// container is looking. This is also the pinch's focal point — expressed
    /// in the frame's own coordinates it is the same number whatever the crop
    /// is, which is what lets the zoom keep the picture under the finger.
    func framePoint(ofContainerPoint point: CGPoint) -> CGPoint {
        CGPoint(x: crop.box.xMin + (point.x - pictureRect.minX) / pictureRect.width * crop.width,
                y: crop.box.yMin + (point.y - pictureRect.minY) / pictureRect.height * crop.height)
    }

    /// A frame-normalized box's rect in the container — the placement's own
    /// mapping (`LiveOverlayPlacement.screenRect`), and the one the preview
    /// layer's transform has to agree with.
    func containerRect(ofFrameBox box: NormalizedBox) -> CGRect {
        let origin = containerPoint(ofFramePoint: CGPoint(x: box.xMin, y: box.yMin))
        let corner = containerPoint(ofFramePoint: CGPoint(x: box.xMax, y: box.yMax))
        return CGRect(x: origin.x, y: origin.y,
                      width: corner.x - origin.x, height: corner.y - origin.y)
    }

    /// Where the *unzoomed* picture would draw this point: the point the
    /// preview layer knows how to convert. `AVCaptureVideoPreviewLayer`'s
    /// `captureDevicePointConverted(fromLayerPoint:)` accounts for the aspect
    /// fit and the device's own zoom and knows nothing about this crop, so a
    /// tap has to be taken back through the presentation before it is handed
    /// over — otherwise the camera would focus where the elder pointed *before*
    /// they zoomed and panned.
    func unzoomedPoint(ofContainerPoint point: CGPoint) -> CGPoint {
        unzoomedContainerPoint(ofFramePoint: framePoint(ofContainerPoint: point))
    }

    /// The pan a drag of `translation` container points asks for.
    ///
    /// Two facts in one line: the picture follows the finger (so the window
    /// moves the other way), and a zoomed window moves less than the finger
    /// does for the same on-screen movement, because every frame fraction is
    /// drawn bigger than it was.
    func panOffset(ofContainerTranslation translation: CGPoint) -> CGPoint {
        CGPoint(x: -translation.x / pictureRect.width * crop.width,
                y: -translation.y / pictureRect.height * crop.height)
    }

    /// The affine the preview layer is drawn with so the crop fills
    /// `pictureRect`, about `anchor` (the layer's anchor point, in the
    /// container's coordinates — `CALayer` applies a transform about it, so
    /// the same maths in a different frame of reference needs this correction).
    ///
    /// The presentation's own linear part is a scale: the crop is drawn
    /// `1 / crop.width` larger than the whole frame was, so the layer is
    /// scaled by that and moved by whatever the crop's origin and the pan ask
    /// for. `live` here is the layer's own drawing of the frame — it already
    /// accounts for the aspect fit and the device's zoom, which is why this
    /// transform must not try to redo either.
    ///
    /// The one contract: for every frame point, `layerTransform` of the
    /// layer's own drawing of that point is what `containerPoint(ofFramePoint:)`
    /// returns. That equality is asserted directly in `LiveCameraZoomModelTests`.
    func layerTransform(anchor: CGPoint) -> CGAffineTransform {
        guard isUsable else { return .identity }
        let scale = 1 / CGFloat(crop.width)
        // The map's translation, fixed by requiring that the frame's origin
        // lands where the presentation says it does.
        let liveOrigin = unzoomedContainerPoint(ofFramePoint: .zero)
        let visibleOrigin = containerPoint(ofFramePoint: .zero)
        let translation = CGPoint(x: visibleOrigin.x - scale * liveOrigin.x,
                                  y: visibleOrigin.y - scale * liveOrigin.y)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: translation.x - (1 - scale) * anchor.x,
                                 ty: translation.y - (1 - scale) * anchor.y)
    }

    /// Where the *unzoomed* picture draws a frame point: the identity crop's
    /// own `containerPoint`, which is the current one with no crop applied.
    func unzoomedContainerPoint(ofFramePoint point: CGPoint) -> CGPoint {
        CGPoint(x: pictureRect.minX + point.x * pictureRect.width,
                y: pictureRect.minY + point.y * pictureRect.height)
    }
}

/// Which way one press of the zoom controls goes.
enum ZoomStepDirection: Equatable {
    /// A longer focal length: a larger factor, a narrower view.
    case closer
    /// A shorter focal length: a smaller factor, a wider view.
    case wider
}

/// The zoom state, as a value: where the elder is, how far they can go, and
/// where the running device changes lens.
///
/// Every rule is here rather than in the view or the session: the view renders
/// `label` and asks `canZoomCloser`/`canZoomWider` about its two buttons, and
/// the session hands the model's factor to the device and adopts what the
/// device applied.
///
/// **Units.** Everything a model holds — `bounds`, `step`, `switchOverFactors`,
/// `factor` — is in the *device's* factor space: the numbers `videoZoomFactor`
/// takes, which is the space the platform clamps and switches in. The config's
/// zoom keys are in the *readout's* space instead — the numbers the elder
/// reads, which are the ones the system camera prints for the same picture —
/// so `init` converts them on the way in, by the device's own
/// `displayMultiplier`. On a single-lens device that multiplier is 1 and the
/// two spaces are the same numbers; on a virtual multi-lens device they are
/// not, and a key read in the wrong one is a key off by that factor.
struct LiveCameraZoomModel: Equatable {

    /// The factors the elder can reach: the app's own bounds, narrowed to what
    /// the running device reports.
    let bounds: ClosedRange<Double>

    /// The factors at or above which the device hands over to its next lens,
    /// ascending, already narrowed to `bounds`.
    ///
    /// Read from the device, never invented here: the same value means
    /// different things on different hardware (the ultra-wide hands over at 2×,
    /// and where the telephoto takes over is the device's business), and a
    /// hard-coded guess would either never trigger or trigger where no lens
    /// exists.
    let switchOverFactors: [Double]

    /// One press of + or −, in factor units.
    let step: Double

    /// How near a pinch release has to be to a switch-over factor, as a
    /// fraction of that factor, before the release lands on it.
    let switchSnapTolerance: Double

    /// The factor in effect.
    let factor: Double

    /// The device's display multiplier for the readout (see
    /// `CameraZoomCapabilities.displayMultiplier`). 1 unless a device says
    /// otherwise.
    let displayMultiplier: Double

    /// Where the visible window is centred, as an offset from the frame's own
    /// centre in frame fractions (0 at the centre, `panLimit` at most either
    /// way). Positive x moves the window right, so the picture moves left.
    let pan: CGPoint

    /// The window's size at full pan range, as a fraction of the frame (see
    /// `cropFraction`). 0 means the config does not describe a window.
    let panWindowFraction: Double

    /// The readouts the window's ramp runs between: the whole frame at or
    /// below `panStartZoom`, `panWindowFraction` at or above `panFullZoom`.
    let panStartZoom: Double
    let panFullZoom: Double

    /// The pinch's exponent: 1 is the recogniser's own scale, and a value
    /// below 1 makes the same finger movement move the picture less.
    let pinchSensitivity: Double

    /// Builds the model for a config and a device.
    ///
    /// `factor`, `deviceRange` and `deviceSwitchOverFactors` are in the
    /// **device's** space (see "Units"); only the config is in the readout's,
    /// and it is converted here. `factor` is the factor in effect — what the
    /// device was last asked for — not a config value, so it is taken as it
    /// comes and only clamped. `pan` is in the frame's own fractions and is
    /// clamped to the window that factor allows.
    init(config: LiveTranslateConfig,
         factor: Double? = nil,
         pan: CGPoint = .zero,
         deviceRange: ClosedRange<Double>? = nil,
         deviceSwitchOverFactors: [Double] = [],
         displayMultiplier: Double = 1) {
        let readoutToDevice = { (readout: Double) in
            Self.deviceFactor(forReadout: readout, displayMultiplier: displayMultiplier)
        }
        let bounds = Self.effectiveBounds(configMin: readoutToDevice(config.minVideoZoom),
                                          configMax: readoutToDevice(config.maxVideoZoom),
                                          deviceRange: deviceRange)
        self.bounds = bounds
        self.switchOverFactors = deviceSwitchOverFactors
            .filter { bounds.contains($0) }
            .sorted()
        self.step = readoutToDevice(config.zoomStep)
        self.switchSnapTolerance = config.zoomSwitchSnapTolerance
        self.displayMultiplier = displayMultiplier
        let factor = Self.clamped(factor ?? readoutToDevice(config.initialVideoZoom), to: bounds)
        self.factor = factor
        // A window fraction that cannot describe a window (zero, negative, past
        // the frame) is not a window at all: the elder gets the whole frame and
        // no pan, which is the behaviour this feature shipped with.
        // `panEnabled` false reaches the same state on purpose — no window means
        // nothing to move, so the drag has nothing to act on and the preview
        // stays the sensor's own picture.
        let window = config.panEnabled ? config.panWindowFraction : 1
        self.panWindowFraction = (window.isFinite && window > 0 && window <= 1) ? window : 1
        self.panStartZoom = config.panStartZoom
        self.panFullZoom = config.panFullZoom
        let sensitivity = config.pinchSensitivity
        self.pinchSensitivity = (sensitivity.isFinite && sensitivity > 0) ? sensitivity : 1
        self.pan = Self.clampedPan(pan, to: Self.panLimit(forFraction: Self.windowFraction(
            forReadout: factor * displayMultiplier,
            window: self.panWindowFraction,
            start: self.panStartZoom,
            full: self.panFullZoom)))
    }

    private init(bounds: ClosedRange<Double>,
                 switchOverFactors: [Double],
                 step: Double,
                 switchSnapTolerance: Double,
                 factor: Double,
                 displayMultiplier: Double,
                 pan: CGPoint,
                 panWindowFraction: Double,
                 panStartZoom: Double,
                 panFullZoom: Double,
                 pinchSensitivity: Double) {
        self.bounds = bounds
        self.switchOverFactors = switchOverFactors
        self.step = step
        self.switchSnapTolerance = switchSnapTolerance
        self.factor = factor
        self.displayMultiplier = displayMultiplier
        self.pan = pan
        self.panWindowFraction = panWindowFraction
        self.panStartZoom = panStartZoom
        self.panFullZoom = panFullZoom
        self.pinchSensitivity = pinchSensitivity
    }

    // MARK: Bounds

    /// The bounds the elder gets: what the app allows, narrowed by what the
    /// running device can deliver.
    ///
    /// The device's side is a **narrowing and never a widening**. Asking below
    /// `minAvailableVideoZoomFactor` is clamped by the platform; asking above
    /// the active format's `videoMaxZoomFactor` is an out-of-range exception,
    /// and a ceiling this feature invented could be above a shorter lens set
    /// than the one it was written for. A device whose widest view is already
    /// tighter than the app's floor (a long-lens device at 2×) narrows the
    /// floor to its own: one factor, a disabled control, and no trapping range.
    static func effectiveBounds(configMin: Double,
                                configMax: Double,
                                deviceRange: ClosedRange<Double>?) -> ClosedRange<Double> {
        guard let deviceRange else {
            return configMin...Swift.max(configMin, configMax)
        }
        let lower = Swift.max(configMin, deviceRange.lowerBound)
        let upper = Swift.min(configMax, deviceRange.upperBound)
        return lower...Swift.max(lower, upper)
    }

    /// A readout value as the device's factor: the inverse of the arithmetic in
    /// `label`, and the one place the config's unit meets the platform's.
    ///
    /// A multiplier of 1 is the identity. A non-positive one is not a unit at
    /// all (nothing that can be divided by), so the value passes through rather
    /// than becoming an infinity the platform would trap on.
    static func deviceFactor(forReadout readout: Double, displayMultiplier: Double) -> Double {
        guard displayMultiplier > 0 else { return readout }
        return readout / displayMultiplier
    }

    /// Brings a value inside a range, exactly like `ClosedRange.clamped(to:)`
    /// — spelled out here because a non-finite value (a pinch that produced
    /// infinity) must land on a real factor rather than propagate.
    static func clamped(_ value: Double, to bounds: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return bounds.lowerBound }
        return Swift.min(bounds.upperBound, Swift.max(bounds.lowerBound, value))
    }

    /// A copy at `value`, clamped to the model's own bounds.
    ///
    /// The pan comes along and is re-clamped: a narrower window (a bigger
    /// factor) allows a bigger pan and a wider one allows less, and a factor
    /// back at the ramp's floor allows none at all — which is how the window
    /// recentres itself when the elder zooms back out, exactly as the system
    /// camera does.
    func withFactor(_ value: Double) -> LiveCameraZoomModel {
        let factor = Self.clamped(value, to: bounds)
        return copy(factor: factor,
                    pan: Self.clampedPan(pan, to: Self.panLimit(forFraction: windowFraction(for: factor))))
    }

    /// A copy at `offset`, clamped to what the current window allows.
    func withPan(_ offset: CGPoint) -> LiveCameraZoomModel {
        copy(pan: Self.clampedPan(offset, to: panLimit))
    }

    private func copy(factor: Double? = nil, pan: CGPoint? = nil) -> LiveCameraZoomModel {
        LiveCameraZoomModel(bounds: bounds,
                            switchOverFactors: switchOverFactors,
                            step: step,
                            switchSnapTolerance: switchSnapTolerance,
                            factor: factor ?? self.factor,
                            displayMultiplier: displayMultiplier,
                            pan: pan ?? self.pan,
                            panWindowFraction: panWindowFraction,
                            panStartZoom: panStartZoom,
                            panFullZoom: panFullZoom,
                            pinchSensitivity: pinchSensitivity)
    }

    // MARK: The window

    /// The visible window's size, as a fraction of the frame: the whole frame
    /// at or below `panStartZoom`, `panWindowFraction` at or beyond
    /// `panFullZoom`, and linear in the readout between the two.
    ///
    /// A function of the **zoom** rather than of the pan, deliberately. Tied to
    /// the pan instead, the window could be narrowed to nothing by a drag, and
    /// the pinch's own anchoring — which reads the window size at the gesture's
    /// start — would have to solve for a size it was simultaneously changing.
    /// Ramping with the zoom gives the elder pan room in proportion to how far
    /// they have zoomed, and none at the bottom of the range where there is
    /// nothing to pan to.
    ///
    /// This is the **display's** magnification, layered on top of the sensor's
    /// own (`factor`): the picture on screen is the lens's field narrowed to
    /// this fraction, so at the ramp's full extent it is enlarged by
    /// `1 / panWindowFraction` beyond what the lens delivers. Vision reads the
    /// same crop at full sensitivity resolution, so the small print the elder
    /// zoomed in for is recognized from the sensor's pixels, not from the
    /// enlarged screen image.
    var cropFraction: Double {
        windowFraction(for: factor)
    }

    /// How far the window may be moved either way from centre, in frame
    /// fractions: exactly enough that the window stays inside the frame
    /// (`(1 - size) / 2`), which is why the pan room tapers to nothing as the
    /// window opens out to the whole frame.
    var panLimit: Double { Self.panLimit(forFraction: cropFraction) }

    /// The rectangle of the frame the elder is looking at — the window at the
    /// current factor, moved by the pan.
    var crop: LiveCameraCrop {
        let size = cropFraction
        let center = CGPoint(x: 0.5 + pan.x, y: 0.5 + pan.y)
        return LiveCameraCrop(box: NormalizedBox(xMin: center.x - size / 2,
                                                 yMin: center.y - size / 2,
                                                 xMax: center.x + size / 2,
                                                 yMax: center.y + size / 2))
    }

    /// The crop and the container rect together, which is everything the
    /// preview, the placement and the gestures map through.
    func presentation(in pictureRect: CGRect) -> LiveCameraPresentation {
        LiveCameraPresentation(crop: crop, pictureRect: pictureRect)
    }

    /// Whether the window shows the whole frame — at which point nothing is
    /// cropped, nothing can be panned, and every consumer takes its
    /// uncropped path.
    var showsWholeFrame: Bool { crop.isWhole }

    /// The window's size at an arbitrary factor: the ramp, as a pure function
    /// of what the elder reads. A degenerate or missing ramp (a config with the
    /// two ends the wrong way round) is no window at all rather than a window
    /// the elder cannot see out of.
    func windowFraction(for factor: Double) -> Double {
        Self.windowFraction(forReadout: factor * displayMultiplier,
                            window: panWindowFraction,
                            start: panStartZoom,
                            full: panFullZoom)
    }

    private static func windowFraction(forReadout readout: Double,
                                       window: Double,
                                       start: Double,
                                       full: Double) -> Double {
        guard start.isFinite, full.isFinite, full > start, readout.isFinite else { return 1 }
        let progress = Swift.min(1, Swift.max(0, (readout - start) / (full - start)))
        return 1 - (1 - window) * progress
    }

    private static func panLimit(forFraction fraction: Double) -> Double {
        Swift.max(0, (1 - fraction) / 2)
    }

    private static func clampedPan(_ pan: CGPoint, to limit: Double) -> CGPoint {
        func clamped(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 0 }
            return Swift.min(CGFloat(limit), Swift.max(-CGFloat(limit), value))
        }
        return CGPoint(x: clamped(pan.x), y: clamped(pan.y))
    }

    // MARK: Stepping

    /// Whether a press of + or − would move at all: the two ends of the range
    /// are where the control is drawn disabled rather than where it silently
    /// does nothing.
    var canZoomCloser: Bool { factor < bounds.upperBound }
    var canZoomWider: Bool { factor > bounds.lowerBound }

    /// One press of + or −.
    ///
    /// A step that would cross the next switch-over factor in its direction
    /// **lands on it** instead of passing it: from 1× on a device that hands
    /// over at 2×, two presses of + give 1.5× then 2× — the press that reaches
    /// the telephoto is the press that shows it, rather than one more that
    /// jumps past the only place a lens changes.
    func stepping(_ direction: ZoomStepDirection) -> LiveCameraZoomModel {
        let raw = direction == .closer ? factor + step : factor - step
        return withFactor(landingOnSwitch(raw, direction: direction))
    }

    /// The step's destination, pulled onto a switch-over factor when the step
    /// would cross one (or land exactly on it).
    private func landingOnSwitch(_ raw: Double, direction: ZoomStepDirection) -> Double {
        switch direction {
        case .closer:
            guard let next = switchOverFactors.first(where: { $0 > factor }) else { return raw }
            return raw >= next ? next : raw
        case .wider:
            guard let previous = switchOverFactors.last(where: { $0 < factor }) else { return raw }
            return raw <= previous ? previous : raw
        }
    }

    // MARK: Pinching

    /// A pinch in flight, measured from the model the gesture started at, and
    /// anchored at the point of the picture the fingers landed on.
    ///
    /// Cumulative from the gesture's own start rather than from the last
    /// delivered value: a pinch is one gesture, and compounding it on itself
    /// would make the same movement travel further the more often it was
    /// sampled.
    ///
    /// **The anchoring.** `focus` is the finger's position inside the visible
    /// window (0–1 of the crop), taken once, when the fingers landed. The
    /// elder's fingers are holding a *place in the picture*, and that place has
    /// to stay under them: if the window narrows by `size - startSize` around a
    /// point that is not the centre, the whole window has to move by that
    /// difference weighted by how far the point is from the centre. At the
    /// centre the weight is zero — zooming from the middle of the picture needs
    /// no pan at all, which is why the buttons and a centre pinch agree. At an
    /// edge it is the full difference — the window slides so that edge's
    /// content is held still. A finger in a corner does both axes at once.
    ///
    /// The pan this asks for can be past what the window allows, in which case
    /// `withPan` clamps it: near the frame's edge the picture stops following
    /// the fingers, which is the only honest answer — the alternative is
    /// showing the elder frame that the camera never captured.
    ///
    /// `magnification` is the recogniser's cumulative scale; `pinchSensitivity`
    /// raises it to a power, so a value below 1 asks for a gentler pinch
    /// without changing what any given scale means.
    func pinched(by magnification: Double,
                 from base: LiveCameraZoomModel,
                 at focus: CGPoint = LiveCameraCrop.whole.center) -> LiveCameraZoomModel {
        guard magnification.isFinite, magnification > 0 else { return self }
        let scale = pinchSensitivity == 1 ? magnification : pow(magnification, pinchSensitivity)
        let zoomed = withFactor(base.factor * scale)
        let drift = (zoomed.cropFraction - base.cropFraction)
        return zoomed.withPan(CGPoint(x: base.pan.x + drift * (0.5 - focus.x),
                                      y: base.pan.y + drift * (0.5 - focus.y)))
    }

    /// Where a pinch release lands: on a switch-over factor when the fingers
    /// stopped within `switchSnapTolerance` of it, and where they left it
    /// otherwise.
    ///
    /// This is the half of "automatic lens switching" a hand can feel. A pinch
    /// that ends at 1.94× on a device that hands over at 2× would show the wide
    /// angle's picture at a wide-angle factor, while the readout said the
    /// telephoto was about to start — snapping the release onto the factor the
    /// device actually switches at is what makes the number and the picture
    /// agree.
    func snappedForRelease() -> LiveCameraZoomModel {
        guard let nearest = nearestSwitchOverFactor() else { return self }
        return withFactor(nearest)
    }

    private func nearestSwitchOverFactor() -> Double? {
        guard switchSnapTolerance > 0 else { return nil }
        let candidates = switchOverFactors.filter {
            abs(factor - $0) <= $0 * switchSnapTolerance
        }
        return candidates.min { abs(factor - $0) < abs(factor - $1) }
    }

    // MARK: Reading the lens

    /// Which constituent lens the factor is in, 0-based from the widest, and
    /// how many the running device offers. A single-lens device is 0 of 1.
    var lensIndex: Int {
        switchOverFactors.filter { $0 <= factor }.count
    }

    var lensCount: Int { switchOverFactors.count + 1 }

    /// The factor as the elder reads it: "1×", "1.5×", "2.5×".
    ///
    /// A numeral and a multiplication sign, like the system camera's own zoom
    /// readout, in the device's *display* space (`displayMultiplier`): the
    /// number is what the Camera app would show for the same lens, not a raw
    /// factor that means the same thing in a unit nobody sees.
    ///
    /// Deliberately **not** catalog copy: the number is arithmetic on session
    /// state, and the feature's catalog is a pinned inventory of sentences
    /// (`LiveTranslateCopyTests`) — a sentence per reachable zoom factor is not
    /// a thing to translate. What is spoken for this control is a label of its
    /// own (the surface's accessibility value), not this string read aloud.
    var label: String {
        let text = String(format: "%.1f", factor * displayMultiplier)
        guard text.hasSuffix(".0") else { return text + Self.zoomSuffix }
        return String(text.dropLast(Self.wholeNumberSuffixLength)) + Self.zoomSuffix
    }

    /// The multiplication sign the readout is built from. A symbol, not copy.
    static let zoomSuffix = "×"
    /// The ".0" a whole factor's one-decimal form ends with.
    static let wholeNumberSuffixLength = 2
}

/// The zoom and focus surface: the one object the session view observes, and
/// the one place a gesture turns into a device call.
///
/// It is a *surface* in this feature's sense — a value the view renders — and
/// it holds no policy: the model above decides what a step or a release means,
/// the injected closures carry the answer to the running session, and what is
/// republished is what the **device** applied. That is what keeps the readout
/// honest when the platform clamps a factor, and what lets the whole gesture
/// path run in tests with no camera.
///
/// Main-thread only: it is owned by the session and read by the view.
final class LiveCameraZoomSurface: ObservableObject {

    /// The zoom model in effect.
    @Published private(set) var model: LiveCameraZoomModel

    /// Whether focus is held at its current lens position (the focus-lock
    /// toggle). Starts from the config, so the control and the device are
    /// never drawn disagreeing.
    @Published private(set) var isFocusLocked: Bool

    private let config: LiveTranslateConfig

    /// What the running device reports now. Asked again on every interaction:
    /// the answer changes with the active format, and a step taken after a
    /// lens switch must be bounded by the format that is live *now*.
    private let capabilities: () -> CameraZoomCapabilities

    /// Applies a factor and answers the one the device actually took.
    private let applyZoom: (Double) -> Double
    /// Moves the focus point, in the device's own normalized coordinates.
    private let applyFocus: (CGPoint) -> Void
    /// Holds focus, or releases it.
    private let applyFocusLock: (Bool) -> Void
    /// Tells the session which rectangle of the frame is visible: the same
    /// value the preview is drawn through and the recognition pass is cropped
    /// to, so that what the elder sees and what Vision reads are one picture.
    private let applyCrop: (LiveCameraCrop) -> Void

    /// The model the pinch in flight started from, or `nil` between pinches:
    /// one gesture, one base, however many times the recogniser samples it.
    /// The whole model rather than just the factor, because the anchoring needs
    /// the pan and the window size the fingers landed with.
    private var pinchBase: LiveCameraZoomModel?

    /// The pan the drag in flight started from, or `nil` between drags.
    private var panBase: CGPoint?

    init(config: LiveTranslateConfig,
         capabilities: @escaping () -> CameraZoomCapabilities = { .unknown },
         applyZoom: @escaping (Double) -> Double = { $0 },
         applyFocus: @escaping (CGPoint) -> Void = { _ in },
         applyFocusLock: @escaping (Bool) -> Void = { _ in },
         applyCrop: @escaping (LiveCameraCrop) -> Void = { _ in }) {
        self.config = config
        self.capabilities = capabilities
        self.applyZoom = applyZoom
        self.applyFocus = applyFocus
        self.applyFocusLock = applyFocusLock
        self.applyCrop = applyCrop
        // Built against the device when there already is one, so the readout
        // and the pinch's base begin in the device's own factor space: a
        // surface that opened from the config's readout numbers alone would
        // print the wrong unit, and its first pinch would spend itself closing
        // the gap between the two spaces instead of moving the picture.
        let current = capabilities()
        let model = LiveCameraZoomModel(config: config,
                                        deviceRange: current.range,
                                        deviceSwitchOverFactors: current.switchOverFactors,
                                        displayMultiplier: current.displayMultiplier)
        self.model = model
        self.isFocusLocked = config.focusLockDefault
        self.applyCrop(model.crop)
    }

    // MARK: Zoom

    /// One press of the **+** (`direction: .closer`) or **−** button.
    func zoom(_ direction: ZoomStepDirection) {
        apply(rebuilt().stepping(direction))
    }

    /// A pinch in flight. `magnification` is the recogniser's cumulative scale
    /// — 1 at the moment the fingers landed — and `focus` is where they landed,
    /// in the visible window's own coordinates (0–1). The default is the
    /// window's centre, the anchoring the buttons have: a pinch that does not
    /// say where it started zooms about the middle of the picture.
    func pinch(to magnification: Double, at focus: CGPoint = LiveCameraCrop.whole.center) {
        if pinchBase == nil { pinchBase = model }
        guard let base = pinchBase else { return }
        apply(rebuilt().pinched(by: magnification, from: base, at: focus))
    }

    /// The pinch's end: the release snaps onto a lens switch when it stopped
    /// near one, and the gesture's base is let go.
    func pinchEnded() {
        guard pinchBase != nil else { return }
        pinchBase = nil
        apply(rebuilt().snappedForRelease())
    }

    // MARK: Panning

    /// A drag of one finger while the picture is zoomed. `offset` is the
    /// drag's translation since it began, converted into frame fractions by
    /// the caller (the view, through the presentation) — the recogniser's own
    /// cumulative convention, measured from the moment the finger landed.
    ///
    /// Nothing happens while the whole frame is visible: there is no window to
    /// move, `panLimit` is zero, and the clamp is the entire enforcement.
    /// Dragging past the frame's edge stops the picture there and keeps the
    /// base, so the elder's finger comes back to it rather than having to
    /// retrace the overshoot.
    func pan(to offset: CGPoint) {
        if panBase == nil { panBase = model.pan }
        guard let base = panBase else { return }
        apply(rebuilt().withPan(CGPoint(x: base.x + offset.x, y: base.y + offset.y)))
    }

    /// The drag's end. The pan stays where the finger left it — a gesture that
    /// moved the picture must not move it back.
    func panEnded() {
        panBase = nil
    }

    /// The session let go of the picture: it stopped, or an interruption ended
    /// and the camera came back.
    ///
    /// Told rather than inferred, and idempotent, like the focus lock's mirror.
    /// The zoom itself is the session's to restore — it is the one holding the
    /// device — but where the window was pointed is the elder's gesture state,
    /// and this is where it goes home. Whether it does is the config's answer
    /// (`panResetsOnExit`), because an elder who was reading a label, was
    /// interrupted by a call, and came back to the same shelf may reasonably
    /// want to be looking at the same place.
    func sessionReleased() {
        panBase = nil
        guard config.panResetsOnExit else { return }
        apply(model.withPan(.zero))
    }

    // MARK: Focus

    /// A tap on the picture: focus there, and let go of any focus lock.
    ///
    /// An elder who taps a new label is asking the camera to look at it, not to
    /// keep looking where the last lock was — and the one-shot focus the
    /// session applies *is* the release, so the device side needs no second
    /// call.
    func focus(atDevicePoint point: CGPoint) {
        focusLockChanged(to: false)
        applyFocus(point)
    }

    /// The focus lock is now `locked` — told rather than inferred, and
    /// idempotent.
    ///
    /// The session keeps its own mirror of the lock, because the subject-area
    /// re-arm reads it on a path that cannot ask the view, and two mirrors of
    /// one fact that nothing synchronises are two facts. Every path that moves
    /// the lock — the toggle below, the session's own `setFocusLocked`, a tap
    /// releasing it — lands here, so the control and the device can never be
    /// drawn disagreeing.
    func focusLockChanged(to locked: Bool) {
        guard isFocusLocked != locked else { return }
        isFocusLocked = locked
    }

    /// The focus-lock toggle. Locked holds the current lens position (the
    /// steady read); unlocked returns to the close-range continuous search.
    func toggleFocusLock() {
        let locked = !isFocusLocked
        focusLockChanged(to: locked)
        applyFocusLock(locked)
    }

    // MARK: Plumbing

    /// The model rebuilt against what the device reports *now*, at the factor
    /// and pan in effect: the bounds and the switch-over factors are the
    /// running device's, never a previous session's.
    private func rebuilt() -> LiveCameraZoomModel {
        let current = capabilities()
        return LiveCameraZoomModel(config: config,
                                   factor: model.factor,
                                   pan: model.pan,
                                   deviceRange: current.range,
                                   deviceSwitchOverFactors: current.switchOverFactors,
                                   displayMultiplier: current.displayMultiplier)
    }

    /// Hands a candidate to the device and republishes what came back.
    ///
    /// The device answers the zoom — it is the one that may clamp a factor to
    /// what the running format can deliver — and the **window is then computed
    /// from that answer**, so the readout, the crop the preview is drawn
    /// through and the crop the recognition pass is given are all the picture
    /// that is actually being captured. A candidate that moves neither the
    /// zoom nor the window is not applied at all: a gesture that has stopped
    /// moving must not keep asking the platform to lock, configure and unlock a
    /// device.
    private func apply(_ candidate: LiveCameraZoomModel) {
        var settled = candidate
        if candidate.factor != model.factor {
            settled = candidate.withFactor(applyZoom(candidate.factor))
        }
        settle(settled)
    }

    /// Publishes a model the device is already at — the session's own read-back
    /// after a start, or the reset after a stop — and hands its window to the
    /// recognition path. Publishing only: the device is not asked for anything,
    /// because it is where this model says it is.
    private func settle(_ settled: LiveCameraZoomModel) {
        guard settled != model else { return }
        model = settled
        applyCrop(settled.crop)
    }

    /// The device actually opened at `factor`: the session's read-back, told
    /// rather than inferred, so the readout and the window describe the picture
    /// the camera is really taking even when the platform clamped the opening
    /// zoom to the active format's range.
    ///
    /// The pan comes along and is re-clamped by `withFactor`, like any other
    /// factor change: the window that factor allows is the window the elder
    /// gets.
    func sessionOpened(atDeviceFactor factor: Double) {
        pinchBase = nil
        settle(model.withFactor(factor))
    }
}
