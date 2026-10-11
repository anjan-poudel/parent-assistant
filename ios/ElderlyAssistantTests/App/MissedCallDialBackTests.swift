import XCTest
@testable import ElderlyAssistant

/// The missed-call row's tap (missed-calls fix, 2026-09-18; route value
/// + announcement: call-dialer-primary-secondary, 2026-10-12): the pure
/// dial-back seams — `resolvedMissedCallChannel` (the SAME resolution a
/// family contact's audio call button uses) and `missedCallDialAction`
/// (the decision `AppCoordinator.dialBackMissedCall` dispatches, now the
/// `MissedCallDialRoute` with channel, provenance and hop candidates,
/// design-l2.md:393-438) — plus the presentation seam the list rows
/// render through (`ActivityRowText.unansweredIdentity`). The route
/// cases are pure statics (the house seam pattern: no coordinator, no
/// CallKit, no UI); the dispatch wiring (announce-before-dispatch, the
/// hop threading, speech only) is pinned by comment-stripped source
/// scans over the delivered region (the `FeatureSourceScan` house
/// convention).
final class MissedCallDialBackTests: XCTestCase {

    private func familyContact(name: String,
                               phone: String,
                               preferredCallApp: CallApp = .phone,
                               messengerHandle: String? = nil) -> FamilyContact {
        FamilyContact(name: name, phone: phone, relationship: "daughter",
                      messengerHandle: messengerHandle,
                      preferredCallApp: preferredCallApp)
    }

    // MARK: - Channel resolution (the house call-resolution reuse)
    //
    // T-146 signature note (call-dialer-primary-secondary): the seam
    // takes the secondary + probe inputs and returns the chain `Result`;
    // these cases read `.channel` with the phone secondary and the
    // shipped ungated probe so their original semantics are preserved
    // exactly. T-153 delivered the route value:
    // `missedCallDialAction` now returns `MissedCallDialRoute` (action +
    // routed channel + provenance + hop candidates) and
    // `dialBackMissedCall` announces at resolution and dispatches with
    // the route's hop — those assertions live in the "Dial action" and
    // "Source pins" sections below; this section keeps driving the
    // shared seam directly (the seam itself is unchanged).

    /// A matched family contact's OWN audio preference wins — the tap
    /// resolves EXACTLY like that contact's audio call button.
    func testFamilyContactPreferenceWins() {
        let whatsApp = familyContact(name: "सीता", phone: "9800000000",
                                     preferredCallApp: .whatsApp)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: whatsApp,
                                                     defaultApp: .phone,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: false,
                                                     whatsAppInstalled: true).channel,
            .whatsApp)
    }

    /// Family contact prefers Messenger AND has a handle → the thread
    /// opens (the same surface the contact's call button opens).
    func testFamilyMessengerWithHandleResolvesToMessenger() {
        let messenger = familyContact(name: "राम", phone: "9811111111",
                                      preferredCallApp: .messenger,
                                      messengerHandle: "ram.sharma")
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: messenger,
                                                     defaultApp: .phone,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: true,
                                                     whatsAppInstalled: true).channel,
            .messenger)
    }

    /// Messenger WITHOUT a handle drops to `.phone` (tel:) — never a
    /// dead tap (the house `resolvedCallChannel` hard rule).
    func testMessengerWithoutHandleDropsToPhone() {
        let messenger = familyContact(name: "राम", phone: "9811111111",
                                      preferredCallApp: .messenger)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: messenger,
                                                     defaultApp: .phone,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: false,
                                                     whatsAppInstalled: true).channel,
            .phone)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: messenger,
                                                     defaultApp: .messenger,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: false,
                                                     whatsAppInstalled: true).channel,
            .phone)
    }

    /// A dial-back is an AUDIO call: FaceTime (video-only in the button
    /// vocabulary) never resolves — a family preference AND a global
    /// default of FaceTime both fall to the GSM dialer.
    func testFaceTimeNeverResolvesForAudioDialBack() {
        let faceTimeFan = familyContact(name: "बुबा", phone: "9841234567",
                                        preferredCallApp: .faceTime)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: faceTimeFan,
                                                     defaultApp: .phone,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: false,
                                                     whatsAppInstalled: true).channel,
            .phone)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .faceTime,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: false,
                                                     whatsAppInstalled: true).channel,
            .phone)
    }

    /// No family match → the global default decides, with the same hard
    /// rules on top.
    func testGlobalDefaultAppliesWithoutFamilyMatch() {
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .whatsApp,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: false,
                                                     whatsAppInstalled: true).channel,
            .whatsApp)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .phone,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: false,
                                                     whatsAppInstalled: true).channel,
            .phone)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .messenger,
                                                     secondaryApp: .phone,
                                                     messengerHandleAvailable: true,
                                                     whatsAppInstalled: true).channel,
            .messenger)
    }

    // MARK: - Dial action (the tap's decision — now the route value)

    /// A numberless row (an anonymous entry from before the fix, or a
    /// caller iOS masked) keeps the honest Phone-app open — there is no
    /// number to dial and the app never fakes one.
    func testNumberlessRowOpensPhoneApp() {
        let route = AppCoordinator.missedCallDialAction(
            phone: "", familyContact: nil, defaultApp: .phone,
            secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "")
        XCTAssertEqual(route.action, .openPhoneApp)
        XCTAssertNil(route.channel, "nothing to route — the guard returns before the chain")
        XCTAssertEqual(route.fellBackFrom, [])
        XCTAssertEqual(route.hopCandidates, [])
    }

    /// A number that normalizes to nothing dialable speaks the honest
    /// dead-row line instead of a silent dead tap (defensive — records
    /// never store one, but a corrupt payload must not dead-end).
    func testUndialableNumberIsHonestDeadRow() {
        let route = AppCoordinator.missedCallDialAction(
            phone: "not-a-number", familyContact: nil, defaultApp: .phone,
            secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "not-a-number")
        XCTAssertEqual(route.action, .unusableNumber(name: "not-a-number"))
        XCTAssertNil(route.channel)
        XCTAssertEqual(route.fellBackFrom, [])
        XCTAssertEqual(route.hopCandidates, [])
    }

    /// Pin (a): both shipped numberless guards return before the chain —
    /// their WHOLE route is the action, with nothing to route, announce
    /// or hop (full-value equality via `MissedCallDialRoute: Equatable`,
    /// not field sampling).
    func testBothNumberlessGuardsCarryAnEmptyRoute() {
        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "", familyContact: nil, defaultApp: .phone,
                secondaryApp: .phone, messengerHandle: nil,
                whatsAppInstalled: true, name: ""),
            AppCoordinator.MissedCallDialRoute(action: .openPhoneApp, channel: nil,
                                               fellBackFrom: [], hopCandidates: []))
        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "not-a-number", familyContact: nil, defaultApp: .phone,
                secondaryApp: .phone, messengerHandle: nil,
                whatsAppInstalled: true, name: "not-a-number"),
            AppCoordinator.MissedCallDialRoute(action: .unusableNumber(name: "not-a-number"),
                                               channel: nil,
                                               fellBackFrom: [], hopCandidates: []))
    }

    /// The tel: fallback is always in the chain: an unmatched number
    /// under any default still dials GSM.
    func testUnmatchedNumberAlwaysDialsTel() {
        let route = AppCoordinator.missedCallDialAction(
            phone: "9841234567", familyContact: nil, defaultApp: .faceTime,
            secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "9841234567")
        XCTAssertEqual(route.action, .call(name: "9841234567", phone: "9841234567"))
        // The FaceTime default is substituted at the seam's INPUT (the
        // audio vocabulary, silently — the shipped `guard supportsAudio`
        // silence), so the routed channel is the floor with NO
        // provenance: nothing was skipped, nothing will be announced.
        XCTAssertEqual(route.channel, .phone)
        XCTAssertEqual(route.fellBackFrom, [])
        XCTAssertEqual(route.hopCandidates, [])
    }

    /// Pin (b): the GSM floor routed DIRECTLY (no fallback) carries an
    /// empty provenance and no candidates — the no-announce condition of
    /// the delivered `dialBackMissedCall` (full route equality).
    func testDirectTelFloorCarriesEmptyProvenance() {
        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "9841234567", familyContact: nil, defaultApp: .phone,
                secondaryApp: .phone, messengerHandle: nil,
                whatsAppInstalled: true, name: "9841234567"),
            AppCoordinator.MissedCallDialRoute(
                action: .call(name: "9841234567", phone: "9841234567"),
                channel: .phone, fellBackFrom: [], hopCandidates: []))
    }

    /// The full matrix for a matched family contact: preference decides,
    /// FaceTime falls to phone, Messenger needs its handle — each leg
    /// also carries the route's channel and provenance.
    func testMatchedFamilyContactDrivesTheAction() {
        let whatsAppRoute = AppCoordinator.missedCallDialAction(
            phone: "9800000000",
            familyContact: familyContact(name: "सीता", phone: "9800000000",
                                         preferredCallApp: .whatsApp),
            defaultApp: .phone, secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "सीता")
        XCTAssertEqual(whatsAppRoute.action, .whatsApp(name: "सीता", phone: "9800000000"))
        XCTAssertEqual(whatsAppRoute.channel, .whatsApp)
        XCTAssertEqual(whatsAppRoute.fellBackFrom, [])

        let messengerRoute = AppCoordinator.missedCallDialAction(
            phone: "9811111111",
            familyContact: familyContact(name: "राम", phone: "9811111111",
                                         preferredCallApp: .messenger,
                                         messengerHandle: "ram.sharma"),
            defaultApp: .phone, secondaryApp: .phone, messengerHandle: "ram.sharma",
            whatsAppInstalled: true, name: "राम")
        XCTAssertEqual(messengerRoute.action,
                       .messenger(name: "राम", phone: "9811111111", handle: "ram.sharma"))
        XCTAssertEqual(messengerRoute.channel, .messenger)
        XCTAssertEqual(messengerRoute.fellBackFrom, [])

        let faceTimeRoute = AppCoordinator.missedCallDialAction(
            phone: "9841234567",
            familyContact: familyContact(name: "बुबा", phone: "9841234567",
                                         preferredCallApp: .faceTime),
            defaultApp: .phone, secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "बुबा")
        XCTAssertEqual(faceTimeRoute.action, .call(name: "बुबा", phone: "9841234567"))
        XCTAssertEqual(faceTimeRoute.channel, .phone)
        XCTAssertEqual(faceTimeRoute.fellBackFrom, [])
    }

    /// Pin (c): the GSM floor stays reachable when EVERY other channel is
    /// infeasible — preferred Messenger WITHOUT a handle, secondary
    /// WhatsApp with the installed probe false. The provenance carries
    /// the two skipped channels in attempt order, and the candidates are
    /// EMPTY because the floor IS the routed terminal (nothing remains
    /// to hop to).
    func testFloorReachableWithEveryOtherChannelInfeasible() {
        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "9811111111",
                familyContact: familyContact(name: "राम", phone: "9811111111",
                                             preferredCallApp: .messenger),
                defaultApp: .phone, secondaryApp: .whatsApp, messengerHandle: nil,
                whatsAppInstalled: false, name: "राम"),
            AppCoordinator.MissedCallDialRoute(
                action: .call(name: "राम", phone: "9811111111"),
                channel: .phone, fellBackFrom: [.messenger, .whatsApp],
                hopCandidates: []))
    }

    /// Pin (d): the dial-back stays an AUDIO call — the shipped
    /// FaceTime-never-resolves semantics (the seam section above) hold at
    /// the route level. A matched FaceTime preference is the shipped
    /// `resolvedAudioApp` substitution; an unmatched FaceTime GLOBAL
    /// default is substituted by the seam's audio vocabulary — both land
    /// the shipped `.call` floor route with EMPTY provenance (a
    /// substitution is not a fallback) and no candidates.
    func testFaceTimePreferenceStaysTheAudioFloorRoute() {
        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "9841234567",
                familyContact: familyContact(name: "बुबा", phone: "9841234567",
                                             preferredCallApp: .faceTime),
                defaultApp: .phone, secondaryApp: .phone, messengerHandle: nil,
                whatsAppInstalled: true, name: "बुबा"),
            AppCoordinator.MissedCallDialRoute(
                action: .call(name: "बुबा", phone: "9841234567"),
                channel: .phone, fellBackFrom: [], hopCandidates: []))

        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "9841234567", familyContact: nil, defaultApp: .faceTime,
                secondaryApp: .phone, messengerHandle: nil,
                whatsAppInstalled: true, name: "9841234567"),
            AppCoordinator.MissedCallDialRoute(
                action: .call(name: "9841234567", phone: "9841234567"),
                channel: .phone, fellBackFrom: [], hopCandidates: []))
    }

    /// Pin (e): a DIRECT route (the resolved channel was routed with
    /// nothing skipped) carries empty provenance — the delivered
    /// announcement's no-speak condition. Exercised for a non-floor
    /// direct route (per-contact WhatsApp preference with the probe on)
    /// and for the floor preferred itself.
    func testDirectRouteCarriesNoProvenanceToAnnounce() {
        let whatsAppRoute = AppCoordinator.missedCallDialAction(
            phone: "9800000000",
            familyContact: familyContact(name: "सीता", phone: "9800000000",
                                         preferredCallApp: .whatsApp),
            defaultApp: .phone, secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "सीता")
        XCTAssertEqual(whatsAppRoute.channel, .whatsApp)
        XCTAssertEqual(whatsAppRoute.fellBackFrom, [],
                       "the preferred channel routed — nothing was skipped, nothing to announce")

        let floorRoute = AppCoordinator.missedCallDialAction(
            phone: "9800000000", familyContact: nil, defaultApp: .phone,
            secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "9800000000")
        XCTAssertEqual(floorRoute.channel, .phone)
        XCTAssertEqual(floorRoute.fellBackFrom, [])
    }

    /// Pin (f) — the W3-review N-2 / L2-D9 edge (pinned, not "fixed"):
    /// the dial-back derives messenger availability with the RAW shipped
    /// expression `messengerHandle?.isEmpty == false`, so a handle that
    /// is non-empty raw but normalises to empty (whitespace-only here)
    /// still routes `.messenger`. The row/voice predicate
    /// (`hasUsableMessengerHandle` — private; the negation of the
    /// normalised `CallLinks.messengerHandle` form) would say unusable:
    /// the divergence is shipped behaviour, design-sanctioned (L2-D9
    /// "derived exactly as shipped"). This pin asserts BOTH sides so a
    /// future "cleanup" that swaps in the normalised predicate fails
    /// here — never weaken it to an equality-only check.
    func testWhitespaceOnlyHandleKeepsTheRawDialBackDerivation() {
        let whitespaceOnly = "   "
        XCTAssertTrue(CallLinks.messengerHandle(whitespaceOnly).isEmpty,
                      "the normalised predicate's input: unusable as a handle")
        let route = AppCoordinator.missedCallDialAction(
            phone: "9811111111",
            familyContact: familyContact(name: "राम", phone: "9811111111",
                                         preferredCallApp: .messenger,
                                         messengerHandle: whitespaceOnly),
            defaultApp: .phone, secondaryApp: .phone,
            messengerHandle: whitespaceOnly,
            whatsAppInstalled: true, name: "राम")
        XCTAssertEqual(route.action,
                       .messenger(name: "राम", phone: "9811111111", handle: whitespaceOnly),
                       "the RAW derivation routes `.messenger` where the normalised "
                       + "predicate would skip it (W3 N-2; do not \"fix\")")
        XCTAssertEqual(route.channel, .messenger)
        XCTAssertEqual(route.fellBackFrom, [])
        XCTAssertEqual(route.hopCandidates,
                       CallChannelChain.hopCandidates(preferred: .messenger,
                                                      secondary: .phone,
                                                      routed: .messenger,
                                                      vocabulary: .audio))
    }

    /// Pin (h): the route's hop candidates are the chain's
    /// per-vocabulary suffix after the ROUTED channel (L2-D1) — the
    /// expectation is DERIVED from `CallChannelChain` directly, never a
    /// guessed list, and the derived list is then pinned to the design's
    /// §10.4 case-table value. A messenger-routed dial-back carries the
    /// remaining feasible channel `[.phone]` (design-l2.md:910: the
    /// `.audio` row — the FaceTime secondary is filtered, the floor
    /// remains); the WhatsApp row likewise; a floor-routed route carries
    /// none (the audio terminal IS the routed channel — L2-D1).
    func testRouteHopCandidatesAreTheChainsDerivedSuffix() {
        let messengerRoute = AppCoordinator.missedCallDialAction(
            phone: "9811111111",
            familyContact: familyContact(name: "राम", phone: "9811111111",
                                         preferredCallApp: .messenger,
                                         messengerHandle: "ram.sharma"),
            defaultApp: .phone, secondaryApp: .phone, messengerHandle: "ram.sharma",
            whatsAppInstalled: true, name: "राम")
        let expectedMessenger = CallChannelChain.hopCandidates(preferred: .messenger,
                                                               secondary: .phone,
                                                               routed: .messenger,
                                                               vocabulary: .audio)
        XCTAssertEqual(messengerRoute.channel, .messenger)
        XCTAssertEqual(messengerRoute.hopCandidates, expectedMessenger)
        XCTAssertEqual(expectedMessenger, [.phone],
                       "the design's §10.4 suffix after `.messenger` is `[.phone]`")

        let whatsAppRoute = AppCoordinator.missedCallDialAction(
            phone: "9800000000", familyContact: nil, defaultApp: .whatsApp,
            secondaryApp: .phone, messengerHandle: nil,
            whatsAppInstalled: true, name: "9800000000")
        let expectedWhatsApp = CallChannelChain.hopCandidates(preferred: .whatsApp,
                                                              secondary: .phone,
                                                              routed: .whatsApp,
                                                              vocabulary: .audio)
        XCTAssertEqual(whatsAppRoute.channel, .whatsApp)
        XCTAssertEqual(whatsAppRoute.hopCandidates, expectedWhatsApp)
        XCTAssertEqual(expectedWhatsApp, [.phone])

        let floorRoute = AppCoordinator.missedCallDialAction(
            phone: "9811111111",
            familyContact: familyContact(name: "राम", phone: "9811111111",
                                         preferredCallApp: .messenger),
            defaultApp: .phone, secondaryApp: .whatsApp, messengerHandle: nil,
            whatsAppInstalled: false, name: "राम")
        XCTAssertEqual(floorRoute.channel, .phone)
        XCTAssertEqual(floorRoute.hopCandidates, [],
                       "the audio terminal is the routed channel — no candidate remains")
    }

    // MARK: - Source pins (the delivered dial-back wiring)

    /// Pin (g): the dial-back announces AT RESOLUTION, before the
    /// dispatch, exactly once, and only on a fallback (ADR-CDP-07) —
    /// the announcement names the skipped channel, the identity and the
    /// routed one — then dispatches the route's action, threading the
    /// route's hop into exactly the three hopping openers (never the
    /// `.call` floor; RES-10). Speech only: no console write anywhere in
    /// the region. SA-4(d): nothing in the region (or the hop path it
    /// dispatches into) awaits, sleeps, retries or schedules a timer.
    /// Comment-stripped source scan (the house `FeatureSourceScan` +
    /// region convention — the pins are code, never prose).
    func testDialBackAnnouncesBeforeDispatchSourcePins() throws {
        let source = coordinatorSource()
        let dialBack = try region(
            between: "func dialBackMissedCall(_ entry: AppActivityEntry) {",
            and: "var contactCallRecency", in: source)
        let flat = collapsed(dialBack)

        // The announcement: exactly ONE site, BEFORE the switch; the
        // fellBackFrom.first + channel non-nil condition gates it.
        XCTAssertEqual(occurrences(of: "call.announce.fallbackRouted", in: dialBack), 1,
                       "one announcement site")
        let announceRange = try XCTUnwrap(
            dialBack.range(of: "if let skipped = route.fellBackFrom.first, let channel = route.channel {"))
        let switchRange = try XCTUnwrap(dialBack.range(of: "switch route.action {"))
        XCTAssertLessThan(announceRange.lowerBound, switchRange.lowerBound,
                          "the announcement runs at resolution, BEFORE the dispatch (ADR-CDP-07)")
        XCTAssertTrue(flat.contains(collapsed("""
            if let skipped = route.fellBackFrom.first, let channel = route.channel {
                speak(text: L10n.fmt("call.announce.fallbackRouted", locale: activeLocale,
                                     CallChannelChain.label(skipped, locale: activeLocale),
                                     identity,
                                     CallChannelChain.label(channel, locale: activeLocale)))
            }
            """).trimmingCharacters(in: .whitespaces)),
                      "the announcement names the skipped channel, the identity "
                      + "and the routed one")

        // The hop: built ONCE from the route's candidates, carrying the
        // family's handle and (W6 N-4 carry) the row's own phone.
        XCTAssertTrue(flat.contains(collapsed("""
            let hop = LaunchHop(candidates: route.hopCandidates,
                                handle: family?.messengerHandle,
                                phone: entry.phone)
            """).trimmingCharacters(in: .whitespaces)),
                      "the hop carries the candidates, the handle and the row's phone (N-4)")

        // Exactly the three hopping openers thread `hop: hop`; nothing
        // hop-shaped before the switch; the floor arm never hops.
        XCTAssertEqual(occurrences(of: "hop: hop", in: dialBack), 3,
                       "exactly the three hopping openers thread the hop")
        XCTAssertFalse(String(dialBack[..<switchRange.lowerBound]).contains("hop: hop"),
                       "nothing hop-shaped runs before the switch")
        let callArm = try region(between: "case .call(let name, let phone):",
                                 and: "case .faceTime(let name, let phone):", in: dialBack)
        XCTAssertEqual(occurrences(of: "hop: hop", in: callArm), 0,
                       "the GSM floor never hops (RES-10)")
        XCTAssertTrue(collapsed(callArm).contains(collapsed("""
            performSystemContactCall(name: name, phone: phone)
            """).trimmingCharacters(in: .whitespaces)),
                      "the shipped no-hop floor form, verbatim")

        let faceTimeArm = try region(between: "case .faceTime(let name, let phone):",
                                     and: "case .whatsApp(let name, let phone):", in: dialBack)
        XCTAssertEqual(occurrences(of: "hop: hop", in: faceTimeArm), 1)
        XCTAssertTrue(collapsed(faceTimeArm).contains(collapsed("""
            performFaceTimeCall(name: name, phone: phone, video: true, hop: hop)
            """).trimmingCharacters(in: .whitespaces)),
                      "the video dial-back arm threads the hop")

        let whatsAppArm = try region(between: "case .whatsApp(let name, let phone):",
                                     and: "case .messenger(let name, _, let handle):",
                                     in: dialBack)
        XCTAssertEqual(occurrences(of: "hop: hop", in: whatsAppArm), 1)
        XCTAssertTrue(collapsed(whatsAppArm).contains(collapsed("""
            performSystemContactWhatsApp(name: name, phone: phone, hop: hop)
            """).trimmingCharacters(in: .whitespaces)),
                      "the WhatsApp arm threads the hop")

        let messengerStart = try XCTUnwrap(
            dialBack.range(of: "case .messenger(let name, _, let handle):"))
        let messengerArm = String(dialBack[messengerStart.lowerBound...])
        XCTAssertEqual(occurrences(of: "hop: hop", in: messengerArm), 1)
        XCTAssertTrue(collapsed(messengerArm).contains(collapsed("""
            performSystemContactMessenger(name: name, handle: handle, hop: hop)
            """).trimmingCharacters(in: .whitespaces)),
                      "the Messenger arm threads the hop")

        // Speech only: the region carries no observability write.
        XCTAssertEqual(occurrences(of: "observabilityBus", in: dialBack), 0,
                       "the dial-back adds no console write")
        XCTAssertEqual(occurrences(of: "emit(", in: dialBack), 0,
                       "the dial-back adds no console write")

        // SA-4(d) (Gherkin scenario 3): nothing delays escalation — no
        // await, sleep, retry loop or timer runs in the dial-back region
        // or in the hop path it dispatches into.
        let hopStep = try region(between: "func launchFailHopStep(after failed: CallApp,",
                                 and: "private func performLaunchFailHop(", in: source)
        let hopHelper = try region(between: "private func performLaunchFailHop(after failed: CallApp,",
                                   and: "private func noteLaunchFailHop(", in: source)
        for token in ["await", "sleep", "Timer", "retry", "asyncAfter"] {
            XCTAssertEqual(occurrences(of: token, in: dialBack), 0,
                           "no `\(token)` in the dial-back chain (SA-4(d))")
            XCTAssertEqual(occurrences(of: token, in: hopStep + hopHelper), 0,
                           "no `\(token)` in the hop path (SA-4(d))")
        }
    }

    /// The route value's shape (design-l2.md:393-402, L2-D9): the action,
    /// the routed channel (optional — nil for the two guards), the
    /// attempt-order provenance and the launch-fail candidates, field
    /// for field, `Equatable` so the whole decision is comparable.
    func testMissedCallDialRouteShapeSourcePins() throws {
        let source = coordinatorSource()
        let route = try region(between: "struct MissedCallDialRoute: Equatable {",
                               and: "static func missedCallDialAction(phone: String,",
                               in: source)
        XCTAssertTrue(collapsed(route).contains(collapsed("""
            struct MissedCallDialRoute: Equatable {
                let action: MissedCallDialAction
                let channel: CallApp?
                let fellBackFrom: [CallApp]
                let hopCandidates: [CallApp]
            }
            """).trimmingCharacters(in: .whitespaces)),
                      "the L2-D9 route value, field for field")
    }

    /// The decision's source (design-l2.md:404-438, L2-D9): the shipped
    /// guards wrap the empty route (returning BEFORE the chain), the
    /// messenger availability stays the RAW shipped derivation (NOT the
    /// normalised `hasUsableMessengerHandle` predicate — W3 N-2), and
    /// the single final return carries the routed channel, the
    /// provenance and the chain's audio-vocabulary hop candidates — one
    /// snapshot, so the dispatch re-derives no routing fact.
    func testMissedCallDialActionSourcePins() throws {
        let source = coordinatorSource()
        let action = try region(between: "static func missedCallDialAction(phone: String,",
                                and: "func dialBackMissedCall(", in: source)
        let flat = collapsed(action)

        XCTAssertTrue(flat.contains(collapsed("""
            static func missedCallDialAction(phone: String,
                                             familyContact: FamilyContact?,
                                             defaultApp: CallApp,
                                             secondaryApp: CallApp,
                                             messengerHandle: String?,
                                             whatsAppInstalled: Bool,
                                             name: String) -> MissedCallDialRoute {
            """).trimmingCharacters(in: .whitespaces)),
                      "the L2-D9 signature: the settings pair, the probe and the identity")
        XCTAssertTrue(flat.contains(collapsed("""
            guard !phone.isEmpty else {
                return MissedCallDialRoute(action: .openPhoneApp, channel: nil,
                                           fellBackFrom: [], hopCandidates: [])
            }
            """).trimmingCharacters(in: .whitespaces)),
                      "the shipped numberless guard, wrapped in an empty route")
        XCTAssertTrue(flat.contains(collapsed("""
            guard !ContactNumberKey.normalized(phone).isEmpty else {
                return MissedCallDialRoute(action: .unusableNumber(name: name), channel: nil,
                                           fellBackFrom: [], hopCandidates: [])
            }
            """).trimmingCharacters(in: .whitespaces)),
                      "the shipped dead-row guard, wrapped in an empty route")
        XCTAssertTrue(flat.contains(collapsed("""
            let preferred = familyContact?.resolvedAudioApp ?? defaultApp
            """).trimmingCharacters(in: .whitespaces)),
                      "the routed channel starts from the contact's AUDIO preference")
        XCTAssertTrue(flat.contains(collapsed("""
            messengerHandleAvailable: messengerHandle?.isEmpty == false,
            """).trimmingCharacters(in: .whitespaces)),
                      "the RAW shipped handle derivation, verbatim (L2-D9 / W3 N-2)")
        XCTAssertFalse(flat.contains("hasUsableMessengerHandle"),
                       "the normalised row predicate is deliberately NOT used here (W3 N-2)")
        XCTAssertTrue(flat.contains(collapsed("""
            return MissedCallDialRoute(
                action: action, channel: route.channel, fellBackFrom: route.fellBackFrom,
                hopCandidates: CallChannelChain.hopCandidates(
                    preferred: preferred, secondary: secondaryApp,
                    routed: route.channel, vocabulary: .audio))
            """).trimmingCharacters(in: .whitespaces)),
                      "one snapshot: channel, provenance and the audio hop candidates (L2-D9)")
    }

    // MARK: - Row identity (the list's name line)

    /// The identity chain: correlated name → stored contact → raw
    /// number → nil (anonymous). The correlated name wins over the
    /// stored one — it is the resolver's CURRENT answer (family first,
    /// then the native book).
    func testUnansweredIdentityChain() {
        let attributed = AppActivityEntry(kind: .call, channel: .unanswered,
                                          contactName: "बुबा", phone: "9841234567")
        XCTAssertEqual(ActivityRowText.unansweredIdentity(for: attributed), "बुबा")
        XCTAssertEqual(ActivityRowText.unansweredIdentity(
            for: attributed, correlatedName: "Hari Sharma"), "Hari Sharma")

        let numberOnly = AppActivityEntry(kind: .call, channel: .unanswered,
                                          contactName: "", phone: "+977 9841234567")
        XCTAssertEqual(ActivityRowText.unansweredIdentity(for: numberOnly),
                       "+977 9841234567")

        let anonymous = AppActivityEntry(kind: .call, channel: .unanswered,
                                         contactName: "", phone: "")
        XCTAssertNil(ActivityRowText.unansweredIdentity(for: anonymous))
    }

    /// The name line resolves through the chain and only falls back to
    /// the "Unanswered call" label for a truly anonymous row; a numbered
    /// row without a match shows its NUMBER.
    func testNameLineShowsNumberWhenNoNameMatches() {
        let ne = Locale(identifier: "ne-NP")
        let numberOnly = AppActivityEntry(kind: .call, channel: .unanswered,
                                          contactName: "", phone: "9841234567")
        XCTAssertEqual(ActivityRowText.name(for: numberOnly, locale: ne), "9841234567")
        XCTAssertEqual(ActivityRowText.name(
            for: numberOnly, locale: ne, correlatedName: "Hari Sharma"), "Hari Sharma")

        let anonymous = AppActivityEntry(kind: .call, channel: .unanswered,
                                         contactName: "", phone: "")
        XCTAssertEqual(ActivityRowText.name(for: anonymous, locale: ne), "नउठाएको कल")
    }

    /// The caption carries the NUMBER for every numbered missed row, so
    /// the number stays visible even when the name line shows a matched
    /// contact — "Missed call · <number> · <time>".
    func testCaptionCarriesTheNumber() {
        let utcCalendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar
        }()
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 6,
                                                        hour: 12, minute: 0, second: 0))!
        let en = Locale(identifier: "en-US")
        let numbered = AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                                        kind: .call, channel: .unanswered,
                                        contactName: "बुबा", phone: "9841234567")
        XCTAssertEqual(ActivityRowText.caption(for: numbered, now: now,
                                               calendar: utcCalendar, locale: en),
                       "Missed call · 9841234567 · Just now")

        let anonymous = AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                                         kind: .call, channel: .unanswered,
                                         contactName: "", phone: "")
        XCTAssertEqual(ActivityRowText.caption(for: anonymous, now: now,
                                               calendar: utcCalendar, locale: en),
                       "Missed call · Just now")
    }

    // MARK: - Helpers (the house source-scan patterns)

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
}
