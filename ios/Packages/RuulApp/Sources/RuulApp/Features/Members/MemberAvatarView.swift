import SwiftUI
import RuulCore

/// Circular avatar with `AsyncImage` for the remote URL path and an
/// initials-on-material fallback when the URL is absent or fails to
/// load. Uses only system primitives — no custom palette.
public struct MemberAvatarView: View {
    let member: MemberListItem

    public init(member: MemberListItem) {
        self.member = member
    }

    public var body: some View {
        if let url = member.avatarURL {
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
            Text(member.initials)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

#Preview("Initials") {
    MemberAvatarView(member: .init(id: UUID(), displayName: "Ana López"))
        .frame(width: 40, height: 40)
        .padding()
}

#Preview("Single letter") {
    MemberAvatarView(member: .init(id: UUID(), displayName: "Luis"))
        .frame(width: 40, height: 40)
        .padding()
}
