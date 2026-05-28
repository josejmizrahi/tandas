import SwiftUI
import RuulCore

/// Compact `.medium` detent sheet for casting (or changing) a vote on
/// an open decision. Drives `cast_vote(...)` via the store. Surfaces
/// the option picker only when the decision has explicit options.
///
/// V2-G1 sub-slice 2 — the value list adapts to `decision.method`:
/// consensus → 3 estados, consent/veto → 2 estados con razón
/// obligatoria al bloquear, admin → informativa (sin voto). Métodos
/// más ricos (ranked_choice / weighted) seguirán cayendo en la lista
/// completa hasta el sub-slice 3 que les diseñe UX propia.
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
                if currentMethod == .admin {
                    adminOnlyNotice
                } else {
                    valueSection
                    if let detail = store.detail, detail.id == store.voteDraftDecisionId, !detail.options.isEmpty {
                        optionSection(options: detail.options)
                    }
                    reasonSection
                }
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
                    .disabled(isSaving || currentMethod == .admin)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Method of the decision being voted on. We prefer the loaded
    /// detail (canonical source) and fall back to majority when neither
    /// detail nor a matching summary is available — that way the sheet
    /// stays usable for the pre-V2-G1 baseline shape.
    private var currentMethod: DecisionMethod {
        if let detail = store.detail, detail.id == store.voteDraftDecisionId {
            return detail.method
        }
        return .majority
    }

    private var allowedValues: [VoteValue] {
        VoteValue.allowed(for: currentMethod)
    }

    @ViewBuilder
    private var adminOnlyNotice: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(L10n.Decisions.voteAdminOnlyTitle)
                        .font(.headline)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(.tint)
                }
                Text(L10n.Decisions.voteAdminOnlyHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var valueSection: some View {
        Section(L10n.Decisions.voteValueSection) {
            ForEach(allowedValues) { value in
                Button {
                    store.voteDraftValue = value
                } label: {
                    HStack {
                        Label(value.label(for: currentMethod), systemImage: value.systemImageName)
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
        let required = store.voteDraftValue.requiresReason(for: currentMethod)
        Section {
            TextField(
                String(localized: required
                       ? L10n.Decisions.voteReasonRequiredPlaceholder
                       : L10n.Decisions.voteReasonPlaceholder),
                text: $store.voteDraftReason,
                axis: .vertical
            )
            .lineLimit(2...5)
        } header: {
            Text(required
                 ? L10n.Decisions.voteReasonRequiredSection
                 : L10n.Decisions.voteReasonSection)
        } footer: {
            if required {
                Text(L10n.Decisions.voteReasonRequiredHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
