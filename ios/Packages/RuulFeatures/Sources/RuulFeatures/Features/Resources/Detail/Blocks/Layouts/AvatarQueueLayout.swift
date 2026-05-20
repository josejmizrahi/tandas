import SwiftUI
import RuulCore
import RuulUI

struct AvatarQueueLayout: View {
    let avatars: [CapabilityBlock.AvatarRef]
    let tint: ResourceFamilyTint

    var body: some View {
        HStack(spacing: -8) {
            ForEach(avatars.prefix(6)) { avatar in
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(tint.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Text(avatar.initials)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint.color)
                        )
                        .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
                    if let badge = avatar.badgeSymbol {
                        Image(systemName: badge)
                            .font(.system(size: 12))
                            .foregroundStyle(tint.color)
                            .background(Color.ruulSurface, in: Circle())
                    }
                }
            }
            if avatars.count > 6 {
                Text("+\(avatars.count - 6)")
                    .font(.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(.leading, RuulSpacing.sm)
            }
            Spacer(minLength: 0)
        }
    }
}
