import SwiftUI
import RuulCore

/// R.2U.3 — crea un contexto hijo bajo `parent`. Visible sólo cuando el
/// backend reporta `context.children.create` en `my_permissions` del padre.
public struct CreateChildContextSheet: View {
    let parent: AppContext
    let container: DependencyContainer
    /// Closure invocado cuando la creación tuvo éxito; el caller refresca
    /// children/breadcrumb/tree. Recibe el contexto recién creado.
    let onCreated: (AppContext) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var subtype: Subtype = .community
    @State private var runner = ActionRunner()
    /// R.2V.4 — creation guard: candidatos similares al nombre.
    @State private var guardCandidates: [ContextCreationCandidate] = []

    private enum Subtype: String, CaseIterable, Identifiable {
        case family
        case community
        case project
        case trip
        case friendGroup = "friend_group"
        case company
        case trust
        case other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .family: return "Familia"
            case .community: return "Comunidad"
            case .project: return "Proyecto"
            case .trip: return "Viaje"
            case .friendGroup: return "Grupo de amigos"
            case .company: return "Negocio"
            case .trust: return "Trust"
            case .other: return "Otro"
            }
        }

        var symbolName: String {
            switch self {
            case .family: return "figure.2.and.child.holdinghands"
            case .community: return "person.3.sequence.fill"
            case .project: return "hammer.fill"
            case .trip: return "airplane"
            case .friendGroup: return "person.3.fill"
            case .company: return "building.2.fill"
            case .trust: return "building.columns.fill"
            case .other: return "square.dashed"
            }
        }

        var actorKind: ActorKind {
            switch self {
            case .company, .trust: return .legalEntity
            default: return .collective
            }
        }
    }

    public init(
        parent: AppContext,
        container: DependencyContainer,
        onCreated: @escaping (AppContext) -> Void
    ) {
        self.parent = parent
        self.container = container
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Comidas Miércoles, Mundial Palco…", text: $displayName)
                }

                CreationGuardView(
                    candidates: guardCandidates.map(CreationGuardCandidate.from)
                ) { selected in
                    // Tap en un candidato → switch + cerrar (evita duplicado).
                    if let target = container.contextStore.availableContexts.first(where: { $0.id == selected.id }) {
                        container.contextStore.switchTo(target)
                    }
                    dismiss()
                }

                Section {
                    ForEach(Subtype.allCases) { option in
                        Button {
                            subtype = option
                        } label: {
                            HStack {
                                Label(option.label, systemImage: option.symbolName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if subtype == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Tipo")
                } footer: {
                    Text("El subcontexto es un contexto real con sus propios miembros, reglas y dinero. La membresía y los rights NO se heredan del padre.")
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear subcontexto").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                } footer: {
                    Text("Quedarás como fundador del nuevo contexto. Podrás invitar miembros después.")
                }
            }
            .navigationTitle("Nuevo subcontexto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
            // R.2V.4 — debounce creation guard.
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

    private func create() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            let created = try await container.rpc.createChildContext(CreateChildContextInput(
                parentContextActorId: parent.id,
                displayName: trimmed,
                actorKind: subtype.actorKind,
                actorSubtype: subtype.rawValue
            ))
            // Recargar contextos para que el hijo aparezca en el switcher.
            await container.contextStore.load()
            let newCtx = AppContext(
                id: created.childContextActorId,
                kind: subtype.actorKind,
                subtype: subtype.rawValue,
                displayName: trimmed,
                membershipType: "founder",
                memberCount: 1,
                roles: ["admin"]
            )
            await MainActor.run { onCreated(newCtx) }
        }
        if success { dismiss() }
    }
}

#Preview("Crear subcontexto") {
    CreateChildContextSheet(
        parent: AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi",
            membershipType: "founder",
            memberCount: 3,
            roles: ["admin"]
        ),
        container: .demo(),
        onCreated: { _ in }
    )
}
