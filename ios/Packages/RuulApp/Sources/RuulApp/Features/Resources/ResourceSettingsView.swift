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
                    LoadingStateView()
                case .failed(let message):
                    ErrorStateView(message: message) {
                        Task { await store.load(resourceId: resourceId) }
                    }
                case .loaded:
                    if let settings = store.settings {
                        settingsList(settings)
                    } else {
                        ErrorStateView(message: "No pudimos cargar la configuración.")
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

            if !store.can("edit_general") {
                Text("Necesitas OWN o MANAGE para editar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Edición inline llega en una próxima versión.")
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
        Section("Derechos") {
            ForEach(["OWN", "MANAGE", "USE", "VIEW", "BENEFICIARY"], id: \.self) { kind in
                if let count = settings.rightsSummary[kind], count > 0 {
                    InfoRow(symbolName: rightIcon(kind),
                            title: rightLabel(kind),
                            value: "\(count)")
                }
            }
            if !store.can("manage_rights") {
                Text("Solo OWN/MANAGE puede editar derechos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Otorgar / revocar derechos llega en una próxima versión.")
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
            Section("Acciones de owner") {
                if store.can("transfer_ownership") {
                    Label("Transferir propiedad", systemImage: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                }
                if store.can("archive") {
                    Label("Archivar recurso", systemImage: "archivebox")
                        .foregroundStyle(.secondary)
                }
                Text("Estas acciones se habilitan en una próxima versión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Resource Settings") {
    ResourceSettingsView(
        resourceId: MockRuulRPCClient.DemoIds.casaValle,
        container: .demo()
    )
}
