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
    /// remotes, ACs — the design's categories). Every value is a
    /// deliberate, dictionary-sound choice; entries are best-effort by
    /// design (the localization is explicitly secondary to the visuals).
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
