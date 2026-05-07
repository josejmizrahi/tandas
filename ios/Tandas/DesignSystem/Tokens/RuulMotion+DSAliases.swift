import SwiftUI

/// DS doc canonical Animation tokens (`docs/DesignSystem.md` §2.6). Additive —
/// the legacy `ruulSnappy/ruulSmooth/ruulBouncy/ruulMorph` accessors in
/// `RuulMotion.swift` still work.
public extension Animation {
    static let ruulTap         = Animation.spring(response: 0.30, dampingFraction: 0.70)
    static let ruulStateChange = Animation.smooth(duration: 0.30)
    static let ruulAppear      = Animation.smooth(duration: 0.40)
    static let ruulSuccess     = Animation.spring(response: 0.40, dampingFraction: 0.60)
    static let ruulSubtle      = Animation.easeInOut(duration: 0.20)
}
