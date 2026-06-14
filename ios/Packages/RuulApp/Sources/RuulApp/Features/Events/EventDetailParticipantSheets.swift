import SwiftUI
import RuulCore

// MARK: - R.5Z.fix.EVENT.PARTICIPANTS — Add Participants Sheet
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).
//
// Sheet con List de members activos del contexto NO presentes aún en el roster.
// Multi-select (toggle por row). "Agregar" llama add_event_participants.

struct AddParticipantsSheet: View {
    let eventId: UUID
    let contextId: UUID?
    let existingActorIds: Set<UUID>
    let rpc: any RuulRPCClient
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var members: [ContextMember] = []
    @State private var selectedIds: Set<UUID> = []
    @State private var runner = ActionRunner()
    @State private var phase: StorePhase = .idle

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Agregar al evento")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Agregar") {
                            Task { await addSelected() }
                        }
                        .disabled(selectedIds.isEmpty || runner.isRunning)
                    }
                }
                .actionErrorAlert(runner)
                .task { await load() }
        }
        .ruulSheet()
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading: RuulLoadingState()
        case .failed(let msg): RuulErrorState(message: msg) { Task { await load() } }
        case .loaded:
            let candidates = members.filter { !existingActorIds.contains($0.actorId) }
            if candidates.isEmpty {
                RuulEmptyState(
                    title: "Sin miembros para agregar",
                    systemImage: "person.2",
                    message: "Todos los miembros activos del contexto ya son participantes del evento.\n\nPara invitar a alguien externo (familiar, pareja, amigo no-miembro) necesitamos el módulo de Invitados Externos — próximamente."
                )
            } else {
                List {
                    Section {
                        ForEach(candidates) { member in
                            Button {
                                if selectedIds.contains(member.actorId) {
                                    selectedIds.remove(member.actorId)
                                } else {
                                    selectedIds.insert(member.actorId)
                                }
                            } label: {
                                HStack {
                                    Label {
                                        Text(member.displayName)
                                            .foregroundStyle(Theme.Text.primary)
                                    } icon: {
                                        Image(systemName: "person.crop.circle")
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                    Spacer()
                                    if selectedIds.contains(member.actorId) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Miembros del espacio")
                    } footer: {
                        Text("Solo aparecen los miembros activos del espacio que aún no son participantes.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func load() async {
        guard let ctxId = contextId else {
            phase = .failed(message: "Contexto del evento desconocido")
            return
        }
        if members.isEmpty { phase = .loading }
        do {
            let summary = try await rpc.contextSummary(contextId: ctxId)
            members = summary.members
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    private func addSelected() async {
        let ids = Array(selectedIds)
        let success = await runner.run {
            try await rpc.addEventParticipants(eventId: eventId, actorIds: ids)
        }
        if success {
            onAdded()
            dismiss()
        }
    }
}

// MARK: - R.5Z.fix.EVENT.GUESTS — Add External Guest Sheet
//
// MVP1: solo source='manual' (name + count share). Phase 2: cross-context
// picker + Apple Contacts integration.

struct AddEventGuestSheet: View {
    let eventId: UUID
    let rpc: any RuulRPCClient
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var countShare = 1
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ej. Mi esposa", text: $displayName)
                        .textInputAutocapitalization(.words)
                    Stepper(value: $countShare, in: 1...20) {
                        HStack {
                            Text("Cuenta como")
                            Spacer()
                            Text("\(countShare) \(countShare == 1 ? "persona" : "personas")")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Datos del invitado")
                } footer: {
                    Text("El invitado no será miembro del espacio. Solo aparece en este evento y cuenta en el reparto del gasto según su parte.")
                }

                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Agregar invitado").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }

                Section {
                    Label("Próximamente", systemImage: "sparkles")
                        .foregroundStyle(Theme.Text.secondary)
                } header: {
                    Text("Próximamente")
                } footer: {
                    Text("Pronto vas a poder seleccionar invitados desde tus otros espacios o tu libreta de contactos de Apple.")
                }
            }
            .navigationTitle("Invitar externo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func add() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            _ = try await rpc.addEventGuest(
                eventId: eventId,
                displayName: trimmed,
                countShare: countShare,
                linkedActorId: nil,
                source: "manual"
            )
        }
        if success {
            onAdded()
            dismiss()
        }
    }
}
