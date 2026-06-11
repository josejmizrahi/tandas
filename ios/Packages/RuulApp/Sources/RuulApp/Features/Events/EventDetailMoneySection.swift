import SwiftUI
import RuulCore

// MARK: - Dinero del evento
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).
//
// R.5Z.fix.EVENT.1 (founder 2026-06-10 Bros/Campo Marte) — Section "Dinero
// del evento" con CTA prominente "Registrar gasto" cuando el caller tiene
// permiso. Antes la acción solo vivía escondida en el "+" Menu del toolbar
// y founder no la encontraba. Section solo se renderiza si record_expense
// está enabled en availableActions del backend.

struct EventDetailMoneySection: View {
    let store: EventDetailStore
    let onRecordExpense: () -> Void

    var body: some View {
        if let action = store.availableActions.first(where: { $0.actionKey == "record_expense" && $0.enabled }) {
            Section {
                Button {
                    onRecordExpense()
                } label: {
                    Label(action.label, systemImage: "dollarsign.circle.fill")
                }
            } header: {
                Text("Dinero del evento")
            } footer: {
                Text("El gasto se divide automáticamente entre los participantes del evento.")
            }
        }
    }
}
