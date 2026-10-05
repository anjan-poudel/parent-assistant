import SwiftUI

enum AppSurfaceRole {
    case card, control, accent, dock
}

extension View {
    /// Apply after padding/layout. This modifier does not size or expand hit targets.
    func appSurface(role: AppSurfaceRole = .card,
                    cornerRadius: CGFloat = DesignTokens.cardCornerRadius) -> some View {
        modifier(AppSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }
}

private struct AppSurfaceModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let role: AppSurfaceRole
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var isEmphasized: Bool { role == .accent || role == .dock }
    private var opaqueFill: Color {
        switch role {
        case .card, .control: appearance.colors.card
        case .accent: appearance.colors.accent
        case .dock: appearance.colors.textPrimary
        }
    }

    func body(content: Content) -> some View {
        content
            .contentShape(shape)
            .background { surface }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? appearance.colors.textPrimary : appearance.colors.separator,
                    lineWidth: contrast == .increased ? 2 : 0.75)
            }
            .shadow(color: appearance.colors.textPrimary.opacity(
                appearance.style == .classic || reduceTransparency || contrast == .increased ? 0 : 0.10),
                    radius: 8, x: 0, y: 3)
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency || contrast == .increased || appearance.style == .classic {
            shape.fill(opaqueFill)
        } else if isEmphasized {
            // Primary and dock ink must never depend on the content behind glass.
            shape.fill(LinearGradient(
                colors: [opaqueFill, role == .accent ? appearance.colors.talkDeep : opaqueFill],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        } else if appearance.style == .glass {
            if #available(iOS 26.0, *) {
                if role == .control && !reduceMotion {
                    shape.fill(.clear)
                        .glassEffect(.regular.tint(appearance.colors.card.opacity(0.35)).interactive(), in: shape)
                } else {
                    shape.fill(.clear)
                        .glassEffect(.regular.tint(appearance.colors.card.opacity(0.35)), in: shape)
                }
            } else {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(appearance.colors.card.opacity(0.28)) }
            }
        } else {
            shape.fill(LinearGradient(
                colors: [appearance.colors.card, appearance.colors.background],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}
