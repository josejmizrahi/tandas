#if DEBUG
import SwiftUI

struct TemplatesShowcaseView: View {
    enum DemoTab: Hashable, Sendable { case a, b, c }
    enum ResourceDemoTab: Hashable, Sendable { case home, inbox, rules, me }
    @State private var demoTab: DemoTab = .a
    @State private var resourceTab: ResourceDemoTab = .home

    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.s4) {
                onboardingTemplateSection
                mainAppTemplateSection
                resourceTabBarSection
                detailTemplateSection
                modalTemplateSection
            }
            .padding(RuulSpacing.s5)
        }
        .background(Color.ruulBackgroundCanvas)
    }

    private var onboardingTemplateSection: some View {
        ShowcaseSection("OnboardingScreenTemplate") {
            NavigationStack {
                OnboardingScreenTemplate(
                    mesh: .violet,
                    progress: 0.6,
                    stepCount: 5,
                    title: "Demo",
                    subtitle: "Mesh background + step container.",
                    primaryCTA: ("Continuar", false, { })
                ) {
                    Color.ruulBackgroundElevated.frame(height: 120)
                }
            }
            .frame(height: 460)
        }
    }

    private var mainAppTemplateSection: some View {
        ShowcaseSection("MainAppScreenTemplate") {
            MainAppScreenTemplate(
                tabs: [
                    .init(id: DemoTab.a, label: "A", systemImage: "1.circle"),
                    .init(id: DemoTab.b, label: "B", systemImage: "2.circle"),
                    .init(id: DemoTab.c, label: "C", systemImage: "3.circle")
                ],
                selection: $demoTab
            ) { tab in
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    Text("Tab \(String(describing: tab))").ruulTextStyle(RuulTypography.title)
                }
            }
            .frame(height: 360)
        }
    }

    private var resourceTabBarSection: some View {
        ShowcaseSection("ResourceTabBar", subtitle: "MainApp + per-tab badge support (used by templates that need an Inbox count)") {
            ResourceTabBar(
                tabs: [
                    .init(id: ResourceDemoTab.home,  label: "Inicio", systemImage: "house.fill"),
                    .init(id: ResourceDemoTab.inbox, label: "Inbox",  systemImage: "tray.fill", badge: .count(3)),
                    .init(id: ResourceDemoTab.rules, label: "Reglas", systemImage: "list.bullet.clipboard.fill"),
                    .init(id: ResourceDemoTab.me,    label: "Yo",     systemImage: "person.crop.circle.fill")
                ],
                selection: $resourceTab
            ) { tab in
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    Text("\(String(describing: tab))").ruulTextStyle(RuulTypography.title)
                }
            }
            .frame(height: 360)
        }
    }

    private var detailTemplateSection: some View {
        ShowcaseSection("DetailScreenTemplate") {
            NavigationStack {
                DetailScreenTemplate(
                    title: "Detalle",
                    primaryCTA: ("Confirmar", { }),
                    secondaryCTA: ("Editar", { })
                ) {
                    ForEach(0..<3, id: \.self) { i in
                        RuulCard(.glass) { Text("Card \(i)").ruulTextStyle(RuulTypography.body) }
                    }
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
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.xl))
        }
    }
}
#endif
