import SwiftUI

/// Cross-group event feed. Renders `MyFeedCoordinator.sectioned()` —
/// Hoy / Esta semana / Próximos / Recientes. Tap on a row activates that
/// event's group and opens the EventDetail.
struct MyFeedView: View {
    @State var coordinator: MyFeedCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let onSelectEvent: (Event, Group) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                if let err = coordinator.loadError {
                    errorBanner(err)
                }
                if coordinator.events.isEmpty && !coordinator.isLoading {
                    emptyState
                } else {
                    ForEach(coordinator.sectioned(), id: \.0) { section, events in
                        sectionView(section: section, events: events)
                    }
                }
            }
            .padding(RuulSpacing.s4)
        }
        .navigationTitle("Mis eventos")
        .navigationBarTitleDisplayMode(.large)
        .task { await coordinator.refresh() }
        .refreshable { await coordinator.refresh() }
    }

    private func sectionView(section: MyFeedCoordinator.Section, events: [Event]) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack {
                Text(section.title)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
                Text("\(events.count)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            VStack(spacing: RuulSpacing.s2) {
                ForEach(events) { ev in
                    Button {
                        if let g = coordinator.group(for: ev) {
                            onSelectEvent(ev, g)
                        }
                    } label: {
                        feedRow(event: ev)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func feedRow(event: Event) -> some View {
        let group = coordinator.group(for: event)
        return RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                HStack(alignment: .firstTextBaseline) {
                    if let groupName = group?.name {
                        Text(groupName)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextAccent)
                            .textCase(.uppercase)
                    }
                    Spacer()
                    Text(formattedDate(event.startsAt))
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Text(event.title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.leading)
                if let location = event.locationName {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                        Text(location)
                    }
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                }
                statusPill(for: event)
            }
        }
    }

    @ViewBuilder
    private func statusPill(for event: Event) -> some View {
        if event.status == .cancelled {
            pill(label: "Cancelado", color: .ruulSemanticError)
        } else if event.status == .closed || (event.startsAt < .now && event.status == .upcoming) {
            pill(label: "Cerrado", color: .ruulTextTertiary)
        } else if Calendar.current.isDateInToday(event.startsAt) {
            pill(label: "Hoy", color: .ruulSemanticSuccess)
        }
    }

    private func pill(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
    }

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.s3) {
            Image(systemName: "calendar.badge.clock")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Sin eventos próximos")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Cuando alguno de tus grupos cree un evento, aparecerá acá.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.s8)
    }

    private func errorBanner(_ message: String) -> some View {
        Text("No pudimos cargar: \(message)")
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulSemanticError)
            .padding(RuulSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulSemanticError.opacity(0.08))
            )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEE d MMM · HH:mm"
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}
