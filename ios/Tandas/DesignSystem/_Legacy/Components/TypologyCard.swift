import SwiftUI

struct TypologyCard: View {
    let type: GroupType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text(type.displayName)
                    .font(.tandaTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(type.copy)
                    .font(.tandaCaption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Brand.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(
                RoundedRectangle(cornerRadius: Brand.Radius.card),
                tint: isSelected ? Brand.accent.opacity(0.5) : nil,
                interactive: true
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}
