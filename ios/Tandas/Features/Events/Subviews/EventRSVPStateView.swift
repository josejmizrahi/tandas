import SwiftUI

/// RSVP control — Apple Sports / Luma aesthetic: monochrome surfaces with
/// thin borders, status conveyed via small colored dot + uppercase label,
/// never via saturated tinted backgrounds.
///
/// Handles 5 statuses (pending/going/maybe/declined/waitlisted) plus
/// plus-ones stepper when the event allows extra guests, plus
/// capacity-aware "Voy" pill (auto-becomes "Lista de espera" when at
/// capacity).
struct EventRSVPStateView: View {
    let status: RSVPStatus
    let event: Event
    let walletAvailable: Bool
    let isAtCapacity: Bool
    @Binding var plusOnes: Int
    let onChange: (RSVPStatus) -> Void
    let onAddToWallet: () -> Void
    let onShowQR: () -> Void

    init(
        status: RSVPStatus,
        event: Event,
        walletAvailable: Bool,
        isAtCapacity: Bool = false,
        plusOnes: Binding<Int> = .constant(0),
        onChange: @escaping (RSVPStatus) -> Void,
        onAddToWallet: @escaping () -> Void,
        onShowQR: @escaping () -> Void
    ) {
        self.status = status
        self.event = event
        self.walletAvailable = walletAvailable
        self.isAtCapacity = isAtCapacity
        self._plusOnes = plusOnes
        self.onChange = onChange
        self.onAddToWallet = onAddToWallet
        self.onShowQR = onShowQR
    }

    var body: some View {
        SwiftUI.Group {
            switch status {
            case .pending:    pendingView
            case .going:      goingView
            case .maybe:      maybeView
            case .declined:   declinedView
            case .waitlisted: waitlistedView
            }
        }
        .animation(.ruulMorph, value: status)
    }

    // MARK: - Pending — 3 segment-style pills (capacity-aware) + plus-ones row

    private var pendingView: some View {
        VStack(spacing: RuulSpacing.s3) {
            if event.allowPlusOnes && event.maxPlusOnesPerMember > 0 {
                plusOnesRow
            }
            HStack(spacing: RuulSpacing.s2) {
                if isAtCapacity {
                    choicePill(.going, label: "Lista", icon: "person.crop.circle.badge.clock", dot: .ruulSemanticWarning)
                } else {
                    choicePill(.going, label: "Voy", icon: "checkmark", dot: .ruulSemanticSuccess)
                }
                choicePill(.maybe,    label: "Tal vez", icon: "questionmark", dot: .ruulSemanticWarning)
                choicePill(.declined, label: "No voy",  icon: "xmark",    dot: .ruulSemanticError)
            }
        }
    }

    private func choicePill(_ s: RSVPStatus, label: String, icon: String, dot: Color) -> some View {
        Button { onChange(s) } label: {
            VStack(spacing: RuulSpacing.s1) {
                ZStack {
                    Circle()
                        .stroke(Color.ruulBorderSubtle, lineWidth: 1)
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.s4)
            .background(Color.ruulBackgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: - Plus-ones stepper (inline row, shown when event allows it)

    private var plusOnesRow: some View {
        HStack(spacing: RuulSpacing.s3) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.ruulTextTertiary)
            Text("Llevo a más gente")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            stepperControl
        }
        .padding(.horizontal, RuulSpacing.s4)
        .padding(.vertical, RuulSpacing.s3)
        .background(Color.ruulBackgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    private var stepperControl: some View {
        HStack(spacing: 4) {
            stepperButton(icon: "minus", enabled: plusOnes > 0) {
                if plusOnes > 0 { plusOnes -= 1 }
            }
            Text("+\(plusOnes)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(minWidth: 28)
            stepperButton(icon: "plus", enabled: plusOnes < event.maxPlusOnesPerMember) {
                if plusOnes < event.maxPlusOnesPerMember { plusOnes += 1 }
            }
        }
    }

    private func stepperButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Color.ruulTextPrimary : Color.ruulTextTertiary)
                .frame(width: 26, height: 26)
                .background(Color.ruulBackgroundCanvas)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.ruulPress)
        .disabled(!enabled)
    }

    // MARK: - Going (confirmed) — flat monochrome card

    private var goingView: some View {
        confirmedCard(
            statusLabel: "VAS",
            statusDot: .ruulSemanticSuccess,
            title: plusOnes > 0 ? "Confirmado · +\(plusOnes)" : "Confirmado",
            subtitle: arrivalLine
        ) {
            VStack(spacing: RuulSpacing.s3) {
                if event.allowPlusOnes && event.maxPlusOnesPerMember > 0 {
                    plusOnesRow
                }
                confirmedActions
            }
        }
    }

    @ViewBuilder
    private var confirmedActions: some View {
        HStack(spacing: RuulSpacing.s2) {
            if walletAvailable {
                actionButton("Wallet", icon: "wallet.bifold.fill", primary: true, action: onAddToWallet)
            }
            actionButton("Mi QR", icon: "qrcode", primary: !walletAvailable, action: onShowQR)
            actionButton("Cambiar", icon: "arrow.triangle.2.circlepath", primary: false) {
                onChange(.pending)
            }
        }
    }

    // MARK: - Maybe — same monochrome card pattern, amber dot only

    private var maybeView: some View {
        confirmedCard(
            statusLabel: "TAL VEZ",
            statusDot: .ruulSemanticWarning,
            title: "Por decidir",
            subtitle: "Confirma o cancela cuando puedas"
        ) { maybeActions }
    }

    @ViewBuilder
    private var maybeActions: some View {
        HStack(spacing: RuulSpacing.s2) {
            actionButton(
                isAtCapacity ? "Lista" : "Voy",
                icon: isAtCapacity ? "person.crop.circle.badge.clock" : "checkmark",
                primary: true
            ) { onChange(.going) }
            actionButton("No voy", icon: "xmark", primary: false) { onChange(.declined) }
        }
    }

    // MARK: - Waitlisted — amber dot, neutral card, "remove from list" action

    private var waitlistedView: some View {
        confirmedCard(
            statusLabel: "EN LISTA",
            statusDot: .ruulSemanticWarning,
            title: "En lista de espera",
            subtitle: "Te avisamos si se libera lugar"
        ) {
            actionButton("Quitarme de la lista", icon: "xmark", primary: false) {
                onChange(.declined)
            }
        }
    }

    // MARK: - Declined — slim neutral row, "Cambiar" inline link

    private var declinedView: some View {
        HStack(spacing: RuulSpacing.s3) {
            Circle()
                .fill(Color.ruulSemanticError)
                .frame(width: 8, height: 8)
            Text("NO VAS")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Button { onChange(.pending) } label: {
                Text("Cambiar")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .buttonStyle(.ruulPress)
        }
        .padding(.horizontal, RuulSpacing.s4)
        .padding(.vertical, RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Confirmed-card scaffold (going + maybe + waitlisted share this layout)

    @ViewBuilder
    private func confirmedCard<Actions: View>(
        statusLabel: String,
        statusDot: Color,
        title: String,
        subtitle: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            HStack(spacing: RuulSpacing.s2) {
                Circle()
                    .fill(statusDot)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            actions()
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    private var arrivalLine: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.startsAt) {
            return "Hoy a las \(event.startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(event.startsAt) {
            return "Mañana a las \(event.startsAt.ruulShortTime)"
        }
        return "El \(event.startsAt.ruulWeekday.lowercased()) a las \(event.startsAt.ruulShortTime)"
    }

    // MARK: - Action buttons — pill primary (inverse fill) / pill ghost

    private func actionButton(_ label: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.s1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.s3)
            .foregroundStyle(primary ? Color.ruulTextInverse : Color.ruulTextPrimary)
            .background(
                primary ? Color.ruulTextPrimary : Color.ruulBackgroundCanvas
            )
            .clipShape(Capsule())
            .overlay(
                primary ? nil :
                Capsule().stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }
}
