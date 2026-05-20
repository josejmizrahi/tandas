import SwiftUI
import RuulUI
import RuulCore

// MARK: - LockFundSheet

/// Deep management sheet: lets a founder lock a fund with an optional
/// reason. Opened by the `fundLockSheet` intent in `PostCreateIntentScreen`.
/// Sheet → `fund_lock` RPC (reason is optional metadata).
///
/// Promoted from `MoneySectionView` (Phase F cleanup 2026-05-19).
struct LockFundSheet: View {
    let asset: ResourceRow
    let onLocked: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var reason: String = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Razón (opcional)") {
                    TextField("ej: pausa antes del cierre de mes", text: $reason, axis: .vertical)
                }
                Section {
                    Text("Bloquear el fondo es una marca de política suave: no impide aportar o gastar por sí solo, pero las reglas activas pueden reaccionar (bloquear, requerir aprobación, etc.).")
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .ruulSheetToolbar("Bloquear fondo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bloquear") { Task { await submit() } }
                        .disabled(isSubmitting)
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let trimmed = reason.trimmingCharacters(in: .whitespaces)
        do {
            try await app.fundRepo.lock(
                fundId: asset.id,
                reason: trimmed.isEmpty ? nil : trimmed
            )
            onLocked()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
