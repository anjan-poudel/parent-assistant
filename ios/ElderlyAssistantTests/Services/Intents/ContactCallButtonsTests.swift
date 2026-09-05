import XCTest
@testable import ElderlyAssistant

/// Per-contact call buttons (contact-call-buttons task, 2026-09-06):
/// the `CallApp` vocabulary, `FamilyContact`'s per-contact preferences
/// (resolution + Codable defaults for contacts stored before the fields
/// existed), and the Messenger/WhatsApp-call open decisions with the
/// opener faked so the exact URLs and fallback paths are asserted.
final class ContactCallButtonsTests: XCTestCase {

    // MARK: - CallApp vocabulary

    func testCallAppVideoAudioSupportMatrix() {
        XCTAssertTrue(CallApp.faceTime.supportsVideo)
        XCTAssertFalse(CallApp.faceTime.supportsAudio, "FaceTime is video-only in the button vocabulary")
        XCTAssertFalse(CallApp.phone.supportsVideo, "GSM dialer can't do video")
        XCTAssertTrue(CallApp.phone.supportsAudio)
        XCTAssertTrue(CallApp.messenger.supportsVideo)
        XCTAssertTrue(CallApp.messenger.supportsAudio)
        XCTAssertTrue(CallApp.whatsApp.supportsVideo)
        XCTAssertTrue(CallApp.whatsApp.supportsAudio)
    }

    func testCallAppRawValuesAreStableForStorage() {
        // Persisted on FamilyContact — renaming a raw value would silently
        // reset stored preferences to defaults, so pin them.
        XCTAssertEqual(CallApp.faceTime.rawValue, "faceTime")
        XCTAssertEqual(CallApp.phone.rawValue, "phone")
        XCTAssertEqual(CallApp.messenger.rawValue, "messenger")
        XCTAssertEqual(CallApp.whatsApp.rawValue, "whatsApp")
    }

    // MARK: - FamilyContact Codable defaults (legacy stored contacts)

    /// Contacts persisted BEFORE the preference fields existed carry no
    /// `preferredVideoApp`/`preferredCallApp` keys — they must decode
    /// with the global defaults, not fail the whole store read.
    func testLegacyContactWithoutPreferencesDecodesWithDefaults() throws {
        let id = UUID()
        let legacyJSON = """
        [{"id":"\(id.uuidString)","name":"माइया","phone":"9841234567","relationship":"आमा"}]
        """.data(using: .utf8)!
        let contacts = try JSONDecoder().decode([FamilyContact].self, from: legacyJSON)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, id)
        XCTAssertEqual(contacts[0].name, "माइया")
        XCTAssertEqual(contacts[0].preferredVideoApp, .faceTime)
        XCTAssertEqual(contacts[0].preferredCallApp, .phone)
    }

    func testExplicitPreferencesRoundTrip() throws {
        let contact = FamilyContact(name: "Hari", phone: "9812345678", relationship: "छोरा",
                                    preferredVideoApp: .whatsApp, preferredCallApp: .messenger)
        let data = try JSONEncoder().encode([contact])
        let decoded = try JSONDecoder().decode([FamilyContact].self, from: data)
        XCTAssertEqual(decoded, [contact])
        XCTAssertEqual(decoded[0].preferredVideoApp, .whatsApp)
        XCTAssertEqual(decoded[0].preferredCallApp, .messenger)
    }

    func testUnknownStoredAppValueFallsBackToDefaults() throws {
        // A future/removed app name (or hand-edited data) must not kill
        // the decode — default, don't crash the store read.
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","name":"A","phone":"1","relationship":"R",\
        "preferredVideoApp":"skype","preferredCallApp":"viber"}]
        """.data(using: .utf8)!
        let contacts = try JSONDecoder().decode([FamilyContact].self, from: legacyJSON)
        XCTAssertEqual(contacts[0].preferredVideoApp, .faceTime)
        XCTAssertEqual(contacts[0].preferredCallApp, .phone)
    }

    // MARK: - Preference resolution (contact pref vs global default)

    func testDefaultContactResolvesToGlobalDefaults() {
        let contact = FamilyContact(name: "माइया", phone: "9841234567", relationship: "आमा")
        XCTAssertEqual(contact.resolvedVideoApp, .faceTime)
        XCTAssertEqual(contact.resolvedAudioApp, .phone)
    }

    func testContactPreferenceWinsOverGlobalDefault() {
        let contact = FamilyContact(name: "Hari", phone: "1", relationship: "son",
                                    preferredVideoApp: .messenger, preferredCallApp: .whatsApp)
        XCTAssertEqual(contact.resolvedVideoApp, .messenger)
        XCTAssertEqual(contact.resolvedAudioApp, .whatsApp)
    }

    func testVideoPreferenceOfAudioOnlyAppFallsBackToDefault() {
        // `.phone` can't do video — treat a stored value like that as
        // unset rather than open the wrong surface.
        let contact = FamilyContact(name: "A", phone: "1", relationship: "R",
                                    preferredVideoApp: .phone)
        XCTAssertEqual(contact.resolvedVideoApp, .faceTime)
    }

    func testAudioPreferenceOfVideoOnlyAppFallsBackToDefault() {
        // `.faceTime` is video-only in the button vocabulary.
        let contact = FamilyContact(name: "A", phone: "1", relationship: "R",
                                    preferredCallApp: .faceTime)
        XCTAssertEqual(contact.resolvedAudioApp, .phone)
    }

    // MARK: - Messenger open decisions (app → https m.me fallback)

    func testMessengerOpensAppSchemeWhenInstalled() {
        let opener = RecordingCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        let outcome = links.openMessengerChat(phone: "+977-9841 234567")
        XCTAssertEqual(outcome, .openedApp)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["fb-messenger://"])
    }

    func testMessengerFallsBackToMMeWebChatWhenAbsent() {
        let opener = RecordingCallLinkOpener(canOpen: false)
        let links = CallLinks(opener: opener)
        let outcome = links.openMessengerChat(phone: "+977-9841 234567")
        XCTAssertEqual(outcome, .openedWebChat)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://m.me/9779841234567"])
        // The app scheme was checked, the dead link never opened.
        XCTAssertEqual(opener.canOpenChecks.map(\.absoluteString), ["fb-messenger://"])
    }

    func testMessengerInvalidPhoneOpensAndChecksNothing() {
        let opener = RecordingCallLinkOpener(canOpen: true)
        let links = CallLinks(opener: opener)
        XCTAssertEqual(links.openMessengerChat(phone: "मा"), .invalidHandle)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(opener.canOpenChecks.isEmpty)
    }

    // MARK: - WhatsApp call open decisions (installed → sms → copy)

    func testWhatsAppCallOpensInAppChatWhenInstalled() {
        let opener = RecordingCallLinkOpener(canOpen: true)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { true },
                              copyText: { copied.append($0) })
        let outcome = links.openWhatsAppCallChat("+977-9841 234567")
        XCTAssertEqual(outcome, .openedChat)
        // A CALL request carries no text — the chat link must have no
        // text parameter (same shape as the shipped empty-text form).
        XCTAssertEqual(opener.opened.map(\.absoluteString),
                       ["whatsapp://send?phone=9779841234567"])
        XCTAssertTrue(copied.isEmpty)
    }

    func testWhatsAppCallFallsBackToNativeComposeWhenAbsent() {
        let opener = RecordingCallLinkOpener(canOpen: false)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { true },
                              copyText: { copied.append($0) })
        let outcome = links.openWhatsAppCallChat("9841234567")
        XCTAssertEqual(outcome, .needsNativeCompose)
        XCTAssertTrue(opener.opened.isEmpty, "the fallback must not open a dead link")
        XCTAssertTrue(copied.isEmpty, "Messages can take the number — nothing to copy")
    }

    func testWhatsAppCallCopiesNumberWhenNoMessagingSurfaceAtAll() {
        let opener = RecordingCallLinkOpener(canOpen: false)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { false },
                              copyText: { copied.append($0) })
        let outcome = links.openWhatsAppCallChat("+977 9841-234567")
        XCTAssertEqual(outcome, .copiedNumber)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(copied, ["+9779841234567"],
                       "a call request has no text — the contact's number is the copied payload")
    }

    func testWhatsAppCallInvalidPhoneOpensAndCopiesNothing() {
        let opener = RecordingCallLinkOpener(canOpen: true)
        var copied: [String] = []
        let links = CallLinks(opener: opener,
                              canSendText: { true },
                              copyText: { copied.append($0) })
        XCTAssertEqual(links.openWhatsAppCallChat(""), .invalidPhone)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(opener.canOpenChecks.isEmpty)
        XCTAssertTrue(copied.isEmpty)
    }
}

/// Scripted `CallLinkOpening` — records every check and open so tests
/// assert the exact URLs and that fallbacks open nothing. (Local twin of
/// the fake in CallLinksTests, which is file-private.)
private final class RecordingCallLinkOpener: CallLinkOpening {
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
