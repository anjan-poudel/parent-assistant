import Foundation
import SwiftUI

/// [YOUTUBE] (2026-09-08) YouTube voice plugin — the interpreter-side
/// twin of the deterministic `YouTubeRoute` marker stage: when the LLM
/// itself recognizes a "play/search something on YouTube" intent it
/// fires `youtube.play` with a `query` entity, and this plugin executes
/// exactly the same honest behavior the router stage does:
///
///   · API key configured (`YouTubeConfigStore`): fetch the TOP video
///     from the YouTube Data API v3, open `youtube://watch` (https
///     fallback when the app is absent), and return the title-bearing
///     confirmation — spoken by the router's plugin dispatch.
///   · No key: open the SEARCH deeplink directly
///     (`youtube://www.youtube.com/results` → https fallback) and say
///     so — the accepted search-only MVP.
///   · Any failure (network, quota, empty, malformed): an honest
///     localized `.failed` line — never a fabricated title.
///
/// The deterministic stage and this plugin deliberately SHARE
/// `YouTubeTool` (URLs, parse, fetch, open decisions) so the two paths
/// can never drift apart; the router stage is the no-model safety net,
/// the plugin the interpreter's richer slot-filling path.
///
/// Privacy mirrors the tool: observability events carry no query or
/// title text; the title-bearing confirmation is returned as spoken text
/// only.
final class YouTubePlugin: AssistantPlugin {

    let pluginID = "youtube"
    let displayNameKey = "plugin.youtube.name"

    private let configStore: YouTubeConfigStore
    private let transport: LocalToolTransport
    private let linkOpener: CallLinkOpening

    init(configStore: YouTubeConfigStore,
         transport: LocalToolTransport = URLSession.shared,
         linkOpener: CallLinkOpening = SystemCallLinkOpener()) {
        self.configStore = configStore
        self.transport = transport
        self.linkOpener = linkOpener
    }

    func isApplicable(locale: Locale) -> Bool {
        true    // English and Nepali households alike
    }

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(
            actionNames: ["youtube.play"],
            promptFragment: """
            PLUGIN CAPABILITY (YouTube): if the user asks to play or
            search for something on YouTube ("play bhajan on youtube",
            "youtube news", "search youtube for old songs", "युट्युबमा
            गीत चलाऊ", "युट्युबमा रामायण खोज"), set action to "plugin",
            pluginAction to "youtube.play", and pluginEntities to
            {"query": "<what they want to play or search for>"}.
            """
        )
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        guard let query = command.entities["query"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            context.observabilityBus.emit(Self.event("youtube_plugin_no_query", outcome: "failure"))
            return .failed(spokenApology: L10n.str("youtube.unavailable",
                                                   locale: context.locale))
        }

        // No API key — the search deeplink IS the feature (the accepted
        // search-only MVP), disclosed as exactly that.
        guard let apiKey = configStore.apiKey else {
            let outcome = YouTubeTool.openSearch(query: query, opener: linkOpener)
            context.observabilityBus.emit(Self.event(
                "youtube_plugin_search_opened",
                outcome: outcome == .openedApp ? "opened_app" : "opened_web"))
            return .spoken(L10n.fmt("youtube.openingSearch", locale: context.locale, query))
        }

        do {
            let top = try await YouTubeTool.fetchTopResult(query: query,
                                                           apiKey: apiKey,
                                                           transport: transport)
            let outcome = YouTubeTool.openWatch(videoID: top.videoID, opener: linkOpener)
            context.observabilityBus.emit(Self.event(
                "youtube_plugin_played",
                outcome: outcome == .openedApp ? "opened_app" : "opened_web"))
            return .spoken(L10n.fmt("youtube.playing", locale: context.locale, top.title))
        } catch YouTubeTool.FetchError.noResults {
            context.observabilityBus.emit(Self.event("youtube_plugin_no_results", outcome: "failure"))
            return .failed(spokenApology: L10n.str("youtube.notFound", locale: context.locale))
        } catch {
            context.observabilityBus.emit(Self.event("youtube_plugin_failed", outcome: "failure"))
            return .failed(spokenApology: L10n.str("youtube.unavailable",
                                                   locale: context.locale))
        }
    }

    func presentationView(for result: PluginResult) -> AnyView? { nil }

    private static func event(_ type: String, outcome: String) -> ObservabilityEvent {
        ObservabilityEvent(component: "plugin_youtube",
                           eventType: type, durationMs: nil,
                           outcome: outcome, errorCode: nil, metadata: [:])
    }
}
