import SwiftUI

/// Header chip that surfaces the active group on tabs other than Home.
/// Tap presents the shared `GroupSwitcherSheet` (same UX as the Menu in
/// HomeView's hero header). Optional `trailing` slot for a tab-specific
/// circular action (e.g. pencil on Rules, gear on Profile).
///
/// Usage:
/// ```
/// GroupContextHeader(
///     group: app.activeGroup,
///     onTap: { groupSwitcherPresented = true }
/// )
/// ```
struct GroupContextHeader<Trailing: View>: View {
    let group: Group?
    let onTap: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(
        group: Group?,
        onTap: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.group = group
        self.onTap = onTap
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: RuulSpacing.sm) {
            Button(action: onTap) {
                HStack(spacing: RuulSpacing.sm) {
                    avatar
                    VStack(alignment: .leading, spacing: 0) {
                        Text("GRUPO ACTIVO")
                            .ruulTextStyle(RuulTypography.sectionLabel)
                            .foregroundStyle(Color.ruulTextTertiary)
                        HStack(spacing: RuulSpacing.xxs) {
                            Text(group?.name ?? "—")
                                .ruulTextStyle(RuulTypography.title)
                                .foregroundStyle(Color.ruulTextPrimary)
                                .lineLimit(1)
                                .id(group?.id) // crossfade key
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.ruulTextTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(
            // TODO v3 §13: replace .regularMaterial → .glassBackground() / .glassMaterial()
            //             cuando SwiftUI iOS 26 SDK los exponga.
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .strokeBorder(Color.ruulSeparator, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, RuulSpacing.md)
        .padding(.top, RuulSpacing.xs)
        .animation(.ruulSnappy, value: group?.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Grupo activo: \(group?.name ?? "ninguno"). Toca para cambiar.")
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.ruulAccentMuted)
                .frame(width: 36, height: 36)
            Text(initial)
                .ruulTextStyle(RuulTypography.callout)
                .fontWeight(.bold)
                .foregroundStyle(Color.ruulAccent)
                .id(group?.id) // crossfade
                .transition(.opacity)
        }
    }

    private var initial: String {
        guard let name = group?.name, let first = name.first else { return "?" }
        return String(first).uppercased()
    }
}

#if DEBUG
#Preview {
    VStack(spacing: RuulSpacing.lg) {
        GroupContextHeader(
            group: Group(
                id: UUID(),
                name: "Cena del Jueves",
                inviteCode: "ABC",
                createdBy: UUID(),
                createdAt: .now
            ),
            onTap: {}
        )
        GroupContextHeader(
            group: Group(
                id: UUID(),
                name: "Trabajo",
                inviteCode: "XYZ",
                createdBy: UUID(),
                createdAt: .now
            ),
            onTap: {},
            trailing: {
                Button { } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.ruulTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.ruulSurface, in: Circle())
                        .overlay(Circle().stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        )
        Spacer()
    }
    .padding(.vertical, RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
