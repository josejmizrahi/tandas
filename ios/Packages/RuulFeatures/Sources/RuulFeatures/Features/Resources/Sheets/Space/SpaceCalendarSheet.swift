import SwiftUI
import RuulUI
import RuulCore

/// Read-only calendar view for a Space resource. Lists the existing
/// `system_events` of booking lifecycle types so the viewer can scan
/// upcoming + past activity at a glance. Editing / creating bookings
/// happens through `SpaceReserveSheet`.
public struct SpaceCalendarSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    let resource: ResourceRow

    @State private var entries: [SystemEvent] = []
    @State private var isLoading: Bool = true

    public init(resource: ResourceRow) {
        self.resource = resource
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "Sin reservas registradas",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Cuando agendes una reserva aparecerá aquí.")
                    )
                } else {
                    List {
                        ForEach(entries, id: \.id) { entry in
                            row(for: entry)
                        }
                    }
                }
            }
            .navigationTitle("Calendario")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func row(for entry: SystemEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.titleFor(entry))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ruulTextPrimary)
            Text(entry.occurredAt, style: .date)
                .font(.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.vertical, 4)
    }

    private static func titleFor(_ entry: SystemEvent) -> String {
        switch entry.eventType {
        case .bookingCreated:   return "Reserva agendada"
        case .bookingCancelled: return "Reserva cancelada"
        case .bookingExpired:   return "Reserva expirada"
        case .spaceBooked:      return "Espacio reservado"
        default:                return entry.eventType.rawString.capitalized
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let filter = SystemEventFilter(
            groupId: resource.groupId,
            resourceId: resource.id
        )
        let all = (try? await app.systemEventRepo.query(
            filter: filter,
            limit: 100,
            offset: 0
        )) ?? []
        entries = all.filter { event in
            switch event.eventType {
            case .bookingCreated, .bookingCancelled, .bookingExpired, .spaceBooked:
                return true
            default:
                return false
            }
        }
    }
}
