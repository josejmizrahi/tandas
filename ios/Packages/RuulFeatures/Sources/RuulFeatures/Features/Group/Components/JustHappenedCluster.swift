import SwiftUI
import RuulUI
import RuulCore

/// "Acabó de pasar" — cluster #5 de la doctrina situacional.
///
/// V4 fix (2026-05-25): la versión PR-1 leía `my_activity_v1`
/// (per-user) y mostraba "Tú confirmaste asistencia". Ahora lee
/// `system_events` group-wide vía `HistoryItemPresentation`, así
/// el feed verdaderamente refleja al grupo: "José confirmó
/// asistencia", "Linda pagó la cena". Auto-oculta si está vacío.
@MainActor
struct JustHappenedCluster: View {
    let events: [SystemEvent]
    let members: [MemberWithProfile]
    var onSeeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text("Acabó de pasar")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer()
                if let onSeeAll {
                    Button("Ver todo", action: onSeeAll)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(events) { event in
                    JustHappenedRow(event: event, members: members)
                    if event.id != events.last?.id {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 54)
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
}

@MainActor
private struct JustHappenedRow: View {
    let event: SystemEvent
    let members: [MemberWithProfile]

    var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            RuulAvatar(
                name: actorMember?.displayName ?? "Alguien",
                imageURL: actorMember?.avatarURL,
                size: .small
            )

            VStack(alignment: .leading, spacing: 2) {
                let presentation = HistoryItemPresentation(
                    event: event,
                    memberName: actorMember?.displayName
                )
                Text(presentation.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                if let subtitle = presentation.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Text(relativeTime(event.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
    }

    private var actorMember: MemberWithProfile? {
        guard let id = event.memberId else { return nil }
        return members.first(where: { $0.member.id == id })
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "es_MX")
        return f.localizedString(for: date, relativeTo: .now)
    }
}
