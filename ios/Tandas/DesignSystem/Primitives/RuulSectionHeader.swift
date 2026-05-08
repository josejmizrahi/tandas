import SwiftUI
import RuulUI

/// Section header con título + subtítulo opcional + trailing slot.
/// Per DS doc §3.7.
public struct RuulSectionHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.title3, design: .default, weight: .semibold))
            if let subtitle {
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(subtitle)
                    .font(.system(.title3, design: .default, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, RuulSpacing.screenPadding)
    }
}

#if DEBUG
#Preview("RuulSectionHeader") {
    VStack(alignment: .leading, spacing: RuulSpacing.lg) {
        RuulSectionHeader(title: "Hoy", subtitle: "martes")
        RuulSectionHeader(title: "Multas pendientes")
        RuulSectionHeader(title: "Histórico") {
            RuulPillButton(symbol: "calendar", size: .small) {}
        }
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
