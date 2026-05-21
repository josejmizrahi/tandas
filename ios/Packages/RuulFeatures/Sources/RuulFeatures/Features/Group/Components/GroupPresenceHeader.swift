import SwiftUI
import RuulUI
import RuulCore

/// Top-of-page identity block for `GroupSpaceView`. Native chrome:
/// `RuulGroupAvatar` (circle, color ramp per category), name in
/// `.title2.weight(.semibold)`, member-count caption, avatar stack
/// that taps through to the members list. Mirrors the hero pattern
/// from the previous `GroupHomeView`.
@MainActor
struct GroupPresenceHeader: View {
    let group: RuulCore.Group
    let memberCount: Int
    let members: [MemberWithProfile]
    var onTapMembers: (() -> Void)?

    var body: some View {
        VStack(spacing: RuulSpacing.sm) {
            RuulGroupAvatar(
                groupName: group.name,
                initials: group.initials,
                category: group.category,
                imageURL: group.avatarUrl.flatMap(URL.init(string:)),
                size: .xl
            )

            VStack(spacing: 2) {
                Text(group.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(metadataLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            if !members.isEmpty {
                Button(action: { onTapMembers?() }) {
                    RuulAvatarStack(
                        people: members.map(personFromMember),
                        size: .small,
                        maxVisible: 5
                    )
                    .padding(.top, RuulSpacing.xxs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ver miembros del grupo")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.md)
    }

    private var metadataLabel: String {
        let category = group.category.displayName
        let countText: String = {
            switch memberCount {
            case 0: return "Sin miembros"
            case 1: return "1 persona"
            default: return "\(memberCount) personas"
            }
        }()
        return "\(category) · \(countText)"
    }

    private func personFromMember(_ m: MemberWithProfile) -> RuulAvatarStack.Person {
        RuulAvatarStack.Person(
            id: m.id.uuidString,
            name: m.displayName,
            imageURL: m.avatarURL
        )
    }
}
