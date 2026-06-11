import SwiftUI
import RuulCore

// MARK: - Más acciones (catálogo del Menu toolbar `+`)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo). El handler (`handleMoreAction`) y el botón viven en el archivo
// principal porque mutan @State; acá sólo el modelo + el builder.

extension EventDetailView {
    enum MoreActionKind {
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
    }

    struct MoreActionItem: Identifiable {
        let id = UUID()
        let kind: MoreActionKind
        let label: String
        let symbol: String
        let isDestructive: Bool
    }

    /// P0 fix 2026-06-08 — clasificación semántica de MoreActionKind para
    /// agrupar en el Menu toolbar.
    enum MoreActionSection: CaseIterable {
        case registrar
        case editar
        case anfitrion
        case estado
        case cancelar

        var label: String {
            switch self {
            case .registrar: return "Registrar"
            case .editar:    return "Editar"
            case .anfitrion: return "Anfitrión"
            case .estado:    return "Estado"
            case .cancelar:  return "Cancelar"
            }
        }
    }

    func moreActionSection(_ kind: MoreActionKind) -> MoreActionSection {
        switch kind {
        case .recordExpense, .createDecision, .reserveResource: return .registrar
        case .editEvent:                              return .editar
        case .changeNextHost, .configureHostRotation: return .anfitrion
        case .closeEvent:                             return .estado
        case .cancelParticipation:                    return .cancelar
        }
    }

    /// Las acciones del menú salen verbatim de `event_detail.available_actions`
    /// — el frontend no infiere ni hardcodea. Las acciones de participación
    /// (rsvp, check-in) NO van acá porque viven en la zona primaria arriba.
    func moreActions(
        _ event: CalendarEvent,
        availableActions: [AvailableAction],
        hasManageAuthority: Bool
    ) -> [MoreActionItem] {
        var out: [MoreActionItem] = []
        for action in availableActions where action.enabled {
            switch action.actionKey {
            case "record_expense":
                out.append(MoreActionItem(
                    kind: .recordExpense, label: action.label,
                    symbol: "dollarsign.circle", isDestructive: false
                ))
            case "create_decision":
                out.append(MoreActionItem(
                    kind: .createDecision, label: action.label,
                    symbol: "checkmark.seal", isDestructive: false
                ))
            case "close_event":
                if event.isScheduled {
                    out.append(MoreActionItem(
                        kind: .closeEvent, label: action.label,
                        symbol: "checkmark.seal", isDestructive: false
                    ))
                }
            case "cancel_participation":
                out.append(MoreActionItem(
                    kind: .cancelParticipation, label: action.label,
                    symbol: "xmark.circle", isDestructive: true
                ))
            case "edit_event":
                if event.isScheduled || event.status == "in_progress" {
                    out.append(MoreActionItem(
                        kind: .editEvent, label: action.label,
                        symbol: "pencil", isDestructive: false
                    ))
                }
            default:
                break
            }
        }
        // F.EVENT.8 — "Cambiar próximo anfitrión" sólo para eventos
        // recurrentes con autoridad de manage. No es action_key del backend
        // todavía (no se modeló en available_actions); lo derivamos del
        // estado: recurring + scheduled + hasManageAuthority.
        if event.isRecurring && event.isScheduled && hasManageAuthority {
            out.append(MoreActionItem(
                kind: .changeNextHost, label: "Cambiar próximo anfitrión",
                symbol: "person.crop.circle.badge.checkmark", isDestructive: false
            ))
            // F.EVENT.10 — sólo tiene sentido cuando la rotación natural aplica
            // (weekly). Para daily/monthly/yearly el host se mantiene, no rota.
            if EventDetailFormatting.recurrenceLabel(event) == "Semanal" {
                out.append(MoreActionItem(
                    kind: .configureHostRotation, label: "Configurar rotación",
                    symbol: "arrow.triangle.2.circlepath", isDestructive: false
                ))
            }
        }
        // R.2T — "Reservar recurso" sólo cuando el evento está activo
        // (scheduled o in_progress). El backend valida permisos en
        // request_resource_reservation; iOS sólo gatea por estado del evento.
        if event.isScheduled || event.status == "in_progress" {
            out.append(MoreActionItem(
                kind: .reserveResource, label: "Reservar recurso",
                symbol: "calendar.badge.checkmark", isDestructive: false
            ))
        }
        return out
    }
}
