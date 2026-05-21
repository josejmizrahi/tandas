import SwiftUI
import RuulUI
import RuulCore

/// Group "space" — the persistent home for a community. Replaces the
/// V2 Slice 4F `GroupHomeView` (Settings-style tab pair: Personas /
/// Cómo decidimos) with a single layered presence scroll, per founder
/// doctrine 2026-05-21:
///
///   1. Presence header (warm 72pt avatar + serif italic name + stack)
///   2. Compose bar (warm card with chip set: Evento · Decidir · Invitar)
///   3. Pendings block (UserActions w/ icon-gradient + CTA capsule)
///   4. Spaces grid (Eventos · Decisiones · Multas · Inbox)
///   5. Activity stream (current user's recent actions in this group)
///   6. Floating "Coordinar" FAB
///
/// Sub-screens previously gated behind the "Personas" / "Cómo
/// decidimos" tabs now live behind:
///   - Avatar stack → MembersList (`onOpenMembers`)
///   - "Decisiones" tile / chip → Acuerdos (`onOpenDecisions`)
///   - "⋯" menu → Edit / Notifications / Advanced / Leave
@MainActor
public struct GroupSpaceView: View {
    @State var coordinator: GroupHomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showComposeSheet = false

    // Compose — chips + FAB share the same routing entry points
    public var onCreateEvent: () -> Void
    public var onOpenDecisions: () -> Void
    public var onInviteMembers: () -> Void

    // Spaces grid
    public var onOpenEvents: (() -> Void)?
    public var onOpenFines: (() -> Void)?
    public var onOpenInbox: (() -> Void)?

    // Header + stream
    public var onOpenMembers: (() -> Void)?
    public var onOpenActivity: (() -> Void)?

    // Pendings
    public var onSelectPending: (UserAction) -> Void

    // Toolbar menu
    public var onShareInvite: () -> Void
    public var onEditIdentity: (() -> Void)?
    public var onRotateCode: (() -> Void)?
    public var onArchiveGroup: (() -> Void)?
    public var onConfirmLeave: (() -> Void)?
    public var onLeaveGroup: () -> Void

    public init(
        coordinator: GroupHomeCoordinator,
        onCreateEvent: @escaping () -> Void,
        onOpenDecisions: @escaping () -> Void,
        onInviteMembers: @escaping () -> Void,
        onOpenEvents: (() -> Void)? = nil,
        onOpenFines: (() -> Void)? = nil,
        onOpenInbox: (() -> Void)? = nil,
        onOpenMembers: (() -> Void)? = nil,
        onOpenActivity: (() -> Void)? = nil,
        onSelectPending: @escaping (UserAction) -> Void,
        onShareInvite: @escaping () -> Void,
        onEditIdentity: (() -> Void)? = nil,
        onRotateCode: (() -> Void)? = nil,
        onArchiveGroup: (() -> Void)? = nil,
        onConfirmLeave: (() -> Void)? = nil,
        onLeaveGroup: @escaping () -> Void
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onCreateEvent = onCreateEvent
        self.onOpenDecisions = onOpenDecisions
        self.onInviteMembers = onInviteMembers
        self.onOpenEvents = onOpenEvents
        self.onOpenFines = onOpenFines
        self.onOpenInbox = onOpenInbox
        self.onOpenMembers = onOpenMembers
        self.onOpenActivity = onOpenActivity
        self.onSelectPending = onSelectPending
        self.onShareInvite = onShareInvite
        self.onEditIdentity = onEditIdentity
        self.onRotateCode = onRotateCode
        self.onArchiveGroup = onArchiveGroup
        self.onConfirmLeave = onConfirmLeave
        self.onLeaveGroup = onLeaveGroup
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            atmosphericBackground.ignoresSafeArea()

            AsyncContentView(
                phase: coordinator.phase,
                onRetry: { await coordinator.refresh() },
                loaded: { _ in loadedScroll }
            )

            if coordinator.group != nil {
                GroupCoordinateFAB { showComposeSheet = true }
                    .padding(.bottom, RuulSpacing.xxl)
            }
        }
        .task { await coordinator.refresh() }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showComposeSheet) {
            composeSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
    }

    /// Soft warm wash at the top of the page tinted by the group's
    /// color ramp. Fades to canvas by the middle of the screen.
    @ViewBuilder
    private var atmosphericBackground: some View {
        if let group = coordinator.group {
            ZStack {
                Color.ruulBackground
                LinearGradient(
                    colors: [group.category.ramp.accent.opacity(0.08), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(maxHeight: 280)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            Color.ruulBackground
        }
    }

    @ViewBuilder
    private var loadedScroll: some View {
        if let group = coordinator.group {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    GroupPresenceHeader(
                        group: group,
                        memberCount: coordinator.memberCount,
                        members: coordinator.members,
                        onTapMembers: onOpenMembers
                    )

                    GroupComposeBar(
                        chips: composeChips(),
                        ramp: group.category.ramp
                    )

                    if !coordinator.pendingActions.isEmpty {
                        GroupPendingsBlock(
                            items: coordinator.pendingActions,
                            onSelect: onSelectPending
                        )
                    }

                    GroupSpacesGrid(tiles: spaceTiles(currency: group.currency))

                    if !coordinator.recentActivity.isEmpty {
                        GroupStreamBlock(
                            items: coordinator.recentActivity,
                            actor: app.profile,
                            locale: app.profile?.locale ?? "es-MX",
                            onSeeAll: onOpenActivity
                        )
                    }

                    Color.clear.frame(height: 120)  // FAB safe area
                }
                .padding(.horizontal, RuulSpacing.lg)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh() }
        }
    }

    private func composeChips() -> [GroupComposeBar.Chip] {
        [
            .init(id: "event",  label: "Evento",  systemImage: "calendar.badge.plus",
                  tint: Color.ruulWarning, action: onCreateEvent),
            .init(id: "decide", label: "Decidir", systemImage: "checkmark.square",
                  tint: GroupColorRamp.blue.accent, action: onOpenDecisions),
            .init(id: "invite", label: "Invitar", systemImage: "person.badge.plus",
                  tint: GroupColorRamp.purple.accent, action: onInviteMembers)
        ]
    }

    private func spaceTiles(currency: String) -> [GroupSpacesGrid.Tile] {
        let s = coordinator.summary
        let finesAlert: String? = {
            guard let s, s.pendingFinesCount > 0 else { return nil }
            let fmt = NumberFormatter()
            fmt.numberStyle = .currency
            fmt.currencyCode = currency
            fmt.maximumFractionDigits = 0
            let amount = Double(s.pendingFinesOutstandingCents) / 100.0
            return fmt.string(from: NSNumber(value: amount)).map { "\($0) por pagar" } ?? "Por pagar"
        }()

        let pendingCount = s?.pendingActionsCount ?? coordinator.pendingActions.count

        return [
            .init(
                id: "events",
                label: "Eventos",
                systemImage: "calendar",
                tint: Color.ruulWarning,
                primary: "\(s?.upcomingEventsCount ?? 0)",
                secondary: "esta semana",
                alert: nil,
                action: { onOpenEvents?() }
            ),
            .init(
                id: "decisions",
                label: "Decisiones",
                systemImage: "checkmark.square",
                tint: GroupColorRamp.blue.accent,
                primary: "\(s?.openVotesCount ?? 0)",
                secondary: (s?.openVotesCount ?? 0) == 1 ? "voto abierto" : "votos abiertos",
                alert: nil,
                action: onOpenDecisions
            ),
            .init(
                id: "fines",
                label: "Multas",
                systemImage: "exclamationmark.triangle.fill",
                tint: Color.ruulNegative,
                primary: "\(s?.pendingFinesCount ?? 0)",
                secondary: (s?.pendingFinesCount ?? 0) == 1 ? "pendiente" : "pendientes",
                alert: finesAlert,
                action: { onOpenFines?() }
            ),
            .init(
                id: "inbox",
                label: "Inbox",
                systemImage: "tray.fill",
                tint: Color.ruulPositive,
                primary: "\(pendingCount)",
                secondary: "por revisar",
                alert: nil,
                action: { onOpenInbox?() }
            )
        ]
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let onEditIdentity {
                    Button("Editar grupo", systemImage: "pencil", action: onEditIdentity)
                }
                Button("Compartir invitación", systemImage: "square.and.arrow.up", action: onShareInvite)
                Divider()
                Section("Avanzado") {
                    if let onRotateCode {
                        Button("Rotar código", systemImage: "arrow.triangle.2.circlepath", action: onRotateCode)
                    }
                    if let onArchiveGroup {
                        Button("Archivar grupo", systemImage: "archivebox", role: .destructive, action: onArchiveGroup)
                    }
                }
                Button(
                    "Salir del grupo",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive,
                    action: { onConfirmLeave?() ?? onLeaveGroup() }
                )
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    // MARK: - Compose sheet (FAB target)

    @ViewBuilder
    private var composeSheet: some View {
        NavigationStack {
            VStack(spacing: RuulSpacing.xl) {
                Text("¿Qué quieres coordinar?")
                    .font(.system(.title3, design: .serif).italic())
                    .padding(.top, RuulSpacing.md)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: RuulSpacing.md
                ) {
                    composeSheetButton(
                        label: "Evento",
                        systemImage: "calendar.badge.plus",
                        tint: Color.ruulWarning,
                        action: {
                            showComposeSheet = false
                            onCreateEvent()
                        }
                    )
                    composeSheetButton(
                        label: "Decidir",
                        systemImage: "checkmark.square",
                        tint: GroupColorRamp.blue.accent,
                        action: {
                            showComposeSheet = false
                            onOpenDecisions()
                        }
                    )
                    composeSheetButton(
                        label: "Invitar",
                        systemImage: "person.badge.plus",
                        tint: GroupColorRamp.purple.accent,
                        action: {
                            showComposeSheet = false
                            onInviteMembers()
                        }
                    )
                }

                Spacer()
            }
            .padding(RuulSpacing.lg)
            .navigationTitle("Coordinar")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func composeSheetButton(
        label: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: RuulSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
        }
        .buttonStyle(.plain)
        .ruulGlass(RoundedRectangle(cornerRadius: RuulRadius.lg), material: .regular, interactive: true)
    }
}
