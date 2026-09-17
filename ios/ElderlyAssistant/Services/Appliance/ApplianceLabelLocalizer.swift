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
    /// remotes, ACs — the design's categories) and for general printed-label
    /// vocabulary. Every value is a deliberate, dictionary-sound choice;
    /// entries are best-effort by design (the localization is explicitly
    /// secondary to the visuals).
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
