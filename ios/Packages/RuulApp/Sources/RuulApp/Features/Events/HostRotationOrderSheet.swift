import SwiftUI
import RuulCore

/// F.EVENT.10 — sheet de drag-to-reorder para configurar el orden cíclico
/// del próximo anfitrión. Estilo Apple Reminders / Files: `List` editable
/// con `.onMove(perform:)`. El estado actual se inicializa con
/// `event.hostRotationOrder` cuando existe, o con los miembros del contexto
/// en orden alfabético cuando no.
public struct HostRotationOrderSheet: View {
    let members: [ContextMember]
    let currentOrder: [UUID]?
    let onSave: (_ orderedIds: [UUID]) async -> Void
    let onClear: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [ContextMember] = []
    @State private var isSaving = false
    @State private var isConfirmingClear = false

    public init(
        members: [ContextMember],
        currentOrder: [UUID]?,
        onSave: @escaping ([UUID]) async -> Void,
        onClear: @escaping () async -> Void
    ) {
        self.members = members
        self.currentOrder = currentOrder
        self.onSave = onSave
        self.onClear = onClear
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ordered) { member in
                        HStack(spacing: 12) {
                            ActorInitialsView(name: member.displayName, size: 32)
                            Text(member.displayName)
                                .font(.callout)
                            Spacer()
                        }
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Orden de la rotación")
                } footer: {
                    Text("Mantén presionado y arrastra para reordenar. El primer anfitrión de la lista será el siguiente al cerrar el evento actual.")
                }

                if currentOrder != nil {
                    Section {
                        Button(role: .destructive) {
                            isConfirmingClear = true
                        } label: {
                            Label("Restaurar rotación automática", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("La rotación volverá al orden por antigüedad en el grupo.")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Rotación de host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        Task {
                            isSaving = true
                            await onSave(ordered.map(\.actorId))
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || ordered.isEmpty)
                }
            }
            .onAppear { resetOrdered() }
            .confirmationDialog(
                "¿Restaurar el orden automático?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Restaurar", role: .destructive) {
                    Task {
                        isSaving = true
                        await onClear()
                        isSaving = false
                        dismiss()
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se perderá el orden manual que configuraste. La rotación volverá al orden por antigüedad en el grupo.")
            }
        }
        .ruulSheet()
    }

    private func move(from source: IndexSet, to destination: Int) {
        ordered.move(fromOffsets: source, toOffset: destination)
    }

    private func resetOrdered() {
        if let order = currentOrder {
            // Cargar en el orden actual; agregar al final cualquier miembro
            // nuevo que no esté en el orden persistido.
            let byId = Dictionary(uniqueKeysWithValues: members.map { ($0.actorId, $0) })
            var result: [ContextMember] = []
            var seen: Set<UUID> = []
            for actorId in order {
                if let member = byId[actorId] {
                    result.append(member)
                    seen.insert(actorId)
                }
            }
            for member in members where !seen.contains(member.actorId) {
                result.append(member)
            }
            ordered = result
        } else {
            // Sin orden configurado: arrancar con miembros alfabéticos
            // (similar al orden natural por joined_at en backend).
            ordered = members.sorted { $0.displayName < $1.displayName }
        }
    }
}
