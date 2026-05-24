import SwiftUI
import RuulUI
import RuulCore

/// Activity timeline for the active group. Reads paginated SystemEvents
/// via `ActivityCoordinator`. Filters: event type, date range.
/// (Member filter + CSV export deferred to V1.x per Plans/Phase1.md
/// decision B.)
public struct ActivityView: View {
    @State var coordinator: ActivityCoordinator
    @Environment(AppState.self) private var app
    @State private var detailEvent: SystemEvent?
    @State private var showFilters: Bool = false
    @State private var selectedChip: ActivityChip = .all
    /// Optional: cuando set, el `SystemEventDetailView` muestra un CTA
    /// "Ver detalle" que routea al destination real (multa / voto /
    /// evento / regla). El forwarding pasa por `ActivityTabView` →
    /// `MainTabView.routeFromHistoryEvent(_:)`.
    public var onOpenRelated: ((SystemEvent) -> Void)? = nil

    public init(coordinator: ActivityCoordinator, onOpenRelated: ((SystemEvent) -> Void)? = nil) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenRelated = onOpenRelated
    }

    public var body: some View {
        VStack(spacing: 0) {
            chipsStrip
            Divider()
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
            .contentMargins(RuulSpacing.md, for: .scrollIndicators)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
        .ruulAppToolbar()
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
        .fullScreenCover(item: $detailEvent) { ev in
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

        }
        .fullScreenCover(isPresented: $showFilters) {
            HistoryFilterSheet(coordinator: coordinator) {
                showFilters = false
            }

        }
    }

    // MARK: - Chips strip

    private var chipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(ActivityChip.allCases) { chip in
                    chipButton(for: chip)
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.sm)
        }
    }

    @ViewBuilder
    private func chipButton(for chip: ActivityChip) -> some View {
        let action = { withAnimation(.smooth) { selectedChip = chip } }
        if chip == selectedChip {
            Button(chip.label, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(chip.label, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("\(visibleEvents.count) eventos")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private var visibleEvents: [SystemEvent] {
        guard selectedChip != .all else { return coordinator.events }
        return coordinator.events.filter { selectedChip.matches($0.eventType) }
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
                .font(.caption)
                .foregroundStyle(Color.ruulTextAccent)
        }
    }

    private func filterChip(label: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.primary)
            Button { onClear() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.secondary)
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
        // AsyncContentView maneja loading/error/refresh/stale-on-error/empty
        // por la fase upstream (events del server). El chip filter es puro
        // cliente — si `coordinator.events` no está vacío pero el chip
        // recorta todo, mostramos el empty inline dentro del builder
        // `loaded` en vez de reportarlo a la fase.
        AsyncContentView(
            phase: coordinator.phase,
            onRetry: { await coordinator.refresh() },
            empty: { emptyState },
            loaded: { _ in
                if visibleEvents.isEmpty {
                    emptyState
                } else {
                    timelineList
                }
            }
        )
    }

    private var timelineList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, ev in
                let presentation = HistoryItemPresentation(
                    event: ev,
                    memberName: coordinator.actorName(for: ev),
                    // P2 (mig 00366): resolver maps payload-embedded
                    // member ids (paid_by_member_id, from_member_id)
                    // to display names so ledger atoms render as
                    // "Daniel registró $500 pagado por María" etc.
                    resolveMemberName: { coordinator.memberName(forMemberId: $0) }
                )
                Button { detailEvent = ev } label: {
                    RuulTimelineItem(
                        icon: presentation.icon,
                        title: presentation.title,
                        subtitle: presentation.subtitle,
                        timestamp: presentation.timestamp,
                        tone: presentation.tone,
                        isFirst: index == 0,
                        isLast: index == visibleEvents.count - 1,
                        actorName: coordinator.actorName(for: ev),
                        actorAvatarURL: coordinator.actorAvatarURL(for: ev)
                    )
                }
                .buttonStyle(.plain)
                .scrollTransition(.animated.threshold(.visible(0.2))) { content, phase in
                    content
                        .scaleEffect(phase.isIdentity ? 1.0 : 0.96)
                }
                .onAppear {
                    // Trigger pagination on the last visible row. When chip
                    // filter is active we still compare against the full
                    // coordinator list so we don't stall pagination mid-filter.
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
        Group {
            switch selectedChip {
            case .moments:
                ContentUnavailableView {
                    Label("Aún no hay momentos guardados", systemImage: "sparkles")
                } description: {
                    Text("Los momentos que marcan al grupo — quién entró, qué se decidió, qué se cerró — aparecen acá a medida que pasan.")
                }
            default:
                ContentUnavailableView {
                    Label("Sin actividad reciente", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Acá aparece todo lo que pasa en el grupo.")
                }
            }
        }
        .padding(.top, RuulSpacing.s8)
    }

}

// MARK: - ActivityChip

/// Categories for the horizontal filter strip at the top of ActivityView.
///
/// "Todo" is the full live chronological stream. "Momentos" filters to
/// durable narrative inflections — the events that define what this group
/// IS, separate from day-to-day churn. The remaining chips are subject
/// filters (money / resources / decisions / members) used to narrow to
/// a specific kind of activity.
///
/// Category → SystemEventType mapping:
///   Momentos:        group lifecycle, member join/leave, vote/appeal resolved,
///                    event closed, rule toggled, resource created, governance updated
///   Dinero (6):      fineOfficialized, fineVoided, finePaid, fineReminderSent, fundDeposit, fundThresholdReached
///   Recursos (12):   eventCreated, eventClosed, rsvpDeadlinePassed, hoursBeforeEvent, rsvpSubmitted,
///                    rsvpChangedSameDay, checkInRecorded, checkInMissed, eventDescriptionMissing,
///                    slotAssigned, slotDeclined, slotExpired, slotSwapRequested, slotSwapApproved,
///                    bookingCreated, bookingCancelled, bookingExpired, assetCreated, fundCreated
///   Decisiones (7):  appealCreated, appealResolved, voteOpened, voteCast, voteResolved,
///                    ruleEnabledChanged, ruleAmountChanged, pendingChangeApplied
///   Miembros (2):    positionChanged, memberJoined, memberLeft
///   (unknown) falls through to .resources at runtime)
private enum ActivityChip: String, CaseIterable, Identifiable {
    case all
    case moments
    case money
    case resources
    case governance
    case members

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:        return "Todo"
        case .moments:    return "Momentos"
        case .money:      return "Dinero"
        case .resources:  return "Recursos"
        case .governance: return "Decisiones"
        case .members:    return "Miembros"
        }
    }

    func matches(_ eventType: SystemEventType) -> Bool {
        switch self {
        case .all:
            return true

        case .moments:
            // Milestone inflections: durable narrative events that
            // become part of the group's memory. Excludes high-volume
            // operational churn (RSVPs, check-ins, individual votes,
            // intermediate vote casts) and rule-fuel synthetic events.
            switch eventType {
            case .groupCreated, .groupArchived, .groupUnarchived, .groupRenamed,
                 .memberJoined, .memberLeft,
                 .voteResolved, .appealResolved,
                 .eventClosed, .eventCancelled,
                 .ruleEnabledChanged,
                 .assetCreated, .fundCreated, .spaceCreated,
                 .governanceUpdated,
                 .positionChanged,
                 .pendingChangeApplied,
                 .rightCreated, .rightRevoked, .rightExpired:
                return true
            default:
                return false
            }

        case .money:
            switch eventType {
            case .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent,
                 .fundDeposit, .fundThresholdReached:
                return true
            default:
                return false
            }

        case .resources:
            switch eventType {
            case .eventCreated, .eventClosed, .rsvpDeadlinePassed, .hoursBeforeEvent,
                 .rsvpSubmitted, .rsvpChangedSameDay, .checkInRecorded, .checkInMissed,
                 .eventDescriptionMissing,
                 .slotAssigned, .slotDeclined, .slotExpired,
                 .slotSwapRequested, .slotSwapApproved,
                 .bookingCreated, .bookingCancelled, .bookingExpired,
                 .assetCreated, .fundCreated:
                return true
            default:
                // .unknown(_) and any future unrecognized event types surface
                // here — least surprising default for user-facing timelines.
                return true
            }

        case .governance:
            switch eventType {
            case .appealCreated, .appealResolved,
                 .voteOpened, .voteCast, .voteResolved,
                 .ruleEnabledChanged, .ruleAmountChanged,
                 .pendingChangeApplied:
                return true
            default:
                return false
            }

        case .members:
            switch eventType {
            case .memberJoined, .memberLeft, .positionChanged:
                return true
            default:
                return false
            }
        }
    }
}

/// Filter editor presented as a sheet over ActivityView.
public struct HistoryFilterSheet: View {
    @Bindable var coordinator: ActivityCoordinator
    public let dismiss: () -> Void

    public init(coordinator: ActivityCoordinator, dismiss: @escaping () -> Void) {
        self.coordinator = coordinator
        self.dismiss = dismiss
    }

    private static let typeOptions: [SystemEventType?] = [nil] + SystemEventType.knownCases

    public var body: some View {
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
                .font(.subheadline)
                .foregroundStyle(Color.ruulTextAccent)
                .frame(maxWidth: .infinity)
                .padding(RuulSpacing.sm)
            }
        }
    }

    private var typeSection: some View {
        GroupBox("Tipo de evento") {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dateSection: some View {
        GroupBox("Rango de fecha") {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
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
