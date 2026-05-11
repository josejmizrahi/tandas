import SwiftUI
import RuulUI
import RuulCore

/// Members tab — group roster with avatar, role badge, and net balance
/// (the "what's their story" stat). Founder always first; alphabetical
/// within the rest.
///
/// V1 is read-only: tapping a row is a no-op for now (member detail
/// view ships in a follow-up). The page already answers the four
/// questions the user has when they open it:
///   "Quiénes están" "Qué rol tienen" "Cuándo entraron" "Cómo van de cuenta"
public struct MembersSubTab: View {
    @Bindable var coordinator: MembersSubTabCoordinator

    public init(coordinator: MembersSubTabCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                heroBlock
                rosterSection
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
        .task { await coordinator.refresh() }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("MIEMBROS")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text("\(coordinator.activeCount) activos")
                .ruulTextStyle(RuulTypography.displayMedium)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(.top, RuulSpacing.xs)
    }

    // MARK: - Roster

    @ViewBuilder
    private var rosterSection: some View {
        if coordinator.isLoading && coordinator.rows.isEmpty {
            RuulLoadingState()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if coordinator.rows.isEmpty {
            EmptyStateView(
                systemImage: "person.2",
                title: "Sin miembros aún",
                message: "Comparte el código de invitación para que entren."
            )
            .padding(.top, RuulSpacing.lg)
        } else {
            VStack(spacing: RuulSpacing.xs) {
                ForEach(coordinator.rows) { row in
                    memberCard(row)
                }
            }
        }
    }

    private func memberCard(_ row: MembersSubTabCoordinator.MemberRow) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            RuulAvatar(name: row.displayName, imageURL: row.avatarURL, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: RuulSpacing.xs) {
                    Text(row.displayName)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    if row.isFounder {
                        rolePill(label: row.roleLabel, color: .ruulWarning)
                    } else if row.roleLabel != "Miembro" {
                        rolePill(label: row.roleLabel, color: .ruulTextSecondary)
                    }
                }
                Text(joinedSubtitle(row.member.joinedAt))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            balancePill(row.netBalanceCents)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private func rolePill(label: String, color: Color) -> some View {
        Text(label.uppercased())
            .ruulTextStyle(RuulTypography.footnote)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func balancePill(_ cents: Int64) -> some View {
        if cents == 0 {
            Text("Sin movimientos")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                RuulMoneyView(
                    amount: Decimal(abs(cents)) / 100,
                    currency: "MXN",
                    size: .small,
                    color: cents > 0 ? .positive : .negative
                )
                Text(cents > 0 ? "a favor" : "a deber")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }

    private func joinedSubtitle(_ joinedAt: Date) -> String {
        "Entró \(joinedAt.ruulRelativeDescription)"
    }
}
