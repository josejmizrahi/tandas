import SwiftUI
import RuulCore
import RuulUI

/// Sticky footer button driven by `PrimaryAction` (from
/// `CapabilityResolver.primaryAction(...)`). Hidden when
/// `action.kind == .none`. Single source of CTA on detail v2.
///
/// Mounted via `.safeAreaInset(edge: .bottom)` on
/// `UniversalResourceDetailView`. Glass-frosted background; respects
/// safe area; scrollable content tucks under it for the iOS 26 look.
@MainActor
public struct ResourcePrimaryCTA: View {
    public let action: PrimaryAction
    public let onTap: () -> Void

    public init(action: PrimaryAction, onTap: @escaping () -> Void) {
        self.action = action
        self.onTap = onTap
    }

    public var body: some View {
        if action.kind == .none {
            EmptyView()
        } else {
            Button(action: onTap) {
                HStack(spacing: RuulSpacing.s2) {
                    if let symbol = action.symbol {
                        Image(systemName: symbol)
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                    Text(action.label)
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.s4)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .fill(backgroundColor)
                )
            }
            .buttonStyle(.ruulPress)
            .padding(.horizontal, RuulSpacing.s6)
            .padding(.bottom, RuulSpacing.s2)
            .padding(.top, RuulSpacing.s2)
            .background(.ultraThinMaterial)
        }
    }

    private var backgroundColor: Color {
        switch action.style {
        case .standard:    return Color.ruulAccentPrimary
        case .prominent:   return Color.ruulAccentPrimary
        case .destructive: return Color.red  // ruulSemanticDanger not in token set; use .red
        }
    }
}

#if DEBUG
#Preview("RSVP confirm") {
    VStack {
        Spacer()
        ResourcePrimaryCTA(
            action: PrimaryAction(
                label: "Confirmar mi asistencia",
                symbol: "checkmark.circle.fill",
                style: .prominent,
                kind: .rsvpConfirm
            ),
            onTap: {}
        )
    }
    .background(Color.ruulBackgroundCanvas)
}

#Preview("Hidden when .none") {
    VStack {
        Spacer()
        ResourcePrimaryCTA(action: .none, onTap: {})
    }
    .frame(height: 200)
    .background(Color.ruulBackgroundCanvas)
}
#endif
