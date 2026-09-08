import SwiftUI

/// Settings editor for the news reader's sources (news-reader task,
/// 2026-09-08). Hosted by the Feeds settings leaf through
/// `NewsSourceEditorSeam.makeEditor` (assigned in `AppCoordinator.start()`
/// once the store exists). Configured sources REPLACE the built-in
/// defaults while non-empty (`NewsSourceStore.effectiveSources`) — the
/// same rule the digest fetch uses, so what this editor shows is exactly
/// what the voice digest reads.
struct NewsSourcesSettingsView: View {
    @ObservedObject var store: NewsSourceStore

    @State private var nameDraft = ""
    @State private var urlDraft = ""
    @State private var addFailed = false

    var body: some View {
        LeafScreen(titleKey: "settings.feeds.newsSection") {
            VStack(spacing: 12) {
                if store.configuredSources.isEmpty {
                    Text("settings.feeds.sourcesEmpty")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(DesignTokens.card)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                } else {
                    ForEach(store.configuredSources) { source in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                                    .foregroundColor(DesignTokens.textPrimary)
                                Text(source.urlString)
                                    .font(.system(size: DesignTokens.minCaptionPointSize))
                                    .foregroundColor(DesignTokens.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                _ = store.remove(id: source.id)
                            } label: {
                                Image(systemName: "trash.fill")
                                    .frame(width: DesignTokens.minTapTargetSize,
                                           height: DesignTokens.minTapTargetSize)
                            }
                            .accessibilityLabel(Text("settings.feeds.removeSource"))
                        }
                        .padding(14)
                        .background(DesignTokens.card)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                    }
                }

                // One-field add form (senior-friendly): a single URL field;
                // the name is derived from the host when left blank.
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.feeds.sourcesHint")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                    TextField("settings.feeds.sourcePlaceholder", text: $urlDraft)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button {
                            let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let fallback = URL(string: trimmed)?.host
                                ?? trimmed.split(separator: "/").first.map(String.init)
                                ?? "News source"
                            let source = NewsSource(
                                name: nameDraft.isEmpty ? fallback : nameDraft,
                                urlString: trimmed,
                                languageCode: ""
                            )
                            if store.add(source) {
                                nameDraft = ""
                                urlDraft = ""
                                addFailed = false
                            } else {
                                addFailed = true
                            }
                        } label: {
                            Text("settings.feeds.addSource")
                                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                                .foregroundColor(.white)
                                .frame(height: DesignTokens.minTapTargetSize)
                                .frame(maxWidth: .infinity)
                                .background(DesignTokens.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if addFailed {
                        Text("settings.feeds.addSourceFailed")
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.stateError)
                    }
                }
                .padding(16)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            }
        }
    }
}
