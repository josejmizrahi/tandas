import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let group: Group

    @State private var members: [Member] = []
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            Brand.Surface.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.Layout.sectionGap) {
                    hero
                    stepCard(
                        symbol: "shield.checkered",
                        title: "Período de gracia",
                        body: "Tus primeros días no generan multas. Aprende cómo funciona el grupo sin presión."
                    )
                    stepCard(
                        symbol: "list.bullet.clipboard",
                        title: "Las reglas del grupo",
                        body: "Las reglas y multas las decide el grupo y se votan. Para ver y proponer cambios, ve a la pestaña de Reglas."
                    )
                    stepCard(
                        symbol: "person.3",
                        title: "Quiénes están",
                        body: membersCopy
                    )
                    Button {
                        dismiss()
                    } label: {
                        Text("Entrar al grupo")
                            .frame(maxWidth: .infinity)
                            .lumaPrimaryPill()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Brand.Layout.pagePadH)
                .padding(.top, 24)
                .padding(.bottom, Brand.Layout.pageBottomPad)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await loadMembers() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.groupType.displayName.uppercased())
                .font(Brand.Typography.rowKicker)
                .tracking(0.5)
                .foregroundStyle(Brand.Surface.textSecondary)
            Text("Bienvenido a")
                .font(Brand.Typography.bodyEmphasis)
                .foregroundStyle(Brand.Surface.textSecondary)
            Text(group.name)
                .font(Brand.Typography.heroTitle)
                .foregroundStyle(Brand.Surface.textPrimary)
        }
    }

    private var membersCopy: String {
        if isLoading { return "Cargando miembros…" }
        if members.isEmpty { return "Eres la primera persona del grupo." }
        return "\(members.count) miembros activos."
    }

    private func stepCard(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Brand.Layout.rowSpacing) {
            RoundedRectangle(cornerRadius: Brand.Layout.cardSmallRadius, style: .continuous)
                .fill(Brand.Surface.card)
                .frame(width: Brand.Layout.cardSmallSize, height: Brand.Layout.cardSmallSize)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Brand.Surface.textPrimary)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Brand.Typography.rowTitle)
                    .foregroundStyle(Brand.Surface.textPrimary)
                Text(body)
                    .font(Brand.Typography.caption)
                    .foregroundStyle(Brand.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func loadMembers() async {
        defer { isLoading = false }
        members = (try? await app.groupsRepo.members(of: group.id)) ?? []
    }
}
