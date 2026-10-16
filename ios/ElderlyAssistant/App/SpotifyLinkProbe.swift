import Foundation

/// [DIAGNOSTIC 2026-10-14 — temporary] Drives the Spotify link flow from a
/// launch argument so the consent presentation can be verified without
/// on-device taps (the `MessengerProbe` precedent). Inert without an
/// argument; DEBUG-only. Remove with the root-cause fix.
///
/// `-spotifyLink` runs the normal path (system session, default-browser
/// fallback); `-spotifyLinkExternal` drives the default-browser seam
/// directly — the path the device takes after the iOS 27.0.1 `start()`
/// refusal.
enum SpotifyLinkProbe {

    static func runIfRequested(on coordinator: AppCoordinator) {
        let arguments = ProcessInfo.processInfo.arguments
        let mode: Mode = arguments.contains("-spotifyLinkExternal") ? .external
            : arguments.contains("-spotifyLink") ? .normal
            : .none
        guard mode != .none else { return }
        Task { @MainActor in
            // Let the window/scene settle before presenting anything.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let pkce = SpotifyAuthFlow.makePKCE()
            let state = UUID().uuidString
            guard let url = SpotifyAuthFlow.authorizeURL(clientID: "1aa5ca19720646e4bc46dea1acac5d37",
                                                         state: state,
                                                         challenge: pkce.challenge) else {
                print("[SPOTIFY-PROBE] no authorize URL")
                return
            }
            do {
                let seam: SpotifyAuthSession = mode == .external
                    ? ExternalBrowserSpotifyAuthSession()
                    : ASWebSpotifyAuthSession()
                let callback = try await seam.authorize(url: url,
                                                        callbackURLScheme: SpotifyAuthFlow.callbackScheme)
                print("[SPOTIFY-PROBE] callback: \(callback.absoluteString)")
            } catch {
                print("[SPOTIFY-PROBE] error: \(String(describing: error))")
            }
        }
    }

    private enum Mode: Equatable { case none, normal, external }
}
