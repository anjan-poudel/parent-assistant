import XCTest
@testable import ElderlyAssistant

final class MethodResolverTests: XCTestCase {

    private let contactId = UUID()

    private func makeResolver(preferences: CallMethodPreferenceStore? = nil,
                              history: ConfirmedMethodHistoryStore? = nil)
    -> (MethodResolver, CallMethodPreferenceStore, ConfirmedMethodHistoryStore) {
        let prefs = preferences ?? CallMethodPreferenceStore(storage: StubEncryptedStorage())
        let hist = history ?? ConfirmedMethodHistoryStore(storage: StubEncryptedStorage())
        return (MethodResolver(preferenceStore: prefs, historyStore: hist), prefs, hist)
    }

    // MARK: Chain order (spec §6.2: explicit > family pref > history > tel:)

    func testBareCallDefaultsToPhone() {
        let (resolver, _, _) = makeResolver()
        let r = resolver.resolve(contactId: contactId, requestedApp: nil, callType: nil)
        XCTAssertEqual(r.method, .phone)
        XCTAssertEqual(r.source, .globalDefault)
    }

    func testExplicitAppWinsOverEverything() {
        let (resolver, prefs, hist) = makeResolver()
        prefs.setPreference(.facetimeAudio, for: contactId)
        hist.record(.facetimeVideo, for: contactId)
        let r = resolver.resolve(contactId: contactId, requestedApp: "whatsapp", callType: nil)
        XCTAssertEqual(r.method, .whatsappChat)
        XCTAssertEqual(r.source, .explicit)
    }

    func testExplicitVideoWinsOverPreference() {
        let (resolver, prefs, _) = makeResolver()
        prefs.setPreference(.phone, for: contactId)
        let r = resolver.resolve(contactId: contactId, requestedApp: nil, callType: "video")
        XCTAssertEqual(r.method, .facetimeVideo)
        XCTAssertEqual(r.source, .explicit)
    }

    func testNepaliAppNamesAreExplicit() {
        let (resolver, _, _) = makeResolver()
        XCTAssertEqual(resolver.resolve(contactId: contactId, requestedApp: "वाट्सएप", callType: nil).method,
                       .whatsappChat)
        XCTAssertEqual(resolver.resolve(contactId: contactId, requestedApp: "फेसटाइम", callType: nil).method,
                       .facetimeAudio)
    }

    func testPlainPhoneRequestIsExplicit() {
        // "फोन नै गर" — said so in as many words.
        let (resolver, _, _) = makeResolver()
        XCTAssertEqual(resolver.resolve(contactId: contactId, requestedApp: "फोन", callType: nil).method,
                       .phone)
    }

    func testFamilyPreferenceBeatsHistory() {
        let (resolver, prefs, hist) = makeResolver()
        prefs.setPreference(.facetimeAudio, for: contactId)
        hist.record(.phone, for: contactId)
        let r = resolver.resolve(contactId: contactId, requestedApp: nil, callType: nil)
        XCTAssertEqual(r.method, .facetimeAudio)
        XCTAssertEqual(r.source, .familyPreference)
    }

    func testHistoryUsedWhenNoPreference() {
        let (resolver, _, hist) = makeResolver()
        hist.record(.whatsappChat, for: contactId)
        let r = resolver.resolve(contactId: contactId, requestedApp: nil, callType: nil)
        XCTAssertEqual(r.method, .whatsappChat)
        XCTAssertEqual(r.source, .confirmedHistory)
    }

    func testUnsupportedAppFallsBackToFaceTimeDisclosed() {
        let (resolver, _, _) = makeResolver()
        let r = resolver.resolve(contactId: contactId, requestedApp: "messenger", callType: nil)
        XCTAssertEqual(r.method, .facetimeAudio)
        XCTAssertEqual(r.unsupportedRequestedApp, "messenger")
        XCTAssertEqual(r.source, .explicit)
    }

    // MARK: Stores round-trip + learning

    func testHistoryCountsConfirmations() {
        let hist = ConfirmedMethodHistoryStore(storage: StubEncryptedStorage())
        hist.record(.phone, for: contactId)
        hist.record(.phone, for: contactId)
        hist.record(.facetimeAudio, for: contactId)
        let record = hist.lastConfirmed(for: contactId)
        XCTAssertEqual(record?.method, .facetimeAudio)
        XCTAssertEqual(record?.count, 3)
    }

    func testPreferenceRemoval() {
        let prefs = CallMethodPreferenceStore(storage: StubEncryptedStorage())
        prefs.setPreference(.facetimeVideo, for: contactId)
        XCTAssertEqual(prefs.preference(for: contactId), .facetimeVideo)
        prefs.removeAll(for: contactId)
        XCTAssertNil(prefs.preference(for: contactId))
    }
}
