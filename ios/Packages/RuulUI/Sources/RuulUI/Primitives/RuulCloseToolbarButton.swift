import SwiftUI

/// Standard close affordance for fullScreenCover/sheet toolbars.
///
/// Replaces the inconsistent mix of `Button("Cerrar")` plain-text
/// buttons (often in `ruulTextSecondary`, easy to miss) with a
/// recognizable xmark icon at primary contrast. Use as the
/// `.topBarLeading` toolbar item in every modal sheet so the close
/// gesture is in the same spot, with the same shape, every time.
///
/// Usage:
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .topBarLeading) {
///         RuulCloseToolbarButton { dismiss() }
///     }
/// }
/// ```
public struct RuulCloseToolbarButton: View {
    private let action: () -> Void
    private let accessibilityLabel: String

    public init(
        accessibilityLabel: String = "Cerrar",
        action: @escaping () -> Void
    ) {
        self.action = action
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .ruulTextStyle(RuulTypography.subheadSemibold)
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

#if DEBUG
#Preview("RuulCloseToolbarButton") {
    NavigationStack {
        Color.ruulBackground
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RuulCloseToolbarButton { }
                }
                ToolbarItem(placement: .principal) {
                    Text("Sheet title")
                        .ruulTextStyle(RuulTypography.headline)
                }
            }
    }
}
#endif
