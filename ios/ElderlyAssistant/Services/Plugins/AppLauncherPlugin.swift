import Foundation
import SwiftUI

/// [APP-LAUNCHER] (2026-09-16) The voice app launcher's interpreter-side
/// plugin: "क्यामेरा खोल" / "open WhatsApp" / "सेटिङ खोल" fires
/// `launcher.open` with an `app` entity naming ONE catalog entry, and this
/// plugin turns that into the elder's spoken confirmation.
///
/// Why a plugin (design §Decisions D4): the on-device IntentEncoder is
/// fine-tuned against the core action list (`InterpretedCommand.Action`),
/// so app-launch rides the existing `.plugin` escape hatch and the
/// `IntentPrompt.pluginSections` mechanism — zero core-enum changes, no
/// encoder retraining, and the classifier contract is untouched.
///
/// The plugin owns NO launch state and opens nothing itself. The
/// confirmation machinery it must reuse (`CommandRouter.route`'s
/// follow-up path, `AppCoordinator.handleConfirmationResponse`) belongs to
/// the coordinator — the pending launch, the 45 s window, the honest
/// not-installed line, the web-fallback offer and the actual open all live
/// there, reached through the single `requestLaunch` seam wired in
/// `AppCoordinator.makePluginRegistry()`. That keeps one launch executor
/// for the voice path and the Home quick-access tile, instead of a second,
/// drifting copy inside the plugin.
///
/// The catalog is the shared vocabulary on both sides: the prompt exposes
/// the catalog's own IDs (plus the words an elder actually says), and the
/// coordinator resolves the returned entity through the same catalog.
final class AppLauncherPlugin: AssistantPlugin {

    let pluginID = "app_launcher"
    let displayNameKey = "plugin.appLauncher.name"

    /// Pends a launch for the elder's yes/no and returns the line to
    /// speak — the confirmation question when the launch can still
    /// succeed, or the honest "not installed" line when it cannot (the
    /// elder is never asked to confirm an action that can only fail; a
    /// missing app that HAS a web fallback asks instead, disclosing the
    /// swap). Wired to `AppCoordinator.requestAppLaunch(appID:confidence:)`.
    /// The confidence is threaded through for the flywheel's capture — the
    /// plugin is the only layer that saw the interpreted command's.
    private let requestLaunch: (_ appID: String, _ confidence: Double) -> String

    init(requestLaunch: @escaping (_ appID: String, _ confidence: Double) -> String) {
        self.requestLaunch = requestLaunch
    }

    func isApplicable(locale: Locale) -> Bool {
        true    // English and Nepali households alike
    }

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(
            actionNames: ["launcher.open"],
            promptFragment: """
            PLUGIN CAPABILITY (open an app on the phone): when the user asks
            to OPEN or START an app itself ("open WhatsApp", "सेटिङ खोल",
            "क्यामेरा खोल्नुहोस्", "फोटो खोल"), set action to "plugin",
            pluginAction to "launcher.open", and pluginEntities to
            {"app": "<app>"} where <app> is EXACTLY one of:
            \(Self.spokenVocabulary).
            Use this ONLY to open an app. Do NOT use it when the user wants
            to call or message a person, to play a specific video (that is
            youtube.play), or to set a reminder.
            """
        )
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        // One plugin can hold several actions later; an action this plugin
        // cannot serve is an honest failure, never a silent drop — and the
        // line is the router's own "can't do that" (the same words the
        // elder hears when no plugin resolves an action at all), not the
        // "which app?" question, which would ask about an action nobody
        // requested.
        guard command.actionName == "launcher.open" else {
            context.observabilityBus.emit(Self.event("launcher_unknown_action", outcome: "failure"))
            return .failed(spokenApology: L10n.str("router.pluginUnavailable",
                                                   locale: context.locale))
        }
        let requested = (command.entities["app"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            context.observabilityBus.emit(Self.event("launcher_no_app", outcome: "failure"))
            return .failed(spokenApology: L10n.str("launcher.noApp", locale: context.locale))
        }
        // Resolve against the catalog BEFORE pending anything: an entity
        // that names no app must never reach a confirmation question, and
        // a guess here would open the wrong app on an elder's phone.
        guard let app = AppLauncher.app(matchingSpoken: requested, locale: context.locale) else {
            context.observabilityBus.emit(Self.event("launcher_unknown_app", outcome: "failure"))
            return .failed(spokenApology: L10n.fmt("launcher.unknownApp",
                                                   locale: context.locale, requested))
        }
        context.observabilityBus.emit(Self.event("launcher_resolved", outcome: "success"))
        // The coordinator speaks the returned line through the router's
        // normal plugin delivery (outcome card + speech) — the same route
        // every plugin's reply takes.
        return .spoken(requestLaunch(app.id, command.confidence))
    }

    func presentationView(for result: PluginResult) -> AnyView? { nil }

    /// The catalog IDs and spoken aliases a launch may name, each as its
    /// OWN quoted token — composed from `AppLauncher.catalog` so a new
    /// entry can never be launchable without the model being told about
    /// it. The catalog is the single source of truth on both sides of the
    /// contract; this is only its prompt-shaped view.
    ///
    /// [APP-LAUNCHER F11] One token per value, and why:
    ///
    ///  - `"whatsapp", "ह्वाट्सएप"` — every id and every alias stands
    ///    alone, quoted, so the model is asked to echo a single VALUE. The
    ///    old `id (alias1, alias2)` display form was a human-facing label:
    ///    the "vocabulary" for `settingsdisplay` read as
    ///    `settingsdisplay (display, brightness)`, which is neither a
    ///    catalog id nor an alias — an entity copied out of it resolved to
    ///    nothing, and the elder heard "I don't know an app called …".
    ///  - NO truncation: every alias is offered, not just the first two.
    ///    `AppLauncher.app(matchingSpoken:)` accepts all of them, so
    ///    hiding the third one only made the model guess at a word it was
    ///    never shown (व्हाट्सएप / वाट्सएप are exactly that kind of
    ///    Whisper-produced spelling).
    ///
    /// Aliases are single-token words (see `App.aliases`), so a quoted
    /// token is exactly what the resolver's exact, full-lexeme match
    /// accepts.
    static var spokenVocabulary: String {
        AppLauncher.catalog
            .flatMap { app in [app.id] + app.aliases }
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
    }

    private static func event(_ type: String, outcome: String) -> ObservabilityEvent {
        ObservabilityEvent(component: "plugin_app_launcher",
                           eventType: type, durationMs: nil,
                           outcome: outcome, errorCode: nil, metadata: [:])
    }
}
