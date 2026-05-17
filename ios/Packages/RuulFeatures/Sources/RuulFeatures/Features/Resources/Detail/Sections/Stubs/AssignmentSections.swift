import SwiftUI
import RuulUI
import RuulCore

// MARK: - assignment

public struct AssignmentSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "assignment",
        priority: 350,
        isEnabledFor: { caps in caps.contains("assignment") },
        render: { ctx in AnyView(AssignmentSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "ASIGNACIÓN") {
            if let name = assigneeName {
                StubMetadataRow(label: "Asignado a", value: name)
            } else {
                StubPlaceholderRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    subtitle: "Sin asignación todavía."
                )
            }
        }
    }

    private var assigneeName: String? {
        guard
            let raw = context.resource.metadata["assigned_member_id"]?.stringValue
                ?? context.resource.metadata["assignee_id"]?.stringValue,
            let id = UUID(uuidString: raw),
            let member = context.memberDirectory[id]
        else { return nil }
        return member.displayName
    }
}

// MARK: - booking

public struct BookingSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "booking",
        priority: 380,
        isEnabledFor: { caps in caps.contains("booking") },
        render: { ctx in AnyView(BookingSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "RESERVAS") {
            StubPlaceholderRow(
                symbol: "calendar.badge.clock",
                subtitle: "Para assets, las reservas viven en la sección CUPOS de abajo."
            )
        }
    }
}

// MARK: - swap

public struct SwapSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "swap",
        priority: 750,
        isEnabledFor: { caps in caps.contains("swap") },
        render: { ctx in AnyView(SwapSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "INTERCAMBIO") {
            StubPlaceholderRow(
                symbol: "arrow.left.arrow.right.circle",
                subtitle: "Pedir o aceptar swaps llegará en una próxima versión."
            )
        }
    }
}
