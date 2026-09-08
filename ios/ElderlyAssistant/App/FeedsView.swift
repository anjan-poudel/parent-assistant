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
                .foregroundColor(DesignTokens.textSecondary)
            Spacer()
            Button {
                Task { await coordinator.refreshFeed() }
            } label: {
                Label("feeds.refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.accent)
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
                .foregroundColor(DesignTokens.textSecondary)
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
                .foregroundColor(DesignTokens.textSecondary)
            Text("feeds.failed")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await coordinator.refreshFeed() }
            } label: {
                Text("feeds.retry")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
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
                .font(.system(size: 16))
                .foregroundColor(DesignTokens.textSecondary)
                .padding(.top, 2)
            Text(L10n.fmt("feeds.partialFailure", locale: coordinator.activeLocale,
                          coordinator.feedFailedSourceNames.joined(separator: ", ")))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var emptyCard: some View {
        Text("feeds.empty")
            .font(.system(size: DesignTokens.minBodyPointSize))
            .foregroundColor(DesignTokens.textSecondary)
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
    /// and the single "Read aloud" action. SpeakQueue speech via the
    /// coordinator's canonical path (BriefingView precedent) — the
    /// `.interactive` lane, no card, no AVSpeech.
    private func textCard(_ item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let summary = cardSummary(item) {
                Text(summary)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            captionRow(item)
            Button {
                readAloud(item)
            } label: {
                Label("feeds.readAloud", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
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
                            .foregroundColor(DesignTokens.textSecondary)
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
                .foregroundColor(DesignTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            captionRow(item)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// Audio/video card: kind badge, title, source caption, and the
    /// single "Play" action presenting the shared AVKit sheet. Disabled
    /// (honest dead control) when the item has no playable URL — the
    /// resolver only produces media kinds WITH a URL, so this is a
    /// defensive-only state.
    private func mediaCard(_ item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: item.kind == .audio
                      ? "speaker.wave.2.fill" : "play.rectangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(DesignTokens.accent)
                Text(item.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(3)
            }
            if let summary = cardSummary(item) {
                Text(summary)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(2)
            }
            captionRow(item)
            Button {
                playingItem = item
            } label: {
                Label("feeds.play", systemImage: "play.fill")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(item.mediaURL == nil)
            .opacity(item.mediaURL == nil ? 0.5 : 1)
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
                .foregroundColor(DesignTokens.textSecondary)
            if let date = item.publishedAt {
                Text("·")
                    .foregroundColor(DesignTokens.textSecondary)
                Text(HistoryTimeFormat.displayString(for: date,
                                                     now: Date(),
                                                     calendar: .current,
                                                     locale: coordinator.activeLocale))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
    }

    /// Sanitized summary for display (shared with the TTS path — one
    /// sanitizer, so the card and the voice can never disagree on what
    /// the item says). nil when there is nothing to show.
    private func cardSummary(_ item: FeedItem) -> String? {
        let cleaned = FeedSpeechSanitizer.stripped(item.summary)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Read-aloud: sanitized title + summary through the SpeakQueue
    /// (coordinator.speak — the app's single speech path). An item with
    /// nothing speakable is never enqueued.
    private func readAloud(_ item: FeedItem) {
        let text = FeedSpeechSanitizer.speechText(title: item.title,
                                                  summary: item.summary)
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
                Text("feeds.playingTitle")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
                Text(item.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(DesignTokens.textSecondary)
                        .accessibilityLabel(Text("feeds.close"))
                }
                .buttonStyle(.plain)
                .frame(minWidth: DesignTokens.minTapTargetSize,
                       minHeight: DesignTokens.minTapTargetSize)
            }
            .padding(16)

            if let player {
                if item.kind == .audio {
                    ZStack {
                        VideoPlayer(player: player)
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.white.opacity(0.85))
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
        .background(Color(theme: coordinator.appTheme).ignoresSafeArea())
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
