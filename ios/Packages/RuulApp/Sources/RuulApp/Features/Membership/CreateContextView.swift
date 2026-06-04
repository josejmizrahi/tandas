import SwiftUI
import RuulCore

/// F.5 — crear un contexto nuevo (cena semanal, familia, viaje, negocio, trust…).
public struct CreateContextView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var subtype: Subtype = .friendGroup
    @State private var runner = ActionRunner()
    /// R.2V.4 — creation guard: candidatos similares al nombre que el usuario teclea.
    @State private var guardCandidates: [ContextCreationCandidate] = []

    private enum Subtype: String, CaseIterable, Identifiable {
        case friendGroup = "friend_group"
        case family
        case trip
        case community
        case project
        case company
        case trust

        var id: String { rawValue }

        var label: String {
            switch self {
            case .friendGroup: return "Grupo de amigos"
            case .family: return "Familia"
            case .trip: return "Viaje"
            case .community: return "Comunidad"
            case .project: return "Proyecto"
            case .company: return "Negocio"
            case .trust: return "Trust"
            }
        }

        var symbolName: String {
            switch self {
            case .friendGroup: return "person.3.fill"
            case .family: return "figure.2.and.child.holdinghands"
            case .trip: return "airplane"
            case .community: return "person.3.sequence.fill"
            case .project: return "hammer.fill"
            case .company: return "building.2.fill"
            case .trust: return "building.columns.fill"
            }
        }

        /// Negocios y trusts son entidades legales; el resto, colectivos.
        var actorKind: ActorKind {
            switch self {
            case .company, .trust: return .legalEntity
            default: return .collective
            }
        }
    }

    public init(container: DependencyContainer) {
        self.container = container
    }

    private var capStore: ActorCapabilitiesStore { container.actorCapabilitiesStore }

    /// Solo se ofrecen los subtypes que el catálogo del backend reconoce.
    /// Cualquier subtype nuevo del backend (sin label/icon iOS) queda fuera
    /// hasta que se agregue al enum.
    private var availableSubtypes: [Subtype] {
        let known = Set(capStore.catalog?.subtypes.map(\.actorSubtype) ?? [])
        let filtered = Subtype.allCases.filter { known.isEmpty || known.contains($0.rawValue) }
        return filtered.isEmpty ? Subtype.allCases : filtered
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Cena Semanal, Familia, Viaje Japón…", text: $displayName)
                }

                CreationGuardView(
                    candidates: guardCandidates.map(CreationGuardCandidate.from)
                ) { selected in
                    // Tap en un candidato → switch + cerrar el sheet (evita duplicado).
                    if let target = container.contextStore.availableContexts.first(where: { $0.id == selected.id }) {
                        container.contextStore.switchTo(target)
                    }
                    dismiss()
                }

                Section {
                    ForEach(availableSubtypes) { option in
                        Button {
                            subtype = option
                        } label: {
                            subtypeRow(option)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Tipo")
                } footer: {
                    Text("Las capabilities las determina el backend según el tipo. Tú no decides permisos individuales aquí.")
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear contexto").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                } footer: {
                    Text("Tú quedas como fundador con rol de admin. Después puedes invitar miembros con un código.")
                }
            }
            .navigationTitle("Nuevo contexto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
            .task {
                await capStore.loadCatalogIfNeeded()
            }
            // R.2V.4 — debounce creation guard al teclear el nombre.
            .task(id: displayName) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                let trimmed = displayName.trimmingCharacters(in: .whitespaces)
                guard !Task.isCancelled, trimmed.count >= 3 else {
                    if trimmed.count < 3 { guardCandidates = [] }
                    return
                }
                do {
                    guardCandidates = try await container.rpc.contextCreationCandidates(displayName: trimmed)
                } catch {
                    guardCandidates = []
                }
            }
        }
    }

    @ViewBuilder
    private func subtypeRow(_ option: Subtype) -> some View {
        let caps = capStore.capabilities(forSubtype: option.rawValue)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(option.label, systemImage: option.symbolName)
                    .foregroundStyle(.primary)
                Spacer()
                if subtype == option {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            if !caps.isEmpty {
                FlowingChips(items: capabilityHints(caps))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Convierte capability keys en labels cortos amigables.
    private func capabilityHints(_ keys: [String]) -> [String] {
        keys.compactMap { key in
            switch key {
            case "can_have_members": return "Miembros"
            case "can_have_beneficiaries": return "Beneficiarios"
            case "can_have_trustees": return "Trustees"
            case "can_have_shareholders": return "Accionistas"
            case "can_hold_money": return "Dinero"
            case "can_hold_assets": return "Activos"
            case "can_own_resources": return "Recursos"
            case "can_issue_decisions": return "Decisiones"
            case "can_receive_contributions": return "Aportaciones"
            case "can_govern_resources": return "Gobierno"
            case "can_receive_obligations", "can_issue_obligations": return nil
            default: return capStore.displayName(for: key)
            }
        }
    }

    private func create() async {
        let success = await runner.run {
            let created = try await container.rpc.createContext(CreateContextInput(
                displayName: displayName.trimmingCharacters(in: .whitespaces),
                actorKind: subtype.actorKind,
                actorSubtype: subtype.rawValue
            ))
            // Recargar contextos y enfocar el nuevo.
            await container.contextStore.load()
            if let new = container.contextStore.availableContexts.first(where: { $0.id == created.contextActorId }) {
                container.contextStore.switchTo(new)
            }
        }
        if success { dismiss() }
    }
}

/// Wrap horizontal de chips compacto sin overflow.
private struct FlowingChips: View {
    let items: [String]

    var body: some View {
        let rows = chunked(items, per: 4)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        Text(item)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chunked(_ items: [String], per size: Int) -> [[String]] {
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0+size, items.count)]) }
    }
}

#Preview("Crear contexto") {
    CreateContextView(container: .demo())
}
