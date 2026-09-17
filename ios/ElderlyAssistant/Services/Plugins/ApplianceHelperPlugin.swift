import Foundation
import SwiftUI

/// Appliance/vision helper plugin (designs:
/// docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md,
/// its live-AR addendum, and the plugin architecture's §6.1 wiring).
///
/// A voice utterance can never CARRY a photo (design §6.1, stated
/// plainly), so `handle` does not answer anything itself — it opens the
/// camera surface via `spokenAndPresented`, and the presented
/// `ApplianceHelperView` drives capture → identify → overlay through
/// `ApplianceHelperSession`. The in-sheet follow-up mic and the live-AR
/// mode are deliberately not built on this branch (addendum §13 is a
/// later phase; see the branch report).
///
/// 2026-09-13 (appliance-default-manual): one thing a voice turn CAN
/// serve is a manual the elder already saved. When the utterance names an
/// appliance whose category has a default manual (`entities["appliance"]`
/// → `ApplianceCategoryKey` → `ApplianceCache.defaultEntry(forCategory:)`)
/// and the request's question doesn't conflict with the one that manual
/// answered, `handle` stashes that entry id and speaks the "I have your
/// manual" prompt instead of the camera prompt; the presented view opens
/// the manual on `.onAppear` and only falls back to the camera when the
/// manual can't be rendered. No default → byte-for-byte the old
/// camera-first behavior.
final class ApplianceHelperPlugin: AssistantPlugin {

    let pluginID = "appliance_helper"
    let displayNameKey = "plugin.applianceHelper.name"

    private let cache: ApplianceCache

    /// The app's one shared translation store, handed to the presented view
    /// so the helper's label seam reads the same dictionary and the same
    /// persisted layer the live translation path reads (T-013, FR-LCT-020).
    /// Optional and defaulted: a plugin built without one — every existing
    /// call site and every test — presents exactly the shipped view.
    private let labelCache: LabelTranslationCache?

    /// Wired by `AppCoordinator.start()` (the speaker is built after the
    /// registry, so it can't be an init parameter). Optional: the feature
    /// works silently without it, and tests never set one.
    var speaker: Speaker?

    /// Everything `presentationView(for:)` needs from the `handle` call
    /// that produced the result — the protocol hands the context to
    /// `handle` only, so the pending request is stashed here between the
    /// two calls (CommandRouter always calls them as a pair).
    private struct PendingRequest {
        let question: String?
        let locale: Locale
        let geminiClient: GeminiClient
        let observabilityBus: ObservabilityBus
        /// Non-nil when `handle` found this request's category default
        /// manual — the presented session opens it instead of the camera.
        let pendingManualEntryID: UUID?
    }
    private var pendingRequest: PendingRequest?

    /// The session the last `presentationView(for:)` built, exposed for
    /// tests: the protocol hands back an opaque `AnyView`, so the only
    /// honest way to assert "the view got a session with a pending
    /// manual" is to look at the session itself. Production never reads
    /// this — the view owns its session from the moment it is built.
    private(set) var lastPresentedSession: ApplianceHelperSession?

    init(storage: EncryptedLocalStorage, labelCache: LabelTranslationCache? = nil) {
        self.cache = ApplianceCache(storage: storage)
        self.labelCache = labelCache
    }

    /// Test seam: the session cache (LRU/keys covered by
    /// `ApplianceCacheTests` directly).
    init(cache: ApplianceCache, labelCache: LabelTranslationCache? = nil) {
        self.cache = cache
        self.labelCache = labelCache
    }

    func isApplicable(locale: Locale) -> Bool { true }   // universal, not geography-gated

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(
            actionNames: ["appliance.identify", "appliance.get_instructions"],
            promptFragment: """
            PLUGIN CAPABILITY (appliance help): if the user wants to know \
            how to use, operate, or understand a physical appliance, \
            remote control, microwave, washing machine, TV, or screen \
            (e.g. "यो कसरी चलाउने", "माइक्रोवेभमा चिया कसरी बनाउने", \
            "यो बटन के हो"), set action to "plugin", pluginAction to \
            "appliance.identify", and pluginEntities to \
            {"question": "<their question, verbatim, or empty string>", \
            "appliance": "<the appliance's category keyword, e.g. microwave, tv, washing machine, fridge>"}. \
            Use "appliance.get_instructions" instead only when they are \
            clearly asking a follow-up about an appliance they were just \
            being helped with in this conversation.
            """
        )
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        guard context.geminiClient.isAvailable else {
            context.observabilityBus.emit(Self.event("appliance_helper_unconfigured"))
            return .failed(spokenApology: L10n.str("plugin.applianceHelper.notConfigured",
                                                   locale: context.locale))
        }
        let question = Self.extractQuestion(from: command)

        // A manual the elder already saved for this appliance outranks the
        // camera. Served from the cache, so this is still "no photo
        // needed" — just the guide they made earlier instead of a new
        // capture.
        if let entry = Self.defaultManualEntry(for: command, question: question, cache: cache) {
            pendingRequest = PendingRequest(question: question,
                                            locale: context.locale,
                                            geminiClient: context.geminiClient,
                                            observabilityBus: context.observabilityBus,
                                            pendingManualEntryID: entry.id)
            context.observabilityBus.emit(Self.event("appliance_helper_default_manual"))
            return .spokenAndPresented(
                L10n.fmt("plugin.applianceHelper.defaultManualPrompt",
                         locale: context.locale,
                         Self.displayName(of: entry)))
        }

        pendingRequest = PendingRequest(question: question,
                                        locale: context.locale,
                                        geminiClient: context.geminiClient,
                                        observabilityBus: context.observabilityBus,
                                        pendingManualEntryID: nil)
        context.observabilityBus.emit(Self.event("appliance_helper_presented"))
        return .spokenAndPresented(L10n.str("plugin.applianceHelper.cameraPrompt",
                                            locale: context.locale))
    }

    /// The category default manual this command should be served instead
    /// of the camera, or nil (the camera path is then untouched).
    ///
    /// The category comes from the plugin's own `appliance` entity — the
    /// LLM's read of the elder's word for the device ("माइक्रोवेभ", "tv"),
    /// folded by `ApplianceCategoryKey` exactly like the stored entry's
    /// category, so either spelling finds the same manual. An absent
    /// entity (an older cached intent, a screen-initiated call) simply
    /// means no default is served.
    ///
    /// The QUESTION rule is what keeps the serve honest: a manual answers
    /// ONE question, so it may only be served when the elder's request
    /// cannot conflict with it — the manual answered general how-to-use
    /// (nil question), or the request asked nothing specific, or the two
    /// questions normalize to the same request. A request about a
    /// DIFFERENT operation ("घडी कसरी मिलाउने" against a manual that
    /// answered "चिया कसरी बनाउने") is a different request entirely:
    /// serving the stored guide would fabricate an answer, and that turn
    /// gets the camera.
    static func defaultManualEntry(for command: PluginCommand, question: String?,
                                   cache: ApplianceCache) -> ApplianceCache.Entry? {
        guard let rawCategory = command.entities["appliance"],
              let entry = cache.defaultEntry(forCategory: rawCategory) else { return nil }
        // `normalizeQuestion` rather than `entry.question == nil`: it also
        // treats a whitespace-only stored question as the general request
        // (the same equivalence every other question comparison uses).
        guard ApplianceCache.normalizeQuestion(entry.question) != nil else { return entry }
        guard let question else { return entry }
        return ApplianceCache.questionsMatch(entry.question, question) ? entry : nil
    }

    /// Spoken-friendly name for the default-manual prompt: the identity's
    /// displayName, falling back to the category when Gemini named the
    /// appliance but gave it no display name — the same fallback the
    /// manuals library uses for its rows, so the elder hears the name
    /// they'd see there.
    static func displayName(of entry: ApplianceCache.Entry) -> String {
        let identity = entry.guidance.identity
        return identity.displayName.isEmpty ? identity.category : identity.displayName
    }

    /// The question travels in the plugin's own `question` entity; an
    /// empty string means "no specific question" (general how-to-use),
    /// and the sanitised transcript is the last-resort carrier.
    static func extractQuestion(from command: PluginCommand) -> String? {
        if let q = command.entities["question"] {
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let transcript = command.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }

    func presentationView(for result: PluginResult) -> AnyView? {
        guard case .spokenAndPresented = result, let request = pendingRequest else { return nil }
        let session = ApplianceHelperSession(question: request.question,
                                             locale: request.locale,
                                             geminiClient: request.geminiClient,
                                             cache: cache,
                                             observabilityBus: request.observabilityBus,
                                             speaker: speaker,
                                             pendingManualEntryID: request.pendingManualEntryID)
        lastPresentedSession = session
        return AnyView(ApplianceHelperView(session: session, labelCache: labelCache))
    }

    private static func event(_ type: String, errorCode: String? = nil) -> ObservabilityEvent {
        ObservabilityEvent(component: "plugin_appliance_helper",
                           eventType: type, durationMs: nil,
                           outcome: errorCode == nil ? "success" : "failure",
                           errorCode: errorCode, metadata: [:])
    }
}
