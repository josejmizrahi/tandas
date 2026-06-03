import SwiftUI
import RuulCore

/// F.9 — solicitar una reservación de un recurso para un rango de fechas.
public struct RequestReservationView: View {
    let resource: Resource
    let context: AppContext
    let store: ReservationsStore
    let container: DependencyContainer
    /// Contexto donde se crea la reservación (el que gobierna el recurso).
    let reservationContextId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var endsAt = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var reservedForActorId: UUID?
    @State private var runner = ActionRunner()
    @State private var conflictNotice: String?
    /// R.2S.10 — preview de permiso (why_can_reserve).
    @State private var whyCanReserve: WhyCanReserve?

    public init(resource: Resource, context: AppContext, reservationContextId: UUID? = nil, store: ReservationsStore, container: DependencyContainer) {
        self.resource = resource
        self.context = context
        self.reservationContextId = reservationContextId ?? context.id
        self.store = store
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            Form {
                whySection

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
            .task {
                await loadWhy()
            }
        }
    }

    @ViewBuilder
    private var whySection: some View {
        if let why = whyCanReserve {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: why.canReserve ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(why.canReserve ? .green : .orange)
                        .imageScale(.large)
                    Text(why.canReserve ? "Puedes reservar" : "No puedes reservar")
                        .font(.callout.weight(.semibold))
                }
                ForEach(why.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Permisos")
            }
        }
    }

    private func loadWhy() async {
        guard let actorId = container.currentActorStore.actorId else { return }
        whyCanReserve = try? await container.rpc.whyCanReserve(
            actorId: actorId, resourceId: resource.id
        )
    }

    private func request() async {
        let success = await runner.run {
            let result = try await store.request(
                RequestReservationInput(
                    resourceId: resource.id,
                    contextId: reservationContextId,
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
