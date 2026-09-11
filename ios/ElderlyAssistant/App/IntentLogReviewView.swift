import SwiftUI

/// Family review screen for the flywheel intent log (spec 2026-09-05
/// §11): shows recent confirmed/corrected actions so family can see what
/// the assistant got right and wrong, and an Export that bundles the log
/// for the next training round. Read-only — corrections themselves
/// happen by voice, this screen is the audit trail.
struct IntentLogReviewView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var records: [IntentLogStore.Record] = []
    @State private var exportURL: URL?
    @State private var showClearConfirm = false

    var body: some View {
        // LeafScreen chrome (2026-09-07): this screen used the system
        // toolbar in a hidden-nav-bar context — no back button and an
        // invisible ShareLink/trash toolbar. The house chrome restores
        // the back affordance and moves the actions in-content.
        LeafScreen(titleKey: "settings.intentLog.title") {
            VStack(spacing: 12) {
                if !records.isEmpty {
                    HStack(spacing: 12) {
                        if let exportURL {
                            ShareLink(item: exportURL) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("intentLog.export")
                                }
                                .font(.system(size: DesignTokens.minCaptionPointSize,
                                              weight: .semibold))
                                .foregroundStyle(DesignTokens.accent)
                                .frame(minHeight: DesignTokens.minTapTargetSize)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text("intentLog.clear")
                            }
                            .font(.system(size: DesignTokens.minCaptionPointSize,
                                          weight: .semibold))
                            .foregroundStyle(DesignTokens.stateError)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                        }
                    }
                }
                if records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checklist")
                            .font(.system(size: 44))
                            .foregroundStyle(DesignTokens.textSecondary)
                        Text(L10n.str("intentLog.empty", locale: coordinator.activeLocale))
                            .font(.system(size: DesignTokens.minBodyPointSize))
                            .foregroundStyle(DesignTokens.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    VStack(spacing: 8) {
                        ForEach(records) { record in
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: record))
                                    .foregroundStyle(DesignTokens.accent)
                                Text(summary(for: record))
                                    .font(.system(size: DesignTokens.minBodyPointSize))
                                    .foregroundStyle(DesignTokens.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .background(DesignTokens.card)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                        }
                    }
                }
            }
        }
        .onAppear {
            records = coordinator.intentLogStore.recent()
            exportURL = coordinator.intentLogStore.exportURL()
        }
        .alert(L10n.str("intentLog.clearTitle", locale: coordinator.activeLocale),
               isPresented: $showClearConfirm) {
            Button(L10n.str("intentLog.clearConfirm", locale: coordinator.activeLocale),
                   role: .destructive) {
                coordinator.intentLogStore.removeAll()
                records = []
                exportURL = nil
            }
            Button(L10n.str("intentLog.clearCancel", locale: coordinator.activeLocale),
                   role: .cancel) {}
        }
    }

    private func icon(for record: IntentLogStore.Record) -> String {
        switch record.action {
        case "call": return record.outcome == "corrected" ? "pencil.circle.fill" : "phone.fill"
        case "send_message": return "message.fill"
        case "set_reminder": return "clock.fill"
        case "music": return "music.note"
        default: return "checkmark.circle.fill"
        }
    }

    private func summary(for record: IntentLogStore.Record) -> String {
        let locale = coordinator.activeLocale
        let contact = record.slots?["contact"] ?? ""
        if record.outcome == "corrected", let to = record.correctedTo?["method"] {
            return L10n.fmt("intentLog.corrected", locale: locale, contact, to)
        }
        return L10n.fmt("intentLog.confirmed", locale: locale, record.action, contact)
    }
}
