import SwiftUI

/// Shadow extensions per DS doc §2.5. ruul uses VERY subtle shadows.
public extension View {
    func ruulShadowSubtle() -> some View {
        shadow(color: .black.opacity(0.04), radius: 8,  x: 0, y: 2)
    }
    func ruulShadowMedium() -> some View {
        shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 4)
    }
    func ruulShadowElevated() -> some View {
        shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
    }
}
