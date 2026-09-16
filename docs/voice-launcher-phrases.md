# Voice Launcher Phrase Inventory (English + Nepali)

This is the evaluation input for the follow-up encoder work on the voice app
launcher (`[APP-LAUNCHER]`, 2026-09-16). It lists every utterance shape the
launcher currently recognizes, in the two layers that recognize it: the
**deterministic keyword fast path** (`KeywordIntentRule`, `.appLaunch` domain —
eleven apps, an app word ∧ an open verb, no model round-trip) and the
**model/plugin path** (`launcher.open` + `AppLauncher.app(matchingSpoken:)` —
the full 28-entry catalog, resolved by exact full-lexeme match against a
catalog id, an entry's spoken `aliases`, or the entry's localized display name
in Nepali or English). A later encoder is expected to generalize beyond the
keyword layer, so the lists below double as the "known good" set — every
phrase here must keep working, and a phrase marked *not recognized* is a
deliberate negative, not an oversight. Matching is whole-lexeme everywhere
(Devanagari Character-cluster substring matching is a pinned regression, see
`swift-devanagari-substring-graphemes`), so the exact forms matter.

The two layers read ONE vocabulary: every word the keyword rules match is a
catalog alias, and every catalog alias is offered to the model (see §4). A
spelling that exists in only one layer is a defect by construction — it makes
the same sentence work on one stack and fail on the other.

Sources of truth: `ios/ElderlyAssistant/Services/Apps/AppLauncher.swift`
(catalog, aliases), `ios/ElderlyAssistant/Services/Voice/KeywordIntentRule.swift`
(word groups, verb families),
`ios/ElderlyAssistant/Services/Plugins/AppLauncherPlugin.swift` (prompt
vocabulary), `ios/ElderlyAssistant/Resources/Localizable.xcstrings`
(display names). Whatever the tables say, those files win.

## 1. Keyword fast path — app words

Each rule fires only when an app word from the table co-occurs with a verb from
§2 (open) anywhere in the utterance. Text is lowercased and interior whitespace
is collapsed first; tokens are split on whitespace and punctuation, so
trailing commas/danda do not break a match.

| App (`id`) | English app words | Nepali app words (Devanagari) | Romanized Nepali | Example utterances (pinned in tests) |
|---|---|---|---|---|
| `camera` | `camera` | क्यामेरा | — | "क्यामेरा खोल", "हजुर, क्यामेरा खोल्नुहोस् न", "camera khol", "open the camera please" |
| `photos` | `photos`, `photo` | फोटो | — | "फोटो खोल", "फोटो खोल्नुहोस्", "photos khol", "open my photos" |
| `settings` | `settings` | सेटिङ | — | "सेटिङ खोल", "settings kholnu hos", "open settings" |
| `weather` | `weather` | मौसम | `mausam` | "मौसम खोल", "weather khol", "mausam kholnus", "open the weather app" |
| `whatsapp` | `whatsapp` | ह्वाट्सएप, व्हाट्सएप, वाट्सएप | — | "ह्वाट्सएप खोल", "whatsapp kholnu hos", "open whatsapp", "व्हाट्सएप खोल्नुहोस्" |
| `youtube` | `youtube` | युट्युब | — | "युट्युब खोल", "open youtube" |
| `facebook` | `facebook` | फेसबुक | — | "फेसबुक खोल", "facebook khol", "open facebook" |
| `magnifier` | `magnifier` | म्याग्निफायर | — | "म्याग्निफायर खोल", "magnifier khol", "open the magnifier" |
| `health` | `health` | स्वास्थ्य | — | "स्वास्थ्य खोल", "health खोल", "open my health app" |
| `instagram` | `instagram` | इन्स्टाग्राम | — | "इन्स्टाग्राम खोल", "instagram खोल", "open instagram please" |
| `calendar` | `calendar` | पात्रो | — | "पात्रो खोल", "calendar खोल", "open the calendar" |

All of these words — the three Devanagari WhatsApp spellings, the romanized
`mausam`, `पात्रो` — are **catalog aliases** (Whisper produces all three
WhatsApp spellings), so the model path resolves exactly the vocabulary the
keyword rules match. `camera` additionally accepts a
**capture** phrasing — a photo word (the `photos` app words: `photos`,
`photo`, फोटो) plus a verb from §3 — which resolves to `camera`, never to the
Photos app:

| Resolves to | Phrase shape | Example utterances (pinned in tests) |
|---|---|---|
| `camera` | photo word ∧ capture verb | "फोटो खिच्न", "फोटो खिच", "फोटो खिच्नुहोस्", "photo khicna", "take a photo", "a photo खिच्नुस्" |

## 2. Keyword fast path — open verbs (required, all eleven rules)

One of these must co-occur with the app word. Whole-token equality only; the
Nepali forms are enumerated in full because the virama fuses the stem
(खोल्नुहोस् does not token-equal खोल).

| Language | Forms |
|---|---|
| English | `open`, `opens`, `opening`, `launch`, `launches`, `launching`, `start`, `starts`, `starting` |
| Romanized Nepali | `khol`, `khola`, `kholnu`, `kholnus`, `kholnuhos`, `kholidinu`, `kholidinus` |
| Devanagari | खोल, खोल्नु, खोल्नुहोस्, खोल्नुस्, खोल्न, खोल्ने, खोलिदिनुहोस्, खोलिदिनुस्, खोलिदिनु, खोलिदेऊ, खोलिदेऊँ, खोलिदेउ, खोल्दिनुहोस्, खोल्दिनुस्, खोल्दिनु |

## 3. Keyword fast path — capture verbs (camera only)

| Language | Forms |
|---|---|
| English | `take`, `snap`, `capture` |
| Romanized Nepali | `khic`, `khich`, `khicna`, `khichna`, `khicnu`, `khichnu` |
| Devanagari | खिच, खिच्न, खिच्नु, खिच्नुहोस्, खिच्नुस्, खिच्ने |

## 4. Full catalog vocabulary (model / plugin path)

Every entry is reachable by its catalog id, by any of its spoken aliases, or by
its display name in the active locale or English, through
`AppLauncher.app(matchingSpoken:)`. The `launcher.open` prompt hands the model
**every** id and alias as its own quoted token — no `id (a, b)` display forms
and no truncation, so a token copied out of the prompt always resolves.

| `id` | English name | Nepali name | Spoken aliases | Keyword fast path? |
|---|---|---|---|---|
| `phone` | Phone | फोन | — | no (existing call action) |
| `messages` | Messages | सन्देश | — | no (existing message action) |
| `facetime` | FaceTime | फेसटाइम | — | no — **cloud path only** |
| `mail` | Mail | मेल | — | no — **cloud path only** |
| `calendar` | Calendar | पात्रो | `calendar`, पात्रो | **yes** |
| `maps` | Maps | नक्सा | — | no (existing directions action) |
| `camera` | Camera | क्यामेरा | `camera`, क्यामेरा | **yes** (+ capture variant) |
| `photos` | Photos | फोटो | `photos`, `photo`, फोटो | **yes** |
| `settings` | Settings | सेटिङ | `settings`, सेटिङ | **yes** |
| `settingswifi` | Wi-Fi Settings | वाइफाइ सेटिङ | `wifi`, `wi-fi`, वाइफाइ | no — **cloud path only** |
| `settingsbluetooth` | Bluetooth Settings | ब्लुटुथ सेटिङ | `bluetooth`, ब्लुटुथ | no — **cloud path only** |
| `settingsdisplay` | Display Settings | डिस्प्ले सेटिङ | `display`, `brightness`, डिस्प्ले | no — **cloud path only** |
| `settingsaccessibility` | Accessibility Settings | पहुँचयोग्यता सेटिङ | `accessibility`, पहुँचयोग्यता | no — **cloud path only** |
| `weather` | Weather | मौसम | `weather`, मौसम, `mausam` | **yes** |
| `magnifier` | Magnifier | म्याग्निफायर | `magnifier`, म्याग्निफायर | **yes** |
| `health` | Health | स्वास्थ्य | `health`, स्वास्थ्य | **yes** |
| `whatsapp` | WhatsApp | ह्वाट्सएप | `whatsapp`, ह्वाट्सएप, व्हाट्सएप, वाट्सएप | **yes** |
| `messenger` | Messenger | मेसेन्जर | — | no — **cloud path only** |
| `facebook` | Facebook | फेसबुक | `facebook`, फेसबुक | **yes** |
| `instagram` | Instagram | इन्स्टाग्राम | `instagram`, इन्स्टाग्राम | **yes** |
| `youtube` | YouTube | युट्युब | `youtube`, युट्युब | **yes** (open only) |
| `gmail` | Gmail | जीमेल | — | no — **cloud path only** |
| `googlemaps` | Google Maps | गुगल नक्सा | — | no — **cloud path only** |
| `chrome` | Chrome | क्रोम | — | no — **cloud path only** |
| `zoom` | Zoom | जुम | — | no — **cloud path only** |
| `telegram` | Telegram | टेलिग्राम | — | no — **cloud path only** |
| `viber` | Viber | भाइबर | — | no — **cloud path only** |
| `imo` | Imo | इमो | — | no — **cloud path only** |

The eleven entries with a tick are launchable on **both** stacks. The entries
marked **cloud path only** have no deterministic rule, so on the on-device
stack — whose grammar cannot emit the plugin action at all — asking for one of
them by name (gmail, zoom, telegram, viber, imo, messenger, facetime, mail,
chrome, googlemaps, and the four Settings panes) reaches neither path today and
is answered with the interpreter's honest "I can't do that" rather than a
launch; the same sentence works in a cloud session, where the `launcher.open`
plugin resolves it. `phone`, `messages` and `maps` are listed separately
because their own strict actions already own those words.

Two shape caveats for the evaluation:

- `wi-fi` and `brightness`/`photo` are devanagari-free single-token Latin
  words, but `wi-fi` **cannot** match the keyword layer's tokenizer even if a
  rule were added — the tokenizer splits on punctuation, so `wi-fi` becomes
  `wi` + `fi`. The alias works only through the exact-string resolver.
- A bare app word is never a launch request. `मौसम` alone stays the weather
  *question* owned by the topic table, and `युट्युब` alone stays a mention.

### Launchability on a device without a cloud session

The launcher's `.camera` entry needs no URL probe (the picker is in-process),
and the Settings entries fall back to the public
`UIApplication.openSettingsURLString` when their private `App-Prefs` pane does
not answer: the question disclosed that swap is `launcher.confirmOpenSettings`,
the announcement is `apps.announce.openingSettings`. An entry whose own scheme
does not answer and which has neither a web fallback nor a Settings fallback is
spoken as "not installed" — nothing is opened, and nothing is claimed.

## 5. Negative set — these must NOT launch

Held as regression pins; an encoder that starts firing on these is a
regression, not an improvement.

| Utterance | Why | Correct handling |
|---|---|---|
| "क्यामेरा", "फोटो", "सेटिङ", "मौसम", "ह्वाट्सएप", "युट्युब", "फेसबुक", "म्याग्निफायर", "स्वास्थ्य", "इन्स्टाग्राम", "पात्रो", "camera", "photos", "weather", "mausam", "youtube", "facebook", "settings", "magnifier", "health", "instagram", "calendar" | bare app word, no open/capture verb | interpreter / topic table, never a launch |
| "आजको मौसम कस्तो छ?", "is it raining today" | weather *question* | topic pre-answer |
| "क्यामेरामा खोल", "फोटोहरू खोल", "photoshop खोल", "youtubers khol" | fused/longer word, not the bare lexeme | no launch (Character-cluster pin) |
| "युट्युब खोल र गीत चलाऊ" | app word *and* a video request | YouTube **play** (launcher rules run last) |
| "समाचार खोल, समाचार सुनाऊ" | app word *and* a news verb | news digest |
| "मद्दत गर्नुहोस्", "help me", "i fell", "मैले औषधि खाएँ", "i took my medication", "बिहान ६ बजे उठाउनुहोस्", "पाँच मिनेटको टाइमर लगाऊ", "अलार्म बन्द गर", "टाइमर रोक", "छोरालाई फोन गर", "call my daughter" | emergency / medication / alarm / timer / call vocabulary | their own strict stages, which run first |

## 6. Spoken confirmation lines (for reference)

Every launch is confirm-first (design D3) and the elder answers yes/no.

| Key | English | Nepali |
|---|---|---|
| `launcher.confirmOpen` | Should I open %@? | %@ खोल्ने हो? |
| `launcher.confirmOpenWeb` | %@ is not installed. Should I open it on the web instead? | %@ स्थापित छैन। सट्टामा वेबमा खोल्ने हो? |
| `launcher.confirmOpenSettings` | I can't open that exact screen. Should I open Settings instead? | त्यो ठ्याक्कै स्क्रिन खोल्न सक्दिनँ। सट्टामा सेटिङ खोल्ने हो? |
| `launcher.cancelled` | Okay, I won't open it. | हुन्छ, खोल्दिनँ। |
| `launcher.timeout` | Time is up. I won't open it. | समय सकियो, खोल्दिनँ। |
| `launcher.unknownApp` | I don't know an app called %@. | %@ भन्ने एप मलाई थाहा छैन। |
| `launcher.noApp` | Which app should I open? | कुन एप खोलूँ? |

The outcome lines the launch executor speaks once the elder has answered
(`apps.announce.opened`, `apps.announce.openingWeb`,
`apps.announce.notInstalled`, `apps.announce.openingSettings`) live under their
own keys in `Localizable.xcstrings`; the Settings fallback adds
`apps.announce.openingSettings` (English: "I can't open that screen. Opening
Settings.").
