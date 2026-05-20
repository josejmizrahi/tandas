import SwiftUI

/// Canonical section header for lists: a tracked-uppercase label on
/// the leading edge plus an optional trailing count. Mirrors Apple
/// Settings / Luma section divider rhythm — `PENDIENTES   3`, `DINERO`,
/// `MIS MULTAS   12`. Replaces the ad-hoc `HStack { Text("CAPS") +
/// Spacer + Text(count) }` pattern duplicated across 10+ feature
/// files.
///
/// Use as the first child of a section's VStack, above a
/// `RuulSeparatedRows` or a single content card.
@MainActor
public struct RuulListSectionHeader: View {
    public let label: String
    public let count: Int?
    public let accessory: AnyView?

    public enum Accessory {
        case none
        case count(Int)
        case custom(AnyView)
    }

    public init(
        _ label: String,
        count: Int? = nil
    ) {
        self.label = label
        self.count = count
        self.accessory = nil
    }

    public init<Trailing: View>(
        _ label: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label
        self.count = nil
        self.accessory = AnyView(trailing())
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.xs) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ruulTextTertiary)
            Spacer(minLength: 0)
            if let accessory {
                accessory
            } else if let count {
                Text("\(count)")
                    .font(.footnote.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }
}

#if DEBUG
#Preview("RuulListSectionHeader") {
    VStack(alignment: .leading, spacing: RuulSpacing.lg) {
        RuulListSectionHeader("PENDIENTES", count: 3)
        RuulListSectionHeader("DINERO")
        RuulListSectionHeader("MIS GRUPOS") {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.ruulAccent)
        }
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
