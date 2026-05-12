import SwiftUI
import RuulUI
import RuulCore

/// "Primary Actions" zone per the canonical Resource Detail spec.
/// Surfaces the single most-important CTA for the active resource —
/// the action the user is most likely to take given current state.
///
/// Today the only wired surface is the event-shape RSVP intent control
/// (`EventRSVPStateView`). Future resource types plug additional CTAs
/// here: booking confirm, contribution-due, etc. Distinct from
/// `DetailActionsBar` (chip strip of secondary money actions).
///
/// Renders `EmptyView` when there's nothing primary to surface for the
/// resource (read-only contexts, non-event types without their own
/// interactor yet).
public struct DetailPrimaryActions: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?
    @Environment(\.eventDetailPresenter) private var presenter: EventDetailPresenter?

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        if context.usesEventHero,
           context.enabledCapabilities.contains("rsvp"),
           let interactor {
            eventRSVPIntent(interactor: interactor)
        }
    }

    // MARK: - Event RSVP intent

    private func eventRSVPIntent(interactor: any EventInteractor) -> some View {
        EventRSVPStateView(
            status: interactor.myRSVP?.status ?? .pending,
            event: interactor.event,
            walletAvailable: interactor.walletAvailable,
            isAtCapacity: isAtCapacity(interactor: interactor),
            plusOnes: plusOnesBinding(interactor: interactor),
            onChange: { newStatus in
                Task {
                    await interactor.setRSVP(
                        newStatus,
                        plusOnes: interactor.myRSVP?.plusOnes ?? 0,
                        reason: nil
                    )
                }
            },
            onAddToWallet: { presenter?.onAddToWallet() },
            onShowQR: { presenter?.onPresentMemberQR() }
        )
    }

    /// Two-way bridge for the plus-ones stepper. Reads from the
    /// interactor's truth; writing rebroadcasts through `setRSVP` so the
    /// server confirms the new count without forcing the user to re-tap
    /// their RSVP pill.
    private func plusOnesBinding(interactor: any EventInteractor) -> Binding<Int> {
        Binding(
            get: { interactor.myRSVP?.plusOnes ?? 0 },
            set: { newValue in
                let status = interactor.myRSVP?.status ?? .going
                Task { await interactor.setRSVP(status, plusOnes: newValue, reason: nil) }
            }
        )
    }

    private func isAtCapacity(interactor: any EventInteractor) -> Bool {
        guard let max = interactor.event.capacityMax else { return false }
        let seatsTaken = interactor.rsvps
            .filter { $0.status == .going }
            .reduce(0) { $0 + 1 + $1.plusOnes }
        let myExisting = (interactor.myRSVP?.status == .going)
            ? (1 + (interactor.myRSVP?.plusOnes ?? 0))
            : 0
        return (seatsTaken - myExisting + 1) > max
    }
}
