import SwiftUI

/// State-driven RSVP control. Distinct from the DS `RSVPStateView` stub —
/// this one uses the real `RSVPStatus` enum, gives a dominant primary
/// "Voy" affordance (Luma pattern), and transforms into a confirmed card
/// with QR / Wallet access once responded.
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

    // MARK: - Pending — primary "Voy" + 2 secondary affordances (Luma style)

    private var pendingView: some View {
        VStack(spacing: RuulSpacing.s3) {
            primaryGoingButton
            HStack(spacing: RuulSpacing.s3) {
                secondaryButton(.maybe, label: "Tal vez", icon: "questionmark", tint: .ruulSemanticWarning)
                secondaryButton(.declined, label: "No voy", icon: "xmark", tint: .ruulTextSecondary)
            }
        }
    }

    private var primaryGoingButton: some View {
        Button { onChange(.going) } label: {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                Text("Voy")
                    .ruulTextStyle(RuulTypography.title)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(Color.ruulTextInverse)
            .padding(.vertical, RuulSpacing.s5)
            .padding(.horizontal, RuulSpacing.s5)
            .frame(maxWidth: .infinity)
            .background(
                Color.ruulSemanticSuccess,
                in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
            )
        }
        .buttonStyle(.ruulPress)
    }

    private func secondaryButton(_ s: RSVPStatus, label: String, icon: String, tint: Color) -> some View {
        Button { onChange(s) } label: {
            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.s4)
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: - Going (confirmed) — celebratory card

    private var goingView: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            HStack(spacing: RuulSpacing.s3) {
                ZStack {
                    Circle()
                        .fill(Color.ruulSemanticSuccess.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.ruulSemanticSuccess)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vas")
                        .ruulTextStyle(RuulTypography.titleLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(arrivalLine)
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
            }

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
        .padding(RuulSpacing.s5)
        .background(
            Color.ruulSemanticSuccess.opacity(0.08),
            in: RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous)
                .stroke(Color.ruulSemanticSuccess.opacity(0.25), lineWidth: 1)
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

    // MARK: - Maybe — amber tinted with confirm/decline shortcuts

    private var maybeView: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            HStack(spacing: RuulSpacing.s3) {
                ZStack {
                    Circle()
                        .fill(Color.ruulSemanticWarning.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "questionmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.ruulSemanticWarning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tal vez")
                        .ruulTextStyle(RuulTypography.titleLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Decide cuando puedas")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
            }
            HStack(spacing: RuulSpacing.s2) {
                Button { onChange(.going) } label: {
                    Text("Confirmar voy")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.s3)
                        .background(Color.ruulSemanticSuccess, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                }
                .buttonStyle(.ruulPress)
                Button { onChange(.declined) } label: {
                    Text("No voy")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.s3)
                        .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                }
                .buttonStyle(.ruulPress)
            }
        }
        .padding(RuulSpacing.s5)
        .background(
            Color.ruulSemanticWarning.opacity(0.08),
            in: RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous)
                .stroke(Color.ruulSemanticWarning.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Declined — neutral, low-key

    private var declinedView: some View {
        HStack(spacing: RuulSpacing.s3) {
            ZStack {
                Circle()
                    .fill(Color.ruulBackgroundRecessed)
                    .frame(width: 36, height: 36)
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Text("No vas")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Button { onChange(.pending) } label: {
                Text("Cambiar")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulAccentPrimary)
                    .padding(.horizontal, RuulSpacing.s3)
                    .padding(.vertical, RuulSpacing.s2)
                    .background(Color.ruulAccentSubtle, in: Capsule())
            }
            .buttonStyle(.ruulPress)
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Action buttons (going state)

    private func actionButton(_ label: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(primary ? Color.ruulTextInverse : Color.ruulTextPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.s3)
            .background(
                primary
                    ? AnyShapeStyle(Color.ruulSemanticSuccess)
                    : AnyShapeStyle(Color.ruulBackgroundElevated),
                in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
            )
            .overlay(
                primary ? nil :
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }
}
