import SwiftUI

/// History timeline for the active group. Reads paginated SystemEvents
/// via `GroupHistoryCoordinator`. Filters: event type, date range.
/// (Member filter + CSV export deferred to V1.x per Plans/Phase1.md
/// decision B.)
struct GroupHistoryView: View {
    @State var coordinator: GroupHistoryCoordinator
    @State private var detailEvent: SystemEvent?
    @State private var showFilters: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                header
                if coordinator.hasAnyFilter {
                    activeFilterBar
                }
                if let err = coordinator.loadError {
                    errorBanner(err)
                }
                content
            }
            .padding(RuulSpacing.s4)
        }
        .navigationTitle("Historia")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: coordinator.hasAnyFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task { await coordinator.refresh() }
        .refreshable { await coordinator.refresh() }
        .sheet(item: $detailEvent) { ev in
            SystemEventDetailView(event: ev, memberName: nil) {
                detailEvent = nil
            }
        }
        .sheet(isPresented: $showFilters) {
            HistoryFilterSheet(coordinator: coordinator) {
                showFilters = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s1) {
            Text("\(coordinator.events.count) eventos")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var activeFilterBar: some View {
        HStack(spacing: RuulSpacing.s2) {
            if let t = coordinator.filter.eventType {
                filterChip(label: t.rawValue) {
                    coordinator.setEventType(nil)
                }
            }
            if coordinator.filter.fromDate != nil || coordinator.filter.toDate != nil {
                filterChip(label: "Fecha") {
                    coordinator.setDateRange(from: nil, to: nil)
                }
            }
            Spacer()
            Button("Limpiar") { coordinator.clearFilters() }
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextAccent)
        }
    }

    private func filterChip(label: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextPrimary)
            Button { onClear() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .padding(.horizontal, RuulSpacing.s2)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.ruulBackgroundElevated)
        )
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.events.isEmpty && !coordinator.isLoading {
            emptyState
        } else {
            timelineList
        }
    }

    private var timelineList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(coordinator.events.enumerated()), id: \.element.id) { index, ev in
                let presentation = HistoryItemPresentation(event: ev)
                Button { detailEvent = ev } label: {
                    RuulTimelineItem(
                        icon: presentation.icon,
                        title: presentation.title,
                        subtitle: presentation.subtitle,
                        timestamp: presentation.timestamp,
                        tone: presentation.tone,
                        isFirst: index == 0,
                        isLast: index == coordinator.events.count - 1
                    )
                }
                .buttonStyle(.plain)
                .onAppear {
                    if ev.id == coordinator.events.last?.id, coordinator.hasMore {
                        Task { await coordinator.loadMore() }
                    }
                }
            }
            if coordinator.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.s4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.s3) {
            Image(systemName: "clock.arrow.circlepath")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Sin actividad todavía")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Cuando pasen cosas en el grupo (eventos, RSVPs, multas, votaciones) aparecerán acá.")
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
}

/// Filter editor presented as a sheet over GroupHistoryView.
struct HistoryFilterSheet: View {
    @Bindable var coordinator: GroupHistoryCoordinator
    let dismiss: () -> Void

    private static let typeOptions: [SystemEventType?] = [nil] + SystemEventType.allCases

    var body: some View {
        ModalSheetTemplate(
            title: "Filtrar",
            primaryCTA: ("Aplicar", dismiss)
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                typeSection
                dateSection
                Button("Limpiar filtros") {
                    coordinator.clearFilters()
                    dismiss()
                }
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextAccent)
                .frame(maxWidth: .infinity)
                .padding(RuulSpacing.s3)
            }
        }
    }

    private var typeSection: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("Tipo de evento")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Picker(selection: Binding(
                    get: { coordinator.filter.eventType },
                    set: { coordinator.setEventType($0) }
                )) {
                    Text("Todos").tag(SystemEventType?.none)
                    ForEach(SystemEventType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(SystemEventType?.some(t))
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
            }
        }
    }

    private var dateSection: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("Rango de fecha")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)

                DatePicker("Desde", selection: Binding(
                    get: { coordinator.filter.fromDate ?? Calendar.current.date(byAdding: .month, value: -3, to: .now) ?? .now },
                    set: { coordinator.setDateRange(from: $0, to: coordinator.filter.toDate) }
                ), displayedComponents: .date)

                DatePicker("Hasta", selection: Binding(
                    get: { coordinator.filter.toDate ?? .now },
                    set: { coordinator.setDateRange(from: coordinator.filter.fromDate, to: $0) }
                ), displayedComponents: .date)
            }
        }
    }
}
