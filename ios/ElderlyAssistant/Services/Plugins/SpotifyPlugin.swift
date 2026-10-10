import Foundation
import SwiftUI

/// [SPOTIFY] (2026-10-07) T-118 — the interpreter-side Spotify plugin, the
/// `AssistantPlugin` twin of the shipped `YouTubePlugin` (design-l2 §12,
/// §27; FR-SP-006). When the LLM itself recognizes a request that names
/// Spotify it fires `spotify.play` with a `query` entity, and this plugin
/// executes exactly the honest behavior the design assigns to that path:
///
///   · Not linked: the honest `spotify.notLinked` line — the plugin never
///     fabricates a playback claim and never fires into a dead end.
///   · Linked: the session's one token path (`validAccessToken()`, which
///     owns the single bounded refresh), then the shared `SpotifyTool` —
///     search for the top track, then, on a Premium-capable account, one
///     remote-play attempt. Success speaks the title-bearing
///     `spotify.playing` line (spoken only — never carded, never logged).
///   · Free tier, unknown product (L2-D14), or ANY remote-play failure:
///     a single-shot `spotify:track:` deep-link hand-off (`spotify.openApp`
///     on an opened probe, `spotify.appMissing` when the app is absent).
///
/// The plugin is deliberately NOT the degradation ladder (ADR-SP-07): it
/// never refreshes a token, never retries a play, never falls back to
/// YouTube and never chains a second attempt. The router's deterministic
/// music path owns the ladder and the forced-refresh rows of the §13
/// matrix; a plugin turn is one bounded attempt ending in one honest line.
///
/// Privacy (NFR-SP-002, M-1): observability events carry component
/// `plugin_spotify` with `metadata: [:]` on every event and closed
/// outcome vocabularies — the query, the track title and the token have no
/// event field, tool-log line or console write anywhere on this path. The
/// title rides the returned spoken text only.
///
/// Isolation (NFR-SP-012): the plugin holds no mutable state of its own,
/// reads no other plugin, and reaches the network only through
/// `SpotifyTool` and the session seams it is handed.
final class SpotifyPlugin: AssistantPlugin {

    let pluginID = "spotify"
    let displayNameKey = "plugin.spotify.name"

    private let accountSession: SpotifyAccountSession

    /// Retained for §27 interface fidelity; `handle` deliberately never
    /// reads it. Every decision derives from `accountSession` — the
    /// session's status and this store's record are written together, so
    /// they cannot disagree (L2-D5/L2-R2) — and the router's music path
    /// reads the session alone (`spotifyAccountSession?.isLinked`), so the
    /// two paths cannot diverge either. A future surface that needs the
    /// raw record (Settings) may read this property instead of a second
    /// store reference.
    private let credentialStore: SpotifyCredentialStore

    private let transport: LocalToolTransport
    private let linkOpener: CallLinkOpening

    init(accountSession: SpotifyAccountSession,
         credentialStore: SpotifyCredentialStore,
         transport: LocalToolTransport = URLSession.shared,
         linkOpener: CallLinkOpening = SystemCallLinkOpener()) {
        self.accountSession = accountSession
        self.credentialStore = credentialStore
        self.transport = transport
        self.linkOpener = linkOpener
    }

    func isApplicable(locale: Locale) -> Bool {
        true    // English and Nepali households alike
    }

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(
            actionNames: ["spotify.play"],
            // Trimmed under C-1 to fit the YouTube fragment's measured
            // budget (see the size model pinned in `SpotifyPluginTests`),
            // keeping the `spotify.play` + `query` tokens and the L2-D15
            // sentence that routes general/bare music requests to the
            // `music` intent — this fragment handles explicit-Spotify
            // requests only; the router's ladder owns everything else.
            promptFragment: """
            PLUGIN CAPABILITY (Spotify): if the user asks to play or search
            on Spotify ("स्पोटिफाइमा गीत चलाऊ"), set action to "plugin",
            pluginAction to "spotify.play", and pluginEntities to
            {"query": "<what they want>"}. General music or bhajan requests without
            the word Spotify are NOT this capability — use the "music" intent
            for those.
            """
        )
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        // The trimmed query is the one entity this plugin's fragment
        // declares; empty means the model addressed Spotify but named
        // nothing to play — the honest unavailable line, never a fabricated
        // search term.
        guard let query = command.entities["query"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            context.observabilityBus.emit(Self.event("spotify_plugin_no_query", outcome: "failure"))
            return .failed(spokenApology: L10n.str("spotify.unavailable",
                                                   locale: context.locale))
        }

        guard await accountSession.isLinked else {
            return notLinkedResult(context: context)
        }

        // The session's one token path (state machine B): it owns the
        // single bounded refresh; this plugin only reads its verdict.
        let accessToken: String
        switch await accountSession.validAccessToken() {
        case .success(let token):
            accessToken = token
        case .failure(.revoked):
            // The provider's definitive rejection: the session already
            // wiped (or there was nothing left to read) — the unlinked
            // treatment, exactly as if no account were linked (row 10's
            // shape, scoped to this plugin turn).
            return notLinkedResult(context: context)
        case .failure:
            // No token could be obtained honestly (transport, refresh,
            // storage): there is no search to run — the honest
            // unavailable line.
            context.observabilityBus.emit(Self.event("spotify_plugin_failed", outcome: "failure"))
            return .failed(spokenApology: L10n.str("spotify.unavailable",
                                                   locale: context.locale))
        }

        let track: SpotifyTool.TrackResult
        do {
            track = try await SpotifyTool.fetchTopTrack(query: query,
                                                        accessToken: accessToken,
                                                        transport: transport)
        } catch SpotifyTool.FetchError.noResults {
            context.observabilityBus.emit(Self.event("spotify_plugin_no_results", outcome: "failure"))
            return .failed(spokenApology: L10n.str("spotify.notFound",
                                                   locale: context.locale))
        } catch {
            // Every other fetch classification shares the one honest
            // unavailable line (the YouTube twin's mapping).
            context.observabilityBus.emit(Self.event("spotify_plugin_failed", outcome: "failure"))
            return .failed(spokenApology: L10n.str("spotify.unavailable",
                                                   locale: context.locale))
        }

        // Remote play is attempted only when the account is
        // Premium-capable (L2-D14); free and unknown hand the validated
        // track straight to the app.
        let product = await accountSession.product
        if product == .premium,
           await playRemote(track: track, accessToken: accessToken, context: context) {
            return .spoken(L10n.fmt("spotify.playing", locale: context.locale, track.title))
        }

        return openDeepLink(track: track, context: context)
    }

    func presentationView(for result: PluginResult) -> AnyView? { nil }

    // MARK: - Play legs

    /// One single-shot remote-play attempt for a Premium-capable account
    /// (ADR-SP-13: the attempt is terminal whatever its outcome). Returns
    /// true only on a provider 2xx; a 401 is NOT special here — the plugin
    /// is not the ladder, performs no refresh and no second attempt, and
    /// any failure falls through to the deep link in `handle`.
    private func playRemote(track: SpotifyTool.TrackResult,
                            accessToken: String,
                            context: PluginExecutionContext) async -> Bool {
        guard let uri = SpotifyTool.trackURI(id: track.id) else {
            // Defensive: `fetchTopTrack` validated the id as 22-char
            // base62 before returning, so this is unreachable from
            // `handle`; the deep-link step's own guard owns the honest
            // treatment.
            return false
        }
        do {
            try await SpotifyTool.playTrack(uri: uri,
                                            accessToken: accessToken,
                                            transport: transport)
        } catch {
            return false
        }
        context.observabilityBus.emit(Self.event("spotify_plugin_played", outcome: "success"))
        return true
    }

    /// Probe-and-open the validated `spotify:track:` deep link through the
    /// opener seam (V-4: the probe alone decides). An opened hand-off is
    /// `opened_app` + the spoken `spotify.openApp` line; a not-opened probe
    /// is the app-absent terminal — no chaining, no second URL.
    private func openDeepLink(track: SpotifyTool.TrackResult,
                              context: PluginExecutionContext) -> PluginResult {
        guard let uri = SpotifyTool.trackURI(id: track.id) else {
            // Defensive (see `playRemote`); mirrors the router's own
            // deep-link guard (`CommandRouter.executeMusicDeepLink`),
            // which treats an unbuildable URI as app-absent.
            return appMissingResult(context: context)
        }
        switch SpotifyTool.open(uri, opener: linkOpener) {
        case .opened:
            context.observabilityBus.emit(Self.event("spotify_plugin_play_opened", outcome: "opened_app"))
            return .spoken(L10n.str("spotify.openApp", locale: context.locale))
        case .notOpened:
            return appMissingResult(context: context)
        }
    }

    // MARK: - Honest terminals

    private func notLinkedResult(context: PluginExecutionContext) -> PluginResult {
        context.observabilityBus.emit(Self.event("spotify_plugin_not_linked", outcome: "failure"))
        return .failed(spokenApology: L10n.str("spotify.notLinked", locale: context.locale))
    }

    private func appMissingResult(context: PluginExecutionContext) -> PluginResult {
        context.observabilityBus.emit(Self.event("spotify_plugin_app_missing", outcome: "failure"))
        return .failed(spokenApology: L10n.str("spotify.appMissing", locale: context.locale))
    }

    // MARK: - Observability

    /// The one event shape this component emits (§12): component
    /// `plugin_spotify`, no duration, a closed outcome string, no error
    /// code and — deliberately — no metadata parameter at all, so no
    /// query, title, id or token has anywhere to go (NFR-SP-002).
    private static func event(_ type: String, outcome: String) -> ObservabilityEvent {
        ObservabilityEvent(component: "plugin_spotify",
                           eventType: type, durationMs: nil,
                           outcome: outcome, errorCode: nil, metadata: [:])
    }
}
