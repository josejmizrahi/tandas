import SwiftUI
import RuulUI
import RuulCore

/// Form for creating a single event-scoped rule. Renders every picker /
/// input from `RuleShapeRegistry` — adding a new trigger or consequence
/// is a server-side change (mig + INSERT into `public.rule_shapes`), no
/// iOS release needed.
///
/// Founder principle: copy reads as "Si X → Y", never "trigger /
/// consequence". The two top sections are labeled "CUÁNDO" and "ENTONCES"
/// to land in the user's mental model.
// File name kept for git continuity; the type is `AddResourceRuleSheet`
// — the form is polymorphic over Resource type, not specific to events.
struct AddResourceRuleSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: ResourceRulesCoordinator

    var body: some View {
        ModalSheetTemplate(
            title: "Nueva regla",
            dismissAction: { isPresented = false }
        ) {
            nameSection
            triggerSection
            consequenceSection
            previewSection
            if let error = coordinator.error {
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
            submitButton
                .padding(.top, RuulSpacing.sm)
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        RuulTextField(
            "Late fee de esta cena",
            text: $coordinator.formName,
            label: "NOMBRE",
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - Trigger picker

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("CUÁNDO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            if coordinator.availableTriggers.isEmpty {
                emptyShapeMessage("No hay momentos disponibles todavía.")
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
                Text("ENTONCES → \(only.labelES.uppercased())")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                configFields(for: only)
            }
        } else if !coordinator.availableConsequences.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("ENTONCES")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
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
            emptyShapeMessage("No hay acciones disponibles todavía.")
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
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.top, 2)
                Text("\(sentence).")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(RuulSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
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
                        .font(RuulTypography.subheadMedium.font)
                        .foregroundStyle(Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(shape.labelES)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if let summary = shape.summaryES, !summary.isEmpty {
                        Text(summary)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .ruulTextStyle(RuulTypography.calloutBold)
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(isSelected ? Color.ruulAccentMuted : Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(isSelected ? Color.ruulAccent : Color.ruulSeparator,
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
            label: field.labelES.uppercased(),
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

    // MARK: - Empty + CTA

    private func emptyShapeMessage(_ message: String) -> some View {
        Text(message)
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextSecondary)
            .padding(.vertical, RuulSpacing.sm)
    }

    private var submitButton: some View {
        let label: String = coordinator.isSubmitting ? "Guardando…" : "Crear regla"
        return RuulButton(
            label,
            style: .primary,
            size: .large,
            isLoading: coordinator.isSubmitting,
            fillsWidth: true
        ) {
            Task {
                let rule = await coordinator.submit()
                if rule != nil {
                    isPresented = false
                }
            }
        }
        .disabled(!coordinator.canSubmit)
    }
}
