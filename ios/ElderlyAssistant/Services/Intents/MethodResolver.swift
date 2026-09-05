import Foundation

/// Picks the default calling method for a contact — deterministic code,
/// never the LLM (spec 2026-09-05 §6.2). The model extracts the
/// `requestedApp`/`callType` slots; this chain owns the DEFAULT when the
/// user didn't name one:
///
///   1. explicit mention ("वाट्सएपमा", "video call")  → honored
///   2. family-set per-contact preference             → used
///   3. confirmed-method history for this contact     → reused
///   4. global default `.phone` (tel:)                → universal fallback
///
/// Consistency beats cleverness for this user population: the household's
/// learned habit outranks any heuristic, and the confirmation prompt
/// always discloses the resolved method so a wrong resolution is caught
/// by ears, not by a misdial.
final class MethodResolver {

    private let preferenceStore: CallMethodPreferenceStore
    private let historyStore: ConfirmedMethodHistoryStore

    init(preferenceStore: CallMethodPreferenceStore,
         historyStore: ConfirmedMethodHistoryStore) {
        self.preferenceStore = preferenceStore
        self.historyStore = historyStore
    }

    /// Which step of the chain produced the method — carried through so
    /// the confirmation prompt can (eventually) explain itself, and so
    /// observability can measure how often each step wins.
    enum ResolutionSource: String {
        case explicit
        case familyPreference
        case confirmedHistory
        case globalDefault
    }

    struct ResolvedMethod {
        let method: CallMethod
        /// Set when the user asked for an app we can't actually call
        /// through (e.g. "messenger"), so we fell back to FaceTime —
        /// named here so the confirmation prompt can disclose it.
        let unsupportedRequestedApp: String?
        let source: ResolutionSource
    }

    func resolve(contactId: UUID,
                 requestedApp: String?,
                 callType: String?) -> ResolvedMethod {
        // 1. Explicit mention — the user's own words outrank everything.
        //    Covers both a named app AND a bare "video call" (FaceTime is
        //    the only video-capable integration, so asking for video IS a
        //    method choice).
        if let explicit = Self.explicitMethod(requestedApp: requestedApp, callType: callType) {
            return ResolvedMethod(method: explicit.method,
                                  unsupportedRequestedApp: explicit.unsupported,
                                  source: .explicit)
        }

        // 2. Family-set preference.
        if let preferred = preferenceStore.preference(for: contactId) {
            return ResolvedMethod(method: preferred,
                                  unsupportedRequestedApp: nil,
                                  source: .familyPreference)
        }

        // 3. Confirmed-method history.
        if let history = historyStore.lastConfirmed(for: contactId) {
            return ResolvedMethod(method: history.method,
                                  unsupportedRequestedApp: nil,
                                  source: .confirmedHistory)
        }

        // 4. Global default — tel:, the only method that works for every
        //    contact with zero app assumptions.
        return ResolvedMethod(method: .phone,
                              unsupportedRequestedApp: nil,
                              source: .globalDefault)
    }

    /// Maps (requestedApp, callType) to a real, achievable method when
    /// the user was explicit. `requestedApp`/`callType` are free-form
    /// strings the LLM extracted from speech (e.g. "whatsapp", "video") —
    /// matched loosely in both English and Nepali since that's what
    /// actually shows up. Returns nil when the user named nothing (the
    /// chain's signal to move to step 2).
    static func explicitMethod(requestedApp: String?,
                               callType: String?) -> (method: CallMethod, unsupported: String?)? {
        let isVideo = callType.map {
            $0.lowercased().contains("video") || $0.contains("भिडियो")
        } ?? false
        guard let app = requestedApp?.lowercased(), !app.isEmpty else {
            return isVideo ? (.facetimeVideo, nil) : nil
        }
        if app.contains("facetime") || app.contains("फेसटाइम") {
            return (isVideo ? .facetimeVideo : .facetimeAudio, nil)
        }
        if app.contains("whatsapp") || app.contains("ह्वाट्सएप") || app.contains("वाट्सएप") {
            return (.whatsappChat, nil)
        }
        if app.contains("phone") || app.contains("फोन") || app.contains("call") || app.contains("कल") {
            // "फोन नै गर" — a plain phone call, said so in as many words.
            return (.phone, nil)
        }
        // Messenger, Viber, or anything else with no real integration —
        // fall back to FaceTime, but say so.
        return (isVideo ? .facetimeVideo : .facetimeAudio, requestedApp)
    }
}
