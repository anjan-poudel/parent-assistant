import SwiftUI
import UIKit

// MARK: - Article reader (news-feed-images task, 2026-10-14)

/// The full article, on screen — the tap-through from a feed card
/// ("tap news to read the news text full"). The card is a glance; this
/// is the read: the photo, the headline, and the source's own body laid
/// out as paragraphs, on the house leaf chrome so Back and Emergency
/// behave exactly as every other leaf does.
///
/// What it shows is the SOURCE's original text (title + body, or the
/// published summary when there is no distinct body). Translations cover
/// the card's title and summary only — the body is never translated (the
/// documented `FeedTranslator` rule) — so the reader deliberately does
/// not mix a translated title over an original body; it is the article
/// as published, and the voice button below reads exactly what this
/// screen shows through `readFeedItemArticleAloud` — the SAME
/// coordinator path (and sanitizer) the card's "Read full article"
/// button uses, with the same completion seam that marks the item read.
///
/// Interruption is the `SpeakQueue`'s, not this screen's: the reading is
/// enqueued under the `feeds_readaloud` source id at `.interactive`
/// priority, so the existing rules apply unchanged — safety lanes
/// preempt it, and a new user turn stops the speaking path exactly as it
/// does for every other reply. This screen adds no second speech
/// mechanism, no autoplay, and nothing is spoken until the button is
/// tapped.
struct FeedArticleReaderView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    let item: FeedItem

    /// Explicit rather than synthesized: the private environment
    /// properties above would make the synthesized memberwise
    /// initializer file-private, and `FeedsView` presents this reader
    /// from another file.
    init(item: FeedItem) {
        self.item = item
    }

    /// True when the source published a body beyond the summary — the
    /// reader's layout, caption and button label all follow this ONE
    /// answer (the same gate the card uses).
    private var hasFullArticle: Bool {
        FeedSpeechSanitizer.hasFullArticle(summary: item.summary,
                                           fullText: item.fullText)
    }

    /// The body as display paragraphs — see `FeedArticleText`.
    private var paragraphs: [String] {
        FeedArticleText.bodyParagraphs(summary: item.summary,
                                       fullText: item.fullText)
    }

    var body: some View {
        LeafScreen(titleKey: "feeds.readerTitle") {
            VStack(alignment: .leading, spacing: 14) {
                // The photo, the same fixed full-width band the cards use
                // (letterboxed whole — see FeedArticleImageView): the
                // card is the glance, this is the article.
                FeedArticleImageView(urlString: item.imageURL, fit: .fit)

                Text(item.title)
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                captionRow

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: appearance.typography.bodyPointSize))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !hasFullArticle {
                    summaryOnlyCaption
                }

                readButton
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
        }
    }

    /// Source name + relative time — the same caption line the card
    /// shows, so the two surfaces agree about where the story came from.
    private var captionRow: some View {
        HStack(spacing: 6) {
            Text(item.sourceName)
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.textSecondary)
            if let date = item.publishedAt {
                Text("·")
                    .foregroundStyle(appearance.colors.textSecondary)
                Text(HistoryTimeFormat.displayString(for: date,
                                                     now: Date(),
                                                     calendar: .current,
                                                     locale: coordinator.activeLocale))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
        }
    }

    /// Honest caption mirroring the card's `feeds.summaryOnly` line: the
    /// source published only a summary, so the button below reads that —
    /// stated, never left for the elder to wonder about.
    private var summaryOnlyCaption: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: appearance.typography.captionPointSize))
            Text("feeds.summaryOnly")
                .font(.system(size: appearance.typography.captionPointSize))
        }
        .foregroundStyle(appearance.colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The voice read — the screen's one primary action, ≥44pt, body
    /// font. Label and icon follow the SAME rule as the card's buttons
    /// ("feeds.readFullArticle" / doc glyph when a body exists,
    /// "feeds.readAloud" / speaker glyph otherwise), and the action is
    /// the one coordinator path either way: `readFeedItemArticleAloud`
    /// reads the body when there is one and falls back to the published
    /// summary when there is not — never silence, never a fabricated
    /// article.
    private var readButton: some View {
        Button {
            coordinator.readFeedItemArticleAloud(item)
        } label: {
            Label(LocalizedStringKey(hasFullArticle
                                     ? "feeds.readFullArticle" : "feeds.readAloud"),
                  systemImage: hasFullArticle ? "doc.text.fill" : "speaker.wave.2.fill")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .accent, cornerRadius: 999)
        }
        .buttonStyle(.plain)
        .hapticOnTap()
    }
}

// MARK: - Downsampled feed image (news-feed-images task, 2026-10-14)

/// One feed image, loaded off-main and decoded through the house bounded
/// downsampling cache (`DownsampledImageCache`) — never full-size:
///
/// - the fetch is `URLSession`'s async data task (a non-2xx response or
///   a network failure resolves to nil — the honest failure glyph),
/// - the decode is ImageIO's thumbnail path on a detached task (the
///   [RESPONSIVENESS] rule: an image about to be thrown away is never
///   decoded on the main thread),
/// - the result is cached under the `"feedimg:<url>"` key family at the
///   size it is actually drawn, so scrolling a long feed re-decodes
///   nothing and memory stays bounded (count + decoded bytes).
///
/// Layout is FIXED: the image always occupies the same full-width,
/// `slotHeight`-tall band — placeholder, failure glyph and loaded photo
/// share it — so a slow network can never shift the card under the
/// elder's finger. The old image card reserved 160pt for its placeholder
/// and then jumped to the photo's natural height when it landed; this
/// slot cannot jump.
///
/// Decorative by decision (the rule the old image card already kept):
/// the title and summary carry the item's meaning, so VoiceOver skips
/// the image — including its placeholder states.
struct FeedArticleImageView: View {

    /// How the photo sits in its fixed slot. `.fill` crops to fill
    /// (card thumbnails — a feed reads as a column of equal foils);
    /// `.fit` letterboxes the whole photo inside the slot (the image
    /// card and the reader, where cropping the photo would hide content
    /// the card's tap was inviting the elder to look at).
    enum Fit {
        case fill
        case fit
    }

    let urlString: String?
    var fit: Fit = .fill

    @Environment(\.appAppearance) private var appearance
    @Environment(\.displayScale) private var displayScale

    /// Explicit rather than synthesized: the private properties below
    /// would make the synthesized memberwise initializer file-private,
    /// and `FeedsView` draws this view from another file.
    init(urlString: String?, fit: Fit = .fill) {
        self.urlString = urlString
        self.fit = fit
    }

    private enum Phase {
        case loading
        case loaded(UIImage)
        case failed
    }

    @State private var phase: Phase = .loading

    /// The longest edge an iPhone card draws this image at, in points —
    /// every current iPhone card column is under this, so the decode is
    /// bounded by what can actually be seen. Folded into the cache key
    /// by `thumbnail(forKey:)`, so the same URL drawn at another size
    /// caches its own thumbnail.
    static let thumbnailPointEdge: CGFloat = 360

    /// The fixed slot's height in points, full-width. A fixed HEIGHT
    /// rather than an aspect ratio on purpose: it is the deterministic
    /// house pattern for a photo band (`ApplianceHelperView`'s
    /// `closeUpHeight`), it needs no knowledge of the container's width,
    /// and it is exactly what "no layout jump" demands — the placeholder,
    /// the failure glyph and the loaded photo all occupy this one band,
    /// so a slow network can never reflow the card under a finger.
    /// 200pt keeps the photo genuinely visible for these eyes without
    /// letting one item swallow the scroll.
    static let slotHeight: CGFloat = 200

    var body: some View {
        // No renderable reference at all (absent, or not an http(s) URL
        // with a host — `FeedImageURL`): no slot is claimed, so a feed
        // without photos reads exactly as it always did.
        if let url = FeedImageURL.displayURL(urlString) {
            slot
                .task(id: url) { await load(url) }
        }
    }

    private var slot: some View {
        ZStack {
            switch phase {
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fit == .fill ? .fill : .fit)
            case .failed:
                // Honest placeholder — the load failed, the card still
                // says what the item is (the same glyph the old image
                // card used).
                Image(systemName: "photo")
                    .font(.system(size: 40))
                    .foregroundStyle(appearance.colors.textSecondary)
            case .loading:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.slotHeight)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        .accessibilityHidden(true)
    }

    /// Fetches and downsamples through the shared cache. Resets to the
    /// loading phase first, so a changed URL can never briefly show the
    /// previous photo, and re-checks cancellation after the awaits —
    /// `.task(id:)` cancels on identity change, and a result for a URL
    /// this view no longer shows is dropped, never assigned.
    private func load(_ url: URL) async {
        phase = .loading
        let loaded = await DownsampledImageCache.shared.thumbnail(
            forKey: "feedimg:\(url.absoluteString)",
            pointSize: Self.thumbnailPointEdge,
            displayScale: displayScale
        ) {
            // Runs only on a cache miss (the cache's contract). Any
            // failure — transport, status, undecodable bytes — is nil,
            // which renders the failure glyph.
            guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                return nil
            }
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return nil
            }
            return data
        }
        guard !Task.isCancelled else { return }
        phase = loaded.map(Phase.loaded) ?? .failed
    }
}
