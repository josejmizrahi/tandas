import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// R.6.AI.4 — Tool read-only que expone al modelo los recursos del contexto
/// activo con su tipo. Útil para reglas atadas a recursos específicos (e.g.,
/// "si nadie reserva la casa el fin de semana", "si el palco está sin uso").
@available(iOS 26.0, *)
public struct ListContextResourcesTool: Tool {
    public let name = "list_context_resources"
    public let description = "Lista los recursos del contexto activo con su nombre y tipo. Úsalo cuando la regla pueda atarse a un recurso concreto (casa, palco, vehículo, etc.)."

    private let rpc: any RuulRPCClient
    private let contextId: UUID

    public init(rpc: any RuulRPCClient, contextId: UUID) {
        self.rpc = rpc
        self.contextId = contextId
    }

    @Generable
    public struct Arguments {
        @Guide(description: "Cantidad máxima de recursos a devolver. Usa 20 si no estás seguro.")
        public let limit: Int
    }

    public func call(arguments: Arguments) async throws -> String {
        let limit = max(1, min(arguments.limit, 50))
        let resources = try await rpc.listContextResources(contextId: contextId).prefix(limit)
        if resources.isEmpty { return "Sin recursos en este contexto." }
        let lines = resources.map { "- \($0.displayName) (\($0.resourceType))" }
        return "Recursos:\n" + lines.joined(separator: "\n")
    }
}
#endif
