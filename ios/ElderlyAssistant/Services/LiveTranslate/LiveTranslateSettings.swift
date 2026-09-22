import Foundation

/// The genuinely user-facing settings this feature owns (C14). Today that is
/// three preferences — `alwaysShowOriginal`, the FR-LCT-017 toggle,
/// `geminiCloudEnabled`, the cloud tier's master switch (owner directive,
/// 2026-09-19), and `liveTranslateEnabled`, the feature's own master switch
/// (owner directive, 2026-09-21) — plus the disclosure version stamp the
/// consent record carries,
/// and one developer-facing switch that is not a user preference at all:
/// `translationDebugLoggingEnabled`, the [DEBUG-LOG] console diagnostic, which
/// is off by default and has no reader outside a Debug build.
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

    /// The [DEBUG-LOG] diagnostic switch's key (review finding on #99,
    /// 2026-09-20). Declared once so no call site spells it.
    static let translationDebugLoggingEnabledKey =
        "livetranslate.translationDebugLoggingEnabled"

    /// The feature's master switch (owner directive, 2026-09-21). Declared once
    /// so no call site spells it.
    static let liveTranslateEnabledKey = "livetranslate.enabled"

    /// [DEBUG-LOG] The **production writer** for the diagnostic switch: a
    /// launch argument, so a run can turn the content-free console line on
    /// without a rebuild — the reason the owner asked for the logging at all —
    /// and without a Settings row an elder could find and flip.
    ///
    /// A launch argument rather than a row, deliberately: this switch changes
    /// nothing about what leaves the device, what is stored or what the elder
    /// sees, so it is a developer's diagnostic and belongs in the scheme that
    /// starts the run, not in a household's settings. It is read only when
    /// nobody has persisted a value (see `translationDebugLoggingEnabled`), so
    /// a stored choice still wins over the argument.
    static let translationDebugLoggingLaunchArgument = "-liveTranslateDebugLogging"

    /// Every key this feature is allowed to write to `UserDefaults`. The
    /// persisted state is four booleans — the display preference, the two
    /// master switches and the DEBUG-ONLY diagnostic switch — and nothing else.
    static let featureKeys: Set<String> = [alwaysShowOriginalKey,
                                           geminiCloudEnabledKey,
                                           translationDebugLoggingEnabledKey,
                                           liveTranslateEnabledKey]

    private let defaults: UserDefaults

    /// The launch arguments the deciding switches are read from. Injected
    /// rather than read from `ProcessInfo` at each use site for the same
    /// reason the store and the clock are: a test can then prove the
    /// production writer works without starting a second process.
    private let launchArguments: [String]

    /// The operational config, held here so the nominal default for the
    /// preference comes from one place (`alwaysShowOriginalDefault`) rather
    /// than a second literal.
    let config: LiveTranslateConfig

    init(defaults: UserDefaults = .standard,
         config: LiveTranslateConfig = .default,
         launchArguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.config = config
        self.launchArguments = launchArguments
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

    // MARK: The feature's master switch (owner directive, 2026-09-21)

    /// Whether live camera translation may run at all.
    ///
    /// An absent key is the config's nominal default, and that default is
    /// **on** (see `LiveTranslateConfig.liveTranslateEnabledDefault` — a closed
    /// door with no copy to explain it was the merge hazard the default
    /// avoided). The Settings leaf now *does* offer the choice (Workstream B:
    /// `livetranslate.settings.enabled.title`, drawn first on the consent leaf
    /// because the refusal it drives promises the elder that the settings are
    /// open), so the reason the default was on no longer holds — but the
    /// shipped default is a product decision and is left as it is; a stored
    /// value, either way, is the household's answer and this getter returns it.
    /// The read is *not* cached: the session model re-reads it when a session
    /// opens and on every write, so the Settings leaf and a running session
    /// cannot disagree about it for longer than the write takes to land.
    ///
    /// It is a *policy*, not consent and not egress: the consent record is still
    /// required and still enforced per cloud attempt (AM-1), and this switch
    /// neither creates nor withdraws one.
    var liveTranslateEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.liveTranslateEnabledKey) != nil else {
                return config.liveTranslateEnabledDefault
            }
            return defaults.bool(forKey: Self.liveTranslateEnabledKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.liveTranslateEnabledKey)
        }
    }

    /// The switch's single write path — the Settings leaf's row and the session
    /// model's own setter behind it. One setter, one key.
    func setLiveTranslateEnabled(_ value: Bool) {
        liveTranslateEnabled = value
    }

    // MARK: The [DEBUG-LOG] diagnostic switch (review finding on #99)

    /// Whether the feature's tiers emit their debug lane — the pairs, their
    /// order and their timing, with the strings redacted by `LogSanitiser`
    /// (see `LiveTranslateDebugLane`). **Nothing in a Release build acts on
    /// it**: the readers, and the lane type itself, live under `#if DEBUG`
    /// (see `LiveTranslateConfig.translationDebugLoggingEnabled`, whose
    /// nominal default the owner's 2026-09-20 directive turned on).
    ///
    /// Persisted rather than a source edit for the reason the owner asked for
    /// the logging at all — a device capture cannot wait for a rebuild — and
    /// the value is boilerplate-free for the same reason the other two are:
    /// one key, one getter, one setter, and an absent key reads as the
    /// config's nominal default rather than as a value nobody chose.
    ///
    /// This is a *diagnostic* preference, not a third display preference: it
    /// changes what the developer's console shows and **nothing about what
    /// leaves the device, what is stored, or what the elder sees**.
    ///
    /// The value someone actually *chose*, or `nil` when nobody has — the
    /// distinction that lets `applyingDebugLogging(to:)` tell "off" from
    /// "unset". A persisted write is a choice; so is this run's launch
    /// argument; the config's nominal default is not.
    var chosenDebugLogging: Bool? {
        if defaults.object(forKey: Self.translationDebugLoggingEnabledKey) != nil {
            return defaults.bool(forKey: Self.translationDebugLoggingEnabledKey)
        }
        // The launch argument can only turn it *on* — there is no `-no-…`
        // form, so an explicit choice is always the stored one and this
        // branch is reached only when nothing is stored.
        if launchArguments.contains(Self.translationDebugLoggingLaunchArgument) {
            return true
        }
        return nil
    }

    var translationDebugLoggingEnabled: Bool {
        get { chosenDebugLogging ?? config.translationDebugLoggingEnabled }
        nonmutating set {
            defaults.set(newValue, forKey: Self.translationDebugLoggingEnabledKey)
        }
    }

    /// The switch's write path — one setter, one key.
    func setTranslationDebugLoggingEnabled(_ value: Bool) {
        translationDebugLoggingEnabled = value
    }

    /// The config a session runs with, with the chosen diagnostic switch
    /// applied. One call site (the session model), so the tiers and the
    /// pipeline cannot disagree about whether the diagnostic is on.
    ///
    /// **It overrides only what someone chose.** When nobody has — no stored
    /// value and no launch argument — the caller's config is returned
    /// untouched, which is what keeps a caller who asked for the logging (a
    /// debug build's config, a test's) from being silently switched off by
    /// this function's own default. "Nobody chose" is not "off".
    func applyingDebugLogging(to config: LiveTranslateConfig) -> LiveTranslateConfig {
        guard let chosen = chosenDebugLogging else { return config }
        var resolved = config
        resolved.translationDebugLoggingEnabled = chosen
        return resolved
    }

    /// The version stamp a consent record is bound to (C09/C14). Exposed
    /// here so the gate and the consent prompt read the same value the
    /// record is stamped with.
    var disclosureVersion: String { config.disclosureVersion }
}
