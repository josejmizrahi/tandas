import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// R.6.AI.4 — Tool read-only que expone al modelo las reglas existentes en el
/// contexto activo. Útil para evitar sugerir reglas duplicadas o que se pisen
/// con normas ya firmadas.
@available(iOS 26.0, *)
public struct ListContextRulesTool: Tool {
    public let name = "list_context_rules"
    public let description = "Lista las reglas existentes del contexto activo (título y trigger). Úsalo para evitar duplicar una regla que ya existe."

    private let rpc: any RuulRPCClient
    private let contextId: UUID

    public init(rpc: any RuulRPCClient, contextId: UUID) {
        self.rpc = rpc
        self.contextId = contextId
    }

    @Generable
    public struct Arguments {
        @Guide(description: "Cantidad máxima de reglas a devolver. Usa 20 si no estás seguro.")
        public let limit: Int
    }

    public func call(arguments: Arguments) async throws -> String {
        let limit = max(1, min(arguments.limit, 50))
        let rules = try await rpc.listRules(contextId: contextId).prefix(limit)
        if rules.isEmpty { return "Sin reglas configuradas todavía." }
        let lines = rules.map { rule -> String in
            let trigger = rule.triggerEventType ?? "manual"
            return "- \(rule.title) · trigger: \(trigger)"
        }
        return "Reglas existentes:\n" + lines.joined(separator: "\n")
    }
}
#endif
