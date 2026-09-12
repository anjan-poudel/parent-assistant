import SwiftUI
import AVKit

// MARK: - Feed leaf (feed-agent task, 2026-09-08)

/// The mixed feed surface — a social-feed-style card list of text,
/// image, audio and video items from the configured sources, filtered by
/// the configured topics. Reached from the Home dock tile and
/// Settings → Feeds.
///
/// Per-card affordances (spec: ONE action per card, ≥44pt targets):
/// - text card  → "Read aloud" (SpeakQueue via the coordinator's single
///   speech path — the `AVSpeech`-free house rule);
/// - image card → the image itself (async-loaded, no action);
/// - audio/video → "Play", which presents the `FeedMediaPlayerSheet`.
/// Nothing autoplays — playback only ever starts from the user's tap.
struct FeedsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    /// The item whose play sheet is open (audio or video), nil = closed.
    @State private var playingItem: FeedItem?

    /// Per-card toggle state (feed translation task, 2026-09-08): ids
    /// the user reverted to the ORIGINAL after a translation was shown —
    /// the "second tap reverts" half of the Translate button.
    @State private var showingOriginalIDs: Set<String> = []

    var body: some View {
        LeafScreen(titleKey: "feeds.title") {
            VStack(spacing: 12) {
                refreshRow
                content
            }
        }
        // Refresh-on-appear with TTL: the service serves its cache while
        // fresh, so re-entering the leaf is free (and silent — existing
        // cards stay up while a stale feed refreshes behind them). The
        // refresh/retry buttons use the loading-indicated path.
        .task { await coordinator.refreshFeedIfNeeded() }
        .sheet(item: $playingItem) { item in
            FeedMediaPlayerSheet(item: item)
        }
    }

    // MARK: - Header row (count + refresh)

    private var refreshRow: some View {
        HStack(spacing: 12) {
            Text(L10n.fmt("feeds.count", locale: coordinator.activeLocale,
                          coordinator.feedItems.count))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Button {
                Task { await coordinator.refreshFeed() }
            } label: {
                Label("feeds.refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.card)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content by load state

    @ViewBuilder
    private var content: some View {
        switch coordinator.feedLoadState {
        case .idle:
            // The leaf's `.task` flips this to .loading in the same
            // appearance — an empty frame is the honest "not started".
            Color.clear.frame(height: 1)
        case .loading:
            loadingCard
        case .failed:
            failedCard
        case .loaded:
            loadedContent
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("feeds.loading")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var failedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(DesignTokens.textSecondary)
            Text("feeds.failed")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await coordinator.refreshFeed() }
            } label: {
                Text("feeds.retry")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    @ViewBuilder
    private var loadedContent: some View {
        // Honest partial failure: the feed shows what loaded and says
        // which sources could not be reached — never a silent hole.
        if !coordinator.feedFailedSourceNames.isEmpty {
            partialFailureCard
        }
        if coordinator.feedItems.isEmpty {
            emptyCard
        } else {
            VStack(spacing: 12) {
                ForEach(coordinator.feedItems) { item in
                    card(for: item)
                }
            }
        }
    }

    private var partialFailureCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                // Caption-token status glyph (DESIGN-REVIEW) — 18pt floor,
                // Dynamic Type aware; was a fixed 16pt.
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .padding(.top, 2)
            Text(L10n.fmt("feeds.partialFailure", locale: coordinator.activeLocale,
                          coordinator.feedFailedSourceNames.joined(separator: ", ")))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var emptyCard: some View {
        Text("feeds.empty")
            .font(.system(size: DesignTokens.minBodyPointSize))
            .foregroundStyle(DesignTokens.textSecondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    // MARK: - Cards (one action per card)

    @ViewBuilder
    private func card(for item: FeedItem) -> some View {
        switch item.kind {
        case .audio, .video:
            mediaCard(item)
        case .image:
            imageCard(item)
        case .text:
            textCard(item)
        }
    }

    /// Text card: title, a few lines of summary, source + time caption,
    /// and two actions — "Translate" (feed translation task) and
    /// "Read aloud" (SpeakQueue via the coordinator's canonical path,
    /// the BriefingView precedent — no AVSpeech). The AI-translated
    /// marker shows only while the translation is displayed.
    private func textCard(_ item: FeedItem) -> some View {
        let display = display(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            if display.isShowingTranslation {
                translatedMarker
            }
            Text(display.title)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let summary = displaySummary(display) {
                Text(summary)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            captionRow(item)
            if coordinator.isFeedItemTranslating(item), !display.hasTranslation {
                translatingCaption
            } else if coordinator.feedTranslationFailed(for: item), !display.hasTranslation {
                translationUnavailableCaption
            }
            HStack(spacing: 10) {
                translateButton(item)
                readAloudButton(item)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// Image card: the photo (async), then title + caption. No action —
    /// the image IS the content.
    private func imageCard(_ item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = item.imageURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 160)
                    case .failure:
                        // Honest placeholder — the image failed to load,
                        // the card still says what the item is.
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundStyle(DesignTokens.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 160)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                .accessibilityHidden(true)
            }
            Text(item.title)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            captionRow(item)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// Audio/video card: kind badge, title, source caption, and two
    /// actions — "Play" (presenting the shared AVKit sheet) and
    /// "Translate" (feed translation task). Play is disabled (honest
    /// dead control) when the item has no playable URL — the resolver
    /// only produces media kinds WITH a URL, so this is a
    /// defensive-only state.
    private func mediaCard(_ item: FeedItem) -> some View {
        let display = display(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            if display.isShowingTranslation {
                translatedMarker
            }
            HStack(spacing: 10) {
                Image(systemName: item.kind == .audio
                      ? "speaker.wave.2.fill" : "play.rectangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(DesignTokens.accent)
                Text(display.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(3)
            }
            if let summary = displaySummary(display) {
                Text(summary)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(2)
            }
            captionRow(item)
            if coordinator.isFeedItemTranslating(item), !display.hasTranslation {
                translatingCaption
            } else if coordinator.feedTranslationFailed(for: item), !display.hasTranslation {
                translationUnavailableCaption
            }
            HStack(spacing: 10) {
                Button {
                    playingItem = item
                } label: {
                    Label("feeds.play", systemImage: "play.fill")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(DesignTokens.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(item.mediaURL == nil)
                .opacity(item.mediaURL == nil ? 0.5 : 1)
                translateButton(item)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    // MARK: - Card helpers

    /// Source name + relative time — the feed's social-caption line.
    private func captionRow(_ item: FeedItem) -> some View {
        HStack(spacing: 6) {
            Text(item.sourceName)
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            if let date = item.publishedAt {
                Text("·")
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(HistoryTimeFormat.displayString(for: date,
                                                     now: Date(),
                                                     calendar: .current,
                                                     locale: coordinator.activeLocale))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
    }

    /// The card's current display text — the ONE resolution both the
    /// render and the read-aloud path read, so the voice can never read
    /// different text than the card shows (feed translation task).
    private func display(for item: FeedItem) -> FeedCardDisplayResolver.Display {
        FeedCardDisplayResolver.resolve(
            item: item,
            translation: coordinator.feedTranslation(for: item),
            showingOriginal: showingOriginalIDs.contains(item.id))
    }

    /// Sanitized summary for display (shared with the TTS path — one
    /// sanitizer, so the card and the voice can never disagree on what
    /// the item says). Translations arrive as plain text; originals may
    /// carry markup — both go through the same strip. nil when there is
    /// nothing to show.
    private func displaySummary(_ display: FeedCardDisplayResolver.Display) -> String? {
        let cleaned = FeedSpeechSanitizer.stripped(display.summary)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The AI-translated marker (feed translation task): a small
    /// house-style chip with the sparkles glyph, shown ONLY while the
    /// card displays the translation — originals never carry it.
    private var translatedMarker: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
            Text("feeds.translatedByAI")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
        }
        .foregroundStyle(DesignTokens.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(DesignTokens.accent.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("feeds.translatedByAI"))
    }

    /// Subtle in-flight state (feed translation task, 2026-09-09): the
    /// card renders the ORIGINAL text immediately and shows this small
    /// caption while its translation is on its way (progressive batch or
    /// per-item ask); the translation swaps in when it lands. Never
    /// shown alongside the failure caption (mutually exclusive).
    private var translatingCaption: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(DesignTokens.textSecondary)
            Text("feeds.translating")
                .font(.system(size: DesignTokens.minCaptionPointSize))
        }
        .foregroundStyle(DesignTokens.textSecondary)
        .accessibilityElement(children: .combine)
    }

    /// Honest failure caption (feed translation task): the item's
    /// translation could not be fetched (no cloud configured, daily cap
    /// reached, or provider failure) — the original text stays and this
    /// small caption says so. Shown only for items whose last attempt
    /// failed and have no cached translation; a successful retry clears
    /// it.
    private var translationUnavailableCaption: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: DesignTokens.minCaptionPointSize))
            Text("feeds.translationUnavailable")
                .font(.system(size: DesignTokens.minCaptionPointSize))
        }
        .foregroundStyle(DesignTokens.textSecondary)
        .accessibilityElement(children: .combine)
    }

    /// The per-item Translate affordance (feed translation task,
    /// 2026-09-09 — progressive): translation is now AUTOMATIC on a
    /// Nepali locale, so this button is (a) the toggle — once a
    /// translation exists the same button flips between the translation
    /// and the original (the cached translation makes the revert free),
    /// and (b) the retry/on-demand ask when no translation exists yet
    /// (a failed batch item or an item beyond the current batch). While
    /// a request is in flight the button shows a spinner and ignores
    /// taps. English locale: the button still toggles/asks, but the
    /// automatic pass never runs.
    private func translateButton(_ item: FeedItem) -> some View {
        let display = display(for: item)
        let translating = coordinator.isFeedItemTranslating(item)
        return Button {
            translateTapped(item, display: display)
        } label: {
            Group {
                if translating {
                    ProgressView()
                        .tint(DesignTokens.accent)
                } else {
                    Label(LocalizedStringKey(display.isShowingTranslation
                                             ? "feeds.showOriginal" : "feeds.translate"),
                          systemImage: display.isShowingTranslation
                          ? "arrow.uturn.backward" : "character.bubble.fill")
                }
            }
            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
            .foregroundStyle(DesignTokens.accent)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.background)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DesignTokens.accent.opacity(0.4), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(translating)
    }

    /// Translate-button tap: cached translation → free toggle between
    /// translation and original; no translation yet → the on-ask cloud
    /// request (its success/failure lands via the coordinator's
    /// published state and re-renders this card).
    private func translateTapped(_ item: FeedItem,
                                 display: FeedCardDisplayResolver.Display) {
        if display.hasTranslation {
            if showingOriginalIDs.contains(item.id) {
                showingOriginalIDs.remove(item.id)
            } else {
                showingOriginalIDs.insert(item.id)
            }
        } else {
            Task { await coordinator.translateFeedItem(item) }
        }
    }

    /// Read-aloud button — speaks EXACTLY what the card currently
    /// displays: the translation when it is showing, the original
    /// otherwise (feed translation task). Sanitized through the shared
    /// TTS-friendly path either way; an item with nothing speakable is
    /// never enqueued.
    private func readAloudButton(_ item: FeedItem) -> some View {
        Button {
            readAloud(item)
        } label: {
            Label("feeds.readAloud", systemImage: "speaker.wave.2.fill")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func readAloud(_ item: FeedItem) {
        let display = display(for: item)
        let text = FeedSpeechSanitizer.speechText(title: display.title,
                                                  summary: display.summary)
        guard !text.isEmpty else { return }
        coordinator.speak(text: text)
    }
}

// MARK: - Media playback sheet (feed-agent task, 2026-09-08)

/// The shared playback surface for audio and video items.
///
/// SIMPLER OPTION CHOSEN AND DOCUMENTED: one AVKit `VideoPlayer` sheet
/// for BOTH kinds — audio plays through the system transport controls on
/// a fixed-height dark stage (with a speaker glyph overlay so the empty
/// stage never reads as a broken video), video fills the sheet. This is
/// deliberately NOT an in-card AVPlayer layer: in-card transport UI
/// (progress scrubbing, play/pause, volume) is what `VideoPlayer`
/// already provides, and re-implementing it would add surface without
/// adding honesty.
///
/// Playback starts on appear — the sheet only appears from the card's
/// explicit "Play" tap, so that tap IS the user's consent; the feed
/// itself never autoplays anything. The player pauses and releases on
/// dismiss.
struct FeedMediaPlayerSheet: View {
    let item: FeedItem
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .frame(minWidth: DesignTokens.minTapTargetSize,
                               minHeight: DesignTokens.minTapTargetSize)
                        .background(DesignTokens.card)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("feeds.close"))
                Text("feeds.playingTitle")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(item.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
            }
            .padding(16)

            if let player {
                if item.kind == .audio {
                    ZStack {
                        VideoPlayer(player: player)
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.85))
                            .allowsHitTesting(false)   // transport controls stay tappable
                    }
                    .frame(height: 240)
                    .background(Color.black)
                } else {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiceBridgeBackground(theme: coordinator.appTheme))
        .onAppear {
            guard let urlString = item.mediaURL, let url = URL(string: urlString) else {
                return
            }
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
