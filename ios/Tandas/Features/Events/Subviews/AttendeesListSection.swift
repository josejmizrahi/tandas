import SwiftUI

/// Sectioned list of attendees by RSVP status. Avatar stack at top + 4
/// expandable sections (going / maybe / declined / pending) with counts.
struct AttendeesListSection: View {
    let rsvps: [RSVP]
    let memberLookup: (UUID) -> (name: String, avatarURL: URL?)
    /// Tap callback opcional. Cuando set, cada attendee row se vuelve un
    /// Button que dispatch con el userId. Default nil = filas display-only
    /// (preserva back-compat con previews/tests sin nav stack).
    var onSelectAttendee: ((UUID) -> Void)? = nil

    @State private var expanded: Set<RSVPStatus> = [.going]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            avatarStack
            ForEach(RSVPStatus.allCases, id: \.self) { status in
                section(for: status)
            }
        }
    }

    private var avatarStack: some View {
        let going = rsvps.filter { $0.status == .going }
        let people = going.map {
            let info = memberLookup($0.userId)
            return RuulAvatarStack.Person(id: $0.userId.uuidString, name: info.name, imageURL: info.avatarURL)
        }
        return SwiftUI.Group {
            if !people.isEmpty {
                RuulAvatarStack(people: people, size: .large, maxVisible: 6)
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func section(for status: RSVPStatus) -> some View {
        let filtered = rsvps.filter { $0.status == status }
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Button {
                    withAnimation(.ruulSnappy) {
                        if expanded.contains(status) { expanded.remove(status) }
                        else { expanded.insert(status) }
                    }
                } label: {
                    HStack(spacing: RuulSpacing.xs) {
                        sectionIcon(for: status)
                        Text(sectionLabel(for: status).uppercased())
                            .ruulTextStyle(RuulTypography.sectionLabelLg)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("\(filtered.count)")
                            .ruulTextStyle(RuulTypography.statSmall)
                            .foregroundStyle(Color.ruulTextTertiary)
                        Spacer()
                        Image(systemName: expanded.contains(status) ? "chevron.up" : "chevron.down")
                            .font(.system(size: RuulSize.iconXS, weight: .bold))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded.contains(status) {
                    VStack(spacing: RuulSpacing.xs) {
                        ForEach(filtered, id: \.id) { rsvp in
                            attendeeRow(rsvp)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private func attendeeRow(_ rsvp: RSVP) -> some View {
        let info = memberLookup(rsvp.userId)
        if let onSelectAttendee {
            Button { onSelectAttendee(rsvp.userId) } label: {
                attendeeRowContent(rsvp: rsvp, info: info)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            attendeeRowContent(rsvp: rsvp, info: info)
        }
    }

    @ViewBuilder
    private func attendeeRowContent(rsvp: RSVP, info: (name: String, avatarURL: URL?)) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            RuulAvatar(name: info.name, imageURL: info.avatarURL, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                if rsvp.isCheckedIn, let arrived = rsvp.arrivedAt {
                    Text("Llegó \(arrived.ruulShortTime)")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulPositive)
                }
            }
            Spacer()
        }
        .padding(.vertical, RuulSpacing.xxs)
    }

    private func sectionIcon(for status: RSVPStatus) -> some View {
        let (icon, color): (String, Color) = {
            switch status {
            case .going:      return ("checkmark.circle.fill", .ruulPositive)
            case .maybe:      return ("questionmark.circle.fill", .ruulWarning)
            case .declined:   return ("xmark.circle.fill", .ruulNegative)
            case .waitlisted: return ("person.crop.circle.badge.clock", .ruulWarning)
            case .pending:    return ("clock", .ruulTextTertiary)
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(color)
    }

    private func sectionLabel(for status: RSVPStatus) -> String {
        switch status {
        case .going:      return "Van"
        case .maybe:      return "Tal vez"
        case .declined:   return "No van"
        case .waitlisted: return "Lista de espera"
        case .pending:    return "Pendientes"
        }
    }
}
