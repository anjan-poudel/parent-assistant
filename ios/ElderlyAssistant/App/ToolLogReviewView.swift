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
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
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
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
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
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.accent)
                Text(kindLabel(for: entry.kind))
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textSecondary)
                outcomeBadge(entry.outcome)
                Spacer(minLength: 0)
                Text(timeLabel(for: entry))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Text(entry.query)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            if !entry.response.isEmpty {
                Text(entry.response)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Outcome badge — raw debug vocabulary (ok / fallback / cap / fail)
    /// on a tinted capsule, the same way the intent-log review shows raw
    /// action values. Colors reuse the DesignTokens state palette (there
    /// are no debug-specific tokens yet): ok = green, cap = amber,
    /// fail = red, fallback (answered for the device, not the place that
    /// was asked) = gray.
    private func outcomeBadge(_ outcome: String) -> some View {
        Text(outcome)
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(.white)
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

    private func kindIcon(for kind: LocalToolLogEntry.Kind) -> String {
        switch kind {
        case .weather: return "cloud.sun.fill"
        case .search: return "magnifyingglass"
        // [YOUTUBE] (2026-09-08) Voice YouTube entries share the app's
        // own play icon.
        case .youtube: return "play.rectangle.fill"
        }
    }

    private func kindLabel(for kind: LocalToolLogEntry.Kind) -> String {
        let key: String
        switch kind {
        case .weather: key = "toolLog.kind.weather"
        case .search: key = "toolLog.kind.search"
        case .youtube: key = "toolLog.kind.youtube"
        }
        return L10n.str(key, locale: coordinator.activeLocale)
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
                .foregroundColor(DesignTokens.textSecondary)
            Text(L10n.str("toolLog.empty", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
