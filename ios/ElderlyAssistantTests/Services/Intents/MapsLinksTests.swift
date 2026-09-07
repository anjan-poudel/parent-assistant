import XCTest
@testable import ElderlyAssistant

/// URL-shape tests for the maps deep links + the surface-selection policy
/// (directions task, 2026-09-07). These are the pure halves of the
/// navigation pipeline's "which app" + "what URL" decisions — everything
/// testable without a device. What CANNOT be verified here (and on any
/// simulator): scheme opens, installed-ness, geocoding, MKDirections —
/// the on-device items.
final class MapsLinksTests: XCTestCase {

    // MARK: - Policy resolution

    func testAutoPrefersAppleMapsWhenOnlyAppleInstalled() {
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .auto,
                                                   googleMapsInstalled: false,
                                                   appleMapsInstalled: true),
                       .appleMaps)
    }

    func testAutoPrefersGoogleMapsWhenBothInstalled() {
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .auto,
                                                   googleMapsInstalled: true,
                                                   appleMapsInstalled: true),
                       .googleMaps)
    }

    func testAutoPrefersGoogleMapsWhenOnlyGoogleInstalled() {
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .auto,
                                                   googleMapsInstalled: true,
                                                   appleMapsInstalled: false),
                       .googleMaps)
    }

    func testAutoFallsBackToInAppWhenNothingInstalled() {
        // First simulator run without Maps installed — the walk still
        // terminates at the one surface this app itself provides.
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .auto,
                                                   googleMapsInstalled: false,
                                                   appleMapsInstalled: false),
                       .inApp)
    }

    func testExplicitGoogleMapsFallsThroughWhenMissing() {
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .googleMaps,
                                                   googleMapsInstalled: false,
                                                   appleMapsInstalled: true),
                       .appleMaps)
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .googleMaps,
                                                   googleMapsInstalled: false,
                                                   appleMapsInstalled: false),
                       .inApp)
    }

    func testExplicitAppleMapsFallsThroughWhenMissing() {
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .appleMaps,
                                                   googleMapsInstalled: true,
                                                   appleMapsInstalled: false),
                       .googleMaps)
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .appleMaps,
                                                   googleMapsInstalled: false,
                                                   appleMapsInstalled: false),
                       .inApp)
    }

    func testExplicitInAppNeverLeavesTheApp() {
        XCTAssertEqual(NavigationMapPolicy.resolve(override: .inApp,
                                                   googleMapsInstalled: true,
                                                   appleMapsInstalled: true),
                       .inApp)
    }

    /// Resolution NEVER returns `.auto` — a caller must always be able
    /// to act on the result (open a URL or present the in-app sheet).
    func testResolutionNeverReturnsAuto() {
        for override in NavigationMapApp.allCases {
            for google in [false, true] {
                for apple in [false, true] {
                    let resolved = NavigationMapPolicy.resolve(override: override,
                                                               googleMapsInstalled: google,
                                                               appleMapsInstalled: apple)
                    XCTAssertNotEqual(resolved, .auto,
                                      "override \(override) g=\(google) a=\(apple)")
                }
            }
        }
    }

    // MARK: - Probe roots

    func testProbeURLs() {
        XCTAssertEqual(MapsLinks.appleMapsProbeURL.absoluteString, "maps://")
        XCTAssertEqual(MapsLinks.googleMapsProbeURL.absoluteString, "comgooglemaps://")
    }

    // MARK: - Coordinate URLs (%.6f formatting)

    func testAppleMapsCoordinateURLFormatting() {
        let url = MapsLinks.appleMapsDirectionsURL(latitude: 27.7172,
                                                   longitude: 85.3240)
        XCTAssertEqual(url?.absoluteString, "maps://?daddr=27.717200,85.324000")
    }

    func testGoogleMapsCoordinateURLCarriesDrivingModeAndLanguageAsk() {
        let url = MapsLinks.googleMapsDirectionsURL(latitude: 27.7172,
                                                    longitude: 85.3240,
                                                    uiLanguageCode: "ne")
        XCTAssertEqual(url?.absoluteString,
                       "comgooglemaps://?daddr=27.717200,85.324000&directionsmode=driving&hl=ne&navigation=1")
    }

    func testGoogleMapsCoordinateURLHonorsPassedUILanguage() {
        // The `hl` ask is the caller's code, never a hardcoded "ne" — an
        // English session must ask for "en".
        let url = MapsLinks.googleMapsDirectionsURL(latitude: 27.7172,
                                                    longitude: 85.3240,
                                                    uiLanguageCode: "en")
        XCTAssertEqual(url?.absoluteString,
                       "comgooglemaps://?daddr=27.717200,85.324000&directionsmode=driving&hl=en&navigation=1")
    }

    func testDirectionsURLDispatchesByResolvedApp() {
        XCTAssertEqual(MapsLinks.directionsURL(for: .googleMaps, latitude: 1, longitude: 2,
                                               uiLanguageCode: "ne")?.scheme,
                       "comgooglemaps")
        XCTAssertEqual(MapsLinks.directionsURL(for: .appleMaps, latitude: 1, longitude: 2,
                                               uiLanguageCode: "ne")?.scheme,
                       "maps")
        XCTAssertNil(MapsLinks.directionsURL(for: .auto, latitude: 1, longitude: 2,
                                             uiLanguageCode: "ne"),
                     ".auto is never a resolved surface — no URL")
        XCTAssertNil(MapsLinks.directionsURL(for: .inApp, latitude: 1, longitude: 2,
                                             uiLanguageCode: "ne"),
                     ".inApp presents the in-app sheet — no external URL")
    }

    func testDirectionsURLCarriesLanguageToGoogleOnly() {
        // The coordinator's plumbing funnels the same uiLanguageCode into
        // the dispatch: Google Maps receives the `hl` ask, Apple Maps does
        // not (its scheme has no language parameter — none is invented).
        XCTAssertEqual(MapsLinks.directionsURL(for: .googleMaps,
                                               latitude: 27.7172, longitude: 85.3240,
                                               uiLanguageCode: "ne")?.absoluteString,
                       "comgooglemaps://?daddr=27.717200,85.324000&directionsmode=driving&hl=ne&navigation=1")
        XCTAssertEqual(MapsLinks.directionsURL(for: .appleMaps,
                                               latitude: 27.7172, longitude: 85.3240,
                                               uiLanguageCode: "en")?.absoluteString,
                       "maps://?daddr=27.717200,85.324000")
    }

    // MARK: - Address-string fallbacks

    func testAppleMapsAddressFallbackPercentEncodesNepali() {
        // URLComponents percent-encodes the free-form Devanagari address.
        let url = MapsLinks.appleMapsDirectionsURL(address: "बूढानीलकण्ठ, काठमाडौं ९")
        let absolute = url?.absoluteString
        XCTAssertNotNil(absolute)
        XCTAssertTrue(absolute!.hasPrefix("maps://?daddr="))
        // The raw address bytes must appear percent-encoded, never
        // verbatim (a raw UTF-8 query would be an invalid URL).
        XCTAssertTrue(absolute!.contains("%E0%A4%AC%E0%A5%82%E0%A4%A2%E0%A4%BE"))
        XCTAssertFalse(absolute!.contains("बूढानीलकण्ठ"))
        // Apple's scheme takes no language — no invented hl/navigation asks.
        XCTAssertFalse(absolute!.contains("hl"))
        XCTAssertFalse(absolute!.contains("navigation"))
    }

    func testGoogleMapsAddressFallbackCarriesDrivingModeAndLanguageAsk() {
        let url = MapsLinks.googleMapsDirectionsURL(address: "ठमेल",
                                                    uiLanguageCode: "ne")
        XCTAssertEqual(url?.absoluteString,
                       "comgooglemaps://?daddr=%E0%A4%A0%E0%A4%AE%E0%A5%87%E0%A4%B2&directionsmode=driving&hl=ne&navigation=1")
    }

    func testGoogleMapsAddressFallbackHonorsPassedUILanguage() {
        let url = MapsLinks.googleMapsDirectionsURL(address: "ठमेल",
                                                    uiLanguageCode: "en")
        XCTAssertEqual(url?.absoluteString,
                       "comgooglemaps://?daddr=%E0%A4%A0%E0%A4%AE%E0%A5%87%E0%A4%B2&directionsmode=driving&hl=en&navigation=1")
    }

    func testBlankAddressYieldsNoFallbackURL() {
        XCTAssertNil(MapsLinks.appleMapsDirectionsURL(address: "   "))
        XCTAssertNil(MapsLinks.googleMapsDirectionsURL(address: "",
                                                       uiLanguageCode: "ne"))
    }

    func testDaddrValueUsesSixDecimalPrecision() {
        XCTAssertEqual(MapsLinks.daddrValue(latitude: 27.71723456, longitude: 85.32404567),
                       "27.717235,85.324046")
    }
}
