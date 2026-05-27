import SwiftUI
import RuulCore

/// Circular avatar with `AsyncImage` for the remote URL path and an
/// initials-on-material fallback when the URL is absent or fails to
/// load. Uses only system primitives — no custom palette.
public struct MemberAvatarView: View {
    let item: MembershipBoundaryItem

    public init(item: MembershipBoundaryItem) {
        self.item = item
    }

    public var body: some View {
        if let url = item.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    fallback
                @unknown default:
                    fallback
                }
            }
            .clipShape(Circle())
        } else {
            fallback
        }
    }

    @ViewBuilder
    private var fallback: some View {
        ZStack {
            Circle().fill(.thinMaterial)
            Text(item.initials)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

#Preview("Initials") {
    MemberAvatarView(item: MembershipBoundaryItem(
        id: UUID(), kind: .membership, displayName: "Ana López"
    ))
    .frame(width: 40, height: 40)
    .padding()
}

#Preview("Single letter") {
    MemberAvatarView(item: MembershipBoundaryItem(
        id: UUID(), kind: .membership, displayName: "Luis"
    ))
    .frame(width: 40, height: 40)
    .padding()
}

#Preview("Invite email") {
    MemberAvatarView(item: MembershipBoundaryItem(
        id: UUID(), kind: .invite, displayName: "carlos@email.com"
    ))
    .frame(width: 40, height: 40)
    .padding()
}
