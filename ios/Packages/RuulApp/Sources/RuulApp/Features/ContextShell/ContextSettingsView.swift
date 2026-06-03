import SwiftUI
import RuulCore

/// F.1A-2 — Configuración del contexto. 10 secciones doctrinales:
/// General · Miembros · Roles · Reglas · Decisiones · Dinero · Reservaciones
/// · Invitaciones · Auditoría. Las que ya tienen pantalla dedicada (Miembros,
/// Reglas) se linkean; el resto muestra estado actual + "próximamente".
public struct ContextSettingsView: View {
    let context: AppContext
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var store: ContextSettingsStore

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ContextSettingsStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .loading:
                    LoadingStateView()
                case .failed(let message):
                    ErrorStateView(message: message) {
                        Task { await store.load(contextId: context.id) }
                    }
                case .loaded:
                    if let settings = store.settings {
                        settingsList(settings)
                    } else {
                        ErrorStateView(message: "No pudimos cargar la configuración.")
                    }
                }
            }
            .navigationTitle("Configuración del contexto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .task { await store.load(contextId: context.id) }
        .refreshable { await store.load(contextId: context.id) }
    }

    @ViewBuilder
    private func settingsList(_ settings: ContextSettings) -> some View {
        List {
            generalSection(settings.general)
            membersSection(settings)
            rolesSection(settings)
            rulesSection(settings)
            decisionsSection(settings.decisionsConfig)
            moneySection(settings.moneyConfig)
            reservationsSection(settings.reservationsConfig)
            invitationsSection(settings.invitationsConfig)
            auditSection(settings)
        }
    }

    // MARK: - General

    @ViewBuilder
    private func generalSection(_ general: ContextGeneralSummary) -> some View {
        Section("General") {
            HStack(spacing: 12) {
                Image(systemName: context.symbolName)
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(general.displayName).font(.headline)
                    if let subtype = general.subtype { Text(subtype.capitalized).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if let description = general.description, !description.isEmpty {
                Text(description).font(.body)
            }

            InfoRow(symbolName: "person.3", title: "Miembros", value: "\(general.memberCount)")
            if let visibility = general.visibility {
                InfoRow(symbolName: "eye", title: "Visibilidad", value: visibilityLabel(visibility))
            }

            if !store.can("edit_general") {
                Text("Solo administradores pueden editar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Edición inline llega en una próxima versión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func visibilityLabel(_ raw: String) -> String {
        switch raw {
        case "private": return "Privado"
        case "public":  return "Público"
        case "members_in_common": return "Miembros en común"
        default:        return raw.capitalized
        }
    }

    // MARK: - Miembros

    @ViewBuilder
    private func membersSection(_ settings: ContextSettings) -> some View {
        Section("Miembros") {
            NavigationLink {
                MembersListView(context: context, container: container)
            } label: {
                Label("Ver y administrar miembros", systemImage: "person.3.fill")
            }
            if !store.can("manage_members") {
                Text("Solo administradores pueden invitar, suspender o expulsar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Roles

    @ViewBuilder
    private func rolesSection(_ settings: ContextSettings) -> some View {
        Section("Roles") {
            InfoRow(symbolName: "shield.lefthalf.filled",
                    title: "Roles del contexto",
                    value: store.can("manage_roles") ? "Editable próximamente" : "Solo lectura")
            Text("Creación y asignación granular de roles llega en una próxima versión.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reglas

    @ViewBuilder
    private func rulesSection(_ settings: ContextSettings) -> some View {
        Section("Reglas") {
            NavigationLink {
                RulesListView(context: context, container: container)
            } label: {
                Label("Reglas, automatizaciones y políticas", systemImage: "scroll")
            }
        }
    }

    // MARK: - Decisiones

    @ViewBuilder
    private func decisionsSection(_ config: ContextDecisionsConfig) -> some View {
        Section("Decisiones") {
            InfoRow(symbolName: "checkmark.square", title: "Modo de votación", value: votingModelLabel(config.defaultVotingModel))
            InfoRow(symbolName: "person.3", title: "Quórum", value: quorumLabel(config.quorum))
            InfoRow(symbolName: "percent", title: "Regla de mayoría", value: majorityLabel(config.majorityRule))
            if store.can("edit_decisions") {
                Text("Configuración inline llega después.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func votingModelLabel(_ raw: String) -> String {
        VotingModel(rawValue: raw)?.label ?? raw
    }

    private func quorumLabel(_ raw: String) -> String {
        switch raw {
        case "simple_majority": return "Mayoría simple"
        case "two_thirds":      return "Dos tercios"
        case "unanimous":       return "Unánime"
        default:                return raw
        }
    }

    private func majorityLabel(_ raw: String) -> String {
        switch raw {
        case "simple": return "Simple (>50%)"
        case "super":  return "Superior (>66%)"
        default:       return raw
        }
    }

    // MARK: - Dinero

    @ViewBuilder
    private func moneySection(_ config: ContextMoneyConfig) -> some View {
        Section("Dinero") {
            InfoRow(symbolName: "creditcard", title: "Moneda", value: config.currency)
            InfoRow(symbolName: "divide", title: "Split por defecto", value: splitLabel(config.defaultSplit))
            InfoRow(symbolName: "calendar.badge.clock", title: "Política de settlement", value: settlementLabel(config.settlementPolicy))
        }
    }

    private func splitLabel(_ raw: String) -> String {
        switch raw {
        case "equal":    return "Parejo"
        case "custom":   return "Personalizado"
        case "weighted": return "Ponderado"
        default:         return raw
        }
    }

    private func settlementLabel(_ raw: String) -> String {
        switch raw {
        case "monthly":  return "Mensual"
        case "weekly":   return "Semanal"
        case "on_demand": return "A demanda"
        default:         return raw
        }
    }

    // MARK: - Reservaciones

    @ViewBuilder
    private func reservationsSection(_ config: ContextReservationsConfig) -> some View {
        Section("Reservaciones") {
            InfoRow(symbolName: "list.number", title: "Prioridad", value: priorityLabel(config.priorityPolicy))
            InfoRow(symbolName: "exclamationmark.triangle", title: "Resolución de conflictos", value: conflictLabel(config.conflictResolution))
            InfoRow(symbolName: "xmark.circle", title: "Cancelación", value: config.cancellationPolicy.capitalized)
        }
    }

    private func priorityLabel(_ raw: String) -> String {
        switch raw {
        case "least_recent_use_wins": return "Quien usó hace más tiempo"
        case "first_come_first_serve": return "Primero llega, primero recibe"
        case "round_robin":            return "Rotativo"
        default:                       return raw
        }
    }

    private func conflictLabel(_ raw: String) -> String {
        switch raw {
        case "community_vote": return "Voto comunitario"
        case "admin_decides":  return "Decide admin"
        case "auto":           return "Automático"
        default:               return raw
        }
    }

    // MARK: - Invitaciones

    @ViewBuilder
    private func invitationsSection(_ config: ContextInvitationsConfig) -> some View {
        Section("Invitaciones") {
            InfoRow(symbolName: "person.crop.circle.badge.plus", title: "Quién puede invitar", value: whoCanInviteLabel(config.whoCanInvite))
            InfoRow(symbolName: "link",
                    title: "Invitaciones abiertas",
                    value: config.openInvites ? "Activadas" : "Solo links manuales")
        }
    }

    private func whoCanInviteLabel(_ raw: String) -> String {
        switch raw {
        case "admins":          return "Solo administradores"
        case "members":         return "Todos los miembros"
        case "founder_only":    return "Solo fundador"
        default:                return raw
        }
    }

    // MARK: - Auditoría

    @ViewBuilder
    private func auditSection(_ settings: ContextSettings) -> some View {
        Section("Auditoría") {
            NavigationLink {
                ActivityFeedView(context: context, container: container)
            } label: {
                Label("Timeline de actividad", systemImage: "clock.arrow.circlepath")
            }
            if store.can("view_audit") {
                Text("Cambios críticos e historial completo llegan después.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Context Settings") {
    ContextSettingsView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi",
            roles: ["admin"]
        ),
        container: .demo()
    )
}
