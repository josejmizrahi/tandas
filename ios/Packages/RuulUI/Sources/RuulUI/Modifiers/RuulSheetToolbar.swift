import SwiftUI

/// Canonical toolbar chrome for every modal sheet / push detail.
///
/// Renders Apple's standard sheet header: native `.navigationTitle`
/// (centered inline) and a "Cancelar" button in `.cancellationAction`
/// placement. Trailing actions stay open for each caller via a normal
/// `.toolbar { ToolbarItem(placement: .topBarTrailing) { ... } }`
/// modifier downstream.
///
/// Pass `onClose` only when the sheet needs to tear down some external
/// route binding before SwiftUI propagates `\.dismiss` (e.g. router
/// stacks). The default reads `@Environment(\.dismiss)`.
public struct RuulSheetToolbarModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onClose: (() -> Void)?

    public init(title: String, onClose: (() -> Void)? = nil) {
        self.title = title
        self.onClose = onClose
    }

    public func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
            }
    }
}

public extension View {
    /// Mounts the canonical sheet toolbar (Cancelar in `.cancellationAction`
    /// + native inline title). Trailing actions go through a normal
    /// `.toolbar { ToolbarItem(placement: .topBarTrailing) { ... } }`
    /// modifier and compose with this one.
    func ruulSheetToolbar(_ title: String, onClose: (() -> Void)? = nil) -> some View {
        modifier(RuulSheetToolbarModifier(title: title, onClose: onClose))
    }
}
