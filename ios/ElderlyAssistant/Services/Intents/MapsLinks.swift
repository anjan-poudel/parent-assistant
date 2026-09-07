import Foundation

/// Which map surface a navigation request opens (directions task,
/// 2026-09-07). The user's pick is stored on the coordinator
/// (`navigation.mapApp` in UserDefaults, default `.auto`); the OPEN
/// decision is always re-derived at request time through
/// `NavigationMapPolicy.resolve` — installed-ness changes (Google Maps
/// deleted, first simulator run without Apple Maps) never leaves the app
/// promising a surface that is not there.
enum NavigationMapApp: String, Codable, CaseIterable, Equatable {
    /// Google Maps when installed, else Apple Maps when installed, else
    /// the in-app map.
    case auto
    /// Google Maps (falls through when not installed).
    case googleMaps
    /// Apple Maps (falls through when not installed).
    case appleMaps
    /// The in-app MapKit route view, always available (weather already
    /// asks for location; the map itself needs none).
    case inApp
}

/// The pure surface-selection chain for a navigation request. `resolve`
/// never returns a surface that is not installed: an explicit override
/// that cannot open falls through exactly like `.auto` does, and the
/// walk always terminates at `.inApp` — the one surface this app itself
/// provides, which needs no external app at all.
enum NavigationMapPolicy {

    /// Decides which map app a request opens.
    ///  - `googleMapsInstalled` is `canOpenURL("comgooglemaps://")` —
    ///    honest scheme presence (declared in
    ///    LSApplicationQueriesSchemes), false on simulators without
    ///    Google Maps.
    ///  - `appleMapsInstalled` is `canOpenURL("maps://")` — true on any
    ///    iPhone, false on simulators where Maps is absent.
    static func resolve(override: NavigationMapApp,
                        googleMapsInstalled: Bool,
                        appleMapsInstalled: Bool) -> NavigationMapApp {
        switch override {
        case .inApp:
            return .inApp
        case .auto:
            // Documented order (see `NavigationMapApp.auto`): Google first,
            // then Apple, then the in-app map.
            if googleMapsInstalled { return .googleMaps }
            if appleMapsInstalled { return .appleMaps }
            return .inApp
        case .googleMaps:
            if googleMapsInstalled { return .googleMaps }
            if appleMapsInstalled { return .appleMaps }
            return .inApp
        case .appleMaps:
            if appleMapsInstalled { return .appleMaps }
            if googleMapsInstalled { return .googleMaps }
            return .inApp
        }
    }
}

/// Builds the map deep links a navigation request opens — the pure
/// counterpart of `CallLinks` for the directions flow (directions task,
/// 2026-09-07). One home for every URL the navigation pipeline opens, so
/// coordinate formatting, Nepali percent-encoding, and the probe URLs are
/// built once and tested once.
///
/// Scheme facts this type encodes:
///  - `maps://?daddr=<lat>,<lng>` — Apple Maps directions to a
///    coordinate. Accepts a percent-encoded address string too, used
///    only as the geocode-failure fallback. Apple's scheme exposes NO
///    language parameter (its UI follows the device language and voice
///    guidance follows the user's own Maps/Siri settings) — so there is
///    no `hl`-style equivalent to send here, and none is invented.
///  - `comgooglemaps://?daddr=…&directionsmode=driving&hl=<code>&
///    navigation=1` — Google Maps directions. Google's `daddr` is
///    UNRELIABLE with a bare address string (it sometimes fails to
///    resolve one), so the pipeline forward-geocodes to coordinates
///    FIRST and only degrades to the address-string form when geocoding
///    fails (plan risk note). `hl` + `navigation` are deep-link asks —
///    what they request and their honest limits are documented on the
///    Google builders below.
///  - Both schemes are declared in LSApplicationQueriesSchemes, so
///    `canOpenURL` on their ROOT URLs is the honest installed check used
///    by `NavigationMapPolicy` at request time.
///
/// URLs are built with `URLComponents` only — never string interpolation
/// — so Nepali addresses ("बूढानीलकण्ठ, काठमाडौं ९") percent-encode
/// correctly.
final class MapsLinks {

    /// Coordinate precision for `daddr` — six decimals is ~0.1 m, far
    /// finer than any geocoder's output and short enough to keep URLs
    /// readable.
    static let coordinatePrecision = 6

    // MARK: - Probe roots (canOpenURL targets)

    /// `maps://` — Apple Maps scheme probe.
    static let appleMapsProbeURL = URL(string: "maps://")!
    /// `comgooglemaps://` — Google Maps scheme probe.
    static let googleMapsProbeURL = URL(string: "comgooglemaps://")!

    // MARK: - Apple Maps

    /// Apple's `maps://` scheme has NO language parameter: the Maps app
    /// renders its UI in the device language and reads turn-by-turn in
    /// the user's own Maps/Siri settings. There is no `hl`-style
    /// equivalent to send — the app does not invent one (maps-language
    /// deep link honesty note), so these builders take no language.

    /// `maps://?daddr=<lat>,<lng>` — directions to a coordinate.
    static func appleMapsDirectionsURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""   // empty host renders the canonical "maps://"
        components.queryItems = [
            URLQueryItem(name: "daddr", value: daddrValue(latitude: latitude, longitude: longitude))
        ]
        return components.url
    }

    /// `maps://?daddr=<percent-encoded address>` — the geocode-failure
    /// fallback (Apple Maps resolves address strings better than Google).
    static func appleMapsDirectionsURL(address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""   // empty host renders the canonical "maps://"
        components.queryItems = [URLQueryItem(name: "daddr", value: trimmed)]
        return components.url
    }

    // MARK: - Google Maps

    /// `comgooglemaps://?daddr=<lat>,<lng>&directionsmode=driving&hl=<code>&
    /// navigation=1` — driving directions to a coordinate (the PRIMARY
    /// form: coordinate daddr is the reliable one for Google), carrying
    /// the two deep-link asks the directions flow makes:
    ///
    ///  - `hl=<uiLanguageCode>` asks Google Maps to render its UI in the
    ///    app's active language ("ne" under Nepali, "en" under English;
    ///    resolved from the app locale by the coordinator). HONESTY NOTE:
    ///    `hl` selects Google Maps' DISPLAY language — menus, place info,
    ///    search. The voice that reads turn-by-turn instructions is
    ///    Google Maps' OWN in-app setting; a deep link can request it,
    ///    never force it. Whether `hl` is honored at all is likewise
    ///    Google Maps' discretion (its UI language can also be changed
    ///    inside the app afterward).
    ///  - `navigation=1` asks Maps to AUTO-START turn-by-turn navigation
    ///    instead of landing on the route preview. Best-effort: it is the
    ///    documented auto-start ask, but Google Maps decides whether —
    ///    and in which version — it complies.
    static func googleMapsDirectionsURL(latitude: Double, longitude: Double,
                                        uiLanguageCode: String) -> URL? {
        var components = URLComponents()
        components.scheme = "comgooglemaps"
        components.host = ""   // empty host renders "comgooglemaps://"
        components.queryItems = [
            URLQueryItem(name: "daddr", value: daddrValue(latitude: latitude, longitude: longitude)),
            URLQueryItem(name: "directionsmode", value: "driving"),
            URLQueryItem(name: "hl", value: uiLanguageCode),
            URLQueryItem(name: "navigation", value: "1")
        ]
        return components.url
    }

    /// `comgooglemaps://?daddr=<percent-encoded address>&directionsmode=
    /// driving&hl=<code>&navigation=1` — address-string form, used ONLY
    /// when forward geocoding failed (Google's address-only daddr is
    /// unreliable; coordinates first, plan risk note). Same `hl` +
    /// `navigation=1` asks as the coordinate form above.
    static func googleMapsDirectionsURL(address: String,
                                        uiLanguageCode: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "comgooglemaps"
        components.host = ""   // empty host renders "comgooglemaps://"
        components.queryItems = [
            URLQueryItem(name: "daddr", value: trimmed),
            URLQueryItem(name: "directionsmode", value: "driving"),
            URLQueryItem(name: "hl", value: uiLanguageCode),
            URLQueryItem(name: "navigation", value: "1")
        ]
        return components.url
    }

    /// The directions URL the resolved map app opens — nil for `.auto`
    /// (never passed a resolved policy) and `.inApp` (no external URL).
    /// `uiLanguageCode` feeds the Google surface's `hl` deep-link ask
    /// only; Apple Maps' scheme has no language parameter (Apple maps
    /// follow device/Maps-settings language — nothing to send, and none
    /// is invented), so the value is ignored for `.appleMaps`.
    static func directionsURL(for app: NavigationMapApp,
                              latitude: Double, longitude: Double,
                              uiLanguageCode: String) -> URL? {
        switch app {
        case .googleMaps:
            return googleMapsDirectionsURL(latitude: latitude, longitude: longitude,
                                           uiLanguageCode: uiLanguageCode)
        case .appleMaps:
            return appleMapsDirectionsURL(latitude: latitude, longitude: longitude)
        case .auto, .inApp:
            return nil
        }
    }

    // MARK: - Formatting

    /// `<lat>,<lng>` at `coordinatePrecision` decimals — the shared
    /// `daddr` value for both map apps.
    static func daddrValue(latitude: Double, longitude: Double) -> String {
        String(format: "%.\(coordinatePrecision)f,%.\(coordinatePrecision)f",
               latitude, longitude)
    }
}
