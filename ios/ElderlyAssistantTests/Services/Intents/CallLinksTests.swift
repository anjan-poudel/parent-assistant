import XCTest
@testable import ElderlyAssistant

/// `CallLinks` — the one home for every outbound calling/messaging URL
/// (v2 pivot Phase 2, §4.3). Pins URL construction (encoding, e164
/// normalization), handle selection from the contact's phone field, and
/// the app-absent fallback decisions, with the opener faked so the exact
/// URLs and decision paths are asserted.
final class CallLinksTests: XCTestCase {

    // MARK: - Handle normalization

    func testPhoneHandleKeepsLeadingPlusAndStripsSeparators() {
        XCTAssertEqual(CallLinks.phoneHandle("+977-9841 234 567"), "+9779841234567")
    }

    func testPhoneHandleWithoutCountryCodeStaysDigits() {
        XCTAssertEqual(CallLinks.phoneHandle("9841-234567"), "9841234567")
    }

    func testPhoneHandleDropsMisplacedPlus() {
        // A '+' anywhere but the front is a typo, not a country code.
        XCTAssertEqual(CallLinks.phoneHandle("9841+234567"), "9841234567")
    }

    func testPhoneHandleEmptyWhenNoDigits() {
        XCTAssertEqual(CallLinks.phoneHandle("  -  "), "")
    }

    func testWhatsAppDigitsStripEverythingNonNumeric() {
        XCTAssertEqual(CallLinks.whatsAppDigits("+977-9841 234 567"), "9779841234567")
    }

    // MARK: - URL construction

    func testPhoneURLBuildsTelLink() {
        XCTAssertEqual(CallLinks.phoneURL("+977-9841 234567")?.absoluteString,
                       "tel:+9779841234567")
    }

    func testPhoneURLNilForEmptyHandle() {
        XCTAssertNil(CallLinks.phoneURL(" — "))
    }

    func testFaceTimeVideoURL() {
        XCTAssertEqual(CallLinks.faceTimeURL(handle: "+977 9841-234567", video: true)?.absoluteString,
                       "facetime://+9779841234567")
    }

    func testFaceTimeAudioURL() {
        XCTAssertEqual(CallLinks.faceTimeURL(handle: "9841234567", video: false)?.absoluteString,
                       "facetime-audio://9841234567")
    }

    func testFaceTimeURLNilForEmptyHandle() {
        XCTAssertNil(CallLinks.faceTimeURL(handle: "", video: true))
    }

    func testWhatsAppChatURLIsShippedWaMeForm() {
        XCTAssertEqual(CallLinks.whatsAppChatURL(phone: "+977-9841 234567")?.absoluteString,
                       "https://wa.me/9779841234567")
    }

    func testWhatsAppTextURLDigitsOnlyPhoneAndEncodedText() {
        let url = CallLinks.whatsAppTextURL(phone: "+977 9841-234567", text: "Hello baba")
        XCTAssertEqual(url?.absoluteString,
                       "whatsapp://send?phone=9779841234567&text=Hello%20baba")
    }

    func testWhatsAppTextURLEncodesNepaliText() {
        let url = CallLinks.whatsAppTextURL(phone: "9841234567", text: "म राम्रो छु")
        XCTAssertNotNil(url)
        // Nothing raw-Devanagari may leak into the URL string…
        XCTAssertFalse(url!.absoluteString.contains("म"))
        // …and the query items must round-trip exactly.
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "whatsapp")
        XCTAssertEqual(components?.host, "send")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "phone" })?.value,
                       "9841234567")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "text" })?.value,
                       "म राम्रो छु")
    }

    func testWhatsAppTextURLEncodesQueryMetacharactersInText() {
        // '&' and '=' inside the message must not corrupt the query.
        let url = CallLinks.whatsAppTextURL(phone: "9841234567", text: "a&b=c?")
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.count, 2)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "text" })?.value, "a&b=c?")
    }

    func testWhatsAppTextURLOmitsTextParameterWhenEmpty() {
        let url = CallLinks.whatsAppTextURL(phone: "9841234567", text: "")
        XCTAssertEqual(url?.absoluteString, "whatsapp://send?phone=9841234567")
    }

    func testWhatsAppTextURLNilWhenPhoneHasNoDigits() {
        XCTAssertNil(CallLinks.whatsAppTextURL(phone: "मा", text: "hello"))
    }

    // MARK: - App-name vocabulary

    func testIsWhatsAppNameMatchesBothScripts() {
        XCTAssertTrue(CallLinks.isWhatsAppName("whatsapp"))
        XCTAssertTrue(CallLinks.isWhatsAppName("WhatsApp"))
        XCTAssertTrue(CallLinks.isWhatsAppName("वाट्सएप"))
        XCTAssertTrue(CallLinks.isWhatsAppName("ह्वाट्सएप"))
        XCTAssertTrue(CallLinks.isWhatsAppName("वाट्सएपमा"))
    }

    func testIsWhatsAppNameRejectsOtherAppsAndEmpty() {
        XCTAssertFalse(CallLinks.isWhatsAppName("messenger"))
        XCTAssertFalse(CallLinks.isWhatsAppName("facetime"))
        XCTAssertFalse(CallLinks.isWhatsAppName(""))
    }

    // MARK: - FaceTime open decisions

    func testOpenFaceTimeOpensExactVideoURLWhenAvailable() {
        let opener = FakeCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        let outcome = links.openFaceTime(handle: "+977-9841 234567", video: true)
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["facetime://+9779841234567"])
    }

    func testOpenFaceTimeOpensExactAudioURLWhenAvailable() {
        let opener = FakeCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        let outcome = links.openFaceTime(handle: "9841234567", video: false)
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["facetime-audio://9841234567"])
    }

    func testOpenFaceTimeReportsUnavailableAndOpensNothing() {
        let opener = FakeCallLinkOpener(canOpen: false)
        let links = CallLinks(opener: opener)
        let outcome = links.openFaceTime(handle: "9841234567", video: true)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testOpenFaceTimeReportsInvalidHandleForEmptyPhone() {
        let opener = FakeCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        XCTAssertEqual(links.openFaceTime(handle: "", video: true), .invalidHandle)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(opener.canOpenChecks.isEmpty)
    }

    // MARK: - tel: / wa.me passthroughs

    func testOpenPhoneOpensTelLink() {
        let opener = FakeCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        XCTAssertTrue(links.openPhone("+977 9841-234567"))
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["tel:+9779841234567"])
    }

    func testOpenPhoneFalseForEmptyHandle() {
        let opener = FakeCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        XCTAssertFalse(links.openPhone(""))
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testOpenWhatsAppChatOpensWaMeLink() {
        let opener = FakeCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        XCTAssertTrue(links.openWhatsAppChat("+977-9841 234567"))
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://wa.me/9779841234567"])
    }

    // MARK: - WhatsApp text: app-present and app-absent decisions

    func testOpenWhatsAppTextOpensExactURLWhenInstalled() {
        let opener = FakeCallLinkOpener(canOpen: true)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { true },
                              copyText: { copied.append($0) })
        let outcome = links.openWhatsAppText("+977-9841 234567", text: "Hi")
        XCTAssertEqual(outcome, .openedWhatsApp)
        XCTAssertEqual(opener.opened.map(\.absoluteString),
                       ["whatsapp://send?phone=9779841234567&text=Hi"])
        XCTAssertTrue(copied.isEmpty)
    }

    func testOpenWhatsAppTextFallsBackToNativeComposeWhenAbsent() {
        let opener = FakeCallLinkOpener(canOpen: false)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { true },
                              copyText: { copied.append($0) })
        let outcome = links.openWhatsAppText("9841234567", text: "Hi")
        XCTAssertEqual(outcome, .needsNativeCompose)
        XCTAssertTrue(opener.opened.isEmpty, "the fallback must not open a dead link")
        XCTAssertTrue(copied.isEmpty, "Messages can take the text — nothing to copy")
    }

    func testOpenWhatsAppTextCopiesWhenNoMessagingSurfaceAtAll() {
        let opener = FakeCallLinkOpener(canOpen: false)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { false },
                              copyText: { copied.append($0) })
        let outcome = links.openWhatsAppText("9841234567", text: "म राम्रो छु")
        XCTAssertEqual(outcome, .copiedText)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(copied, ["म राम्रो छु"], "the dictated body is what lands on the pasteboard")
    }

    func testOpenWhatsAppTextInvalidPhoneOpensAndCopiesNothing() {
        let opener = FakeCallLinkOpener(canOpen: true)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { true },
                              copyText: { copied.append($0) })
        XCTAssertEqual(links.openWhatsAppText("", text: "Hi"), .invalidPhone)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(opener.canOpenChecks.isEmpty)
        XCTAssertTrue(copied.isEmpty)
    }
}

/// Scripted `CallLinkOpening` — records every check and open so tests
/// assert the exact URLs and that fallbacks open nothing.
private final class FakeCallLinkOpener: CallLinkOpening {
    let canOpen: Bool
    private(set) var canOpenChecks: [URL] = []
    private(set) var opened: [URL] = []

    init(canOpen: Bool) {
        self.canOpen = canOpen
    }

    func canOpenURL(_ url: URL) -> Bool {
        canOpenChecks.append(url)
        return canOpen
    }

    func open(_ url: URL) {
        opened.append(url)
    }
}
