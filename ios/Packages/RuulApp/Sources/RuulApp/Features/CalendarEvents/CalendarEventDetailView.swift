import SwiftUI
import RuulCore

/// V3-D.23 — Calendar event detail. Sections (in order):
///   1. Header con título / fecha / lugar / estado
///   2. Descripción
///   3. Mi RSVP (botones)
///   4. Asistentes (lista + invitar)
///   5. Recordatorios
///   6. Acciones (cancelar / archivar)
public struct CalendarEventDetailView: View {
    @Bindable var store: CalendarEventsStore
    let groupId: UUID
    let eventId: UUID
    let initial: CalendarEventListItem?
    let permissionKeys: [String]
    let membersStore: MembersStore?

    @State private var showCancelConfirm = false
    @State private var cancelReason: String = ""
    @State private var showArchiveConfirm = false
    @State private var showAttendeePicker = false

    public init(
        store: CalendarEventsStore,
        groupId: UUID,
        eventId: UUID,
        initial: CalendarEventListItem? = nil,
        permissionKeys: [String] = [],
        membersStore: MembersStore? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.eventId = eventId
        self.initial = initial
        self.permissionKeys = permissionKeys
        self.membersStore = membersStore
    }

    public var body: some View {
        List {
            header
            if let detail = store.detail {
                if let description = detail.event.description, !description.isEmpty {
                    Section("Descripción") {
                        Text(description)
                    }
                }
                rsvpSection(detail: detail)
                attendeesSection(detail: detail)
                remindersSection(detail: detail)
                actionsSection(detail: detail)
            } else if case .failed(let message) = store.detailPhase {
                Section {
                    ContentUnavailableView {
                        Label("No se pudo cargar", systemImage: "exclamationmark.triangle")
                    } description: { Text(message) }
                }
            } else {
                Section {
                    ProgressView().listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadDetail(eventId: eventId)
        }
        .alert("Cancelar evento", isPresented: $showCancelConfirm) {
            TextField("Razón (opcional)", text: $cancelReason)
            Button("No") { showCancelConfirm = false }
            Button("Sí, cancelar", role: .destructive) {
                Task {
                    await store.cancel(eventId: eventId, reason: cancelReason.isEmpty ? nil : cancelReason, groupId: groupId)
                    cancelReason = ""
                }
            }
        } message: {
            Text("Se notificará a los asistentes.")
        }
        .confirmationDialog("Archivar evento", isPresented: $showArchiveConfirm) {
            Button("Archivar", role: .destructive) {
                Task { await store.archive(eventId: eventId, groupId: groupId) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(isPresented: $showAttendeePicker) {
            attendeePickerSheet
        }
    }

    private var displayTitle: String {
        store.detail?.event.title ?? initial?.title ?? "Evento"
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        let event: CalendarEvent? = store.detail?.event
        let title = event?.title ?? initial?.title ?? "Evento"
        let starts = event?.startsAt ?? initial?.startsAt ?? Date()
        let ends = event?.endsAt ?? initial?.endsAt
        let location = event?.locationName ?? initial?.locationName
        let type = event?.eventType ?? initial?.eventType ?? .other
        let status = event?.status ?? initial?.status ?? .scheduled
        let isRecurring = (event?.recurrenceRule ?? initial?.recurrenceRule) != nil

        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: type.systemImageName).font(.title2).foregroundStyle(.tint)
                    Text(title).font(.title2.weight(.semibold))
                    Spacer()
                    statusBadge(status: status)
                }
                Label(formattedRange(starts: starts, ends: ends), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let loc = location, !loc.isEmpty {
                    Label(loc, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Label(type.label, systemImage: type.systemImageName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                    if isRecurring {
                        Label("Se repite", systemImage: "repeat")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func statusBadge(status: CalendarEventStatus) -> some View {
        if status != .scheduled {
            Label(status.label, systemImage: statusSymbol(status))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
        }
    }

    private func statusSymbol(_ status: CalendarEventStatus) -> String {
        switch status {
        case .scheduled: return "calendar"
        case .cancelled: return "xmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .archived:  return "archivebox.fill"
        }
    }

    @ViewBuilder
    private func rsvpSection(detail: CalendarEventDetail) -> some View {
        if detail.permissions.canRsvp && detail.event.status == .scheduled {
            Section("Tu respuesta") {
                let mine = detail.attendees.first { $0.membershipId == detail.callerMembershipId }
                if let mine {
                    Text("Tu estado: \(mine.rsvpStatus.label)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    rsvpButton(.accepted, currentStatus: detail.attendees.first { $0.membershipId == detail.callerMembershipId }?.rsvpStatus)
                    rsvpButton(.declined, currentStatus: detail.attendees.first { $0.membershipId == detail.callerMembershipId }?.rsvpStatus)
                    rsvpButton(.tentative, currentStatus: detail.attendees.first { $0.membershipId == detail.callerMembershipId }?.rsvpStatus)
                }
            }
        }
    }

    @ViewBuilder
    private func rsvpButton(_ status: CalendarEventRSVPStatus, currentStatus: CalendarEventRSVPStatus?) -> some View {
        let isCurrent = currentStatus == status
        Button {
            Task { await store.respond(eventId: eventId, status: status, note: nil, groupId: groupId) }
        } label: {
            Label(status.label, systemImage: status.systemImageName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? .accentColor : .secondary)
    }

    @ViewBuilder
    private func attendeesSection(detail: CalendarEventDetail) -> some View {
        Section {
            if detail.attendees.isEmpty {
                Text("Aún no hay asistentes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detail.attendees) { a in
                    HStack {
                        let isHost = a.role == .host || a.role == .cohost
                        Image(systemName: isHost ? "crown.fill" : "person.fill")
                            .foregroundStyle(isHost ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.displayName ?? a.invitedEmail ?? "Sin nombre")
                                .font(.body)
                            Text("\(a.role.label) · \(a.rsvpStatus.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: a.rsvpStatus.systemImageName)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if detail.permissions.canManageAttendees && a.role != .host {
                            Button(role: .destructive) {
                                Task { await store.removeAttendee(attendeeId: a.id, eventId: eventId) }
                            } label: {
                                Label("Quitar", systemImage: "person.fill.xmark")
                            }
                        }
                    }
                }
            }
            if detail.permissions.canManageAttendees {
                Button {
                    showAttendeePicker = true
                } label: {
                    Label("Invitar a alguien", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } header: {
            HStack {
                Text("Asistentes")
                Spacer()
                Text("\(detail.attendees.filter { $0.rsvpStatus == .accepted }.count)/\(detail.attendees.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func remindersSection(detail: CalendarEventDetail) -> some View {
        if detail.permissions.canManageReminders || !detail.reminders.isEmpty {
            Section("Recordatorios") {
                if detail.reminders.isEmpty {
                    Text("Sin recordatorios.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.reminders) { r in
                        HStack {
                            Image(systemName: "bell.fill").foregroundStyle(.tint)
                            Text(formattedReminderOffset(r.offsetMinutes))
                            Spacer()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if detail.permissions.canManageReminders {
                                Button(role: .destructive) {
                                    Task { await store.removeReminder(reminderId: r.id, eventId: eventId) }
                                } label: {
                                    Label("Quitar", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                if detail.permissions.canManageReminders {
                    Menu {
                        Button("15 min antes") { Task { await store.addReminder(eventId: eventId, offsetMinutes: 15) } }
                        Button("1 hora antes") { Task { await store.addReminder(eventId: eventId, offsetMinutes: 60) } }
                        Button("1 día antes")  { Task { await store.addReminder(eventId: eventId, offsetMinutes: 60 * 24) } }
                    } label: {
                        Label("Agregar recordatorio", systemImage: "plus")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(detail: CalendarEventDetail) -> some View {
        if detail.event.status == .scheduled && (detail.permissions.canCancel || detail.permissions.canArchive) {
            Section {
                if detail.permissions.canCancel {
                    Button(role: .destructive) {
                        showCancelConfirm = true
                    } label: {
                        Label("Cancelar evento", systemImage: "calendar.badge.minus")
                    }
                }
                if detail.permissions.canArchive {
                    Button {
                        showArchiveConfirm = true
                    } label: {
                        Label("Archivar", systemImage: "archivebox")
                    }
                }
            }
        }
    }

    // MARK: - Attendee picker sheet

    @ViewBuilder
    private var attendeePickerSheet: some View {
        NavigationStack {
            List {
                if let members = membersStore?.items {
                    let invited = Set((store.detail?.attendees ?? []).compactMap { $0.membershipId })
                    let candidates = members.filter { item in
                        guard item.status == MembershipStatus.active else { return false }
                        guard let mid = item.membershipId else { return false }
                        return !invited.contains(mid)
                    }
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            "Todos ya están invitados",
                            systemImage: "person.2.fill"
                        )
                    } else {
                        Section("Miembros del grupo") {
                            ForEach(candidates) { item in
                                Button {
                                    Task {
                                        await store.addAttendee(
                                            eventId: eventId,
                                            membershipId: item.membershipId,
                                            invitedEmail: nil,
                                            displayName: item.displayName
                                        )
                                        showAttendeePicker = false
                                    }
                                } label: {
                                    HStack {
                                        Text(item.displayName)
                                        Spacer()
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No hay miembros cargados",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                }
            }
            .navigationTitle("Invitar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { showAttendeePicker = false }
                }
            }
            .task {
                if let ms = membersStore {
                    await ms.refreshIfNeeded(groupId: groupId)
                }
            }
        }
    }

    // MARK: - Formatters

    private func formattedRange(starts: Date, ends: Date?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_MX")
        formatter.dateFormat = "EEEE d MMM · HH:mm"
        let startStr = formatter.string(from: starts)
        guard let ends else { return startStr }
        let endFmt = DateFormatter()
        endFmt.locale = Locale(identifier: "es_MX")
        if Calendar.current.isDate(starts, inSameDayAs: ends) {
            endFmt.dateFormat = "HH:mm"
        } else {
            endFmt.dateFormat = "d MMM · HH:mm"
        }
        return "\(startStr) – \(endFmt.string(from: ends))"
    }

    private func formattedReminderOffset(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min antes" }
        if minutes < 60 * 24 {
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hora" : "horas") antes"
        }
        let days = minutes / (60 * 24)
        return "\(days) \(days == 1 ? "día" : "días") antes"
    }

}
