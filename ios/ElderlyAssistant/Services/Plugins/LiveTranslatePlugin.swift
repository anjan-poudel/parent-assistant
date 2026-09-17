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

final class LiveTranslatePlugin: AssistantPlugin {

    /// The feature's identifier, spelled once. The shipped plugins keep only
    /// the protocol's instance property; the static is named `identifier`
    /// rather than `pluginID` because an instance property of that name
    /// shadows it inside the class body (which is exactly the compiler error
    /// this name avoids) — and the tests want to read it without an instance.
    static let identifier = "live_translate"

    /// The one action the shared intent encoder may hand this plugin. The
    /// design names it; the registry dispatches on it.
    static let openAction = "livetranslate.open"

    /// The string the elder hears when the feature opens, and the same
    /// sentence T-008 shows before the camera prompt. Reused, not re-written:
    /// it already says what to do with the camera, which is exactly what the
    /// elder needs to hear one second before the preview appears.
    static let spokenKey = "livetranslate.camera.explanation"

    /// What the elder hears if the app layer cannot assemble a session at all
    /// — the shipped assistant's own "I can't do that right now", reused
    /// rather than re-written, because that is exactly what it means.
    static let unavailableKey = "router.pluginUnavailable"

    let pluginID = LiveTranslatePlugin.identifier

    /// `settings.livetranslate.title` — "Live translation" / "लाइभ अनुवाद" —
    /// is the shipped, catalog-backed name for this feature (it titles its
    /// Settings row). Reusing it keeps the feature's name in one place instead
    /// of adding a second string that would have to mean the same thing.
    let displayNameKey = LiveTranslateEntry.labelKey

    private let observabilityBus: ObservabilityBus
    private let makeDependencies: LiveTranslateSessionFactory

    /// The locale the feature was opened in, captured by `handle` and consumed
    /// by `presentationView(for:)` — the shipped plugins' own handoff shape
    /// (the protocol splits "handle" from "present the view" and hands no
    /// context to the second call).
    private var pendingLocale: Locale?

    /// The session the last `handle` built, handed to `presentationView(for:)`
    /// — the same handoff `ApplianceHelperPlugin.pendingRequest` performs, and
    /// the reason the two protocol calls cannot build two different sessions.
    private var pendingSession: LiveTranslateSessionDependencies?

    init(observabilityBus: ObservabilityBus,
         makeDependencies: @escaping LiveTranslateSessionFactory) {
        self.observabilityBus = observabilityBus
        self.makeDependencies = makeDependencies
    }

    /// Universal: this feature is not geography- or language-gated. The
    /// recognition and translation layers decide per string what they can do.
    func isApplicable(locale: Locale) -> Bool { true }

    var intentContribution: PluginIntentContribution {
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
        pendingLocale = context.locale
        guard let dependencies = makeDependencies(context.locale) else {
            // The one thing that can stop entry is the app layer being unable
            // to assemble a session, and that is said out loud rather than
            // returned as a success with no view (failure-table row 23). The
            // message names no cause the feature cannot verify.
            pendingSession = nil
            observabilityBus.emit(Self.event("live_translate_open_failed",
                                             errorCode: "session_construction_failed"))
            return .failed(spokenApology: L10n.str(Self.unavailableKey, locale: context.locale))
        }
        pendingSession = dependencies
        observabilityBus.emit(Self.event("live_translate_opened"))
        return .spokenAndPresented(L10n.str(Self.spokenKey, locale: context.locale))
    }

    /// The view for the result the handler returned. Built from the session
    /// `handle` already assembled, so opening builds exactly one.
    func presentationView(for result: PluginResult) -> AnyView? {
        guard case .spokenAndPresented = result else { return nil }
        return sessionView(dependencies: pendingSession)
    }

    /// The Home tile's entry (FR-LCT-001, T-027): a tap is already an
    /// unambiguous intent, so it takes the same route the voice entry takes
    /// minus the utterance — assemble one session, and return the same view.
    /// `nil` when the app layer could not assemble one; the caller speaks the
    /// apology rather than presenting an empty screen.
    func tileView(locale: Locale) -> AnyView? {
        guard let dependencies = makeDependencies(locale) else {
            observabilityBus.emit(Self.event("live_translate_open_failed",
                                             errorCode: "session_construction_failed"))
            return nil
        }
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
