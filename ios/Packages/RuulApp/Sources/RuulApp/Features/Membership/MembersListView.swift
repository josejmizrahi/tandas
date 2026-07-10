import SwiftUI
import RuulCore

/// F.5 — lista de miembros del contexto.
///
/// **R.5V.X (2026-06-09)** — Rebuild Apple-native + Liquid Glass (mismo patrón
/// que MyResourcesView/EventsListView v3):
/// 1. Hero Liquid Glass con count + breakdown por rol (1 founder · 2 admins ·
///    5 miembros · 3 pendientes)
/// 2. `.searchable` para filtrar por nombre / contacto
/// 3. Sections por rol semántico (Fundador / Administradores / Miembros /
///    Pendientes / Observadores) con tints
/// 4. Estados Ruul* (Loading/Error/Empty)
public struct MembersListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: MembersStore
    @State private var isShowingInvite = false
    @State private var query: String = ""
    @State private var reputation: [UUID: MemberReputationSnapshot] = [:]

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: MembersStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando miembros…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }
            case .loaded:
                loadedContent
            }
        }
        .navigationTitle("Miembros")
        .task {
            await store.load(context: context)
            await loadReputation()
        }
        .refreshable {
            await store.load(context: context)
            await loadReputation()
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar {
            if store.canInvite(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingInvite = true
                    } label: {
                        Label("Invitar", systemImage: "person.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingInvite) {
            InviteMembersView(context: context, store: store, container: container)
        }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private var loadedContent: some View {
        if store.members.isEmpty {
            RuulEmptyState(
                title: "Sin miembros",
                systemImage: "person.2",
                message: "Invita a alguien con un código para empezar."
            )
        } else {
            let filtered = filter(store.members)
            let grouped = groupByRole(filtered)
            List {
                heroSection(store.members)
                if !reputation.isEmpty {
                    leaderboardsSection
                }
                ForEach(MemberRole.displayOrder, id: \.self) { role in
                    if let items = grouped[role], !items.isEmpty {
                        Section {
                            ForEach(items) { member in
                                NavigationLink {
                                    MemberDetailView(
                                        member: member,
                                        context: context,
                                        store: store,
                                        myActorId: container.currentActorStore.actorId,
                                        container: container
                                    )
                                } label: {
                                    memberRow(member, role: role)
                                }
                            }
                        } header: {
                            HStack {
                                Label(role.displayName, systemImage: role.symbolName)
                                    .foregroundStyle(Theme.Text.secondary)
                                Spacer()
                                Text("\(items.count)")
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
                if grouped.isEmpty {
                    Section {
                        Text("Sin coincidencias con \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar miembro")
            .searchToolbarBehavior(.minimize)
        }
    }

    // MARK: - Hero (Liquid Glass)

    @ViewBuilder
    private func heroSection(_ members: [ContextMember]) -> some View {
        let byRole = Dictionary(grouping: members, by: { MemberRole.from($0) })
        let breakdown = MemberRole.displayOrder.compactMap { role -> (MemberRole, Int)? in
            guard let count = byRole[role]?.count, count > 0 else { return nil }
            return (role, count)
        }
        // R.17 — mismo lenguaje que el hero de Dinero: typography prominente
        // plana, etiqueta semántica y botón de acción prominente. Sin glass
        // flotante (el card anterior se sentía como widget pegado).
        let canInvite = store.canInvite(in: context)
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Tu grupo", systemImage: "person.3.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Tint.primary)
                    Text(members.count == 1 ? "1 persona" : "\(members.count) personas")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.Text.primary)
                }
                if breakdown.count > 1 {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(breakdown, id: \.0) { role, count in
                            roleChip(role, count: count)
                        }
                    }
                }
                if canInvite {
                    Button {
                        isShowingInvite = true
                    } label: {
                        Label("Invitar amigos", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .ruulHeroRow()
        }
    }

    @ViewBuilder
    private func roleChip(_ role: MemberRole, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: role.symbolName)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(role.tint)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(role.tint.opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Member row

    @ViewBuilder
    private func memberRow(_ member: ContextMember, role: MemberRole) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: member.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    if member.actorId == container.currentActorStore.actorId {
                        Text("(tú)")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
                Text(memberSubtitle(member))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let snapshot = reputation[member.actorId], role != .pending, role != .invited {
                reputationBadge(snapshot)
            } else {
                switch role {
                case .pending:
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityLabel("Pendiente de unirse (sin app)")
                case .invited:
                    // R.5Z.fix.3 — distingue del placeholder con clock con icono de sobre.
                    Image(systemName: "envelope.badge.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Tint.warning)
                        .accessibilityLabel("Invitación pendiente de aceptar")
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func reputationBadge(_ snapshot: MemberReputationSnapshot) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(snapshot.score)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(snapshot.tint)
            Text("score")
                .font(.caption2)
                .foregroundStyle(Theme.Text.tertiary)
        }
        .accessibilityLabel("Score estimado \(snapshot.score)")
    }

    // MARK: - Reputation + leaderboards

    private var leaderboardsSection: some View {
        let snapshots = reputation.values
            .filter { !$0.member.isPlaceholder && !$0.member.isInvited }
        let fame = snapshots
            .filter { $0.hasSignals }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.member.displayName < rhs.member.displayName
            }
            .prefix(3)
        let shame = snapshots
            .filter { $0.shamePoints > 0 }
            .sorted { lhs, rhs in
                if lhs.shamePoints != rhs.shamePoints { return lhs.shamePoints > rhs.shamePoints }
                return lhs.member.displayName < rhs.member.displayName
            }
            .prefix(3)

        return Section {
            if fame.isEmpty && shame.isEmpty {
                Label("Aún no hay señales suficientes", systemImage: "chart.bar.doc.horizontal")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(Array(fame)) { snapshot in
                    ReputationLeaderboardRow(
                        title: snapshot.member.displayName,
                        subtitle: snapshot.bestSignal,
                        value: "\(snapshot.score)",
                        systemImage: "trophy.fill",
                        tint: Theme.Tint.success
                    )
                }
                ForEach(Array(shame)) { snapshot in
                    ReputationLeaderboardRow(
                        title: snapshot.member.displayName,
                        subtitle: snapshot.riskSignal,
                        value: "\(snapshot.shamePoints)",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Theme.Tint.warning
                    )
                }
            }
        } header: {
            Text("Reputación")
        } footer: {
            Text("Score estimado con asistencia, organización, pagos, multas y actividad reciente. El ranking definitivo debe venir del backend.")
        }
    }

    private func loadReputation() async {
        reputation = await MemberReputationBuilder.load(
            context: context,
            members: store.members,
            rpc: container.rpc
        )
    }

    /// R.5W — Subtítulo unificado. Placeholders muestran su contacto +
    /// "Pendiente de unirse"; registered members muestran fecha de unión.
    /// R.5Z.fix.3 — invitados (registered no-placeholders status='invited')
    /// muestran "Esperando que acepte".
    private func memberSubtitle(_ member: ContextMember) -> String {
        if member.isPlaceholder {
            let contact = member.contactPhone?.nilIfEmpty
                ?? member.contactEmail?.nilIfEmpty
            if let contact {
                return "\(contact) · Pendiente de unirse"
            }
            return "Pendiente de unirse"
        }
        if member.isInvited {
            return "Esperando que acepte la invitación"
        }
        if let joined = member.joinedAt {
            return "Desde \(joined.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Miembro"
    }

    // MARK: - Filter + group

    private func filter(_ members: [ContextMember]) -> [ContextMember] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter { m in
            m.displayName.lowercased().contains(q)
                || (m.contactEmail?.lowercased().contains(q) ?? false)
                || (m.contactPhone?.lowercased().contains(q) ?? false)
        }
    }

    private func groupByRole(_ members: [ContextMember]) -> [MemberRole: [ContextMember]] {
        Dictionary(grouping: members, by: { MemberRole.from($0) })
            .mapValues { $0.sorted { $0.displayName < $1.displayName } }
    }
}

// MARK: - MemberRole (grouping helper)

private enum MemberRole: String, CaseIterable, Hashable {
    case founder, admin, member, invited, pending, guest, viewer

    static let displayOrder: [MemberRole] = [.founder, .admin, .member, .invited, .pending, .guest, .viewer]

    static func from(_ member: ContextMember) -> MemberRole {
        // R.5Z.fix.3 — invited (registered users pre-accept) → role dedicado.
        // Placeholder pendientes de claim siguen siendo `.pending`.
        if member.isInvited && !member.isPlaceholder { return .invited }
        if member.isPlaceholder { return .pending }
        if member.isFounder { return .founder }
        if member.isAdmin { return .admin }
        switch member.membershipType {
        case "guest":  return .guest
        case "viewer": return .viewer
        default:       return .member
        }
    }

    var displayName: String {
        switch self {
        case .founder:  return "Fundador"
        case .admin:    return "Administradores"
        case .member:   return "Miembros"
        case .invited:  return "Invitados pendientes"
        case .pending:  return "Sin app"
        case .guest:    return "Invitados"
        case .viewer:   return "Observadores"
        }
    }

    var symbolName: String {
        switch self {
        case .founder:  return "crown.fill"
        case .admin:    return "person.badge.shield.checkmark"
        case .member:   return "person.fill"
        case .invited:  return "envelope.fill"
        case .pending:  return "clock.fill"
        case .guest:    return "person.crop.circle.dashed"
        case .viewer:   return "eye.fill"
        }
    }

    var tint: Color {
        switch self {
        case .founder:  return .purple
        case .admin:    return Theme.Tint.info
        case .member:   return Theme.Tint.primary
        case .invited:  return Theme.Tint.warning
        case .pending:  return Theme.Tint.warning
        case .guest:    return Theme.Text.secondary
        case .viewer:   return Theme.Text.tertiary
        }
    }
}

// MARK: - Reputation presentation

private struct ReputationLeaderboardRow: View {
    let title: String
    let subtitle: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(value)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview("Miembros") {
    NavigationStack {
        MembersListView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
