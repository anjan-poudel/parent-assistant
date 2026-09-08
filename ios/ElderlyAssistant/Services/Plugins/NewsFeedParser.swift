import Foundation

/// One headline extracted from a news feed (news-reader feature,
/// 2026-09-08). Only the TITLE is kept — the digest speaks headlines, and
/// nothing else, so the parser deliberately ignores description/link/media
/// (no fabrication surface, no payload bloat).
struct NewsHeadline: Equatable {
    let title: String
}

/// Result of parsing one feed body. `.empty` is a WELL-FORMED feed with
/// zero items — honest "nothing new" — while `.malformed` is a feed we
/// could not trust (truncated/broken XML), which the reader reports as a
/// per-source failure, never as "nothing new".
enum NewsFeedParseOutcome: Equatable {
    case ok([NewsHeadline])
    case empty
    case malformed
}

/// RSS 2.0 + Atom headline extraction over `XMLParser` (Foundation's
/// built-in SAX parser — the app has no third-party XML dependency,
/// constitution §Architecture).
///
/// Both shapes reduce to the same walk: an ITEM CONTAINER is an `<item>`
/// (RSS 2.0) or an `<entry>` (Atom); a headline is the container's child
/// `<title>`. Channel/feed-level titles are never captured (their parent
/// is `channel`/`feed`, not `item`/`entry`), so "BBC News" can never be
/// spoken as if it were a headline.
///
/// Text-encoding split (deliberate, pinned by tests): the parser returns
/// titles as extracted — whitespace-trimmed only. `XMLParser` already
/// resolves character references in normal text nodes but NOT inside
/// CDATA, so extraction is raw-by-design; `NewsDigestComposer.sanitizedTitle`
/// is the single place that decodes HTML entities and strips
/// non-speakable artifacts (its decode is a no-op on already-decoded
/// text).
enum NewsFeedParser {

    /// Parses `data` as RSS 2.0 or Atom. `.ok` only when at least one
    /// non-blank headline exists; a well-formed feed with nothing to say
    /// is `.empty`; anything `XMLParser.parse()` rejects is `.malformed`.
    static func parse(_ data: Data) -> NewsFeedParseOutcome {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false   // elementName = local name
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else { return .malformed }
        return delegate.headlines.isEmpty ? .empty : .ok(delegate.headlines)
    }

    /// The delegate must stay alive for the whole parse (XMLParser holds
    /// it WEAKLY) — `parse` keeps a strong local for exactly that reason.
    private final class FeedDelegate: NSObject, XMLParserDelegate {

        private(set) var headlines: [NewsHeadline] = []

        /// Stack of open element names (lowercased), outermost first.
        private var containers: [String] = []
        private var capturingTitle = false
        private var currentTitle = ""

        /// True while the element open on top of the stack is an item
        /// container — checked at `title`-start time so only a title
        /// DIRECTLY inside an item/entry is captured.
        private var topIsItemContainer: Bool {
            guard let top = containers.last else { return false }
            return top == "item" || top == "entry"
        }

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = elementName.lowercased()
            let parentIsItem = topIsItemContainer   // BEFORE the push
            containers.append(name)
            if name == "title", parentIsItem {
                capturingTitle = true
                currentTitle = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturingTitle else { return }
            currentTitle += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.lowercased()
            if name == "title", capturingTitle {
                capturingTitle = false
                let title = NewsFeedParser.collapsed(currentTitle)
                if !title.isEmpty {
                    headlines.append(NewsHeadline(title: title))
                }
            }
            if !containers.isEmpty {
                containers.removeLast()
            }
        }
    }

    /// Whitespace-collapses raw extracted text (CDATA titles arrive with
    /// newlines/indentation that would garble TTS). Entity decoding and
    /// URL/tag stripping happen later, in the digest composer.
    static func collapsed(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
