import SwiftUI
import RuulUI
import RuulCore

// MARK: - status

public struct StatusSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "status",
        priority: 90,
        isEnabledFor: { caps in caps.contains(CapabilityID.status) },
        render: { ctx in AnyView(StatusSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "ESTADO") {
            StubMetadataRow(label: "Actual", value: statusLabel)
            StubDivider()
            StubMetadataRow(label: "Actualizado", value: context.resource.updatedAt.ruulShortDate)
        }
    }

    private var statusLabel: String {
        let raw = context.resource.status
        switch raw.lowercased() {
        case "active":     return "Activo"
        case "scheduled":  return "Programado"
        case "open":       return "Abierto"
        case "closed":     return "Cerrado"
        case "cancelled":  return "Cancelado"
        case "completed":  return "Completado"
        case "draft":      return "Borrador"
        default:           return raw.capitalized
        }
    }
}

