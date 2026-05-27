import SwiftUI
import RuulCore

/// Single row inside `MembersListView`. Renders a boundary item
/// (membership or pending invite). Pending invites use the same
/// avatar/initial fallback as memberships and surface "Invitación
/// pendiente" as the subtitle so the row makes sense even when no
/// profile is attached to the invite yet.
public struct MemberRowView: View {
    let item: MembershipBoundaryItem

    public init(item: MembershipBoundaryItem) {
        self.item = item
    }

    public var body: some View {
        HStack(spacing: 12) {
            MemberAvatarView(item: item)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            MembershipStatusBadge(status: item.status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.accessibilityLabelText))
    }
}

#Preview("Active w/ role") {
    List {
        MemberRowView(item: MembershipBoundaryItem(
            id: UUID(), kind: .membership, membershipId: UUID(),
            displayName: "Ana López", status: .active,
            roleNames: ["Tesorero"]
        ))
    }
}

#Preview("Pending invite") {
    List {
        MemberRowView(item: MembershipBoundaryItem(
            id: UUID(), kind: .invite, inviteId: UUID(),
            displayName: "carlos@email.com", status: .invited
        ))
    }
}

#Preview("Provisional") {
    List {
        MemberRowView(item: MembershipBoundaryItem(
            id: UUID(), kind: .membership, membershipId: UUID(),
            displayName: "Mateo García", status: .active,
            membershipType: .provisional
        ))
    }
}

#Preview("Long name + many roles") {
    List {
        MemberRowView(item: MembershipBoundaryItem(
            id: UUID(), kind: .membership, membershipId: UUID(),
            displayName: "Christopher Alexander de la Vega y Castillo del Mar",
            status: .active,
            roleNames: ["Coordinador", "Aprobador", "Moderador"]
        ))
    }
}
