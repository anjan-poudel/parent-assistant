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
    @Environment(\.appAppearance) private var appearance

    @ObservedObject var session: ApplianceHelperSession
    @ObservedObject var model: ApplianceManualLibraryModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var pendingDeletion: ApplianceManualLibraryModel.Manual?
    @State private var didFailToOpen = false
    @State private var didFailToOpenBundled = false
    /// The shipped default manuals (2026-09-07), loaded once per open —
    /// fixed at build time, so a single load suffices (unlike the saved
    /// list, which reloads because it tracks the cache).
    @State private var bundled: [BundledManual] = []

    private static let thumbnailSize: CGFloat = 64

    var body: some View {
        NavigationStack {
            ZStack {
                appearance.colors.background.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("appliance.manual.title")
                        .font(DesignTokens.greetingFont(size: 20))
                        .foregroundColor(appearance.colors.textPrimary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                    .accessibilityLabel(Text("appliance.dismiss"))
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
            // Bundled-manual open failure (2026-09-07): the message above
            // talks about deletion/refresh, which is a SAVED-manual
            // truth — a default manual that cannot open (missing overview
            // image) gets a title-only alert instead of that lie.
            .alert("appliance.manual.openFailedTitle", isPresented: $didFailToOpenBundled) {
                Button("appliance.manual.cancel", role: .cancel) {}
            }
        }
        .tint(appearance.colors.accent)
        .task {
            bundled = ApplianceManualLibraryModel.bundledManuals()
            model.reload()
        }
    }

    private var deletionDialogPresented: Binding<Bool> {
        Binding(get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // The library is never empty since the user manual row
        // (user-manual-in-app task, 2026-09-09) always ships — the
        // search pill and the list show unconditionally; an empty
        // SEARCH shows the honest no-results state instead.
        VStack(spacing: 14) {
            searchPill
            results
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// The bundled rows after the query filter (default manuals search
    /// like saved ones — the elder may be looking for "youtube").
    private var visibleBundled: [BundledManual] {
        ApplianceManualLibraryModel.filterBundled(bundled,
                                                  query: model.query,
                                                  locale: locale)
    }

    /// Whether the USER MANUAL row matches the current query — the same
    /// model-owned rule the Default-manuals section and the no-results
    /// state both consult, so they can never disagree.
    private var isUserManualVisible: Bool {
        ApplianceManualLibraryModel.isUserManualVisible(query: model.query,
                                                        locale: locale)
    }

    /// Big search pill — as-you-type, no submit step (same pattern as
    /// the phone leaf's contact search).
    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(appearance.colors.textSecondary)
            TextField("appliance.manual.searchPlaceholder", text: $model.query)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(appearance.colors.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .appSurface(role: .control, cornerRadius: 100)
    }

    @ViewBuilder
    private var results: some View {
        let matches = model.visibleManuals
        let bundledMatches = visibleBundled
        if matches.isEmpty && bundledMatches.isEmpty && !isUserManualVisible {
            noResults
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Default manuals section (2026-09-07): the shipped
                    // rows sit above the saved list — they are the
                    // starting point for an elder who just wants to read
                    // "how do I use this app" with no camera involved.
                    // The USER MANUAL row (user-manual-in-app task,
                    // 2026-09-09) leads the section: it opens the full
                    // text manual, not the step-card guidance.
                    if !bundledMatches.isEmpty || isUserManualVisible {
                        bundledSectionHeader
                        if isUserManualVisible {
                            userManualRow
                        }
                        ForEach(bundledMatches, id: \.id) { manual in
                            BundledManualRow(manual: manual) {
                                openBundled(manual)
                            }
                        }
                    }
                    ForEach(matches) { manual in
                        row(manual)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    /// Small caps label above the bundled rows.
    private var bundledSectionHeader: some View {
        Text("appliance.manual.bundled")
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
            .foregroundColor(appearance.colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    /// The USER MANUAL row (user-manual-in-app task, 2026-09-09): the
    /// full in-app guide to Sahayak, first in the "Default manuals"
    /// section. Same card shape as `BundledManualRow`, but it pushes
    /// `UserManualView` (the text manual) onto the library's own
    /// NavigationStack instead of arming a step-card session — the
    /// viewer's LeafScreen back returns to this list. Non-deletable like
    /// the device manuals; the book badge carries the accent like the
    /// Settings → Manuals entry so the row reads as the same manual on
    /// both surfaces.
    private var userManualRow: some View {
        NavigationLink {
            UserManualView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "book.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(appearance.colors.onAccent)
                    .frame(width: DesignTokens.iconBadgeDiameter,
                           height: DesignTokens.iconBadgeDiameter)
                    .background(appearance.colors.accent)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.manuals.userManual")
                        .font(.system(size: DesignTokens.minBodyPointSize,
                                      weight: .semibold))
                        .foregroundColor(appearance.colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("settings.manuals.userManualHint")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(appearance.colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(appearance.colors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface()
    }

    private var noResults: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(appearance.colors.textSecondary)
            Text("appliance.manual.noResults")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(appearance.colors.textPrimary)
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
                        HStack(spacing: 8) {
                            Text(manual.title)
                                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                                .foregroundColor(appearance.colors.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            // The star marks the manual the assistant will
                            // serve for this appliance's category.
                            if manual.isDefault {
                                defaultBadge
                            }
                        }
                        if let question = manual.question, !question.isEmpty {
                            Text(question)
                                .font(.system(size: DesignTokens.minCaptionPointSize))
                                .foregroundColor(appearance.colors.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Text(manual.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(appearance.colors.textSecondary)
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
        .appSurface()
    }

    /// The star that marks a category's default manual (2026-09-13,
    /// appliance-default-manual): the same accent-circle + white-glyph
    /// language as the user-manual row's book badge, sized down to ride
    /// beside the title rather than lead the row (it is a marker, not a
    /// control — no tap target of its own). Labeled rather than just
    /// drawn: a bare star means nothing to an elder who never learned the
    /// convention, while VoiceOver reads this one as "Default".
    private var defaultBadge: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(appearance.colors.onAccent)
            .frame(width: 24, height: 24)
            .background(appearance.colors.accent)
            .clipShape(Circle())
            .accessibilityLabel(Text("appliance.manual.defaultBadge"))
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
                    appearance.colors.userBubble
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundColor(appearance.colors.textSecondary)
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

    /// Opens a DEFAULT (bundled) manual through the session's
    /// catalog-based path — no cache entry exists for it (2026-09-07).
    private func openBundled(_ manual: BundledManual) {
        guard session.presentBundledManual(manual, locale: session.locale) else {
            // Overview image missing (the images folder is a separate
            // content deliverable) — say so and stay in the library.
            didFailToOpenBundled = true
            return
        }
        dismiss()
    }
}

// MARK: - Bundled manual row (2026-09-07, bundled-manuals task)

/// One DEFAULT (bundled) manual row: overview thumbnail, localized title
/// and overview snippet — non-deletable (ships with the app), the whole
/// card is the open target. Shared by the library's "Default manuals"
/// section and the Settings browse leaf.
struct BundledManualRow: View {
    @Environment(\.appAppearance) private var appearance
    let manual: BundledManual
    let open: () -> Void

    @Environment(\.locale) private var locale

    private static let thumbnailSize: CGFloat = 64

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(BundledManualCatalog.localized(manual.title, locale: locale))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(appearance.colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(BundledManualCatalog.localized(manual.overview, locale: locale))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(appearance.colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(appearance.colors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface()
    }

    /// The manual's overview image, or a book placeholder while the
    /// images folder has not been populated (a separate deliverable).
    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = BundledManualCatalog.image(named: manual.overviewImage) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    appearance.colors.userBubble
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 22))
                        .foregroundColor(appearance.colors.textSecondary)
                }
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}
