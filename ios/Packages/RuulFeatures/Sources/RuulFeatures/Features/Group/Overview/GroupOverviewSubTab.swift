import SwiftUI
import RuulUI
import RuulCore

/// Group "home" — the most important screen post-G1. Answers the user's
/// four questions every time they open the app:
///
///   1. ¿Qué sigue?           → "Próximamente" section
///   2. ¿Qué debo hacer?      → "Necesita atención" section
///   3. ¿Qué recursos hay?    → "Recursos activos" section
///   4. ¿Qué acaba de pasar?  → "Actividad reciente" section
///
/// Above all that sits a thin hero with the group's identity + meta. The
/// page is action-oriented: every section's rows are tappable and route
/// the user to where the action lives (event detail, fine detail, rule
/// detail, resource detail, money sub-tab).
public struct GroupOverviewSubTab: View {
    @Environment(AppState.self) private var app
    public let group: RuulCore.Group
    public let inboxCoordinator: InboxCoordinator?
    public let userId: UUID
    public let onOpenInboxAction: (UserAction) async -> Void
    public let onGoToMoney: () -> Void
    /// Salto al sub-tab Recursos. nil ⇒ chip oculta. Resumen es dashboard;
    /// el catálogo completo vive en Recursos — la chip de Acceso rápido
    /// solo es el linkout.
    public let onJumpToResources: (() -> Void)?
    /// Salto al sub-tab Miembros. nil ⇒ chip oculta.
    public let onJumpToMembers: (() -> Void)?

    @State private var resources: [ResourceRow] = []
    @State private var isLoading: Bool = true
    @State private var memberCount: Int = 0
    /// Resolved `template.name` for the active group's `baseTemplate`.
    /// Loaded async because `TemplateRegistry.template(id:)` is actor-
    /// isolated. nil while loading or when the group has no preset.
    @State private var templateName: String?

    public init(
        group: RuulCore.Group,
        inboxCoordinator: InboxCoordinator?,
        userId: UUID,
        onOpenInboxAction: @escaping (UserAction) async -> Void,
        onGoToMoney: @escaping () -> Void,
        onJumpToResources: (() -> Void)? = nil,
        onJumpToMembers: (() -> Void)? = nil
    ) {
        self.group = group
        self.inboxCoordinator = inboxCoordinator
        self.userId = userId
        self.onOpenInboxAction = onOpenInboxAction
        self.onGoToMoney = onGoToMoney
        self.onJumpToResources = onJumpToResources
        self.onJumpToMembers = onJumpToMembers
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                summaryBlock
                attentionSection
                quickAccessRow
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
    }

    // MARK: - Summary block (stat-driven, mirrors ResourceSummaryView spec)

    /// KPI grid + active-modules chips + meta line. Sin identity row aquí:
    /// el `RuulGroupSwitcher` en el header de Grupo ya muestra avatar +
    /// nombre + categoría — duplicarlo aquí era ruido. Resumen es dashboard,
    /// no portada.
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            kpiGrid
            if !activeModuleChips.isEmpty {
                modulesChipsRow
            }
            metaLine
        }
        .padding(.top, RuulSpacing.xs)
    }

    // KPI tiles — capability-style: each computed independently from
    // available data, only shown if it's meaningful (skips zero-valued).

    private struct KPITile: Identifiable, Hashable {
        let id: String
        let icon: String
        let label: String
        let value: String
    }

    private var kpiTiles: [KPITile] {
        var tiles: [KPITile] = []

        // Miembros — always show if loaded
        if memberCount > 0 {
            tiles.append(KPITile(
                id: "members",
                icon: "person.2.fill",
                label: "Miembros",
                value: "\(memberCount)"
            ))
        }

        // Recursos activos (non-event polymorphic resources + events)
        if !resources.isEmpty {
            tiles.append(KPITile(
                id: "resources",
                icon: "square.stack.3d.up.fill",
                label: "Recursos",
                value: "\(resources.count)"
            ))
        }

        // Próximos — polimórfico, deriva de `resources` (no del array de
        // `upcomingEvents`). Cualquier resource con metadata time-bound
        // (`starts_at`, `due_at`, `deadline_at`, `next_at`) en el futuro
        // cuenta aquí, no sólo eventos.
        let upcomingCount = upcomingResources.count
        if upcomingCount > 0 {
            tiles.append(KPITile(
                id: "upcoming",
                icon: "calendar",
                label: "Por venir",
                value: "\(upcomingCount)"
            ))
        }

        // Pendientes (NecesitaAtención count for THIS group)
        let pendingCount = (inboxCoordinator?.actions ?? [])
            .filter { $0.groupId == group.id }.count
        if pendingCount > 0 {
            tiles.append(KPITile(
                id: "pending",
                icon: "bell.badge.fill",
                label: "Pendientes",
                value: "\(pendingCount)"
            ))
        }

        return tiles
    }

    @ViewBuilder
    private var kpiGrid: some View {
        let tiles = kpiTiles
        if !tiles.isEmpty {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: RuulSpacing.sm), count: 2),
                spacing: RuulSpacing.sm
            ) {
                ForEach(tiles) { tile in
                    kpiCard(tile)
                }
            }
        }
    }

    private func kpiCard(_ tile: KPITile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tile.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(tile.label.uppercased())
                    .font(.ruulMicro.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .lineLimit(1)
            }
            Text(tile.value)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, RuulSpacing.sm)
        .padding(.horizontal, RuulSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(Color.ruulSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    // Active modules chips — human-readable names from ModuleRegistry.

    private var activeModuleChips: [(id: String, label: String)] {
        let active = group.activeModules ?? []
        let resolved = app.moduleRegistry.resolve(ids: active)
        return resolved.map { ($0.id, $0.name) }
    }

    private var modulesChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(activeModuleChips, id: \.id) { chip in
                    Text(chip.label)
                        .font(.ruulCaption.weight(.medium))
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.ruulSurface))
                        .overlay(Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: RuulSpacing.xs) {
            if let templateName = templateName {
                Text(templateName)
                Text("·")
            }
            Text("Creado \(relativeFormatter.localizedString(for: group.createdAt, relativeTo: .now))")
            Spacer(minLength: 0)
        }
        .font(.ruulCaption)
        .foregroundStyle(Color.ruulTextTertiary)
    }

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .full
        return f
    }()

    // MARK: - Necesita atención (top 3 + linkout)

    /// Lo más urgente de este grupo, en versión compacta. Resumen no es
    /// el inbox completo — para eso está el badge del tab Inicio (cross-
    /// group) o el deep list. Top 3 + "Ver todas (N)" → al final delega
    /// al tab Inicio que es el inbox completo.
    @ViewBuilder
    private var attentionSection: some View {
        let actions = (inboxCoordinator?.actions ?? []).filter { $0.groupId == group.id }
        if !actions.isEmpty {
            sectionHeader(title: "NECESITA ATENCIÓN", count: actions.count)
            VStack(spacing: RuulSpacing.xs) {
                ForEach(actions.prefix(3)) { action in
                    ActionCard(
                        icon: pendingIcon(for: action.actionType),
                        meta: action.createdAt.ruulRelativeDescription,
                        title: action.title,
                        subtitle: action.body,
                        priority: pendingPriority(for: action.priority),
                        timeRemaining: nil,
                        onTap: { Task { await onOpenInboxAction(action) } }
                    )
                }
                if actions.count > 3 {
                    Button {
                        // Linkout al inbox completo. El badge del tab Inicio
                        // ya muestra el cross-group total — al tapear "ver
                        // todas" subimos al feed donde el user filtra.
                        Task { if let first = actions.first { await onOpenInboxAction(first) } }
                    } label: {
                        HStack {
                            Text("Ver todas (\(actions.count))")
                                .ruulTextStyle(RuulTypography.callout)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.ruulTextTertiary)
                        }
                        .padding(RuulSpacing.md)
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .stroke(Color.ruulSeparator, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Acceso rápido (chips a sub-tabs hermanas)

    /// Chips horizontales a las otras sub-tabs hermanas. Resumen es la
    /// vista de aterrizaje; debe servir de despachador. Sin duplicar
    /// listas: el usuario tappea la chip y aterriza en la sub-tab que
    /// hace ese trabajo a fondo.
    private var quickAccessRow: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("ACCESO RÁPIDO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.horizontal, RuulSpacing.xxs)
            HStack(spacing: RuulSpacing.xs) {
                quickAccessChip(icon: "square.stack.3d.up.fill", label: "Recursos") {
                    onJumpToResources?()
                }
                quickAccessChip(icon: "banknote.fill", label: "Dinero") {
                    onGoToMoney()
                }
                quickAccessChip(icon: "person.2.fill", label: "Miembros") {
                    onJumpToMembers?()
                }
            }
        }
    }

    private func quickAccessChip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(label)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func pendingIcon(for type: ActionType) -> String {
        switch type {
        case .finePending:             return "exclamationmark.triangle.fill"
        case .fineVoided:              return "xmark.circle"
        case .appealVotePending:       return "hand.raised.fill"
        case .rsvpPending:             return "checkmark.circle.fill"
        case .fineProposalReview:      return "doc.text.magnifyingglass"
        case .ruleChangeApplyPending:  return "list.bullet.clipboard.fill"
        case .hostAssigned:            return "person.crop.circle.badge.checkmark"
        case .slotPending:             return "ticket.fill"
        case .votePending:             return "hand.raised.fill"
        case .contributionDue:         return "banknote.fill"
        case .compensationDue:         return "arrow.up.right"
        }
    }

    private func pendingPriority(for raw: ActionPriority) -> ActionCard.Priority {
        switch raw {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        case .urgent: return .urgent
        }
    }

    // MARK: - Próximamente — POLYMORPHIC, resource-driven
    //
    // Derives "upcoming" from `resources` using a polymorphic time-bound
    // metadata lookup. Any Resource (event, slot, booking, contribution,
    // …) that exposes a future date in one of the canonical keys lands
    // here, sorted ASC. Memoria `feedback_no_hardcoded_verticals` +
    // `project_resource_detail_capability_driven`: never branch by
    // `resource_type` in the view layer.

    /// Resources whose time-bound metadata points to a future moment.
    /// Sorted ascending by that moment so the nearest one comes first.
    private var upcomingResources: [(row: ResourceRow, at: Date)] {
        resources.compactMap { row -> (row: ResourceRow, at: Date)? in
            guard let at = nextAt(for: row), at > .now else { return nil }
            return (row, at)
        }
        .sorted { $0.at < $1.at }
    }

    /// Pulls the next-occurrence date from a resource's metadata. Tries
    /// the canonical keys in priority order: `starts_at` (events / slots /
    /// bookings) → `due_at` (contributions) → `deadline_at` (votes,
    /// limit-bound resources) → `next_at` (generic). Accepts both snake_
    /// and camelCase. Returns nil when none parse to a Date.
    private func nextAt(for row: ResourceRow) -> Date? {
        let keys = ["starts_at", "startsAt", "due_at", "dueAt", "deadline_at", "deadlineAt", "next_at", "nextAt"]
        for key in keys {
            if case let .string(s)? = row.metadata[key],
               let date = isoFormatter.date(from: s) {
                return date
            }
        }
        return nil
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Section header

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Spacer()
            Text("\(count)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    // MARK: - Load

    @MainActor
    private func load(force: Bool) async {
        if force || resources.isEmpty {
            do {
                let types: [ResourceType] = [.event, .asset, .slot, .fund, .space, .right]
                resources = try await app.resourceRepo.list(
                    in: group.id,
                    types: types,
                    statuses: nil,
                    limit: 50
                )
            } catch {
                resources = []
            }
        }
        if force || memberCount == 0 {
            let mwps = (try? await app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
            memberCount = mwps.count
        }
        if force || templateName == nil {
            if let templateId = group.baseTemplate,
               let template = await app.templateRegistry.template(id: templateId) {
                templateName = template.name
            }
        }
        isLoading = false
    }
}
