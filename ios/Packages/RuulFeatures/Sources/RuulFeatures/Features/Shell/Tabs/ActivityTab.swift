import SwiftUI
import RuulCore

/// Placeholder for the Activity tab body. Pass 2 Task 4 fills this in
/// with `ActivityView` + filter chips (renamed from `GroupHistoryView`).
@MainActor
public struct ActivityTab: View {
    public init() {}

    public var body: some View {
        Color.clear
            .overlay {
                ProgressView()
                    .controlSize(.large)
            }
    }
}
