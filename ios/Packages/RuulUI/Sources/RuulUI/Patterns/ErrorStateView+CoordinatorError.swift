import SwiftUI
import RuulCore

public extension ErrorStateView {
    /// Convenience init para coordinator-driven errors.
    init(error: CoordinatorError, retry: (() -> Void)? = nil) {
        self.init(
            systemImage: error.isRetryable ? "exclamationmark.triangle" : "exclamationmark.octagon",
            title: error.title,
            message: error.message,
            retryAction: (error.isRetryable && retry != nil) ? ("Reintentar", retry!) : nil
        )
    }
}
