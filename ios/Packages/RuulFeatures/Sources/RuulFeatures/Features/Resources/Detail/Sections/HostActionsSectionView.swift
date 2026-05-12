import SwiftUI
import RuulUI
import RuulCore

/// Host-only action panel for event-shaped resources. Settings-style
/// grouped list — a single rounded surface with action rows divided by
/// thin separators. Replaces the legacy stack of four to five separate
/// `RuulActionableCard` instances which created visual heaviness in the
/// detail page.
///
/// Gated by the `host_actions` capability (mig 00109) AND
/// `EventInteractor.viewerIsHost`. Non-host viewers see `EmptyView`
/// even though the cap is enabled.
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

    // MARK: - Composition

    @ViewBuilder
    private func content(interactor: any EventInteractor) -> some View {
        let event = interactor.event
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Como host")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
                .padding(.horizontal, RuulSpacing.xxs)

            statsRow(interactor: interactor)
            actionList(event: event)

            if event.isRecurringGenerated {
                autoGenerateRow(interactor: interactor)
            }
        }
    }

    // MARK: - Stats

    private func statsRow(interactor: any EventInteractor) -> some View {
        let totalConfirmed = interactor.rsvps.filter { $0.status == .going }.count
        let total = max(interactor.rsvps.count, 1)
        let ratio = Double(totalConfirmed) / Double(total)
        let percent = Int(ratio * 100)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(totalConfirmed) de \(interactor.rsvps.count) confirmaron")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: 0)
                Text("\(percent)%")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            RuulProgressBar(value: ratio)
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    // MARK: - Action list

    @ViewBuilder
    private func actionList(event: Event) -> some View {
        let showScanner = !event.isPast && event.status != .cancelled
        let showManualFine = presenter?.canIssueManualFine == true

        VStack(spacing: 0) {
            actionRow(icon: "bell.badge", title: "Mandar recordatorio") {
                presenter?.onPresentRemindAttendeesSheet()
            }
            divider
            actionRow(icon: "pencil", title: "Editar evento") {
                presenter?.onPresentEditEvent()
            }
            if showScanner {
                divider
                actionRow(
                    icon: "qrcode.viewfinder",
                    title: "Modo check-in",
                    badge: "Nuevo"
                ) {
                    presenter?.onPresentScanner()
                }
            }
            if showManualFine {
                divider
                actionRow(icon: "exclamationmark.triangle", title: "Multar manualmente") {
                    presenter?.onPresentManualFineSheet()
                }
            }
            divider
            actionRow(
                icon: "xmark.circle",
                title: "Cancelar evento",
                tint: .ruulNegative
            ) {
                presenter?.onPresentCancelEventSheet()
            }
        }
        .background(
            Color.ruulSurface,
            in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
        )
    }

    @ViewBuilder
    private func actionRow(
        icon: String,
        title: String,
        badge: String? = nil,
        tint: Color = .ruulTextPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint == .ruulTextPrimary ? Color.ruulTextSecondary : tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(tint)
                if let badge {
                    Text(badge)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulAccent)
                        .padding(.horizontal, RuulSpacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.ruulAccent.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.md)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private var divider: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, RuulSpacing.md + 28 + RuulSpacing.md)
    }

    // MARK: - Auto-generate (recurring)

    private func autoGenerateRow(interactor: any EventInteractor) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.md) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Generación automática")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Cuando cierres este evento, creamos el siguiente.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
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
        .padding(RuulSpacing.md)
        .background(
            Color.ruulSurface,
            in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
        )
    }
}
