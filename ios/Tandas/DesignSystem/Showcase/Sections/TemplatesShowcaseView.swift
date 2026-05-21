import RuulUI
#if DEBUG
import SwiftUI

struct TemplatesShowcaseView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.md) {
                onboardingTemplateSection
                modalTemplateSection
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground)
    }

    private var onboardingTemplateSection: some View {
        ShowcaseSection("OnboardingScreenTemplate") {
            NavigationStack {
                OnboardingScreenTemplate(
                    progress: 0.6,
                    title: "Demo",
                    subtitle: "Mesh background + step container.",
                    primaryCTA: ("Continuar", false, { })
                ) {
                    Color.ruulSurface.frame(height: 120)
                }
            }
            .frame(height: 460)
        }
    }

    private var modalTemplateSection: some View {
        ShowcaseSection("ModalSheetTemplate", subtitle: "Renders inline as a preview") {
            ModalSheetTemplate(
                title: "Modal",
                dismissAction: { },
                primaryCTA: ("Guardar", { })
            ) {
                RuulTextField("Demo input", text: .constant(""))
            }
            .frame(height: 320)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.extraLarge))
        }
    }
}
#endif
