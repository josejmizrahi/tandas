import SwiftUI
import RuulUI
import RuulCore

/// Push destination for creating a single resource-scoped rule. Renders
/// every picker / input from `RuleShapeRegistry` — adding a new trigger
/// or consequence is a server-side change (mig + INSERT into
/// `public.rule_shapes`), no iOS release needed.
///
/// Founder principle: copy reads as "Si X → Y", never "trigger /
/// consequence". The two top sections are labeled "CUÁNDO" and "ENTONCES"
/// to land in the user's mental model.
///
/// Sheet-on-sheet doctrine (2026-05-20): the parent `ResourceRulesSheet`
/// is a fullScreenCover that hosts its own NavigationStack. This view is
/// the push destination registered behind `RuleAddRoute`, NOT a child
/// sheet — opaque base under the form so the glass treatment stays
/// readable.
// File name kept for git continuity; the type is `AddResourceRuleDestination`
// — the form is polymorphic over Resource type, not specific to events.
struct AddResourceRuleDestination: View {
    @Bindable var coordinator: ResourceRulesCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                nameSection
                triggerSection
                consequenceSection
                previewSection
                if let error = coordinator.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.lg)
        }
        .navigationTitle("Nueva regla")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        let rule = await coordinator.submit()
                        if rule != nil { dismiss() }
                    }
                } label: {
                    if coordinator.isSubmitting {
                        ProgressView()
                    } else {
                        Text("Crear")
                    }
                }
                .disabled(!coordinator.canSubmit || coordinator.isSubmitting)
            }
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        RuulTextField(
            "Late fee de esta cena",
            text: $coordinator.formName,
            label: "Nombre",
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - Trigger picker

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Cuándo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            if coordinator.availableTriggers.isEmpty {
                emptyShapeMessage("Aún no hay opciones disponibles.")
            } else {
                RuulSeparatedRows(items: coordinator.availableTriggers) { shape in
                    shapeRow(
                        shape,
                        isSelected: coordinator.formTriggerId == shape.id,
                        onTap: { coordinator.selectTrigger(shape.id) }
                    )
                }
                .disabled(coordinator.isSubmitting)
                if let trigger = coordinator.selectedTrigger {
                    configFields(for: trigger)
                }
            }
        }
    }

    // MARK: - Consequence picker

    @ViewBuilder
    private var consequenceSection: some View {
        if coordinator.availableConsequences.count <= 1,
           let only = coordinator.availableConsequences.first {
            // Single consequence path — render just its config fields
            // under a fixed "ENTONCES" header. Avoids a one-row picker
            // that adds noise without choice.
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Entonces → \(only.labelES)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                configFields(for: only)
            }
        } else if !coordinator.availableConsequences.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Entonces")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                RuulSeparatedRows(items: coordinator.availableConsequences) { shape in
                    shapeRow(
                        shape,
                        isSelected: coordinator.formConsequenceId == shape.id,
                        onTap: { coordinator.selectConsequence(shape.id) }
                    )
                }
                .disabled(coordinator.isSubmitting)
                if let consequence = coordinator.selectedConsequence {
                    configFields(for: consequence)
                }
            }
        } else {
            emptyShapeMessage("Aún no hay opciones de qué pasa.")
        }
    }

    // MARK: - Live preview ("Si X → Y" sentence)

    @ViewBuilder
    private var previewSection: some View {
        if let sentence = RuleSentenceFormatter.draftSentence(
            triggerShapeId: coordinator.formTriggerId,
            consequenceShapeId: coordinator.formConsequenceId,
            fieldValues: coordinator.formFieldValues,
            registry: coordinator.shapeRegistry
        ) {
            HStack(alignment: .top, spacing: RuulSpacing.xs) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.top, 2)
                Text("\(sentence).")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(RuulSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        }
    }

    // MARK: - Shape row primitive

    private func shapeRow(
        _ shape: RuleShape,
        isSelected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(isSelected ? 0.18 : 0.10))
                        .frame(width: 36, height: 36)
                    Image(systemName: shape.icon ?? "circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(shape.labelES)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    if let summary = shape.summaryES, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(isSelected ? Color.ruulAccentMuted : Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(isSelected ? Color.ruulAccent : Color(.separator),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dynamic config fields

    @ViewBuilder
    private func configFields(for shape: RuleShape) -> some View {
        if !shape.configFields.isEmpty {
            VStack(spacing: RuulSpacing.sm) {
                ForEach(shape.configFields, id: \.key) { field in
                    fieldEditor(shape: shape, field: field)
                }
            }
            .padding(.top, RuulSpacing.xs)
        }
    }

    @ViewBuilder
    private func fieldEditor(shape: RuleShape, field: RuleShapeField) -> some View {
        let key = coordinator.fieldBindingKey(shape: shape, field: field)
        RuulTextField(
            field.placeholder ?? "",
            text: bindingForField(key),
            label: field.labelES,
            style: textFieldStyle(for: field.kind),
            isDisabled: coordinator.isSubmitting
        )
    }

    private func bindingForField(_ key: String) -> Binding<String> {
        Binding(
            get: { coordinator.formFieldValues[key] ?? "" },
            set: { coordinator.formFieldValues[key] = $0 }
        )
    }

    private func textFieldStyle(for kind: RuleShapeField.Kind) -> RuulTextField.Style {
        switch kind {
        case .int, .currency: return .numeric
        case .string:         return .standard
        }
    }

    // MARK: - Empty messages

    private func emptyShapeMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .padding(.vertical, RuulSpacing.sm)
    }
}
