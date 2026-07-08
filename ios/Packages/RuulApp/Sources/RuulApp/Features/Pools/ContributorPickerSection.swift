import SwiftUI
import RuulCore

/// R.14.F — sección "A nombre de" para las sheets de aporte a botes.
///
/// Caso founder: el admin/tesorero recibe efectivo de un miembro (o de un
/// placeholder sin app) y registra el aporte a nombre de esa persona. Default:
/// el usuario actual. El backend re-valida (`money.settle` cuando el
/// contribuyente difiere del caller) — la UI solo presenta.
struct ContributorPickerSection: View {
    let context: AppContext
    let container: DependencyContainer
    @Binding var contributorId: UUID?

    @State private var members: [ContextMember] = []

    var body: some View {
        Section {
            if !members.isEmpty {
                Picker("A nombre de", selection: $contributorId) {
                    Text("Tú").tag(UUID?.none)
                    ForEach(members) { member in
                        Text(member.displayName).tag(UUID?.some(member.actorId))
                    }
                }
            }
        } footer: {
            if contributorId != nil {
                Text("Registra el efectivo que recibiste de este miembro como su aporte. En la memoria del grupo queda que tú lo capturaste.")
            }
        }
        .task {
            guard members.isEmpty else { return }
            let myId = container.currentActorStore.actorId
            let summary = try? await container.rpc.contextSummary(contextId: context.id)
            members = (summary?.members ?? []).filter {
                $0.actorId != myId && $0.membershipStatus == "active"
            }
        }
    }
}
