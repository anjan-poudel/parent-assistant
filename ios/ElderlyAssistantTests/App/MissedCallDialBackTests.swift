import XCTest
@testable import ElderlyAssistant

/// The missed-call row's tap (missed-calls fix, 2026-09-18): the pure
/// dial-back seams — `resolvedMissedCallChannel` (the SAME resolution a
/// family contact's audio call button uses) and `missedCallDialAction`
/// (the decision `AppCoordinator.dialBackMissedCall` dispatches) — plus
/// the presentation seam the list rows render through
/// (`ActivityRowText.unansweredIdentity`). All pure statics, the house
/// seam pattern: no coordinator, no CallKit, no UI.
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

    /// A matched family contact's OWN audio preference wins — the tap
    /// resolves EXACTLY like that contact's audio call button.
    func testFamilyContactPreferenceWins() {
        let whatsApp = familyContact(name: "सीता", phone: "9800000000",
                                     preferredCallApp: .whatsApp)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: whatsApp,
                                                     defaultApp: .phone,
                                                     messengerHandleAvailable: false),
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
                                                     messengerHandleAvailable: true),
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
                                                     messengerHandleAvailable: false),
            .phone)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: messenger,
                                                     defaultApp: .messenger,
                                                     messengerHandleAvailable: false),
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
                                                     messengerHandleAvailable: false),
            .phone)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .faceTime,
                                                     messengerHandleAvailable: false),
            .phone)
    }

    /// No family match → the global default decides, with the same hard
    /// rules on top.
    func testGlobalDefaultAppliesWithoutFamilyMatch() {
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .whatsApp,
                                                     messengerHandleAvailable: false),
            .whatsApp)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .phone,
                                                     messengerHandleAvailable: false),
            .phone)
        XCTAssertEqual(
            AppCoordinator.resolvedMissedCallChannel(familyContact: nil,
                                                     defaultApp: .messenger,
                                                     messengerHandleAvailable: true),
            .messenger)
    }

    // MARK: - Dial action (the tap's decision)

    /// A numberless row (an anonymous entry from before the fix, or a
    /// caller iOS masked) keeps the honest Phone-app open — there is no
    /// number to dial and the app never fakes one.
    func testNumberlessRowOpensPhoneApp() {
        let action = AppCoordinator.missedCallDialAction(
            phone: "", familyContact: nil, defaultApp: .phone,
            messengerHandle: nil, name: "")
        XCTAssertEqual(action, .openPhoneApp)
    }

    /// A number that normalizes to nothing dialable speaks the honest
    /// dead-row line instead of a silent dead tap (defensive — records
    /// never store one, but a corrupt payload must not dead-end).
    func testUndialableNumberIsHonestDeadRow() {
        let action = AppCoordinator.missedCallDialAction(
            phone: "not-a-number", familyContact: nil, defaultApp: .phone,
            messengerHandle: nil, name: "not-a-number")
        XCTAssertEqual(action, .unusableNumber(name: "not-a-number"))
    }

    /// The tel: fallback is always in the chain: an unmatched number
    /// under any default still dials GSM.
    func testUnmatchedNumberAlwaysDialsTel() {
        let action = AppCoordinator.missedCallDialAction(
            phone: "9841234567", familyContact: nil, defaultApp: .faceTime,
            messengerHandle: nil, name: "9841234567")
        XCTAssertEqual(action, .call(name: "9841234567", phone: "9841234567"))
    }

    /// The full matrix for a matched family contact: preference decides,
    /// FaceTime falls to phone, Messenger needs its handle.
    func testMatchedFamilyContactDrivesTheAction() {
        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "9800000000",
                familyContact: familyContact(name: "सीता", phone: "9800000000",
                                             preferredCallApp: .whatsApp),
                defaultApp: .phone, messengerHandle: nil, name: "सीता"),
            .whatsApp(name: "सीता", phone: "9800000000"))

        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "9811111111",
                familyContact: familyContact(name: "राम", phone: "9811111111",
                                             preferredCallApp: .messenger,
                                             messengerHandle: "ram.sharma"),
                defaultApp: .phone, messengerHandle: "ram.sharma", name: "राम"),
            .messenger(name: "राम", phone: "9811111111", handle: "ram.sharma"))

        XCTAssertEqual(
            AppCoordinator.missedCallDialAction(
                phone: "9841234567",
                familyContact: familyContact(name: "बुबा", phone: "9841234567",
                                             preferredCallApp: .faceTime),
                defaultApp: .phone, messengerHandle: nil, name: "बुबा"),
            .call(name: "बुबा", phone: "9841234567"))
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
}
