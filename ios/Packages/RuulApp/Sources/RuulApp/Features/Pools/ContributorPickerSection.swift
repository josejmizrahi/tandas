import SwiftUI
import RuulCore

/// R.14.F — sección "A nombre de" para las sheets de aporte a botes.
///
/// Caso founder: el admin/tesorero recibe efectivo de un miembro (o de un
/// placeholder sin app) y registra el aporte a nombre de esa persona. Default:
/// el usuario actual. El backend re-valida (`money.settle` cuando el
/// contribuyente difiere del caller) — la UI solo presenta.
///
/// R.18 (founder 2026-07-10: "solo me sale la cantidad y el botón, no veo cómo
/// hacerle") — el picker era un row sin encabezado, fácil de no ver. Ahora:
/// header + footer explícitos, control visible siempre (menú explícito), y
/// carga robusta con retry. Incluye placeholders (el caso exacto: alguien sin
/// app que te dio efectivo).
struct ContributorPickerSection: View {
    let context: AppContext
    let container: DependencyContainer
    @Binding var contributorId: UUID?

    @State private var members: [ContextMember] = []
    @State private var didLoad = false

    private var selectedName: String {
        guard let contributorId,
              let m = members.first(where: { $0.actorId == contributorId })
        else { return "Tú" }
        return m.displayName
    }

    var body: some View {
        Section {
            Menu {
                Button {
                    contributorId = nil
                } label: {
                    Label("Tú (yo lo pagué)", systemImage: contributorId == nil ? "checkmark" : "person.fill")
                }
                if !members.isEmpty {
                    Divider()
                    ForEach(members) { member in
                        Button {
                            contributorId = member.actorId
                        } label: {
                            Label(
                                member.isPlaceholder ? "\(member.displayName) (sin app)" : member.displayName,
                                systemImage: contributorId == member.actorId ? "checkmark" : "person"
                            )
                        }
                    }
                }
            } label: {
                HStack {
                    Label("A nombre de", systemImage: "person.2.fill")
                        .foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Text(selectedName)
                        .foregroundStyle(Theme.Text.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        } header: {
            Text("¿De quién es el aporte?")
        } footer: {
            if didLoad && members.isEmpty {
                Text("Aún no hay otros miembros a quienes atribuir el aporte.")
            } else if contributorId != nil {
                Text("Registras el efectivo que recibiste de este miembro como su aporte. En la memoria del grupo queda que tú lo capturaste.")
            } else {
                Text("Por defecto el aporte es tuyo. Si recibiste efectivo de otro miembro, elígelo aquí (requiere que seas tesorero/admin).")
            }
        }
        .task {
            guard members.isEmpty else { return }
            await load()
        }
    }

    private func load() async {
        let myId = container.currentActorStore.actorId
        let summary = try? await container.rpc.contextSummary(contextId: context.id)
        members = (summary?.members ?? [])
            .filter { $0.actorId != myId && $0.membershipStatus == "active" }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        didLoad = true
    }
}
