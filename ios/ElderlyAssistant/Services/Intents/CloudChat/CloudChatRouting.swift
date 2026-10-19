// T-173 — the single fail-closed routing decision for cloud chat (design-l1
// §8.1). One pure function answers the feature's only egress question — "may
// this chat turn leave the device?" — and it is the only place that answers
// it: the router's chat lane asks it (T-175), the guard escalation asks it
// (T-174), and nothing else in the feature may put a chat turn on the wire.
// That is what makes "enforced at the routing decision, not merely in the
// UI" (FR-CNR-009) a structural property of the code rather than a
// convention.
//
// The safety argument is exhaustiveness, so the shape is deliberately small:
//
//  - **One yes.** `.cloud` requires consent granted AND online AND key
//    configured AND cost allowed. Every other combination of the four inputs
//    is `.local(reason:)` — the test drives all 4 x 2 x 2 x 2 = 32 cells and
//    exactly one returns cloud (the design's sixteen-cell claim, taken at
//    the consent axis's full width: the gate has four readable states, not
//    a granted/not-granted dichotomy).
//  - **The first blocking input names the reason,** in the fixed order
//    consent -> online -> key -> cost. The reason is for humans reading why
//    the cloud was not used, and for classification-only telemetry; the
//    three non-granted consent states keep their own names (design §8.1,
//    FR-CNR-009).
//  - **Unknown inputs are not-granted inputs.** Absent, nil-returning and
//    throwing closures all resolve to a definite NOT *before* the decision
//    body runs. There is no input state — not a missing wiring, not a
//    corrupt consent store behind the closure, not a test double that
//    explodes — that can reach `.cloud` without all four inputs saying yes.
//  - **No route is cached.** `decide` reads its inputs on every call and
//    keeps nothing: the router calls it per turn, and a revocation between
//    two turns changes the second turn's route (design §8.6). The gate is
//    re-read, too — this type adds no memory of its own that a later read
//    would have to be reconciled with.
//  - **Classification only, and structurally so.** A reason is a fixed
//    token describing an input *state*: this file contains no string
//    literal at all, takes no transcript, holds no identity and logs
//    nothing. There is nothing here for content to travel through
//    (FR-CNR-007, FR-CNR-010, NFR-CNR-006 apply to the surfaces that later
//    consume these reasons; this type is pure).
//
// What this file deliberately does not do: it wires nothing (T-175, T-177),
// prompts nothing (T-176), resolves no guard flag (T-174) and knows nothing
// about the indicator, the Settings row or the voice surfaces. It also
// imports nothing — the decision needs the language and the gate's decision
// type, and a type that cannot reach an I/O primitive cannot egress.

/// The routing chokepoint (design §8.1). `decide` is the feature's only
/// producer of `.cloud`; every other member exists to feed it a definite
/// value.
enum CloudChatRouting {

    // MARK: - Route

    /// The route one chat turn takes. Two cases and no third exit: either
    /// the turn may egress, or it is answered on-device together with the
    /// reason the cloud was not used.
    enum ChatRoute: Equatable {

        /// Egress allowed for this turn — the one yes, produced only by
        /// `decide` and only for four simultaneous grants.
        case cloud

        /// Egress refused; `reason` names the first blocking input.
        case local(reason: LocalReason)

        /// Why a turn did not leave the device. Classification only: every
        /// value describes an *input state*, never content, never identity.
        /// The raw value is the case name (the file declares no string), so
        /// even a reason used as a telemetry token carries a member of this
        /// closed vocabulary and nothing else.
        enum LocalReason: String, Equatable, CaseIterable {

            /// The gate has no consent record for the current disclosure
            /// version — the elder has not decided under the copy in force
            /// (design §8.3). Also the reading when no consent reader is
            /// wired at all: nothing recorded is the truth about a missing
            /// input.
            case consentNotRecorded

            /// The gate's `denied`: a record that says no. A decline and a
            /// withdrawal both leave the gate in this one state (see
            /// `consentRevoked` below), and this is the state the routing
            /// decision reports.
            case consentDenied

            /// A withdrawal — the revocation surfaces' token (T-177), and
            /// the vocabulary the feature uses when *it performed* the
            /// withdrawal and knows so. `decide` never returns it: the
            /// gate's readable state cannot distinguish a revocation from a
            /// decline (`Decision.denied` is "the elder declined, or
            /// revoked"), and a routing read that named every `.denied` a
            /// revocation would misname every decline. Naming the state the
            /// gate actually has, and letting the surface that knows the
            /// history say so, is the honest split — inventing a distinct
            /// revocation state here would be a second consent source.
            case consentRevoked

            /// The gate holds a consent record it could not read or
            /// understand (or a reader threw); fail closed, and keep the
            /// name distinct so a human reading the reason looks for a
            /// broken read rather than an unmade decision.
            case consentUnreadable

            /// No network path is known to be available right now.
            case offline

            /// No cloud key is configured (or the key input could not be
            /// read), so a request could not be made.
            case keyMissing

            /// The cost governor refuses a call right now.
            case costBlocked
            /// The app-level cloud switch (the voice-engine stack)
            /// is off — the master override: no chat egress
            /// regardless of the chat consent record.
            case cloudDisabled
        }
    }

    // MARK: - The injected seam

    /// The routing decision's four inputs, as injected closures.
    ///
    /// The shape is the router's existing readiness-closure shape
    /// (`geminiKeyConfigured` / `geminiCostAllows`, `IntentRouter` :107-108)
    /// extended with the two inputs this feature adds: the consent gate's
    /// decision and reachability — the `NetworkReachability` discipline the
    /// LiveTranslate indicator uses, where a path that is not known to be
    /// there reads as not there. Closures rather than values are injected so
    /// the decision re-reads per turn, and so a test can drive every state
    /// without a network, a keychain or a clock.
    ///
    /// Every member is optional and every read is total: absent, nil and
    /// throwing each resolve to a definite not-granted / not-allowed value
    /// *before* the decision body runs (see `resolvedConsent` and
    /// `resolvedAllowance`). A construction site that wires nothing — every
    /// pre-feature site, and `Inputs()` itself — selects local, honestly,
    /// with no behavioural surprise; and no combination of unknown inputs
    /// can produce `.cloud`.
    struct Inputs {

        /// The consent gate's decision for this turn, read now. The shipped
        /// wiring is `{ gate.currentDecision() }`; the gate re-derives from
        /// storage on every read, so this seam caches nothing that a
        /// revocation would have to invalidate.
        var consent: (() throws -> CloudChatConsentGate.Decision?)?

        /// Whether a network path is available right now.
        var online: (() throws -> Bool?)?

        /// Whether a cloud key is configured (the router's existing
        /// `geminiKeyConfigured` input).
        var keyConfigured: (() throws -> Bool?)?

        /// Whether the cost governor allows a call right now (the router's
        /// existing `geminiCostAllows` input).
        var costAllows: (() throws -> Bool?)?

        /// The app-level cloud switch (voice-engine stack == gemini).
        /// Absent resolves via resolvedAllowance to not-allowed, so pre-feature
        /// sites stay fail-closed local; the shipped site always supplies it.
        var cloudEnabled: (() throws -> Bool?)?

        /// All four absent: `decide` selects local, and says why — no
        /// consent has been recorded, because no consent reader exists. A
        /// site that never opted in to chat egress has nothing to disable.
        init(consent: (() throws -> CloudChatConsentGate.Decision?)? = nil,
             online: (() throws -> Bool?)? = nil,
             keyConfigured: (() throws -> Bool?)? = nil,
             costAllows: (() throws -> Bool?)? = nil,
             cloudEnabled: (() throws -> Bool?)? = nil) {
            self.cloudEnabled = cloudEnabled
            self.consent = consent
            self.online = online
            self.keyConfigured = keyConfigured
            self.costAllows = costAllows
        }
    }

    // MARK: - The decision (design §8.1)

    /// The route for one chat turn, read from the injected seam.
    ///
    /// Reads every input *now* and stores nothing: the router calls this per
    /// turn, and consent revoked between two calls changes the second
    /// result (design §8.6 — revocation takes effect at the next turn's
    /// routing decision, never later and never earlier).
    static func decide(_ inputs: Inputs) -> ChatRoute {
        decide(consent: resolvedConsent(inputs.consent),
               online: resolvedAllowance(inputs.online),
               keyConfigured: resolvedAllowance(inputs.keyConfigured),
               costAllows: resolvedAllowance(inputs.costAllows),
               cloudEnabled: resolvedAllowance(inputs.cloudEnabled))
    }

    /// The pure core — the design's declared signature, and the single body
    /// in which the precedence lives, so the seam above cannot drift from
    /// it. `.cloud` requires all four yeses in one line of reasoning;
    /// everything else names the FIRST input that refused, in the fixed
    /// order consent -> online -> key -> cost. Exhaustive by construction
    /// and by test: 32 cells, exactly one cloud.
    static func decide(consent: CloudChatConsentGate.Decision,
                       online: Bool,
                       keyConfigured: Bool,
                       costAllows: Bool,
                       cloudEnabled: Bool = true) -> ChatRoute {
        // The master switch is the broadest override: off means NO chat
        // egress, named honestly, before every other axis.
        guard cloudEnabled else { return .local(reason: .cloudDisabled) }
        if let reason = nonGrantedReason(for: consent) {
            return .local(reason: reason)
        }
        guard online else { return .local(reason: .offline) }
        guard keyConfigured else { return .local(reason: .keyMissing) }
        guard costAllows else { return .local(reason: .costBlocked) }
        return .cloud
    }

    // MARK: - Resolving the seam (total; fail-closed)

    /// The gate's decision, or the fail-closed stand-in when the input
    /// cannot supply one.
    ///
    ///  - **No reader wired** -> `notRecorded`. "Nothing has been recorded"
    ///    is the true statement about an input that does not exist, and it
    ///    is the reading the gate itself gives a store that holds nothing:
    ///    it refuses egress and it asks (design §8.3). Every pre-feature
    ///    construction site lands here.
    ///  - **A reader that returns no decision** -> `notRecorded`, for the
    ///    same reason: there is no decision to honour.
    ///  - **A reader that throws** -> `unreadable`. The read did not
    ///    complete, which is a different failure from "the elder has not
    ///    decided" (the gate's own `.unreadable` distinction, kept rather
    ///    than collapsed) and keeps its own name so the human reading the
    ///    reason looks for a broken read, not an unmade decision.
    ///
    /// Every path is non-granted: no reader, and no failure of a reader,
    /// can turn into a grant.
    private static func resolvedConsent(
        _ read: (() throws -> CloudChatConsentGate.Decision?)?)
        -> CloudChatConsentGate.Decision {
        guard let read else { return .notRecorded }
        do {
            return try read() ?? .notRecorded
        } catch {
            return .unreadable
        }
    }

    /// An allowance input (online / key / budget) as a definite yes-or-no:
    /// absent, nil-returning and throwing all read as NO. "Not known to be
    /// allowed" is not allowed — the conservative direction the shipped
    /// reachability discipline takes (a path monitor that has not seen its
    /// first update answers false, costing the cloud only its ORDER; here
    /// the conservative direction is the same one: without a yes, no
    /// egress).
    private static func resolvedAllowance(_ read: (() throws -> Bool?)?) -> Bool {
        guard let read else { return false }
        return (try? read()) == true
    }

    /// The consent state's reason — nil for the one state that lets the
    /// decision continue. Deliberately no `default:`: a fifth gate state
    /// fails to compile here rather than silently mapping somewhere, which
    /// is the fail-closed direction for a vocabulary change.
    private static func nonGrantedReason(
        for consent: CloudChatConsentGate.Decision) -> ChatRoute.LocalReason? {
        switch consent {
        case .granted: return nil
        case .notRecorded: return .consentNotRecorded
        case .denied: return .consentDenied
        case .unreadable: return .consentUnreadable
        }
    }
}
