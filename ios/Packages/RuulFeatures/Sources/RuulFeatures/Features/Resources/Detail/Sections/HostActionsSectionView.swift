import SwiftUI
import RuulUI
import RuulCore

/// Host-only action panel for event-shaped resources. Gated by the
/// `host_actions` capability (seeded for every event by mig 00109) plus
/// `EventInteractor.viewerIsHost`. Non-host viewers see nothing even
/// though the cap is enabled — the section returns `EmptyView`.
///
/// Surfaces:
///   - Confirmation stats (X de Y CONFIRMARON + progress bar)
///   - Reminders / Edit / Scanner / Cancel / Manual fine action cards
///   - Auto-generate toggle for recurring events
///   - "Cerrar evento" primary CTA when the event window has elapsed
///
/// All taps route through `\.eventDetailPresenter` (sheets, scanner,
/// edit) or `\.eventInteractor` (mutations like cancel / toggle
/// autogen). When the presenter is missing, taps degrade to no-ops; the
/// section itself still renders so the host sees the surface in
/// previews / read-only contexts.
public struct HostActionsSectionView: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?
    @Environment(\.eventDetailPresenter) private var presenter: EventDetailPresenter?

    public let context: ResourceDetailContext

    @State private var autoGenerateLocal: Bool = false

    public static let definition = CapabilitySection(
        id: "host_actions",
        priority: 350,
        isEnabledFor: { caps in caps.contains("host_actions") },
        render: { ctx in AnyView(HostActionsSectionView(context: ctx)) }
    )

    public var body: some View {
        if let interactor, interactor.viewerIsHost {
            content(interactor: interactor)
        }
    }

    @ViewBuilder
    private func content(interactor: any EventInteractor) -> some View {
        let event = interactor.event
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            sectionHeader("COMO HOST")

            statsCard(interactor: interactor)
            actionsCard(event: event, interactor: interactor)

            // "Cerrar evento" lives in the sticky bottom footer
            // (DetailStickyFooterView) so the host always has the CTA in
            // reach when the event window has elapsed. Keeping a second
            // copy here would duplicate the affordance.

            if event.isRecurringGenerated {
                autoGenerateToggleCard(interactor: interactor)
            }
        }
    }

    // MARK: - Stats

    private func statsCard(interactor: any EventInteractor) -> some View {
        let totalConfirmed = interactor.rsvps.filter { $0.status == .going }.count
        let totalMembers = max(interactor.rsvps.count, 1)
        let ratio = Double(totalConfirmed) / Double(totalMembers)
        let percent = Int(ratio * 100)

        return RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(alignment: .lastTextBaseline) {
                    HStack(spacing: 6) {
                        Text("\(totalConfirmed)")
                            .ruulTextStyle(RuulTypography.statMedium)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("DE \(interactor.rsvps.count) CONFIRMARON")
                            .ruulTextStyle(RuulTypography.sectionLabel)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    Spacer()
                    Text("\(percent)%")
                        .ruulTextStyle(RuulTypography.statMedium)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                RuulProgressBar(value: ratio)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionsCard(event: Event, interactor: any EventInteractor) -> some View {
        VStack(spacing: RuulSpacing.sm) {
            RuulActionableCard(
                icon: "bell.badge",
                title: "Mandar recordatorio",
                subtitle: "A los que no han confirmado."
            ) {
                presenter?.onPresentRemindAttendeesSheet()
            }
            RuulActionableCard(
                icon: "pencil",
                title: "Editar evento",
                subtitle: "Cambiar fecha, ubicación, host."
            ) {
                presenter?.onPresentEditEvent()
            }
            if !event.isPast && event.status != .cancelled {
                RuulActionableCard(
                    icon: "qrcode.viewfinder",
                    title: "Modo check-in",
                    subtitle: "Escanea QRs de tus invitados.",
                    accessory: .badge("Nuevo")
                ) {
                    presenter?.onPresentScanner()
                }
            }
            RuulActionableCard(
                icon: "xmark.circle",
                title: "Cancelar evento",
                subtitle: "Avisamos a todos los confirmados.",
                tint: .ruulNegative,
                accessory: .none
            ) {
                presenter?.onPresentCancelEventSheet()
            }
            if presenter?.canIssueManualFine == true {
                RuulActionableCard(
                    icon: "exclamationmark.triangle",
                    title: "Multar manualmente",
                    subtitle: "Sin pasar por reglas automáticas."
                ) {
                    presenter?.onPresentManualFineSheet()
                }
            }
        }
    }

    // MARK: - Auto-generate

    private func autoGenerateToggleCard(interactor: any EventInteractor) -> some View {
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
                Toggle(
                    "",
                    isOn: Binding(
                        get: { autoGenerateLocal },
                        set: { newValue in
                            autoGenerateLocal = newValue
                            Task { await interactor.toggleAutoGenerate(newValue) }
                        }
                    )
                )
                .labelsHidden()
                .tint(Color.ruulAccent)
                .accessibilityLabel("Generación automática")
            }
        }
    }

}
