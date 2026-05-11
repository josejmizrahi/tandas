import SwiftUI
import RuulUI
import RuulCore

/// Resource-scoped activity feed. Queries `system_events` filtered to
/// `resource_id = context.resource.id` so each row is a real atom
/// (event closed, fine officialized, vote opened, rule changed, etc).
///
/// Always enabled — there's no "off" state for memory. Lives at the
/// bottom of the dynamic stack (priority 900) so it acts as the
/// chronological tail of the section column.
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
            sectionHeader("ACTIVIDAD", count: events.isEmpty ? nil : events.count)
            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView().padding(RuulSpacing.lg)
                Spacer()
            }
            .cardBackground()
        } else if events.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Aún no hay actividad")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
            .padding(RuulSpacing.md)
            .cardBackground()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(events.prefix(8).enumerated()), id: \.element.id) { idx, event in
                    activityRow(event)
                    if idx < min(7, events.count - 1) { divider }
                }
            }
            .cardBackground()
        }
    }

    private func activityRow(_ event: SystemEvent) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle().fill(Color.ruulBackgroundRecessed).frame(width: 32, height: 32)
                Image(systemName: iconFor(event.eventType))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(labelFor(event.eventType))
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
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 48)
    }

    private func iconFor(_ type: SystemEventType) -> String {
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

    private func labelFor(_ type: SystemEventType) -> String {
        switch type {
        case .eventCreated:        return "Se creó el evento"
        case .eventClosed:         return "El evento cerró"
        case .checkInRecorded:     return "Alguien hizo check-in"
        case .fineOfficialized:    return "Multa oficializada"
        case .fineVoided:          return "Multa anulada"
        case .finePaid:            return "Multa pagada"
        case .fineReminderSent:    return "Recordatorio de multa"
        case .voteOpened:          return "Se abrió una votación"
        case .voteCast:            return "Alguien votó"
        case .voteResolved:        return "Votación resuelta"
        case .appealCreated:       return "Se abrió apelación"
        case .appealResolved:      return "Apelación resuelta"
        case .ruleEnabledChanged:  return "Una regla cambió de estado"
        case .ruleAmountChanged:   return "Cambió el monto de una regla"
        default:                   return "Actividad"
        }
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        // The system_events repository's `recent(groupId:)` returns the
        // group-wide stream. We filter client-side to this resource —
        // a dedicated `recent(resourceId:)` is worth adding when the
        // group's stream grows beyond a few hundred rows.
        let groupStream = (try? await app.systemEventRepo.recent(
            groupId: context.group.id,
            limit: 200
        )) ?? []
        events = groupStream.filter { $0.resourceId == context.resource.id }
    }
}
