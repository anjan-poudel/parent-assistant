import Foundation
@testable import ElderlyAssistant

/// Records every `CallLinkOpening` interaction in order, so a test can pin
/// the probe-then-open sequence, the exact URLs offered, and — most
/// importantly for T-107 — that a rejected input never reaches this seam at
/// all (the `CallLinkOpening` house pattern, mirroring the YouTube/call-flow
/// fakes; V-4).
///
/// `grantsOpen` is the scripted probe answer: `true` models the Spotify app
/// being installed, `false` models its absence.
final class RecordingSpotifyLinkOpener: CallLinkOpening {

    /// One seam interaction, in call order.
    enum Event: Equatable {
        case canOpenURL(URL)
        case open(URL)
    }

    private(set) var events: [Event] = []
    private let grantsOpen: Bool

    init(grantsOpen: Bool) {
        self.grantsOpen = grantsOpen
    }

    /// The URLs the probe was asked about, in order.
    var probedURLs: [URL] {
        events.compactMap { event in
            if case .canOpenURL(let url) = event { return url }
            return nil
        }
    }

    /// The URLs the seam actually opened, in order.
    var openedURLs: [URL] {
        events.compactMap { event in
            if case .open(let url) = event { return url }
            return nil
        }
    }

    func canOpenURL(_ url: URL) -> Bool {
        events.append(.canOpenURL(url))
        return grantsOpen
    }

    func open(_ url: URL) {
        events.append(.open(url))
    }
}
