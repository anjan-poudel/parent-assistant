import Foundation

// T-176 — the consent prompt's lifecycle for cloud chat (design-l1 §8.4,
// §14; FR-CNR-009, NFR-CNR-009/010). The third feature to carry the shipped
// consent-prompt doctrine (`ConsentPromptController`, then PointAsk's
// `.consentPending` sheet), and the doctrine is the point of this file:
//
//  - **A blocking decision, with no way out but an answer.** There is no
//    timer, no auto-dismiss, no "dismissed means yes". A dismissal, a
//    backgrounding or a screen change is not an answer: nothing in this file
//    observes any of them, `isPromptPresented` falls only when the gate has a
//    decision, and the sheet's own file forbids the interactive dismissal
//    that would otherwise be an implicit consent. A failure to persist an
//    answer is NOT an answer either — the elder's "yes" that did not reach
//    storage leaves the question exactly where it was, and the routing
//    decision keeps refusing egress (design §8.4, AM-4 ordering).
//
//  - **Asked where the question becomes real, never earlier.** The ONE entry
//    point is `consentNeedDetected` — called when a chat turn's routing
//    decision reports that the consent answer is what is missing. Nothing
//    here fires at launch, in Settings navigation or speculatively, and this
//    file contains no session/UI lifecycle hook to fire from: a stranger's
//    utterance cannot reach the question without a chat-classified turn
//    having produced the routing decision first (FR-CNR-009, and the
//    recorded Gemini-stack transcription exception the design keeps).
//
//  - **The turn is never blocked by the question.** The pending turn is
//    answered by the local chat path in the same breath the question is
//    presented: the caller hands its local answer in as the injected seam
//    (`answerPendingTurnLocally` — the routing lane and the coordinator own
//    what "local" means for their surface, T-175/T-177) and this type runs
//    it unless the turn may egress. So "answered while the decision is
//    pending" is a property of the call, not a convention the wiring could
//    forget: a turn can be neither held nor dropped waiting for the elder.
//
//  - **The answer is the elder's, through the one writer.** Both paths —
//    the sheet's controls and the existing spoken-confirmation capture —
//    arrive at the gate's single `record(granted:)`; this type has no
//    storage access of its own, no second preference and no configuration
//    value that could produce a grant. A spoken yes/no applies only while
//    the question is live: an answer that arrives when no question is on
//    screen is not an answer to it, and nothing is written (declared, not
//    quiet — the caller gets `questionNotLive`). A decline closes the
//    question for the session and is never re-asked automatically; only an
//    explicit revocation / re-enable or an app-level reset can put the
//    record back to "not decided" (the gate's own reading).
//
//  - **No content anywhere, structurally.** No method here takes text; the
//    prompt never sees the transcript, and the sheet renders catalogue keys
//    only. This type emits no observability events of its own — the gate's
//    classification-only catalogue is the evidence for a recorded decision,
//    and the prompt has nothing content-bearing to add to it (NFR-CNR-006).
//
// `@MainActor` because every consumer is a view and because serialising the
// presentation state is what makes "exactly one question" structural, the
// shipped `ConsentPromptController`'s own reason.

@MainActor
final class CloudChatConsentPrompt: ObservableObject {

    // MARK: - What a cloud need turned into

    /// What one `consentNeedDetected` call decided about the turn.
    enum Outcome: Equatable {

        /// Consent is in force for the current disclosure version: the
        /// routing decision re-read now returns `.cloud` (the race where an
        /// answer landed between the caller's decision and this call). The
        /// pending turn was NOT answered locally — it may egress — and the
        /// local-answer seam was not run.
        case cloudAllowed

        /// The question is on screen and the elder has not answered. The
        /// pending turn was answered on-device through the injected seam
        /// before this returned, and no chat content may be sent while the
        /// decision is pending.
        case awaitingDecision

        /// Consent is not in force and the question must NOT be shown: the
        /// elder already said no during this session (a decline or a
        /// revocation), or the stored record cannot be read (fail closed —
        /// a broken record is not a question for the elder, it is a bug to
        /// fix). The pending turn was answered on-device through the seam.
        /// The decision is carried for classification; it is `.denied` or
        /// `.unreadable`, never `.granted`.
        case localOnly(CloudChatConsentGate.Decision)

        /// Whether the turn this outcome belongs to may leave the device.
        /// `cloudAllowed` is the only yes — the same rule the routing
        /// decision enforces, stated here so no caller has to redefine it.
        var allowsEgress: Bool { self == .cloudAllowed }
    }

    /// The two spoken answers, as the existing spoken-confirmation capture
    /// produces them (the app's `ConfirmationResponse`, mapped at the
    /// wiring, T-177). There is no third: "maybe" is the question staying
    /// up, which is not an answer.
    enum SpokenAnswer: Equatable {
        case yes
        case no
    }

    /// What handing an answer to the prompt did.
    enum AnswerOutcome: Equatable {

        /// The gate recorded the answer. A grant was written and read back
        /// as a grant; a decline is in force (the gate mirrors "no" before
        /// it writes, so a decline is recorded in the only sense that
        /// matters even when storage failed — see `writeFailed`).
        case recorded

        /// The gate could not put the record on disk. Surfaced, never
        /// swallowed: no success is claimed for a record that is not there.
        /// A failed grant leaves the question up (the elder's answer was
        /// not recorded, so their retry is one tap away); a failed decline
        /// still denies, so the question closes.
        case writeFailed(CloudChatConsentGate.ConsentError)

        /// No question is live — nothing was written. A yes/no that arrives
        /// after the question was answered (or before it was ever asked) is
        /// not an answer to this question, and recording it would be a
        /// consent the elder never gave to it.
        case questionNotLive
    }

    // MARK: - Presentation state

    /// Whether the question is on screen. Only `consentNeedDetected` sets
    /// it, and only the gate having a decision (an answer, or a revocation
    /// surfaced through `refreshAfterDecisionChange`) clears it.
    @Published private(set) var isPromptPresented = false

    // MARK: - Dependencies

    private let gate: CloudChatConsentGate
    private var locale: Locale

    /// The app's existing spoken yes/no capture, injected (T-177 wires it to
    /// the shipped confirmation window). Called when the question appears —
    /// and through `reofferSpokenAnswer` when the wiring wants the answer
    /// offered again (the capture's own window has its own lifetime; the
    /// question does not). This type never captures anything itself, so it
    /// cannot answer the elder's question for them.
    private let startSpokenCapture: () -> Void

    // MARK: - Init

    init(gate: CloudChatConsentGate,
         locale: Locale,
         startSpokenCapture: @escaping () -> Void) {
        self.gate = gate
        self.locale = locale
        self.startSpokenCapture = startSpokenCapture
    }

    // MARK: - The one entry point

    /// Called at the first moment a chat turn would route to the cloud and
    /// the missing answer is the reason — never at launch, never in Settings
    /// navigation, never speculatively. The routing decision already
    /// required a chat-classified turn to get here.
    ///
    /// `answerPendingTurnLocally` is the injected seam (T-175/T-177 own its
    /// wiring): the local resolution of the turn that arrived at the
    /// question. It is run for every outcome except `.cloudAllowed`, exactly
    /// once per call, and it is not retained — the caller hands over the
    /// turn's local answer and does not run it separately. The same call
    /// thus presents, asks for the spoken answer and completes the pending
    /// turn, in that order; repeats while the question is up answer their
    /// own turns and never re-ask it.
    @discardableResult
    func consentNeedDetected(answerPendingTurnLocally: () -> Void) -> Outcome {
        let decision = gate.currentDecision()
        switch decision {
        case .granted:
            // Consent landed between the caller's routing decision and this
            // call (its own earlier answer, or a touch that beat the need).
            // The turn may egress; answering it locally as well would serve
            // it twice.
            return .cloudAllowed

        case .notRecorded:
            if !isPromptPresented {
                // The question appears here and nowhere else, and the
                // spoken answer is offered with it — the elder is never
                // required to touch.
                isPromptPresented = true
                startSpokenCapture()
            }
            answerPendingTurnLocally()
            return .awaitingDecision

        case .denied, .unreadable:
            // Declined or revoked this session, or a record that cannot be
            // read: fail closed, show nothing, answer on-device, and do not
            // re-ask (the shipped row-8 rule; a re-ask needs the elder's
            // explicit revocation/re-enable or an app-level reset, which
            // put the record back to "not decided").
            isPromptPresented = false
            answerPendingTurnLocally()
            return .localOnly(decision)
        }
    }

    // MARK: - The question's content

    /// The sheet's content, in the active language. Every string is a
    /// catalogue value by key — no literal copy exists in either of this
    /// unit's files.
    var sheetSurface: CloudChatConsentSheetSurface {
        CloudChatConsentSheetSurface(locale: locale)
    }

    /// The elder changed the app language; every string the sheet shows is
    /// re-resolved from the catalogue.
    func updateLocale(_ newLocale: Locale) {
        locale = newLocale
    }

    // MARK: - The question's lifetime

    /// Re-offers the spoken answer for the question that is still up. The
    /// capture's window (the voice session's own lifetime) can lapse
    /// unanswered — that lapses the window, never the question — and this is
    /// the one public way to ask the app to listen again (T-177 calls it
    /// where its machinery decides a re-offer is due). A no-op when no
    /// question is live: there is nothing to answer.
    func reofferSpokenAnswer() {
        guard isPromptPresented else { return }
        startSpokenCapture()
    }

    /// Re-reads the gate after a decision may have changed elsewhere (the
    /// revocation surfaces write through the gate's one writer, T-177). The
    /// question closes the moment the gate has a decision — a question with
    /// an answer is not a question — and never re-opens here: presentation
    /// has exactly one entry, `consentNeedDetected`.
    func refreshAfterDecisionChange() {
        if gate.currentDecision() != .notRecorded {
            isPromptPresented = false
        }
    }

    // MARK: - The elder's answers

    /// The sheet's "yes" control. The same two actions serve every surface:
    /// this is the answer the spoken capture also takes, through
    /// `submitSpokenAnswer`.
    @discardableResult
    func grant() -> AnswerOutcome {
        answer(granted: true)
    }

    /// The sheet's "no" control. A decline closes the question for the
    /// session; chat keeps working on-device, and nothing is re-asked until
    /// the record itself is put back to "not decided" by an explicit
    /// revocation/re-enable or an app-level reset.
    @discardableResult
    func decline() -> AnswerOutcome {
        answer(granted: false)
    }

    /// The existing spoken-confirmation capture's answer (T-177 hands the
    /// app's yes/no here). The answer rides the gate's one writer exactly as
    /// the touch answer does — the confirmation strings are T-171's answer
    /// keys, and there is no separate voice consent path.
    @discardableResult
    func submitSpokenAnswer(_ answer: SpokenAnswer) -> AnswerOutcome {
        switch answer {
        case .yes: return grant()
        case .no: return decline()
        }
    }

    /// The single body both answer paths share. The liveness guard is the
    /// first rule: only a live question can be answered, because a yes/no
    /// outside it was addressed to something else.
    private func answer(granted: Bool) -> AnswerOutcome {
        guard isPromptPresented else { return .questionNotLive }

        switch gate.record(granted: granted) {
        case .success:
            isPromptPresented = false
            return .recorded

        case .failure(let error):
            if !granted {
                // The elder answered "no". The gate mirrors the deny before
                // it writes, so the answer stands for this session even
                // though it may not survive a restart; the question closes
                // and is not re-shown. The failure is still surfaced — the
                // caller is told the record did not land.
                isPromptPresented = false
            }
            // A failed grant leaves the question up: "the write returned
            // success" is not "the elder's yes is on disk", and a question
            // whose answer did not take effect is still the truth on
            // screen. The retry is the elder's, one tap away.
            return .writeFailed(error)
        }
    }
}
