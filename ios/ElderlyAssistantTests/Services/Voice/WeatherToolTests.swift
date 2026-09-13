import XCTest
@testable import ElderlyAssistant

/// [LOCAL-TOOLS] (2026-09-07) Live-weather tool contract (pure seams — no
/// network):
///  - the forecast URL is exactly the open-meteo shape (coordinates +
///    ONE fixed `current` parameter list, no key, no user state),
///  - parsing accepts the real payload shape and tolerates the optional
///    wind/humidity readings; anything malformed is nil (the router then
///    falls back to the deterministic no-data line),
///  - WMO codes band onto the spoken-condition keys (0 clear, 1–3 partly
///    cloudy, 45/48 fog, 51–67 rain, 71–77 + 85/86 snow, 80–84 rain
///    showers, 95–99 thunderstorm; anything else → unknown),
///  - the reply is localized with Devanagari numerals under Nepali and
///    reads grammatically WITH and WITHOUT a place name.
final class WeatherToolTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")
    private let en = Locale(identifier: "en")

    // MARK: - URL shape

    func testRequestURLHitsOpenMeteoForecastWithExactQueryItems() {
        let url = WeatherTool.requestURL(latitude: 27.7172, longitude: 85.3240)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "api.open-meteo.com")
        XCTAssertEqual(components?.path, "/v1/forecast")
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "latitude", value: "27.7172"),
            URLQueryItem(name: "longitude", value: "85.324"),
            URLQueryItem(name: "current",
                         value: "temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m")
        ])
    }

    // MARK: - Parsing

    func testParseHappyPathDecodesAllReadings() {
        let data = Data("""
        {"current": {"temperature_2m": 24.3, "weather_code": 1,
                     "wind_speed_10m": 12.5, "relative_humidity_2m": 62}}
        """.utf8)

        XCTAssertEqual(WeatherTool.parseForecastJSON(data: data),
                       WeatherTool.CurrentConditions(temperatureC: 24.3,
                                                     wmoCode: 1,
                                                     windKmh: 12.5,
                                                     humidityPercent: 62))
    }

    func testParseToleratesMissingOptionalWindAndHumidity() {
        let data = Data("""
        {"current": {"temperature_2m": -3.0, "weather_code": 71}}
        """.utf8)

        XCTAssertEqual(WeatherTool.parseForecastJSON(data: data),
                       WeatherTool.CurrentConditions(temperatureC: -3.0,
                                                     wmoCode: 71,
                                                     windKmh: nil,
                                                     humidityPercent: nil))
    }

    func testParseReturnsNilForMalformedPayloads() {
        XCTAssertNil(WeatherTool.parseForecastJSON(data: Data("not json".utf8)))
        // Missing `current` block.
        XCTAssertNil(WeatherTool.parseForecastJSON(data: Data(#"{"hourly": {}}"#.utf8)))
        // Missing the REQUIRED temperature reading.
        XCTAssertNil(WeatherTool.parseForecastJSON(data: Data(#"{"current": {"weather_code": 1}}"#.utf8)))
        // Missing the REQUIRED weather code.
        XCTAssertNil(WeatherTool.parseForecastJSON(data: Data(#"{"current": {"temperature_2m": 1}}"#.utf8)))
        // Empty payload.
        XCTAssertNil(WeatherTool.parseForecastJSON(data: Data()))
    }

    // MARK: - WMO code → condition mapping

    func testWMOCodeMappingFollowsOpenMeteoBands() {
        func key(_ code: Int) -> String { WeatherTool.conditionKey(wmoCode: code) }
        XCTAssertEqual(key(0), "weather.condition.clear")
        for code in 1...3 {
            XCTAssertEqual(key(code), "weather.condition.partlyCloudy", "code \(code)")
        }
        XCTAssertEqual(key(45), "weather.condition.fog")
        XCTAssertEqual(key(48), "weather.condition.fog")
        for code in [51, 53, 55, 56, 57, 61, 63, 65, 66, 67] {
            XCTAssertEqual(key(code), "weather.condition.rain", "code \(code)")
        }
        for code in [71, 73, 75, 77] {
            XCTAssertEqual(key(code), "weather.condition.snow", "code \(code)")
        }
        // Rain showers (open-meteo emits 80–82) stay rain…
        for code in 80...84 {
            XCTAssertEqual(key(code), "weather.condition.rain", "code \(code)")
        }
        // …snow showers are snow…
        XCTAssertEqual(key(85), "weather.condition.snow")
        XCTAssertEqual(key(86), "weather.condition.snow")
        // …and thunderstorms (with/without hail) are thunderstorm.
        for code in 95...99 {
            XCTAssertEqual(key(code), "weather.condition.thunderstorm", "code \(code)")
        }
    }

    func testUnexpectedCodesMapToUnknown() {
        // Ice pellets / codes open-meteo never emits / out-of-band values
        // must degrade to the honest generic word, never a wrong claim.
        XCTAssertEqual(WeatherTool.conditionKey(wmoCode: 68), "weather.condition.unknown")
        XCTAssertEqual(WeatherTool.conditionKey(wmoCode: 78), "weather.condition.unknown")
        XCTAssertEqual(WeatherTool.conditionKey(wmoCode: 100), "weather.condition.unknown")
    }

    func testConditionNameResolvesLocalizedWords() {
        XCTAssertEqual(WeatherTool.conditionName(wmoCode: 0, locale: en), "clear")
        XCTAssertEqual(WeatherTool.conditionName(wmoCode: 1, locale: en), "partly cloudy")
        XCTAssertEqual(WeatherTool.conditionName(wmoCode: 61, locale: en), "rain")
        XCTAssertEqual(WeatherTool.conditionName(wmoCode: 95, locale: en), "thunderstorm")
        XCTAssertEqual(WeatherTool.conditionName(wmoCode: 0, locale: ne), "खुला")
        XCTAssertEqual(WeatherTool.conditionName(wmoCode: 61, locale: ne), "पानी परिरहेको")
        XCTAssertEqual(WeatherTool.conditionName(wmoCode: 300, locale: ne), "मौसम")
    }

    // MARK: - Spoken reply

    func testEnglishReplyWithPlaceName() {
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3,
                                                       wmoCode: 0, windKmh: nil, humidityPercent: nil)
        XCTAssertEqual(WeatherTool.reply(for: conditions, placeName: "Kathmandu", locale: en),
                       "It's 24°C and clear in Kathmandu.")
    }

    func testEnglishReplyWithoutPlaceNameOmitsTheClause() {
        let conditions = WeatherTool.CurrentConditions(temperatureC: -1.6,
                                                       wmoCode: 71, windKmh: nil, humidityPercent: nil)
        XCTAssertEqual(WeatherTool.reply(for: conditions, placeName: nil, locale: en),
                       "It's -2°C and snow.")
    }

    func testNepaliReplyUsesDevanagariNumeralsAndPlaceFirst() {
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.3,
                                                       wmoCode: 1, windKmh: nil, humidityPercent: nil)
        XCTAssertEqual(WeatherTool.reply(for: conditions, placeName: "काठमाडौं", locale: ne),
                       "काठमाडौंमा अहिले २४°C र आंशिक बादल छ।")
    }

    func testNepaliReplyWithoutPlaceNameStillReadsGrammatically() {
        let conditions = WeatherTool.CurrentConditions(temperatureC: 9.0,
                                                       wmoCode: 61, windKmh: nil, humidityPercent: nil)
        XCTAssertEqual(WeatherTool.reply(for: conditions, placeName: nil, locale: ne),
                       "अहिले ९°C र पानी परिरहेको छ।")
    }

    func testTemperatureRoundsToNearestDegree() {
        let conditions = WeatherTool.CurrentConditions(temperatureC: 24.6,
                                                       wmoCode: 0, windKmh: nil, humidityPercent: nil)
        XCTAssertEqual(WeatherTool.reply(for: conditions, placeName: nil, locale: en),
                       "It's 25°C and clear.")
    }

    func testEmptyPlaceNameIsTreatedAsAbsent() {
        let conditions = WeatherTool.CurrentConditions(temperatureC: 20,
                                                       wmoCode: 95, windKmh: nil, humidityPercent: nil)
        XCTAssertEqual(WeatherTool.reply(for: conditions, placeName: "   ", locale: en),
                       "It's 20°C and thunderstorm.")
    }

    // MARK: - Named-place extraction (weather-routing, 2026-09-07)

    func testPlaceNameExtractsAfterEnglishWeatherPrepositions() {
        XCTAssertEqual(WeatherTool.placeName(in: "is it raining in Arncliffe"), "arncliffe")
        XCTAssertEqual(WeatherTool.placeName(in: "What's the weather like in Arncliffe today?"),
                       "arncliffe")
        XCTAssertEqual(WeatherTool.placeName(in: "check the weather in Kathmandu please"),
                       "kathmandu")
        XCTAssertEqual(WeatherTool.placeName(in: "what is the forecast for Pokhara tomorrow"),
                       "pokhara")
        XCTAssertEqual(WeatherTool.placeName(in: "will it snow in Canberra this week"),
                       "canberra")
        XCTAssertEqual(WeatherTool.placeName(in: "what is the temperature in Tokyo right now"),
                       "tokyo")
    }

    func testPlaceNameExtractsCompoundPlaceNames() {
        // Up to three tokens — "new york", "arncliffe australia".
        XCTAssertEqual(WeatherTool.placeName(in: "what is the weather in New York"), "new york")
        XCTAssertEqual(WeatherTool.placeName(in: "is it raining in Arncliffe, Australia?"),
                       "arncliffe australia")
    }

    func testPlaceNameReturnsNilWhenNoNamedPlace() {
        XCTAssertNil(WeatherTool.placeName(in: "what is the weather like"))
        XCTAssertNil(WeatherTool.placeName(in: "how hot is it today"))
        XCTAssertNil(WeatherTool.placeName(in: "is it raining outside"))
        XCTAssertNil(WeatherTool.placeName(in: "is it cold in here"))
        XCTAssertNil(WeatherTool.placeName(in: "weather like for tomorrow"))
        XCTAssertNil(WeatherTool.placeName(in: "मौसम कस्तो छ?"))
        XCTAssertNil(WeatherTool.placeName(in: "   "))
        XCTAssertNil(WeatherTool.placeName(in: ""))
    }

    func testPlaceNameExtractsNepaliGenitivePlace() {
        // "काठमाडौंको मौसम कस्तो छ?" — the token before मौसम, minus को.
        XCTAssertEqual(WeatherTool.placeName(in: "काठमाडौंको मौसम कस्तो छ?"), "काठमाडौं")
    }

    func testPlaceNameExtractsNepaliLocativePlace() {
        // X-मा with a bare weather word elsewhere in the utterance.
        XCTAssertEqual(WeatherTool.placeName(in: "भोलि काठमाडौंमा पानी पर्छ कि?"), "काठमाडौं")
        XCTAssertEqual(WeatherTool.placeName(in: "काठमाडौंमा मौसम कस्तो छ?"), "काठमाडौं")
    }

    func testPlaceNameNepaliTimeWordsAreNotPlaces() {
        // "आजको/भोलिको मौसम" = today's/tomorrow's weather — not a place.
        XCTAssertNil(WeatherTool.placeName(in: "आजको मौसम कस्तो छ?"))
        XCTAssertNil(WeatherTool.placeName(in: "भोलिको मौसम कस्तो होला?"))
        // "घरमा" (at home) is not a geocodable place either.
        XCTAssertNil(WeatherTool.placeName(in: "घरमा पानी पर्छ कि?"))
    }

    func testPlaceNameDoesNotConfuseWeatherWordsForPlaces() {
        // A मा-suffixed weather word is the topic, not a place.
        XCTAssertNil(WeatherTool.placeName(in: "मौसममा के भयो?"))
    }

    // MARK: - Geocoding seams (weather-routing, 2026-09-07)

    func testGeocodingURLTargetsOpenMeteoSearchWithExactQueryItems() {
        let url = WeatherTool.geocodingURL(name: "Arncliffe")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(components?.path, "/v1/search")
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "name", value: "Arncliffe"),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ])
    }

    func testGeocodingURLPercentEncodesDevanagariName() {
        let url = WeatherTool.geocodingURL(name: "काठमाडौं")

        // The wire URL carries the name percent-encoded — no raw
        // Devanagari bytes on the wire…
        XCTAssertFalse(url.absoluteString.contains("काठमाडौं"))
        XCTAssertTrue(url.absoluteString.contains("name="))
        // …and URLComponents still decodes the exact original name.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "name" }?.value,
                       "काठमाडौं")
    }

    func testParseGeocodingHappyPathDecodesTopHit() {
        let data = Data("""
        {"results": [
            {"id": 1, "name": "Arncliffe", "latitude": -33.9375, "longitude": 151.1522,
             "country": "Australia", "admin1": "New South Wales"}
        ]}
        """.utf8)

        XCTAssertEqual(WeatherTool.parseGeocodingJSON(data: data),
                       WeatherTool.GeocodedPlace(latitude: -33.9375, longitude: 151.1522,
                                                 name: "Arncliffe"))
    }

    func testParseGeocodingReturnsNilWhenNothingMatchedOrMalformed() {
        // 200 OK but zero hits — indistinguishable from failure by design.
        XCTAssertNil(WeatherTool.parseGeocodingJSON(data: Data(#"{"results": []}"#.utf8)))
        // No results key at all.
        XCTAssertNil(WeatherTool.parseGeocodingJSON(data: Data(#"{"generationtime_ms": 0.5}"#.utf8)))
        // Top hit missing coordinates or name.
        XCTAssertNil(WeatherTool.parseGeocodingJSON(data:
            Data(#"{"results": [{"name": "Nowhere"}]}"#.utf8)))
        XCTAssertNil(WeatherTool.parseGeocodingJSON(data:
            Data(#"{"results": [{"latitude": 1.0, "longitude": 2.0}]}"#.utf8)))
        // Blank name.
        XCTAssertNil(WeatherTool.parseGeocodingJSON(data:
            Data(#"{"results": [{"name": "  ", "latitude": 1.0, "longitude": 2.0}]}"#.utf8)))
        // Non-JSON / empty.
        XCTAssertNil(WeatherTool.parseGeocodingJSON(data: Data("not json".utf8)))
        XCTAssertNil(WeatherTool.parseGeocodingJSON(data: Data()))
    }

    // MARK: - Day-aware query (tomorrow's weather, 2026-09-13)
    //
    // Field report: asking (in Nepali) for TOMORROW's weather answered
    // with TODAY's. Root cause: the tool had no day concept at all — the
    // request carried only open-meteo's `current` block and the reply
    // said "अहिले"/"It's …", so a भोलि/पर्सि question was answered with
    // the current (today) reading. These tests pin the day-aware query,
    // the daily payload parsing and the day-naming reply.

    /// open-meteo daily parameter list — one day's forecast: condition
    /// code plus the day's temperature range.
    private let dailyJSON = Data("""
    {"daily": {"time": ["2026-09-13", "2026-09-14", "2026-09-15"],
               "weather_code": [0, 61, 3],
               "temperature_2m_max": [24.3, 22.1, 25.0],
               "temperature_2m_min": [15.2, 14.0, 16.0]}}
    """.utf8)

    func testRequestURLForTodayKeepsTheCurrentConditionsShape() {
        // dayOffset 0 (आज / no day word) is the pre-existing behaviour —
        // the exact `current`-only request is pinned above and must not
        // drift: today's question is answered with a live reading.
        XCTAssertEqual(WeatherTool.requestURL(latitude: 27.7172, longitude: 85.3240, dayOffset: 0),
                       WeatherTool.requestURL(latitude: 27.7172, longitude: 85.3240))
    }

    func testRequestURLForTomorrowAsksTheDailyBlockForThatDay() {
        let url = WeatherTool.requestURL(latitude: 27.7172, longitude: 85.3240, dayOffset: 1)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.host, "api.open-meteo.com")
        XCTAssertEqual(components?.path, "/v1/forecast")
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "latitude", value: "27.7172"),
            URLQueryItem(name: "longitude", value: "85.324"),
            URLQueryItem(name: "daily",
                         value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto")
        ])
        XCTAssertNil(components?.queryItems?.first { $0.name == "current" },
                     "a future-day question must not fetch the current reading")
    }

    func testRequestURLForTheDayAfterTomorrowRequestsThreeDays() {
        let url = WeatherTool.requestURL(latitude: 1.5, longitude: 2.5, dayOffset: 2)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "forecast_days" }?.value, "3")
        XCTAssertEqual(items?.first { $0.name == "timezone" }?.value, "auto")
    }

    func testParseDailyForecastPicksTheRequestedDay() {
        // Index 1 = tomorrow: 14.0…22.1 °C, WMO 61 = rain.
        XCTAssertEqual(WeatherTool.parseDailyForecastJSON(data: dailyJSON, dayOffset: 1),
                       WeatherTool.DailyForecast(temperatureMaxC: 22.1,
                                                 temperatureMinC: 14.0,
                                                 wmoCode: 61,
                                                 dayOffset: 1))
        // Index 2 = the day after tomorrow.
        XCTAssertEqual(WeatherTool.parseDailyForecastJSON(data: dailyJSON, dayOffset: 2),
                       WeatherTool.DailyForecast(temperatureMaxC: 25.0,
                                                 temperatureMinC: 16.0,
                                                 wmoCode: 3,
                                                 dayOffset: 2))
    }

    func testParseDailyForecastReturnsNilForOutOfRangeOrMalformed() {
        // Index 3 is past the requested window — the payload cannot
        // answer the asked day, so the router takes the honest line.
        XCTAssertNil(WeatherTool.parseDailyForecastJSON(data: dailyJSON, dayOffset: 3))
        // dayOffset 0 is the CURRENT path — never a daily index.
        XCTAssertNil(WeatherTool.parseDailyForecastJSON(data: dailyJSON, dayOffset: 0))
        // A `current`-only payload does not decode as a daily forecast.
        XCTAssertNil(WeatherTool.parseDailyForecastJSON(
            data: Data(#"{"current": {"temperature_2m": 24.3, "weather_code": 0}}"#.utf8),
            dayOffset: 1))
        // Missing/blank arrays, non-JSON, empty.
        XCTAssertNil(WeatherTool.parseDailyForecastJSON(
            data: Data(#"{"daily": {"weather_code": [0, 61]}}"#.utf8), dayOffset: 1))
        XCTAssertNil(WeatherTool.parseDailyForecastJSON(data: Data("not json".utf8), dayOffset: 1))
        XCTAssertNil(WeatherTool.parseDailyForecastJSON(data: Data(), dayOffset: 1))
        // A swapped range is not a usable forecast (never speak it).
        XCTAssertNil(WeatherTool.parseDailyForecastJSON(
            data: Data(#"{"daily": {"weather_code": [61], "temperature_2m_max": [10.0], "temperature_2m_min": [20.0]}}"#.utf8),
            dayOffset: 1))
    }

    func testTomorrowReplyNamesTheDayInEnglishAndNepali() {
        let forecast = WeatherTool.DailyForecast(temperatureMaxC: 22.1, temperatureMinC: 14.0,
                                                 wmoCode: 61, dayOffset: 1)
        XCTAssertEqual(WeatherTool.reply(for: forecast, placeName: "Kathmandu", locale: en),
                       "Tomorrow it will be 14 to 22°C and rain in Kathmandu.")
        XCTAssertEqual(WeatherTool.reply(for: forecast, placeName: nil, locale: en),
                       "Tomorrow it will be 14 to 22°C and rain.")
        XCTAssertEqual(WeatherTool.reply(for: forecast, placeName: "काठमाडौं", locale: ne),
                       "काठमाडौंमा भोलि १४ देखि २२°C र पानी परिरहेको हुनेछ।")
        XCTAssertEqual(WeatherTool.reply(for: forecast, placeName: nil, locale: ne),
                       "भोलि १४ देखि २२°C र पानी परिरहेको हुनेछ।")
    }

    func testDayAfterTomorrowReplyUsesTheFarDayWord() {
        let forecast = WeatherTool.DailyForecast(temperatureMaxC: 25.0, temperatureMinC: 16.0,
                                                 wmoCode: 3, dayOffset: 2)
        XCTAssertEqual(WeatherTool.reply(for: forecast, placeName: nil, locale: en),
                       "The day after tomorrow it will be 16 to 25°C and partly cloudy.")
        XCTAssertEqual(WeatherTool.reply(for: forecast, placeName: nil, locale: ne),
                       "पर्सि १६ देखि २५°C र आंशिक बादल हुनेछ।")
    }

    /// The honesty pin: a future-day reading is a forecast, so it must
    /// NEVER claim "now" ("अहिले" / "It's …") — that was exactly the lie
    /// the field report caught ("tomorrow's weather" answered as today's).
    func testFutureDayReplyNeverClaimsNow() {
        let forecast = WeatherTool.DailyForecast(temperatureMaxC: 24.0, temperatureMinC: 15.0,
                                                 wmoCode: 0, dayOffset: 1)
        let nepali = WeatherTool.reply(for: forecast, placeName: "काठमाडौं", locale: ne)
        let english = WeatherTool.reply(for: forecast, placeName: "Kathmandu", locale: en)
        XCTAssertFalse(nepali.contains("अहिले"), "गोल forecast must not be spoken as now: \(nepali)")
        XCTAssertFalse(english.contains("It's"), "a forecast must not be spoken as now: \(english)")
    }
}
