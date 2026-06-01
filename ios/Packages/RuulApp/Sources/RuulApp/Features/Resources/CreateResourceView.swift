import SwiftUI
import RuulCore

/// 2-step Create flow.
///   Step 1 (`.type`) — picks one of the 18 canonical resource types.
///                      Renders icon + label + subtitle from the
///                      descriptor.
///   Step 2 (`.details`) — common envelope form (name, description,
///                      visibility, ownership).
/// Member-owner picker still ships in a later slice. `RuulApp` does
/// not expose a custodian field; `create_group_resource` receives NULL
/// from the repository.
struct CreateResourceView: View {
    @Bindable var store: ResourcesStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                switch store.createStep {
                case .type:    typeStep
                case .details: detailsStep
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var navigationTitle: LocalizedStringResource {
        switch store.createStep {
        case .type:    return L10n.Resources.typeStepTitle
        case .details: return L10n.Resources.createTitle
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                store.clearError()
                dismiss()
            } label: {
                Text(L10n.Resources.cancel)
            }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            switch store.createStep {
            case .type:
                Button {
                    store.advanceFromTypePicker()
                } label: {
                    Text(L10n.Resources.typeStepContinue)
                }
            case .details:
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() }
                    else { Text(L10n.Resources.save) }
                }
                .disabled(!store.canSaveDraft || isSaving)
            }
        }
    }

    // MARK: - Step 1: Type picker

    @ViewBuilder
    private var typeStep: some View {
        List {
            Section {
                ForEach(GroupResourceType.displayOrder, id: \.self) { type in
                    typeRow(type)
                }
            } header: {
                Text(L10n.Resources.typeStepTitle)
            }
        }
    }

    @ViewBuilder
    private func typeRow(_ type: GroupResourceType) -> some View {
        let descriptor = type.descriptor
        let isSelected = store.draftType == type
        Button {
            store.draftType = type
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: descriptor.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(descriptor.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Step 2: Common envelope form

    @ViewBuilder
    private var detailsStep: some View {
        Form {
            Section {
                Button {
                    store.returnToTypePicker()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: store.draftType.descriptor.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.draftType.label)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(store.draftType.descriptor.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(L10n.Resources.typeStepBack)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            } header: {
                Text(L10n.Resources.typeLabel)
            }

            Section {
                TextField(
                    String(localized: L10n.Resources.namePlaceholder),
                    text: $store.draftName
                )
                .textInputAutocapitalization(.sentences)
                .submitLabel(.next)
            } header: {
                Text(L10n.Resources.nameLabel)
            }

            Section {
                TextField(
                    String(localized: L10n.Resources.descriptionPlaceholder),
                    text: $store.draftDescription,
                    axis: .vertical
                )
                .lineLimit(2...6)
            } header: {
                Text(L10n.Resources.descriptionLabel)
            }

            Section {
                Picker(selection: $store.draftVisibility) {
                    ForEach(ResourceVisibility.allCases) { v in
                        Text(v.label).tag(v)
                    }
                } label: {
                    Text(L10n.Resources.visibilityLabel)
                }
                .pickerStyle(.menu)

                Picker(selection: $store.draftOwnershipKind) {
                    // Foundation V1 surfaces group + external only.
                    // The member-owner picker (which would unlock
                    // `.member` / `.shared` / `.custodial`) ships in
                    // a later slice. Backend still accepts the others.
                    Text(ResourceOwnershipKind.group.label)
                        .tag(ResourceOwnershipKind.group)
                    Text(ResourceOwnershipKind.external.label)
                        .tag(ResourceOwnershipKind.external)
                } label: {
                    Text(L10n.Resources.ownershipLabel)
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.Resources.visibilityLabel)
            }

            if let message = store.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.createDraft(groupId: groupId)
        if ok { dismiss() }
    }
}
