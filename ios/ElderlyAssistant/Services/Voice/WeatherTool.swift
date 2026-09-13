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
///  - [WEATHER-ROUTING] (2026-09-07) A NAMED PLACE in the utterance
///    ("is it raining in Arncliffe") is resolved through open-meteo's
///    free geocoding API (geocoding-api.open-meteo.com/v1/search) and the
///    forecast is read for THAT point — a question about a place answers
///    for that place, never for wherever the device happens to be. Any
///    geocoding failure falls back to the device location, and the
///    router wraps every live reply in the `weather.replySource` hedge
///    ("According to the weather service, …") so a reading is presented
///    as forecast data, never as unmediated ground truth.
///  - Any failure (timeout, network error, non-200, malformed payload,
///    location denied) falls back to the EXISTING deterministic
///    `topic.weather.unavailable` line in the router — the user hears the
///    honest "live weather is not available right now" message that
///    pre-dates this tool, never a fabricated number.
///
/// [TOMORROW-WEATHER] (2026-09-13) A question about a FUTURE day
/// ("भोलिको मौसम कस्तो छ?", "will it rain tomorrow?") is a FORECAST
/// question, so it reads open-meteo's `daily` block for that day —
/// requested as `dayOffset` days ahead of the location's today
/// (1 = भोलि/tomorrow, 2 = पर्सि/the day after tomorrow) — and the reply
/// names the day ("Tomorrow it will be 14 to 22°C …" / "भोलि १४ देखि
/// २२°C … हुनेछ।"). Pre-fix the tool had no day concept at all: every
/// question fetched the `current` block and the reply said "अहिले"
/// ("now"), so a tomorrow question was answered with TODAY's weather —
/// the field report this path exists to fix. A day-0 (today) question
/// keeps the current-conditions request byte-for-byte.
///
/// Privacy: the forecast request carries ONLY coordinates (+ open-meteo's
/// fixed `current` parameter list); the geocoding request carries the
/// place name the USER spoke (a named-place question sends that name
/// instead of the device location — same provider, no identifiers).
/// Documented in the `searchSettings.privacy` settings line.
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

    /// [TOMORROW-WEATHER] (2026-09-13) One FUTURE day's forecast: the
    /// day's WMO condition code plus its temperature range, read from
    /// open-meteo's `daily` block. `dayOffset` is the day this reading
    /// was requested FOR (the router's resolved day index — 1 = tomorrow,
    /// 2 = the day after), carried so the spoken reply can name the day
    /// it belongs to.
    struct DailyForecast: Equatable {
        let temperatureMaxC: Double
        let temperatureMinC: Double
        /// WMO 4677 weather code (0–99) — see `conditionKey(wmoCode:)`.
        let wmoCode: Int
        let dayOffset: Int
    }

    /// Timeout for the forecast round-trip. The router announces
    /// "weather.checking" before firing; on failure the static fallback
    /// follows, so the budget is "user-visible ceiling" — 8 s is long
    /// enough for a mobile link, short enough to not feel hung.
    static let fetchTimeoutSeconds: TimeInterval = 8

    /// Comma-joined open-meteo `current` parameter. All four readings come
    /// from the SAME snapshot, so temperature and condition always agree.
    static let currentParameter = "temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m"

    /// Comma-joined open-meteo `daily` parameter for a FUTURE day: that
    /// day's condition code plus its temperature range. All three come
    /// from the SAME day of the same forecast run.
    static let dailyParameter = "weather_code,temperature_2m_max,temperature_2m_min"

    // MARK: - URL

    /// open-meteo forecast endpoint for one point. Pure URL construction —
    /// the unit tests assert the exact query-item set here (coordinates
    /// plus the fixed parameter list; no API key, no per-user state).
    ///
    /// `dayOffset` is how many days ahead the question asks about:
    /// 0 (default) = today → the `current` block, the historical shape;
    /// 1 = भोलि/tomorrow, 2 = पर्सि/the day after tomorrow → the `daily`
    /// block, sized to reach that day (`forecast_days` = dayOffset + 1)
    /// and timezone-aware (`timezone=auto` — the day boundaries are the
    /// QUERIED point's, so "tomorrow" means tomorrow where the weather
    /// is). A future-day request never carries `current`: today's reading
    /// cannot answer tomorrow's question.
    static func requestURL(latitude: Double, longitude: Double,
                           dayOffset: Int = 0) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        var items = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude))
        ]
        if dayOffset > 0 {
            items.append(URLQueryItem(name: "daily", value: dailyParameter))
            items.append(URLQueryItem(name: "forecast_days",
                                      value: String(dayOffset + 1)))
            items.append(URLQueryItem(name: "timezone", value: "auto"))
        } else {
            items.append(URLQueryItem(name: "current", value: currentParameter))
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: - Geocoding (named places, weather-routing 2026-09-07)

    /// open-meteo's free geocoding endpoint for a spoken place name.
    /// Pure URL construction — `count=1` (one best match), `language=en`
    /// (canonical English result names) and `format=json` are fixed; the
    /// only variable is the name itself (URL-encoded by URLComponents).
    /// No key, no per-user state.
    static func geocodingURL(name: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "geocoding-api.open-meteo.com"
        components.path = "/v1/search"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components.url!
    }

    /// One geocoding hit — the point the named-place forecast is read
    /// for, plus the geocoder's canonical name (the reply's "in <name>"
    /// clause uses THIS name, never the raw transcript fragment).
    struct GeocodedPlace: Equatable {
        let latitude: Double
        let longitude: Double
        let name: String
    }

    /// Wire format of the geocoding response (`results` is absent when
    /// nothing matched). Every field optional: a hit without a name or
    /// coordinates is not a usable place.
    private struct GeocodingPayload: Decodable {
        struct Result: Decodable {
            let name: String?
            let latitude: Double?
            let longitude: Double?
        }
        let results: [Result]?
    }

    /// Decodes the FIRST geocoding hit into a usable place. Returns nil
    /// on ANY malformation (non-JSON, wrong shape) and when nothing
    /// matched or the top hit lacks a name/coordinates — the router
    /// treats nil exactly like a network failure and falls back to the
    /// device location.
    static func parseGeocodingJSON(data: Data) -> GeocodedPlace? {
        guard let payload = try? JSONDecoder().decode(GeocodingPayload.self, from: data),
              let top = payload.results?.first,
              let name = top.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let latitude = top.latitude,
              let longitude = top.longitude else {
            return nil
        }
        return GeocodedPlace(latitude: latitude, longitude: longitude, name: name)
    }

    // MARK: - Named-place extraction (weather-routing, 2026-09-07)

    /// English marker phrases that introduce a place name — matched as
    /// substrings on the LOWERCASED transcript, longest first so
    /// "weather like in" wins over its shorter cousins. The place is the
    /// text right after the marker (see `placeName(in:)`).
    private static let englishPlaceMarkers = [
        "weather like in", "weather like at", "weather like for",
        "weather in", "weather at", "weather for",
        "forecast for", "forecast in",
        "raining in", "rains in", "rain in",
        "snowing in", "snow in", "sunny in", "cloudy in", "windy in",
        "humid in", "storm in", "hot in", "cold in", "temperature in"
    ]

    /// Tokens that END a place-name capture: time words, determiners,
    /// pronouns, conjunctions and conversational fillers that can trail a
    /// place ("is it raining in Arncliffe today?", "…in Paris or
    /// London?", "…weather in New York right now"). Anything before the
    /// first stop token is the captured place.
    private static let englishPlaceStopTokens: Set<String> = [
        "today", "tomorrow", "tonight", "now", "right", "this", "that",
        "week", "weekend", "month", "year", "later", "morning",
        "afternoon", "evening", "day", "night", "outside", "here",
        "there", "the", "a", "an", "my", "our", "your", "their", "its",
        "in", "at", "on", "for", "and", "or", "of", "like", "please",
        "around", "how", "is", "are", "was", "were", "will", "would",
        "can", "could", "do", "does", "did", "so", "if"
    ]

    /// Nepali weather-condition nouns that flag an utterance as weather
    /// talk for the locative scan below (the genitive scan has its own
    /// explicit `मौसम` adjacency and needs no trigger).
    private static let nepaliWeatherWordTriggers: Set<String> = [
        "मौसम", "पानी", "घाम", "हिउँ", "आँधी", "गर्मी", "जाडो", "चिसो",
        "तापक्रम", "बादल", "झरी", "हावा"
    ]

    /// Stripped stems that are NOT places: time words ("आजको मौसम" =
    /// today's weather), pronouns, question words and generic nouns like
    /// घर (home) — none of these may go to the geocoder.
    private static let nepaliNonPlaceStops: Set<String> = [
        "आज", "भोलि", "हिजो", "अस्ति", "पर्सि", "अहिले", "यो", "त्यो",
        "यस", "उहाँ", "तपाईं", "हामी", "म", "सबै", "धेरै", "के", "कस्तो",
        "कुन", "कति", "को", "कहाँ", "कहिले", "किन", "कसरी", "घर",
        "बाहिर", "अरु", "अब", "पछि", "तल", "माथि", "वरिपरि"
    ]

    /// [WEATHER-ROUTING] (2026-09-07) Extracts a place name from a
    /// weather utterance, or nil when the utterance names no place (the
    /// router then reads the weather for the DEVICE location). Called
    /// only after the utterance already matched the `.weather` topic.
    ///
    /// Conservative by design — a wrong place name is worse than none
    /// (the geocoder would answer for somewhere the user never asked
    /// about):
    ///
    ///  - English: a place after a weather preposition — "weather in X",
    ///    "weather like in X", "raining in X", "forecast for X" — read up
    ///    to the first time/determiner/conjunction token, max 3 tokens
    ///    ("new york", "arncliffe australia"). Lowercased on return
    ///    (STT transcripts are usually lowercase; the geocoder resolves
    ///    case).
    ///  - Nepali genitive: the token directly before मौसम ending in को
    ///    ("काठमाडौंको मौसम कस्तो छ?") → the stem. आज/भोलि (…को मौसम =
    ///    "today's weather") are rejected by the stop set.
    ///  - Nepali locative: any token ending in मा while a weather word
    ///    occurs elsewhere in the utterance ("भोलि काठमाडौंमा पानी
    ///    पर्छ कि?") → the stem. Common nouns that end in मा (घरमा,
    ///    बगैंचामा) are not distinguishable from places without a
    ///    gazetteer — they pass through and the GEOCODER rejects them,
    ///    falling back to the device location.
    ///
    /// Unsupported (deliberate, documented): place-before-verb English
    /// ("is Arncliffe rainy?"), and sentences naming two places (the
    /// first one wins).
    static func placeName(in transcript: String) -> String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        for marker in englishPlaceMarkers {
            guard let range = lower.range(of: marker) else { continue }
            let tail = String(lower[range.upperBound...])
            let tokens = tail.components(
                separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            var placeTokens: [String] = []
            for token in tokens where !token.isEmpty {
                if englishPlaceStopTokens.contains(token) { break }
                placeTokens.append(token)
                if placeTokens.count == 3 { break }
            }
            if !placeTokens.isEmpty {
                return placeTokens.joined(separator: " ")
            }
        }

        // Nepali scans (no English marker matched — the raw text is used
        // so Devanagari case-folding is a no-op).
        let tokens = text.components(
            separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
        // Genitive: "X-को मौसम" — X directly before a bare मौसम token.
        for (index, token) in tokens.enumerated()
        where token.hasSuffix("को") && index + 1 < tokens.count && tokens[index + 1] == "मौसम" {
            if let stem = usableNepaliStem(String(token.dropLast("को".count))) {
                return stem
            }
        }
        // Locative: "X-मा" anywhere in a weather utterance.
        if tokens.contains(where: { nepaliWeatherWordTriggers.contains($0) }) {
            for token in tokens where token.hasSuffix("मा") {
                if let stem = usableNepaliStem(String(token.dropLast("मा".count))) {
                    return stem
                }
            }
        }
        return nil
    }

    /// True when a stripped Nepali stem is a plausible place to geocode:
    /// non-empty, not a weather word itself, not a stop word.
    private static func usableNepaliStem(_ stem: String) -> String? {
        guard !stem.isEmpty,
              !nepaliWeatherWordTriggers.contains(stem),
              !nepaliNonPlaceStops.contains(stem) else {
            return nil
        }
        return stem
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

    /// [TOMORROW-WEATHER] (2026-09-13) Wire format of the open-meteo
    /// `daily` block: parallel arrays, one entry per forecast day
    /// (index 0 = the queried point's today). All fields optional so a
    /// short or missing array is a nil reading, never a crash.
    private struct DailyPayload: Decodable {
        struct Daily: Decodable {
            let weather_code: [Int]?
            let temperature_2m_max: [Double]?
            let temperature_2m_min: [Double]?
        }
        let daily: Daily
    }

    /// Decodes the forecast for the REQUESTED day (`dayOffset` — must be
    /// ≥ 1: day 0 is the current-conditions path, never a daily index).
    /// Returns nil unless every array carries that day AND the range is
    /// coherent (min ≤ max) — the router then takes the honest no-data
    /// line rather than speaking a different day's numbers.
    static func parseDailyForecastJSON(data: Data, dayOffset: Int) -> DailyForecast? {
        guard dayOffset >= 1,
              let payload = try? JSONDecoder().decode(DailyPayload.self, from: data),
              let codes = payload.daily.weather_code,
              let maxima = payload.daily.temperature_2m_max,
              let minima = payload.daily.temperature_2m_min,
              dayOffset < codes.count,
              dayOffset < maxima.count,
              dayOffset < minima.count else {
            return nil
        }
        let maxC = maxima[dayOffset]
        let minC = minima[dayOffset]
        guard minC <= maxC else { return nil }
        return DailyForecast(temperatureMaxC: maxC, temperatureMinC: minC,
                             wmoCode: codes[dayOffset], dayOffset: dayOffset)
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
    ///
    /// [WEATHER-ROUTING] (2026-09-07) Returns the BARE conditions
    /// sentence — the router wraps it in the `weather.replySource` hedge
    /// at the single live-delivery point, so this direct form stays the
    /// tool's own testable contract.
    static func reply(for conditions: CurrentConditions,
                      placeName: String?,
                      locale: Locale) -> String {
        let isNepali = locale.language.languageCode?.identifier == "ne"
        let temperatureText = temperatureText(conditions.temperatureC, isNepali: isNepali)
        let condition = conditionName(wmoCode: conditions.wmoCode, locale: locale)

        // en: "It's 24°C and clear in Kathmandu." / ne: "काठमाडौंमा अहिले २४°C र खुला छ।"
        return L10n.fmt("weather.reply", locale: locale,
                        temperatureText, condition, placeClause(placeName, isNepali: isNepali))
    }

    /// [TOMORROW-WEATHER] (2026-09-13) The spoken answer for a FUTURE day:
    /// "Tomorrow it will be 14 to 22°C and rain in Kathmandu." /
    /// "काठमाडौंमा भोलि १४ देखि २२°C र पानी परिरहेको हुनेछ।"
    ///
    /// The day the forecast was READ FOR (`forecast.dayOffset`) picks the
    /// reply key, so the sentence names भोलि/पर्सि — a future-day reading
    /// is a FORECAST and must never be spoken as "अहिले"/"It's …" (the
    /// exact lie the field report caught: tomorrow's question answered
    /// with today's reading). The temperature is the day's RANGE, the
    /// house spoken form for a daily forecast.
    static func reply(for forecast: DailyForecast,
                      placeName: String?,
                      locale: Locale) -> String {
        let isNepali = locale.language.languageCode?.identifier == "ne"
        let minText = temperatureText(forecast.temperatureMinC, isNepali: isNepali)
        let maxText = temperatureText(forecast.temperatureMaxC, isNepali: isNepali)
        let condition = conditionName(wmoCode: forecast.wmoCode, locale: locale)
        // 2 is the deepest day the resolver produces (पर्सि); anything
        // beyond reads as the far day rather than silently as tomorrow.
        let key = forecast.dayOffset >= 2
            ? "weather.reply.dayAfterTomorrow"
            : "weather.reply.tomorrow"

        // en: "Tomorrow it will be 14 to 22°C and rain in Kathmandu."
        // ne: "काठमाडौंमा भोलि १४ देखि २२°C र पानी परिरहेको हुनेछ।"
        return L10n.fmt(key, locale: locale,
                        minText, maxText, condition,
                        placeClause(placeName, isNepali: isNepali))
    }

    /// Spoken degrees: Devanagari numerals under Nepali, rounded to the
    /// nearest degree (the house convention of `TopicPreAnswer`).
    private static func temperatureText(_ celsius: Double, isNepali: Bool) -> String {
        let rounded = Int(celsius.rounded())
        return isNepali ? BikramSambat.devanagariDigits(rounded) : String(rounded)
    }

    /// The "in X" / "Xमा " glue, as an argument so a nil place (device
    /// location without a reverse-geocoded name, geocode miss) still
    /// yields a grammatical sentence. Trimmed: a whitespace-only place
    /// must read as ABSENT, never "in     ."
    private static func placeClause(_ placeName: String?, isNepali: Bool) -> String {
        guard let trimmed = placeName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return ""
        }
        return isNepali ? "\(trimmed)मा " : " in \(trimmed)"
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

    /// [TOMORROW-WEATHER] (2026-09-13) The same fetch for a FUTURE day:
    /// reads the `daily` block for day `dayOffset` (≥ 1) at one point.
    /// Same error discipline as `fetchCurrent` — non-200 and undecodable
    /// (or day-less) payloads throw, transport errors propagate, and the
    /// router answers with the honest no-data line on any throw.
    static func fetchDailyForecast(latitude: Double,
                                   longitude: Double,
                                   dayOffset: Int,
                                   transport: LocalToolTransport = URLSession.shared) async throws -> DailyForecast {
        var request = URLRequest(url: requestURL(latitude: latitude, longitude: longitude,
                                                 dayOffset: dayOffset))
        request.timeoutInterval = fetchTimeoutSeconds
        let (data, response) = try await transport.fetchData(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.invalidResponse(statusCode: http.statusCode)
        }
        guard let forecast = parseDailyForecastJSON(data: data, dayOffset: dayOffset) else {
            throw FetchError.malformedResponse
        }
        return forecast
    }

    /// [WEATHER-ROUTING] (2026-09-07) Resolves a spoken place name to a
    /// point via the open-meteo geocoder over the SAME transport seam as
    /// `fetchCurrent`. Throws `FetchError` on non-200 / undecodable /
    /// no-match payloads; transport-level errors propagate as-is. The
    /// router falls back to the device location on ANY throw.
    static func fetchGeocode(name: String,
                             transport: LocalToolTransport = URLSession.shared) async throws -> GeocodedPlace {
        var request = URLRequest(url: geocodingURL(name: name))
        request.timeoutInterval = fetchTimeoutSeconds
        let (data, response) = try await transport.fetchData(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.invalidResponse(statusCode: http.statusCode)
        }
        guard let place = parseGeocodingJSON(data: data) else {
            throw FetchError.malformedResponse
        }
        return place
    }
}
