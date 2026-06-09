import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// R.6.AI.4 — Tool read-only que expone al modelo la actividad reciente del
/// contexto activo. Útil para detectar patrones (e.g., "Aaron llega tarde
/// seguido, sugiere multa", "casi nadie reserva el palco los lunes").
@available(iOS 26.0, *)
public struct ListContextRecentActivityTool: Tool {
    public let name = "list_context_recent_activity"
    public let description = "Lista los eventos recientes del contexto activo (qué tipo, cuándo). Úsalo para detectar patrones que justifiquen la regla."

    private let rpc: any RuulRPCClient
    private let contextId: UUID

    public init(rpc: any RuulRPCClient, contextId: UUID) {
        self.rpc = rpc
        self.contextId = contextId
    }

    @Generable
    public struct Arguments {
        @Guide(description: "Cantidad máxima de eventos a devolver (1-15). Usa 10 si no estás seguro.")
        public let limit: Int
    }

    public func call(arguments: Arguments) async throws -> String {
        let limit = max(1, min(arguments.limit, 15))
        let events = try await rpc.listActivity(
            contextId: contextId,
            limit: limit,
            before: nil,
            includeDescendants: false
        )
        if events.isEmpty { return "Sin actividad reciente." }
        let formatter = relativeDateFormatter
        let lines = events.map { event -> String in
            let when = event.occurredAt.map { formatter.localizedString(for: $0, relativeTo: .now) } ?? "—"
            return "- \(event.eventType) · \(when)"
        }
        return "Actividad reciente:\n" + lines.joined(separator: "\n")
    }

    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "es_MX")
        return f
    }
}
#endif
