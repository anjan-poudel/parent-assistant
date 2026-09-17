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
        XCTAssertEqual(model.pinched(by: 1.2, from: 1).factor, 1.2)
        XCTAssertEqual(model.pinched(by: 1.8, from: 1).factor, 1.8)
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
        XCTAssertTrue(view.contains("zoom.pinch(to: Double($0))"),
                      "the pinch's cumulative scale goes to the surface as one gesture")
        XCTAssertTrue(view.contains("zoom.focus(atDevicePoint: $0)"))
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

    func makeSurface(config: LiveTranslateConfig = .default) -> LiveCameraZoomSurface {
        LiveCameraZoomSurface(
            config: config,
            capabilities: { [unowned self] in capabilities },
            applyZoom: { [unowned self] factor in
                appliedFactors.append(factor)
                return deviceAnswer(factor)
            },
            applyFocus: { [unowned self] point in focusPoints.append(point) },
            applyFocusLock: { [unowned self] locked in lockRequests.append(locked) })
    }
}
