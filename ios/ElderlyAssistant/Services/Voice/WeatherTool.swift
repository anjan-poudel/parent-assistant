import Foundation

/// [LOCAL-TOOLS] (2026-09-07) Live-weather tool for the ON-DEVICE voice
/// stack, consulted by `CommandRouter` when a weather question reaches the
/// deterministic layer but no live-web path exists (stack == .onDevice).
/// The Gemini stack keeps its existing grounding path untouched.
///
/// Honesty contract (same rules as `TopicPreAnswer`):
///  - LIVE data only from open-meteo's public forecast API
///    (api.open-meteo.com/v1/forecast) — no fabricated forecasts, no
///    cached guesses.
///  - The temperature is always a real current-conditions reading; the
///    condition word comes from the WMO weather-code table below, mapped
///    to the SAME condition vocabulary the spoken reply uses.
///  - Any failure (timeout, network error, non-200, malformed payload,
///    location denied) falls back to the EXISTING deterministic
///    `topic.weather.unavailable` line in the router — the user hears the
///    honest "live weather is not available right now" message that
///    pre-dates this tool, never a fabricated number.
///
/// Privacy: the request carries ONLY coordinates (+ open-meteo's fixed
/// `current` parameter list); no user data, no identifiers. Documented in
/// the `searchSettings.privacy` settings line.
///
/// Design: a caseless enum of pure statics (house tool pattern, like
/// `CalculatorTool`) with a transport seam (`LocalToolTransport`) so tests
/// never touch the network — parse and URL-shape seams only.
enum WeatherTool {

    /// What "current weather" means here: one snapshot from open-meteo's
    /// `current` block. Optionals mirror the API — wind/humidity are
    /// requested but a payload that omits them is still a usable fix.
    struct CurrentConditions: Equatable {
        let temperatureC: Double
        /// WMO 4677 weather code (0–99) — see `conditionKey(wmoCode:)`.
        let wmoCode: Int
        let windKmh: Double?
        let humidityPercent: Int?
    }

    /// Why `fetchCurrent` failed. The router maps every case to the same
    /// honest fallback line — the distinction exists for tests and
    /// observability, not for user-facing speech.
    enum FetchError: Error, Equatable {
        /// The server answered, but not with 200 OK.
        case invalidResponse(statusCode: Int)
        /// The payload did not decode into usable current conditions.
        case malformedResponse
    }

    /// Timeout for the forecast round-trip. The router announces
    /// "weather.checking" before firing; on failure the static fallback
    /// follows, so the budget is "user-visible ceiling" — 8 s is long
    /// enough for a mobile link, short enough to not feel hung.
    static let fetchTimeoutSeconds: TimeInterval = 8

    /// Comma-joined open-meteo `current` parameter. All four readings come
    /// from the SAME snapshot, so temperature and condition always agree.
    static let currentParameter = "temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m"

    // MARK: - URL

    /// open-meteo forecast endpoint for one point. Pure URL construction —
    /// the unit tests assert the exact query-item set here (coordinates
    /// plus ONLY the fixed `current` parameter list; no API key, no
    /// per-user state).
    static func requestURL(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentParameter)
        ]
        return components.url!
    }

    // MARK: - Parsing

    /// Wire format of the open-meteo current block. Only the keys we
    /// requested are decoded; temperature and weather code are required,
    /// wind/humidity optional (a snapshot missing them is still honest).
    private struct ForecastPayload: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let wind_speed_10m: Double?
            let relative_humidity_2m: Int?
        }
        let current: Current
    }

    /// Decodes `ForecastPayload`. Returns nil on ANY malformation
    /// (non-JSON, wrong shape, missing required keys) — the router treats
    /// nil exactly like a network failure.
    static func parseForecastJSON(data: Data) -> CurrentConditions? {
        guard let payload = try? JSONDecoder().decode(ForecastPayload.self, from: data) else {
            return nil
        }
        return CurrentConditions(temperatureC: payload.current.temperature_2m,
                                 wmoCode: payload.current.weather_code,
                                 windKmh: payload.current.wind_speed_10m,
                                 humidityPercent: payload.current.relative_humidity_2m)
    }

    // MARK: - Conditions

    /// WMO 4677 weather code → localization key. Banding follows
    /// open-meteo's own code table:
    ///
    ///   - 0            clear sky
    ///   - 1–3          mainly/partly clear, overcast-in-between
    ///   - 45, 48       fog / depositing rime fog
    ///   - 51–67        drizzle + freezing drizzle + rain (+ freezing)
    ///   - 71–77        snow fall
    ///   - 80–84        rain showers (open-meteo emits 80–82)
    ///   - 85, 86       snow showers
    ///   - 95–99        thunderstorm (with/without hail)
    ///   - anything else (incl. 68/69/78 ice-pellet oddities) → unknown,
    ///     which the reply still reads honestly ("weather" / "मौसम").
    static func conditionKey(wmoCode: Int) -> String {
        switch wmoCode {
        case 0:
            return "weather.condition.clear"
        case 1...3:
            return "weather.condition.partlyCloudy"
        case 45, 48:
            return "weather.condition.fog"
        case 51...67:
            return "weather.condition.rain"
        case 71...77:
            return "weather.condition.snow"
        case 80...84:
            return "weather.condition.rain"    // rain showers
        case 85, 86:
            return "weather.condition.snow"    // snow showers
        case 95...99:
            return "weather.condition.thunderstorm"
        default:
            return "weather.condition.unknown"
        }
    }

    /// Localized spoken condition word ("clear", "खुला", …).
    static func conditionName(wmoCode: Int, locale: Locale) -> String {
        L10n.str(conditionKey(wmoCode: wmoCode), locale: locale)
    }

    // MARK: - Reply

    /// The spoken answer: "It's 24°C and clear in Kathmandu." /
    /// "काठमाडौंमा अहिले २४°C र खुला छ।"
    ///
    /// Temperature renders in Devanagari numerals under Nepali — the house
    /// convention of `TopicPreAnswer`/`CalculatorTool` — so the reply key
    /// takes PRE-RENDERED text placeholders (deviating from the spec's
    /// literal %d sample for that reason; the sentence shape matches).
    /// `placeName` is a spoken clause, not a bare noun: the "in …" /
    /// "…मा " glue lives in the argument so a nil place (simulator, denied
    /// location, geocode miss) still yields a grammatical sentence.
    static func reply(for conditions: CurrentConditions,
                      placeName: String?,
                      locale: Locale) -> String {
        let isNepali = locale.language.languageCode?.identifier == "ne"
        let rounded = Int(conditions.temperatureC.rounded())

        let temperatureText = isNepali
            ? BikramSambat.devanagariDigits(rounded)
            : String(rounded)

        let condition = conditionName(wmoCode: conditions.wmoCode, locale: locale)

        let placeClause: String
        // Trimmed: a whitespace-only placeName (geocoder gave nothing)
        // must read as ABSENT, never "in     ."
        if let trimmed = placeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            placeClause = isNepali ? "\(trimmed)मा " : " in \(trimmed)"
        } else {
            placeClause = ""
        }

        // en: "It's 24°C and clear in Kathmandu." / ne: "काठमाडौंमा अहिले २४°C र खुला छ।"
        return L10n.fmt("weather.reply", locale: locale,
                        temperatureText, condition, placeClause)
    }

    // MARK: - Fetch

    /// Fetches and parses current conditions at one point via `transport`
    /// (URLSession in production, a stub in tests). Throws `FetchError`
    /// on non-200 / undecodable payloads; transport-level errors (timeout,
    /// no network) propagate as-is — the router catches everything.
    static func fetchCurrent(latitude: Double,
                             longitude: Double,
                             transport: LocalToolTransport = URLSession.shared) async throws -> CurrentConditions {
        var request = URLRequest(url: requestURL(latitude: latitude, longitude: longitude))
        request.timeoutInterval = fetchTimeoutSeconds
        let (data, response) = try await transport.fetchData(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.invalidResponse(statusCode: http.statusCode)
        }
        guard let conditions = parseForecastJSON(data: data) else {
            throw FetchError.malformedResponse
        }
        return conditions
    }
}
