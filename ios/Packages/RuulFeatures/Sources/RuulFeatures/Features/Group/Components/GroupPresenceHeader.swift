import SwiftUI
import RuulUI
import RuulCore

/// Top-of-page identity block for `GroupSpaceView`. Mirrors the snippet
/// PresenceHeader: 72pt rounded-square avatar with the group's color
/// ramp as a gradient + warm shadow, 30pt serif italic name, metadata
/// row, large avatar stack.
///
/// The avatar shape is intentionally rounded-square (not circle) — it's
/// "el escudo del grupo", a flag the group identifies with.
@MainActor
struct GroupPresenceHeader: View {
    let group: RuulCore.Group
    let memberCount: Int
    let members: [MemberWithProfile]
    var onTapMembers: (() -> Void)?

    private var ramp: GroupColorRamp { group.category.ramp }

    var body: some View {
        VStack(spacing: RuulSpacing.md) {
            avatar
            identity
            if !members.isEmpty {
                Button(action: { onTapMembers?() }) {
                    RuulAvatarStack(
                        people: members.map(personFromMember),
                        size: .medium,
                        maxVisible: 5
                    )
                    .padding(.top, RuulSpacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ver miembros del grupo")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.lg)
    }

    private var avatar: some View {
        ZStack {
            if let url = group.avatarUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: gradientFill
                    }
                }
            } else {
                gradientFill
                Text(group.initials)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ramp.background)
                    .kerning(-0.5)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .strokeBorder(Color.ruulBorderGlass, lineWidth: 1)
        )
        .shadow(color: ramp.accent.opacity(0.35), radius: 18, y: 8)
    }

    private var gradientFill: some View {
        LinearGradient(
            colors: [ramp.accent, ramp.foreground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var identity: some View {
        VStack(spacing: RuulSpacing.xxs) {
            Text(group.name)
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .italic()
                .kerning(-0.5)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            HStack(spacing: RuulSpacing.xs) {
                Text(group.category.displayName)
                Text("·")
                Text(memberCountLabel)
            }
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        }
    }

    private var memberCountLabel: String {
        switch memberCount {
        case 0: "Sin miembros"
        case 1: "1 persona"
        default: "\(memberCount) personas"
        }
    }

    private func personFromMember(_ m: MemberWithProfile) -> RuulAvatarStack.Person {
        RuulAvatarStack.Person(
            id: m.id.uuidString,
            name: m.displayName,
            imageURL: m.avatarURL
        )
    }
}
