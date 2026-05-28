import SwiftUI
import RuulCore

/// Compact `.medium` detent sheet for casting (or changing) a vote on
/// an open decision. Drives `cast_vote(...)` via the store. Surfaces
/// the option picker only when the decision has explicit options.
public struct VoteSheet: View {
    @Bindable var store: DecisionsStore
    let groupId: UUID

    @State private var isSaving: Bool = false

    public init(store: DecisionsStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            Form {
                valueSection
                if let detail = store.detail, detail.id == store.voteDraftDecisionId, !detail.options.isEmpty {
                    optionSection(options: detail.options)
                }
                reasonSection
                if let message = store.voteDraftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Decisions.voteTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Decisions.voteCancel)) {
                        store.isVotePresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Decisions.voteConfirm)) {
                        save()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var valueSection: some View {
        Section(L10n.Decisions.voteValueSection) {
            ForEach(VoteValue.displayOrder) { value in
                Button {
                    store.voteDraftValue = value
                } label: {
                    HStack {
                        Label(value.label, systemImage: value.systemImageName)
                            .font(.body)
                        Spacer()
                        if store.voteDraftValue == value {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func optionSection(options: [GroupDecisionOption]) -> some View {
        Section(L10n.Decisions.voteOptionSection) {
            Button {
                store.voteDraftOptionId = nil
            } label: {
                HStack {
                    Text(L10n.Decisions.voteOptionNoneRow)
                        .foregroundStyle(.primary)
                    Spacer()
                    if store.voteDraftOptionId == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(options) { option in
                Button {
                    store.voteDraftOptionId = option.id
                } label: {
                    HStack {
                        Text(option.label)
                            .foregroundStyle(.primary)
                        Spacer()
                        if store.voteDraftOptionId == option.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var reasonSection: some View {
        Section(L10n.Decisions.voteReasonSection) {
            TextField(
                String(localized: L10n.Decisions.voteReasonPlaceholder),
                text: $store.voteDraftReason,
                axis: .vertical
            )
            .lineLimit(2...5)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveDraftVote(groupId: groupId)
            isSaving = false
        }
    }
}
