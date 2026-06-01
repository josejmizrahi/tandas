import SwiftUI
import RuulCore

/// Form to record a reputation event (Primitiva 12). Requires
/// `reputation.record` permission server-side. Doctrina: NO score /
/// NO ranking / NO badges — sólo hechos neutrales. La UI sólo captura:
/// sobre quién, qué tipo, opcionalmente por qué, y a quién es visible.
struct RecordReputationEventSheet: View {
    @Bindable var store: ReputationFeedStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.RecordReputation.subjectSection) {
                    if eligibleSubjects.isEmpty {
                        Text("Aún no hay miembros activos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: $store.draftSubjectMembershipId) {
                            Text(L10n.RecordReputation.subjectNone).tag(UUID?.none)
                            ForEach(eligibleSubjects, id: \.id) { item in
                                Text(item.displayName).tag(Optional(item.membershipId!))
                            }
                        } label: {
                            Text(L10n.RecordReputation.subjectSection)
                        }
                    }
                }

                Section(L10n.RecordReputation.kindSection) {
                    Picker(selection: $store.draftKind) {
                        ForEach(ReputationKind.allCases) { kind in
                            Label(kind.label, systemImage: kind.systemImageName).tag(kind)
                        }
                    } label: {
                        Text(L10n.RecordReputation.kindSection)
                    }
                }

                Section(L10n.RecordReputation.reasonSection) {
                    TextField(
                        String(localized: L10n.RecordReputation.reasonPlaceholder),
                        text: $store.draftReason,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                Section(L10n.RecordReputation.visibilitySection) {
                    Picker(selection: $store.draftVisibility) {
                        ForEach(ReputationVisibility.allCases, id: \.self) { vis in
                            Text(vis.label).tag(vis)
                        }
                    } label: {
                        Text(L10n.RecordReputation.visibilitySection)
                    }
                    .pickerStyle(.segmented)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.RecordReputation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.RecordReputation.cancel)) {
                        store.clearError()
                        store.isRecordPresented = false
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            let ok = await store.saveDraft(groupId: groupId)
                            if ok { dismiss() }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.RecordReputation.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
            .task {
                await membersStore.refreshIfNeeded(groupId: groupId)
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var eligibleSubjects: [MembershipBoundaryItem] {
        membersStore.items.filter { item in
            item.isActiveMembership && item.membershipId != nil
        }
    }
}
