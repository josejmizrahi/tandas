import SwiftUI
import RuulUI
import RuulCore

public struct PastResourcesView: View {
    public let group: RuulCore.Group
    public let userId: UUID
    public let eventRepo: any EventRepository
    public var onOpenEvent: (Event) -> Void

    public init(group: RuulCore.Group, userId: UUID, eventRepo: any EventRepository, onOpenEvent: @escaping (Event) -> Void) {
        self.group = group
        self.userId = userId
        self.eventRepo = eventRepo
        self.onOpenEvent = onOpenEvent
    }

    @State private var events: [Event] = []
    @State private var isLoading = true
    @State private var error: EventError?

    public var body: some View {
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
                        .scrollTransition(.animated.threshold(.visible(0.2))) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1.0 : 0.96)
                        }
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
