import SwiftUI
import RuulCore

/// Failure-state placeholder paired with a retry button. The caller
/// owns the retry closure so the same view can be reused for any
/// load-and-fail screen across the members surface.
public struct MembersErrorStateView: View {
    let message: String
    let retry: () -> Void

    public init(message: String, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(L10n.Members.errorTitle, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(action: retry) {
                Text(L10n.Members.retryButton)
            }
        }
    }
}

#Preview {
    MembersErrorStateView(message: "Sin conexión") {}
}
