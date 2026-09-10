import SwiftUI

/// The single notifications affordance on Home (home-redesign v3,
/// 2026-09-08): one bell with a badge showing how many panels are active
/// (0 hides the badge entirely — no stale "0" dot). The badge derives
/// from the SAME registry rows the Updates leaf's "Notifications" section
/// lists, so the bell can never advertise a count the leaf does not show.
/// The bell PUSHES the Updates leaf (LeafDestination.updates) — a
/// sheet-less, back-button-chrome surface (v3 replaced the drawer sheet
/// with the pushed leaf). Tap target is the full 44pt frame, not the
/// 32pt glyph.
struct NotificationBellButton: View {
    let count: Int
    let action: () -> Void

    private var bell: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                IconBadge(systemImage: "bell.fill", tint: .reminders, diameter: 32)
                if count > 0 {
                    Text("\(count)")
                        // DESIGN-REVIEW: the count is real information, not
                        // decoration — it takes the 18pt caption token (and
                        // its Dynamic Type scaling) instead of a fixed 12pt,
                        // and the capsule grows with it via minWidth/minHeight
                        // instead of clipping the digits.
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(DesignTokens.accent)
                        .clipShape(Capsule())
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text("notifications.bell"))
    }

    var body: some View {
        if count > 0 {
            bell.accessibilityValue(Text("\(count)"))
        } else {
            bell
        }
    }
}
