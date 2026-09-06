import SwiftUI

/// The saved-manuals library (2026-09-06, local-cache-manuals): one row
/// per cached manual — thumbnail, appliance name, question, saved date —
/// most recently saved first, searchable as the elder types (big search
/// pill, no submit step, ≥44pt targets — the same pattern as the phone
/// leaf's contact search). Tapping a row hands the manual to the session,
/// which renders the SAME per-step card result UI from the cache: no
/// camera, no network. Deletion is per-manual and confirmed before it
/// happens (an elder's accidental delete would be hard to undo).
struct ApplianceManualLibraryView: View {

    @ObservedObject var session: ApplianceHelperSession
    @ObservedObject var model: ApplianceManualLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: ApplianceManualLibraryModel.Manual?
    @State private var didFailToOpen = false

    private static let thumbnailSize: CGFloat = 64

    var body: some View {
        NavigationStack {
            ZStack {
                DesignTokens.background.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("appliance.manual.title")
                        .font(DesignTokens.greetingFont(size: 20))
                        .foregroundColor(DesignTokens.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(DesignTokens.textSecondary)
                            .accessibilityLabel(Text("appliance.dismiss"))
                    }
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                }
            }
            .confirmationDialog("appliance.manual.deleteConfirmTitle",
                                isPresented: deletionDialogPresented,
                                titleVisibility: .visible) {
                Button("appliance.manual.deleteAction", role: .destructive) {
                    if let manual = pendingDeletion {
                        model.delete(manualID: manual.id)
                    }
                    pendingDeletion = nil
                }
                Button("appliance.manual.cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text("appliance.manual.deleteConfirmMessage")
            }
            .alert("appliance.manual.openFailedTitle", isPresented: $didFailToOpen) {
                Button("appliance.manual.cancel", role: .cancel) {}
            } message: {
                Text("appliance.manual.openFailedMessage")
            }
        }
        .task { model.reload() }
    }

    private var deletionDialogPresented: Binding<Bool> {
        Binding(get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.manuals.isEmpty {
            emptyLibrary
        } else {
            VStack(spacing: 14) {
                searchPill
                results
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundColor(DesignTokens.textSecondary)
            Text("appliance.manual.empty")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    /// Big search pill — as-you-type, no submit step (same pattern as
    /// the phone leaf's contact search).
    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            TextField("appliance.manual.searchPlaceholder", text: $model.query)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var results: some View {
        let matches = model.visibleManuals
        if matches.isEmpty {
            noResults
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(matches) { manual in
                        row(manual)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(DesignTokens.textSecondary)
            Text("appliance.manual.noResults")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: - Rows

    private func row(_ manual: ApplianceManualLibraryModel.Manual) -> some View {
        HStack(spacing: 14) {
            // The whole card minus the trash button is the open target —
            // one big button beats a tap-anywhere gesture for both
            // touch and VoiceOver.
            Button {
                open(manual)
            } label: {
                HStack(spacing: 14) {
                    thumbnail(manual)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manual.title)
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                            .foregroundColor(DesignTokens.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let question = manual.question, !question.isEmpty {
                            Text(question)
                                .font(.system(size: DesignTokens.minCaptionPointSize))
                                .foregroundColor(DesignTokens.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Text(manual.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: DesignTokens.minTapTargetSize)

            Button {
                pendingDeletion = manual
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(DesignTokens.stateListening)
                    .accessibilityLabel(Text("appliance.manual.deleteA11y"))
            }
            .frame(minWidth: DesignTokens.minTapTargetSize,
                   minHeight: DesignTokens.minTapTargetSize)
            .contentShape(Rectangle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// The manual's stored photo, or a warm placeholder when the file is
    /// unreadable (defensive only — entries are filtered to image-bearing
    /// ones by the model).
    @ViewBuilder
    private func thumbnail(_ manual: ApplianceManualLibraryModel.Manual) -> some View {
        Group {
            if let image = manual.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    DesignTokens.userBubble
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundColor(DesignTokens.textSecondary)
                }
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private func open(_ manual: ApplianceManualLibraryModel.Manual) {
        guard session.presentManual(entryID: manual.id) else {
            // Gone between listing and tap (deleted by another surface):
            // never show a fabricated manual — say so and refresh.
            didFailToOpen = true
            model.reload()
            return
        }
        dismiss()
    }
}
