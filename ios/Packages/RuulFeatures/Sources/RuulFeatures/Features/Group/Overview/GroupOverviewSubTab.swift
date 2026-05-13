import SwiftUI
import RuulUI
import RuulCore

/// Group "home" — the most important screen post-G1. Answers the user's
/// four questions every time they open the app:
///
///   1. ¿Qué sigue?           → "Próximamente" section
///   2. ¿Qué debo hacer?      → "Necesita atención" section
///   3. ¿Qué recursos hay?    → "Recursos activos" section
///   4. ¿Qué acaba de pasar?  → "Actividad reciente" section
///
/// Above all that sits a thin hero with the group's identity + meta. The
/// page is action-oriented: every section's rows are tappable and route
/// the user to where the action lives (event detail, fine detail, rule
/// detail, resource detail, money sub-tab).
public struct GroupOverviewSubTab: View {
    @Environment(AppState.self) private var app
    public let group: RuulCore.Group
    public let upcomingEvents: [Event]
    public let myRSVPs: [UUID: RSVP]
    public let inboxCoordinator: InboxCoordinator?
    public let userId: UUID
    public let onOpenEvent: (Event) -> Void
    public let onOpenFine: (Fine) -> Void
    public let onOpenInboxAction: (UserAction) async -> Void
    public let onGoToMoney: () -> Void

    @State private var resources: [ResourceRow] = []
    @State private var recentActivity: [SystemEvent] = []
    @State private var openedResource: ResourceRow?
    @State private var isLoading: Bool = true

    public init(
        group: RuulCore.Group,
        upcomingEvents: [Event],
        myRSVPs: [UUID: RSVP],
        inboxCoordinator: InboxCoordinator?,
        userId: UUID,
        onOpenEvent: @escaping (Event) -> Void,
        onOpenFine: @escaping (Fine) -> Void,
        onOpenInboxAction: @escaping (UserAction) async -> Void,
        onGoToMoney: @escaping () -> Void
    ) {
        self.group = group
        self.upcomingEvents = upcomingEvents
        self.myRSVPs = myRSVPs
        self.inboxCoordinator = inboxCoordinator
        self.userId = userId
        self.onOpenEvent = onOpenEvent
        self.onOpenFine = onOpenFine
        self.onOpenInboxAction = onOpenInboxAction
        self.onGoToMoney = onGoToMoney
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                heroBlock
                attentionSection
                upcomingSection
                resourcesSection
                activitySection
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
        .sheet(item: $openedResource) { row in
            ResourceDetailSheet(resource: row)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(group.name)
                .ruulTextStyle(RuulTypography.displayMedium)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(2)
            Text(heroSubtitle)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.top, RuulSpacing.xs)
    }

    private var heroSubtitle: String {
        // Members + active resources today. Best-effort with what we have
        // on hand; full member count comes from app.groups after load.
        let activeResources = resources.count
        var parts: [String] = []
        if activeResources > 0 {
            parts.append(activeResources == 1 ? "1 recurso activo" : "\(activeResources) recursos activos")
        }
        if !upcomingEvents.isEmpty {
            parts.append("\(upcomingEvents.count) por venir")
        }
        if parts.isEmpty { return "Empieza creando un recurso o un evento." }
        return parts.joined(separator: " · ")
    }

    // MARK: - Necesita atención

    @ViewBuilder
    private var attentionSection: some View {
        let actions = (inboxCoordinator?.actions ?? []).filter { $0.groupId == group.id }
        if !actions.isEmpty {
            sectionHeader(title: "NECESITA ATENCIÓN", count: actions.count)
            VStack(spacing: RuulSpacing.xs) {
                ForEach(actions.prefix(5)) { action in
                    ActionCard(
                        icon: pendingIcon(for: action.actionType),
                        meta: action.createdAt.ruulRelativeDescription,
                        title: action.title,
                        subtitle: action.body,
                        priority: pendingPriority(for: action.priority),
                        timeRemaining: nil,
                        onTap: { Task { await onOpenInboxAction(action) } }
                    )
                }
            }
        }
    }

    private func pendingIcon(for type: ActionType) -> String {
        switch type {
        case .finePending:             return "exclamationmark.triangle.fill"
        case .fineVoided:              return "xmark.circle"
        case .appealVotePending:       return "hand.raised.fill"
        case .rsvpPending:             return "checkmark.circle.fill"
        case .fineProposalReview:      return "doc.text.magnifyingglass"
        case .ruleChangeApplyPending:  return "list.bullet.clipboard.fill"
        case .hostAssigned:            return "person.crop.circle.badge.checkmark"
        case .slotPending:             return "ticket.fill"
        case .votePending:             return "hand.raised.fill"
        case .contributionDue:         return "banknote.fill"
        case .compensationDue:         return "arrow.up.right"
        }
    }

    private func pendingPriority(for raw: ActionPriority) -> ActionCard.Priority {
        switch raw {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        case .urgent: return .urgent
        }
    }

    // MARK: - Próximamente

    @ViewBuilder
    private var upcomingSection: some View {
        if !upcomingEvents.isEmpty {
            sectionHeader(title: "PRÓXIMAMENTE", count: upcomingEvents.count)
            VStack(spacing: RuulSpacing.xs) {
                ForEach(upcomingEvents.prefix(5)) { event in
                    EventRow(
                        event: event,
                        originGroup: nil,
                        myStatus: myRSVPs[event.id]?.status,
                        onTap: { onOpenEvent(event) }
                    )
                }
            }
        }
    }

    // MARK: - Recursos activos

    @ViewBuilder
    private var resourcesSection: some View {
        let nonEvent = resources.filter { $0.resourceType != .event }
        if !nonEvent.isEmpty {
            sectionHeader(title: "RECURSOS ACTIVOS", count: nonEvent.count)
            VStack(spacing: RuulSpacing.xs) {
                ForEach(nonEvent.prefix(6)) { row in
                    resourceRow(row)
                }
            }
        }
    }

    private func resourceRow(_ row: ResourceRow) -> some View {
        Button {
            openedResource = row
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle().fill(Color.ruulSurface).frame(width: 40, height: 40)
                    Image(systemName: iconFor(row.resourceType))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayNameFor(row))
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    Text(row.resourceType.humanLabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func displayNameFor(_ row: ResourceRow) -> String {
        if case let .string(s) = row.metadata["name"]  { return s }
        if case let .string(s) = row.metadata["title"] { return s }
        return row.resourceType.humanLabel
    }

    private func iconFor(_ type: ResourceType) -> String {
        switch type {
        case .event:        return "calendar"
        case .asset:        return "key.fill"
        case .slot:         return "ticket"
        case .fund:         return "banknote"
        case .booking:      return "calendar.badge.checkmark"
        case .contribution: return "arrow.up.bin"
        default:            return "square.dashed"
        }
    }

    // MARK: - Actividad reciente

    @ViewBuilder
    private var activitySection: some View {
        if !recentActivity.isEmpty {
            sectionHeader(title: "ACTIVIDAD RECIENTE", count: recentActivity.count)
            VStack(spacing: RuulSpacing.xs) {
                ForEach(recentActivity.prefix(5)) { event in
                    activityRow(event)
                }
            }
        }
    }

    private func activityRow(_ event: SystemEvent) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle().fill(Color.ruulBackgroundRecessed).frame(width: 32, height: 32)
                Image(systemName: activityIcon(event.eventType))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(activityLabel(event.eventType))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(event.occurredAt.ruulRelativeDescription)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private func activityIcon(_ type: SystemEventType) -> String {
        switch type {
        case .eventCreated:        return "calendar.badge.plus"
        case .eventClosed:         return "calendar.badge.checkmark"
        case .checkInRecorded:     return "qrcode"
        case .fineOfficialized:    return "exclamationmark.triangle.fill"
        case .fineVoided:          return "xmark.circle"
        case .finePaid:            return "checkmark.seal.fill"
        case .fineReminderSent:    return "bell.fill"
        case .voteOpened:          return "hand.raised.fill"
        case .voteCast:            return "checkmark.square.fill"
        case .voteResolved:        return "flag.checkered"
        case .appealCreated:       return "doc.text"
        case .appealResolved:      return "doc.text.fill"
        case .ruleEnabledChanged:  return "list.bullet.clipboard"
        case .ruleAmountChanged:   return "list.bullet.clipboard"
        default:                   return "circle.dotted"
        }
    }

    private func activityLabel(_ type: SystemEventType) -> String {
        switch type {
        case .eventCreated:        return "Se creó un evento"
        case .eventClosed:         return "Un evento cerró"
        case .checkInRecorded:     return "Alguien hizo check-in"
        case .fineOfficialized:    return "Multa oficializada"
        case .fineVoided:          return "Multa anulada"
        case .finePaid:            return "Multa pagada"
        case .fineReminderSent:    return "Recordatorio de multa"
        case .voteOpened:          return "Se abrió una votación"
        case .voteCast:            return "Alguien votó"
        case .voteResolved:        return "Votación resuelta"
        case .appealCreated:       return "Se abrió una apelación"
        case .appealResolved:      return "Apelación resuelta"
        case .ruleEnabledChanged:  return "Una regla cambió de estado"
        case .ruleAmountChanged:   return "Cambió el monto de una regla"
        default:                   return "Actividad del grupo"
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Spacer()
            Text("\(count)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    // MARK: - Load

    @MainActor
    private func load(force: Bool) async {
        if force || resources.isEmpty {
            do {
                let types: [ResourceType] = [.event, .asset, .slot, .fund, .booking, .contribution]
                resources = try await app.resourceRepo.list(
                    in: group.id,
                    types: types,
                    statuses: nil,
                    limit: 50
                )
            } catch {
                resources = []
            }
        }
        if force || recentActivity.isEmpty {
            recentActivity = (try? await app.systemEventRepo.recent(groupId: group.id, limit: 10)) ?? []
        }
        isLoading = false
    }
}
