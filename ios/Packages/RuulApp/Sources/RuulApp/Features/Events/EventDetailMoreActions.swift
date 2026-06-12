import SwiftUI
import RuulCore

// MARK: - Más acciones (catálogo del Menu toolbar `+`)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo). El handler (`handleMoreAction`) y el botón viven en el archivo
// principal porque mutan @State; acá sólo el modelo + el builder.

extension EventDetailView {
    enum MoreActionKind {
        /// Founder 2026-06-12 — el toolbar lista TODAS las acciones del evento.
        /// rsvp_event renderiza como submenu Picker (Voy/Tal vez/No voy).
        case rsvp
        /// check_in_participant sobre uno mismo ("Marcar mi llegada").
        case selfCheckIn
        case recordExpense
        case createDecision
        case closeEvent
        case cancelParticipation
        case editEvent
        /// F.EVENT.8 — override del próximo anfitrión.
        case changeNextHost
        /// F.EVENT.10 — configurar el ciclo de rotación de host.
        case configureHostRotation
        /// R.2T — reservar un recurso del contexto para este evento.
        case reserveResource
        /// Action_key del backend sin dispatcher iOS todavía — se muestra
        /// deshabilitado con "Próximamente" (doctrina R.5X.fix.A), nunca se
        /// dropea en silencio.
        case unsupported
    }

    struct MoreActionItem: Identifiable {
        let id = UUID()
        let kind: MoreActionKind
        let label: String
        let symbol: String
        let isDestructive: Bool
        /// P0.5 — la `AvailableAction` original del backend cuando el item
        /// viene de `available_actions[]`. nil para los items derivados
        /// localmente (changeNextHost / configureHostRotation / reserveResource)
        /// que aún no se modelan como action_key. Con la action presente, el
        /// Menu renderiza vía `ActionMenuButton` (reason visible si disabled).
        let action: AvailableAction?
    }

    /// P0 fix 2026-06-08 — clasificación semántica de MoreActionKind para
    /// agrupar en el Menu toolbar.
    enum MoreActionSection: CaseIterable {
        case asistencia
        case registrar
        case editar
        case anfitrion
        case estado
        case cancelar
        case otras

        var label: String {
            switch self {
            case .asistencia: return "Asistencia"
            case .registrar:  return "Registrar"
            case .editar:     return "Editar"
            case .anfitrion:  return "Anfitrión"
            case .estado:     return "Estado"
            case .cancelar:   return "Cancelar"
            case .otras:      return "Otras"
            }
        }
    }

    func moreActionSection(_ kind: MoreActionKind) -> MoreActionSection {
        switch kind {
        case .rsvp, .selfCheckIn:                     return .asistencia
        case .recordExpense, .createDecision, .reserveResource: return .registrar
        case .editEvent:                              return .editar
        case .changeNextHost, .configureHostRotation: return .anfitrion
        case .closeEvent:                             return .estado
        case .cancelParticipation:                    return .cancelar
        case .unsupported:                            return .otras
        }
    }

    /// Las acciones del menú salen verbatim de `event_detail.available_actions`
    /// — el frontend no infiere ni hardcodea. Las acciones de participación
    /// (rsvp, check-in) NO van acá porque viven en la zona primaria arriba.
    /// P0.5 — las acciones disabled TAMBIÉN entran al menú: `ActionMenuButton`
    /// las muestra deshabilitadas con su `reason` como subtítulo.
    func moreActions(
        _ event: CalendarEvent,
        availableActions: [AvailableAction],
        hasManageAuthority: Bool
    ) -> [MoreActionItem] {
        var out: [MoreActionItem] = []
        for action in availableActions {
            switch action.actionKey {
            case "rsvp_event":
                out.append(MoreActionItem(
                    kind: .rsvp, label: action.label,
                    symbol: "person.crop.circle.badge.questionmark", isDestructive: false,
                    action: action
                ))
            case "check_in_participant":
                out.append(MoreActionItem(
                    kind: .selfCheckIn, label: action.label,
                    symbol: "checkmark.circle", isDestructive: false,
                    action: action
                ))
            case "record_expense":
                out.append(MoreActionItem(
                    kind: .recordExpense, label: action.label,
                    symbol: "dollarsign.circle", isDestructive: false,
                    action: action
                ))
            case "create_decision":
                out.append(MoreActionItem(
                    kind: .createDecision, label: action.label,
                    symbol: "checkmark.seal", isDestructive: false,
                    action: action
                ))
            case "close_event":
                if event.isScheduled {
                    out.append(MoreActionItem(
                        kind: .closeEvent, label: action.label,
                        symbol: "checkmark.seal", isDestructive: false,
                        action: action
                    ))
                }
            case "cancel_participation":
                out.append(MoreActionItem(
                    kind: .cancelParticipation, label: action.label,
                    symbol: "xmark.circle", isDestructive: true,
                    action: action
                ))
            case "edit_event":
                if event.isScheduled || event.status == "in_progress" {
                    out.append(MoreActionItem(
                        kind: .editEvent, label: action.label,
                        symbol: "pencil", isDestructive: false,
                        action: action
                    ))
                }
            default:
                // Doctrina R.5X.fix.A — action_key sin dispatcher iOS: visible,
                // deshabilitado y honesto ("Próximamente"). Nunca se dropea.
                out.append(MoreActionItem(
                    kind: .unsupported, label: action.label,
                    symbol: "hourglass", isDestructive: false,
                    action: AvailableAction(
                        actionKey: action.actionKey, label: action.label,
                        section: action.section, enabled: false,
                        reason: "Próximamente"
                    )
                ))
            }
        }
        // F.EVENT.8 — "Cambiar próximo anfitrión" sólo para eventos
        // recurrentes con autoridad de manage. No es action_key del backend
        // todavía (no se modeló en available_actions); lo derivamos del
        // estado: recurring + scheduled + hasManageAuthority.
        if event.isRecurring && event.isScheduled && hasManageAuthority {
            out.append(MoreActionItem(
                kind: .changeNextHost, label: "Cambiar próximo anfitrión",
                symbol: "person.crop.circle.badge.checkmark", isDestructive: false,
                action: nil
            ))
            // F.EVENT.10 — sólo tiene sentido cuando la rotación natural aplica
            // (weekly). Para daily/monthly/yearly el host se mantiene, no rota.
            if EventDetailFormatting.recurrenceLabel(event) == "Semanal" {
                out.append(MoreActionItem(
                    kind: .configureHostRotation, label: "Configurar rotación",
                    symbol: "arrow.triangle.2.circlepath", isDestructive: false,
                    action: nil
                ))
            }
        }
        // R.2T — "Reservar recurso" sólo cuando el evento está activo
        // (scheduled o in_progress). El backend valida permisos en
        // request_resource_reservation; iOS sólo gatea por estado del evento.
        if event.isScheduled || event.status == "in_progress" {
            out.append(MoreActionItem(
                kind: .reserveResource, label: "Reservar recurso",
                symbol: "calendar.badge.checkmark", isDestructive: false,
                action: nil
            ))
        }
        return out
    }
}
