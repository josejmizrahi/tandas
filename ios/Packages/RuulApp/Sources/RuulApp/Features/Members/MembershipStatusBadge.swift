import SwiftUI
import RuulCore

/// Capsule badge surfacing a non-active membership status. Returns
/// `EmptyView` for `.active` so the common case stays uncluttered.
/// Combines text + material so the meaning isn't carried by colour
/// alone (accessibility).
public struct MembershipStatusBadge: View {
    let status: MembershipStatus

    public init(status: MembershipStatus) {
        self.status = status
    }

    public var body: some View {
        if status == .active {
            EmptyView()
        } else {
            Text(status.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .accessibilityLabel(Text(status.label))
        }
    }
}

#Preview("Statuses") {
    VStack(alignment: .leading, spacing: 8) {
        MembershipStatusBadge(status: .invited)
        MembershipStatusBadge(status: .requested)
        MembershipStatusBadge(status: .suspended)
        MembershipStatusBadge(status: .banned)
        MembershipStatusBadge(status: .left)
        MembershipStatusBadge(status: .active) // empty
    }
    .padding()
}
