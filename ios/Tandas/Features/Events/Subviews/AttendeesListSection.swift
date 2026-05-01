import SwiftUI

/// Sectioned list of attendees by RSVP status. Avatar stack at top + 4
/// expandable sections (going / maybe / declined / pending) with counts.
struct AttendeesListSection: View {
    let rsvps: [RSVP]
    let memberLookup: (UUID) -> (name: String, avatarURL: URL?)

    @State private var expanded: Set<RSVPStatus> = [.going]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s5) {
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
        return Group {
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
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Button {
                    withAnimation(.ruulSnappy) {
                        if expanded.contains(status) { expanded.remove(status) }
                        else { expanded.insert(status) }
                    }
                } label: {
                    HStack(spacing: RuulSpacing.s2) {
                        sectionIcon(for: status)
                        Text("\(sectionLabel(for: status)) (\(filtered.count))")
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        Image(systemName: expanded.contains(status) ? "chevron.up" : "chevron.down")
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded.contains(status) {
                    VStack(spacing: RuulSpacing.s2) {
                        ForEach(filtered, id: \.id) { rsvp in
                            attendeeRow(rsvp)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func attendeeRow(_ rsvp: RSVP) -> some View {
        let info = memberLookup(rsvp.userId)
        return HStack(spacing: RuulSpacing.s3) {
            RuulAvatar(name: info.name, imageURL: info.avatarURL, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                if rsvp.isCheckedIn, let arrived = rsvp.arrivedAt {
                    Text("Llegó \(arrived.ruulShortTime)")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulSemanticSuccess)
                }
            }
            Spacer()
        }
        .padding(.vertical, RuulSpacing.s1)
    }

    private func sectionIcon(for status: RSVPStatus) -> some View {
        let (icon, color): (String, Color) = {
            switch status {
            case .going:    return ("checkmark.circle.fill", .ruulSemanticSuccess)
            case .maybe:    return ("questionmark.circle.fill", .ruulSemanticWarning)
            case .declined: return ("xmark.circle.fill", .ruulSemanticError)
            case .pending:  return ("clock", .ruulTextTertiary)
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(color)
    }

    private func sectionLabel(for status: RSVPStatus) -> String {
        switch status {
        case .going:    return "Van"
        case .maybe:    return "Tal vez"
        case .declined: return "No van"
        case .pending:  return "Pendientes"
        }
    }
}
