import SwiftUI
import RuulCore

/// `ContentUnavailableView` for the "no members yet" state. Stays
/// minimal — the invite action lives in the parent's toolbar so the
/// empty state focuses on explaining the next step.
public struct MembersEmptyStateView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label(L10n.Members.emptyTitle, systemImage: "person.2.slash")
        } description: {
            Text(L10n.Members.emptyDescription)
        }
    }
}

#Preview {
    MembersEmptyStateView()
}
