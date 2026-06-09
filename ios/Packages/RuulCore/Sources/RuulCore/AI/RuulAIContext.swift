import Foundation

/// R.6.AI.5 — Pre-aggregation pattern para features de AI on-device.
/// Doctrina founder-firmada 2026-06-09.
///
/// Ruul siempre sabe qué slice del contexto necesita el modelo para sugerir.
/// En vez de pagar el costo de tool calling (~1200 tokens en definitions +
/// outputs entre ida y vuelta), pre-fetch UNA vez vía `context_summary()` y
/// inyecta como prefix compacto del prompt. Resultado: budget de 4096 tokens
/// protegido + 1 RPC en vez de N.
///
/// Tool calling queda reservado para casos genuinamente agénticos (modelo
/// decide entre N caminos posibles), no para fetch predecible.
///
/// **Patrón canónico para cualquier service AI nuevo:**
/// ```swift
/// let snapshot = try await RuulAIContext.compact(
///     rpc: rpc, contextId: contextId, fields: RuulAIContext.forXxxFeature
/// )
/// let session = LanguageModelSession(instructions: instructions)
/// let response = try await session.respond(
///     to: "\(snapshot.prefix)\n\nPetición: \(userPrompt)",
///     generating: MyGenerable.self
/// )
/// // Surface snapshot.considered en la UI como chips "DATOS CONSIDERADOS".
/// ```
public enum RuulAIContext {
    /// Slice del contexto que se puede incluir en el prefix. Cada caso lleva
    /// un `limit` duro de items para mantener compacto el prefix.
    public enum Field: Sendable, Hashable {
        case members(limit: Int)
        case resources(limit: Int)
        case recentActivity(limit: Int)
        case rules(limit: Int)
        case openObligations(limit: Int)
        case upcomingEvents(limit: Int)
    }

    /// Resultado del builder: el `prefix` para inyectar al prompt + un
    /// manifest `considered` que la UI consume como chips de transparencia.
    public struct Snapshot: Sendable, Equatable {
        public let prefix: String
        public let considered: [Considered]

        public init(prefix: String, considered: [Considered]) {
            self.prefix = prefix
            self.considered = considered
        }
    }

    public struct Considered: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let summary: String

        public init(id: String, label: String, summary: String) {
            self.id = id
            self.label = label
            self.summary = summary
        }
    }

    /// Presets canónicos por feature. Cada feature usa SOLO los fields que
    /// realmente necesita para mantener el prefix compacto.
    public static let forRuleSuggestion: [Field] = [
        .members(limit: 10),
        .resources(limit: 10),
        .rules(limit: 10)
    ]

    public static let forIntentSuggestion: [Field] = [
        .upcomingEvents(limit: 3),
        .openObligations(limit: 3)
    ]

    public static let forActivitySummary: [Field] = [
        .recentActivity(limit: 15)
    ]

    /// R.6.AI.7 — Expense necesita solo miembros (para que el modelo
    /// resuelva payerName/excludedNames a nombres exactos del contexto).
    public static let forExpenseSuggestion: [Field] = [
        .members(limit: 20)
    ]

    /// Construye el snapshot con un solo RPC (`context_summary`) y formato
    /// compacto. Items vacíos se omiten del prefix (excepto Rules, que se
    /// reporta explícito "ninguna" para anti-duplicación).
    public static func compact(
        rpc: any RuulRPCClient,
        contextId: UUID,
        fields: [Field]
    ) async throws -> Snapshot {
        let summary = try await rpc.contextSummary(contextId: contextId)
        var parts: [String] = ["Contexto: \(summary.context.displayName)"]
        var considered: [Considered] = []

        for field in fields {
            switch field {
            case .members(let limit):
                let items = summary.members.prefix(limit)
                guard !items.isEmpty else { continue }
                let names = items.map(\.displayName).joined(separator: ", ")
                parts.append("Miembros (\(summary.membersCount)): \(names)")
                considered.append(Considered(
                    id: "members",
                    label: "Miembros del contexto",
                    summary: "\(items.count) de \(summary.membersCount): \(names)"
                ))

            case .resources(let limit):
                let items = summary.resources.prefix(limit)
                guard !items.isEmpty else { continue }
                let names = items.map { "\($0.displayName) (\($0.resourceType))" }
                    .joined(separator: ", ")
                parts.append("Recursos (\(summary.resourcesCount)): \(names)")
                considered.append(Considered(
                    id: "resources",
                    label: "Recursos del contexto",
                    summary: "\(items.count) de \(summary.resourcesCount): \(names)"
                ))

            case .recentActivity(let limit):
                let items = summary.recentActivity.prefix(limit)
                guard !items.isEmpty else { continue }
                let types = items.map(\.eventType).joined(separator: ", ")
                parts.append("Actividad reciente: \(types)")
                considered.append(Considered(
                    id: "activity",
                    label: "Actividad reciente",
                    summary: "\(items.count): \(types)"
                ))

            case .rules(let limit):
                let items = summary.activeRules.prefix(limit)
                if items.isEmpty {
                    // Importante reportar explícito para que el modelo NO
                    // crea que hay reglas escondidas que evitan duplicación.
                    parts.append("Reglas existentes: ninguna")
                    considered.append(Considered(
                        id: "rules",
                        label: "Reglas existentes",
                        summary: "Sin reglas configuradas todavía"
                    ))
                    continue
                }
                let titles = items.map(\.title).joined(separator: ", ")
                parts.append("Reglas existentes (\(summary.activeRules.count)): \(titles)")
                considered.append(Considered(
                    id: "rules",
                    label: "Reglas existentes",
                    summary: "\(items.count) de \(summary.activeRules.count): \(titles)"
                ))

            case .openObligations(let limit):
                let items = summary.money.openObligations.prefix(limit)
                guard !items.isEmpty else { continue }
                let descs = items.map { o -> String in
                    let amount = o.amount.map { "\($0) \(o.currency ?? "")" } ?? "—"
                    return "\(o.obligationType): \(amount)"
                }.joined(separator: ", ")
                parts.append("Obligaciones abiertas (\(summary.openObligationsCount)): \(descs)")
                considered.append(Considered(
                    id: "obligations",
                    label: "Obligaciones abiertas",
                    summary: descs
                ))

            case .upcomingEvents(let limit):
                let items = summary.upcomingEvents.prefix(limit)
                guard !items.isEmpty else { continue }
                let titles = items.map(\.title).joined(separator: ", ")
                parts.append("Próximos eventos: \(titles)")
                considered.append(Considered(
                    id: "events",
                    label: "Próximos eventos",
                    summary: titles
                ))
            }
        }

        return Snapshot(prefix: parts.joined(separator: "\n"), considered: considered)
    }
}
