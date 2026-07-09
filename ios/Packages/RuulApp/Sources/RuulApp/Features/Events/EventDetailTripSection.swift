import SwiftUI
import RuulCore

struct EventDetailTripSection: View {
    let event: CalendarEvent
    /// R.15 — para gatear el CTA de gasto con `available_actions[]` (mismo
    /// gate que EventDetailMoneySection).
    let store: EventDetailStore
    /// R.16.B — para cargar los botes del contexto (`list_context_pools`) y
    /// ligar/crear el bote del viaje (`metadata.source_event_id`).
    let context: AppContext
    let container: DependencyContainer
    /// Abre la misma sheet de gasto scoped al evento (openExpenseSheet en
    /// EventDetailView — mismo MoneyStore + EventScope).
    let onRecordExpense: () -> Void

    @State private var poolsStore: PoolsStore
    @State private var pools: [PoolAccount] = []
    @State private var didLoadPools = false
    @State private var isShowingCreatePool = false

    init(
        event: CalendarEvent,
        store: EventDetailStore,
        context: AppContext,
        container: DependencyContainer,
        onRecordExpense: @escaping () -> Void
    ) {
        self.event = event
        self.store = store
        self.context = context
        self.container = container
        self.onRecordExpense = onRecordExpense
        _poolsStore = State(initialValue: PoolsStore(rpc: container.rpc))
    }

    /// Mismo criterio que `EventDetailMoneySection.recordExpenseAction`.
    private var recordExpenseAction: AvailableAction? {
        store.availableActions.first { $0.actionKey == "record_expense" }
    }

    /// R.16.B — el bote ligado a ESTE viaje vía `metadata.source_event_id`.
    private var tripPool: PoolAccount? {
        pools.first { $0.sourceEventId == event.id }
    }

    var body: some View {
        if event.type == .trip {
            Section {
                if let startsAt = event.startsAt {
                    LabeledContent("Fechas") {
                        Text(dateRange(startsAt: startsAt, endsAt: event.endsAt))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let destination = event.locationText, !destination.isEmpty {
                    LabeledContent("Destino") {
                        Text(destination)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let budget = tripMetadata["budget_per_person"]?.numberValue {
                    LabeledContent("Presupuesto por persona") {
                        Text(budget, format: .currency(code: tripMetadata["budget_currency"]?.stringValue ?? "MXN"))
                    }
                }
                LabeledContent("Estado") {
                    Text(tripStatus)
                        .foregroundStyle(statusTint)
                }
                .task { await loadPoolsIfNeeded() }
                // Sheet anclada a una fila que SIEMPRE existe: la fila del CTA
                // desaparece en cuanto tripPool se materializa y desmontaría
                // la sheet a media presentación.
                .sheet(isPresented: $isShowingCreatePool) {
                    CreatePoolSheet(
                        context: context,
                        store: poolsStore,
                        initialName: event.title,
                        metadata: .object([
                            "source_event_id": .string(event.id.uuidString)
                        ]),
                        onCreated: { _ in
                            Task { await loadPools() }
                        }
                    )
                }
                // R.16.B — bote del viaje: si ya existe un pool ligado a este
                // evento (metadata.source_event_id), fila con total + push al
                // detalle; si no, CTA para crearlo pre-llenado (mismo gate
                // money.record que el CTA de gasto — create_pool usa el mismo
                // permission backend-side).
                if let pool = tripPool {
                    NavigationLink {
                        PoolDetailView(
                            poolAccountId: pool.poolAccountId,
                            context: context,
                            container: container
                        )
                    } label: {
                        LabeledContent {
                            Text((pool.totals?.basisTotal ?? 0).compactCurrencyLabel(pool.currency ?? "MXN"))
                                .monospacedDigit()
                        } label: {
                            Label("Bote del viaje", systemImage: "banknote.fill")
                        }
                    }
                } else if didLoadPools, recordExpenseAction != nil {
                    Button {
                        isShowingCreatePool = true
                    } label: {
                        Label("Crear bote del viaje", systemImage: "plus.circle")
                    }
                }
                // R.15 — CTA de gasto scoped al viaje. Sólo si el backend
                // trae record_expense; disabled respeta el `enabled` (P0.5).
                if let action = recordExpenseAction {
                    Button {
                        onRecordExpense()
                    } label: {
                        Label("Registrar gasto del viaje", systemImage: "banknote")
                    }
                    .disabled(!action.enabled)
                }
            } header: {
                Text("Viaje")
            }
        }
    }

    private func loadPoolsIfNeeded() async {
        guard !didLoadPools else { return }
        await loadPools()
    }

    /// Falla en silencio (espejo de EventDetailPoolsSection): el bote es
    /// insight, no bloquea el detalle del viaje.
    private func loadPools() async {
        pools = (try? await container.rpc.listContextPools(contextId: context.id)) ?? []
        didLoadPools = true
    }

    private var tripMetadata: [String: JSONValue] {
        event.metadata["trip"]?.objectValue ?? [:]
    }

    private var tripStatus: String {
        if event.isCompleted { return "Cerrado" }
        guard let startsAt = event.startsAt else { return "Planeación" }
        let now = Date()
        if let endsAt = event.endsAt, startsAt <= now, now <= endsAt {
            return "En curso"
        }
        if startsAt > now { return "Planeación" }
        return "Terminado"
    }

    private var statusTint: Color {
        switch tripStatus {
        case "En curso": return Theme.Tint.success
        case "Cerrado", "Terminado": return Theme.Text.secondary
        default: return Theme.Tint.info
        }
    }

    private func dateRange(startsAt: Date, endsAt: Date?) -> String {
        guard let endsAt else {
            return startsAt.formatted(date: .abbreviated, time: .omitted)
        }
        let start = startsAt.formatted(date: .abbreviated, time: .omitted)
        let end = endsAt.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) - \(end)"
    }
}
