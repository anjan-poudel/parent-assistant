import SwiftUI

// MARK: - In-app user manual viewer (user-manual-in-app task)

/// The full user manual, rendered phone-friendly from the bundled
/// structured content (`Resources/ManualText/userManual.json` via
/// `UserManualCatalog`). Reached from Settings → Manuals (the top
/// "User manual" row, pushed onto the same navigation stack).
///
/// Bilingual: the catalog ships every section in BOTH languages and this
/// viewer resolves the ACTIVE locale at render time through the house
/// pattern (`coordinator.activeLocale` — the `AppLanguage`-derived source
/// of truth): Nepali content for ne-*, English for everything else (the
/// unknown-locale fallback lives in `UserManualSection`).
///
/// Phone-friendly rules: house `LeafScreen` chrome (back + title +
/// emergency icon), ONE vertical ScrollView, one white card per section
/// with a bold rounded header, body text at `DesignTokens.minBodyPointSize`
/// with generous spacing — no horizontal scrolling, no images.
///
/// Honest fallback: a missing or malformed resource renders the dedicated
/// empty-state card, never a half-rendered manual.
struct UserManualView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    /// nil = not loaded yet (or the resource is absent); the `.task`
    /// loads once — the resource is fixed at build time.
    @State private var sections: [UserManualSection]?

    /// The sections the viewer renders — shipped ones that pass the
    /// content gate (an invalid section fails the whole load upstream,
    /// so this is a defensive-only filter).
    private var visibleSections: [UserManualSection]? {
        sections?.filter(\.isValid)
    }

    var body: some View {
        LeafScreen(titleKey: "settings.manuals.userManual") {
            Group {
                if let visibleSections, !visibleSections.isEmpty {
                    VStack(spacing: 16) {
                        ForEach(visibleSections) { section in
                            sectionCard(section)
                        }
                    }
                } else {
                    emptyCard
                }
            }
        }
        .task {
            guard sections == nil else { return }
            sections = UserManualCatalog.bundledSections()
        }
    }

    // MARK: - Content

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundColor(DesignTokens.textSecondary)
            Text("manual.userManual.unavailable")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// One section card: bold rounded header, then each paragraph at
    /// ≥`minBodyPointSize` with line spacing, all resolved in the ACTIVE
    /// locale (the catalog's own resolution — see `UserManualSection`).
    /// Bullet paragraphs (the "• " convention) render as-is — the
    /// content never carries markdown beyond that prefix.
    private func sectionCard(_ section: UserManualSection) -> some View {
        let locale = coordinator.activeLocale
        let paragraphs = section.paragraphs(locale: locale)
        return VStack(alignment: .leading, spacing: 12) {
            Text(section.title(locale: locale))
                .font(DesignTokens.greetingFont(
                    size: DesignTokens.minBodyPointSize + 2))
                .foregroundColor(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}
