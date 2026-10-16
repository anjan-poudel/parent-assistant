import SwiftUI
import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-176 — the consent prompt, its sheet and the disclosure (FR-CNR-009,
/// NFR-CNR-009/010; design-l1 §8.4, §14, §17).
///
/// The negative cases carry this task, exactly as the unit's failure table
/// says, and they are the ones a happy-path test would miss:
///
///  - **No timeout, no auto-dismiss, no implicit grant.** The prompt has no
///    timer, its sheet cannot be swiped away, and no lifecycle event is an
///    answer. A test here fails if any of those paths ever appears.
///  - **The pending turn is never lost.** Presenting the question answers
///    the turn on-device through the injected seam in the same call.
///  - **A decline is final for the session.** The decision reads denied, the
///    question is not re-shown, and later turns answer locally.
///  - **A relaunch without an answer is still notRecorded**, and egress is
///    still refused — no hidden default grant exists.
///  - **A write that did not take effect is never a success.** A failed
///    grant leaves the question up and the routing decision refusing; a
///    failed decline still denies and says so.
///  - **An answer outside the live question is not an answer** (a late
///    spoken "yes" cannot flip a recorded "no").
final class CloudChatConsentPromptTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")
    private let consentKey = CloudChatConsentGate.storageKey
    private let recordedAt = Date(timeIntervalSince1970: 1_760_000_000)

    private var bus = LiveTranslateSanitisingBus()
    private var storage = LabelTranslationCacheTestStorage()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        storage = LabelTranslationCacheTestStorage()
    }

    // MARK: - The harness

    /// The two seams the wiring (T-177) supplies, as counters: the local
    /// answer of the turn that arrived at the question, and the offer of the
    /// app's existing spoken yes/no capture.
    private final class PromptSeams {
        private(set) var localAnswers = 0
        private(set) var captureOffers = 0
        func answerLocally() { localAnswers += 1 }
        func offerSpokenCapture() { captureOffers += 1 }
    }

    @MainActor
    private func makeGate(storage: EncryptedLocalStorage? = nil)
        -> CloudChatConsentGate {
        CloudChatConsentGate(storage: storage ?? self.storage,
                             observabilityBus: bus,
                             now: { self.recordedAt })
    }

    @MainActor
    private func makePrompt(locale: Locale? = nil,
                            gate: CloudChatConsentGate? = nil,
                            seams: PromptSeams) -> CloudChatConsentPrompt {
        CloudChatConsentPrompt(gate: gate ?? makeGate(),
                               locale: locale ?? english,
                               startSpokenCapture: { seams.offerSpokenCapture() })
    }

    // MARK: - Scenario: the first cloud chat need presents the disclosure

    @MainActor
    func testTheFirstCloudNeedPresentsTheQuestionAnswersTheTurnLocallyAndSendsNothing() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        XCTAssertFalse(prompt.isPromptPresented,
                       "nothing presents the question at construction or before a cloud need")

        let outcome = prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        })

        XCTAssertEqual(outcome, .awaitingDecision)
        XCTAssertFalse(outcome.allowsEgress, "a pending decision never allows egress")
        XCTAssertTrue(prompt.isPromptPresented, "the question is on screen awaiting an answer")
        XCTAssertEqual(seams.localAnswers, 1,
                       "the pending turn was answered on-device in the same breath — the "
                       + "elder never loses a turn to the question")
        XCTAssertEqual(seams.captureOffers, 1,
                       "the spoken answer is offered with the question: the elder is never "
                       + "required to touch")
        XCTAssertEqual(gate.currentDecision(), .notRecorded,
                       "nothing has been recorded: the question is still a question")
        XCTAssertEqual(storage.writeCount, 0,
                       "no conversation content is sent, and no consent record exists, while "
                       + "the decision is pending")
        XCTAssertTrue(bus.events.isEmpty,
                      "the prompt itself emits nothing; the gate's catalogue is the only "
                      + "evidence and it has nothing to report yet")
    }

    @MainActor
    func testThePendingDecisionKeepsTheRoutingDecisionRefusingEgress() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        _ = prompt.consentNeedDetected(answerPendingTurnLocally: { seams.answerLocally() })

        // The integration that matters: even with every other input a yes,
        // the routing decision (T-173) reads the gate and refuses.
        XCTAssertEqual(CloudChatRouting.decide(consent: gate.currentDecision(),
                                               online: true,
                                               keyConfigured: true,
                                               costAllows: true),
                       .local(reason: .consentNotRecorded),
                       "no chat content may leave the device while the decision is pending")
    }

    @MainActor
    func testTheQuestionIsAskedOnceAndStaysNoMatterHowManyTurnsArrive() {
        let seams = PromptSeams()
        let prompt = makePrompt(seams: seams)

        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        }), .awaitingDecision)
        for _ in 0..<25 {
            XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
                seams.answerLocally()
            }), .awaitingDecision)
        }

        XCTAssertEqual(seams.captureOffers, 1, "the elder is asked once, not once per turn")
        XCTAssertTrue(prompt.isPromptPresented, "no time and no repetition dismisses it")
        XCTAssertEqual(seams.localAnswers, 26,
                       "every pending turn was still answered on-device")
        XCTAssertEqual(storage.writeCount, 0)
    }

    @MainActor
    func testAGrantThatLandedBeforeTheNeedAllowsEgressAndSendsNothingLocal() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        // The race the outcome exists for: the caller's routing decision saw
        // no record, and by the time the need reaches the prompt the elder
        // has granted (from the question the previous turn put up). The turn
        // is no longer blocked on consent, and it is not answered locally as
        // well — serving it twice would be the bug.
        XCTAssertTrue(gate.record(granted: true).isSuccess)

        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        }), .cloudAllowed)
        XCTAssertEqual(seams.localAnswers, 0,
                       "a turn that may egress is not also answered on-device")
        XCTAssertEqual(seams.captureOffers, 0, "no question is put up")
        XCTAssertFalse(prompt.isPromptPresented)
    }

    // MARK: - Scenario: voice answers work

    @MainActor
    func testTheSpokenYesIsRecordedThroughTheGatesOneWriterAsGranted() throws {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})

        XCTAssertEqual(prompt.submitSpokenAnswer(.yes), .recorded)

        XCTAssertEqual(gate.currentDecision(), .granted,
                       "the spoken yes is the elder's grant, through the one writer")
        XCTAssertFalse(prompt.isPromptPresented, "the question is answered and closes")

        let events = bus.events(named: "consent_recorded")
        XCTAssertEqual(events.count, 1, "one answer, one event")
        XCTAssertEqual(events.first?.component, "cloud_chat")
        XCTAssertEqual(bus.observedMetadataKeys(named: "consent_recorded"),
                       ["disclosureVersion"],
                       "classification only: the version stamp and nothing else")
        XCTAssertEqual(events.first?.metadata["disclosureVersion"],
                       CloudChatConsentGate.Config.default.disclosureVersion,
                       "the stamp survives the shipped sanitiser — the evidence is readable "
                       + "and it is the stamp the record carries")

        let stored = try JSONDecoder().decode(
            CloudChatConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey)))
        XCTAssertTrue(stored.granted)

        // Downstream, the turn the question was blocking now may egress.
        XCTAssertEqual(CloudChatRouting.decide(consent: gate.currentDecision(),
                                               online: true,
                                               keyConfigured: true,
                                               costAllows: true),
                       .cloud)
    }

    @MainActor
    func testTheSpokenNoIsRecordedAsDeniedAndClosesTheQuestion() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})

        XCTAssertEqual(prompt.submitSpokenAnswer(.no), .recorded)

        XCTAssertEqual(gate.currentDecision(), .denied)
        XCTAssertFalse(prompt.isPromptPresented)
        XCTAssertEqual(bus.events(named: "consent_denied").count, 1)
        XCTAssertEqual(CloudChatRouting.decide(consent: gate.currentDecision(),
                                               online: true,
                                               keyConfigured: true,
                                               costAllows: true),
                       .local(reason: .consentDenied))
    }

    @MainActor
    func testTheTouchAnswerAndTheSpokenAnswerTakeTheSamePath() throws {
        let touchStorage = LabelTranslationCacheTestStorage()
        let voiceStorage = LabelTranslationCacheTestStorage()
        let touchGate = makeGate(storage: touchStorage)
        let voiceGate = makeGate(storage: voiceStorage)
        let touchPrompt = CloudChatConsentPrompt(gate: touchGate, locale: english,
                                                 startSpokenCapture: {})
        let voicePrompt = CloudChatConsentPrompt(gate: voiceGate, locale: english,
                                                 startSpokenCapture: {})

        XCTAssertEqual(touchPrompt.consentNeedDetected(answerPendingTurnLocally: {}),
                       .awaitingDecision)
        XCTAssertEqual(voicePrompt.consentNeedDetected(answerPendingTurnLocally: {}),
                       .awaitingDecision)

        XCTAssertEqual(touchPrompt.grant(), .recorded)
        XCTAssertEqual(voicePrompt.submitSpokenAnswer(.yes), .recorded)

        XCTAssertEqual(touchGate.currentDecision(), voiceGate.currentDecision(),
                       "one writer, two entry points: the decision cannot differ")
        XCTAssertEqual(touchStorage.bytes(forKey: consentKey),
                       voiceStorage.bytes(forKey: consentKey),
                       "the record is identical whatever asked for it")
        XCTAssertEqual(bus.events(named: "consent_recorded").count, 2,
                       "each answer is evidenced once")
    }

    @MainActor
    func testASpokenAnswerWhenNoQuestionIsLiveIsNotAnAnswer() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        // Never asked, so a yes is answered to nothing.
        XCTAssertEqual(prompt.submitSpokenAnswer(.yes), .questionNotLive)
        XCTAssertEqual(gate.currentDecision(), .notRecorded)
        XCTAssertEqual(storage.writeCount, 0, "nothing was written")

        // Answered already: a late yes cannot flip a recorded no.
        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})
        XCTAssertEqual(prompt.submitSpokenAnswer(.no), .recorded)
        let writesAfterDecline = storage.writeCount

        XCTAssertEqual(prompt.submitSpokenAnswer(.yes), .questionNotLive,
                       "the question is closed; a yes now is not an answer to it")
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the elder's no stays final for the session")
        XCTAssertEqual(storage.writeCount, writesAfterDecline,
                       "and the late yes wrote nothing")
        XCTAssertTrue(bus.events(named: "consent_recorded").isEmpty,
                      "no grant was ever recorded")
    }

    // MARK: - Scenario: a decline is final for the session

    @MainActor
    func testADeclineIsDeniedForTheSessionAndTheQuestionIsNeverReAsked() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        _ = prompt.consentNeedDetected(answerPendingTurnLocally: { seams.answerLocally() })
        XCTAssertEqual(prompt.decline(), .recorded)
        XCTAssertFalse(prompt.isPromptPresented)

        for _ in 0..<10 {
            XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
                seams.answerLocally()
            }), .localOnly(.denied),
                           "the decision reads denied and the prompt is not shown again")
        }

        XCTAssertEqual(seams.localAnswers, 11,
                       "every later turn answers locally — chat keeps working")
        XCTAssertEqual(seams.captureOffers, 1,
                       "the question is never put up again in this session")
        XCTAssertEqual(bus.events(named: "consent_denied").count, 1)
        XCTAssertEqual(CloudChatRouting.decide(consent: gate.currentDecision(),
                                               online: true,
                                               keyConfigured: true,
                                               costAllows: true),
                       .local(reason: .consentDenied))
    }

    @MainActor
    func testAPendingTurnThatArrivesAfterADeclineIsStillAnsweredLocally() {
        let seams = PromptSeams()
        let prompt = makePrompt(seams: seams)

        _ = prompt.consentNeedDetected(answerPendingTurnLocally: { seams.answerLocally() })
        XCTAssertEqual(prompt.decline(), .recorded)

        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        }), .localOnly(.denied))
        XCTAssertEqual(seams.localAnswers, 2,
                       "the turn that arrives after the decline is answered on-device, not "
                       + "dropped and not sent")
    }

    // MARK: - Scenario: a relaunch without an answer stays notRecorded

    @MainActor
    func testARelaunchWithoutAnAnswerIsStillNotRecordedAndEgressIsStillRefused() {
        let seams = PromptSeams()
        let prompt = makePrompt(seams: seams)
        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})
        XCTAssertTrue(prompt.isPromptPresented, "the elder never answered")

        // The "relaunch": a new gate and a new prompt over the same store.
        let relaunchedGate = makeGate()
        let relaunchedSeams = PromptSeams()
        let relaunchedPrompt = makePrompt(gate: relaunchedGate, seams: relaunchedSeams)

        XCTAssertEqual(relaunchedGate.currentDecision(), .notRecorded,
                       "no answer was given, so no record exists — there is no hidden "
                       + "default grant")
        XCTAssertFalse(relaunchedGate.currentDecision().allowsEgress)
        XCTAssertNil(storage.bytes(forKey: consentKey))
        XCTAssertEqual(CloudChatRouting.decide(consent: relaunchedGate.currentDecision(),
                                               online: true,
                                               keyConfigured: true,
                                               costAllows: true),
                       .local(reason: .consentNotRecorded))

        // And the new session asks again, because the question was never answered.
        XCTAssertEqual(relaunchedPrompt.consentNeedDetected(answerPendingTurnLocally: {
            relaunchedSeams.answerLocally()
        }), .awaitingDecision)
        XCTAssertTrue(relaunchedPrompt.isPromptPresented)
    }

    // MARK: - Scenario: a write failure is surfaced, never a success

    @MainActor
    func testAGrantWhoseWriteFailsIsSurfacedAndTheQuestionStaysUp() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)
        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})
        storage.failsWrites = true

        XCTAssertEqual(prompt.grant(), .writeFailed(.writeFailed),
                       "the failure is surfaced to the caller")

        XCTAssertTrue(prompt.isPromptPresented,
                      "the answer did not take effect, so the question is still the truth "
                      + "on screen and the retry stays one tap away")
        XCTAssertEqual(gate.currentDecision(), .notRecorded)
        XCTAssertNil(storage.bytes(forKey: consentKey),
                     "no record is on disk, so none can read back as a grant")
        XCTAssertEqual(bus.events(named: "consent_write_failed").count, 1,
                       "the failure is evidenced as a failure")

        // The next turn keeps refusing egress — with every other input yes.
        XCTAssertEqual(CloudChatRouting.decide(consent: gate.currentDecision(),
                                               online: true,
                                               keyConfigured: true,
                                               costAllows: true),
                       .local(reason: .consentNotRecorded))
        _ = prompt.consentNeedDetected(answerPendingTurnLocally: { seams.answerLocally() })

        // And the store recovering lets the elder's retry land for real.
        storage.failsWrites = false
        XCTAssertEqual(prompt.grant(), .recorded)
        XCTAssertEqual(gate.currentDecision(), .granted)
        XCTAssertFalse(prompt.isPromptPresented)
    }

    @MainActor
    func testAGrantThatLandsAsGarbageIsReportedAsUnreadableAndNeverAsSuccess() {
        let lying = CloudChatPromptGarbageWriteStorage()
        let gate = makeGate(storage: lying)
        let prompt = makePrompt(gate: gate, seams: PromptSeams())

        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})

        XCTAssertEqual(prompt.grant(), .writeFailed(.recordUnreadable),
                       "the write reported success and the record cannot be read back as a "
                       + "grant — that is a failure, not a grant")

        XCTAssertEqual(gate.currentDecision(), .unreadable)
        XCTAssertFalse(gate.currentDecision().allowsEgress)
        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {}),
                       .localOnly(.unreadable),
                       "a record that cannot be read is not a question for the elder — fail "
                       + "closed, answer on-device, ask nothing")
        XCTAssertFalse(prompt.isPromptPresented)
    }

    @MainActor
    func testADeclineWhoseWriteFailsStillDeniesAndClosesTheQuestion() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)
        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})
        storage.failsWrites = true

        XCTAssertEqual(prompt.decline(), .writeFailed(.writeFailed),
                       "the elder is told the decision may not survive a restart")

        XCTAssertFalse(prompt.isPromptPresented, "the elder answered; the question is done")
        XCTAssertEqual(gate.currentDecision(), .denied,
                       "the gate mirrors the no before it writes — the answer stands in "
                       + "this session regardless")
        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        }), .localOnly(.denied))
        XCTAssertTrue(bus.events(named: "consent_write_failed").count == 1)
    }

    // MARK: - The other gate states: no question, answered locally

    @MainActor
    func testAnUnreadableRecordNeverPresentsTheQuestion() {
        storage.setRaw(Data("not a record".utf8), forKey: consentKey)
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)

        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        }), .localOnly(.unreadable))
        XCTAssertFalse(prompt.isPromptPresented,
                       "a corrupt record is a bug to fix, not a question for the elder")
        XCTAssertEqual(seams.captureOffers, 0)
        XCTAssertEqual(seams.localAnswers, 1, "the turn still answers on-device")
        XCTAssertEqual(CloudChatRouting.decide(consent: gate.currentDecision(),
                                               online: true,
                                               keyConfigured: true,
                                               costAllows: true),
                       .local(reason: .consentUnreadable))
    }

    @MainActor
    func testARevocationFromTheOtherSurfacesClosesTheQuestion() {
        let seams = PromptSeams()
        let gate = makeGate()
        let prompt = makePrompt(gate: gate, seams: seams)
        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})
        XCTAssertEqual(prompt.grant(), .recorded)
        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})
        XCTAssertFalse(prompt.isPromptPresented, "a granted decision never puts the question up")

        // The elder revokes from the revocation surfaces (T-177) — the same
        // one writer — while a question would otherwise be relevant.
        XCTAssertTrue(gate.revoke().isSuccess)
        prompt.refreshAfterDecisionChange()

        XCTAssertFalse(prompt.isPromptPresented)
        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        }), .localOnly(.denied),
                       "the withdrawal takes effect on the very next turn, and asking again "
                       + "is a fresh launch's business, not this session's")
        XCTAssertEqual(seams.captureOffers, 1, "revocation is never answered with a question")

        // An explicit re-enable (T-177's other control) writes through the
        // same one writer: the confirmed grant ends the session's deny and
        // the next turn may egress without any question being put back up.
        XCTAssertTrue(gate.record(granted: true).isSuccess)
        prompt.refreshAfterDecisionChange()
        XCTAssertEqual(prompt.consentNeedDetected(answerPendingTurnLocally: {
            seams.answerLocally()
        }), .cloudAllowed,
                       "an explicit re-enable needs no question and no local fallback")
        XCTAssertFalse(prompt.isPromptPresented)
        XCTAssertEqual(seams.captureOffers, 1)
    }

    @MainActor
    func testTheCaptureIsReOfferedOnlyWhileTheQuestionIsUp() {
        let seams = PromptSeams()
        let prompt = makePrompt(seams: seams)

        _ = prompt.consentNeedDetected(answerPendingTurnLocally: {})
        XCTAssertEqual(seams.captureOffers, 1)

        prompt.reofferSpokenAnswer()
        XCTAssertEqual(seams.captureOffers, 2,
                       "the wiring may re-offer the spoken answer for the question that is "
                       + "still up (the capture's window has its own lifetime)")

        XCTAssertEqual(prompt.decline(), .recorded)
        prompt.reofferSpokenAnswer()
        XCTAssertEqual(seams.captureOffers, 2, "no question, nothing to answer by voice")
    }

    // MARK: - Scenario: copy comes from the catalogue in both languages

    @MainActor
    func testEveryStringOnTheSheetComesFromTheCatalogueInBothLanguages() {
        let keys = ["cloud.chat.consent.title", "cloud.chat.consent.body",
                    "cloud.chat.consent.allow", "cloud.chat.consent.notNow"]

        for locale in [english, nepali] {
            let surface = CloudChatConsentSheetSurface(locale: locale)
            XCTAssertEqual(surface.title, L10n.str(keys[0], locale: locale))
            XCTAssertEqual(surface.message, L10n.str(keys[1], locale: locale))
            XCTAssertEqual(surface.actions.map(\.title),
                           [L10n.str(keys[2], locale: locale),
                            L10n.str(keys[3], locale: locale)],
                           "the two answers are the catalogue's answer keys, in order")
            for value in [surface.title, surface.message] + surface.actions.map(\.title) {
                XCTAssertFalse(value.isEmpty,
                               "every string resolves in \(locale.identifier), not to an "
                               + "empty fallback")
            }
        }

        let en = CloudChatConsentSheetSurface(locale: english)
        let ne = CloudChatConsentSheetSurface(locale: nepali)
        XCTAssertNotEqual(en.title, ne.title, "the copy is localised, not fallback English")
        XCTAssertNotEqual(en.message, ne.message)

        XCTAssertEqual(en.actions.map(\.kind), [.allow, .notNow])
        XCTAssertEqual(en.actions.map(\.accessibilityIdentifier),
                       ["cloudchat.consent.allow", "cloudchat.consent.notNow"],
                       "the stable identifiers automation and VoiceOver addressing use")

        // The prompt re-resolves every string when the device language changes.
        let prompt = makePrompt(seams: PromptSeams())
        XCTAssertEqual(prompt.sheetSurface.title, en.title)
        prompt.updateLocale(nepali)
        XCTAssertEqual(prompt.sheetSurface.title, ne.title)
    }

    func testTheSheetCarriesNoComposedOrHardcodedCopy() {
        let sheetCode = sourceText("CloudChatConsentSheet.swift")
        let promptCode = sourceText("CloudChatConsentPrompt.swift")

        for (name, code) in [("CloudChatConsentSheet.swift", sheetCode),
                             ("CloudChatConsentPrompt.swift", promptCode)] {
            XCTAssertEqual(occurrences(of: "%", in: code), 0,
                           "\(name) composes a format argument: the consent family is a "
                           + "zero-slot contract")
        }

        for key in ["cloud.chat.consent.title", "cloud.chat.consent.body",
                    "cloud.chat.consent.allow", "cloud.chat.consent.notNow"] {
            XCTAssertEqual(occurrences(of: NSRegularExpression.escapedPattern(for: key),
                                       in: sheetCode),
                           1,
                           "\(key) must be resolved from the catalogue by the sheet, once")
        }
    }

    // MARK: - Scenario: the doctrine holds (no timeout, no dismissal, no grant)

    func testNoTimeoutNoAutoDismissAndNoImplicitGrantPathExists() {
        let sheetCode = sourceText("CloudChatConsentSheet.swift")
        let promptCode = sourceText("CloudChatConsentPrompt.swift")

        // The doctrine's failure path, pinned: an implementation that
        // dismisses the prompt after a timeout, or treats a dismissal, a
        // backgrounding or a screen change as an answer, fails here.
        for (name, code) in [("CloudChatConsentSheet.swift", sheetCode),
                             ("CloudChatConsentPrompt.swift", promptCode)] {
            for pattern in ["Timer", "asyncAfter", "Task\\.sleep", "withTimeout", "deadline",
                            "autoDismiss", "dismissAfter", "onDismiss", "presentationMode",
                            "\\bdismiss\\b", "scenePhase", "NotificationCenter",
                            "willResignActive", "didEnterBackground", "\\.onChange",
                            "onAppear", "\\.task"] {
                XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                             "\(name) contains '\(pattern)': the question is a blocking "
                             + "decision — a dismissal, a timeout or a lifecycle event must "
                             + "never be able to answer it")
            }
        }

        XCTAssertEqual(occurrences(of: "interactiveDismissDisabled\\(true\\)", in: sheetCode), 1,
                       "the sheet must forbid the interactive dismissal that would otherwise "
                       + "close the question without an answer")

        // A grant can be produced by exactly one expression, reached from the
        // two answer controls — there is no default, no configuration value
        // and no other path that writes a consent record.
        XCTAssertEqual(occurrences(of: "gate\\.record\\(", in: promptCode), 1,
                       "the answer path reaches the gate's one writer exactly once")
        XCTAssertEqual(occurrences(of: "answer\\(granted: true\\)", in: promptCode), 1)
        XCTAssertEqual(occurrences(of: "answer\\(granted: false\\)", in: promptCode), 1)
    }

    @MainActor
    func testTheQuestionHasExactlyOnePresentationEntryAndNoOtherHook() {
        let promptCode = sourceText("CloudChatConsentPrompt.swift")

        let seams = PromptSeams()
        let prompt = makePrompt(seams: seams)
        XCTAssertFalse(prompt.isPromptPresented)

        XCTAssertEqual(occurrences(of: "isPromptPresented = true", in: promptCode), 1,
                       "presentation has exactly one site, inside consentNeedDetected")
        for pattern in ["func sessionStarted", "func viewDidAppear", "func applicationDid",
                        "func launch", "func onScene"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: promptCode),
                         "the prompt has a \(pattern)-shaped hook: it must be reachable only "
                         + "from the routing decision of a chat-classified turn")
        }
    }

    // MARK: - Structure: no transport, no content, no extra state

    func testThePromptHoldsNoTransportNoModelAndNoContentParameter() {
        let promptCode = sourceText("CloudChatConsentPrompt.swift")

        for token in ["URLSession", "Gemini", "Model", "Engine", "Encoder", "Whisper",
                      "print\\(", "transcript", "utterance", "String"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: token, in: promptCode),
                         "CloudChatConsentPrompt.swift mentions '\(token)': the prompt must "
                         + "have no transport, no model and nothing a transcript could "
                         + "travel through")
        }

        let sheetCode = sourceText("CloudChatConsentSheet.swift")
        for token in ["URLSession", "Gemini", "print\\("] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: token, in: sheetCode),
                         "CloudChatConsentSheet.swift mentions '\(token)'")
        }
    }

    @MainActor
    func testThePromptStateIsTheGateAndTheQuestionOnly() throws {
        let prompt = makePrompt(seams: PromptSeams())
        // `@Published` reflects as its backing storage, `_name`; the property
        // the type exposes is the same field.
        let labels = Mirror(reflecting: prompt).children.compactMap(\.label)
            .map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
            .sorted()
        XCTAssertEqual(labels,
                       ["gate", "isPromptPresented", "locale", "startSpokenCapture"],
                       "the prompt holds no grant of its own: the gate is the single source "
                       + "of the decision, and presentation is the only state it adds")
        XCTAssertFalse(prompt.isPromptPresented,
                       "and the only state it adds starts false: no question until a need")
    }

    // MARK: - Accessibility: the sheet's own DoD

    @MainActor
    func testTheSheetRendersTwoFullTapTargetAnswersAndFollowsTheHouseTypography() throws {
        let surface = CloudChatConsentSheetSurface(locale: english)
        let sheetCode = sourceText("CloudChatConsentSheet.swift")

        XCTAssertGreaterThanOrEqual(AppAppearance.default.typography.bodyPointSize, 18,
                                    "body text keeps the app's 18 pt floor")
        XCTAssertEqual(occurrences(of: "appearance\\.typography\\.bodyPointSize", in: sheetCode),
                       3,
                       "the heading, the disclosure and both answers take the environment's "
                       + "large-type-aware body size — no literal point size is pinned anywhere")
        XCTAssertEqual(occurrences(of: "minHeight: DesignTokens.minTapTargetSize", in: sheetCode),
                       1,
                       "the one button construction both answers come through takes the full "
                       + "44 pt tap target — equal reachability is structural, not copied "
                       + "onto two hand-kept buttons")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "lineLimit", in: sheetCode),
                     "the copy must never be truncated at large type")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\.font\\(\\.system\\(size:",
                                                  in: sheetCode),
                     "no fixed system point size: the house typography resolves the size")
        XCTAssertEqual(occurrences(of: "actionButton\\(", in: sheetCode), 2,
                       "one builder, one call site: both answers are built by the same code")
        XCTAssertEqual(occurrences(of: "ForEach\\(surface\\.actions", in: sheetCode), 1)

        for forbidden in ["borderedProminent", "keyboardShortcut", "buttonRole", "destructive",
                          "isDefault", "isPrimary", "preferred"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: sheetCode),
                         "CloudChatConsentSheet.swift uses '\(forbidden)': neither answer may "
                         + "be styled, shortcut or marked as the expected one")
        }

        let image = try XCTUnwrap(render(surface), "the sheet rendered nothing")
        let runs = try accentRowRuns(in: image)
        XCTAssertEqual(runs.count, 2,
                       "two full-height answers are drawn; runs measured: \(runs)")
        let minimum = Int(DesignTokens.minTapTargetSize * image.scale) - 4
        for run in runs {
            XCTAssertGreaterThanOrEqual(run, minimum,
                                        "an answer is only \(run)px tall at scale "
                                        + "\(image.scale): the two must be equally reachable")
        }
    }

    // MARK: - Rendering helpers (the shipped consent-prompt measurement)

    @MainActor
    private func render(_ surface: CloudChatConsentSheetSurface, width: CGFloat = 360) -> UIImage? {
        let renderer = ImageRenderer(
            content: CloudChatConsentSheet(surface: surface, onAllow: {}, onNotNow: {})
                .environment(\.appAppearance, AppAppearance(skin: .sky, style: .classic))
                .frame(width: width))
        renderer.scale = 2
        return renderer.uiImage
    }

    /// The heights, in pixels, of the contiguous bands where the accent colour
    /// is drawn — one per answer button. The accessibility tree is not
    /// readable in a unit-test host, so equal reachability is asserted on the
    /// geometry the elder actually gets.
    private func accentRowRuns(in image: UIImage) throws -> [Int] {
        let pixels = try pixelBytes(of: image)
        // Measure the answers' shared fill, independent of the selected skin.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(UIColor(AppAppearance.default.colors.accent)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let accent = (r: Int((red * 255).rounded()),
                      g: Int((green * 255).rounded()),
                      b: Int((blue * 255).rounded()))
        var runs: [Int] = []
        var current = 0
        for row in 0..<pixels.height {
            var hasAccent = false
            for column in 0..<pixels.width {
                let offset = (row * pixels.width + column) * 4
                if abs(Int(pixels.bytes[offset]) - accent.r) <= 2,
                   abs(Int(pixels.bytes[offset + 1]) - accent.g) <= 2,
                   abs(Int(pixels.bytes[offset + 2]) - accent.b) <= 2 {
                    hasAccent = true
                    break
                }
            }
            if hasAccent {
                current += 1
            } else if current > 0 {
                runs.append(current)
                current = 0
            }
        }
        if current > 0 { runs.append(current) }
        return runs
    }

    private func pixelBytes(of image: UIImage) throws -> (bytes: [UInt8], width: Int,
                                                          height: Int, scale: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage, "the rendering has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height, image.scale)
    }

    // MARK: - Source helpers

    /// One of this unit's production files, found by name under the
    /// feature's own sources — `Views/` included, and a name that matches
    /// nothing fails loudly instead of scanning an empty string.
    private func sourceText(_ name: String) -> String {
        let matches = FeatureSourceScan
            .swiftFiles(in: "ElderlyAssistant/Services/Intents/CloudChat")
            .filter { $0.lastPathComponent == name }
        guard matches.count == 1, let url = matches.first else {
            XCTFail("expected exactly one \(name) under the feature sources, found "
                    + "\(matches.count): a scan that reads nothing proves nothing")
            return ""
        }
        return FeatureSourceScan.codeText(of: url)
    }

    private func occurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return 0
        }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: whole)
    }
}

/// A store whose write reports success and lands bytes no reader can decode —
/// the read-back failure the gate reports as `.recordUnreadable`. The
/// byte-level double cannot express it (it either stores what it was given or
/// fails honestly), and it is the case a prompt must never call a grant.
private final class CloudChatPromptGarbageWriteStorage: EncryptedLocalStorage, RawEncryptedStorage {

    private var raw: [String: Data] = [:]

    func bytes(forKey key: String) -> Data? { raw[key] }

    // MARK: - EncryptedLocalStorage

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        raw[key] = Data("not a record".utf8)
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = raw[key],
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return .failure(.encryptedReadFailed)
        }
        return .success(value)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        raw.removeValue(forKey: key)
        return .success(())
    }

    // MARK: - RawEncryptedStorage

    func readRawData(key: String) -> Data? { raw[key] }

    func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError> {
        raw[key] = data
        return .success(())
    }
}
