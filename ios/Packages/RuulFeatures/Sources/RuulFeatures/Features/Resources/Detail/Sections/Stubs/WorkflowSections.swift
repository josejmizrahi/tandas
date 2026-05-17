import SwiftUI
import RuulUI
import RuulCore

// MARK: - participants

public struct ParticipantsSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "participants",
        priority: 250,
        isEnabledFor: { caps in caps.contains("participants") },
        render: { ctx in AnyView(ParticipantsSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "PARTICIPANTES") {
            if let count = participantCount {
                StubMetadataRow(label: "Confirmados", value: "\(count)")
            } else {
                StubPlaceholderRow(symbol: "person.3", subtitle: "Lista de participantes en una próxima versión.")
            }
        }
    }

    private var participantCount: Int? {
        context.resource.metadata["participant_count"]?.intValue
    }
}

// MARK: - attendance

public struct AttendanceSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "attendance",
        priority: 260,
        isEnabledFor: { caps in caps.contains("attendance") },
        render: { ctx in AnyView(AttendanceSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "ASISTENCIA") {
            StubPlaceholderRow(
                symbol: "checkmark.seal",
                subtitle: "El detalle de check-in vive en su propia sección cuando el recurso lo activa."
            )
        }
    }
}

// MARK: - guest_access

public struct GuestAccessSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "guest_access",
        priority: 270,
        isEnabledFor: { caps in caps.contains("guest_access") },
        render: { ctx in AnyView(GuestAccessSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "INVITADOS") {
            StubPlaceholderRow(
                symbol: "person.badge.plus",
                subtitle: "Permitir invitados externos llegará pronto."
            )
        }
    }
}

// MARK: - approval

public struct ApprovalSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "approval",
        priority: 720,
        isEnabledFor: { caps in caps.contains("approval") },
        render: { ctx in AnyView(ApprovalSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "APROBACIÓN") {
            if let stateLabel {
                StubMetadataRow(label: "Estado", value: stateLabel)
            } else {
                StubPlaceholderRow(
                    symbol: "checkmark.shield",
                    subtitle: "Flujo de aprobación todavía no wired al backend."
                )
            }
        }
    }

    private var stateLabel: String? {
        context.resource.metadata["approval_state"]?.stringValue
    }
}

// MARK: - appeal

public struct AppealSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "appeal",
        priority: 730,
        isEnabledFor: { caps in caps.contains("appeal") },
        render: { ctx in AnyView(AppealSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "APELACIONES") {
            StubPlaceholderRow(
                symbol: "exclamationmark.bubble",
                subtitle: "Las apelaciones siguen pasando por la pantalla de multas."
            )
        }
    }
}
