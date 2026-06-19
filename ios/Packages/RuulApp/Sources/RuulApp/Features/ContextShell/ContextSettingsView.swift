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
    @State private var membersStore: MembersStore
    @State private var isShowingEditGeneral = false
    /// D.2 — política bajo edición (nil = crear nueva, no-nil = editar existente).
    @State private var editingPolicy: EditPolicyTarget?
    /// D.3 — sheet de delegación de voto.
    @State private var isShowingDelegate = false
    @State private var runner = ActionRunner()
    /// P1.8 — catálogo declarativo R.7 (solo lectura, informativo).
    @State private var governanceCatalog: [GovernanceCatalogEntry] = []
    /// FE.7 (P1.4) — archivar espacio vía governance.
    @State private var isConfirmingArchive = false
    @State private var archiveClientId = UUID().uuidString
    @State private var archivePendingDecisionId: UUID?
    @State private var archiveRunner = ActionRunner()

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ContextSettingsStore(rpc: container.rpc))
        _governanceStore = State(initialValue: GovernanceStore(rpc: container.rpc))
        _membersStore = State(initialValue: MembersStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .loading:
                    RuulLoadingState()
                case .failed(let message):
                    RuulErrorState(message: message) {
                        Task { await store.load(contextId: context.id) }
                    }
                case .loaded:
                    if let settings = store.settings {
                        settingsList(settings)
                    } else {
                        RuulErrorState(message: "No pudimos cargar la configuración.")
                    }
                }
            }
            .navigationTitle("Configuración del espacio")
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
            await membersStore.load(context: context)
        }
        .refreshable {
            await store.load(contextId: context.id)
            await governanceStore.load(contextId: context.id)
            await membersStore.load(context: context)
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
        .sheet(item: $editingPolicy) { target in
            EditGovernancePolicySheet(
                contextId: context.id,
                initialKey: target.key,
                initialValue: target.value,
                governanceStore: governanceStore
            )
        }
        .sheet(isPresented: $isShowingDelegate) {
            DelegateVoteSheet(
                context: context,
                myActorId: container.currentActorStore.actorId,
                container: container,
                governanceStore: governanceStore
            )
        }
        .actionErrorAlert(runner)
    }

    @ViewBuilder
    private func settingsList(_ settings: ContextSettings) -> some View {
        List {
            generalSection(settings.general)
            membersSection(settings)
            // R.13.A — rolesSection eliminada. Editor granular de roles no
            // implementado; cuando se implemente vuelve al body.
            rulesSection(settings)
            policiesSection(settings)
            invitationsSection(settings.invitationsConfig)
            governanceSection()
            governanceCatalogSection()
            auditSection(settings)
            archiveSection()
        }
        .task { await loadGovernanceCatalog() }
        .confirmationDialog(
            "¿Archivar \(context.displayName)?",
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button("Solicitar archivado", role: .destructive) {
                archiveClientId = UUID().uuidString
                Task { await requestArchiveContext() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El espacio desaparecerá de las listas de todos los miembros; la historia se conserva. Por default requiere votación colectiva.")
        }
        .actionErrorAlert(archiveRunner)
        .sheet(item: Binding(
            get: { archivePendingDecisionId.map { ArchiveDecisionSheetWrapper(id: $0) } },
            set: { archivePendingDecisionId = $0?.id }
        )) { wrapper in
            NavigationStack {
                DecisionDetailView(decisionId: wrapper.id, context: context, container: container)
            }
        }
    }

    // MARK: - FE.7 — Archivar espacio (governance)

    @ViewBuilder
    private func archiveSection() -> some View {
        if store.can("edit_general"), !context.isPersonal {
            Section {
                Button(role: .destructive) {
                    isConfirmingArchive = true
                } label: {
                    Label("Archivar espacio", systemImage: "archivebox")
                }
                .disabled(archiveRunner.isRunning)
            } footer: {
                Text("Acción peligrosa: por default requiere una decisión aprobada por el grupo (política context_archive_requires_vote).")
            }
        }
    }

    /// FE.7 — pide aprobación colectiva para `context.archive` (mismo patrón
    /// que rule.archive). Si la policy `context_archive_requires_vote` está
    /// en `false`, el backend retorna `requires_decision=false` (status
    /// `not_required`) y el iOS dispara `archive_context()` directo. Si la
    /// policy es default/true, se abre la decisión y al aprobarse el trigger
    /// AFTER UPDATE ejecuta `archive_context` vía `_governance_action_dispatch`
    /// (FE.7.B).
    private func requestArchiveContext() async {
        let input = RequestGovernanceActionInput(
            contextActorId: context.id,
            actionKey: "context.archive",
            targetType: "actor",
            targetId: context.id,
            payload: .object([:]),
            title: "Archivar espacio: \(context.displayName)",
            closesAt: nil,
            clientId: archiveClientId
        )
        var capturedDecisionId: UUID?
        var requiresDecision = true
        let success = await archiveRunner.run {
            let result = try await container.rpc.requestGovernanceAction(input)
            capturedDecisionId = result.decisionId
            requiresDecision = result.requiresDecision
            if !result.requiresDecision {
                // Policy en false → ejecutar archive directamente; el backend
                // request_governance_action solo registra la entrada como
                // `not_required` y NO archiva por sí solo.
                _ = try await container.rpc.archiveContext(contextActorId: context.id)
            }
        }
        guard success else { return }
        if requiresDecision, let decisionId = capturedDecisionId {
            archivePendingDecisionId = decisionId
        } else {
            await container.contextStore.load()
            dismiss()
        }
    }

    // MARK: - P1.8 — Qué requiere aprobación (catálogo R.7, read-only)

    @ViewBuilder
    private func governanceCatalogSection() -> some View {
        let voteActions = governanceCatalog.filter(\.defaultRequiresDecision)
        if !voteActions.isEmpty {
            Section {
                ForEach(voteActions) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.dangerous ? "exclamationmark.shield" : "checkmark.shield")
                            .foregroundStyle(entry.dangerous ? Color.red : Color.purple)
                            .frame(width: 22)
                        Text(entry.displayName)
                            .font(.callout)
                        Spacer()
                        Text("Votación")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
                }
            } header: {
                Text("Qué requiere aprobación (\(voteActions.count))")
            } footer: {
                Text("Defaults del sistema. Las políticas de este espacio pueden cambiarlos arriba.")
            }
        }
    }

    private func loadGovernanceCatalog() async {
        guard governanceCatalog.isEmpty else { return }
        governanceCatalog = (try? await container.rpc.listGovernanceActionCatalog()) ?? []
    }

    // MARK: - Gobierno (R.5)

    /// Sección de gobernanza. Lectura: `list_governance_policies`. Escritura:
    /// `create_governance_policy` (upsert + delete cuando value es null), gated
    /// por backend a `decisions.execute`.
    @ViewBuilder
    private func governanceSection() -> some View {
        let canEdit = store.can("decisions.execute")
        Section {
            if governanceStore.policies.isEmpty {
                Text("Sin políticas configuradas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(governanceStore.policies) { policy in
                    Button {
                        guard canEdit else { return }
                        editingPolicy = EditPolicyTarget(key: policy.policyKey, value: policy.policyValue)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.policyKey)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(policyValueSummary(policy.policyValue))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if canEdit {
                            Button("Eliminar", role: .destructive) {
                                Task {
                                    try? await governanceStore.setPolicy(
                                        contextId: context.id,
                                        key: policy.policyKey,
                                        value: .null
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Gobierno")
                Spacer()
                if canEdit {
                    Button {
                        editingPolicy = EditPolicyTarget(key: "", value: .bool(true))
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nueva política de gobernanza")
                }
            }
        } footer: {
            if canEdit {
                Text("Toca una política para editarla. Eliminar = swipe izquierdo.")
            } else {
                Text("Sólo quien tiene autoridad para ejecutar decisiones puede editar políticas.")
            }
        }

        // D.3 — Mi delegación de voto en este contexto.
        myDelegationSection()
    }

    /// Subsección "Mi voto" para delegar/revocar la delegación del caller.
    @ViewBuilder
    private func myDelegationSection() -> some View {
        let myActorId = container.currentActorStore.actorId
        let active = myActorId.flatMap { governanceStore.myActiveDelegation(actorId: $0) }
        let incoming = myActorId.map { governanceStore.incomingDelegationCount(actorId: $0) } ?? 0
        Section {
            if let delegation = active {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delegas tu voto en…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(delegateDisplayName(delegation.delegateActorId))
                        .font(.callout.weight(.medium))
                    if let ends = delegation.endsAt {
                        Text("Vence \(ends.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Sin vencimiento")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)

                Button(role: .destructive) {
                    Task {
                        try? await governanceStore.revokeMyDelegation(contextId: context.id)
                    }
                } label: {
                    Label("Revocar delegación", systemImage: "arrow.uturn.backward")
                }
            } else {
                Text("No has delegado tu voto en este espacio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    isShowingDelegate = true
                } label: {
                    Label("Delegar mi voto", systemImage: "person.crop.circle.badge.checkmark")
                }
            }

            if incoming > 0 {
                Label("\(incoming) \(incoming == 1 ? "persona delega" : "personas delegan") en ti",
                      systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Mi voto")
        } footer: {
            Text("Mientras delegues, tu peso de voto se suma al del delegado en decisiones de este espacio.")
        }
    }

    /// Resuelve el display name del delegado vía MembersStore (cargado en .task).
    /// Fallback a UUID corto si todavía no llegó el roster.
    private func delegateDisplayName(_ actorId: UUID) -> String {
        membersStore.members.first { $0.actorId == actorId }?.displayName
            ?? String(actorId.uuidString.prefix(8))
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

    // MARK: - Políticas (Decisiones · Dinero · Reservaciones)
    //
    // Founder doctrine F.1A-2 mantiene los 3 dominios como sub-grupos lógicos,
    // pero visualmente los plegamos en una sola Section con DisclosureGroups
    // (pattern Apple Settings.app). Wall scroll: ~12 elementos → 3 collapsed
    // labels. El admin abre el dominio que necesita editar.

    @ViewBuilder
    private func policiesSection(_ settings: ContextSettings) -> some View {
        Section("Políticas") {
            DisclosureGroup {
                decisionsRows(settings.decisionsConfig)
            } label: {
                Label("Decisiones", systemImage: "checkmark.bubble")
            }
            DisclosureGroup {
                moneyRows(settings.moneyConfig)
            } label: {
                Label("Dinero", systemImage: "creditcard")
            }
            DisclosureGroup {
                reservationsRows(settings.reservationsConfig)
            } label: {
                Label("Reservaciones", systemImage: "calendar.badge.clock")
            }
        }
    }

    @ViewBuilder
    private func decisionsRows(_ config: ContextDecisionsConfig) -> some View {
        let canEdit = store.can("edit_decisions")
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

    @ViewBuilder
    private func moneyRows(_ config: ContextMoneyConfig) -> some View {
        let canEdit = store.can("edit_money")
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

    @ViewBuilder
    private func reservationsRows(_ config: ContextReservationsConfig) -> some View {
        let canEdit = store.can("edit_reservations")
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
                    TextField("Nombre del espacio", text: $displayName)
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

// MARK: - D.2 Edit governance policy

/// Target del sheet de edición. `key.isEmpty` ⇒ crear nueva.
struct EditPolicyTarget: Identifiable {
    let key: String
    let value: JSONValue
    var id: String { key.isEmpty ? "__new__" : key }
}

/// Sheet para crear/editar una política de gobernanza. UX neutra al policy_key:
/// no hardcodea behaviors. Soporta 4 tipos de valor (Boolean / Number / String /
/// JSON crudo) suficiente para todos los policy_value que R.5 acepta hoy.
private struct EditGovernancePolicySheet: View {
    let contextId: UUID
    let initialKey: String
    let initialValue: JSONValue
    let governanceStore: GovernanceStore

    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var valueKind: ValueKind
    @State private var boolValue: Bool
    @State private var numberText: String
    @State private var stringValue: String
    @State private var jsonText: String
    @State private var runner = ActionRunner()

    enum ValueKind: String, CaseIterable, Identifiable {
        case boolean = "Booleano"
        case number = "Número"
        case string = "Texto"
        case json = "JSON"
        var id: String { rawValue }
    }

    init(contextId: UUID, initialKey: String, initialValue: JSONValue, governanceStore: GovernanceStore) {
        self.contextId = contextId
        self.initialKey = initialKey
        self.initialValue = initialValue
        self.governanceStore = governanceStore
        _key = State(initialValue: initialKey)
        // Inferir kind y valores iniciales del JSONValue actual.
        switch initialValue {
        case .bool(let b):
            _valueKind = State(initialValue: .boolean)
            _boolValue = State(initialValue: b)
            _numberText = State(initialValue: "")
            _stringValue = State(initialValue: "")
            _jsonText = State(initialValue: "")
        case .number(let n):
            _valueKind = State(initialValue: .number)
            _boolValue = State(initialValue: false)
            _numberText = State(initialValue: n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n))
            _stringValue = State(initialValue: "")
            _jsonText = State(initialValue: "")
        case .string(let s):
            _valueKind = State(initialValue: .string)
            _boolValue = State(initialValue: false)
            _numberText = State(initialValue: "")
            _stringValue = State(initialValue: s)
            _jsonText = State(initialValue: "")
        case .null, .array, .object:
            _valueKind = State(initialValue: .json)
            _boolValue = State(initialValue: false)
            _numberText = State(initialValue: "")
            _stringValue = State(initialValue: "")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let text = (try? encoder.encode(initialValue)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            _jsonText = State(initialValue: text)
        }
    }

    private var isEditingExisting: Bool { !initialKey.isEmpty }
    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty && !runner.isRunning && composedValue != nil
    }

    private var composedValue: JSONValue? {
        switch valueKind {
        case .boolean: return .bool(boolValue)
        case .number:
            let trimmed = numberText.trimmingCharacters(in: .whitespaces)
            guard let n = Double(trimmed) else { return nil }
            return .number(n)
        case .string: return .string(stringValue)
        case .json:
            let trimmed = jsonText.trimmingCharacters(in: .whitespaces)
            guard let data = trimmed.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Clave") {
                    TextField("policy_key (ej. quorum, consent_voting)", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isEditingExisting)
                }

                Section("Tipo de valor") {
                    Picker("Tipo", selection: $valueKind) {
                        ForEach(ValueKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Valor") {
                    switch valueKind {
                    case .boolean:
                        Toggle(boolValue ? "true" : "false", isOn: $boolValue)
                    case .number:
                        TextField("Ej. 0.5", text: $numberText)
                            .keyboardType(.decimalPad)
                    case .string:
                        TextField("Texto", text: $stringValue)
                    case .json:
                        TextField("{\"key\":\"value\"}", text: $jsonText, axis: .vertical)
                            .lineLimit(3...10)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.callout, design: .monospaced))
                        if composedValue == nil {
                            Text("JSON inválido")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(isEditingExisting ? "Editar política" : "Nueva política")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .actionErrorAlert(runner)
        }
    }

    private func save() async {
        guard let value = composedValue else { return }
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            try await governanceStore.setPolicy(contextId: contextId, key: trimmedKey, value: value)
        }
        if success { dismiss() }
    }
}

// MARK: - D.3 Delegate vote sheet

/// Sheet para delegar el voto del caller en otro miembro del contexto. Carga
/// el roster vía MembersStore para presentar el picker y, opcionalmente,
/// permite poner fecha de vencimiento.
private struct DelegateVoteSheet: View {
    let context: AppContext
    let myActorId: UUID?
    let container: DependencyContainer
    let governanceStore: GovernanceStore

    @Environment(\.dismiss) private var dismiss
    @State private var membersStore: MembersStore
    @State private var selectedActorId: UUID?
    @State private var hasExpiration = false
    @State private var expirationDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var runner = ActionRunner()

    init(context: AppContext, myActorId: UUID?, container: DependencyContainer, governanceStore: GovernanceStore) {
        self.context = context
        self.myActorId = myActorId
        self.container = container
        self.governanceStore = governanceStore
        _membersStore = State(initialValue: MembersStore(rpc: container.rpc))
    }

    private var candidates: [ContextMember] {
        membersStore.members.filter { $0.actorId != myActorId }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch membersStore.phase {
                case .idle, .loading:
                    RuulLoadingState(title: "Cargando miembros…")
                case .failed(let message):
                    RuulErrorState(message: message) {
                        Task { await membersStore.load(context: context) }
                    }
                case .loaded:
                    form
                }
            }
            .navigationTitle("Delegar mi voto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delegar") { Task { await delegate() } }
                        .disabled(selectedActorId == nil || runner.isRunning)
                }
            }
            .actionErrorAlert(runner)
            .task {
                await membersStore.load(context: context)
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        Form {
            Section {
                if candidates.isEmpty {
                    Text("No hay otros miembros activos a quien delegar.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { member in
                        Button {
                            selectedActorId = member.actorId
                        } label: {
                            HStack {
                                Text(member.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedActorId == member.actorId {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("¿En quién delegas?")
            } footer: {
                Text("Mientras la delegación esté activa, tu peso de voto se suma al del delegado.")
            }

            Section("Vencimiento") {
                Toggle("Poner fecha de vencimiento", isOn: $hasExpiration)
                if hasExpiration {
                    DatePicker("Vence", selection: $expirationDate, in: Date()...)
                        .datePickerStyle(.compact)
                }
            }
        }
    }

    private func delegate() async {
        guard let actorId = selectedActorId else { return }
        let endsAt: Date? = hasExpiration ? expirationDate : nil
        let success = await runner.run {
            try await governanceStore.delegateVote(contextId: context.id, to: actorId, endsAt: endsAt)
        }
        if success { dismiss() }
    }
}


/// FE.7 — wrapper Identifiable para presentar la decisión de archivado.
private struct ArchiveDecisionSheetWrapper: Identifiable {
    let id: UUID
}
