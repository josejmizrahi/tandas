import SwiftUI
import RuulUI
import RuulCore

/// Welcome overlay shown after the invited flow completes. Renders a glass
/// card centered on top of whatever main-app view is below; tapping
/// "Entendido" dismisses the overlay (and triggers wallet pass generation
/// if applicable).
public struct GroupTourOverlay: View {
    @Environment(InvitedOnboardingCoordinator.self) private var coord
    public var walletGen: any WalletPassGenerator
    public var onDismiss: () -> Void

    public init(walletGen: any WalletPassGenerator, onDismiss: @escaping () -> Void) {
        self.walletGen = walletGen
        self.onDismiss = onDismiss
    }

    @State private var visible: Bool = false

    public var body: some View {
        ZStack {
            (visible ? Color.ruulOverlayDim : Color.clear)
                .ignoresSafeArea()
                .animation(.smooth, value: visible)
                .onTapGesture { /* swallow */ }

            if visible {
                card
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .padding(RuulSpacing.lg)
            }
        }
        .onAppear {
            withAnimation(.smooth) { visible = true }
        }
    }

    private var card: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                Text("Bienvenido a \(coord.preview?.groupName ?? "tu grupo")")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text("Esto es lo que necesitas saber:")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                bulletList
                RuulButton("Entendido", style: .primary, size: .large, fillsWidth: true) {
                    Task { await dismiss() }
                }
                .padding(.top, RuulSpacing.xs)
            }
        }
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            bullet(icon: "calendar", text: nextEventCopy)
            bullet(icon: "list.bullet.clipboard", text: "Las reglas del grupo viven aquí. Léelas cuando puedas.")
            bullet(icon: "shield.checkered", text: "Tienes período de gracia: las primeras 3 reuniones no aplican multas.")
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            RuulIconBadge(icon, size: .small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
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
        withAnimation(.smooth) { visible = false }
        try? await Task.sleep(for: .milliseconds(220))
        onDismiss()
    }
}
