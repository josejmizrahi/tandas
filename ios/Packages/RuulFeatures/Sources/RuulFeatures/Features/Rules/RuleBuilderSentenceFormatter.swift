import Foundation
import RuulCore

/// Translates a `RuleBuilderTemplate` + filled params into a human-readable
/// Spanish sentence for the sticky bottom preview during builder fase 2 +
/// for the publish review sheet in fase 3.
///
/// Per Plans/Active/Governance.md §11 + memoria `feedback_rules_ux_human`:
/// **never expose trigger/condition/consequence jargon**. The sentence is
/// the source of truth shown to the user; the JSON behind it stays hidden.
///
/// Beta 1: hardcoded copy per template id. Future: derive from shape pieces'
/// `.strings` files when the catalog grows.
public enum RuleBuilderSentenceFormatter {
    /// Short single-line summary shown in cards + sticky footer.
    public static func summary(
        template: RuleBuilderTemplate,
        params: [String: JSONConfig]
    ) -> String {
        switch template.id {
        case "late_arrival_fine":
            let mins   = paramInt(params, "minutes") ?? 15
            let amount = paramInt(params, "amount") ?? 200
            return "Si alguien llega \(mins)+ minutos tarde, se cobra una multa de \(currency(amount))."

        case "no_show_fine":
            let amount = paramInt(params, "amount") ?? 300
            return "Si alguien no asiste, se cobra una multa de \(currency(amount))."

        case "same_day_cancel_fine":
            let amount = paramInt(params, "amount") ?? 250
            return "Si alguien cancela su asistencia el mismo día, se cobra una multa de \(currency(amount))."

        case "no_rsvp_fine":
            let amount = paramInt(params, "amount") ?? 150
            return "Si alguien no responde antes de la fecha límite, se cobra una multa de \(currency(amount))."

        case "host_no_menu_fine":
            let hours  = paramInt(params, "hours") ?? 24
            let amount = paramInt(params, "amount") ?? 100
            return "Si el anfitrión no propone plan \(hours)h antes del evento, se cobra una multa de \(currency(amount))."

        case "expense_threshold_warning":
            // threshold_cents is MXN cents — divide by 100 for the display
            // value users entered (Form will render in whole MXN).
            let cents = paramInt(params, "threshold_cents") ?? 200_000
            return "Si alguien registra un gasto mayor a \(currency(cents / 100)), el grupo recibe un aviso en la actividad."

        default:
            return template.descriptionES
        }
    }

    /// Two-three sentence elaboration shown in the publish review sheet.
    /// Includes the edge case the user should know about per template.
    public static func detail(
        template: RuleBuilderTemplate,
        params: [String: JSONConfig]
    ) -> String {
        let base = summary(template: template, params: params)
        let footnote: String
        switch template.id {
        case "late_arrival_fine":
            footnote = "La regla se evalúa cuando el miembro hace check-in. Tarde = más de los minutos configurados después de la hora de inicio."
        case "no_show_fine":
            footnote = "La regla se evalúa al cerrar el evento. Aplica a miembros que no registraron check-in."
        case "same_day_cancel_fine":
            footnote = "Aplica si el cambio de RSVP a \"no voy\" sucede el día del evento."
        case "no_rsvp_fine":
            footnote = "Aplica a quienes no hayan registrado RSVP cuando llega la fecha límite del evento."
        case "host_no_menu_fine":
            footnote = "Aplica al anfitrión asignado al evento si no comunicó el plan antes del corte."
        case "expense_threshold_warning":
            footnote = "El aviso queda en el feed de actividad del grupo. Los administradores lo ven al momento; no se cobra ni se abre votación. Útil para detectar gastos grandes sin pre-aprobación."
        default:
            footnote = ""
        }
        return footnote.isEmpty ? base : base + "\n\n" + footnote
    }

    // MARK: Helpers

    private static func paramInt(_ params: [String: JSONConfig], _ key: String) -> Int? {
        params[key]?.intValue
    }

    private static func currency(_ amount: Int) -> String {
        // MXN whole units, no decimals — matches RuleShapeField.kind = .currency
        // in v1Fallback (cents-equivalent comment is misleading; field stores
        // whole MXN). Format: `$200 MXN`.
        "$\(amount) MXN"
    }
}
