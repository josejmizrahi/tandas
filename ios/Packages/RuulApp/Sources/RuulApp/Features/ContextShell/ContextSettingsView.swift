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
    @State private var governanceStore: GovernanceStore
    @State private var isShowingEditGeneral = false
    @State private var runner = ActionRunner()

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ContextSettingsStore(rpc: container.rpc))
        _governanceStore = State(initialValue: GovernanceStore(rpc: container.rpc))
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
        .task {
            await store.load(contextId: context.id)
            await governanceStore.load(contextId: context.id)
        }
        .refreshable {
            await store.load(contextId: context.id)
            await governanceStore.load(contextId: context.id)
        }
        .sheet(isPresented: $isShowingEditGeneral, onDismiss: {
            Task { await store.load(contextId: context.id) }
        }) {
            if let settings = store.settings {
                EditContextGeneralSheet(
                    contextId: context.id,
                    initial: settings.general,
                    store: store
                )
            }
        }
        .actionErrorAlert(runner)
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
            governanceSection()
            auditSection(settings)
        }
    }

    // MARK: - Gobierno (R.5)

    /// Lista las políticas de gobierno del contexto desde `list_governance_policies`.
    /// Read-only en D.1 (write paths llegan en sub-slices posteriores).
    @ViewBuilder
    private func governanceSection() -> some View {
        Section {
            if governanceStore.policies.isEmpty {
                Text("Sin políticas configuradas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(governanceStore.policies) { policy in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(policy.policyKey)
                            .font(.callout.weight(.medium))
                        Text(policyValueSummary(policy.policyValue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Gobierno")
        } footer: {
            Text("Políticas que rigen el comportamiento del contexto. La edición llega en siguiente slice.")
        }
    }

    /// Renderiza un JSONValue como string compacto para preview en la lista.
    private func policyValueSummary(_ value: JSONValue) -> String {
        switch value {
        case .null: return "—"
        case .bool(let b): return b ? "Sí" : "No"
        case .number(let n):
            return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "(estructurado)"
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

            if store.can("edit_general") {
                Button {
                    isShowingEditGeneral = true
                } label: {
                    Label("Editar general", systemImage: "pencil")
                }
            } else {
                Text("Solo administradores pueden editar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func visibilityLabel(_ raw: String) -> String {
        switch raw {
        case "private": return "Privado"
        case "members": return "Solo miembros"
        case "public":  return "Público"
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
        let canEdit = store.can("edit_decisions")
        Section("Decisiones") {
            configPicker(
                title: "Modo de votación",
                systemImage: "checkmark.square",
                current: config.defaultVotingModel,
                options: [
                    ("yes_no_abstain", "Sí / No / Abstención"),
                    ("single_choice", "Elegir una opción"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setDecisionsConfig(contextId: context.id, ["default_voting_model": .string(newValue)])
            }
            configPicker(
                title: "Quórum",
                systemImage: "person.3",
                current: config.quorum,
                options: [
                    ("simple_majority", "Mayoría simple"),
                    ("two_thirds_majority", "Dos tercios"),
                    ("unanimous", "Unánime"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setDecisionsConfig(contextId: context.id, ["quorum": .string(newValue)])
            }
            configPicker(
                title: "Regla de mayoría",
                systemImage: "percent",
                current: config.majorityRule,
                options: [
                    ("simple", "Simple (>50%)"),
                    ("super", "Superior (>66%)"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setDecisionsConfig(contextId: context.id, ["majority_rule": .string(newValue)])
            }
        }
    }

    /// Helper genérico: HStack(label + Picker) que dispara setter del store.
    @ViewBuilder
    private func configPicker(
        title: String,
        systemImage: String,
        current: String,
        options: [(value: String, label: String)],
        enabled: Bool,
        onChange: @escaping (String) async throws -> Void
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Picker("", selection: Binding<String>(
                get: { current },
                set: { newValue in
                    guard newValue != current, enabled else { return }
                    Task {
                        await runner.run { try await onChange(newValue) }
                    }
                }
            )) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .disabled(!enabled || runner.isRunning)
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
        let canEdit = store.can("edit_money")
        Section("Dinero") {
            configPicker(
                title: "Moneda",
                systemImage: "creditcard",
                current: config.currency,
                options: [
                    ("MXN", "MXN"), ("USD", "USD"), ("EUR", "EUR"),
                    ("ARS", "ARS"), ("CLP", "CLP"), ("COP", "COP"), ("BRL", "BRL"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setMoneyConfig(contextId: context.id, ["currency": .string(newValue)])
            }
            configPicker(
                title: "Split por defecto",
                systemImage: "divide",
                current: config.defaultSplit,
                options: [
                    ("equal", "Parejo"),
                    ("custom", "Personalizado"),
                    ("weighted", "Ponderado"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setMoneyConfig(contextId: context.id, ["default_split": .string(newValue)])
            }
            configPicker(
                title: "Política de settlement",
                systemImage: "calendar.badge.clock",
                current: config.settlementPolicy,
                options: [
                    ("monthly", "Mensual"),
                    ("weekly", "Semanal"),
                    ("on_demand", "A demanda"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setMoneyConfig(contextId: context.id, ["settlement_policy": .string(newValue)])
            }
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
        let canEdit = store.can("edit_reservations")
        Section("Reservaciones") {
            configPicker(
                title: "Prioridad",
                systemImage: "list.number",
                current: config.priorityPolicy,
                options: [
                    ("least_recent_use_wins", "Quien usó hace más tiempo"),
                    ("first_come_first_served", "Primero en llegar"),
                    ("round_robin", "Rotativo"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setReservationsConfig(contextId: context.id, ["priority_policy": .string(newValue)])
            }
            configPicker(
                title: "Resolución de conflictos",
                systemImage: "exclamationmark.triangle",
                current: config.conflictResolution,
                options: [
                    ("community_vote", "Voto comunitario"),
                    ("admin_decides", "Decide admin"),
                    ("auto", "Automático"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setReservationsConfig(contextId: context.id, ["conflict_resolution": .string(newValue)])
            }
            configPicker(
                title: "Cancelación",
                systemImage: "xmark.circle",
                current: config.cancellationPolicy,
                options: [
                    ("open", "Abierta"),
                    ("strict", "Estricta"),
                    ("admin_only", "Solo admin"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setReservationsConfig(contextId: context.id, ["cancellation_policy": .string(newValue)])
            }
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
        let canEdit = store.can("edit_invitations")
        Section("Invitaciones") {
            configPicker(
                title: "Quién puede invitar",
                systemImage: "person.crop.circle.badge.plus",
                current: config.whoCanInvite,
                options: [
                    ("admins", "Solo administradores"),
                    ("members", "Todos los miembros"),
                    ("founder_only", "Solo fundador"),
                ],
                enabled: canEdit
            ) { newValue in
                try await store.setInvitationsConfig(contextId: context.id, ["who_can_invite": .string(newValue)])
            }
            HStack {
                Label("Invitaciones abiertas", systemImage: "link")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { config.openInvites },
                    set: { newValue in
                        guard newValue != config.openInvites, canEdit else { return }
                        Task {
                            await runner.run {
                                try await store.setInvitationsConfig(contextId: context.id, ["open_invites": .bool(newValue)])
                            }
                        }
                    }
                ))
                .labelsHidden()
                .disabled(!canEdit || runner.isRunning)
            }
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

// MARK: - Edit general sheet (F.1A polish)

private struct EditContextGeneralSheet: View {
    let contextId: UUID
    let initial: ContextGeneralSummary
    let store: ContextSettingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var description: String
    @State private var visibility: String
    @State private var runner = ActionRunner()

    init(contextId: UUID, initial: ContextGeneralSummary, store: ContextSettingsStore) {
        self.contextId = contextId
        self.initial = initial
        self.store = store
        _displayName = State(initialValue: initial.displayName)
        _description = State(initialValue: initial.description ?? "")
        _visibility = State(initialValue: initial.visibility ?? "private")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Nombre del contexto", text: $displayName)
                }
                Section("Descripción") {
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Visibilidad") {
                    Picker("Visibilidad", selection: $visibility) {
                        Text("Privado").tag("private")
                        Text("Solo miembros").tag("members")
                        Text("Público").tag("public")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Editar general")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { Task { await save() } }
                        .disabled(!canSave || runner.isRunning)
                }
            }
            .actionErrorAlert(runner)
        }
    }

    private var canSave: Bool {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        return trimmedName != initial.displayName
            || description != (initial.description ?? "")
            || visibility != (initial.visibility ?? "private")
    }

    private func save() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            try await store.setGeneral(
                contextId: contextId,
                displayName: trimmedName != initial.displayName ? trimmedName : nil,
                description: trimmedDesc != (initial.description ?? "") ? trimmedDesc : nil,
                visibility: visibility != (initial.visibility ?? "private") ? visibility : nil
            )
        }
        if success { dismiss() }
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
