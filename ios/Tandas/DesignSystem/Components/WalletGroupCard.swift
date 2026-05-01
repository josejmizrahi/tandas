import SwiftUI

struct WalletGroupCard: View {
    let group: Group
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                HStack {
                    Image(systemName: group.groupType.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text(group.groupType.displayName)
                        .font(.tandaCaption)
                        .padding(.horizontal, Brand.Spacing.s)
                        .padding(.vertical, 4)
                        .adaptiveGlass(Capsule())
                }
                Spacer()
                Text(group.name)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(Brand.Spacing.l)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            .adaptiveGlass(
                RoundedRectangle(cornerRadius: Brand.Radius.card),
                tint: Brand.paletteColor(forGroupId: group.id),
                interactive: true
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
