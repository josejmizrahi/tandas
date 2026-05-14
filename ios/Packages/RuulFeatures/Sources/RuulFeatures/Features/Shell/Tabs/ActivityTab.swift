import SwiftUI
import RuulCore

@MainActor
public struct ActivityTab: View {
    @Environment(AppState.self) private var app
    let coordinator: ActivityCoordinator?

    public init(activity: ActivityCoordinator?) {
        self.coordinator = activity
    }

    public var body: some View {
        NavigationStack {
            if let coord = coordinator {
                ActivityView(coordinator: coord)
                    .environment(app)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
