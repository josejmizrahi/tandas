import SwiftUI
import RuulUI
import RuulCore

/// Rules surface for a single event. Lists rules scoped to
/// `rules.resource_id = event.id`, with a CTA to add a new one. The add
/// path opens `AddEventRuleSheet` — both views bind the same coordinator.
///
/// Per Taxonomy §29 scope contract: this sheet ONLY shows event-scoped
/// rules. Group-level rules (the Reglas tab) remain visible separately.
/// Adding a rule from here always writes `resource_id = event.id`.
struct EventRulesSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: EventRulesCoordinator

    public init(
        isPresented: Binding<Bool>,
        coordinator: EventRulesCoordinator
    ) {
        self._isPresented = isPresented
        self.coordinator = coordinator
    }

    var body: some View {
        ModalSheetTemplate(
            title: "Reglas del evento",
            dismissAction: { isPresented = false }
        ) {
            if coordinator.isLoading && coordinator.rules.isEmpty {
                RuulLoadingState()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if coordinator.rules.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.clipboard",
                    title: "Sin reglas específicas",
                    message: coordinator.canCreate
                        ? "Agrega reglas que sólo apliquen a este evento. Las del grupo siguen aplicando."
                        : "Sólo el host o un admin pueden crear reglas específicas para este evento."
                )
                .padding(.vertical, RuulSpacing.md)
            } else {
                ForEach(coordinator.rules) { rule in
                    ruleRow(rule)
                }
            }
            if coordinator.canCreate {
                addRuleCTA
                    .padding(.top, RuulSpacing.sm)
            }
        }
        .task { await coordinator.load() }
        .ruulSheet(isPresented: $coordinator.addSheetPresented) {
            AddEventRuleSheet(
                isPresented: $coordinator.addSheetPresented,
                coordinator: coordinator
            )
        }
    }

    // MARK: - Rule row

    private func ruleRow(_ rule: GroupRule) -> some View {
        let triggerLabel = triggerDisplay(for: rule.trigger.eventType)
        let fineAmount = rule.amountMXN
        return VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "list.bullet.clipboard.fill")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(2)
                    Text(triggerLabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                if let amount = fineAmount {
                    Text(formatMXN(amount))
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private var addRuleCTA: some View {
        RuulButton(
            "Agregar regla",
            style: .primary,
            size: .large,
            fillsWidth: true
        ) {
            coordinator.resetForm()
            coordinator.addSheetPresented = true
        }
    }

    // MARK: - Helpers

    private func triggerDisplay(for type: SystemEventType) -> String {
        switch type {
        case .checkInRecorded:     return "Cuando alguien llega tarde"
        case .rsvpChangedSameDay:  return "Cuando alguien cancela mismo día"
        case .eventClosed:         return "Al cerrar el evento"
        case .rsvpDeadlinePassed:  return "Al vencer el RSVP"
        case .hoursBeforeEvent:    return "Horas antes del evento"
        default:                   return type.rawString
        }
    }

    private func formatMXN(_ amount: Int) -> String {
        "$\(amount)"
    }
}
