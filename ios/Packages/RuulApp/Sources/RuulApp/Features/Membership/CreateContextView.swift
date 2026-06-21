import SwiftUI
import RuulCore

/// F.5 — crear un contexto nuevo (cena semanal, familia, viaje, negocio, trust…).
public struct CreateContextView: View {
    let container: DependencyContainer
    /// R.5Z.fix.1 — callback con (contextActorId, displayName) post-create.
    /// El parent (CreateIntentSheet / MeView) dismissea + presenta el detail.
    var onCreated: ((UUID, String) -> Void)? = nil

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

    public init(container: DependencyContainer, onCreated: ((UUID, String) -> Void)? = nil) {
        self.container = container
        self.onCreated = onCreated
    }

    private var capStore: ActorCapabilitiesStore { container.actorCapabilitiesStore }

    /// Launch de amigos: la superficie pública sólo ofrece grupos humanos.
    /// Tipos empresariales/proyecto/trust siguen soportados por backend, pero
    /// no se muestran en el flujo inicial.
    private var availableSubtypes: [Subtype] {
        let known = Set(capStore.catalog?.subtypes.map(\.actorSubtype) ?? [])
        let launchSubtypes: [Subtype] = [.friendGroup, .trip, .family, .community]
        let filtered = launchSubtypes.filter { known.isEmpty || known.contains($0.rawValue) }
        return filtered.isEmpty ? launchSubtypes : filtered
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Cena Semanal, Viaje Japón…", text: $displayName)
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
                    Text("¿Qué tipo de grupo es?")
                } footer: {
                    Text("Después puedes cambiarlo desde la configuración del grupo.")
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear grupo").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                } footer: {
                    Text("Tú quedas como fundador. Después puedes invitar amigos con un link o código.")
                }
            }
            .navigationTitle("Nuevo grupo")
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
        .ruulSheet()
    }

    // Capability chips eliminados (founder feedback "que sigue → onboarding"
    // 2026-06-20): jerga técnica que el creador no necesita ver al elegir
    // tipo. Las capabilities las maneja el backend según subtype — el usuario
    // solo elige el concepto humano (Familia · Viaje · Grupo · …).

    @ViewBuilder
    private func subtypeRow(_ option: Subtype) -> some View {
        HStack {
            Label(option.label, systemImage: option.symbolName)
                .foregroundStyle(.primary)
            Spacer()
            if subtype == option {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func create() async {
        var createdId: UUID?
        var createdDisplayName: String?
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
                createdId = new.id
                createdDisplayName = new.displayName
            } else {
                createdId = created.contextActorId
                createdDisplayName = displayName.trimmingCharacters(in: .whitespaces)
            }
        }
        if success {
            if let id = createdId, let name = createdDisplayName, let onCreated {
                // R.5Z.fix.1 — el parent dismissea + pushea al detail.
                onCreated(id, name)
            } else {
                dismiss()
            }
        }
    }
}

#Preview("Crear contexto") {
    CreateContextView(container: .demo())
}
