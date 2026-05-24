import SwiftUI
import RuulUI
import RuulCore

/// Cross-group event feed. Apple Invites pattern: the first event of the
/// nearest section gets hero treatment (full EventCard); the rest render
/// as compact `EventRow`s grouped by day language.
///
/// Design contract (Docs/DesignPrinciples.md):
///   - Hero card uses the event cover as background
///   - Compact rows reuse EventRow primitive
///   - Sections labeled with tracked uppercase (HOY / MAÑANA / etc.)
///   - Date language, never raw date strings
///   - Empty state conversational, has CTA
public struct MyFeedView: View {
    @State var coordinator: MyFeedCoordinator
    @Environment(AppState.self) private var app

    public let onSelectEvent: (Event, RuulCore.Group) -> Void

    public init(coordinator: MyFeedCoordinator, onSelectEvent: @escaping (Event, RuulCore.Group) -> Void) {
        self._coordinator = State(initialValue: coordinator)
        self.onSelectEvent = onSelectEvent
    }

    public var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            AsyncContentView(
                phase: coordinator.phase,
                onRetry: { await coordinator.refresh() },
                empty: { emptyScroll },
                loaded: { _ in loadedScroll }
            )
        }
        .navigationTitle("Mis eventos")
        .navigationBarTitleDisplayMode(.large)
        .task { await coordinator.refresh() }
    }

    /// Loaded path: el ScrollView con secciones temporales. AsyncContentView
    /// se encarga del refresh inline progress + stale-on-error banner.
    private var loadedScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                contentSections
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    /// Empty path: scroll vacío con el empty hero — el contenedor
    /// scrollable mantiene el `.refreshable` para que el usuario pueda
    /// hacer pull-to-refresh sin contenido.
    private var emptyScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                emptyState
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var contentSections: some View {
        let sections = coordinator.sectioned()
        ForEach(sections, id: \.0) { section, events in
            sectionView(section: section, events: events, isFirst: section == sections.first?.0)
        }
    }

    @ViewBuilder
    private func sectionView(
        section: MyFeedCoordinator.Section,
        events: [Event],
        isFirst: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionHeader(section: section, count: events.count)

            // Hero treatment: first event of the FIRST non-empty section
            // (typically Hoy or the next upcoming day).
            let useHero = isFirst && (section == .today || section == .thisWeek || section == .upcoming)
            if useHero, let hero = events.first {
                heroCard(for: hero)
                ForEach(events.dropFirst()) { ev in
                    eventRow(for: ev)
                }
            } else {
                ForEach(events) { ev in
                    eventRow(for: ev)
                }
            }
        }
    }

    private func sectionHeader(section: MyFeedCoordinator.Section, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
            Spacer()
            Text("\(count)")
                .font(.footnote.monospacedDigit().weight(.bold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
    }

    // MARK: - Hero card (full cover, EventCard primitive)

    private func heroCard(for event: Event) -> some View {
        let group = coordinator.group(for: event)
        return EventCard(
            event: event,
            myStatus: nil,                    // V1.x — batch RSVP load deferred
            isHostedByMe: false,              // cross-group hosted-by-me requires per-event lookup; defer
            attendeeAvatars: [],
            confirmedCount: 0,
            isAtCapacity: false
        ) {
            if let group { onSelectEvent(event, group) }
        }
        .scrollTransition(.animated.threshold(.visible(0.2))) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1.0 : 0.96)
        }
    }

    // MARK: - Compact row

    private func eventRow(for event: Event) -> some View {
        let group = coordinator.group(for: event)
        let groupName = (coordinator.groupsById.count > 1) ? group?.name : nil
        return EventRow(
            event: event,
            groupName: groupName,
            myStatus: nil                     // V1.x — batch RSVP load deferred
        ) {
            if let group { onSelectEvent(event, group) }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Sin eventos próximos", systemImage: "calendar.badge.clock")
        } description: {
            Text("Cuando alguno de tus grupos proponga algo, va a aparecer acá.")
        }
        .padding(.top, 40)
    }

    // Nota: la antigua `errorBanner(_:)` local quedó obsoleta — el
    // `AsyncContentView` ya muestra el `ErrorBanner` DS automáticamente
    // sobre la fase `.failed(_, previous:)`, preservando el tono
    // conversacional pero sin re-implementar el chrome.
}
