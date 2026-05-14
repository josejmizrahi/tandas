import SwiftUI
import RuulCore

/// Placeholder for the Inbox tab body. Pass 2 Task 3 fills this in
/// with `InboxView` + filter chips.
@MainActor
public struct InboxTab: View {
    public init() {}

    public var body: some View {
        Color.clear
            .overlay {
                ProgressView()
                    .controlSize(.large)
            }
    }
}
