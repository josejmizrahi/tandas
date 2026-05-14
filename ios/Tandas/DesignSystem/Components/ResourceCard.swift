import SwiftUI
import RuulCore
import RuulUI
import RuulFeatures

/// Generic resource card. Switches on `resource.resourceType` to dispatch
/// to the appropriate concrete view body. V1 only `.event` is wired and
/// re-uses the existing `EventCard` primitive — when Phase 2/3/4 ship
/// Slot/Fund/Position/Asset/Contribution, their bodies will hang off the
/// same switch here.
///
/// **Por qué scaffolding y no full HomeView swap V1**: HomeView's hero
/// es un render bespoke. ResourceCard V1 es scaffolding + router para
/// los consumers que SÍ usan EventCard hoy (`MyFeedView`, `PastResourcesView`).
///
/// Invariante: `resource.resourceType == .event ⇒ resource is Event`
/// (Event conforms to Resource directly post Plan 1; the EventResource
/// wrapper is gone). Cast con seguridad dentro del case.
struct ResourceCard: View {
    let resource: any Resource
    let myStatus: RSVPStatus?
    let isHostedByMe: Bool
    let attendeeAvatars: [RuulAvatarStack.Person]
    let confirmedCount: Int
    let isAtCapacity: Bool
    let onTap: () -> Void

    init(
        resource: any Resource,
        myStatus: RSVPStatus? = nil,
        isHostedByMe: Bool = false,
        attendeeAvatars: [RuulAvatarStack.Person] = [],
        confirmedCount: Int = 0,
        isAtCapacity: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.resource = resource
        self.myStatus = myStatus
        self.isHostedByMe = isHostedByMe
        self.attendeeAvatars = attendeeAvatars
        self.confirmedCount = confirmedCount
        self.isAtCapacity = isAtCapacity
        self.onTap = onTap
    }

    var body: some View {
        switch resource.resourceType {
        case .event:
            if let event = resource as? Event {
                EventCard(
                    event: event,
                    myStatus: myStatus,
                    isHostedByMe: isHostedByMe,
                    attendeeAvatars: attendeeAvatars,
                    confirmedCount: confirmedCount,
                    isAtCapacity: isAtCapacity,
                    onTap: onTap
                )
            } else {
                // Defensive — V1 invariant says Event is the only .event
                // conformer. Si esto se rompe es bug, no UI fallback.
                UnknownResourceCard(resource: resource)
            }
        case .fund, .asset, .space, .slot, .right, .unknown:
            UnknownResourceCard(resource: resource)
        }
    }
}

/// Fallback visual para resource types aún no implementados. Existe para
/// que el switch sea total y para que QA spotee inmediatamente si un
/// resource llega a UI sin body — no es un error silencioso.
private struct UnknownResourceCard: View {
    let resource: any Resource

    var body: some View {
        HStack(spacing: RuulSpacing.xs) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ruulTextTertiary)
            Text("Resource \(String(describing: resource.resourceType)) sin body")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }
}
