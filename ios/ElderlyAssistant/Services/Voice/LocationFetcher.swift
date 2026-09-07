import Foundation
import CoreLocation

/// [LOCAL-TOOLS] (2026-09-07) Why a current-location request failed. Each
/// case maps to the same honest fallback in `CommandRouter` (the existing
/// deterministic weather pre-answer line) — the user never hears a raw
/// failure reason.
enum LocationFetchFailure: Error, Equatable {
    /// Permission denied or restricted (also fires when the user said no
    /// to the point-of-use prompt).
    case notAuthorized
    /// The location manager errored out (no fix before its own failure,
    /// GPS unavailable, …).
    case locationUnavailable
    /// No fix within `LocationFetcher.timeoutSeconds` — a hung
    /// authorization callback or a dead GPS must not leave the weather
    /// turn hanging in silence.
    case timedOut
}

/// A resolved location plus its best-effort human name.
struct LocationFix: Equatable {
    let latitude: Double
    let longitude: Double
    /// Reverse-geocoded locality ("Kathmandu") — nil when geocoding
    /// failed or returned no locality. The weather reply then simply
    /// omits the "in <place>" clause; a fix WITHOUT a name is still a
    /// usable fix.
    let placeName: String?
}

/// [LOCAL-TOOLS] (2026-09-07) One-shot location seam for the weather
/// tool. The completion is guaranteed to fire EXACTLY ONCE, on the main
/// queue, with the timeout as the backstop — the router fires the fetch,
/// announces "weather.checking", and can trust that this always settles.
protocol LocationFetching: AnyObject {
    func requestCurrentLocation(completion: @escaping (Result<LocationFix, LocationFetchFailure>) -> Void)
}

/// [LOCAL-TOOLS] (2026-09-07) Production `LocationFetching` — a small
/// `CLLocationManager` wrapper that asks permission at the POINT OF USE
/// (constitution rule: no permission prompt until the user actually asks
/// for weather) and reverse-geocodes the fix into a place name.
///
/// One request per instance: `CommandRouter` creates a fresh fetcher per
/// weather question, so the manager + delegate lifecycle is bounded by a
/// single request and the router never juggles delegate callbacks.
///
/// Self-retention: the fetcher keeps itself alive from
/// `requestCurrentLocation` until it has delivered (or timed out), so a
/// caller that fires-and-forgets cannot deallocate the delegate mid-ask.
final class LocationFetcher: NSObject, LocationFetching, CLLocationManagerDelegate {

    /// How long a fix may take (authorization dance + first location
    /// callback) before the request fails as `.timedOut`. Generous: the
    /// whole weather round-trip (location + geocode + HTTP) stays inside
    /// the user's attention span, and a timeout only costs the static
    /// weather fallback line.
    static let timeoutSeconds: TimeInterval = 10

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    private var completion: ((Result<LocationFix, LocationFetchFailure>) -> Void)?
    private var finished = false

    override init() {
        super.init()
        manager.delegate = self
        // Weather grids are kilometer-scale — no need for the precision
        // dance (and its extra power + latency) of a fine fix.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - LocationFetching

    func requestCurrentLocation(completion: @escaping (Result<LocationFix, LocationFetchFailure>) -> Void) {
        guard self.completion == nil else { return }   // one request per instance
        self.completion = completion
        keepAlive = self

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
            self?.fail(.timedOut)
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            // Point-of-use ask: the system prompt appears NOW, only
            // because the user asked for the weather.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            fail(.notAuthorized)
        @unknown default:
            fail(.notAuthorized)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            break   // still waiting on the system prompt
        case .denied, .restricted:
            fail(.notAuthorized)
        @unknown default:
            fail(.notAuthorized)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !finished,
              let location = locations.last,
              location.horizontalAccuracy >= 0 else { return }
        manager.stopUpdatingLocation()
        reverseGeocode(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fail(.locationUnavailable)
    }

    // MARK: - Place name

    /// Reverse-geocodes the fix into a locality for the "in Kathmandu"
    /// spoken clause. Geocoding failure is NOT a request failure — the
    /// reply simply omits the place (deliberate: an offline simulator or
    /// a foreign grid point must still get the temperature).
    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self, !self.finished else { return }
            let placeName = placemarks?.first?.locality
            self.finish(.success(LocationFix(latitude: location.coordinate.latitude,
                                             longitude: location.coordinate.longitude,
                                             placeName: placeName)))
        }
    }

    // MARK: - Delivery (exactly once, on the main queue)

    private func finish(_ result: Result<LocationFix, LocationFetchFailure>) {
        guard !finished else { return }
        finished = true
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async {
            completion?(result)
        }
        keepAlive = nil
    }

    private func fail(_ failure: LocationFetchFailure) {
        finish(.failure(failure))
    }

    /// Self-retention while a request is outstanding — see the type doc.
    private var keepAlive: LocationFetcher?
}
