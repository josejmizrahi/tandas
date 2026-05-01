import SwiftUI

struct TypologyCard: View {
    let type: GroupType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Brand.Surface.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Brand.Surface.cardPressed)
                    )
                Text(type.displayName)
                    .font(Brand.Typography.rowTitle)
                    .foregroundStyle(Brand.Surface.textPrimary)
                    .lineLimit(1)
                Text(type.copy)
                    .font(Brand.Typography.caption)
                    .foregroundStyle(Brand.Surface.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                    .fill(isSelected ? Brand.Surface.cardPressed : Brand.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                    .stroke(
                        isSelected ? Brand.Surface.textPrimary.opacity(0.30) : Brand.Surface.border,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}
