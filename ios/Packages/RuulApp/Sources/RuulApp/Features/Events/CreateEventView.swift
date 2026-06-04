import SwiftUI
import RuulCore

/// F.7 — crear un evento (cena, reunión, viaje, noche de juegos…).
public struct CreateEventView: View {
    let context: AppContext
    let store: EventsStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var eventType: EventType = .dinner
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var locationText = ""
    @State private var isVirtual = false
    @State private var isWeekly = false
    @State private var inviteAllMembers = true
    @State private var runner = ActionRunner()

    public init(context: AppContext, store: EventsStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    /// F.EVENT.5 — un evento siempre debe tener ubicación, salvo que sea virtual.
    private var locationIsValid: Bool {
        isVirtual || !locationText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && locationIsValid
            && !runner.isRunning
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Evento") {
                    TextField("Título (Cena de los jueves…)", text: $title)
                    Picker("Tipo", selection: $eventType) {
                        ForEach(EventType.allCases) { type in
                            Label(type.label, systemImage: type.symbolName).tag(type)
                        }
                    }
                    DatePicker("Cuándo", selection: $startsAt)
                }

                Section {
                    Toggle(isOn: $isVirtual) {
                        Label("Evento virtual", systemImage: "video.fill")
                    }
                    if !isVirtual {
                        TextField("Dónde", text: $locationText)
                    }
                } header: {
                    Text("Ubicación")
                } footer: {
                    if isVirtual {
                        Text("Sin ubicación física. Después puedes compartir el link del Zoom o Meet.")
                    } else {
                        Text("La ubicación es obligatoria. Si el evento es por videollamada, activa \"Evento virtual\".")
                    }
                }

                Section {
                    Toggle("Se repite cada semana", isOn: $isWeekly)
                } header: {
                    Text("Recurrencia")
                } footer: {
                    if isWeekly {
                        Text("Al cerrar cada evento se crea automáticamente el de la siguiente semana y el host rota entre los miembros.")
                    }
                }

                if !context.isPersonal {
                    Section("Invitados") {
                        Toggle("Invitar a todos los miembros", isOn: $inviteAllMembers)
                    }
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear evento").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Nuevo evento")
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
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            _ = try await store.createEvent(
                CreateEventInput(
                    contextId: context.id,
                    title: title.trimmingCharacters(in: .whitespaces),
                    eventType: eventType,
                    startsAt: startsAt,
                    locationText: isVirtual || trimmedLocation.isEmpty ? nil : trimmedLocation,
                    isVirtual: isVirtual,
                    recurrenceRule: isWeekly ? "weekly" : nil,
                    inviteAllMembers: inviteAllMembers,
                    clientId: UUID().uuidString
                ),
                context: context
            )
        }
        if success { dismiss() }
    }
}

#Preview("Crear evento") {
    CreateEventView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: EventsStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
