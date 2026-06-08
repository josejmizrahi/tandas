import SwiftUI
import RuulCore

/// F.EVENT.8 — picker para definir el próximo anfitrión cuando el evento es
/// recurrente. Muestra los miembros activos del contexto (excluyendo al host
/// actual) y resalta el actualmente apuntado.
public struct NextHostPickerSheet: View {
    let members: [ContextMember]
    let currentNextHostId: UUID?
    let onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        members: [ContextMember],
        currentNextHostId: UUID?,
        onPick: @escaping (UUID) -> Void
    ) {
        self.members = members
        self.currentNextHostId = currentNextHostId
        self.onPick = onPick
    }

    public var body: some View {
        NavigationStack {
            List {
                if members.isEmpty {
                    Text("No hay otros miembros disponibles para tomar el siguiente turno.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members) { member in
                        Button {
                            onPick(member.actorId)
                            dismiss()
                        } label: {
                            HStack {
                                ActorInitialsView(name: member.displayName, size: 36)
                                Text(member.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if member.actorId == currentNextHostId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Próximo anfitrión")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .ruulCompactSheet()
    }
}
