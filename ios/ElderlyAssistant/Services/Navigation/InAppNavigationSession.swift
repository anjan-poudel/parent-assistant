import Foundation
import CoreLocation
import MapKit

// MARK: - Route model

/// One maneuver of a calculated route (directions task, 2026-09-07). The
/// `instruction` is the text the map framework produced — spoken verbatim
/// by `InAppNavigationSession.speakSteps` and listed by the in-app view.
/// NOTE: MKRoute instructions come in the DEVICE language, not the app
/// language; the step list carries an honest `directions.inApp.stepsNote`
/// about that.
struct InAppRouteStep: Equatable {
    let instruction: String
    /// Length of this step's road segment in meters (not shown in the
    /// current UI; the instruction text usually carries the distance).
    let distanceMeters: CLLocationDistance
}

/// The app-side shape of a calculated route — the value `MapKitDirectionsCalculator`
/// extracts from an `MKRoute` and the in-app session hands to the map view.
///
/// WHY an app model instead of `MKRoute`: `MKRoute` has no public
/// initializer, so any seam that returns one would be untestable in unit
/// tests. The route the session needs is only polyline points + spoken
/// steps + a travel time, so the conversion lives inside the production
/// calculator and the session/UI/test world deals with a constructible
/// value.
struct InAppRoute: Equatable {
    /// The maneuvers in driving order. `steps[0]` is the departure
    /// instruction ("head east on …"); a final "arrive" step usually
    /// closes the list.
    let steps: [InAppRouteStep]
    /// Server-estimated drive time (seconds); 0 when unknown.
    let expectedTravelTime: TimeInterval
    /// The route polyline, sampled by the map framework. Two or more
    /// points when a route exists.
    let polylineCoordinates: [CLLocationCoordinate2D]

    static func == (lhs: InAppRoute, rhs: InAppRoute) -> Bool {
        guard lhs.steps == rhs.steps,
              lhs.expectedTravelTime == rhs.expectedTravelTime,
              lhs.polylineCoordinates.count == rhs.polylineCoordinates.count else { return false }
        // CLLocationCoordinate2D is not Equatable — compare elementwise.
        for (a, b) in zip(lhs.polylineCoordinates, rhs.polylineCoordinates) {
            if a.latitude != b.latitude || a.longitude != b.longitude { return false }
        }
        return true
    }
}

// MARK: - Route calculation seam

/// Why route calculation failed (directions task, 2026-09-07). Both cases
/// map to the same honest `.failed` session phase — the user sees the
/// generic in-app fallback message and can close or ask again.
enum NavigationDirectionsFailure: Error, Equatable {
    /// MKDirections errored (offline, no route between the points, …).
    case failed
    /// No result within `MapKitDirectionsCalculator.timeoutSeconds`.
    case timedOut
}

/// One-shot route-calculation seam for the in-app navigation session —
/// the `LocationFetcher` template (same contract, different service): the
/// completion is guaranteed to fire EXACTLY ONCE, on the main queue, with
/// the timeout as the backstop.
protocol NavigationDirectionsCalculating: AnyObject {
    func calculateRoute(from start: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        completion: @escaping (Result<InAppRoute, NavigationDirectionsFailure>) -> Void)
}

/// Production `NavigationDirectionsCalculating` — a small `MKDirections`
/// wrapper (directions task, 2026-09-07).
///
/// One request per instance: `MKDirections.calculate` is a one-shot quota
/// API (a second call on the same instance errors), and the coordinator
/// creates a fresh calculator per navigation request, so the instance
/// lifecycle is bounded by a single route.
///
/// `MKDirections` has no cancel: the timeout only MARKS the request
/// failed (the session moves on); a route that straggles in later is
/// discarded by the finished flag.
///
/// Self-retention: the calculator keeps itself alive from `calculateRoute`
/// until it has delivered (or timed out), so a caller that fires-and-
/// forgets cannot deallocate the wrapper mid-request.
final class MapKitDirectionsCalculator: NavigationDirectionsCalculating {

    /// How long one route calculation may take before the request fails
    /// as `.timedOut`. Routes are server-side; offline or overloaded
    /// conditions must not leave the in-app session hanging on an
    /// indeterminate spinner.
    static let timeoutSeconds: TimeInterval = 12

    /// Driving directions — matches the `directionsmode=driving` deep
    /// links the external-map path opens.
    private let transportType: MKDirectionsTransportType = .automobile

    private var completion: ((Result<InAppRoute, NavigationDirectionsFailure>) -> Void)?
    private var finished = false

    // MARK: - NavigationDirectionsCalculating

    func calculateRoute(from start: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        completion: @escaping (Result<InAppRoute, NavigationDirectionsFailure>) -> Void) {
        guard self.completion == nil else { return }   // one request per instance
        self.completion = completion
        keepAlive = self

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
            self?.fail(.timedOut)
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType

        MKDirections(request: request).calculate { [weak self] response, _ in
            guard let self, !self.finished else { return }
            guard let route = response?.routes.first,
                  !route.steps.isEmpty else {
                self.fail(.failed)
                return
            }
            let stepCount = route.polyline.pointCount
            var coordinates = [CLLocationCoordinate2D]()
            coordinates.reserveCapacity(stepCount)
            route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: stepCount))
            let inApp = InAppRoute(
                steps: route.steps.map {
                    InAppRouteStep(instruction: $0.instructions, distanceMeters: $0.distance)
                },
                expectedTravelTime: route.expectedTravelTime,
                polylineCoordinates: coordinates
            )
            self.finish(.success(inApp))
        }
    }

    // MARK: - Delivery (exactly once, on the main queue)

    private func finish(_ result: Result<InAppRoute, NavigationDirectionsFailure>) {
        guard !finished else { return }
        finished = true
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async {
            completion?(result)
        }
        keepAlive = nil
    }

    private func fail(_ failure: NavigationDirectionsFailure) {
        finish(.failure(failure))
    }

    /// Self-retention while a request is outstanding — see the type doc.
    private var keepAlive: MapKitDirectionsCalculator?
}

// MARK: - Session

/// How far the in-app navigation session has gotten (directions task,
/// 2026-09-07). Drives the map view's status line and its transitions.
enum InAppNavigationPhase: Equatable {
    /// Waiting on the point-of-use location fix.
    case locating
    /// Forward-geocoding the destination address.
    case geocoding
    /// Calculating the route (server-side MKDirections).
    case calculating
    /// A route is on the table — `InAppRoute` carries the polyline, the
    /// steps, and the travel time.
    case ready(InAppRoute)
    /// The pipeline gave up honestly (location denied/unavailable, the
    /// address did not geocode, no route was found). The view shows the
    /// generic `directions.inApp.failed` message — never a raw reason.
    case failed
}

/// Why an in-app session failed — recorded for diagnostics, never spoken
/// verbatim (house rule: the user hears one honest generic line).
enum InAppNavigationFailure: Equatable {
    case locating(LocationFetchFailure)
    case geocoding(NavigationGeocodeFailure)
    case routeCalculation
}

/// One static in-app navigation session (directions task, 2026-09-07) —
/// the fallback surface when no map app is installed or the user forced
/// `.inApp`. Runs the fixed pipeline
///
///     locate (point-of-use) → geocode destination → calculate route → ready
///
/// then speaks the route's steps one by one. DELIBERATELY STATIC: one
/// route, computed once, no live re-routing, no turn-by-turn location
/// tracking — the session is a "here is the way, here are the steps"
/// fallback, not a navigation app (plan constraint).
///
/// The pipeline is injected as seams (`LocationFetching`,
/// `NavigationGeocoding`, `NavigationDirectionsCalculating`, `Speaker`) so
/// tests drive every phase with stubs; the coordinator builds one session
/// per request with a FRESH `LocationFetcher` (one request per fetcher
/// instance) and hands the app's speaker over.
///
/// @MainActor throughout: the fetcher/geocoder/calculator seams deliver on
/// the main queue, and the published phase drives SwiftUI directly.
@MainActor
final class InAppNavigationSession: ObservableObject {

    @Published private(set) var phase: InAppNavigationPhase = .locating
    /// The route once `.ready` — the view's map + step list read this.
    @Published private(set) var route: InAppRoute?
    /// The located current position (needed for the map fit; the map view
    /// does NOT show a live user dot — the session's point-of-use
    /// permission ask belongs to the fetcher alone, and a static fallback
    /// has no need to track the user).
    @Published private(set) var startCoordinate: CLLocationCoordinate2D?
    /// The geocoded destination — the map view's destination pin.
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    /// The failure behind `.failed`, nil otherwise. Diagnostics only.
    private(set) var failure: InAppNavigationFailure?

    /// Display name of the destination (saved-place/contact name) — the
    /// map pin's title.
    let destinationName: String
    /// The address text being geocoded.
    let destinationAddress: String

    private let locationFetcher: LocationFetching
    private let geocoder: NavigationGeocoding
    private let directionsCalculator: NavigationDirectionsCalculating
    private let speaker: Speaker
    private let locale: Locale

    /// One session is one shot: `start()` runs the pipeline once, `stop()`
    /// ends it, and neither is reversible.
    private var started = false
    private var stopped = false
    /// Bumped by `stopSpeech()` — a pending speak-steps loop checks it
    /// between utterances and exits (the Speaker.cancel only stops the
    /// utterance in flight).
    private var speechGeneration = 0

    init(destinationName: String,
         destinationAddress: String,
         locationFetcher: LocationFetching,
         geocoder: NavigationGeocoding,
         directionsCalculator: NavigationDirectionsCalculating,
         speaker: Speaker,
         locale: Locale) {
        self.destinationName = destinationName
        self.destinationAddress = destinationAddress
        self.locationFetcher = locationFetcher
        self.geocoder = geocoder
        self.directionsCalculator = directionsCalculator
        self.speaker = speaker
        self.locale = locale
    }

    // MARK: - Pipeline

    /// Runs locate → geocode → calculate. The pipeline settles in `.ready`
    /// or `.failed`; every stage's seam delivers exactly once on the main
    /// queue, so the session always lands somewhere.
    func start() {
        guard !started else { return }
        started = true
        phase = .locating
        locationFetcher.requestCurrentLocation { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let fix):
                self.startCoordinate = CLLocationCoordinate2D(
                    latitude: fix.latitude, longitude: fix.longitude)
                self.geocodeDestination()
            case .failure(let reason):
                self.fail(.locating(reason))
            }
        }
    }

    private func geocodeDestination() {
        phase = .geocoding
        geocoder.geocode(address: destinationAddress) { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let destination):
                self.destinationCoordinate = CLLocationCoordinate2D(
                    latitude: destination.latitude, longitude: destination.longitude)
                self.calculateRoute()
            case .failure(let reason):
                self.fail(.geocoding(reason))
            }
        }
    }

    private func calculateRoute() {
        guard let start = startCoordinate,
              let destination = destinationCoordinate else {
            fail(.routeCalculation)
            return
        }
        phase = .calculating
        directionsCalculator.calculateRoute(from: start, to: destination) { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let route):
                self.route = route
                self.phase = .ready(route)
            case .failure:
                self.fail(.routeCalculation)
            }
        }
    }

    private func fail(_ failure: InAppNavigationFailure) {
        self.failure = failure
        phase = .failed
    }

    // MARK: - Spoken steps

    /// Speaks the ready route's step instructions one by one (sequential
    /// awaits — each utterance finishes, or is cancelled, before the next
    /// starts). A no-op unless the session is `.ready`.
    ///
    /// Honest disclosure: instructions are the map framework's text in the
    /// DEVICE language — the session speaks them as-is, and the step list
    /// shows the same text with the `directions.inApp.stepsNote` note.
    func speakSteps() async {
        guard let route, !route.steps.isEmpty else { return }
        speechGeneration += 1
        let generation = speechGeneration
        for step in route.steps {
            guard generation == speechGeneration, !stopped else { return }
            await speaker.speak(step.instruction, locale: locale)
        }
    }

    /// Stops the utterance in flight and cancels the rest of a pending
    /// speak-steps run (the loop checks `speechGeneration` between steps).
    func stopSpeech() {
        speechGeneration += 1
        speaker.cancel()
    }

    /// Ends the session: cancels speech and makes late seam deliveries
    /// no-ops. The coordinator calls this when the in-app sheet goes away.
    func stop() {
        stopped = true
        stopSpeech()
    }
}
