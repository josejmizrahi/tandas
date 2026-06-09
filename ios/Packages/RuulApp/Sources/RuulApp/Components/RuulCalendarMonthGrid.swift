import SwiftUI

/// R.5V.Calendar — Month grid Apple-native reutilizable.
///
/// Componente que renderiza el grid mensual + selector de día + decoración
/// por día (color dot). Caller controla:
/// - `displayedMonth` y `selectedDay` (bindings)
/// - `dotColor(_ date:) -> Color?` — color del badge si el día tiene algo
///
/// Usado por:
/// - `ContextCalendarView` (eventos + reservaciones del contexto)
/// - `MyCalendarView` (cross-context)
/// - `ResourceCalendarView` (eventos + reservaciones del recurso)
public struct RuulCalendarMonthGrid: View {
    @Binding var displayedMonth: Date
    @Binding var selectedDay: Date?
    /// Decoración del día: retorna un Color para dot, nil si no hay nada.
    let dotColor: (Date) -> Color?
    /// Opcional: leyenda debajo del grid (legend items).
    let legendItems: [(label: String, color: Color)]

    private let cal = Calendar.current

    public init(
        displayedMonth: Binding<Date>,
        selectedDay: Binding<Date?>,
        dotColor: @escaping (Date) -> Color?,
        legendItems: [(label: String, color: Color)] = []
    ) {
        self._displayedMonth = displayedMonth
        self._selectedDay = selectedDay
        self.dotColor = dotColor
        self.legendItems = legendItems
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            monthHeader
            weekdayHeader
            dayGrid
            if !legendItems.isEmpty {
                legend
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Month header (chevrons + "Hoy")

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Mes anterior")

            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()

            Button {
                jumpToToday()
            } label: {
                Text("Hoy")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(isCurrentMonth)
            .accessibilityLabel("Ir a hoy")

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Mes siguiente")
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    private var isCurrentMonth: Bool {
        cal.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    private func shiftMonth(by delta: Int) {
        if let next = cal.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = next
        }
    }

    private func jumpToToday() {
        let monthStart = cal.dateInterval(of: .month, for: .now)?.start ?? .now
        displayedMonth = monthStart
        selectedDay = cal.startOfDay(for: .now)
    }

    // MARK: - Weekday header

    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Day grid

    private var monthCells: [Date?] {
        guard let monthInterval = cal.dateInterval(of: .month, for: displayedMonth),
              let dayCount = cal.range(of: .day, in: .month, for: displayedMonth)?.count
        else { return [] }

        let firstWeekday = cal.component(.weekday, from: monthInterval.start)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(cal.date(byAdding: .day, value: offset, to: monthInterval.start))
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
                        .frame(height: 44)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let dot = dotColor(day)
        let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
        let isToday = cal.isDateInToday(day)

        Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday && !isSelected ? Theme.Tint.primary : Theme.Text.primary)
                Circle()
                    .fill(dot ?? .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Theme.Tint.primary.opacity(0.18) : .clear)
            )
            .overlay {
                if isToday && !isSelected {
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.Tint.primary.opacity(0.5), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Theme.Spacing.lg) {
            ForEach(Array(legendItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}
