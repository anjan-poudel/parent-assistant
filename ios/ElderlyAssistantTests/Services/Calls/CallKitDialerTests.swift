// NEW file: Services/Calls/CallKitDialerTests.swift (callkit-gsm, 2026-10-14)
import XCTest
@testable import ElderlyAssistant
#if canImport(CallKit)
import CallKit
#endif

/// The CallKit GSM dialer's obligations (callkit-gsm, 2026-10-14) — the
/// owner-report fix: asking the assistant to call a contact must show the
/// app's own localized confirmation ONLY, never the system `tel:`
/// Open/Cancel sheet (a `tel:` open ALWAYS raises it; nothing can
/// suppress it — so the dial moved to CallKit's `CXStartCallAction`,
/// which places the native GSM call with no prompt at all).
///
/// Two layers, the house split:
/// 1. BEHAVIOUR, driven against a fake `CallTransactionSubmitting` (the
///    `CallStateProviding` wall pattern — CallKit's own request pipeline
///    cannot be driven by unit tests): the request build (handle type and
///    value, `isVideo`), the invalid-number refusal (nothing submitted,
///    no fallback — nothing dialable anywhere), and the fallback
///    decision (the `tel:` open runs ONLY on CallKit's error, after its
///    answer, exactly once).
/// 2. SOURCE PINS (`FeatureSourceScan`, comment-stripped — the
///    CallChannelResolutionTests/ContactCallButtonsTests convention):
///    every GSM path dials through the ONE shared coordinator site, the
///    naive `tel:` open survives only as that site's CallKit-failure
///    fallback, the emergency tap takes the same path, and
///    `CXStartCallAction` is built in exactly one file.
final class CallKitDialerTests: XCTestCase {

    // MARK: - 1. Request building and the fallback decision

    /// Captures what the dialer hands CallKit. The submission itself is
    /// the one thing a unit test cannot exercise (no fake can be injected
    /// into `CXCallController`), so the seam is the wall — everything up
    /// to and including the build is real.
    private final class FakeSubmitter: CallTransactionSubmitting {
        private(set) var transactions: [CXTransaction] = []
        private(set) var completion: ((Error?) -> Void)?

        func submit(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void) {
            transactions.append(transaction)
            self.completion = completion
        }

        /// Answer the pending request the way CallKit would — nil for
        /// accepted, an error for rejected.
        func answer(_ error: Error?) {
            completion?(error)
        }
    }

    private struct CallKitError: Error {}

    /// The dial build, whole: one transaction, one `CXStartCallAction`
    /// with a `.phoneNumber` handle in the shipped `phoneHandle` form
    /// (CallKit and the `tel:` fallback dial the identical number) and
    /// `isVideo = false` — a GSM audio call, never FaceTime.
    func testDialBuildsAPhoneNumberStartCallRequest() throws {
        let submitter = FakeSubmitter()
        let dialer = CallKitDialer(submitter: submitter, deliver: { $0() })
        var fallbacks = 0

        let outcome = dialer.dial(phoneNumber: "+977-9841 23 45 67",
                                  onFailure: { fallbacks += 1 })

        XCTAssertEqual(outcome, .requested, "a dialable number is a submitted request")
        XCTAssertEqual(submitter.transactions.count, 1, "one request per dial")
        XCTAssertEqual(submitter.transactions.first?.actions.count, 1,
                       "one action per request")
        let action = try XCTUnwrap(submitter.transactions.first?.actions.first
                                       as? CXStartCallAction,
                                   "the GSM dial is a CXStartCallAction")
        XCTAssertEqual(action.handle.type, .phoneNumber,
                       "a phone-number handle needs no entitlement and gets no "
                       + "confirmation prompt")
        XCTAssertEqual(action.handle.value, "+9779841234567",
                       "the handle carries the shipped phoneHandle form — digits "
                       + "with the single leading + kept")
        XCTAssertEqual(action.isVideo, false, "GSM audio, never video")
        XCTAssertEqual(fallbacks, 0,
                       "no CallKit answer yet — no reason for a fallback")
    }

    /// One normalization rule for every GSM path: `CallKitDialRequest`
    /// equals the shipped `CallLinks.phoneHandle` for every raw number —
    /// CallKit and the `tel:` fallback can never dial different digits
    /// (the guard is exactly the shipped 'handle not empty' one).
    func testHandleNormalizationMatchesTheShippedPhoneHandleRule() {
        for raw in ["+977-9841 23 45 67", "9841 23 45 67", "  +977 9841  ",
                    "98+41", "+", "9841", ""] {
            let shipped = CallLinks.phoneHandle(raw)
            XCTAssertEqual(CallKitDialRequest.numberValue(raw),
                           shipped.isEmpty ? nil : shipped,
                           "CallKitDialRequest must mirror CallLinks.phoneHandle for "
                           + "\(raw.debugDescription) — one dial decision, two paths")
        }
        XCTAssertEqual(CallKitDialRequest.numberValue("+977-9841 23 45 67"),
                       "+9779841234567")
        XCTAssertEqual(CallKitDialRequest.numberValue("98+41"), "9841",
                       "a + anywhere but the front is a typo, not a country code")
        XCTAssertNil(CallKitDialRequest.numberValue(""),
                     "an empty number is undialable")
        XCTAssertNil(CallKitDialRequest.numberValue("   "))
        XCTAssertNil(CallKitDialRequest.numberValue("no digits here"))
    }

    /// The invalid-number refusal: nothing submitted to CallKit AND no
    /// `tel:` fallback — with no dialable digits there is nothing any
    /// path could dial, so neither side effect may fire.
    func testInvalidNumberSubmitsNothingAndNeverFallsBack() {
        let submitter = FakeSubmitter()
        let dialer = CallKitDialer(submitter: submitter, deliver: { $0() })
        var fallbacks = 0

        XCTAssertEqual(dialer.dial(phoneNumber: "", onFailure: { fallbacks += 1 }),
                       .invalidNumber)
        XCTAssertEqual(dialer.dial(phoneNumber: "no digits here",
                                   onFailure: { fallbacks += 1 }),
                       .invalidNumber)

        XCTAssertTrue(submitter.transactions.isEmpty,
                      "nothing dialable — nothing reaches CallKit")
        XCTAssertEqual(fallbacks, 0,
                       "the tel: fallback is for CallKit FAILURES, not for "
                       + "undialable numbers — it could not dial either")
    }

    /// The happy-path fallback silence: CallKit accepting the request
    /// (completion nil) must leave the `tel:` open untouched — the whole
    /// point is that the system sheet never appears on a working dial.
    func testCallKitAcceptanceRunsNoFallback() {
        let submitter = FakeSubmitter()
        let dialer = CallKitDialer(submitter: submitter, deliver: { $0() })
        var fallbacks = 0

        dialer.dial(phoneNumber: "9841234567", onFailure: { fallbacks += 1 })
        XCTAssertEqual(fallbacks, 0, "the fallback waits for CallKit's answer")

        submitter.answer(nil)
        XCTAssertEqual(fallbacks, 0,
                       "an accepted request is the end of the path — no tel: sheet")
    }

    /// The fallback matrix, failure leg: a CallKit rejection delivers the
    /// `tel:` open exactly once, and only AFTER the answer (never before
    /// — the dial may still succeed).
    func testCallKitFailureRunsTheFallbackExactlyOnce() {
        let submitter = FakeSubmitter()
        let dialer = CallKitDialer(submitter: submitter, deliver: { $0() })
        var fallbacks = 0

        dialer.dial(phoneNumber: "9841234567", onFailure: { fallbacks += 1 })
        XCTAssertEqual(fallbacks, 0, "the fallback waits for CallKit's answer")

        submitter.answer(CallKitError())
        XCTAssertEqual(fallbacks, 1,
                       "a rejected request is exactly the case the tel: fallback "
                       + "survives for — once")
    }

    /// The delivery seam (Constraint 12 — the environment fact as an
    /// argument): the failure fallback runs on the INJECTED queue, not
    /// inline where CallKit calls back. Production injects the main
    /// queue, where the coordinator's speech, state and the `tel:` open
    /// live; the test injects a hold so the scheduling is visible.
    func testFallbackRunsOnTheInjectedQueueNotInline() {
        let submitter = FakeSubmitter()
        var pending: (() -> Void)?
        let dialer = CallKitDialer(submitter: submitter, deliver: { pending = $0 })
        var fallbacks = 0

        dialer.dial(phoneNumber: "9841234567", onFailure: { fallbacks += 1 })
        submitter.answer(CallKitError())

        XCTAssertEqual(fallbacks, 0,
                       "the fallback is DELIVERED, not run inline on CallKit's "
                       + "callback queue")
        pending?()
        XCTAssertEqual(fallbacks, 1, "the injected queue runs it exactly once")
    }

    // MARK: - 2. The confirmation copy stays the app's own (en + ne)

    private let englishLocale = Locale(identifier: "en-US")
    private let nepaliLocale = Locale(identifier: "ne-NP")

    /// The owner's ask, positively: with the system sheet gone, the ONLY
    /// confirmation is the app's own localized seam — the question names
    /// the contact and the method in the app's language, and the placed
    /// call announces itself in the same language. (The frozen byte-pins
    /// live in CallConfirmationWordingTests; this unit enforces the
    /// two-language coverage the fix rests on.)
    func testConfirmationCopyResolvesInEnglishAndNepali() {
        for locale in [englishLocale, nepaliLocale] {
            let method = L10n.str("router.call.methodPhone", locale: locale)
            XCTAssertFalse(method.isEmpty,
                           "router.call.methodPhone must resolve from the "
                           + "\(locale.identifier) catalog")
            let question = L10n.fmt("router.call.confirmQuestion", locale: locale,
                                    "Maya", method)
            XCTAssertFalse(question.isEmpty,
                           "router.call.confirmQuestion must resolve from the "
                           + "\(locale.identifier) catalog")
            XCTAssertTrue(question.contains("Maya"),
                          "the contact's name rides the localized question "
                          + "(\(locale.identifier)): \(question)")
            XCTAssertTrue(question.contains(method),
                          "the localized method noun rides the question "
                          + "(\(locale.identifier)): \(question)")

            let calling = L10n.fmt("router.call.calling", locale: locale, "Maya")
            XCTAssertFalse(calling.isEmpty,
                           "router.call.calling must resolve from the "
                           + "\(locale.identifier) catalog")
            XCTAssertTrue(calling.contains("Maya"),
                          "the placed-call line names the contact "
                          + "(\(locale.identifier)): \(calling)")
        }

        XCTAssertNotEqual(L10n.str("router.call.methodPhone", locale: englishLocale),
                          L10n.str("router.call.methodPhone", locale: nepaliLocale),
                          "the confirmation copy is genuinely localized (en ≠ ne)")
        XCTAssertNotEqual(L10n.fmt("router.call.confirmQuestion", locale: englishLocale,
                                   "Maya", L10n.str("router.call.methodPhone",
                                                    locale: englishLocale)),
                          L10n.fmt("router.call.confirmQuestion", locale: nepaliLocale,
                                   "Maya", L10n.str("router.call.methodPhone",
                                                    locale: nepaliLocale)),
                          "the question is genuinely localized (en ≠ ne)")
    }

    // MARK: - 3. Source pins — the ONE dial site everywhere

    /// Every GSM path dials through the coordinator's shared `placeGSMCall`
    /// site, and the naive `tel:` open survives in exactly ONE place: that
    /// site's CallKit-failure fallback. The system-search floor and the
    /// emergency tap carry no raw open of their own anymore.
    func testEveryGSMPathDialsThroughTheSharedCallKitSite() throws {
        let source = coordinatorSource()

        // The whole coordinator: exactly one `callLinks.openPhone(` — the
        // fallback inside placeGSMCall. Any new naive tel: open fails here.
        XCTAssertEqual(occurrences(of: "callLinks.openPhone(", in: source), 1,
                       "tel: is the FAILURE fallback only — exactly one direct "
                       + "openPhone site in the coordinator")

        let site = try region(between: "func placeGSMCall(phone: String) -> Bool {",
                              and: "func dialEmergencyContact(", in: source)
        XCTAssertTrue(collapsed(site).contains(
            "switch callKitDialer.dial(phoneNumber: phone, onFailure: { [weak self] in _ = self?.callLinks.openPhone(phone) }) {"),
                      "the shared site dials through the CallKit dialer and keeps "
                      + "the shipped tel: open as its failure fallback")
        XCTAssertTrue(site.contains("case .requested:"),
                      "the requested outcome is the success return")
        XCTAssertTrue(site.contains("case .invalidNumber:"),
                      "the invalid-number outcome is the honest false return")

        // The system-search floor: its whole body is the shared site plus
        // the shipped honest line — no PhoneDialer, no raw open.
        let systemFloor = try region(
            between: "func performSystemContactCall(name: String, phone: String,",
            and: "func placeGSMCall(phone: String) -> Bool {", in: source)
        XCTAssertTrue(collapsed(systemFloor).contains(
            "guard placeGSMCall(phone: phone) else {"),
                      "the floor guards on the shared dial site")
        XCTAssertFalse(systemFloor.contains("PhoneDialer."),
                       "no raw tel: build survives in the floor (callkit-gsm)")
        XCTAssertFalse(systemFloor.contains("UIApplication.shared.open"),
                       "no direct open survives in the floor — the dial is "
                       + "CallKit's")

        // The emergency tap: the coordinator's CallKit path, not the raw
        // tel: builder — the tap must not raise the system sheet either.
        let trigger = try region(between: "private func trigger() {",
                                 and: "struct HintCarousel: View {",
                                 in: screensSource())
        XCTAssertTrue(trigger.contains("coordinator.dialEmergencyContact(contact)"),
                      "the emergency tap goes through the shared CallKit path")
        XCTAssertFalse(trigger.contains("UIApplication.shared.open"),
                       "no raw open in the emergency trigger")
        XCTAssertFalse(trigger.contains("PhoneDialer."),
                       "no raw tel: build in the emergency trigger")
    }

    /// `CXStartCallAction`/`CXCallController` live in exactly ONE file —
    /// the dialer's. A second construction site (another feature dialing
    /// around the shared path) fails here, as it should.
    func testTheStartCallActionIsBuiltInExactlyOneFile() {
        var actionBuilders: [String] = []
        var controllers: [String] = []
        for file in FeatureSourceScan.swiftFiles(in: "ElderlyAssistant") {
            let text = FeatureSourceScan.codeText(of: file)
            if text.contains("CXStartCallAction(") {
                actionBuilders.append(file.lastPathComponent)
            }
            if text.contains("CXCallController(") {
                controllers.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(actionBuilders, ["CallKitDialer.swift"],
                       "the native dial request is built in exactly the dialer")
        XCTAssertEqual(controllers, ["CallKitDialer.swift"],
                       "the CXCallController lives in exactly the dialer file "
                       + "(the submitter)")
    }

    /// The private/undocumented `telprompt:` scheme (a historical
    /// workaround for the very sheet this fix removes) must not sneak
    /// into the dial path — the dialer is CallKit or the public `tel:`.
    func testTheDialerNeverUsesThePrivateTelpromptScheme() throws {
        let dialer = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory(file: #filePath)
                .appendingPathComponent("ElderlyAssistant/Services/Calls/CallKitDialer.swift"))
        XCTAssertFalse(dialer.isEmpty, "the dialer source must be readable")
        XCTAssertFalse(dialer.contains("telprompt"),
                       "the private telprompt: scheme is not a dial path — CallKit "
                       + "is, with the public tel: fallback")
    }

    // MARK: - Helpers (the house patterns twin'd from the sibling suites)

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    private func screensSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/RedesignComponents.swift"))
    }

    /// The text between two code markers — comment-stripped, so the
    /// markers and the pins are code, never prose (the
    /// `CallConfirmationWordingTests.region` convention, verbatim).
    private func region(between start: String, and end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start),
                                       "the source has no `\(start)`")
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
