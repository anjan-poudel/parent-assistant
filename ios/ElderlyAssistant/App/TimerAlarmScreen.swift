import SwiftUI

/// Full-screen foreground timer alarm. Both exits stop the ringing timer:
/// the large STOP action is primary, while the required leading back
/// chevron gives every non-Home screen a consistent escape path. Neither
/// path can dismiss the alert while leaving its bell running.
struct TimerAlarmScreen: View {
    @Environment(\.appAppearance) private var appearance
    /// [AX-VIEWPORT] Gates the pinned STOP button's padding below.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// [RESPONSIVENESS] Gates the ringing bell's pulse below: a
    /// repeating decorative animation is exactly what reduceMotion is
    /// for (the motion IS the decoration here — when it is off the bell
    /// is simply still).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let timer: TimerItem
    let onStop: () -> Void

    var body: some View {
        ZStack {
            DesignTokens.stateError
                .ignoresSafeArea()
            ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Button {
                        // [RESPONSIVENESS] Escape-path confirmation: a
                        // light tap for the navigation-flavoured exit.
                        // The STOP button below carries the success
                        // feel — the deliberate completion — while both
                        // silence the same bell (the shell doc's
                        // "Both exits stop the ringing timer"). See
                        // `Haptics` for the reduceMotion/VoiceOver
                        // gates; the swipe-down dismissal
                        // (`TimerAlarmOverlay`) deliberately carries no
                        // haptic: it closes with the system sheet's own
                        // feel.
                        Haptics.play(.tap)
                        onStop()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                            .frame(minWidth: DesignTokens.minTapTargetSize,
                                   minHeight: DesignTokens.minTapTargetSize)
                            .background(appearance.colors.card)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.back"))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                Spacer()
                bellIcon
                Text("timerAlarm.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                if let label = timer.label {
                    Text(label)
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Text("timerAlarm.ringingNote")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                // [AX-VIEWPORT] STOP used to sit HERE, at the end of a
                // scrollable column: at accessibility text sizes the
                // column is taller than the screen, and STOP — the only
                // way to silence a ringing alarm — fell below the fold.
                // It is pinned as the ScrollView's bottom safe-area inset
                // now (see `stopButton`), always on screen whatever the
                // type size.
                // The honest foreground/background contract, on the one
                // screen where it matters most.
                Text("timerAlarm.backgroundNote")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
            }
            }
            .safeAreaInset(edge: .bottom) { stopButton }
        }
    }

    /// The ringing bell — the ONE moving thing on this screen, and the
    /// native way to say "this is ringing, not just displayed"
    /// [RESPONSIVENESS] (2026-10-14). A slowly repeating `.pulse` symbol
    /// effect on iOS 17+, where the glyph itself animates without a
    /// single timeline driving a view tree. Gated twice:
    ///
    /// - `#available(iOS 17.0, *)` — the iOS 16 floor renders the exact
    ///   static glyph this screen always had (no fallback animation: a
    ///   hand-rolled pulse would be new machinery for an icon, and the
    ///   ringing is already carried by the alarm audio).
    /// - `accessibilityReduceMotion` — no pulse at all under the Reduce
    ///   Motion setting; the STOP action and the audio are the alarm.
    @ViewBuilder
    private var bellIcon: some View {
        let bell = Image(systemName: "bell.fill")
            .font(.system(size: 100, weight: .bold))
            .foregroundColor(.white)
            .padding(.top, 32)
        if #available(iOS 17.0, *) {
            bell.symbolEffect(.pulse, isActive: !reduceMotion)
        } else {
            bell
        }
    }

    /// The STOP action, pinned to the bottom safe area (see `body`): the
    /// one exit from a ringing alarm must be visible without scrolling,
    /// at every text size. Its padding tightens at accessibility sizes —
    /// the pin owns visibility and the scaling label carries the size —
    /// so the pinned bar cannot eat the viewport it sits over. Standard
    /// sizes keep the 24pt padding exactly.
    private var stopButton: some View {
        Button {
            // [RESPONSIVENESS] The success notification's double-tick is
            // the one "it worked" feel in the vocabulary, reserved for
            // exactly this: silencing a ringing alarm. Fires inside the
            // action (never a gesture) so it is guaranteed on a shaky
            // press — for a ringing alarm the confirmation must not be
            // the thing that can be missed. See `Haptics` for the gates.
            Haptics.play(.success)
            onStop()
        } label: {
            Text("timerAlarm.stop")
                .font(.system(size: appearance.typography.bodyPointSize + 4,
                              weight: .bold))
                .foregroundColor(appearance.statusForeground(DesignTokens.stateError))
                .frame(maxWidth: .infinity)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 14 : 24)
                .background(appearance.colors.card)
                .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .padding(.horizontal, 36)
    }
}

/// Host view mounted at the app root: transparent while idle, presents
/// `TimerAlarmScreen` as a fullScreenCover the moment the engine enters
/// `.ringing`. The cover dismisses only when the engine leaves ringing —
/// which only the STOP button can do.
struct TimerAlarmOverlay: View {
    @ObservedObject var engine: TimerAlarmEngine
    let onStop: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fullScreenCover(isPresented: Binding(
                get: { isRinging },
                set: { presented in if !presented { onStop() } }
            )) {
                if let timer = ringingTimer {
                    TimerAlarmScreen(timer: timer, onStop: onStop)
                }
            }
    }

    private var isRinging: Bool {
        if case .ringing = engine.phase { return true }
        return false
    }

    private var ringingTimer: TimerItem? {
        if case .ringing(let timer) = engine.phase { return timer }
        return nil
    }
}
