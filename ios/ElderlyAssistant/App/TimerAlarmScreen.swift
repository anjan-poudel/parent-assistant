import SwiftUI

/// [TIMER-ALARM] (2026-09-10) The full-screen timer-alarm UI — the
/// foreground ringing experience for UN-path timers (pre-iOS-26 /
/// AlarmKit-denied). Elderly-first per the app's design tokens: one deep
/// alarm-red screen (`DesignTokens.stateError` — the app's "stop" light,
/// ≥5.7:1 with white glyphs), a huge bell, the finished line, and a
/// SINGLE large STOP button. No other controls — a ringing alarm offers
/// exactly one answer.
///
/// The STOP button is the only exit: it ends the looping bell and expires
/// the timer row (coordinator's `stopTimerAlarm`). The fullScreenCover
/// hosting this screen is not interactively dismissable on iPhone, so
/// the alarm cannot be swiped away without stopping it — deliberate.
struct TimerAlarmScreen: View {
    let timer: TimerItem
    let onStop: () -> Void

    var body: some View {
        ZStack {
            DesignTokens.stateError
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "bell.fill")
                    .font(.system(size: 100, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.top, 32)
                Text("timerAlarm.title")
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                if let label = timer.label {
                    Text(label)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Text("timerAlarm.ringingNote")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button(action: onStop) {
                    Text("timerAlarm.stop")
                        .font(.system(size: DesignTokens.minBodyPointSize + 4,
                                      weight: .bold))
                        .foregroundColor(DesignTokens.stateError)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                }
                .padding(.horizontal, 36)
                // The honest foreground/background contract, on the one
                // screen where it matters most.
                Text("timerAlarm.backgroundNote")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
            }
        }
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
