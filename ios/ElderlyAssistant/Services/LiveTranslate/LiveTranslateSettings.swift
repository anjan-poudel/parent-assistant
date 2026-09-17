import Foundation

/// The genuinely user-facing settings this feature owns (C14). Today that is
/// exactly one preference — `alwaysShowOriginal`, the FR-LCT-017 toggle —
/// plus the disclosure version stamp the consent record carries.
///
/// Reachability and consistency:
///  - the toggle is reachable by touch (the overlay chrome, T-022) and by
///    voice (the `set-show-original` command, T-023). **Both paths write
///    through this type**, which is what makes it impossible for the two to
///    disagree: there is one setter and one storage key.
///  - it takes effect on the next rendered frame; nothing here is cached in
///    the overlay, so no restart or session change is involved.
///
/// Persistence: `UserDefaults`, following the shipped `AppLanguage.persisted()`
/// precedent. This is a UI preference containing no user content, so it does
/// not belong on the encrypted file channel — and a test asserts that the
/// only feature key in the store is this boolean.
///
/// The toggle changes the overlay's form and nothing else: it cannot affect
/// translation, consent, cost, capture or the cloud indicator (T-022), and it
/// is never presented as controlling what leaves the device.
struct LiveTranslateSettings: Equatable {

    /// The prefix reserved for this feature in `UserDefaults`. The test that
    /// proves the store carries no user content walks every key under it.
    static let featureKeyPrefix = "livetranslate."

    /// The single feature key. Declared once so no call site spells it.
    static let alwaysShowOriginalKey = "livetranslate.alwaysShowOriginal"

    /// Every key this feature is allowed to write to `UserDefaults`. The
    /// persisted state is a boolean preference and nothing else.
    static let featureKeys: Set<String> = [alwaysShowOriginalKey]

    private let defaults: UserDefaults

    /// The operational config, held here so the nominal default for the
    /// preference comes from one place (`alwaysShowOriginalDefault`) rather
    /// than a second literal.
    let config: LiveTranslateConfig

    init(defaults: UserDefaults = .standard,
         config: LiveTranslateConfig = .default) {
        self.defaults = defaults
        self.config = config
    }

    /// Whether original recognized text stays visible alongside translations.
    /// An absent key means the elder has never chosen, which is the design's
    /// nominal default (false — smart mix on, OD2), not `false` by accident.
    var alwaysShowOriginal: Bool {
        get {
            guard defaults.object(forKey: Self.alwaysShowOriginalKey) != nil else {
                return config.alwaysShowOriginalDefault
            }
            return defaults.bool(forKey: Self.alwaysShowOriginalKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.alwaysShowOriginalKey)
        }
    }

    /// The touch control's write path (T-022).
    func setAlwaysShowOriginal(_ value: Bool) {
        alwaysShowOriginal = value
    }

    /// The voice command's write path (T-023, `set-show-original`). Same
    /// setter as the touch control, by construction.
    func toggleAlwaysShowOriginal() {
        alwaysShowOriginal = !alwaysShowOriginal
    }

    /// The version stamp a consent record is bound to (C09/C14). Exposed
    /// here so the gate and the consent prompt read the same value the
    /// record is stamped with.
    var disclosureVersion: String { config.disclosureVersion }
}
