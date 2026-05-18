import SwiftUI
import RuulUI
import RuulCore

// MARK: - voting

public struct VotingSectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext

    @State private var activeVote: Vote?
    @State private var loaded: Bool = false

    public static let definition = CapabilitySection(
        id: "voting",
        priority: 700,
        isEnabledFor: { caps in caps.contains(CapabilityID.voting) },
        render: { ctx in AnyView(VotingSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "VOTACIÓN") {
            if let vote = activeVote {
                StubMetadataRow(label: "Propuesta abierta", value: vote.title)
                StubDivider()
                StubMetadataRow(label: "Cierra", value: TimingDate.short(ISO8601DateFormatter().string(from: vote.closesAt)))
            } else if loaded {
                StubPlaceholderRow(
                    symbol: "checkmark.circle",
                    subtitle: "Sin propuestas activas para este recurso."
                )
            } else {
                StubPlaceholderRow(
                    symbol: "hourglass",
                    title: "Cargando…",
                    subtitle: nil
                )
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        activeVote = try? await app.voteRepo.voteForReference(referenceId: context.resource.id)
        loaded = true
    }
}

// MARK: - consequence

public struct ConsequenceSectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext

    @State private var emittedCount: Int = 0
    @State private var loaded: Bool = false

    public static let definition = CapabilitySection(
        id: "consequence",
        priority: 740,
        isEnabledFor: { caps in caps.contains(CapabilityID.consequence) },
        render: { ctx in AnyView(ConsequenceSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "CONSECUENCIAS") {
            if loaded {
                if emittedCount > 0 {
                    StubMetadataRow(label: "Aplicadas", value: "\(emittedCount)")
                } else {
                    StubPlaceholderRow(
                        symbol: "checkmark.circle",
                        subtitle: "Sin consecuencias emitidas para este recurso."
                    )
                }
            } else {
                StubPlaceholderRow(symbol: "hourglass", title: "Cargando…", subtitle: nil)
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        // Consecuencias hoy = multas oficializadas. No hay un eventType
        // genérico de "consequence emitted" — usamos fineOfficialized
        // como proxy hasta que el rule engine ronde sus propios eventos.
        let events = (try? await app.systemEventRepo.query(
            filter: SystemEventFilter(
                groupId: context.resource.groupId,
                eventType: .fineOfficialized,
                resourceId: context.resource.id
            ),
            limit: 50,
            offset: 0
        )) ?? []
        emittedCount = events.count
        loaded = true
    }
}
