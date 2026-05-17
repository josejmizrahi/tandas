import SwiftUI
import PhotosUI
import RuulUI
import RuulCore

/// Full-screen cover for renaming a group, editing its description, and
/// changing its avatar. All three writes are independent: name/description
/// go through `updateConfig`, avatar through `updateAvatar`. Wire-up from
/// `GroupHomeView` lands in Task 10.
@MainActor
public struct EditGroupIdentitySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var saving = false
    @State private var error: String?

    public init(groupId: UUID) { self.groupId = groupId }

    private var current: RuulCore.Group? {
        app.groups.first(where: { $0.id == groupId })
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Nombre del grupo", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Descripción") {
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Foto") {
                    PhotosPicker(
                        selection: $avatarItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        HStack {
                            RuulAvatar(
                                name: name.isEmpty ? "?" : name,
                                imageURL: current?.avatarUrl.flatMap(URL.init(string:)),
                                size: .medium
                            )
                            Text(avatarItem == nil ? "Cambiar foto" : "Foto seleccionada")
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .ruulSheetToolbar("Editar grupo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let g = current {
                    name = g.name
                    description = g.description ?? ""
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
            let patch = GroupConfigPatch(
                name: trimmedName != current?.name ? trimmedName : nil,
                description: trimmedDesc != (current?.description ?? "") ? trimmedDesc : nil
            )
            if patch.name != nil || patch.description != nil {
                _ = try await app.groupsRepo.updateConfig(groupId: groupId, patch: patch)
            }
            if let item = avatarItem,
               let data = try await item.loadTransferable(type: Data.self) {
                _ = try await app.groupsRepo.updateAvatar(
                    groupId: groupId,
                    data: data,
                    contentType: "image/jpeg"
                )
            }
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos guardar los cambios."
        }
    }
}
