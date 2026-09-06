import Foundation

/// Catalog + launch seam for the Quick Access Apps feature (Home quick-
/// access row + Settings picker, 2026-09-06). iOS cannot enumerate
/// installed apps, so the picker searches this curated built-in catalog
/// and probes each app's custom URL scheme via `canOpenURL` — which is why
/// every catalog scheme must be declared in Info.plist
/// `LSApplicationQueriesSchemes` (cap 50; `AppLauncherTests` pins the
/// invariant against the real Info.plist).
///
/// Pure logic (catalog, stored-order mapping, validation, search) is
/// `static` and unit-tested without platform glue; installed/open go
/// through the same `CallLinkOpening` seam the call/message flows fake in
/// tests (`SystemCallLinkOpener` in production).
final class AppLauncher {

    /// A catalog app. `id` is the stable storage key (UserDefaults
    /// "quickAccessApps"), `nameKey` resolves in the UI's locale (views
    /// use `Text(LocalizedStringKey)`, non-View code uses `L10n.str`),
    /// `systemImage` is the SF Symbol on the tile/badge, and `scheme` is
    /// the custom URL scheme that both the installed-probe and the open
    /// use.
    struct App: Equatable, Identifiable {
        let id: String
        let nameKey: String
        let systemImage: String
        /// Custom URL scheme, declared in Info.plist
        /// LSApplicationQueriesSchemes (e.g. "whatsapp").
        let scheme: String

        /// The scheme-only root URL `canOpenURL` probes and `open` opens
        /// (e.g. `whatsapp://`). The schemes are compile-time constants,
        /// so the forced unwrap can never trap.
        var rootURL: URL { URL(string: "\(scheme)://")! }
    }

    /// The curated catalog, in display order: Apple built-ins first, then
    /// the commonly-installed third-party apps (schemes researched
    /// 2026-09 — each must be declared in LSApplicationQueriesSchemes for
    /// `canOpenURL` to answer honestly).
    static let catalog: [App] = [
        App(id: "phone", nameKey: "app.name.phone", systemImage: "phone.fill", scheme: "tel"),
        App(id: "messages", nameKey: "app.name.messages", systemImage: "message.fill", scheme: "sms"),
        App(id: "facetime", nameKey: "app.name.facetime", systemImage: "video.fill", scheme: "facetime"),
        App(id: "mail", nameKey: "app.name.mail", systemImage: "envelope.fill", scheme: "message"),
        App(id: "calendar", nameKey: "app.name.calendar", systemImage: "calendar", scheme: "calshow"),
        App(id: "maps", nameKey: "app.name.maps", systemImage: "map.fill", scheme: "maps"),
        App(id: "whatsapp", nameKey: "app.name.whatsapp", systemImage: "phone.arrow.down.left.fill", scheme: "whatsapp"),
        App(id: "messenger", nameKey: "app.name.messenger", systemImage: "bolt.fill", scheme: "fb-messenger"),
        App(id: "facebook", nameKey: "app.name.facebook", systemImage: "person.2.fill", scheme: "fb"),
        App(id: "instagram", nameKey: "app.name.instagram", systemImage: "camera.fill", scheme: "instagram"),
        App(id: "youtube", nameKey: "app.name.youtube", systemImage: "play.rectangle.fill", scheme: "youtube"),
        App(id: "gmail", nameKey: "app.name.gmail", systemImage: "envelope.circle.fill", scheme: "googlegmail"),
        App(id: "googlemaps", nameKey: "app.name.googlemaps", systemImage: "location.fill", scheme: "comgooglemaps"),
        App(id: "chrome", nameKey: "app.name.chrome", systemImage: "globe", scheme: "googlechrome"),
        App(id: "zoom", nameKey: "app.name.zoom", systemImage: "videocam.fill", scheme: "zoomus"),
        App(id: "telegram", nameKey: "app.name.telegram", systemImage: "paperplane.fill", scheme: "tg"),
        App(id: "viber", nameKey: "app.name.viber", systemImage: "phone.badge.waveform.fill", scheme: "viber"),
        App(id: "imo", nameKey: "app.name.imo", systemImage: "person.crop.circle.fill", scheme: "imo")
    ]

    /// Hard cap on Home-row favourites — the picker blocks adds and shows
    /// `quickApps.capNote` at this count.
    static let maxFavourites = 8

    /// Catalog lookup by stable id — nil for anything that names no app.
    static func app(for id: String) -> App? {
        catalog.first { $0.id == id }
    }

    /// Stored-order mapping of favourite ids → catalog apps. Unknown ids
    /// (an app removed from the catalog, or a corrupt stored value) are
    /// dropped so a stale preference can't wedge the UI — the same
    /// stale-proof rule `validatedFavouriteIDs` applies on restore.
    static func apps(for ids: [String]) -> [App] {
        ids.compactMap { app(for: $0) }
    }

    /// Pure restore/backstop: dedupe (first occurrence wins), drop ids
    /// that name no catalog app, then cap at `cap`. Never touches
    /// storage or the probe — the coordinator restores through this so
    /// UserDefaults can hold anything and the UI still gets a sane list.
    static func validatedFavouriteIDs(_ ids: [String],
                                      cap: Int = AppLauncher.maxFavourites) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for id in ids {
            guard app(for: id) != nil else { continue }
            guard seen.insert(id).inserted else { continue }
            kept.append(id)
            if kept.count >= cap { break }
        }
        return kept
    }

    /// Pure name search over the catalog, in catalog order. A trimmed,
    /// empty query returns [] (the UI then shows the full sections
    /// instead of a search). Matching is case- and diacritic-insensitive
    /// over the app's localized name in the ACTIVE locale AND in English
    /// plus the raw id — the cross-script net that lets both
    /// "ह्वाट्सएप" (the Nepali name) and "whatsapp" (id / English name)
    /// find WhatsApp in a Nepali session. Devanagari passes the folding
    /// unchanged (no case/diacritics), so Devanagari queries match
    /// Devanagari names exactly.
    static func search(query raw: String, in locale: Locale) -> [App] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let foldedQuery = folded(query)
        let english = Locale(identifier: "en")
        return catalog.filter { app in
            let haystacks = [
                folded(L10n.str(app.nameKey, locale: locale)),
                folded(L10n.str(app.nameKey, locale: english)),
                folded(app.id)
            ]
            return haystacks.contains { $0.contains(foldedQuery) }
        }
    }

    /// Case- and diacritic-insensitive folding used by `search`.
    private static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive],
                  locale: Locale(identifier: "en"))
    }

    /// Whether the app answers its scheme probe — the honest "is it on
    /// this phone" check. Only meaningful because the scheme is declared
    /// in Info.plist LSApplicationQueriesSchemes (unlike an https
    /// universal link, which `canOpenURL` can't distinguish from Safari).
    func isInstalled(_ app: App) -> Bool {
        opener.canOpenURL(app.rootURL)
    }

    /// Opens the app's scheme root URL. Deliberately dumb — the caller
    /// probes `isInstalled` first and speaks honestly when the app is
    /// absent (never a silent dead tap), exactly like the openers in
    /// `CallLinks`.
    func open(_ app: App) {
        opener.open(app.rootURL)
    }

    private let opener: CallLinkOpening

    init(opener: CallLinkOpening = SystemCallLinkOpener()) {
        self.opener = opener
    }
}
