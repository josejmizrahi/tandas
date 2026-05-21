import SwiftUI
import RuulUI
import RuulCore

/// Edit form for a Space resource. Patches `name` / `capacity` /
/// `location` directly via the existing `SpaceLifecycleRepository.
/// updateSpaceMetadata` RPC (admin-only on the server). All other space
/// attributes (description, lat/lng) stay untouched until the larger
/// space-with-bookings surface lands in V1.5.
public struct SpaceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    let resource: ResourceRow
    let onSaved: () -> Void

    @State private var name: String
    @State private var capacityText: String
    @State private var location: String
    @State private var isSubmitting: Bool = false
    @State private var error: String?

    public init(resource: ResourceRow, onSaved: @escaping () -> Void = {}) {
        self.resource = resource
        self.onSaved = onSaved
        _name = State(initialValue: Self.string(resource.metadata["name"]) ?? "")
        _capacityText = State(initialValue: {
            if case let .int(n) = resource.metadata["capacity"] { return String(n) }
            return ""
        }())
        _location = State(initialValue: Self.string(resource.metadata["location"]) ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Espacio") {
                    TextField("Nombre", text: $name)
                    TextField("Capacidad (personas)", text: $capacityText)
                        .keyboardType(.numberPad)
                    TextField("Ubicación", text: $location)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.ruulSemanticError)
                    }
                }
            }
            .navigationTitle("Editar espacio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Guardar").fontWeight(.semibold)
                        }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @MainActor
    private func save() async {
        guard !isSubmitting, canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        var patch: [String: JSONConfig] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces))
        ]
        if let capacity = Int(capacityText.trimmingCharacters(in: .whitespaces)), capacity > 0 {
            patch["capacity"] = .int(capacity)
        }
        let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
        if !trimmedLocation.isEmpty {
            patch["location"] = .string(trimmedLocation)
        }
        do {
            try await app.spaceLifecycleRepo.updateSpaceMetadata(
                space: resource.id,
                patch: .object(patch)
            )
            onSaved()
            dismiss()
        } catch {
            self.error = "No pudimos guardar los cambios. Verifica que tengas permiso para editar este espacio."
        }
    }

    private static func string(_ value: JSONConfig?) -> String? {
        if case let .string(s) = value { return s }
        return nil
    }
}
