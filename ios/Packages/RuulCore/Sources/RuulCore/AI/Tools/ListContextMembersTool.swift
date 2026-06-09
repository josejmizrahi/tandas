import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// R.6.AI.4 — Tool read-only que expone al modelo los miembros del contexto
/// activo. Útil para reglas que aplican a personas (e.g., "el último que llega
/// paga", "si Aaron cancela, multa al doble"). Doctrina founder:
/// **el modelo NO decide, solo lee** para sugerir mejor.
@available(iOS 26.0, *)
public struct ListContextMembersTool: Tool {
    public let name = "list_context_members"
    public let description = "Lista los miembros del contexto activo con nombre y rol. Úsalo cuando la regla pueda aplicar a personas específicas o necesites saber cuántas personas hay."

    private let rpc: any RuulRPCClient
    private let contextId: UUID

    public init(rpc: any RuulRPCClient, contextId: UUID) {
        self.rpc = rpc
        self.contextId = contextId
    }

    @Generable
    public struct Arguments {
        @Guide(description: "Cantidad máxima de miembros a devolver. Usa 20 si no estás seguro.")
        public let limit: Int
    }

    public func call(arguments: Arguments) async throws -> String {
        let limit = max(1, min(arguments.limit, 50))
        let summary = try await rpc.contextSummary(contextId: contextId)
        let members = summary.members.prefix(limit)
        if members.isEmpty { return "Sin miembros visibles." }
        let lines = members.map { m -> String in
            let roles = m.roles.isEmpty ? "" : " · \(m.roles.joined(separator: ","))"
            return "- \(m.displayName)\(roles)"
        }
        return "Miembros (\(summary.members.count)):\n" + lines.joined(separator: "\n")
    }
}
#endif
