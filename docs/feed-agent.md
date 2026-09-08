# Feed Agent — Mixed-Content Feed Screen

How the Feeds screen works — the mixed text/image/audio/video feed, its
sources and topic filtering, and the dedicated Settings → Feeds section.
Implemented 2026-09-08.

## What it does

The feed agent turns configured RSS/Atom sources into a social-feed-style
card list on the Home dock's Feeds leaf. Each item is one of four kinds —
text, image, audio, video — resolved from the feed's enclosures, filtered
by configured topic keywords, composed newest-first, and rendered as one
card per item with a single action. It is a **display-and-playback surface,
not a summarizer**: card text is the feed's own title/summary, sanitized,
never rewritten (constitution: no fabricated content).

The composition root lives in `AppCoordinator` like every other
store/service: the Settings leaf edits through the coordinator's mutation
methods, the Feed leaf renders the published state
(`feedItems` / `feedLoadState` / `feedFailedSourceNames`), and `FeedService`
itself publishes nothing — its results forward through `refreshFeed()` /
`refreshFeedIfNeeded()`.

## The mixed-content model

`FeedItemKind`: `.text`, `.image`, `.audio`, `.video` — resolved from an
item's enclosures (`FeedMediaResolver`); `.text` is the fallback for
enclosure-less items. One `FeedItem` carries: `id` (guid, else link, else
title, plus the source name appended so identical titles from two sources
can never collide), `title`, `summary`, `kind`, `publishedAt`, `linkURL`,
`imageURL` (any image-type URL, whatever the kind), `mediaURL` (the
audio/video stream — non-nil only for `.audio`/`.video`), and `sourceName`
(rendered on the caption exactly as the user named the source).

The parser (`FeedRSSParser`, Foundation `XMLParser` SAX — no third-party
dependency) handles RSS 2.0 (`<item>`: title, link, description or
`content:encoded`, guid, pubDate, `<enclosure url type>`, media-namespace
`<media:content>` / `<media:thumbnail>`) and Atom 1.0 (`<entry>`: title,
alternate/enclosure links, summary/content, id, published/updated). XML
character references and CDATA are decoded by `XMLParser` itself, so
titles/summaries arrive entity-free. Dates parse from RFC 822 (strict, then
a weekday-less loose shape) and ISO 8601 (plain, then fractional-second
fallback); a garbage date stays nil — the item simply has no date, never a
fabricated one.

**Enclosure resolution rules** (`FeedMediaResolver.resolve`, pinned by
`FeedMediaResolverTests`):

- Kind comes from **kind-bearing enclosures only** — a typed MIME
  (`audio/*`, `video/*`, `image/*`). First audio wins (a podcast episode
  with a splash image IS an audio item), else first video, else first
  image, else `.text`.
- **A thumbnail never decides the kind.** `media:thumbnail` references are
  captured as `thumbnailOnly` enclosures and excluded from kind resolution
  — a thumbnail on a text story is still a text story (BBC items all carry
  one; turning every article into an image card would bury the read-aloud
  action).
- `imageURL` carries the first image-type URL whatever the kind (an
  audio/video item keeps its thumbnail for the card), falling back to a
  `thumbnailOnly` reference when no real image enclosure exists.
- `mediaURL` is the chosen audio/video stream; nil for image/text items.
- Missing MIME types: `media:content` without `type` derives a family
  prefix from its `medium` attribute (`"image"` → `image/*`); otherwise
  "unknown" — never a fabricated type.
- Namespace note: `shouldProcessNamespaces = false`, so elements match by
  verbatim name (`"media:content"`, `"content:encoded"`); feeds that emit
  these under different prefixes are not handled (documented limitation —
  the curated defaults use the standard names).

A malformed feed parses to the items completed before the failure; a
structurally empty feed parses to `[]`. The caller treats either as "this
source failed" without ever fabricating items. Entries with both title and
summary empty are skipped (nothing to render or speak is not an item).

## Sources and topics configuration

`FeedSettingsStore` persists `FeedConfig` (sources + topics) in
`EncryptedLocalStorage` (Keychain, Data Protection Complete) under
`"feeds.config.v1"` — same bar as `FamilyContactStore`/`SavedPlaceStore`.
Bounds: `maxSources` 10, `maxTopics` 20.

**Seeding:** the first ever read stores the curated defaults; after that
the user's config is authoritative — removing every default (or every
source) persists, and a later read never re-seeds over the user's choices.

Curated defaults (verified reachable over HTTPS, 2026-09-08), one per feed
kind so the mixed feed shows its whole range out of the box:

| Name | Kind shown | URL |
|---|---|---|
| BBC World | text + thumbnails | `https://feeds.bbci.co.uk/news/world/rss.xml` |
| BBC नेपाली | text (Devanagari) | `https://feeds.bbci.co.uk/nepali/rss.xml` |
| NPR News | audio enclosures | `https://feeds.npr.org/1001/rss.xml` |
| NASA Image of the Day | image | `https://www.nasa.gov/feeds/iotd-feed/` |

Curated defaults carry fixed ids (`"default.*"`) so a re-seed can never
duplicate them, and an `isCuratedDefault` flag the Settings leaf shows as a
"default" tag — removable like any other source (their config, their
choice).

Adding a user source validates: non-empty name/URL, an http(s) URL with a
host (`FeedSettingsStore.isValidFeedURL` — syntactic only; reachability is
the fetch's own honest failure state), no duplicate URL, under the source
cap. The add form has ONE field (senior-friendly); the name derives from
the URL's host via `FeedSourceNameSuggester` (strips `www.`/`feeds.`,
capitalizes the first label). Topics reject empty, case-insensitive
duplicates, and the cap.

### Filter semantics

`FeedTopicFilter.matches` — case- and diacritic-insensitive substring match
of any configured topic against the item's title + summary:

- **Diacritic folding** is Latin-only in practice (`"CAFÉ"` ↔ `"cafe"`),
  verified empirically to pass Devanagari through byte-exact — matras and
  chandrabindu are not combining diacritics in the folding tables. Fold
  locale is pinned to `en_US_POSIX` for determinism.
- **Grapheme-safe:** every operation is `Character`-based, never
  scalar/UTF-16 surgery — Devanagari clusters match exactly as they read
  (the topic "का" matches "नेपालका समाचार", and राष्ट्र is never confused
  with रास्ट्र).
- **Substring, not word-boundary, matching** — documented and pinned:
  Nepali has no reliable word boundaries for tokenization, so "cat" matches
  "catalogue".
- **An empty topic list matches everything** (no filtering) — the settings
  hint states this, so leaving topics empty is the user's explicit "show me
  everything".

## The Feed screen

`FeedsView`, reached from the Home dock tile (`home.hub.feeds`,
`rectangle.stack.fill` icon, `.feeds` tint) and Settings → Feeds. Layout:

- **Header row** — item count (`feeds.count`) + "Check for new items"
  button (`feeds.refresh`, the full loading-indicated refresh path).
- **Content by load state** (`feedLoadState`): `.idle` → empty frame (the
  leaf's `.task` flips it); `.loading` → progress card; `.failed` → wifi
  icon + "The feed could not be loaded" + Try again button; `.loaded` →
  the cards.
- **Honest partial failure:** when some sources failed, a caption card
  lists their names (`feeds.partialFailure` — "Some sources could not be
  reached: …") above whatever did load — never a silent hole. Empty with
  zero failures is the honest `feeds.empty` card (nothing here yet — add
  sources or topics).

Cards and actions (one action per card, ≥44pt targets):

- **Text card** — title, up to 4 lines of sanitized summary, source +
  relative-time caption, and the single **"Read aloud"** action: the
  sanitized title + summary go through `coordinator.speak` (the app's
  single speech path — SpeakQueue `.interactive` lane, no card, no
  `AVSpeech`; the house rule). An item with nothing speakable is never
  enqueued.
- **Image card** — the photo itself (`AsyncImage`, honest progress and
  `photo` placeholder on failure), title, caption. No action — the image
  IS the content.
- **Audio/video card** — kind badge, title, 2-line summary, caption, and
  the single **"Play"** action presenting `FeedMediaPlayerSheet`. Disabled
  when the item has no playable URL (defensive-only state — the resolver
  only produces media kinds with a URL).

**Playback never autoplays.** The feed list itself plays nothing; the
player sheet only appears from the card's explicit Play tap, so that tap IS
the user's consent. `FeedMediaPlayerSheet` is deliberately one AVKit
`VideoPlayer` for both kinds (documented simpler option): audio plays
through the system transport controls on a fixed-height dark stage with a
speaker glyph overlay (so the empty stage never reads as a broken video),
video fills the sheet. Playback starts on appear and pauses + releases on
dismiss.

## Settings → Feeds

`FeedsSettingsView` is the dedicated section the brief demands — one leaf
managing three parts:

- **(a) Feed sources** — the list (curated defaults tagged "default",
  user-added identical in behaviour) with per-row trash removal, plus the
  one-field URL add form with host-derived name. A failed add keeps the
  draft and shows the honest caption (invalid address vs duplicate/cap/
  storage failure — nothing is claimed that didn't happen).
- **(b) Topics** — add/remove keyword chips, with the hint that an empty
  list shows everything.
- **(c) News sources** — the News Reader's editor slot: a push row into
  `NewsSourcesSettingsView` through the `NewsSourceEditorSeam.makeEditor`
  hook (assigned in `AppCoordinator.start()`); the honest "arrives with the
  News update" caption shows only when the seam is not wired.

The row lives in `SettingsView`'s settings list (`settings.feeds.title`).
Every mutation flows through the coordinator (`addFeedSource` /
`removeFeedSource` / `addFeedTopic` / `removeFeedTopic`), which re-reads the
store into the published lists (`reloadFeedConfig`) — the single path both
the Settings leaf and the next refresh's config read, so UI and service can
never disagree.

## Refresh, TTL and cache

`FeedService.refresh` — bounded fetch + compose pipeline:

- **Bounds:** 15 s hard timeout per source (`fetchTimeout`), 20 items per
  source (`maxItemsPerSource`, enforced in the parser), 100 items total
  (`FeedComposer.defaultMaxTotal`), 10 sources / 20 topics at the config
  layer. The fetch is bounded end to end.
- **TTL cache:** `cacheTTL` is 15 minutes. `refresh` serves the last good
  items without touching the network while they are younger than the TTL.
  The leaf's refresh-on-appear (`.task` → `refreshFeedIfNeeded()`)
  therefore re-fetches at most every fifteen minutes, shows the loading
  card only on the FIRST load, and refreshes silently behind existing cards
  afterwards — the network is never thrashed by re-entry. The manual
  Refresh/Retry buttons use `refreshFeed()` with visible loading.
- **Failure isolation:** one dead source never blanks the feed — its
  display name lands in `failedSourceNames` (honestly surfaced by the leaf)
  and every other source's items still compose.
- **Stale grace:** when EVERY source fails but a cache exists, the stale
  items are returned with the failure list — showing slightly old content
  plus "couldn't refresh" is more honest than pretending the feed is empty.
- The cache is in-memory only (items + fetch timestamp); feed items are
  transient third-party content, never persisted — a cold launch re-fetches.
  The cache is only written when at least one item was collected.
- State mapping (in `AppCoordinator.performFeedRefresh`): empty + failures
  → `.failed` (something is wrong); empty + clean → `.loaded` with the
  honest empty card.

`FeedComposer` orders the merged per-source lists: newest first by
`publishedAt` (stable within equal dates — source order is the tie-breaker);
items WITHOUT a published date sort after all dated items (the feed never
claims an unknown date is new); deduped by `id` within the refresh (first
occurrence wins); capped at `maxTotal`.

## Honesty limits

- Per-source failures are always surfaced (partial-failure card, or the
  failed card when nothing loaded and something failed).
- No fabrication anywhere: titles/summaries are the feed's own, sanitized;
  parse failures yield only items completed before the failure; garbage
  dates stay nil; missing MIME types stay unknown; entries with nothing
  renderable are skipped, never padded.
- Stale content is only ever shown labelled with the failure names — never
  presented as fresh.
- An honest empty feed (`.loaded`, zero items, no failures) is a normal
  state with guidance, not an error.
- Kind is display/playback only: an image kind with a failing image load
  shows an honest placeholder and still says what the item is.

## Privacy

- **PII-free logging:** `feed.fetch_source` observability events carry the
  source URL's **hostname** and the entry count only — never titles,
  summaries, or full URLs (a configured feed URL may embed a personal
  token; only the host is ever logged).
- Configuration (sources + topics) lives in encrypted Keychain storage —
  reading interests are not left in plaintext `UserDefaults`.
- Feed items are transient and in-memory only; nothing about the feed or
  the user's reading is persisted beyond the config itself.

## Where the code lives

| Concern | File |
|---|---|
| Models (`FeedItem`, `FeedItemKind`, `FeedSource`, `FeedConfig`, `FeedLoadState`) | `ios/ElderlyAssistant/Services/Feeds/FeedModels.swift` |
| RSS/Atom parsing (SAX, dates, enclosures, id) | `ios/ElderlyAssistant/Services/Feeds/FeedRSSParser.swift` |
| Enclosure → kind/URL resolution | `ios/ElderlyAssistant/Services/Feeds/FeedMediaResolver.swift` |
| Topic matching (folding, grapheme-safe) | `ios/ElderlyAssistant/Services/Feeds/FeedTopicFilter.swift` |
| Ordering/dedup/capping | `ios/ElderlyAssistant/Services/Feeds/FeedComposer.swift` |
| TTS/display sanitization | `ios/ElderlyAssistant/Services/Feeds/FeedSpeechSanitizer.swift` |
| Config store + defaults + caps + name suggester | `ios/ElderlyAssistant/Services/Feeds/FeedSettingsStore.swift` |
| Fetch pipeline (TTL, timeouts, stale grace, logging) | `ios/ElderlyAssistant/Services/Feeds/FeedService.swift` |
| Network seam (stub in tests, URLSession in production) | `ios/ElderlyAssistant/Services/Feeds/FeedTransport.swift` |
| Feed leaf + media player sheet | `ios/ElderlyAssistant/App/FeedsView.swift` |
| Settings → Feeds leaf (sources/topics/news seam) | `ios/ElderlyAssistant/App/FeedsSettingsView.swift` |
| Dock tile + leaf routing | `ios/ElderlyAssistant/App/HomeView.swift` (`LeafDestination.feed`, dock `home.hub.feeds`) |
| Settings row | `ios/ElderlyAssistant/App/SettingsView.swift` (`.feeds`) |
| Coordinator wiring | `ios/ElderlyAssistant/App/AppCoordinator.swift` (feed-agent section: stores, published state, refresh/mutation methods, `fireNewsReader`-adjacent shell wiring) |
| Strings | `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (`feeds.*`, `settings.feeds.*`, en + ne) |
| Tests | `ios/ElderlyAssistantTests/Services/Feeds/` — `FeedRSSParserTests`, `FeedMediaResolverTests`, `FeedTopicFilterTests`, `FeedComposerTests`, `FeedSpeechSanitizerTests`, `FeedSettingsStoreTests`, `FeedServiceTests` |

## How to extend

- **Add a source** — via Settings → Feeds (validated, capped, persisted), or
  ship a curated default by appending a `FeedSource` with a fixed
  `"default.*"` id to `FeedSettingsStore.curatedDefaults` (verify the feed
  live first — the house rule for every shipped default).
- **Add a topic** — via Settings → Feeds; semantics come from
  `FeedTopicFilter` (substring, folded, grapheme-safe). No code change
  needed unless the matching rules themselves change (then extend
  `FeedTopicFilterTests` first).
- **Add a new item kind** — four touch points: add the case to
  `FeedItemKind`; map a MIME prefix in `FeedMediaResolver.mimeKind` and
  honour it in `resolve`; capture the enclosing element in `FeedRSSParser`
  (RSS and/or Atom handler); render a card branch in `FeedsView.card(for:)`
  with its one action. Pin each layer with tests in
  `FeedMediaResolverTests` / `FeedRSSParserTests`.
- **Tune bounds** — `FeedService` (`fetchTimeout`, `maxItemsPerSource`,
  `cacheTTL`), `FeedComposer.defaultMaxTotal`, `FeedSettingsStore`
  (`maxSources`, `maxTopics`), `FeedSpeechSanitizer.maxSpeechLength` — each
  has pinning tests that assert the exact cap, so update them together.
- **Add a new spoken/display string** — `feeds.*` or `settings.feeds.*` key
  in `Localizable.xcstrings` with both `en` and `ne` values.
