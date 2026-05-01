import SwiftUI

/// RSVP state component. Renders 3 buttons when the user hasn't responded,
/// or a confirmed card with the chosen state.
public struct RSVPStateView: View {
    private let state: EventCardData.RSVP
    private let onSelect: (EventCardData.RSVP) -> Void

    public init(state: EventCardData.RSVP, onSelect: @escaping (EventCardData.RSVP) -> Void) {
        self.state = state
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            switch state {
            case .notResponded:
                threeButtons
            case .going, .maybe, .notGoing:
                confirmedCard
            }
        }
        .animation(.ruulMorph, value: state)
    }

    private var threeButtons: some View {
        HStack(spacing: RuulSpacing.s3) {
            stateButton(.going, label: "Voy", systemImage: "checkmark", tint: .ruulSemanticSuccess)
            stateButton(.maybe, label: "Tal vez", systemImage: "questionmark", tint: .ruulSemanticWarning)
            stateButton(.notGoing, label: "No voy", systemImage: "xmark", tint: .ruulSemanticError)
        }
    }

    private func stateButton(_ s: EventCardData.RSVP, label: String, systemImage: String, tint: Color) -> some View {
        Button { onSelect(s) } label: {
            VStack(spacing: RuulSpacing.s2) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.s4)
            .ruulGlass(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous), material: .regular, interactive: true)
        }
        .buttonStyle(.ruulPress)
    }

    private var confirmedCard: some View {
        HStack(spacing: RuulSpacing.s3) {
            RuulIconBadge(confirmedIcon, tint: confirmedTint, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(confirmedTitle)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Tap para cambiar")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
        }
        .padding(RuulSpacing.s4)
        .ruulGlass(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous),
            material: .regular,
            tint: confirmedTint.opacity(0.12)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(.notResponded) }
    }

    private var confirmedIcon: String {
        switch state {
        case .going: return "checkmark"
        case .maybe: return "questionmark"
        case .notGoing: return "xmark"
        case .notResponded: return ""
        }
    }

    private var confirmedTint: Color {
        switch state {
        case .going: return .ruulSemanticSuccess
        case .maybe: return .ruulSemanticWarning
        case .notGoing: return .ruulSemanticError
        case .notResponded: return .ruulTextTertiary
        }
    }

    private var confirmedTitle: String {
        switch state {
        case .going: return "Confirmado"
        case .maybe: return "Tal vez voy"
        case .notGoing: return "No voy"
        case .notResponded: return ""
        }
    }
}

#if DEBUG
private struct RSVPStateViewPreview: View {
    @State var state: EventCardData.RSVP = .notResponded

    var body: some View {
        VStack(spacing: RuulSpacing.s5) {
            RSVPStateView(state: state, onSelect: { state = $0 })
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RSVPStateView") {
    RSVPStateViewPreview()
}
#endif
