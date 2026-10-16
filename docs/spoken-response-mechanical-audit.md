# Spoken-response mechanical-phrasing audit

Date: 2026-10-14. Branch: `worktree-weather-wording` (line numbers are this
branch's). Method: two independent read-only sweeps — (1) deterministic
spoken surfaces (catalog templates, CommandRouter speak paths, briefing /
reminder / medication / alarm lines, correction and yes/no flows), (2)
model-reply prompts and the full TTS delivery pipeline (Speaker, SpeakQueue,
lanes) — merged and each finding's file:line re-checked against source
before writing this file. Severity reflects what an elder would actually
hear; entries are ranked by how OFTEN a surface is heard, not by how bad the
worst case is. "TTS would say" is the best reading of the espeak-based
Piper/sherpa path (the shipping voice); the AVSpeechSynthesizer fallback
handles some symbols better. Exact voice readings of individual symbols
("pm", "™", "mg") could not be verified by running the voice in this
environment and are marked as such.

**Status (fix pass, 2026-10-14): all 19 items resolved — FIXED with the fix
location, or WONTFIX with the reason (item 11 only).** The structural fix is
one shared normalization pass at the speaker seam, plus the dose/measure
unit expansion in `SpokenUnits`, four template groups and the L10n miss
contract.

## The fix architecture (what item 3 became)

The prompt-independent guarantee now lives in ONE place:
`SpokenTextNormalizer.normalize(_:locale:)` (new file
`ios/ElderlyAssistant/Services/Voice/SpokenTextNormalizer.swift`, entry at
:79) runs inside BOTH concrete speakers —
`SystemSpeechSpeaker.speak` (`Services/Voice/Speaker.swift:392`) and
`PiperVoiceSpeaker.speak` (`Services/Voice/Speaker.swift:923`, deliberately
AFTER `resolveVoiceSpec` so the voice-audition matcher still sees the raw
utterance). Every spoken path in the app funnels through those two
functions — SpeakQueue lanes, direct `speaker.speak` calls, plugin/guide
text, LiveTranslate read-aloud, feed read-aloud, the notification reader,
nav steps — so producers keep their raw text for their cards and only what
is SPOKEN is normalized. Ordered stages: whitespace + ™®©, media-title
noise, dose units (`SpokenUnits.normalizeDoseUnits`), measure units
(`SpokenUnits.normalizeMeasureUnits`), temperatures
(`SpokenUnits.normalizeTemperatures`), numeric ranges, clock times through
`SpokenTime`, hostnames, street suffixes, symbols & money, quote/paren
character removal, prose dashes. Idempotent by contract (the polisher may
have run first; replies get re-spoken) — pinned by a 16-case fixed-point
test. Locale-aware (en + ne, Devanagari digits per the house convention).

New/changed tests: `SpokenTextNormalizerTests` (new; per-stage vectors +
the fixed-point corpus), `SpokenUnitsTests` extended (dose + measure
suites, en + ne), `PiperVoiceSpeakerTests` +2 seam tests
(`testSpeakNormalizesSpokenTextAtTheSeam`,
`testSeamNormalizesEnglishMechanicals`), `MorningBriefingTests` pins
updated to the new template forms, `NotificationReaderTests` mirrors the
new `L10n.fmt` app-language impl. No-build gate: a faithful python
replication of the two Swift sources ran 87 vectors + 16 corpus lines + 26
function-level pins, 0 failures, every output also checked as a fixed
point.

## HIGH

### 1. Medication dose text is spoken letter-by-letter, every day
- `Services/Plugins/MorningBriefing.swift:325-328` — the morning briefing's
  medication line joins `[medicationName, entry.doseDescription, time]` with
  " — ". Key `briefing.medications` en "Your medications today: %@".
- `Services/MedicationScheduler/PlatformAlarmScheduler.swift:89` — the dose
  notification body `meds.reminderNotificationBody` "Time to take your %@"
  (with a strength often embedded in the caregiver-typed name, e.g.
  "Amlodipine 5mg"), which the notification reader then SPEAKS
  (`Services/Plugins/NotificationReader.swift:156-166`).
- `Services/MedicationScheduler/ConfirmationChallenge.swift:38` —
  "Is that the %@?" where %@ is caregiver free text ("1 tab 500mg").
- Current text: "Your medications today: Amlodipine — 500 mg — 8:00 am."
- TTS would say: "…five hundred **em gee**…", "one **slash** two tablet" for
  "1/2 tablet", possibly a raw "½" skip. The OCR path normalizes strength to
  "500 mg" (still "em gee").
- Suggested: a shared dose speech normalizer (mg→"milligrams", ml→
  "millilitres", 1/2→"half", ½→"half", +→"plus") applied to the SPOKEN copy
  only; the card keeps the raw text. Highest-frequency mechanical text in
  the app (daily briefing + every dose alert).
- **Status: FIXED** — `SpokenUnits.normalizeDoseUnits`
  (`Services/Voice/SpokenUnits.swift:205`): mg/mgs→milligram(s)/मिलीग्राम,
  mcg/µg/ug→microgram(s)/माइक्रोग्राम, ml/mls→millilitre(s)/मिलीलिटर,
  IU→international unit(s)/अन्तर्राष्ट्रिय युनिट, "1/2"/"१/२"/"½"→half/आधा,
  singular on 1, ASCII digits→Devanagari under `ne`. Composed at the seam
  (dose stage). All three surfaces reach a speaker, so briefing, alarm
  notification and the confirmation challenge are covered without producer
  edits; card text keeps the raw "500 mg".

### 2. Model prompts teach brevity but never ban mechanical tokens
- `Services/Voice/GeminiCommandInterpreter.swift:35-41` (`replyPersona`),
  `Services/Voice/LlamaCommandInterpreter.swift:552-564` (`chatSystemPrompt`),
  `IntentPrompt.swift` — none instruct "write times and numbers in words;
  never 5-6 PM, 50%, ₹500, U.S., 8:00 AM in the `response` field".
- This task added the temperature-units sentence to both personas only.
  The broader token class is still model-discretion.
- Suggested: one shared anti-mechanical sentence in both personas plus the
  general normalizer below (prompt guidance alone is not deterministic).
- **Status: FIXED** — both personas now carry the broader sentence:
  GeminiCommandInterpreter.swift:39-42 and LlamaCommandInterpreter.swift:558-561
  ("Speak units, times, money and percents as words, never symbols: … never
  \"15°C\", \"15c\", \"8:00 AM\", \"50%\", \"Rs. 500\""). Kept short for the
  1,024-token brain context. The deterministic enforcement remains the seam
  below, not the prompt. `IntentPrompt.swift` untouched (byte-pinned by
  PinnedSurfaceGuardTests).

### 3. There is no TTS pre-processing stage at all (systemic)
- `Services/Voice/Speaker.swift:384` (`AVSpeechUtterance(string:)`), `:549`
  (`tts.generate(text:)`), `:918` (`engine.synthesize(text,…)`);
  `Services/Voice/SpeakQueue.swift:421-427` and the reply lanes pass text
  through raw. Nothing strips symbols, expands numbers/units, or fixes
  abbreviations between any reply and either engine.
- Every finding below is an instance of this gap. A shared
  speech-text normalization stage (or per-producer normalizers) is the
  structural fix.
- **Status: FIXED** — `SpokenTextNormalizer` at the two speaker seams (see
  "The fix architecture" above). Both engine paths (`AVSpeechUtterance` and
  `engine.synthesize`) now receive normalized text; SpeakQueue lanes are
  covered because the queue speaks only through these speakers.

## MEDIUM

### 4. Search answers speak the raw hostname
- `Services/Voice/SearchTool.swift:134-135` appends
  `search.sourceLine` = "— %@" with the host from `displayHost`.
- TTS would say: "… — B B C **dot com**." Snippets/titles also pass with
  only whitespace collapse, so "12.5%"/"₹500" read mechanically.
- Suggested: speak the site name only ("from BBC") or drop the source line
  from speech; keep the card.
- **Status: FIXED** — hostname stage: subdomains (www/m/mobile/amp/…)
  stripped until the registrable label ("www.bbc.com"→"bbc",
  "news.bbc.co.uk"→"bbc", e-mail never matches). The source line's "—"
  reads as a comma pause; percent/money in snippets normalize via the same
  pass. `search.sourceLine` template unchanged (card keeps the raw line).

### 5. Now-playing titles are spoken raw ("feat." → "feet")
- `Services/Plugins/SpotifyPlugin.swift:151` (`spotify.playing`), 
  `Services/Plugins/YouTubePlugin.swift:90` and `CommandRouter.swift:3140`
  (`youtube.playing`). Only whitespace collapsing exists
  (`Services/Spotify/SpotifyTool.swift:303`).
- TTS would say: "Playing Shape of You **feet** Ed Sheeran…";
  "(Official Video)"/" - Single" read out or pause awkwardly.
- Suggested: strip parentheticals and " - Single/Remastered" suffixes from
  the SPOKEN copy.
- **Status: FIXED** — media-title stage: "(Official Video)"/"(Lyrics)"/
  "(Official Lyric Video)"/"(HD)"/"(4K)" stripped, "(Remastered 2011)" and
  " - Single/- Remastered/- Deluxe" suffixes dropped, "feat."→"featuring".
  An organic parenthetical keeps its words (only the parens are dropped by
  the later stage). SpotifTool's own whitespace collapse untouched.

### 6. LiveTranslate read-aloud speaks the on-screen string verbatim
- `Services/LiveTranslate/LiveTranslateSpeech.swift:136-140` — by design
  ("the spoken string is the on-screen string"); translated signs/prices
  ("Rs. 500/kg", "50% off") reach the speaker raw.
- Suggested: minimal speech-only normalization on the spoken copy, or
  documented acceptance.
- **Status: FIXED** — the seam normalizes the synthesis input, so "Rs.
  500/kg" is read "500 rupees per kilogram". The plan/announcement text
  stays byte-identical to the screen; the by-design contract comment now
  says exactly that (`LiveTranslateSpeech.swift:26-33`).

### 7. Plugin/guide model text bypasses the polisher
- `Services/Voice/CommandRouter.swift:4805` and `:4847` speak
  `result.spokenText` directly; `NepaliCalendarPlugin.swift:55-87` answers
  are LLM prose spoken with no symbol/number rule; appliance
  `spokenSummary` has no reply-style guidance.
- Suggested: route `.spoken` plugin results through the polisher.
- **Status: FIXED** — the polisher bypass remains (deliberate: plugin text
  is not reply-shaped), but SPEECH no longer depends on the polisher: the
  seam normalizes at the speaker boundary, which is downstream of every
  `.spoken` path.

### 8. Feeds full-article read-aloud sanitizes structure only
- `Services/Feeds/FeedSpeechSanitizer.swift:42-53, 78-98, 119-121` — strips
  HTML/URLs/whitespace, but "kg", "₹500", "45%", "e.g.", "COVID-19" survive;
  espeak letter-spells unknown clusters. Full-article reading runs to 4000
  chars (`:37`).
- **Status: FIXED** — `FeedSpeechSanitizer` unchanged (it owns structure);
  the unit/money/percent tokens it passes through are normalized by the
  seam on the way to the synthesizer.

### 9. Notification read-aloud: raw bodies, and the medication line resolves in the SYSTEM locale
- `Services/Plugins/NotificationReader.swift:156-166` — the medication lane
  uses `NSLocalizedString` (system language), not `L10n` (app language): on
  an English-system phone with the app in Nepali the elder hears English
  "Medicine time: …" mid-Nepali. Non-medication lanes speak
  `content.body` verbatim (`:194-196`).
- **Status: FIXED** — the reader now resolves through
  `L10n.fmt("notification.read.medication", locale: AppLanguage.persisted().locale, name)`
  (`NotificationReader.swift:165`; doc comment updated). Bodies ride the
  seam. `NSLocalizedString` is gone from the reader.

## LOW-MEDIUM

### 10. News digest entity map can PRODUCE symbol-speak, and the digest is spoken
- `Services/Plugins/NewsReader.swift:161-169` maps "deg"→"°", "trade"→"™",
  "copy"→"©", "pound"→"£"…; `digestText` (:118) is exactly what `fire()`
  enqueues (:345). "28° in Kathmandu" → engine-dependent symbol read.
  Rare in real headlines today; flagrant when it fires.
- Suggested: map to words ("degrees") or scrub from the spoken copy.
- **Status: FIXED via the seam** — bare "°" reads as "degrees" (scale never
  invented), ™/© are dropped, "£" as pounds. The entity map itself is
  unchanged (card text); only speech is affected.

### 11. English spoken times still emit "pm" and ":"
- `Services/Voice/SpokenTime.swift:56-61` ("1 pm", "1:30 pm");
  `TopicPreAnswer.swift:207-216` ("It's 9:05 in the morning."). This is the
  deliberate, test-pinned convention; AVSpeechSynthesizer reads it well,
  Piper/espeak "pm" reading is unverified. Kept — flagged for a voice
  verification pass, not a quiet change.
- **Status: WONTFIX** — deliberate test-pinned convention (English "1:30
  pm"); the shakedown pass kept it as a fixed point
  (`SpokenTextNormalizerTests.testClockTimesFlowThroughSpokenTime` pins
  "12:30 pm" unchanged), it reads well on the fallback voice, and changing
  it silently would fight `SpokenTimeTests`. Remains flagged for the voice
  verification pass.
- Note (fix-pass carry-over): the seam's clock stage still routes RAW
  "8:00 am"/"8:00 PM" through `SpokenTime` ("8 am"/"8 pm"), so model text
  and templates converge on the pinned convention.

## LOW

### 12. Em dash "—" separators in spoken lines
- `MorningBriefing.swift:305, 328`; `RoutinePlugin.swift:163`;
  `ExternalCalendarService.swift:351`; `AppCoordinator.swift:11705`;
  `search.sourceLine`; `alarms.setFailed` ("Sorry — I couldn't set that
  alarm."). Both engines most likely pause/skip; mechanical on the
  transcript card. Suggested: ", " or "at" in speech.
- **Status: FIXED via the seam** — prose dashes become ", " ("Sorry — I
  couldn't set that alarm." → "Sorry, I couldn't…"); a sentence-final dash
  is a separator, tight en/em numeric dashes are handled by the range
  stage. Templates unchanged (cards keep the dash).

### 13. Quotes in calendar confirm/created lines
- `router.calendarEventConfirm` en `Should I add "%1$@", at %2$@, to your
  calendar?` (ne uses «»), `router.calendarEventCreated`
  (`AppCoordinator.swift:8196, 8274`). Most voices drop quotes; some say
  "quote…unquote". Suggested: drop the marks in spoken templates.
- **Status: FIXED via the seam** — quote characters (en `"`, curly
  “”, «») are dropped from speech; templates keep the marks so the CARDS
  still show the quoted event title. Chosen over template edits because
  every quoting source (calendar, corrections, plugin text) is then
  covered at once.

### 14. Parentheses in the call-disambiguation line
- `router.call.disambiguate` "I found more than one matching person (%@)."
  Suggested: "…person: %@." 
- **Status: FIXED** — en template is now "I found more than one matching
  person, %@. Please say the full name." (ne already colon-free); the seam
  drops parens anyway for any other source.

### 15. "Tap to call." is spoken as part of the contact-search result
- `call.search.spokenFound` "Found %@. Tap to call." spoken at
  `App/LeafViews.swift:1575` — a touch instruction during a voice turn.
  Suggested: speak "Found %@."; keep the rest on screen.
- **Status: FIXED** — en "Found %@." / ne "%@ फेला पर्यो।" (ZWJ preserved);
  the visible list below the search row keeps its own affordances, so
  nothing is lost on screen.

### 16. In-app navigation steps are spoken verbatim in the DEVICE language
- `Services/Navigation/InAppNavigationSession.swift:333-341` — "St", "Ave",
  "Hwy" abbreviations; a Nepali voice reading English street names. Rare
  (fallback path only).
- **Status: FIXED (abbreviations)** — the street-suffix stage expands
  St→Street, Ave→Avenue, Rd→Road, Blvd→Boulevard, Hwy→Highway, Ln/Ct/Pl/Ter
  under capitalization, while "St. Louis" and "Dr. Smith" are protected
  (and "dr" is deliberately not a drive token). The separate
  voice-language question (a Nepali voice reading English street names) is
  a voice-selection matter, out of this pass's scope.

### 17. Colon-label templates
- `router.reminderSet` "Reminder set: %@" (`CommandRouter.swift:4593`),
  `briefing.*` "…: %@", `notification.read.medication` "Medicine time: %@".
  Benign pause; listed for completeness.
- **Status: FIXED** — templates changed at the value level:
  `router.reminderSet` en "Reminder set, %@" / ne "सम्झना राखियो, %@";
  `briefing.routines`/`briefing.medications`/`briefing.calendar`/
  `briefing.weather` en "…. %@" / ne "…। %@";
  `notification.read.medication` en "Medicine time, %@". (`home.outcome.reminderSet`
  keeps its colon: display-only outcome card, never synthesized — the
  spoken twin is `router.reminderSet`.)

### 18. Latent: a missing catalog key would be SPOKEN as the raw key
- `App/L10n.swift:29` falls back to `String(localized:)` which returns the
  key itself; `CommandRouter.speak(key:)` (:4962-4967) guards only
  `isEmpty`, so "router.foo.bar" would be read aloud. Every reachable
  spoken key was resolved during this audit and none miss TODAY; the trap
  is future-facing. Also known dead keys that would speak raw if wired:
  `dialogue.correction.or` (declared, absent from catalog, unused),
  `router.calendarEventWriteFailed` (absent, unreferenced),
  `calculator.op.power/modulo` (absent, currently unreachable).
- Suggested: return "" on total miss, or detect `text == key` in
  `speak(key:)`.
- **Status: FIXED** — `L10n.str` returns "" on a total miss
  (`App/L10n.swift:36`), so the EXISTING emptiness guards in
  `CommandRouter.speak(key:)` / `speakWithVisibleOutcome` and the
  notification reader turn a miss into silence (verified: the guards were
  already in place and only needed a truthful empty). `fmt` documents the
  empty contract; `ModelCatalogEntry.displayName` is now empty-aware
  (`L10n.swift:79`). The three dead keys, if ever wired, resolve to
  silence — not gibberish.

### 19. Compose-ack speaks the model reply without the polisher
- `Services/Voice/CommandRouter.swift:4758` — sanity-gated but unpolished
  model text (a "15°C" here would NOT be normalized). Low frequency.
- **Status: FIXED** — the compose-ack text reaches a speaker like every
  other reply, so the seam normalizes it; no producer change needed.

## Checked and found acceptable

- Alarm/timer set/off/snooze confirmations use `SpokenTime` and
  `AlarmTimerCommandParser.durationText` ("5 minutes", "१ घण्टा ५ मिनेट");
  ring time plays only the bell WAV (no TTS).
- Calculator echoes use operator WORDS and Devanagari digits under Nepali.
- Correction/"did you mean" prompts (`dialogue.didYouMean`), the candidate
  probe, and all call/calendar/launch confirm questions are natural prose.
- `meds.scan.found` speaks the OCR-extracted NAME only (strength stripped).
- `notification.read.summary` "You have %d new notifications" — counts read
  normally. Festival `fallsOn` and `topic.date.now` are clean.
- Weather: fixed in this task (`weather.reply*` templates carry no ° sign;
  `SpokenUnits` covers model free text).

## Resolution log

- Fix pass (2026-10-14, same worktree, same no-build/no-commit constraints):
  items 1-10, 12-19 FIXED; item 11 WONTFIX (reasons at the item).
- Gate: python replication of the two formatter sources — 87 vectors + 16
  idempotence-corpus lines + 26 function-level pins, 0 failures; every
  vector additionally proven a fixed point. Swift-side pin updates are
  listed in "The fix architecture" above. No Xcode build was run (constraint).
