import SwiftUI
import RuulUI
import RuulCore

/// Sticky bottom CTA pinned via `.safeAreaInset(edge: .bottom)`. The view
/// renders one of three states (mutually exclusive):
///
///   - Host with a closeable event → "Cerrar evento" primary CTA
///   - Guest with `.going` RSVP    → "No voy a poder ir" subtle dismiss
///   - Otherwise                   → EmptyView (no insetting cost)
///
/// Both branches require `\.eventInteractor` to gate the state and
/// `\.eventDetailPresenter` to route the tap to the owning sheet
/// (CloseEventSheet / CancelAttendanceSheet). Footer collapses cleanly
/// when either env value is missing — the universal detail still
/// renders without a footer on non-event resources.
public struct DetailStickyFooterView: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?
    @Environment(\.eventDetailPresenter) private var presenter: EventDetailPresenter?

    public init() {}

    public var body: some View {
        if let footer = footerContent {
            footer
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.vertical, RuulSpacing.sm)
                .frame(maxWidth: .infinity)
                .ruulGlass(Rectangle(), material: .regular)
        }
    }

    @ViewBuilder
    private var footerContent: (some View)? {
        if let interactor, let presenter {
            if interactor.viewerIsHost, isCloseable(event: interactor.event) {
                RuulButton(
                    "Cerrar evento",
                    style: .primary,
                    size: .large,
                    fillsWidth: true
                ) {
                    presenter.onPresentCloseEventSheet()
                }
            } else if !interactor.viewerIsHost, interactor.myRSVP?.status == .going {
                Button {
                    presenter.onPresentCancelAttendanceSheet()
                } label: {
                    Text("No voy a poder ir")
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancelar mi asistencia")
            }
        }
    }

    private func isCloseable(event: Event) -> Bool {
        guard event.status == .upcoming || event.status == .inProgress else { return false }
        return Date.now > event.startsAt.addingTimeInterval(TimeInterval(event.durationMinutes * 60))
    }
}
