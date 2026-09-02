import XCTest
@testable import ElderlyAssistant

final class NepaliTimeParserTests: XCTestCase {

    func testMorningPeriodWordWithHour() {
        XCTAssertEqual(NepaliTimeParser.parse("बिहान ८ बजे"),
                       DateComponents(hour: 8, minute: 0))
    }

    func testAfternoonPeriodWordAdjustsTo24Hour() {
        XCTAssertEqual(NepaliTimeParser.parse("दिउँसो २ बजे"),
                       DateComponents(hour: 14, minute: 0))
    }

    func testEveningPeriodWordAdjustsTo24Hour() {
        XCTAssertEqual(NepaliTimeParser.parse("बेलुका ७ बजे"),
                       DateComponents(hour: 19, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("साँझ ५ बजे"),
                       DateComponents(hour: 17, minute: 0))
    }

    func testNightPeriodWordAdjustsTo24Hour() {
        XCTAssertEqual(NepaliTimeParser.parse("राति ९ बजे"),
                       DateComponents(hour: 21, minute: 0))
    }

    func testSaadheMeansHalfPast() {
        XCTAssertEqual(NepaliTimeParser.parse("साढे ८"),
                       DateComponents(hour: 8, minute: 30))
    }

    func testClockStringWithColon() {
        XCTAssertEqual(NepaliTimeParser.parse("8:30"),
                       DateComponents(hour: 8, minute: 30))
    }

    func testDandaClockString() {
        XCTAssertEqual(NepaliTimeParser.parse("८॥३०"),
                       DateComponents(hour: 8, minute: 30))
    }

    func testAmPmSuffixes() {
        XCTAssertEqual(NepaliTimeParser.parse("8 am"),
                       DateComponents(hour: 8, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("1 pm"),
                       DateComponents(hour: 13, minute: 0))
    }

    func testPeriodWordAloneUsesRepresentativeTime() {
        XCTAssertEqual(NepaliTimeParser.parse("बिहान"), DateComponents(hour: 8, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("दिउँसो"), DateComponents(hour: 12, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("साँझ"), DateComponents(hour: 17, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("राति"), DateComponents(hour: 20, minute: 0))
    }

    func testAbMeansNow() {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let parsed = NepaliTimeParser.parse("अब १० मिनेटपछि सम्झाउनु")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.hour, now.hour)
        XCTAssertEqual(parsed?.minute, now.minute)
    }

    func testDevanagariDigits() {
        XCTAssertEqual(NepaliTimeParser.parse("१० बजे औषधि सम्झाउनु"),
                       DateComponents(hour: 10, minute: 0))
    }

    func testNonTimeTextReturnsNil() {
        XCTAssertNil(NepaliTimeParser.parse("भोलि मौसम कस्तो छ"))
        XCTAssertNil(NepaliTimeParser.parse(""))
        XCTAssertNil(NepaliTimeParser.parse("छोरालाई फोन गर"))
    }
}
