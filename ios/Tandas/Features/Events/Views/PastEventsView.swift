import SwiftUI

struct PastEventsView: View {
    let group: Group
    let userId: UUID
    let eventRepo: any EventRepository
    var onOpenEvent: (Event) -> Void

    @State private var events: [Event] = []
    @State private var isLoading = true
    @State private var error: EventError?

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            content
        }
        .navigationTitle("Historial")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            LoadingStateView(.list).padding(RuulSpacing.s5)
        } else if let error {
            ErrorStateView(
                systemImage: "wifi.exclamationmark",
                title: "No pudimos cargar el historial",
                message: error.localizedDescription
            ) {
                Task { await load() }
            }
            .padding(RuulSpacing.s5)
        } else if events.isEmpty {
            EmptyStateView(
                systemImage: "clock",
                title: "Sin eventos pasados",
                message: "Aquí aparecen los eventos cerrados o cancelados."
            )
            .padding(RuulSpacing.s5)
        } else {
            ScrollView {
                VStack(spacing: RuulSpacing.s3) {
                    ForEach(events) { event in
                        EventCard(
                            event: event,
                            myStatus: nil,
                            isHostedByMe: event.hostId == userId
                        ) { onOpenEvent(event) }
                    }
                }
                .padding(RuulSpacing.s5)
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
