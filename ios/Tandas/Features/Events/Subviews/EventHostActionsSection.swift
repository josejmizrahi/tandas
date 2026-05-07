import SwiftUI

/// Host-only action panel inside `EventDetailView`. Surfaces stats +
/// reminder + edit + check-in mode + cancel + auto-generation toggle.
struct EventHostActionsSection: View {
    let event: Event
    let group: Group
    let totalConfirmed: Int
    let totalMembers: Int
    let onSendReminders: () -> Void
    let onEdit: () -> Void
    let onOpenScanner: () -> Void
    let onCancelEvent: () -> Void
    let onCloseEvent: () -> Void
    let onToggleAutoGenerate: (Bool) -> Void
    let canIssueManualFine: Bool
    let onIssueManualFine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("COMO HOST")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)

            statsCard
            actionsCard
            if event.isPast || event.status == .closed {
                EmptyView()
            } else if isCloseable {
                closeButton
            }
            if event.isRecurringGenerated {
                autoGenerateToggleCard
            }
        }
    }

    private var statsCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(alignment: .lastTextBaseline) {
                    HStack(spacing: 6) {
                        Text("\(totalConfirmed)")
                            .ruulTextStyle(RuulTypography.statMedium)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("DE \(totalMembers) CONFIRMARON")
                            .ruulTextStyle(RuulTypography.sectionLabel)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    Spacer()
                    Text("\(percentConfirmed)%")
                        .ruulTextStyle(RuulTypography.statMedium)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                RuulProgressBar(value: ratioConfirmed)
            }
        }
    }

    private var actionsCard: some View {
        VStack(spacing: RuulSpacing.sm) {
            RuulActionableCard(
                icon: "bell.badge",
                title: "Mandar recordatorio",
                subtitle: "A los que no han confirmado.",
                action: onSendReminders
            )
            RuulActionableCard(
                icon: "pencil",
                title: "Editar evento",
                subtitle: "Cambiar fecha, ubicación, host.",
                action: onEdit
            )
            if !event.isPast && event.status != .cancelled {
                RuulActionableCard(
                    icon: "qrcode.viewfinder",
                    title: "Modo check-in",
                    subtitle: "Escanea QRs de tus invitados.",
                    accessory: .badge("Nuevo"),
                    action: onOpenScanner
                )
            }
            RuulActionableCard(
                icon: "xmark.circle",
                title: "Cancelar evento",
                subtitle: "Avisamos a todos los confirmados.",
                tint: .ruulNegative,
                accessory: .none,
                action: onCancelEvent
            )
            if canIssueManualFine {
                RuulActionableCard(
                    icon: "exclamationmark.triangle",
                    title: "Multar manualmente",
                    subtitle: "Sin pasar por reglas automáticas.",
                    action: onIssueManualFine
                )
            }
        }
    }

    private var closeButton: some View {
        RuulButton("Cerrar evento", style: .primary, size: .large, fillsWidth: true, action: onCloseEvent)
    }

    @State private var autoGenerateLocal: Bool = false

    private var autoGenerateToggleCard: some View {
        RuulCard(.tile) {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                RuulIconBadge("arrow.triangle.2.circlepath", size: .small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generación automática")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Cuando cierres este evento, creamos el siguiente automáticamente.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { autoGenerateLocal },
                    set: { newValue in
                        autoGenerateLocal = newValue
                        onToggleAutoGenerate(newValue)
                    }
                ))
                .labelsHidden()
                .tint(Color.ruulAccent)
            }
        }
    }

    // MARK: - Helpers

    private var ratioConfirmed: Double {
        guard totalMembers > 0 else { return 0 }
        return Double(totalConfirmed) / Double(totalMembers)
    }

    private var percentConfirmed: Int {
        Int(ratioConfirmed * 100)
    }

    private var isCloseable: Bool {
        Date.now > event.startsAt.addingTimeInterval(TimeInterval(event.durationMinutes * 60))
    }
}
