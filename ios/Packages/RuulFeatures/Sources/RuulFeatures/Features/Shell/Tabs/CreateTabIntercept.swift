import SwiftUI

/// The body of this view is never shown — `RootRouter.handleTabSelection`
/// intercepts `.create` taps before the TabView swaps content and routes
/// to a sheet/cover instead. A clear `Color.clear` keeps the tab valid
/// for SwiftUI's TabView machinery.
@MainActor
public struct CreateTabIntercept: View {
    public init() {}

    public var body: some View {
        Color.clear
    }
}
