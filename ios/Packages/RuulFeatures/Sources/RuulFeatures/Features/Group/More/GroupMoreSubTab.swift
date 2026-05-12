import SwiftUI
import RuulUI
import RuulCore

/// "Más" sub-tab — humanized entry point to the governance surfaces
/// that used to live as top-level Group sub-tabs (Reglas / Votos / Multas).
/// Post-G1 the Group's siblings are user-facing concerns (Overview /
/// Resources / Money / Más); governance is one layer deeper.
///
/// Each row is a NavigationLink-equivalent that fires a callback the
/// parent (MainTabView's groupTab stack) translates into a push.
public struct GroupMoreSubTab: View {
    public let openVotesCount: Int
    public let outstandingFinesCount: Int
    public let onOpenRules: () -> Void
    public let onOpenVotes: () -> Void
    public let onOpenFines: () -> Void
    /// Opens `GroupRulesSettingsView` — the preset picker for governance
    /// policies (Casual / Equilibrado / Estricto). Lives under "Más" so
    /// changing how decisions are taken is one tap from the group home,
    /// not buried behind the Inicio header icon.
    public let onOpenGroupRules: () -> Void

    public init(
        openVotesCount: Int,
        outstandingFinesCount: Int,
        onOpenRules: @escaping () -> Void,
        onOpenVotes: @escaping () -> Void,
        onOpenFines: @escaping () -> Void,
        onOpenGroupRules: @escaping () -> Void
    ) {
        self.openVotesCount = openVotesCount
        self.outstandingFinesCount = outstandingFinesCount
        self.onOpenRules = onOpenRules
        self.onOpenVotes = onOpenVotes
        self.onOpenFines = onOpenFines
        self.onOpenGroupRules = onOpenGroupRules
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                groupRulesSection
                operationsSection
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
    }

    /// Group-level governance — the social system. Permissions, decisions,
    /// money, visibility, defaults. Doctrine: lives ABOVE behaviors because
    /// it gobierna how the group itself works, not any one resource. See
    /// memory/project_group_governance_rules.md.
    private var groupRulesSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("REGLAS DEL GRUPO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.horizontal, RuulSpacing.xxs)
            VStack(spacing: 0) {
                row(icon: "building.columns.fill",
                    label: "Gobierno del grupo",
                    sublabel: "Permisos, decisiones, dinero, invitados",
                    trailing: { EmptyView() },
                    action: onOpenGroupRules)
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    /// Day-to-day operation surfaces: the behavior rules (acuerdos), votes
    /// in flight, fines outstanding. These describe specific things — they
    /// are NOT group governance. Renamed from "GOBERNANZA" because Acuerdos
    /// is behavior (resource rules), not governance.
    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("DÍA A DÍA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.horizontal, RuulSpacing.xxs)
            VStack(spacing: 0) {
                row(icon: "list.bullet.clipboard.fill",
                    label: "Acuerdos",
                    sublabel: "Cómo se comporta el grupo: multas, llegadas, RSVP",
                    trailing: { EmptyView() },
                    action: onOpenRules)
                divider
                row(icon: "hand.raised.fill",
                    label: "Decisiones abiertas",
                    sublabel: votesSublabel,
                    trailing: { badgeIfNonZero(openVotesCount, color: .ruulWarning) },
                    action: onOpenVotes)
                divider
                row(icon: "exclamationmark.triangle.fill",
                    label: "Sanciones",
                    sublabel: finesSublabel,
                    trailing: { badgeIfNonZero(outstandingFinesCount, color: .ruulNegative) },
                    action: onOpenFines)
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private var votesSublabel: String {
        switch openVotesCount {
        case 0: return "Sin votaciones abiertas"
        case 1: return "1 votación abierta"
        default: return "\(openVotesCount) votaciones abiertas"
        }
    }

    private var finesSublabel: String {
        switch outstandingFinesCount {
        case 0: return "Sin multas pendientes"
        case 1: return "1 multa pendiente"
        default: return "\(outstandingFinesCount) multas pendientes"
        }
    }

    @ViewBuilder
    private func badgeIfNonZero(_ count: Int, color: Color) -> some View {
        if count > 0 {
            Text("\(count)")
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextInverse)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(color, in: Capsule())
        }
    }

    private func row<T: View>(
        icon: String,
        label: String,
        sublabel: String,
        @ViewBuilder trailing: () -> T,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.ruulTextSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(sublabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, 56)
    }
}
