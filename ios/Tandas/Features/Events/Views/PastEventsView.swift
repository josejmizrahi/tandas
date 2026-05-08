import SwiftUI
import RuulUI
import RuulCore

struct PastEventsView: View {
    let group: RuulCore.Group
    let userId: UUID
    let eventRepo: any EventRepository
    var onOpenEvent: (Event) -> Void

    @State private var events: [Event] = []
    @State private var isLoading = true
    @State private var error: EventError?

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            content
        }
        .navigationTitle("Historial")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            RuulLoadingState()
        } else if let error {
            ErrorStateView(
                systemImage: "wifi.exclamationmark",
                title: "No pudimos cargar el historial",
                message: error.localizedDescription,
                retryAction: ("Reintentar", { Task { await load() } })
            )
            .padding(RuulSpacing.lg)
        } else if events.isEmpty {
            EmptyStateView(
                systemImage: "clock",
                title: "Sin eventos pasados",
                message: "Aquí aparecen los eventos cerrados o cancelados."
            )
            .padding(RuulSpacing.lg)
        } else {
            ScrollView {
                VStack(spacing: RuulSpacing.sm) {
                    ForEach(events) { event in
                        EventCard(
                            event: event,
                            myStatus: nil,
                            isHostedByMe: event.hostId == userId
                        ) { onOpenEvent(event) }
                    }
                }
                .padding(RuulSpacing.lg)
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            events = try await eventRepo.pastEvents(in: group.id, limit: 50)
        } catch {
            self.error = .fetchFailed(error.localizedDescription)
        }
    }
}
