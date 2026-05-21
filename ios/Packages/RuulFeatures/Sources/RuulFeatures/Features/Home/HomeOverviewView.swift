//
//  HomeOverviewView.swift
//  Ruul
//
//  Wave-3 home pivot — "qué necesita mi atención ahora", no dashboard.
//  Adaptación del boceto `HomeOverviewView` original al DS de Ruul (tokens
//  `RuulSpacing`/`RuulRadius`, primitives `RuulAvatar`/`RuulGroupAvatar`,
//  `.buttonStyle(.glass)`/`.glassProminent`) y al wiring real:
//
//    Greeting   ← `app.profile?.displayName`
//    Atención   ← `InboxCoordinator.actions` (mapeo UserAction → fila)
//    Espacios   ← `app.groups` (strip horizontal)
//    Próximo    ← `HomeCoordinator.nextEvent` (+ RSVP)
//    Actividad  ← <reservado>: el feed cross-grupos aún no existe; cuando
//                 llegue, se renderiza acá sin tocar el shell.
//
//  Las rutas son las MISMAS de `HomeTab` — sigue siendo `RootRouter` el
//  que despacha. Esta vista es drop-in y mantiene la misma signature que
//  `HomeView` para que `HomeTab` la cambie sin tocar nada más.
//

import SwiftUI
import RuulUI
import RuulCore

// SwiftUI also exports `Group` (the layout container). Inside this file
// the domain `RuulCore.Group` is the one we want — alias it once so
// `[Group]`/`(Group)` resolve without ambiguity.
private typealias RuulGroup = RuulCore.Group

public struct HomeOverviewView: View {
    @Bindable var coordinator: HomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    public var inboxCoordinator: InboxCoordinator?
    public var onInboxActionTap: (UserAction) async -> Void = { _ in }
    public let userId: UUID
    public var onCreateEvent: () -> Void
    public var onOpenEvent: (Event) -> Void
    public var onOpenPastEvents: () -> Void
    public var onOpenGroupHistory: () -> Void = {}
    public var onInvitePeople: (() -> Void)? = nil
    public var onSwitchGroup: () -> Void = {}

    public init(
        coordinator: HomeCoordinator,
        inboxCoordinator: InboxCoordinator?,
        onInboxActionTap: @escaping (UserAction) async -> Void = { _ in },
        userId: UUID,
        onCreateEvent: @escaping () -> Void,
        onOpenEvent: @escaping (Event) -> Void,
        onOpenPastEvents: @escaping () -> Void,
        onOpenGroupHistory: @escaping () -> Void = {},
        onInvitePeople: (() -> Void)? = nil,
        onSwitchGroup: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.inboxCoordinator = inboxCoordinator
        self.onInboxActionTap = onInboxActionTap
        self.userId = userId
        self.onCreateEvent = onCreateEvent
        self.onOpenEvent = onOpenEvent
        self.onOpenPastEvents = onOpenPastEvents
        self.onOpenGroupHistory = onOpenGroupHistory
        self.onInvitePeople = onInvitePeople
        self.onSwitchGroup = onSwitchGroup
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: RuulSpacing.s0) {
                greetingHeader

                if let actions = inboxCoordinator?.actions, !actions.isEmpty {
                    SectionHeading("Necesita tu atención")
                    AttentionCard(
                        actions: actions,
                        onTap: { action in Task { await onInboxActionTap(action) } }
                    )
                }

                if !app.groups.isEmpty {
                    SectionHeading("Tus espacios", actionLabel: "Todos") {
                        onSwitchGroup()
                    }
                    SpacesStrip(
                        groups: app.groups,
                        activeId: app.activeGroupId,
                        pendingByGroup: pendingByGroup,
                        onSelect: { group in
                            app.activeGroupId = group.id
                            router.selectTab(.groups)
                        }
                    )
                }

                if let event = coordinator.nextEvent {
                    SectionHeading("Próximo")
                    UpcomingCard(
                        event: event,
                        rsvp: coordinator.myRSVPs[event.id],
                        onTap: { onOpenEvent(event) },
                        onRSVP: { status in Task { await setRSVP(event: event, status: status) } }
                    )
                }

                Color.clear.frame(height: RuulSpacing.s12) // padding por tab bar
            }
            .padding(.horizontal, RuulSpacing.s5)
        }
        .background(Color.ruulBackgroundRecessed)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .refreshable {
            async let h: Void = coordinator.refresh(force: true)
            async let i: Void? = inboxCoordinator?.refresh()
            _ = await (h, i)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            async let h: Void = coordinator.refresh()
            async let i: Void? = inboxCoordinator?.refresh()
            _ = await (h, i)
        }
    }

    // MARK: Greeting
    //
    // Apple Health / Apple Fitness daily-brief pattern: bold large title +
    // dense first-name, weekday tag right-aligned. The italic is dropped
    // when the displayName looks like an email/handle id (no spaces,
    // all-lower) so "jmizrahit" doesn't read like a stylised brand.

    @ViewBuilder
    private var greetingHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: RuulSpacing.s0) {
                Text(greetingLine)
                    .font(.largeTitle.weight(.bold))
                Text(displayName)
                    .font(.largeTitle.weight(.semibold))
                    .italic(displayNameLooksLikeRealName)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: RuulSpacing.s3)
            Text(Date.now, format: .dateTime.weekday(.wide))
                .font(.subheadline)
                .foregroundStyle(Color.ruulTextSecondary)
                .textCase(.lowercase)
        }
        .padding(.top, RuulSpacing.s2)
    }

    /// Returns the friendliest form of the profile name we can render
    /// without surprising the user. Three cases:
    ///   1. has a space → first word capitalised ("Jose Mizrahi" → "Jose")
    ///   2. looks like a handle (no spaces, all lowercase, optional dots /
    ///      underscores / digits) → capitalise the first character only
    ///      ("jmizrahit" → "Jmizrahit")
    ///   3. anything else → return as-is.
    private var displayName: String {
        guard let raw = app.profile?.displayName, !raw.isEmpty else { return "" }
        if let firstSpace = raw.firstIndex(of: " ") {
            return String(raw[..<firstSpace]).capitalized
        }
        if raw.allSatisfy({ $0.isLetter ? $0.isLowercase : true }) {
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
        return raw
    }

    /// True when the displayName has a real space (suggesting "Nombre
    /// Apellido"). Drives the italic — handles look better upright.
    private var displayNameLooksLikeRealName: Bool {
        app.profile?.displayName.contains(" ") == true
    }

    private var greetingLine: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return "Buen día,"
        case 12..<19: return "Buenas tardes,"
        default:       return "Buenas noches,"
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Apple Maps pattern: avatar-only button to the profile sheet —
        // no inline name (the greeting body owns the name) so the toolbar
        // stays uncrowded. Tap targets remain 44pt via the .glass button.
        ToolbarItem(placement: .topBarLeading) {
            Button {
                router.selectTab(.profile)
            } label: {
                RuulAvatar(name: app.profile?.displayName ?? "", size: .xs)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Tu perfil")
        }
        if let onInvitePeople {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onInvitePeople) {
                    Image(systemName: "person.badge.plus")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Invitar gente")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.presentCreate(hasActiveGroup: app.activeGroup != nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Crear")
        }
    }

    // MARK: Pending counts per group (badge en cards de SpacesStrip)

    private var pendingByGroup: [UUID: Int] {
        guard let actions = inboxCoordinator?.actions else { return [:] }
        return Dictionary(grouping: actions, by: { $0.groupId }).mapValues(\.count)
    }

    // MARK: RSVP dispatch

    private func setRSVP(event: Event, status: RSVPStatus) async {
        // Use the repo directly — `HomeCoordinator` doesn't own a mutator
        // since RSVP changes live on the detail surface.  The next
        // `coordinator.refresh()` will sync `myRSVPs`. The inbox refresh
        // is required so the server-resolved `rsvpPending` user_action
        // (mig 00158 `on_rsvp_action_inserted` trigger) actually drops
        // out of the "Necesita tu atención" list — otherwise the row
        // lingers until pull-to-refresh.
        _ = try? await app.rsvpRepo.setRSVP(
            eventId: event.id,
            status: status,
            plusOnes: 0,
            reason: nil
        )
        async let h: Void = coordinator.refresh(force: true)
        async let i: Void? = router.state.refreshInboxes()
        _ = await (h, i)
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: ATTENTION
// MARK: ════════════════════════════════════════════════════════════════════

/// Recipe mirrored verbatim from `GroupPendingsBlock` — `Color.ruulSurface`
/// directly in `.background(_, in: RoundedRectangle(cornerRadius: .lg))`,
/// 0.5pt separator stroke, leading-inset divider, `RuulSpacing.md` row
/// padding, 40pt circular icon badge with 12% tint.  The "Necesita tu
/// atención" label now lives in the outer `SectionHeading`; the card
/// itself is rows-only, no internal header bar.
private struct AttentionCard: View {
    let actions: [UserAction]
    let onTap: (UserAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.prefix(5).enumerated()), id: \.element.id) { index, action in
                AttentionRow(action: action, onTap: { onTap(action) })
                if index < min(actions.count, 5) - 1 {
                    Divider()
                        .background(Color(.separator))
                        .padding(.leading, 64)
                }
            }
        }
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}

/// Reuses `GroupPendingsBlock` static helpers for icon / tint / cta —
/// single source of truth across home + group page. The data-side
/// `action.title` / `action.body` come straight from the backend so
/// neither surface invents its own copy.  Routing lives in
/// `HomeTab.handleInboxAction(_:)`; we just dispatch with `onTap`.
private struct AttentionRow: View {
    let action: UserAction
    let onTap: () -> Void
    @State private var tapTick: Int = 0

    var body: some View {
        Button(action: {
            tapTick &+= 1
            onTap()
        }) {
            HStack(spacing: RuulSpacing.md) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: GroupPendingsBlock.icon(for: action.actionType))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroupPendingsBlock.tint(for: action.actionType))
                        .frame(width: 40, height: 40)
                        .background(
                            GroupPendingsBlock.tint(for: action.actionType).opacity(0.12),
                            in: Circle()
                        )

                    if action.priority == .urgent || action.priority == .high {
                        Circle()
                            .fill(Color.ruulNegative)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.ruulSurface, lineWidth: 2))
                            .offset(x: 2, y: -2)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if let body = action.body, !body.isEmpty {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button(GroupPendingsBlock.cta(for: action.actionType)) {
                    tapTick &+= 1
                    onTap()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ruulTextInverse)
                .padding(.horizontal, RuulSpacing.sm)
                .padding(.vertical, RuulSpacing.xxs)
                .background(GroupPendingsBlock.tint(for: action.actionType), in: Capsule())
                .buttonStyle(.plain)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: tapTick)
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: SPACES STRIP
// MARK: ════════════════════════════════════════════════════════════════════

private struct SpacesStrip: View {
    let groups: [RuulGroup]
    let activeId: UUID?
    let pendingByGroup: [UUID: Int]
    let onSelect: (RuulGroup) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: RuulSpacing.s4) {
                ForEach(groups, id: \.id) { group in
                    Button { onSelect(group) } label: {
                        GroupCard(
                            group: group,
                            isActive: group.id == activeId,
                            pending: pendingByGroup[group.id] ?? 0
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RuulSpacing.s5)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .padding(.horizontal, -RuulSpacing.s5)
        .padding(.bottom, RuulSpacing.s3)
    }
}

private struct GroupCard: View {
    let group: RuulGroup
    let isActive: Bool
    let pending: Int

    var body: some View {
        // Apple Music "Recently Played" tile pattern: bigger avatar
        // anchored at the top, single bold title underneath, optional
        // micro-status line ("3 pendientes") when there's actionable
        // signal. The repeated `category.displayName` was visual noise —
        // every group in the same template flavour echoed the same
        // phrase, so it dropped.
        VStack(alignment: .leading, spacing: RuulSpacing.s0) {
            RuulGroupAvatar(groupName: group.name, category: group.category, size: .lg)
                .padding(.bottom, RuulSpacing.s3)

            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(1)

            if pending > 0 {
                Text("\(pending) pendiente\(pending == 1 ? "" : "s")")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.ruulSemanticError)
                    .padding(.top, RuulSpacing.s0_5)
                    .monospacedDigit()
            }
        }
        .frame(width: HomeMetrics.groupCardWidth, alignment: .leading)
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(isActive ? Color.ruulAccent : Color(.separator),
                        lineWidth: isActive ? HomeMetrics.activeStrokeWidth : 0.5)
        )
        .scrollTransition(.animated.threshold(.visible(0.05))) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                .opacity(phase.isIdentity ? 1 : 0.6)
        }
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: UPCOMING
// MARK: ════════════════════════════════════════════════════════════════════

private struct UpcomingCard: View {
    let event: Event
    let rsvp: RSVP?
    let onTap: () -> Void
    let onRSVP: (RSVPStatus) -> Void

    var body: some View {
        VStack(spacing: RuulSpacing.s4) {
            Button(action: onTap) {
                HStack(spacing: RuulSpacing.s4) {
                    DateTile(date: event.startsAt)

                    VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                        Text(event.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ruulTextPrimary)
                            .lineLimit(2)
                        // Apple Calendar event-cell pattern: time + venue
                        // on one line, venue uses first comma-segment so
                        // "Altezza Bosques, Camino a Tecamachalco 98"
                        // reads as "Altezza Bosques" — no mid-word cut.
                        HStack(spacing: RuulSpacing.s1) {
                            Text(event.startsAt, format: .dateTime.hour().minute())
                                .font(.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                                .monospacedDigit()
                            if let venue = primaryVenue(event.locationName) {
                                Text("·").font(.caption).foregroundStyle(Color.ruulTextSecondary)
                                Text(venue)
                                    .font(.caption)
                                    .foregroundStyle(Color.ruulTextSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: RuulSpacing.s3) {
                rsvpButton(.going, label: "Voy", icon: "checkmark", tint: .ruulSemanticSuccess)
                rsvpButton(.maybe, label: "Tal vez", tint: nil)
                rsvpButton(.declined, label: "No", tint: .ruulSemanticError)
            }
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    /// Takes a free-form address (e.g. "Altezza Bosques, Camino a
    /// Tecamachalco 98, El Olivo, 52789 Naucalpan") and returns the
    /// venue / first-segment so the card preview never cuts a road
    /// number mid-word. Returns nil for empty/whitespace input.
    private func primaryVenue(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let comma = raw.firstIndex(of: ",") {
            let head = raw[..<comma].trimmingCharacters(in: .whitespaces)
            return head.isEmpty ? raw : head
        }
        return raw
    }

    /// Apple segmented-selector recipe: the selected option fills via
    /// `.glassProminent` + semantic tint (filled CTA, white label by
    /// system contrast); the others stay outlined via plain `.glass`
    /// with default accent label.  Avoids the `Color.ruulFillGlassStrong`
    /// as-tint antipattern that washed the label into the background.
    @ViewBuilder
    private func rsvpButton(_ status: RSVPStatus, label: String, icon: String? = nil, tint: Color?) -> some View {
        let isSelected = rsvp?.status == status
        Button { onRSVP(status) } label: {
            HStack(spacing: RuulSpacing.s1) {
                if let icon { Image(systemName: icon).font(.caption.weight(.bold)) }
                Text(label).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: HomeMetrics.rsvpButtonMinHeight)
        }
        .modifier(RSVPButtonStyle(isSelected: isSelected, tint: tint))
        .sensoryFeedback(.success, trigger: rsvp?.status)
    }
}

private struct RSVPButtonStyle: ViewModifier {
    let isSelected: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        if isSelected {
            content
                .buttonStyle(.glassProminent)
                .tint(tint ?? Color.ruulAccent)
        } else {
            content
                .buttonStyle(.glass)
        }
    }
}

private struct DateTile: View {
    let date: Date

    var body: some View {
        VStack(spacing: RuulSpacing.s0_5) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.ruulSemanticError)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(date, format: .dateTime.day())
                .font(.title.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .frame(width: HomeMetrics.dateTile, height: HomeMetrics.dateTile)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: SHARED
// MARK: ════════════════════════════════════════════════════════════════════

private struct SectionHeading: View {
    let title: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    init(_ title: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        // Group-page recipe (GroupPendingsBlock / GroupStreamBlock /
        // GroupSpacesGrid): `.footnote.weight(.semibold)` in
        // `tertiaryLabel`, leading-inset `RuulSpacing.xxs` (4pt) so the
        // title aligns with the card body, not the screen edge.
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Spacer()
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ruulAccent)
            }
        }
        .padding(.leading, RuulSpacing.xxs)
        .padding(.top, RuulSpacing.s5)
        .padding(.bottom, RuulSpacing.xs)
    }
}

private struct PulseDot: View {
    let color: Color
    @State private var phase: CGFloat = 0

    /// Diameter of the inner dot; the outer halo pulses at ~2.4× this.
    /// Sized to RuulSpacing.micro so the eye reads it as a subtle marker
    /// (~6pt) inline with caption-weight type.
    private var dotSize: CGFloat { RuulSpacing.micro }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.25))
                .frame(width: dotSize * 2.4, height: dotSize * 2.4)
                .scaleEffect(0.6 + phase * 0.4)
                .opacity(1 - phase)
            Circle().fill(color)
                .frame(width: dotSize, height: dotSize)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Layout intents

/// Frame sizes that aren't expressible in semantic spacing/radius tokens
/// (icon tile dimensions, fixed-width strip card). Centralised here so
/// every magic number has a name and an intent, never repeated inline.
private enum HomeMetrics {
    /// Square icon "well" that backs an attention-row symbol. Matches the
    /// iOS Settings-style icon dimension.
    static let iconTile: CGFloat = 34
    /// Calendar-tile in `UpcomingCard`. Square, ~50pt — Apple Calendar
    /// "date pill" recipe.
    static let dateTile: CGFloat = 50
    /// Width of a single card inside the horizontal SpacesStrip — chosen
    /// so 2.4 cards fit on a 393pt-wide device, enough peek for the
    /// scroll affordance without losing card legibility.
    static let groupCardWidth: CGFloat = 144
    /// Stroke width of the "active group" highlight ring.
    static let activeStrokeWidth: CGFloat = 1.5
    /// Min height of the RSVP triplet buttons (Voy / Tal vez / No) so all
    /// three line up at a comfortable tappable target.
    static let rsvpButtonMinHeight: CGFloat = 32
}

// UserAction row mapping (icon/tint/cta) was duplicated here previously.
// Now we read it directly from `GroupPendingsBlock.icon/tint/cta` so the
// home and group page can never drift on the same actionType, and the
// row title/body comes verbatim from the data (`action.title`,
// `action.body`) — backend is the single source of truth.
