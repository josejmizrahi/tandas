import SwiftUI
import RuulUI
import RuulCore

/// Floating "Coordinar" button matching the snippet's
/// `FloatingCoordinateButton`. Brand-blue gradient capsule (pulled
/// from `GroupColorRamp.blue` so the color resolves dynamically per
/// scheme + contrast — never hex-hardcoded) with double-shadow and
/// press-scale haptic.
@MainActor
struct GroupCoordinateFAB: View {
    let action: () -> Void
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var brandBlue: Color { GroupColorRamp.blue.accent }
    private var brandBlueDeep: Color { GroupColorRamp.blue.foreground }

    var body: some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.xs - 1) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                Text("Coordinar")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.ruulTextInverse)
            .padding(.horizontal, RuulSpacing.xxl)
            .padding(.vertical, RuulSpacing.md + 2)
            .background(
                LinearGradient(
                    colors: [brandBlue, brandBlueDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Color.ruulBorderGlass, lineWidth: 1))
            .shadow(color: brandBlue.opacity(0.55), radius: 18, y: 10)
            .shadow(color: brandBlue.opacity(0.25), radius: 6, y: 4)
            .scaleEffect(isPressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isPressed)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 50) { } onPressingChanged: { pressing in
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6)) {
                isPressed = pressing
            }
        }
    }
}
