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
        ZStack {
            DesignTokens.background.ignoresSafeArea()
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 44))
                        .foregroundColor(DesignTokens.textSecondary)
                    Text(L10n.str("intentLog.empty", locale: coordinator.activeLocale))
                        .font(.body)
                        .foregroundColor(DesignTokens.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: icon(for: record))
                                    .foregroundColor(DesignTokens.accent)
                                Text(summary(for: record))
                                    .font(.body)
                                    .foregroundColor(DesignTokens.textPrimary)
                            }
                            Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(DesignTokens.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(L10n.str("intentLog.title", locale: coordinator.activeLocale))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                if !records.isEmpty {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
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
