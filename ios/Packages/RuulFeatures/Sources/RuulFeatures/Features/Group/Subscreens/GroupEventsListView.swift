import SwiftUI
import RuulUI
import RuulCore

/// "Eventos" — group-scoped events list, pushed from the GroupSpace
/// "Eventos" tile. Reuses `EventRow` so the visual treatment matches
/// the cross-group feed; the difference is solely the data source
/// (filtered to one group) and the navigation context (lives inside
/// the Grupo tab's stack, not the Inicio tab).
@MainActor
public struct GroupEventsListView: View {
    public let group: RuulCore.Group
    public let onOpenEvent: (Event) -> Void

    @Environment(AppState.self) private var app

    @State private var events: [Event] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    public init(group: RuulCore.Group, onOpenEvent: @escaping (Event) -> Void) {
        self.group = group
        self.onOpenEvent = onOpenEvent
    }

    private var phase: LoadPhase<[Event]> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(title: "No pudimos cargar los eventos", message: $0, isRetryable: true)
        }
        return LoadPhase.fromCollection(
            value: events,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: coordError
        )
    }

    public var body: some View {
        AsyncContentView(
            phase: phase,
            onRetry: { await load() },
            empty: {
                ContentUnavailableView {
                    Label("Sin eventos", systemImage: "calendar")
                } description: {
                    Text("Cuando alguien cree un evento en este grupo aparecerá acá.")
                }
            },
            loaded: { rows in
                ScrollView {
                    LazyVStack(spacing: RuulSpacing.sm) {
                        ForEach(rows, id: \.id) { event in
                            EventRow(
                                event: event,
                                myStatus: nil,
                                onTap: { onOpenEvent(event) }
                            )
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Eventos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            events = try await app.eventRepo.upcomingEvents(in: group.id, limit: 100)
        } catch {
            errorMessage = "No pudimos cargar los eventos."
        }
    }
}
