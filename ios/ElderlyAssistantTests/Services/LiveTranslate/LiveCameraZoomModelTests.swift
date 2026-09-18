import AVFoundation
import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import ElderlyAssistant

/// The camera's zoom and focus surface (owner report, 2026-09-17: "the camera
/// is blurry and not sharp enough for small packaging text; they want zoom
/// in/out and automatic lens switching like the standard camera app").
///
/// Three layers, tested where each one can be tested honestly:
///
///  1. **The model's arithmetic, against literals.** Bounds narrowed by the
///     device, a step that lands on a lens switch instead of beside it, a
///     pinch measured from its own start and snapped on release, the readout.
///     No device, no session, no camera: the rules that decide when an iPhone
///     changes lens are asserted as numbers, because a simulator cannot change
///     lens and the owner's device can (see the file's closing note).
///  2. **The surface's gesture path, against a recorder.** What the view calls
///     (`zoom(_:)`, `pinch(to:)`, `pinchEnded()`, `focus(atDevicePoint:)`,
///     `toggleFocusLock()`) and what that asks of the running session — plus
///     the one rule that matters most for honesty: the surface republishes the
///     factor the **device applied**, not the one the gesture asked for.
///  3. **The view's own UI, where a unit host can check it.** A source scan for
///     the controls, their identifiers and the layer-side conversion, the
///     reserved strip's arithmetic, and one rendered pixel check that the
///     controls are drawn in the strip the placement is told to avoid.
///
/// **What this suite cannot prove.** A simulator has one camera and it does not
/// switch lenses, so nothing here exercises a real wide→telephoto hand-over or
/// the platform's close-subject fallback. What is asserted is the input the
/// platform switches on (`videoZoomFactor` crossing a published
/// `virtualDeviceSwitchOverVideoZoomFactors`) and the device discovery that
/// makes a virtual device the one in use. The hardware behaviour needs the
/// owner's iPhone 14 Pro Max.
final class LiveCameraZoomModelTests: XCTestCase {

    // MARK: - The bounds

    func testTheBoundsAreTheAppsNarrowedToWhatTheRunningDeviceReports() {
        XCTAssertEqual(LiveCameraZoomModel.effectiveBounds(configMin: 1, configMax: 8,
                                                           deviceRange: 1...6),
                       1...6,
                       "a device whose own ceiling is lower than the app's narrows it")
        XCTAssertEqual(LiveCameraZoomModel.effectiveBounds(configMin: 1, configMax: 8,
                                                           deviceRange: nil),
                       1...8,
                       "with no device (before the session is configured) the app's own bounds stand")
    }

    func testADeviceWhoseWidestViewIsTighterThanTheAppsFloorNarrowsTheFloorRatherThanInvertingTheRange() {
        // A long-lens device: its widest view is already 2×. The floor moves to
        // the device's own — one reachable factor, a disabled control, no
        // trapping range.
        let bounds = LiveCameraZoomModel.effectiveBounds(configMin: 1, configMax: 8,
                                                         deviceRange: 2...4)
        XCTAssertEqual(bounds, 2...4)
        let model = LiveCameraZoomModel(config: .default, factor: 1,
                                        deviceRange: 2...4, deviceSwitchOverFactors: [])
        XCTAssertEqual(model.factor, 2)
        XCTAssertFalse(model.canZoomWider, "there is nothing wider than this device's widest view")
        XCTAssertTrue(model.canZoomCloser)
    }

    func testAFactorThatIsNotARealNumberLandsOnARealFactor() {
        // A degenerate pinch must not propagate: the widest view is the factor
        // an elder can always recognise, and it is never a crash.
        XCTAssertEqual(LiveCameraZoomModel.clamped(.nan, to: 1...8), 1)
        XCTAssertEqual(LiveCameraZoomModel.clamped(.infinity, to: 1...8), 1)
        XCTAssertEqual(LiveCameraZoomModel.clamped(-.infinity, to: 1...8), 1)
        XCTAssertEqual(LiveCameraZoomModel.clamped(12, to: 1...8), 8)
        XCTAssertEqual(LiveCameraZoomModel.clamped(0.1, to: 1...8), 1)
    }

    func testTheFactorStartsAtTheConfiguredOpeningZoomInsideTheBounds() {
        var config = LiveTranslateConfig.default
        config.initialVideoZoom = 1.5

        XCTAssertEqual(LiveCameraZoomModel(config: config).factor, 1.5)
        XCTAssertEqual(LiveCameraZoomModel(config: config, factor: 99,
                                           deviceRange: 1...6, deviceSwitchOverFactors: []).factor, 6,
                       "a restored factor the device cannot deliver is clamped, never assigned")
    }

    // MARK: - Stepping

    func testAPressMovesByTheConfiguredStepAndStopsAtTheBounds() {
        var config = LiveTranslateConfig.default
        config.zoomStep = 0.5

        var model = LiveCameraZoomModel(config: config, factor: 1)
        model = model.stepping(.closer)
        XCTAssertEqual(model.factor, 1.5)
        model = model.stepping(.wider)
        XCTAssertEqual(model.factor, 1, "a press either way is the same size step")
        model = model.stepping(.wider)
        XCTAssertEqual(model.factor, 1, "the bottom of the range is a disabled control, not a jump")

        var atTop = LiveCameraZoomModel(config: config, factor: 8)
        atTop = atTop.stepping(.closer)
        XCTAssertEqual(atTop.factor, 8)
    }

    func testAPressThatWouldCrossALensSwitchLandsOnItInsteadOfPassingIt() {
        // The platform hands the picture from the ultra-wide to the wide at 2×
        // (the standard dual-wide switch), and a step of 0.6 from 1.6 would land
        // at 2.2 — past the only place a lens changes, at a factor that belongs
        // to the *next* lens's digital range.
        var config = LiveTranslateConfig.default
        config.zoomStep = 0.6
        let device = CameraZoomCapabilities(range: 1...6, switchOverFactors: [2, 4])

        var model = LiveCameraZoomModel(config: config, factor: 1.6,
                                        deviceRange: device.range,
                                        deviceSwitchOverFactors: device.switchOverFactors)
        model = model.stepping(.closer)
        XCTAssertEqual(model.factor, 2, "the press that reaches the lens switch is the press that shows it")

        // And the same on the way down: from 2.4 a 0.6 step would pass 2×.
        var falling = LiveCameraZoomModel(config: config, factor: 2.4,
                                          deviceRange: device.range,
                                          deviceSwitchOverFactors: device.switchOverFactors)
        falling = falling.stepping(.wider)
        XCTAssertEqual(falling.factor, 2, "a step never steps over a lens switch on the way out either")
    }

    func testTheControlsAreDisabledAtTheEndsOfTheRange() {
        var config = LiveTranslateConfig.default
        config.initialVideoZoom = 1
        let atFloor = LiveCameraZoomModel(config: config, factor: 1)
        XCTAssertTrue(atFloor.canZoomCloser)
        XCTAssertFalse(atFloor.canZoomWider)

        let atCeiling = LiveCameraZoomModel(config: config, factor: 8)
        XCTAssertFalse(atCeiling.canZoomCloser)
        XCTAssertTrue(atCeiling.canZoomWider)
    }

    // MARK: - Pinching

    func testAPinchIsMeasuredFromTheFactorTheGestureStartedAt() {
        let model = LiveCameraZoomModel(config: .default, factor: 1, deviceRange: 1...6)

        // Two samples of one pinch: the second is not compounded on the first
        // (the recogniser's scale is already cumulative), so the same movement
        // travels the same distance however often it is sampled.
        XCTAssertEqual(model.pinched(by: 1.2, from: model).factor, 1.2)
        XCTAssertEqual(model.pinched(by: 1.8, from: model).factor, 1.8)
    }

    func testAPinchReleaseSnapsOntoALensSwitchItStoppedNear() {
        let device = CameraZoomCapabilities(range: 1...6, switchOverFactors: [2, 4])
        let near = LiveCameraZoomModel(config: .default, factor: 1.94,
                                       deviceRange: device.range,
                                       deviceSwitchOverFactors: device.switchOverFactors)
        XCTAssertEqual(near.snappedForRelease().factor, 2,
                       "a release that stopped beside a lens switch lands on it, so the readout and the picture agree")

        let far = LiveCameraZoomModel(config: .default, factor: 2.9,
                                      deviceRange: device.range,
                                      deviceSwitchOverFactors: device.switchOverFactors)
        XCTAssertEqual(far.snappedForRelease().factor, 2.9,
                       "a release in open ground is left exactly where the fingers stopped")
    }

    func testASingleLensDeviceNeverSnapsBecauseItHasNothingToSnapTo() {
        let model = LiveCameraZoomModel(config: .default, factor: 1.95,
                                        deviceRange: 1...6, deviceSwitchOverFactors: [])
        XCTAssertEqual(model.snappedForRelease().factor, 1.95)
        XCTAssertEqual(model.lensIndex, 0)
        XCTAssertEqual(model.lensCount, 1)
    }

    // MARK: - Reading the lens

    func testTheLensIndexAndCountFollowTheSwitchOverFactors() {
        let model = LiveCameraZoomModel(config: .default, factor: 1,
                                        deviceRange: 1...6, deviceSwitchOverFactors: [2, 4])
        XCTAssertEqual(model.lensCount, 3, "three constituents, two hand-overs")
        XCTAssertEqual(model.withFactor(1).lensIndex, 0)
        XCTAssertEqual(model.withFactor(2).lensIndex, 1, "the switch factor is the new lens's own view")
        XCTAssertEqual(model.withFactor(3.9).lensIndex, 1)
        XCTAssertEqual(model.withFactor(4).lensIndex, 2)
    }

    func testASwitchOverFactorOutsideTheReachableRangeIsNotCounted() {
        // The device publishes its factors for every constituent; a factor the
        // elder can never reach (the app's ceiling is below it) is not a lens
        // this surface can show, and counting it would draw a lens count the
        // controls cannot reach.
        let model = LiveCameraZoomModel(config: .default, factor: 1,
                                        deviceRange: 1...3, deviceSwitchOverFactors: [2, 6])
        XCTAssertEqual(model.switchOverFactors, [2])
        XCTAssertEqual(model.lensCount, 2)
    }

    func testTheReadoutIsTheDisplayFactorWithATrailingZeroDropped() {
        var config = LiveTranslateConfig.default
        config.minVideoZoom = 1

        XCTAssertEqual(LiveCameraZoomModel(config: config, factor: 1).label, "1×")
        XCTAssertEqual(LiveCameraZoomModel(config: config, factor: 1.5).label, "1.5×")
        XCTAssertEqual(LiveCameraZoomModel(config: config, factor: 2.5).label, "2.5×")
        XCTAssertEqual(LiveCameraZoomModel.zoomSuffix, "×")
        XCTAssertEqual(LiveCameraZoomModel.wholeNumberSuffixLength, 2,
                       "the '.0' a whole factor's one-decimal form ends with")
    }

    func testTheReadoutIsTheSystemsOwnFactorWhenTheDeviceShowsOne() {
        // The device's readout unit (`displayMultiplier`): the number the system
        // camera prints for a lens. The readout follows it — the model's own
        // arithmetic stays in the device's raw factor space.
        let model = LiveCameraZoomModel(config: .default, factor: 2,
                                        deviceRange: 1...8, deviceSwitchOverFactors: [2],
                                        displayMultiplier: 0.5)
        XCTAssertEqual(model.label, "1×", "the factor the Camera app would print for this same lens")
        XCTAssertEqual(model.factor, 2, "display only: the factor the device is asked for is unchanged")
        XCTAssertEqual(model.bounds, 2...8,
                       "the config's own 1×...8×, in this device's factors and narrowed by its ceiling "
                       + "— which on this device reaches 4× on the control, not the 8× the app allows")
    }

    func testTheReadoutUnitIsDerivedFromTheDevicesOwnGeometry() {
        // The unit is not a constant: a phone that starts at its ultra-wide
        // shows the wide camera as 1×, and the factor at which the platform
        // hands the picture to that camera is the device's own statement of
        // where "1×" is. A device whose widest lens *is* the wide camera needs
        // no conversion at all.
        let ultraWideWidest = CameraZoomCapabilities(range: 1...8,
                                                     switchOverFactors: [2, 6],
                                                     widestLensIsUltraWide: true)
        XCTAssertEqual(ultraWideWidest.displayMultiplier, 0.5,
                       "the hand-over at 2 is where the system readout says 1×")

        let model = LiveCameraZoomModel(config: .default,
                                        factor: ultraWideWidest.range?.upperBound,
                                        deviceRange: ultraWideWidest.range,
                                        deviceSwitchOverFactors: ultraWideWidest.switchOverFactors,
                                        displayMultiplier: ultraWideWidest.displayMultiplier)
        XCTAssertEqual(model.label, "4×",
                       "raw 8 on this device is the number the Camera app would print for it")

        let wideWidest = CameraZoomCapabilities(range: 1...8,
                                                switchOverFactors: [2],
                                                widestLensIsUltraWide: false)
        XCTAssertEqual(wideWidest.displayMultiplier, 1,
                       "raw 1 is already the wide camera: there is nothing to convert")

        XCTAssertEqual(CameraZoomCapabilities.unknown.displayMultiplier, 1,
                       "no device, no conversion")
        XCTAssertEqual(CameraZoomCapabilities(range: 1...8, switchOverFactors: [],
                                              widestLensIsUltraWide: true).displayMultiplier, 1,
                       "an ultra-wide with no reported hand-over factor has no anchor: never divide by nothing")
    }

    // MARK: - The unit the config is written in

    /// The owner's iPhone 14 Pro Max, in the numbers: a triple camera whose
    /// widest lens is the ultra-wide, so the device's own factor 1 is the
    /// "0.5×" the system camera prints, the wide camera the config's 1× means
    /// is raw 2, and the telephoto the readout calls 3× is raw 6.
    private var tripleCamera: CameraZoomCapabilities {
        CameraZoomCapabilities(range: 1...16, switchOverFactors: [2, 6],
                               widestLensIsUltraWide: true)
    }

    private func zoomModel(config: LiveTranslateConfig = .default,
                           device: CameraZoomCapabilities,
                           factor: Double? = nil) -> LiveCameraZoomModel {
        LiveCameraZoomModel(config: config, factor: factor,
                            deviceRange: device.range,
                            deviceSwitchOverFactors: device.switchOverFactors,
                            displayMultiplier: device.displayMultiplier)
    }

    /// Every zoom key is in the elder's unit, and the model converts them into
    /// the device's on the way in — once, so that the readout, the controls and
    /// the numbers the platform switches lenses at all describe one picture.
    func testTheConfigsZoomKeysAreConvertedIntoTheDevicesOwnFactors() {
        let device = tripleCamera
        let zoom = zoomModel(device: device)

        XCTAssertEqual(device.displayMultiplier, 0.5, "this device's raw 1 is the readout's 0.5×")
        XCTAssertEqual(zoom.bounds, 2...16, "the config's 1×...8× as factors the device takes")
        XCTAssertEqual(zoom.step, 1, "half a factor of the readout is a whole factor of this device's")
        XCTAssertEqual(zoom.factor, 2, "the session opens on the wide camera, which this device calls 2")
        XCTAssertEqual(zoom.label, "1×", "and the control says what the elder asked for")
        XCTAssertEqual(zoom.switchOverFactors, [2, 6],
                       "the device's published factors, untouched by the config's unit")
    }

    /// The presses the elder feels: half a readout factor each, landing on the
    /// telephoto at the factor the readout calls 3× — which is where the
    /// platform itself hands the picture over on this device.
    func testAStepInTheReadoutUnitLandsOnTheSwitchTheReadoutShows() {
        var zoom = zoomModel(device: tripleCamera)
        var readouts: [String] = []
        for _ in 1...4 {
            zoom = zoom.stepping(.closer)
            readouts.append(zoom.label)
        }

        XCTAssertEqual(readouts, ["1.5×", "2×", "2.5×", "3×"])
        XCTAssertEqual(zoom.factor, 6, "the telephoto's own factor on this device")
        XCTAssertEqual(zoom.lensIndex, 2, "and the third lens is the live one, as the readout says")
        XCTAssertEqual(zoom.bounds.upperBound, 16,
                       "eight more readout steps are still available past the telephoto")
    }

    /// The floor is the wide camera; the ultra-wide is one key away, for the
    /// household that wants the whole shelf in frame instead of one packet.
    func testTheFloorIsTheWideCameraAndTheUltraWideIsOneKeyAway() {
        let device = tripleCamera
        XCTAssertEqual(zoomModel(device: device).bounds.lowerBound, 2,
                       "the shipped floor is the wide camera, never the ultra-wide")

        var config = LiveTranslateConfig.default
        config.minVideoZoom = 0.5
        let widened = zoomModel(config: config, device: device)
        XCTAssertEqual(widened.bounds.lowerBound, 1, "the ultra-wide, on the device's own floor")
        XCTAssertEqual(widened.withFactor(1).label, "0.5×",
                       "the same number the system camera's readout shows for that lens")
        XCTAssertEqual(widened.withFactor(1).lensIndex, 0)
    }

    /// The two conversions the capabilities own, and the one case with nothing
    /// to convert: a device with no published hand-over has no unit of its own,
    /// so the readout's numbers are already the device's.
    func testTheCapabilitiesConvertAConfigBothWays() {
        let device = tripleCamera
        XCTAssertEqual(device.deviceFactor(forReadout: 1), 2)
        XCTAssertEqual(device.deviceFactor(forReadout: 8), 16)
        XCTAssertEqual(device.deviceFactor(forReadout: 0.5), 1)
        XCTAssertEqual(device.rawBounds(for: .default), 2...16)
        XCTAssertEqual(device.openingFactor(for: .default), 2,
                       "what the session opens the device at: the wide camera, not the ultra-wide")

        let singleLens = CameraZoomCapabilities(range: 1...8, switchOverFactors: [])
        XCTAssertEqual(singleLens.rawBounds(for: .default), 1...8, "nothing to convert")
        XCTAssertEqual(singleLens.openingFactor(for: .default), 1)

        // And the device's own limits still close in over the converted config:
        // a phone whose format stops at raw 6 gives the elder 1×...3×.
        let shortReach = CameraZoomCapabilities(range: 1...6, switchOverFactors: [2],
                                                widestLensIsUltraWide: true)
        XCTAssertEqual(shortReach.rawBounds(for: .default), 2...6)
        XCTAssertEqual(shortReach.openingFactor(for: .default), 2)
    }

    /// A unit of zero or less is not a unit: the conversion passes the value
    /// through rather than turning the config into infinities the platform
    /// would trap on.
    func testAUnitThatCannotDivideLeavesTheValueAlone() {
        XCTAssertEqual(LiveCameraZoomModel.deviceFactor(forReadout: 2, displayMultiplier: 0), 2)
        XCTAssertEqual(LiveCameraZoomModel.deviceFactor(forReadout: 2, displayMultiplier: -1), 2)
        XCTAssertEqual(LiveCameraZoomModel.deviceFactor(forReadout: 2, displayMultiplier: 1), 2)
        XCTAssertEqual(LiveCameraZoomModel.deviceFactor(forReadout: 2, displayMultiplier: 0.5), 4)
    }

    func testTheReadoutUsesTheDecimalPointRatherThanALocalisedSeparator() {
        // `String(format:)` without a locale is not localised, so the readout is
        // the same "1.5" the system camera shows — never a comma decimal
        // separator that would read as a different number mid-gesture.
        let label = LiveCameraZoomModel(config: .default, factor: 1.5).label
        XCTAssertEqual(label, "1.5×")
        XCTAssertFalse(label.contains(","))
    }

    // MARK: - The surface the view renders

    func testAStepAsksTheSessionForTheNextFactorAndAdoptsWhatTheDeviceApplied() {
        let recorder = ZoomSurfaceRecorder()
        recorder.capabilities = CameraZoomCapabilities(range: 1...6, switchOverFactors: [])
        recorder.deviceAnswer = { _ in 3 }
        let surface = recorder.makeSurface()

        surface.zoom(.closer)

        XCTAssertEqual(recorder.appliedFactors, [1.5], "the step the model decided")
        XCTAssertEqual(surface.model.factor, 3,
                       "the readout shows the factor the device took, never the one the gesture asked for")
    }

    func testAGestureThatMovesNothingIsNotSentToTheDevice() {
        var config = LiveTranslateConfig.default
        config.initialVideoZoom = 6   // the top of this device's range
        let recorder = ZoomSurfaceRecorder()
        recorder.capabilities = CameraZoomCapabilities(range: 1...6, switchOverFactors: [])
        let surface = recorder.makeSurface(config: config)

        surface.zoom(.closer)

        XCTAssertTrue(recorder.appliedFactors.isEmpty,
                      "a press that cannot move must not lock, configure and unlock a device to do nothing")
    }

    func testTheSurfaceAsksTheDeviceForItsBoundsOnEveryInteraction() {
        // The valid range follows the device's *active format*, which the
        // platform may change under a running session: a step bounded by a
        // range read once would send a factor the format no longer allows.
        let recorder = ZoomSurfaceRecorder()
        recorder.capabilities = CameraZoomCapabilities(range: 1...2, switchOverFactors: [])
        let surface = recorder.makeSurface()

        surface.zoom(.closer)
        XCTAssertEqual(surface.model.factor, 1.5)
        XCTAssertEqual(surface.model.bounds, 1...2)

        recorder.capabilities = CameraZoomCapabilities(range: 1...8, switchOverFactors: [])
        surface.zoom(.closer)
        XCTAssertEqual(recorder.appliedFactors, [1.5, 2],
                       "the second press is bounded by the range the device reports now")
        XCTAssertEqual(surface.model.bounds, 1...8)
    }

    func testAPinchCarriesOneBaseForTheWholeGestureAndDropsItOnRelease() {
        let recorder = ZoomSurfaceRecorder()
        recorder.capabilities = CameraZoomCapabilities(range: 1...6, switchOverFactors: [2, 4])
        let surface = recorder.makeSurface()

        surface.pinch(to: 1.5)
        surface.pinch(to: 2)
        surface.pinchEnded()
        surface.pinchEnded()

        XCTAssertEqual(recorder.appliedFactors, [1.5, 2],
                       "one gesture, one base: 1 × 2 is 2, not 1 × 1.5 × 2; a release at a switch is not a move")

        surface.pinch(to: 0.5)
        XCTAssertEqual(recorder.appliedFactors, [1.5, 2, 1],
                       "the next pinch starts from where the last one left the factor")
    }

    func testTheSurfacePublishesWhatTheDeviceAppliedAPinchReleaseIncluded() {
        let recorder = ZoomSurfaceRecorder()
        recorder.capabilities = CameraZoomCapabilities(range: 1...6, switchOverFactors: [2])
        recorder.deviceAnswer = { Swift.min($0, 2) }   // the device stops at the switch
        let surface = recorder.makeSurface()

        surface.pinch(to: 3)        // asks for 3, the device delivers 2
        XCTAssertEqual(surface.model.factor, 2)

        surface.pinchEnded()
        XCTAssertEqual(surface.model.factor, 2)
        XCTAssertEqual(recorder.appliedFactors, [3],
                       "the release did not move — the snap landed on the factor already in effect")
    }

    func testAFocusTapAsksForFocusAndReleasesTheLock() {
        var config = LiveTranslateConfig.default
        config.focusLockDefault = true
        let recorder = ZoomSurfaceRecorder()
        let surface = recorder.makeSurface(config: config)
        let point = CGPoint(x: 0.25, y: 0.75)

        surface.focus(atDevicePoint: point)

        XCTAssertEqual(recorder.focusPoints, [point],
                       "the tap's point reaches the session's device call, unconverted — the layer already converted it")
        XCTAssertFalse(surface.isFocusLocked, "tapping a new label is asking to look at it, not to hold the last lock")
        XCTAssertTrue(recorder.lockRequests.isEmpty,
                      "the release is the one-shot focus itself, not a second device call")
    }

    func testTheLockToggleFlipsTheControlAndTellsTheSession() {
        let recorder = ZoomSurfaceRecorder()
        let surface = recorder.makeSurface()
        XCTAssertFalse(surface.isFocusLocked, "the config's default is the initial state")

        surface.toggleFocusLock()
        XCTAssertTrue(surface.isFocusLocked)
        surface.toggleFocusLock()
        XCTAssertFalse(surface.isFocusLocked)

        XCTAssertEqual(recorder.lockRequests, [true, false])
    }

    func testTheLockStartsHeldWhenTheConfigSaysSoAndIsToldWhenItMoves() {
        var config = LiveTranslateConfig.default
        config.focusLockDefault = true
        let recorder = ZoomSurfaceRecorder()
        let surface = recorder.makeSurface(config: config)
        XCTAssertTrue(surface.isFocusLocked, "the config's default is the state the control opens in")

        // Told, not inferred: the session keeps its own mirror of the lock
        // (its subject-area re-arm reads it), and a path that moves the lock
        // through the session alone must leave this control showing the truth.
        surface.focusLockChanged(to: false)
        XCTAssertFalse(surface.isFocusLocked)
        XCTAssertTrue(recorder.lockRequests.isEmpty,
                      "being told is not a device call — the session already knows")

        surface.focusLockChanged(to: false)
        XCTAssertFalse(surface.isFocusLocked, "and being told the same thing twice changes nothing")
    }

    // MARK: - The window, the pan and the anchored pinch (owner report, 2026-09-18)

    /// A model for the arithmetic below, on a device with no lens switch and a
    /// long range: the numbers asserted here are the window's own, not a
    /// switch-over factor's.
    private func zoomModel(at factor: Double,
                           config: LiveTranslateConfig = .default,
                           pan: CGPoint = .zero) -> LiveCameraZoomModel {
        LiveCameraZoomModel(config: config, factor: factor, pan: pan,
                            deviceRange: 1...8, deviceSwitchOverFactors: [])
    }

    /// Core Animation's own rule, written out so this suite can check the
    /// presentation's transform *as the elder's screen applies it*: a layer's
    /// affine transform is applied about its anchor point, so a point of the
    /// layer's bounds lands at `T(p) + (I - L)(anchor)` in the superlayer. The
    /// presentation's `layerTransform(anchor:)` carries exactly this
    /// correction; if it ever stopped, the picture would sit offset from the
    /// callouts by `(1 - scale) × half the container`.
    private func drawnPoint(_ point: CGPoint, by transform: CGAffineTransform,
                            anchor: CGPoint) -> CGPoint {
        let applied = point.applying(transform)
        return CGPoint(x: applied.x + (1 - transform.a) * anchor.x,
                       y: applied.y + (1 - transform.d) * anchor.y)
    }

    /// A container and a picture rect to map through: a 390 × 844 phone with a
    /// 4:3 frame in it, letterboxed by the app's own aspect-fit arithmetic.
    private func pictureRect(_ size: CGSize = CGSize(width: 390, height: 844)) -> CGRect {
        ApplianceOverlayMapper.displayedImageRect(containerSize: size,
                                                  imageSize: CGSize(width: 1280, height: 720))
    }

    func testTheWindowIsTheWholeFrameAtTheRampsStartAndTheConfiguredFractionAtItsEnd() {
        XCTAssertEqual(zoomModel(at: 1).cropFraction, 1,
                       "at the ramp's start there is nothing to pan to, so nothing is cropped")
        XCTAssertTrue(zoomModel(at: 1).crop.isWhole)
        XCTAssertTrue(zoomModel(at: 1).showsWholeFrame)
        XCTAssertEqual(zoomModel(at: 1).panLimit, 0, "and no room to move")

        XCTAssertEqual(zoomModel(at: 2.5).cropFraction, 0.85, accuracy: 1e-12,
                       "halfway up a 1×–4× ramp is halfway from the whole frame to the configured 0.7")
        XCTAssertEqual(zoomModel(at: 4).cropFraction, 0.7, accuracy: 1e-12)
        XCTAssertEqual(zoomModel(at: 8).cropFraction, 0.7, accuracy: 1e-12,
                       "past the ramp's end the window stays at the configured fraction")
        XCTAssertFalse(zoomModel(at: 8).showsWholeFrame)
    }

    func testTheWindowRampIsLinearInTheReadoutAndADegenerateRampIsNoWindow() {
        var config = LiveTranslateConfig.default
        config.panStartZoom = 2
        config.panFullZoom = 4
        config.panWindowFraction = 0.5
        let ramp = zoomModel(at: 1, config: config)

        XCTAssertEqual(ramp.windowFraction(for: 1), 1, "below the ramp's start the window is the frame")
        XCTAssertEqual(ramp.windowFraction(for: 2), 1)
        XCTAssertEqual(ramp.windowFraction(for: 3), 0.75, accuracy: 1e-12, "linear between the ends")
        XCTAssertEqual(ramp.windowFraction(for: 4), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ramp.windowFraction(for: 8), 0.5, accuracy: 1e-12)

        // The ends the wrong way round (or the same) describe no ramp: the
        // elder gets the whole frame rather than a window they cannot see out
        // of.
        config.panStartZoom = 4
        config.panFullZoom = 1
        XCTAssertEqual(zoomModel(at: 8, config: config).cropFraction, 1)
        config.panStartZoom = 2
        config.panFullZoom = 2
        XCTAssertEqual(zoomModel(at: 8, config: config).cropFraction, 1)
    }

    func testAWindowFractionThatCannotDescribeAWindowIsReadAsTheWholeFrame() {
        for fraction in [0, -0.5, 1.5, Double.nan] {
            var config = LiveTranslateConfig.default
            config.panWindowFraction = fraction
            let model = zoomModel(at: 8, config: config)
            XCTAssertEqual(model.cropFraction, 1, "\(fraction) is not a window")
            XCTAssertTrue(model.crop.isWhole)
            XCTAssertEqual(model.panLimit, 0)
        }
    }

    func testPanningTurnedOffLeavesTheWholeFrameAtEveryZoom() {
        var config = LiveTranslateConfig.default
        config.panEnabled = false
        let model = zoomModel(at: 8, config: config, pan: CGPoint(x: 0.5, y: 0.5))

        XCTAssertEqual(model.cropFraction, 1, "no window means nothing to move")
        XCTAssertTrue(model.showsWholeFrame)
        XCTAssertEqual(model.pan, .zero, "and a pan that somehow arrived is not held")
        XCTAssertEqual(model.withPan(CGPoint(x: 0.3, y: 0.3)).pan, .zero)
    }

    func testThePanIsClampedSoTheWindowNeverLeavesTheFrame() {
        let atFullRamp = zoomModel(at: 4)
        XCTAssertEqual(atFullRamp.panLimit, 0.15, accuracy: 1e-12,
                       "a 0.7 window has 0.15 of frame to move either way")

        let right = atFullRamp.withPan(CGPoint(x: 0.9, y: 0))
        XCTAssertEqual(right.pan.x, 0.15, accuracy: 1e-12)
        XCTAssertEqual(right.crop.box.xMax, 1, accuracy: 1e-12,
                       "the window's edge stops at the frame's, so nothing beyond it is ever shown")
        XCTAssertGreaterThanOrEqual(right.crop.box.xMin, 0)

        let left = atFullRamp.withPan(CGPoint(x: -0.9, y: 0))
        XCTAssertEqual(left.pan.x, -0.15, accuracy: 1e-12)
        XCTAssertEqual(left.crop.box.xMin, 0, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(left.crop.box.xMax, 1)

        // A gesture that reports a number that is not a number (a cancelled
        // recogniser, a degenerate translation) recentres rather than
        // propagating a NaN into the crop, the placement and the layer.
        XCTAssertEqual(atFullRamp.withPan(CGPoint(x: CGFloat.nan, y: CGFloat.infinity)).pan, .zero)
    }

    func testThePanRoomOpensWithTheZoomAndClosesAroundTheWholeFrame() {
        XCTAssertEqual(zoomModel(at: 1).panLimit, 0, accuracy: 1e-12)
        XCTAssertEqual(zoomModel(at: 2.5).panLimit, 0.075, accuracy: 1e-12)
        XCTAssertEqual(zoomModel(at: 4).panLimit, 0.15, accuracy: 1e-12)
        XCTAssertEqual(zoomModel(at: 8).panLimit, 0.15, accuracy: 1e-12)
    }

    func testZoomingBackOutPullsTheWindowHomeRatherThanLeavingItAtTheFramesEdge() {
        // The elder pans to the frame's right edge at 4× and then zooms out:
        // the window that factor allows is the whole frame, and the only place
        // a whole-frame window can be is the centre.
        let panned = zoomModel(at: 4).withPan(CGPoint(x: 0.15, y: 0.15))
        let widened = panned.withFactor(1)

        XCTAssertEqual(widened.pan, .zero)
        XCTAssertTrue(widened.crop.isWhole)
        XCTAssertEqual(widened.crop.box, NormalizedBox(xMin: 0, yMin: 0, xMax: 1, yMax: 1))
    }

    func testAPinchHoldsTheFramePointUnderTheFingers() {
        // The anchoring, as arithmetic: the elder's fingers are holding a
        // *place in the picture*, and the place has to stay under them.
        let base = zoomModel(at: 2)
        XCTAssertEqual(base.cropFraction, 0.9, accuracy: 1e-12)
        let focus = CGPoint(x: 0.2, y: 0.8)          // low and to the left of the window
        let held = base.crop.framePoint(ofCropPoint: focus)

        let zoomed = base.pinched(by: 1.25, from: base, at: focus)

        XCTAssertEqual(zoomed.factor, 2.5, accuracy: 1e-12)
        XCTAssertEqual(zoomed.cropFraction, 0.85, accuracy: 1e-12)
        XCTAssertEqual(zoomed.crop.cropPoint(ofFramePoint: held).x, focus.x, accuracy: 1e-12,
                       "the frame point under the finger is still under the finger")
        XCTAssertEqual(zoomed.crop.cropPoint(ofFramePoint: held).y, focus.y, accuracy: 1e-12)
        XCTAssertGreaterThan(abs(zoomed.pan.x), 0,
                             "and holding a place that is not the centre is what moves the window")
    }

    func testAPinchAtTheCentreOfThePictureNeedsNoPanAndOneAtTheEdgeMovesTheWindowTheOtherWay() {
        let base = zoomModel(at: 2)

        let centred = base.pinched(by: 2, from: base, at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(centred.pan, .zero,
                       "zooming about the middle of the window is the buttons' own behaviour")

        // A finger on the window's left edge: the window has to slide left to
        // keep that edge's content still, and the tap that focuses where the
        // elder is looking follows it.
        let left = base.pinched(by: 2, from: base, at: CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(left.pan.x, -0.1, accuracy: 1e-12)
        let right = base.pinched(by: 2, from: base, at: CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(right.pan.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(left.pan.y, 0, accuracy: 1e-12, "a finger on the horizontal centre moves no window vertically")
    }

    func testAPinchThatAsksForMoreRoomThanTheFrameHasIsClampedToTheFrame() {
        // Zooming *in* from an edge-panned window wants more room than the
        // frame has: the picture stops following the fingers at the frame's
        // edge, because the alternative is showing frame the camera never
        // captured.
        let panned = zoomModel(at: 4).withPan(CGPoint(x: 0.15, y: 0))
        let released = panned.pinched(by: 0.6, from: panned, at: CGPoint(x: 0.99, y: 0.5))

        XCTAssertEqual(released.cropFraction, 0.86, accuracy: 1e-12)
        XCTAssertEqual(released.pan.x, released.panLimit, accuracy: 1e-12,
                       "the window stops at the frame's edge rather than past it")
        XCTAssertEqual(released.crop.box.xMax, 1, accuracy: 1e-12)
        XCTAssertTrue(released.crop.intersects(NormalizedBox(xMin: 0.99, yMin: 0, xMax: 1, yMax: 1)),
                      "and the content the elder was pinching is still on screen")
    }

    func testPinchSensitivityRaisesTheRecognisersScaleToTheConfiguredPower() {
        var config = LiveTranslateConfig.default
        config.pinchSensitivity = 2
        let gentle = zoomModel(at: 1, config: config)

        XCTAssertEqual(gentle.pinched(by: 1.5, from: gentle).factor, 2.25, accuracy: 1e-12,
                       "1.5² — the key changes how much picture the same fingers buy, not what a scale means")

        for sensitivity in [0, -1, Double.nan] {
            config.pinchSensitivity = sensitivity
            let model = zoomModel(at: 1, config: config)
            XCTAssertEqual(model.pinched(by: 1.5, from: model).factor, 1.5, accuracy: 1e-12,
                           "\(sensitivity) is not a power: the scale itself is used")
        }

        // A pinch that reports a scale that is not a positive number cannot
        // move anything: a cancelled recogniser must not widen the picture.
        XCTAssertEqual(gentle.pinched(by: 0, from: gentle).factor, 1)
        XCTAssertEqual(gentle.pinched(by: .nan, from: gentle).factor, 1)
    }

    // MARK: - One map for the picture and the callouts

    func testThePresentationMapsAFramePointToTheContainerAndBack() {
        let picture = pictureRect()
        let presentation = zoomModel(at: 4).withPan(CGPoint(x: 0.15, y: -0.15))
            .presentation(in: picture)

        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1),
                      CGPoint(x: 0.31, y: 0.72)] {
            let container = presentation.containerPoint(ofFramePoint: point)
            let back = presentation.framePoint(ofContainerPoint: container)
            XCTAssertEqual(back.x, point.x, accuracy: 1e-12)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-12)
        }

        // What the window shows fills the picture rect and nothing else: the
        // window's own corners are the letterbox's corners, and a frame point
        // the window has moved away from has no place on screen.
        let topLeft = presentation.containerPoint(ofFramePoint:
            CGPoint(x: presentation.crop.box.xMin, y: presentation.crop.box.yMin))
        XCTAssertEqual(topLeft.x, picture.minX, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, picture.minY, accuracy: 1e-9)
        XCTAssertFalse(picture.contains(presentation.containerPoint(ofFramePoint: .zero)),
                       "the corner the window moved away from is off the picture, not drawn at its edge")
    }

    func testTheLayerTransformDrawsEveryFramePointWhereThePlacementPutsIt() {
        let picture = pictureRect()
        let anchor = CGPoint(x: picture.midX, y: picture.midY)
        let crops = [LiveCameraCrop.whole,
                     zoomModel(at: 2).crop,
                     zoomModel(at: 4).withPan(CGPoint(x: 0.15, y: 0.15)).crop,
                     zoomModel(at: 4).withPan(CGPoint(x: -0.15, y: 0)).crop]

        for crop in crops {
            let presentation = LiveCameraPresentation(crop: crop, pictureRect: picture)
            let transform = presentation.layerTransform(anchor: anchor)
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.5, y: 0.5),
                          CGPoint(x: 1, y: 1)] {
                // The layer's own drawing of the frame point is the *unzoomed*
                // container point — `captureDevicePointConverted`'s space — and
                // what the elder sees is that point through the transform.
                let live = presentation.unzoomedContainerPoint(ofFramePoint: point)
                let drawn = drawnPoint(live, by: transform, anchor: anchor)
                let placed = presentation.containerPoint(ofFramePoint: point)
                XCTAssertEqual(drawn.x, placed.x, accuracy: 1e-9,
                               "the layer and the placement must agree about \(point) at \(crop)")
                XCTAssertEqual(drawn.y, placed.y, accuracy: 1e-9)
            }
        }
    }

    func testABubbleGluedToARegionStaysGluedWhileThePictureIsZoomedAndPanned() {
        // The owner's requirement, as arithmetic: a callout is drawn from its
        // *frame* box, and the picture is drawn from the same crop. If the two
        // maps are one map, a callout over a sign is over the sign at every
        // window.
        let picture = pictureRect()
        let anchor = CGPoint(x: picture.midX, y: picture.midY)
        let region = NormalizedBox(xMin: 0.42, yMin: 0.31, xMax: 0.58, yMax: 0.44)
        let crops = [LiveCameraCrop.whole,
                     zoomModel(at: 1.6).crop,
                     zoomModel(at: 3).crop,
                     zoomModel(at: 4).withPan(CGPoint(x: 0.15, y: -0.15)).crop]

        for crop in crops {
            XCTAssertTrue(crop.intersects(region),
                          "the region is on screen at \(crop), so the glue is a fact about what is drawn")
            let presentation = LiveCameraPresentation(crop: crop, pictureRect: picture)
            let transform = presentation.layerTransform(anchor: anchor)
            let placement = LiveOverlayPlacement.screenRect(for: region,
                                                            containerSize: CGSize(width: 390, height: 844),
                                                            framePixelSize: CGSize(width: 1280, height: 720),
                                                            crop: crop)
            let origin = drawnPoint(presentation.unzoomedContainerPoint(
                ofFramePoint: CGPoint(x: region.xMin, y: region.yMin)), by: transform, anchor: anchor)
            let corner = drawnPoint(presentation.unzoomedContainerPoint(
                ofFramePoint: CGPoint(x: region.xMax, y: region.yMax)), by: transform, anchor: anchor)

            XCTAssertEqual(origin.x, placement.minX, accuracy: 1e-9)
            XCTAssertEqual(origin.y, placement.minY, accuracy: 1e-9)
            XCTAssertEqual(corner.x, placement.maxX, accuracy: 1e-9)
            XCTAssertEqual(corner.y, placement.maxY, accuracy: 1e-9)
        }
    }

    func testADragMovesThePictureWithTheFingerOneForOne() {
        // The pan is a display-space offset, so a drag moves the *content*
        // under the finger by the finger's own distance — whatever the zoom,
        // because the crop cancels: the visible window is drawn in the picture
        // rect at every factor.
        let picture = pictureRect()
        let base = zoomModel(at: 4)
        let presentation = base.presentation(in: picture)

        let translation = CGPoint(x: 30, y: -40)
        let offset = presentation.panOffset(ofContainerTranslation: translation)
        XCTAssertEqual(offset.x, -translation.x / picture.width * base.cropFraction, accuracy: 1e-12)
        XCTAssertEqual(offset.y, -translation.y / picture.height * base.cropFraction, accuracy: 1e-12)
        XCTAssertLessThan(offset.x, 0,
                          "the window moves the other way, which is what makes the picture follow the finger")
        XCTAssertLessThan(abs(offset.x), abs(translation.x) / picture.width,
                          "and a narrow window moves less than the finger, because every frame fraction "
                          + "is drawn bigger than it was")

        // The elder's own proof: the frame point they grabbed is where their
        // finger went, and it is still on screen (the drag stayed in bounds).
        let grabbed = CGPoint(x: 0.5, y: 0.5)   // the window's centre
        let before = presentation.containerPoint(ofFramePoint: grabbed)
        let after = base.withPan(CGPoint(x: base.pan.x + offset.x, y: base.pan.y + offset.y))
            .presentation(in: picture).containerPoint(ofFramePoint: grabbed)
        XCTAssertEqual(after.x - before.x, translation.x, accuracy: 1e-9)
        XCTAssertEqual(after.y - before.y, translation.y, accuracy: 1e-9)
    }

    func testATapIsTakenBackThroughTheWindowBeforeTheLayerConvertsIt() {
        // The layer knows the aspect fit and the device's zoom; it knows
        // nothing about the window. So a tap on the glass is mapped back to the
        // frame, and then to the point the *unzoomed* picture would draw it at,
        // which is the only container point the layer's conversion is defined
        // for.
        let picture = pictureRect()
        let base = zoomModel(at: 1)
        let zoomed = zoomModel(at: 4).withPan(CGPoint(x: 0.15, y: 0))
        let glass = CGPoint(x: picture.midX, y: picture.midY)

        let unzoomed = base.presentation(in: picture)
        let panned = zoomed.presentation(in: picture)

        XCTAssertEqual(panned.framePoint(ofContainerPoint: glass).x, 0.65, accuracy: 1e-12,
                       "the middle of the glass is the middle of the *window*, which is past the frame's "
                       + "own middle once the window has moved right")
        XCTAssertEqual(panned.unzoomedPoint(ofContainerPoint: glass).x,
                       unzoomed.containerPoint(ofFramePoint: panned.framePoint(ofContainerPoint: glass)).x,
                       accuracy: 1e-9,
                       "and what the layer is handed is where the *unzoomed* picture draws it")
        XCTAssertNotEqual(panned.unzoomedPoint(ofContainerPoint: glass).x, glass.x,
                          "which is not the point on the glass: the layer would focus the wrong place otherwise")
    }

    // MARK: - The surface's pan path

    func testADragIsMeasuredFromWhereItStartedAndSurvivesTheFingerLifting() {
        let recorder = ZoomSurfaceRecorder()
        let surface = recorder.makeSurface()
        surface.zoom(.closer)                                   // 1× → 1.5×
        surface.zoom(.closer)                                   // 1.5× → 2×
        let start = surface.model.pan

        surface.pan(to: CGPoint(x: -0.02, y: 0.01))
        surface.pan(to: CGPoint(x: -0.04, y: 0.02))
        XCTAssertEqual(surface.model.pan.x, start.x - 0.04, accuracy: 1e-12,
                       "the recogniser's translation is cumulative, so the surface adds it to one base")
        XCTAssertEqual(surface.model.pan.y, start.y + 0.02, accuracy: 1e-12)

        surface.panEnded()
        XCTAssertEqual(surface.model.pan.x, start.x - 0.04, accuracy: 1e-12,
                       "a gesture that moved the picture does not move it back")

        // A new touch is a new translation: the recogniser reports 0.01 from
        // *this* touch's start, and the surface adds it to the window the last
        // drag left behind — so the readout reads the finger's own movement,
        // not a jump back to where the first drag began.
        surface.pan(to: CGPoint(x: 0.01, y: 0))
        XCTAssertEqual(surface.model.pan.x, start.x - 0.04 + 0.01, accuracy: 1e-12,
                       "the next drag starts from where the last one left the window")
    }

    func testAThawSendsTheWindowHomeAndTheConfigCanSayNotTo() {
        let recorder = ZoomSurfaceRecorder()
        let surface = recorder.makeSurface()
        surface.zoom(.closer)
        surface.zoom(.closer)
        surface.pan(to: CGPoint(x: -0.05, y: 0))
        XCTAssertNotEqual(surface.model.pan, .zero)

        surface.sessionReleased()                               // the camera came back
        XCTAssertEqual(surface.model.pan, .zero, "the elder comes back to the middle of the frame")

        // The household that would rather come back to the same label. The
        // recorder outlives the surface: the surface's closures answer for the
        // device, and a recorder that died first would take the device with it.
        var config = LiveTranslateConfig.default
        config.panResetsOnExit = false
        let keptRecorder = ZoomSurfaceRecorder()
        let kept = keptRecorder.makeSurface(config: config)
        kept.zoom(.closer)
        kept.zoom(.closer)
        kept.pan(to: CGPoint(x: -0.05, y: 0))
        let panned = kept.model.pan
        kept.sessionReleased()
        XCTAssertEqual(kept.model.pan.x, panned.x, accuracy: 1e-12)
        XCTAssertEqual(kept.model.pan.y, panned.y, accuracy: 1e-12)
    }

    func testEveryWindowTheSurfaceSettlesOnIsTheWindowTheSessionIsTold() {
        let recorder = ZoomSurfaceRecorder()
        let surface = recorder.makeSurface()

        surface.zoom(.closer)
        surface.pinch(to: 2)
        surface.pan(to: CGPoint(x: -0.02, y: 0))
        surface.pinchEnded()

        XCTAssertEqual(recorder.crops.first, .whole,
                       "the session is told the window the surface opens at")
        XCTAssertEqual(recorder.crops.last, surface.model.crop,
                       "and every settled window after that: the last one it was told is the one the readout shows")
        let distinct = recorder.crops.filter { $0 != recorder.crops.first }.count
        XCTAssertGreaterThanOrEqual(distinct, 3,
                                    "a press, a pinch and a drag are three different windows")
    }

    /// The crop the session is told is the crop the section above says — and it
    /// is told once per *change*, not once per frame: an unchanged window is
    /// dropped by `settle`, which is what keeps a per-frame consumer from being
    /// woken by a gesture that has stopped.
    func testTheSurfaceDoesNotRepublishAWindowThatDidNotChange() {
        var config = LiveTranslateConfig.default
        config.maxVideoZoom = 2
        let recorder = ZoomSurfaceRecorder()
        let surface = recorder.makeSurface(config: config)

        let opened = recorder.crops.count                     // the window the surface opens at
        surface.zoom(.closer)                                   // 1× → 1.5×: a new window
        XCTAssertEqual(recorder.crops.count, opened + 1)
        surface.pan(to: .zero)                                  // a drag that moved nothing
        surface.panEnded()
        XCTAssertEqual(recorder.crops.count, opened + 1, "a gesture that moved nothing publishes nothing")

        surface.zoom(.closer)                                   // 1.5× → 2×: a new window
        XCTAssertEqual(recorder.crops.count, opened + 2)
        surface.zoom(.closer)                                   // at the ceiling: no move, no window
        XCTAssertEqual(recorder.crops.count, opened + 2,
                       "a press at the end of the range does not republish the window it is already at")
    }

    // MARK: - The capture layer's device mapping

    func testTheLensSetsAreDiscoveredWithTheSwitchingDevicesFirst() {
        XCTAssertEqual(CameraLensSet.discoveryOrder, [.triple, .dualWide, .wideAngle],
                       "the virtual multi-lens device first: it is the only kind that publishes "
                       + "switch-over factors and performs the close-subject fallback")
        XCTAssertEqual(CameraLensSet.allCases.count, CameraLensSet.discoveryOrder.count,
                       "the order names every case")
        XCTAssertEqual(CameraLensSet.triple.switchOverFactorCount, 2)
        XCTAssertEqual(CameraLensSet.dualWide.switchOverFactorCount, 1)
        XCTAssertEqual(CameraLensSet.wideAngle.switchOverFactorCount, 0,
                       "a single wide-angle camera has nothing to switch to")
    }

    func testTheDeviceTypePerLensSetIsTheVirtualCameraWhereOneExists() {
        XCTAssertEqual(AVFoundationCaptureLayer.deviceType(for: .triple), .builtInTripleCamera)
        XCTAssertEqual(AVFoundationCaptureLayer.deviceType(for: .dualWide), .builtInDualWideCamera)
        XCTAssertEqual(AVFoundationCaptureLayer.deviceType(for: .wideAngle), .builtInWideAngleCamera)
    }

    func testTheQualityPresetsStartAtTheRequestedQualityAndFallBackToTheUniversalOne() {
        XCTAssertEqual(LiveTranslateConfig.default.cameraQuality, .high,
                       "the owner's report is small print: the shipped quality is the sharper one")
        XCTAssertEqual(AVFoundationCaptureLayer.presets(for: .high), [.hd1280x720, .vga640x480],
                       "the sharper preset first, then the size every back camera can deliver")
        XCTAssertEqual(AVFoundationCaptureLayer.presets(for: .standard), [.vga640x480])
    }

    // MARK: - The view's own UI

    private func viewSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift"))
    }

    func testTheViewDrawsTwoStepControlsAReadoutAndAFocusLock() {
        let view = viewSource()

        XCTAssertTrue(view.contains("livetranslate.zoom.in"))
        XCTAssertTrue(view.contains("livetranslate.zoom.out"))
        XCTAssertTrue(view.contains("livetranslate.zoom.factor"))
        XCTAssertTrue(view.contains("livetranslate.focus.lock"))
        XCTAssertTrue(view.contains("zoom.zoom(direction)"),
                      "a press is the surface's step, which is the model's arithmetic")
        XCTAssertTrue(view.contains("zoom.toggleFocusLock()"))
        XCTAssertTrue(view.contains("zoom.model.label"),
                      "the readout is the model's own label, not a number the view formats")
        XCTAssertFalse(view.contains("String(format:"),
                       "the view does not format the factor — the model does, so the readout cannot drift from the maths")
    }

    func testTheControlsAreSizedFromTheTokenTableAndAreNeverLitrals() {
        let view = viewSource()

        XCTAssertTrue(view.contains("static let zoomControlDiameter = DesignTokens.minTapTargetSize + DesignTokens.interElementSpacing"),
                      "a control's size is the app's tap target plus its spacing — the one relationship the strip is computed from")
        XCTAssertGreaterThanOrEqual(LiveTranslateView.zoomControlDiameter, DesignTokens.minTapTargetSize,
                                    "and never below the app's minimum tap target")
        XCTAssertTrue(view.contains("DesignTokens.warmFont(size: DesignTokens.minBodyPointSize"),
                      "the readout is drawn at the app's body floor")
    }

    func testTheZoomStripStandsOnTheOverlaysOwnStripAndNeverReservesAnImpossibleRect() throws {
        let size = CGSize(width: 390, height: 844)
        let strip = try XCTUnwrap(LiveTranslateView.zoomChromeRects(containerSize: size).first)
        XCTAssertEqual(strip.width, size.width, "full width, because either control can be the wide one")
        XCTAssertGreaterThanOrEqual(strip.height, LiveTranslateView.zoomControlDiameter,
                                    "at least as tall as a control")
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(strip), "and on screen")

        // The overlay's own strip holds T-021's always-show-original toggle at
        // its bottom-leading corner; the zoom controls stand *on* that strip's
        // top edge rather than in its corner, so the two controls never share a
        // touch.
        let overlay = try XCTUnwrap(LiveTranslateOverlaySurface.chromeRects(containerSize: size).first)
        XCTAssertEqual(strip.maxY, overlay.minY,
                       "the zoom band begins where the overlay's strip ends")
        XCTAssertFalse(strip.intersects(overlay), "and does not overlap it")

        XCTAssertTrue(LiveTranslateView.zoomChromeRects(containerSize: .zero).isEmpty,
                      "a container with no size reserves nothing rather than an impossible rect")

        // The safe area's own inset moves the band up with the chrome that
        // stands in it, which is what keeps the reservation where the controls
        // are drawn.
        let withInset = try XCTUnwrap(
            LiveTranslateView.zoomChromeRects(containerSize: size, bottomInset: 34).first)
        XCTAssertEqual(strip.minY - withInset.minY, 34)
        XCTAssertEqual(withInset.height, strip.height, "the inset moves the band, it does not grow it")
    }

    func testTheLayoutTheSessionIsGivenCarriesTheZoomStripAndTheTwoFixedStrips() {
        // The two strips that are always reserved stay one arithmetic
        // (`occupiedRects`, which the overlay's own suites pin); the zoom strip
        // is composed in where the safe area is known.
        let size = CGSize(width: 390, height: 844)
        XCTAssertEqual(LiveTranslateView.occupiedRects(containerSize: size).count, 2)
        XCTAssertEqual(LiveTranslateView.occupiedRects(containerSize: size, bottomInset: 34).count, 3)
        XCTAssertTrue(LiveTranslateView.occupiedRects(containerSize: size, bottomInset: 34)
            .contains(LiveTranslateView.zoomChromeRects(containerSize: size, bottomInset: 34)[0]),
                      "the placement is told about the band the controls stand in")
    }

    func testTheTapIsConvertedOnTheLayerRatherThanByArithmeticInTheView() {
        let view = viewSource()

        XCTAssertTrue(view.contains("captureDevicePointConverted(fromLayerPoint:"),
                      "the aspect fit and the frame size are the layer's business, not the view's arithmetic")
        XCTAssertTrue(view.contains("UIPinchGestureRecognizer"))
        XCTAssertTrue(view.contains("UITapGestureRecognizer"))
        XCTAssertTrue(view.contains("recognizer.location(in: view)"),
                      "the touch is read in the preview view's own space, which is the space the conversion takes")
        XCTAssertTrue(view.contains("zoom.pinch(to: Double($0), at: $1)"),
                      "the pinch's cumulative scale goes to the surface as one gesture, with the window "
                      + "position the fingers landed on — the zoom's anchor")
        XCTAssertTrue(view.contains("zoom.focus(atDevicePoint: $0)"))
        XCTAssertTrue(view.contains("presentation.framePoint(ofContainerPoint:"),
                      "the tap is taken back through the window before the layer converts it")
        XCTAssertTrue(view.contains("unzoomedContainerPoint"),
                      "and the layer is handed the point the *unzoomed* picture draws it at, which is the "
                      + "only space its conversion is defined in")
        XCTAssertTrue(view.contains("presentation.layerTransform(anchor:"),
                      "the layer is drawn through the same map the placement is drawn through")
        XCTAssertTrue(view.contains("setAffineTransform("),
                      "an affine transform moves the layer's drawing without re-laying it out")
        XCTAssertFalse(view.contains("previewLayer.frame = bounds"),
                       "and it must not resize the layer while a transform is set: `frame` is derived "
                       + "from the transform, so assigning it would shrink the drawing area to compensate")
    }

    /// Gesture ownership (owner follow-up, 2026-09-18): the three touches that
    /// can land on the picture, and which of them owns what. A drag that ran
    /// during a pinch would move the window the zoom was already moving, and a
    /// drag that ran while the whole frame was visible would move a window that
    /// does not exist — so the recogniser is one finger, and it is switched off
    /// until there is something to move.
    func testOneFingerDragsTwoPinchAndTheDragExistsOnlyWhileThereIsAWindow() {
        let view = viewSource()

        XCTAssertTrue(view.contains("UIPanGestureRecognizer"),
                      "the drag is a recogniser of its own, so its finger count is its own")
        XCTAssertTrue(view.contains("recognizer.minimumNumberOfTouches = 1"))
        XCTAssertTrue(view.contains("recognizer.maximumNumberOfTouches = 1"),
                      "two fingers are the pinch's: a drag that also ran would fight it for the same gesture")
        XCTAssertTrue(view.contains("panRecognizer?.isEnabled = isWindowed"),
                      "the drag exists exactly while a window does — the whole frame has nothing to move")
        // …and `isWindowed` is the **elder's** window, not the drawing's: since
        // the frame's stabilization is composed into the presentation's crop
        // (owner device verdict, 2026-09-18: "STABILISE THE IMAGE FIRST"), that
        // crop is never whole while a margin is held, so a drag gated on it
        // would be live at the at-rest zoom — moving a window the elder never
        // asked for. The gesture's own window stays the zoom model's.
        XCTAssertTrue(view.contains("isWindowed: !zoom.model.crop.isWhole"),
                      "the drag's window is the elder's own, and the correction is never part of it")
        XCTAssertTrue(view.contains("presentation.panOffset(ofContainerTranslation: recognizer.translation(in: view))"),
                      "the drag's own translation is converted to the window offset it asks for")
        XCTAssertTrue(view.contains("zoom.pan(to: $0)") && view.contains("zoom.panEnded()"),
                      "and the surface keeps what the finger left, rather than springing back")
        XCTAssertTrue(view.contains("case .began, .changed:"),
                      "all three recognisers drive their surface on began and changed alike")
    }

    /// The pixel half, in the `OverlayRenderProbe` / plugin-exit precedent: a
    /// unit host cannot read SwiftUI's accessibility tree, so what it can check
    /// is what the elder can see. The zoom controls must be drawn **inside the
    /// strip the placement is told to keep clear** — the reservation is a
    /// promise about where the controls are, and this is where that promise
    /// becomes pixels.
    @MainActor
    func testTheRenderedSessionDrawsTheZoomControlsInTheStripThePlacementAvoids() throws {
        let parts = makeLiveTranslateSessionTestParts()
        defer { UserDefaults().removePersistentDomain(forName: parts.suiteName) }

        let size = CGSize(width: 390, height: 844)
        let renderer = ImageRenderer(
            content: LiveTranslateView(dependencies: parts.dependencies)
                .frame(width: size.width, height: size.height))
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.uiImage, "the session view must render at all")
        let strip = try XCTUnwrap(LiveTranslateView.zoomChromeRects(containerSize: size).first)
        let drawn = try cardPixels(in: image, within: strip)

        XCTAssertGreaterThan(drawn.count, 0,
                             "the zoom controls must be drawn, in the band the placement was told to avoid")
        XCTAssertGreaterThanOrEqual(drawn.maxY - drawn.minY,
                                    Int(DesignTokens.minTapTargetSize * image.scale) - 2,
                                    "a control is a full tap target tall")
        XCTAssertGreaterThanOrEqual(drawn.minX,
                                    Int(DesignTokens.interElementSpacing * image.scale) - 2,
                                    "the − control begins at the view's leading padding")
        XCTAssertLessThanOrEqual(drawn.minX,
                                 Int(DesignTokens.interElementSpacing * image.scale) + 4,
                                 "and not an element's width in from it")
        XCTAssertLessThanOrEqual(drawn.maxY, Int(strip.maxY * image.scale),
                                 "the controls must be in the band above the overlay's own control, "
                                 + "not on the corner T-021 pinned that control to")
        XCTAssertGreaterThanOrEqual(drawn.minY, Int(strip.minY * image.scale) - 2)
    }

    /// The near-white pixels inside a rect, as a count and a bounding box in
    /// device pixels — the app's card fill (`DesignTokens.card`) on the black
    /// preview, which only the chrome draws. The same measurement the plugin
    /// suite makes for the exit control, over the zoom strip instead.
    private func cardPixels(in image: UIImage, within rect: CGRect) throws
        -> (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let cgImage = try XCTUnwrap(image.cgImage, "the rendering has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scale = image.scale
        var count = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        let firstRow = max(0, Int((rect.minY * scale).rounded(.down)))
        let lastRow = min(height, Int((rect.maxY * scale).rounded(.up)))
        let firstColumn = max(0, Int((rect.minX * scale).rounded(.down)))
        let lastColumn = min(width, Int((rect.maxX * scale).rounded(.up)))
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                let offset = (row * width + column) * 4
                let red = bytes[offset], green = bytes[offset + 1], blue = bytes[offset + 2]
                guard min(red, green, blue) > 200 else { continue }
                count += 1
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        return (count, minX, minY, maxX, maxY)
    }
}

/// Records what the zoom surface asks of the session, and answers for the
/// device. The surface's whole job is to turn a gesture into these calls and to
/// republish what came back, so a test of it is a test of this log.
private final class ZoomSurfaceRecorder {

    /// What the running device reports. Writable, so a test can change it
    /// between interactions the way the platform changes an active format.
    var capabilities = CameraZoomCapabilities(range: 1...8, switchOverFactors: [])

    /// What the device answers for a factor it was asked for — the platform's
    /// own clamping, injected.
    var deviceAnswer: (Double) -> Double = { $0 }

    private(set) var appliedFactors: [Double] = []
    private(set) var focusPoints: [CGPoint] = []
    private(set) var lockRequests: [Bool] = []
    /// Every window the surface settled on and told the session about, in
    /// order. The session crops its frames to the last of these, so what the
    /// elder sees and what Vision reads are one picture.
    private(set) var crops: [LiveCameraCrop] = []

    func makeSurface(config: LiveTranslateConfig = .default) -> LiveCameraZoomSurface {
        LiveCameraZoomSurface(
            config: config,
            capabilities: { [unowned self] in capabilities },
            applyZoom: { [unowned self] factor in
                appliedFactors.append(factor)
                return deviceAnswer(factor)
            },
            applyFocus: { [unowned self] point in focusPoints.append(point) },
            applyFocusLock: { [unowned self] locked in lockRequests.append(locked) },
            applyCrop: { [unowned self] crop in crops.append(crop) })
    }
}
