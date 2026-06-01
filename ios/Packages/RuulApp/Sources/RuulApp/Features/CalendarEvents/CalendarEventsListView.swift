import SwiftUI
import RuulCore

/// V3-D.23 — Upcoming + past calendar events for a group.
/// Tap → CalendarEventDetailView. Toolbar `+` opens CreateCalendarEventView
/// (gated by `events.create`).
public struct CalendarEventsListView: View {
    @Bindable var store: CalendarEventsStore
    let groupId: UUID
    let permissionKeys: [String]
    let membersStore: MembersStore?

    @State private var filter: EventsFilter = .upcoming

    public init(
        store: CalendarEventsStore,
        groupId: UUID,
        permissionKeys: [String] = [],
        membersStore: MembersStore? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.permissionKeys = permissionKeys
        self.membersStore = membersStore
    }

    public var body: some View {
        List {
            filterSection
            content
        }
        .navigationTitle("Eventos")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load(groupId: groupId) }
        .toolbar {
            if permissionKeys.contains("events.create") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.beginCreating()
                    } label: {
                        Label("Crear evento", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $store.isCreatePresented) {
            CreateCalendarEventView(store: store, groupId: groupId)
        }
        .navigationDestination(for: CalendarEventListItem.self) { item in
            CalendarEventDetailView(
                store: store,
                groupId: groupId,
                eventId: item.id,
                initial: item,
                permissionKeys: permissionKeys,
                membersStore: membersStore
            )
        }
        .task {
            if case .idle = store.phase {
                await store.load(groupId: groupId)
            }
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("", selection: $filter) {
                Text("Próximos").tag(EventsFilter.upcoming)
                Text("Pasados").tag(EventsFilter.past)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudo cargar", systemImage: "exclamationmark.triangle")
            } description: { Text(message) }
            actions: {
                Button("Reintentar") { Task { await store.load(groupId: groupId) } }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            switch filter {
            case .upcoming: upcomingSection
            case .past:     pastSection
            }
        }
    }

    private var visibleEvents: [CalendarEventListItem] {
        let now = Date()
        switch filter {
        case .upcoming: return store.events.filter { $0.startsAt >= Calendar.current.startOfDay(for: now) }
        case .past:     return store.events.filter { $0.startsAt <  Calendar.current.startOfDay(for: now) }
        }
    }

    @ViewBuilder
    private var upcomingSection: some View {
        if visibleEvents.isEmpty {
            ContentUnavailableView {
                Label("Sin eventos próximos", systemImage: "calendar")
            } description: {
                Text("Aún no hay nada agendado.")
            } actions: {
                if permissionKeys.contains("events.create") {
                    Button { store.beginCreating() } label: {
                        Text("Crear el primero")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .listRowBackground(Color.clear)
        } else {
            Section("Próximos") {
                ForEach(visibleEvents) { item in
                    NavigationLink(value: item) {
                        CalendarEventRow(item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pastSection: some View {
        if visibleEvents.isEmpty {
            ContentUnavailableView(
                "Sin eventos pasados",
                systemImage: "clock.arrow.circlepath"
            )
            .listRowBackground(Color.clear)
        } else {
            Section("Anteriores") {
                ForEach(visibleEvents) { item in
                    NavigationLink(value: item) {
                        CalendarEventRow(item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Placeholder evento").font(.body.weight(.semibold))
            Text("hh:mm").font(.caption).foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }

    private enum EventsFilter: Hashable { case upcoming, past }
}

struct CalendarEventRow: View {
    let item: CalendarEventListItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.eventType.systemImageName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    statusBadge
                }
                HStack(spacing: 8) {
                    Label(formattedDate, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let loc = item.locationName, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 12) {
                    if item.attendeeCount > 0 {
                        Label("\(item.acceptedCount)/\(item.attendeeCount)", systemImage: "person.2")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let rsvp = item.myRsvpStatus {
                        Label(rsvp.label, systemImage: rsvp.systemImageName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    if item.recurrenceRule != nil {
                        Label("Se repite", systemImage: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_MX")
        formatter.dateFormat = "EEE d MMM · HH:mm"
        return formatter.string(from: item.startsAt)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.status != .scheduled {
            let tint: Color = {
                switch item.status {
                case .scheduled: return .blue
                case .cancelled: return .red
                case .completed: return .green
                case .archived:  return .gray
                }
            }()
            Text(item.status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.12)))
        }
    }
}
