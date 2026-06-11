import SwiftUI
import RuulCore

// MARK: - Personal space content (P0 fix 2026-06-08)
//
// Backend `context_detail_descriptor` raisea "context not found" para
// actores `person` (sólo aplica a contextos colectivos). Renderizamos un
// home personal con drill-downs a las vistas existentes de Profile.

struct ContextDetailV2PersonalSpace: View {
    let context: AppContext
    let container: DependencyContainer
    let attentionItems: [AttentionItem]
    @Binding var presentedAttention: AttentionDestination?
    @Binding var isShowingAllAttention: Bool

    var body: some View {
        List {
            // Hero
            Section {
                HStack(spacing: 14) {
                    Image(systemName: context.symbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Tint.primary)
                        .frame(width: 56, height: 56)
                        .background(Theme.Tint.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mi espacio")
                            .font(.title3.bold())
                            .foregroundStyle(Theme.Text.primary)
                        Text("Tu actividad, recursos y compromisos")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
            }

            // Attention items para el actor personal (filtrados por contextActorId == personal actor).
            let personalAttention = attentionItems
            if !personalAttention.isEmpty {
                Section {
                    ForEach(personalAttention.prefix(3)) { item in
                        Button {
                            presentedAttention = AttentionDispatcher.destination(for: item)
                        } label: {
                            ContextDetailV2AttentionRow(item: item)
                        }
                    }
                    if personalAttention.count > 3 {
                        Button {
                            isShowingAllAttention = true
                        } label: {
                            Label("Ver todos los pendientes (\(personalAttention.count))", systemImage: "list.bullet")
                        }
                    }
                } header: {
                    Text("Atención")
                }
            }

            // Drill-downs a vistas personales.
            Section {
                NavigationLink {
                    MyActivityFeedView(container: container)
                } label: {
                    Label("Mi actividad", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    MyResourcesView(container: container)
                } label: {
                    Label("Mis recursos", systemImage: "shippingbox.fill")
                }
                NavigationLink {
                    MySubscriptionsView(container: container)
                } label: {
                    Label("Mis suscripciones", systemImage: "bookmark.fill")
                }
                NavigationLink {
                    MyTrustNetworkView(container: container)
                } label: {
                    Label("Mi red de confianza", systemImage: "person.line.dotted.person")
                }
            } header: {
                Text("Tus cosas")
            }
        }
        .listStyle(.insetGrouped)
    }
}
