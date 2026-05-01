import SwiftUI

/// Real RSVP state view for the event-detail screen. Distinct from the DS
/// `RSVPStateView` stub (which uses `EventCardData.RSVP`); this one uses the
/// real `RSVPStatus` enum + provides QR / Wallet affordances + reason input
/// when changing to .declined.
struct EventRSVPStateView: View {
    let status: RSVPStatus
    let event: Event
    let walletAvailable: Bool
    let onChange: (RSVPStatus) -> Void
    let onAddToWallet: () -> Void
    let onShowQR: () -> Void

    @Namespace private var namespace

    var body: some View {
        Group {
            switch status {
            case .pending:        threeButtonsView
            case .going:          confirmedGoingView
            case .maybe:          confirmedMaybeView
            case .declined:       confirmedDeclinedView
            }
        }
        .animation(.ruulMorph, value: status)
    }

    // MARK: - States

    private var threeButtonsView: some View {
        HStack(spacing: RuulSpacing.s3) {
            stateButton(.going, label: "Voy", icon: "checkmark", tint: .ruulSemanticSuccess)
            stateButton(.maybe, label: "Tal vez", icon: "questionmark", tint: .ruulSemanticWarning)
            stateButton(.declined, label: "No voy", icon: "xmark", tint: .ruulSemanticError)
        }
    }

    private func stateButton(_ s: RSVPStatus, label: String, icon: String, tint: Color) -> some View {
        Button {
            onChange(s)
        } label: {
            VStack(spacing: RuulSpacing.s2) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.s4)
            .ruulGlass(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous),
                material: .regular,
                interactive: true
            )
        }
        .buttonStyle(.ruulPress)
    }

    private var confirmedGoingView: some View {
        RuulCard(.glass, tint: .ruulSemanticSuccess) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                HStack(spacing: RuulSpacing.s3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.ruulSemanticSuccess)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vas \(event.startsAt.ruulRelativeDescription)")
                            .ruulTextStyle(RuulTypography.title)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Listo")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer()
                }
                HStack(spacing: RuulSpacing.s2) {
                    if walletAvailable {
                        RuulButton("Agregar a Wallet", systemImage: "wallet.bifold", style: .primary, size: .medium, fillsWidth: true, action: onAddToWallet)
                    }
                    RuulButton("Ver QR", systemImage: "qrcode", style: .glass, size: .medium, fillsWidth: !walletAvailable, action: onShowQR)
                    if walletAvailable {
                        RuulButton("Cambiar", style: .plain, size: .medium) {
                            onChange(.pending)
                        }
                    } else {
                        RuulButton("Cambiar", style: .plain, size: .medium) {
                            onChange(.pending)
                        }
                    }
                }
            }
        }
    }

    private var confirmedMaybeView: some View {
        RuulCard(.glass, tint: .ruulSemanticWarning) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                HStack(spacing: RuulSpacing.s3) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.ruulSemanticWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Estás considerando")
                            .ruulTextStyle(RuulTypography.title)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Decide cuando puedas")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer()
                }
                HStack(spacing: RuulSpacing.s2) {
                    RuulButton("Confirmar voy", style: .primary, size: .medium, fillsWidth: true) {
                        onChange(.going)
                    }
                    RuulButton("No voy", style: .glass, size: .medium) {
                        onChange(.declined)
                    }
                }
            }
        }
    }

    private var confirmedDeclinedView: some View {
        RuulCard(.glass) {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.ruulSemanticError)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No vas")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Spacer()
                RuulButton("Cambiar", style: .plain, size: .small) {
                    onChange(.pending)
                }
            }
        }
    }
}
