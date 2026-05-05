import Foundation

/// Maps RuleTrigger / RuleCondition list into human-readable Spanish
/// strings for the EditRuleSheet "CÓMO FUNCIONA" section. V1 ships
/// es-MX only; future Fase 5 multi-locale is out of scope.
enum RuleSummaryFormatter {
    static func summarize(trigger: RuleTrigger) -> String {
        switch trigger.eventType {
        case .eventClosed:
            return "Cuando se cierra un evento"
        case .checkInRecorded:
            return "Cuando alguien hace check-in"
        case .rsvpChangedSameDay:
            return "Cuando alguien cambia su RSVP el mismo día del evento"
        case .hoursBeforeEvent:
            if let h = trigger.config["hours"]?.intValue {
                return "\(h) horas antes de un evento"
            }
            return "Horas antes de un evento"
        case .rsvpSubmitted:
            return "Cuando alguien responde RSVP"
        case .rsvpDeadlinePassed:
            return "Cuando cierra la deadline de RSVP"
        case .eventDescriptionMissing:
            return "Cuando falta la descripción del evento"
        default:
            return trigger.eventType.rawString
        }
    }

    static func summarize(conditions: [RuleCondition]) -> String? {
        let lines = conditions.compactMap(summarize(condition:))
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " · ")
    }

    private static func summarize(condition: RuleCondition) -> String? {
        switch condition.type {
        case .alwaysTrue:
            return nil  // skip — always-true is the absence of a condition
        case .responseStatusIs:
            if let status = condition.config["status"]?.stringValue {
                return "Si la respuesta es \(humanStatus(status))"
            }
            return "Si la respuesta tiene un estado"
        case .checkInExists:
            if condition.config["exists"]?.boolValue == false {
                return "Si no hizo check-in"
            }
            return "Si hizo check-in"
        case .checkInMinutesLate:
            if let n = condition.config["thresholdMinutes"]?.intValue {
                return "Si llegó \(n)+ minutos tarde"
            }
            return "Si llegó tarde"
        case .eventDescriptionMissing:
            return "Si falta la descripción"
        default:
            return condition.type.rawString
        }
    }

    private static func humanStatus(_ raw: String) -> String {
        switch raw {
        case "pending":
            return "pendiente"
        case "going":
            return "asistirá"
        case "maybe":
            return "tal vez"
        case "declined":
            return "no asistirá"
        case "waitlisted":
            return "en lista de espera"
        default:
            return raw
        }
    }
}
