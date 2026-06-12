import SwiftUI
import RuulCore

/// P0.5 (doctrina UX §0.4 / R.5V) — botón canónico para una `AvailableAction`
/// del backend en menús y secciones. Cuando la acción está **deshabilitada**
/// muestra su `reason` como subtítulo del item (+ accessibility hint): el usuario
/// sabe POR QUÉ no puede, no sólo que no puede. Único punto de verdad del patrón
/// que antes vivía inline y disperso por las vistas de detalle.
///
/// Sirve igual en `Menu { … }` y en `Section { … }` (es un `Button` + `Label`).
struct ActionMenuButton: View {
    let action: AvailableAction
    /// Rol del botón (p.ej. `.destructive` para acciones peligrosas). Si es nil
    /// se deriva del catálogo de presentación.
    let role: ButtonRole?
    /// Deshabilitación adicional ortogonal al `enabled` del backend (p.ej. mientras
    /// corre otra acción: `runner.isRunning`).
    let extraDisabled: Bool
    let onTap: () -> Void

    init(
        action: AvailableAction,
        role: ButtonRole? = nil,
        extraDisabled: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.action = action
        self.role = role
        self.extraDisabled = extraDisabled
        self.onTap = onTap
    }

    /// Conveniencia: deriva el rol destructivo desde `ActionPresentationCatalog`.
    static func deriving(
        action: AvailableAction,
        extraDisabled: Bool = false,
        onTap: @escaping () -> Void
    ) -> ActionMenuButton {
        ActionMenuButton(
            action: action,
            role: ActionPresentationCatalog.isDestructive(for: action.actionKey) ? .destructive : nil,
            extraDisabled: extraDisabled,
            onTap: onTap
        )
    }

    var body: some View {
        let symbol = ActionPresentationCatalog.presentation(for: action.actionKey).symbolName
        Button(role: role) {
            onTap()
        } label: {
            if !action.enabled, let reason = action.reason, !reason.isEmpty {
                Label {
                    Text(action.label)
                    Text(reason)
                } icon: {
                    Image(systemName: symbol)
                }
            } else {
                Label(action.label, systemImage: symbol)
            }
        }
        .disabled(!action.enabled || extraDisabled)
        .accessibilityHint(action.reason ?? "")
    }
}

#Preview("Habilitada / deshabilitada") {
    List {
        Section("Acciones") {
            ActionMenuButton(
                action: AvailableAction(
                    actionKey: "record_expense", label: "Registrar gasto",
                    section: "money", enabled: true, reason: nil
                )
            ) {}
            ActionMenuButton(
                action: AvailableAction(
                    actionKey: "void_transaction", label: "Anular transacción",
                    section: "money", enabled: false,
                    reason: "Necesitas el permiso «liquidar» para anular movimientos."
                ),
                role: .destructive
            ) {}
        }
    }
}
