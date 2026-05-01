import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let group: Group

    @State private var members: [Member] = []
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(spacing: Brand.Spacing.xl) {
                    hero
                    WelcomeStepCard(title: "Período de gracia", symbol: "shield.checkered") {
                        Text("Tus primeros días no generan multas. Aprende cómo funciona el grupo sin presión.")
                            .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                    }
                    WelcomeStepCard(title: "Las reglas del grupo", symbol: "list.bullet.clipboard") {
                        Text("Las reglas y multas las decide el grupo y se votan. Para ver y proponer cambios, ve a la pestaña de Reglas (próximamente).")
                            .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                    }
                    WelcomeStepCard(title: "Quiénes están", symbol: "person.3") {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else if members.isEmpty {
                            Text("Eres la primera persona del grupo.")
                                .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                        } else {
                            Text("\(members.count) miembros activos.")
                                .font(.tandaBody).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    GlassCapsuleButton("Entrar al grupo") { dismiss() }
                }
                .padding(.horizontal, Brand.Spacing.xl)
                .padding(.top, Brand.Spacing.xxl)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await loadMembers() }
    }

    private var hero: some View {
        VStack(spacing: Brand.Spacing.s) {
            Text("Bienvenido a")
                .font(.tandaTitle).foregroundStyle(.white.opacity(0.7))
            Text(group.name)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(group.groupType.displayName)
                .font(.tandaCaption).foregroundStyle(.white.opacity(0.65))
        }
    }

    private func loadMembers() async {
        defer { isLoading = false }
        members = (try? await app.groupsRepo.members(of: group.id)) ?? []
    }
}
