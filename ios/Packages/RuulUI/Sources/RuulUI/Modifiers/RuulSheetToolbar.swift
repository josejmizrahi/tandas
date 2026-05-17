import SwiftUI

/// Canonical toolbar chrome for every modal sheet / push detail.
///
/// Two slots are filled here, leaving `.topBarTrailing` open for each
/// caller to append its own actions via a regular `.toolbar { ... }`
/// modifier downstream:
///
///   `.topBarLeading`  — xmark close (`RuulCloseToolbarButton`)
///   `.principal`      — title centered, `RuulTypography.headline`
///
/// Replaces the inline pattern duplicated across ~20 sheets:
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .topBarLeading) {
///         RuulCloseToolbarButton { dismiss() }
///     }
///     ToolbarItem(placement: .principal) {
///         Text("Title").ruulTextStyle(RuulTypography.headline)...
///     }
/// }
/// .toolbarBackground(.visible, for: .navigationBar)
/// .toolbarBackground(Color.ruulBackground, for: .navigationBar)
/// .navigationBarTitleDisplayMode(.inline)
/// ```
///
/// Now a single line at the call site:
///
/// ```swift
/// .ruulSheetToolbar("Editar grupo")
/// ```
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RuulCloseToolbarButton {
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

public extension View {
    /// Mounts the canonical sheet toolbar (xmark close on the left,
    /// title centered). Trailing actions go through a normal
    /// `.toolbar { ToolbarItem(placement: .topBarTrailing) { ... } }`
    /// modifier and compose with this one.
    func ruulSheetToolbar(_ title: String, onClose: (() -> Void)? = nil) -> some View {
        modifier(RuulSheetToolbarModifier(title: title, onClose: onClose))
    }
}
