import SwiftUI

/// Generic data shape for an event card. Patterns receive this struct rather
/// than the product's `Event` model so the design system stays decoupled.
public struct EventCardData: Identifiable, Sendable, Hashable {
    public enum RSVP: Sendable, Hashable { case going, maybe, notGoing, notResponded }

    public let id: String
    public let title: String
    public let dateText: String     // pre-formatted by caller
    public let location: String?
    public let rsvp: RSVP
    public let attendees: [RuulAvatarStack.Person]

    public init(id: String, title: String, dateText: String, location: String?, rsvp: RSVP, attendees: [RuulAvatarStack.Person]) {
        self.id = id
        self.title = title
        self.dateText = dateText
        self.location = location
        self.rsvp = rsvp
        self.attendees = attendees
    }
}

/// Standard event card.
public struct EventCardStub: View {
    private let data: EventCardData
    private let action: (() -> Void)?

    public init(_ data: EventCardData, action: (() -> Void)? = nil) {
        self.data = data
        self.action = action
    }

    public var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(data.title)
                            .ruulTextStyle(RuulTypography.title)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(data.dateText)
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer()
                    rsvpChip
                }
                if let location = data.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                if !data.attendees.isEmpty {
                    HStack {
                        RuulAvatarStack(people: data.attendees, size: .small, maxVisible: 5)
                        Spacer()
                    }
                }
            }
            .padding(RuulSpacing.s5)
        }
        .buttonStyle(.ruulPress)
        .background {
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .fill(Color.clear)
                .ruulGlass(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous), material: .regular)
        }
    }

    @ViewBuilder
    private var rsvpChip: some View {
        switch data.rsvp {
        case .going:
            Label("Voy", systemImage: "checkmark.circle.fill")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulSemanticSuccess)
        case .maybe:
            Label("Tal vez", systemImage: "questionmark.circle.fill")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulSemanticWarning)
        case .notGoing:
            Label("No voy", systemImage: "xmark.circle.fill")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulSemanticError)
        case .notResponded:
            Text("Pendiente")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }
}

#if DEBUG
#Preview("EventCardStub") {
    let attendees = (1...8).map { RuulAvatarStack.Person(id: "\($0)", name: "P\($0)") }
    return ScrollView {
        VStack(spacing: RuulSpacing.s3) {
            EventCardStub(.init(
                id: "1",
                title: "Cena de los miércoles",
                dateText: "Mié 7 may · 8:30 PM",
                location: "Casa de Jose",
                rsvp: .going,
                attendees: attendees
            ))
            EventCardStub(.init(
                id: "2",
                title: "Poker night",
                dateText: "Vie 9 may · 9:00 PM",
                location: nil,
                rsvp: .maybe,
                attendees: Array(attendees.prefix(4))
            ))
            EventCardStub(.init(
                id: "3",
                title: "Brunch de domingo",
                dateText: "Dom 11 may · 11:00 AM",
                location: "TBD",
                rsvp: .notResponded,
                attendees: []
            ))
        }
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
