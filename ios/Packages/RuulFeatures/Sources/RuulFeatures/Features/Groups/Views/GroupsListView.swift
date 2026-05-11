import SwiftUI
import RuulUI
import RuulCore

/// Root view of the "Grupos" tab post-G2 bottom-nav restructure. Replaces
/// the prior "Inicio" hero (which showed the active group's next event)
/// with an explicit list of every group the user belongs to.
///
/// Tap a card → push GroupTabView (Resumen/Recursos/Dinero/Miembros/Más).
/// The header CTAs cover the two group-level entry points: create a new
/// group from scratch, or join one via invite code.
public struct GroupsListView: View {
    @Environment(AppState.self) private var app
    public let onSelectGroup: (RuulCore.Group) -> Void
    public let onCreateGroup: () -> Void
    public let onJoinGroup: () -> Void

    public init(
        onSelectGroup: @escaping (RuulCore.Group) -> Void,
        onCreateGroup: @escaping () -> Void,
        onJoinGroup: @escaping () -> Void
    ) {
        self.onSelectGroup = onSelectGroup
        self.onCreateGroup = onCreateGroup
        self.onJoinGroup = onJoinGroup
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                    header
                    if app.groups.isEmpty {
                        emptyState
                    } else {
                        groupsSection
                    }
                    quickActions
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
                .padding(.top, RuulSpacing.xs)
                .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Tus grupos")
                .ruulTextStyle(RuulTypography.displayMedium)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(.top, RuulSpacing.md)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12:  return "BUENOS DÍAS"
        case 12..<19: return "BUENAS TARDES"
        default:      return "BUENAS NOCHES"
        }
    }

    // MARK: - Groups list

    private var groupsSection: some View {
        VStack(spacing: RuulSpacing.xs) {
            ForEach(app.groups) { group in
                groupCard(group)
            }
        }
    }

    private func groupCard(_ group: RuulCore.Group) -> some View {
        Button {
            onSelectGroup(group)
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                RuulGroupAvatar(
                    groupName: group.name,
                    initials: group.initials,
                    category: group.category,
                    size: .lg
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    Text(subtitle(for: group))
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for group: RuulCore.Group) -> String {
        let modules = group.effectiveActiveModules
        if modules.isEmpty { return "Grupo nuevo" }
        let humanized = modules.compactMap { humanizeModule($0) }.prefix(3)
        if humanized.isEmpty { return "Grupo nuevo" }
        return humanized.joined(separator: " · ")
    }

    private func humanizeModule(_ id: String) -> String? {
        switch id {
        case "rsvp":           return "Eventos"
        case "check_in":       return "Check-in"
        case "rotating_host":  return "Rotación"
        case "basic_fines":    return "Multas"
        case "slot_assignment": return "Slots"
        case "common_fund":    return "Fondo"
        case "appeal_voting":  return "Votos"
        default:               return nil
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.lg) {
            Spacer(minLength: RuulSpacing.xl)
            ZStack {
                Circle().fill(Color.ruulSurface).frame(width: 80, height: 80)
                Image(systemName: "person.3")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            VStack(spacing: RuulSpacing.xs) {
                Text("Aún no tienes grupos")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Crea uno nuevo o únete con código de invitación.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(spacing: RuulSpacing.sm) {
            RuulButton(
                "Crear grupo",
                systemImage: "plus",
                style: .primary,
                size: .large,
                fillsWidth: true,
                action: onCreateGroup
            )
            RuulButton(
                "Unirme con código",
                systemImage: "qrcode.viewfinder",
                style: .glass,
                size: .large,
                fillsWidth: true,
                action: onJoinGroup
            )
        }
    }
}
