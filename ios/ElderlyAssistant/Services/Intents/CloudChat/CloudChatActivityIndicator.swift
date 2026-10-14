import Foundation
import SwiftUI

// T-177 — the cloud-chat activity indicator, its responder wrapper and the
// elder-facing surfaces host (design-l1 §8.5, §17; FR-CNR-008). The third
// feature to carry a cloud-activity indicator, and the second to carry the
// shipped `CloudActivityIndicatorModel` shape: the LiveTranslate indicator's
// model, view chrome and "nothing is drawn when inactive" rule are reused
// deliberately, because the elder should not have to learn a second visual
// language for the same fact ("this answer is coming from the internet").
//
// What this file exists to make true:
//
//  - **The badge is a true statement about one window, and the window is the
//    routing decision.** `isActive` is `private(set)` and moves only through
//    the coordinator's paired window calls, which open it at the cloud
//    attempt's begin and close it when the reply has been spoken (or the
//    decision changed underneath it). A turn that routes local never opens
//    it, so "the badge never shows for a local-only turn" is a structural
//    property of having exactly one open site, not a rendering condition.
//  - **It reflects the enabled state in Settings.** The surface the
//    coordinator hands the view ANDs `isActive` with the gate's current
//    decision (read per render, never cached — design §8.5), so a revoked
//    device shows nothing even if a window were still open: the badge is
//    shown only while cloud chat is in force.
//  - **No content text, structurally.** The label is a catalogue key with no
//    format arguments, there is no parameter here that could carry a
//    transcript, a prompt or an identifier, and no event or log line is
//    emitted by this file at all. The gate's classification-only catalogue
//    is the consent evidence; this type has nothing content-bearing to add
//    (NFR-CNR-006, FR-CNR-007).
//  - **A glyph and a sentence, never a glyph alone** (NFR-CNR-009): the SF
//    Symbol is a system identifier and all the words are T-171's
//    `cloud.chat.indicator` in the active language, the same rule the
//    LiveTranslate indicator states for its own elder.
//
// `@MainActor` on the model and the host because both are bound to views and
// because serialising the window state on the main actor is what makes "no
// two transitions interleave" structural rather than hoped for.

/// The badge's whole state: whether a cloud-active window is open right now.
///
/// A counter, not a boolean edge: the open site is one call site but the
/// close funnels are several (speech end, revocation, the next turn's
/// decision), so the paired-begin/end discipline is what keeps a close from
/// racing an open. The count is `isActive`'s only source of truth.
@MainActor
final class CloudChatActivityIndicatorModel: ObservableObject {

    /// Whether a cloud-active window is open **right now**. The only writers
    /// are the coordinator's paired window calls; the only readers are the
    /// host view and the tests.
    @Published private(set) var isActive = false

    /// How many windows the model believes are open. Evidence for tests;
    /// there is no setter.
    private var openWindowCount = 0
    var openWindowCountForTesting: Int { openWindowCount }

    // MARK: - The paired window calls (the only input)

    /// The coordinator reports that a cloud attempt has begun. The badge
    /// appears on the 0→1 transition.
    func requestBegan() {
        openWindowCount += 1
        guard openWindowCount == 1 else { return }
        isActive = true
    }

    /// The coordinator reports that the window is over — the reply for the
    /// attempt was spoken, the decision changed, or a new turn superseded it.
    /// The badge disappears on the 1→0 transition.
    ///
    /// An unpaired call is ignored rather than counted: a count that could go
    /// negative would let a later attempt fail to show the badge, and
    /// silently *not* showing it is the one error this type must not make
    /// (the shipped model's own rule).
    func requestEnded() {
        guard openWindowCount > 0 else { return }
        openWindowCount -= 1
        guard openWindowCount == 0 else { return }
        isActive = false
    }
}

/// The pure surface behind `CloudChatActivityIndicatorView`: whether the
/// window is open, whether cloud chat is in force, and the copy to show in
/// the active language.
struct CloudChatActivityIndicatorSurface: Equatable {

    /// The glyph. An SF Symbol name is a system identifier, not user-visible
    /// copy, so it is a constant here; the words are all in the catalog.
    static let symbolName = "cloud"

    /// The model's current state — the window.
    let isActive: Bool
    /// The gate's current decision, read per render by the coordinator
    /// (design §8.5: the badge "also reflects the enabled state in
    /// Settings"). The view renders only when both are true.
    let cloudChatEnabled: Bool
    /// The active language, resolved here rather than through the view
    /// hierarchy, so a Nepali session reads Nepali.
    let locale: Locale

    init(isActive: Bool, cloudChatEnabled: Bool, locale: Locale) {
        self.isActive = isActive
        self.cloudChatEnabled = cloudChatEnabled
        self.locale = locale
    }

    /// Whether the badge is on screen: an open window on a device where
    /// cloud chat is in force. One computed truth, so the view and the
    /// tests cannot disagree about it.
    var isShown: Bool { isActive && cloudChatEnabled }

    /// The plain-language label, from the catalog, in the active language.
    /// Deliberately zero format slots (T-171's contract): nothing from the
    /// turn can ride into the copy.
    var label: String {
        L10n.str("cloud.chat.indicator", locale: locale)
    }
}

/// The elder-facing badge: a small card with a glyph and a sentence, the
/// shipped indicator chrome reused so the same fact looks the same.
struct CloudChatActivityIndicatorView: View {
    @Environment(\.appAppearance) private var appearance

    let surface: CloudChatActivityIndicatorSurface

    var body: some View {
        if surface.isShown {
            HStack(spacing: 8) {
                Image(systemName: CloudChatActivityIndicatorSurface.symbolName)
                    .font(DesignTokens.warmFont(size: appearance.typography.bodyPointSize))
                    .foregroundColor(appearance.colors.textPrimary)
                Text(surface.label)
                    .font(DesignTokens.warmFont(size: appearance.typography.bodyPointSize))
                    .foregroundColor(appearance.colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .appSurface(cornerRadius: DesignTokens.bubbleCornerRadius)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(surface.label))
            .accessibilityIdentifier("cloudchat.indicator")
        }
    }
}

/// The turn's cloud responder with the indicator's two hooks (T-177).
///
/// A pass-through wrapper, not a second responder: it delegates to the
/// interpreter that actually answers chat (`GeminiIntentInterpreter` via the
/// coordinator) and adds nothing to the conversation. Its whole job is to
/// make the attempt's begin and settle observable at the one seam every
/// cloud chat call already goes through, so the badge window and the served-
/// path provenance are driven by the call itself rather than by a call site
/// remembering to report (the same "a call site cannot forget" discipline as
/// the shipped model's scoped registration).
///
/// Hook ordering is the contract: `onAttemptBegan` runs before the delegate
/// is asked, and `onAttemptSettled` runs in the delegate's completion —
/// **before** the caller's completion — so by the time the router's chat
/// guard reads the served path (T-174) the provenance for this attempt is
/// already recorded, and no caller can observe the reply ahead of the
/// indicator's own bookkeeping.
final class CloudChatIndicatorResponder: ChatResponding, CloudFailureReporting {

    /// The interpreter that answers. Weak would be wrong here: this wrapper
    /// exists only while its delegate does (the coordinator holds both), and
    /// a nil delegate would be a silently broken cloud leg.
    private let wrapped: ChatResponding & CloudFailureReporting

    /// Called once per attempt, before the delegate is asked. Main-confined
    /// by the completion contract of `ChatResponding`.
    private let onAttemptBegan: () -> Void

    /// Called once per attempt, in the delegate's completion, before the
    /// caller's completion runs. `nil` means the attempt produced no usable
    /// reply (failure or abstention) — the provenance question ("was the
    /// reply served from the cloud?") is answered `false` for it.
    private let onAttemptSettled: (InterpretedCommand?) -> Void

    init(wrapping wrapped: ChatResponding & CloudFailureReporting,
         onAttemptBegan: @escaping () -> Void,
         onAttemptSettled: @escaping (InterpretedCommand?) -> Void) {
        self.wrapped = wrapped
        self.onAttemptBegan = onAttemptBegan
        self.onAttemptSettled = onAttemptSettled
    }

    // MARK: - ChatResponding

    func respondToChat(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
        onAttemptBegan()
        wrapped.respondToChat(transcript: transcript, context: context) { [onAttemptSettled] command in
            onAttemptSettled(command)
            completion(command)
        }
    }

    // MARK: - CloudFailureReporting

    var lastCloudFailureClass: GeminiFailureClass? { wrapped.lastCloudFailureClass }

    func clearCloudFailure() { wrapped.clearCloudFailure() }
}

/// The one mount point for the feature's elder-facing overlays inside the
/// main screen: the activity badge and the consent sheet (T-177).
///
/// Mounted by `TalkStage` in the status slot (`HomeSubviews.swift`), which is
/// the design's §8.5 home for the badge ("the existing status-slot surface;
/// no new screen"). It reads the coordinator from the environment — every
/// main-screen subview already resolves it that way — and asks it three
/// questions per render: what the badge surface is, whether the consent
/// question is up, and what its sheet surface is. No state of its own: the
/// coordinator owns the window and the question, so there is no second place
/// either could diverge from.
///
/// The sheet's `isPresented` binding reads the prompt's published state and
/// ignores writes: the question closes when the gate has a decision — never
/// because a view said so — and the sheet's own `.interactiveDismissDisabled`
/// makes the system's write-back a non-event.
struct CloudChatSurfacesHost: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        CloudChatActivityIndicatorView(surface: coordinator.cloudChatIndicatorSurface)
            .sheet(isPresented: Binding(
                get: { coordinator.cloudChatConsentPromptIsPresented },
                set: { _ in }
            )) {
                CloudChatConsentSheet(
                    surface: coordinator.cloudChatConsentSheetSurface,
                    onAllow: { coordinator.answerCloudChatConsentFromSheet(.allow) },
                    onNotNow: { coordinator.answerCloudChatConsentFromSheet(.notNow) }
                )
            }
    }
}
