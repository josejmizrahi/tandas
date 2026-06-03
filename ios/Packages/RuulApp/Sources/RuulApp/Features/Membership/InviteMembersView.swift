import SwiftUI
import RuulCore

/// F.5 — invitar miembros al contexto. Dos modos:
/// 1. **Directo** (`invite_member`): selecciona a alguien que conoces de otros
///    contextos. Le llega como invitación pendiente; debe llamar
///    `accept_invitation` (sheet "Invitaciones") para activarse.
/// 2. **Por código** (`create_invite` + `join_by_invite_code`): genera un código
///    compartible para gente que aún no está en la red.
public struct InviteMembersView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case direct, code
        var id: String { rawValue }
        var label: String {
            switch self {
            case .direct: return "Directo"
            case .code: return "Por código"
            }
        }
    }

    let context: AppContext
    let store: MembersStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .direct

    // Mode .code
    @State private var invite: InviteCreated?
    @State private var limitUses = false
    @State private var maxUses = 5

    // Mode .direct
    @State private var knownActors: [KnownActor] = []
    @State private var isLoadingKnown = false
    @State private var selectedActorId: UUID?
    @State private var directSearch = ""
    @State private var directSuccessName: String?

    @State private var runner = ActionRunner()

    public init(context: AppContext, store: MembersStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Modo", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch mode {
                case .direct:
                    directSections
                case .code:
                    codeSections
                }
            }
            .navigationTitle("Invitar miembros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task {
                await loadKnown()
            }
            .actionErrorAlert(runner)
        }
    }

    // MARK: - Direct (invite_member)

    @ViewBuilder
    private var directSections: some View {
        if let directSuccessName {
            Section {
                Label(
                    "Invitaste a \(directSuccessName). Aparecerá como miembro pendiente hasta que acepte.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
        }

        Section {
            if isLoadingKnown {
                HStack { ProgressView(); Text("Buscando personas que conoces…") }
            } else if filteredKnown.isEmpty {
                Text(knownActors.isEmpty
                     ? "Por ahora no tienes a nadie en otros contextos. Usa “Por código” para invitar a alguien nuevo."
                     : "Sin coincidencias para “\(directSearch)”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ForEach(filteredKnown) { actor in
                    Button { selectedActorId = actor.actorId } label: {
                        directRow(actor)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Personas que conoces")
        } footer: {
            Text("Mostramos miembros de tus otros contextos. Si no encuentras a quien buscas, comparte un código en “Por código”.")
        }
        .searchable(text: $directSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar persona")

        if let selectedActorId,
           let selected = knownActors.first(where: { $0.actorId == selectedActorId }) {
            Section {
                Button {
                    Task { await inviteDirect(selected) }
                } label: {
                    if runner.isRunning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Invitar a \(selected.displayName)", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(runner.isRunning)
            } footer: {
                Text("La invitación queda pendiente hasta que la persona la acepte desde su sección de Invitaciones.")
            }
        }
    }

    private var filteredKnown: [KnownActor] {
        let query = directSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return knownActors }
        return knownActors.filter { $0.displayName.lowercased().contains(query) }
    }

    @ViewBuilder
    private func directRow(_ actor: KnownActor) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: actor.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(actor.displayName)
                    .font(.body)
                Text(actor.sharedContexts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if selectedActorId == actor.actorId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func loadKnown() async {
        guard knownActors.isEmpty else { return }
        isLoadingKnown = true
        defer { isLoadingKnown = false }
        do {
            let myWorld = try await container.rpc.myWorld()
            knownActors = await store.loadKnownActors(
                myWorld: myWorld,
                excludingContext: context.id,
                myActorId: container.currentActorStore.actorId
            )
        } catch {
            // Falla silenciosa — el listado simplemente queda vacío y el footer
            // del Section lo explica.
            knownActors = []
        }
    }

    private func inviteDirect(_ actor: KnownActor) async {
        await runner.run {
            _ = try await store.inviteMember(
                context: context,
                memberActorId: actor.actorId
            )
            directSuccessName = actor.displayName
            selectedActorId = nil
            directSearch = ""
        }
    }

    // MARK: - Code (create_invite)

    @ViewBuilder
    private var codeSections: some View {
        if let invite {
            Section("Código de invitación") {
                HStack {
                    Text(invite.code)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 8)

                ShareLink(
                    item: inviteURL(invite),
                    subject: Text("Invitación a \(context.displayName)"),
                    message: Text(shareMessage(invite))
                ) {
                    Label("Compartir invitación", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
            }

            Section {
                Button("Generar otro código") {
                    self.invite = nil
                }
            }
        } else {
            Section("Opciones") {
                Toggle("Limitar usos", isOn: $limitUses)
                if limitUses {
                    Stepper("Máximo \(maxUses) personas", value: $maxUses, in: 1...50)
                }
            }

            Section {
                Button {
                    Task { await generate() }
                } label: {
                    if runner.isRunning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Generar código", systemImage: "ticket")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(runner.isRunning)
            } footer: {
                Text("Cualquier persona con el código puede unirse a \(context.displayName) como miembro.")
            }
        }
    }

    private func generate() async {
        await runner.run {
            invite = try await store.createInvite(
                contextId: context.id,
                maxUses: limitUses ? maxUses : nil
            )
        }
    }

    /// Universal link que abre la app (o la landing de web/ si no la tienen).
    private func inviteURL(_ invite: InviteCreated) -> URL {
        URL(string: "https://ruul.mx/invite/\(invite.code)") ?? URL(string: "https://ruul.mx")!
    }

    private func shareMessage(_ invite: InviteCreated) -> String {
        "Únete a \(context.displayName) en Ruul. Abre el link o usa el código \(invite.code)."
    }
}

#Preview("Invitar · directo") {
    InviteMembersView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: MembersStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
