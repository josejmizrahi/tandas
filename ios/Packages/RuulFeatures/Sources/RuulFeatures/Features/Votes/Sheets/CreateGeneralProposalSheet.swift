import SwiftUI
import RuulUI
import RuulCore

/// Sheet para crear una vote de tipo `.generalProposal`. Renderiza el
/// `CreateGeneralProposalCoordinator` con un Form: title, description
/// (opcional) y duración. Botón "Abrir voto" gateado por `canSubmit`.
public struct CreateGeneralProposalSheet: View {
    @Bindable var coordinator: CreateGeneralProposalCoordinator
    public var onCreated: (UUID) -> Void

    public init(coordinator: CreateGeneralProposalCoordinator, onCreated: @escaping (UUID) -> Void) {
        self.coordinator = coordinator
        self.onCreated = onCreated
    }

    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            Form {
                Section("Título") {
                    TextField("¿Qué quieres proponer?", text: $coordinator.title)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Descripción (opcional)") {
                    TextField("Detalles", text: $coordinator.description, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Stepper(value: $coordinator.durationHours, in: 1...168, step: 1) {
                        Text("Cierra en \(coordinator.durationHours)h")
                    }
                } header: {
                    Text("Duración")
                } footer: {
                    Text("La votación cerrará automáticamente.")
                }

                Section {
                    Toggle("Voto anónimo", isOn: $coordinator.isAnonymous)
                } footer: {
                    // Backend (start_vote RPC p_is_anonymous) ya soporta
                    // el modo; el wire del toggle es solo UI.
                    Text(coordinator.isAnonymous
                        ? "Solo se publicarán los conteos. Nadie sabrá quién votó qué."
                        : "El grupo verá quién votó qué — transparencia por defecto.")
                }

                if let error = coordinator.error {
                    Section {
                        Text(error)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .ruulSheetToolbar("Propuesta")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abrir voto") {
                        Task {
                            await coordinator.submit()
                            if let id = coordinator.createdVoteId {
                                dismiss()
                                onCreated(id)
                            }
                        }
                    }
                    .disabled(!coordinator.canSubmit)
                }
            }
        }
    }
}
