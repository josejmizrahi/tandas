import SwiftUI

struct EmptyGroupsView: View {
    @State private var showCreate: Bool = false
    @State private var showJoin: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                MeshBackground()
                ScrollView {
                    VStack(spacing: Brand.Spacing.xl) {
                        Spacer().frame(height: Brand.Spacing.xxl * 2)
                        VStack(spacing: Brand.Spacing.m) {
                            Text("Aún no tienes grupos")
                                .font(.tandaHero).foregroundStyle(.white)
                            Text("Crea uno o únete con un código de invitación.")
                                .font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        VStack(spacing: Brand.Spacing.m) {
                            cardButton(
                                title: "Crear un grupo",
                                copy: "Cena recurrente, tanda de ahorro, equipo deportivo…",
                                symbol: "plus.circle"
                            ) { showCreate = true }
                            cardButton(
                                title: "Unirme con código",
                                copy: "Si alguien ya creó tu grupo, pídele el código.",
                                symbol: "ticket"
                            ) { showJoin = true }
                        }
                    }
                    .padding(.horizontal, Brand.Spacing.xl)
                }
            }
            .navigationDestination(isPresented: $showCreate) { NewGroupWizard() }
            .navigationDestination(isPresented: $showJoin) { JoinByCodeView() }
        }
    }

    private func cardButton(title: String, copy: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Brand.Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.tandaTitle).foregroundStyle(.white)
                    Text(copy).font(.tandaCaption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Brand.Spacing.l)
            .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.card), interactive: true)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: showCreate || showJoin)
    }
}

