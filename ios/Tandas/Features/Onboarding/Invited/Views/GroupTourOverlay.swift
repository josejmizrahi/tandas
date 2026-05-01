import SwiftUI

/// Welcome overlay shown after the invited flow completes. Renders a glass
/// card centered on top of whatever main-app view is below; tapping
/// "Entendido" dismisses the overlay (and triggers wallet pass generation
/// if applicable).
struct GroupTourOverlay: View {
    @Environment(InvitedOnboardingCoordinator.self) private var coord
    var walletGen: any WalletPassGenerator
    var onDismiss: () -> Void

    @State private var visible: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(visible ? 0.35 : 0)
                .ignoresSafeArea()
                .animation(.ruulSmooth, value: visible)
                .onTapGesture { /* swallow */ }

            if visible {
                card
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .padding(RuulSpacing.s5)
            }
        }
        .onAppear {
            withAnimation(.ruulMorph) { visible = true }
        }
    }

    private var card: some View {
        RuulCard(.glass) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                Text("Bienvenido a \(coord.preview?.groupName ?? "tu grupo")")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Esto es lo que necesitas saber:")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                bulletList
                RuulButton("Entendido", style: .primary, size: .large, fillsWidth: true) {
                    Task { await dismiss() }
                }
                .padding(.top, RuulSpacing.s2)
            }
        }
        .ruulElevation(.lg)
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            bullet(icon: "calendar", text: nextEventCopy)
            bullet(icon: "list.bullet.clipboard", text: "Las reglas del grupo viven aquí. Léelas cuando puedas.")
            bullet(icon: "shield.checkered", text: "Tienes período de gracia: las primeras 3 \(coord.preview?.eventLabel ?? "reuniones") no aplican multas.")
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.s3) {
            RuulIconBadge(icon, size: .small)
            Text(text)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nextEventCopy: String {
        // V1 doesn't have event data threaded through onboarding. Generic copy.
        "Cuando haya un próximo evento, te aviso aquí."
    }

    @MainActor
    private func dismiss() async {
        // Wallet pass stub — V1 returns nil, no-op.
        // Future: if let url = await walletGen.createPass(for: ...), present
        // PKAddPassesViewController via a UIViewControllerRepresentable.
        await coord.finishOnboarding()
        withAnimation(.ruulSmooth) { visible = false }
        try? await Task.sleep(for: .milliseconds(220))
        onDismiss()
    }
}
