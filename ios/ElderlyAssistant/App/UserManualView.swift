import SwiftUI

// MARK: - In-app user manual viewer (user-manual-in-app task)

/// The full user manual, rendered phone-friendly from the bundled
/// structured content (`Resources/ManualText/userManual.json` via
/// `UserManualCatalog`). Reached from Settings → Manuals (the top
/// "User manual" row, pushed onto the same navigation stack) and from
/// the appliance helper's manuals library (the "Default manuals"
/// section's top row — see `ApplianceManualLibraryView`).
///
/// Bilingual: the catalog ships every section in BOTH languages and this
/// viewer resolves the ACTIVE locale at render time through the house
/// pattern (`coordinator.activeLocale` — the `AppLanguage`-derived source
/// of truth): Nepali content for ne-*, English for everything else (the
/// unknown-locale fallback lives in `UserManualSection`).
///
/// Visual aids (2026-09-09): sections that declare diagrams render them
/// above the text — programmatic sketch PNGs, NOT screenshots (they are
/// watermarked as sketches and the caption under the image says so in
/// plain words). Images are screen-width, aspect-fit, rounded, and
/// decorative: a missing image is skipped, never an error.
///
/// Phone-friendly rules: house `LeafScreen` chrome (back + title +
/// emergency icon), ONE vertical ScrollView, one white card per section
/// with a bold rounded header, body text at `DesignTokens.minBodyPointSize`
/// with generous spacing — no horizontal scrolling.
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

    /// One section card: bold rounded header, then the section's
    /// DIAGRAMS (the ones that resolve — full width, aspect-fit,
    /// rounded), an honest sketch caption when any rendered, then each
    /// paragraph at ≥`minBodyPointSize` with line spacing — all text
    /// resolved in the ACTIVE locale (the catalog's own resolution —
    /// see `UserManualSection`). Bullet paragraphs (the "• " convention)
    /// render as-is; the content never carries markdown beyond that
    /// prefix.
    private func sectionCard(_ section: UserManualSection) -> some View {
        let locale = coordinator.activeLocale
        let paragraphs = section.paragraphs(locale: locale)
        return VStack(alignment: .leading, spacing: 12) {
            Text(section.title(locale: locale))
                .font(DesignTokens.greetingFont(
                    size: DesignTokens.minBodyPointSize + 2))
                .foregroundColor(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            imagesBlock(section)
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

    /// The section's diagrams + the honest sketch caption. Images that
    /// don't resolve (a missing file) are skipped — decorative-only by
    /// contract, never an error; the shipped-artifact test pins that
    /// every declared image resolves in the built bundle.
    @ViewBuilder
    private func imagesBlock(_ section: UserManualSection) -> some View {
        let rendered = section.images.compactMap { name in
            UserManualCatalog.image(named: name).map { (name: name, image: $0) }
        }
        if !rendered.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rendered, id: \.name) { entry in
                    Image(uiImage: entry.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                                .stroke(DesignTokens.textSecondary.opacity(0.18),
                                        lineWidth: 1)
                        )
                        // Diagrams are decorative for VoiceOver — the
                        // paragraph text carries the full explanation.
                        .accessibilityHidden(true)
                }
                Text("manual.imageCaption")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
