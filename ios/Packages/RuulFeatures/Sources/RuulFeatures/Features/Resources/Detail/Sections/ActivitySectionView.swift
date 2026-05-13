import SwiftUI
import RuulUI
import RuulCore

/// Resource-scoped activity feed. Queries `system_events` filtered to
/// `resource_id = context.resource.id` so each row is a real atom (event
/// closed, fine officialized, vote opened, rule changed, …).
///
/// Settings-style grouped list under a quiet sentence-case header — no
/// more shouty "ACTIVIDAD" caps, no card chrome on loading / empty
/// states (those collapse to a quiet inline message instead).
public struct ActivitySectionView: View {
    @Environment(AppState.self) private var app

    public let context: ResourceDetailContext

    @State private var events: [SystemEvent] = []
    @State private var isLoading: Bool = true

    public static let definition = CapabilitySection(
        id: "activity",
        priority: 900,
        // Always render — every resource has a history.
        isEnabledFor: { _ in true },
        render: { ctx in AnyView(ActivitySectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            header
            content
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Actividad")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            if !events.isEmpty {
                Text("\(events.count)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: RuulSpacing.sm) {
                ProgressView()
                Text("Cargando…")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.xxs)
            .padding(.vertical, RuulSpacing.sm)
        } else if events.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
                Text("Aún no hay actividad")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.xxs)
            .padding(.vertical, RuulSpacing.sm)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(events.prefix(8).enumerated()), id: \.element.id) { idx, event in
                    activityRow(event)
                    if idx < min(7, events.count - 1) { divider }
                }
            }
            .background(
                Color.ruulSurface,
                in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
            )
        }
    }

    private func activityRow(_ event: SystemEvent) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: iconFor(event))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(labelFor(event))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(event.occurredAt.ruulRelativeDescription)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private var divider: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, RuulSpacing.md + 28 + RuulSpacing.md)
    }

    /// True when the SystemEvent's payload marks it as a cancellation
    /// (00098 emits eventClosed with status:cancelled for cancel_event).
    /// We keep the SystemEventType enum closed (no `eventCancelled`
    /// case) so the differentiation lives entirely in payload + the
    /// renderer.
    private func isCancelled(_ event: SystemEvent) -> Bool {
        guard event.eventType == .eventClosed else { return false }
        if case .string(let s) = event.payload["status"] {
            return s == "cancelled"
        }
        return false
    }

    private func iconFor(_ event: SystemEvent) -> String {
        switch event.eventType {
        case .eventCreated:        return "calendar.badge.plus"
        case .eventClosed:         return isCancelled(event) ? "xmark.circle" : "calendar.badge.checkmark"
        case .checkInRecorded:     return "qrcode"
        case .rsvpSubmitted:       return "checkmark.bubble"
        case .rsvpChangedSameDay:  return "arrow.uturn.backward"
        case .fineOfficialized:    return "exclamationmark.triangle.fill"
        case .fineVoided:          return "xmark.circle"
        case .finePaid:            return "checkmark.seal.fill"
        case .fineReminderSent:    return "bell.fill"
        case .voteOpened:          return "hand.raised.fill"
        case .voteCast:            return "checkmark.square.fill"
        case .voteResolved:        return "flag.checkered"
        case .appealCreated:       return "doc.text"
        case .appealResolved:      return "doc.text.fill"
        case .memberJoined:        return "person.fill.badge.plus"
        case .memberLeft:          return "person.fill.badge.minus"
        case .ruleEnabledChanged:  return "list.bullet.clipboard"
        case .ruleAmountChanged:   return "list.bullet.clipboard"
        default:                   return "circle.dotted"
        }
    }

    private func labelFor(_ event: SystemEvent) -> String {
        switch event.eventType {
        case .eventCreated:        return labelForEventCreated(event)
        case .eventClosed:         return isCancelled(event) ? "El evento se canceló" : "El evento cerró"
        case .checkInRecorded:     return "Alguien hizo check-in"
        case .rsvpSubmitted:       return "Alguien respondió"
        case .rsvpChangedSameDay:  return "Cambio de RSVP el mismo día"
        case .fineOfficialized:    return "Multa oficializada"
        case .fineVoided:          return "Multa anulada"
        case .finePaid:            return "Multa pagada"
        case .fineReminderSent:    return "Recordatorio de multa"
        case .voteOpened:          return "Se abrió una votación"
        case .voteCast:            return "Alguien votó"
        case .voteResolved:        return "Votación resuelta"
        case .appealCreated:       return "Se abrió apelación"
        case .appealResolved:      return "Apelación resuelta"
        case .memberJoined:        return "Alguien se unió al grupo"
        case .memberLeft:          return "Alguien dejó el grupo"
        case .ruleEnabledChanged:  return "Una regla cambió de estado"
        case .ruleAmountChanged:   return "Cambió el monto de una regla"
        default:                   return "Actividad"
        }
    }

    /// Tier 5 Beta: when the eventCreated payload carries `host_id`,
    /// surface the host's display name in the activity row so the feed
    /// reflects rotation assignments without a separate "hostAssigned"
    /// SystemEventType. The host_id payload was added in mig 00097 and
    /// preserved through 00126's recurrence wiring.
    private func labelForEventCreated(_ event: SystemEvent) -> String {
        let baseLabel = "Se creó el evento"
        guard case .string(let raw) = event.payload["host_id"],
              let hostUserId = UUID(uuidString: raw),
              let host = context.memberDirectory[hostUserId] else {
            return baseLabel
        }
        return "\(baseLabel) · anfitrión: \(host.displayName)"
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        let groupStream = (try? await app.systemEventRepo.recent(
            groupId: context.group.id,
            limit: 200
        )) ?? []
        events = groupStream.filter { $0.resourceId == context.resource.id }
    }
}
