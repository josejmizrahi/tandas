import SwiftUI
import RuulCore

/// Generic descriptor-driven editor for the envelope's `metadata`
/// jsonb. Renders one input per `MetadataField` (string / multiline /
/// integer / decimal / date / boolean / url). Hidden for resource
/// types whose descriptor has an empty `metadataSchema`.
struct EditMetadataSheet: View {
    @Bindable var store: ResourcesStore
    let resource: GroupResource
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    private var descriptor: ResourceTypeDescriptor {
        resource.resourceType.descriptor
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.EditMetadata.fieldsSection) {
                    ForEach(descriptor.metadataSchema) { field in
                        fieldEditor(field)
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.EditMetadata.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.EditMetadata.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.EditMetadata.save) }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    @ViewBuilder
    private func fieldEditor(_ field: MetadataField) -> some View {
        switch field.kind {
        case .string, .url:
            LabeledContent {
                TextField("", text: textBinding(for: field.key))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled(field.kind == .url)
                    .textInputAutocapitalization(field.kind == .url ? .never : .sentences)
            } label: {
                Text(field.label)
            }
        case .multilineString:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("", text: textBinding(for: field.key), axis: .vertical)
                    .lineLimit(2...6)
            }
        case .integer, .decimal:
            LabeledContent {
                TextField("", text: textBinding(for: field.key))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(field.kind == .integer ? .numberPad : .decimalPad)
            } label: {
                Text(field.label)
            }
        case .boolean:
            Toggle(isOn: boolBinding(for: field.key)) {
                Text(field.label)
            }
        case .date:
            DatePicker(
                selection: dateBinding(for: field.key),
                displayedComponents: [.date]
            ) {
                Text(field.label)
            }
        }
    }

    private func textBinding(for key: String) -> Binding<String> {
        Binding(
            get: { store.metadataDraftStrings[key] ?? "" },
            set: { store.metadataDraftStrings[key] = $0 }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { store.metadataDraftBools[key] ?? false },
            set: { store.metadataDraftBools[key] = $0 }
        )
    }

    private func dateBinding(for key: String) -> Binding<Date> {
        Binding(
            get: { store.metadataDraftDates[key] ?? Date() },
            set: { store.metadataDraftDates[key] = $0 }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveEditMetadata(resource: resource, groupId: groupId)
        if ok { dismiss() }
    }
}
