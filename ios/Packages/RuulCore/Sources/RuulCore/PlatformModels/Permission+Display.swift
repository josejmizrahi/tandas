import Foundation

public extension Permission {
    /// Spanish-MX label for use in the GroupRolesSheet / RoleEditor UI.
    /// Falls back to the `rawString` for `.unknown` so future server-
    /// added permissions still render something meaningful.
    var humanLabel: String {
        switch self {
        case .modifyGovernance: return "Cambiar gobierno"
        case .modifyRules:      return "Editar reglas"
        case .modifyMembers:    return "Editar miembros"
        case .assignRoles:      return "Asignar roles"
        case .removeMember:     return "Echar miembros"
        case .issueFine:        return "Emitir multas"
        case .voidFine:         return "Anular multas"
        case .markFinePaid:     return "Marcar multas pagadas"
        case .closeAppeal:      return "Cerrar apelaciones"
        case .createVotes:      return "Iniciar votaciones"
        case .castVote:         return "Votar"
        case .manageEvents:     return "Administrar eventos"
        case .manageModules:    return "Activar módulos"

        case .assignSlot:       return "Asignar cupos"
        case .bookSlot:         return "Reservar cupos"
        case .approveSlotSwap:  return "Aprobar cambios de cupo"

        case .fundContribute:   return "Aportar al fondo"
        case .fundWithdraw:     return "Retirar del fondo"
        case .fundAudit:        return "Auditar el fondo"

        case .expenseSubmit:    return "Enviar gastos"
        case .expenseApprove:   return "Aprobar gastos"

        case .transferRight:    return "Transferir derechos"
        case .delegateRight:    return "Delegar derechos"
        case .revokeRight:      return "Revocar derechos"
        case .suspendRight:     return "Suspender derechos"
        case .exerciseRight:    return "Ejercer derechos"

        case .unknown(let raw): return raw
        }
    }

    /// Short hint describing what the permission unlocks. Used as a
    /// secondary line under the checkbox in `GroupRoleEditorSheet`.
    var hint: String {
        switch self {
        case .modifyGovernance: return "Editar quién decide qué."
        case .modifyRules:      return "Crear, editar o apagar reglas."
        case .modifyMembers:    return "Cambiar nombre o foto de miembros."
        case .assignRoles:      return "Otorgar o quitar roles dentro del grupo."
        case .removeMember:     return "Sacar a alguien del grupo."
        case .issueFine:        return "Crear una multa manual contra un miembro."
        case .voidFine:         return "Cancelar una multa después de emitida."
        case .markFinePaid:     return "Marcar como pagada la multa de otro miembro."
        case .closeAppeal:      return "Resolver una apelación de multa."
        case .createVotes:      return "Abrir una votación de cualquier tipo."
        case .castVote:         return "Emitir un voto en votaciones abiertas."
        case .manageEvents:     return "Cerrar, cancelar o editar cualquier evento."
        case .manageModules:    return "Activar o desactivar módulos del grupo."

        case .assignSlot:       return "Otorgar cupos a miembros (palco, casa…)."
        case .bookSlot:         return "Reservar un cupo para sí."
        case .approveSlotSwap:  return "Aceptar solicitudes de cambio de cupo."

        case .fundContribute:   return "Depositar dinero al fondo."
        case .fundWithdraw:     return "Retirar dinero del fondo."
        case .fundAudit:        return "Consultar movimientos sin poder mover dinero."

        case .expenseSubmit:    return "Subir un gasto del grupo para aprobación."
        case .expenseApprove:   return "Autorizar gastos pendientes."

        case .transferRight:    return "Pasar un derecho a otro miembro."
        case .delegateRight:    return "Delegar el uso temporal de un derecho."
        case .revokeRight:      return "Quitar un derecho permanentemente."
        case .suspendRight:     return "Pausar el uso de un derecho."
        case .exerciseRight:    return "Usar un derecho como holder o auditor."

        case .unknown:          return "Permiso reciente del servidor (sin descripción local)."
        }
    }

    /// Category for grouping in the role editor checklist.
    var category: Category {
        switch self {
        case .modifyGovernance, .modifyRules, .modifyMembers,
             .assignRoles, .removeMember, .createVotes, .castVote,
             .manageEvents, .manageModules:
            return .governance
        case .issueFine, .voidFine, .markFinePaid, .closeAppeal:
            return .fines
        case .assignSlot, .bookSlot, .approveSlotSwap:
            return .slots
        case .fundContribute, .fundWithdraw, .fundAudit:
            return .fund
        case .expenseSubmit, .expenseApprove:
            return .expenses
        case .transferRight, .delegateRight, .revokeRight,
             .suspendRight, .exerciseRight:
            return .rights
        case .unknown:
            return .other
        }
    }

    enum Category: Int, CaseIterable, Sendable, Hashable {
        case governance, fines, slots, fund, expenses, rights, other

        public var title: String {
            switch self {
            case .governance: return "Gobierno y miembros"
            case .fines:      return "Multas"
            case .slots:      return "Cupos y reservas"
            case .fund:       return "Fondo común"
            case .expenses:   return "Gastos"
            case .rights:     return "Derechos"
            case .other:      return "Otros"
            }
        }
    }
}

public extension RoleDefinition {
    /// User-facing label. System roles have hardcoded localized strings;
    /// custom roles fall back to their stored `label` and then to a
    /// best-effort humanization of the id (`seat_owner` → `Seat owner`).
    var humanLabel: String {
        if let provided = label, !provided.isEmpty { return provided }
        switch id {
        case "founder": return "Fundador"
        case "member":  return "Miembro"
        case "host":    return "Anfitrión"
        default:        return id
            .split(separator: "_")
            .map { word -> String in
                let first = word.prefix(1).uppercased()
                let rest  = word.dropFirst()
                return first + rest
            }
            .joined(separator: " ")
        }
    }
}
