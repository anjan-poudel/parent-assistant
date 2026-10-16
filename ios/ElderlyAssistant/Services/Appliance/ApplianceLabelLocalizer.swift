import Foundation

/// Best-effort Nepali augmentation of the English button labels Gemini
/// extracts from a photo (e.g. a button that reads "Start" is shown as
/// "सुरु गर्ने"). Rules, deliberately conservative:
///
///  - EXACT whole-label match only (trimmed, case-folded) against a small
///    curated dictionary of common appliance/remote-control labels. No
///    fuzzy or substring matching — an unknown label keeps its English
///    text untouched rather than risking a wrong translation.
///  - Gated on the ACTIVE locale (the app's selected language —
///    `AppLanguage`, e.g. `ne-NP` vs `en-US`, injected as
///    `.environment(\.locale)`): only a Nepali-active session augments;
///    an English UI shows the photo's English label verbatim.
///  - Labels already written in Devanagari (Gemini is prompted to reply
///    in the active language and may already have translated the label)
///    are passed through as-is, never re-translated.
enum ApplianceLabelLocalizer {

    /// What the view renders under a step's close-up image.
    struct Display: Equatable {
        /// The button's name in the active locale (Nepali when known).
        let primary: String
        /// The original English text, kept as secondary reference only
        /// when a Nepali translation was applied.
        let secondary: String?
    }

    /// EN → NE for control-panel labels (microwaves, washing machines,
    /// remotes, ACs — the design's categories), for general printed-label
    /// vocabulary, and since [TIER-0-CONVERSATION] for the conversational
    /// phrases an elder meets every day (greetings, courtesies, the everyday
    /// asks — see the section at the end of the table). Every value is a
    /// deliberate, dictionary-sound choice; entries are best-effort by design
    /// (the localization is explicitly secondary to the visuals).
    ///
    /// One table serves both readers of this tier — the appliance helper's
    /// label augmentation and `LabelTranslationCache`'s layer A — so a string
    /// curated here is answered by lookup on either path, before any model is
    /// asked and with no prior history on the device.
    ///
    /// The set is **additive only** (NFR-LCT-012): the entries that shipped
    /// before the live-translation extension keep their exact keys and
    /// values, pinned by a test that fails if any of them changes. The table
    /// is deliberately **not reversible** — several English keys map onto one
    /// Nepali value — so no reverse lookup may be built from it.
    static let dictionary: [String: String] = [
        "auto": "अटो",
        "back": "फिर्ता",
        "cancel": "रद्द गर्ने",
        "channel": "च्यानल",
        "clear": "मेट्ने",
        "clock": "घडी",
        "close": "बन्द गर्ने",
        "cold": "चिसो",
        "cook": "पकाउने",
        "cool": "चिसो",
        "defrost": "पगाल्ने",
        "dry": "सुकाउने",
        "fan": "पंखा",
        "grill": "ग्रिल",
        "heat": "तताउने",
        "high": "उच्च",
        "home": "होम",
        "hot": "तातो",
        "input": "स्रोत",
        "light": "बत्ती",
        "lock": "लक",
        "low": "कम",
        "menu": "मेनु",
        "mode": "मोड",
        "mute": "म्युट",
        "off": "अफ",
        "ok": "ठीक छ",
        "on": "अन",
        "open": "खोल्ने",
        "pause": "पज",
        "play": "प्ले",
        "power": "पावर",
        "reheat": "फेरि तताउने",
        "reset": "रिसेट",
        "rinse": "कुल्ला गर्ने",
        "select": "छान्ने",
        "settings": "सेटिङ",
        "source": "स्रोत",
        "speed": "गति",
        "spin": "स्पिन",
        "start": "सुरु गर्ने",
        "stop": "रोक्ने",
        "temperature": "तापक्रम",
        "time": "समय",
        "timer": "टाइमर",
        "volume": "आवाज",
        "wash": "धुने",

        // MARK: Remotes, TVs and set-top boxes

        "audio": "अडियो",
        "brightness": "चमक",
        "display": "डिस्प्ले",
        "down": "तल",
        "enter": "प्रवेश गर्ने",
        "exit": "बाहिर निस्कने",
        "favorite": "मनपर्ने",
        "guide": "गाइड",
        "hdmi": "एचडीएमआई",
        "info": "जानकारी",
        "left": "बायाँ",
        "movie": "चलचित्र",
        "next": "अर्को",
        "picture": "तस्बिर",
        "previous": "अघिल्लो",
        "record": "रेकर्ड",
        "return": "फिर्ता",
        "rewind": "पछाडि घुमाउने",
        "right": "दायाँ",
        "screen": "स्क्रिन",
        "search": "खोज्ने",
        "sleep": "निद्रा",
        "tv": "टिभी",
        "usb": "यूएसबी",
        "zoom": "जुम",

        // MARK: Cooking — microwave, oven, rice cooker

        "bake": "बेक गर्ने",
        "beverage": "पेय",
        "convection": "कन्भेक्सन",
        "keep warm": "न्यानो राख्ने",
        "melt": "पगाल्ने",
        "pizza": "पिज्जा",
        "popcorn": "पपकर्न",
        "potato": "आलु",
        "quick start": "द्रुत सुरु",
        "rice": "भात",
        "roast": "भुट्ने",
        "steam": "बाफ",
        "toast": "टोस्ट",
        "vegetable": "तरकारी",
        "warm": "न्यानो",

        // MARK: Laundry — washing machine, dishwasher

        "bleach": "ब्लिच",
        "child lock": "बाल लक",
        "clean": "सफा गर्ने",
        "cotton": "कपास",
        "delicate": "नाजुक",
        "door": "ढोका",
        "drain": "पानी निकाल्ने",
        "filter": "फिल्टर",
        "heavy": "भारी",
        "load": "लोड",
        "normal": "सामान्य",
        "soak": "भिजाउने",
        "wool": "ऊन",

        // MARK: Fridge and air conditioner

        "alarm": "अलार्म",
        "eco": "इको",
        "freezer": "फ्रिजर",
        "fridge": "फ्रिज",

        // MARK: General printed labels — packaging, manuals, warnings

        "caution": "सावधानी",
        "danger": "खतरा",
        "done": "सम्पन्न",
        "error": "त्रुटि",
        "expiry": "म्याद",
        "fragile": "नाजुक",
        "ingredients": "सामग्री",
        "note": "नोट",
        "open here": "यहाँ खोल्ने",
        "press": "थिच्ने",
        "pull": "तान्ने",
        "push": "धकेल्ने",
        "ready": "तयार",
        "sensor": "सेन्सर",
        "storage": "भण्डारण",
        "warning": "चेतावनी",

        // MARK: Conversational phrases — greetings, courtesies, everyday asks
        //
        // [TIER-0-CONVERSATION] The same table, a second vocabulary. The
        // strings an elder meets on paper, signage and screen every day —
        // "What is your name?", "Good morning", "Call my daughter" — are
        // answered here, deterministically, before any model is asked: a
        // curated hit costs no generation, no request and no consent prompt.
        //
        // Every value is **तपाईं-level** (respectful) and every imperative is
        // the polite `-नुहोस्` form, because the elder reading it is being
        // addressed by, or addressing someone as, an equal-or-elder. The
        // strings are written as single orthographic words wherever Nepali
        // fuses a case marker or a postposition (छोरीलाई, श्रीमान्लाई, कहाँ,
        // बज्यो): a space inside one of those would be a different string to
        // a Nepali reader, and the normalization below would not join it.
        //
        // **Why some phrases appear twice.** The key is the cache's own
        // normalization — trim + whitespace-collapse + case-fold, and
        // deliberately *nothing else*. Punctuation is part of the text, so
        // "What is your name?" and "What is your name" are two keys; both are
        // listed because OCR keeps a printed question mark about as often as
        // it drops it. These are two entries in one table, not a fuzzy or a
        // punctuation-stripping layer: a near miss is still a miss.
        //
        // The set is subject to the same additive rule as the rest of the
        // table (NFR-LCT-012) — nothing above this line changes.

        "what is your name?": "तपाईंको नाम के हो?",
        "what is your name": "तपाईंको नाम के हो?",
        "what is your age?": "तपाईंको उमेर कति छ?",
        "what is your age": "तपाईंको उमेर कति छ?",
        "how are you?": "तपाईंलाई कस्तो छ?",
        "how are you": "तपाईंलाई कस्तो छ?",
        "where are you?": "तपाईं कहाँ हुनुहुन्छ?",
        "where are you": "तपाईं कहाँ हुनुहुन्छ?",
        "what time is it?": "अहिले कति बज्यो?",
        "what time is it": "अहिले कति बज्यो?",
        "where is the toilet?": "शौचालय कहाँ छ?",
        "where is the toilet": "शौचालय कहाँ छ?",
        "how much is this?": "यसको मूल्य कति छ?",
        "how much is this": "यसको मूल्य कति छ?",

        "i am fine, thank you": "म ठीक छु, धन्यवाद।",
        "i am fine thank you": "म ठीक छु, धन्यवाद।",
        "i am fine": "म ठीक छु।",
        "i am hungry": "मलाई भोक लाग्यो।",
        "i am thirsty": "मलाई तिर्खा लाग्यो।",
        "i am sick": "म बिरामी छु।",
        "i need help": "मलाई सहयोग चाहिन्छ।",
        "help me": "मलाई सहयोग गर्नुहोस्।",
        "i do not understand": "मलाई बुझिएन।",
        "i want to go home": "म घर जान चाहन्छु।",

        "good morning": "शुभ प्रभात",
        "good afternoon": "शुभ दिउँसो",
        "good evening": "शुभ साँझ",
        "good night": "शुभ रात्रि",
        "namaste": "नमस्ते",
        "see you later": "फेरि भेटौंला।",
        "take care": "आफ्नो ख्याल राख्नुहोस्।",
        "happy birthday": "जन्मदिनको शुभकामना।",

        "please": "कृपया",
        "thank you": "धन्यवाद",
        "thank you very much": "धेरै धन्यवाद।",
        "sorry": "माफ गर्नुहोस्।",
        "yes": "हो",
        "no": "होइन",
        "please sit down": "कृपया बस्नुहोस्।",
        "please come here": "कृपया यहाँ आउनुहोस्।",
        "please speak slowly": "कृपया बिस्तारै बोल्नुहोस्।",
        "please say it again": "कृपया फेरि भन्नुहोस्।",

        "open the door": "ढोका खोल्नुहोस्।",
        "close the door": "ढोका बन्द गर्नुहोस्।",

        "call my daughter": "मेरी छोरीलाई फोन गर्नुहोस्।",
        "call my son": "मेरो छोरालाई फोन गर्नुहोस्।",
        "call my doctor": "मेरो डाक्टरलाई फोन गर्नुहोस्।",
        "call my husband": "मेरो श्रीमान्लाई फोन गर्नुहोस्।",
        "call my wife": "मेरी श्रीमतीलाई फोन गर्नुहोस्।",
        "call the doctor": "डाक्टरलाई फोन गर्नुहोस्।",
        "call the police": "प्रहरीलाई फोन गर्नुहोस्।",
        "call an ambulance": "एम्बुलेन्स बोलाउनुहोस्।",

        "today is sunday": "आज आइतबार हो।",
        "today is monday": "आज सोमबार हो।",
        "today is tuesday": "आज मङ्गलबार हो।",
        "today is wednesday": "आज बुधबार हो।",
        "today is thursday": "आज बिहीबार हो।",
        "today is friday": "आज शुक्रबार हो।",
        "today is saturday": "आज शनिबार हो।",
    ]

    /// Devanagari block U+0900–U+097F (includes the ०-९ digit run).
    static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// True when `locale` is a Nepali-active one ("ne", "ne-NP", …). The
    /// single gate for label augmentation AND Devanagari numerals — both
    /// follow the app's selected language, never a hardcoded default.
    static func isNepali(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "ne"
    }

    /// Resolves the display form for `label` (a button's printed text) in
    /// the app's ACTIVE `locale` (views pass `@Environment(\.locale)`,
    /// which the root sets from `AppLanguage`).
    static func display(for label: String, locale: Locale) -> Display {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Display(primary: label, secondary: nil) }
        guard isNepali(locale) else { return Display(primary: trimmed, secondary: nil) }
        guard !containsDevanagari(trimmed) else { return Display(primary: trimmed, secondary: nil) }
        if let nepali = dictionary[trimmed.lowercased()] {
            return Display(primary: nepali, secondary: trimmed)
        }
        return Display(primary: trimmed, secondary: nil)
    }
}
