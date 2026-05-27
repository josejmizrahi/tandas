import SwiftUI
import RuulCore

/// Single row inside `MembersListView`. Avatar + name + optional role
/// subtitle on the leading side; status badge trailing. The whole row
/// is exposed as a single accessibility element so VoiceOver doesn't
/// fragment the announcement.
public struct MemberRowView: View {
    let member: MemberListItem

    public init(member: MemberListItem) {
        self.member = member
    }

    public var body: some View {
        HStack(spacing: 12) {
            MemberAvatarView(member: member)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle = member.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            MembershipStatusBadge(status: member.status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(member.accessibilityLabelText))
    }
}

#Preview("Active w/ role") {
    List {
        MemberRowView(member: .init(
            id: UUID(),
            displayName: "Ana López",
            status: .active,
            roleNames: ["Tesorero"]
        ))
    }
}

#Preview("Invited, no role") {
    List {
        MemberRowView(member: .init(
            id: UUID(),
            displayName: "carlos@email.com",
            status: .invited
        ))
    }
}

#Preview("Long name + many roles") {
    List {
        MemberRowView(member: .init(
            id: UUID(),
            displayName: "Christopher Alexander de la Vega y Castillo del Mar",
            status: .active,
            roleNames: ["Coordinador", "Aprobador", "Moderador"]
        ))
    }
}
