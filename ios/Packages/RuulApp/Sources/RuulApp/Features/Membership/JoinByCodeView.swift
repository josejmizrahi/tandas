import SwiftUI
import RuulCore

/// F.5 — unirse a un contexto con un código de invitación.
public struct JoinByCodeView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var runner = ActionRunner()
    @State private var joinedContextName: String?
    /// 7.C.3 (audit 2026-06-14) — copy específico cuando el backend
    /// devuelve un error conocido (código inválido, ya miembro, etc.)
    /// en lugar del `.actionErrorAlert(runner)` genérico.
    @State private var joinErrorMessage: String?

    public init(container: DependencyContainer, prefilledCode: String? = nil) {
        self.container = container
        _code = State(initialValue: prefilledCode ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Código de invitación", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                        .multilineTextAlignment(.center)
                } footer: {
                    Text("Pídele el código a quien administra el grupo.")
                }

                Section {
                    Button {
                        Task { await join() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Unirme").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }

                if let joinedContextName {
                    Section {
                        Label("Te uniste a \(joinedContextName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let joinErrorMessage {
                    Section {
                        Label(joinErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
            }
            .navigationTitle("Unirme con código")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func join() async {
        joinErrorMessage = nil
        do {
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let result = try await container.rpc.joinByInviteCode(trimmed)
            joinedContextName = result.context.displayName
            await container.contextStore.load()
            if let new = container.contextStore.availableContexts.first(where: { $0.id == result.contextActorId }) {
                container.contextStore.switchTo(new)
            }
            // 7.C.3 — antes había Task.sleep(1s) ciego antes del dismiss para
            // mostrar el toast. Con el switchTo arriba, el contexto ya es el
            // activo — dismiss inmediato lleva al usuario directo al espacio
            // recién unido, no a un toast y luego a la lista vacía.
            dismiss()
        } catch {
            joinErrorMessage = joinErrorCopy(for: error)
        }
    }

    /// 7.C.3 (audit 2026-06-14) — copy específico por tipo de error en lugar
    /// de "Algo salió mal" genérico. Captura los códigos que el backend
    /// devuelve en join_by_invite_code (RLS, expired, ya miembro).
    private func joinErrorCopy(for error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("expired") {
            return "Este código ya expiró. Pídele a quien lo compartió uno nuevo."
        }
        if raw.contains("invalid") || raw.contains("not found") || raw.contains("no rows") {
            return "Código incorrecto. Revisa que esté bien escrito o pídele uno nuevo."
        }
        if raw.contains("already") || raw.contains("duplicate") {
            return "Ya eres miembro de este grupo. Búscalo en Ajustes > Grupo."
        }
        if raw.contains("revoked") {
            return "Este código fue cancelado por el administrador. Pide uno nuevo."
        }
        if raw.contains("archived") || raw.contains("closed") {
            return "Este grupo ya no está activo."
        }
        if raw.contains("network") || raw.contains("internet") {
            return "Sin conexión. Revisa tu red e intenta de nuevo."
        }
        return "No pudimos validar el código. Intenta de nuevo en unos segundos."
    }
}

#Preview("Unirme con código") {
    JoinByCodeView(container: .demo())
}
