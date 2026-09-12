# VoiceBridge AI — Sahayak User Manual

**The voice-first assistant for everyday life.** The app on your home screen is called
**VoiceBridge AI**; the assistant who speaks to you is called **Sahayak** (सहायक — "helper").
This manual explains everything Sahayak can do for you, how to do each thing by voice and by
touch, and — just as important — what Sahayak will honestly *never* do.

**Everything in this manual is also available inside the app in Nepali (नेपाली).** Every
button, every screen, and every spoken sentence exists in both English and Nepali. You can
speak to Sahayak in either language at any time — Sahayak replies in the language you chose
in Settings (see "Language & region" in the Settings tour).

**This whole manual also ships inside the app itself** — Settings → Manuals → *User manual*
(and the appliance helper's manuals library) — as a phone-friendly, bilingual guide (it
follows the app's language setting: Nepali in Nepali, English otherwise). The in-app
version is illustrated with generated sketch diagrams (clearly labelled as sketches, not
screenshots): the Talk-button traffic lights, the home-screen layout, the voice flow, the
Updates screen, the confirmation chips, the calendar card, the Phone screen, the feed
cards, the Show-Me camera, and the alarms & timers list. This document is the English
source of truth for that content.

Throughout this manual, every feature follows the same four-part pattern:

1. **What it does** — in plain language.
2. **By voice** — what to say.
3. **By touch** — where to tap.
4. **What it will never do** — the honesty guarantee.

---

## 1. Quick start (your first 15 minutes)

### 1.1 Installing

Sahayak runs on any iPhone with iOS 16 or newer. Install it the way you install any app
(usually a family member sets this up for you). The app is named **VoiceBridge AI**.
It needs a microphone — that is how it hears you.

### 1.2 First launch — the welcome wizard

The first time the app opens, a simple four-step welcome appears. **Every step can be
skipped** (tap *Skip* at the top right) — nothing locks you in, and skipped steps show up
later as a small reminder on the home screen (*"N setup steps left"* — tap it to finish them
any time).

| Step | What you see | What to do |
|---|---|---|
| **1. Choose language** | "Which language should the assistant talk in?" | Pick **English** or **नेपाली** (Nepali is pre-selected). Sahayak will speak to you in this language. |
| **2. Allow permissions** | Two cards: **Microphone** and **Notifications** | Tap *Allow* on each. The microphone lets Sahayak hear you; notifications carry your medication reminders and alarms. |
| **3. Family and friends** | Name, phone number, relationship, Messenger username | Type the person to notify if something goes wrong — or skip; you can add people later in Settings. |
| **4. Connect Gemini AI** | A box for a "Gemini API key" | This is a family-member job (see section 4i). **Skip is fine** — medicines, alarms, timers, the news and emergency phrases all work without it. Tap *Go to Home*. |

After the wizard finishes (or is skipped), the voice feature switches on and the home
screen appears.

### 1.3 The Talk button — its colour tells you what it is doing

The big round button in the middle of the home screen is how you talk. Each state has a
distinct colour and written label:

| Colour | State | Button says | What it means |
|---|---|---|---|
| **Burgundy and pink** (glossy face, breathing rings) | Resting | "Talk" / "I'm ready" | Sahayak is awake and waiting for you. Tap (or say the wake phrase) and speak. |
| **Amber** (three deepening shades) | Working | "Listening…" → "Writing…" → "Thinking…" | Sahayak heard you: first listening, then writing your words down, then understanding them. |
| **Green** | Speaking | "Speaking" | Sahayak is replying to you out loud. |
| **Red** | Something wrong | "Try again" | Something failed — the small line under the button says exactly what (e.g. microphone is off). An *Open Settings* button appears when the fix is there. |
| **Dim blue** | Voice off | "Voice off" | The voice pipeline is stopped. Tap the button to start it again. |
| **Yes / No chips** | Confirming | "Please confirm" | Sahayak asked you a yes/no question (e.g. about a call or a medicine). Tap **Yes** or **No** — or just say "yes" / "हो" / "no" / "होइन". |

Three touch tricks worth learning early:

- **Tap once** when it is burgundy → starts listening.
- **Tap once while it is working or speaking** → cancels the current turn (an escape hatch —
  the same thing happens automatically after 40 seconds if it ever gets stuck).
- **Press and hold for 2 seconds** → resets the voice completely. A white ring fills up
  while you hold; when it completes you hear *"Voice reset. I'm ready."* Use this whenever
  voice misbehaves — it fixes most problems (see Troubleshooting).

### 1.4 Three sentences that always work

Try these on day one:

1. **"Set a timer for 5 minutes"** — नेपाली: "टाइमर ५ मिनेट". Sahayak confirms:
   *"Timer started for 5 minutes."* Timers work even without any setup.
2. **"Read me the news"** — नेपाली: "समाचार सुनाऊ". Sahayak checks its news sources and
   reads you a short headline digest.
3. **"Call my daughter"** — नेपाली: "छोरीलाई फोन गर". Sahayak asks you to confirm
   (*"Make a phone call to …?"*), then dials. This one needs the person to be saved in
   **Family and friends** (Settings) first.

### 1.5 A tour of the home screen

From top to bottom:

- **Top bar** — from left to right:
  - **Settings gear** — opens all settings.
  - **Today's date** — shows the active calendar date and tithi; tap it to open the
    **Calendar** screen.
  - **Bell** — opens **Updates**. A small number badge shows how many notification panels
    are waiting; it always matches what the Updates screen lists.
  - **Emergency triangle** — the red-edged warning triangle. It is on *every* screen, not
    just Home. Tap it and Sahayak speaks *"Help is on the way…"*, posts an emergency
    notification, and dials your emergency contact (see section 4d).
- **Quick apps row** — your favourite apps (WhatsApp, YouTube, Phone…) as one-tap tiles.
  This row appears only after someone picks favourites in Settings → **Quick apps**; the
  plus tile on the right opens that picker.
- **The Talk button** — the traffic light from section 1.3. Under it, while resting, a small
  pill rotates through example sentences you can literally imitate ("I took my medicine",
  "Remind me at 8 in the morning", "Call my son", "What's the weather today?").
- **The feedback card** — after each exchange it shows what you said and what Sahayak
  replied (in case you didn't catch it by ear). It folds into a one-line chip after a few
  seconds; tap it to reopen. Some actions show an **Undo** button.
- **Conversation chip** — a small "Conversation" capsule above the dock opens the full
  history of what you and Sahayak have said (20 rows per page, tap *Show more* for older).
- **The dock** — the six big buttons at the bottom edge:
  | Tile | Opens |
  |---|---|
  | **Medication** (pill icon) | Today's medicines + doctor's appointments |
  | **Reminders** (clock icon) | Today's full reminder list |
  | **Call** (phone icon, or your first family contact's face) | Family & friends, the phone book, recent calls |
  | **Show Me** (camera icon) | Camera helper for appliances + the manuals library |
  | **Directions** (map icon) | Your saved places and the map |
  | **Feeds** (stacked-cards icon) | The mixed news feed |

### 1.6 The bell — the Updates screen

Tap the bell (or open *Updates*) for one screen with three sections, each always with a
heading:

- **Notifications** — the currently active panels: today's morning briefing, medication
  status, and any other active notices. Tapping a row opens its screen (e.g. the briefing).
  If nothing is pending, it honestly says *"No notifications right now."*
- **Today** — today's Nepali date, tithi and any festival, plus *"Next: <medicine name> at
  <time>"* — the very next thing you must not miss today.
- **Activity** — a read-only log of your recent conversations with Sahayak, newest first,
  with the time of each exchange.

---

## 2. Talking to the assistant

### 2.1 How one turn works

Every voice turn runs the same four steps — you can watch them on the button colours:

1. **Listening** (amber) — you speak. Sahayak listens until you have been quiet for about
   one second (long enough for natural pauses and slow speech — up to 8 seconds maximum).
2. **Writing** (deeper amber) — your words appear in the "You're saying" card.
3. **Understanding** (deepest amber) — Sahayak decides what you meant: a command, a
   question, or an answer to *its* question.
4. **Speaking** (green) — the reply is spoken aloud *and* written on the card, so you never
   miss it just because you didn't hear it.

### 2.2 Two ways to start talking

1. **Tap the Talk button** — always works, on the home screen.
2. **The wake phrase** — say **"ये कान्छी"** (sounds like *"yeah kanchhi"* — a warm Nepali
   "hey, dear"), pause briefly, then speak your command, for example
   *"ये कान्छी … समाचार सुनाऊ"*. With the wake phrase on, no button press is needed at all.
   Note: a few screens in Settings still print the older name "Hey Sahayak" for this
   phrase — the phrase Sahayak actually listens for is **"ये कान्छी"** (yeah kanchhi), as
   shown on the Voice activation screen's phrase card. The wake phrase can be switched off
   (and on) in Settings → **Voice activation**; the Talk button works regardless. While it
   is on, the microphone listens continuously, which uses a little more battery — the
   Settings screen says so in plain words.

### 2.3 When Sahayak doesn't understand

Sahayak never pretends. Three honest outcomes:

- **It didn't understand you** → *"Sorry, I didn't understand. Please say that again."*
  Just repeat, a little slower and clearer (the app already tolerates uneven spacing
  between words).
- **It understood, but is not confident** → it asks back:
  *"Did I understand that correctly? Please say yes or no."*
- **Its "brain" is not ready yet** → it says exactly that instead of blaming you:
  *"I'm not ready to answer yet. My brain model is still downloading — this only happens
  once."* or *"I can't answer that yet — my brain isn't set up…"* — a family member fixes
  this in Settings (section 4i).

### 2.4 Both languages, any time

Speak **English or Nepali** freely — mixing is fine. All 800+ pieces of screen text exist
in both languages, and the language you pick in Settings → **Language & region** decides
both the on-screen text and the language Sahayak speaks back.

### 2.5 Replies are made to be heard

- Times are always spoken the way people say them — *"6 in the morning"* / *"बिहान ६ बजे"*,
  never "zero-six-hundred" (a dedicated spoken-time formatter guarantees this everywhere:
  alarms, reminders, the briefing, the time question).
- Speech is slightly slower than normal by design (5% below natural pace).
- Every reply is also written on the screen.
- If a spoken reply is ever impossible (e.g. voice files missing from the build), Sahayak
  stays **silent rather than mangling Nepali into gibberish** — the text is always there.
  The Voices screen (Settings → **Voices**) shows plainly which voices are installed.

### 2.6 Yes/No questions and the 45-second rule

When Sahayak needs confirmation — a call, a medicine, a place — it asks out loud and shows
big **Yes / No** buttons. Answer by voice ("yes" / "हो", "no" / "होइन") or by tap. If no
answer comes within 45 seconds, Sahayak says *"Time is up. I'll remind you again."* and
returns to listening.

### 2.7 The morning briefing

Once a day, Sahayak reads you a short summary of your day:

- **What it does:** greeting → today's date (in the Nepali calendar when your language is
  Nepali) → today's routines → today's medicines → today's calendar events → a weather
  line. Anything with nothing scheduled is honestly reported empty (*"No routines scheduled
  today"*), and weather that can't be fetched says so instead of inventing a forecast.
- **By voice:** *"Read me my briefing"* / "मेरो ब्रीफिङ सुनाऊ" — works at any hour.
- **Automatic:** the first time you open the app between **5:00 and 10:00 in the morning**,
  Sahayak reads it on its own. Once per day either way — a second request the same day is
  politely skipped.
- **Saved for later:** the exact text is stored (encrypted) for the whole day. Find it in
  Updates → Notifications → *Today's briefing*, where a **Speak again** button re-reads the
  stored text (it never re-composes, so you hear exactly what was said this morning).

---

## 3. Voice command reference

Every row below is verified against the app's actual command tables. "Deterministic" means
the app matches the words itself — no AI, no setup, works offline. Phrases in
[romanized Nepali] also work.

| What it does | English phrasings | नेपाली phrasings | Notes |
|---|---|---|---|
| **Emergency** — reassurance + emergency notification | "help", "emergency", "i fell", "fell down", "chest pain", "can't breathe" | "मद्दत", "सहयोग गर", "बचाउ", "आपतकाल", "लडेँ", "लडें", "लड्नुभयो", "सास फेर्न सकिन", "सास फेर्न गाह्रो", "छाती दुख्यो" | Deterministic — always first, never blocked by anything, even mid-question. Speaks "Help is on the way. I'm notifying your family." + posts a notification. The **Emergency button** (any screen) additionally dials your emergency contact. |
| **Medicine: I took it** | "I took my medicine", "I've taken my medication", "took my medicine" | "औषधि खाएँ", "दवाई खाए", "औषधि लिएको छु", "लिइसकेँ", "खाइसकें" | Deterministic. Triggers the confirmation challenge (section 4a). Saying "not yet"/"नखाए"/"खाएको छैन" is understood as a *refusal* — the app is careful about word tricks like "नखाए" containing "खाए". |
| **Set an alarm** (daily) | "set an alarm for 6 am", "wake me up at 7:30", "alarm at 8 pm", "set an alarm for 6:30 am for yoga" (label) | "बिहान ६ बजे अलार्म लगाऊ", "अलार्म ८ बजे", "बिहान ६ बजे उठाउनुहोस्" | Deterministic. A time already past today rolls to tomorrow. Rings daily through the app's own notification (iOS doesn't allow writing to the Clock app — said honestly in Settings). Max 20 alarms. |
| **Turn the alarm off** | "turn off the alarm", "cancel my alarm", "switch off the alarm" | "अलार्म बन्द गर", "अलार्म बन्द गर्नुहोस्", "रद्द गर" | Turns off the alarm that most recently rang; the confirmation always names its time so a wrong target can't pass silently. "Cancel the 6 am alarm" is deliberately *not* guessed — do that by touch. |
| **Snooze** | "snooze", "snooze for 15 minutes" | "स्नुज गर", "स्नुज १५ मिनेट" | Bare "snooze" = 10 more minutes; 1–60 minutes accepted. A one-shot re-wake; the daily alarm stays untouched. |
| **Set a timer** | "set a timer for 5 minutes", "timer 10 minutes", "1 hour timer", "1 hour 30 minutes" | "टाइमर ५ मिनेट", "५ मिनेटको टाइमर लगाऊ", "१ घण्टाको टाइमर" | Deterministic. 1 second to 24 hours; compound durations ("1 hour 30 minutes") parse as one timer. Max 10 running. Finishing speaks "Timer finished." while the app is open. |
| **News digest** | "read me the news", "read the news", "tell me the news", "what's the news" | "समाचार सुनाऊ", "समाचार पढ", "खबर सुनाऊ", "खबर पढ", [samachar sunau, khabar sunau] | Deterministic. Up to 3 headlines per source, read per source with honest failure lines (section 4e). |
| **YouTube** | "play bhajan on youtube", "youtube news", "search youtube for old songs" | "युट्युबमा गीत चलाऊ", "युट्युबमा रामायण खोज", "युट्युबमा भजन चलाऊ" | Deterministic. With no API key: opens YouTube search. With a key: plays the top result and speaks its title. |
| **Directions** | "take me home", "take me to the hospital", "bring me home", "directions to …" | "मलाई घर लैजाऊ", "मैयाको घर लैजाऊ", "अस्पताल लैजाऊ", "घर जानुहोस्", [ghar laija] | Deterministic. Navigates to saved places and family addresses. Google Maps opens in walking mode and starts navigating on its own. If two places could match, Sahayak asks — never guesses a place. |
| **Find a contact** | "contact search ram", "maiya ko phone khoja" | "मैयाको फोन नम्बर खोज" | Deterministic. Opens the Phone screen with the search already typed and speaks the result ("Found मैया. Tap to call."). |
| **Make a call** | "call my son", "call Maiya", "video call my daughter" | "छोरालाई फोन गर", "मैयालाई कल गर" | Needs the brain (Gemini key or on-device model) + the person in Family & friends. Sahayak always asks first: "Make a phone call to …?" — nothing dials until you say yes. You can correct it: "no, call on Messenger". |
| **Send a message** | "send a message to my son: I will be late" | "छोरालाई सन्देश पठाऊ …" | Opens the phone's message sheet (or WhatsApp) with your words pre-filled — **you** tap Send; Sahayak never sends by itself. |
| **Reminder by voice** | "remind me at 8 in the morning", "remind me tomorrow at 5 pm" | "बिहान ८ बजे सम्झना राख" | Needs the brain. Confirms with the spoken time: "Reminder set: …" |
| **Routine by voice** | "walk at 5", "exercise every day at 7" | "बेलुका ५ बजे हिँड्ने सम्झना" | Needs the brain. Creates a repeating daily or weekly routine reminder. |
| **Calculator** | "2 plus 3", "10 times 4", "100 minus 25" | "२ जोड ३", "५ गुणा ४" | Deterministic, no brain needed. "Divide by zero" gets the honest "You can't divide by zero." |
| **Weather** | "what's the weather today", "is it raining in Arncliffe" | "आजको मौसम कस्तो छ?", "भोलिको मौसम कस्तो छ?" | Depends on your voice engine (section 4i): live answer on the on-device engine (open-meteo, hedged "According to the weather service…"), web-grounded answer on the Gemini engine, otherwise the honest "I can't check the live weather yet." |
| **Time / date** | "what time is it", "what's the date today" | "कति बजे", "कति गते" | Deterministic. Nepali date answer uses the Bikram Sambat calendar with the weekday ("आज बुधबार, असोज २२, २०८३ हो।"). |
| **Greeting** | "good morning", "hello" | "नमस्ते", "सुप्रभात" | Deterministic warm reply. |
| **Web search** (open questions) | any question: "who won the match yesterday?" | — | Only on the **on-device** engine with family-set Google search credentials; up to 50 searches/day; question-shaped utterances only. The Gemini engine answers open questions natively. |
| **Not yet available** | music, health data, calendar-event creation by voice | — | Sahayak says honestly: "That feature isn't ready yet, but it's coming." — never pretends it worked. |

---

## 4. Deep dives

### 4a. Medical — medications, appointments, and the safety checks

**What it does.** The Medication screen (dock tile, pill icon) shows **today's doses** with
times, and — below — the **Doctor's appointments** list.

**Taking a dose — by touch.** Tap **"I took it"** next to a dose.

**Taking a dose — by voice.** Say *"I took my medicine"* / *"औषधि खाएँ"*.

**The confirmation challenge (dementia-aware).** Either way, before anything is recorded,
Sahayak asks out loud — *"Did you take your <name> just now?"* — and shows big Yes/No
buttons. Answer yes (voice or tap) to record the dose. Why the extra question: a yes/no
challenge is the design's protection for users with memory difficulties, and a built-in
**double-dose guard** refuses a second "taken" within the safety window (4 hours for
once-daily medicines, 2 hours for twice-daily) instead of double-counting. Missed-dose
escalation re-prompts automatically. If you say you haven't taken it, Sahayak accepts that
calmly: *"Okay, I'll remind you again later."*

**Doctor's appointments.**
- **What it does:** a list of upcoming appointments (doctor/clinic, place, date, time,
  note), newest first, stored encrypted, up to 50.
- **By touch:** the **Medical** screen → *Add appointment* form; or copy an appointment SMS
  in the Messages app and tap **"Paste appointment message"** — Sahayak reads the text off
  the clipboard and shows you exactly what it understood for your confirmation before
  saving anything. The clipboard is read *only* on that tap — never in the background.
- **Honesty — SMS reading:** the iPhone does not let apps read text messages, so
  appointment texts can never be added automatically; the screen says this in a one-time
  note and points to the paste button and the voice alternative ("add a doctor
  appointment").
- **Calendar seam:** the **"Add appointments to the iPhone Calendar"** toggle (default ON)
  is the switch that will write appointments into the iPhone Calendar app. **Honest status
  today:** the writing backend is not yet wired into this build — the toggle and the intent
  are real, but appointments currently live in the app only. Family can mirror the daily
  *routine* to the Calendar app already (see 4c).
- **Settings → Medication schedule:** where the family types each medicine's name and
  time(s); duplicate name+time pairs are refused. Below it, **Festival reminders**: how
  many days early (0–7, default 2) important festivals notify.

**What it will never do:** mark a dose as taken without your yes; accept "नखाए" as "खाए";
double-count a dose inside the safety window; claim an SMS was read automatically; claim an
appointment was written to the iPhone Calendar when it wasn't.

### 4b. Reminders — routines, today's list, and what comes in from outside

**What it does.** The Reminders screen (dock tile, clock icon) merges **three reminder
systems** into one list sorted by time:

1. **Medication doses** (from the medical system — read-only here),
2. **Routine occurrences** (walk, exercise, meals, bedtime… — past ones stay visible,
   dimmed, as context for the day),
3. **Items imported from your iPhone's own Calendar and Reminders apps** (marked with
   their calendar's name; tapping one opens it in its own app — the import is read-only,
   the app never writes to them).

**The daily routine.** The app comes with seven sensible routine reminders that the family
can switch on or off right on this screen: exercise (7:00 and 16:00), meals (8:00, 13:00,
19:00), a walk (17:30) and bedtime (21:30) start **on**; gym (Mon/Wed/Fri 9:00), reading
(20:15) and "call a relative" (Sunday 18:00) start **off**. Voice-created reminders appear
here too.

**Upcoming events.** Below today's list, an **Upcoming events** section shows the next five
events from the iPhone Calendar app (beyond today). If more exist, a *Show more* button
opens the Calendar screen. This section only appears while the import toggle is on; if the
import is denied or failing, it says so instead of pretending nothing is coming.

**Settings → Calendar** hosts the three import/mirror switches (see 4c).

**What it will never do:** write or change anything in your iPhone Calendar/Reminders apps
through the import (strictly read-only); re-fire a late routine as if it were on time
(late walk reminders are dropped as noise — only *medication* re-fires, because medicine is
safety-critical).

### 4c. Calendar — the Nepali calendar and the two-way mirror

**What it does.** The Calendar screen (tap today's date at the top of Home) shows:

- **Today in the Nepali calendar** — Bikram Sambat date in Nepali numerals (e.g.
  "आइतबार, भदौ २१, २०८३"), the **tithi** for every day, and the English date beneath.
  The BS conversion is fully offline and covers 1978–2099 BS; if a date falls outside the
  table it honestly says the Nepali date is unavailable rather than guessing.
- **Festival today** — with its tithi, when one falls on the day.
- **Upcoming festivals** — the next five with BS dates and "in N days" (in Devanagari
  numerals for Nepali).
- **Today's routine** — the same merged schedule as Reminders (medicines + routines +
  imported events).

**Festival notifications.** Every festival gets a day-of notification (08:00); the
important ones (Dashain, Tihar, Teej, Laxmi Puja, Chhath, New Year…) also notify N days
early — N is set in Settings → Medication schedule → *Festival reminders* (0–7, default 2).

**The calendar settings leaf** (Settings → **Calendar**) — three switches, each with an
honest status line beneath it:

1. **Show in Calendar app** (mirror out) — copies your daily routine into the iPhone
   Calendar app so the family can see it there. Calendar access is asked only when you
   switch it on; if denied, everything still works in-app and the status line says so.
2. **Mirror routine changes both ways** (two-way, **off by default**) — mirrored routine
   events live in a dedicated **"Sahayak" calendar** inside the Calendar app; edits made
   *there* (time changes, deletions) flow back into the app's routine. Needs full calendar
   access, asked only when switched on. This switch only works while mirroring itself is
   on.
3. **Import from Calendar & Reminders** — reads your native events and due reminders into
   the app (today's lists + notifications), never writes back. When on, a stepper sets how
   many minutes early to notify (0–30); all-day items always announce at 8:00 AM.

**What it will never do:** fabricate a Nepali date outside the verified conversion table;
warn about a festival on the wrong day (all festival dates are a fixed curated BS-date
catalog, with lunar-sighted ones marked); pretend two-way sync is working when full
calendar access wasn't granted.

### 4d. Phone & people — calling, searching, and the emergency button

**What it does.** The Phone screen (dock tile **Call**) is the hub for people: it leads
with your curated **Family & friends** tiles, offers whole-phone-book search, and keeps
**Recent activity** at the bottom.

**Family & friends (curated).**
- Each tile shows the person's photo (or initials), name and relationship, with two big
  buttons: **video call** and **audio call** — one tap dials. Tapping the tile itself in a
  search result dials through the person's chosen channel.
- **Settings → Family and friends** manages the list (up to 12 people) with a five-step
  wizard: (1) find them in your contacts — or add manually, (2) relationship from a fixed
  list (daughter, son, mother, father, sister, brother, husband, wife, grandmother,
  grandfather, friend, **Doctor/GP**), plus an **Emergency contact** flag, (3) photo,
  (4) Messenger username (with hints on where to find it), (5) nickname + home address
  (the address is what lets voice navigation say "take me to Maiya's home").
- People flagged **Emergency** wear a red badge; **Doctor/GP** wears a green one.

**Searching the whole phone book.** Tap the magnifying glass on the header. The search
sweeps the *system* address book — your own entries plus everyone synced in by WhatsApp,
Messenger and other apps. Matches rank people you recently called first. Contacts
permission is asked at that moment, behind a plain-language card; the family tiles keep
working either way. There's a small **mic button** inside the search pill for speaking a
name instead of typing. If WhatsApp people are missing, the screen shows the one-line fix
(WhatsApp → Settings → Privacy → Sync contacts).

**Choosing how to call a person.** Each result row's big circle dials through the person's
**resolved channel** — a per-person choice, or the global default (Settings → **Calling**:
FaceTime / Phone / Messenger / WhatsApp). The "…" menu picks the channel per person;
Messenger needs that person's username on file (a handle sheet collects it). The WhatsApp
pill always opens the official WhatsApp chat form. **Tapping a contact is its own
confirmation** — it's your finger on your own phone, same as any contacts app.

**Calls by voice.** "Call my son" → Sahayak resolves the name or relationship against
Family & friends, announces the plan, and asks yes/no; corrections like "no, call on
Messenger" are understood. If it recently dialed the same person, it mentions that. If the
name isn't in Family & friends, it says so and points at Settings.

**Call history & missed calls.** *Recent activity* (bottom of the Phone screen; the full
History leaf via "Show more") logs only what **Sahayak itself** opened — the app never
reads the iPhone's own call log (iOS forbids it). Rows tap-to-redial through the same
channel. **Missed calls** are detected anonymously (iOS masks the caller's identity and
number); such rows read "Unanswered call" and tapping opens the Phone app — the call
genuinely lives in its Recents tab, one tap away. A live-call banner shows while a call is
connected.

**The Emergency button** (red triangle, every screen). What it does, exactly: speaks and
posts *"Help is on the way. I'm notifying your family."* and dials your emergency contact —
the first contact flagged **Emergency contact**, or the first contact if none is flagged.
If no contact exists at all, it honestly alerts you instead of pretending. The voice
emergency phrases (section 3) do the reassurance + notification; the button is what places
the real phone call.

**What it will never do:** dial by voice without your "yes"; pretend a WhatsApp "call" was
started (WhatsApp has no call deep link — a WhatsApp call request honestly opens the chat);
invent a missed caller's name or number (iOS masks them — the app says "Unanswered call",
not a guess); read the iPhone's call log.

### 4e. News reader — the spoken digest

**What it does.** *"Read me the news"* turns your configured news sources into a short
**spoken headline digest** — the source's own headlines, never an AI summary.

- **Default sources** (used until someone configures their own): BBC World, NPR News, The
  Guardian (English) and Online Khabar, Ratopati, Setopati (Nepali) — all live-verified.
- **The replace rule:** the moment at least one source is configured in Settings, the
  digest reads *exactly* the configured list — defaults are only the out-of-box list. What
  the family saved is what gets read; nothing else.
- **Digest shape:** "Let me check the news." → per source, *"From BBC World: headline.
  headline. headline."* — at most 3 headlines each, all sources fetched in parallel with
  the same 8-second budget. A source with nothing new → *"Nothing new from X."*; a source
  that can't be reached → *"X could not be reached."*; everything down → one honest
  *"I couldn't fetch the news right now."* — never six failure lines, never a fake digest.
- **Settings editor:** Settings → **Feeds** → *News sources* — a list with delete buttons
  and a one-field add form (paste a feed URL; the name is derived from the address).
  Family-facing by design — the elderly user is never asked to type URLs.

**What it will never do:** paraphrase news it didn't fetch, attribute a headline to a
source that didn't publish it, or store a headline anywhere after it's spoken (news is
ephemeral; nothing is kept on disk or in logs).

### 4f. Feeds — the mixed-content feed

**What it does.** The Feeds screen (dock tile) turns RSS/Atom sources into a
social-feed-style card list — **text, picture, audio and video** items mixed together,
newest first, filtered by the family's topic keywords.

- **Default sources:** BBC World (text), BBC नेपाली (text in Devanagari), NPR News
  (audio), NASA Image of the Day (images) — one per kind so the mixed feed shows its whole
  range out of the box. Up to 10 sources and 20 topics total.
- **Cards and their one action:** text cards → **"Read aloud"** (title + summary spoken by
  Sahayak's voice); image cards → the picture itself (no action); audio/video cards →
  **"Play"** (an in-app player sheet). **Nothing ever autoplays** — playback starts only
  from your tap, which is your consent.
- **Topics:** only items whose title or summary mentions a topic appear (case- and
  diacritic-insensitive, Nepali script safe); an empty topic list shows everything.
- **Honesty:** a "Some sources could not be reached: …" card names exactly which sources
  failed while everything else still loads; an empty feed with clean sources is a normal
  state with guidance, not an error; stale content (when every source failed but older
  items are cached) is shown only *labelled* with the failure. The feed re-fetches at most
  every 15 minutes.
- **Settings → Feeds** manages sources (add by URL, one field), topics (keyword chips),
  and hosts the News sources editor.

**What it will never do:** rewrite or summarise an item's text (the card shows the feed's
own title/summary, sanitized), autoplay anything, or guess a date an item didn't publish.
*(Note: an automatic Translate button for feed items is under development in the code but
not yet part of the screen — items currently appear in their original language.)*

### 4g. Appliance helpers & the bundled manuals

**"Show Me" — camera help.**
- **What it does:** take a photo of an appliance, remote, or screen, and Sahayak (using its
  cloud vision service) guides you step by step with circled, annotated steps. When it is
  not completely sure, it says so — *"I'm not completely sure about this — please
  double-check yourself."*
- **By touch:** the dock tile **Show Me** (camera icon) → *Take a photo*.
- **By voice:** "how do I use the washing machine" — the assistant offers the camera flow.
- **Saved manuals:** a successful answer is saved to your **Manuals library** (searchable,
  newest first, delete-with-confirmation), which reopens with no camera and no network.
  Honest errors exist for every failure (offline, unusable photo, timeout, not configured).

**Bundled manuals — no camera, no AI, no internet.**
- **What it does:** five built-in picture guides ship with the app, in **English and
  Nepali**, each with zoomable, annotated step cards: **iPhone basics, Phone calls, Text
  messages, Messenger, YouTube**. Steps circle the exact button to press on the screen.
- **By touch:** Settings → **Manuals** → tap a manual. (Also reachable from the Show Me
  flow's library.)

**What it will never do:** pretend certainty about a photo it is unsure of (it hedges
openly), or invent a control on a photo where it can't mark the spot (it says to follow the
written steps or take a closer photo).

### 4h. Alarms & timers

**What it does.** Sahayak's alarms and countdown timers — set mostly by voice, managed on
the Settings → **Alarms & timers** screen (list, per-alarm on/off toggle, delete; live
per-second countdown with cancel; a hand-set alarm form).

- **Alarms:** daily-repeating notifications at the chosen time, up to **20**. Snooze arms a
  one-shot re-wake (default 10 minutes, 1–60 allowed) without touching the daily repeat.
  "Turn off the alarm" disables the most recently rung alarm and always says which time it
  was.
- **Timers:** in-app countdowns up to **10** live, 1 second to 24 hours, compound durations
  understood. Completion rings a notification and — while the app is open — speaks *"Timer
  finished."*
- **The honesty note (printed in Settings, in plain words):** *"Alarms ring through this
  app's own notifications — iPhone doesn't let apps set the built-in Clock's alarms."*
  Alarms therefore appear in this app's list, not the Clock app's.
- **Permissions at the point of use:** the very first alarm or timer asks for notification
  permission; if denied, nothing is stored and Sahayak says so. Everything is persisted
  encrypted and re-armed on every launch.

**What it will never do:** write into the iPhone's Clock app; ring an alarm that wasn't
stored and armed (confirmation only after both happen); silently guess which alarm to turn
off (the spoken confirmation names the time).

### 4i. Voice brains & providers — where Sahayak's "thinking" happens

**Two engines, one switch** (Settings → **Voice Engine**):

1. **Gemini (cloud)** — the default. Speech recognition and understanding run through
   Google's Gemini AI using the family's API key. Uses the internet. Needs:
   Settings → **Gemini AI** → paste the key once. The Gemini screen also holds the **daily
   cost guard** — a family-set daily call limit (default 200, adjustable 10–1000) so a
   technical mishap can never run up a bill; when the limit is reached Sahayak says so and
   keeps medicines, alarms and emergency commands working, with full answers resuming
   tomorrow. A model picker (Flash-Lite, Flash, Pro, custom) lets the family trade cost for
   capability.
2. **On-device (offline)** — speech recognition (Whisper models) and the local brain model
   run entirely on the phone. Works fully offline **once its models are downloaded**.
   Downloading is done on the hidden **AI models** screen — **long-press the word
   "Settings" at the top of the Settings screen for 1.5 seconds** to open it (deliberately
   hidden from one-tap reach: it's a family tool). There you pick the speech-recognition
   model, the assistant brain model, and watch/delete downloads with sizes shown.
3. **Cloud fallback** (on-device stack only, **off by default**): *"Ask Gemini when I
   can't answer"* — an opt-in that escalates only the questions the local brain couldn't
   answer, and only when a Gemini key exists.

**The brain's ladder** (whichever engine): every utterance is checked in a fixed order —
emergency phrases → medicine acknowledgements → yes/no answers → contact search →
directions → alarms/timers → briefing → news → YouTube → time/date/weather/greeting
pre-answers → calculator → the brain model → web search. The safety vocabulary never waits
on any model, so emergencies work even while the brain is downloading.

**Offline behaviour, honestly:**
- On-device engine + models downloaded: everything works offline (news/feeds/YouTube
  searches still need internet to fetch, and Sahayak says so when they fail).
- Gemini engine with no internet: understanding falls back to the deterministic commands;
  if *no brain exists at all*, Sahayak says *"my brain isn't set up — please ask a family
  member…"* rather than pretending it misunderstood you.

**Web search & YouTube keys** (family-facing): Settings → **Web search** holds the Google
Custom Search credentials (both fields required; up to 50 searches/day; queries go to
Google — said plainly on the screen). Settings → **YouTube** holds the optional YouTube
Data API key that upgrades "play X on youtube" from opening a search to auto-playing the
top result (free quota ≈ 100 searches/day; your words are sent to YouTube to find the
video — said plainly on the screen).

**What it will never do:** send voice to Gemini unless the family configured a key (and,
on the on-device engine, not even then — only the opt-in cloud-fallback questions);
exceed the family's daily Gemini budget; claim an answer came from the web when it came
from a stale snippet (weather questions are routed to live sources or the honest
"unavailable" line — never a web snippet).

### 4j. Privacy & honesty — what is stored, what is logged, what is never fabricated

**Stored on this phone, encrypted (Keychain, strongest iPhone protection):**
your family contacts and their photos, saved places, routine entries, medication schedule,
adherence log, doctor's appointments, morning briefing text, alarms & timers, news sources,
feed sources & topics, conversation history (last 200 exchanges), and the voice fingerprint
(if enrolled). The clipboard is read only when you tap "Paste appointment message".

**Logged — and deliberately NOT logged.** Sahayak's internal observability events are
PII-free by policy: event names, counts and outcomes only. Headline text, search queries,
medication names, transcripts, and titles **never** reach any log. Two family-facing
windows exist on purpose: Settings → **Assistant activity** (the intent log: which
commands were confirmed or corrected — clearable, exportable) and Settings → **Tool
requests** (the last 200 weather/search/YouTube requests, kept in encrypted storage —
exportable). YouTube's spoken video titles are deliberately spoken-only: never carded,
never logged.

**Permissions are asked at the point of use** with plain-language cards (contacts when you
search, calendar when you switch on the mirror, location when you ask for weather or
directions, microphone & notifications in the welcome wizard) — and every feature keeps
working in a reduced, honest mode if you say no.

**Honesty guarantees (what Sahayak will never do):**
- Never fabricate news, weather, dates, or events: news is verbatim headlines; weather is
  live data hedged with its source, or an open "can't check it yet"; dates outside the BS
  table are reported unavailable.
- Never claim a call or message happened when it didn't (messages are never auto-sent;
  WhatsApp "calls" are honestly chats; outcomes say exactly which surface opened).
- Never claim certainty it doesn't have (appliance guidance hedges; uncertain commands
  become yes/no questions).
- Never blame you when the real problem is a missing brain model or permission — it names
  the actual fix.
- **One honest caveat to know:** the Privacy screen's paragraph ("Nothing is sent to the
  cloud for AI processing") describes the on-device promise. With the default **Gemini**
  engine and a key configured, your spoken words *do* go to Google's Gemini — that's how
  that engine works, and the Gemini, Web search and YouTube settings screens say so
  plainly. Choose the **On-device** engine (with its models downloaded) if you want the
  strictly-offline guarantee.

### 4k. Full Settings tour — every section, one line each

Open Settings with the gear at the top-left of Home. In order:

| # | Section | What it does |
|---|---|---|
| 1 | **Appearance** | Pick a warm background theme — Cream (default), Sage, Sky, Lavender, Dusk. Changes every screen instantly; text and cards keep their contrast. |
| 2 | **Language & region** | English or नेपाली — the app's whole interface and Sahayak's spoken replies follow it. (Region: Nepal, ne-NP.) |
| 3 | **Calling** | The default calling app for call buttons: FaceTime / Phone / Messenger / WhatsApp (Messenger needs a per-person username). |
| 4 | **Places and maps** | Saved places (home + important places, with a default-home radio), which map app voice navigation opens (Auto / Google Maps / Apple Maps / inside this app), add/edit/delete places. |
| 5 | **Gemini AI** | Paste the Gemini API key; daily call limit with a live usage bar (10–1000, default 200); AI model picker (Flash-Lite default, Flash, Pro, custom). Status dot: Connected / Setup needed. |
| 6 | **Voice Engine** | Gemini (cloud) vs On-device (offline) — instant switch, no restart; plus the "Ask Gemini when I can't answer" fallback toggle under On-device. |
| 7 | **Voice activation** | The wake-word switch (listen for "ये कान्छी"), an honest status card (Active / Off / Setup needed / Restart to activate) with a checklist of what's missing, and the battery note. |
| 8 | **Voices** | Pick the voice for Sahayak's replies: Google voice (Nepali) + its 17 other speakers, Chitwan voice; Listen to audition each without switching; confirm before applying; English voice shown as status; a test button speaks a sample greeting. |
| 9 | **Voice personalization** | *Reduce background noise* (experimental, off by default, on-device), *Help with my accent* (on by default, on-device), and the *Voice fingerprint* (enroll with 3 short recordings, stays on-device, removable). |
| 10 | **Web search** | Google API key + search-engine ID for the on-device engine's web search; 50/day quota and the privacy note stated on the screen. |
| 11 | **YouTube** | Optional YouTube Data API key (upgrades voice "play X" to auto-play); quota and privacy notes on the screen. |
| 12 | **Feeds** | Feed sources (add-by-URL with "default" tags), topic chips, and the News sources editor. |
| 13 | **Quick apps** | Pick up to 8 favourite apps for the Home quick-access row; installed apps are detected honestly (apps that aren't on the phone are labelled). |
| 14 | **Family and friends** | The curated contact list (up to 12) with the 5-step add/edit wizard: search → relationship (+ emergency flag) → photo → Messenger username → nickname + home address. |
| 15 | **Medication schedule** | Medicine names and times (duplicates refused), plus festival advance-reminder days (0–7, default 2). |
| 16 | **Manuals** | The five bundled camera-free manuals (iPhone, Phone, Messages, Messenger, YouTube) in English + Nepali with zoomable annotated steps. |
| 17 | **Calendar** | The three bridge switches: Show in Calendar app (mirror out), Mirror routine changes both ways (Sahayak calendar, off by default), Import from Calendar & Reminders (with notify-minutes-before stepper 0–30). |
| 18 | **Alarms & timers** | Every voice-set alarm (toggle/delete) and live countdown timer (cancel), a hand-set alarm form, and the honesty note about the Clock app. |
| 19 | **Privacy** | The privacy statement and the app version number. |
| 20 | **Assistant activity** | The intent log — confirmed/corrected commands; clear or export. |
| 21 | **Tool requests** | The last 200 weather/search/YouTube requests with outcomes; export. (Encrypted on-device.) |
| — | **AI models** *(hidden)* | Long-press the word "Settings" at the top for 1.5 s: speech-recognition model picker, assistant brain model picker, and the downloads list with sizes, cancel and delete. |

---

## 5. Troubleshooting

| Symptom | What to do |
|---|---|
| **"Sorry, I didn't understand"** often | Speak a little slower and clearer, closer to the phone. Uneven spacing between words is fine — the app already handles it. If it keeps happening, tap the Talk button instead of the wake phrase. If Sahayak says its *brain model is downloading / not set up*, that's the real cause — see the next row. |
| **"My brain isn't set up" / "brain model is still downloading"** | A family member should open Settings → **Voice Engine**: either paste a Gemini key (Settings → **Gemini AI**) or pick On-device and long-press the "Settings" title to open **AI models** and download the brain model (one-time, can be large — the screen shows sizes). |
| **Voice is stuck listening / misbehaving** | Tap the Talk button once (cancels the turn), or **press and hold it for 2 seconds** — the white ring fills and Sahayak says "Voice reset. I'm ready." A red button with "Try again" means the pipeline failed: read the line under the button — it names the actual problem (mic off, no audio). |
| **Microphone permission was denied** | The button shows "Microphone access is turned off" with an **Open Settings** button — tap it, allow the microphone in iOS Settings, come back. (Welcome wizard: step 2.) |
| **Nothing speaks / Nepali replies are silent** | Settings → **Voices**: the voice list shows Installed / Ready (installs on first use) / Missing. Tap a voice's **Listen** to audition, then **Use this voice** (confirm). A red "Missing" line means the voice files aren't in this build — a family member must rebuild the app with them; until then replies are always written on screen. |
| **Calendar events don't appear** | Settings → **Calendar** → turn on **Import from Calendar & Reminders**, and grant Calendar/Reminders access when asked (the status line says Denied / Partial / On). Also check Reminders → *Upcoming events* (only shows while the import is on). |
| **Alarms/timers don't ring** | Notifications must be allowed (welcome wizard step 2, or iOS Settings → the app → Notifications). Remember the honest rule: these alarms ring through the app's notifications, not the iPhone Clock app — they're listed in Settings → **Alarms & timers**. The very first alarm/timer asks permission; if it was refused, setting another one tells you. |
| **Wake phrase doesn't wake Sahayak** | Settings → **Voice activation**: check the status card. "Listening is on" + Active means it should work — say "ये कान्छी" (yeah kanchhi) clearly, pause briefly, then the command. "Restart to activate" means fully close and reopen the app once. "Setup needed" lists exactly what a family member must fix. The Talk button always works regardless. |
| **Contacts search shows nobody / asks again** | Contacts permission was denied: the search card shows "Open Settings" — allow it, return. Family tiles and manual entry keep working without it. WhatsApp people missing? WhatsApp → Settings → Privacy → Sync contacts. |
| **A voice call didn't happen** | Sahayak only dials after your "yes" (or your tap). If it said *"I couldn't find X in your family contacts"*, add the person in Settings → Family and friends. If it said *"calling and messaging stay off…"*, no brain is available — set up Gemini or the on-device brain. |
| **Directions say "no home"** | Settings → **Places and maps** → add a place, mark one **Default home**; or add a home address to a family contact. "I couldn't find a place by that name" means the spoken name matched nothing saved. |
| **Gemini daily limit reached** | Sahayak says so and continues with basic commands (medicines, alarms, emergency all keep working). Full answers resume tomorrow, or a family member raises the limit in Settings → **Gemini AI** → Daily usage limit. |
| **The app seems to have "forgotten" everything** | Nothing is ever stored unencrypted; if the app was deleted and reinstalled, encrypted data is restored only from an iCloud backup that included it. Re-enter medicines/contacts via Settings if they're missing. |

---

## 6. Glossary

| Term | Plain meaning |
|---|---|
| **Sahayak (सहायक)** | The assistant's name — Nepali for "helper". The app itself is titled **VoiceBridge AI**. |
| **Wake word / wake phrase** | The phrase that wakes Sahayak without any button: **"ये कान्छी"** ("yeah kanchhi"). |
| **STT (speech-to-text)** | Turning your spoken words into written text — Sahayak's "ears". Runs with Whisper models on the phone, or Gemini in the cloud. |
| **TTS (text-to-speech)** | Turning written replies into spoken words — Sahayak's "voice". Uses on-device Piper voices; falls back to the iPhone's own voice. |
| **Local brain / on-device model** | The thinking model that runs inside the phone, with no internet. |
| **Cloud fallback** | An opt-in that sends only the questions the local brain couldn't answer to Gemini. |
| **Gemini** | Google's cloud AI, used for understanding and open questions when the family adds an API key. |
| **BS calendar (Bikram Sambat)** | The Nepali calendar (currently in the 2080s), shown with tithi and festivals, converted offline. |
| **Tithi** | The lunar day of the Nepali calendar, shown every day. |
| **RSS / Atom / feed** | Standard ways websites publish updates; the News reader and the Feeds screen read these. |
| **Enclosure** | The attached file in a feed item — the picture, audio or video that decides an item's kind. |
| **Sahayak calendar** | The dedicated calendar inside the iPhone Calendar app that holds your mirrored routine when two-way sync is on. |
| **Lane / speak queue** | Sahayak's internal queuing of speech by importance: emergency and safety lines always jump ahead; ordinary notifications never interrupt what's being said. |
| **VAD (voice activity detection)** | The mechanism that notices when you have finished speaking (~1 second of quiet). |
| **Confirmation challenge** | The yes/no question Sahayak asks before recording a medicine dose or dialing a call. |
| **Intent log / Tool log** | The family-facing windows in Settings showing what commands were understood and what weather/search/YouTube requests were made — exportable, PII-free elsewhere. |
| **API key** | A family-managed credential that connects Sahayak to Gemini, web search, or YouTube. |
| **App language** | The language setting (English/Nepali) that drives the whole interface and spoken replies. |

---

*This manual describes the app as it is built. Every command phrase, colour, permission
flow and honesty line above was verified against the app's source code. Where the app
itself is still honest about a limitation (the Clock app, SMS reading, the appointment
calendar writer, the missing voice files), this manual repeats that limitation rather than
rounding it away.*
