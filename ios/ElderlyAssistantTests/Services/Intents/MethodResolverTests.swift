import XCTest
@testable import ElderlyAssistant

final class MethodResolverTests: XCTestCase {

    private let contactId = UUID()

    private func makeResolver(preferences: CallMethodPreferenceStore? = nil,
                              history: ConfirmedMethodHistoryStore? = nil,
                              globalDefault: ((Bool) -> CallMethod)? = nil)
    -> (MethodResolver, CallMethodPreferenceStore, ConfirmedMethodHistoryStore) {
        let prefs = preferences ?? CallMethodPreferenceStore(storage: StubEncryptedStorage())
        let hist = history ?? ConfirmedMethodHistoryStore(storage: StubEncryptedStorage())
        // No closure → the shipped two-argument construction, so every
        // pre-existing test exercises the unchanged call shape.
        let resolver: MethodResolver
        if let globalDefault = globalDefault {
            resolver = MethodResolver(preferenceStore: prefs,
                                      historyStore: hist,
                                      globalDefault: globalDefault)
        } else {
            resolver = MethodResolver(preferenceStore: prefs, historyStore: hist)
        }
        return (resolver, prefs, hist)
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
        let r = resolver.resolve(contactId: contactId, requestedApp: "viber", callType: nil)
        XCTAssertEqual(r.method, .facetimeAudio)
        XCTAssertEqual(r.unsupportedRequestedApp, "viber")
        XCTAssertEqual(r.source, .explicit)
    }

    // MARK: Messenger (2026-09-06: explicit user request — thread deep link)

    func testMessengerAudioIsExplicit() {
        let (resolver, _, _) = makeResolver()
        let r = resolver.resolve(contactId: contactId, requestedApp: "messenger", callType: nil)
        XCTAssertEqual(r.method, .messengerAudio)
        XCTAssertNil(r.unsupportedRequestedApp)
        XCTAssertEqual(r.source, .explicit)
    }

    func testMessengerVideoIsExplicit() {
        let (resolver, _, _) = makeResolver()
        let r = resolver.resolve(contactId: contactId, requestedApp: "messenger", callType: "video")
        XCTAssertEqual(r.method, .messengerVideo)
        XCTAssertNil(r.unsupportedRequestedApp)
        XCTAssertEqual(r.source, .explicit)
    }

    func testMessengerNepaliNameIsExplicit() {
        let (resolver, _, _) = makeResolver()
        XCTAssertEqual(resolver.resolve(contactId: contactId, requestedApp: "म्यासेन्जर", callType: nil).method,
                       .messengerAudio)
        XCTAssertEqual(resolver.resolve(contactId: contactId, requestedApp: "म्यासेन्जरमा", callType: "भिडियो").method,
                       .messengerVideo)
    }

    func testMessengerHistoryRoundTrips() {
        // The new methods are Codable store payloads too (preference +
        // history) — a messenger-confirmed contact defaults to messenger
        // next time the user names nothing.
        let (resolver, _, hist) = makeResolver()
        hist.record(.messengerAudio, for: contactId)
        let r = resolver.resolve(contactId: contactId, requestedApp: nil, callType: nil)
        XCTAssertEqual(r.method, .messengerAudio)
        XCTAssertEqual(r.source, .confirmedHistory)
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

    // MARK: Global-default closure (FR-CDP-012, design-l2 §8; T-147)

    func testGlobalDefaultClosureMapsCallType() {
        // The closure shape the coordinator installs: the settings
        // primary mapped by call type. Here the primary is FaceTime, so
        // the closure returns faceTime for a video call and the
        // unchanged voice (audio) method for a plain call.
        let settingsPrimary: CallApp = .faceTime
        let globalDefault: (Bool) -> CallMethod = { isVideo in
            CallChannelChain.method(for: settingsPrimary, isVideo: isVideo)
        }
        XCTAssertEqual(globalDefault(true), .facetimeVideo)

        let (resolver, _, _) = makeResolver(globalDefault: globalDefault)
        let r = resolver.resolve(contactId: contactId, requestedApp: nil, callType: nil)
        XCTAssertEqual(r.method, .facetimeAudio)
        XCTAssertEqual(r.source, .globalDefault)
        XCTAssertEqual(CallChannelChain.channel(for: r.method), .faceTime)
    }

    func testDefaultConstructionStillPhone() {
        // Every existing construction — the shipped two-argument
        // initialiser — keeps the phone floor and knows no settings:
        // absent stores, plain call, `.phone` channel, unchanged source.
        let resolver = MethodResolver(
            preferenceStore: CallMethodPreferenceStore(storage: StubEncryptedStorage()),
            historyStore: ConfirmedMethodHistoryStore(storage: StubEncryptedStorage()))
        let r = resolver.resolve(contactId: contactId, requestedApp: nil, callType: nil)
        XCTAssertEqual(r.method, .phone)
        XCTAssertEqual(CallChannelChain.channel(for: r.method), .phone)
        XCTAssertEqual(r.source, .globalDefault)
        XCTAssertNil(r.unsupportedRequestedApp)
    }

    func testGlobalDefaultClosureReceivesCallTypeFlag() {
        // Closed map: the closure records the flag `resolve` passes and
        // returns per it, so the call-type sense is observable.
        var seenFlags: [Bool] = []
        let (resolver, _, _) = makeResolver(globalDefault: { isVideo in
            seenFlags.append(isVideo)
            return isVideo ? .facetimeVideo : .phone
        })

        let plain = resolver.resolve(contactId: contactId, requestedApp: nil, callType: nil)
        XCTAssertEqual(seenFlags, [false])
        XCTAssertEqual(plain.method, .phone)
        XCTAssertEqual(plain.source, .globalDefault)

        // A bare video word is already an explicit method choice at
        // step 1 (FaceTime is the only video-capable integration), so it
        // never reaches — or consults — the closure: steps 1–3 intact.
        let video = resolver.resolve(contactId: contactId, requestedApp: nil, callType: "video")
        XCTAssertEqual(video.method, .facetimeVideo)
        XCTAssertEqual(video.source, .explicit)
        XCTAssertEqual(seenFlags, [false])
    }
}
