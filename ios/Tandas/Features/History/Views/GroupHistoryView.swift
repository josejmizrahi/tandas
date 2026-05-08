import SwiftUI
import RuulUI

/// History timeline for the active group. Reads paginated SystemEvents
/// via `GroupHistoryCoordinator`. Filters: event type, date range.
/// (Member filter + CSV export deferred to V1.x per Plans/Phase1.md
/// decision B.)
struct GroupHistoryView: View {
    @State var coordinator: GroupHistoryCoordinator
    @State private var detailEvent: SystemEvent?
    @State private var showFilters: Bool = false
    /// Optional: cuando set, el `SystemEventDetailView` muestra un CTA
    /// "Ver detalle" que routea al destination real (multa / voto /
    /// evento / regla). El forwarding pasa por `HistoryTabView` →
    /// `MainTabView.routeFromHistoryEvent(_:)`.
    var onOpenRelated: ((SystemEvent) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                header
                if coordinator.hasAnyFilter {
                    activeFilterBar
                }
                content
            }
            .padding(RuulSpacing.md)
        }
        .navigationTitle("Historia")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: coordinator.hasAnyFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Filtrar")
            }
        }
        .task { await coordinator.refresh() }
        .refreshable { await coordinator.refresh() }
        .sheet(item: $detailEvent) { ev in
            SystemEventDetailView(
                event: ev,
                memberName: nil,
                dismiss: { detailEvent = nil },
                onOpenRelated: onOpenRelated.map { handler in
                    { event in
                        // Dismiss la sheet primero — el padre setea el route
                        // en el siguiente runloop (Task) y SwiftUI puede
                        // pushear sin overlap con la sheet.
                        detailEvent = nil
                        handler(event)
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFilters) {
            HistoryFilterSheet(coordinator: coordinator) {
                showFilters = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("\(coordinator.events.count) eventos")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var activeFilterBar: some View {
        HStack(spacing: RuulSpacing.xs) {
            if let t = coordinator.filter.eventType {
                filterChip(label: t.rawString) {
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
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Quitar filtro \(label)")
        }
        .padding(.horizontal, RuulSpacing.xs)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.ruulSurface)
        )
    }

    @ViewBuilder
    private var content: some View {
        SwiftUI.Group {
            if let error = coordinator.error, coordinator.events.isEmpty {
                ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                    .transition(.opacity)
            } else if coordinator.events.isEmpty && coordinator.isLoading {
                RuulLoadingState()
                    .transition(.opacity)
            } else if coordinator.events.isEmpty {
                emptyState
                    .transition(.opacity)
            } else {
                timelineList
                    .transition(.opacity)
            }
        }
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.events.isEmpty)
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
            // loadMore footer: small inline spinner is intentional (not a
            // full skeleton) — content is already on screen, this is just
            // the next-page indicator.
            if coordinator.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.md)
            }
        }
    }

    private var emptyState: some View {
        // Use the canonical EmptyStateView primitive — same shape as
        // every other empty state in the app (consistency principle).
        EmptyStateView(
            systemImage: "clock.arrow.circlepath",
            title: "Sin actividad todavía",
            message: "Cuando pasen cosas en el grupo —eventos, RSVPs, multas, votaciones— aparecerán acá."
        )
        .padding(.top, RuulSpacing.s8)
    }

}

/// Filter editor presented as a sheet over GroupHistoryView.
struct HistoryFilterSheet: View {
    @Bindable var coordinator: GroupHistoryCoordinator
    let dismiss: () -> Void

    private static let typeOptions: [SystemEventType?] = [nil] + SystemEventType.knownCases

    var body: some View {
        ModalSheetTemplate(
            title: "Filtrar",
            primaryCTA: ("Aplicar", dismiss)
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                typeSection
                dateSection
                Button("Limpiar filtros") {
                    coordinator.clearFilters()
                    dismiss()
                }
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextAccent)
                .frame(maxWidth: .infinity)
                .padding(RuulSpacing.sm)
            }
        }
    }

    private var typeSection: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Tipo de evento")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Picker(selection: Binding(
                    get: { coordinator.filter.eventType },
                    set: { coordinator.setEventType($0) }
                )) {
                    Text("Todos").tag(SystemEventType?.none)
                    ForEach(SystemEventType.knownCases, id: \.self) { t in
                        Text(t.rawString).tag(SystemEventType?.some(t))
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
            }
        }
    }

    private var dateSection: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
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
