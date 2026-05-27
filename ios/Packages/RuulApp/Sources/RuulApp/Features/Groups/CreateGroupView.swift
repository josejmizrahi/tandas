import SwiftUI
import RuulCore

/// Founder-creates-a-group sheet. Wraps `CanonicalGroupRepository.createGroup`
/// — the `create_group` RPC auto-promotes the caller to founder + grants
/// baseline roles, so a successful return is enough for slice 4a; no
/// follow-up RPC calls.
struct CreateGroupView: View {
    let container: DependencyContainer
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var slug: String = ""
    @State private var category: String = ""
    @State private var purpose: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("¿Cómo se llama?", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Detalles (opcionales)") {
                    TextField("Apodo corto (slug)", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Categoría", text: $category)
                        .textInputAutocapitalization(.sentences)
                    TextField("¿Para qué se junta?", text: $purpose, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Nuevo grupo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Crear")
                        }
                    }
                    .disabled(!isFormValid || isSubmitting)
                }
            }
            .alert(
                error?.title ?? "",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                actions: {
                    Button("OK") { error = nil }
                },
                message: {
                    Text(error?.message ?? "")
                }
            )
        }
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slugClean = slug.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let categoryClean = category.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let purposeClean = purpose.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        do {
            _ = try await container.groupRepository.createGroup(
                name: cleaned,
                slug: slugClean,
                category: categoryClean,
                purposeDeclared: purposeClean
            )
            onCreated()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
