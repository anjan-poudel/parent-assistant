import SwiftUI

/// Family-facing review screen for the local-tools debug log
/// (tool-debug-log, 2026-09-07): every live weather / web-search request
/// the on-device stack made and how the app answered it, newest first —
/// the debugging window for "did it even try the network, and what did
/// it answer?" Rows show the request (the user's raw question), the
/// response the app delivered, an outcome badge (ok / fallback / cap /
/// fail), and the time; a ShareLink exports the whole log as JSON for
/// off-device review. Read-only — the store self-prunes at its 200-entry
/// cap (the cap note stays visible). Mirrors `IntentLogReviewView`'s
/// LeafScreen form and the export row of the intent-log screen.
struct ToolLogReviewView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var entries: [LocalToolLogEntry] = []
    @State private var exportURL: URL?

    var body: some View {
        LeafScreen(titleKey: "settings.toolLog.title") {
            VStack(spacing: 12) {
                if entries.isEmpty {
                    emptyState
                } else {
                    exportRow
                    entriesList
                }
                // Cap note visible in BOTH states — an empty log still
                // says what fills it (and that nothing here grows forever).
                Text(L10n.str("toolLog.capNote", locale: coordinator.activeLocale))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            entries = coordinator.localToolLogStore.entries()
            exportURL = coordinator.localToolLogStore.exportJSON()
        }
    }

    // MARK: - Rows

    private var exportRow: some View {
        HStack(spacing: 12) {
            if let exportURL {
                ShareLink(item: exportURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("toolLog.export")
                    }
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold)).foregroundStyle(appearance.colors.accentForeground)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                }
            }
            Spacer()
        }
    }

    private var entriesList: some View {
        VStack(spacing: 8) {
            ForEach(entries) { entry in
                entryRow(entry)
            }
        }
    }

    /// One request/response pair: the kind + outcome badge + time on the
    /// first line, the raw query beneath (bold — it is the row's subject),
    /// then a preview of what the app answered. Queries and answers are
    /// capped at a few lines each so a long search turn cannot balloon a
    /// row.
    private func entryRow(_ entry: LocalToolLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kindIcon(for: entry.kind))
                    .font(.system(size: appearance.typography.captionPointSize)).foregroundStyle(appearance.colors.accentForeground)
                Text(kindLabel(for: entry.kind))
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textSecondary)
                outcomeBadge(entry.outcome)
                Spacer(minLength: 0)
                Text(timeLabel(for: entry))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
            Text(entry.query)
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            if !entry.response.isEmpty {
                Text(entry.response)
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// Outcome badge — raw debug vocabulary (ok / fallback / cap / fail)
    /// on a tinted capsule, the same way the intent-log review shows raw
    /// action values. Colors reuse the DesignTokens state palette (there
    /// are no debug-specific tokens yet): ok = green, cap = amber,
    /// fail = red, fallback (answered for the device, not the place that
    /// was asked) = gray.
    private func outcomeBadge(_ outcome: String) -> some View {
        Text(outcome)
            .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(outcomeTint(outcome))
            .clipShape(Capsule())
    }

    private func outcomeTint(_ outcome: String) -> Color {
        switch outcome {
        case "ok": return DesignTokens.stateSpeaking
        case "cap": return DesignTokens.stateListening
        case "fail": return DesignTokens.stateError
        default: return DesignTokens.stateStopped   // "fallback" and anything unknown
        }
    }

    /// Kind → SF Symbol. Exhaustive over `LocalToolLogEntry.Kind` with NO
    /// default arm (review C-4): a new kind must fail the build until it
    /// is mapped here. Static and environment-free so the mapping is
    /// pinnable from `ToolLogKindMappingTests` without standing up the
    /// view's coordinator/appearance environment; `kindIcon(for:)` below
    /// keeps the row call site unchanged.
    static func kindIconName(for kind: LocalToolLogEntry.Kind) -> String {
        switch kind {
        case .weather: return "cloud.sun.fill"
        case .search: return "magnifyingglass"
        // [YOUTUBE] (2026-09-08) Voice YouTube entries share the app's
        // own play icon.
        case .youtube: return "play.rectangle.fill"
        // [SPOTIFY] (2026-10-06, C-SP-14) Music entries draw the app's
        // own music glyph — the same note the intent log uses for
        // `music`.
        case .spotify: return "music.note"
        }
    }

    /// Kind → L10n key. The second exhaustive switch of review C-4 —
    /// same no-default rule as the icon mapping. The key resolves through
    /// the catalog (`toolLog.kind.*`, both languages) at the call site
    /// below.
    static func kindLabelKey(for kind: LocalToolLogEntry.Kind) -> String {
        switch kind {
        case .weather: return "toolLog.kind.weather"
        case .search: return "toolLog.kind.search"
        case .youtube: return "toolLog.kind.youtube"
        case .spotify: return "toolLog.kind.spotify"
        }
    }

    private func kindIcon(for kind: LocalToolLogEntry.Kind) -> String {
        Self.kindIconName(for: kind)
    }

    private func kindLabel(for kind: LocalToolLogEntry.Kind) -> String {
        L10n.str(Self.kindLabelKey(for: kind), locale: coordinator.activeLocale)
    }

    private func timeLabel(for entry: LocalToolLogEntry) -> String {
        HistoryTimeFormat.displayString(for: entry.timestamp,
                                        now: Date(),
                                        calendar: .current,
                                        locale: coordinator.activeLocale)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(appearance.colors.textSecondary)
            Text(L10n.str("toolLog.empty", locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
