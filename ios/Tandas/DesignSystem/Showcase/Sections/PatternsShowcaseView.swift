import RuulUI
import RuulCore
#if DEBUG
import SwiftUI

struct PatternsShowcaseView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.md) {
                emptyStateSection
                loadingStateSection
                errorStateSection
                onboardingSection
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground)
    }

    private var emptyStateSection: some View {
        ShowcaseSection("ContentUnavailableView (empty)") {
            ContentUnavailableView {
                Label("Aún no hay miembros", systemImage: "person.2")
            } description: {
                Text("Comparte el código del grupo.")
            } actions: {
                Button("Compartir") { }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var loadingStateSection: some View {
        ShowcaseSection("RuulLoadingState") {
            VStack(spacing: RuulSpacing.md) {
                RuulLoadingState()
                    .frame(height: 120)
                RuulLoadingState(message: "Cargando…")
                    .frame(height: 120)
            }
        }
    }

    private var errorStateSection: some View {
        ShowcaseSection("ContentUnavailableView (error)") {
            ContentUnavailableView {
                Label("Error de red", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Verifica tu conexión.")
            } actions: {
                Button("Reintentar") { }
            }
        }
    }

    private var onboardingSection: some View {
        ShowcaseSection("OnboardingStepContainer") {
            OnboardingStepContainer(
                progress: 0.4,
                title: "Pregunta",
                subtitle: "Subtítulo",
                primaryCTA: ("Continuar", false, { })
            ) {
                RuulTextField("Demo", text: .constant(""))
            }
            .frame(height: 460)
        }
    }
}
#endif
