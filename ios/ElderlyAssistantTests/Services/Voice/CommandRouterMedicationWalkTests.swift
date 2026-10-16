import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [MED-ACK-WALK] (T-014) Router-level tests for the acknowledgement
/// resolution call and the clarification walk's interception placement
/// (C4 router half, R-4):
///
/// - `handleMedicationAcknowledgement` resolves through the REAL T-004
///   resolver over the coordinator's candidates (IF-7): a named entry
///   resolves to what the elder said (never firing or pending order), a
///   simple acknowledgement with several candidates opens the walk with
///   the sanctioned copy, `.nothingPending` keeps the shipped line and
///   `.unmatched` answers honestly with nothing recorded.
/// - The walk consult is the sibling immediately ahead of the shipped
///   confirmation block, and the two risk-5 guards hold: होइन inside a
///   walk never reaches the challenge handler, and an acknowledgement
///   inside a walk restarts resolution (it is never consumed as a
///   yes/no).
///
/// The double `WalkCoordinator` scripts the T-013 seam contract (IF-7 +
/// IF-8) and records every seam call — the walk's own state machine,
/// copy and lines are pinned by `MedicationAckClarificationTests`; this
/// suite pins the ROUTER half: which seam is called, with what, and
/// which seam is deliberately never reached. The resolver is the real
/// implementation — nothing about resolution is mocked here.
final class CommandRouterMedicationWalkTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Fakes

    /// Records every walk/ack seam the router touches and scripts the
    /// walk responses per test. `isAwaitingConfirmation` is the REAL
    /// OR-fold (challenge open ∨ walk open) so the refusal fall-through
    /// is exercised against the same flag the shipped block reads.
    private final class WalkCoordinator: VoiceCommandCoordinating {
        var manualAwaitingConfirmation = false
        var walkOpen = false
        var isAwaitingConfirmation: Bool { manualAwaitingConfirmation || walkOpen }

        var brainReadiness = BrainReadiness.available
        var isAwaitingCallConfirmation = false
        var activeLocale = Locale(identifier: "ne-NP")

        // [MED-ACK] scripted pending state
        var candidates: [MedicationAckCandidate] = []
        var oldestPending: UUID?
        var challengePrompt: String? = "औषधि खानुभयो?"   // the shipped test prompt
        private(set) var challengeIssuedFor: UUID?
        private(set) var recordedAckEntryIds: [UUID] = []
        private(set) var confirmationResponses: [ConfirmationResponse] = []
        private(set) var assistantSpokenTexts: [String] = []
        private(set) var genericReplies: [String] = []

        // [MED-ACK-WALK] seam logs
        private(set) var beginCalls: [[MedicationAckCandidate]] = []
        private(set) var responseCalls: [(raw: String, isYes: Bool, isNo: Bool)] = []
        private(set) var endCalls: [AckClarifyEndReason] = []
        /// Scripted walk answers; nil (no script) ⇒ `.unanswered`.
        var responseScript: ((String, Bool, Bool) -> AckClarifyOutcome)?

        // Required minimal conformance (the StubCoordinator pattern).
        func recordTranscript(_ text: String) {}
        func oldestPendingReminderEntryId() -> UUID? { oldestPending }
        func handleMedicationAcknowledgement(entryId: UUID) { recordedAckEntryIds.append(entryId) }
        func startVoiceAckConfirmation(for entryId: UUID) -> String? {
            challengeIssuedFor = entryId
            return challengePrompt
        }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {
            confirmationResponses.append(response)
        }
        func noteSpeakingStarted() {}
        func noteSpeakingEnded() {}
        func noteAssistantSpoke(_ text: String) { assistantSpokenTexts.append(text) }
        func noteGenericReply(_ text: String) { genericReplies.append(text) }
        var profilePersonalization: ProfilePersonalizationReading?
        func addVoiceReminder(title: String, time: DateComponents) {}
        func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                     sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? {
            nil
        }
        func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
        func composeMessage(toContactNamed name: String?, body: String,
                            requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
        func presentPluginView(_ view: AnyView) {}
        func requestContactSearch(query: String?) {}
        var pendingRephraseCommand: InterpretedCommand? { nil }
        func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {}
        func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
        var calendarEventPrompt: String? = nil
        func requestCalendarEventConfirmation(title: String, startDate: Date) -> String? {
            calendarEventPrompt
        }

        // [MED-ACK-WALK] IF-7 + IF-8 seams under test.
        func medicationAckCandidates() -> [MedicationAckCandidate] { candidates }
        var isAwaitingAckClarification: Bool { walkOpen }
        func beginAckClarification(orderedCandidates: [MedicationAckCandidate]) {
            beginCalls.append(orderedCandidates)
            if !orderedCandidates.isEmpty { walkOpen = true }
        }
        @discardableResult
        func ackClarificationResponse(raw: String, isYes: Bool, isNo: Bool) -> AckClarifyOutcome {
            responseCalls.append((raw, isYes, isNo))
            let outcome = responseScript?(raw, isYes, isNo) ?? .unanswered
            switch outcome {
            case .resolved, .ended:
                // T-013's contract: both ends clear the walk inside the op.
                walkOpen = false
            default:
                break
            }
            return outcome
        }
        func endAckClarification(reason: AckClarifyEndReason) {
            endCalls.append(reason)
            walkOpen = false
        }
    }

    private final class WalkSpeaker: Speaker {
        private(set) var utterances: [(text: String, locale: Locale)] = []
        func speak(_ text: String, locale: Locale) async { utterances.append((text, locale)) }
        func cancel() {}
    }

    // MARK: - Harness

    private func makeRouter(_ coordinator: WalkCoordinator)
        -> (CommandRouter, WalkSpeaker, RecordingObservabilityBus) {
        let speaker = WalkSpeaker()
        let bus = RecordingObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: NullCommandInterpreter())
        return (router, speaker, bus)
    }

    private func waitForAsyncSpeak() {
        let exp = expectation(description: "async speak settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
    }

    /// Two pending morning reminders, Amlodipine EARLIER and fired,
    /// Metformin later and not fired — the old oldest-pending path would
    /// have picked Amlodipine; resolution must go by what was said.
    private func morningPair() -> (amlodipine: MedicationAckCandidate,
                                   metformin: MedicationAckCandidate) {
        let amlodipine = MedicationAckCandidate(
            entryId: UUID(),
            scheduledAt: Date(timeIntervalSince1970: 1_000),
            fired: true,
            slot: .morning,
            voiceKeys: ["amlodipine"],
            medicationName: "Amlodipine")
        let metformin = MedicationAckCandidate(
            entryId: UUID(),
            scheduledAt: Date(timeIntervalSince1970: 2_000),
            fired: false,
            slot: .morning,
            voiceKeys: ["metformin"],
            medicationName: "Metformin")
        return (amlodipine, metformin)
    }

    private func text(_ key: String) -> String { L10n.str(key, locale: ne) }

    // MARK: - Gherkin 1: the named medication and slot resolve to it

    func testNamedMedicationAndSlotResolvesToNamedEntry() {
        let coordinator = WalkCoordinator()
        let pair = morningPair()
        coordinator.candidates = [pair.amlodipine, pair.metformin]
        coordinator.oldestPending = pair.amlodipine.entryId
        let (router, speaker, bus) = makeRouter(coordinator)

        // "I have taken Metformin for morning" — the named, not the fired,
        // not the oldest.
        let result = router.route(transcript: "i have taken metformin for morning")
        waitForAsyncSpeak()

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.challengeIssuedFor, pair.metformin.entryId,
                       "the shipped safety sequence runs for the NAMED entry")
        XCTAssertNotEqual(coordinator.challengeIssuedFor, pair.amlodipine.entryId,
                          "firing order and pending order never select the entry")
        XCTAssertEqual(coordinator.beginCalls.count, 0, "a resolution opens no walk")
        XCTAssertTrue(speaker.utterances.contains {
            $0.text == coordinator.challengePrompt
        }, "the challenge prompt is the spoken line")
        let resolved = bus.events(named: "medication_ack_resolved").first
        XCTAssertNotNil(resolved, "the resolution is observed")
        XCTAssertEqual(resolved?.component, "command_router")
        XCTAssertEqual(resolved?.metadata["entry_id_hash"],
                       IdHashing.shortHash(of: pair.metformin.entryId),
                       "PII-free: the entry id HASH, never the id or a name")
        XCTAssertEqual(resolved?.metadata.count, 1,
                       "the entry id hash is the ONLY metadata")
    }

    // MARK: - Gherkin 2: a simple ack with several sharing the slot opens
    // the walk with the sanctioned copy

    func testAmbiguousSimpleAckOpensWalkWithSanctionedCopy() {
        let coordinator = WalkCoordinator()
        let pair = morningPair()
        // Both fired: a simple ack with no name and no slot cannot be
        // narrowed — the walk decides (never firing order, never a guess).
        let amlodipine = firedCopy(pair.amlodipine)
        let metformin = firedCopy(pair.metformin)
        coordinator.candidates = [amlodipine, metformin]
        let (router, speaker, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "taken")
        waitForAsyncSpeak()

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.beginCalls.count, 1,
                       "the ambiguous acknowledgement opens the walk")
        XCTAssertEqual(coordinator.beginCalls.first, [amlodipine, metformin],
                       "the walk gets exactly the resolver's candidates in its fixed order")
        XCTAssertTrue(coordinator.beginCalls.first?.count == 2)
        XCTAssertTrue(coordinator.walkOpen, "the walk stays open for the answer")
        XCTAssertNil(coordinator.challengeIssuedFor,
                     "nothing is challenged or recorded until the clarification resolves")
        XCTAssertTrue(coordinator.recordedAckEntryIds.isEmpty,
                      "no medication is chosen by firing order")
        XCTAssertTrue(coordinator.assistantSpokenTexts.isEmpty,
                      "the sanctioned question is the coordinator's own op to speak — the router adds no copy")
        XCTAssertTrue(speaker.utterances.isEmpty,
                      "the router never speaks the clarification copy itself")
        XCTAssertEqual(bus.events(named: "medication_ack_ambiguous").count, 1)
    }

    /// The same candidate with `fired` flipped — the simple-ack narrowing
    /// fixture (both fired ⇒ the fired preference cannot decide).
    private func firedCopy(_ candidate: MedicationAckCandidate) -> MedicationAckCandidate {
        MedicationAckCandidate(entryId: candidate.entryId,
                               scheduledAt: candidate.scheduledAt,
                               fired: true,
                               slot: candidate.slot,
                               voiceKeys: candidate.voiceKeys,
                               medicationName: candidate.medicationName)
    }

    // MARK: - Gherkin 4 (risk 5): an acknowledgement inside a walk restarts
    // resolution and is never consumed as a yes/no

    func testAcknowledgementInsideWalkRestartsResolution() {
        let coordinator = WalkCoordinator()
        let pair = morningPair()
        coordinator.candidates = [pair.amlodipine, pair.metformin]
        coordinator.walkOpen = true
        let (router, _, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "i have taken metformin for morning")
        waitForAsyncSpeak()

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.endCalls, [.bargedIn],
                       "the open walk is ended first, honestly as a barge-in")
        XCTAssertTrue(coordinator.responseCalls.isEmpty,
                      "the utterance is not consumed as a yes or a no")
        XCTAssertEqual(coordinator.challengeIssuedFor, pair.metformin.entryId,
                       "resolution restarts against the pending set and finds the named entry")
        XCTAssertEqual(bus.events(named: "medication_ack_resolved").count, 1)
    }

    // MARK: - Gherkin 3 (risk 5): होइन inside a walk never reaches the
    // challenge handler

    func testHoinInsideWalkNeverReachesChallengeHandler() {
        let coordinator = WalkCoordinator()
        coordinator.walkOpen = true
        coordinator.responseScript = { _, isYes, isNo in
            XCTAssertFalse(isYes, "होइन is a no verdict, never a yes")
            XCTAssertTrue(isNo, "the shipped classifier owns the verdict")
            return .ended(reason: .rejected)
        }
        let (router, speaker, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "होइन")
        waitForAsyncSpeak()

        XCTAssertEqual(result, .unrecognised(transcript: "होइन"))
        XCTAssertEqual(coordinator.responseCalls.count, 1,
                       "the walk owns the utterance")
        XCTAssertEqual(coordinator.responseCalls.first?.raw, "होइन")
        XCTAssertTrue(coordinator.confirmationResponses.isEmpty,
                      "the challenge handler never sees the utterance")
        XCTAssertNil(coordinator.challengeIssuedFor)
        XCTAssertTrue(coordinator.recordedAckEntryIds.isEmpty,
                      "no acknowledgement is recorded")
        XCTAssertTrue(coordinator.assistantSpokenTexts.isEmpty,
                      "the walk's own ended line is the coordinator's to speak")
        XCTAssertTrue(bus.events(named: "confirmation_no").isEmpty,
                      "the shipped generic no arm never ran")
        XCTAssertTrue(bus.events(named: "confirmation_ambiguous").isEmpty,
                      "nor the generic re-prompt")
        XCTAssertTrue(bus.events(named: "medication_ack_resolved").isEmpty)
    }

    // MARK: - Gherkin: true inside a walk resolves through the shipped chain

    func testTrueInsideWalkResolvesThroughShippedChain() {
        let coordinator = WalkCoordinator()
        let pair = morningPair()
        coordinator.candidates = [pair.amlodipine, pair.metformin]
        coordinator.walkOpen = true
        coordinator.responseScript = { _, isYes, isNo in
            XCTAssertTrue(isYes, "yes reaches the walk as a yes verdict")
            XCTAssertFalse(isNo)
            return .resolved(entryId: pair.metformin.entryId)
        }
        let (router, speaker, bus) = makeRouter(coordinator)

        let result = router.route(transcript: "yes")
        waitForAsyncSpeak()

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.responseCalls.count, 1)
        XCTAssertEqual(coordinator.challengeIssuedFor, pair.metformin.entryId,
                       "the resolved entry continues through startVoiceAckConfirmation")
        XCTAssertTrue(speaker.utterances.contains { $0.text == coordinator.challengePrompt },
                      "the shipped challenge prompt is spoken")
        XCTAssertTrue(coordinator.recordedAckEntryIds.isEmpty,
                      "recording waits for the challenge answer, as shipped")
        XCTAssertEqual(bus.events(named: "command_ack_challenge_issued").count, 1)
        XCTAssertTrue(coordinator.endCalls.isEmpty,
                      "a resolution ends the walk inside the coordinator's own op")
    }

    // MARK: - Gherkin: nothing pending keeps the shipped line

    func testNothingPendingKeepsShippedLine() {
        // (a) No candidates and no oldest — the shipped no-pending leg,
        // byte for byte.
        let empty = WalkCoordinator()
        let (emptyRouter, emptySpeaker, emptyBus) = makeRouter(empty)
        _ = emptyRouter.route(transcript: "taken")
        waitForAsyncSpeak()

        XCTAssertEqual(emptySpeaker.utterances.last?.text, text("router.noPendingReminder"),
                       "the shipped line is kept")
        XCTAssertEqual(empty.assistantSpokenTexts, [text("router.noPendingReminder")],
                       "the no-pending line is the only utterance the router commits")
        XCTAssertEqual(emptyBus.events(named: "command_ack_no_pending").count, 1)
        XCTAssertNil(empty.challengeIssuedFor)

        // (b) The C12 fallback: a conformer with an oldest read but no
        // candidate read (the inert default) still gets the shipped
        // challenge chain — the pre-T-014 behaviour, byte-identically.
        let legacy = WalkCoordinator()
        legacy.candidates = []
        legacy.oldestPending = UUID()
        let (legacyRouter, _, legacyBus) = makeRouter(legacy)
        _ = legacyRouter.route(transcript: "taken")
        waitForAsyncSpeak()

        XCTAssertEqual(legacy.challengeIssuedFor, legacy.oldestPending,
                       "the fallback selects the oldest pending reminder, as shipped")
        XCTAssertEqual(legacyBus.events(named: "command_ack_challenge_issued").count, 1)
        XCTAssertTrue(legacyBus.events(named: "command_ack_no_pending").isEmpty)
    }

    // MARK: - Gherkin: a slot named with nothing pending there answers
    // honestly (no walk, no recording)

    func testUnmatchedProducesHonestLine() {
        let coordinator = WalkCoordinator()
        let evening = MedicationAckCandidate(
            entryId: UUID(),
            scheduledAt: Date(timeIntervalSince1970: 3_000),
            fired: false,
            slot: .evening,
            voiceKeys: ["metformin"],
            medicationName: "Metformin")
        coordinator.candidates = [evening]
        let (router, speaker, bus) = makeRouter(coordinator)

        // "औषधि खाएँ बिहान" — a taken-ack naming the morning slot, which
        // has nothing pending (only the evening dose is).
        let result = router.route(transcript: "औषधि खाएँ बिहान")
        waitForAsyncSpeak()

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertTrue(speaker.utterances.contains { $0.text == text("meds.ack.clarifyEnded") },
                      "the honest no-match line is spoken")
        XCTAssertFalse(speaker.utterances.contains { $0.text == text("router.noPendingReminder") },
                       "the no-pending line would lie — other slots ARE pending")
        XCTAssertEqual(bus.events(named: "medication_ack_unmatched").count, 1)
        XCTAssertTrue(bus.events(named: "medication_ack_ambiguous").isEmpty)
        XCTAssertTrue(coordinator.beginCalls.isEmpty, "nothing to walk over — no walk opens")
        XCTAssertNil(coordinator.challengeIssuedFor)
        XCTAssertTrue(coordinator.recordedAckEntryIds.isEmpty, "nothing is recorded")
    }

    // MARK: - Definition of done: denial ordering unchanged — a denial with
    // ack-like tokens stays a denial, inside a walk and outside it

    func testDenialGuardOrderUnchanged() {
        // The mixed utterance: "औषधि खाए" (an ack phrase) sits INSIDE
        // "औषधि खाएको छैन" — without the refusal-first guard it would be
        // an acknowledgement.
        let denial = "औषधि खाएको छैन"
        XCTAssertFalse(CommandRouter.isExplicitMedicationAcknowledgement(denial),
                       "a denial with ack-like tokens is never an acknowledgement")

        // (a) No walk: the refusal ladder's denial arm answers; the ack
        // path is never entered.
        let standalone = WalkCoordinator()
        let pair = morningPair()
        standalone.candidates = [pair.amlodipine, pair.metformin]
        standalone.oldestPending = pair.amlodipine.entryId
        let (routerA, speakerA, busA) = makeRouter(standalone)

        let resultA = routerA.route(transcript: denial)
        waitForAsyncSpeak()

        XCTAssertEqual(resultA, .unrecognised(transcript: denial))
        XCTAssertTrue(speakerA.utterances.contains { $0.text == text("router.ackDenied") })
        XCTAssertEqual(busA.events(named: "command_ack_denied_keyword").count, 1)
        XCTAssertNil(standalone.challengeIssuedFor, "no challenge for a denial")
        XCTAssertTrue(standalone.beginCalls.isEmpty)
        XCTAssertTrue(standalone.recordedAckEntryIds.isEmpty)

        // (b) Inside a walk: the refusal ends the walk `.denied` and falls
        // through to the ladder unchanged — the walk's end flips the
        // confirmation flag, so the shipped block cannot swallow it and
        // the challenge handler never sees the utterance (risk 5).
        let walking = WalkCoordinator()
        walking.candidates = [pair.amlodipine, pair.metformin]
        walking.walkOpen = true
        let (routerB, speakerB, busB) = makeRouter(walking)

        let resultB = routerB.route(transcript: denial)
        waitForAsyncSpeak()

        XCTAssertEqual(resultB, .unrecognised(transcript: denial))
        XCTAssertEqual(walking.endCalls, [.denied], "the walk ends as denied")
        XCTAssertTrue(walking.responseCalls.isEmpty,
                      "the refusal is not consumed as a walk answer")
        XCTAssertTrue(walking.confirmationResponses.isEmpty,
                      "the challenge handler never sees the utterance")
        XCTAssertNil(walking.challengeIssuedFor)
        XCTAssertTrue(walking.recordedAckEntryIds.isEmpty, "no acknowledgement is recorded")
        XCTAssertTrue(speakerB.utterances.contains { $0.text == text("router.ackDenied") },
                      "the refusal-first ladder handles the refusal")
        XCTAssertEqual(busB.events(named: "command_ack_denied_keyword").count, 1)
        XCTAssertTrue(busB.events(named: "confirmation_no").isEmpty)
    }

    // MARK: - N-4: the walk consumes every other utterance; the generic
    // ambiguous re-prompt is unreachable while it is open

    func testWalkConsumesNonYesNoUtterancesPerShippedReprompt() {
        let coordinator = WalkCoordinator()
        coordinator.walkOpen = true
        coordinator.responseScript = { _, isYes, isNo in
            XCTAssertFalse(isYes, "a non-yes/no answer is not a yes")
            XCTAssertFalse(isNo, "nor a no")
            return .unanswered   // the coordinator re-asks its sanctioned question
        }
        let (router, speaker, bus) = makeRouter(coordinator)

        let utterance = "आज मौसम कस्तो छ"
        let result = router.route(transcript: utterance)
        waitForAsyncSpeak()

        XCTAssertEqual(result, .unrecognised(transcript: utterance))
        XCTAssertEqual(coordinator.responseCalls.count, 1,
                       "the walk consumes the utterance — it never reaches the interpreter")
        XCTAssertEqual(coordinator.responseCalls.first?.raw, utterance)
        XCTAssertTrue(coordinator.walkOpen, "the walk stays open — its own re-ask is the voice")
        XCTAssertTrue(coordinator.assistantSpokenTexts.isEmpty,
                      "the router speaks nothing on the walk's behalf")
        XCTAssertTrue(bus.events(named: "confirmation_ambiguous").isEmpty,
                      "the generic ambiguous re-prompt is unreachable during a walk (N-4)")
        XCTAssertFalse(speaker.utterances.contains { $0.text == text("router.confirmationAmbiguous") })
        XCTAssertTrue(coordinator.confirmationResponses.isEmpty)
    }
}
