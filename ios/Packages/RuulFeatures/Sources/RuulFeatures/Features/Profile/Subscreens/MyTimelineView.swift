import SwiftUI
import RuulUI
import RuulCore

/// Cross-group chronological feed of the current user's own actions
/// (RSVP, check-in, vote cast, ledger movements). Reads `my_activity_v1`
/// via `AppState.myActivityRepo`. Grouped by calendar day.
@MainActor
public struct MyTimelineView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MyActivityItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading && items.isEmpty {
                    ProgressView().padding(RuulSpacing.xl)
                } else if items.isEmpty {
                    Text("Aún no hay actividad")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .padding(RuulSpacing.xl)
                } else {
                    LazyVStack(alignment: .leading, spacing: RuulSpacing.lg) {
                        ForEach(groupedByDay, id: \.day) { group in
                            section(day: group.day, items: group.items)
                        }
                    }
                    .padding(RuulSpacing.lg)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulNegative)
                        .padding(.horizontal, RuulSpacing.lg)
                }
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Mi línea de tiempo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    // MARK: - Grouped data

    private var groupedByDay: [(day: Date, items: [MyActivityItem])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: items) { item in
            cal.startOfDay(for: item.occurredAt)
        }
        return groups.keys.sorted(by: >).map { day in
            (day: day, items: groups[day]!.sorted { $0.occurredAt > $1.occurredAt })
        }
    }

    // MARK: - Section + Row

    private func section(day: Date, items: [MyActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text(dayLabel(day))
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    if item.id != items.last?.id {
                        Divider()
                            .background(Color.ruulSeparator)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private func row(_ item: MyActivityItem) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: iconFor(item))
                .ruulTextStyle(RuulTypography.subheadMedium)
                .foregroundStyle(colorFor(item))
                .frame(width: 32, height: 32)
                .background(colorFor(item).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(titleFor(item))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(originLabel(item))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            Text(relativeTime(item.occurredAt))
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
    }

    // MARK: - Display helpers

    private func iconFor(_ item: MyActivityItem) -> String {
        switch item.kind {
        case .rsvp:     return "checkmark.circle"
        case .checkIn:  return "location.fill"
        case .voteCast: return "hand.raised"
        case .ledger:   return "creditcard"
        }
    }

    private func colorFor(_ item: MyActivityItem) -> Color {
        switch item.kind {
        case .rsvp:     return Color.ruulPositive
        case .checkIn:  return Color.ruulAccent
        case .voteCast: return Color.ruulAccent
        case .ledger:   return Color.ruulWarning
        }
    }

    private func titleFor(_ item: MyActivityItem) -> String {
        switch item.kind {
        case .rsvp:
            if case .string(let s)? = item.payload["status"] {
                switch s {
                case "yes":       return "Confirmaste asistencia"
                case "no":        return "Declinaste asistencia"
                case "waitlist":  return "Te uniste a lista de espera"
                default:          return "Cambiaste tu RSVP"
                }
            }
            return "Cambiaste tu RSVP"
        case .checkIn:
            return "Hiciste check-in"
        case .voteCast:
            if case .string(let s)? = item.payload["choice"] {
                switch s {
                case "in_favor":   return "Votaste a favor"
                case "against":    return "Votaste en contra"
                case "abstained":  return "Te abstuviste en un voto"
                default:           return "Emitiste un voto"
                }
            }
            return "Emitiste un voto"
        case .ledger:
            if case .string(let s)? = item.payload["type"] {
                switch s {
                case "fine_paid":    return "Pagaste una multa"
                case "contribution": return "Hiciste una aportación"
                case "expense":      return "Registraste un gasto"
                default:             return "Movimiento de dinero"
                }
            }
            return "Movimiento de dinero"
        }
    }

    private func originLabel(_ item: MyActivityItem) -> String {
        app.groups.first(where: { $0.id == item.groupId })?.name ?? "Grupo"
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "HOY" }
        if cal.isDateInYesterday(date) { return "AYER" }
        let f = DateFormatter()
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f.string(from: date).uppercased()
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return f.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let repo = app.myActivityRepo else { return }
        do {
            items = try await repo.loadRecent(limit: 100)
        } catch {
            self.errorMessage = "No pudimos cargar tu actividad."
        }
    }
}
