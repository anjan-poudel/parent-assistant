import SwiftUI

/// Settings → "Quick apps" (quick-access-apps task, 2026-09-06): manage
/// the apps on the Home quick-access row. iOS cannot enumerate installed
/// apps, so this screen searches a curated built-in catalog
/// (`AppLauncher`) and probes each app's custom URL scheme via
/// `canOpenURL` — an app can be added ONLY when that probe says it is
/// installed on this phone (the schemes are declared in Info.plist
/// LSApplicationQueriesSchemes). The probe runs once per appearance into
/// local `@State`; the coordinator re-probes at launch time and speaks
/// honestly if an app has gone away since the probe.
///
/// Search is the Call leaf's capsule pattern: searching replaces the
/// sections with the filtered catalog; not searching shows "Your apps"
/// (favourites, with removal) and the full catalog with installed badges
/// and add buttons.
struct QuickAccessAppsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var searchText = ""
    /// app.id → installed snapshot from the scheme probe, filled once per
    /// appearance by `probeInstalled()`.
    @State private var installed: [String: Bool] = [:]

    var body: some View {
        LeafScreen(titleKey: "settings.quickApps.title") {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                if isSearching {
                    searchResults
                } else {
                    if !coordinator.favoriteApps.isEmpty {
                        favouritesSection
                    }
                    catalogSection
                    notes
                }
            }
        }
        .task { await probeInstalled() }
    }

    // MARK: - Search

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Big search pill (≥44pt, body-size text, warm card) — the same
    /// capsule shape as the Call leaf's search. Search runs as the user
    /// types — no submit step to fumble.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            TextField("quickApps.search.placeholder", text: $searchText)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(Capsule())
    }

    private var searchResults: some View {
        let results = AppLauncher.search(query: searchText,
                                         in: coordinator.appLanguage.locale)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(results) { app in
                catalogRow(app)
            }
        }
    }

    // MARK: - Sections

    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("quickApps.yourApps")
            ForEach(coordinator.favoriteApps) { app in
                favouriteRow(app)
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("quickApps.allApps")
            ForEach(AppLauncher.catalog) { app in
                catalogRow(app)
            }
        }
    }

    /// Cap note (once full) + the probe disclaimer. The disclaimer earns
    /// its place because "why is WhatsApp missing an Add button" is the
    /// first question a family member asks on a phone where the probe
    /// answered false.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if atCap {
                Text("quickApps.capNote")
            }
            Text("apps.probeNote")
        }
        .font(.system(size: DesignTokens.minCaptionPointSize))
        .foregroundColor(DesignTokens.textSecondary)
    }

    private var atCap: Bool {
        coordinator.favoriteAppIDs.count >= AppLauncher.maxFavourites
    }

    private func sectionHeader(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(DesignTokens.textSecondary)
    }

    // MARK: - Rows

    /// A favourite with a remove button; shows the honest "not installed"
    /// caption when the appearance-time probe says the app has gone away
    /// (removal is still offered — the tile on Home launches through the
    /// coordinator, which re-probes and speaks honestly on tap).
    private func favouriteRow(_ app: AppLauncher.App) -> some View {
        HStack(spacing: 14) {
            AppGlyph(app: app, diameter: 48)
            // `== false` (not `!= true`) so a not-yet-probed row shows no
            // caption for the one frame before `.task` fills `installed`.
            rowLabel(app, captionKey: installed[app.id] == false ? "apps.notInstalled" : nil)
            Spacer(minLength: 0)
            removeButton(app)
        }
        .rowCard()
    }

    /// One catalog entry. Trailing control is honest about each state:
    /// an Add button only when the probe says installed AND under the
    /// cap; a filled checkmark when already favourited; nothing (never a
    /// disabled button) when not installed.
    private func catalogRow(_ app: AppLauncher.App) -> some View {
        let isFavourite = coordinator.favoriteAppIDs.contains(app.id)
        let isInstalledHere = installed[app.id] == true
        return HStack(spacing: 14) {
            AppGlyph(app: app, diameter: 48)
            rowLabel(app, captionKey: isInstalledHere ? "quickApps.installed" : nil)
            Spacer(minLength: 0)
            if isFavourite {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(DesignTokens.accent)
                    .accessibilityLabel(Text("quickApps.added"))
            } else if isInstalledHere && !atCap {
                addButton(app)
            }
        }
        .rowCard()
    }

    private func rowLabel(_ app: AppLauncher.App, captionKey: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(app.nameKey))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
            if let captionKey {
                Text(LocalizedStringKey(captionKey))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
    }

    private func addButton(_ app: AppLauncher.App) -> some View {
        Button {
            // The coordinator re-validates every precondition as the
            // backstop (probe can go stale between appearance and tap);
            // on refusal, refresh just this row's probe rather than
            // leaving a stale Add.
            if !coordinator.addFavoriteApp(app) {
                installed[app.id] = coordinator.isAppInstalled(app)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("quickApps.add")
            }
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.fmt("quickApps.addFor",
                                          locale: coordinator.appLanguage.locale,
                                          appDisplayName(app))))
    }

    private func removeButton(_ app: AppLauncher.App) -> some View {
        Button {
            coordinator.removeFavoriteApp(app)
        } label: {
            // The key carries %@, so it must render through L10n.fmt — a
            // bare Text("quickApps.remove") would print the literal "%@".
            // Formatting with the app name keeps the Nepali word order
            // correct ("व्हाट्सएप हटाउनुहोस्") and makes the control
            // self-describing for VoiceOver ("Remove WhatsApp, button").
            Text(L10n.fmt("quickApps.remove",
                          locale: coordinator.appLanguage.locale,
                          appDisplayName(app)))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.accent)
                .padding(.horizontal, 14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func appDisplayName(_ app: AppLauncher.App) -> String {
        L10n.str(app.nameKey, locale: coordinator.appLanguage.locale)
    }

    /// One scheme probe per catalog app — runs once per appearance (the
    /// `SystemCallLinkOpener` is main-thread-safe; the loop stays on the
    /// main actor and is fast). Refresh-on-appearance keeps "app was
    /// deleted in Settings" honest without polling while the screen sits
    /// open.
    private func probeInstalled() async {
        var fresh: [String: Bool] = [:]
        for app in AppLauncher.catalog {
            fresh[app.id] = coordinator.isAppInstalled(app)
        }
        installed = fresh
    }
}

private extension View {
    /// Card chrome shared by every Quick apps row (Settings row pattern).
    func rowCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}
