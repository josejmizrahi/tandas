import SwiftUI
import RuulUI

// MARK: - Shared view helpers (rescued from section views — Phase F 2026-05-19)

extension View {
    /// Standard surface treatment for a section's content card.
    /// Used by `AttendeesListSheet` and any remaining sheet UI that
    /// needs the consistent card background.
    ///
    /// **2026-05-15 Luma refresh:** `.ultraThinMaterial` so cards pick
    /// up the detail screen's ambient palette tint instead of flat white.
    @ViewBuilder
    func cardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
        self.background(.ultraThinMaterial, in: shape)
    }
}
