import XCTest
import CoreLocation
@testable import ElderlyAssistant

/// Pipeline tests for the static in-app navigation session (directions
/// task, 2026-09-07) — the locate → geocode → calculate pipeline, the
/// honest `.failed` landing for every seam failure, the one-shot guards,
/// and the spoken steps (speak / stop / stopSpeech). Every seam is a
/// stub: what CANNOT be exercised here is the real CLLocationManager ask,
/// CLGeocoder, and MKDirections — the on-device items.
///
/// The session is @MainActor (its phases drive SwiftUI directly), so every
/// test runs on the main actor; the stub seams deliver synchronously, so
/// the pipeline settles within `start()` itself.
final class InAppNavigationSessionTests: XCTestCase {

    private let startFix = LocationFix(latitude: 27.71, longitude: 85.32,
                                       placeName: "काठमाडौं")
    private let destination = GeocodedDestination(latitude: 27.70, longitude: 85.33)

    private func route() -> InAppRoute {
        InAppRoute(
            steps: [
                InAppRouteStep(instruction: "सिधा अगाडि जानुहोस्", distanceMeters: 500),
                InAppRouteStep(instruction: "दायाँ मोड्नुहोस्", distanceMeters: 200)
            ],
            expectedTravelTime: 480,
            polylineCoordinates: [
                CLLocationCoordinate2D(latitude: 27.71, longitude: 85.32),
                CLLocationCoordinate2D(latitude: 27.705, longitude: 85.325),
                CLLocationCoordinate2D(latitude: 27.70, longitude: 85.33)
            ])
    }

    /// Test methods run on the main actor, so the session (itself
    /// @MainActor) is constructed there too.
    @MainActor
    private func makeSession(location: StubLocationFetcher,
                             geocoder: StubGeocoder,
                             calculator: StubDirectionsCalculator,
                             speaker: Speaker = RecordingSpeaker(),
                             locale: Locale = Locale(identifier: "ne-NP"))
        -> InAppNavigationSession {
        InAppNavigationSession(destinationName: "अस्पताल",
                               destinationAddress: "बूढानीलकण्ठ",
                               locationFetcher: location,
                               geocoder: geocoder,
                               directionsCalculator: calculator,
                               speaker: speaker,
                               locale: locale)
    }

    // MARK: - Happy path

    @MainActor
    func testFullPipelineReachesReadyWithRoute() {
        let location = StubLocationFetcher(result: .success(startFix))
        let geocoder = StubGeocoder(result: .success(destination))
        let expected = route()
        let calculator = StubDirectionsCalculator(result: .success(expected))
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator)

        session.start()

        XCTAssertEqual(session.phase, .ready(expected))
        XCTAssertEqual(session.route, expected)
        XCTAssertEqual(session.startCoordinate?.latitude, 27.71)
        XCTAssertEqual(session.startCoordinate?.longitude, 85.32)
        XCTAssertEqual(session.destinationCoordinate?.latitude, 27.70)
        XCTAssertEqual(session.destinationCoordinate?.longitude, 85.33)
        XCTAssertNil(session.failure)
        XCTAssertEqual(location.requestCount, 1)
        XCTAssertEqual(geocoder.requestCount, 1)
        XCTAssertEqual(calculator.requestCount, 1)
    }

    // MARK: - Honest failures (one generic line, never a raw reason)

    @MainActor
    func testLocationDeniedLandsInFailedPhase() {
        let location = StubLocationFetcher(result: .failure(.notAuthorized))
        let geocoder = StubGeocoder(result: .success(destination))
        let calculator = StubDirectionsCalculator(result: .success(route()))
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator)

        session.start()

        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.failure, .locating(.notAuthorized))
        XCTAssertNil(session.route)
        XCTAssertEqual(geocoder.requestCount, 0,
                       "a failed location ask never geocodes")
        XCTAssertEqual(calculator.requestCount, 0)
    }

    @MainActor
    func testGeocodeTimeoutLandsInFailedPhase() {
        let location = StubLocationFetcher(result: .success(startFix))
        let geocoder = StubGeocoder(result: .failure(.timedOut))
        let calculator = StubDirectionsCalculator(result: .success(route()))
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator)

        session.start()

        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.failure, .geocoding(.timedOut))
        XCTAssertNil(session.route)
        XCTAssertEqual(calculator.requestCount, 0,
                       "an unresolved destination never calculates a route")
    }

    @MainActor
    func testRouteCalculationFailureLandsInFailedPhase() {
        let location = StubLocationFetcher(result: .success(startFix))
        let geocoder = StubGeocoder(result: .success(destination))
        let calculator = StubDirectionsCalculator(result: .failure(.failed))
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator)

        session.start()

        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.failure, .routeCalculation)
        XCTAssertNil(session.route)
    }

    // MARK: - One-shot guards

    @MainActor
    func testStartIsOneShot() {
        let location = StubLocationFetcher(result: .success(startFix))
        let geocoder = StubGeocoder(result: .success(destination))
        let calculator = StubDirectionsCalculator(result: .success(route()))
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator)

        session.start()
        session.start()   // second start must be a no-op

        XCTAssertEqual(session.phase, .ready(route()))
        XCTAssertEqual(location.requestCount, 1)
        XCTAssertEqual(geocoder.requestCount, 1)
        XCTAssertEqual(calculator.requestCount, 1)
    }

    @MainActor
    func testStopFreezesPipelineAgainstLateDeliveries() {
        let location = StubLocationFetcher(result: .success(startFix))
        let geocoder = StubGeocoder(result: .success(destination))
        let calculator = StubDirectionsCalculator(result: .success(route()))

        // A location fetch that never answers — the session must sit in
        // .locating until stopped.
        let locationLatched = StubLocationFetcher()   // completion captured
        let sessionLatched = makeSession(location: locationLatched,
                                         geocoder: geocoder,
                                         calculator: calculator)
        sessionLatched.start()
        XCTAssertEqual(sessionLatched.phase, .locating)

        sessionLatched.stop()
        locationLatched.fire(.success(startFix))   // late delivery

        XCTAssertEqual(sessionLatched.phase, .locating,
                       "a delivery after stop() is a no-op — the sheet is gone")
        XCTAssertNil(sessionLatched.route)
        XCTAssertEqual(geocoder.requestCount, 0)

        // stop() also cuts in-flight speech.
        let gated = GateSpeaker()
        let sessionReady = makeSession(location: location, geocoder: geocoder,
                                       calculator: calculator, speaker: gated)
        sessionReady.start()
        XCTAssertEqual(sessionReady.phase, .ready(route()))
        sessionReady.stop()
        XCTAssertEqual(gated.cancelCount, 1)
    }

    // MARK: - Spoken steps

    @MainActor
    func testSpeakStepsSpeaksEveryStepInOrder() async {
        let location = StubLocationFetcher(result: .success(startFix))
        let geocoder = StubGeocoder(result: .success(destination))
        let calculator = StubDirectionsCalculator(result: .success(route()))
        let speaker = RecordingSpeaker()
        let locale = Locale(identifier: "ne-NP")
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator, speaker: speaker,
                                  locale: locale)
        session.start()

        await session.speakSteps()

        XCTAssertEqual(speaker.utterances.map(\.text),
                       ["सिधा अगाडि जानुहोस्", "दायाँ मोड्नुहोस्"])
        XCTAssertEqual(speaker.utterances.map(\.locale), [locale, locale],
                       "steps are spoken in the app language's locale")
    }

    @MainActor
    func testSpeakStepsBeforeReadyIsANoOp() async {
        let location = StubLocationFetcher(result: .failure(.timedOut))
        let geocoder = StubGeocoder(result: .success(destination))
        let calculator = StubDirectionsCalculator(result: .success(route()))
        let speaker = RecordingSpeaker()
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator, speaker: speaker)
        session.start()
        XCTAssertEqual(session.phase, .failed)

        await session.speakSteps()

        XCTAssertTrue(speaker.utterances.isEmpty,
                      "no route, no steps — nothing to speak")
    }

    @MainActor
    func testStopSpeechCutsRemainingSteps() async {
        let location = StubLocationFetcher(result: .success(startFix))
        let geocoder = StubGeocoder(result: .success(destination))
        let calculator = StubDirectionsCalculator(result: .success(route()))
        let gated = GateSpeaker()
        let session = makeSession(location: location, geocoder: geocoder,
                                  calculator: calculator, speaker: gated)
        session.start()
        XCTAssertEqual(session.phase, .ready(route()))

        let speaking = Task { await session.speakSteps() }
        // speak() is a NONISOLATED async method — the loop needs an extra
        // executor hop past the MainActor boundary, so wait for the first
        // utterance instead of assuming a single yield lines it up.
        var spins = 0
        while gated.utterances.isEmpty && spins < 100 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(gated.utterances.count, 1,
                       "the first step is in flight, the second pending")

        session.stopSpeech()
        await speaking.value

        XCTAssertEqual(gated.utterances.count, 1,
                       "stopSpeech cancels the utterance in flight AND the pending steps")
        XCTAssertGreaterThanOrEqual(gated.cancelCount, 1)
    }
}

// MARK: - Seam stubs

/// `LocationFetching` double — fires a scripted result synchronously, or
/// holds the completion for the caller to fire (the never-answers case).
private final class StubLocationFetcher: LocationFetching {
    private(set) var requestCount = 0
    private let result: Result<LocationFix, LocationFetchFailure>?
    private var completion: ((Result<LocationFix, LocationFetchFailure>) -> Void)?

    init(result: Result<LocationFix, LocationFetchFailure>? = nil) {
        self.result = result
    }

    func requestCurrentLocation(completion: @escaping (Result<LocationFix, LocationFetchFailure>) -> Void) {
        requestCount += 1
        if let result {
            completion(result)
        } else {
            self.completion = completion
        }
    }

    /// Fires the captured completion (a late delivery, after stop()).
    func fire(_ result: Result<LocationFix, LocationFetchFailure>) {
        completion?(result)
        completion = nil
    }
}

/// `NavigationGeocoding` double — fires a scripted result synchronously.
private final class StubGeocoder: NavigationGeocoding {
    private(set) var requestCount = 0
    private let result: Result<GeocodedDestination, NavigationGeocodeFailure>

    init(result: Result<GeocodedDestination, NavigationGeocodeFailure>) {
        self.result = result
    }

    func geocode(address: String,
                 completion: @escaping (Result<GeocodedDestination, NavigationGeocodeFailure>) -> Void) {
        requestCount += 1
        completion(result)
    }
}

/// `NavigationDirectionsCalculating` double — fires a scripted result
/// synchronously.
private final class StubDirectionsCalculator: NavigationDirectionsCalculating {
    private(set) var requestCount = 0
    private let result: Result<InAppRoute, NavigationDirectionsFailure>

    init(result: Result<InAppRoute, NavigationDirectionsFailure>) {
        self.result = result
    }

    func calculateRoute(from start: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        completion: @escaping (Result<InAppRoute, NavigationDirectionsFailure>) -> Void) {
        requestCount += 1
        completion(result)
    }
}

/// `Speaker` double — records utterances synchronously and returns.
private final class RecordingSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

/// `Speaker` double whose `speak` suspends until released — lets a test
/// hold the step loop mid-utterance and then stop it.
private final class GateSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []
    private(set) var cancelCount = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
        if released { return }
        await withCheckedContinuation { gates.append($0) }
    }

    func cancel() {
        cancelCount += 1
        releaseAll()
    }

    func releaseAll() {
        released = true
        for gate in gates { gate.resume() }
        gates = []
    }
}
