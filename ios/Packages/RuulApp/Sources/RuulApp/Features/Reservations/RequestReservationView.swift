import SwiftUI
import RuulCore

/// F.9 — solicitar una reservación de un recurso para un rango de fechas.
public struct RequestReservationView: View {
    let resource: Resource
    let context: AppContext
    let store: ReservationsStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var endsAt = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var reservedForActorId: UUID?
    @State private var runner = ActionRunner()
    @State private var conflictNotice: String?

    public init(resource: Resource, context: AppContext, store: ReservationsStore, container: DependencyContainer) {
        self.resource = resource
        self.context = context
        self.store = store
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Fechas") {
                    DatePicker("Desde", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Hasta", selection: $endsAt, in: startsAt..., displayedComponents: [.date, .hourAndMinute])
                }

                if !store.members.isEmpty {
                    Section("Para quién") {
                        Picker("Reservar para", selection: $reservedForActorId) {
                            Text("Para mí").tag(nil as UUID?)
                            ForEach(store.members) { member in
                                Text(member.displayName).tag(member.actorId as UUID?)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await request() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Solicitar reservación").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(endsAt <= startsAt || runner.isRunning)
                } footer: {
                    Text("Si las fechas se traslapan con otra solicitud, se abre un conflicto que un admin debe resolver.")
                }

                if let conflictNotice {
                    Section {
                        Label(conflictNotice, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Reservar \(resource.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
    }

    private func request() async {
        let success = await runner.run {
            let result = try await store.request(
                RequestReservationInput(
                    resourceId: resource.id,
                    contextId: context.id,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    reservedForActorId: reservedForActorId,
                    clientId: UUID().uuidString
                ),
                context: context
            )
            if result.conflictsDetected > 0 {
                conflictNotice = "Tu solicitud quedó registrada, pero hay \(result.conflictsDetected) conflicto(s) de fechas. Un admin tendrá que resolverlo."
            }
        }
        if success && conflictNotice == nil {
            dismiss()
        }
    }
}

#Preview("Solicitar reservación") {
    RequestReservationView(
        resource: Resource(
            id: MockRuulRPCClient.DemoIds.casaValle,
            resourceType: "house",
            displayName: "Casa Valle"
        ),
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi"
        ),
        store: ReservationsStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
