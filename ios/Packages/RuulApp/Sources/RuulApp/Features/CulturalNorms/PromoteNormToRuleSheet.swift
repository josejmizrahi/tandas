import SwiftUI
import RuulCore

/// V2-G6 — sheet to promote an active cultural norm into a formal
/// rule. Pre-populates title from the norm; lets the proponente pick
/// the canonical rule_type (norm/requirement/prohibition/process/
/// principle) and a severity 0…5. On success the norm is removed
/// from the list (backend retired it) and the parent surface can
/// optionally refresh its RulesStore via the `onSuccess` callback.
struct PromoteNormToRuleSheet: View {
    @Bindable var store: CulturalNormsStore
    let groupId: UUID
    let norm: GroupCulturalNorm
    let onSuccess: ((PromoteNormToRuleResult) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var ruleType: GroupRuleType = .principle
    @State private var severity: Int = 1
    @State private var isSubmitting: Bool = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.CulturalNorms.promoteSourceSection) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(norm.title)
                            .font(.body.weight(.semibold))
                        if let body = norm.body, !body.isEmpty {
                            Text(body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Label(norm.type.label, systemImage: norm.type.systemImageName)
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                                .foregroundStyle(.secondary)
                            Text(norm.status.label)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(L10n.CulturalNorms.promoteRuleTypeSection) {
                    Picker("rule_type", selection: $ruleType) {
                        ForEach(GroupRuleType.allCases) { type in
                            Label(type.label, systemImage: type.systemImageName)
                                .tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Section {
                    Stepper(
                        value: $severity,
                        in: 0...5,
                        step: 1
                    ) {
                        HStack {
                            Text(L10n.CulturalNorms.promoteSeveritySection)
                            Spacer()
                            Text("\(severity)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(L10n.CulturalNorms.promoteSeverityHint)
                }

                Section {
                    EmptyView()
                } footer: {
                    Text(L10n.CulturalNorms.promoteFootnote)
                }

                if let message = localError ?? store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.CulturalNorms.promoteSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.CulturalNorms.cancel)) {
                        store.clearError()
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L10n.CulturalNorms.promoteConfirm)
                        }
                    }
                    .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        localError = nil
        store.clearError()
        let result = await store.promoteToRule(
            normId: norm.id,
            ruleType: ruleType,
            severity: severity,
            groupId: groupId
        )
        guard let result else {
            localError = store.errorMessage
            return
        }
        onSuccess?(result)
        dismiss()
    }
}
