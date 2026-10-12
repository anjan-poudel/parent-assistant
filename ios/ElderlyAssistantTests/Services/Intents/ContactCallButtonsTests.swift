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
        // Thread form by phone (field fix 2026-09-06): the bare
        // fb-messenger:// root opened the app without the contact.
        XCTAssertEqual(opener.opened.map(\.absoluteString),
                       ["fb-messenger://user-thread/9779841234567"])
    }

    func testMessengerFallsBackToMMeWebChatWhenAbsent() {
        let opener = RecordingCallLinkOpener(canOpen: false)
        let links = CallLinks(opener: opener)
        let outcome = links.openMessengerChat(phone: "+977-9841 234567")
        XCTAssertEqual(outcome, .openedWebChat)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://m.me/9779841234567"])
        // The thread-form app scheme was checked, the dead link never opened.
        XCTAssertEqual(opener.canOpenChecks.map(\.absoluteString),
                       ["fb-messenger://user-thread/9779841234567"])
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

    // MARK: - Family tiles: chain routing and hop branches (T-152)
    //
    // Security evidence for call-dialer-primary-secondary at the family
    // VIDEO/AUDIO TILES (design-l2 §9.2; FR-CDP-003/004/010/015/016,
    // NFR-CDP-002, the SA-3 tile surface): the tile resolves through the
    // six-argument seam with ITS button's vocabulary — a video tile never
    // falls to the GSM dialer, an audio tile never to FaceTime (the seam
    // substitutes what the vocabulary forbids, the input silently like
    // the shipped guard), the routed channel is announced at resolution
    // when the chain skipped a channel and BEFORE the open (ADR-CDP-07),
    // only the two failure arms hop (FaceTime unavailable/invalidHandle,
    // Messenger invalidHandle) through the shipped helper, the `.phone`
    // floor stays terminal (RES-10), and the WhatsApp lane's every arm —
    // terminal or recovery — never hops and never even consults the
    // candidate list.
    //
    // The tile helper lives on the coordinator behind these same seams,
    // so the arms below drive the REAL `performContactCall` through an
    // in-memory coordinator (an empty phone and an empty handle fail
    // before any platform probe — nothing opens, nothing is dialed,
    // nothing is recorded), and the branch wiring is pinned at the
    // comment-stripped source. Both W6 carries are exercised here too:
    // the FaceTime arm's hop threads (N-1) and the messenger-family
    // openers' hop phone (N-4) ride the same shipped helper this suite
    // already pins.

    /// FR-CDP-004/007 + SA-3 (scenario "A video tile never falls to the
    /// dialer") — the video vocabulary excludes the phone candidate: a
    /// routed FaceTime is the surface's floor (no candidates at all), a
    /// handle-less Messenger preference gains a FaceTime candidate rather
    /// than the GSM floor, and a substituted terminal carries no
    /// candidates while keeping only the real provenance.
    func testVideoTileVocabularyExcludesThePhoneCandidateUntilTheFloor() {
        XCTAssertFalse(CallChannelVocabulary.video.permits(.phone),
                       "the GSM dialer is not a video surface")
        XCTAssertEqual(CallChannelVocabulary.video.terminal, .faceTime)

        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .faceTime,
                                                      secondary: .phone,
                                                      routed: .faceTime,
                                                      vocabulary: .video),
                       [CallApp](),
                       "FaceTime routed IS the video floor — nothing remains")

        let videoCandidates = CallChannelChain.hopCandidates(preferred: .messenger,
                                                             secondary: .phone,
                                                             routed: .messenger,
                                                             vocabulary: .video)
        XCTAssertEqual(videoCandidates, [.faceTime])
        XCTAssertFalse(videoCandidates.contains(.phone),
                       "a video tile can never fall to the GSM dialer")

        // The seam: the raw route for a handle-less Messenger preference
        // lands on GSM — refused by the video vocabulary — and the
        // substitution replaces it with the FaceTime terminal, keeping
        // the real provenance. The substituted terminal has NO
        // candidates: it is already the surface's floor.
        let substituted = AppCoordinator.resolvedCallChannel(
            explicit: .messenger, defaultApp: .phone, secondaryApp: .phone,
            messengerHandleAvailable: false, whatsAppInstalled: false,
            vocabulary: .video)
        XCTAssertEqual(substituted.channel, .faceTime)
        XCTAssertEqual(substituted.fellBackFrom, [.messenger],
                       "the substitution fabricates no provenance — only the "
                       + "feasibility-skipped channels")
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger,
                                                      secondary: .phone,
                                                      routed: substituted.channel,
                                                      vocabulary: .video),
                       [CallApp](),
                       "the substituted terminal is already open — nothing to hop to")
    }

    /// FR-CDP-004/007 + the shipped guard's silence — the audio
    /// vocabulary excludes FaceTime: a raw FaceTime audio preference is
    /// substituted SILENTLY at the seam's input (no provenance, therefore
    /// nothing to announce — the shipped `guard supportsAudio` behaviour),
    /// and the candidate list for a handle-less Messenger line carries
    /// the GSM floor, never FaceTime, even when FaceTime is the
    /// secondary.
    func testAudioTileVocabularyExcludesFaceTimeAndKeepsSilentSubstitution() {
        XCTAssertFalse(CallChannelVocabulary.audio.permits(.faceTime),
                       "FaceTime is video-only in the button vocabulary")
        XCTAssertEqual(CallChannelVocabulary.audio.terminal, .phone)

        let silent = AppCoordinator.resolvedCallChannel(
            explicit: .faceTime, defaultApp: .phone, secondaryApp: .phone,
            messengerHandleAvailable: true, whatsAppInstalled: false,
            vocabulary: .audio)
        XCTAssertEqual(silent.channel, .phone)
        XCTAssertEqual(silent.fellBackFrom, [CallApp](),
                       "the input substitution keeps the shipped silence — "
                       + "nothing to announce")

        let audioCandidates = CallChannelChain.hopCandidates(preferred: .messenger,
                                                             secondary: .faceTime,
                                                             routed: .messenger,
                                                             vocabulary: .audio)
        XCTAssertEqual(audioCandidates, [.phone])
        XCTAssertFalse(audioCandidates.contains(.faceTime),
                       "an audio tile never opens FaceTime")

        // The floor is reachable: the same preference with no handle
        // routes to `.phone` with REAL provenance, and the floor terminal
        // has nothing behind it.
        let floored = AppCoordinator.resolvedCallChannel(
            explicit: .messenger, defaultApp: .phone, secondaryApp: .phone,
            messengerHandleAvailable: false, whatsAppInstalled: true,
            vocabulary: .audio)
        XCTAssertEqual(floored.channel, .phone)
        XCTAssertEqual(floored.fellBackFrom, [.messenger])
        XCTAssertEqual(CallChannelChain.hopCandidates(preferred: .messenger,
                                                      secondary: .phone,
                                                      routed: floored.channel,
                                                      vocabulary: .audio),
                       [CallApp]())
    }

    /// FR-CDP-016 + ADR-CDP-07 (behavioural) — a direct video tile emits
    /// the shipped `video:` outcome with the chain's provenance token
    /// (`direct`), opens through the FaceTime branch (which fails on the
    /// empty test number BEFORE any platform probe), has no candidates to
    /// hop to, and records nothing from the failed open (RES-10).
    @MainActor
    func testVideoTileDirectEmitsTheShippedDirectOutcome() {
        let coordinator = makeCoordinator()
        let contact = FamilyContact(name: Self.tileContactName, phone: "",
                                    relationship: "आमा")
        let activitiesBefore = coordinator.activityLog.entries().count
        let console = captureConsole {
            coordinator.performContactCall(contact, kind: .video)
        }
        let taps = tileEventLines(in: console)
        XCTAssertEqual(taps.count, 1, "one tap, one classification event")
        XCTAssertTrue(taps.first?.contains("outcome=video:faceTime:direct metadata=[:]") ?? false,
                      "the shipped `video:<channel>` token, byte-identical, with the "
                      + "provenance token appended: " + (taps.first ?? ""))
        XCTAssertTrue(hopEventLines(in: console).isEmpty,
                      "the video floor has no candidates — the failed open hops nowhere")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.str("router.call.facetimeUnavailable",
                                locale: coordinator.activeLocale),
                       "the shipped honest FaceTime line")
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore,
                       "a failed open records nothing")
    }

    /// The audio twin (behavioural) — a direct audio tile emits the
    /// shipped `audio:phone:direct`, lands on the floor's shipped guard
    /// line for the empty number, and never hops.
    @MainActor
    func testAudioTileDirectKeepsTheShippedDirectOutcome() {
        let coordinator = makeCoordinator()
        let contact = FamilyContact(name: Self.tileContactName, phone: "",
                                    relationship: "आमा")
        let activitiesBefore = coordinator.activityLog.entries().count
        let console = captureConsole {
            coordinator.performContactCall(contact, kind: .audio)
        }
        let taps = tileEventLines(in: console)
        XCTAssertEqual(taps.count, 1)
        XCTAssertTrue(taps.first?.contains("outcome=audio:phone:direct metadata=[:]") ?? false,
                      taps.first ?? "")
        XCTAssertTrue(hopEventLines(in: console).isEmpty,
                      "the GSM floor never hops (RES-10)")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.fmt("call.announce.noPhoneNumber",
                                locale: coordinator.activeLocale, Self.tileContactName))
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore)
    }

    /// FR-CDP-016/015 (behavioural) — an audio tile whose preferred
    /// Messenger line is handle-less falls back through the chain to the
    /// floor: the emit carries `audio:phone:fellBack`, the announcement
    /// runs at resolution (source-pinned for order), and the floor's
    /// shipped guard line ends the tap with no hop — the floor is
    /// terminal.
    @MainActor
    func testAudioTileFallbackReachesTheFloorWithProvenance() {
        let coordinator = makeCoordinator()
        let contact = FamilyContact(name: Self.tileContactName, phone: "",
                                    relationship: "आमा",
                                    preferredCallApp: .messenger)
        let activitiesBefore = coordinator.activityLog.entries().count
        let console = captureConsole {
            coordinator.performContactCall(contact, kind: .audio)
        }
        let taps = tileEventLines(in: console)
        XCTAssertEqual(taps.count, 1)
        XCTAssertTrue(taps.first?.contains("outcome=audio:phone:fellBack metadata=[:]") ?? false,
                      taps.first ?? "")
        XCTAssertTrue(hopEventLines(in: console).isEmpty,
                      "routed ON the floor: nothing remains to hop to")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.fmt("call.announce.noPhoneNumber",
                                locale: coordinator.activeLocale, Self.tileContactName))
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore)
    }

    /// SA-3 (behavioural) — a video tile whose preferred Messenger line is
    /// handle-less substitutes to the FaceTime terminal with REAL
    /// provenance: the emit says `video:faceTime:fellBack`, the FaceTime
    /// branch fails on the empty number, and — being the surface's
    /// already-open floor — it hops nowhere.
    @MainActor
    func testVideoTileSubstitutionNeverHopsAndStaysOnFaceTime() {
        let coordinator = makeCoordinator()
        let contact = FamilyContact(name: Self.tileContactName, phone: "",
                                    relationship: "आमा",
                                    preferredVideoApp: .messenger)
        let activitiesBefore = coordinator.activityLog.entries().count
        let console = captureConsole {
            coordinator.performContactCall(contact, kind: .video)
        }
        let taps = tileEventLines(in: console)
        XCTAssertEqual(taps.count, 1)
        XCTAssertTrue(taps.first?.contains("outcome=video:faceTime:fellBack metadata=[:]") ?? false,
                      taps.first ?? "")
        XCTAssertTrue(hopEventLines(in: console).isEmpty,
                      "the substituted terminal is the floor — no hop")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.str("router.call.facetimeUnavailable",
                                locale: coordinator.activeLocale))
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore)
    }

    /// FR-CDP-015 (behavioural, tile arm) — the Messenger branch's
    /// `invalidHandle` is a failed open: after the shipped honest line the
    /// tap hops through the remaining candidates exactly once, landing on
    /// the GSM floor, which speaks the shipped no-number line for the
    /// empty test number.
    @MainActor
    func testMessengerTileInvalidHandleHopsThroughTheChain() {
        let coordinator = makeCoordinator()
        let contact = FamilyContact(name: Self.tileContactName, phone: "",
                                    relationship: "आमा",
                                    messengerHandle: "maya.gurung",
                                    preferredCallApp: .messenger)
        let activitiesBefore = coordinator.activityLog.entries().count
        let console = captureConsole {
            coordinator.performContactCall(contact, kind: .audio)
        }
        let taps = tileEventLines(in: console)
        XCTAssertEqual(taps.count, 1)
        XCTAssertTrue(taps.first?.contains("outcome=audio:messenger:direct metadata=[:]") ?? false,
                      "the on-file handle routes the preference directly: " + (taps.first ?? ""))
        let hops = hopEventLines(in: console)
        XCTAssertEqual(hops.count, 1, "exactly one hop — the chain is consumed, never looped")
        XCTAssertTrue(hops.first?.contains("outcome=messenger:phone metadata=[:]") ?? false,
                      hops.first ?? "")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.fmt("call.announce.noPhoneNumber",
                                locale: coordinator.activeLocale, Self.tileContactName),
                       "the hopped floor leg's shipped honest line")
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore,
                       "failed opens record nothing — the hop included")
    }

    /// RES-10 (behavioural) — the WhatsApp lane is terminal/recovery only:
    /// handed a candidate list explicitly, the shipped chat opener's
    /// `invalidPhone` arm still speaks its one honest line, emits no hop
    /// event, and records nothing. The tile's own branch is pinned
    /// structurally in the source test below.
    @MainActor
    func testWhatsAppLaneNeverHopsEvenHandedCandidates() {
        let coordinator = makeCoordinator()
        let activitiesBefore = coordinator.activityLog.entries().count
        let console = captureConsole {
            coordinator.performSystemContactWhatsApp(
                name: Self.tileContactName, phone: "",
                hop: AppCoordinator.LaunchHop(candidates: [.phone], handle: nil))
        }
        XCTAssertTrue(hopEventLines(in: console).isEmpty,
                      "the lane never hops — even handed candidates, it consults none")
        drainMainQueue()
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       L10n.fmt("call.announce.noPhoneNumber",
                                locale: coordinator.activeLocale, Self.tileContactName))
        XCTAssertEqual(coordinator.activityLog.entries().count, activitiesBefore)
    }

    /// Design-l2 §9.2 (the tile chain head, comment-stripped source) —
    /// preferred and vocabulary come from the tapped button, the
    /// six-argument seam runs with the non-nil preferred and the button's
    /// vocabulary, the emit precedes the announce which precedes the
    /// openers (ADR-CDP-07), the shipped emit expression keeps the
    /// byte-identical `video:`/`audio:` prefix, exactly the two failure
    /// arms hop through the shipped helper, the floor arm keeps the
    /// shipped guard and success statements verbatim, and the WhatsApp
    /// lane neither hops nor consults the candidates.
    func testTileChainHeadSourcePins() throws {
        let source = coordinatorSource()
        let tile = try region(
            between: "func performContactCall(_ contact: FamilyContact, kind: ContactCallKind) {",
            and: "func performSystemContactCall(", in: source)
        let flat = collapsed(tile)

        XCTAssertTrue(flat.contains(collapsed("""
            let preferred = kind == .video ? contact.resolvedVideoApp : contact.resolvedAudioApp
            """).trimmingCharacters(in: .whitespaces)),
                      "the tapped button decides the preferred app — non-nil by construction")
        XCTAssertTrue(flat.contains(collapsed("""
            let vocabulary: CallChannelVocabulary = kind == .video ? .video : .audio
            """).trimmingCharacters(in: .whitespaces)),
                      "the tapped button decides the vocabulary")
        XCTAssertTrue(flat.contains(collapsed("""
            let route = Self.resolvedCallChannel(
                explicit: preferred,
                defaultApp: defaultCallApp,
                secondaryApp: secondaryCallApp,
                messengerHandleAvailable: hasUsableMessengerHandle(contact.messengerHandle),
                whatsAppInstalled: whatsAppInstalledNow,
                vocabulary: vocabulary)
            """).trimmingCharacters(in: .whitespaces)),
                      "the six-argument seam with the button's vocabulary")
        XCTAssertFalse(flat.contains("explicit: nil"),
                       "a per-contact preferred is NEVER nil on this surface")

        // Order: emit → announce → switch (ADR-CDP-07).
        let emitRange = try XCTUnwrap(tile.range(of: "observabilityBus.emit("))
        let announceRange = try XCTUnwrap(tile.range(of: "if let skipped = route.fellBackFrom.first {"))
        let switchRange = try XCTUnwrap(tile.range(of: "switch route.channel {"))
        XCTAssertLessThan(emitRange.lowerBound, announceRange.lowerBound)
        XCTAssertLessThan(announceRange.lowerBound, switchRange.lowerBound)
        XCTAssertEqual(occurrences(of: "call.announce.fallbackRouted", in: tile), 1,
                       "one announcement site")

        XCTAssertTrue(flat.contains(collapsed("""
            outcome: "\\(kind == .video ? "video" : "audio"):\\(route.channel.rawValue):"
                + (route.fellBackFrom.isEmpty ? "direct" : "fellBack"),
            """).trimmingCharacters(in: .whitespaces)),
                      "the shipped `video:<channel>`/`audio:<channel>` token, "
                      + "byte-identical, plus the chain's provenance token")
        XCTAssertTrue(flat.contains(collapsed("""
            if let skipped = route.fellBackFrom.first {
                speak(text: L10n.fmt("call.announce.fallbackRouted", locale: locale,
                                     CallChannelChain.label(skipped, locale: locale),
                                     contact.name,
                                     CallChannelChain.label(route.channel, locale: locale)))
            }
            """).trimmingCharacters(in: .whitespaces)),
                      "the announcement names the skipped channel, the contact and "
                      + "the routed one")
        XCTAssertTrue(flat.contains(collapsed("""
            let candidates = CallChannelChain.hopCandidates(preferred: preferred,
                                                            secondary: secondaryCallApp,
                                                            routed: route.channel,
                                                            vocabulary: vocabulary)
            """).trimmingCharacters(in: .whitespaces)),
                      "the candidates come from the SAME snapshot and vocabulary")

        // Exactly two hopping arms, each through the shipped helper.
        XCTAssertEqual(occurrences(of: "performLaunchFailHop(", in: tile), 2)
        let faceTimeArm = try region(between: "case .faceTime:", and: "case .phone:", in: tile)
        XCTAssertEqual(occurrences(of: "performLaunchFailHop(", in: faceTimeArm), 1)
        XCTAssertTrue(collapsed(faceTimeArm).contains(collapsed("""
            performLaunchFailHop(after: .faceTime, candidates: candidates,
                                 name: contact.name, phone: contact.phone,
                                 handle: contact.messengerHandle,
                                 isVideo: kind == .video, locale: locale)
            """).trimmingCharacters(in: .whitespaces)),
                      "the FaceTime failure arm hops with the contact's own number "
                      + "and video-ness")

        let phoneArm = try region(between: "case .phone:", and: "case .messenger:", in: tile)
        XCTAssertEqual(occurrences(of: "performLaunchFailHop(", in: phoneArm), 0,
                       "the GSM floor never hops (RES-10)")
        XCTAssertTrue(collapsed(phoneArm).contains(collapsed("""
            guard callLinks.openPhone(contact.phone) else {
                announceNoUsableNumber(contact: contact, locale: locale)
                return
            }
            """).trimmingCharacters(in: .whitespaces)),
                      "the shipped floor guard, verbatim")
        XCTAssertTrue(collapsed(phoneArm).contains(collapsed("""
            setOutcome(icon: "phone.fill",
                       text: L10n.fmt("home.outcome.callPlaced", locale: locale, contact.name))
            speak(text: L10n.fmt("router.call.calling", locale: locale, contact.name))
            recordActivity(kind: .call, channel: .phone,
                           contactName: contact.name, phone: contact.phone)
            """).trimmingCharacters(in: .whitespaces)),
                      "the shipped success statements, verbatim")

        let messengerArm = try region(between: "case .messenger:", and: "case .whatsApp:", in: tile)
        XCTAssertEqual(occurrences(of: "performLaunchFailHop(", in: messengerArm), 1)
        XCTAssertTrue(collapsed(messengerArm).contains(collapsed("""
            performLaunchFailHop(after: .messenger, candidates: candidates,
                                 name: contact.name, phone: contact.phone,
                                 handle: contact.messengerHandle,
                                 isVideo: kind == .video, locale: locale)
            """).trimmingCharacters(in: .whitespaces)),
                      "the Messenger invalidHandle arm hops")

        let whatsAppStart = try XCTUnwrap(tile.range(of: "case .whatsApp:"))
        let whatsAppArm = String(tile[whatsAppStart.lowerBound...])
        XCTAssertEqual(occurrences(of: "performLaunchFailHop(", in: whatsAppArm), 0,
                       "the WhatsApp lane's every arm is terminal or a recovery (RES-10)")
        XCTAssertFalse(whatsAppArm.contains("candidates"),
                       "the lane does not even consult the candidate list")
        XCTAssertTrue(collapsed(whatsAppArm).contains(collapsed("""
            case .needsNativeCompose:
                presentMessageDraft(contact: contact, body: "")
                speak(text: L10n.fmt("call.announce.whatsAppSmsFallback", locale: locale, contact.name))
            case .copiedNumber:
                setOutcome(icon: "doc.on.doc.fill",
                           text: L10n.fmt("home.outcome.numberCopied", locale: locale, contact.name))
                speak(text: L10n.fmt("call.announce.whatsAppCopiedFallback", locale: locale, contact.name))
            case .invalidPhone:
                announceNoUsableNumber(contact: contact, locale: locale)
            """).trimmingCharacters(in: .whitespaces)),
                      "the shipped terminal/recovery arms, verbatim")
    }

    // MARK: - Helpers (the house patterns twin'd from the sibling suites)

    private static let languageKey = "appLanguage"
    private static let defaultCallAppKey = "defaultCallApp"
    private static let secondaryCallAppKey = "secondaryCallApp"
    private static let tileContactName = "Maya Gurung"

    private var languageBackup: Any?
    private var defaultCallAppBackup: Any?
    private var secondaryCallAppBackup: Any?

    override func setUp() {
        super.setUp()
        languageBackup = UserDefaults.standard.object(forKey: Self.languageKey)
        defaultCallAppBackup = UserDefaults.standard.object(forKey: Self.defaultCallAppKey)
        secondaryCallAppBackup = UserDefaults.standard.object(forKey: Self.secondaryCallAppKey)
    }

    override func tearDown() {
        restore(languageBackup, forKey: Self.languageKey)
        restore(defaultCallAppBackup, forKey: Self.defaultCallAppKey)
        restore(secondaryCallAppBackup, forKey: Self.secondaryCallAppKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Seeds the settings the resolution reads (language, primary and
    /// secondary dialer) BEFORE construction — the init restores through
    /// the real persisted seams — so the tile arms are deterministic
    /// regardless of test order; `tearDown` restores the prior values.
    @MainActor
    private func makeCoordinator() -> AppCoordinator {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Self.languageKey)
        UserDefaults.standard.set(CallApp.phone.rawValue, forKey: Self.defaultCallAppKey)
        UserDefaults.standard.set(CallApp.phone.rawValue, forKey: Self.secondaryCallAppKey)
        return AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())
    }

    /// Waits out the main-queue hops (`setOutcome` dispatches async — the
    /// sentinel enqueued LAST runs after everything before it).
    private func drainMainQueue() {
        let done = expectation(description: "main drain")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Runs `body` with process stdout redirected to a temp file and
    /// returns what the console bus printed (the LiveTranslate pattern,
    /// via `DialogueCoordinatorWiringTests`).
    private func captureConsole(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/contact-call-buttons-sink-\(UUID().uuidString).log"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, descriptor >= 0 else {
            if descriptor >= 0 { close(descriptor) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)

        body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }

    /// The tile's classification lines in a captured console — component
    /// `contact_call_buttons`, event type `tap`.
    private func tileEventLines(in console: String) -> [String] {
        console.components(separatedBy: .newlines)
            .filter { $0.contains("[contact_call_buttons] tap ") }
    }

    /// The hop classification lines — component `call_launch_fallback`,
    /// event type `hop`.
    private func hopEventLines(in console: String) -> [String] {
        console.components(separatedBy: .newlines)
            .filter { $0.contains("[call_launch_fallback] hop ") }
    }

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    /// The text between two code markers — comment-stripped, so the
    /// markers and the pins are code, never prose (the
    /// `CallConfirmationWordingTests.region` convention, verbatim).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "AppCoordinator.swift has no `\(start)`")
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex),
                                     "no `\(end)` after `\(start)`")
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Whitespace-collapsed form: exact token sequences and counts survive
    /// while indentation and line breaks do not (a source pin must fail
    /// on a weakened gate, not on a reformat).
    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - In-memory stand-in for the encrypted channel
    // (the house helper its sibling suites ship: the coordinator's payload
    // store only; the seams under test are the real hop machinery + the
    // real catalogue.)

    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
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
