import SwiftUI

/// RSVP control — Apple Sports / Luma aesthetic: monochrome surfaces with
/// thin borders, status conveyed via small colored dot + uppercase label,
/// never via saturated tinted backgrounds.
struct EventRSVPStateView: View {
    let status: RSVPStatus
    let event: Event
    let walletAvailable: Bool
    let onChange: (RSVPStatus) -> Void
    let onAddToWallet: () -> Void
    let onShowQR: () -> Void

    var body: some View {
        SwiftUI.Group {
            switch status {
            case .pending:  pendingView
            case .going:    goingView
            case .maybe:    maybeView
            case .declined: declinedView
            }
        }
        .animation(.ruulMorph, value: status)
    }

    // MARK: - Pending — 3 segment-style pills, equal weight, monochrome

    private var pendingView: some View {
        HStack(spacing: RuulSpacing.s2) {
            choicePill(.going,    label: "Voy",     icon: "checkmark", dot: .ruulSemanticSuccess)
            choicePill(.maybe,    label: "Tal vez", icon: "questionmark", dot: .ruulSemanticWarning)
            choicePill(.declined, label: "No voy",  icon: "xmark",    dot: .ruulSemanticError)
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

    // MARK: - Going (confirmed) — flat monochrome card with status header + actions

    private var goingView: some View {
        confirmedCard(
            statusLabel: "VAS",
            statusDot: .ruulSemanticSuccess,
            title: "Confirmado",
            subtitle: arrivalLine
        ) { confirmedActions }
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
            actionButton("Voy", icon: "checkmark", primary: true) { onChange(.going) }
            actionButton("No voy", icon: "xmark", primary: false) { onChange(.declined) }
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

    // MARK: - Confirmed-card scaffold (going + maybe share this layout)

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
