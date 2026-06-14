import SwiftUI
import RuulCore

/// F.2X — Sección reusable "⚡ Acciones rápidas" que renderiza `[AvailableAction]`
/// del backend.
///
/// Doctrina: el frontend NO infiere acciones. La lista, el `label`, el
/// `enabled` y el `reason` son verbatim del backend. iOS sólo agrega
/// presentación (ícono/tint del catálogo) y enrutamiento (vía `ActionRouting`).
///
/// **Hard no:** ningún branch por tipo de recurso/evento/decisión.
public struct QuickActionsSection: View {
    private let title: String
    private let actions: [AvailableAction]
    private let scope: ActionScope
    private let router: ActionRouting

    /// - Parameters:
    ///   - title: Encabezado de la sección. Default "Acciones rápidas".
    ///   - actions: Lista de acciones canónicas del backend.
    ///   - scope: Objeto sobre el cual estas acciones operan.
    ///   - router: Receptor de `open(destination)`.
    public init(
        title: String = "Acciones rápidas",
        actions: [AvailableAction],
        scope: ActionScope,
        router: ActionRouting
    ) {
        self.title = title
        self.actions = actions
        self.scope = scope
        self.router = router
    }

    public var body: some View {
        if actions.isEmpty {
            EmptyView()
        } else {
            Section {
                ForEach(actions) { action in
                    QuickActionRow(action: action, scope: scope, router: router)
                }
            } header: {
                Label(title, systemImage: "bolt.fill")
                    .font(.subheadline)
            }
        }
    }
}

/// Una fila individual de Quick Action. Render fijo (label + ícono + reason
/// si está disabled). No conoce el dominio del objeto.
private struct QuickActionRow: View {
    let action: AvailableAction
    let scope: ActionScope
    let router: ActionRouting

    var body: some View {
        let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
        Button {
            router.open(ActionRouter.destination(for: action, in: scope))
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: presentation.symbolName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(action.enabled ? presentation.tint : Color.secondary)
                    .frame(width: Theme.IconSize.xs, alignment: .center)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(action.label)
                        .font(.body)
                        .foregroundStyle(action.enabled ? Color.primary : Color.secondary)
                    if !action.enabled, let reason = action.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if action.enabled {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!action.enabled)
        .accessibilityHint(action.reason ?? "")
    }
}

// MARK: - Previews

#Preview("Context home — founder (todo enabled)") {
    @Previewable @State var router = NoopActionRouter()
    let ctxId = UUID()
    return Form {
        QuickActionsSection(
            actions: [
                AvailableAction(actionKey: "create_resource", label: "Crear recurso",
                                section: "resources", enabled: true,
                                reason: "Tienes permiso para crear recursos en este espacio"),
                AvailableAction(actionKey: "create_event", label: "Crear evento",
                                section: "calendar", enabled: true,
                                reason: "Tienes permiso para crear eventos"),
                AvailableAction(actionKey: "create_decision", label: "Crear decisión",
                                section: "decisions", enabled: true,
                                reason: "Tienes permiso para abrir decisiones"),
                AvailableAction(actionKey: "record_expense", label: "Registrar gasto",
                                section: "money", enabled: true,
                                reason: "Tienes permiso para registrar gastos"),
                AvailableAction(actionKey: "invite_member", label: "Invitar miembro",
                                section: "members", enabled: true,
                                reason: "Tienes permiso para invitar miembros"),
            ],
            scope: .context(ctxId),
            router: router
        )
    }
}

#Preview("Resource detail — Casa Valle (USE only)") {
    @Previewable @State var router = NoopActionRouter()
    let resId = UUID()
    return Form {
        QuickActionsSection(
            actions: [
                AvailableAction(actionKey: "reserve_resource", label: "Reservar",
                                section: "reservations", enabled: true,
                                reason: "Tienes USE sobre el recurso"),
                AvailableAction(actionKey: "view_ownership", label: "Ver participaciones",
                                section: "ownership", enabled: false,
                                reason: "Requiere OWN o GOVERN"),
                AvailableAction(actionKey: "attach_document", label: "Adjuntar documento",
                                section: "documents", enabled: true,
                                reason: nil),
            ],
            scope: .resource(resId),
            router: router
        )
    }
}

#Preview("Event detail — Cena viernes (host)") {
    @Previewable @State var router = NoopActionRouter()
    let evId = UUID()
    return Form {
        QuickActionsSection(
            actions: [
                AvailableAction(actionKey: "rsvp_event", label: "Responder asistencia",
                                section: "participation", enabled: true,
                                reason: "Puedes responder asistencia"),
                AvailableAction(actionKey: "close_event", label: "Cerrar evento",
                                section: "participation", enabled: true,
                                reason: "Eres el anfitrión del evento"),
                AvailableAction(actionKey: "record_expense", label: "Registrar gasto",
                                section: "money", enabled: true,
                                reason: "Puedes registrar un gasto asociado al evento"),
                AvailableAction(actionKey: "attach_document", label: "Adjuntar documento",
                                section: "documents", enabled: true,
                                reason: nil),
            ],
            scope: .event(evId),
            router: router
        )
    }
}

#Preview("Empty — sin acciones") {
    @Previewable @State var router = NoopActionRouter()
    return Form {
        QuickActionsSection(
            actions: [],
            scope: .context(UUID()),
            router: router
        )
    }
}
