import SwiftUI

/// Full-screen foreground timer alarm. Both exits stop the ringing timer:
/// the large STOP action is primary, while the required leading back
/// chevron gives every non-Home screen a consistent escape path. Neither
/// path can dismiss the alert while leaving its bell running.
struct TimerAlarmScreen: View {
    let timer: TimerItem
    let onStop: () -> Void

    var body: some View {
        ZStack {
            DesignTokens.stateError
                .ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Button(action: onStop) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(DesignTokens.stateError)
                            .frame(minWidth: DesignTokens.minTapTargetSize,
                                   minHeight: DesignTokens.minTapTargetSize)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.back"))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
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
