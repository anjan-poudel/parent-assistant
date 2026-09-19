import Foundation

/// The genuinely user-facing settings this feature owns (C14). Today that is
/// two preferences — `alwaysShowOriginal`, the FR-LCT-017 toggle, and
/// `geminiCloudEnabled`, the cloud tier's master switch (owner directive,
/// 2026-09-19) — plus the disclosure version stamp the consent record carries.
///
/// Reachability and consistency:
///  - the display toggle is reachable by touch (the overlay chrome, T-022)
///    and by voice (the `set-show-original` command, T-023). **Both paths
///    write through this type**, which is what makes it impossible for the
///    two to disagree: there is one setter and one storage key.
///  - the display toggle takes effect on the next rendered frame; nothing
///    here is cached in the overlay, so no restart or session change is
///    involved.
///  - the cloud switch is reachable from the feature's Settings leaf only
///    (there is no voice phrase for it, deliberately: a spoken sentence is
///    too easy to say by accident to be the thing that starts paying for
///    translations). It is read by the session model when the session opens
///    and pushed into the running pipeline on every write, so the two
///    surfaces cannot disagree.
///
/// Persistence: `UserDefaults`, following the shipped `AppLanguage.persisted()`
/// precedent. These are UI preferences containing no user content, so they do
/// not belong on the encrypted file channel — and a test asserts that the
/// only feature keys in the store are these booleans.
///
/// **The two are different kinds of preference and must not be conflated.**
/// The FR-LCT-017 toggle changes the overlay's form and nothing else: it
/// cannot affect translation, consent, cost, capture or the cloud indicator
/// (T-022), and it is never presented as controlling what leaves the device.
/// The cloud switch is the opposite: it is exactly a controller of egress,
/// and it is drawn beside the consent surface rather than in the overlay's
/// display chrome for that reason. Neither of them is consent — a recorded
/// grant is still required, and still enforced per attempt (AM-1, OD-13).
struct LiveTranslateSettings: Equatable {

    /// The prefix reserved for this feature in `UserDefaults`. The test that
    /// proves the store carries no user content walks every key under it.
    static let featureKeyPrefix = "livetranslate."

    /// The FR-LCT-017 display preference's key. Declared once so no call site
    /// spells it.
    static let alwaysShowOriginalKey = "livetranslate.alwaysShowOriginal"

    /// The cloud tier's master switch (owner directive, 2026-09-19). Declared
    /// once so no call site spells it.
    static let geminiCloudEnabledKey = "livetranslate.geminiCloudEnabled"

    /// Every key this feature is allowed to write to `UserDefaults`. The
    /// persisted state is two boolean preferences and nothing else.
    static let featureKeys: Set<String> = [alwaysShowOriginalKey,
                                           geminiCloudEnabledKey]

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

    /// Whether the Gemini (cloud) translation tier may run at all (owner
    /// directive, 2026-09-19).
    ///
    /// An absent key means the household has never opted in, which is the
    /// config's nominal default (**false** — the cloud tier does not cascade
    /// unless someone turns it on), not `false` by accident. The read is
    /// *not* cached: the session model re-reads it on every session and on
    /// every write, so the Settings leaf and a running session cannot
    /// disagree about it for longer than the write takes to land.
    ///
    /// This is the feature's one setting that changes what leaves the device,
    /// which is why it is the feature's one setting whose default is checked
    /// from both sides: `LiveTranslateSettingsTests` pins the absent-key
    /// default and `LiveTranslationPipelineTests` pins that the gate is shut
    /// while it is false.
    var geminiCloudEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.geminiCloudEnabledKey) != nil else {
                return config.geminiCloudEnabledDefault
            }
            return defaults.bool(forKey: Self.geminiCloudEnabledKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.geminiCloudEnabledKey)
        }
    }

    /// The switch's write path — the Settings leaf's row, and the session
    /// model's own `setGeminiCloudEnabled` behind it. One setter, one key.
    func setGeminiCloudEnabled(_ value: Bool) {
        geminiCloudEnabled = value
    }

    /// The version stamp a consent record is bound to (C09/C14). Exposed
    /// here so the gate and the consent prompt read the same value the
    /// record is stamped with.
    var disclosureVersion: String { config.disclosureVersion }
}
