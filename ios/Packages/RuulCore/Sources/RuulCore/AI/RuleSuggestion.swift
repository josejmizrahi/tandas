import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.1 — Estructura `@Generable` que el modelo on-device llena para
/// sugerir una regla a partir del lenguaje natural del usuario.
///
/// El mapeo a las 5 plantillas canónicas de `CreateRuleWizard.Template` es
/// 1:1 vía `templateKey` (raw string para no acoplar RuulCore al UI enum).
///
/// Doctrina founder R.6: el modelo NUNCA decide aprobar/rechazar; sólo
/// pre-llena un wizard que el usuario confirma. La regla creada pasa por la
/// misma RPC que cualquier regla manual.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct RuleSuggestion: Sendable, Equatable {
    @Guide(description: "Plantilla canónica. Valores válidos: lateFee, sameDayCancellation, lateReservationCancel, expenseAlert, textNorm.")
    public let templateKey: String

    @Guide(description: "Título corto de la regla en español, máximo 8 palabras.")
    public let title: String

    @Guide(description: "Monto de la multa en MXN (sólo para lateFee, sameDayCancellation, lateReservationCancel). 0 si no aplica.")
    public let fineAmount: Double

    @Guide(description: "Minutos de tolerancia para lateFee, entre 5 y 120. 0 si no aplica.")
    public let thresholdMinutes: Int

    @Guide(description: "Horas mínimas de anticipación para lateReservationCancel, entre 6 y 168. 0 si no aplica.")
    public let lateCancelHours: Int

    @Guide(description: "Monto a partir del cual aplica para expenseAlert, en MXN. 0 si no aplica.")
    public let expenseThreshold: Double

    @Guide(description: "Texto de la norma (sólo para textNorm). Cadena vacía si no aplica.")
    public let normText: String

    @Guide(description: "Una frase corta en español explicando qué hace la regla y cuándo aplica.")
    public let rationale: String
}
#endif
