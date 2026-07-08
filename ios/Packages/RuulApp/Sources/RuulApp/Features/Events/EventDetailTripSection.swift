import SwiftUI
import RuulCore

struct EventDetailTripSection: View {
    let event: CalendarEvent
    /// R.15 — para gatear el CTA de gasto con `available_actions[]` (mismo
    /// gate que EventDetailMoneySection).
    let store: EventDetailStore
    /// Abre la misma sheet de gasto scoped al evento (openExpenseSheet en
    /// EventDetailView — mismo MoneyStore + EventScope).
    let onRecordExpense: () -> Void

    /// Mismo criterio que `EventDetailMoneySection.recordExpenseAction`.
    private var recordExpenseAction: AvailableAction? {
        store.availableActions.first { $0.actionKey == "record_expense" }
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
