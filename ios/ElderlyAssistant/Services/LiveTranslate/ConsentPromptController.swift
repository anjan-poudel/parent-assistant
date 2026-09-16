import Foundation

// T-015 — the consent prompt's lifecycle and the tier's consent entry point.
//
// The gate (T-014, C09) answers "is consent in force?". This type answers the
// two questions the feature's surfaces ask around it:
//
//  - **When may the prompt be shown?** At the first cloud need — the moment
//    an unresolved string would otherwise be sent — and never on session open,
//    never on a dictionary-only scene, and never again automatically in a
//    session once the elder has answered (FR-LCT-013, failure-table row 8).
//    `cloudNeedDetected()` is that decision, and it is the only thing that
//    presents the prompt.
//  - **What does the elder's answer do?** The same three actions serve both
//    surfaces: the prompt over the session view and the control in Settings
//    and in the session chrome. A grant or a decline goes through the gate's
//    one writer; a revocation goes through the gate's one delete-and-verify
//    path. A write that did not take effect is shown as a failure — never as
//    a success the elder did not get (AM-4 part 3).
//
// There is **no timeout and no dismissal**. The prompt is a blocking
// decision: it stays presented until the elder chooses, because any automatic
// dismissal would be an implicit consent (FR-LCT-013). That is why there is
// no timer in this file and no timeout parameter in `LiveTranslateConfig` to
// configure one — a value for it would be wrong.
//
// `@MainActor` because every consumer is a view, and because serialising the
// presentation state is what makes "exactly one prompt" structural.

@MainActor
final class ConsentPromptController: ObservableObject {

    /// What a cloud need turned into.
    enum Outcome: Equatable {
        /// Consent is in force: the caller may build its request with the
        /// proof. Nothing else allows a send.
        case proceed(LiveTranslateConsentGate.Grant)
        /// The prompt is presented and the elder has not answered. No request
        /// may be in flight and none may start.
        case awaitingDecision
        /// Consent is not in force and the prompt must not be shown: the
        /// elder already declined or revoked in this session, or the record
        /// cannot be trusted. The caller shows the original text with the
        /// honest unavailable indication.
        case unavailable(LiveTranslateError)

        /// Whether the caller may send. `proceed` is the only yes.
        var allowsSend: Bool {
            if case .proceed = self { return true }
            return false
        }
    }

    // MARK: Presentation state

    /// Whether the prompt is on screen. Only `cloudNeedDetected()` sets it,
    /// and only an elder's answer clears it.
    @Published private(set) var isPromptPresented = false
    /// The honest failure line when the elder's answer did not reach storage.
    @Published private(set) var failureMessage: String?
    /// What the control (session chrome and Settings) shows right now.
    @Published private(set) var controlSurface: ConsentControlSurface
    /// Whether the last revocation did not fully take effect. The control
    /// shows the retry state while this is set, so the elder can act on the
    /// failure rather than being told about it and stranded.
    @Published private(set) var revocationIncomplete = false

    // MARK: Dependencies

    private let gate: LiveTranslateConsentGate
    private let events: LiveTranslateEvents
    private var locale: Locale

    // MARK: Init

    init(gate: LiveTranslateConsentGate,
         config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         locale: Locale) {
        self.gate = gate
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        self.locale = locale
        self.controlSurface = gate.currentDecision().allowsEgress
            ? .granted(locale: locale)
            : .decision(locale: locale)
    }

    // MARK: The tier's entry point

    /// Called at the point of first cloud need — the moment a string that the
    /// dictionary and the cache could not resolve would otherwise be sent.
    ///
    /// A dictionary hit never reaches this call, which is why a dictionary-only
    /// scene shows no prompt at all: the prompt is presented *here*, not at
    /// session open.
    func cloudNeedDetected() -> Outcome {
        switch gate.currentDecision() {
        case .granted:
            // The proof is minted per attempt (AM-1), so a revocation between
            // attempts denies the next one without a restart.
            switch gate.authorize() {
            case .success(let grant): return .proceed(grant)
            case .failure(let error): return .unavailable(error)
            }
        case .notRecorded:
            guard !isPromptPresented else { return .awaitingDecision }
            presentPrompt()
            return .awaitingDecision
        case .denied:
            // Declined or revoked — including earlier in this session. The
            // prompt is not re-shown automatically (row 8); the elder can
            // change the decision deliberately from the control.
            return .unavailable(.consentDenied)
        case .unreadable:
            return .unavailable(.consentRecordUnreadable)
        }
    }

    /// The honest unavailable indication's copy, in the active language. The
    /// overlay shows this for a region whose string could not be translated;
    /// it names no cause, because the feature does not know one
    /// (NFR-LCT-004, FR-LCT-012).
    var unavailableMessage: String {
        L10n.str("livetranslate.state.unavailable", locale: locale)
    }

    /// The prompt's current content, in the active language.
    var promptSurface: ConsentPromptSurface {
        ConsentPromptSurface(locale: locale, failureMessage: failureMessage)
    }

    // MARK: The elder's answers

    /// The elder grants. On success a record is written for the current
    /// disclosure version and the caller may proceed — the pending send
    /// continues without a second prompt, because the decision is now
    /// `granted` and the prompt branch is not taken again.
    @discardableResult
    func grant() -> Result<Void, LiveTranslateConsentGate.ConsentError> {
        let result = gate.record(granted: true)
        switch result {
        case .success:
            failureMessage = nil
            isPromptPresented = false
        case .failure:
            // The answer did not take effect. The prompt stays up and the
            // elder is told, rather than being shown a consent that was not
            // recorded.
            failureMessage = L10n.str("livetranslate.consent.failed", locale: locale)
        }
        refreshControl()
        return result
    }

    /// The elder declines. The dictionary tier and the cache are untouched —
    /// they never needed consent — and the region shows its original text with
    /// the honest unavailable indication.
    ///
    /// A decline whose write fails still denies: the gate mirrors the "no"
    /// before it writes. The failure is reported so the elder knows the
    /// decision may not survive a restart.
    @discardableResult
    func decline() -> Result<Void, LiveTranslateConsentGate.ConsentError> {
        let result = gate.record(granted: false)
        if case .failure = result {
            failureMessage = L10n.str("livetranslate.consent.failed", locale: locale)
        } else {
            failureMessage = nil
        }
        // Either way the elder has answered, so the automatic prompt is done
        // for this session; the answer stands in memory even if the write
        // failed.
        isPromptPresented = false
        refreshControl()
        return result
    }

    /// The elder withdraws consent. Immediate and total: the gate denies in
    /// memory first, cancels every registered in-flight request, deletes the
    /// record and verifies the delete by reading back.
    ///
    /// A withdrawal that did not fully take effect is **surfaced**: the elder
    /// is told, and the control keeps offering the retry. It is never reported
    /// as a success (AM-4 part 3).
    @discardableResult
    func revoke() -> Result<Void, LiveTranslateConsentGate.ConsentError> {
        let result = gate.revoke()
        switch result {
        case .success:
            failureMessage = nil
            revocationIncomplete = false
        case .failure:
            revocationIncomplete = true
        }
        isPromptPresented = false
        refreshControl()
        return result
    }

    // MARK: In-flight registration

    /// Registers in-flight tier-2 work with the gate, so a revocation from
    /// either surface cancels it. T-019 holds the registration for the
    /// duration of an attempt.
    func registerInFlight(cancel: @escaping () -> Void) -> LiveTranslateConsentGate.InFlightRegistration {
        gate.registerInFlight(cancel: cancel)
    }

    // MARK: Presentation

    /// Re-reads the gate and republishes the control. The control calls this
    /// when it appears, so Settings always shows the decision in force — and
    /// never a cached one.
    func refreshControl() {
        if revocationIncomplete {
            controlSurface = .revocationIncomplete(locale: locale)
        } else if gate.currentDecision().allowsEgress {
            controlSurface = .granted(locale: locale)
        } else {
            controlSurface = .decision(locale: locale, failureMessage: failureMessage)
        }
    }

    /// The elder changed the app language; every string this type owns is
    /// re-resolved from the catalog.
    func updateLocale(_ newLocale: Locale) {
        locale = newLocale
        refreshControl()
    }

    private func presentPrompt() {
        isPromptPresented = true
        failureMessage = nil
        events.consentPromptShown()
    }
}
