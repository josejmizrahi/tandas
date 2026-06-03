import SwiftUI
import RuulCore

/// F.5 — crear un contexto nuevo (cena semanal, familia, viaje, negocio, trust…).
public struct CreateContextView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var subtype: Subtype = .friendGroup
    @State private var runner = ActionRunner()

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

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Cena Semanal, Familia, Viaje Japón…", text: $displayName)
                }

                Section("Tipo") {
                    ForEach(Subtype.allCases) { option in
                        Button {
                            subtype = option
                        } label: {
                            HStack {
                                Label(option.label, systemImage: option.symbolName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if subtype == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
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

#Preview("Crear contexto") {
    CreateContextView(container: .demo())
}
