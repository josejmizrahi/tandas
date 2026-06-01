import SwiftUI
import RuulCore

/// Wraps `set_membership_state` for Primitiva 2. Same sheet handles
/// Suspender / Reactivar / Expulsar — the target state is set on the
/// store via `beginChangingState(...)` before presenting. Reason is
/// required for non-active targets; suspension also accepts an optional
/// `until` date that the RPC persists into `suspended_until`.
struct MembershipStateSheet: View {
    @Bindable var store: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                if store.stateDraftTargetState != .active {
                    Section(L10n.MembershipState.reasonSection) {
                        TextField(
                            String(localized: L10n.MembershipState.reasonPlaceholder),
                            text: $store.stateDraftReason,
                            axis: .vertical
                        )
                        .lineLimit(2...6)
                    }
                }

                if store.stateDraftTargetState == .suspended {
                    Section(L10n.MembershipState.untilSection) {
                        Toggle(isOn: $store.stateDraftHasUntil) {
                            Text(L10n.MembershipState.untilToggle)
                        }
                        if store.stateDraftHasUntil {
                            DatePicker(
                                "",
                                selection: $store.stateDraftUntil,
                                in: Date()...,
                                displayedComponents: [.date]
                            )
                            .labelsHidden()
                        }
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.MembershipState.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.MembershipState.save) }
                    }
                    .disabled(!store.canSaveStateDraft || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var title: LocalizedStringResource {
        switch store.stateDraftTargetState {
        case .suspended: return L10n.MembershipState.suspendTitle
        case .banned:    return L10n.MembershipState.removeTitle
        default:         return L10n.MembershipState.reactivateTitle
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveStateDraft(groupId: groupId)
        if ok { dismiss() }
    }
}
