# News Reader Plugin — Voice News Digest

How the "read me the news" voice digest works — what it speaks, where it
fetches from, and how the family configures it. Implemented 2026-09-08 as the
voice-OS shell's second push speech source beside `MorningBriefing`.

## What it does

The news reader turns the user's configured news sources into a short spoken
digest. It is a **headline digest, not an LLM summary** — every spoken line is
either a source's verbatim (sanitized) headline, a pinned per-source honest
failure/empty line, or the pinned all-failed/all-empty line. The app never
paraphrases news it did not fetch and never attributes to a source something
that source did not publish (constitution: no fabricated content).

It is a `SpeechSource` (`sourceID` `"news_reader"`) registered with the
`SpeechSourceRegistry`, push-driven like `MorningBriefing`
(`nextAnnouncement()` is always nil). Announcements ride the `.briefing`
lane of the speak queue, so a digest waits for whatever is being spoken and
is itself interrupted only by safety-critical lanes.

Key behaviours:

- **Deterministic trigger, zero tokens.** Fired only by the `CommandRouter`
  news stage (see below), never by the LLM interpreter — it consumes no
  `IntentPrompt` budget and can never be misclassified into a topic answer.
- **Never blocks the voice turn.** `fire()` enqueues the localized
  "checking" line first, then fetches every source **concurrently**, each
  with the same 8 s timeout the search tool uses
  (`NewsReader.perSourceTimeoutSeconds`) — the whole round-trip is ~8 s,
  not 8 s × sources.
- **One digest per command.** A second `fire()` while a fetch is in flight
  is a guarded no-op that speaks the honest "already fetching" line and
  emits `news_fire_skipped`. On-demand: no once-per-wake-window budget.
- **Dormant default.** With no transport injected (tests, or before
  `AppCoordinator.start()` wires `URLSession.shared`), every source fails
  honestly — the reader degrades to the `news.allFailed` line, never a fake
  digest.

## How to trigger it

The `CommandRouter` news stage matches the lowercased transcript against
`CommandRouter.newsPhrases` — full-phrase containment only:

| Language | Phrases |
|---|---|
| English | `read me the news`, `read the news`, `tell me the news`, `what's the news`, `whats the news`, `what is the news` |
| नेपाली | `समाचार सुनाऊ`, `समाचार सुनाउनुहोस्`, `समाचार पढ`, `खबर सुनाऊ`, `खबर सुनाउनुहोस्`, `खबर पढ` |
| Romanized | `samachar sunau`, `samachar sunaunuhos`, `khabar sunau` |

All STT spacing variants ship ("what's" / "whats" / "what is").

Vetoes (same discipline as the briefing phrase list, pinned by
`NewsStageRoutingTests`):

- The bare words "news" / "समाचार" are deliberately absent — an utterance
  that merely mentions news ("news from my son about school") can never
  hijack the stage.
- Imperative/question forms only — a noun phrase ("today's news") never
  matches.

Placement in the routing ladder: after the safety net, confirmation flow,
contact search, directions, alarms/timers, and the morning briefing stage
(a briefing utterance can never be swallowed by the news stage), and before
the topic table (a greeting-prefixed "नमस्ते, खबर सुनाऊ" is a digest, never
small talk). The stage only decides and hands off to
`coordinator.fireNewsReader()`; the reader owns every spoken line and its
outcome card.

`fire()` sequence:

1. Speak + card `news.checking` ("Let me check the news." /
   "म समाचार ल्याउँदैछु।") with the `newspaper` symbol.
2. Fetch all `store.effectiveSources` concurrently; each outcome is
   `.ok` / `.empty` / `.failed` (mapping pinned in `NewsReader.fetchSource`:
   no transport, unparseable URL, transport throw, non-2xx, or malformed XML
   → `.failed` — never `.empty`, which would claim the source had nothing).
3. Compose the digest and enqueue it as one `.briefing`-lane announcement
   with its own card (`newspaper.fill` symbol, title `news.cardTitle`).

## Default sources and the replace-defaults rule

`NewsSourceStore.defaults` ships six curated sources, all verified live on
2026-09-08 (HTTP 200, well-formed XML):

| Name | Language | Feed URL |
|---|---|---|
| BBC World | en | `https://feeds.bbci.co.uk/news/world/rss.xml` |
| NPR News | en | `https://feeds.npr.org/1001/rss.xml` |
| The Guardian | en | `https://www.theguardian.com/world/rss` |
| Online Khabar | ne | `https://www.onlinekhabar.com/feed` |
| Ratopati | ne | `https://ratopati.com/feed` |
| Setopati | ne | `https://www.setopati.com/feed` |

**REPLACE rule (pinned, tested):** `effectiveSources` is exactly the
configured list whenever at least one source is configured — "when the user
has configured sources, those are the news" — and the curated defaults only
while the configured list is empty. This keeps one mental model for the
elderly user (what the family saved is what is read) and avoids surprising
mixed-language merges.

Kantipur (ekantipur.com) was requested as a default but publishes **no
public RSS endpoint** as of 2026-09-08 (`/feed` and `/rss` both 404). The
two Kantipur-region Nepali portals with real feeds (Ratopati, Setopati)
stand in. See "Known limits".

## Digest format

`NewsDigestComposer` turns per-source fetch results into the spoken digest.
Pure statics — no network, no queue — so templates and sanitization are
unit-testable without fakes.

- **Top `maxHeadlinesPerSource` (3) per source**, in configured feed order.
  Bounded so a 6-source digest stays a digest — the user hears a summary,
  not a newspaper.
- **One line per source**, in feed order, whenever at least one source has
  items:
  - `news.sourceLine` ("From %@:" / "%@ बाट:") + up to 3 headlines, each
    ending with its sentence stop.
  - Sentence stop is the house convention (same pair as the search tool):
    `. ` in English, `। ` in Nepali. Example shape:
    `"From BBC World: H1. H2. H3."` / `"अनलाइन खबर बाट: शीर्षक। शीर्षक। शीर्षक।"`
  - A source with nothing → `news.sourceEmpty` ("Nothing new from %@." /
    "%@ बाट नयाँ समाचार छैन।").
  - A source that could not be reached → `news.sourceFailed` ("%@ could not
    be reached." / "%@ बाट समाचार लिन सकिएन।").
- **Global honest lines (pinned rules):**
  - every source failed → ONE `news.allFailed` line, not six failure lines
    in a row;
  - every source fetched fine but had nothing → ONE `news.allEmpty` line;
  - a mix of failures and empties with NO items → per-source lines (which
    sources are down and which merely have nothing is real information);
  - zero sources (a configured-then-cleared race) → `news.allFailed` rather
    than silence (constitution: no silent stubs).
- Every `.ok` line ends with its sentence stop, so headline lists read as
  finished sentences and TTS pauses cleanly before the next source line.
- The full text is `lines(...)` joined by newlines — exactly what gets
  enqueued and spoken, and the outcome card body.

## TTS sanitization

`NewsDigestComposer.sanitizedTitle` is the single gate a title must pass
before it may be spoken. Pipeline: decode HTML entities → strip embedded
tags → strip URLs → collapse whitespace → trim → strip dangling trailing
colons. A trailing colon is a list/continuation artifact ("Read more:
<url>") — once the URL is gone the colon reads aloud like a prompt for text
that never comes, so it is stripped. **No other symbol scrubbing:** titles
are prose, and over-sanitizing corrupts Nepali script.

- Entity decode is a single pass (a second pass could decode already-decoded
  text twice — `&amp;quot;` must become `&quot;`, not a quote) covering
  numeric entities and a named table of what actually appears in real feed
  titles (`&amp;`, `&#039;`, `&nbsp;`, `&hellip;`, `&mdash;`, …). Unknown
  named entities degrade to their inner text — no content invented or
  destroyed.
- A title that sanitizes to nothing is dropped; a source whose titles all
  sanitize to nothing renders the honest `news.sourceEmpty` line, never a
  bare "From X:".
- The render seam re-sanitizes every title defensively (idempotent — a no-op
  in production, since `fetchSource` already sanitized).

The parser (`NewsFeedParser`) is deliberately raw: RSS 2.0 + Atom over
Foundation's `XMLParser` (no third-party XML dependency), capturing only
item/entry child `<title>` elements (channel/feed-level titles can never be
spoken as headlines), whitespace-collapsed only. Only the title is kept —
description/link/media are ignored, so there is no fabrication surface and
no payload bloat. A well-formed feed with zero items is `.empty` (honest
"nothing new"); a feed `XMLParser` rejects is `.malformed`, reported as a
per-source failure — never as "nothing new".

## The store API

`NewsSourceStore` persists the configured source list in
`EncryptedLocalStorage` (Keychain, Data Protection Complete — household
configuration, so plaintext `UserDefaults` is not acceptable;
constitution §Security), as one JSON array under the key `"news.sources"`.

```swift
final class NewsSourceStore: ObservableObject
@Published private(set) var configuredSources: [NewsSource]   // bind directly to a List
var effectiveSources: [NewsSource]                            // REPLACE rule: configured, else defaults
func list() -> [NewsSource]                                   // configured only (settings editor)
@discardableResult func add(_ source: NewsSource) -> Bool     // write-through
@discardableResult func remove(id: UUID) -> Bool
@discardableResult func save(_ sources: [NewsSource]) -> Bool
@discardableResult func clear() -> Bool                       // back to defaults ("use built-in sources")
static let defaults: [NewsSource]                             // curated list, for the restore affordance
```

All mutations are **persist-first**: memory changes only when the Keychain
write succeeded, so the editor can show an honest failure line and
`@Published` observers never see state that is not on disk. `NewsSource` is
`Codable`, keeps its URL as a string so an invalid-but-preserved entry still
round-trips for repair, and carries an informational `languageCode` tag used
for grouping by the editor.

The digest itself is deliberately **not persisted**: news is ephemeral, and
storing it would add a headline-carrying payload for no user benefit.

## Privacy

Observability component `news_reader`, PII-free: event metadata carries
counts and outcome tags only — source index, headline count, ok/empty/failed,
and the defaults-vs-configured mode. Headline text, source names, and the
digest itself never reach the bus or any log; they exist only inside the
in-memory `Announcement`. Events: `news_fire_started`,
`news_source_result` (per source), `news_digest_delivered`,
`news_fire_skipped`, plus `news_reader_command` emitted by the router stage.

## The settings editor

`NewsSourcesSettingsView`, hosted by Settings → Feeds under the
"News sources" section. The Feeds settings leaf renders the section through
the `NewsSourceEditorSeam.makeEditor` static hook, assigned in
`AppCoordinator.start()` once the store exists:

```swift
NewsSourceEditorSeam.makeEditor = { AnyView(NewsSourcesSettingsView(store: newsSourceStore)) }
```

The editor is deliberately senior-friendly and URL-driven (the elderly
primary user is never asked to type URLs — a family member does this):

- a list of configured sources (name + URL) each with a trash button
  (`settings.feeds.removeSource` accessibility label);
- an empty-state caption when nothing is configured — which, per the
  REPLACE rule, means the digest reads the defaults;
- **one-field add form**: paste a feed URL; the display name is derived
  from the URL's host when left blank (fallback "News source");
- an honest failure caption when the Keychain write fails (draft kept —
  nothing is claimed that didn't happen).

Because the editor shows `configuredSources` and the digest reads
`effectiveSources` with the same REPLACE rule, what the editor shows is
exactly what the voice digest reads.

## Known limits

- **Kantipur has no public RSS** as of 2026-09-08 — no fabricated URL is
  shipped; Ratopati and Setopati stand in. When ekantipur restores a feed,
  add it to `NewsSourceStore.defaults` or via Settings → Feeds.
- **No LLM summarization, by design.** The digest speaks verbatim
  (sanitized) headlines only — the constitutional no-fabrication rule
  makes headline-digest the ceiling, not a temporary compromise.
- Only RSS 2.0 and Atom item shapes are parsed (same parser class as the
  feed agent); other syndication dialects parse as `.malformed` and report
  as an honest per-source failure.
- The digest is ephemeral — there is no news history screen and nothing is
  stored after the announcement.

## Where the code lives

| Concern | File |
|---|---|
| Reader + fetch + observability | `ios/ElderlyAssistant/Services/Plugins/NewsReader.swift` |
| Digest composition + TTS sanitization | same file, `NewsDigestComposer` enum |
| RSS/Atom headline extraction | `ios/ElderlyAssistant/Services/Plugins/NewsFeedParser.swift` |
| Source model + store + defaults (REPLACE rule) | `ios/ElderlyAssistant/Services/Storage/NewsSourceStore.swift` |
| Trigger phrases + routing stage | `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` (`newsPhrases`, the `[NEWS-READER]` stage; `fireNewsReader()` on `VoiceCommandCoordinating`, inert by default) |
| Coordinator wiring | `ios/ElderlyAssistant/App/AppCoordinator.swift` (`newsReader` creation + `SpeechSourceRegistry` registration, `fireNewsReader()`, locale injection, lazy `newsSourceStore`) |
| Settings editor | `ios/ElderlyAssistant/App/NewsSourcesSettingsView.swift` |
| Editor seam hosted by Feeds settings | `ios/ElderlyAssistant/App/FeedsSettingsView.swift` (`NewsSourceEditorSeam`) |
| Spoken strings | `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (`news.*` keys, en + ne) |
| Tests | `NewsReaderTests.swift`, `NewsDigestComposerTests.swift`, `NewsFeedParserTests.swift` (Tests/Services/Plugins), `NewsSourceStoreTests.swift` (Tests/Services/Storage), `NewsStageRoutingTests.swift` (Tests/Services/Voice) |

## How to extend

- **Add a default source** — append a `NewsSource` to `NewsSourceStore.defaults`
  (short, plain, TTS-friendly `name`; correct `languageCode`). Verify the
  feed live first (HTTP 200, well-formed XML) — the house rule for every
  shipped default. A source added via Settings → Feeds replaces the
  defaults wholesale, so defaults matter only for the out-of-box digest.
- **Add a trigger phrase** — append to `CommandRouter.newsPhrases`, keeping
  the veto discipline (full multi-word phrases only, imperative/question
  forms; never the bare words "news"/"समाचार"), and extend
  `NewsStageRoutingTests` with both a positive and a near-miss (veto) case.
- **Add a spoken line** — add the `news.*` key to `Localizable.xcstrings`
  with both `en` and `ne` values (both languages are pinned by tests for
  every spoken template), then use `L10n.str`/`L10n.fmt` in the composer
  or reader.
- **Tune the digest size** — change `NewsDigestComposer.maxHeadlinesPerSource`
  (and its pinning tests); the per-source fetch cap follows it
  (`NewsReader.fetchSource` prefixes by the same constant).
