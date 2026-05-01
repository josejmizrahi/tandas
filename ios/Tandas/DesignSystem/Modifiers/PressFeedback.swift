import SwiftUI

/// Visual press feedback used across primitives: subtle scale + opacity dip.
///
/// Apply via `.ruulPressEffect()` on a `Button`'s label, or use the supplied
/// `RuulButtonStyle` which already applies it.
public extension View {
    func ruulPressEffect(isPressed: Bool) -> some View {
        self
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .opacity(isPressed ? 0.92 : 1.0)
            .animation(.ruulSnappy, value: isPressed)
    }
}

/// A `ButtonStyle` that composes the standard ruul press effect.
public struct RuulPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ruulPressEffect(isPressed: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == RuulPressButtonStyle {
    static var ruulPress: RuulPressButtonStyle { RuulPressButtonStyle() }
}
