import SwiftUI
import RuulCore
import RuulUI

/// Layer 4: key/value list with hairline dividers. Renders nothing when
/// rows is empty (the parent skips it). 4-7 rows is the doctrine max;
/// the builder enforces that limit.
struct PropertiesBlockView: View {
    let block: PropertiesBlock

    var body: some View {
        if !block.rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(block.rows.enumerated()), id: \.element.id) { idx, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.key)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(row.value)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, RuulSpacing.sm)
                    if idx < block.rows.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.xs)
            .background(
                Color.ruulSurface,
                in: RoundedRectangle(cornerRadius: RuulRadius.md)
            )
        }
    }
}
