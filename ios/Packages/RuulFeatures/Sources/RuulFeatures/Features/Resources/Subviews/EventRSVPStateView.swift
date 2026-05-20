import SwiftUI
import RuulUI
import RuulCore

/// RSVP control — Apple Sports / Luma aesthetic: monochrome surfaces with
/// thin borders, status conveyed via small colored dot + uppercase label,
/// never via saturated tinted backgrounds.
///
/// Handles 5 statuses (pending/going/maybe/declined/waitlisted) plus
/// plus-ones stepper when the event allows extra guests, plus
/// capacity-aware "Voy" pill (auto-becomes "Lista de espera" when at
/// capacity).
public struct EventRSVPStateView: View {
    public let status: RSVPStatus
    public let event: Event
    public let walletAvailable: Bool
    public let isAtCapacity: Bool
    @Binding var plusOnes: Int
    public let onChange: (RSVPStatus) -> Void
    public let onAddToWallet: () -> Void
    public let onShowQR: () -> Void

    public init(
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

    public var body: some View {
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
        VStack(spacing: RuulSpacing.sm) {
            if event.allowPlusOnes && event.maxPlusOnesPerMember > 0 {
                plusOnesRow
            }
            HStack(spacing: RuulSpacing.xs) {
                if isAtCapacity {
                    choicePill(.going, label: "Lista", icon: "person.crop.circle.badge.clock", dot: .ruulWarning)
                } else {
                    choicePill(.going, label: "Voy", icon: "checkmark", dot: .ruulPositive)
                }
                choicePill(.maybe,    label: "Tal vez", icon: "questionmark", dot: .ruulWarning)
                choicePill(.declined, label: "No voy",  icon: "xmark",    dot: .ruulNegative)
            }
        }
    }

    private func choicePill(_ s: RSVPStatus, label: String, icon: String, dot: Color) -> some View {
        Button { onChange(s) } label: {
            VStack(spacing: RuulSpacing.xxs) {
                ZStack {
                    Circle()
                        .stroke(Color.ruulSeparator, lineWidth: 1)
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.ruulTextPrimary)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.md)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: - Plus-ones stepper (inline row, shown when event allows it)

    private var plusOnesRow: some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "person.2.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
            Text("Llevo a más gente")
                .font(.footnote)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            stepperControl
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private var stepperControl: some View {
        HStack(spacing: 4) {
            stepperButton(icon: "minus", enabled: plusOnes > 0) {
                if plusOnes > 0 { plusOnes -= 1 }
            }
            Text("+\(plusOnes)")
                .font(.footnote.monospacedDigit().weight(.bold))
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
                .font(.caption.weight(.bold))
                .foregroundStyle(enabled ? Color.ruulTextPrimary : Color.ruulTextTertiary)
                .frame(width: 26, height: 26)
                .background(Color.ruulBackground)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.ruulSeparator, lineWidth: 0.5))
                .accessibilityHidden(true)
        }
        .buttonStyle(.ruulPress)
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "Agregar invitado" : "Quitar invitado")
    }

    // MARK: - Going (confirmed) — flat monochrome card

    private var goingView: some View {
        confirmedCard(
            statusLabel: "VAS",
            statusDot: .ruulPositive,
            title: plusOnes > 0 ? "Confirmado · +\(plusOnes)" : "Confirmado",
            subtitle: arrivalLine
        ) {
            VStack(spacing: RuulSpacing.sm) {
                if event.allowPlusOnes && event.maxPlusOnesPerMember > 0 {
                    plusOnesRow
                }
                confirmedActions
            }
        }
    }

    @ViewBuilder
    private var confirmedActions: some View {
        HStack(spacing: RuulSpacing.xs) {
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
            statusDot: .ruulWarning,
            title: "Por decidir",
            subtitle: "Confirma o cancela cuando puedas"
        ) { maybeActions }
    }

    @ViewBuilder
    private var maybeActions: some View {
        HStack(spacing: RuulSpacing.xs) {
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
            statusDot: .ruulWarning,
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
        HStack(spacing: RuulSpacing.sm) {
            Circle()
                .fill(Color.ruulNegative)
                .frame(width: 8, height: 8)
            Text("NO VAS")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Button { onChange(.pending) } label: {
                Text("Cambiar")
                    .font(.footnote)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .buttonStyle(.ruulPress)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.md)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
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
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(spacing: RuulSpacing.xs) {
                Circle()
                    .fill(statusDot)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            actions()
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
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
            HStack(spacing: RuulSpacing.xxs) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
                Text(label)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.sm)
            .foregroundStyle(primary ? Color.ruulTextInverse : Color.ruulTextPrimary)
            .background(
                primary ? Color.ruulTextPrimary : Color.ruulBackground
            )
            .clipShape(Capsule())
            .overlay(
                primary ? nil :
                Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }
}
