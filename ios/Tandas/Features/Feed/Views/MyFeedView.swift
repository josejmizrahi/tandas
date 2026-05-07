import SwiftUI

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
struct MyFeedView: View {
    @State var coordinator: MyFeedCoordinator
    @Environment(AppState.self) private var app

    let onSelectEvent: (Event, Group) -> Void

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                    if let err = coordinator.loadError {
                        errorBanner(err)
                    }
                    if coordinator.events.isEmpty && !coordinator.isLoading {
                        emptyState
                    } else {
                        contentSections
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.xs)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh() }
        }
        .navigationTitle("Mis eventos")
        .navigationBarTitleDisplayMode(.large)
        .task { await coordinator.refresh() }
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
            Text(section.title.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text("\(count)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextTertiary)
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
        EmptyStateView(
            systemImage: "calendar.badge.clock",
            title: "Todo tranquilo por ahora",
            message: "Cuando alguno de tus grupos cree un evento, vas a verlo acá junto con los demás."
        )
        .padding(.top, RuulSpacing.s8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: RuulSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.ruulNegative)
            Text(message)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(2)
        }
        .padding(RuulSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(Color.ruulNegative.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulNegative.opacity(0.3), lineWidth: 0.5)
        )
    }
}
