import SwiftUI
import RuulCore

/// F.1A-3 — Configuración de un recurso. Capability-gated:
/// las secciones de policy (Reservable/Monetary/Beneficiarios/Documentos) solo
/// se renderizan si `capabilities` incluye la capability. Acceso restringido a
/// OWN/MANAGE — el backend lo enforça; este view confía en available_actions.
public struct ResourceSettingsView: View {
    let resourceId: UUID
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var store: ResourceSettingsStore
    @State private var isShowingEditGeneral = false
    @State private var isShowingTransfer = false
    @State private var runner = ActionRunner()
    /// R.RES.POLICY.D.UI — state para el editor del override de reservation_policy.
    @State private var isShowingEditPolicy = false
    @State private var resourceForPolicy: Resource?
    @State private var subtypeDefaultPolicy: ReservationPolicy?
    @State private var currentOverridePolicy: ReservationPolicy?

    public init(resourceId: UUID, container: DependencyContainer) {
        self.resourceId = resourceId
        self.container = container
        _store = State(initialValue: ResourceSettingsStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .loading:
                    RuulLoadingState()
                case .failed(let message):
                    RuulErrorState(message: message) {
                        Task { await store.load(resourceId: resourceId) }
                    }
                case .loaded:
                    if let settings = store.settings {
                        settingsList(settings)
                    } else {
                        RuulErrorState(message: "No pudimos cargar la configuración.")
                    }
                }
            }
            .navigationTitle("Configuración del recurso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .task { await store.load(resourceId: resourceId) }
        .refreshable { await store.load(resourceId: resourceId) }
        .sheet(isPresented: $isShowingEditGeneral, onDismiss: {
            Task { await store.load(resourceId: resourceId) }
        }) {
            if let settings = store.settings {
                EditResourceGeneralSheet(
                    resourceId: resourceId,
                    initial: settings.general,
                    store: store
                )
            }
        }
        .sheet(isPresented: $isShowingTransfer, onDismiss: {
            Task { await store.load(resourceId: resourceId) }
        }) {
            TransferOwnershipSheet(resourceId: resourceId, container: container)
        }
        // R.RES.POLICY.D.UI — sheet del editor de policy override.
        .sheet(isPresented: $isShowingEditPolicy, onDismiss: {
            Task { await loadPolicyContext() }
        }) {
            if let resource = resourceForPolicy, let subtypeDefault = subtypeDefaultPolicy {
                EditReservationPolicyOverrideSheet(
                    resource: resource,
                    subtypeDefault: subtypeDefault,
                    currentOverride: currentOverridePolicy,
                    container: container,
                    onSaved: {
                        Task { await store.load(resourceId: resourceId) }
                    }
                )
            }
        }
        .actionErrorAlert(runner)
        .task { await loadPolicyContext() }
    }

    /// R.RES.POLICY.D.UI — fetch del Resource completo + subtype default +
    /// override actual. Llamado on appear y después de save.
    private func loadPolicyContext() async {
        do {
            let detail = try await container.rpc.resourceDetail(resourceId: resourceId)
            resourceForPolicy = detail.resource
            // Override del resource.metadata, si existe.
            if case .object(let dict) = detail.resource.metadata,
               let overrideValue = dict["reservation_policy_override"] {
                currentOverridePolicy = ReservationPolicy.from(jsonValue: overrideValue)
            } else {
                currentOverridePolicy = nil
            }
            // Subtype default del catalog.
            if let subtypeKey = try await container.rpc.resourceSubtypeKey(resourceId: resourceId) {
                let subtypes = try await container.rpc.listResourceSubtypes(classKey: nil)
                subtypeDefaultPolicy = subtypes.first(where: { $0.subtypeKey == subtypeKey })?.reservationPolicy
            }
        } catch {
            // Silent: si falla, el button "Personalizar" simplemente no aparece.
        }
    }

    @ViewBuilder
    private func settingsList(_ settings: ResourceSettings) -> some View {
        List {
            generalSection(settings.general)
            rightsSection(settings)
            capabilitiesSection(settings.capabilities)

            // Capability-gated policy sections (R.2M doctrina)
            if settings.has("reservable") {
                reservableSection(settings.policies.reservable)
            }
            if settings.has("monetary") {
                monetarySection(settings.policies.monetary)
            }
            if settings.has("beneficiary_supported") {
                beneficiarySection(settings.policies.beneficiary)
            }
            if settings.has("documentable") {
                documentableSection(settings.policies.documentable)
            }

            ownerActionsSection(settings)
        }
    }

    // MARK: - General

    @ViewBuilder
    private func generalSection(_ general: ResourceGeneralSummary) -> some View {
        Section("General") {
            HStack(spacing: 12) {
                Image(systemName: typeIcon(general.resourceType))
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(general.displayName).font(.headline)
                    Text(general.resourceType.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if let description = general.description, !description.isEmpty {
                Text(description).font(.body)
            }

            if let status = general.status {
                InfoRow(symbolName: "circle.fill", title: "Estado", value: status.capitalized)
            }
            if let value = general.estimatedValue, value > 0 {
                let currency = general.currency ?? "MXN"
                InfoRow(symbolName: "dollarsign.circle",
                        title: "Valor estimado",
                        value: "\(currency) \(String(format: "%.0f", value))")
            }

            if store.can("edit_general") {
                Button {
                    isShowingEditGeneral = true
                } label: {
                    Label("Editar general", systemImage: "pencil")
                }
            } else {
                Text("Necesitas OWN o MANAGE para editar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func typeIcon(_ type: String) -> String {
        switch type {
        case "house":            return "house"
        case "vehicle":          return "car"
        case "equipment":        return "wrench.and.screwdriver"
        case "bank_account":     return "banknote"
        case "cash_pool":        return "creditcard"
        case "security":         return "chart.line.uptrend.xyaxis"
        case "trust_asset":      return "lock.shield"
        case "contract":         return "doc.text"
        case "document":         return "doc"
        case "trip_booking":     return "airplane"
        case "membership_asset": return "person.crop.rectangle"
        case "digital_asset":    return "wifi"
        default:                 return "shippingbox"
        }
    }

    // MARK: - Rights

    @ViewBuilder
    private func rightsSection(_ settings: ResourceSettings) -> some View {
        Section("Permisos") {
            ForEach(["OWN", "MANAGE", "USE", "VIEW", "BENEFICIARY"], id: \.self) { kind in
                if let count = settings.rightsSummary[kind], count > 0 {
                    InfoRow(symbolName: rightIcon(kind),
                            title: rightLabel(kind),
                            value: "\(count)")
                }
            }
            if !store.can("manage_rights") {
                Text("Solo OWN/MANAGE puede editar permisos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Otorgar / revocar permisos llega en una próxima versión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rightLabel(_ kind: String) -> String {
        switch kind {
        case "OWN":         return "Propietarios"
        case "MANAGE":      return "Administran"
        case "USE":         return "Usan"
        case "VIEW":        return "Ven"
        case "BENEFICIARY": return "Beneficiarios"
        default:            return kind
        }
    }

    private func rightIcon(_ kind: String) -> String {
        switch kind {
        case "OWN":         return "key"
        case "MANAGE":      return "wrench"
        case "USE":         return "hand.raised"
        case "VIEW":        return "eye"
        case "BENEFICIARY": return "heart"
        default:            return "lock"
        }
    }

    // MARK: - Capabilities

    @ViewBuilder
    private func capabilitiesSection(_ capabilities: [String]) -> some View {
        Section("Capacidades") {
            if capabilities.isEmpty {
                Text("Este tipo de recurso no expone capacidades extra.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(capabilities, id: \.self) { cap in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(.green)
                            .frame(width: 24)
                        Text(capabilityLabel(cap))
                        Spacer()
                    }
                }
                Text("Cada capacidad activa sus políticas dedicadas más abajo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capabilityLabel(_ key: String) -> String {
        switch key {
        case "reservable":             return "Reservable"
        case "monetary":               return "Monetario"
        case "ownership_trackable":    return "Propiedad rastreable"
        case "transferable":           return "Transferible"
        case "maintainable":           return "Mantenimiento"
        case "documentable":           return "Documentos"
        case "beneficiary_supported":  return "Beneficiarios"
        case "auditable":              return "Auditable"
        case "approval_required":      return "Requiere aprobación"
        default:                       return key.capitalized
        }
    }

    // MARK: - Reservable

    @ViewBuilder
    private func reservableSection(_ policy: ReservablePolicy) -> some View {
        Section("Reservaciones") {
            InfoRow(symbolName: "calendar", title: "Ventana máxima", value: "\(policy.maxWindowDays) días")
            InfoRow(symbolName: "xmark.circle", title: "Cancelación", value: policy.cancellationPolicy.capitalized)
            InfoRow(symbolName: "list.number", title: "Prioridad", value: priorityLabel(policy.priorityPolicy))
            InfoRow(symbolName: "person.2", title: "Capacidad simultánea", value: "\(policy.capacity)")
        }

        // R.RES.POLICY.D.UI — política de reservación + button editor.
        // Solo aparece cuando el catalog tiene policy seedeada para el subtype.
        if let subtypeDefault = subtypeDefaultPolicy, subtypeDefault.isReservable {
            policyOverrideSection(subtypeDefault: subtypeDefault)
        }
    }

    @ViewBuilder
    private func policyOverrideSection(subtypeDefault: ReservationPolicy) -> some View {
        let effective = currentOverridePolicy ?? subtypeDefault
        Section {
            LabeledContent("Unidad", value: effective.granularity.label)
            LabeledContent("Mínimo", value: durationLabel(effective.minDurationUnits, granularity: effective.granularity))
            if let max = effective.maxDurationUnits {
                LabeledContent("Máximo", value: durationLabel(max, granularity: effective.granularity))
            }
            if let days = effective.advanceWindowDays {
                LabeledContent("Adelanto", value: "Hasta \(days) día\(days == 1 ? "" : "s")")
            }
            LabeledContent("Aprobación", value: effective.requiresApproval ? "Requerida" : "No requerida")
            Button {
                isShowingEditPolicy = true
            } label: {
                Label("Personalizar política", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Política de reservación")
        } footer: {
            Text(currentOverridePolicy == nil
                 ? "Usando el default del subtipo. Personaliza si necesitas reglas distintas para este recurso."
                 : "Override activo. Las reservas se validan contra estos valores en lugar del default del subtipo.")
        }
    }

    private func durationLabel(_ units: Int, granularity: ReservationPolicy.Granularity) -> String {
        switch granularity {
        case .day:       return "\(units) día\(units == 1 ? "" : "s")"
        case .hour:      return "\(units) hora\(units == 1 ? "" : "s")"
        case .eventSlot: return "Un evento"
        case .none:      return "—"
        }
    }

    private func priorityLabel(_ raw: String) -> String {
        switch raw {
        case "least_recent_use_wins":  return "Quien usó hace más tiempo"
        case "first_come_first_serve": return "Primero llega, primero recibe"
        case "round_robin":            return "Rotativo"
        default:                       return raw
        }
    }

    // MARK: - Monetary

    @ViewBuilder
    private func monetarySection(_ policy: MonetaryPolicy) -> some View {
        Section("Monetario") {
            InfoRow(symbolName: "creditcard", title: "Moneda", value: policy.currency)
            InfoRow(symbolName: "calendar.badge.clock",
                    title: "Política de settlement",
                    value: settlementLabel(policy.settlementPolicy))
        }
    }

    private func settlementLabel(_ raw: String) -> String {
        switch raw {
        case "monthly":   return "Mensual"
        case "weekly":    return "Semanal"
        case "on_demand": return "A demanda"
        default:          return raw
        }
    }

    // MARK: - Beneficiarios

    @ViewBuilder
    private func beneficiarySection(_ policy: BeneficiaryPolicy) -> some View {
        Section("Beneficiarios") {
            InfoRow(symbolName: "heart",
                    title: "Beneficiarios activos",
                    value: "\(policy.beneficiaries.count)")
            InfoRow(symbolName: "divide",
                    title: "Distribución",
                    value: policy.distribution.capitalized)
            Text("Lista detallada y reglas de distribución llegan después.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Documentable

    @ViewBuilder
    private func documentableSection(_ policy: DocumentablePolicy) -> some View {
        Section("Documentos") {
            InfoRow(symbolName: "doc.on.doc",
                    title: "Versionado",
                    value: policy.versioningEnabled ? "Activo" : "Inactivo")
            InfoRow(symbolName: "checkmark.shield",
                    title: "Aprobaciones requeridas",
                    value: "\(policy.approvalsRequired)")
        }
    }

    // MARK: - Owner actions

    @ViewBuilder
    private func ownerActionsSection(_ settings: ResourceSettings) -> some View {
        if store.can("transfer_ownership") || store.can("archive") {
            Section {
                if store.can("transfer_ownership") {
                    Button {
                        isShowingTransfer = true
                    } label: {
                        Label("Transferir propiedad", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(runner.isRunning)
                }
                if store.can("archive") {
                    Label("Archivar recurso", systemImage: "archivebox")
                        .foregroundStyle(.secondary)
                    Text("Archivar se habilita en una próxima versión.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Acciones de owner")
            }
        }
    }
}

// MARK: - Edit general sheet (F.1A polish)

private struct EditResourceGeneralSheet: View {
    let resourceId: UUID
    let initial: ResourceGeneralSummary
    let store: ResourceSettingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var description: String
    @State private var estimatedValueText: String
    @State private var currency: String
    @State private var runner = ActionRunner()

    init(resourceId: UUID, initial: ResourceGeneralSummary, store: ResourceSettingsStore) {
        self.resourceId = resourceId
        self.initial = initial
        self.store = store
        _displayName = State(initialValue: initial.displayName)
        _description = State(initialValue: initial.description ?? "")
        _estimatedValueText = State(initialValue: initial.estimatedValue.map { String(format: "%.2f", $0) } ?? "")
        _currency = State(initialValue: initial.currency ?? "MXN")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Nombre del recurso", text: $displayName)
                }

                Section("Descripción") {
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    HStack {
                        TextField("0.00", text: $estimatedValueText)
                            .keyboardType(.decimalPad)
                        Picker("Moneda", selection: $currency) {
                            ForEach(["MXN", "USD", "EUR", "ARS", "CLP", "COP", "BRL"], id: \.self) { c in
                                Text(c).tag(c)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                } header: {
                    Text("Valor estimado")
                } footer: {
                    Text("Solo el dueño o quien gestiona pueden cambiar el valor.")
                }
            }
            .navigationTitle("Editar general")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        Task { await save() }
                    }
                    .disabled(!canSave || runner.isRunning)
                }
            }
            .actionErrorAlert(runner)
        }
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty && displayName != initial.displayName
            || description != (initial.description ?? "")
            || parsedValue != initial.estimatedValue
            || currency != (initial.currency ?? "MXN")
    }

    private var parsedValue: Double? {
        let trimmed = estimatedValueText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    private func save() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            try await store.setGeneral(
                resourceId: resourceId,
                displayName: trimmedName != initial.displayName ? trimmedName : nil,
                description: trimmedDesc != (initial.description ?? "") ? trimmedDesc : nil,
                estimatedValue: parsedValue != initial.estimatedValue ? parsedValue : nil,
                currency: currency != (initial.currency ?? "MXN") ? currency : nil
            )
        }
        if success { dismiss() }
    }
}

// MARK: - Transfer ownership sheet (F.1A polish)

private struct TransferOwnershipSheet: View {
    let resourceId: UUID
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ContextMember] = []
    @State private var contexts: [AppContext] = []
    @State private var recipientId: UUID?
    @State private var reason: String = ""
    @State private var runner = ActionRunner()
    @State private var isConfirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Nuevo dueño", selection: $recipientId) {
                        Text("Selecciona…").tag(UUID?.none)
                        ForEach(candidates) { c in
                            Text(c.displayName).tag(Optional(c.actorId))
                        }
                        ForEach(contexts) { ctx in
                            Text("\(ctx.displayName) (espacio)").tag(Optional(ctx.id))
                        }
                    }
                } header: {
                    Text("Destinatario")
                } footer: {
                    Text("La transferencia revoca tu OWN y se lo otorga al destinatario. El cambio de canonical_owner es atómico.")
                }

                Section {
                    TextField("Razón (opcional)", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Motivo")
                }

                Section {
                    Button(role: .destructive) {
                        isConfirming = true
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Transferir propiedad").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(recipientId == nil || runner.isRunning)
                }
            }
            .navigationTitle("Transferir propiedad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                await loadCandidates()
            }
            .confirmationDialog(
                "¿Confirmas transferir tu propiedad?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Transferir", role: .destructive) {
                    Task { await submit() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Vas a perder tu OWN sobre este recurso. La acción es irreversible salvo que el nuevo dueño te transfiera de vuelta.")
            }
            .actionErrorAlert(runner)
        }
    }

    private func loadCandidates() async {
        // Carga miembros de cada contexto al que el caller tiene acceso.
        let allContexts = container.contextStore.collectiveContexts
        contexts = allContexts
        var seenActors = Set<UUID>()
        var members: [ContextMember] = []
        for ctx in allContexts {
            if let summary = try? await container.rpc.contextSummary(contextId: ctx.id) {
                for member in summary.members where !seenActors.contains(member.actorId) {
                    // Excluir al caller (no podemos transferirnos a nosotros mismos).
                    if member.actorId != container.currentActorStore.actorId {
                        members.append(member)
                        seenActors.insert(member.actorId)
                    }
                }
            }
        }
        candidates = members.sorted { $0.displayName < $1.displayName }
    }

    private func submit() async {
        guard let recipientId else { return }
        let trimmedReason = reason.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            _ = try await container.rpc.transferResourceOwnership(
                resourceId: resourceId,
                toActorId: recipientId,
                reason: trimmedReason.isEmpty ? nil : trimmedReason
            )
        }
        if success { dismiss() }
    }
}

#Preview("Resource Settings") {
    ResourceSettingsView(
        resourceId: MockRuulRPCClient.DemoIds.casaValle,
        container: .demo()
    )
}
