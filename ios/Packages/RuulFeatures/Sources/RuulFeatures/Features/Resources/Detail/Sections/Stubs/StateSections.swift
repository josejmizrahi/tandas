import SwiftUI
import RuulUI
import RuulCore

// MARK: - status

public struct StatusSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "status",
        priority: 90,
        isEnabledFor: { caps in caps.contains("status") },
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

// MARK: - history

public struct HistorySectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext

    @State private var events: [SystemEvent] = []
    @State private var loaded: Bool = false

    public static let definition = CapabilitySection(
        id: "history",
        priority: 950,
        isEnabledFor: { caps in caps.contains("history") },
        render: { ctx in AnyView(HistorySectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "HISTORIAL") {
            if !loaded {
                StubPlaceholderRow(symbol: "hourglass", title: "Cargando…", subtitle: nil)
            } else if events.isEmpty {
                StubPlaceholderRow(
                    symbol: "clock.arrow.circlepath",
                    subtitle: "Sin eventos registrados para este recurso."
                )
            } else {
                ForEach(Array(events.prefix(5).enumerated()), id: \.element.id) { idx, ev in
                    historyRow(ev)
                    if idx < min(events.count, 5) - 1 {
                        StubDivider()
                    }
                }
            }
        }
        .task { await load() }
    }

    private func historyRow(_ ev: SystemEvent) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(humanLabel(for: ev.eventType))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(ev.occurredAt.ruulShortDate)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer()
        }
        .padding(RuulSpacing.md)
    }

    private func humanLabel(for type: SystemEventType) -> String {
        // Best-effort prettifier: enum raw value → "Event Type Name".
        let raw = String(describing: type)
        let spaced = raw.unicodeScalars.reduce(into: "") { acc, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !acc.isEmpty {
                acc.append(" ")
            }
            acc.append(Character(scalar))
        }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    @MainActor
    private func load() async {
        events = (try? await app.systemEventRepo.query(
            filter: SystemEventFilter(
                groupId: context.resource.groupId,
                resourceId: context.resource.id
            ),
            limit: 20,
            offset: 0
        )) ?? []
        loaded = true
    }
}
