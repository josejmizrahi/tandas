import SwiftUI
import RuulUI
import RuulCore

public struct PastResourcesView: View {
    @Environment(AppState.self) private var app
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

    /// LoadPhase-driven state — uses the standard `AsyncContentView` shell
    /// instead of the ad-hoc isLoading/error/empty switch. Stale-on-error
    /// is "free" here: if a refresh fails after the user saw the list, the
    /// banner appears without dumping them back to a blank screen.
    @State private var phase: LoadPhase<[Event]> = .idle

    public var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            AsyncContentView(
                phase: phase,
                onRetry: { await load() },
                empty: {
                    ContentUnavailableView {
                        Label("Sin eventos pasados", systemImage: "clock")
                    } description: {
                        Text("Acá vas a ver el historial cuando termine la primera cena.")
                    }
                    .padding(RuulSpacing.lg)
                },
                loaded: { events in loadedScroll(events) }
            )
        }
        .navigationTitle("Historial")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func loadedScroll(_ events: [Event]) -> some View {
        ScrollView {
            RuulSeparatedRows(items: events) { event in
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
            .padding(RuulSpacing.lg)
        }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        // Promote loaded → refreshing so AsyncContentView shows the inline
        // top progress indicator instead of swapping to the full-screen
        // spinner.
        switch phase {
        case .loaded(let prev): phase = .refreshing(prev)
        case .refreshing, .failed(_, .some): break
        default: phase = .loading
        }
        do {
            let events = try await eventRepo.pastEvents(in: group.id, limit: 50)
            phase = events.isEmpty ? .empty : .loaded(events)
        } catch {
            phase = .failed(
                CoordinatorError(
                    title: "No pudimos cargar el historial",
                    message: error.localizedDescription,
                    isRetryable: true
                ),
                previous: phase.value
            )
        }
    }
}
