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
            // R.11.J — Hero canonical (RuulDetailHero) consistente con
            // ContextsListView Mi espacio (R.11.F) y el resto de Detail Views.
            Section {
                RuulDetailHero(
                    title: "Mi espacio",
                    subtitle: "Tu actividad, recursos y compromisos",
                    systemImage: context.symbolName,
                    tint: Theme.Tint.primary,
                    status: nil,
                    chips: []
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
