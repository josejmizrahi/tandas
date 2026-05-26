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
    /// Tap on the whole avatar strip (or the "+N" overflow). Routes
    /// to the full members list.
    var onTapMembers: (() -> Void)?
    /// 2026-05-25: per-avatar tap → opens `MemberQuickSheet`. When nil,
    /// the avatar stack is a single tap target falling back to
    /// `onTapMembers`. When set, each avatar becomes its own tap surface.
    var onTapMember: ((MemberWithProfile) -> Void)?

    private let maxVisible = 5
    private var visibleMembers: [MemberWithProfile] {
        Array(members.prefix(maxVisible))
    }
    private var overflow: Int {
        max(0, memberCount - maxVisible)
    }

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
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(metadataLabel)
                    .font(.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            if !members.isEmpty {
                avatarRow
                    .padding(.top, RuulSpacing.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.md)
    }

    // MARK: - Avatar row

    /// When `onTapMember` is non-nil, each avatar is independently
    /// tappable (opens MemberQuickSheet). When nil, the whole row falls
    /// back to a single button that routes to the full members list.
    @ViewBuilder
    private var avatarRow: some View {
        if onTapMember != nil {
            HStack(spacing: -8) {
                ForEach(visibleMembers, id: \.id) { m in
                    Button {
                        onTapMember?(m)
                    } label: {
                        RuulAvatar(
                            name: m.displayName,
                            imageURL: m.avatarURL,
                            size: .small,
                            border: .glass
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(m.displayName)
                }
                if overflow > 0 {
                    Button(action: { onTapMembers?() }) {
                        Text("+\(overflow)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ruulTextSecondary)
                            .frame(width: 28, height: 28)
                            .background(Color.ruulSurface, in: Circle())
                            .overlay(
                                Circle().strokeBorder(Color.ruulSurface, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ver \(overflow) miembros más")
                }
            }
        } else {
            Button(action: { onTapMembers?() }) {
                RuulAvatarStack(
                    people: members.map(personFromMember),
                    size: .small,
                    maxVisible: maxVisible
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ver miembros del grupo")
        }
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
