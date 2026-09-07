import Foundation
import CoreLocation

/// Why a forward-geocode of a destination address failed (directions
/// task, 2026-09-07). Every case maps to the same honest degradation in
/// the navigation pipeline — the request falls back to an address-string
/// Maps deep link (Apple Maps resolves address text well) or, in the
/// in-app session, to the `.failed` phase. The user never hears a raw
/// failure reason.
enum NavigationGeocodeFailure: Error, Equatable {
    /// CLGeocoder errored (no network, malformed address, …).
    case failed
    /// No placemark within `NavigationGeocoder.timeoutSeconds` — a hung
    /// geocoder must not leave the navigation turn hanging in silence.
    case timedOut
}

/// A resolved destination coordinate — the address text the user typed
/// turned into something a map can route to. No place name: the caller
/// already has the display name (the saved place / contact name), and
/// the map deep links take coordinates directly.
struct GeocodedDestination: Equatable {
    let latitude: Double
    let longitude: Double
}

/// One-shot forward-geocoding seam for the navigation pipeline — the
/// `LocationFetcher` template (same contract, different service): the
/// completion is guaranteed to fire EXACTLY ONCE, on the main queue,
/// with the timeout as the backstop.
protocol NavigationGeocoding: AnyObject {
    func geocode(address: String,
                 completion: @escaping (Result<GeocodedDestination, NavigationGeocodeFailure>) -> Void)
}

/// Production `NavigationGeocoding` — a small `CLGeocoder` wrapper
/// (directions task, 2026-09-07).
///
/// One request per instance: the coordinator creates a fresh geocoder
/// per navigation request, so the geocoder lifecycle is bounded by a
/// single address lookup and no caller ever juggles overlapping
/// completions.
///
/// Self-retention: the geocoder keeps itself alive from `geocode` until
/// it has delivered (or timed out), so a caller that fires-and-forgets
/// cannot deallocate the wrapper mid-lookup.
final class NavigationGeocoder: NavigationGeocoding {

    /// How long one forward-geocode may take before the request fails as
    /// `.timedOut`. CLGeocoder rate-limits aggressively (Apple's
    /// guidance is ~1 request/second per app), so a stuck lookup must
    /// not hold the navigation turn hostage — the pipeline has an honest
    /// address-string fallback ready.
    static let timeoutSeconds: TimeInterval = 8

    private let geocoder = CLGeocoder()

    private var completion: ((Result<GeocodedDestination, NavigationGeocodeFailure>) -> Void)?
    private var finished = false

    /// Whether the shared geocoder is mid-request — set before the
    /// `geocodeAddressString` call and cleared in `finish`, so callers
    /// can observe throttling without racing Apple's private state.
    private(set) var isGeocoding = false

    // MARK: - NavigationGeocoding

    func geocode(address: String,
                 completion: @escaping (Result<GeocodedDestination, NavigationGeocodeFailure>) -> Void) {
        guard self.completion == nil else { return }   // one request per instance
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // An empty address can never resolve — deliver the failure
            // synchronously so the caller's fallback path is uniform.
            DispatchQueue.main.async { completion(.failure(.failed)) }
            return
        }
        self.completion = completion
        keepAlive = self

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
            self?.fail(.timedOut)
        }

        isGeocoding = true
        geocoder.geocodeAddressString(trimmed) { [weak self] placemarks, _ in
            guard let self, !self.finished else { return }
            if let location = placemarks?.first?.location {
                self.finish(.success(GeocodedDestination(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude)))
            } else {
                self.fail(.failed)
            }
        }
    }

    // MARK: - Delivery (exactly once, on the main queue)

    private func finish(_ result: Result<GeocodedDestination, NavigationGeocodeFailure>) {
        guard !finished else { return }
        finished = true
        isGeocoding = false
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async {
            completion?(result)
        }
        keepAlive = nil
    }

    private func fail(_ failure: NavigationGeocodeFailure) {
        finish(.failure(failure))
    }

    /// Self-retention while a request is outstanding — see the type doc.
    private var keepAlive: NavigationGeocoder?
}
