import Foundation
import SwiftUI

// T-027 — C13's plugin: the feature's entry (FR-LCT-001, FR-LCT-022;
// NFR-LCT-012).
//
// The shipped plugin pattern, followed exactly — one identifier, one
// display-name key, universal applicability, an intent contribution and a
// presentation view — with one deliberate divergence that is a correctness
// decision rather than a style one:
//
//   **There is no provider-availability guard.** `ApplianceHelperPlugin.handle`
//   opens with `guard context.geminiClient.isAvailable`. This plugin must not
//   copy it: live translation works with no provider key and no network at all
//   (every curated string resolves on device, and an uncurated one degrades per
//   region with the honest sentence). A guard here would refuse to open a
//   feature that works, which is why the divergence is asserted by a test that
//   names the template's guard.
//
// Nothing is built until the feature is opened (NFR-LCT-012): this object holds
// a *factory*, never a session, a camera, a detector or a client. The factory
// runs inside `presentationView(for:)`, which is called on the one path that
// opens the feature.

/// Everything a session needs, resolved when the feature is opened.
///
/// A closure rather than a stored value: the app layer builds capture,
/// recognition and the tier on demand, so registering the plugin at launch
/// costs nothing (the same reason `ApplianceHelperPlugin` holds a cache and not
/// a session).
///
/// `nil` means the app layer could not assemble a session at all — the shell's
/// speech queue does not exist yet, which is the state before `start()` and is
/// reachable by neither entry point. That is a construction failure, and the
/// design's failure table (row 23) says what one of those does: it is spoken,
/// never a silent no-op, and it is never a cloud-availability refusal.
typealias LiveTranslateSessionFactory = (Locale) -> LiveTranslateSessionDependencies?

/// The feature's Settings leaf, as a view the refusal can open.
///
/// The plugin cannot build one: the leaf draws the consent control, which is
/// the app layer's (it is the one gate the session and the prompt both drive),
/// and a plugin that minted its own would be a second consent surface. So the
/// app layer hands this over the same way it hands over the session factory —
/// on the path that needs it, built from the app's own controller.
typealias LiveTranslateSettingsViewFactory = (Locale) -> AnyView?

/// The feature's entry facts, spelled once for the three surfaces that must
/// agree about them: the plugin's display name, the Home tile (T-027's one
/// clear action) and the tests that assert the two are the same string.
enum LiveTranslateEntry {
    /// The shipped, catalog-backed name for this feature. It titles the
    /// Settings row, so reusing it keeps the feature's name in one place
    /// instead of adding a second string that would have to mean the same
    /// thing — and it is user-visible copy, so it is a key and never a
    /// literal (NFR-LCT-004).
    static let labelKey = "settings.livetranslate.title"

    /// The Home tile's glyph. A system identifier, not user-visible copy.
    static let iconName = "text.viewfinder"
}

/// **Main-actor confined** (Workstream B, review finding 11).
///
/// The plugin holds three pieces of mutable handoff state — the locale, the
/// session and the refusal view the two protocol calls pass between them — and
/// two of those are a SwiftUI view and a session that draws one. The shipped
/// hosts call the two halves from different places: `handle` runs inside the
/// router's `Task` (potentially off the main thread) while the presentation and
/// the Home tile's entry are the app's own main-confined code. Nothing kept the
/// writes and the reads on one executor, so the handoff was a race that happened
/// not to have been observed.
///
/// The protocol's *state-free* requirements stay `nonisolated`: they are pure
/// functions of constants and touch nothing this class mutates, so the router
/// can compose them from any thread. `presentationView(for:)` is the one
/// synchronous requirement that must read the handoff state, so it is
/// `nonisolated` and hops — the shipped sync-hop pattern
/// (`AppCoordinator.makePluginRegistry`'s `buildOnMain`) rather than a second
/// concurrency idiom.
@MainActor
final class LiveTranslatePlugin: AssistantPlugin {

    /// The feature's identifier, spelled once. The shipped plugins keep only
    /// the protocol's instance property; the static is named `identifier`
    /// rather than `pluginID` because an instance property of that name
    /// shadows it inside the class body (which is exactly the compiler error
    /// this name avoids) — and the tests want to read it without an instance.
    /// `nonisolated` like the rest of the plugin's entry facts: it is a
    /// constant, and the router reads it while composing (see the class doc).
    nonisolated static let identifier = "live_translate"

    /// The one action the shared intent encoder may hand this plugin. The
    /// design names it; the registry dispatches on it.
    nonisolated static let openAction = "livetranslate.open"

    /// The string the elder hears when the feature opens, and the same
    /// sentence T-008 shows before the camera prompt. Reused, not re-written:
    /// it already says what to do with the camera, which is exactly what the
    /// elder needs to hear one second before the preview appears.
    nonisolated static let spokenKey = "livetranslate.camera.explanation"

    /// What the elder hears if the app layer cannot assemble a session at all
    /// — the shipped assistant's own "I can't do that right now", reused
    /// rather than re-written, because that is exactly what it means.
    nonisolated static let unavailableKey = "router.pluginUnavailable"

    /// What the elder hears when the feature's **master switch** is off
    /// (Workstream B, owner directive 2026-09-21).
    ///
    /// A different sentence from `unavailableKey` on purpose, and the
    /// difference is the whole point of the switch: "I can't do that right
    /// now" is a failure the elder can only wait out, while this names a state
    /// the elder owns and the surface that changes it. It is spoken by **both**
    /// entries — the voice command through `handle`, the Home tile through the
    /// coordinator — so the two cannot refuse differently.
    nonisolated static let disabledKey = "livetranslate.disabled"

    /// The plugin's own event for a refusal by the master switch. Distinct
    /// from `live_translate_open_failed`, because nothing failed: the
    /// household turned the feature off, and that is a success of the switch.
    nonisolated static let disabledEventType = "live_translate_open_disabled"

    /// Computed rather than stored so it is `nonisolated` without a second
    /// spelling of its own value (see the class doc): the protocol asks for it
    /// while composing the router, where the main actor is not available.
    nonisolated var pluginID: String { Self.identifier }

    /// `settings.livetranslate.title` — "Live translation" / "लाइभ अनुवाद" —
    /// is the shipped, catalog-backed name for this feature (it titles its
    /// Settings row). Reusing it keeps the feature's name in one place instead
    /// of adding a second string that would have to mean the same thing.
    /// `nonisolated` for the same reason as `pluginID`.
    nonisolated var displayNameKey: String { LiveTranslateEntry.labelKey }

    private let observabilityBus: ObservabilityBus
    private let makeDependencies: LiveTranslateSessionFactory
    /// Where the Settings leaf comes from when the master switch refuses. Not
    /// defaulted: every construction site must decide, so a host that silently
    /// dropped it cannot make the refusal's promise a lie (the spoken line says
    /// the settings *are* open).
    private let makeSettingsView: LiveTranslateSettingsViewFactory
    /// The feature's master switch (C14). Read on every entry, never cached:
    /// the Settings leaf and the entries cannot disagree while this is the one
    /// store both read.
    private let settings: LiveTranslateSettings

    /// What `presentationView(for:)` hands over — **one value, because it is
    /// one question** (Workstream B, review finding 11).
    ///
    /// The handoff was two fields (`pendingSession`, `pendingRefusalView`) with
    /// three writers, and each writer had to remember to move both: the voice
    /// entry's refusal set one and cleared the other, its success did the
    /// reverse, and the tile path cleared one without touching the other — so a
    /// refusal could sit next to the last session's dependencies and the answer
    /// depended on which field `presentationView` happened to read first. As an
    /// enum the pair is not two things to keep in step: setting the session
    /// *is* the refusal being gone.
    ///
    /// The locale the feature was opened in used to be a third field here,
    /// written by `handle` and read by nothing: the session view takes its
    /// locale from the dependencies, so the field was a copy of the truth that
    /// no surface consulted.
    private enum PendingPresentation {
        /// A session the entry built, to be drawn (`sessionView`).
        case session(LiveTranslateSessionDependencies)
        /// The Settings leaf a refusal opened.
        case refusal(AnyView)
    }

    private var pendingPresentation: PendingPresentation?

    /// `nonisolated` because the registry is composed off the main actor
    /// (`AppCoordinator`'s lazily-built plugin registry), and constructing an
    /// object is not touching shared main-actor state — nothing here runs a
    /// closure or builds a view. Every *use* of the instance is main-confined
    /// (see the class doc), which is what the annotation is for.
    nonisolated init(observabilityBus: ObservabilityBus,
         settings: LiveTranslateSettings = LiveTranslateSettings(),
         makeDependencies: @escaping LiveTranslateSessionFactory,
         makeSettingsView: @escaping LiveTranslateSettingsViewFactory) {
        self.observabilityBus = observabilityBus
        self.settings = settings
        self.makeDependencies = makeDependencies
        self.makeSettingsView = makeSettingsView
    }

    /// Whether the feature's master switch currently lets the feature open.
    /// Read by the Home tile's entry (`AppCoordinator.presentLiveTranslate`),
    /// which owns its own speaking and so cannot read it from a `PluginResult`.
    var isEnabled: Bool { settings.liveTranslateEnabled }

    /// **The one refusal, and the whole of it** (Workstream B; review finding
    /// 10): the line to say, the Settings leaf to open, and the event that
    /// records whose decision this was — all three, in one call, so the voice
    /// entry and the Home tile cannot refuse differently — the same rule that
    /// makes the session factory one closure rather than two builders.
    ///
    /// The line and the leaf are a pair and must stay one: the sentence
    /// promises the settings are open, so a caller that spoke it without
    /// presenting the leaf would be lying to an elder. Returning them together
    /// is what makes that unrepresentable.
    ///
    /// The **event** belongs to the refusal the same way, and it is what the
    /// call sites had drifted on: the voice entry emitted it, the Home tile's
    /// refusal emitted nothing at all (the coordinator is what presents that
    /// path, and it spoke from a method that recorded nothing), and the plugin's
    /// own tile branch emitted a third copy that the coordinator's earlier
    /// guard makes unreachable. One act, so one place that records it, whichever
    /// entry made the refusal.
    ///
    /// `nil` when the app layer cannot build the leaf — the teardown case the
    /// hosting closure's weak capture leaves open. Then **the sentence is
    /// refused too**: the caller falls back to `unavailableKey`, because "I've
    /// opened its settings" is not sayable when no settings can be opened, and
    /// the failure is recorded here as the failure it is. A caller must never
    /// speak `disabledKey` on its own for exactly this reason, which is why the
    /// pair is returned together and not as two methods.
    ///
    /// The handoff is cleared **here, before either branch**, because a refusal
    /// replaces whatever the last entry left for `presentationView(for:)` — the
    /// session view and the refusal leaf are the same slot, and a refusal that
    /// left the field alone would present the previous answer.
    func disabledRefusal(locale: Locale) -> (spoken: String, view: AnyView)? {
        pendingPresentation = nil
        guard let view = makeSettingsView(locale) else {
            observabilityBus.emit(Self.event("live_translate_open_failed",
                                             errorCode: "settings_view_unavailable"))
            return nil
        }
        pendingPresentation = .refusal(view)
        observabilityBus.emit(Self.event(Self.disabledEventType,
                                         errorCode: "master_switch_off"))
        return (L10n.str(Self.disabledKey, locale: locale), view)
    }

    /// Universal: this feature is not geography- or language-gated. The
    /// recognition and translation layers decide per string what they can do.
    /// `nonisolated` with the other state-free entry facts (see the class doc):
    /// the router composes the intent vocabulary off the main actor.
    nonisolated func isApplicable(locale: Locale) -> Bool { true }

    nonisolated var intentContribution: PluginIntentContribution {
        PluginIntentContribution(actionNames: [Self.openAction], promptFragment: """
        PLUGIN CAPABILITY (live camera translation): if the user wants the \
        phone's camera to read and translate text that is physically in front \
        of them — a sign, a label, a package, a menu, a nameplate, a screen \
        (e.g. "translate this", "यो अनुवाद गर्नुहोस्", "यो के लेखेको छ", \
        "read this sign", "यो कागज पढ्नुहोस्"), set action to "plugin", \
        pluginAction to "\(Self.openAction)", and pluginEntities to \
        {"phrase": "<what they said, verbatim, or empty string>"}. Also use \
        "\(Self.openAction)" when the user asks to stop or close the \
        translation ("अनुवाद बन्द गर्नुहोस्", "stop translating"): the session \
        itself is what closes, and opening it again is where its close control \
        already leads.
        """)
    }

    // MARK: - Entry

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        // Not a guard, and deliberately not one: no provider key, no network
        // and no camera permission is consulted here. The feature opens, and
        // whatever the scene or the tiers cannot do is said honestly per region
        // once there are regions (FR-LCT-007, FR-LCT-023).
        //
        // **The master switch, before anything is built** (Workstream B). The
        // order matters: the household turned the feature off, so this path
        // must not assemble a capture session, a detector or a client on its
        // way to saying so — nothing is built until the feature is opened, and
        // a feature that is off is not opened (NFR-LCT-012).
        //
        // The refusal is the *same* one the Home tile gives, from the same
        // method, so the two entries cannot say different things about the same
        // switch — and it carries its own event and its own handoff (see
        // `disabledRefusal`), which is why nothing here clears or records
        // anything on either branch. It is a refusal and not a failure:
        // `isEnabled` is false because someone chose it, which is why the event
        // type is its own.
        guard settings.liveTranslateEnabled else {
            guard let refusal = disabledRefusal(locale: context.locale) else {
                // No leaf, so no promise: the shipped apology is the only
                // sentence here that is true (see `disabledRefusal`, which has
                // already recorded the failure).
                return .failed(spokenApology: L10n.str(Self.unavailableKey,
                                                       locale: context.locale))
            }
            return .spokenAndPresented(refusal.spoken)
        }
        guard let dependencies = makeDependencies(context.locale) else {
            // The one thing that can stop entry is the app layer being unable
            // to assemble a session, and that is said out loud rather than
            // returned as a success with no view (failure-table row 23). The
            // message names no cause the feature cannot verify.
            pendingPresentation = nil
            observabilityBus.emit(Self.event("live_translate_open_failed",
                                             errorCode: "session_construction_failed"))
            return .failed(spokenApology: L10n.str(Self.unavailableKey, locale: context.locale))
        }
        pendingPresentation = .session(dependencies)
        observabilityBus.emit(Self.event("live_translate_opened"))
        return .spokenAndPresented(L10n.str(Self.spokenKey, locale: context.locale))
    }

    /// The view for the result the handler returned. Built from the session
    /// `handle` already assembled, so opening builds exactly one — or, for a
    /// refusal, the Settings leaf the refusal named.
    ///
    /// `nonisolated` and hopped because it is the protocol's one *synchronous*
    /// requirement that reads main-confined state: the view it returns is
    /// SwiftUI, and the handoff it reads was written by whichever thread ran
    /// the entry. The hop is the shipped one
    /// (`AppCoordinator.makePluginRegistry`'s `buildOnMain`): a direct call when
    /// this already runs on the main thread, `DispatchQueue.main.sync` when it
    /// does not. The second branch cannot deadlock — it is only taken off the
    /// main thread, where there is no queue to be blocked on.
    nonisolated func presentationView(for result: PluginResult) -> AnyView? {
        guard case .spokenAndPresented = result else { return nil }
        let readOnMain = { MainActor.assumeIsolated { () -> AnyView? in
            switch self.pendingPresentation {
            case .refusal(let view): return view
            case .session(let dependencies): return self.sessionView(dependencies: dependencies)
            case nil: return nil
            }
        } }
        return Thread.isMainThread ? readOnMain() : DispatchQueue.main.sync(execute: readOnMain)
    }

    /// The Home tile's entry (FR-LCT-001, T-027): a tap is already an
    /// unambiguous intent, so it takes the same route the voice entry takes
    /// minus the utterance — assemble one session, and return the same view.
    /// `nil` when the app layer could not assemble one; the caller speaks the
    /// apology rather than presenting an empty screen.
    ///
    /// The master switch is checked first and returns the *same* refusal the
    /// voice entry gives — the same line, the same leaf, the same event — which
    /// is what makes "the two entries cannot refuse differently" true rather
    /// than intended. The caller speaks nothing of its own for this case:
    /// `disabledRefusal` carries all of it.
    func tileView(locale: Locale) -> AnyView? {
        guard settings.liveTranslateEnabled else {
            return disabledRefusal(locale: locale)?.view
        }
        guard let dependencies = makeDependencies(locale) else {
            pendingPresentation = nil
            observabilityBus.emit(Self.event("live_translate_open_failed",
                                             errorCode: "session_construction_failed"))
            return nil
        }
        // Recorded like the voice entry's, so the tile's `nil` return is the
        // only thing the caller has to know about: the handoff says what was
        // built (review finding 11), and a later `presentationView(for:)` cannot
        // reach back past it to another entry's session.
        pendingPresentation = .session(dependencies)
        observabilityBus.emit(Self.event("live_translate_opened"))
        return sessionView(dependencies: dependencies)
    }

    /// The one view constructor both entries use: a session is built on the
    /// path that opens the feature and nowhere else, so an app that launches
    /// and never opens live translation creates no capture session, no
    /// recognition request and no network client (NFR-LCT-012).
    private func sessionView(dependencies: LiveTranslateSessionDependencies?) -> AnyView? {
        guard let dependencies else { return nil }
        return AnyView(LiveTranslateView(dependencies: dependencies))
    }

    /// Test seam: whether a session would be built for a result, without
    /// building one. Production never reads it.
    func wouldPresentView(for result: PluginResult) -> Bool {
        if case .spokenAndPresented = result { return true }
        return false
    }
}

private extension LiveTranslatePlugin {
    /// The plugin's own event, in the shipped shape (the appliance helper's
    /// `event(_:)`): a component, a fixed event type, an outcome token and no
    /// metadata — so no transcript and no entity the encoder extracted has
    /// anywhere to travel.
    static func event(_ type: String, errorCode: String? = nil) -> ObservabilityEvent {
        ObservabilityEvent(component: "plugin_live_translate",
                           eventType: type, durationMs: nil,
                           outcome: errorCode == nil ? "success" : "failure",
                           errorCode: errorCode, metadata: [:])
    }
}
