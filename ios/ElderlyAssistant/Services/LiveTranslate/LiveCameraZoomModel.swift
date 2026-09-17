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

    /// Builds the model for a config and a device.
    ///
    /// `factor`, `deviceRange` and `deviceSwitchOverFactors` are in the
    /// **device's** space (see "Units"); only the config is in the readout's,
    /// and it is converted here. `factor` is the factor in effect — what the
    /// device was last asked for — not a config value, so it is taken as it
    /// comes and only clamped.
    init(config: LiveTranslateConfig,
         factor: Double? = nil,
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
        self.factor = Self.clamped(factor ?? readoutToDevice(config.initialVideoZoom), to: bounds)
    }

    private init(bounds: ClosedRange<Double>,
                 switchOverFactors: [Double],
                 step: Double,
                 switchSnapTolerance: Double,
                 factor: Double,
                 displayMultiplier: Double) {
        self.bounds = bounds
        self.switchOverFactors = switchOverFactors
        self.step = step
        self.switchSnapTolerance = switchSnapTolerance
        self.factor = factor
        self.displayMultiplier = displayMultiplier
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
    func withFactor(_ value: Double) -> LiveCameraZoomModel {
        LiveCameraZoomModel(bounds: bounds,
                            switchOverFactors: switchOverFactors,
                            step: step,
                            switchSnapTolerance: switchSnapTolerance,
                            factor: Self.clamped(value, to: bounds),
                            displayMultiplier: displayMultiplier)
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

    /// A pinch in flight, measured from the factor the gesture started at.
    ///
    /// Cumulative from the gesture's own start rather than from the last
    /// delivered value: a pinch is one gesture, and compounding it on itself
    /// would make the same movement travel further the more often it was
    /// sampled.
    func pinched(by magnification: Double, from base: Double) -> LiveCameraZoomModel {
        withFactor(base * magnification)
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

    /// The factor the pinch in flight started from, or `nil` between pinches:
    /// one gesture, one base, however many times the recogniser samples it.
    private var pinchBase: Double?

    init(config: LiveTranslateConfig,
         capabilities: @escaping () -> CameraZoomCapabilities = { .unknown },
         applyZoom: @escaping (Double) -> Double = { $0 },
         applyFocus: @escaping (CGPoint) -> Void = { _ in },
         applyFocusLock: @escaping (Bool) -> Void = { _ in }) {
        self.config = config
        self.capabilities = capabilities
        self.applyZoom = applyZoom
        self.applyFocus = applyFocus
        self.applyFocusLock = applyFocusLock
        // Built against the device when there already is one, so the readout
        // and the pinch's base begin in the device's own factor space: a
        // surface that opened from the config's readout numbers alone would
        // print the wrong unit, and its first pinch would spend itself closing
        // the gap between the two spaces instead of moving the picture.
        let current = capabilities()
        self.model = LiveCameraZoomModel(config: config,
                                         deviceRange: current.range,
                                         deviceSwitchOverFactors: current.switchOverFactors,
                                         displayMultiplier: current.displayMultiplier)
        self.isFocusLocked = config.focusLockDefault
    }

    // MARK: Zoom

    /// One press of the **+** (`direction: .closer`) or **−** button.
    func zoom(_ direction: ZoomStepDirection) {
        apply(rebuilt().stepping(direction))
    }

    /// A pinch in flight. `magnification` is the recogniser's cumulative scale
    /// — 1 at the moment the fingers landed.
    func pinch(to magnification: Double) {
        if pinchBase == nil { pinchBase = model.factor }
        guard let base = pinchBase else { return }
        apply(rebuilt().pinched(by: magnification, from: base))
    }

    /// The pinch's end: the release snaps onto a lens switch when it stopped
    /// near one, and the gesture's base is let go.
    func pinchEnded() {
        guard pinchBase != nil else { return }
        pinchBase = nil
        apply(rebuilt().snappedForRelease())
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
    /// in effect: the bounds and the switch-over factors are the running
    /// device's, never a previous session's.
    private func rebuilt() -> LiveCameraZoomModel {
        let current = capabilities()
        return LiveCameraZoomModel(config: config,
                                   factor: model.factor,
                                   deviceRange: current.range,
                                   deviceSwitchOverFactors: current.switchOverFactors,
                                   displayMultiplier: current.displayMultiplier)
    }

    /// Hands a candidate to the device and republishes what came back. A
    /// candidate that moves nothing is not applied at all: a gesture that has
    /// stopped moving must not keep asking the platform to lock, configure and
    /// unlock a device.
    private func apply(_ candidate: LiveCameraZoomModel) {
        guard candidate.factor != model.factor else { return }
        model = candidate.withFactor(applyZoom(candidate.factor))
    }
}
