import SwiftUI

// MARK: - News Reader seam (feed-agent task, 2026-09-08)

/// The slot the News Reader agent (news-reader task, PARALLEL worktree)
/// plugs its source editor into. When its `NewsSourceStore` + editor
/// view land, the integrator assigns this closure — e.g.
/// `NewsSourceEditorSeam.makeEditor = { AnyView(NewsSourcesSettingsView()) }`
/// — and the Feeds settings leaf's "News sources" section pushes that
/// editor instead of showing the honest pending card. Until then the
/// card states exactly that, so nothing is ever presented as existing
/// when it does not.
enum NewsSourceEditorSeam {
    /// nil = the News Reader's editor is not wired yet.
    static var makeEditor: (() -> AnyView)? = nil
}

// MARK: - Settings → Feeds (feed-agent task, 2026-09-08)

/// The DEDICATED feeds settings section the brief demands — one leaf
/// managing:
/// (a) feed sources — the curated defaults plus user-added RSS/Atom
///     addresses, removable either way;
/// (b) topic keywords — add/remove, matching the feed's title/summary
///     filter;
/// (c) the news-source editor slot — the News Reader's seam above.
///
/// House SettingsView pattern: the row lives in `SettingsView`'s
/// `SettingsSection` list; this is the pushed destination.
struct FeedsSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    // Add-form drafts (kept on screen when a store write fails — the
    // house "nothing claimed that didn't happen" rule).
    @State private var newSourceURL = ""
    @State private var newTopic = ""
    @State private var sourceAddFailed = false

    var body: some View {
        LeafScreen(titleKey: "settings.feeds.title") {
            VStack(spacing: 20) {
                sourcesSection
                topicsSection
                newsSection
            }
        }
    }

    // MARK: - (a) Feed sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(key: "settings.feeds.sourcesSection")
            Text("settings.feeds.sourcesHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if coordinator.feedSources.isEmpty {
                emptyLine(key: "settings.feeds.sourcesEmpty")
            } else {
                ForEach(coordinator.feedSources) { source in
                    sourceRow(source)
                }
            }
            addSourceForm
        }
    }

    private func sourceRow(_ source: FeedSource) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(source.name)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    if source.isCuratedDefault {
                        Text("settings.feeds.defaultTag")
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                            .foregroundStyle(DesignTokens.accent)
                    }
                }
                Text(source.urlString)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(role: .destructive) {
                coordinator.removeFeedSource(id: source.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DesignTokens.stateError)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.feeds.removeSource"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// ONE-field add form (senior-friendly): paste the feed address; the
    /// name is derived from the URL's host (`FeedSourceNameSuggester`).
    /// A failed add keeps the draft and shows the honest caption.
    private var addSourceForm: some View {
        VStack(spacing: 10) {
            TextField(LocalizedStringKey("settings.feeds.sourcePlaceholder"),
                      text: $newSourceURL)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            if sourceAddFailed {
                Text("settings.feeds.addSourceFailed")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.stateError)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Button {
                addSource()
            } label: {
                Text("settings.feeds.addSource")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func addSource() {
        let urlString = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validity checked BEFORE the store call so the caption can say
        // the honest specific thing ("not a valid address") vs the
        // generic failure — both routes keep the draft on screen.
        guard FeedSettingsStore.isValidFeedURL(urlString) else {
            sourceAddFailed = true
            return
        }
        let name = FeedSourceNameSuggester.name(from: urlString)
        if coordinator.addFeedSource(name: name.isEmpty ? urlString : name,
                                     urlString: urlString) {
            newSourceURL = ""
            sourceAddFailed = false
        } else {
            // Duplicate, cap reached, or storage failure.
            sourceAddFailed = true
        }
    }

    // MARK: - (b) Topics

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(key: "settings.feeds.topicsSection")
            Text("settings.feeds.topicsHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if coordinator.feedTopics.isEmpty {
                emptyLine(key: "settings.feeds.topicsEmpty")
            } else {
                ForEach(coordinator.feedTopics, id: \.self) { topic in
                    topicRow(topic)
                }
            }
            addTopicForm
        }
    }

    private func topicRow(_ topic: String) -> some View {
        HStack(spacing: 12) {
            Text(topic)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
            Spacer()
            Button {
                coordinator.removeFeedTopic(topic)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.feeds.removeTopic"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var addTopicForm: some View {
        HStack(spacing: 10) {
            TextField(LocalizedStringKey("settings.feeds.topicPlaceholder"),
                      text: $newTopic)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            Button {
                addTopic()
            } label: {
                Text("settings.feeds.addTopic")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(newTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func addTopic() {
        if coordinator.addFeedTopic(newTopic) {
            newTopic = ""
        }
        // A rejected add (duplicate/cap) leaves the draft visible — the
        // row already showing the existing topic IS the feedback.
    }

    // MARK: - (c) News sources (the News Reader's editor slot)

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(key: "settings.feeds.newsSection")
            if let makeEditor = NewsSourceEditorSeam.makeEditor {
                NavigationLink {
                    makeEditor()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "newspaper.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(DesignTokens.accent)
                            .frame(width: 40)
                        Text("settings.feeds.newsManage")
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                            .foregroundStyle(DesignTokens.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(DesignTokens.card)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                }
                .buttonStyle(.plain)
            } else {
                emptyLine(key: "settings.feeds.newsPending")
            }
        }
    }

    // MARK: - Shared section pieces

    private func sectionHeader(key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundStyle(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func emptyLine(key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minBodyPointSize))
            .foregroundStyle(DesignTokens.textSecondary)
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}
