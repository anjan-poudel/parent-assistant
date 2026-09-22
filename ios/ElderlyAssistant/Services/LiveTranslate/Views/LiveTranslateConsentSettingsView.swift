import SwiftUI

// T-015 — the Settings entry point for the consent control, and (owner
// directive, 2026-09-19) the cloud tier's master switch.
//
// Revocation must not depend on the camera running, and the elder must be
// able to change a decision without having a live scene in front of them, so
// the same control the session view shows is reachable here. It drives the
// SAME gate instance the session view drives (`AppCoordinator`'s one
// controller), which is what makes "a decision made in Settings takes effect
// over the session view without a restart" true by construction rather than
// by a refresh that might be forgotten.
//
// The surface is `ConsentControlView`: while a grant is in force it offers
// revocation; otherwise it offers the decision itself — the same prompt, the
// same equally weighted choices, the same catalog copy. Opening this screen
// is a deliberate act by the elder, so offering the decision here is not the
// automatic re-prompt that failure-table row 8 forbids.
//
// **The master switch sits on this leaf, and deliberately here rather than in
// the overlay's chrome.** It is the one setting this feature owns that changes
// what leaves the device: with it off the cloud tier is never even asked, so
// no prompt is presented and no request is built. Grouping it with the consent
// surface is the honest placement — both are about egress, and an elder who
// came here to change their mind about the cloud finds the two controls
// together — while the FR-LCT-017 display toggle stays in the overlay, where
// it is drawn away from anything that reads as a privacy control
// (`AlwaysShowOriginalControl`).
//
// The switch is **not** a consent control and does not stand in for one: a
// grant is still required and still enforced per attempt (AM-1, OD-13), and
// turning the switch off neither withdraws a recorded grant nor creates one
// when it is turned back on.
//
// **The feature's own master switch sits above both of them** (Workstream B,
// owner directive 2026-09-21). It is the outermost decision on the page — the
// feature does not open at all while it is off, so nothing below it matters in
// that state — and it is drawn *first* for a reason the refusal depends on:
// when the feature is asked for while it is off, the elder hears
// `livetranslate.disabled` and lands here. A promise to open "its settings" is
// only honest if the switch that refused them is the first thing they see.
//
// It writes through `LiveTranslateSettings.setLiveTranslateEnabled`, the one
// setter the session model's own `setLiveTranslateEnabled` also calls, so the
// leaf and a running session cannot disagree about it.

/// The row's pure surface: the switch's current value and the language its
/// copy is resolved in. Built by the session model (for the session's own
/// surfaces) and by this leaf (for the Settings row), so both draw the same
/// words from the same catalog keys.
struct GeminiCloudToggleSurface: Equatable {

    /// The row's title. "Use online translation (Gemini)" — the provider is
    /// named because the household is being asked to let a *particular*
    /// service do work for them.
    static let titleKey = "livetranslate.settings.cloud.title"
    /// The one-line explanation under the row: what "off" actually does.
    static let noteKey = "livetranslate.settings.cloud.note"

    let isOn: Bool
    let locale: Locale

    init(isOn: Bool, locale: Locale) {
        self.isOn = isOn
        self.locale = locale
    }

    /// The catalog's title, in the active language. Nepali first, like every
    /// other elder-facing string (T-005).
    var title: String { L10n.str(Self.titleKey, locale: locale) }

    /// The catalog's explanation, in the active language. It says what the
    /// switch does when it is off — on-device translation only — because that
    /// is the state a household that never touches it stays in.
    var note: String { L10n.str(Self.noteKey, locale: locale) }
}

/// The feature's master switch as its row renders it (Workstream B, owner
/// directive 2026-09-21) — the twin of `GeminiCloudToggleSurface`, and built
/// the same way for the same reason: the row draws the value and the language,
/// and the sentence lives in the catalog in both languages.
struct LiveTranslateEnabledToggleSurface: Equatable {

    /// The row's title. Deliberately the same *shape* as the cloud row's
    /// ("Use online translation (Gemini)"): the leaf now carries two switches
    /// and they must read as one family rather than as two unrelated controls.
    static let titleKey = "livetranslate.settings.enabled.title"
    /// The one-line explanation under the row: what "off" actually does, and
    /// where it is undone. The second sentence is the promise the refusal
    /// keeps — the leaf this line sits on is what opens when the feature is
    /// asked for while the switch is off.
    static let noteKey = "livetranslate.settings.enabled.note"

    let isOn: Bool
    let locale: Locale

    var title: String { L10n.str(Self.titleKey, locale: locale) }
    var note: String { L10n.str(Self.noteKey, locale: locale) }
}

/// The elder-facing switch row: a label, an explanation, and the app's own
/// token sizes. It draws a switch rather than the overlay's labelled button
/// because it lives on a Settings page among other switches
/// (`CalendarSettingsView`'s rows are the template), and it carries the app's
/// minimum tap target in both directions.
///
/// **One row for every switch on this leaf.** The master switch and the cloud
/// switch are the same control with different words, and a second copy of this
/// layout would be a second place for the token sizes, the identifier shape and
/// the type floors to drift — the failure the leaf's own copy notes warn about.
/// The switch's *identifier* is its title's key, so no call site mints a second
/// identifier for a control the tests need to find.
struct LiveTranslateToggleRow: View {

    let title: String
    let note: String
    /// The accessibility identifier, spelled by the surface that owns the key.
    let identifier: String
    /// The value the elder is asking for — an explicit set, so the write says
    /// what the tap meant even if the surface it was drawn from is a frame
    /// old, exactly as the overlay's display toggle does it.
    let isOn: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.interElementSpacing / 2) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .accessibilityIdentifier(identifier)

            Text(note)
                .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

/// The cloud tier's row, as it has always been — now the shared row with the
/// cloud surface's own words. Kept as its own type so every existing call site
/// and test reads unchanged.
struct GeminiCloudToggleRow: View {

    let surface: GeminiCloudToggleSurface
    let isOn: Binding<Bool>

    var body: some View {
        LiveTranslateToggleRow(title: surface.title,
                               note: surface.note,
                               identifier: GeminiCloudToggleSurface.titleKey,
                               isOn: isOn)
    }
}

struct LiveTranslateConsentSettingsView: View {

    /// The app's shared prompt/control state.
    @ObservedObject var controller: ConsentPromptController
    /// The feature's settings store (C14) — the same `UserDefaults`-backed
    /// value the session model is built from, so the switch written here is
    /// the switch the next session gates on. Injectable so a test can drive it
    /// over its own suite.
    let settings: LiveTranslateSettings
    @Environment(\.locale) private var locale

    /// The switch as this screen draws it. A local mirror of the store, and
    /// for the reason the store is a value: writing it cannot tell SwiftUI
    /// that anything changed, so the row would keep drawing the value it was
    /// first handed. The write still goes to the store — the mirror follows
    /// the write, never the other way round — so there is one persisted
    /// answer and this is only the copy the screen is drawing.
    @State private var geminiCloudEnabled: Bool

    /// The master switch's mirror, for the same reason and with the same rule:
    /// the mirror follows the write, and the store is the one answer.
    @State private var liveTranslateEnabled: Bool

    /// Both mirrors are **read from the store here**, synchronously, rather
    /// than in `onAppear` (review finding 8).
    ///
    /// This screen is *pushed by a refusal*: the elder tapped a tile that said
    /// the feature is off, "I've opened its settings" was spoken, and this leaf
    /// is what appears. `onAppear` runs after the first frame is drawn, so a
    /// mirror that started `true` painted the switch ON under the sentence that
    /// had just said the feature is off — the refusal contradicting itself for
    /// a frame. The store is the one answer and this is the same read
    /// `onAppear` makes; that read stays, because the decision can change on
    /// another surface while this one is alive.
    init(controller: ConsentPromptController,
         settings: LiveTranslateSettings = LiveTranslateSettings()) {
        self.controller = controller
        self.settings = settings
        _geminiCloudEnabled = State(initialValue: settings.geminiCloudEnabled)
        _liveTranslateEnabled = State(initialValue: settings.liveTranslateEnabled)
    }

    var body: some View {
        LeafScreen(titleKey: "settings.livetranslate.title") {
            VStack(spacing: 16) {
                // **The master switch is drawn first on purpose.** An elder who
                // reached this leaf because the feature refused — the spoken
                // line promises "I've opened its settings" — must find the
                // switch that refused them without scrolling past anything
                // else. It is also the outermost decision on the page: nothing
                // below it matters while it is off.
                let masterSwitch = LiveTranslateEnabledToggleSurface(isOn: liveTranslateEnabled,
                                                                     locale: locale)
                LiveTranslateToggleRow(title: masterSwitch.title,
                                       note: masterSwitch.note,
                                       identifier: LiveTranslateEnabledToggleSurface.titleKey,
                                       isOn: Binding(get: { liveTranslateEnabled },
                                                     set: { newValue in
                                                         liveTranslateEnabled = newValue
                                                         settings.setLiveTranslateEnabled(newValue)
                                                     }))

                ConsentControlView(surface: controller.controlSurface,
                                   onGrant: { controller.grant() },
                                   onDecline: { controller.decline() },
                                   onRevoke: { controller.revoke() })

                GeminiCloudToggleRow(surface: GeminiCloudToggleSurface(isOn: geminiCloudEnabled,
                                                                       locale: locale),
                                     isOn: Binding(get: { geminiCloudEnabled },
                                                   set: { newValue in
                                                       geminiCloudEnabled = newValue
                                                       settings.setGeminiCloudEnabled(newValue)
                                                   }))
            }
            .padding(.bottom, 32)
        }
        .onAppear {
            // The language may have changed since the controller was built,
            // and the decision may have been made on another surface: both
            // are re-read from source rather than remembered. The switches are
            // re-read from the store for the same reason — a value the elder
            // changed on a previous visit is the value this visit must show.
            controller.updateLocale(locale)
            controller.refreshControl()
            geminiCloudEnabled = settings.geminiCloudEnabled
            liveTranslateEnabled = settings.liveTranslateEnabled
        }
    }
}
