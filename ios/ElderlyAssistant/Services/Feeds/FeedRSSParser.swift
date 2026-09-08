import Foundation

// MARK: - RSS/Atom parsing (feed-agent task, 2026-09-08)

/// SAX parser over Foundation's `XMLParser` — no third-party
/// dependencies. Handles RSS 2.0 and Atom 1.0 items:
///
/// - RSS: `<item>` with `<title>`, `<link>`, `<description>` /
///   `<content:encoded>`, `<guid>`, `<pubDate>` (RFC 822),
///   `<enclosure url type>`, media-namespace `<media:content>` /
///   `<media:thumbnail>`.
/// - Atom: `<entry>` with `<title>`, `<link href rel>`
///   (alternate → link, enclosure → media), `<summary>`/`<content>`,
///   `<id>`, `<published>`/`<updated>` (ISO 8601).
///
/// XML character references and CDATA are decoded by `XMLParser` itself
/// (`foundCharacters` receives decoded text), so titles/summaries arrive
/// entity-free — the pin tests assert that ("Tom & Jerry", not
/// "Tom &amp; Jerry").
///
/// Namespace handling: `shouldProcessNamespaces = false`, so element
/// names arrive verbatim ("media:content", "content:encoded") and match
/// by plain string — the only namespace-mangling risk is feeds that emit
/// those elements under DIFFERENT prefixes, which are not handled
/// (documented limitation; the curated defaults use these standard
/// names).
///
/// Robustness: a malformed feed parses to the items completed before the
/// failure (XMLParser calls `parseErrorOccurred`); a structurally empty
/// feed parses to `[]`. The caller treats either as "this source failed"
/// without ever fabricating items.
final class FeedRSSParser: NSObject, XMLParserDelegate {

    private let sourceName: String
    private let maxItems: Int

    private(set) var items: [FeedItem] = []

    /// Root element discriminates RSS vs Atom; anything else stays
    /// `.unknown` and produces no items.
    private var mode: Mode = .unknown
    private enum Mode { case unknown, rss, atom }

    // Per-item accumulation (reset on every item/entry start).
    private var inItem = false
    private var currentTitle = ""
    private var currentSummary = ""
    private var currentLink = ""
    private var currentDate: Date?
    private var currentID: String?
    private var enclosures: [FeedMediaResolver.Enclosure] = []
    /// The element whose character content is being accumulated.
    private var accumulating: Accumulator = .none
    private enum Accumulator {
        case none, title, summary, link, id, date
    }
    /// Date elements are buffered as text and parsed at end-element —
    /// `foundCharacters` may arrive in fragments, and parsing a fragment
    /// can never succeed.
    private var currentDateText = ""

    // MARK: - Date parsing (static — formatters are not thread-safe)

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    /// Fallback RFC 822 shape (some feeds omit the weekday or use
    /// "-0000"-style zones that the strict format above rejects).
    private static let rfc822Loose: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    /// Plain internet date-time — the canonical Atom shape
    /// ("2026-09-08T08:00:00Z"). MUST NOT carry `.withFractionalSeconds`:
    /// with that option set the formatter REQUIRES fractional seconds and
    /// rejects every whole-second timestamp (the exact bug the Atom
    /// date test pinned — the spec's `published` fixture has none).
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Fallback for feeds that publish fractional-second timestamps
    /// ("2026-09-08T08:00:00.123Z").
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = rfc822.date(from: trimmed) { return date }
        if let date = rfc822Loose.date(from: trimmed) { return date }
        if let date = iso8601.date(from: trimmed) { return date }
        return iso8601Fractional.date(from: trimmed)
    }

    // MARK: - Entry point

    /// Parses `data` into at most `maxItems` items. Never throws — a
    /// parse failure yields the items completed so far.
    static func parse(data: Data, sourceName: String, maxItems: Int) -> [FeedItem] {
        let parser = FeedRSSParser(sourceName: sourceName, maxItems: maxItems)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        xml.parse()
        return parser.items
    }

    private init(sourceName: String, maxItems: Int) {
        self.sourceName = sourceName
        self.maxItems = maxItems
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch mode {
        case .unknown:
            // Root element discriminates the dialect. Names arrive
            // verbatim (shouldProcessNamespaces = false), so prefixed
            // roots — "rdf:RDF" (RSS 1.0), "atom:feed" — must match by
            // suffix, not equality.
            if elementName == "rss" || elementName.hasSuffix("RDF") {
                mode = .rss
            } else if elementName == "feed" || elementName.hasSuffix(":feed") {
                mode = .atom
            }
            return
        case .rss:
            if elementName == "item" {
                beginItem()
                return
            }
            guard inItem else { return }
            handleRSSStart(elementName, attributes: attributeDict)
        case .atom:
            if elementName == "entry" {
                beginItem()
                return
            }
            guard inItem else { return }
            handleAtomStart(elementName, attributes: attributeDict)
        }
    }

    private func beginItem() {
        inItem = true
        currentTitle = ""
        currentSummary = ""
        currentLink = ""
        currentDate = nil
        currentID = nil
        enclosures = []
        accumulating = .none
    }

    private func handleRSSStart(_ elementName: String, attributes: [String: String]) {
        switch elementName {
        case "title":
            accumulating = .title
        case "description":
            accumulating = .summary
        case "content:encoded":
            // Prefer description; content:encoded is the fallback only
            // (handled on end-element — see handleRSSEnd).
            if currentSummary.isEmpty { accumulating = .summary }
        case "link":
            accumulating = .link
        case "guid":
            accumulating = .id
        case "pubDate":
            accumulating = .date
            currentDateText = ""
        case "enclosure":
            // RSS 2.0: <enclosure url="..." type="audio/mpeg" length="..."/>
            if let url = attributes["url"] {
                enclosures.append(FeedMediaResolver.Enclosure(
                    url: url, mimeType: attributes["type"]))
            }
        case "media:content":
            // Media RSS: <media:content url="..." type="image/jpeg"
            // medium="image"/>. Type is the MIME; when type is absent,
            // `medium` gives the family ("image" → image/*).
            if let url = attributes["url"] {
                let type = attributes["type"] ?? mediaFallbackType(medium: attributes["medium"])
                enclosures.append(FeedMediaResolver.Enclosure(url: url, mimeType: type))
            }
        case "media:thumbnail":
            // Thumbnail-only: an image URL candidate for the card that
            // must never flip a text story into an image item (see
            // FeedMediaResolver.Enclosure.thumbnailOnly).
            if let url = attributes["url"] {
                enclosures.append(FeedMediaResolver.Enclosure(
                    url: url, mimeType: nil, thumbnailOnly: true))
            }
        default:
            break
        }
    }

    private func handleAtomStart(_ elementName: String, attributes: [String: String]) {
        switch elementName {
        case "title", "summary", "content":
            accumulating = elementName == "title" ? .title : .summary
        case "id":
            accumulating = .id
        case "published", "updated":
            // Prefer published; updated is the fallback when no
            // published element arrives first.
            if currentDate == nil || elementName == "published" {
                accumulating = .date
                currentDateText = ""
            }
        case "link":
            handleAtomLink(attributes: attributes)
        default:
            break
        }
    }

    private func handleAtomLink(attributes: [String: String]) {
        let href = attributes["href"] ?? ""
        let rel = attributes["rel"] ?? "alternate"
        switch rel {
        case "enclosure":
            // Atom: <link rel="enclosure" href="..." type="audio/mpeg"/>
            if !href.isEmpty {
                enclosures.append(FeedMediaResolver.Enclosure(
                    url: href, mimeType: attributes["type"]))
            }
        case "alternate":
            if currentLink.isEmpty && !href.isEmpty { currentLink = href }
        default:
            break
        }
    }

    /// media:content without a MIME type: derive a family prefix from the
    /// `medium` attribute ("image" → "image/*"). Unknown/missing stays
    /// nil — never fabricate a type.
    private func mediaFallbackType(medium: String?) -> String? {
        switch medium?.lowercased() {
        case "image": return "image/*"
        case "audio": return "audio/*"
        case "video": return "video/*"
        default: return nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch accumulating {
        case .title: currentTitle += string
        case .summary: currentSummary += string
        case .link: currentLink += string
        case .id: if currentID == nil { currentID = string } else { currentID! += string }
        case .date: currentDateText += string
        case .none: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch mode {
        case .rss:
            guard inItem else { return }
            switch elementName {
            case "item":
                endItem()
            case "title", "description", "content:encoded", "link", "guid":
                accumulating = .none
            case "pubDate":
                accumulating = .none
                // Parse the buffered text; a garbage date stays nil
                // (the item simply has no date — never fabricated).
                currentDate = FeedRSSParser.parseDate(currentDateText)
            default:
                break
            }
        case .atom:
            guard inItem else { return }
            switch elementName {
            case "entry":
                endItem()
            case "title", "summary", "content", "id":
                accumulating = .none
            case "published":
                accumulating = .none
                // Published beats updated even when it arrives second;
                // a garbage published value falls back to whatever was
                // already parsed (updated).
                currentDate = FeedRSSParser.parseDate(currentDateText) ?? currentDate
            case "updated":
                accumulating = .none
                if currentDate == nil {
                    currentDate = FeedRSSParser.parseDate(currentDateText)
                }
            default:
                break
            }
        case .unknown:
            break
        }
    }

    /// Builds the completed item. Skipped when both title and summary are
    /// empty (a feed entry with nothing to render or speak is not an
    /// item), and past `maxItems` (bounded fetch — the spec's per-source
    /// cap; older items beyond the cap are simply not shown).
    private func endItem() {
        inItem = false
        accumulating = .none
        guard items.count < maxItems else { return }

        let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = currentSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !summary.isEmpty else { return }

        let resolved = FeedMediaResolver.resolve(enclosures: enclosures)
        // id precedence: guid/id, then link, then the renderable text —
        // with the source name appended so identical titles from two
        // sources can never collide into one deduped item.
        let fallback = title.isEmpty ? summary : title
        let id = (currentID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? currentLink.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallback) + "|" + sourceName

        items.append(FeedItem(
            id: id,
            title: title.isEmpty ? summary : title,
            summary: summary,
            kind: resolved.kind,
            publishedAt: currentDate,
            linkURL: currentLink.trimmingCharacters(in: .whitespacesAndNewlines),
            imageURL: resolved.imageURL,
            mediaURL: resolved.mediaURL,
            sourceName: sourceName
        ))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
