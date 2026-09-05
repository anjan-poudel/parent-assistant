import XCTest
@testable import ElderlyAssistant

final class CallOverrideParserTests: XCTestCase {

    func testPhoneOverrideNepali() {
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("होइन, फोन नै गर"), .phone)
    }

    func testWhatsAppOverrideBothScripts() {
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("होइन, वाट्सएपमा गर"), .whatsappChat)
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("no, use whatsapp"), .whatsappChat)
    }

    func testVideoOverride() {
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("भिडियो कलमा गर"), .facetimeVideo)
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("make it a video call"), .facetimeVideo)
    }

    func testFaceTimeOverride() {
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("फेसटाइममा गर"), .facetimeAudio)
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("facetime instead"), .facetimeAudio)
    }

    func testWhatsAppWinsOverStrayCallToken() {
        // "whatsapp ma call gara" — the app mention outranks the generic
        // call word, or the override would flip to tel: against the
        // user's plain meaning.
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("whatsapp ma call gara"), .whatsappChat)
    }

    func testMessengerOverrideBothScripts() {
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("होइन, म्यासेन्जरमा गर"), .messengerAudio)
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("no, use messenger"), .messengerAudio)
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("मेसेन्जर नै गर"), .messengerAudio)
    }

    func testMessengerWinsOverStrayVideoAndCallTokens() {
        // "messenger video call gara" — the app mention owns its OWN
        // audio/video distinction; without this ordering the bare
        // "video"/"call" tokens would flip the override to FaceTime or
        // tel: against the user's plain meaning.
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("messenger ma call gara"), .messengerAudio)
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("messenger video"), .messengerVideo)
        XCTAssertEqual(CallOverrideParser.parseMethodOverride("म्यासेन्जरमा भिडियो गर"), .messengerVideo)
    }

    func testPlainYesNoIsNotAnOverride() {
        XCTAssertNil(CallOverrideParser.parseMethodOverride("हो"))
        XCTAssertNil(CallOverrideParser.parseMethodOverride("होइन"))
        XCTAssertNil(CallOverrideParser.parseMethodOverride("yes"))
        XCTAssertNil(CallOverrideParser.parseMethodOverride("no"))
    }

    func testEmptyAndUnrelatedAreNil() {
        XCTAssertNil(CallOverrideParser.parseMethodOverride(""))
        XCTAssertNil(CallOverrideParser.parseMethodOverride("भजन बजाउ"))
    }
}
