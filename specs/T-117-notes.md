# T-117 — Spotify localisation catalog — notes (F-7 record)

**Provenance, read this first.** This file was **created by T-120** (2026-10-07) because it did not exist: T-117 shipped in W1 (commit `a198830`) without a `specs/T-117-notes.md`, and its implementation evidence lives elsewhere — the doc comment and pinned copy in `ios/ElderlyAssistantTests/Services/Spotify/SpotifyLocalizationTests.swift`, the L10n pins in `L10nCatalogCoverageTests`, and the W1 review record `specs/implement-review-w1.md` (:42 carries the F-7 note on the review side). This file is **not** a reconstruction of T-117's own notes; it is the F-7 adjudication record that T-120's task file requires the settings surface work to leave "in T-117 as well as T-120". Nothing here was invented — every quoted string is the shipped catalog value.

## F-7 — `spotifySettings.removeConfirm` copy kept (deviation, recorded not fixed)

**Copy (shipped, both locales):**

- en: "Remove the Spotify connection? Music will use YouTube only."
- ne: "स्पोटिफाइ जडान हटाउने हो? संगीत युट्युबबाट मात्र बज्नेछ।"

**Adjudication.** T-120's settings surface renders this sentence as the unlink confirmation dialog. The operator review-l2's F-7 ruling offered "No — copy option" (keep the sentence as the design-l2 §31 choice); T-120 exercised the default — **keep the copy, record the deviation** — and changed no catalog copy.

**Why keeping is defensible.** The sentence's second clause is a shortcut summary, not a broken promise: with the connection removed, music playback runs through the YouTube path, and the router can still open the `spotify:search:` hand-off when YouTube cannot serve a request (matrix row 8). "YouTube only" is the household-facing outcome in the common case; the hand-off is plumbing detail the confirmation does not need to narrate.

**What would change it.** Any wording change is §31 copy territory (owner sign-off). If it is ever changed, it must be changed in `Localizable.xcstrings` (both locales), re-pinned in `SpotifyLocalizationTests` (the F-7 comment there is the catalog-side record), and the §31 table updated — the T-120 surface consumes the key and would pick the change up unchanged.

**Cross-reference.** Full T-120 record: `specs/T-120-notes.md` (D10 and the Deviations section).
