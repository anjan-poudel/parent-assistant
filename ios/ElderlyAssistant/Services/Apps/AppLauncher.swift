import Foundation
import UIKit

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
///
/// The same catalog and seam back the voice app launcher (2026-09-16):
/// entries added for it carry spoken `aliases` (keyword rules), a
/// `webFallback` where the design says "web", and one `Kind.camera` entry
/// — the only one with no URL at all, because iOS has no camera scheme a
/// third-party app can use.
final class AppLauncher {

    /// How a catalog entry launches (voice app launcher, 2026-09-16).
    ///
    /// `.url` is the norm: probe the entry's `rootURL` with `canOpenURL`,
    /// then open it (or offer its web fallback when the app is absent).
    ///
    /// `.camera` is the single special case. iOS gives third-party apps
    /// NO usable URL scheme for the Camera app — the community
    /// `camera://` only resolves inside Shortcuts (iOS 17.2+), so from
    /// this app it fails with "address is invalid". The launcher resolves
    /// a `.camera` entry to an in-app `UIImagePickerController` instead,
    /// which is why that entry carries no scheme and no URL at all. The
    /// picker presentation lives with the `launcher.open` plugin, not
    /// here.
    enum Kind: Equatable {
        case url
        case camera
    }

    /// What a launch of a catalog entry will ACTUALLY open on this phone —
    /// the probe, the fallback and the honest refusal resolved in one
    /// place, so the two launch call sites (the voice request and the tile
    /// executor) can never disagree about what a tap or a yes does.
    ///
    /// [APP-LAUNCHER F9] `.settingsFallback` exists because the Settings
    /// entries ride the PRIVATE `App-Prefs` scheme: when Apple's probe does
    /// not answer (the pane ids are undocumented and shift between
    /// releases), the entry must still launch something real rather than
    /// claim "not installed" about an app that ships with iOS. The public
    /// `UIApplication.openSettingsURLString` — already the seam four other
    /// screens in this app use — opens the Settings root, and the caller
    /// says so out loud (the pane is best-effort; the Settings app is the
    /// fallback, disclosed, never a silent substitution).
    enum LaunchPlan: Equatable {
        /// The entry's own URL answered the probe and will be opened.
        case app
        /// The app is absent but carries a `webFallback` (Facebook,
        /// Instagram, YouTube, WhatsApp, …).
        case webFallback
        /// A Settings entry whose `App-Prefs` pane did not answer: the
        /// public Settings root opens instead.
        case settingsFallback
        /// Nothing can be opened — say so honestly, open nothing.
        case unavailable
        /// The in-app camera picker (`Kind.camera`).
        case camera
    }

    /// A catalog app. `id` is the stable storage key (UserDefaults
    /// "quickAccessApps"), `nameKey` resolves in the UI's locale (views
    /// use `Text(LocalizedStringKey)`, non-View code uses `L10n.str`),
    /// `systemImage` is the SF Symbol fallback tile/badge glyph, and
    /// `scheme` is the custom URL scheme that both the installed-probe
    /// and the open use. `imageName` (2026-09-07) names the app's
    /// OFFICIAL multicolor logo from `AppIcons.xcassets` (Wikimedia
    /// Commons PNGs — see the catalog's README for sources); the logo is
    /// drawn as-is, so no tint travels with it. nil imageName keeps the
    /// SF Symbol stand-in.
    struct App: Equatable, Identifiable {
        let id: String
        let nameKey: String
        let systemImage: String
        /// Custom URL scheme, declared in Info.plist
        /// LSApplicationQueriesSchemes (e.g. "whatsapp"). nil for the one
        /// `.camera` entry, which opens no URL.
        let scheme: String?
        /// Asset-catalog image name for the official brand logo, or nil
        /// for the SF Symbol stand-in.
        let imageName: String?
        /// URL entry vs in-app camera picker (see `Kind`).
        let kind: Kind
        /// Full launch URL when the bare scheme root is NOT the URL to
        /// open (`App-Prefs:root=WIFI` — no `//`, and iOS opens the pane
        /// only from the full form). nil for every entry whose launch URL
        /// is its `rootURL` — which is all but the Settings panes.
        /// Must be nil for a `.camera` entry (it launches no URL).
        let urlOverride: String?
        /// Web fallback a launch offers when a third-party app is not
        /// installed (spec: "web" fallback — Facebook, Instagram,
        /// YouTube, WhatsApp). nil means no fallback exists, and the
        /// launcher says so honestly instead of opening Safari blind.
        let webFallback: URL?
        /// Spoken aliases (English + Devanagari, lowercase Latin) the
        /// voice keyword rules match against — e.g. "camera" /
        /// "क्यामेरा". Kept minimal and separate from `nameKey`: the
        /// display name is what the UI shows, these are the words an
        /// elder actually says. Exact full-lexeme matching only (the
        /// Devanagari substring-grapheme regression).
        let aliases: [String]

        init(id: String, nameKey: String, systemImage: String, scheme: String?,
             imageName: String? = nil, kind: Kind = .url,
             urlOverride: String? = nil, webFallback: URL? = nil,
             aliases: [String] = []) {
            self.id = id
            self.nameKey = nameKey
            self.systemImage = systemImage
            self.scheme = scheme
            self.imageName = imageName
            self.kind = kind
            self.urlOverride = urlOverride
            self.webFallback = webFallback
            self.aliases = aliases
        }

        /// The URL `canOpenURL` probes and `open` opens (e.g.
        /// `whatsapp://`). nil for a `.camera` entry — there is no URL to
        /// probe, and `isInstalled`/`open` answer in-process instead.
        ///
        /// Apple's own telephony schemes are the exception (tel-scheme
        /// fix, 2026-09-07): `tel` and `sms` root URLs are built WITHOUT
        /// slashes (`tel:`, `sms:`). iOS does not handle the slashed
        /// `tel://` form when the number is EMPTY — it shows an
        /// Open/Cancel confirmation sheet that then opens nothing — while
        /// the slashes-less `tel:` opens the Phone app's dialer and
        /// `canOpenURL("tel:")` is the honest probe. Every other catalog
        /// scheme keeps `scheme://`, which is the form third-party apps
        /// register — except the Settings panes, which carry the full
        /// `App-Prefs:root=…` URL in `urlOverride`.
        var rootURL: URL? {
            if let urlOverride { return URL(string: urlOverride) }
            guard let scheme else { return nil }
            if scheme == "tel" || scheme == "sms" {
                return URL(string: "\(scheme):")
            }
            return URL(string: "\(scheme)://")
        }

        /// [APP-LAUNCHER F9] Whether this entry is a deep link into the
        /// SYSTEM Settings app (the root or one of its panes) rather than a
        /// third-party app of its own. The distinction decides what a
        /// failed probe means: a pane whose private `App-Prefs` URL did not
        /// answer is still launchable through the public
        /// `UIApplication.openSettingsURLString`, while an absent
        /// third-party app is not (see `LaunchPlan.settingsFallback`).
        ///
        /// Derived from the scheme rather than stored: the `App-Prefs`
        /// scheme IS the pane marker, and a per-entry flag could drift
        /// from it.
        var isSettingsSurface: Bool {
            scheme?.lowercased() == "app-prefs"
        }
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
        // [APP-LAUNCHER F8] The calendar's spoken aliases — the same
        // vocabulary the keyword fast path reads (`KeywordIntentRule`'s
        // `appWords`), so "पात्रो खोल" / "calendar khol" launches it on
        // both stacks.
        App(id: "calendar", nameKey: "app.name.calendar", systemImage: "calendar", scheme: "calshow",
            aliases: ["calendar", "पात्रो"]),
        App(id: "maps", nameKey: "app.name.maps", systemImage: "map.fill", scheme: "maps"),
        // Voice app-launcher additions (2026-09-16) — the launches an
        // elder asks for by name. The camera is the one entry with NO
        // URL (see `Kind.camera`): iOS exposes no workable camera scheme
        // to third-party apps, so it resolves to the in-app picker.
        // Everything else here is community-tier (scheme verified on a
        // device — see the design's v1 catalog) except Health, which
        // Apple documents, and the already-whitelisted calshow above.
        App(id: "camera", nameKey: "app.name.camera", systemImage: "camera.circle.fill",
            scheme: nil, kind: .camera,
            aliases: ["camera", "क्यामेरा"]),
        App(id: "photos", nameKey: "app.name.photos", systemImage: "photo.on.rectangle.angled",
            scheme: "photos-redirect",
            aliases: ["photos", "photo", "फोटो"]),
        // The Settings entry and its panes are deep links into one app,
        // not apps of their own. iOS opens a pane only from the full
        // `App-Prefs:root=…` URL (no `//`), which is what `urlOverride`
        // carries; the SCHEME (what the probe needs declared) is
        // `App-Prefs`. Both casings are whitelisted because the exact one
        // iOS answers is device-dependent.
        App(id: "settings", nameKey: "app.name.settings", systemImage: "gearshape.fill",
            scheme: "App-Prefs", urlOverride: "App-Prefs:root=",
            aliases: ["settings", "सेटिङ"]),
        App(id: "settingswifi", nameKey: "app.name.settingswifi", systemImage: "wifi",
            scheme: "App-Prefs", urlOverride: "App-Prefs:root=WIFI",
            aliases: ["wifi", "wi-fi", "वाइफाइ"]),
        App(id: "settingsbluetooth", nameKey: "app.name.settingsbluetooth",
            systemImage: "dot.radiowaves.left.and.right", scheme: "App-Prefs",
            urlOverride: "App-Prefs:root=Bluetooth",
            aliases: ["bluetooth", "ब्लुटुथ"]),
        App(id: "settingsdisplay", nameKey: "app.name.settingsdisplay", systemImage: "sun.max.fill",
            scheme: "App-Prefs", urlOverride: "App-Prefs:root=DISPLAY",
            aliases: ["display", "brightness", "डिस्प्ले"]),
        App(id: "settingsaccessibility", nameKey: "app.name.settingsaccessibility",
            systemImage: "accessibility", scheme: "App-Prefs",
            urlOverride: "App-Prefs:root=ACCESSIBILITY",
            aliases: ["accessibility", "पहुँचयोग्यता"]),
        // [APP-LAUNCHER F12] `mausam` (the romanized मौसम) lives HERE, not
        // only in the keyword table: the two paths must accept one
        // vocabulary, and the model path resolves through these aliases —
        // a keyword-only spelling was reachable on the fast path and
        // rejected by the interpreter's `app` entity.
        App(id: "weather", nameKey: "app.name.weather", systemImage: "cloud.sun.fill",
            scheme: "weather",
            aliases: ["weather", "मौसम", "mausam"]),
        App(id: "magnifier", nameKey: "app.name.magnifier", systemImage: "magnifyingglass",
            scheme: "apple-magnifier",
            aliases: ["magnifier", "म्याग्निफायर"]),
        App(id: "health", nameKey: "app.name.health", systemImage: "heart.fill",
            scheme: "x-apple-health",
            aliases: ["health", "स्वास्थ्य"]),
        // Official multicolor logos (Wikimedia Commons PNGs, 2026-09-07 —
        // see AppIcons.xcassets/README.md for sources) render as-is on
        // the white tile; no per-app tint needed. imo (below) is the one
        // third-party app without one.
        //
        // The four third-party apps the spec gives a "web" fallback carry
        // it here; a launch offers it only when the probe says the app is
        // absent.
        // [APP-LAUNCHER F12] All three Devanagari spellings Whisper
        // produces for "WhatsApp" are catalog aliases — the keyword table
        // used to carry व्हाट्सएप/वाट्सएप privately, so a model that echoed
        // one of them got "I don't know an app called …".
        App(id: "whatsapp", nameKey: "app.name.whatsapp", systemImage: "phone.arrow.down.left.fill", scheme: "whatsapp", imageName: "appIcon.whatsapp", webFallback: URL(string: "https://web.whatsapp.com/"), aliases: ["whatsapp", "ह्वाट्सएप", "व्हाट्सएप", "वाट्सएप"]),
        App(id: "messenger", nameKey: "app.name.messenger", systemImage: "bolt.fill", scheme: "fb-messenger", imageName: "appIcon.messenger"),
        App(id: "facebook", nameKey: "app.name.facebook", systemImage: "person.2.fill", scheme: "fb", imageName: "appIcon.facebook", webFallback: URL(string: "https://www.facebook.com/"), aliases: ["facebook", "फेसबुक"]),
        App(id: "instagram", nameKey: "app.name.instagram", systemImage: "camera.fill", scheme: "instagram", imageName: "appIcon.instagram", webFallback: URL(string: "https://www.instagram.com/"), aliases: ["instagram", "इन्स्टाग्राम"]),
        App(id: "youtube", nameKey: "app.name.youtube", systemImage: "play.rectangle.fill", scheme: "youtube", imageName: "appIcon.youtube", webFallback: URL(string: "https://www.youtube.com/"), aliases: ["youtube", "युट्युब"]),
        App(id: "gmail", nameKey: "app.name.gmail", systemImage: "envelope.circle.fill", scheme: "googlegmail", imageName: "appIcon.gmail"),
        App(id: "googlemaps", nameKey: "app.name.googlemaps", systemImage: "location.fill", scheme: "comgooglemaps", imageName: "appIcon.googlemaps"),
        App(id: "chrome", nameKey: "app.name.chrome", systemImage: "globe", scheme: "googlechrome", imageName: "appIcon.googlechrome"),
        App(id: "zoom", nameKey: "app.name.zoom", systemImage: "videocam.fill", scheme: "zoomus", imageName: "appIcon.zoom"),
        App(id: "telegram", nameKey: "app.name.telegram", systemImage: "paperplane.fill", scheme: "tg", imageName: "appIcon.telegram"),
        App(id: "viber", nameKey: "app.name.viber", systemImage: "phone.badge.waveform.fill", scheme: "viber", imageName: "appIcon.viber"),
        // IMO has NO clean-licensed official logo (simple-icons removed
        // it over trademark concerns and Wikimedia Commons hosts none) —
        // the SF Symbol stand-in stays, and the catalog must not pretend
        // otherwise.
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

    /// Case- and diacritic-insensitive folding used by `search` and
    /// `app(matchingSpoken:)`.
    private static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive],
                  locale: Locale(identifier: "en"))
    }

    /// Catalog resolution for a SPOKEN app name (voice app launcher,
    /// 2026-09-16): the interpreter's `app` entity is usually a catalog id
    /// ("whatsapp", "camera"), but a model may echo what the elder
    /// actually said ("फोटो", "Wi-Fi Settings", "क्यामेरा"), so the match
    /// tries, in order, the id, an entry's spoken `aliases` (the exact
    /// words keyword rules use), and the entry's localized display name in
    /// the active locale and in English.
    ///
    /// Matching is EXACT, full-lexeme, case/diacritic-folded — never a
    /// substring. A phrase ("क्यामेरा खोल", "open the camera") must NOT
    /// resolve: partial matching is the Devanagari Character-cluster
    /// regression this catalog's aliases are deliberately immune to, and a
    /// near-miss guess would launch the wrong app on an elder's phone.
    /// No match returns nil, and the caller says so honestly.
    static func app(matchingSpoken raw: String, locale: Locale) -> App? {
        let needle = folded(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return nil }
        let english = Locale(identifier: "en")
        return catalog.first { app in
            folded(app.id) == needle
                || app.aliases.contains { folded($0) == needle }
                || folded(L10n.str(app.nameKey, locale: locale)) == needle
                || folded(L10n.str(app.nameKey, locale: english)) == needle
        }
    }

    /// Whether the app answers its scheme probe — the honest "is it on
    /// this phone" check. Only meaningful because the scheme is declared
    /// in Info.plist LSApplicationQueriesSchemes (unlike an https
    /// universal link, which `canOpenURL` can't distinguish from Safari).
    ///
    /// A `.camera` entry has no URL to probe: the camera UI is
    /// in-process, so it is always available to launch. Whether the
    /// DEVICE actually has a usable camera (simulator, camera-less
    /// hardware) or the permission was refused is answered honestly at
    /// capture time, where the failure is, not here.
    ///
    /// [APP-LAUNCHER F9] A Settings entry is present even when its private
    /// `App-Prefs` pane does not answer: `launchPlan` opens the public
    /// Settings root instead, so reporting "not installed" here would hide
    /// every Settings row on a phone where Apple closed that door — the
    /// app IS on the phone, only the pane deep link is not.
    ///
    /// `.webFallback` stays "not installed" on purpose: an absent WhatsApp
    /// is absent, and this probe is what the picker's "Installed" caption
    /// and its add gate read. The launch executor still offers the website
    /// (disclosed) from `launchPlan`; the two questions — "is it here?" and
    /// "can a launch show something real?" — are deliberately different.
    func isInstalled(_ app: App) -> Bool {
        switch launchPlan(for: app) {
        case .app, .camera, .settingsFallback:
            return true
        case .webFallback, .unavailable:
            return false
        }
    }

    /// [APP-LAUNCHER F9] Resolves what a launch of `app` will actually
    /// open, by probing the entry's own URL — the ONE place the probe, the
    /// web fallback and the Settings fallback are weighed together.
    ///
    /// Precedence, and why:
    ///  1. the entry's own URL, when the probe answers (the only case in
    ///     which the elder gets the app they asked for);
    ///  2. for a SETTINGS entry, the public Settings root — the pane ids
    ///     are private API and may not answer at all, but the Settings app
    ///     ships with iOS, so the launch is always possible;
    ///  3. the entry's web fallback, when it has one;
    ///  4. otherwise `.unavailable`: nothing is opened and the caller says
    ///     so honestly.
    ///
    /// `canOpenURL` is called exactly once per resolution, and the caller
    /// opens the plan it was handed — never a second, differently-probed
    /// decision.
    func launchPlan(for app: App) -> LaunchPlan {
        if app.kind == .camera { return .camera }
        guard let url = app.rootURL else { return .unavailable }
        if opener.canOpenURL(url) { return .app }
        if app.isSettingsSurface { return settingsFallbackURL() == nil ? .unavailable : .settingsFallback }
        return app.webFallback == nil ? .unavailable : .webFallback
    }

    /// Opens the app's launch URL. Deliberately dumb — the caller probes
    /// `launchPlan` first and speaks honestly when the app is absent
    /// (never a silent dead tap), exactly like the openers in
    /// `CallLinks`.
    ///
    /// A `.camera` entry opens nothing here: it has no URL, and its
    /// launch is the in-app picker the `launcher.open` plugin presents
    /// (T4 of the 2026-09-16 launcher plan). Callers that announce a
    /// launch must therefore not treat `.camera` as "opened" — the
    /// plugin path owns that entry, and the Home quick-access tile is
    /// wired to it there.
    func open(_ app: App) {
        guard let url = app.rootURL else { return }
        opener.open(url)
    }

    /// Opens the entry's WEB fallback (its universal `https://` link, which
    /// iOS routes into the app when it is installed and to Safari when it
    /// is not) through the same opener seam as every other launch URL.
    ///
    /// Returns false — opening nothing — when the entry has no fallback
    /// (only Facebook, Instagram, YouTube and WhatsApp do, per the
    /// design's v1 catalog): the caller then says the honest "not
    /// installed" line instead of sending the elder to Safari on a page
    /// that has nothing to do with what they asked for.
    @discardableResult
    func openWebFallback(_ app: App) -> Bool {
        guard let url = app.webFallback else { return false }
        opener.open(url)
        return true
    }

    /// [APP-LAUNCHER F9] Opens the PUBLIC Settings deep link
    /// (`UIApplication.openSettingsURLString`) through the same opener
    /// seam — the fallback for a Settings entry whose private `App-Prefs`
    /// pane did not answer. Returns false (opening nothing) when no
    /// fallback URL exists, so the caller can say the honest
    /// not-installed line instead of announcing a screen that never
    /// appears.
    ///
    /// The URL is injected so a test can script the App-Prefs probe
    /// without a device — and so the private-scheme dependency stays
    /// visible in one place (spec: the launcher degrades to documented
    /// API, never to a silent dead tap).
    @discardableResult
    func openSettingsFallback() -> Bool {
        guard let url = settingsFallbackURL() else { return false }
        opener.open(url)
        return true
    }

    private let opener: CallLinkOpening

    /// The public Settings deep link, read lazily (see
    /// `openSettingsFallback`). `UIApplication.openSettingsURLString` is a
    /// constant string, so touching it needs no running application.
    private let settingsFallbackURL: () -> URL?

    init(opener: CallLinkOpening = SystemCallLinkOpener(),
         settingsFallbackURL: @escaping () -> URL? = {
             URL(string: UIApplication.openSettingsURLString)
         }) {
        self.opener = opener
        self.settingsFallbackURL = settingsFallbackURL
    }
}
