import SwiftUI
import RuulCore

/// F.9 — calendario mensual de un recurso. Cada día se pinta según el estado
/// de la reservación que lo cubre; tocar un día muestra sus reservaciones.
struct ReservationsCalendarView: View {
    let resource: Resource
    let context: AppContext
    let store: ReservationsStore

    @State private var displayedMonth: Date
    @State private var selectedDay: Date?

    private let calendar = Calendar.current

    init(resource: Resource, context: AppContext, store: ReservationsStore) {
        self.resource = resource
        self.context = context
        self.store = store
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        _displayedMonth = State(initialValue: monthStart)
        _selectedDay = State(initialValue: Calendar.current.startOfDay(for: .now))
    }

    var body: some View {
        List {
            Section {
                monthHeader
                weekdayHeader
                dayGrid
                legend
            }

            if let selectedDay {
                daySection(selectedDay)
            }
        }
    }

    // MARK: - Mes

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)

            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .textCase(nil)
            Spacer()

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func shiftMonth(by delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = next
            selectedDay = nil
        }
    }

    // MARK: - Grid

    /// Símbolos de día de la semana empezando por `firstWeekday` del calendario.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Celdas del mes: nils para el offset inicial + un Date por día.
    private var monthCells: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayCount = calendar.range(of: .day, in: .month, for: displayedMonth)?.count
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: monthInterval.start))
        }
        return cells
    }

    private var dayGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear
                        .frame(height: 36)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let covering = store.reservations(covering: day, calendar: calendar)
        let color = covering.isEmpty ? nil : statusColor(strongestStatus(covering))
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = calendar.isDateInToday(day)

        Button {
            selectedDay = day
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.weight(isToday ? .bold : .regular))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color?.opacity(isSelected ? 0.45 : 0.2) ?? (isSelected ? Color.accentColor.opacity(0.2) : .clear))
                )
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .foregroundStyle(color ?? .primary)
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem("Solicitada", color: .orange)
            legendItem("Aprobada", color: .blue)
            legendItem("Confirmada", color: .green)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Día seleccionado

    @ViewBuilder
    private func daySection(_ day: Date) -> some View {
        let covering = store.reservations(covering: day, calendar: calendar)
        Section {
            if covering.isEmpty {
                Text("\(resource.displayName) está libre este día.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(covering) { reservation in
                    HStack(spacing: 12) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.displayName(for: reservation.reservedForActorId ?? reservation.requestedByActorId))
                            Text(rangeText(reservation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(reservation.statusLabel, color: statusColor(reservation.status))
                    }
                }
            }
        } header: {
            Text(day.formatted(date: .complete, time: .omitted))
        }
    }

    // MARK: - Helpers

    /// El estado "más fuerte" entre las reservaciones de un día decide el color.
    private func strongestStatus(_ reservations: [Reservation]) -> String {
        let order = ["confirmed", "approved", "requested", "completed"]
        for status in order where reservations.contains(where: { $0.status == status }) {
            return status
        }
        return reservations.first?.status ?? "requested"
    }

    private func rangeText(_ reservation: Reservation) -> String {
        let start = reservation.startsAt.formatted(date: .abbreviated, time: .omitted)
        let end = reservation.endsAt.formatted(date: .abbreviated, time: .omitted)
        return "\(start) → \(end)"
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "requested": return .orange
        case "approved": return .blue
        case "confirmed": return .green
        case "rejected", "cancelled": return .red
        case "completed": return .gray
        default: return .secondary
        }
    }
}

#Preview("Calendario Casa Valle") {
    let mock = MockRuulRPCClient.demo()
    let now = Date()
    NavigationStack {
        ReservationsCalendarView(
            resource: Resource(
                id: MockRuulRPCClient.DemoIds.casaValle,
                resourceType: "house",
                displayName: "Casa Valle"
            ),
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi",
                roles: ["admin"]
            ),
            store: ReservationsStore(
                rpc: mock,
                previewReservations: [
                    Reservation(
                        id: UUID(),
                        resourceId: MockRuulRPCClient.DemoIds.casaValle,
                        contextActorId: MockRuulRPCClient.DemoIds.familia,
                        requestedByActorId: MockRuulRPCClient.DemoIds.jose,
                        startsAt: now.addingTimeInterval(2 * 86_400),
                        endsAt: now.addingTimeInterval(4 * 86_400),
                        status: "confirmed"
                    ),
                    Reservation(
                        id: UUID(),
                        resourceId: MockRuulRPCClient.DemoIds.casaValle,
                        contextActorId: MockRuulRPCClient.DemoIds.familia,
                        requestedByActorId: MockRuulRPCClient.DemoIds.jose,
                        startsAt: now.addingTimeInterval(8 * 86_400),
                        endsAt: now.addingTimeInterval(10 * 86_400),
                        status: "requested"
                    )
                ]
            )
        )
    }
}
