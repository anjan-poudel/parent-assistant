import SwiftUI

// MARK: - Notification drawer row (home-redesign, 2026-09-08)

/// The ONE row component every drawer panel renders through — a drawer
/// with a single item and a drawer with ten items are the same
/// `ForEach` over the same rows using this same view, so the surface
/// cannot degrade as panels accumulate. Icon badge, message, chevron:
/// everything a row needs arrives in `HomeNotificationRow`; rows never
/// reach past it into the coordinator.
struct NotificationRowButton: View {
    let row: HomeNotificationRow
    /// Fires on tap — the sheet owner dismisses and routes to the row's
    /// destination (the drawer is a sheet: a push from inside it would
    /// strand the sheet).
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconBadge(systemImage: row.icon, tint: row.tint, diameter: 40)
                Text(row.text)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize,
                   alignment: .leading)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(row.text))
    }
}

// MARK: - Bell + badge (Home top bar)

/// The single notifications affordance on Home: one bell with a badge
/// showing how many panels are active (0 hides the badge entirely —
/// no stale "0" dot). The badge derives from the SAME registry rows the
/// drawer lists, so the bell can never advertise a count the sheet does
/// not show. Tap target is the full 44pt frame, not the 32pt glyph.
struct NotificationBellButton: View {
    let count: Int
    let action: () -> Void

    private var bell: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                IconBadge(systemImage: "bell.fill", tint: .reminders, diameter: 32)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DesignTokens.accent)
                        .clipShape(Capsule())
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text("notifications.bell"))
    }

    var body: some View {
        if count > 0 {
            bell.accessibilityValue(Text("\(count)"))
        } else {
            bell
        }
    }
}

// MARK: - Notifications drawer sheet

/// The ONE notifications surface (home-redesign, 2026-09-08): a sheet
/// titled "Notifications" listing EVERY active panel as a scrollable row.
/// House sheet rules (2026-09-08 back/close audit): explicit title + a
/// ≥44pt ✕ — an elder is never stranded on this sheet. Rows come from
/// the SAME `HomeWidgetRegistry` instance Home renders, live — adding a
/// panel (or a panel self-hiding) changes the list while it is open, and
/// the bell's count on Home always matches.
struct NotificationsDrawerSheet: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    let registry: HomeWidgetRegistry
    /// Row tap: dismiss + route. The destination leaf is pushed on Home's
    /// navigation stack (never inside this sheet — see HomeView).
    let onSelect: (LeafDestination) -> Void

    private var rows: [HomeNotificationRow] {
        registry.notificationRows(coordinator: coordinator)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Capsule()
                    .fill(DesignTokens.textSecondary.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                // Title row with an explicit ✕ (2026-09-08 back/close
                // audit) — see ConversationHistorySheet.
                HStack(alignment: .center, spacing: 12) {
                    Text("notifications.title")
                        .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer(minLength: 0)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(DesignTokens.textSecondary)
                            .accessibilityLabel(Text("common.close"))
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                }
                if rows.isEmpty {
                    // Honest empty state: the bell is still reachable and
                    // the surface stays identical — nothing active to
                    // tell, no invented panels.
                    Text("notifications.empty")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 28)
                } else {
                    ForEach(rows) { row in
                        NotificationRowButton(row: row) {
                            onSelect(row.destination)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(theme: coordinator.appTheme).ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
