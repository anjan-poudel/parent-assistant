import SwiftUI

// MARK: - [TRANSLATE-TEST] The hidden dev screen (2026-09-21)
//
// A plain, honest comparison tool, reachable only through the hidden
// technical sheet (the Settings title's 0.8 s long-press), next to the URL
// scheme probe. It exists because the translation tiers could previously
// only be observed through a live camera session: the owner could see THAT
// a string was translated, never which engine answered, how long it took,
// or what the other engine would have said.
//
// It reads the SHIPPED engines — tier 1 (`LocalBrainTranslationTier`) and
// tier 2 (`CloudTranslationTier`) — through `TranslateTestModel`. It adds
// no translation logic, no second consent path and no second speech path:
// see the two files beside this one for why each reuse is the safe one.
//
// Deliberately not DEBUG-gated, and that is the existing surface's rule
// rather than an exception to it: the app's hidden technical sheet is
// reached by a gesture (see `SettingsView.hiddenSheetLongPressDuration`),
// and every instrument on it — the URL scheme probe, the intent log, the
// encoder switches — ships in Release too. Gating this one on DEBUG would
// invent a second, differently-hidden surface for one row.

struct TranslateTestView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var downloads: ModelDownloadService

    /// `@StateObject` with a no-arg init, configured on first appearance.
    ///
    /// The engines are built in `configure`, not here, for two reasons: the
    /// coordinator arrives through the environment (unreadable while a
    /// `@StateObject` is being constructed), and the engines hold a model
    /// tier whose construction spawns a generator — SwiftUI evaluates a
    /// view's initializer on every re-render, so building them there would
    /// cost a generator per keystroke in the editor.
    @StateObject private var model = TranslateTestModel()

    var body: some View {
        LeafScreen(titleKey: "settings.translateTest.title") {
            TranslateTestBody(model: model,
                              downloads: downloads,
                              locale: coordinator.activeLocale)
        }
        .task {
            // Configure, then ask — in that order, and in ONE task. Two
            // `.task` modifiers would race: a readiness check that ran
            // before the engines existed would find none and, without a
            // second trigger, the screen would never ask again.
            model.configure(with: coordinator.makeTranslateTestDependencies())
            await model.refreshReadiness()
        }
    }
}

// MARK: - The screen

/// The whole screen, once the model exists. A real `View` struct rather
/// than a computed property on `TranslateTestView` so a keystroke in the
/// editor invalidates this subtree and not the navigation chrome around it.
private struct TranslateTestBody: View {
    @ObservedObject var model: TranslateTestModel
    let downloads: ModelDownloadService
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TranslateTestComposerCard(model: model, locale: locale)

            TranslateTestControlsCard(model: model, locale: locale)

            if model.readiness == .modelMissing, model.selectedEngine == .local {
                TranslateTestInstallCard(downloads: downloads, locale: locale)
            }

            if let outcome = model.outcome {
                TranslateTestResultCard(outcome: outcome, locale: locale)
            }

            Text(L10n.str("settings.translateTest.note", locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A finished install is the one thing that can flip the local
        // engine from "no model" to runnable while this screen is open.
        .onReceive(downloads.$states) { _ in
            Task { await model.refreshReadiness() }
        }
        .onDisappear { model.onDisappear() }
    }
}

// MARK: - Composer (text + mic)

/// The input card: a multiline editor and the mic button.
///
/// The editor is a `TextEditor` rather than a `TextField` because the
/// interesting inputs are sentences (and pasted paragraphs), and the whole
/// point is to compare how the engines handle real text.
private struct TranslateTestComposerCard: View {
    @ObservedObject var model: TranslateTestModel
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if model.inputText.isEmpty {
                        Text(L10n.str("settings.translateTest.input.placeholder", locale: locale))
                            .font(.system(size: DesignTokens.minBodyPointSize))
                            .foregroundStyle(DesignTokens.textSecondary.opacity(0.6))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.inputText)
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                }

                TranslateTestMicButton(model: model, locale: locale)
            }

            if model.micPhase == .failed {
                Text(L10n.str("settings.translateTest.mic.failed", locale: locale))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.stateError)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

/// The mic button. One button, two jobs (start a capture, end a live one),
/// following the shipped leaf-mic behaviour in `DirectionsView`.
private struct TranslateTestMicButton: View {
    @ObservedObject var model: TranslateTestModel
    let locale: Locale

    private var isListening: Bool { model.micPhase == .listening }

    var body: some View {
        Button {
            model.toggleDictation()
        } label: {
            Image(systemName: isListening ? "mic.fill" : "mic")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isListening ? DesignTokens.accent : DesignTokens.textPrimary)
                .frame(minWidth: DesignTokens.minTapTargetSize,
                       minHeight: DesignTokens.minTapTargetSize)
                .background(isListening ? DesignTokens.accent.opacity(0.12)
                                        : DesignTokens.background)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.str(isListening
                                          ? "settings.translateTest.mic.listening"
                                          : "settings.translateTest.mic.start",
                                          locale: locale)))
    }
}

// MARK: - Engine picker + run

private struct TranslateTestControlsCard: View {
    @ObservedObject var model: TranslateTestModel
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.str("settings.translateTest.engine.label", locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)

            Picker(L10n.str("settings.translateTest.engine.label", locale: locale),
                   selection: $model.selectedEngine) {
                ForEach(TranslateTestEngine.allCases) { engine in
                    Text(L10n.str(engine.titleKey, locale: locale)).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            Text(readinessLine)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(model.readiness == .ready
                                 ? DesignTokens.stateSpeaking
                                 : DesignTokens.stateError)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await model.run() }
            } label: {
                Text(L10n.str(model.runState == .running
                              ? "settings.translateTest.state.running"
                              : "settings.translateTest.action.translate",
                              locale: locale))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                    .background(model.canRun ? DesignTokens.accent
                                             : DesignTokens.textSecondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(!model.canRun)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// The readiness caption: what the selected engine needs, in the words
    /// of the thing the household would have to do about it. A screen that
    /// only disabled the button would leave the reason unstated.
    private var readinessLine: String {
        // Unwrapped first: an unanswered readiness question is a state of
        // its own ("not checked yet"), and folding it into the switch would
        // make `nil` read as one of the three answers.
        guard let readiness = model.readiness else {
            return L10n.str("settings.translateTest.readiness.checking", locale: locale)
        }
        switch readiness {
        case .ready:
            return L10n.str("settings.translateTest.readiness.ready", locale: locale)
        case .modelMissing:
            return L10n.str("settings.translateTest.readiness.modelMissing", locale: locale)
        case .providerKeyMissing:
            return L10n.str("settings.translateTest.readiness.providerKeyMissing", locale: locale)
        case .cloudDisabled:
            return L10n.str("settings.translateTest.readiness.cloudDisabled", locale: locale)
        }
    }
}

// MARK: - Result

/// The answer card: the translation, then the facts about how it was
/// produced. The tier, latency and reason are rendered as the enum's own
/// tokens (`onDeviceBrain`, `412`, `consentNotGranted`) rather than as
/// translated prose — this is a developer's instrument, and a pretty
/// sentence would be a lossy copy of the token it is standing in for.
private struct TranslateTestResultCard: View {
    let outcome: TranslateProbeOutcome
    let locale: Locale

    private var result: TranslationResult { outcome.result }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.str(result.degraded
                          ? "settings.translateTest.result.degraded"
                          : "settings.translateTest.result.title",
                          locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(result.degraded ? DesignTokens.stateError
                                                 : DesignTokens.textPrimary)

            // The original text stays on screen for a degradation: with no
            // translation to show, the honest thing is the input plus the
            // token that says why, never a blank card.
            Text(result.text)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                fact(L10n.str("settings.translateTest.result.tier", locale: locale),
                     result.sourceTier?.rawValue ?? "—")
                // The unit lives in the LABEL, not in a format string: a
                // developer reading "Latency (ms) 412" wants the number and
                // the unit, and a %@ indirection would buy nothing but a
                // second key to keep in step.
                fact(L10n.str("settings.translateTest.result.latency", locale: locale),
                     String(outcome.latencyMs))
            }

            if let reason = result.degradedReason {
                fact(L10n.str("settings.translateTest.result.reason", locale: locale),
                     reason.rawValue)
            }

            // Tier 1's own words for "I declined to attempt this": the
            // result above already says nothing was translated, and this
            // says whether the model was even asked.
            if let deferral = outcome.localDeferral {
                fact(L10n.str("settings.translateTest.result.deferral", locale: locale),
                     deferral.displayToken)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
            Text(value)
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
        }
    }
}

// MARK: - Install affordance

/// Shown instead of the run button when tier 1 has no model on this device.
///
/// This is the "degrade honestly" requirement made visible: without it the
/// local engine would offer a button whose only possible outcome is a
/// refusal, and the screen would give no hint that the fix is a download.
/// It reuses `ModelManagementRow` — the SAME row the hidden AI-models screen
/// uses for this artifact — rather than a second download UI that could
/// disagree with the first about sizes, states or the class verdict.
private struct TranslateTestInstallCard: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let downloads: ModelDownloadService
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.str("settings.translateTest.install.section", locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)

            ForEach(ModelCatalog.availableTranslationEntries, id: \.id) { entry in
                ModelManagementRow(
                    entry: entry,
                    state: downloadState(for: entry.id),
                    // The ledger's verdict, not one this view derived: a
                    // view that guessed the device class would disagree with
                    // the manager on exactly the phones where it matters.
                    unavailableReason: ModelLifecycleManager.shared.availability(of: entry).reason,
                    downloadsWhileUnavailable: true,
                    showsArtifactSize: true,
                    onStart: { downloads.start(entry.id) },
                    onCancel: { downloads.cancel(entry.id) },
                    onDelete: {
                        try? coordinator.modelStore.delete(entry.id)
                        downloads.reset(entry.id)
                    }
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// The service's live state wins; otherwise derive from what is on disk,
    /// so a model installed before this screen opened reads as Ready rather
    /// than Download.
    private func downloadState(for id: ModelID) -> ModelDownloadState {
        if let state = downloads.states[id] { return state }
        guard let entry = ModelCatalog.entry(for: id) else { return .notStarted }
        return coordinator.modelStore.isInstalled(entry) ? .completed : .notStarted
    }
}
